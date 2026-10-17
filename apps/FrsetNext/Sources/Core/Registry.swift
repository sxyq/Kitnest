import Foundation
import SwiftUI

// MARK: - 跨模块解耦基础设施
// 规则：功能模块之间**禁止直接引用彼此的具体类型**，一律通过本文件的注册表 / ServiceLocator 交互。
// 这样各模块可独立编译（typecheck 只带 Core/Models/Storage + 自身目录），并行开发不阻塞。

// MARK: 主面板区段（04 号模块消费；其余模块注册）

public struct PanelSectionDescriptor {
    public let id: String
    public let title: String
    public let priority: Int          // 越小越靠前
    public let build: () -> AnyView
    public init(id: String, title: String, priority: Int, build: @escaping () -> AnyView) {
        self.id = id; self.title = title; self.priority = priority; self.build = build
    }
}

public enum PanelSectionRegistry {
    private static var lock = NSLock()
    private static var items: [PanelSectionDescriptor] = []
    public static func register(_ d: PanelSectionDescriptor) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.id == d.id }
        items.append(d)
        items.sort { $0.priority < $1.priority }
    }
    public static var all: [PanelSectionDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

// MARK: 设置窗口页签（07 号模块消费；其余模块注册）

public struct SettingsPaneDescriptor {
    public let id: String
    public let title: String
    public let systemImage: String
    public let build: () -> AnyView
    public init(id: String, title: String, systemImage: String, build: @escaping () -> AnyView) {
        self.id = id; self.title = title; self.systemImage = systemImage; self.build = build
    }
}

public enum SettingsPaneRegistry {
    private static var lock = NSLock()
    private static var items: [SettingsPaneDescriptor] = []
    public static func register(_ d: SettingsPaneDescriptor) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.id == d.id }
        items.append(d)
    }
    /// 默认排序（与原作设置窗口页签序一致：通用/监测/剪贴板/截图/搜索/AI/工具/快捷键/关于；
    /// "search" 为规格 07 预留位——原作有搜索设置页但内容未测绘，暂无模块注册）
    private static let order = ["general", "monitor", "clipboard", "capture", "search", "ai", "tools", "shortcuts", "statistics", "about"]
    public static var all: [SettingsPaneDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return items.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }
}

// MARK: 状态栏项（08 号模块消费；监测等模块注册）

public struct StatusItemDescriptor {
    public let id: String
    public let priority: Int
    /// 返回要显示的标题（短文本，如 "12%"、"↑25 KB/s"）
    public let title: () -> String
    /// 可选富文本（带颜色/图标）
    public let attributedTitle: (() -> NSAttributedString)?
    /// 可选双层标题（状态栏两行紧凑渲染：第一行/第二行）；非 nil 且返回非 nil 时优先于 title，
    /// 由 StatusBarController 用自绘子视图呈现（省横向空间，2026-10-16）
    public let twoLineTitle: (() -> (String, String)?)?
    /// 点击行为
    public let onTap: (() -> Void)?
    /// 点击后弹出的 popover 内容（监测模块详情面板）
    public let popover: (() -> AnyView)?
    public init(id: String,
                priority: Int,
                title: @escaping () -> String,
                attributedTitle: (() -> NSAttributedString)? = nil,
                twoLineTitle: (() -> (String, String)?)? = nil,
                onTap: (() -> Void)? = nil,
                popover: (() -> AnyView)? = nil) {
        self.id = id; self.priority = priority; self.title = title
        self.attributedTitle = attributedTitle; self.twoLineTitle = twoLineTitle
        self.onTap = onTap; self.popover = popover
    }
}

public enum StatusItemRegistry {
    private static var lock = NSLock()
    private static var items: [StatusItemDescriptor] = []
    public static func register(_ d: StatusItemDescriptor) {
        lock.lock(); defer { lock.unlock() }
        items.removeAll { $0.id == d.id }
        items.append(d)
        items.sort { $0.priority < $1.priority }
    }
    public static var all: [StatusItemDescriptor] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

// MARK: 面板 / 设置窗口控制（08、04 通过 ServiceLocator 调用，避免互相 import）

public protocol PanelControlling: AnyObject {
    func toggle()
    func show()
    func hide()
}

public protocol SettingsWindowControlling: AnyObject {
    func open(pane: String?)
    func close()
}

public extension ServiceLocator {
    private static var _panel: PanelControlling?
    private static var _settings: SettingsWindowControlling?
    static var panel: PanelControlling? {
        get { lock.lock(); defer { lock.unlock() }; return _panel }
        set { lock.lock(); defer { lock.unlock() }; _panel = newValue }
    }
    static var settings: SettingsWindowControlling? {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set { lock.lock(); defer { lock.unlock() }; _settings = newValue }
    }
}

// MARK: 预览呈现（Panel 实现，Clipboard 消费；specs/12 契约面）
// Clipboard 模块不得直接引用 Panel 模块的 MainPanelPreviewPopoverCoordinator（CONTRACT §1.3），
// 一律经 ServiceLocator.panelPreview 协议调用；Panel 侧由适配器转调协调器。

public protocol PanelPreviewPresenting: AnyObject {
    /// 呈现预览（单击接线用）
    @discardableResult
    func presentPreview(for item: ClipboardItem,
                        anchorRectInWindow: CGRect?,
                        anchorView: NSView?,
                        isFloatingSource: Bool) -> Bool
    /// 程序化关闭预览
    func dismissPreview()
    /// 行悬停调度（anchorRectProvider 延迟取行 window 坐标框，可为 nil）
    func rowHover(_ hovering: Bool,
                  item: ClipboardItem,
                  anchorRectProvider: (() -> CGRect?)?,
                  isFloatingSource: Bool)
    /// 空格键键盘预览（带延时 WorkItem）
    func requestKeyboardPreview(item: ClipboardItem,
                                anchorRectProvider: (() -> CGRect?)?)
    /// 取消未决的键盘预览
    func cancelKeyboardPreview()
    /// 面板即将出现：清抑制与未决 WorkItem
    func prepareForPanelAppear()
    /// 刷新预览导航顺序表
    func setPreviewOrder(_ ids: [String])
    /// 锚条目被删除 → 同步关闭预览
    func notifyItemRemoved(itemID: String)
}

public extension ServiceLocator {
    private static var _panelPreview: PanelPreviewPresenting?
    static var panelPreview: PanelPreviewPresenting? {
        get { lock.lock(); defer { lock.unlock() }; return _panelPreview }
        set { lock.lock(); defer { lock.unlock() }; _panelPreview = newValue }
    }
}
