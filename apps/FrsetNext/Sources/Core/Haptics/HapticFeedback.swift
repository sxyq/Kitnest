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

    /// 直连马达的波形编号：3 轻、4 中、6 重（HapticKey 同款）。
    /// 公开接口的 pattern 只在手指贴着触控板时有效，直连不受此限制。
    var actuationID: Int32? {
        switch self {
        case .off: return nil
        case .light: return 3
        case .medium: return 4
        case .strong: return 6
        }
    }

    /// 公开接口回落用。直连不可用时才会走到这里。
    var pattern: NSHapticFeedbackManager.FeedbackPattern? {
        switch self {
        case .off: return nil
        case .light: return .alignment
        case .medium: return .levelChange
        case .strong: return .generic
        }
    }
}

struct HapticConfiguration: Codable, Equatable {
    static let key = "haptic.configuration"
    /// v270：总开关。旧配置没有这个键，解码时必须回落到 true，不能把用户已有设置判成关闭。
    var enabled = true
    /// v271：默认「中」。旧默认「轻」映射 alignment，触控板上几乎无感。
    var intensity: HapticIntensity = .medium
    var disabledEvents: Set<HapticEvent> = [
        .aiCompleted, .searchCompleted, .deviceConnected, .deviceDisconnected,
        .mediaPlayPause, .volumeBoundary
    ]

    init() {}

    /// v271：配置结构版本。0 = 旧 JSON（无版本键）。
    private enum CodingKeys: String, CodingKey { case schemaVersion, enabled, intensity, disabledEvents }

    /// CodingKeys 里的 schemaVersion 没有对应存储属性，Encodable 无法合成，手写编码。
    /// 写 schemaVersion=2：表示本条配置已经走过「轻→中」迁移，下次结构变更从它起算。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(disabledEvents, forKey: .disabledEvents)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intensity = try c.decodeIfPresent(HapticIntensity.self, forKey: .intensity) ?? .medium
        disabledEvents = try c.decodeIfPresent(Set<HapticEvent>.self, forKey: .disabledEvents)
            ?? Self().disabledEvents
        // 一次性迁移：旧默认「轻」= alignment 无感，抬到「中」（levelChange）。
        // 与预览字号迁移同一策略——版本号保证只跑一次，用户此后手动调档不再被改。
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        if version < 2, intensity == .light {
            intensity = .medium
            try? persist()
            Log.info("Haptics", "v271 迁移：默认强度 轻→中（alignment 无感）")
        }
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
    /// 连续拖拽会让网格吸附每帧都请求一次，加一道最小间隔，避免连成机关枪。
    private static var lastPerformAt: TimeInterval = 0
    private static let minimumInterval: TimeInterval = 0.06

    /// 真实业务完成点调用。总开关关闭、场景关闭、强度为「关闭」时都不发。
    static func perform(_ event: HapticEvent) {
        let configuration = HapticConfiguration.load()
        guard configuration.enabled, configuration.intensity != .off,
              configuration.isEnabled(event) else { return }
        let intensity = configuration.intensity
        DispatchQueue.main.async {
            let now = Date.timeIntervalSinceReferenceDate
            guard now - lastPerformAt >= minimumInterval else { return }
            lastPerformAt = now
            emit(intensity, event: event.debugName)
        }
    }

    /// 设置页里点开关、换强度时立刻敲一下，用户不用去猜有没有生效。
    static func preview(_ intensity: HapticIntensity) {
        guard intensity != .off else { return }
        emit(intensity, event: "preview")
    }

    /// 设置页「试听」：按草稿强度敲一次，不改任何业务状态。
    static func simulate(event: HapticEvent, intensity: HapticIntensity) {
        guard intensity != .off else { return }
        emit(intensity, event: "simulate:\(event.debugName)")
    }

    /// 启动探针——`defaults write com.sxyq.frsetnext probe.haptic -bool true`
    /// 后重启，2.5s 后按真实业务路径敲一次（走配置、走节流）；用完删键。
    static func fireProbeIfRequested() {
        guard UserDefaults.standard.bool(forKey: "probe.haptic") else { return }
        Log.info("Haptics", "探针：检测到 probe.haptic，2.5s 后按真实事件触发")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            perform(.gridMove)
        }
    }

    private static func emit(_ intensity: HapticIntensity, event: String) {
        guard let actuation = intensity.actuationID else { return }
        let fire = {
            // 先走私有马达：脱离触摸也能响，后台窗口同样有效。
            // 失败（无内建触控板 / 系统改动）再回落公开接口，至少前台还有救。
            let direct = TrackpadActuator.shared.actuate(id: actuation)
            Log.info("Haptics", "触觉 \(event) 强度=\(intensity.rawValue) 波形=\(actuation) 直连=\(direct ? "ok" : "fallback")")
            if !direct, let pattern = intensity.pattern {
                NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
            }
        }
        if Thread.isMainThread { fire() } else { DispatchQueue.main.async(execute: fire) }
    }
}
