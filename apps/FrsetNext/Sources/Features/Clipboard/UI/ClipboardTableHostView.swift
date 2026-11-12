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

public extension Notification.Name {
    /// 剪贴板列表选中项变化（object: ClipboardItem?）。
    /// 主面板底部工具条的「编辑/上传」按选中项启用（2026-10-18）。
    static let clipboardSelectionChanged = Notification.Name("frset.clipboardSelectionChanged")
    /// v102：底部工具条「回到顶部」→ 剪贴板列表回顶（代理在 ClipboardSectionView 内，走通知触发）
    static let frsetClipboardScrollTop = Notification.Name("frset.clipboardScrollTop")
}

/// ClipboardSectionView 持有，触发表格平滑回顶（FilterBar_ScrollToTop，specs/14 F8）
public final class ClipboardTableScrollProxy {
    fileprivate weak var scrollView: NSScrollView?

    public init() {}

    /// v102（2026-10-21 用户：「向上箭头按钮无法点击，功能应该是回到顶部」）：
    /// 回顶此前从未实现（代理空壳），按钮被误做成「上传」占位。补真实现：
    /// 平滑滚回列表顶部并同步滚动条。
    public func scrollToTop() {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.dPage
            ctx.timingFunction = Theme.Motion.caEaseOut
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: 0))
            scrollView.reflectScrolledClipView(clip)
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

/// 对**首行底边相对视口顶部的距离**做迟滞双阈值判定（enter > exit 防抖动），
/// 输出 onFirstItemScrolledOutChange → ClipboardManager.isMainListAtTop。
///
/// 坐标语义（修复说明）：`distance = viewportOriginY - (firstRowMinY + firstRowHeight)`，
/// 即首行底边高出视口顶部的距离。列表在顶部时 distance = -(行高) 为负；
/// 向下滚动越过首行后 distance 递增转正。故 enter(40) 判「已滚出」、exit(24) 判「已回到顶部」。
/// ⚠️ 阈值数值 40/24 为推断值，原作字面量位于字面池未解码（specs/14 §7）。
public final class ClipboardListTopScrollTracker {
    public private(set) var band: Double = 0
    public private(set) var isOut = false
    private var lastMinY: Double?

    public var enterThreshold: Double = 40
    public var exitThreshold: Double = 24
    public var onFirstItemScrolledOutChange: ((Bool) -> Void)?

    public init() {}

    /// - Parameters:
    ///   - firstRowMinY: 首行在表格内容坐标系中的 top
    ///   - firstRowHeight: 首行高度
    ///   - viewportOriginY: clipView 视口原点（内容坐标系）
    ///   - hasFirstRow: 列表是否非空；空列表视为在顶部
    public func feed(firstRowMinY: Double?, firstRowHeight: Double, viewportOriginY: Double) {
        guard let firstRowMinY else {
            lastMinY = nil
            setOut(false)
            return
        }
        let distance = viewportOriginY - (firstRowMinY + firstRowHeight)
        lastMinY = distance
        if isOut {
            if distance <= exitThreshold { setOut(false) }
        } else {
            if distance > enterThreshold { setOut(true) }
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
// MARK: - 行容器（接管系统选中绘制）

/// v156（用户：「蓝色框会直接填满，状态品味很差」）：
/// NSTableView 默认选中是**整行铺满 controlAccentColor**，在无边框、无内距的列表里
/// 就是一块高饱和蓝砖，而且会盖住行内的圆角与分隔线。这里接管绘制：
///   · 与 hover 同款内缩（左右 6pt / 上下 1.5pt）+ G2 圆角（半径 9）
///   · 强调色只上 12%（非活动窗口 8%），选中是「淡底」而不是「实心」
final class ClipboardRowChromeView: NSTableRowView {

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = bounds.insetBy(dx: 6, dy: 1.5)
        guard inset.width > 8, inset.height > 8 else { return }
        let alpha: CGFloat = isEmphasized ? 0.12 : 0.08
        Theme.accentNS.withAlphaComponent(alpha).setFill()
        NSBezierPath.continuousRoundedRect(inset, radius: 9).fill()
    }

    /// 不用系统的行底色（交替条纹/压暗），列表背景由页面负责
    override func drawBackground(in dirtyRect: NSRect) {}
}

final class RowHostingView: NSHostingView<AnyView> {

    static let hoverActionsZoneWidth: CGFloat = 104

    let reuseIdentifier: NSUserInterfaceItemIdentifier
    var item: ClipboardItem?
    var contentBuilder: ((ClipboardItem, Bool) -> AnyView)?
    /// 本视图对应的行号（viewFor 中登记）；供选中态反查
    var row: Int = -1

    /// 行主体区按下后的宿主回调（修复 C11）：同时负责建立选中态与把表格设为 first responder。
    /// 两个动作缺一不可——见 mouseDown 内注释。尾部 hover 操作按钮区不走此回调。
    var onPlainMouseDown: ((Int, NSEvent) -> Void)?

    /// 单击（clickCount == 1）→ 预览
    var onSingleClick: ((ClipboardItem) -> Void)?
    /// 双击（clickCount >= 2）→ 复制
    var onDoubleClick: ((ClipboardItem) -> Void)?
    /// 修饰键点击（⌘=toggle 加选 / ⇧=范围加选）→ 多选批量复制（原版「已复制 N 项」）。
    /// 多选期间不触发预览/复制，由宿主维护 selectedRowIndexes。
    var onModifierClick: ((Int, Bool) -> Void)?
    /// 右键**按下**即触发（吞事件，不透传）
    var onRightMouseDown: ((ClipboardItem, CGPoint, NSView) -> Void)?

    init(reuseIdentifier: NSUserInterfaceItemIdentifier, frame: NSRect) {
        self.reuseIdentifier = reuseIdentifier
        super.init(rootView: AnyView(EmptyView()))
        self.frame = frame
        autoresizingMask = [.width]
        // v100（2026-10-21 用户：「每条卡片横向宽度不一致，改了没生效」）：
        // 真凶在此——NSHostingView 默认 sizingOptions 会**按内容自定尺寸**，
        // SwiftUI 视图被换 rootView 后自缩宽度 → 每条卡片宽窄不一、和日历卡
        // 对不齐；此前改 padding/列宽都没用，因为宽度被宿主视图自己改掉。
        // 关掉自适应（与工具窗/预览窗宿主同规格）：宽度由表格列宽决定，恒满宽。
        sizingOptions = []
    }

    @available(*, unavailable)
    required init(rootView: AnyView) {
        fatalError("RowHostingView 走 init(reuseIdentifier:frame:)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RowHostingView 不支持 nib")
    }

    /// 当前渲染的 hover 态（v101：同值短路，rootView 重挂是 NSHostingView 最贵操作）
    private var renderedHovered: Bool?

    func setItem(_ item: ClipboardItem, hovered: Bool) {
        let same = self.item == item && renderedHovered == hovered
        self.item = item
        guard !same, let contentBuilder else { return }
        renderedHovered = hovered
        rootView = contentBuilder(item, hovered)
    }

    /// hover 高亮刷新（由表格宿主的跟踪回调驱动）
    func setHovered(_ hovered: Bool) {
        guard let item, let contentBuilder else { return }
        guard renderedHovered != hovered else { return }   // v101 同值短路
        renderedHovered = hovered
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
        // 尾部 hover 操作按钮区：交给 SwiftUI 按钮处理（保持既有分支不变，不抢键盘焦点）
        if location.x > bounds.width - Self.hoverActionsZoneWidth {
            super.mouseDown(with: event)
            return
        }
        // 行点击语义（specs/14 §3.7）：单击=预览、双击=复制；
        // ⌘=toggle 加选、⇧=范围加选（多选期间不触发预览/复制）
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command), shift = mods.contains(.shift)
        if cmd || shift {
            if row >= 0 { onModifierClick?(row, shift) }
            if row >= 0 { onPlainMouseDown?(row, event) }   // 仍夺键盘归属（↩ 批量复制用）
            return
        }
        if event.clickCount >= 2 {
            onDoubleClick?(item)
        } else {
            Log.info("clipboard", "row mouseDown: single click dispatched (row=\(row))")
            onSingleClick?(item)
        }
        // 分派之后才建立选中态与键盘归属（修复 C11，两个动作缺一不可）：
        // ① 选中——本类不透传 super，AppKit 默认选中路径不执行，selectedRow 恒 -1，
        //    而空格/↩ 都以 selectedRow >= 0 为门槛；
        // ② 键盘归属——本类 acceptsFirstMouse=true 会抢走 first responder，
        //    若不显式把表格设为 first responder，ClipboardTableView.keyDown 收不到
        //    空格/↩，即使选中态已成立。
        // 放在分派之后：让 popover 先完成呈现，再落first responder。
        if row >= 0 { onPlainMouseDown?(row, event) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 行视图弱引用盒：挂在 Coordinator 的行号侧表里，避免强引用阻止复用池回收。
final class WeakRowBox {
    weak var view: RowHostingView?
    init(_ view: RowHostingView) { self.view = view }
}

// MARK: - 表格视图（键盘导航 + hover 跟踪）

final class ClipboardTableView: NSTableView {

    /// 近期选择窗只勾选，不触发主列表的预览或双击复制。
    var onSelectionClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onSelectAll: (() -> Void)?
    var onSelectionCursorMove: (() -> Void)?
    var selectionCursor = -1

    override func mouseDown(with event: NSEvent) {
        guard let onSelectionClick else { super.mouseDown(with: event); return }
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onSelectionClick(row, event.modifierFlags) }
        window?.makeFirstResponder(self)
    }

    func toggleRowSelection(row: Int, shift: Bool, anchor: inout Int) {
        var rows = selectedRowIndexes
        if shift, anchor >= 0 {
            rows.formUnion(IndexSet(integersIn: min(anchor, row)...max(anchor, row)))
        } else {
            if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
            anchor = row
        }
        selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// 空格 → 键盘预览（specs/12 F6 requestKeyboardPreview）
    var onSpaceKey: (() -> Void)?
    /// ↩ → 复制
    var onReturnKey: (() -> Void)?
    /// 本次选中变化是否由键盘导航（↑/↓/PageUp/PageDown/Home/End/首字母）引起。
    /// 生命周期仅覆盖一次 keyDown → super.keyDown 的同步分派：
    /// 置位 → super.keyDown 内同步触发 selectionDidChange → 消费 → 复位。
    /// 用于让 tableViewSelectionDidChange 区分「键盘导航移动选择」（应取消未决键盘预览）
    /// 与「鼠标点击 / reloadData 导致的选中变化」（不应取消）。
    var isKeyboardNavigating = false
    /// 鼠标移动（解除 hover 抑制 + 刷新高亮）
    var onMouseMoved: ((NSEvent) -> Void)?
    /// 鼠标离开列表
    var onMouseExited: (() -> Void)?

    /// 页面激活状态（2026-10-18「幽灵预览」修复）：
    /// 主面板三页（主页/性能监测/中转站）是 ZStack **常驻**结构，非当前页只做
    /// `opacity(0) + allowsHitTesting(false)`——但 NSTrackingArea 是 AppKit 层机制，
    /// **不受 SwiftUI 命中测试控制**：透明主页的表格仍在接收 mouseMoved，
    /// 在性能页/中转站页上划过「隐形行」的位置就会弹出文本框/图片预览。
    /// 非激活时移除 tracking area 并忽略 mouseMoved。
    var isActive: Bool = true {
        didSet {
            guard oldValue != isActive else { return }
            updateTrackingAreas()
            if !isActive { onMouseExited?() }   // 顺带清掉残留的 hover 高亮/预览
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    override var acceptsFirstResponder: Bool { isActive || onSelectionClick != nil }

    // v112（2026-10-21 宽度实证：日历卡 344.0 vs 行卡 332.06，两侧各缩 6pt）：
    // 列宽此前只在 updateNSView 修一次——SwiftUI 后续布局变化不再触发 →
    // 列宽停在中间值，单元格比表窄（NSTableView 居中放置 = 两侧各缩 6pt）。
    // 每次 layout 钉死列宽 = 表宽，行卡恒满宽（与日历卡 344 对齐）。
    override func layout() {
        super.layout()
        // v112（AppKit 实测链：table=344 而 column=332 → 行卡 332 vs 日历卡 344，
        // 两侧各缩 6pt 的真凶是列宽）。注意：NSTableView 的 bounds.width =
        // 列宽之和（自撑 documentView），钉 bounds.width 会自增循环（实测爆到
        // 22686）；稳定基准是**剪辑视图宽**（可视宽，恒 344）。
        if let clip = enclosingScrollView?.contentView,
           let col = tableColumns.first, clip.bounds.width > 50,
           abs(col.width - clip.bounds.width) > 0.5 {
            col.width = clip.bounds.width
        }
    }

    // v112：宽度对齐后仍有 6pt 水平偏移——AppKit 默认 cell 框带缩进标记内边距
    //（indentationMarkerInset 默认 6pt）。覆写 cell 框：x=0、宽=剪辑宽，
    // 行卡与日历卡完全同缘。
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let base = super.frameOfCell(atColumn: column, row: row)
        let w = enclosingScrollView?.contentView.bounds.width ?? base.width
        guard w > 50 else { return base }
        return NSRect(x: 0, y: base.origin.y, width: w, height: base.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea); self.hoverTrackingArea = nil }
        guard isActive else { return }
        // inVisibleRect：随可视区自动伸缩
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard isActive else { return }
        onMouseMoved?(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard isActive else { return }
        onMouseExited?()
    }

    // 键盘语义（specs/14 §3.7）：空格=预览、↩=复制；↑/↓ 走 NSTableView 默认选择移动
    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        if let onSelectionClick {
            if event.modifierFlags.contains(.command), characters == "a" { onSelectAll?(); return }
            if event.keyCode == 125 || event.keyCode == 126 {
                selectionCursor = min(max(selectionCursor + (event.keyCode == 125 ? 1 : -1), 0), numberOfRows - 1)
                if selectionCursor >= 0 { scrollRowToVisible(selectionCursor) }
                onSelectionCursorMove?()
                return
            }
            if characters == " " {
                if selectionCursor >= 0 { onSelectionClick(selectionCursor, event.modifierFlags) }
                return
            }
            if characters == "\r" { onReturnKey?(); return }
        }
        // 诊断（临时）：键盘入口打状态。handleSpaceKey/handleReturnKey 的入口日志
        // 只在本函数真正分派过去后才才会执行；若这里完全没有日志 → 说明本表格
        // 不是 first responder（焦点被搜索框等抢占），keyDown 压根没被调用。
        // ⚠️ 诊断点，非行为变更，不计入对照差异。
        Log.info("clipboard", "keyDown[\(characters)] selectedRow=\(selectedRow) "
            + "firstResponder=\(String(describing: window?.firstResponder))")
        switch characters {
        case " ":
            if selectedRow >= 0 { onSpaceKey?(); return }
            super.keyDown(with: event)
        case "\r", "\u{3}":   // ↩ / 小键盘回车
            if selectedRow >= 0 { onReturnKey?(); return }
            super.keyDown(with: event)
        default:
            // 其余按键（↑/↓/PageUp/PageDown/Home/End/首字母选择）一律交给 NSTableView 默认处理，
            // 且它们都可能**同步**改变选中态。置标记供 tableViewSelectionDidChange 判别来源：
            // 「键盘导航导致的选中变化」应取消未决键盘预览（specs/12 F6），
            // 「鼠标点击 / reloadData 导致的选中变化」不应取消。
            isKeyboardNavigating = true
            super.keyDown(with: event)
            // 兜底复位：末行按 ↓、首行按 ↑ 等边界不会产生选中变化，selectionDidChange 不触发，
            // 标记必须在此回收，否则会泄漏到下一次鼠标点击。
            isKeyboardNavigating = false
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
    @Environment(\.isSettingsPreview) private var isSettingsPreview

    @ObservedObject var manager: ClipboardManager
    /// v66 个性化（密度/徽章/缩略图变更 → updateNSView 即时生效）
    @ObservedObject var personalization = Personalization.shared
    var scrollProxy: ClipboardTableScrollProxy
    /// 页面是否激活（非主页 = 面板切到性能监测/中转站时禁用 hover 追踪，防幽灵预览）
    var isActive: Bool = true
    var onCopy: (ClipboardItem) -> Void
    var onEdit: (ClipboardItem) -> Void
    var onSummarize: (ClipboardItem) -> Void
    var onDelete: (ClipboardItem) -> Void

    public init(manager: ClipboardManager,
                scrollProxy: ClipboardTableScrollProxy,
                isActive: Bool = true,
                onCopy: @escaping (ClipboardItem) -> Void,
                onEdit: @escaping (ClipboardItem) -> Void,
                onSummarize: @escaping (ClipboardItem) -> Void,
                onDelete: @escaping (ClipboardItem) -> Void) {
        self.manager = manager
        self.scrollProxy = scrollProxy
        self.isActive = isActive
        self.onCopy = onCopy
        self.onEdit = onEdit
        self.onSummarize = onSummarize
        self.onDelete = onDelete
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(owner: self)
    }

    /// 行卡之间的呼吸间距（v92 用户反馈「卡片之间距离过近」）：
    /// 卡片列表的观感关键——6pt 时卡卡贴边显得拥挤，10pt 拉开层次仍紧凑；
    /// 与行高档位解耦（密度变化时间距恒定，节奏不跳）。
    // v156：0 → 3。行高亮改成「内缩 6pt 的圆角块」后，相邻两行的色块会贴在一起；
    // 3pt 间隙让它们读作两个独立的 pill，同时不会像 v152 的 17pt 那样只剩 4 行。
    private static let rowGap: CGFloat = 3

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClipboardListScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // 底部悬浮工具条会盖住最后一条：留出滚动内边距，让末尾卡片能滚到条上方
        scrollView.automaticallyAdjustsContentInsets = false
        // v92（2026-10-20 用户：「卡片之间距离过近，注意 UI 设计」）：
        // 顶部给 4pt 呼吸（列表不顶到日历卡），底部 52pt 仍留给悬浮工具条
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 52, right: 0)

        let table = ClipboardTableView()
        table.isActive = isActive && !context.environment.isSettingsPreview
        table.headerView = nil
        table.rowHeight = Theme.statsRowHeight
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        // 行卡间距：6pt 太挤（卡片贴卡片）——统一 10pt（见 rowGap 常量）
        table.intercellSpacing = NSSize(width: 0, height: Self.rowGap)
        table.gridStyleMask = []
        table.style = .fullWidth
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard.items"))
        // v91（2026-10-20 用户：「日历与剪贴板没有统一宽度」）：行卡宽度 = 列宽，
        // 列必须钉死随表宽走（默认 uniform 分栏会让单列略窄于表宽 → 行卡比日历卡窄几 pt）
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        column.width = table.bounds.width
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
        // 页面激活状态同步（非主页时表格移除 hover 追踪，防幽灵预览）
        (nsView.documentView as? ClipboardTableView)?.isActive = isActive && !context.environment.isSettingsPreview
        // v66 个性化：密度档位变更 → 行高/间距即时生效
        let table = nsView.documentView as? ClipboardTableView
        let newHeight = Theme.statsRowHeight
        if table?.rowHeight != newHeight {
            table?.rowHeight = newHeight
            table?.intercellSpacing = NSSize(width: 0, height: Self.rowGap)
        }
        // v91：宽度随表走（行卡与日历卡同宽的最后一环）
        // v101 性能审计：updateNSView 此前无条件全表 reload（滑动卡顿总放大器）
        table?.sizeLastColumnToFit()
        context.coordinator.reloadTableIfNeeded()
    }

    // MARK: Coordinator（DataSource + Delegate + 交互仲裁）

    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        /// 上次显示的条目用于刷新内容，并在重排时保留选中项。
        private var displayedItems: [ClipboardItem] = []
        private var lastRowHeight: CGFloat = 0

        /// 条目内容或行高变化时刷新。
        func reloadTableIfNeeded() {
            let height = Theme.statsRowHeight
            guard owner.manager.items != displayedItems || height != lastRowHeight else { return }
            reloadTable()
            displayedItems = owner.manager.items
            lastRowHeight = height
        }

        fileprivate var owner: ClipboardTableHostView
        private weak var scrollView: NSScrollView?
        private weak var table: ClipboardTableView?
        private weak var proxy: ClipboardTableScrollProxy?

        // 交互族状态
        let topTracker = ClipboardListTopScrollTracker()
        let hoverSuppression = ClipboardRowHoverSuppressionController()
        private var hoveredRowView: RowHostingView?
        private var hoveredItemID: String?
        /// 行号 → 行视图弱引用（view-based NSTableView 的视图层级不可用于反查，见 viewFor 注释）
        private var rowViewsByRow: [Int: WeakRowBox] = [:]
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
            // v102：底部「回到顶部」按钮经通知触发（代理在别处持有）
            NotificationCenter.default.addObserver(
                forName: .frsetClipboardScrollTop, object: nil, queue: .main
            ) { [weak proxy] _ in proxy?.scrollToTop() }

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
                                  frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: Theme.statsRowHeight))
            host.identifier = identifier
            host.row = row

            host.contentBuilder = { [weak self] item, hovered in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(ClipboardRow(
                    item: item,
                    isHighlighted: hovered,
                    onCopy: { self.owner.onCopy(item) },
                    onEdit: { self.owner.onEdit(item) },
                    onSummarize: { self.owner.onSummarize(item) }
                ))
            }
            host.onSingleClick = { [weak self] item in self?.handleSingleClick(item) }
            host.onDoubleClick = { [weak self] item in self?.handleDoubleClick(item) }
            host.onModifierClick = { [weak self] row, shift in self?.handleModifierClick(row: row, shift: shift) }
            host.onPlainMouseDown = { [weak self] row, event in self?.handlePlainMouseDown(row: row, event: event) }
            host.onRightMouseDown = { [weak self] item, location, sourceView in
                // 右键按下即弹菜单（specs/14 §3.2/C4）；菜单打开期间抑制 hover
                self?.hoverSuppression.suppressUntilMouseMove()
                let selection = self?.table?.selectedRowIndexes.compactMap { self?.owner.manager.items[$0] } ?? []
                ClipboardNativeMenuPresenter.shared.presentMenu(for: item, at: location, in: sourceView, selectedItems: selection)
            }
            host.setItem(item, hovered: (item.id == hoveredItemID))
            // v129（内存）：移除 WidthAudit 调试日志（v112 宽度实证残留）——
            // 每次 viewFor（滚动/刷新每可见行一次）都做字符串格式化+落盘。
            // 行号侧表登记（修复 C2）：view-based NSTableView 会把 delegate 返回的视图
            // 包进 NSTableRowView，table.subviews 的直接子元素是 NSTableRowView 而非
            // RowHostingView，按 subviews 强转恒为 nil。故按行号侧记，弱引用防泄漏。
            rowViewsByRow[row] = WeakRowBox(host)
            return host
        }

        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // 行高（原版实测 400 宽面板）：缩略图 50 + 上下留白 ≈ 68pt 行内容 + 8pt 行距
            Theme.statsRowHeight
        }

        /// 行容器：接管系统选中绘制（见 ClipboardRowChromeView 注释）
        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            ClipboardRowChromeView()
        }

        public func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            // 分页加载：尾行进入视口 → loadMoreIfNeeded
            // （顺序表刷新挂预览协调器，specs/12 F8 __pendingPreviewPaginationRequest 对接点）
            // v101：仅尾行附近触发分页（此前每行入视口都调）
            let count = owner.manager.items.count
            guard row < count, row >= count - 3 else { return }
            owner.manager.loadMoreIfNeeded(currentItem: owner.manager.items[row])
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            if owner.isSettingsPreview { return }
            if let table {
                for (row, box) in rowViewsByRow {
                    box.view?.setHovered(table.selectedRowIndexes.contains(row) || (owner.manager.items.indices.contains(row) && owner.manager.items[row].id == hoveredItemID))
                }
            }
            // 选中项广播（工具条编辑/上传按钮消费；键盘/鼠标/重载都会经过这里）
            if let table, table.selectedRow >= 0, table.selectedRow < owner.manager.items.count {
                NotificationCenter.default.post(name: .clipboardSelectionChanged,
                                                object: owner.manager.items[table.selectedRow])
            } else {
                NotificationCenter.default.post(name: .clipboardSelectionChanged, object: nil)
            }
            // 选择移动 → 取消未决键盘预览（specs/12 F6）。
            // **仅限键盘导航导致**：方向键移动选择后，旧的空格预览 WorkItem 不该再弹。
            // 鼠标点击与 reloadData 导致的选中变化不取消：
            //  - 鼠标点击：单击/双击走presentPreview/复制，其内部已调用 cancelKeyboardPreview
            //    （MainPanelPreviewPopoverCoordinator.swift:164），此处再取消是重复动作；
            //  - reloadData：捕获到新内容会重建选中态，若在此取消，用户刚按下的空格
            //    预览会被静默吞掉（0.30s 延时窗口内），且无任何提示。
            guard table?.isKeyboardNavigating == true else { return }
            multiAnchor = table?.selectedRow ?? -1
            ServiceLocator.panelPreview?.cancelKeyboardPreview()
        }

        // MARK: 数据刷新（锚定滚动：新条目置顶不打断浏览）

        func reloadTable() {
            guard let table, let scrollView else { return }
            let items = owner.manager.items
            let previousSelection = table.selectedRowIndexes
            let selectedIDs = Set(previousSelection.compactMap { row in
                displayedItems.indices.contains(row) ? displayedItems[row].id : nil
            })
            let anchorID = displayedItems.indices.contains(multiAnchor) ? displayedItems[multiAnchor].id : nil
            let previousFirstVisibleRow = table.row(at: NSPoint(x: 0, y: scrollView.contentView.documentVisibleRect.minY + 1))
            let previousAnchorID: String? = displayedItems.indices.contains(previousFirstVisibleRow)
                ? displayedItems[previousFirstVisibleRow].id : nil
            let previousTopGap: CGFloat = previousFirstVisibleRow >= 0
                ? table.rect(ofRow: previousFirstVisibleRow).minY - scrollView.contentView.documentVisibleRect.minY
                : 0

            table.reloadData()
            let selection = IndexSet(items.indices.filter { selectedIDs.contains(items[$0].id) })
            table.selectRowIndexes(selection, byExtendingSelection: false)
            // 行号未变时 AppKit 不发送选择变化，工具条仍需收到更新后的条目。
            if selection == previousSelection {
                tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
            }
            multiAnchor = items.firstIndex(where: { $0.id == anchorID }) ?? -1
            // reloadData 后按行号裁剪侧表，**不做整体清空**。
            // 原因：reloadData() 可能同步触发可见行的 tableView(_:viewFor:row:) 重新登记，
            // 整体 removeAll() 会把刚登记好的新映射一并抹掉 → 预览锚点退化 + hover 高亮失效，
            // 且因 AppKit display pass 时机而「时隐时现」（审计代理 v-a 勘误指出）。
            // 只裁掉「行号越界」与「视图已被回收」两类条目：前者是条目删除后的残留，
            // 后者由 weak 引用自然变 nil（残留条目只会查得 nil，不会给出错误视图），
            // 一并清掉可避免字典无限增长——这正是整体 removeAll() 原本的唯一收益。
            let validRows = Set(0..<table.numberOfRows)
            rowViewsByRow = rowViewsByRow.filter { validRows.contains($0.key) && $0.value.view != nil }
            hoveredRowView = nil
            // hoveredItemID 必须与 hoveredRowView 同步清空：若只清视图而保留 ID，
            // 下一次 mouseMoved 会因「item.id == hoveredItemID」提前 return（见 handleMouseMoved
            // 的同条目短路），导致刷新后原位置永久失去高亮。两者同清，下次鼠标移动即重建高亮。
            hoveredItemID = nil

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

        /// 滚动 → 顶部迟滞 tracker（specs/14 Q④）。
        /// 语义：以**首行（row 0）**在内容坐标系中的位置与 clipView 视口原点比较，
        /// 判定首行是否已完全滚出视口上沿。不可用「首个可见行」——那个值恒≈0，永远触发不了。
        private func feedTopTracker() {
            guard let scrollView, let table, table.numberOfRows > 0 else {
                topTracker.feed(firstRowMinY: nil, firstRowHeight: 0, viewportOriginY: 0)
                return
            }
            let firstRect = table.rect(ofRow: 0)
            topTracker.feed(firstRowMinY: Double(firstRect.minY),
                            firstRowHeight: Double(firstRect.height),
                            viewportOriginY: Double(scrollView.contentView.bounds.minY))
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

        /// 行号 → 行视图（走侧表；视图已被复用池回收时返回 nil）
        private func rowView(at row: Int) -> RowHostingView? {
            guard row >= 0, row < owner.manager.items.count else { return nil }
            return rowViewsByRow[row]?.view
        }

        // MARK: 行点击语义（specs/14 §3.7 / C11）

        /// 修复 C11：行视图不透传 super，AppKit 不会走 NSTableView 的默认选中路径，
        /// 且 RowHostingView.acceptsFirstMouse=true 会抢走 first responder。
        /// 这里一次做完两件事，使空格/↩ 真正可用：
        /// ① 显式选中 → table.selectedRow 成立（handleSpaceKey/handleReturnKey 的门槛）；
        /// ② 把表格设为 first responder → 空格/↩ 能路由到 ClipboardTableView.keyDown。
        private func handlePlainMouseDown(row: Int, event: NSEvent) {
            guard let table, row >= 0, row < table.numberOfRows else { return }
            if event.modifierFlags.intersection([.command, .shift]).isEmpty {
                // 注：老的 selectRow(_:byExtendingSelection:) 在 Swift 中已 unavailable，
                // 用官方替代 API selectRowIndexes(_:byExtendingSelection:)。
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                multiAnchor = row
                // 点击的行必然已在视口内（用户刚点到它），此处不调scrollRowToVisible，
                // 避免在点击时产生额外跳动。
            }
            // 键盘归属：行视图 acceptsFirstMouse=true 会在点击后成为 first responder，
            // 此时 keyDown 走的是 NSHostingView 而非表格 → 空格/↩ 收不到。显式夺回。
            // FloatingPanel.canBecomeKey = true（Panel/FloatingPanel.swift:59），故此调用有效。
            if table.window?.firstResponder !== table {
                table.window?.makeFirstResponder(table)
            }
        }

        /// 一次性交互提示（specs/14 §3.7：提示文案 cstring `0xb43d70` "双击条目可复制" /
        /// `0xb43da0` "单击条目可预览"）。⚠️ 原作对应的 defaults 键名未探明（specs/14 §7），
        /// 此处按工程既有键名风格自拟，语义为「该提示已消费」。
        private static let singleClickPreviewHintKey = "hasSeenClipboardSingleClickPreviewHint"
        private static let doubleClickCopyHintKey = "hasSeenClipboardDoubleClickCopyHint"

        /// 首次触发时消费一次性提示键，返回是否需要展示
        private func consumeOneTimeHint(_ key: String) -> Bool {
            let preferences = Preferences.shared
            if preferences.value(key, default: false) { return false }
            preferences.set(key, true)
            return true
        }

        private func anchorProvider(for view: NSView?) -> () -> CGRect? {
            { [weak view] in
                guard let view, view.window != nil else { return nil }
                return view.convert(view.bounds, to: nil)
            }
        }

        private func handleSingleClick(_ item: ClipboardItem) {
            // 工具条操作目标 = 最后点击项（单击走预览路径不产生标准选中，
            // 2026-10-18：编辑/上传按钮据此启用）
            NotificationCenter.default.post(name: .clipboardSelectionChanged, object: item)
            // 单击与悬停共用当前预览窗；换条目由呈现入口连续调整尺寸。
            if consumeOneTimeHint(Self.singleClickPreviewHintKey) {
                Toast.show("单击条目打开预览窗", icon: "eye")
            }
            // v182（用户：「不要点开后常驻、带两个叉的框」）：
            // 单击改走与 hover 同一条轻量预览路径（无标题栏、移出即关）。
            // 常驻窗（.persistent）不再从这里产生。
            let row = rowView(forItemID: item.id)
            _ = ServiceLocator.panelPreview?.presentPreview(
                for: item,
                anchorRectInWindow: row.map { $0.convert($0.bounds, to: nil) },
                anchorView: row,
                isFloatingSource: false)
        }

        private func handleDoubleClick(_ item: ClipboardItem) {
            // 双击 = 复制（预览程序化关闭）
            ServiceLocator.panelPreview?.dismissPreview()
            if consumeOneTimeHint(Self.doubleClickCopyHintKey) {
                // 原作此处除提示外还有复制成功 toast（copy() 内部已发），故不重复发
                Log.info("clipboard", "首次双击条目：已提示「双击条目可复制」")
            }
            owner.onCopy(item)
        }

        private func handleSpaceKey() {
            // 诊断（临时）：入口打全量状态，一次区分三道门哪个挂了
            // ⚠️ 诊断点，非行为变更，不计入对照差异。注意不能引用下方才声明的 item，
            //    故此处按行号安全取 id。
            let row = table?.selectedRow ?? -1
            let rowID = owner.manager.items.indices.contains(row) ? owner.manager.items[row].id : "<none>"
            Log.info("clipboard", "space → selectedRow=\(row) "
                + "firstResponder=\(String(describing: table?.window?.firstResponder)) "
                + "rowView=\(rowView(forItemID: rowID) != nil)")
            guard let table, table.selectedRow >= 0, table.selectedRow < owner.manager.items.count else { return }
            let item = owner.manager.items[table.selectedRow]
            let view = rowView(forItemID: item.id)
            ServiceLocator.panelPreview?.requestKeyboardPreview(item: item,
                                                                anchorRectProvider: anchorProvider(for: view))
        }

        /// 范围选择的起点；选中集合由表格统一持有。
        private var multiAnchor: Int = -1

        /// ⌘=toggle 该行加选；⇧=从锚点范围加选。同步 table.selectedRowIndexes 供键盘/复制用。
        private func handleModifierClick(row: Int, shift: Bool) {
            guard let table, row >= 0, row < owner.manager.items.count else { return }
            table.toggleRowSelection(row: row, shift: shift, anchor: &multiAnchor)
            hoverSuppression.suppressUntilMouseMove()   // 多选期间不弹 hover 预览
            clearHoverHighlight()
        }

        private func handleReturnKey() {
            // 诊断（临时）：↩ 只依赖 selectedRow + first responder（不依赖锚点），
            // 是二分判据的干净探针——与space 的 rowView= 值对比即可定位失败层。
            let row = table?.selectedRow ?? -1
            Log.info("clipboard", "return → selectedRow=\(row) "
                + "firstResponder=\(String(describing: table?.window?.firstResponder))")
            guard let table, table.selectedRow >= 0, table.selectedRow < owner.manager.items.count else { return }
            // 多选批量复制（原版「已复制 %d 项」）：⌘/⇧ 点击 ≥2 条后按 ↩ 一次性写入剪贴板
            if table.selectedRowIndexes.count > 1 {
                let items = table.selectedRowIndexes.compactMap { idx in
                    idx < owner.manager.items.count ? owner.manager.items[idx] : nil
                }
                if let reason = owner.manager.copy(items) {
                    Toast.show(reason, icon: "exclamationmark.triangle", isWarning: true)
                }
                ServiceLocator.panelPreview?.dismissPreview()
                return
            }
            let item = owner.manager.items[table.selectedRow]
            ServiceLocator.panelPreview?.dismissPreview()
            owner.onCopy(item)
        }

        private func rowView(forItemID itemID: String) -> NSView? {
            guard let row = owner.manager.items.firstIndex(where: { $0.id == itemID }) else { return nil }
            return rowView(at: row)
        }
    }
}

// MARK: - 原生右键菜单（specs/14 §2.2：ClipboardNativeMenuPresenter / ClipboardMenuActionItem）

/// 右键按下即呈现的原生 NSMenu（AppKit 层，替代 SwiftUI contextMenu 的延迟语义）
public final class ClipboardNativeMenuPresenter: NSObject {

    public static let shared = ClipboardNativeMenuPresenter()

    // v129（内存）：菜单符号静态缓存——每次右键都为 ~8 个固定菜单项重建
    // NSImage(systemSymbolName:)（CoreSVG 解码，heap：SVGAttribute/SVGPathCommand
    // 就是这批产物）。符号名固定，一次解码全局复用。
    private static let symbolCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 32
        return c
    }()

    private static func symbol(_ name: String) -> NSImage? {
        let key = name as NSString
        if let hit = symbolCache.object(forKey: key) { return hit }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        symbolCache.setObject(image, forKey: key)
        return image
    }

    public func presentMenu(for item: ClipboardItem, at location: CGPoint, in view: NSView,
                            selectedItems: [ClipboardItem] = []) {
        let menu = NSMenu()
        let manager = ClipboardManager.shared
        let tagStore = TagStore.shared
        let canSummarize = ClipboardSummaryExecutionCoordinator.shared.isAvailable

        func addItem(_ title: String, systemImage: String?, enabled: Bool = true, _ action: @escaping () -> Void) {
            let menuItem = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = BlockMenuItemAction(action)
            menuItem.isEnabled = enabled
            if let systemImage {
                menuItem.image = Self.symbol(systemImage)
            }
            menu.addItem(menuItem)
        }

        addItem("复制", systemImage: "doc.on.doc") { manager.copy(item) }
        for action in ClipboardContentActions.items(for: item) {
            addItem(action.title, systemImage: action.systemImage, action.action)
        }
        if !selectedItems.isEmpty {
            addItem("复制为编号清单…", systemImage: "list.number") {
                ServiceLocator.panelPreview?.dismissPreview()
                PanelController.shared.hide {
                    Task { @MainActor in RecentClipboardWindowController.shared.show(items: selectedItems, format: .numbered) }
                }
            }
        }
        // v112 空投联动（与 ClipboardRowMenuContent 的 SwiftUI 菜单同款）
        addItem("隔空投送", systemImage: "dot.radiowaves.left.and.right", enabled: item.airDropFileURL != nil) {
            if let url = item.airDropFileURL {
                NotificationCenter.default.post(name: .frsetAirDropFiles, object: nil,
                                                userInfo: ["urls": [url]])
            }
        }
        addItem("编辑", systemImage: "pencil") { ClipboardItemEditWindowRecord.open(for: item) }
        addItem("重命名", systemImage: "character.cursor.ibeam") { ClipboardItemEditWindowRecord.open(for: item) }
        addItem(item.isNote ? "取消笔记标记" : "标记为笔记", systemImage: "note.text") {
            manager.setNote(item, isNote: !item.isNote)
        }
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
            tagItem.image = Self.symbol("tag")   // v129（内存）：同上，符号缓存复用
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
