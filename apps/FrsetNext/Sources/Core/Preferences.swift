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
        public static let menuBarIconsVisible = "menuBar.iconsVisible"
        public static let panelWidth = "panel.width"
        public static let panelHeight = "panel.height"
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
        // AI（09）
        public static let aiProvider = "ai.provider"
        public static let aiModel = "ai.model"
        public static let aiBaseURL = "ai.baseURL"
        // 工具箱（10）
        public static let toolboxEnabled = "toolbox.enabled"
        public static let calendarShowLunar = "calendar.showLunar"
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
