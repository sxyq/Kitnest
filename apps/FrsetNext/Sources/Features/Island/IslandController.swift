import AppKit
import Combine
import SwiftUI

/// 一个透明舞台承载同一外壳；原生窗口不跟着每一帧缩放，也不占用主面板状态。
final class IslandController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = IslandController()
    @Published private(set) var configuration = IslandConfiguration.saved
    @Published var expanded = false
    @Published var page = IslandPage.clipboard
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var notchHeight: CGFloat = 0
    @Published var dropping = false
    private(set) var panel: IslandPanel?
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var inside = false
    private var hoverArmed = true
    private var openedExplicitly = false
    private var previousDropState: (Bool, IslandPage)?
    private var acceptedDrop = false
    private var observation: AnyCancellable?
    private var screenObserver: NSObjectProtocol?

    var height: CGFloat {
        switch page {
        case .clipboard:
            let row = ThemeAppearance(personalization: .shared, isMidnight: AppearanceState.shared.isMidnight).statsRowHeight
            return notchHeight + 100 + CGFloat(min(configuration.visibleRows, max(1, ClipboardManager.shared.items.count))) * (row + 3)
        case .transfer:
            let count = LocalTransferStore.shared.items.count
            return notchHeight + (count <= 4 ? 250 : 120 + CGFloat(min(5, (count + 1) / 2)) * 50)
        case .search: return notchHeight + 440
        case .media: return notchHeight + 260
        case .calendar: return notchHeight + 280
        }
    }

    func start() {
        if configuration.enabled { show() }
    }

    func apply(_ value: IslandConfiguration) {
        configuration = value
        if !value.pages.contains(page), let first = value.pages.first { page = first }
        if value.enabled { show() }
        else { stop() }
    }

    @objc func open() {
        show()
        expand(takeFocus: true)
    }

    private func show() {
        if panel == nil {
            let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.title = "Kitnest · 顶部刘海"
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isReleasedWhenClosed = false; p.acceptsMouseMovedEvents = true
            p.sharingType = .none
            p.delegate = self
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
        let screen = configuration.followPointerScreen
            ? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens[0]
            : NSScreen.screens[0]
        notchHeight = screen.safeAreaInsets.top
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        } else { notchWidth = 0 }
        configuration.width = min(configuration.width, Double(screen.frame.width - 40))
        let size = NSSize(width: CGFloat(configuration.width) + 24,
                          height: min(580 + notchHeight, screen.frame.height - 40))
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
        Log.info("Island", "展开：主动=\(openedExplicitly)")
    }

    func collapse() {
        hoverWork?.cancel()
        hoverWork = nil
        if expanded { Log.info("Island", "收起：指针在内=\(inside)") }
        openedExplicitly = false
        expanded = false
        dropping = false
        hoverArmed = !inside
        panel?.makeFirstResponder(nil)
        MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .programmatic)
        FileHoverPreviewController.shared.scheduleHide()
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
        let width = expanded ? CGFloat(configuration.width) : max(340, notchWidth + 180)
        let h = expanded ? height : max(38, notchHeight + 8)
        let rect = NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - h, width: width, height: h)
        let next = rect.contains(location ?? NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == next { panel.ignoresMouseEvents = !next }
        guard inside != next || (!next && expanded && hoverWork == nil) else { return }
        inside = next
        hoverWork?.cancel()
        if !next { hoverArmed = true }
        if next, !expanded, configuration.hoverOpens, hoverArmed {
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.hoverDelay, execute: work)
        } else if !next, expanded, !openedExplicitly {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverWork = nil
                guard NSEvent.pressedMouseButtons == 0,
                      self.panel?.isKeyWindow != true,
                      !(self.panel?.firstResponder is NSTextView), !self.dropping else { return }
                self.collapse()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.collapseDelay, execute: work)
        }
    }

    func targetDrop(_ active: Bool) {
        dropping = active
        if active {
            previousDropState = (expanded, page)
            acceptedDrop = false
            page = .transfer
            expand()
        } else if !acceptedDrop, let previousDropState {
            page = previousDropState.1
            expanded = previousDropState.0
            self.previousDropState = nil
        }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        acceptedDrop = true
        previousDropState = nil
        TransferFileDropReader.load(from: providers) { urls in
            guard !urls.isEmpty else {
                Toast.show("未能读取拖入的文件", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            LocalTransferStore.shared.add(urls: urls) { count in
                if let error = LocalTransferStore.shared.lastError {
                    Toast.show(error, icon: "exclamationmark.triangle", isWarning: true)
                } else { Toast.show("已加入 \(count) 个文件", icon: "tray") }
            }
        }
        return true
    }

    func reorder(_ pages: [IslandPage]) {
        configuration.pages = pages
        do { UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: IslandConfiguration.key) }
        catch { Toast.show("保存排列失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true) }
    }

    func openFullWindow() {
        collapse()
        switch page {
        case .clipboard: FloatingClipboardWindowController.shared.toggle()
        case .transfer: MonitorCenterPresenter.shared.selectTransferDock(); ServiceLocator.panel?.show()
        case .search:
            ServiceLocator.panel?.show()
            NotificationCenter.default.post(name: .frsetFocusPanelSearch, object: nil)
        case .media: ServiceLocator.settings?.open(pane: "audio")
        case .calendar: MonitorCenterPresenter.shared.selectHome(); ServiceLocator.panel?.show()
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
