import AppKit

enum HapticEvent: String, Codable, CaseIterable, Sendable {
    case gridMove, gridResize, layoutSaved, copy, screenshot, ocr
    case recordingStarted, recordingSaved, transferCompleted, downloadCompleted, transferFailed
    case aiCompleted, searchCompleted, deviceConnected, deviceDisconnected, operationFailed
    case mediaPlayPause, volumeBoundary
}

extension HapticEvent {
    /// 日志与设置页用：不参与持久化，改名不影响旧配置。
    var debugName: String { settingTitle }
    var settingTitle: String {
        switch self {
        case .gridMove: return "网格吸附"
        case .gridResize: return "组件尺寸切档"
        case .layoutSaved: return "布局保存成功"
        case .copy: return "主动复制成功"
        case .screenshot: return "截图完成"
        case .ocr: return "文字识别完成"
        case .recordingStarted: return "录制开始"
        case .recordingSaved: return "录制保存完成"
        case .transferCompleted: return "文件发送完成"
        case .downloadCompleted: return "下载完成"
        case .transferFailed: return "发送/下载失败"
        case .aiCompleted: return "AI 输出完成"
        case .searchCompleted: return "搜索完成"
        case .deviceConnected: return "设备接入"
        case .deviceDisconnected: return "设备断开"
        case .operationFailed: return "操作失败"
        case .mediaPlayPause: return "播放/暂停"
        case .volumeBoundary: return "音量到边界"
        }
    }
}

enum HapticIntensity: String, Codable, CaseIterable, Sendable {
    case off, light, medium, strong

    var title: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻"
        case .medium: return "中"
        case .strong: return "强"
        }
    }

    var systemMode: String {
        switch self {
        case .off: return "关闭"
        case .light: return "对齐（alignment）"
        case .medium: return "通用（generic）"
        case .strong: return "档位变化（levelChange）"
        }
    }

    var pattern: NSHapticFeedbackManager.FeedbackPattern? {
        switch self {
        case .off: return nil
        case .light: return .alignment
        case .medium: return .generic
        case .strong: return .levelChange
        }
    }
}

struct HapticConfiguration: Codable, Equatable {
    static let key = "haptic.configuration"
    /// v270：总开关。旧配置没有这个键，解码时必须回落到 true，不能把用户已有设置判成关闭。
    var enabled = true
    var intensity: HapticIntensity = .light
    var disabledEvents: Set<HapticEvent> = [
        .aiCompleted, .searchCompleted, .deviceConnected, .deviceDisconnected,
        .mediaPlayPause, .volumeBoundary
    ]

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, intensity, disabledEvents }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intensity = try c.decodeIfPresent(HapticIntensity.self, forKey: .intensity) ?? .light
        disabledEvents = try c.decodeIfPresent(Set<HapticEvent>.self, forKey: .disabledEvents)
            ?? Self().disabledEvents
    }

    func isEnabled(_ event: HapticEvent) -> Bool { enabled && !disabledEvents.contains(event) }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key) else { return Self() }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch {
            Log.warn("Haptics", "触觉配置读取失败：\(error.localizedDescription)")
            return Self()
        }
    }

    func persist() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}

enum HapticFeedback {
    /// 真实业务完成点调用。总开关关闭、场景关闭、强度为「关闭」时都不发请求。
    static func perform(_ event: HapticEvent) {
        let configuration = HapticConfiguration.load()
        guard configuration.enabled, configuration.intensity != .off,
              configuration.isEnabled(event) else { return }
        emit(configuration.intensity, event: event.debugName)
    }

    /// 设置页「模拟所选场景」：用草稿强度发一次同样的系统模式。
    ///
    /// 这不是业务验证——系统 API 是 void，既不能证明业务动作成功，也不能证明
    /// 用户真的感觉到了振动。UI 文案必须按「模拟触觉模式」表述。
    static func simulate(event: HapticEvent, intensity: HapticIntensity) {
        guard intensity != .off else { return }
        emit(intensity, event: "simulate:\(event.debugName)")
    }

    private static func emit(_ intensity: HapticIntensity, event: String) {
        guard let pattern = intensity.pattern else { return }
        Log.info("Haptics", "请求触觉 pattern=\(patternName(pattern)) event=\(event)")
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }

    private static func patternName(_ pattern: NSHapticFeedbackManager.FeedbackPattern) -> String {
        switch pattern {
        case .alignment: return "alignment"
        case .generic: return "generic"
        case .levelChange: return "levelChange"
        default: return "other"
        }
    }
}
