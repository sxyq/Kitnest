import AppKit
import CoreAudio
import SwiftUI

// MARK: - 音频混音器（vorssaint 每 App 音量对齐，2026-10-19 用户需求）
//
// 公开 CoreAudio 能力边界（macOS 26.5 SDK 实测，2026-10-19）：
//   ✓ kAudioHardwarePropertyProcessObjectList('prs#')  枚举全部有声进程
//   ✓ kAudioProcessPropertyIsRunningOutput('piro')     实时「谁在出声」
//   ✓ kAudioHardwarePropertyProcessIsAudible('pmut')   本进程 bypass（自管豁免）
//   ✗ 其他进程的音量/静音选择器（'pmut'/'volm'/'vmul'）全部返回 'what'——
//     系统设置里的每 App 音量走私有 HAL，公开 API 无法实现（探针实测，
//     见 /tmp/audioprobe2.swift 输出 status=2003332927）。
// 因此本混音器提供：系统输出音量/静音、输出设备切换、实时有声 App 监视、
// 本 App 音频 bypass；每 App 音量以只读活动列表 + 能力说明呈现。

// MARK: - FourCC 辅助

private func cc(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for ch in s.utf8 { v = (v << 8) | UInt32(ch) }
    return v
}

private func addr(_ selector: UInt32, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - 数据模型

/// 一个正在输出音频的进程
public struct AudioAppInfo: Identifiable, Equatable {
    public let id: Int              // pid
    public let processObjectID: AudioObjectID
    public let name: String
    public let bundleID: String
    public let icon: NSImage?

    public static func == (l: AudioAppInfo, r: AudioAppInfo) -> Bool { l.id == r.id }
}

/// 一个输出设备
public struct AudioDeviceInfo: Identifiable, Equatable {
    public let id: AudioObjectID
    public let name: String
    public let isDefault: Bool

    public static func == (l: AudioDeviceInfo, r: AudioDeviceInfo) -> Bool { l.id == r.id }
}

// MARK: - 控制器

public final class AudioMixerController: ObservableObject {
    public static let shared = AudioMixerController()

    /// 系统输出音量 0-1
    @Published public var outputVolume: Double = 0 {
        didSet {
            if !readingOutput && oldValue != outputVolume { setSystemVolume(Float(outputVolume)) }
        }
    }
    /// 系统静音
    @Published public var outputMuted: Bool = false {
        didSet {
            if !readingOutput && oldValue != outputMuted { setSystemMuted(outputMuted) }
        }
    }
    /// 输出设备列表
    @Published public var devices: [AudioDeviceInfo] = []
    /// 当前默认输出设备
    @Published public var selectedDevice: AudioObjectID? {
        didSet {
            guard !readingOutput, oldValue != selectedDevice, let id = selectedDevice else { return }
            selectDefaultDevice(id)
        }
    }
    /// 实时有声 App
    @Published public var playingApps: [AudioAppInfo] = []
    /// 本 App 音频 bypass（自管豁免；公开 API 仅对本进程可写）
    @Published public var selfAudible: Bool = true {
        didSet { setSelfAudible(selfAudible) }
    }
    /// 每 App 音量能力（公开 API 实测不可用 → UI 显示说明）
    @Published public private(set) var perAppVolumeSupported = false
    @Published public private(set) var volumeAvailable = false
    @Published public private(set) var volumeAdjustable = false
    @Published public private(set) var muteAvailable = false
    @Published public private(set) var muteAdjustable = false
    @Published public private(set) var outputError: String?

    private var refreshTimer: Timer?
    private var visibleClients = 0
    private var readingOutput = false

    // v128（流畅度）：进程图标缓存（pid → NSImage）——原来每 2s 对每个有声进程
    // 重取 NSRunningApplication.icon（AppKit 图标查找/解码），窗口开着半小时就是
    // 几千次重复查找。图标随 pid 不变，缓存后整窗生命周期内每进程只查一次。
    private var iconCache: [Int32: NSImage] = [:]

    private init() {
        selfAudible = getSelfAudible()
        refreshSystemOutput()
    }

    // MARK: 定时刷新（窗口可见期间）

    public func startRefreshing() {
        visibleClients += 1
        guard refreshTimer == nil else { return }
        refreshSystemOutput()
        refreshPlayingApps()
        // 设置音频页与 Dock 共享计数，最后一个可见使用方退出才停止。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            autoreleasepool {
                self?.refreshSystemOutput()
                self?.refreshPlayingApps()
            }
        }
    }

    public func stopRefreshing() {
        visibleClients -= 1
        guard visibleClients == 0 else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: 系统音量 / 静音（默认输出设备，主控或实际输出声道）

    private var defaultOutputID: AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        if status != noErr { reportOutputError("读取默认输出设备", status) }
        return id
    }

    /// 读值不触发 didSet 写设备；设置页和 Dock 共用同一份真实状态。
    public func refreshSystemOutput() {
        readingOutput = true
        defer { readingOutput = false }
        reloadDevices()
        outputVolume = getSystemVolume()
        outputMuted = getSystemMuted()
    }

    private func reportOutputError(_ operation: String, _ status: OSStatus) {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
        let fourCC = bytes.allSatisfy { (32...126).contains($0) }
            ? " / '\(String(bytes: bytes, encoding: .ascii)!)'" : ""
        outputError = "\(operation)失败：CoreAudio OSStatus \(status)\(fourCC)"
    }

    /// 主控或实际输出声道；HDMI 等没有该属性的硬件返回空列表。
    private func outputControls(_ selector: UInt32, device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        guard device != kAudioObjectUnknown else { return [] }
        var main = addr(selector, kAudioObjectPropertyScopeOutput)
        if AudioObjectHasProperty(device, &main) { return [main] }
        var streams = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size)
        guard sizeStatus == noErr else {
            reportOutputError("读取输出声道", sizeStatus)
            return []
        }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        let status = AudioObjectGetPropertyData(device, &streams, 0, nil, &size, data)
        guard status == noErr else {
            reportOutputError("读取输出声道", status)
            return []
        }
        let channels = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        return (0..<channels).compactMap { channel in
            var a = addr(selector, kAudioObjectPropertyScopeOutput, channel + 1)
            return AudioObjectHasProperty(device, &a) ? a : nil
        }
    }

    private func outputControlSettable(_ address: AudioObjectPropertyAddress, device: AudioObjectID) -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &a, &settable)
        if status != noErr { reportOutputError("读取输出控件能力", status) }
        return status == noErr && settable.boolValue
    }

    public func getSystemVolume() -> Double {
        let device = defaultOutputID
        let controls = outputControls(kAudioDevicePropertyVolumeScalar, device: device)
        volumeAvailable = false
        volumeAdjustable = false
        guard !controls.isEmpty else { return outputVolume }
        var values: [Float32] = []
        for var a in controls {
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &vol)
            guard status == noErr else {
                reportOutputError("读取系统音量", status)
                return outputVolume
            }
            values.append(vol)
        }
        volumeAvailable = true
        volumeAdjustable = controls.allSatisfy { outputControlSettable($0, device: device) }
        return Double(values.max()!)
    }

    public func setSystemVolume(_ v: Float) {
        outputError = nil
        let device = defaultOutputID
        let controls = outputControls(kAudioDevicePropertyVolumeScalar, device: device)
        // 声道音量按最大值等比调整，保留系统原有左右平衡。
        var values: [Float32] = []
        for var a in controls {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value)
            guard status == noErr else {
                reportOutputError("读取声道音量", status)
                refreshSystemOutput()
                return
            }
            values.append(value)
        }
        let maximum = values.max() ?? 0
        for (index, var a) in controls.enumerated() {
            var value = maximum > 0 ? values[index] / maximum * v : v
            let status = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            if status != noErr { reportOutputError("设置系统音量", status); break }
        }
        refreshSystemOutput()
    }

    public func getSystemMuted() -> Bool {
        let device = defaultOutputID
        let controls = outputControls(kAudioDevicePropertyMute, device: device)
        muteAvailable = false
        muteAdjustable = false
        guard !controls.isEmpty else { return outputMuted }
        var muted = true
        for var a in controls {
            var m: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m)
            guard status == noErr else {
                reportOutputError("读取系统静音", status)
                return outputMuted
            }
            muted = muted && m != 0
        }
        muteAvailable = true
        muteAdjustable = controls.allSatisfy { outputControlSettable($0, device: device) }
        return muted
    }

    public func setSystemMuted(_ muted: Bool) {
        outputError = nil
        let device = defaultOutputID
        for var a in outputControls(kAudioDevicePropertyMute, device: device) {
            var m: UInt32 = muted ? 1 : 0
            let status = AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
            if status != noErr { reportOutputError("设置系统静音", status); break }
        }
        refreshSystemOutput()
    }

    // MARK: 本 App bypass（kAudioHardwarePropertyProcessIsAudible 'pmut'，系统对象）

    public func getSelfAudible() -> Bool {
        var a = addr(cc("pmut"))
        var v: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &v) == 0 else { return true }
        return v != 0
    }

    public func setSelfAudible(_ audible: Bool) {
        var a = addr(cc("pmut"))
        var v: UInt32 = audible ? 1 : 0
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    // MARK: 输出设备

    public func reloadDevices() {
        let wasReading = readingOutput
        readingOutput = true
        defer { readingOutput = wasReading }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = addr(cc("dev#"))
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &size)
        guard sizeStatus == noErr else {
            devices = []
            selectedDevice = nil
            reportOutputError("枚举输出设备", sizeStatus)
            return
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let listStatus = AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &size, &ids)
        guard listStatus == noErr else {
            devices = []
            selectedDevice = nil
            reportOutputError("枚举输出设备", listStatus)
            return
        }

        let defaultID = defaultOutputID
        var out: [AudioDeviceInfo] = []
        for id in ids {
            // 有输出流的设备才有意义（output scope 的设备流数 > 0）
            var streamAddr = AudioObjectPropertyAddress(mSelector: cc("stm#"),
                                                        mScope: kAudioObjectPropertyScopeOutput,
                                                        mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &sSize)
            if streamStatus != noErr { reportOutputError("读取设备 \(id) 输出流", streamStatus); continue }
            guard sSize > 0 else { continue }
            // 'name' 返回 C 字符串；'lnam' 才返回供下方桥接的 CFString。
            var nameAddr = addr(kAudioObjectPropertyName)
            var name: CFString = "" as CFString
            var nSize = UInt32(MemoryLayout<CFString>.stride)
            let nameStatus = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nSize, &name)
            if nameStatus != noErr { reportOutputError("读取设备 \(id) 名称", nameStatus); continue }
            out.append(AudioDeviceInfo(id: id, name: name as String, isDefault: id == defaultID))
        }
        devices = out
        selectedDevice = defaultID == kAudioObjectUnknown ? nil : defaultID
    }

    public func selectDefaultDevice(_ id: AudioObjectID) {
        outputError = nil
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(cc("dOut"))
        var dev = id
        let status = AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
        if status != noErr { reportOutputError("切换默认输出设备", status) }
        refreshSystemOutput()
    }

    // MARK: 实时有声 App（'prs#' + 'piro'）

    public func refreshPlayingApps() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = addr(cc("prs#"))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &size) == 0, size > 0 else {
            playingApps = []
            return
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &size, &ids) == 0 else { return }

        var apps: [AudioAppInfo] = []
        apps.reserveCapacity(ids.count)
        for objID in ids {
            var runAddr = addr(cc("piro"))
            var run: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(objID, &runAddr, 0, nil, &runSize, &run) == 0, run == 1 else { continue }

            var pidAddr = addr(cc("ppid"))
            var pid: Int32 = 0
            var pidSize = UInt32(MemoryLayout<Int32>.size)
            guard AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid) == 0, pid > 0 else { continue }

            let running = NSRunningApplication(processIdentifier: pid)
            // v128（流畅度）：图标按 pid 缓存——原每 2s 重取 NSRunningApplication.icon
            // （AppKit 图标查找/解码），有声进程不变时纯属重复开销。
            let icon: NSImage?
            if let cached = iconCache[pid] {
                icon = cached
            } else {
                icon = running?.icon
                if let icon { iconCache[pid] = icon }
            }
            apps.append(AudioAppInfo(id: Int(pid),
                                     processObjectID: objID,
                                     name: running?.localizedName ?? "PID \(pid)",
                                     bundleID: running?.bundleIdentifier ?? "",
                                     icon: icon))
        }
        // v128（流畅度）：无变化不触发 @Published——AudioAppInfo 的 == 只比 pid，
        // 列表不变时写回会让整页 Form 每 2s 白重绘一次（含 Slider/Picker）。
        if apps.map(\.id) != playingApps.map(\.id) {
            playingApps = apps
        }
    }
}

// MARK: - 设置页（设置 → 音频）

public struct AudioMixerPane: View {
    @ObservedObject private var mixer = AudioMixerController.shared

    public init() {}

    public var body: some View {
        Form {
            Section("系统输出") {
                HStack {
                    Image(systemName: mixer.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Slider(value: $mixer.outputVolume, in: 0...1)
                        .disabled(!mixer.volumeAdjustable || (mixer.muteAvailable && mixer.outputMuted))
                    Text(mixer.volumeAvailable ? "\(Int(mixer.outputVolume * 100))%" : "—")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                    Toggle("静音", isOn: $mixer.outputMuted)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!mixer.muteAdjustable)
                }
                if mixer.outputError == nil {
                    if !mixer.volumeAdjustable { Text("此输出设备不支持软件调节音量").foregroundStyle(.secondary) }
                    if !mixer.muteAdjustable { Text("此输出设备不支持软件静音").foregroundStyle(.secondary) }
                }
                if let error = mixer.outputError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }

            Section("输出设备") {
                Picker("默认设备", selection: $mixer.selectedDevice) {
                    ForEach(mixer.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
            }

            Section("正在播放声音的 App（实时）") {
                if mixer.playingApps.isEmpty {
                    Text("当前没有 App 在输出音频")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mixer.playingApps) { app in
                        HStack(spacing: 8) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            Text(app.name).font(.system(size: 12))
                            Spacer()
                            Image(systemName: "waveform")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Text("每 App 独立音量/静音需要私有 HAL 接口（公开 CoreAudio 在本系统实测仅支持进程枚举与活动判断，见探针记录），系统设置 > 声音 中的每 App 音量为系统私有实现。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }

            Section("本 App 音频") {
                Toggle("本 App 音频可被听到（音频 bypass 豁免）", isOn: $mixer.selfAudible)
                Text("公开 API 仅允许进程管理自身音频通道（kAudioHardwarePropertyProcessIsAudible）。关闭后本 App 发出的声音静默，用于「自管音频 App bypass」。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .onAppear { mixer.startRefreshing() }
        .onDisappear { mixer.stopRefreshing() }
    }
}
