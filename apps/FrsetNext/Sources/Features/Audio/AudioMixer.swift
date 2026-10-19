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
    @Published public var outputVolume: Double = 0.5 {
        didSet { setSystemVolume(Float(outputVolume)) }
    }
    /// 系统静音
    @Published public var outputMuted: Bool = false {
        didSet { setSystemMuted(outputMuted) }
    }
    /// 输出设备列表
    @Published public var devices: [AudioDeviceInfo] = []
    /// 当前默认输出设备
    @Published public var selectedDevice: AudioObjectID? {
        didSet {
            guard oldValue != selectedDevice, let id = selectedDevice else { return }
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

    private var refreshTimer: Timer?

    private init() {
        outputVolume = getSystemVolume()
        outputMuted = getSystemMuted()
        selfAudible = getSelfAudible()
        reloadDevices()
    }

    // MARK: 定时刷新（窗口可见期间）

    public func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshPlayingApps()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPlayingApps() }
        }
    }

    public func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: 系统音量 / 静音（默认输出设备，scope output element main）

    private var defaultOutputID: AudioObjectID {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(cc("dOut"))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == 0, id != 0 else {
            return AudioObjectID(1)  // kAudioObjectUnknown 回退设备 1
        }
        return id
    }

    public func getSystemVolume() -> Double {
        var a = addr(cc("voll"), kAudioObjectPropertyScopeOutput)
        var vol: Float32 = 0.5
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(defaultOutputID, &a, 0, nil, &size, &vol) == 0 else { return 0.5 }
        return Double(vol)
    }

    public func setSystemVolume(_ v: Float) {
        var a = addr(cc("voll"), kAudioObjectPropertyScopeOutput)
        var vol = min(1, max(0, v))
        AudioObjectSetPropertyData(defaultOutputID, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
    }

    public func getSystemMuted() -> Bool {
        var a = addr(cc("mute"), kAudioObjectPropertyScopeOutput)
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(defaultOutputID, &a, 0, nil, &size, &m) == 0 else { return false }
        return m != 0
    }

    public func setSystemMuted(_ muted: Bool) {
        var a = addr(cc("mute"), kAudioObjectPropertyScopeOutput)
        var m: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(defaultOutputID, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
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
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = addr(cc("dev#"))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &listAddr, 0, nil, &size) == 0, size > 0 else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &listAddr, 0, nil, &size, &ids) == 0 else { return }

        let defaultID = defaultOutputID
        var out: [AudioDeviceInfo] = []
        for id in ids {
            // 有输出流的设备才有意义（output scope 的设备流数 > 0）
            var streamAddr = AudioObjectPropertyAddress(mSelector: cc("stm#"),
                                                        mScope: kAudioObjectPropertyScopeOutput,
                                                        mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &sSize) == 0, sSize > 0 else { continue }
            var nameAddr = addr(cc("name"))
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
        AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev)
        reloadDevices()
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
            apps.append(AudioAppInfo(id: Int(pid),
                                     processObjectID: objID,
                                     name: running?.localizedName ?? "PID \(pid)",
                                     bundleID: running?.bundleIdentifier ?? "",
                                     icon: running?.icon))
        }
        playingApps = apps
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
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Text("每 App 独立音量/静音需要私有 HAL 接口（公开 CoreAudio 在本系统实测仅支持进程枚举与活动判断，见探针记录），系统设置 > 声音 中的每 App 音量为系统私有实现。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Section("本 App 音频") {
                Toggle("本 App 音频可被听到（音频 bypass 豁免）", isOn: $mixer.selfAudible)
                Text("公开 API 仅允许进程管理自身音频通道（kAudioHardwarePropertyProcessIsAudible）。关闭后本 App 发出的声音静默，用于「自管音频 App bypass」。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .onAppear { mixer.startRefreshing() }
        .onDisappear { mixer.stopRefreshing() }
    }
}
