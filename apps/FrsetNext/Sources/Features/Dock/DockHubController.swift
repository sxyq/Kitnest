import AppKit
import SwiftUI
import ApplicationServices

enum DockHubSection: String, CaseIterable { case tools, calendar, media, windows }
enum DockHubAction: CaseIterable { case panel, clipboard, transfer, screenshot, longshot, recording, tools, monitor, settings }

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

/// Dock 只负责定位，功能仍进入现有正式控制器；紧凑卡与完整窗复用一个窗口。
final class DockHubController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = DockHubController()
    static let enabledKey = "dock.hub.enabled"
    static var savedEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    @Published var section: DockHubSection = .tools {
        didSet {
            if section == .windows { reloadWindows() }
            else { thumbnailTask?.cancel(); windowLoad += 1 }
        }
    }
    @Published private(set) var isExpanded = false
    @Published private(set) var hoveredApplication: NSRunningApplication?
    @Published private(set) var windows: [DockWindowItem] = []
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var window: NSWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverWork: DispatchWorkItem?
    private var hitWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var pendingPID: pid_t?
    private var dockElement: AXUIElement?
    private var anchor: NSRect?
    private var lastHitTime: TimeInterval = 0
    private var generation = 0
    private var windowLoad = 0
    private var thumbnailTask: Task<Void, Never>?

    func start() {
        NSApp.setActivationPolicy(Self.savedEnabled ? .regular : .accessory)
        guard Self.savedEnabled, globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.pointerMoved()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        Log.info("Dock", "Dock 悬停入口已启用；辅助功能=\(AXIsProcessTrusted())")
    }

    func stop() {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        localMonitor = nil
        dockElement = nil
        hitWork?.cancel()
        cancelHover()
        dismiss(animated: false)
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
        guard !isExpanded else { return }
        let point = NSEvent.mouseLocation
        if let window, window.isVisible,
           (window.frame.contains(point) || anchor.map { transitRect(from: $0, to: window.frame).contains(point) } == true) {
            leaveWork?.cancel()
            leaveWork = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        hitWork?.cancel()
        if now - lastHitTime < 0.08 {
            let work = DispatchWorkItem { [weak self] in self?.pointerMoved() }
            hitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            return
        }
        lastHitTime = now
        let granted = AXIsProcessTrusted()
        if accessibilityGranted != granted { accessibilityGranted = granted }
        guard accessibilityGranted, let hit = dockHit(at: point) else {
            cancelHover()
            if window?.isVisible == true, leaveWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.dismiss() }
                leaveWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            }
            return
        }
        leaveWork?.cancel()
        leaveWork = nil
        if hoveredApplication?.processIdentifier == hit.app.processIdentifier, window?.isVisible == true { return }
        guard pendingPID != hit.app.processIdentifier else { return }
        cancelHover()
        pendingPID = hit.app.processIdentifier
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.dockHit(at: NSEvent.mouseLocation),
                  current.app.processIdentifier == hit.app.processIdentifier else { return }
            self.pendingPID = nil
            self.hoveredApplication = current.app
            self.anchor = current.frame
            switch current.app.bundleIdentifier {
            case Bundle.main.bundleIdentifier: self.section = .tools
            case "com.apple.iCal": self.section = .calendar
            case "com.apple.Music", "com.spotify.client": self.section = .media
            default: self.section = .windows
            }
            self.present(expanded: false, activate: false)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func transitRect(from icon: NSRect, to panel: NSRect) -> NSRect {
        if icon.maxX < panel.minX {
            return NSRect(x: icon.minX, y: icon.minY - 8, width: panel.minX - icon.minX + 8, height: icon.height + 16)
        }
        if icon.minX > panel.maxX {
            return NSRect(x: panel.maxX - 8, y: icon.minY - 8, width: icon.maxX - panel.maxX + 8, height: icon.height + 16)
        }
        return NSRect(x: icon.minX - 8, y: icon.minY, width: icon.width + 16, height: max(0, panel.minY - icon.minY) + 8)
    }

    private func cancelHover() {
        hoverWork?.cancel()
        hoverWork = nil
        pendingPID = nil
    }

    /// AX 坐标为主屏左上原点；不用固定 Dock 高度，支持左右侧、自动隐藏及多屏。
    private func dockHit(at point: NSPoint) -> (app: NSRunningApplication, frame: NSRect)? {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        if dockElement == nil, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            dockElement = AXUIElementCreateApplication(dock.processIdentifier)
            AXUIElementSetMessagingTimeout(dockElement!, 0.05)
        }
        guard let dockElement else { return nil }
        guard let list = (attribute(dockElement, kAXChildrenAttribute) as? [AXUIElement])?.first else {
            self.dockElement = nil
            return nil
        }
        guard let item = (attribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement])?.first,
              attribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              let url = attribute(item, kAXURLAttribute) as? URL,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }),
              let p = attribute(item, kAXPositionAttribute), let s = attribute(item, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &position)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        let frame = NSRect(x: position.x, y: primaryTop - position.y - size.height, width: size.width, height: size.height)
        return frame.contains(point) ? (app, frame) : nil
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
        if window?.isVisible != true {
            hoveredApplication = NSWorkspace.shared.frontmostApplication
            if hoveredApplication?.processIdentifier == getpid() { hoveredApplication = nil }
        }
        if let selected { section = selected }
        else if section == .windows { reloadWindows() }
        present(expanded: expanded, activate: true)
    }

    // 原生窗形态不能在 SwiftUI 键盘动作的焦点更新栈里切换；退出该次动作后再改窗。
    func expand() { DispatchQueue.main.async { self.present(expanded: true, activate: true) } }
    func collapse() { DispatchQueue.main.async { self.present(expanded: false, activate: true) } }

    private func present(expanded: Bool, activate: Bool) {
        if let window, window.isVisible, window.contentView?.layer?.opacity != 0, expanded == isExpanded, activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        generation += 1
        leaveWork?.cancel()
        leaveWork = nil
        let changingMode = window?.isVisible == true && expanded != isExpanded
        isExpanded = expanded
        let window: NSWindow
        if let existing = self.window { window = existing }
        else {
            window = DockHubWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.title = "Kitnest · Dock 控制台"
            window.identifier = NSUserInterfaceItemIdentifier("kitnest.dock.hub")
            window.contentView = nil
            self.window = window
        }
        if changingMode { window.makeFirstResponder(nil); window.orderOut(nil) }
        TransientWindowCenter.shared.unregister(window: window)
        window.styleMask = expanded ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : .borderless
        window.level = expanded ? .normal : .floating
        window.collectionBehavior = expanded ? [.fullScreenAuxiliary] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } } ?? NSScreen.main ?? NSScreen.screens.first!
        let available = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let size = NSSize(width: min(expanded ? 760 : 360, available.width), height: min(expanded ? 560 : 420, available.height))
        window.minSize = size
        window.maxSize = size
        var frame = NSRect(origin: NSPoint(x: available.midX - size.width / 2, y: available.midY - size.height / 2), size: size)
        if !expanded, let anchor {
            let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
            if orientation == "left" {
                frame.origin = NSPoint(x: anchor.maxX + 8, y: anchor.midY - size.height / 2)
            } else if orientation == "right" {
                frame.origin = NSPoint(x: anchor.minX - size.width - 8, y: anchor.midY - size.height / 2)
            } else {
                frame.origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8)
            }
        }
        frame.origin.x = min(max(frame.minX, available.minX), available.maxX - size.width)
        frame.origin.y = min(max(frame.minY, available.minY), available.maxY - size.height)
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
        window.applyOfficialChrome(glassBacking: false, lights: expanded ? .fixed : .hidden)
        window.setFrame(frame, display: false)
        WindowReveal.reset(window)
        if !expanded { TransientWindowCenter.shared.register(window: window) { [weak self] in self?.dismiss() } }
        if activate { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        else { window.orderFrontRegardless() }
        if changingMode || !window.isKeyWindow || activate {
            WindowReveal.playIn(on: window, from: CGPoint(x: 0.5, y: expanded ? 0.5 : 1),
                                scale: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0.96,
                                duration: 0.14)
        }
        Log.info("Dock", "\(expanded ? "完整窗" : "紧凑卡") section=\(section.rawValue) size=\(size)")
    }

    func dismiss(animated: Bool = true) {
        cancelHover()
        leaveWork?.cancel()
        leaveWork = nil
        thumbnailTask?.cancel()
        windowLoad += 1
        guard let window else { return }
        generation += 1
        let current = generation
        TransientWindowCenter.shared.unregister(window: window)
        let finish = { [weak self] in
            guard let self, self.generation == current else { return }
            window.orderOut(nil)
            window.contentView = nil
            WindowReveal.reset(window)
            self.isExpanded = false
            self.windows = []
        }
        if animated, window.isVisible {
            WindowReveal.playOutToLastAnchor(on: window, duration: 0.12, completion: finish)
        } else { finish() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func windowDidResignKey(_ notification: Notification) {
        if !isExpanded, let window { TransientWindowCenter.shared.requestDismiss(window: window) }
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
        dismiss(animated: false)
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
        dismiss(animated: false)
        switch action {
        case .panel: ServiceLocator.panel?.show()
        case .clipboard: FloatingClipboardWindowController.shared.show()
        case .transfer: ServiceLocator.panel?.show(); MonitorCenterPresenter.shared.selectTransferDock()
        case .screenshot: ScreenshotManager.shared.captureRegion()
        case .longshot: LongScreenshotCoordinator.shared.beginSelection()
        case .recording: StatsBarEngine.openRecorder()
        case .tools: CommandPaletteController.shared.toggle()
        case .monitor: MonitorPopoutWindowController.shared.open(module: nil)
        case .settings: ServiceLocator.settings?.open(pane: "dock")
        }
    }
}
