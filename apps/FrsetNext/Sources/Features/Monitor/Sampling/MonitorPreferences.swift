import Foundation

// MARK: - 监测偏好（键名沿用原作 monitor.* 风格，全部经 Preferences 持久化）

public enum MonitorModuleID: String, CaseIterable, Sendable {
    case power
    case battery
    case cpu
    case memory
    case network
    case disk
    case sensors
    case gpu

    /// 显示名（设置页签 / 详情标题）
    public var displayName: String {
        switch self {
        case .power: return "功耗"
        case .battery: return "电池"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .disk: return "磁盘"
        case .sensors: return "温度"
        case .gpu: return "GPU"
        }
    }

    /// 状态栏图标
    public var systemImage: String {
        switch self {
        case .power: return "bolt.fill"
        case .battery: return "battery.100"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        case .sensors: return "thermometer"
        case .gpu: return "cube.transparent"
        }
    }

    /// 模块默认是否启用（控制**监测面板 / 中心卡片**的可见性）。
    ///
    /// v42 澄清：这与「菜单栏原生图标」是两件事——菜单栏我们不摆官方那 4 个独立项了
    /// （已有更好的 STATS 合并条），但面板卡片仍需按模块显示，故默认值保持原样。
    public var enabledByDefault: Bool {
        switch self {
        case .memory, .network, .disk: return true
        // v190：充电页已并入电池页；电源流向图只剩「功耗」页一处，
        // 所以功耗改为默认显示（原来它关着是因为充电页替它展示了流向图）。
        // 台式机没有电池，电池页会被 availableModules 过滤掉。
        case .battery, .power: return true
        case .cpu, .sensors, .gpu: return false
        }
    }
}

public enum MonitorPreferences {
    /// 偏好变更后发出的通知（状态栏模块可据此重建状态项）
    public static let didChangeNotification = Notification.Name("MonitorPreferencesDidChange")

    // 键名（在原 Keys 基础上扩展，避免修改 Core/Runtime/Preferences.swift）
    public static let keyEnabled = "monitor.enabled"
    public static let keyRefreshInterval = "monitor.refreshInterval"
    public static let keyCombinedMode = "monitor.combinedMode"
    public static let keyShowTemperatures = "monitor.showTemperatures"
    /// 网络页「流量去哪了」显示多少个 App（3…8，默认 4）
    public static let keyFlowTopN = "monitor.flow.topN"
    /// 网络统计常驻（v191，默认开）
    public static let keyNetworkKeepAlive = "monitor.net.keepAlive"

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

    /// 网络分流显示条数（含「其他」之前的分支数）
    public static var flowTopN: Int {
        get {
            let raw = Preferences.shared.value(keyFlowTopN, default: 4)
            return min(8, max(3, raw))
        }
        set {
            Preferences.shared.set(keyFlowTopN, min(8, max(3, newValue)))
            notify()
        }
    }

    /// 网络统计常驻（v191）
    ///
    /// 用户原话（2026-11-03）：「这个每次打开它都会隔一会才跳得出来。不对，应该是就跟
    /// 其他的组件一样，就一直放在那，只是它会变化它的一个显示的 APP」
    ///
    /// 旧实现把 nettop 采样绑在「监测页可见」上（v128 的 CPU 优化）：页面一关就停，
    /// 所以每次都从 0 开始累计，打开后要等 5s 采样 + 几分钟窗口才有像样的数字。
    /// 现在改为默认常驻：后台每 5s 读一轮 nettop 缓存并积分进 10 分钟窗口，
    /// 打开页面立刻就是「过去 10 分钟」的现成结果，只是上榜的 App 会随流量变化。
    ///
    /// 代价：常驻每 5s 一个 nettop 子进程（实测单轮约 1s、CPU < 0.5%）。
    /// 需要极致省电时可关掉（回到旧的"打开才采"行为）。
    public static var networkKeepAlive: Bool {
        get { Preferences.shared.value(keyNetworkKeepAlive, default: true) }
        set { Preferences.shared.set(keyNetworkKeepAlive, newValue); notify() }
    }

    /// 单模块开关
    public static func isModuleEnabled(_ module: MonitorModuleID) -> Bool {
        Preferences.shared.value(keyEnabled(for: module), default: module.enabledByDefault)
    }

    public static func setModuleEnabled(_ module: MonitorModuleID, _ enabled: Bool) {
        Preferences.shared.set(keyEnabled(for: module), enabled)
        notify()
    }

    // v210：`visibleStatusItemIDs()` 随 Swift 动态状态项一并删除（注册表已不存在）。

    /// 恢复默认设置
    public static func resetToDefaults() {
        Preferences.shared.set(keyEnabled, true)
        Preferences.shared.set(legacyRefreshInterval, 2.0)
        Preferences.shared.set(legacyCombinedMode, false)
        Preferences.shared.set(keyShowTemperatures, true)
        Preferences.shared.set(keyFlowTopN, 4)
        for module in MonitorModuleID.allCases {
            Preferences.shared.set(keyEnabled(for: module), module.enabledByDefault)
        }
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
