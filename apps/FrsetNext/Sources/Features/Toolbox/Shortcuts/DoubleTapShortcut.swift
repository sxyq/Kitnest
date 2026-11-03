import AppKit
import Foundation
import ApplicationServices
import Carbon.HIToolbox

// MARK: - 双击快捷键（对齐原版 DoubleTapShortcutDetector / AppKitDoubleTapMonitor）
//
// 2026-10-18 原版实机核验（设置 → 快捷键页 AX 树 + 点击行为）：
//   · 每个动作右侧有一个「2×」开关（原版类 DoubleTapInlineSwitch，按钮 30×16pt）；
//   · 打开后该动作从「组合键」切换为「双击修饰键」模式：
//       - 原组合键位置变成一个下拉菜单（AXMenuButton），菜单项为 ⌘ ⌘ / ⌥ ⌥ / ⌃ ⌃ / ⇧ ⇧，
//         即“双击哪个修饰键”，默认 ⌘ ⌘（原版截图与菜单实测一致）；
//       - 2× 开关变蓝（开启态）；
//   · 未授予辅助功能权限时，原版弹出兼容性卡片：
//     “当前未开启辅助功能权限。双击快捷键仍可尝试使用；如遇兼容性问题，请在系统设置中
//       开启辅助功能权限，以获得更稳定的体验。”（Localizable: Double-tap shortcut
//       compatibility warning）；
//   · 启用失败回退组合键时提示：“双击快捷键启用失败，已切回组合快捷键。”
//     （Localizable: Double-tap shortcut failed and reverted to combination shortcut.）
//
// 实现方式：NSEvent.flagsChanged 全局监听（原版同款 AppKitDoubleTapMonitor 技术栈，
// 字符串实证 AppKitDoubleTapEvent/AppKitDoubleTapMonitor）。辅助功能权限缺失时
// 全局监听收不到事件，与系统行为一致——原版也是“仍可尝试使用”。

// MARK: - 修饰键（原作 DoubleTapModifier）

public enum DoubleTapModifier: String, CaseIterable, Identifiable {
    case command
    case option
    case control
    case shift

    public var id: String { rawValue }

    /// 单个修饰键符号
    public var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option:  return "⌥"
        case .control: return "⌃"
        case .shift:   return "⇧"
        }
    }

    /// 设置页展示文本：原版下拉菜单项为「⌘ ⌘」这种双符号（按两次的含义）
    public var display: String { "\(symbol) \(symbol)" }

    /// NSEvent 修饰位
    public var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option:  return .option
        case .control: return .control
        case .shift:   return .shift
        }
    }

    /// Carbon 掩码（与 ShortcutManager 的展示/存储保持同一套语义）
    public var carbonMask: UInt32 {
        switch self {
        case .command: return UInt32(cmdKey)
        case .option:  return UInt32(optionKey)
        case .control: return UInt32(controlKey)
        case .shift:   return UInt32(shiftKey)
        }
    }
}

// MARK: - 检测中心

/// 双击修饰键的运行时分发中心。
/// 一个修饰键同时只绑定一个动作（原版 AX 菜单是单选语义）；重复绑定时按注册顺序取先者。
public final class DoubleTapShortcutCenter {
    public static let shared = DoubleTapShortcutCenter()

    /// 双击判定窗口（原作 doubleTapInterval；两次“按下沿”间隔）
    private static let interval: TimeInterval = 0.30

    private var handlers: [String: () -> Void] = [:]
    /// 绑定顺序（保证同一修饰键冲突时行为稳定）
    private var order: [String] = []
    /// actionID → 修饰键
    private(set) var bindings: [String: DoubleTapModifier] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var lastTapUptime: [DoubleTapModifier: TimeInterval] = [:]

    private init() {}

    // MARK: 注册

    /// 由 App 层注入 actionID → 行为（handler 只做懒分发）
    public func setHandlers(_ handlers: [String: () -> Void]) {
        self.handlers = handlers
    }

    /// 绑定某个动作的双击修饰键（幂等）
    public func bind(actionID: String, modifier: DoubleTapModifier) {
        bindings[actionID] = modifier
        if !order.contains(actionID) { order.append(actionID) }
        startMonitoringIfNeeded()
    }

    public func unbind(actionID: String) {
        bindings.removeValue(forKey: actionID)
        order.removeAll { $0 == actionID }
        if bindings.isEmpty { stopMonitoringIfNeeded() }
    }

    public func unbindAll() {
        bindings.removeAll()
        order.removeAll()
        stopMonitoringIfNeeded()
    }

    /// 当前动作的修饰键（nil = 组合键模式）
    public func modifier(for actionID: String) -> DoubleTapModifier? { bindings[actionID] }

    // MARK: 权限

    /// 辅助功能权限（全局 flagsChanged 监听需要；缺失时与系统原生行为一致地“仍可尝试”）
    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    // MARK: 监听

    private func startMonitoringIfNeeded() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(event.modifierFlags)
        }
        // 本 App 处于前台时 global monitor 收不到事件，补一个 local monitor
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(event.modifierFlags)
            return event
        }
        lastFlags = NSEvent.modifierFlags
        Log.info("DoubleTap", "双击快捷键监听已启动（辅助功能=\(Self.accessibilityTrusted ? "已授权" : "未授权（仍尝试）")）")
    }

    private func stopMonitoringIfNeeded() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        lastFlags = []
        lastTapUptime.removeAll()
        Log.info("DoubleTap", "双击快捷键监听已停止")
    }

    /// flagsChanged 解析：只看“从未按下 → 按下”的按下沿，同键两次按下落在 interval 内即触发。
    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.command, .option, .control, .shift])
        let previous = lastFlags.intersection([.command, .option, .control, .shift])

        for modifier in DoubleTapModifier.allCases {
            let isDown = relevant.contains(modifier.flag)
            let wasDown = previous.contains(modifier.flag)
            guard isDown, !wasDown else { continue }

            let now = ProcessInfo.processInfo.systemUptime
            if let previousTap = lastTapUptime[modifier], now - previousTap <= Self.interval {
                lastTapUptime[modifier] = nil
                fire(modifier)
            } else {
                lastTapUptime[modifier] = now
            }
        }
        lastFlags = flags
    }

    /// 分发：同一修饰键绑定了多个动作时，取注册顺序中的第一个
    private func fire(_ modifier: DoubleTapModifier) {
        guard let actionID = order.first(where: { bindings[$0] == modifier }),
              let handler = handlers[actionID] else { return }
        Log.info("DoubleTap", "双击 \(modifier.symbol) → \(actionID)")
        DispatchQueue.main.async { handler() }
    }
}
