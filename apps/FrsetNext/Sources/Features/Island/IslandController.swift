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
    @Published var page = IslandPage.home {
        didSet {
            if IslandPage.tabs.contains(oldValue) { returnPage = oldValue }
            if IslandPage.tabs.contains(page) { returnPage = page }
        }
    }
    private(set) var returnPage = IslandPage.home
    @Published var componentPage = 0
    @Published private(set) var componentPageCount = 1
    @Published var selectedRecord: String?
    @Published var selectedTool: String?
    @Published var toolQuery = ""
    @Published var toolCategory: ToolCategory?
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
    private var openedExplicitly = false
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
    private(set) var selection: AppBootstrap.SelectionResult?

    init(configuration: IslandConfiguration = .load(), previewOnly: Bool = false) {
        self.configuration = configuration
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
    var layoutColumns: Int { min(configuration.columns, max(1, Int((effectiveWidth - IslandLayout.horizontalInset * 2 + 8) / 152))) }
    var layoutRows: Int { min(configuration.rows, max(1, Int((effectiveHeight - 176 + 8) / 120))) }

    func surfaceAnimation(reduceMotion: Bool) -> Animation? {
        if previewOnly && !previewVisible { return nil }
        return reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: expanded ? 0.32 : 0.26, dampingFraction: expanded ? 0.94 : 1, blendDuration: 0)
    }

    private var hidesCollapsedSurface: Bool {
        displayScreen.safeAreaInsets.top == 0 || visiblePeeks.isEmpty
    }

    @discardableResult
    func apply(_ configuration: IslandConfiguration) -> String? {
        if !previewOnly {
            do { try configuration.persist() }
            catch { return "刘海设置保存失败：\(error.localizedDescription)" }
        }
        self.configuration = configuration
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
        page = .home
        beginInteraction()
        feedback = "拖动组件调整位置 · 右下角调整尺寸"
    }

    func updateLayout(_ value: IslandConfiguration) {
        layoutDraft = value
    }

    func finishLayoutEditing() {
        let next = layoutConfiguration
        if let reason = apply(next) { feedback = reason; HapticFeedback.perform(.operationFailed); return }
        layoutDraft = nil
        layoutDidChange?(next)
        feedback = previewOnly ? "布局已更新到设置草稿，保存后应用" : "布局已保存"
        if !previewOnly { HapticFeedback.perform(.layoutSaved) }
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
        if previewOnly { return } // 模拟场景没有真实指针，不进入移开收回计时。
        if menuTracking || editingText { return }
        updatePointer()
        if !inside, expanded, !openedExplicitly, entryHoverWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
        }
    }

    var collapsedWidth: CGFloat {
        notchWidth + CGFloat((visiblePeeks.count + 1) / 2) * 2 * (peeksShowValues ? 72 : 38)
    }

    func turnPage(_ step: Int) {
        if page == .home, componentPageCount > 1 {
            componentPage = min(max(componentPage + step, 0), componentPageCount - 1)
            return
        }
        if editingLayout { return }
        let pages = IslandPage.tabs
        let index = pages.firstIndex(of: page) ?? pages.firstIndex(of: returnPage)!
        page = pages[(index + step + pages.count) % pages.count]
    }

    func setComponentPageCount(_ count: Int) {
        if componentPageCount != count { componentPageCount = count }
        if componentPage >= count { componentPage = count - 1 }
    }

    func goBack() { page = returnPage }

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
        let summary = String((ClipboardRepository.shared.fetch(ClipboardQuery(limit: 1)).first?.displayTitle ?? "暂无内容").prefix(24)).replacingOccurrences(of: "\n", with: " ")
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
            case .monitor: page = .monitor; expand(takeFocus: true)
            }
        } else {
            page = peek.page
            expand(takeFocus: true)
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
        if !previewOnly {
            guard configuration.enabled else { ServiceLocator.settings?.open(pane: "island"); return }
            show()
            if let target = displays.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
                move(to: target)
            }
        }
        expand(takeFocus: true)
    }

    private func show() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() }
        }
        displays = IslandDisplay.enabled(for: configuration)
        if !displays.contains(where: { $0.id == activeDisplayID }) { activeDisplayID = displays.first?.id }
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

    private func refreshEntries() {
        let ids = Set(displays.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) {
            entries.removeValue(forKey: id)?.orderOut(nil)
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
            }
            entries[display.id]?.setFrame(display.entryFrame, display: true)
            let revealed = display.hasNotch || revealedEntryID == display.id
            entries[display.id]?.contentView?.isHidden = !revealed
            entries[display.id]?.ignoresMouseEvents = !revealed
            let visible = display.hasNotch ? display.id != activeDisplayID
                : !(display.id == activeDisplayID && contentVisible)
            if visible { entries[display.id]?.orderFrontRegardless() }
            else { entries[display.id]?.orderOut(nil) }
        }
    }

    private func activateDisplay(_ id: String) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let hasPreview = panel.map { MainPanelPreviewPopoverCoordinator.shared.hasPreview(from: $0) } ?? false
        if !contentVisible && !display.hasNotch { page = .search }
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
        activeDisplayID = display.id
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
            centerX = screen.frame.midX
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
        let size = IslandDisplay(screen: screen)?.entrySize ?? CGSize(width: 180, height: 28)
        let width = size.width, height = size.height
        if notchWidth != width { notchWidth = width }
        if notchHeight != height { notchHeight = height }
    }

    func expand(takeFocus: Bool = false) {
        hoverWork?.cancel()
        hoverWork = nil
        openedExplicitly = openedExplicitly || takeFocus
        if !expanded {
            if !previewOnly { selection = AppBootstrap.readSelection() }
            refreshClipboard()
            showingContent = true
            if !previewOnly { position(); panel?.orderFrontRegardless() }
            expanded = true
            revealedEntryID = nil
            if !previewOnly { refreshEntries() }
        }
        hoverArmed = false
        if takeFocus { panel?.makeKeyAndOrderFront(nil) }
    }

    func collapse() {
        if editingLayout { cancelLayoutEditing() }
        if let panel, MainPanelPreviewPopoverCoordinator.shared.hasPreview(from: panel) {
            MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .panelCollapse)
        }
        hoverWork?.cancel()
        hoverWork = nil
        openedExplicitly = false
        expanded = false
        entryHoverID = nil
        entryHoverWork?.cancel(); entryHoverWork = nil
        revealedEntryID = nil
        if !previewOnly { refreshEntries() }
        hoverArmed = false
        panel?.makeFirstResponder(nil)
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
            }
        ]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseUp { self?.endInteraction() }
            else { self?.updatePointer(pointerMoved: true) }
        } { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, let target = self.entry(at: NSEvent.mouseLocation),
               target.hasNotch || self.revealedEntryID == target.id {
                self.activateDisplay(target.id); return
            }
            self?.updatePointer(at: event.locationInWindow, pointerMoved: true)
            if self?.inside == false, self?.menuTracking == false { self?.collapse() }
        } { monitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .leftMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, let target = self.entry(at: NSEvent.mouseLocation),
               target.hasNotch || self.revealedEntryID == target.id {
                self.activateDisplay(target.id); return nil
            }
            if event.type == .leftMouseUp { self.endInteraction() }
            self.updatePointer(at: event.window?.convertPoint(toScreen: event.locationInWindow), pointerMoved: true)
            if event.type == .leftMouseDown, event.window === self.panel {
                self.openedExplicitly = true
                self.beginInteraction()
            }
            if event.type == .scrollWheel {
                NotificationCenter.default.post(name: .islandGlowShouldHide, object: event.window)
            }
            if event.type == .scrollWheel, event.window === self.panel, self.expanded,
               self.page == .home, self.componentPageCount > 1, !self.interacting, event.hasPreciseScrollingDeltas {
                if event.phase.contains(.began) { self.horizontalScroll = 0; self.didSwipe = false }
                if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), event.momentumPhase.isEmpty {
                    self.horizontalScroll += event.scrollingDeltaX
                    if !self.didSwipe, abs(self.horizontalScroll) > 36 {
                        self.turnPage(self.horizontalScroll < 0 ? 1 : -1)
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
            if let target, !target.hasNotch, configuration.hoverEnabled,
               !(target.id == activeDisplayID && contentVisible) {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.entryHoverID == target.id else { return }
                    self.entryHoverWork = nil
                    self.revealedEntryID = target.id
                    self.refreshEntries()
                    self.updatePointer(pointerMoved: true)
                }
                entryHoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
            } else if target == nil, revealedEntryID != nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.entryHoverWork = nil
                    self?.revealedEntryID = nil
                    self?.refreshEntries()
                }
                entryHoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
            } else if let target, target.hasNotch, target.id != activeDisplayID, configuration.hoverEnabled,
               !openedExplicitly, !interacting, !menuTracking, !editingText {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.entryHoverID == target.id, !self.openedExplicitly,
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
        if hoverInside, displayScreen.safeAreaInsets.top > 0, !expanded, hoverArmed, configuration.hoverEnabled, pointerMoved {
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
        } else if pointerMoved, !hoverInside, expanded, !openedExplicitly, !interacting, !menuTracking,
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
        displays.first { $0.entryFrame.contains(point) }
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
            let material = NSVisualEffectView(frame: bounds)
            material.material = .menu
            material.state = .active
            material.autoresizingMask = [.width, .height]
            material.wantsLayer = true
            material.layer?.cornerRadius = 8
            material.layer?.masksToBounds = true
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
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
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
            IslandController.shared.collapse()
            return true
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "o" {
            IslandController.shared.open()
            return true
        }
        if event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 {
            IslandController.shared.turnPage(event.keyCode == 123 ? -1 : 1)
            return true
        }
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers,
           let index = Int(key), (1...IslandPage.allCases.count).contains(index) {
            if IslandController.shared.editingLayout { return true }
            IslandController.shared.page = IslandPage.allCases[index - 1]
            IslandController.shared.expand(takeFocus: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
