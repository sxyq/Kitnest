import AppKit
import SwiftUI

// MARK: - 主列表 NSTableView 宿主（specs/14 §4：ClipboardSectionView 行区迁移）
//
// 职责：NSScrollView + NSTableView 骨架，承载原作列表交互族：
// - 行视图复用（RowHostingView，按条目类型注册复用标识）
// - 行点击语义（specs/14 §3.7）：单击/空格 = 预览（不复制）、双击/↩ = 复制、右键 = 菜单
// - 右键按下即触发（specs/14 §3.2 ClipboardRowContextMenuActivationTrackerNSView 语义）
// - hover 高亮与抑制（specs/14 §3.3 ClipboardRowHoverSuppressionController：抑制至鼠标再次移动）
// - 顶部滚动迟滞跟踪（specs/14 §3.4 ClipboardListTopScrollTracker → 回顶按钮）
// - 分页加载（willDisplay 尾行 → loadMoreIfNeeded，顺序表挂预览协调器）
// 预览呈现经 ServiceLocator.panelPreview 协议（specs/12 契约面，Panel 模块实现注入）。

// MARK: - 回顶滚动代理

/// ClipboardSectionView 持有，触发表格平滑回顶（FilterBar_ScrollToTop，specs/14 F8）
public final class ClipboardTableScrollProxy {
    fileprivate weak var scrollView: NSScrollView?

    public init() {}

    public func scrollToTop(animated: Bool = true) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let work = {
            document.scroll(NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
                context.duration = 0.25
                work()
            }
        } else {
            work()
        }
    }
}

// MARK: - hover 抑制控制器（specs/14 §3.3，字段对齐原作）

/// 事件（滚轮滚动/菜单打开/预览关闭等）→ 抑制 hover 高亮；鼠标再次移动即恢复。
public final class ClipboardRowHoverSuppressionController {
    public private(set) var isSuppressedUntilMouseMove = false
    public var hoveredRowItemID: String?
    public var hoveredIconItemID: String?

    public init() {}

    public var isHoverSuppressed: Bool { isSuppressedUntilMouseMove }

    public func suppressUntilMouseMove() {
        isSuppressedUntilMouseMove = true
        hoveredRowItemID = nil
        hoveredIconItemID = nil
    }

    /// 鼠标移动：解除抑制，恢复 hover 高亮
    public func mouseMoved() {
        isSuppressedUntilMouseMove = false
    }
}

// MARK: - 顶部滚动 tracker（specs/14 §3.4，ivar 对齐原作 band/isOut/lastMinY）

/// 对首条目 minY 做迟滞双阈值判定（enter > exit 防抖动），
/// 输出 onFirstItemScrolledOutChange → ClipboardManager.isMainListAtTop。
/// 阈值数值 ⬜ 原作未探明（spec 14 §7），取 40/24 合理默认。
public final class ClipboardListTopScrollTracker {
    public private(set) var band: Double = 0
    public private(set) var isOut = false
    private var lastMinY: Double?

    public var enterThreshold: Double = 40
    public var exitThreshold: Double = 24
    public var onFirstItemScrolledOutChange: ((Bool) -> Void)?

    public init() {}

    /// minY = 首条目相对视口顶部的距离（nil = 空表）
    public func feed(minY: Double?) {
        lastMinY = minY
        guard let minY else {
            setOut(false)
            return
        }
        if isOut {
            if minY <= exitThreshold { setOut(false) }
        } else {
            if minY > enterThreshold { setOut(true) }
        }
    }

    private func setOut(_ value: Bool) {
        guard isOut != value else { return }
        isOut = value
        onFirstItemScrolledOutChange?(value)
    }
}

// MARK: - 行宿主视图（复用 + 点击分派）

/// 行容器：NSHostingView 包 SwiftUI ClipboardRow；右键**按下**即回调（不透传 super，
/// specs/14 §3.2），普通按下按单击/双击分派。尾部 hover 操作按钮区事件交还 SwiftUI。
final class RowHostingView: NSHostingView<AnyView> {

    static let hoverActionsZoneWidth: CGFloat = 104

    let reuseIdentifier: NSUserInterfaceItemIdentifier
    var item: ClipboardItem?
    var contentBuilder: ((ClipboardItem, Bool) -> AnyView)?

    /// 单击（clickCount == 1）→ 预览
    var onSingleClick: ((ClipboardItem) -> Void)?
    /// 双击（clickCount >= 2）→ 复制
    var onDoubleClick: ((ClipboardItem) -> Void)?
    /// 右键**按下**即触发（吞事件，不透传）
    var onRightMouseDown: ((ClipboardItem, CGPoint, NSView) -> Void)?

    init(reuseIdentifier: NSUserInterfaceItemIdentifier, frame: NSRect) {
        self.reuseIdentifier = reuseIdentifier
        super.init(rootView: AnyView(EmptyView()))
        self.frame = frame
        autoresizingMask = [.width]
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError("RowHostingView 走 init(reuseIdentifier:frame:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RowHostingView 不支持 nib")
    }

    func setItem(_ item: ClipboardItem, hovered: Bool) {
        self.item = item
        if let contentBuilder {
            rootView = contentBuilder(item, hovered)
        }
    }

    /// hover 高亮刷新（由表格宿主的跟踪回调驱动）
    func setHovered(_ hovered: Bool) {
        guard let item, let contentBuilder else { return }
        rootView = contentBuilder(item, hovered)
    }

    // 右键按下即触发（specs/14 §3.2：不调 super，吞事件）
    override func rightMouseDown(with event: NSEvent) {
        guard let item else { return }
        let location = convert(event.locationInWindow, from: nil)
        onRightMouseDown?(item, location, self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { super.mouseDown(with: event); return }
        let location = convert(event.locationInWindow, from: nil)
        // 尾部 hover 操作按钮区：交给 SwiftUI 按钮处理
        if location.x > bounds.width - Self.hoverActionsZoneWidth {
            super.mouseDown(with: event)
            return
        }
        // 行点击语义（specs/14 §3.7）：单击=预览、双击=复制
        if event.clickCount >= 2 {
            onDoubleClick?(item)
        } else {
            onSingleClick?(item)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 表格视图（键盘导航 + hover 跟踪）

final class ClipboardTableView: NSTableView {

    /// 空格 → 键盘预览（specs/12 F6 requestKeyboardPreview）
    var onSpaceKey: (() -> Void)?
    /// ↩ → 复制
    var onReturnKey: (() -> Void)?
    /// 鼠标移动（解除 hover 抑制 + 刷新高亮）
    var onMouseMoved: ((NSEvent) -> Void)?
    /// 鼠标离开列表
    var onMouseExited: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // inVisibleRect：随可视区自动伸缩
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    // 键盘语义（specs/14 §3.7）：空格=预览、↩=复制；↑/↓ 走 NSTableView 默认选择移动
    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        switch characters {
        case " ":
            if selectedRow >= 0 { onSpaceKey?(); return }
            super.keyDown(with: event)
        case "\r", "\u{3}":   // ↩ / 小键盘回车
            if selectedRow >= 0 { onReturnKey?(); return }
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - 滚动视图（滚轮 → 抑制 hover，specs/14 F6/C5）

final class ClipboardListScrollView: NSScrollView {
    var onScrollWheel: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?()
        super.scrollWheel(with: event)
    }
}

// MARK: - Representable

public struct ClipboardTableHostView: NSViewRepresentable {

    @ObservedObject var manager: ClipboardManager
    var scrollProxy: ClipboardTableScrollProxy
    var onCopy: (ClipboardItem) -> Void
    var onEdit: (ClipboardItem) -> Void
    var onSummarize: (ClipboardItem) -> Void
    var onDelete: (ClipboardItem) -> Void

    public init(manager: ClipboardManager,
                scrollProxy: ClipboardTableScrollProxy,
                onCopy: @escaping (ClipboardItem) -> Void,
                onEdit: @escaping (ClipboardItem) -> Void,
                onSummarize: @escaping (ClipboardItem) -> Void,
                onDelete: @escaping (ClipboardItem) -> Void) {
        self.manager = manager
        self.scrollProxy = scrollProxy
        self.onCopy = onCopy
        self.onEdit = onEdit
        self.onSummarize = onSummarize
        self.onDelete = onDelete
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClipboardListScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let table = ClipboardTableView()
        table.headerView = nil
        table.rowHeight = Theme.rowHeight
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.gridStyleMask = []
        table.style = .fullWidth
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard.items"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scrollView.documentView = table
        scrollView.postsBoundsChangedNotifications = true
        context.coordinator.bind(scrollView: scrollView, table: table, proxy: scrollProxy)

        // 滚动 → 顶部迟滞 tracker（specs/14 Q④）
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.clipboardBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.reloadTable()
    }

    // MARK: Coordinator（DataSource + Delegate + 交互仲裁）

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        fileprivate var owner: ClipboardTableHostView
        private weak var scrollView: NSScrollView?
        private weak var table: ClipboardTableView?
        private weak var proxy: ClipboardTableScrollProxy?

        // 交互族状态
        let topTracker = ClipboardListTopScrollTracker()
        let hoverSuppression = ClipboardRowHoverSuppressionController()
        private var hoveredRowView: RowHostingView?
        private var hoveredItemID: String?
        /// 是否正在执行锚定滚动（新条目置顶时保持视口，避免 tracker 误报）
        private var isAnchorScrolling = false

        init(owner: ClipboardTableHostView) {
            self.owner = owner
            super.init()
            // 首条目滚出 → manager 发布 + 通知（specs/14 §3.4 mainClipboardFirstItemScrolledOutChanged）
            topTracker.onFirstItemScrolledOutChange = { scrolledOut in
                ClipboardManager.shared.updateFirstItemScrolledOut(scrolledOut)
            }
        }

        func bind(scrollView: ClipboardListScrollView, table: ClipboardTableView, proxy: ClipboardTableScrollProxy) {
            self.scrollView = scrollView
            self.table = table
            self.proxy = proxy
            proxy.scrollView = scrollView

            table.onMouseMoved = { [weak self] event in self?.handleMouseMoved(event) }
            table.onMouseExited = { [weak self] in self?.handleMouseExited() }
            table.onSpaceKey = { [weak self] in self?.handleSpaceKey() }
            table.onReturnKey = { [weak self] in self?.handleReturnKey() }
            scrollView.onScrollWheel = { [weak self] in
                // 滚轮滚动 → 抑制 hover 高亮至鼠标再次移动（specs/14 §3.3/C5）
                self?.hoverSuppression.suppressUntilMouseMove()
                self?.clearHoverHighlight()
            }
        }

        // MARK: DataSource / Delegate

        public func numberOfRows(in tableView: NSTableView) -> Int {
            owner.manager.items.count
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < owner.manager.items.count else { return nil }
            let item = owner.manager.items[row]
            // 行复用：按条目类型注册标识（specs/14 §4：row.text / row.image / …）
            let identifier = NSUserInterfaceItemIdentifier("row.\(item.type.rawValue)")
            let host = tableView.makeView(withIdentifier: identifier, owner: nil) as? RowHostingView
                ?? RowHostingView(reuseIdentifier: identifier,
                                  frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: Theme.rowHeight))
            host.identifier = identifier

            host.contentBuilder = { [weak self] item, hovered in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(ClipboardRow(
                    item: item,
                    isHighlighted: hovered,
                    onCopy: { self.owner.onCopy(item) },
                    onEdit: { self.owner.onEdit(item) },
                    onPreviewWindow: { ClipboardPreviewWindow.open(item: item) },
                    onSummarize: { self.owner.onSummarize(item) }
                ))
            }
            host.onSingleClick = { [weak self] item in self?.handleSingleClick(item) }
            host.onDoubleClick = { [weak self] item in self?.handleDoubleClick(item) }
            host.onRightMouseDown = { [weak self] item, location, sourceView in
                // 右键按下即弹菜单（specs/14 §3.2/C4）；菜单打开期间抑制 hover
                self?.hoverSuppression.suppressUntilMouseMove()
                ClipboardNativeMenuPresenter.shared.presentMenu(for: item, at: location, in: sourceView)
            }
            host.setItem(item, hovered: (item.id == hoveredItemID))
            return host
        }

        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // 行高策略（specs/14 §4）：图/文统一 56，大文本预览交给 popover（specs/12）
            Theme.rowHeight
        }

        public func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            // 分页加载：尾行进入视口 → loadMoreIfNeeded
            // （顺序表刷新挂预览协调器，specs/12 F8 __pendingPreviewPaginationRequest 对接点）
            guard row < owner.manager.items.count else { return }
            owner.manager.loadMoreIfNeeded(currentItem: owner.manager.items[row])
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            // 选择移动 → 取消未决键盘预览（specs/12 F6）
            ServiceLocator.panelPreview?.cancelKeyboardPreview()
        }

        // MARK: 数据刷新（锚定滚动：新条目置顶不打断浏览）

        func reloadTable() {
            guard let table, let scrollView else { return }
            let items = owner.manager.items
            let previousFirstVisibleRow = table.row(at: NSPoint(x: 0, y: scrollView.contentView.documentVisibleRect.minY + 1))
            let previousAnchorID: String? = (previousFirstVisibleRow >= 0 && previousFirstVisibleRow < owner.manager.items.count)
                ? owner.manager.items[previousFirstVisibleRow].id : nil
            let previousTopGap: CGFloat = previousFirstVisibleRow >= 0
                ? table.rect(ofRow: previousFirstVisibleRow).minY - scrollView.contentView.documentVisibleRect.minY
                : 0

            table.reloadData()

            // 非顶部浏览态：新条目置顶提升不拉走视口（specs/14 §3.4 顶部同步闸的 UX 等价实现）
            if !owner.manager.isMainListAtTop, let anchorID = previousAnchorID,
               let anchorRow = items.firstIndex(where: { $0.id == anchorID }) {
                isAnchorScrolling = true
                let targetY = table.rect(ofRow: anchorRow).minY - previousTopGap
                table.scrollRowToVisible(anchorRow)
                scrollView.documentView?.scroll(NSPoint(x: 0, y: max(0, targetY)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                isAnchorScrolling = false
            }

            // 预览协调器对接（specs/12 F7 顺序表 + F8 __pendingPreviewPaginationRequest 对接点）：
            // 顺序表随列表/分页刷新，预览导航与分页可见新页条目
            ServiceLocator.panelPreview?.setPreviewOrder(items.map(\.id))
        }

        // MARK: 滚动跟踪

        @objc func clipboardBoundsDidChange(_ note: Notification) {
            guard !isAnchorScrolling else { return }
            feedTopTracker()
        }

        private func feedTopTracker() {
            guard let scrollView, let table, table.numberOfRows > 0 else {
                topTracker.feed(minY: nil)
                return
            }
            let visible = scrollView.contentView.documentVisibleRect
            let firstRow = table.row(at: NSPoint(x: 0, y: visible.minY + 1))
            guard firstRow >= 0 else {
                topTracker.feed(minY: nil)
                return
            }
            let minY = table.rect(ofRow: firstRow).minY - visible.minY
            topTracker.feed(minY: Double(minY))
        }

        // MARK: hover（specs/14 §3.3/C5）

        private func handleMouseMoved(_ event: NSEvent) {
            hoverSuppression.mouseMoved()   // 移动即恢复高亮
            guard let table else { return }
            let location = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: location)
            guard row >= 0, row < owner.manager.items.count else {
                clearHoverHighlight()
                return
            }
            let item = owner.manager.items[row]
            guard item.id != hoveredItemID else { return }
            clearHoverHighlight()
            guard !hoverSuppression.isHoverSuppressed else { return }
            hoveredItemID = item.id
            hoverSuppression.hoveredRowItemID = item.id
            hoveredRowView = rowView(at: row)
            hoveredRowView?.setHovered(true)
            // 悬停预览调度（specs/12 F1：open/close WorkItem + hover-intent 由协调器仲裁）
            ServiceLocator.panelPreview?.rowHover(
                true, item: item,
                anchorRectProvider: { [weak hoveredRowView] in
                    guard let view = hoveredRowView, view.window != nil else { return nil }
                    return view.convert(view.bounds, to: nil)
                },
                isFloatingSource: false)
        }

        private func handleMouseExited() {
            clearHoverHighlight()
        }

        private func clearHoverHighlight() {
            guard let previousID = hoveredItemID else { return }
            hoveredRowView?.setHovered(false)
            hoveredRowView = nil
            hoveredItemID = nil
            hoverSuppression.hoveredRowItemID = nil
            if let item = owner.manager.items.first(where: { $0.id == previousID }) {
                ServiceLocator.panelPreview?.rowHover(
                    false, item: item,
                    anchorRectProvider: { nil },
                    isFloatingSource: false)
            }
        }

        private func rowView(at row: Int) -> RowHostingView? {
            guard let table, row >= 0, row < table.numberOfRows else { return nil }
            let rect = table.rect(ofRow: row)
            let hit = table.subviews.first { $0.frame.intersects(rect) } as? RowHostingView
            return hit
        }

        // MARK: 行点击语义（specs/14 §3.7 / C11）

        private func anchorProvider(for view: NSView?) -> () -> CGRect? {
            { [weak view] in
                guard let view, view.window != nil else { return nil }
                return view.convert(view.bounds, to: nil)
            }
        }

        private func handleSingleClick(_ item: ClipboardItem) {
            // 单击 = 预览（不复制）；锚点取行视图 window 坐标
            let anchor = anchorProvider(for: rowView(forItemID: item.id))
            ServiceLocator.panelPreview?.presentPreview(for: item,
                                                        anchorRectInWindow: anchor(),
                                                        anchorView: nil,
                                                        isFloatingSource: false)
        }

        private func handleDoubleClick(_ item: ClipboardItem) {
            // 双击 = 复制（预览程序化关闭）
            ServiceLocator.panelPreview?.dismissPreview()
            owner.onCopy(item)
        }

        private func handleSpaceKey() {
            guard let table, table.selectedRow >= 0, table.selectedRow < owner.manager.items.count else { return }
            let item = owner.manager.items[table.selectedRow]
            let view = rowView(forItemID: item.id)
            ServiceLocator.panelPreview?.requestKeyboardPreview(item: item,
                                                                anchorRectProvider: anchorProvider(for: view))
        }

        private func handleReturnKey() {
            guard let table, table.selectedRow >= 0, table.selectedRow < owner.manager.items.count else { return }
            let item = owner.manager.items[table.selectedRow]
            ServiceLocator.panelPreview?.dismissPreview()
            owner.onCopy(item)
        }

        private func rowView(forItemID itemID: String) -> NSView? {
            guard let table,
                  let row = owner.manager.items.firstIndex(where: { $0.id == itemID }),
                  row < table.numberOfRows else { return nil }
            let rect = table.rect(ofRow: row)
            return table.subviews.first { $0.frame.intersects(rect) }
        }
    }
}

// MARK: - 原生右键菜单（specs/14 §2.2：ClipboardNativeMenuPresenter / ClipboardMenuActionItem）

/// 右键按下即呈现的原生 NSMenu（AppKit 层，替代 SwiftUI contextMenu 的延迟语义）
public final class ClipboardNativeMenuPresenter: NSObject {

    public static let shared = ClipboardNativeMenuPresenter()

    public func presentMenu(for item: ClipboardItem, at location: CGPoint, in view: NSView) {
        let menu = NSMenu()
        let manager = ClipboardManager.shared
        let tagStore = TagStore.shared
        let canSummarize = ClipboardSummaryExecutionCoordinator.shared.isAvailable

        func addItem(_ title: String, systemImage: String?, enabled: Bool = true, _ action: @escaping () -> Void) {
            let menuItem = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = BlockMenuItemAction(action)
            menuItem.isEnabled = enabled
            if let systemImage, let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title) {
                menuItem.image = image
            }
            menu.addItem(menuItem)
        }

        addItem("复制", systemImage: "doc.on.doc") { manager.copy(item) }
        addItem("编辑", systemImage: "pencil") { ClipboardItemEditWindowRecord.open(for: item) }
        addItem("重命名", systemImage: "character.cursor.ibeam") { ClipboardItemEditWindowRecord.open(for: item) }
        addItem(item.isNote ? "取消笔记标记" : "标记为笔记", systemImage: "note.text") {
            manager.setNote(item, isNote: !item.isNote)
        }
        addItem("大文本预览", systemImage: "doc.text.magnifyingglass") { ClipboardPreviewWindow.open(item: item) }
        addItem("AI 摘要", systemImage: "sparkles", enabled: canSummarize) {
            Task { _ = try? await ClipboardSummaryExecutionCoordinator.shared.summarizeAndWriteBack(item) }
        }

        // 标签子菜单（specs/14 §3.6：标签菜单 + 全标签哨兵语义；新建标签走编辑窗，TODO 注释）
        let tagMenu = NSMenu(title: "标签")
        for tag in tagStore.tags {
            let tagItem = NSMenuItem(title: tag.name, action: #selector(menuAction(_:)), keyEquivalent: "")
            tagItem.target = self
            tagItem.representedObject = BlockMenuItemAction {
                tagStore.toggle(tagID: tag.id, dedupeKey: item.dedupeKey)
            }
            tagItem.state = item.tagIDs.contains(tag.id) ? .on : .off
            tagItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: tag.name)
            tagMenu.addItem(tagItem)
        }
        if tagStore.tags.isEmpty {
            let empty = NSMenuItem(title: "暂无标签", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            tagMenu.addItem(empty)
        }
        let tagRoot = NSMenuItem(title: "标签", action: nil, keyEquivalent: "")
        tagRoot.submenu = tagMenu
        menu.addItem(tagRoot)

        menu.addItem(.separator())
        addItem("删除", systemImage: "trash") {
            // 条目删除 → 预览协调器同步关闭锚定预览（specs/12 F10 itemRemoved）
            ServiceLocator.panelPreview?.notifyItemRemoved(itemID: item.id)
            manager.delete(item)
        }

        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: location, in: view)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? BlockMenuItemAction)?.run()
    }
}

/// NSMenuItem 的闭包载体（ClipboardMenuActionItem+Coordinator 语义的最小实现）
final class BlockMenuItemAction {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    func run() { block() }
}
