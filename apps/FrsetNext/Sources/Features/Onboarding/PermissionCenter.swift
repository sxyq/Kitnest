import AppKit
import ApplicationServices
import AVFoundation
import EventKit
import ScreenCaptureKit
import SwiftUI

// MARK: - 权限中心（重建版自研，替代原版 PermissionWindow 系列）
//
// 背景：原版只有「屏幕录制」一个权限引导窗（PermissionWindow/PermissionWindowController/
// PermissionPromptModel，逆向审计中的未实现项）。重建版功能面远大于原版，实际涉及
// 四类 TCC 权限，且散落在各模块各自弹窗（ScreenshotManager 的 NSAlert、ClipboardManager
// 的 Toast、CalendarService 的静默请求）——缺少统一入口与统一状态视图。
//
// 本中心只做「状态探测 / 发起请求 / 跳转系统设置」三件事，不持有 UI：
//   · 屏幕录制：CGPreflight 有假阴性（重签名/自签证书/启动方式，见 ScreenshotManager
//     probePermission 头注），权威判据用 SCShareableContent 实探；
//   · 辅助功能：AXIsProcessTrusted 无请求 API，只能引导去系统设置（可带系统提示弹窗）；
//   · 麦克风 / 日历：标准 requestAccess 流程。
//
// 权限 URL 形如 x-apple.systempreferences:com.apple.preference.security?Privacy_XXX，
// 老系统（<13）打不开时回退 Toast（与原版 Unable to Open Link 行为对齐）。

/// FrsetNext 涉及的权限种类（与欢迎窗「权限引导卡」、权限引导窗共用同一份定义）
public enum PermissionKind: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case microphone
    case calendar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .accessibility:    return "辅助功能"
        case .microphone:       return "麦克风"
        case .calendar:         return "日历"
        }
    }

    public var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility:    return "hand.raised.circle"
        case .microphone:       return "mic"
        case .calendar:         return "calendar"
        }
    }

    /// 一句话说明「为什么要这个权限」——权限引导窗与欢迎窗共用
    public var purpose: String {
        switch self {
        case .screenRecording:
            return "截图、长截图、OCR、取色、录屏都需要读取屏幕内容"
        case .accessibility:
            return "自动粘贴、划词工具条、全局快捷键与双击唤起需要监听/合成系统事件"
        case .microphone:
            return "录屏时录制麦克风声音（可选，仅录系统音则不授予）"
        case .calendar:
            return "主面板日历卡片读取日程与节假日（不授予则日历仅显示日期）"
        }
    }

    /// 关联功能（引导窗中列出的功能名）
    public var features: [String] {
        switch self {
        case .screenRecording:
            return ["区域/全屏截图", "长截图", "截图识字 OCR", "取色器", "屏幕录制"]
        case .accessibility:
            return ["复制后自动粘贴", "划词工具条", "全局热键", "双击唤起面板"]
        case .microphone:
            return ["录屏收音"]
        case .calendar:
            return ["日历卡片", "节假日标识"]
        }
    }

    /// 是否「核心权限」（未授权时主流程受损，引导窗置顶强调）
    public var isCore: Bool {
        switch self {
        case .screenRecording, .accessibility: return true
        case .microphone, .calendar:           return false
        }
    }

    /// 系统设置隐私页 URL 片段
    var settingsFragment: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility:    return "Privacy_Accessibility"
        case .microphone:       return "Privacy_Microphone"
        case .calendar:         return "Privacy_Calendars"
        }
    }

    public var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsFragment)")
    }
}

public enum PermissionStatus: String {
    case granted
    case denied
    case notDetermined
    case unsupported

    public var isGranted: Bool { self == .granted }

    public var label: String {
        switch self {
        case .granted:       return "已授权"
        case .denied:        return "已拒绝"
        case .notDetermined: return "未授权"
        case .unsupported:   return "不可用"
        }
    }

    public var symbol: String {
        switch self {
        case .granted:       return "checkmark.circle.fill"
        case .denied:        return "xmark.circle.fill"
        case .notDetermined: return "circle"
        case .unsupported:   return "minus.circle"
        }
    }

    public var tint: Color {
        switch self {
        case .granted:       return Color(nsColor: .systemGreen)
        case .denied:        return Color(nsColor: .systemRed)
        case .notDetermined: return Color(nsColor: .secondaryLabelColor)
        case .unsupported:   return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: - 权限中心

public final class PermissionCenter: ObservableObject {

    public static let shared = PermissionCenter()

    /// 全部权限当前状态（引导窗/欢迎窗观察）
    @Published public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]

    /// 屏幕录制权威探测是否进行中（SCK 实探需要一瞬）
    @Published public private(set) var probingScreenRecording = false

    private let eventStore = EKEventStore()

    private init() {
        refreshAll()
    }

    // MARK: - 状态

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notDetermined
    }

    /// 快速刷新（不发起 SCK 实探）；viewOnAppear 用
    public func refreshAll() {
        var next: [PermissionKind: PermissionStatus] = [:]
        for kind in PermissionKind.allCases {
            next[kind] = quickStatus(kind)
        }
        statuses = next
    }

    /// 快速状态：屏幕录制用 CGPreflight（可能假阴性，权威值走 probeScreenRecording）
    private func quickStatus(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:    return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default:    return .unsupported
            }
        case .calendar:
            // 用 rawValue 判定而非 switch 枚举：兼容 macOS 14 引入的 .fullAccess/.writeOnly
            // （notDetermined=0, restricted=1, denied=2, authorized=3, fullAccess=4, writeOnly=5，
            //   见 CalendarService 同款处理）
            let raw = EKEventStore.authorizationStatus(for: .event).rawValue
            switch raw {
            case EKAuthorizationStatus.notDetermined.rawValue: return .notDetermined
            case EKAuthorizationStatus.restricted.rawValue,
                 EKAuthorizationStatus.denied.rawValue:        return .denied
            default:
                return raw >= EKAuthorizationStatus.authorized.rawValue ? .granted : .notDetermined
            }
        }
    }

    /// 屏幕录制权威探测：以 SCK 能否枚举显示器为准（preflight 假阴性场景，
    /// 见 ScreenshotManager.probePermission 头注：自签证书/重签名/启动方式都会让
    /// preflight 返回 false 而实际抓屏可用）。
    @MainActor
    public func probeScreenRecording() async {
        if CGPreflightScreenCaptureAccess() {
            statuses[.screenRecording] = .granted
            return
        }
        probingScreenRecording = true
        defer { probingScreenRecording = false }
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                statuses[.screenRecording] = content.displays.isEmpty ? .notDetermined : .granted
                Log.info("Onboarding", "权限实探：屏幕录制 SCK=\(content.displays.isEmpty ? "不可用" : "可用")")
            } catch {
                statuses[.screenRecording] = .notDetermined
                Log.info("Onboarding", "权限实探：屏幕录制 SCK 失败 \(error.localizedDescription)")
            }
        } else {
            statuses[.screenRecording] = .notDetermined
        }
    }

    // MARK: - 请求

    /// 发起授权请求。返回请求后的状态（用户可能在系统面板里拒绝）。
    /// 注意：辅助功能没有「弹窗即请求」的 API，走系统提示 + 引导去设置。
    public func request(_ kind: PermissionKind, completion: ((PermissionStatus) -> Void)? = nil) {
        switch kind {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
            // 授权后面板不会回调，延迟后刷新（用户切出去再切回来通常 >1s）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.refreshAll()
                Task { await self?.probeScreenRecording() }
                completion?(self?.status(kind) ?? .notDetermined)
            }
        case .accessibility:
            // 带系统提示的询问（弹出系统对话框指引去设置；不实际授权）
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.refreshAll()
                completion?(self?.status(kind) ?? .notDetermined)
            }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshAll()
                    completion?(self?.status(kind) ?? .notDetermined)
                }
            }
        case .calendar:
            // 统一走旧版 requestAccess（全版本可用；macOS 14 的 requestFullAccess
            // 只是更细粒度，读权限两者等价，CalendarService 亦用此路径）
            eventStore.requestAccess(to: .event) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.refreshAll()
                    completion?(self?.status(kind) ?? .notDetermined)
                }
            }
        }
    }

    // MARK: - 跳转系统设置

    @discardableResult
    public func openSystemSettings(_ kind: PermissionKind) -> Bool {
        guard let url = kind.settingsURL else {
            Toast.show("无法打开系统设置", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        let ok = NSWorkspace.shared.open(url)
        if !ok {
            Toast.show("无法打开链接", icon: "exclamationmark.triangle", isWarning: true)
        }
        return ok
    }

    // MARK: - 汇总

    /// 核心权限是否全部就绪（启动自检/引导完成度用）
    public var allCoreGranted: Bool {
        PermissionKind.allCases.filter(\.isCore).allSatisfy { status($0).isGranted }
    }

    /// 已授权数量 / 总数（进度展示）
    public var grantedCount: Int {
        PermissionKind.allCases.filter { status($0).isGranted }.count
    }
}
