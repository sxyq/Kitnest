import AppKit
import Combine
import SwiftUI

/// 一个透明舞台只承载 Demo；窗口尺寸固定，形状和内容由 SwiftUI 同步过渡。
final class IslandController: NSObject, ObservableObject {
    static let shared = IslandController()
    @Published private(set) var configuration = IslandConfiguration()
    @Published var expanded = false
    @Published var page = IslandPage.home
    @Published var usesGlass = true
    @Published var visiblePeeks = Set<IslandPeek>()
    @Published var peeksShowValues = true
    @Published var peeksQuickActions = true
    @Published var glowEnabled = true
    @Published var playing = false
    @Published var volume = 56.0
    @Published var widgetOrder = IslandWidget.allCases
    @Published var metricOrder = IslandMetric.allCases
    @Published var peekOrder = IslandPeek.allCases
    @Published var track = 0
    @Published var seek = 86.0
    @Published var completedEvents = Set<Int>()
    let tracks = [("Quiet Hours", "Lo-fi Session"), ("Blue Afternoon", "Studio Sessions"), ("Night Walk", "Ambient Notes")]
    @Published var feedback = "界面演示 · 左右滑动切页"
    @Published private(set) var clipboardSummary = "暂无内容"
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var notchHeight: CGFloat = 0
    private(set) var panel: IslandPanel?
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var inside = false
    private var hoverArmed = true
    private var openedExplicitly = false
    private var screenObserver: NSObjectProtocol?
    private var visibleSize = CGSize.zero
    private var visibleRadius: CGFloat = 0
    private var clipboardSnapshot: [[NSPasteboard.PasteboardType: Data]] = []
    private var clipboardChange = -1
    private var horizontalScroll: CGFloat = 0
    private var didSwipe = false

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
        let pasteboard = NSPasteboard.general
        guard clipboardChange != pasteboard.changeCount else { return }
        clipboardChange = pasteboard.changeCount
        clipboardSnapshot = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        clipboardSummary = pasteboard.string(forType: .string).map { String($0.prefix(24)).replacingOccurrences(of: "\n", with: " ") }
            ?? (clipboardSnapshot.isEmpty ? "暂无内容" : "图片或文件")
    }

    func copyLatest() {
        refreshClipboard()
        guard !clipboardSnapshot.isEmpty else { feedback = "系统剪贴板为空"; return }
        let items = clipboardSnapshot.map { data in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: type) }
            return item
        }
        NSPasteboard.general.clearContents()
        feedback = NSPasteboard.general.writeObjects(items) ? "已复制系统剪贴板最近内容" : "剪贴板写入失败"
    }

    func copyDate() {
        let value = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        NSPasteboard.general.clearContents()
        feedback = NSPasteboard.general.setString(value, forType: .string) ? "已复制日期 \(value)" : "日期写入失败"
    }

    func activatePeek(_ peek: IslandPeek) {
        if peeksQuickActions {
            switch peek {
            case .clipboard: copyLatest()
            case .media: playing.toggle()
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
    }

    func start() {
        show()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.tophalf.inset.filled",
                                     accessibilityDescription: "Kitnest Island Demo")
        let menu = NSMenu()
        let open = NSMenuItem(title: "展开 Demo", action: #selector(IslandController.open), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc func open() {
        show()
        expand(takeFocus: true)
    }

    private func show() {
        if panel == nil {
            let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.title = "Kitnest Island · 界面与动效 Demo"
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
        configuration.width = min(780, screen.frame.width - 40)
        configuration.height = min(440, screen.frame.height - 40)
        let size = NSSize(width: configuration.width + 32, height: configuration.height + 16)
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
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    private func installMonitors() {
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
            self?.updatePointer()
        } { monitors.append(token) }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.updatePointer(at: event.locationInWindow)
            if self?.inside == false { self?.collapse() }
        } { monitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .leftMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
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
        let next = IslandOutline(radius: visibleRadius)
            .path(in: CGRect(origin: .zero, size: visibleSize)).contains(local)
        panel.ignoresMouseEvents = !next
        let overCamera = abs(local.x - visibleSize.width / 2) < notchWidth / 2
        let hoverInside = next && (expanded || overCamera)
        guard inside != hoverInside else { return }
        inside = hoverInside
        hoverWork?.cancel()
        hoverWork = nil
        if !hoverInside { hoverArmed = true }
        if hoverInside, !expanded, hoverArmed {
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
        } else if !hoverInside, expanded, !openedExplicitly {
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
