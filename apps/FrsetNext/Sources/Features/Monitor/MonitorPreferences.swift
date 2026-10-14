import Foundation

// MARK: - 监测偏好（键名沿用原作 monitor.* 风格，全部经 Preferences 持久化）

public enum MonitorModuleID: String, CaseIterable, Sendable {
    case cpu
    case memory
    case network
    case disk
    case sensors
    case battery

    /// 显示名（设置页签 / 详情标题）
    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .disk: return "磁盘"
        case .sensors: return "温度"
        case .battery: return "电池"
        }
    }

    /// 状态栏图标
    public var systemImage: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        case .sensors: return "thermometer"
        case .battery: return "battery.100"
        }
    }

    /// 默认是否启用（对齐规划 v2：GPU/电池类默认关，这里电池默认关）
    public var enabledByDefault: Bool {
        switch self {
        case .cpu, .memory, .network, .disk, .sensors: return true
        case .battery: return false
        }
    }
}

public enum MonitorPreferences {
    /// 偏好变更后发出的通知（状态栏模块可据此重建状态项）
    public static let didChangeNotification = Notification.Name("MonitorPreferencesDidChange")

    // 键名（在原 Keys 基础上扩展，避免修改 Core/Preferences.swift）
    public static let keyEnabled = "monitor.enabled"
    public static let keyRefreshInterval = "monitor.refreshInterval"
    public static let keyCombinedMode = "monitor.combinedMode"
    public static let keyShowTemperatures = "monitor.showTemperatures"

    // 兼容 Core/Preferences.Keys 里已定义的键
    private static let legacyEnabledModules = Preferences.Keys.monitorEnabledModules
    private static let legacyCombinedMode = Preferences.Keys.monitorCombinedMode
    private static let legacyRefreshInterval = Preferences.Keys.monitorRefreshInterval

    public static func keyEnabled(for module: MonitorModuleID) -> String {
        "monitor.\(module.rawValue).enabled"
    }

    /// 总开关
    public static var isEnabled: Bool {
        get { Preferences.shared.value(keyEnabled, default: true) }
        set { Preferences.shared.set(keyEnabled, newValue); notify() }
    }

    /// 采样间隔（秒），范围 0.5...10
    public static var refreshInterval: Double {
        get {
            let raw = Preferences.shared.value(legacyRefreshInterval, default: 2.0)
            return min(10, max(0.5, raw))
        }
        set {
            Preferences.shared.set(legacyRefreshInterval, min(10, max(0.5, newValue)))
            notify()
        }
    }

    /// 合并模式：状态栏只显示一个总览项
    public static var combinedMode: Bool {
        get { Preferences.shared.value(legacyCombinedMode, default: false) }
        set { Preferences.shared.set(legacyCombinedMode, newValue); notify() }
    }

    /// 是否采集温度（关闭后完全跳过 SMC 读取）
    public static var showTemperatures: Bool {
        get { Preferences.shared.value(keyShowTemperatures, default: true) }
        set { Preferences.shared.set(keyShowTemperatures, newValue); notify() }
    }

    /// 单模块开关
    public static func isModuleEnabled(_ module: MonitorModuleID) -> Bool {
        Preferences.shared.value(keyEnabled(for: module), default: module.enabledByDefault)
    }

    public static func setModuleEnabled(_ module: MonitorModuleID, _ enabled: Bool) {
        Preferences.shared.set(keyEnabled(for: module), enabled)
        notify()
    }

    /// 当前应显示的状态栏项 id 列表（供状态栏模块过滤 StatusItemRegistry.all）
    public static func visibleStatusItemIDs() -> Set<String> {
        guard isEnabled else { return [] }
        if combinedMode { return ["monitor.combined"] }
        var ids: Set<String> = ["monitor.combined"]
        for module in MonitorModuleID.allCases where isModuleEnabled(module) {
            ids.insert("monitor.\(module.rawValue)")
        }
        return ids
    }

    /// 恢复默认设置
    public static func resetToDefaults() {
        Preferences.shared.set(keyEnabled, true)
        Preferences.shared.set(legacyRefreshInterval, 2.0)
        Preferences.shared.set(legacyCombinedMode, false)
        Preferences.shared.set(keyShowTemperatures, true)
        for module in MonitorModuleID.allCases {
            Preferences.shared.set(keyEnabled(for: module), module.enabledByDefault)
        }
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
