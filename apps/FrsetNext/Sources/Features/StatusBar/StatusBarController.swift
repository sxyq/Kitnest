import AppKit
import Foundation
import SwiftUI

// MARK: - 状态项运行时条目（NSStatusItem + 其描述符）

/// 一个已创建的动态状态项：持有 NSStatusItem 与对应的描述符
private struct StatusItemEntry {
    let descriptor: StatusItemDescriptor
    let item: NSStatusItem
}

// MARK: - 菜单栏状态项总控

/// StatusBarController：Item-0（主图标）+ 由 StatusItemRegistry 注册的动态状态项
/// - 左键主图标 → ServiceLocator.panel?.toggle()；右键 → 主菜单
/// - 动态状态项：1s 刷新标题，点击优先 onTap，否则弹 popover
/// - 每 5s 重新同步注册表（新增/移除），尊重 menuBarIconsVisible，最多展示 6 个（其余合并到「更多」）
public final class StatusBarController: NSObject {

    public static let shared = StatusBarController()

    /// 除主图标外最多展示的动态状态项数量
    private static let maxVisibleItems = 6
    /// 「更多」聚合项的标题
    private static let overflowTitle = "⋯"
    /// 隐藏标记：注册方（如监测模块）在设置里关掉某项时，不注销 descriptor，
    /// 而是让 title() 返回以本前缀开头的字符串；本模块据此隐藏该项（硬编码，避免跨模块引用）
    private static let hiddenMarker = "⟨monitor:hidden⟩"

    private var mainItem: NSStatusItem?
    private var entries: [StatusItemEntry] = []
    private var overflowItem: NSStatusItem?
    private var overflowDescriptors: [StatusItemDescriptor] = []
    /// 上次同步时的状态项 id 序列（用于判定是否需要重建）
    private var lastIDs: [String] = []

    private var currentPopover: NSPopover?
    private var refreshTimer: Timer?
    private var syncTimer: Timer?
    private var defaultsObservation: NSObjectProtocol?
    private var didInstall = false

    private override init() { super.init() }

    // MARK: 安装

    /// 安装主图标并启动刷新/同步定时器（必须在主线程调用，内部会兜底切主线程）
    public func install() {
        if Thread.isMainThread {
            performInstall()
        } else {
            DispatchQueue.main.async { self.performInstall() }
        }
    }

    private func performInstall() {
        guard !didInstall else { return }
        didInstall = true
        installMainItem()
        syncStatusItems()
        startTimers()
        observePreferences()
        Log.info("StatusBar", "installed")
    }

    /// 卸载全部状态项（退出或调试用）
    public func uninstall() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.uninstall() }; return }
        refreshTimer?.invalidate(); refreshTimer = nil
        syncTimer?.invalidate(); syncTimer = nil
        if let obs = defaultsObservation { NotificationCenter.default.removeObserver(obs); defaultsObservation = nil }
        teardownItems()
        if let main = mainItem { NSStatusBar.system.removeStatusItem(main); mainItem = nil }
        didInstall = false
    }

    private func installMainItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let symbol = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Frset")
        symbol?.isTemplate = true                 // 模板图：随菜单栏明暗自动变色
        item.button?.image = symbol
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Frset（右键查看更多）"
        item.button?.target = self
        item.button?.action = #selector(mainItemClicked(_:))
        // 左键开面板，右键弹菜单
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        ToastAnchor.button = item.button       // 通知条定位锚点（spec 13 §3，主状态项图标）
        mainItem = item
    }

    private func startTimers() {
        refreshTimer?.invalidate()
        let refresh = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshTitles() }
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh

        syncTimer?.invalidate()
        let sync = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in self?.syncStatusItems() }
        RunLoop.main.add(sync, forMode: .common)
        syncTimer = sync
    }

    /// 偏好变化时立即生效（menuBar.iconsVisible）
    private func observePreferences() {
        defaultsObservation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncStatusItems()
        }
    }

    // MARK: 同步（新建/移除）

    /// 与 StatusItemRegistry 对齐：id 序列变化才重建，否则只刷新标题
    public func syncStatusItems() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.syncStatusItems() }; return }
        guard didInstall else { return }
        // 关闭开关时只保留主图标；再过滤掉注册方标记为隐藏的项
        let descriptors = Preferences.shared.menuBarIconsVisible
            ? StatusItemRegistry.all.filter { !Self.isHidden($0) }
            : []
        let ids = descriptors.map { $0.id }
        guard ids != lastIDs else { refreshTitles(); return }
        rebuild(descriptors)
    }

    /// 该项是否被注册方标记为隐藏（title 带隐藏标记前缀）
    private static func isHidden(_ d: StatusItemDescriptor) -> Bool {
        if d.title().hasPrefix(hiddenMarker) { return true }
        if let attr = d.attributedTitle?(), attr.string.hasPrefix(hiddenMarker) { return true }
        return false
    }

    private func rebuild(_ descriptors: [StatusItemDescriptor]) {
        teardownItems()
        let visible = Array(descriptors.prefix(Self.maxVisibleItems))
        entries = visible.map { StatusItemEntry(descriptor: $0, item: makeStatusItem(for: $0)) }
        let rest = Array(descriptors.dropFirst(Self.maxVisibleItems))
        overflowDescriptors = rest
        if rest.isEmpty {
            overflowItem = nil
        } else {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = Self.overflowTitle
            item.button?.font = NSFont.menuBarFont(ofSize: 13)
            item.button?.toolTip = "更多状态项"
            let menu = NSMenu()
            menu.delegate = self                  // 打开时按最新数据重建（见 menuNeedsUpdate）
            item.menu = menu
            overflowItem = item
        }
        lastIDs = descriptors.map { $0.id }
        refreshTitles()
        Log.debug("StatusBar", "synced: visible=\(visible.count) overflow=\(rest.count)")
    }

    private func makeStatusItem(for d: StatusItemDescriptor) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = d.title()
        item.button?.font = NSFont.menuBarFont(ofSize: 11)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.toolTip = d.id
        return item
    }

    private func teardownItems() {
        currentPopover?.close(); currentPopover = nil
        for e in entries { NSStatusBar.system.removeStatusItem(e.item) }
        entries = []
        if let overflow = overflowItem { NSStatusBar.system.removeStatusItem(overflow) }
        overflowItem = nil
        overflowDescriptors = []
    }

    // MARK: 刷新

    private func refreshTitles() {
        guard Thread.isMainThread else { return }
        var needsResync = false
        for e in entries {
            guard let button = e.item.button else { continue }
            // 运行中被标记隐藏（两次同步之间）：先就地隐藏，再触发同步释放名额
            if Self.isHidden(e.descriptor) {
                if e.item.isVisible { e.item.isVisible = false }
                needsResync = true
                continue
            }
            if !e.item.isVisible { e.item.isVisible = true }
            if let attributed = e.descriptor.attributedTitle?() {
                button.attributedTitle = attributed
            } else {
                let text = e.descriptor.title()
                if button.title != text { button.title = text }
            }
            // B6：按内容自适应宽度
            e.item.length = NSStatusItem.variableLength
        }
        // 「更多」聚合项：其下全部被隐藏时一并隐藏
        if let overflow = overflowItem {
            let hasVisible = overflowDescriptors.contains { !Self.isHidden($0) }
            if overflow.isVisible != hasVisible { overflow.isVisible = hasVisible }
            if !hasVisible { needsResync = true }
        }
        // 有项被隐藏 → 立即重建，把名额让给后面的项（重建后 entries 不再含隐藏项，不会递归）
        if needsResync { syncStatusItems() }
    }

    // MARK: 交互

    @objc private func mainItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        // 彩蛋：连续单击主图标 10 次触发 Symbol Mode 解锁（spec 13 §6，重建版触发器改造）
        MenuBarIconEasterEggManager.shared.registerMainIconClick()
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            let menu = StatusBarMenuBuilder.mainMenu(target: self)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 6),
                       in: button)
        } else {
            ServiceLocator.panel?.toggle()
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let entry = entries.first(where: { $0.item.button === button }) else { return }
        handle(descriptor: entry.descriptor, anchor: button)
    }

    @objc private func overflowItemAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let d = overflowDescriptors.first(where: { $0.id == id }),
              let button = overflowItem?.button else { return }
        handle(descriptor: d, anchor: button)
    }

    /// 点击行为：优先 onTap，其次 popover，最后回落为打开主面板
    private func handle(descriptor d: StatusItemDescriptor, anchor button: NSStatusBarButton) {
        if let onTap = d.onTap {
            onTap()
            return
        }
        if let build = d.popover {
            showPopover(build(), relativeTo: button)
            return
        }
        ServiceLocator.panel?.toggle()
    }

    private func showPopover(_ view: AnyView, relativeTo button: NSStatusBarButton) {
        currentPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient                 // 点击外部自动关闭
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: Theme.panelWidth, height: 260)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        currentPopover = popover
    }

    // MARK: 菜单动作（StatusBarMenuBuilder 组装的菜单目标）

    @objc func openPanelAction(_ sender: Any?) { ServiceLocator.panel?.show() }

    @objc func openSettingsAction(_ sender: Any?) { ServiceLocator.settings?.open(pane: nil) }

    /// 打开统计窗（spec 17 S1/S2：打开即埋点 statistics_open，埋点在 StatisticsWindowController.openStatistics 内）
    @objc func showStatisticsAction(_ sender: Any?) {
        StatisticsWindowController.shared.openStatistics()
    }

    @objc func toggleIconsAction(_ sender: NSMenuItem) {
        let next = !Preferences.shared.menuBarIconsVisible
        Preferences.shared.menuBarIconsVisible = next
        syncStatusItems()
        Toast.show(next ? "已显示菜单栏状态项" : "已隐藏菜单栏状态项", icon: "menubar.rectangle")
    }

    @objc func quitAction(_ sender: Any?) { NSApp.terminate(nil) }
}

// MARK: - NSPopoverDelegate / NSMenuDelegate

extension StatusBarController: NSPopoverDelegate, NSMenuDelegate {
    public func popoverDidClose(_ notification: Notification) {
        currentPopover = nil
    }

    /// 「更多」菜单：每次打开按最新数据重建
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === overflowItem?.menu else { return }
        menu.removeAllItems()
        // 隐藏项不出现在「更多」菜单里
        for d in overflowDescriptors where !Self.isHidden(d) {
            let item = NSMenuItem(title: d.title(),
                                  action: #selector(overflowItemAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = d.id
            menu.addItem(item)
        }
    }
}
