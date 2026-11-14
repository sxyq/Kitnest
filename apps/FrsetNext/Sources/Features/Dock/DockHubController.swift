import AppKit
import SwiftUI
import ApplicationServices

enum DockHubSection: String, CaseIterable { case tools, calendar, media, windows }
enum DockHubAction: CaseIterable { case panel, clipboard, transfer, screenshot, longshot, recording, tools, monitor, settings, manual }

struct DockWindowItem: Identifiable {
    let id: Int
    let title: String
    let isMinimized: Bool
    let element: AXUIElement
    var thumbnail: NSImage?
}

private final class DockHubWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { styleMask.contains(.titled) }
}

/// 顶部刘海入口与完整控制窗共用内容和操作；原生窗不再切换 styleMask。
final class DockHubController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DockHubController()
    static let enabledKey = "dock.hub.enabled"
    static var savedEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    @Published var section: DockHubSection = .tools {
        didSet {
            if section == .windows { refreshApplications(); reloadWindows() }
            else { thumbnailTask?.cancel(); windowLoad += 1 }
        }
    }
    @Published private(set) var isExpanded = false
    @Published private(set) var isCollapsed = true
    @Published private(set) var notchWidth: CGFloat = 0
    @Published private(set) var topInset: CGFloat = 30
    @Published private(set) var hoveredApplication: NSRunningApplication?
    @Published private(set) var applications: [NSRunningApplication] = []
    @Published private(set) var windows: [DockWindowItem] = []
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    var window: NSWindow? { isExpanded ? fullWindow : topWindow }
    private var topWindow: NSWindow?
    private var fullWindow: NSWindow?
    private var topScreen: NSScreen?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var windowLoad = 0
    private var thumbnailTask: Task<Void, Never>?

    func start() {
        NSApp.setActivationPolicy(Self.savedEnabled ? .regular : .accessory)
        guard Self.savedEnabled, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.pointerMoved()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        present(expanded: false, activate: false, collapsed: true)
        Log.info("Dock", "顶部刘海入口已启用；辅助功能=\(AXIsProcessTrusted())")
    }

    func stop() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        localMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        cancelHover()
        leaveWork?.cancel()
        leaveWork = nil
        thumbnailTask?.cancel()
        windowLoad += 1
        for window in [topWindow, fullWindow].compactMap({ $0 }) {
            TransientWindowCenter.shared.unregister(window: window)
            window.orderOut(nil)
            window.contentView = nil
        }
        isExpanded = false
        isCollapsed = true
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        stop()
        start()
    }

    func requestAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let granted = AXIsProcessTrusted()
        if accessibilityGranted != granted { accessibilityGranted = granted }
    }

    private func pointerMoved() {
        guard !isExpanded, let window = topWindow else { return }
        let point = NSEvent.mouseLocation
        if window.frame.contains(point) {
            leaveWork?.cancel()
            leaveWork = nil
            guard isCollapsed, hoverWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.topWindow?.frame.contains(NSEvent.mouseLocation) == true else { return }
                self.cancelHover()
                self.captureFrontmostApplication()
                self.present(expanded: false, activate: false)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
            return
        }
        cancelHover()
        if !isCollapsed, leaveWork == nil, !window.isKeyWindow {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            leaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    private func cancelHover() {
        hoverWork?.cancel()
        hoverWork = nil
    }

    @objc private func screenChanged() {
        topScreen = nil
        if !isExpanded { present(expanded: false, activate: false, collapsed: isCollapsed) }
    }

    private func captureFrontmostApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            hoveredApplication = app
        }
        if section == .windows { refreshApplications(); reloadWindows() }
    }

    private func refreshApplications() {
        applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    func selectApplication(_ pid: pid_t) {
        hoveredApplication = applications.first { $0.processIdentifier == pid }
        reloadWindows()
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    func open(section selected: DockHubSection? = nil, expanded: Bool = true) {
        cancelHover()
        let granted = AXIsProcessTrusted()
        if accessibilityGranted != granted { accessibilityGranted = granted }
        if isCollapsed { captureFrontmostApplication() }
        if let selected { section = selected }
        else if section == .windows { reloadWindows() }
        present(expanded: expanded, activate: true)
    }

    // 原生窗形态不能在 SwiftUI 键盘动作的焦点更新栈里切换；退出该次动作后再改窗。
    func expand() { DispatchQueue.main.async { self.present(expanded: true, activate: true) } }
    func collapse() { DispatchQueue.main.async { self.present(expanded: false, activate: true) } }

    private func present(expanded: Bool, activate: Bool) {
        if let window, window.isVisible, !isCollapsed, window.contentView?.layer?.opacity != 0, expanded == isExpanded, activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        present(expanded: expanded, activate: activate, collapsed: false)
    }

    private func present(expanded: Bool, activate: Bool, collapsed: Bool) {
        cancelHover()
        leaveWork?.cancel()
        leaveWork = nil
        let previous = window
        let resizeTop = !isExpanded && !expanded && previous?.isVisible == true
        let changingMode = expanded != isExpanded
        isExpanded = expanded
        isCollapsed = collapsed
        if changingMode, let previous {
            previous.makeFirstResponder(nil)
            TransientWindowCenter.shared.unregister(window: previous)
            previous.orderOut(nil)
            previous.contentView = nil
        }
        let window: NSWindow
        if let existing = self.window { window = existing }
        else {
            let mask: NSWindow.StyleMask = expanded ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : .borderless
            window = DockHubWindow(contentRect: .zero, styleMask: mask, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.title = expanded ? "Kitnest · 控制台" : "Kitnest · 刘海组件"
            window.titleVisibility = .hidden
            window.identifier = NSUserInterfaceItemIdentifier(expanded ? "kitnest.dock.hub" : "kitnest.notch.hub")
            window.acceptsMouseMovedEvents = true
            if expanded { fullWindow = window } else { topWindow = window }
        }
        TransientWindowCenter.shared.unregister(window: window)
        if collapsed && window.isKeyWindow { window.orderOut(nil) }
        window.level = expanded ? .normal : NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = expanded ? [.fullScreenAuxiliary] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = topScreen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first!
        topScreen = screen
        notchWidth = screen.auxiliaryTopLeftArea.flatMap { left in screen.auxiliaryTopRightArea.map { $0.minX - left.maxX } } ?? 0
        topInset = max(30, screen.safeAreaInsets.top)
        let available = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let size = NSSize(width: min(expanded ? 760 : (collapsed ? max(184, notchWidth + 100) : max(440, notchWidth + 100)), available.width),
                          height: expanded ? min(560, available.height) : (collapsed ? topInset : min(440 + topInset, screen.frame.height - 20)))
        window.minSize = size
        window.maxSize = size
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: expanded ? available.midY - size.height / 2 : screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        let root = DockHubView(controller: self, size: size)
        if let hosting = window.contentView as? NSHostingView<DockHubView> {
            hosting.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.sizingOptions = []
            if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
            hosting.wantsLayer = true
            window.contentView = hosting
        }
        window.applyOfficialChrome(glassBacking: expanded, lights: expanded ? .fixed : .hidden)
        window.hasShadow = expanded || !collapsed
        window.appearance = expanded ? nil : NSAppearance(named: .darkAqua)
        WindowReveal.reset(window)
        if resizeTop && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = Theme.Motion.caEaseOut
                window.animator().setFrame(frame, display: true)
            }
        } else { window.setFrame(frame, display: false) }
        if !expanded && !collapsed { TransientWindowCenter.shared.register(window: window) { [weak self] in self?.dismiss() } }
        if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
        if !collapsed && !resizeTop {
            WindowReveal.playIn(on: window, from: CGPoint(x: 0.5, y: expanded ? 0.5 : 0),
                                scale: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0.96,
                                duration: 0.14)
        }
        Log.info("Dock", "\(expanded ? "完整窗" : (collapsed ? "刘海入口" : "刘海展开")) section=\(section.rawValue) size=\(size)")
    }

    func dismiss() {
        cancelHover()
        leaveWork?.cancel()
        leaveWork = nil
        thumbnailTask?.cancel()
        windowLoad += 1
        windows = []
        applications = []
        if Self.savedEnabled { present(expanded: false, activate: false, collapsed: true) }
        else {
            for window in [topWindow, fullWindow].compactMap({ $0 }) {
                TransientWindowCenter.shared.unregister(window: window)
                window.orderOut(nil)
                window.contentView = nil
            }
            isExpanded = false
            isCollapsed = true
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func windowDidResignKey(_ notification: Notification) {
        if !isExpanded && !isCollapsed, let window { TransientWindowCenter.shared.requestDismiss(window: window) }
    }

    private func reloadWindows() {
        thumbnailTask?.cancel()
        windowLoad += 1
        let current = windowLoad
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted, let app = hoveredApplication else { windows = []; return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        let elements = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        windows = elements.enumerated().map { index, element in
            DockWindowItem(id: index, title: attribute(element, kAXTitleAttribute) as? String ?? app.localizedName ?? "窗口",
                           isMinimized: attribute(element, kAXMinimizedAttribute) as? Bool ?? false, element: element)
        }
        // 仅用户打开窗口页时取一次缩略图，不录屏、不常驻采样；未授权仍可按标题切窗。
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess() else { return }
        let pid = app.processIdentifier
        thumbnailTask = Task { @MainActor [weak self] in
            let infos = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            let candidates = infos.filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }
            for item in self?.windows ?? [] where !item.isMinimized {
                var position = CGPoint.zero
                var size = CGSize.zero
                if let p = self?.attribute(item.element, kAXPositionAttribute) {
                    AXValueGetValue(p as! AXValue, .cgPoint, &position)
                }
                if let s = self?.attribute(item.element, kAXSizeAttribute) {
                    AXValueGetValue(s as! AXValue, .cgSize, &size)
                }
                guard !Task.isCancelled, let match = candidates.first(where: {
                    guard let dictionary = $0[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
                    return abs(rect.minX - position.x) < 2 && abs(rect.minY - position.y) < 2 && abs(rect.width - size.width) < 2 && abs(rect.height - size.height) < 2
                }),
                      let number = match[kCGWindowNumber as String] as? UInt32 else { continue }
                do {
                    let image = try await ScreenSnapshot.sckCapture(windowID: number, maximumDimension: 640)
                    guard let self, !Task.isCancelled, self.windowLoad == current,
                          let index = self.windows.firstIndex(where: { $0.id == item.id }) else { return }
                    self.windows[index].thumbnail = NSImage(cgImage: image, size: .zero)
                } catch { Log.warn("Dock", "窗口缩略图：\(error.localizedDescription)") }
            }
        }
    }

    func activateWindow(_ item: DockWindowItem) {
        guard let app = hoveredApplication else { return }
        if item.isMinimized {
            let result = AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard result == .success else { Toast.show("无法恢复窗口：\(result.rawValue)", isWarning: true); return }
        }
        app.activate(options: [.activateIgnoringOtherApps])
        let result = AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
        guard result == .success else { Toast.show("无法切换窗口：\(result.rawValue)", isWarning: true); return }
        dismiss()
    }

    func isAvailable(_ action: DockHubAction) -> Bool {
        switch action {
        case .panel: return GlobalEntries.isEnabled(GlobalEntries.homeKey)
        case .transfer: return MonitorCenterPresenter.isTransferDockEnabled && Preferences.shared.value(PanelSegments.transferKey, default: true)
        case .monitor: return GlobalEntries.isEnabled(GlobalEntries.monitorPopoutKey)
        default: return true
        }
    }

    func run(_ action: DockHubAction) {
        guard isAvailable(action) else { return }
        dismiss()
        switch action {
        case .panel: ServiceLocator.panel?.show()
        case .clipboard: FloatingClipboardWindowController.shared.show()
        case .transfer: ServiceLocator.panel?.show(); MonitorCenterPresenter.shared.selectTransferDock()
        case .screenshot: ScreenshotManager.shared.captureRegion()
        case .longshot: LongScreenshotCoordinator.shared.beginSelection()
        case .recording: StatsBarEngine.openRecorder()
        case .tools: CommandPaletteController.shared.toggle()
        case .monitor: MonitorPopoutWindowController.shared.open(module: nil)
        case .settings: ServiceLocator.settings?.open(pane: nil)
        case .manual: ServiceLocator.settings?.open(pane: "manual")
        }
    }
}
