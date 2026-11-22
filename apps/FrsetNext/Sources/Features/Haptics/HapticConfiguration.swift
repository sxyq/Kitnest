import AppKit

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

    /// 强度阶梯（0 = off），给「失败事件不低于中」这类规则用。
    var level: Int {
        switch self {
        case .off: return 0
        case .light: return 1
        case .medium: return 2
        case .strong: return 3
        }
    }

    static func atLeast(_ minimum: HapticIntensity, _ value: HapticIntensity) -> HapticIntensity {
        value.level >= minimum.level ? value : minimum
    }
}

/// 用户配置。字段名与旧版一致，旧 JSON 直接可读。
struct HapticConfiguration {
    static let key = "haptic.configuration"
    /// 当前结构版本。2 = 「轻→中」迁移已执行过；3 = 拆出 Features/Haptics 后的结构（字段未变）。
    static let currentSchemaVersion = 3

    /// v270：总开关。旧配置没有这个键，解码时必须回落到 true，不能把用户已有设置判成关闭。
    var enabled = true
    /// v271：默认「中」。旧默认「轻」映射 alignment，触控板上几乎无感。
    var intensity: HapticIntensity = .medium
    var disabledEvents: Set<HapticEvent> = [
        .aiCompleted, .searchCompleted, .deviceConnected, .deviceDisconnected,
        .mediaPlayPause, .volumeBoundary
    ]
    /// 只在内存里用于迁移判断；写盘时总是写当前版本。
    private(set) var schemaVersion = HapticConfiguration.currentSchemaVersion

    init() {}

    func isEnabled(_ event: HapticEvent) -> Bool {
        enabled && intensity != .off && !disabledEvents.contains(event)
    }

    /// 迁移：只在 schemaVersion < 3 时补齐旧默认。
    /// 旧实现把这段写进 `init(from:)` 并顺手 `persist()`——读一次配置写一次盘，
    /// 还会在任意解码线程里改持久数据；现在解码保持纯函数，迁移由这里显式返回。
    func migrated() -> (configuration: HapticConfiguration, changed: Bool) {
        var next = self
        var changed = false
        if next.schemaVersion < 2, next.intensity == .light {
            next.intensity = .medium
            changed = true
        }
        if next.schemaVersion < Self.currentSchemaVersion {
            next.schemaVersion = Self.currentSchemaVersion
            changed = true
        }
        return (next, changed)
    }
}

extension HapticConfiguration: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, enabled, intensity, disabledEvents }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(disabledEvents, forKey: .disabledEvents)
    }

    /// 解码**无副作用**：不写盘、不改 UserDefaults。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intensity = try c.decodeIfPresent(HapticIntensity.self, forKey: .intensity) ?? .medium
        disabledEvents = try c.decodeIfPresent(Set<HapticEvent>.self, forKey: .disabledEvents)
            ?? Self().disabledEvents
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    }
}

extension HapticConfiguration: Equatable {
    /// 版本号不参与比较：迁移只补版本、不改用户设置，不能因此让设置页显示「有未保存修改」。
    static func == (lhs: HapticConfiguration, rhs: HapticConfiguration) -> Bool {
        lhs.enabled == rhs.enabled
            && lhs.intensity == rhs.intensity
            && lhs.disabledEvents == rhs.disabledEvents
    }
}

extension HapticConfiguration {
    /// 读盘 + 迁移（不落盘）。设置页草稿与 store 共用。
    static func load() -> HapticConfiguration {
        guard let data = UserDefaults.standard.data(forKey: key) else { return Self() }
        do {
            let decoded = try JSONDecoder().decode(Self.self, from: data)
            return decoded.migrated().configuration
        } catch {
            Log.warn("Haptics", "触觉配置读取失败：\(error.localizedDescription)")
            return Self()
        }
    }
}

/// 已保存配置的唯一读取口。
///
/// 旧实现每个触觉事件都 `UserDefaults.data` + `JSONDecoder.decode` 一次——网格拖拽时
/// 每帧一次 JSON 解码。这里在内存里留一份快照，只有保存设置时才替换；
/// 业务侧 `perform` 只做一次加锁读，不碰磁盘、不碰 JSON。
final class HapticSettingsStore {
    static let shared = HapticSettingsStore()

    private let lock = NSLock()
    private var snapshot: HapticConfiguration

    private init() {
        snapshot = HapticConfiguration.load()
    }

    var current: HapticConfiguration {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// 设置页保存后调用：写盘成功才替换内存快照。
    @discardableResult
    func save(_ configuration: HapticConfiguration) -> Error? {
        do {
            let data = try JSONEncoder().encode(configuration)
            UserDefaults.standard.set(data, forKey: HapticConfiguration.key)
        } catch {
            return error
        }
        lock.lock()
        snapshot = configuration
        lock.unlock()
        return nil
    }

    func reload() {
        let fresh = HapticConfiguration.load()
        lock.lock()
        snapshot = fresh
        lock.unlock()
    }
}
