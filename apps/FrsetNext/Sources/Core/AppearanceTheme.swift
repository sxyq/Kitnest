import Foundation
import SwiftUI

// MARK: - 外观模式与 Midnight 主题基础设施（共享层）
//
// 原作 AppearanceManager（classobj 0x100ace180）行为还原的**视图侧**部分。
// 二进制仅引用系统 Aqua/DarkAqua/VibrantDark：**Midnight 不是自定义 NSAppearance**，
// 而是深色基底（DarkAqua）之上的 SwiftUI 主题覆盖层
// （原作反射字段 midnightBaseBackgroundOverride / usesMidnightTextColor）。
//
// 归属说明（契约 §1.3 依赖方向）：
// 本文件只依赖 Foundation/SwiftUI，**不引用任何 Features/* 类型**。
// NSAppearance 应用与 defaults 读写留在 Features/Settings/AppearanceManager.swift，
// 它单向依赖本文件的 `AppearanceState` 并负责同步；方向是「业务模块 → 共享层」，
// 绝不反向（共享层不得持有业务模块类型）。

// MARK: 外观模式

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

// MARK: Midnight 色板

/// Midnight 色板（深色基底 + 冷黑蓝调；视觉近似原作 Midnight）
public enum MidnightTheme {
    /// 基础背景覆盖色
    public static let baseBackground = Color(red: 0.055, green: 0.067, blue: 0.105)
    /// 卡片背景（略提亮）
    public static let cardBackground = Color(red: 0.09, green: 0.10, blue: 0.15)
    /// 文本主色（冷白偏蓝）
    public static let textColor = Color(red: 0.88, green: 0.91, blue: 1.0)
}

// MARK: 主题状态（视图侧唯一数据源）

/// 外观主题状态：视图层据此注入 Midnight 覆盖。
/// 由 Features/Settings 的 AppearanceManager 在 apply/applyCurrent 时写入，
/// 本类不感知 NSAppearance 与 UserDefaults，故共享层无业务模块依赖。
public final class AppearanceState: ObservableObject {
    public static let shared = AppearanceState()

    /// 当前是否启用 Midnight 主题覆盖
    @Published public var isMidnight: Bool = false

    public init() {}
}

// MARK: Environment 键（公开，跨模块可见）

private struct MidnightBaseBackgroundOverrideKey: EnvironmentKey {
    /// 默认无覆盖（nil = 用系统材质底色）
    static let defaultValue: Color? = nil
}

private struct UsesMidnightTextColorKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MidnightCardBackgroundOverrideKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private struct MidnightTextColorOverrideKey: EnvironmentKey {
    static let defaultValue: Color? = nil
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
    /// Midnight 卡片底色覆盖（nil = 用 Theme.cardBackground）
    var midnightCardBackgroundOverride: Color? {
        get { self[MidnightCardBackgroundOverrideKey.self] }
        set { self[MidnightCardBackgroundOverrideKey.self] = newValue }
    }
    /// Midnight 正文色覆盖（nil = 用系统 primary；实际启用与否以 usesMidnightTextColor 为准）
    var midnightTextColorOverride: Color? {
        get { self[MidnightTextColorOverrideKey.self] }
        set { self[MidnightTextColorOverrideKey.self] = newValue }
    }
}

// MARK: - 视图注入器

/// 根视图注入器：Midnight 时注入背景覆盖与文本用色开关（对齐原作两反射字段语义）
public struct AppearanceThemeModifier: ViewModifier {
    @ObservedObject var state: AppearanceState

    public init(state: AppearanceState = .shared) {
        self.state = state
    }

    public func body(content: Content) -> some View {
        let midnight = state.isMidnight
        return content
            .environment(\.midnightBaseBackgroundOverride, midnight ? MidnightTheme.baseBackground : nil)
            .environment(\.usesMidnightTextColor, midnight)
            // 卡片/正文色一并注入：各模块根视图只读 environment，不直接引用 MidnightTheme
            .environment(\.midnightCardBackgroundOverride, midnight ? MidnightTheme.cardBackground : nil)
            .environment(\.midnightTextColorOverride, midnight ? MidnightTheme.textColor : nil)
    }
}

public extension View {
    /// Midnight 主题覆盖注入（设置窗/主面板/悬浮剪贴板三个根视图各挂一次）
    ///
    /// 消费点（契约 §10.4：基建注入器零挂载 ≡ 未实现）：
    /// - Features/Panel/PanelRootView.swift
    /// - Features/Settings/SettingsRootView.swift
    /// - Features/Clipboard/FloatingClipboardWindow.swift
    func frsetAppearanceTheme(_ state: AppearanceState = .shared) -> some View {
        modifier(AppearanceThemeModifier(state: state))
    }
}
