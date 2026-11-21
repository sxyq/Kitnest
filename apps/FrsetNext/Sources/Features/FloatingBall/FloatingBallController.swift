import AppKit
import SwiftUI

enum FloatingBallSettings {
    static let enabledKey = "entry.floatingBall"
    static let actionsKey = "floatingBall.actions"
    static let orderKey = "floatingBall.actionOrder"
    static let sizeKey = "floatingBall.size"
    static let tileSizeKey = "floatingBall.tileSize"
    static let gridColumnsKey = "floatingBall.gridColumns"
    static let opacityKey = "floatingBall.opacity"
    static let autoHideKey = "floatingBall.autoHide"
    static let positionsKey = "floatingBall.positions"

    static var actions: [(id: String, title: String, symbol: String)] {
        IslandWidget.allCases.map { ($0.rawValue, $0.title, $0.icon) }
            + [("favorites", "收藏", "star")]
    }
    static let defaultActions = ["capture", "clipboard", "search"]
    static var autoHideEnabled: Bool {
        UserDefaults.standard.object(forKey: autoHideKey) as? Bool ?? true
    }
    static var orderedActions: [(id: String, title: String, symbol: String)] {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? actions.map(\.id)
        var ids = saved.map { $0 == "toolbox" ? "tools" : $0 }
            .filter { id in actions.contains(where: { $0.id == id }) }
        for action in actions where !ids.contains(action.id) { ids.append(action.id) }
        return ids.compactMap { id in actions.first(where: { $0.id == id }) }
    }
    static var enabledActions: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: actionsKey) ?? defaultActions
        let selected = Set(stored.map { $0 == "toolbox" ? "tools" : $0 })
        return orderedActions.map(\.id).filter { selected.contains($0) }
    }
    static var tileSize: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: tileSizeKey)).clamped(to: 36...64, fallback: 44)
    }
    static var gridColumns: Int {
        let value = UserDefaults.standard.integer(forKey: gridColumnsKey)
        return value == 0 ? 4 : min(max(value, 2), 6)
    }
    static func expandedSize(ballSize: CGFloat) -> NSSize {
        let count = enabledActions.count
        let columns = min(gridColumns, max(1, count))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let side = tileSize + 4
        return NSSize(width: CGFloat(columns) * side + 20,
                      height: CGFloat(rows) * side + ballSize + 22)
    }
}

public final class FloatingBallController: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = FloatingBallController()
    @Published private(set) var expanded = false

    private var panel: NSPanel?
    private var observer: NSObjectProtocol?
    private var collapseTask: DispatchWorkItem?
    private var expandedEdge: Int?
    private var movingProgrammatically = false
    private var parkedHalfHidden = false
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var positionSaveTask: DispatchWorkItem?
    private var activeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private override init() { super.init() }

    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: GlobalEntries.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.applyEnabledState() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in if self?.expanded == true { self?.collapse() } }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.clampToConnectedScreen() }
        applyEnabledState()
    }

    public func applyEnabledState() {
        if GlobalEntries.isEnabled(FloatingBallSettings.enabledKey) { show() }
        else { panel?.orderOut(nil); collapseTask?.cancel(); removeExpandedMonitors(); expanded = false }
    }

    public func applyConfiguration() {
        guard GlobalEntries.isEnabled(FloatingBallSettings.enabledKey) else { return }
        ensurePanel()
        guard let panel else { return }
        panel.alphaValue = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.opacityKey)).clamped(to: 0.45...1, fallback: 0.92)
        let size = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.sizeKey)).clamped(to: 40...72, fallback: 48)
        let frame = panel.frame
        let target = expanded ? FloatingBallSettings.expandedSize(ballSize: size) : NSSize(width: size, height: size)
        let screen = screenFor(frame)
        let left = expanded ? expandedEdge == 0 : frame.midX < screen.frame.midX
        let x = left ? screen.visibleFrame.minX : screen.visibleFrame.maxX - target.width
        let y = clampedOrigin(NSPoint(x: frame.minX, y: frame.midY - target.height / 2), size: target, screen: screen).y
        move(panel, to: NSRect(origin: NSPoint(x: x, y: y), size: target))
        objectWillChange.send()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.sizeKey)).clamped(to: 40...72, fallback: 48)
        let p = FloatingBallPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size))
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.acceptsMouseMovedEvents = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.delegate = self
        let host = NSHostingView(rootView: FloatingBallView(controller: self))
        host.sizingOptions = []
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        p.contentView = host
        panel = p
    }

    public func show() {
        ensurePanel()
        guard let panel else { return }
        if panel.isVisible { return }
        let screen = screenAtPointer()
        let key = screenKey(screen)
        let positions = UserDefaults.standard.dictionary(forKey: FloatingBallSettings.positionsKey) as? [String: [Double]]
        let size = panel.frame.size
        let point = positions?[key].flatMap { $0.count >= 2 ? NSPoint(x: $0[0], y: $0[1]) : nil }
            ?? NSPoint(x: screen.visibleFrame.maxX - size.width - 18, y: screen.visibleFrame.midY)
        panel.setFrameOrigin(clampedOrigin(point, size: size, screen: screen))
        panel.alphaValue = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.opacityKey)).clamped(to: 0.45...1, fallback: 0.92)
        panel.orderFrontRegardless()
    }

    func toggleExpanded() {
        if expanded { collapse() }
        else { expand() }
    }

    func expand() {
        guard let panel else { return }
        collapseTask?.cancel()
        let screen = screenFor(panel.frame)
        let edge = panel.frame.midX < screen.frame.midX ? 0 : 1
        expandedEdge = edge
        parkedHalfHidden = false
        expanded = true
        installExpandedMonitors()
        let ball = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.sizeKey)).clamped(to: 40...72, fallback: 48)
        let size = FloatingBallSettings.expandedSize(ballSize: ball)
        let x = edge == 0 ? screen.visibleFrame.minX : screen.visibleFrame.maxX - size.width
        let y = clampedOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY),
                              size: size, screen: screen).y
        move(panel, to: NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    func pointerEntered() {
        collapseTask?.cancel()
        if parkedHalfHidden { expand() }
    }

    func pointerLeft() {
        guard expanded, FloatingBallSettings.autoHideEnabled else { return }
        let task = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: task)
    }

    func collapse() {
        guard let panel, expanded else { return }
        collapseTask?.cancel()
        let screen = screenFor(panel.frame)
        let ball = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.sizeKey)).clamped(to: 40...72, fallback: 48)
        let left = expandedEdge == 0
        let autoHide = FloatingBallSettings.autoHideEnabled
        parkedHalfHidden = autoHide
        let x: CGFloat
        if autoHide { x = left ? screen.visibleFrame.minX - ball + 16 : screen.visibleFrame.maxX - 16 }
        else { x = left ? screen.visibleFrame.minX : screen.visibleFrame.maxX - ball }
        expanded = false
        removeExpandedMonitors()
        move(panel, to: NSRect(x: x, y: panel.frame.midY - ball / 2, width: ball, height: ball))
    }

    private func installExpandedMonitors() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.expanded, event.window !== self.panel else { return event }
            self.collapse()
            return event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.expanded, event.keyCode == 53 else { return event }
            self.collapse()
            return nil
        }
    }

    private func removeExpandedMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }

    public func windowDidResignKey(_ notification: Notification) {
        if expanded { collapse() }
    }

    func run(_ id: String) {
        collapse()
        switch id {
        case "capture":
            panel?.orderOut(nil)
            ScreenshotManager.shared.captureRegion { [weak self] in self?.show() }
        case "clipboard": FloatingClipboardWindowController.shared.toggle()
        case "search", "tools", "toolbox": CommandPaletteController.shared.show()
        case "monitor": MonitorPopoutWindowController.shared.toggle()
        case "favorites": FavoritesWindowController.shared.show()
        default:
            guard let widget = IslandWidget(rawValue: id) else { return }
            IslandController.shared.open(page: widget.page)
        }
    }

    private func move(_ panel: NSPanel, to frame: NSRect) {
        movingProgrammatically = true
        panel.setFrame(frame, display: true, animate: true)
        DispatchQueue.main.async { self.movingProgrammatically = false }
    }

    public func windowDidMove(_ notification: Notification) {
        guard !movingProgrammatically, let panel else { return }
        let screen = screenFor(panel.frame)
        let key = screenKey(screen)
        positionSaveTask?.cancel()
        let point = panel.frame.origin
        let task = DispatchWorkItem {
            var positions = UserDefaults.standard.dictionary(forKey: FloatingBallSettings.positionsKey) as? [String: [Double]] ?? [:]
            positions[key] = [Double(point.x), Double(point.y)]
            UserDefaults.standard.set(positions, forKey: FloatingBallSettings.positionsKey)
        }
        positionSaveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
    }

    private func clampToConnectedScreen() {
        guard let panel, panel.isVisible else { return }
        let screen = screenFor(panel.frame)
        let origin = clampedOrigin(panel.frame.origin, size: panel.frame.size, screen: screen)
        move(panel, to: NSRect(origin: origin, size: panel.frame.size))
    }

    private func screenAtPointer() -> NSScreen { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main! }
    private func screenFor(_ rect: NSRect) -> NSScreen { NSScreen.screens.first { $0.frame.intersects(rect) } ?? screenAtPointer() }
    private func screenKey(_ screen: NSScreen) -> String {
        String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }
    private func clampedOrigin(_ point: NSPoint, size: NSSize, screen: NSScreen) -> NSPoint {
        NSPoint(x: min(max(point.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width),
                y: min(max(point.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height))
    }
}

private struct FloatingBallView: View {
    @ObservedObject var controller: FloatingBallController
    private var size: CGFloat { CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.sizeKey)).clamped(to: 40...72, fallback: 48) }
    private var actions: [String] { FloatingBallSettings.enabledActions }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(FloatingBallSettings.tileSize), spacing: 4),
              count: min(FloatingBallSettings.gridColumns, max(1, actions.count)))
    }

    var body: some View {
        Group {
            if controller.expanded {
                VStack(spacing: 5) {
                    Button(action: controller.collapse) {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                    }.buttonStyle(.plain).help("收起快捷窗")
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(actions, id: \.self) { id in
                            if let action = FloatingBallSettings.actions.first(where: { $0.id == id }) {
                                Button { controller.run(id) } label: {
                                    Image(systemName: action.symbol).font(.system(size: 15, weight: .medium))
                                        .frame(width: FloatingBallSettings.tileSize, height: FloatingBallSettings.tileSize)
                                        .contentShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain).help(action.title).accessibilityLabel(action.title)
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Button(action: controller.toggleExpanded) {
                        Image(systemName: "sparkle").font(.system(size: 17, weight: .semibold))
                            .frame(width: size - 12, height: size - 12).contentShape(Circle())
                    }.buttonStyle(.plain).help("Kitnest 快捷入口")
                }
            }
        }
        .padding(controller.expanded ? 8 : 0)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: controller.expanded ? 22 : size / 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: controller.expanded ? 22 : size / 2, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .onHover { $0 ? controller.pointerEntered() : controller.pointerLeft() }
        .onExitCommand { controller.collapse() }
    }
}

private final class FloatingBallPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        self == 0 ? fallback : Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
