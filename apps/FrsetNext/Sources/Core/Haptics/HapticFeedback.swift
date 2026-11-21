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
        case .medium: return "档位变化（levelChange）"
        case .strong: return "通用（generic）"
        }
    }

    /// v271：按真实感知强度映射。macOS 三种模式的实际触感排序是
    /// alignment（极轻）< levelChange（中）< generic（明显），
    /// 旧版把 medium/strong 接反了，且默认「轻」= alignment 在触控板上几乎无感
    /// （用户原话：「我对这部分进行测试呀，但是我没有感受到」）。
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
    /// 真实业务完成点调用。总开关关闭、场景关闭、强度为「关闭」时都不发请求。
    static func perform(_ event: HapticEvent) {
        let configuration = HapticConfiguration.load()
        guard configuration.enabled, configuration.intensity != .off,
              configuration.isEnabled(event) else { return }
        emit(configuration.intensity, event: event.debugName)
    }

    /// 设置页「模拟所选场景」：用草稿强度发同样的系统模式。
    ///
    /// 系统 API 是 void——它不能证明业务动作成功，硬件是否振动也无法程序化
    /// 确认。UI 文案按「模拟触觉模式」表述。
    /// v272（用户：「是一点感觉没有的，你现在好像没有正确的触发」）：
    /// NSHapticFeedbackManager 只在 App 处于前台激活时真正产生触感，
    /// 后台请求被系统静默丢弃——而 Kitnest 大量交互发生在不激活 App 的
    /// 浮动面板上，这正是「日志有请求、手上没感觉」的最可能根因。
    /// 模拟按钮是用户主动点击的验证动作：先显式激活 App，再连发 3 次
    /// （间隔 0.18s）——单次可能被吞，三连发只要硬件支持一定感觉得到。
    static func simulate(event: HapticEvent, intensity: HapticIntensity) {
        guard intensity != .off else { return }
        DispatchQueue.main.async {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(i)) {
                    emit(intensity, event: "simulate:\(event.debugName)#\(i + 1)")
                }
            }
        }
    }

    /// v272：启动探针——`defaults write com.sxyq.frsetnext probe.haptic -bool true`
    /// 后重启 App，激活 2.5s 后自动模拟一次。用于无鼠标环境验证触觉链路
    /// （项目探针惯例，probe.* 键用完删）。
    static func fireProbeIfRequested() {
        guard UserDefaults.standard.bool(forKey: "probe.haptic") else { return }
        Log.info("Haptics", "探针：检测到 probe.haptic，2.5s 后模拟（先激活 App）")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            simulate(event: .gridMove, intensity: HapticConfiguration.load().intensity)
        }
    }

    private static func emit(_ intensity: HapticIntensity, event: String) {
        guard let pattern = intensity.pattern else { return }
        // 诊断：请求时的激活状态。前台要求不满足时系统静默丢请求，
        // 这一行就是「日志有、感觉无」的直接证据。
        let state = NSApp.isActive ? "active" : "inactive"
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        Log.info("Haptics", "请求触觉 pattern=\(patternName(pattern)) event=\(event) app=\(state) front=\(front)")
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
