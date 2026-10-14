import AppKit
import SwiftUI

// MARK: - 外观管理（specs/18 §5）
//
// 原作 AppearanceManager（classobj 0x100ace180）行为还原：
// - 四选一 radio：系统/浅色/深色/Midnight，defaults 键 `appearance`（默认 system，未改过不落盘）；
// - **Midnight 不是自定义 NSAppearance**——二进制仅引用系统 Aqua/DarkAqua/VibrantDark：
//   Midnight = 深色基底（DarkAqua）之上的 SwiftUI 主题覆盖层
//   （原作反射字段 midnightBaseBackgroundOverride / usesMidnightTextColor）；
// - system → NSApp.appearance = nil（跟随系统）；light/dark → 显式 Aqua/DarkAqua；
// - Pro 门控（midnight_appearance feature flag）不移植：Midnight 免费放开。

/// 外观模式（raw 值原作 ⬜ 未解出，按 specs/18 §5 推断拼写）
public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case midnight

    public var id: String { rawValue }

    /// 显示名（中文文案；后续接 L10n 键面）
    public var title: String {
        switch self {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "深色"
        case .midnight: return "Midnight"
        }
    }

    /// 图标
    public var systemImage: String {
        switch self {
        case .system: return "gearshape"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .midnight: return "moon.stars"
        }
    }
}

// MARK: Midnight 主题覆盖层（SwiftUI environment，对齐原作两反射字段）

private struct MidnightBaseBackgroundOverrideKey: EnvironmentKey {
    /// 默认无覆盖（nil = 用系统材质底色）
    static let defaultValue: Color? = nil
}

private struct UsesMidnightTextColorKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Midnight 基础背景色覆盖（原作反射字段 midnightBaseBackgroundOverride）
    var midnightBaseBackgroundOverride: Color? {
        get { self[MidnightBaseBackgroundOverrideKey.self] }
        set { self[MidnightBaseBackgroundOverrideKey.self] = newValue }
    }
    /// Midnight 文本用色开关（原作反射字段 usesMidnightTextColor）
    var usesMidnightTextColor: Bool {
        get { self[UsesMidnightTextColorKey.self] }
        set { self[UsesMidnightTextColorKey.self] = newValue }
    }
}

/// Midnight 色板（深色基底 + 冷黑蓝调；视觉近似原作 Midnight）
public enum MidnightTheme {
    /// 基础背景覆盖色
    public static let baseBackground = Color(red: 0.055, green: 0.067, blue: 0.105)
    /// 卡片背景（略提亮）
    public static let cardBackground = Color(red: 0.09, green: 0.10, blue: 0.15)
    /// 文本主色（冷白偏蓝）
    public static let textColor = Color(red: 0.88, green: 0.91, blue: 1.0)
}

// MARK: 管理器

public final class AppearanceManager: ObservableObject {
    public static let shared = AppearanceManager()

    /// defaults 键（原作键面："appearance"）
    private static let defaultsKey = "appearance"

    @Published public private(set) var mode: AppearanceMode

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = AppearanceMode(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .system
    }

    /// 切换外观并立即生效（亮/暗/系统走 NSAppearance 通道；Midnight = DarkAqua 基底 + 主题覆盖）
    public func apply(_ newMode: AppearanceMode) {
        mode = newMode
        if newMode == .system {
            defaults.removeObject(forKey: Self.defaultsKey)   // 原作：未改过设置键不落盘
        } else {
            defaults.set(newMode.rawValue, forKey: Self.defaultsKey)
        }
        applyNSAppearance()
        Log.info("Appearance", "外观已切换: \(newMode.rawValue)")
    }

    /// 应用启动时调用一次（App 层 start 接入点）
    public func applyCurrent() {
        applyNSAppearance()
    }

    /// NSAppearance 通道（仅系统 Aqua/DarkAqua，对齐原作 @0x10021a020 函数族）
    private func applyNSAppearance() {
        switch mode {
        case .system:
            NSApp.appearance = nil                       // 跟随系统
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark, .midnight:
            // Midnight：深色基底（主题覆盖层由视图层经 environment 取 Midnight 色板）
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 当前是否为 Midnight 主题（视图层据此注入 environment 覆盖）
    public var isMidnight: Bool { mode == .midnight }
}

// MARK: - 视图便捷修饰

public extension View {
    /// Midnight 主题覆盖注入（设置窗/主面板根视图挂一次即可）
    func frsetAppearanceTheme(_ manager: AppearanceManager = .shared) -> some View {
        modifier(AppearanceThemeModifier(manager: manager))
    }
}

/// 根视图注入器：Midnight 时注入背景覆盖与文本用色开关（对齐原作两反射字段语义）
struct AppearanceThemeModifier: ViewModifier {
    @ObservedObject var manager: AppearanceManager

    func body(content: Content) -> some View {
        content
            .environment(\.midnightBaseBackgroundOverride, manager.isMidnight ? MidnightTheme.baseBackground : nil)
            .environment(\.usesMidnightTextColor, manager.isMidnight)
    }
}
