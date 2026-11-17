import AppKit

enum HapticEvent: String, Codable, CaseIterable, Sendable {
    case gridMove, gridResize, layoutSaved, copy, screenshot, ocr
    case recordingStarted, recordingSaved, transferCompleted, downloadCompleted, transferFailed
    case aiCompleted, searchCompleted, deviceConnected, deviceDisconnected, operationFailed
    case mediaPlayPause, volumeBoundary
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
    var intensity: HapticIntensity = .light
    var disabledEvents: Set<HapticEvent> = [
        .aiCompleted, .searchCompleted, .deviceConnected, .deviceDisconnected,
        .mediaPlayPause, .volumeBoundary
    ]

    func isEnabled(_ event: HapticEvent) -> Bool { !disabledEvents.contains(event) }

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
    static func perform(_ event: HapticEvent) {
        let configuration = HapticConfiguration.load()
        guard configuration.isEnabled(event) else { return }
        preview(configuration.intensity)
    }

    /// 试听使用草稿强度；系统只接受离散模式，每次请求一次反馈。
    static func preview(_ intensity: HapticIntensity) {
        guard let pattern = intensity.pattern else { return }
        DispatchQueue.main.async {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }
}
