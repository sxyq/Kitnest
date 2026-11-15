import AppKit
import Combine
import SwiftUI

/// 单一透明舞台，几何过渡与业务内容共用正式入口。
final class IslandController: NSObject, ObservableObject {
    static let shared = IslandController()
    let previewOnly: Bool
    var layoutDidChange: ((IslandConfiguration) -> Void)?
    @Published private(set) var configuration: IslandConfiguration
    @Published var expanded = false
    @Published var page = IslandPage.home
    @Published var playing = false
    @Published var volume = 56.0
    @Published var track = 0
    @Published var seek = 86.0
    @Published var completedEvents = Set<Int>()
    let tracks = [("Quiet Hours", "Lo-fi Session"), ("Blue Afternoon", "Studio Sessions"), ("Night Walk", "Ambient Notes")]
    @Published var feedback = "左右滑动切页 · 拖动把手排列组件"
    @Published private(set) var clipboardSummary = "暂无内容"
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var notchHeight: CGFloat = 0
    private(set) var panel: IslandPanel?
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var inside = false
    private var hoverArmed = true
    private var openedExplicitly = false
    private var screenObserver: NSObjectProtocol?
    private var visibleSize = CGSize.zero
    private var visibleRadius: CGFloat = 0
    private var interacting = false
    private var horizontalScroll: CGFloat = 0
    private var didSwipe = false
    private var afterCollapse: (() -> Void)?
    private(set) var selection: AppBootstrap.SelectionResult?

    init(configuration: IslandConfiguration = .load(), previewOnly: Bool = false) {
        self.configuration = configuration
        self.previewOnly = previewOnly
        super.init()
        if previewOnly { notchWidth = 180; notchHeight = 28 }
    }

    var usesGlass: Bool { configuration.usesGlass }
    var visiblePeeks: Set<IslandPeek> { configuration.visiblePeeks }
    var peeksShowValues: Bool { configuration.peeksShowValues }
    var peeksQuickActions: Bool { configuration.peeksQuickActions }
    var glowEnabled: Bool { configuration.glowEnabled }
    var widgetOrder: [IslandWidget] { configuration.widgetOrder }
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
    var effectiveWidth: CGFloat { min(configuration.width, (panel?.screen?.frame.width ?? configuration.width + 40) - 40) }
    var effectiveHeight: CGFloat { min(configuration.height, (panel?.screen?.frame.height ?? configuration.height + 40) - 40) }

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

    func resize(_ widget: IslandWidget, to size: IslandWidgetSize) {
        var next = configuration
        next.widgetSizes[widget.rawValue] = size
        if let reason = apply(next) { feedback = reason }
        else { layoutDidChange?(next) }
    }

    func move(_ widget: IslandWidget, before target: IslandWidget) {
        guard widget != target else { return }
        var next = configuration
        next.widgetOrder.removeAll { $0 == widget }
        next.widgetOrder.insert(widget, at: next.widgetOrder.firstIndex(of: target)!)
        if let reason = apply(next) { feedback = reason }
        else { layoutDidChange?(next) }
    }

    func beginInteraction() { interacting = true; hoverWork?.cancel(); hoverWork = nil }
    func endInteraction() {
        interacting = false
        updatePointer()
        if !inside, expanded, !openedExplicitly {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
        }
    }

    var collapsedWidth: CGFloat {
        notchWidth + CGFloat((visiblePeeks.count + 1) / 2) * 2 * (peeksShowValues ? 72 : 38)
    }

    func turnPage(_ step: Int) {
        let pages = IslandPage.tabs
        let index = pages.firstIndex(of: page) ?? 0
        page = pages[(index + step + pages.count) % pages.count]
    }

    func changeTrack(_ step: Int) {
        track = (track + step + tracks.count) % tracks.count
        seek = 0
    }

    private func refreshClipboard() {
        if previewOnly { clipboardSummary = IslandSample.clipboard[0].title; return }
        clipboardSummary = ClipboardRepository.shared.fetch(ClipboardQuery(limit: 1)).first?.content.map {
            String($0.prefix(24)).replacingOccurrences(of: "\n", with: " ")
        } ?? "暂无内容"
    }

    func copyLatest() {
        if previewOnly { feedback = "预览：已复制近期内容"; return }
        guard let item = ClipboardRepository.shared.fetch(ClipboardQuery(limit: 1)).first else {
            feedback = "暂无近期内容"; return
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
                else { page = .media; expand(takeFocus: true) }
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
        updatePointer()
        if !expanded, size == CGSize(width: collapsedWidth, height: notchHeight), let action = afterCollapse {
            afterCollapse = nil
            DispatchQueue.main.async(execute: action)
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
        }
        expand(takeFocus: true)
    }

    private func show() {
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
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in self?.position() }
            position()
            let hosting = NSHostingView(rootView: IslandRootView(controller: self))
            hosting.sizingOptions = []
            p.contentView = hosting
        } else { position() }
        panel?.orderFrontRegardless()
        updatePointer()
    }

    private func position() {
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens[0]
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
            notchHeight = screen.safeAreaInsets.top
        } else {
            // 无刘海屏幕仅展示一块小型黑色入口，不扩大有刘海屏幕的收起态。
            notchWidth = 180
            notchHeight = 28
        }
        let size = NSSize(width: min(configuration.width, screen.frame.width - 40) + 32,
                          height: min(configuration.height, screen.frame.height - 40) + 16)
        let scale = screen.backingScaleFactor
        panel.setFrame(NSRect(x: ((screen.frame.midX - size.width / 2) * scale).rounded() / scale,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    func expand(takeFocus: Bool = false) {
        hoverWork?.cancel()
        hoverWork = nil
        openedExplicitly = openedExplicitly || takeFocus
        if !expanded {
            if !previewOnly { selection = AppBootstrap.readSelection() }
            refreshClipboard()
            expanded = true
        }
        hoverArmed = false
        if takeFocus { panel?.makeKeyAndOrderFront(nil) }
    }

    func collapse() {
        hoverWork?.cancel()
        hoverWork = nil
        openedExplicitly = false
        expanded = false
        if !previewOnly { MonitorSampler.shared.setIslandActive(false) }
        hoverArmed = !inside
        panel?.makeFirstResponder(nil)
    }

    func stop() {
        collapse()
        panel?.orderOut(nil)
        for token in monitors { NSEvent.removeMonitor(token) }
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        panel = nil
    }

    private func installMonitors() {
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if event.type == .leftMouseUp { self?.endInteraction() }
            else { self?.updatePointer() }
        } { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.updatePointer(at: event.locationInWindow)
            if self?.inside == false { self?.collapse() }
        } { monitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .leftMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp { self.endInteraction() }
            self.updatePointer(at: event.window?.convertPoint(toScreen: event.locationInWindow))
            if event.type == .scrollWheel, event.window === self.panel, self.expanded {
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
            if (event.type == .leftMouseDown || event.type == .rightMouseDown), event.window !== self.panel {
                self.collapse()
            }
            return event
        } { monitors.append(token) }
    }

    private func updatePointer(at location: NSPoint? = nil) {
        guard let panel, panel.isVisible else { return }
        let point = location ?? NSEvent.mouseLocation
        let local = CGPoint(x: point.x - panel.frame.midX + visibleSize.width / 2,
                            y: panel.frame.maxY - point.y)
        let next = CGRect(origin: .zero, size: visibleSize).contains(local) &&
            (local.y < visibleRadius || IslandOutline(radius: visibleRadius)
                .path(in: CGRect(origin: .zero, size: visibleSize)).contains(local))
        panel.ignoresMouseEvents = !next
        let overCamera = abs(local.x - visibleSize.width / 2) < notchWidth / 2
        let hoverInside = next && (expanded || overCamera)
        guard inside != hoverInside else { return }
        inside = hoverInside
        hoverWork?.cancel()
        hoverWork = nil
        if !hoverInside { hoverArmed = true }
        if hoverInside, !expanded, hoverArmed, configuration.hoverEnabled {
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
        } else if !hoverInside, expanded, !openedExplicitly, !interacting {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
        }
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
            IslandController.shared.page = IslandPage.allCases[index - 1]
            IslandController.shared.expand(takeFocus: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
