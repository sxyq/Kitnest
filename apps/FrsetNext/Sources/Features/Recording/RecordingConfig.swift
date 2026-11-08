import Foundation
import CoreGraphics

// MARK: - 录屏配置（v264 · C 档「录屏五件套」的开关面）
//
// 对标 1Capture 的录屏：摄像头画中画 / 显示按键 / 忽略指定 App / 点击动画 /
// 后期编辑器。这里把「录什么、叠什么」收敛成一个值类型，
// 录制器只认 RecordingOptions，不再到处读 UserDefaults。

public enum RecordingAudioSource: String, CaseIterable, Identifiable {
    case none, system, microphone
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none:       return "不录音"
        case .system:     return "系统声音"
        case .microphone: return "麦克风"
        }
    }
}

public enum RecordingCorner: String, CaseIterable, Identifiable {
    case bottomRight, bottomLeft, topRight, topLeft
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bottomRight: return "右下"
        case .bottomLeft:  return "左下"
        case .topRight:    return "右上"
        case .topLeft:     return "左上"
        }
    }
}

public struct RecordingOptions {
    /// 录制区域（nil = 整屏）
    public var region: CGRect?
    /// 目标显示器（区域为空时用）
    public var displayID: CGDirectDisplayID?
    public var fps: Int = 30
    public var audio: RecordingAudioSource = .none
    public var showsCursor: Bool = true
    /// 摄像头画中画
    public var cameraEnabled: Bool = false
    public var cameraDeviceID: String?
    public var cameraCorner: RecordingCorner = .bottomRight
    /// 画中画宽度占画面宽度的比例（0.12–0.3）
    public var cameraScale: CGFloat = 0.18
    /// 显示按键
    public var showKeys: Bool = false
    /// 点击动画
    public var showClicks: Bool = false
    /// 忽略的 App bundle id（这些 App 的窗口不会进画面）
    public var excludedBundleIDs: [String] = []

    public init() {}

    // MARK: 偏好

    static let keyFPS = "recording.fps"
    static let keyAudio = "recording.audio"
    static let keyCursor = "recording.showsCursor"
    static let keyCamera = "recording.camera.enabled"
    static let keyCameraDevice = "recording.camera.device"
    static let keyCameraCorner = "recording.camera.corner"
    static let keyCameraScale = "recording.camera.scale"
    static let keyKeys = "recording.keys"
    static let keyClicks = "recording.clicks"
    static let keyExcluded = "recording.excludedApps"
    static let keySavePath = "recording.savePath"

    public static var defaultFPS: Int {
        get { Preferences.shared.value(keyFPS, default: 30) }
        set { Preferences.shared.set(keyFPS, max(15, min(60, newValue))) }
    }
    public static var defaultAudio: RecordingAudioSource {
        get { RecordingAudioSource(rawValue: Preferences.shared.value(keyAudio, default: "none")) ?? .none }
        set { Preferences.shared.set(keyAudio, newValue.rawValue) }
    }
    public static var defaultShowsCursor: Bool {
        get { Preferences.shared.value(keyCursor, default: true) }
        set { Preferences.shared.set(keyCursor, newValue) }
    }
    public static var cameraEnabled: Bool {
        get { Preferences.shared.value(keyCamera, default: false) }
        set { Preferences.shared.set(keyCamera, newValue) }
    }
    public static var cameraDeviceID: String {
        get { Preferences.shared.value(keyCameraDevice, default: "") }
        set { Preferences.shared.set(keyCameraDevice, newValue) }
    }
    public static var cameraCorner: RecordingCorner {
        get { RecordingCorner(rawValue: Preferences.shared.value(keyCameraCorner, default: "bottomRight")) ?? .bottomRight }
        set { Preferences.shared.set(keyCameraCorner, newValue.rawValue) }
    }
    public static var cameraScale: Double {
        get { Preferences.shared.value(keyCameraScale, default: 0.18) }
        set { Preferences.shared.set(keyCameraScale, max(0.10, min(0.35, newValue))) }
    }
    public static var showKeys: Bool {
        get { Preferences.shared.value(keyKeys, default: false) }
        set { Preferences.shared.set(keyKeys, newValue) }
    }
    public static var showClicks: Bool {
        get { Preferences.shared.value(keyClicks, default: false) }
        set { Preferences.shared.set(keyClicks, newValue) }
    }
    /// 忽略录制的 App（bundle id 列表）
    public static var excludedBundleIDs: [String] {
        get { Preferences.shared.value(keyExcluded, default: []) }
        set { Preferences.shared.set(keyExcluded, newValue) }
    }
    /// 录制文件保存目录（空 = 下载目录）
    public static var saveDirectory: URL {
        get {
            let raw: String = Preferences.shared.value(keySavePath, default: "")
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? AppDirectories.sub("recordings")
            }
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        set { Preferences.shared.set(keySavePath, newValue.path) }
    }

    /// 保存目录的原始偏好（设置页输入框显示用；空 = 下载目录）
    public static var savePathRaw: String {
        Preferences.shared.value(keySavePath, default: "")
    }

    /// 从偏好组装一份「当前设置」
    public static func current(region: CGRect? = nil,
                               displayID: CGDirectDisplayID? = nil) -> RecordingOptions {
        var o = RecordingOptions()
        o.region = region
        o.displayID = displayID
        o.fps = defaultFPS
        o.audio = defaultAudio
        o.showsCursor = defaultShowsCursor
        o.cameraEnabled = cameraEnabled
        o.cameraDeviceID = cameraDeviceID.isEmpty ? nil : cameraDeviceID
        o.cameraCorner = cameraCorner
        o.cameraScale = CGFloat(cameraScale)
        o.showKeys = showKeys
        o.showClicks = showClicks
        o.excludedBundleIDs = excludedBundleIDs
        return o
    }
}
