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
public struct AudioAppInfo: Identifiable {
    public let id: Int              // pid
    public let name: String
    public let icon: NSImage?
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
    @Published public var outputVolume: Double = 0.5 {
        didSet {
            guard !readingOutput else { return }
            if setSystemVolume(Float(outputVolume)), oldValue != outputVolume,
               outputVolume == 0 || outputVolume == 1 {
                HapticFeedback.perform(.volumeBoundary)
            }
        }
    }
    /// 系统静音
    @Published public var outputMuted: Bool = false {
        didSet { if !readingOutput { setSystemMuted(outputMuted) } }
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
    @Published public private(set) var volumeReadable = false
    @Published public private(set) var muteReadable = false
    @Published public private(set) var outputError = ""

    private var refreshTimer: Timer?
    private var readingOutput = false
    private var settingsVisible = false
    private var islandConsumers = Set<UUID>()
    private var outputListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listenedOutput: AudioObjectID = 0
    private lazy var outputListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        guard let self, self.settingsVisible || !self.islandConsumers.isEmpty else { return }
        let outputChanged = self.listenedOutput != self.defaultOutputID
        if outputChanged { self.removeOutputListeners(); self.addOutputListeners() }
        let devicesChanged = UnsafeBufferPointer(start: addresses, count: Int(count)).contains {
            $0.mSelector == kAudioHardwarePropertyDevices
        }
        self.refreshOutputState(refreshDevices: outputChanged || devicesChanged)
    }

    // v128（流畅度）：进程图标缓存（pid → NSImage）——原来每 2s 对每个有声进程
    // 重取 NSRunningApplication.icon（AppKit 图标查找/解码），窗口开着半小时就是
    // 几千次重复查找。图标随 pid 不变，缓存后整窗生命周期内每进程只查一次。
    private var iconCache: [Int32: NSImage] = [:]

    private init() {
        refreshOutputState(refreshDevices: true)
        selfAudible = getSelfAudible()
    }

    // MARK: 定时刷新（窗口可见期间）

    public func startRefreshing() {
        settingsVisible = true
        if outputListeners.isEmpty { addOutputListeners() }
        refreshOutputState(refreshDevices: true)
        guard refreshTimer == nil else { return }
        refreshPlayingApps()
        // v128（流畅度）：周期维持 2s——本 timer 仅在「设置 → 音频」页可见时跑
        // （onAppear/onDisappear 成对启停），关闭页面即完全停止，不存在常驻成本；
        // 「谁在出声」需要实时性，降频会让列表明显滞后。回调体补 autoreleasepool。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                autoreleasepool { self?.refreshPlayingApps() }
            }
        }
    }

    public func stopRefreshing() {
        settingsVisible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        if islandConsumers.isEmpty { removeOutputListeners() }
    }

    /// 刘海仅消费系统输出；设置页的进程采样由它自己持有。
    public func setIslandVisible(_ visible: Bool, consumer: UUID) {
        if visible { islandConsumers.insert(consumer) } else { islandConsumers.remove(consumer) }
        if visible {
            if outputListeners.isEmpty { addOutputListeners() }
            refreshOutputState(refreshDevices: true)
        } else if islandConsumers.isEmpty && !settingsVisible { removeOutputListeners() }
    }

    private func addOutputListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listenedOutput = defaultOutputID
        let properties = [(system, addr(kAudioHardwarePropertyDefaultOutputDevice)),
                          (system, addr(kAudioHardwarePropertyDevices))] +
            volumeProperties(for: listenedOutput).map { (listenedOutput, $0) } +
            [(listenedOutput, addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput))]
        for (object, property) in properties {
            var property = property
            if AudioObjectHasProperty(object, &property) {
                let status = AudioObjectAddPropertyListenerBlock(object, &property, .main, outputListener)
                if status == noErr { outputListeners.append((object, property)) }
                else { outputError = "系统输出监听失败：\(status)" }
            }
        }
    }

    private func removeOutputListeners() {
        for (object, property) in outputListeners {
            var property = property
            AudioObjectRemovePropertyListenerBlock(object, &property, .main, outputListener)
        }
        outputListeners.removeAll()
        listenedOutput = 0
    }

    private func refreshOutputState(refreshDevices: Bool = false) {
        readingOutput = true
        defer { readingOutput = false }
        let device = defaultOutputID
        let properties = volumeProperties(for: device)
        volumeReadable = !properties.isEmpty
        if volumeReadable { outputVolume = getSystemVolume(device, properties: properties) }
        var mute = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        muteReadable = AudioObjectHasProperty(device, &mute)
        if muteReadable { outputMuted = getSystemMuted(device) }
        if refreshDevices { reloadDevices(defaultID: device) }
    }

    // MARK: 系统音量 / 静音（默认输出设备，scope output element main）

    private var defaultOutputID: AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(cc("dOut"))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == 0, id != 0 else {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return id
    }

    private func volumeProperties(for device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        // 本机默认设备仅提供公开 volm；部分设备使用虚拟主音量或独立左右声道。
        for selector in [cc("voll"), kAudioDevicePropertyVolumeScalar] {
            var property = addr(selector, kAudioObjectPropertyScopeOutput)
            if AudioObjectHasProperty(device, &property) { return [property] }
        }
        var stereo = addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput)
        var channels: [UInt32] = [0, 0]
        var size = UInt32(2 * MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &stereo, 0, nil, &size, &channels) == noErr else { return [] }
        return Array(Set(channels)).sorted().compactMap { channel in
            var property = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, channel)
            return AudioObjectHasProperty(device, &property) ? property : nil
        }
    }

    private func getSystemVolume(_ device: AudioObjectID, properties: [AudioObjectPropertyAddress]) -> Double {
        var total = 0.0
        for var property in properties {
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &volume)
            guard status == noErr else { volumeReadable = false; outputError = "读取系统音量失败：\(status)"; return outputVolume }
            total += Double(volume)
        }
        return total / Double(properties.count)
    }

    @discardableResult
    public func setSystemVolume(_ v: Float) -> Bool {
        let device = defaultOutputID
        let properties = volumeProperties(for: device)
        guard !properties.isEmpty else { outputError = "输出设备不提供系统音量，请使用设备音量旋钮"; return false }
        outputError = ""
        var vol = min(1, max(0, v))
        var succeeded = true
        for var property in properties {
            let status = AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            if status != noErr { outputError = "设置系统音量失败：\(status)"; succeeded = false; break }
        }
        refreshOutputState()
        return succeeded
    }

    private func getSystemMuted(_ device: AudioObjectID) -> Bool {
        var a = addr(cc("mute"), kAudioObjectPropertyScopeOutput)
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &a, 0, nil, &size, &m)
        guard status == noErr else { muteReadable = false; outputError = "读取系统静音失败：\(status)"; return outputMuted }
        return m != 0
    }

    public func setSystemMuted(_ muted: Bool) {
        var a = addr(cc("mute"), kAudioObjectPropertyScopeOutput)
        var m: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(defaultOutputID, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        outputError = status == noErr ? "" : "设置系统静音失败：\(status)"
        refreshOutputState()
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

    private func reloadDevices(defaultID: AudioObjectID) {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = addr(cc("dev#"))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &size) == 0, size > 0 else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &size, &ids) == 0 else { return }

        var out: [AudioDeviceInfo] = []
        for id in ids {
            // 有输出流的设备才有意义（output scope 的设备流数 > 0）
            var streamAddr = AudioObjectPropertyAddress(mSelector: cc("stm#"),
                                                        mScope: kAudioObjectPropertyScopeOutput,
                                                        mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &sSize) == 0, sSize > 0 else { continue }
            // 'name' 返回 C 字符串；'lnam' 才返回供下方桥接的 CFString。
            var nameAddr = addr(kAudioObjectPropertyName)
            var name: CFString = "" as CFString
            var nSize = UInt32(MemoryLayout<CFString>.stride)
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nSize, &name)
            out.append(AudioDeviceInfo(id: id, name: name as String, isDefault: id == defaultID))
        }
        devices = out
        selectedDevice = defaultID
    }

    public func selectDefaultDevice(_ id: AudioObjectID) {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(cc("dOut"))
        var dev = id
        let status = AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
        outputError = status == noErr ? "" : "切换输出设备失败：\(status)"
        if !outputListeners.isEmpty { removeOutputListeners(); addOutputListeners() }
        refreshOutputState(refreshDevices: true)
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
                                     name: running?.localizedName ?? "PID \(pid)",
                                     icon: icon))
        }
        // 进程顺序不变时不发布，避免每 2s 重绘设置页。
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
                        .disabled(mixer.outputMuted)
                    Text("\(Int(mixer.outputVolume * 100))%")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                    Toggle("静音", isOn: $mixer.outputMuted)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
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
