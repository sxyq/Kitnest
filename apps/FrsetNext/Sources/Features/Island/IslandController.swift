import AppKit
import Combine
import SwiftUI

/// 单一透明舞台，几何过渡与业务内容共用正式入口。
final class IslandController: NSObject, ObservableObject {
    static let shared = IslandController()
    let previewOnly: Bool
    let previewSessionID = UUID()
    var layoutDidChange: ((IslandConfiguration) -> Void)?
    var previewViewportChanged: ((CGSize) -> Void)?
    @Published private(set) var configuration: IslandConfiguration
    @Published var expanded = false {
        didSet { if expanded { showingContent = true } }
    }
    @Published private(set) var showingContent = false
    /// v270：正文独立透明度。外壳先起形（延后 80ms），正文再用 220ms 淡入；
    /// 收起时正文 120ms 先淡出，外壳 300ms 随后收拢——避免文字在窄剪裁区里被挤压。
    @Published private(set) var contentOpacity: CGFloat = 0
    @Published var page = IslandPage.home {
        didSet {
            if configuration.visiblePages.contains(oldValue) { returnPage = oldValue }
            if configuration.visiblePages.contains(page) {
                returnPage = page
                rememberPage(page)
            }
        }
    }
    private(set) var returnPage = IslandPage.home
    @Published var componentPage = 0
    /// v270：页面切换方向（+1 右→左、-1 左→右），只用于内容过渡的 12pt 横移。
    @Published private(set) var pageSlide = 0
    @Published private(set) var componentPageCount = 1
    @Published var selectedRecord: String?
    @Published var selectedTool: String?
    @Published var toolQuery = ""
    @Published var toolCategory: ToolCategory?
    @Published var clipboardTagID: String?
    @Published var showingClipboardFavoritesOnly: Bool
    @Published var previewVisible = true
    @Published var selectedMetric = IslandMetric.cpu
    @Published var selectedDate = Date.now
    var toolInputs: [String: String] = [:]
    private var recordScrollOffset = CGPoint.zero
    private weak var recordScrollView: NSScrollView?
    private var recordScrollObserver: NSObjectProtocol?
    @Published private(set) var layoutDraft: IslandConfiguration?
    @Published var playing = false
    @Published var volume = 56.0
    @Published var track = 0
    @Published var seek = 86.0
    @Published var completedEvents = Set<Int>()
    let tracks = [("Quiet Hours", "Lo-fi Session"), ("Blue Afternoon", "Studio Sessions"), ("Night Walk", "Ambient Notes")]
    @Published var feedback = "左右滑动切页 · 编辑布局可调整组件"
    @Published private(set) var clipboardSummary = "暂无内容"
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var notchHeight: CGFloat = 0
    private(set) var panel: IslandPanel?
    @Published private(set) var activeDisplayID: String?
    private var entries: [String: NSPanel] = [:]
    private var displays: [IslandDisplay] = []
    private var entryHoverID: String?
    private var revealedEntryID: String?
    private var entryHoverWork: DispatchWorkItem?
    private var spaceObserver: NSObjectProtocol?
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var inside = false
    private var hoverArmed = true
    /// 「明确固定打开」：用户点了入口/深链/搜索聚焦这类**明确意图**才置位，
    /// 只有 collapse() 解除。
    private var openedExplicitly = false
    /// v286（审计包 02）：「点击期间保护」——在岛面板里按下鼠标时临时置位，
    /// `endInteraction()`（抬起/菜单/编辑结束）即解除。旧实现把普通点击也写成
    /// `openedExplicitly = true` 且抬起不清除，点一下组件后鼠标移开会一直展开。
    private var clickPinned = false
    /// 收起调度统一看的「是否被意图钉住」。
    private var pinnedOpen: Bool { openedExplicitly || clickPinned }
    private var screenObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTracking = false
    private var visibleSize = CGSize.zero
    private var visibleRadius: CGFloat = 0
    private var visibleOutline = Path()
    private var interacting = false
    private var horizontalScroll: CGFloat = 0
    private var didSwipe = false
    private var afterCollapse: (() -> Void)?
    /// v292 A2：选区结果改为 @Published——异步读取完成时可能没有其他状态变化，
    /// 必须靠它自身触发岛视图刷新（原同步赋值搭 expanded/showingContent 的顺风车）。
    @Published private(set) var selection: AppBootstrap.SelectionResult?
    /// v292 A2：选区异步读取的代次（每次展开递增；旧代次结果回到主线程时直接丢弃）
    private var selectionGeneration = 0

    init(configuration: IslandConfiguration = .load(), previewOnly: Bool = false) {
        self.configuration = configuration
        self.showingClipboardFavoritesOnly = configuration.clipboardFavoritesOnly
        self.previewOnly = previewOnly
        self.displays = IslandDisplay.enabled(for: configuration)
        super.init()
        updateNotchMetrics()
        if previewOnly { selectedDate = SettingsPreviewSamples.date }
    }

    var usesGlass: Bool { configuration.effectiveMaterial != .solid }
    var contentVisible: Bool { expanded || showingContent }
    var visiblePeeks: Set<IslandPeek> { configuration.visiblePeeks }
    var peeksShowValues: Bool { configuration.peeksShowValues }
    var peeksQuickActions: Bool { configuration.peeksQuickActions }
    var glowEnabled: Bool { configuration.glowEnabled }
    var widgetOrder: [IslandWidget] { layoutConfiguration.widgetOrder }
    var editingLayout: Bool { layoutDraft != nil }
    var layoutConfiguration: IslandConfiguration {
        var value = configuration
        if let draft = layoutDraft {
            value.widgetSizes = draft.widgetSizes
            value.widgetPositions = draft.widgetPositions
            value.widgetOrder = draft.widgetOrder
            value.hiddenWidgets = draft.hiddenWidgets
        }
        if page == .custom {
            value.widgetOrder = configuration.customWidgetOrder
                + IslandWidget.allCases.filter { !configuration.customWidgetOrder.contains($0) }
            value.hiddenWidgets = Set(IslandWidget.allCases).subtracting(configuration.customWidgetOrder)
            value.widgetSizes = configuration.customWidgetSizes
            value.widgetPositions = configuration.customWidgetPositions
            if let draft = layoutDraft {
                value.widgetOrder = draft.customWidgetOrder
                    + IslandWidget.allCases.filter { !draft.customWidgetOrder.contains($0) }
                value.hiddenWidgets = Set(IslandWidget.allCases).subtracting(draft.customWidgetOrder)
                value.widgetSizes = draft.customWidgetSizes
                value.widgetPositions = draft.customWidgetPositions
            }
        }
        return value
    }
    var metricOrder: [IslandMetric] {
        get { configuration.metricOrder }
        set {
            var next = configuration
            next.metricOrder = newValue
            if let reason = apply(next) { feedback = reason }
            else { layoutDidChange?(next) }
        }
    }
    var peekOrder: [IslandPeek] { configuration.peekOrder }
    var displayScreen: NSScreen {
        displays.first { $0.id == activeDisplayID }?.screen ?? displays.first?.screen ?? NSScreen.screens[0]
    }
    var effectiveWidth: CGFloat { min(max(configuration.width, configuration.minimumWidth), displayScreen.frame.width - 40) }
    var effectiveHeight: CGFloat { min(max(configuration.height, configuration.minimumHeight), displayScreen.frame.height - 40) }
    var layoutColumns: Int {
        min(page == .custom ? configuration.customColumns : configuration.columns,
            max(1, Int((effectiveWidth - IslandLayout.horizontalInset * 2 + 8) / 152)))
    }
    var layoutRows: Int {
        min(page == .custom ? configuration.customRows : configuration.rows,
            max(1, Int((effectiveHeight - 176 + 8) / 120)))
    }

    // v270（参考 NotchKit motion.md）：展开只给外壳适度弹性，收起单调退场。
    // 旧的 0.46/0.94 全程高阻尼＋内容同步渐显，观感「笨重」；0.28/1 收起会在末端顿一下。
    func surfaceAnimation(reduceMotion: Bool) -> Animation? {
        if previewOnly && !previewVisible { return nil }
        guard !reduceMotion else { return .easeOut(duration: 0.12) }
        return expanded ? .spring(response: 0.42, dampingFraction: 0.80)
                        : .smooth(duration: 0.30)
    }

    private var hidesCollapsedSurface: Bool {
        displayScreen.safeAreaInsets.top == 0 || visiblePeeks.isEmpty
    }

    @discardableResult
    func apply(_ configuration: IslandConfiguration) -> String? {
        var configuration = configuration
        if configuration.hiddenPages.count >= IslandPage.tabs.count { configuration.hiddenPages.remove(.home) }
        if !configuration.visiblePages.contains(configuration.fixedPage) {
            configuration.fixedPage = configuration.visiblePages[0]
        }
        configuration.lastPageByDisplay = configuration.lastPageByDisplay.mapValues {
            configuration.visiblePages.contains($0) ? $0 : configuration.visiblePages[0]
        }
        if !previewOnly {
            do { try configuration.persist() }
            catch { return "刘海设置保存失败：\(error.localizedDescription)" }
        }
        let favoritesDefaultChanged = self.configuration.clipboardFavoritesOnly != configuration.clipboardFavoritesOnly
        self.configuration = configuration
        if favoritesDefaultChanged {
            showingClipboardFavoritesOnly = configuration.clipboardFavoritesOnly
        }
        if !configuration.visiblePages.contains(page) { page = configuration.visiblePages[0] }
        if !previewOnly {
            if configuration.enabled { start() } else { stop() }
        }
        return nil
    }

    func beginLayoutEditing() {
        if let panel, MainPanelPreviewPopoverCoordinator.shared.hasPreview(from: panel) {
            MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .programmatic)
        }
        layoutDraft = configuration
        beginInteraction()
        feedback = "拖动组件调整位置 · 右下角调整尺寸"
    }

    func updateLayout(_ value: IslandConfiguration) {
        var draft = layoutDraft ?? configuration
        if page == .custom {
            draft.customWidgetOrder = value.widgetOrder.filter { !value.hiddenWidgets.contains($0) }
            draft.customWidgetSizes = value.widgetSizes
            draft.customWidgetPositions = value.widgetPositions ?? [:]
        } else {
            draft.widgetOrder = value.widgetOrder
            draft.widgetSizes = value.widgetSizes
            draft.widgetPositions = value.widgetPositions
            draft.hiddenWidgets = value.hiddenWidgets
        }
        layoutDraft = draft
    }

    func finishLayoutEditing() {
        let next = layoutDraft ?? configuration
        if let reason = apply(next) { feedback = reason; HapticService.shared.perform(.operationFailed); return }
        layoutDraft = nil
        layoutDidChange?(next)
        feedback = previewOnly ? "布局已更新到设置草稿，保存后应用" : "布局已保存"
        if !previewOnly { HapticService.shared.perform(.layoutSaved) }
        endInteraction()
    }

    func cancelLayoutEditing() {
        layoutDraft = nil
        feedback = "已取消布局调整"
        endInteraction()
    }

    func setWidgetVisible(_ widget: IslandWidget, visible: Bool) {
        var next = layoutConfiguration
        if visible { next.hiddenWidgets.remove(widget) }
        else { next.hiddenWidgets.insert(widget) }
        updateLayout(next)
    }

    func beginInteraction() { interacting = true; hoverWork?.cancel(); hoverWork = nil }
    func endInteraction() {
        if editingLayout { return }
        interacting = false
        // v286：点击保护到抬起为止。清除后按当前位置重新判定是否该收，
        // 普通组件点击不再把展开状态永久锁住。
        clickPinned = false
        if previewOnly { return } // 模拟场景没有真实指针，不进入移开收回计时。
        if menuTracking || editingText { return }
        updatePointer()
        if !inside, expanded, !pinnedOpen, entryHoverWork == nil {
            // v286：先清掉可能过期的旧延时（比如悬停展开腿），再排收起，
            // 避免同一时刻既有 expand 又有 collapse 两个 work 竞争。
            hoverWork?.cancel()
            hoverWork = nil
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
        }
    }

    var collapsedWidth: CGFloat {
        let placement = activeDisplayID.flatMap { configuration.peekPlacements[$0] } ?? .both
        let left = placement == .left ? visiblePeeks.count : placement == .both ? (visiblePeeks.count + 1) / 2 : 0
        let right = placement == .right ? visiblePeeks.count : placement == .both ? visiblePeeks.count / 2 : 0
        return notchWidth + CGFloat(left + right) * (peeksShowValues ? 72 : 38)
    }

    func turnPage(_ step: Int) {
        if editingLayout { return }
        let pages = configuration.visiblePages
        let index = pages.firstIndex(of: page) ?? pages.firstIndex(of: returnPage) ?? 0
        pageSlide = step >= 0 ? 1 : -1
        selectPage(pages[(index + step + pages.count) % pages.count])
    }

    func turnComponentPage(_ step: Int) {
        componentPage = min(max(componentPage + step, 0), max(0, componentPageCount - 1))
    }

    func selectPage(_ requested: IslandPage, remember: Bool = true) {
        let page = configuration.visiblePages.contains(requested) ? requested : (configuration.visiblePages.first ?? .home)
        let pages = configuration.visiblePages
        if let from = pages.firstIndex(of: self.page), let to = pages.firstIndex(of: page), from != to {
            pageSlide = to > from ? 1 : -1
        }
        self.page = page
        returnPage = page
        if remember { rememberPage(page) }
    }

    func selectDeepLinkPage(_ requested: IslandPage) {
        if IslandPage.tabs.contains(requested) { selectPage(requested) }
        else { page = requested }
    }

    private func rememberPage(_ page: IslandPage) {
        guard !previewOnly, configuration.openingPageMode == .remember,
              IslandPage.tabs.contains(page),
              let activeDisplayID, configuration.lastPageByDisplay[activeDisplayID] != page else { return }
        var next = configuration
        next.lastPageByDisplay[activeDisplayID] = page
        do {
            try next.persist()
            configuration = next
        } catch {
            feedback = "页面记忆保存失败：\(error.localizedDescription)"
        }
    }

    private func applyOpeningPage() {
        let pages = configuration.visiblePages
        let candidate = configuration.openingPageMode == .fixed
            ? configuration.fixedPage
            : configuration.lastPageByDisplay[activeDisplayID ?? ""] ?? pages.first ?? .home
        selectPage(pages.contains(candidate) ? candidate : (pages.first ?? .home), remember: false)
    }

    func setComponentPageCount(_ count: Int) {
        if componentPageCount != count { componentPageCount = count }
        if componentPage >= count { componentPage = count - 1 }
    }

    func goBack() {
        selectPage(returnPage)
        feedback = "左右滑动切页 · 编辑布局可调整组件"
    }

    // MARK: 监测指标详情（v270）

    /// 详情页可切换的模块顺序：与 IslandMonitorFullContent 共用同一份，
    /// 避免「卡片点进去的指标」和「详情里排的顺序」两套。
    var monitorDetailOrder: [MonitorModuleID] {
        var order = metricOrder.compactMap { MonitorModuleID(rawValue: $0.rawValue) }
        let index = order.firstIndex(of: .power) ?? order.count
        order.insert(contentsOf: [.disk, .sensors], at: index)
        return order
    }

    /// 首页监测卡点击 → 直接打开该指标详情（不经过泛化面板）。
    func openMonitorDetail(_ metric: IslandMetric) {
        guard let module = MonitorModuleID(rawValue: metric.rawValue) else { return }
        selectedMetric = metric
        MonitorCenterPresenter.shared.monitorSelection.module = module
        if !expanded { expand(takeFocus: true, useOpeningPage: false) }
        pageSlide = 1
        page = .monitor          // page.didSet 会记录来源页；goBack() 回得去
        feedback = "左右切换指标 · Esc 返回上一页"
    }

    /// 详情内左右切换指标。作用域优先于整页切换。
    func stepMonitorDetail(_ step: Int) {
        let order = monitorDetailOrder
        guard !order.isEmpty else { return }
        let current = MonitorCenterPresenter.shared.monitorSelection.module
        let index = order.firstIndex(of: current) ?? 0
        let next = order[min(max(index + step, 0), order.count - 1)]
        guard next != current else { return }
        MonitorCenterPresenter.shared.monitorSelection.module = next
        if let metric = IslandMetric(rawValue: next.rawValue) { selectedMetric = metric }
    }

    /// 当前是否处在「指标详情」这类非 tab 页面（Esc 先返回，再收起）。
    var isInDetailPage: Bool { !IslandPage.tabs.contains(page) }

    func resumeAfterOutside() { open() }

    func bindRecordScroll(_ scrollView: NSScrollView) {
        if recordScrollView === scrollView { return }
        releaseRecordScroll()
        recordScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        let offset = recordScrollOffset
        DispatchQueue.main.async { [weak scrollView] in
            scrollView?.contentView.setBoundsOrigin(offset)
            if let scrollView { scrollView.reflectScrolledClipView(scrollView.contentView) }
        }
        recordScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView, queue: .main) { [weak self, weak scrollView] _ in
                if let scrollView { self?.recordScrollOffset = scrollView.contentView.bounds.origin }
            }
    }

    func releaseRecordScroll() {
        if let recordScrollObserver { NotificationCenter.default.removeObserver(recordScrollObserver) }
        recordScrollObserver = nil
        recordScrollView = nil
    }

    func changeTrack(_ step: Int) {
        track = (track + step + tracks.count) % tracks.count
        seek = 0
    }

    private func refreshClipboard() {
        if previewOnly { clipboardSummary = IslandSample.clipboard[0].title; return }
        // v292（性能第二轮 A3）：优先复用 ClipboardManager 的内存快照（items 随捕获实时
        // reload、最新在头部），不再每次展开同步查一次 SQLite。
        // 快照受搜索/筛选影响 → 只有在默认过滤态才用它；否则回退查库保持语义。
        // 快照为空（启动后尚未加载成功）同样回退。
        let manager = ClipboardManager.shared
        let snapshotUsable = manager.searchText.isEmpty && manager.filter == .all && manager.tagFilterID == nil
        let cached = snapshotUsable ? manager.items.first?.displayTitle : nil
        let title = cached ?? ClipboardRepository.shared.fetch(ClipboardQuery(limit: 1)).first?.displayTitle
        let summary = String((title ?? "暂无内容").prefix(24)).replacingOccurrences(of: "\n", with: " ")
        if clipboardSummary != summary { clipboardSummary = summary }
    }

    func copyLatest() {
        if previewOnly { feedback = "预览：已复制近期内容"; return }
        guard let item = ClipboardRepository.shared.fetch(ClipboardQuery(limit: 1)).first else {
            feedback = "暂无近期内容"
            Toast.show(feedback, icon: "doc.on.clipboard", isWarning: true)
            return
        }
        feedback = ClipboardManager.shared.copy(item, autoPaste: false) ?? "已复制近期内容"
    }

    func copyDate() {
        let value = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        feedback = previewOnly ? "预览：已复制日期" : ClipboardManager.shared.copyText(value, successMessage: "已复制日期 \(value)") ?? "已复制日期 \(value)"
    }

    func activatePeek(_ peek: IslandPeek) {
        if peeksQuickActions {
            switch peek {
            case .clipboard: copyLatest()
            case .media:
                if previewOnly { playing.toggle() }
                else {
                    Task { @MainActor in
                        let player = NowPlayingController.shared
                        if player.snapshot.available { player.send(player.snapshot.isPlaying ? 1 : 0) }
                        else {
                            feedback = "没有正在播放的媒体"
                            Toast.show(feedback, icon: "music.note", isWarning: true)
                        }
                    }
                }
            case .calendar: copyDate()
            case .monitor: page = .monitor; expand(takeFocus: true, useOpeningPage: false)
            }
        } else {
            page = peek.page
            expand(takeFocus: true, useOpeningPage: false)
        }
    }

    func surfaceDidChange(size: CGSize, radius: CGFloat) {
        guard size != visibleSize || radius != visibleRadius else { return }
        visibleSize = size
        visibleRadius = radius
        visibleOutline = IslandOutline(radius: radius).path(in: CGRect(origin: .zero, size: size))
        previewViewportChanged?(size)
        updatePointer()
        if !expanded, size == CGSize(width: collapsedWidth, height: notchHeight) {
            let action = afterCollapse
            afterCollapse = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.expanded, self.visibleSize == size else { return }
                self.showingContent = false
                if !self.previewOnly {
                    self.position(collapsed: true)
                    self.panel?.resignKey()
                    if self.hidesCollapsedSurface { self.panel?.orderOut(nil) }
                    self.refreshEntries()
                    self.entryHoverID = nil
                    self.updatePointer(pointerMoved: true)
                }
                action?()
            }
        }
    }

    func performOutside(_ action: @escaping () -> Void) {
        if previewOnly { feedback = "操作预览"; return }
        guard expanded else { action(); return }
        afterCollapse = action
        collapse()
    }

    func start() {
        guard !previewOnly, configuration.enabled else { return }
        show()
    }

    @objc func open() {
        openIsland(page: nil)
    }

    func open(page: IslandPage) {
        openIsland(page: page)
    }

    private func openIsland(page requestedPage: IslandPage?) {
        if !previewOnly {
            guard configuration.enabled else { ServiceLocator.settings?.open(pane: "island"); return }
            // 2026-11-23（需求 B：不随鼠标移动重新定位面板）：
            // 这里原来会把岛搬到「鼠标所在的屏」——打开位置跟着鼠标跑。
            // 现在打开保持在设置选定的屏幕上（displayScope + lastActiveDisplayID，
            // show() 内恢复），跨屏迁移只走该屏入口（updatePointer/点击，
            // 按 entryTriggers / hoverEnabled 设置门控），不跟鼠标漂移。
            show()
        }
        if let requestedPage { selectDeepLinkPage(requestedPage) }
        expand(takeFocus: true, useOpeningPage: requestedPage == nil)
    }

    private func show() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
        }
        displays = IslandDisplay.enabled(for: configuration)
        if !displays.contains(where: { $0.id == activeDisplayID }) {
            // v266：优先回到上次使用的屏幕，其次才是第一块可用屏。
            activeDisplayID = displays.first { $0.id == configuration.lastActiveDisplayID }?.id
                ?? displays.first?.id
        }
        guard activeDisplayID != nil else {
            panel?.orderOut(nil)
            for entry in entries.values { entry.orderOut(nil) }
            return
        }
        if panel == nil {
            let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.title = "Kitnest · 刘海工作台"
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isReleasedWhenClosed = false; p.acceptsMouseMovedEvents = true
            p.sharingType = .readOnly
            panel = p
            installMonitors()
            refreshClipboard()
            position(collapsed: !expanded && !showingContent)
            let hosting = NSHostingView(rootView: IslandRootView(controller: self))
            hosting.sizingOptions = []
            p.contentView = hosting
        } else { position(collapsed: !expanded && !showingContent) }
        if expanded || showingContent || !hidesCollapsedSurface { panel?.orderFrontRegardless() }
        else { panel?.orderOut(nil) }
        refreshEntries()
        updatePointer()
    }

    private func refreshDisplays() {
        if panel == nil { show(); return }
        displays = IslandDisplay.enabled(for: configuration)
        if let target = displays.first(where: { $0.id == activeDisplayID }) ?? displays.first {
            move(to: target)
        } else {
            hoverWork?.cancel(); hoverWork = nil
            entryHoverWork?.cancel(); entryHoverWork = nil
            panel?.orderOut(nil)
        }
        refreshEntries()
    }

    /// 入口窗的上次已应用状态（v292 A3）：旧实现每次 refreshEntries 都无条件
    /// setFrame/isHidden/ignoresMouseEvents/orderFront|orderOut——expand/collapse/move
    /// 路径里多次重复执行，产生不必要的 WindowServer 往返。现在只有真实变化的属性才动窗口。
    private struct EntryWindowState: Equatable {
        var frame: CGRect
        var contentHidden: Bool
        var ignoresMouse: Bool
        var onScreen: Bool
    }
    private var entryWindowStates: [String: EntryWindowState] = [:]

    private func refreshEntries() {
        let ids = Set(displays.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) {
            entries.removeValue(forKey: id)?.orderOut(nil)
            entryWindowStates.removeValue(forKey: id)
        }
        for display in displays {
            if entries[display.id] == nil {
                let entry = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                entry.title = "Kitnest · \(display.name) · 收起入口"
                entry.isOpaque = false; entry.backgroundColor = .clear; entry.hasShadow = false
                entry.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                entry.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                entry.isReleasedWhenClosed = false
                entry.contentView = IslandEntryView(hasNotch: display.hasNotch) { [weak self] in self?.activateDisplay(display.id) }
                entries[display.id] = entry
                entryWindowStates.removeValue(forKey: display.id)   // 新窗口：状态未知，首轮全部重放
            }
            guard let entry = entries[display.id] else { continue }
            let visibility = configuration.entryVisibilities[display.id] ?? (display.hasNotch ? .always : .event)
            let width = configuration.hotspotWidths[display.id] ?? 210
            let frame = display.entryFrame(hotspot: configuration.hotspots[display.id] ?? .center, width: width)
            let revealed = visibility != .hidden && (display.hasNotch || visibility == .always ||
                (visibility == .event && revealedEntryID == display.id)
            )
            let visible = display.hasNotch ? display.id != activeDisplayID
                : !(display.id == activeDisplayID && contentVisible)
            let newState = EntryWindowState(frame: frame, contentHidden: !revealed,
                                            ignoresMouse: !revealed, onScreen: visible)
            let old = entryWindowStates[display.id]
            if old?.frame != frame { entry.setFrame(frame, display: true) }
            if old?.contentHidden != newState.contentHidden { entry.contentView?.isHidden = newState.contentHidden }
            if old?.ignoresMouse != newState.ignoresMouse { entry.ignoresMouseEvents = newState.ignoresMouse }
            // 状态缓存失真的兜底：窗口被系统暂时隐藏时仍按需拉回前台。
            if old?.onScreen != visible || (visible && !entry.isVisible) {
                if visible { entry.orderFrontRegardless() } else { entry.orderOut(nil) }
            }
            entryWindowStates[display.id] = newState
        }
    }

    private func activateDisplay(_ id: String) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let hasPreview = panel.map { MainPanelPreviewPopoverCoordinator.shared.hasPreview(from: $0) } ?? false
        move(to: display)
        openedExplicitly = true
        expand(takeFocus: !hasPreview)
        if page == .search, !hasPreview {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .frsetFocusPanelSearch, object: nil)
            }
        }
    }

    /// 移动原窗口及预览会话，不经过会取消草稿的 collapse，也不替换 hosting view。
    private func move(to display: IslandDisplay) {
        hoverWork?.cancel(); hoverWork = nil
        entryHoverWork?.cancel(); entryHoverWork = nil
        entryHoverID = nil
        let oldFrame = panel?.frame ?? .zero
        let displayChanged = activeDisplayID != display.id
        activeDisplayID = display.id
        // v266：把「最后停留的屏幕」写进配置。多屏用户重启后回到原屏，
        // 不再固定弹到第一块屏幕（只在真正换屏时写，避免每次定位都落盘）。
        if displayChanged, configuration.lastActiveDisplayID != display.id {
            configuration.lastActiveDisplayID = display.id
            try? configuration.persist()
        }
        position(collapsed: !expanded && !showingContent)
        if let panel {
            MainPanelPreviewPopoverCoordinator.shared.movePreview(from: panel,
                by: CGSize(width: panel.frame.minX - oldFrame.minX, height: panel.frame.maxY - oldFrame.maxY),
                within: display.screen.visibleFrame)
            if expanded || showingContent || !hidesCollapsedSurface { panel.orderFrontRegardless() }
            else { panel.orderOut(nil) }
        }
        refreshEntries()
        updatePointer()
    }

    private func position(collapsed: Bool = false) {
        guard let panel else { return }
        let screen = displayScreen
        updateNotchMetrics()
        let centerX: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            centerX = (left.maxX + right.minX) / 2
        } else {
            switch configuration.hotspots[activeDisplayID ?? ""] ?? .center {
            case .left: centerX = screen.visibleFrame.minX + (effectiveWidth + 40) / 2
            case .center: centerX = screen.frame.midX
            case .right: centerX = screen.visibleFrame.maxX - (effectiveWidth + 40) / 2
            }
        }
        // 舞台保留当前动画所需范围，缩小时不提前裁掉正在收缩的外壳。
        let size = collapsed ? CGSize(width: collapsedWidth, height: notchHeight) :
            NSSize(width: min(max(panel.frame.width, effectiveWidth + 32, collapsedWidth + 32), screen.frame.width),
                   height: min(max(panel.frame.height, effectiveHeight + 16), screen.frame.height))
        let scale = screen.backingScaleFactor
        let frame = NSRect(x: ((centerX - size.width / 2) * scale).rounded() / scale,
                           y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if collapsed {
            visibleSize = size
            visibleRadius = IslandLayout.collapsedRadius
            visibleOutline = IslandOutline(radius: visibleRadius).path(in: CGRect(origin: .zero, size: size))
        }
    }

    private func updateNotchMetrics() {
        let screen = displayScreen
        let requestedWidth = configuration.hotspotWidths[activeDisplayID ?? ""] ?? 210
        let size = IslandDisplay(screen: screen)?.entrySize(hotspotWidth: requestedWidth)
            ?? CGSize(width: CGFloat(requestedWidth), height: 28)
        let width = size.width, height = size.height
        if notchWidth != width { notchWidth = width }
        if notchHeight != height { notchHeight = height }
    }

    func expand(takeFocus: Bool = false, useOpeningPage: Bool = true) {
        hoverWork?.cancel()
        hoverWork = nil
        openedExplicitly = openedExplicitly || takeFocus
        var expandStart: UInt64 = 0
        var stepMarks: [(label: String, nanos: UInt64)] = []
        let didExpand = !expanded
        if didExpand {
            // 2026-11-23 阶段计时：展开同步段到底花在哪（与主面板 布局=XXms 同口径）。
            // 只记毫秒，不动动画曲线（弹簧 0.42s/0.80 保持原值）。
            // v286：显示时钟探针在**同步段之前**起表——旧位置在首次布局之后，
            // 会漏掉「入口事件 → 首帧可见」那一段（审计包 02 指出的口径缺口）。
            // v292（性能第二轮 A1）：改为单调时钟分步计时、一行汇总；口径是「开窗准备
            // 各步骤的机器耗时」，不代表真实呈现。选区已异步化（A2），这里只记发起耗时。
            if !previewOnly { MotionPacingProbe.shared.run("岛展开", duration: 0.75) }
            let clock = { DispatchTime.now().uptimeNanoseconds }
            func mark(_ label: String) { stepMarks.append((label, clock())) }
            expandStart = clock()

            if useOpeningPage { applyOpeningPage() }
            mark("开页")
            if !previewOnly { beginSelectionRefresh() }
            mark("选区发起")
            refreshClipboard()
            mark("剪贴板")
            showingContent = true
            contentOpacity = 0
            mark("状态")
            if !previewOnly { position() }
            mark("定位")
            if !previewOnly { panel?.orderFrontRegardless() }
            mark("上屏")
            expanded = true
            revealedEntryID = nil
            if !previewOnly { refreshEntries() }
            mark("入口")
            revealContent(after: 0.08)
        }
        hoverArmed = false
        if takeFocus {
            panel?.makeKeyAndOrderFront(nil)
            if didExpand { stepMarks.append(("焦点", DispatchTime.now().uptimeNanoseconds)) }
        }
        if didExpand, !previewOnly {
            logExpandPhases(stepMarks, start: expandStart)
        }
    }

    /// v292（性能第二轮 A2）：岛展开的选区读取移到后台——外壳展开不再阻塞在三次同步 AX IPC 上。
    /// 触发时先固定前台应用上下文（纯本地查询）；完成后回主线程，代次不匹配就丢弃。
    /// 命令面板 / 划词路径仍走 AppBootstrap.readSelection() 同步读取，语义不变。
    private func beginSelectionRefresh() {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let capturedApp = AppBootstrap.frontmostForSelection()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let result = AppBootstrap.readSelection(in: capturedApp, messagingTimeout: 0.25)
            let costMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            DispatchQueue.main.async {
                guard let self, self.selectionGeneration == generation else { return }
                self.selection = result
                Log.info("Island", String(format: "岛展开·选区异步读取 %.0fms（不计入开窗准备）", costMs))
            }
        }
    }

    private func logExpandPhases(_ marks: [(label: String, nanos: UInt64)], start: UInt64) {
        guard !marks.isEmpty else { return }
        var parts: [String] = []
        var previous = start
        for mark in marks {
            let ms = Double(mark.nanos - previous) / 1_000_000
            parts.append(String(format: "%@ %.1f", mark.label, ms))
            previous = mark.nanos
        }
        let total = Double(previous - start) / 1_000_000
        Log.info("Island", "岛展开分段：\(parts.joined(separator: " · ")) · 合计 \(String(format: "%.1f", total))ms")
    }

    /// 延后淡入正文；期间再次收起会被 guard 拦下，不会把已收起的正文又点亮。
    private func revealContent(after delay: TimeInterval) {
        guard !previewOnly else { contentOpacity = 1; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.expanded else { return }
            withAnimation(.easeOut(duration: 0.22)) { self.contentOpacity = 1 }
        }
    }

    func collapse() {
        // 2026-11-23 阶段计时：同 expand()，只记同步段毫秒。
        // v286：显示时钟探针在同步段之前起表（同 expand 口径修正）。
        let t0 = CFAbsoluteTimeGetCurrent()
        let wasExpanded = expanded
        if wasExpanded, !previewOnly { MotionPacingProbe.shared.run("岛收起", duration: 0.45) }
        if editingLayout { cancelLayoutEditing() }
        if let panel, MainPanelPreviewPopoverCoordinator.shared.hasPreview(from: panel) {
            MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .panelCollapse)
        }
        hoverWork?.cancel()
        hoverWork = nil
        openedExplicitly = false
        clickPinned = false
        // 正文先退场（120ms），外壳再收（surfaceAnimation 300ms）。
        if !previewOnly { withAnimation(.easeOut(duration: 0.12)) { contentOpacity = 0 } }
        expanded = false
        entryHoverID = nil
        entryHoverWork?.cancel(); entryHoverWork = nil
        revealedEntryID = nil
        if !previewOnly { refreshEntries() }
        hoverArmed = false
        panel?.makeFirstResponder(nil)
        if wasExpanded, !previewOnly {
            Log.info("Island", String(format: "岛收起：首次布局 %.0fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
    }

    func stop() {
        entryHoverWork?.cancel(); entryHoverWork = nil; entryHoverID = nil; revealedEntryID = nil
        for entry in entries.values { entry.orderOut(nil) }
        entries.removeAll()
        displays.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        releaseRecordScroll()
        layoutDraft = nil
        collapse()
        panel?.orderOut(nil)
        for token in monitors { NSEvent.removeMonitor(token) }
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers.removeAll()
        screenObserver = nil
        panel = nil
    }

    private func installMonitors() {
        menuObservers = [
            NotificationCenter.default.addObserver(forName: ClipboardManager.itemsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshClipboard()
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.expanded, self.inside || self.panel?.isKeyWindow == true else { return }
                self.menuTracking = true
                self.beginInteraction()
            },
            NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.menuTracking else { return }
                self.menuTracking = false
                self.endInteraction()
            },
            NotificationCenter.default.addObserver(forName: NSText.didBeginEditingNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as? NSView)?.window === self.panel else { return }
                self.beginInteraction()
            },
            NotificationCenter.default.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, (note.object as? NSView)?.window === self.panel else { return }
                DispatchQueue.main.async { self.endInteraction() }
            },
            NotificationCenter.default.addObserver(forName: LanguageManager.languageDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            }
        ]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseUp { self?.endInteraction() }
            else { self?.updatePointer(pointerMoved: true) }
        } { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, let target = self.entry(at: NSEvent.mouseLocation) {
                self.activateDisplay(target.id); return
            }
            self?.updatePointer(at: event.locationInWindow, pointerMoved: true)
            if self?.inside == false, self?.menuTracking == false { self?.collapse() }
        } { monitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .leftMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, let target = self.entry(at: NSEvent.mouseLocation) {
                self.activateDisplay(target.id)
                if target.hasNotch || self.revealedEntryID == target.id { return nil }
                return event
            }
            if event.type == .leftMouseUp { self.endInteraction() }
            self.updatePointer(at: event.window?.convertPoint(toScreen: event.locationInWindow), pointerMoved: true)
            if event.type == .leftMouseDown, event.window === self.panel {
                // v286：普通点击只挂「点击期间保护」，抬起（endInteraction）即解除；
                // 不再冒充 openedExplicitly 把展开状态钉死。
                self.clickPinned = true
                self.beginInteraction()
            }
            if event.type == .scrollWheel {
                NotificationCenter.default.post(name: .islandGlowShouldHide, object: event.window)
            }
            if event.type == .scrollWheel, event.window === self.panel, self.expanded,
               !self.interacting, !self.editingText, event.hasPreciseScrollingDeltas {
                if event.phase.contains(.began) { self.horizontalScroll = 0; self.didSwipe = false }
                if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.momentumPhase.isEmpty {
                    self.horizontalScroll += event.scrollingDeltaX
                    if !self.didSwipe, abs(self.horizontalScroll) > 36 {
                        let step = self.horizontalScroll < 0 ? 1 : -1
                        if self.page == .monitor {
                            // 详情横滑 = 切指标，绝不整页跳走（两种作用域分开）
                            self.stepMonitorDetail(step)
                        } else if (self.page == .home || self.page == .custom) && self.componentPageCount > 1 {
                            self.turnComponentPage(step)
                        } else { self.turnPage(step) }
                        self.didSwipe = true
                    }
                    if event.phase.isEmpty { self.horizontalScroll = 0; self.didSwipe = false }
                    return nil
                }
            }
            if (event.type == .leftMouseDown || event.type == .rightMouseDown), event.window !== self.panel, !self.inside, !self.menuTracking {
                self.collapse()
            }
            return event
        } { monitors.append(token) }
    }

    private func updatePointer(at location: NSPoint? = nil, pointerMoved: Bool = false) {
        guard let panel else { return }
        let point = location ?? NSEvent.mouseLocation
        let target = entry(at: point)
        let hoverID = target?.id
        if entryHoverID != hoverID {
            entryHoverWork?.cancel(); entryHoverWork = nil
            entryHoverID = hoverID
            if let target, !target.hasNotch,
               !(target.id == activeDisplayID && contentVisible) {
                let clickOnly = configuration.entryTriggers[target.id] == .clickOnly || !configuration.hoverEnabled
                if !clickOnly {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.entryHoverID == target.id else { return }
                        self.entryHoverWork = nil
                        self.move(to: target)
                        self.expand()
                    }
                    entryHoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
                } else if (configuration.entryVisibilities[target.id] ?? .event) == .event,
                          revealedEntryID != target.id {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.entryHoverID == target.id else { return }
                        self.entryHoverWork = nil
                        self.revealedEntryID = target.id
                        self.refreshEntries()
                    }
                    entryHoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
                }
            } else if target == nil, revealedEntryID != nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.entryHoverWork = nil
                    self?.revealedEntryID = nil
                    self?.refreshEntries()
                }
                entryHoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
            } else if let target, target.hasNotch, target.id != activeDisplayID, configuration.hoverEnabled,
                      // 2026-11-23（需求 B）：跨屏迁移按用户设置门控——与非刘海入口同口径，
                      // 「仅点击」的屏幕不再被悬停带走（原来只有 hoverEnabled 一档，漏了 entryTriggers）。
                      configuration.entryTriggers[target.id] != .clickOnly,
               !pinnedOpen, !interacting, !menuTracking, !editingText {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.entryHoverID == target.id, !self.pinnedOpen,
                          !self.interacting, !self.menuTracking, !self.editingText else { return }
                    self.move(to: target)
                    self.expand()
                }
                entryHoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
            }
        }
        let local = CGPoint(x: point.x - panel.frame.midX + visibleSize.width / 2,
                            y: panel.frame.maxY - point.y)
        let next = CGRect(origin: .zero, size: visibleSize).contains(local) && visibleOutline.contains(local)
        panel.ignoresMouseEvents = !next || !panel.isVisible
        let overCamera = abs(local.x - visibleSize.width / 2) < notchWidth / 2
        let hoverInside = next && (expanded || overCamera) ||
            (expanded && MainPanelPreviewPopoverCoordinator.shared.hasPreview(from: panel, at: point))
        guard inside != hoverInside || (!hoverInside && expanded && hoverWork == nil) else { return }
        inside = hoverInside
        hoverWork?.cancel()
        hoverWork = nil
        if !hoverInside && pointerMoved { hoverArmed = true }
        if hoverInside, !expanded, hoverArmed, configuration.hoverEnabled, pointerMoved {
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
        } else if pointerMoved, !hoverInside, expanded, !pinnedOpen, !interacting, !menuTracking,
                  entryHoverWork == nil || target?.hasNotch == false,
                  !editingText {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
        }
    }

    private var editingText: Bool {
        panel?.isKeyWindow == true && (panel?.firstResponder as? NSTextView)?.isEditable == true
    }

    private func entry(at point: NSPoint) -> IslandDisplay? {
        displays.first {
            // `.hidden` hides only the drawn capsule; the screen's pointer hot zone stays active.
            return $0.entryFrame(hotspot: configuration.hotspots[$0.id] ?? .center,
                                 width: configuration.hotspotWidths[$0.id] ?? 210).contains(point)
        }
    }

    func containsEntry(at point: NSPoint) -> Bool { entry(at: point) != nil }
}

/// 其他屏幕只绘制入口；没有 SwiftUI 正文、数据库订阅或采样器。
private final class IslandEntryView: NSView {
    let hasNotch: Bool
    let activate: () -> Void
    init(hasNotch: Bool, activate: @escaping () -> Void) {
        self.hasNotch = hasNotch
        self.activate = activate
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(hasNotch ? "打开刘海工作台" : "搜索并打开工作台")
        if !hasNotch {
            // 2026-11-23：自拼 NSVisualEffectView 收敛到 LiquidGlass 工厂（R2 口径），
            // 26+ 得真玻璃、旧系统仍是 .menu 毛玻璃；圆角收编 Theme.Radius.control（= 8）。
            let material = LiquidGlass.makeView(frame: bounds,
                                                cornerRadius: Theme.Radius.control,
                                                material: .menu)
            material.autoresizingMask = [.width, .height]
            addSubview(material)
            let icon = NSImageView(frame: NSRect(x: 10, y: 7, width: 14, height: 14))
            icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            addSubview(icon)
            let label = NSTextField(labelWithString: "搜索…")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 30, y: 6, width: 138, height: 16)
            addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { activate() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func accessibilityPerformPress() -> Bool { activate(); return true }
    override func draw(_ dirtyRect: NSRect) {
        guard hasNotch else { return }
        NSColor.black.setFill()
        // 2026-11-23：入口胶囊圆角 10 → Theme.Radius.card（取值不变）
        NSBezierPath(roundedRect: bounds,
                     xRadius: Theme.Radius.card, yRadius: Theme.Radius.card).fill()
        let mark = NSRect(x: bounds.midX - 12, y: 4, width: 24, height: 3)
        NSColor.white.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: mark, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.type == .keyDown {
            // v270：详情页 Esc 先回上一页，再按一次才收起。
            if IslandController.shared.isInDetailPage { IslandController.shared.goBack() }
            else { IslandController.shared.collapse() }
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "o" {
            IslandController.shared.open()
            return true
        }
        if event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 {
            let step = event.keyCode == 123 ? -1 : 1
            if IslandController.shared.page == .monitor { IslandController.shared.stepMonitorDetail(step) }
            else { IslandController.shared.turnPage(step) }
            return true
        }
        let visiblePages = IslandController.shared.configuration.visiblePages
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers,
           let index = Int(key), (1...visiblePages.count).contains(index) {
            if IslandController.shared.editingLayout { return true }
            IslandController.shared.selectPage(visiblePages[index - 1])
            IslandController.shared.expand(takeFocus: true, useOpeningPage: false)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
