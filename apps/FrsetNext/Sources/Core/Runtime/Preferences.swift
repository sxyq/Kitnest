import Foundation
import SwiftUI

/// 全局偏好（键名沿用原 App 命名风格，便于行为对照）
public final class Preferences: ObservableObject {
    public static let shared = Preferences()

    private let defaults: UserDefaults

    public init(suiteName: String? = nil) {
        self.defaults = suiteName.map { UserDefaults(suiteName: $0) ?? .standard } ?? .standard
    }

    // MARK: - 通用读写

    public func value<T>(_ key: String, default fallback: T) -> T {
        guard let v = defaults.object(forKey: key) as? T else { return fallback }
        return v
    }
    public func set(_ key: String, _ value: Any?) { defaults.set(value, forKey: key) }

    // MARK: - 强类型分组（各模块可在此扩展 computed property）

    public struct Keys {
        // 通用
        public static let launchAtLogin = "launchAtLogin"
        /// 深度释放时顺带暂停闲置应用（v259 第二档；默认开，内存卡上可临时关掉）
        public static let memoryFreezeIdle = "memory.freezeIdleOnRelease"
        /// 已看过的欢迎窗版本（onboardingVersion；空=没看过。见 WelcomeWindowController）
        public static let onboardingWelcomeSeenVersion = "onboarding.welcomeSeenVersion"
        public static let menuBarIconsVisible = "menuBar.iconsVisible"
        public static let panelWidth = "panel.width"
        public static let panelHeight = "panel.height"
        /// 置顶窗口（官方齿轮菜单勾选态，2026-10-18）
        public static let panelPinned = "panel.pinned"
        /// 主面板是否显示「文件中转」入口（v40 侧边栏，设置→常规→功能）
        public static let panelTransferDock = "panel.transferDock"
        /// 「设置 → 文件中转 → 启用文件中转」独占的功能总开关（v260）。
        ///
        /// 之前它和 `panel.transferDock`（常规→功能里的勾选）共用一个键，
        /// 两个 UI 互相覆盖，用户在任一处切换都会把另一处带偏——
        /// 关掉功能后连入口一起消失，而不是像文案承诺的那样「只提示已关闭」。
        public static let transferFeatureEnabled = "transfer.featureEnabled"
        /// 主面板宽度（v40 大侧边栏版式；旧版 panel.width=400 不复用）
        public static let panelWidthV2 = "panel.width.v2"
        /// v47 首页搜索分类开关（分类展现：网页 / 剪贴板历史 / 本地文件）
        public static let searchCategoryWeb = "search.category.web"
        public static let searchCategoryClipboard = "search.category.clipboard"
        public static let searchCategoryFiles = "search.category.files"
        // 剪贴板（05）
        public static let clipboardRetentionDays = "clipboard.retentionDays"
        public static let clipboardIgnoredApps = "clipboard.ignoredApps"
        public static let clipboardStorageLimitMB = "clipboard.storageLimitMB"
        public static let floatingOriginX = "floatingClipboard.originX"
        public static let floatingOriginY = "floatingClipboard.originY"
        public static let floatingWidth = "floatingClipboard.width"
        public static let floatingHeight = "floatingClipboard.height"
        // 监测（03）
        public static let monitorRefreshInterval = "monitor.refreshInterval"
        public static let monitorEnabledModules = "monitor.enabledModules"
        public static let monitorCombinedMode = "monitor.combinedMode"
        // 截图（06）
        public static let captureSound = "capture.soundEnabled"
        public static let captureSavePath = "capture.savePath"
        public static let ocrLanguages = "ocr.languages"
        // 图帘（v263 前叫「截图悬挂架」，对标 1Capture 的 DDShelf → 悬挂样式）。
        // 键名保留 `shelf.*`：改名不能把老用户已经调好的样式/宽度清零。
        /// 总开关：默认关。关着的时候不建窗口、不挂任何东西（用户要求「不是常驻的」）
        public static let curtainEnabled = "shelf.enabled"
        public static let curtainRopeStyle = "shelf.ropeStyle"
        /// 展示时长（秒）；0 = 永不自动收起
        public static let curtainDisplayDuration = "shelf.displayDuration"
        public static let curtainMaxCards = "shelf.maxCards"
        public static let curtainAttachOnCapture = "shelf.attachOnCapture"
        public static let curtainCardWidth = "shelf.cardWidth"
        /// 帘线是否跟随卡片等比放大（v263，默认开）
        public static let curtainRailScales = "shelf.railScales"
        // AI（09）
        public static let aiProvider = "ai.provider"
        public static let aiModel = "ai.model"
        public static let aiBaseURL = "ai.baseURL"
        // 工具箱（10）
        public static let toolboxEnabled = "toolbox.enabled"
        public static let calendarShowLunar = "calendar.showLunar"
        // 个性化（v66：设置 → 常规 →「个性化」，全档即改即生效）
        public static let uiAccentColor = "ui.accent.color"            // hex 字符串，空 = 跟随系统
        public static let uiFontScale = "ui.font.scale"                // 0.9 / 1.0 / 1.1 / 1.25
        public static let uiListDensity = "ui.list.density"            // compact / standard / relaxed
        public static let uiCornerRadius = "ui.corner.radius"          // 6 / 10 / 14
        public static let uiOpenAnimation = "ui.open.animation"        // snappy / standard / soft
        public static let uiPanelMaterial = "ui.panel.material"        // solid / vibrancy
        public static let uiSourceBadge = "ui.clipboard.sourceBadge"   // 来源应用徽章显隐
        public static let uiThumbSize = "ui.clipboard.thumb"           // 44 / 56 / 72
        public static let uiToastDuration = "ui.toast.duration"        // 2 / 3 / 5 秒
        public static let uiToastPosition = "ui.toast.position"        // followPanel / screenCenter
        public static let uiBarDividerColor = "ui.bar.divider.color"   // hex，空 = 默认
        // 玻璃质感五参数（v193：设置 → 个性化 → 玻璃质感）
        public static let uiGlassOpacity = "ui.glass.opacity"          // 0.55…1.0 通透度
        public static let uiGlassBlur = "ui.glass.blur"                // 0…1 磨砂强度
        public static let uiGlassCardLift = "ui.glass.cardLift"        // 0…1 卡片亮度台阶
        public static let uiGlassStroke = "ui.glass.stroke"            // 0…1 发丝边强度
        public static let uiBarDividerAlpha = "ui.bar.divider.alpha"   // 0..1
        public static let uiMidnightHue = "ui.midnight.hue"            // -30...30 色相偏移
        public static let uiBackgroundImage = "ui.background.image"    // 面板背景图路径
        public static let uiBackgroundDim = "ui.background.dim"        // 遮罩 0...0.8
    }

    // MARK: - 具体项（带默认值，直接读写 UserDefaults）

    public var launchAtLogin: Bool {
        get { value(Keys.launchAtLogin, default: false) }
        set { set(Keys.launchAtLogin, newValue) }
    }
    public var menuBarIconsVisible: Bool {
        get { value(Keys.menuBarIconsVisible, default: true) }
        set { set(Keys.menuBarIconsVisible, newValue) }
    }
    public var calendarShowLunar: Bool {
        get { value(Keys.calendarShowLunar, default: true) }
        set { set(Keys.calendarShowLunar, newValue) }
    }
}

/// 简单开关集合（各模块直接用 Preferences.shared 即可；此处提供 SwiftUI 便捷绑定）
public extension Preferences {
    func binding<T>(_ key: String, default fallback: T) -> Binding<T> {
        Binding(get: { self.value(key, default: fallback) },
                set: { self.set(key, $0) })
    }
}
