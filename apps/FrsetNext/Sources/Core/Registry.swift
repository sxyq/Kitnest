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
    private static let order = ["general", "monitor", "clipboard", "capture", "search", "ai", "tools", "shortcuts", "about"]
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
    /// 点击行为
    public let onTap: (() -> Void)?
    /// 点击后弹出的 popover 内容（监测模块详情面板）
    public let popover: (() -> AnyView)?
    public init(id: String,
                priority: Int,
                title: @escaping () -> String,
                attributedTitle: (() -> NSAttributedString)? = nil,
                onTap: (() -> Void)? = nil,
                popover: (() -> AnyView)? = nil) {
        self.id = id; self.priority = priority; self.title = title
        self.attributedTitle = attributedTitle; self.onTap = onTap; self.popover = popover
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
