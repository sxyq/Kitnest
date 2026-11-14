import AppKit
import Combine
import SwiftUI

/// 一个透明舞台只承载 Demo；窗口尺寸固定，形状和内容由 SwiftUI 同步过渡。
final class IslandController: NSObject, ObservableObject {
    static let shared = IslandController()
    @Published private(set) var configuration = IslandConfiguration()
    @Published var expanded = false
    @Published var page = IslandPage.home
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var notchHeight: CGFloat = 0
    private(set) var panel: IslandPanel?
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var inside = false
    private var hoverArmed = true
    private var openedExplicitly = false
    private var observation: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    var height: CGFloat {
        let body: CGFloat
        switch page {
        case .home: body = 530
        case .clipboard: body = 368
        case .transfer: body = 418
        case .monitor: body = 530
        case .media: body = 480
        case .calendar: body = 462
        case .tools: body = 368
        case .settings: body = 422
        }
        return notchHeight + body
    }

    func start() {
        show()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.tophalf.inset.filled",
                                     accessibilityDescription: "Kitnest Island Demo")
        let menu = NSMenu()
        let open = NSMenuItem(title: "展开 Demo", action: #selector(IslandController.open), keyEquivalent: "")
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
            observation = objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePointer() }
            }
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
        configuration.width = min(560, screen.frame.width - 40)
        let size = NSSize(width: configuration.width + 32, height: min(650, screen.frame.height - 40))
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    func expand(takeFocus: Bool = false) {
        hoverWork?.cancel()
        hoverWork = nil
        openedExplicitly = openedExplicitly || takeFocus
        expanded = true
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
        observation = nil
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
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .keyDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            self.updatePointer()
            if (event.type == .leftMouseDown || event.type == .rightMouseDown), event.window !== self.panel {
                self.collapse()
            }
            return event
        } { monitors.append(token) }
    }

    private func updatePointer(at location: NSPoint? = nil) {
        guard let panel, panel.isVisible else { return }
        let width = expanded ? configuration.width : notchWidth
        let h = expanded ? height : notchHeight
        let rect = NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - h, width: width, height: h)
        let next = rect.contains(location ?? NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !next
        guard inside != next else { return }
        inside = next
        hoverWork?.cancel()
        hoverWork = nil
        if !next { hoverArmed = true }
        if next, !expanded, hoverArmed {
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
        } else if !next, expanded, !openedExplicitly {
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
        return super.performKeyEquivalent(with: event)
    }
}
