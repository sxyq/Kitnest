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
//
// 分层（契约 §1.3 依赖方向）：
//   本文件（业务模块 Settings）→ Core/AppearanceTheme.swift（共享层）单向依赖。
//   AppearanceMode / MidnightTheme / 四个 EnvironmentKey / AppearanceState /
//   frsetAppearanceTheme() 均已下沉至共享层，故主面板与悬浮剪贴板可在
//   per-module 编译子集里取到它们；反向依赖（共享层持有本文件的类型）不存在。
//   本文件只保留 NSAppearance 应用 + defaults 读写，并单向同步 AppearanceState。

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
        AppearanceState.shared.isMidnight = isMidnight        // 同步给共享层的视图注入器
        Log.info("Appearance", "外观已切换: \(newMode.rawValue)")
    }

    /// 应用启动时调用一次（App 层 start 接入点）
    public func applyCurrent() {
        applyNSAppearance()
        AppearanceState.shared.isMidnight = isMidnight        // 同步给共享层的视图注入器
    }

    /// NSAppearance 通道（仅系统 Aqua/DarkAqua，对齐原作 @0x10021a020 函数族）
    private func applyNSAppearance() {
        switch mode {
        case .system:
            NSApp.appearance = nil                       // 跟随系统
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark, .midnight:
            // Midnight：深色基底（主题覆盖层由 Core 的注入器经 environment 注入色板）
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 当前是否为 Midnight 主题（转发到共享层 AppearanceState，现有调用点不变）
    public var isMidnight: Bool { mode == .midnight }
}
