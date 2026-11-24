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
    static let widthKey = "floatingBall.width"
    static let heightKey = "floatingBall.height"
    static let defaultPageKey = "floatingBall.defaultPage"
    static let rememberPageKey = "floatingBall.rememberPage"
    static let pagesKey = "floatingBall.pages"
    static let rememberPositionKey = "floatingBall.rememberPosition"
    static let lastDisplayKey = "floatingBall.lastDisplay"
    static let expandOnHoverKey = "floatingBall.expandOnHover"
    static let keepOpenKey = "floatingBall.keepOpen"

    static var actions: [(id: String, title: String, symbol: String)] {
        FloatingBallModule.allCases.map { ($0.rawValue, $0.title, $0.symbol) }
            + [("favorites", "收藏", "star")]
    }
    static let defaultActions = ["capture", "clipboard", "search"]
    static var autoHideEnabled: Bool {
        UserDefaults.standard.object(forKey: autoHideKey) as? Bool ?? true
    }
    static var rememberPosition: Bool {
        UserDefaults.standard.object(forKey: rememberPositionKey) as? Bool ?? true
    }
    static var rememberPage: Bool {
        UserDefaults.standard.object(forKey: rememberPageKey) as? Bool ?? true
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
    static var windowSize: NSSize {
        NSSize(width: CGFloat(UserDefaults.standard.double(forKey: widthKey)).clamped(to: 160...480, fallback: 220),
               height: CGFloat(UserDefaults.standard.double(forKey: heightKey)).clamped(to: 160...480, fallback: 180))
    }
    static func columns(for size: NSSize) -> Int {
        min(gridColumns, max(1, enabledActions.count), max(1, Int((size.width - 12) / (tileSize + 4))))
    }
    static func pageCapacity(for size: NSSize) -> Int {
        columns(for: size) * max(1, Int((size.height - 72) / (tileSize + 4)))
    }
    static func pageCount(for size: NSSize) -> Int {
        max(1, Int(ceil(Double(enabledActions.count) / Double(pageCapacity(for: size)))))
    }
}

public final class FloatingBallController: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = FloatingBallController()
    @Published private(set) var expanded = false
    @Published private(set) var page = 0

    private var panel: NSPanel?
    private var moduleWindow: NSWindow?
    private var observer: NSObjectProtocol?
    private var collapseTask: DispatchWorkItem?
    private var parkedHalfHidden = false
    private var outsideClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var escapeMonitor: Any?
    private var activeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var activeDisplayID: String?
    private var ballOrigin = NSPoint.zero
    private var dragOffset: NSPoint?
    /// 拖动中（DesktopPetView 据此暂停装饰动画）
    var isDragging: Bool { dragOffset != nil }

    private var ballSize: CGFloat {
        CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.sizeKey)).clamped(to: 40...72, fallback: 48)
    }
    private var displayScreen: NSScreen {
        IslandDisplay.available.first { $0.id == activeDisplayID }?.screen ?? screenFor(panel?.frame ?? .zero)
    }
    private var expandedSize: NSSize {
        let visible = displayScreen.visibleFrame
        return NSSize(width: min(FloatingBallSettings.windowSize.width, visible.width),
                      height: min(FloatingBallSettings.windowSize.height, visible.height))
    }
    var columnCount: Int { FloatingBallSettings.columns(for: expandedSize) }
    var pageCount: Int { FloatingBallSettings.pageCount(for: expandedSize) }
    var pageActions: [String] {
        let capacity = FloatingBallSettings.pageCapacity(for: expandedSize)
        return Array(FloatingBallSettings.enabledActions.dropFirst(page * capacity).prefix(capacity))
    }

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
        else { collapse(); panel?.orderOut(nil); collapseTask?.cancel(); removeExpandedMonitors() }
    }

    public func applyConfiguration() {
        guard GlobalEntries.isEnabled(FloatingBallSettings.enabledKey) else { return }
        ensurePanel()
        guard let panel else { return }
        panel.alphaValue = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.opacityKey)).clamped(to: 0.45...1, fallback: 0.92)
        if expanded { positionExpanded(); selectPage(page) }
        else { parkBall(halfHidden: parkedHalfHidden && FloatingBallSettings.autoHideEnabled) }
        pointerLeft()
        objectWillChange.send()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = ballSize
        let p = FloatingBallPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size))
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        p.acceptsMouseMovedEvents = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.delegate = self
        p.title = "Kitnest · 悬浮球与快捷小窗"
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
        let defaults = UserDefaults.standard
        let positions = defaults.dictionary(forKey: FloatingBallSettings.positionsKey) as? [String: [Double]] ?? [:]
        let displays = IslandDisplay.available
        let remembered = displays.first { $0.id == defaults.string(forKey: FloatingBallSettings.lastDisplayKey) }
            ?? displays.first { positions[$0.id] != nil || positions[legacyScreenKey($0.screen)] != nil }
        let screen = FloatingBallSettings.rememberPosition ? (remembered?.screen ?? screenAtPointer()) : screenAtPointer()
        activeDisplayID = screenKey(screen)
        let size = NSSize(width: ballSize, height: ballSize)
        let stable = positions[screenKey(screen)].flatMap { $0.count >= 2
            ? NSPoint(x: screen.visibleFrame.minX + $0[0], y: screen.visibleFrame.minY + $0[1]) : nil }
        let legacy = positions[legacyScreenKey(screen)].flatMap { $0.count >= 2 ? NSPoint(x: $0[0], y: $0[1]) : nil }
        let initial = NSPoint(x: screen.visibleFrame.maxX - size.width - 18, y: screen.visibleFrame.midY)
        ballOrigin = clampedOrigin(FloatingBallSettings.rememberPosition ? (stable ?? legacy ?? initial) : initial,
                                   size: size, screen: screen)
        expanded = false
        parkedHalfHidden = false
        panel.setFrame(NSRect(origin: ballOrigin, size: size), display: true)
        panel.alphaValue = CGFloat(UserDefaults.standard.double(forKey: FloatingBallSettings.opacityKey)).clamped(to: 0.45...1, fallback: 0.92)
        panel.orderFrontRegardless()
        savePosition()
        pointerLeft()
    }

    func toggleExpanded() {
        guard dragOffset == nil else { return }
        if expanded { collapse() }
        else { expand() }
    }

    func expand() {
        guard let panel else { return }
        collapseTask?.cancel()
        parkedHalfHidden = false
        expanded = true
        positionExpanded()
        let saved = UserDefaults.standard.dictionary(forKey: FloatingBallSettings.pagesKey) as? [String: Int]
        let opening = FloatingBallSettings.rememberPage ? saved?[screenKey(displayScreen)] : nil
        selectPage(opening ?? UserDefaults.standard.integer(forKey: FloatingBallSettings.defaultPageKey))
        installExpandedMonitors()
        panel.makeKeyAndOrderFront(nil)
    }

    private func positionExpanded() {
        guard let panel else { return }
        let screen = displayScreen
        let size = expandedSize
        let left = ballOrigin.x + ballSize / 2 < screen.visibleFrame.midX
        let point = NSPoint(x: left ? screen.visibleFrame.minX : screen.visibleFrame.maxX - size.width,
                            y: ballOrigin.y + ballSize / 2 - size.height / 2)
        move(panel, to: NSRect(origin: clampedOrigin(point, size: size, screen: screen), size: size))
    }

    func selectPage(_ requested: Int) {
        page = min(max(requested, 0), pageCount - 1)
        if FloatingBallSettings.rememberPage {
            var pages = UserDefaults.standard.dictionary(forKey: FloatingBallSettings.pagesKey) as? [String: Int] ?? [:]
            pages[screenKey(displayScreen)] = page
            UserDefaults.standard.set(pages, forKey: FloatingBallSettings.pagesKey)
        }
    }

    func pointerEntered() {
        collapseTask?.cancel()
        guard dragOffset == nil else { return }
        if parkedHalfHidden { parkBall(halfHidden: false) }
        if !expanded, UserDefaults.standard.bool(forKey: FloatingBallSettings.expandOnHoverKey) {
            let task = DispatchWorkItem { [weak self] in self?.expand() }
            collapseTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
        }
    }

    func pointerLeft() {
        collapseTask?.cancel()
        guard dragOffset == nil else { return }
        if expanded && UserDefaults.standard.bool(forKey: FloatingBallSettings.keepOpenKey) { return }
        if !expanded && !FloatingBallSettings.autoHideEnabled { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.expanded { self.collapse() }
            else { self.parkBall(halfHidden: true) }
        }
        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: task)
    }

    func collapse() {
        guard expanded else { return }
        collapseTask?.cancel()
        expanded = false
        removeExpandedMonitors()
        parkBall(halfHidden: FloatingBallSettings.autoHideEnabled)
        panel?.resignKey()
    }

    func dragChanged() {
        guard let panel else { return }
        collapseTask?.cancel()
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil { dragOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY) }
        panel.setFrameOrigin(NSPoint(x: mouse.x - dragOffset!.x, y: mouse.y - dragOffset!.y))
    }

    func dragEnded() {
        guard let panel else { return }
        activeDisplayID = screenKey(screenFor(panel.frame))
        ballOrigin = panel.frame.origin
        parkBall(halfHidden: false)
        // 2026-11-21：同一个释放事件也会到达球面按钮，处理完后才恢复点击。
        DispatchQueue.main.async {
            self.dragOffset = nil
            self.pointerLeft()
        }
    }

    // MARK: - 海豚桌面精灵

    /// 双击海豚：执行自定义动作（默认 = 展开面板）
    func petDoubleTap() {
        let action = DesktopPetSettings.doubleClickAction
        if action.isEmpty || action == "expand" {
            toggleExpanded()
        } else {
            run(action)
        }
    }

    /// 隐藏精灵（收起并隐藏面板）
    func hidePet() {
        collapse()
        panel?.orderOut(nil)
    }

    /// 退出精灵（关闭桌面精灵功能，回退普通悬浮球）
    func quitPet() {
        UserDefaults.standard.set(false, forKey: DesktopPetSettings.enabledKey)
        applyConfiguration()
        objectWillChange.send()
    }

    private func parkBall(halfHidden: Bool) {
        guard let panel else { return }
        let screen = displayScreen
        let size = NSSize(width: ballSize, height: ballSize)
        let left = ballOrigin.x + ballSize / 2 < screen.visibleFrame.midX
        ballOrigin = clampedOrigin(NSPoint(x: left ? screen.visibleFrame.minX : screen.visibleFrame.maxX - ballSize,
                                          y: ballOrigin.y), size: size, screen: screen)
        parkedHalfHidden = halfHidden
        // v266：半隐藏也以 visibleFrame 为界。旧代码用 screen.frame，
        // 侧边 Dock 常驻时球会退到 Dock 底下（可见 0pt）。
        let edge = screen.visibleFrame
        let x = halfHidden ? (left ? edge.minX + 16 - ballSize : edge.maxX - 16) : ballOrigin.x
        move(panel, to: NSRect(x: x, y: ballOrigin.y, width: ballSize, height: ballSize))
        savePosition()
    }

    private func installExpandedMonitors() {
        guard outsideClickMonitor == nil else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, self.expanded, event.window !== self.panel else { return event }
            self.collapse()
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in self?.collapse() }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.expanded, event.keyCode == 53 else { return event }
            self.collapse()
            return nil
        }
    }

    private func removeExpandedMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor); self.globalClickMonitor = nil }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }

    public func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === panel, expanded { collapse() }
    }

    public func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === moduleWindow { moduleWindow?.contentView = nil }
    }

    func run(_ id: String) {
        collapse()
        switch id {
        case "capture":
            panel?.orderOut(nil)
            ScreenshotManager.shared.captureRegion { [weak self] in self?.show() }
        case "clipboard": FloatingClipboardWindowController.shared.toggle()
        case "search": CommandPaletteController.shared.show()
        case "tools", "toolbox": openModule(.tools)
        case "monitor": MonitorPopoutWindowController.shared.toggle()
        case "favorites": FavoritesWindowController.shared.show()
        case "statistics": StatisticsWindowController.shared.openStatistics()
        case "archive": ArchiveFileBoxWindow.show()
        case "ocr": CaptureModule.capture(.ocr)
        default:
            guard let module = FloatingBallModule(rawValue: id) else { return }
            openModule(module)
        }
    }

    private func openModule(_ module: FloatingBallModule) {
        if moduleWindow == nil {
            let visible = displayScreen.visibleFrame
            let size = NSSize(width: min(640, visible.width), height: min(520, visible.height))
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 360, height: 280)
            window.delegate = self
            // 2026-11-23：模块窗补统一外观入口（此前是裸 NSWindow 默认灰底，
            // 与全 App 内容窗的玻璃/圆角/红绿灯口径割裂）。
            window.applyOfficialChrome()
            moduleWindow = window
        }
        let host = NSHostingView(rootView: FloatingBallModuleView(module: module))
        host.sizingOptions = []
        moduleWindow?.title = "Kitnest · " + module.title
        // 换内容走 setOfficialContent：保证玻璃底重挂到新内容之下（v272 契约）
        moduleWindow?.setOfficialContent(host)
        moduleWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func move(_ panel: NSPanel, to frame: NSRect) {
        panel.setFrame(frame, display: true, animate: true)
    }

    private func savePosition() {
        guard FloatingBallSettings.rememberPosition else { return }
        let screen = displayScreen
        let key = screenKey(screen)
        var positions = UserDefaults.standard.dictionary(forKey: FloatingBallSettings.positionsKey) as? [String: [Double]] ?? [:]
        positions[key] = [Double(ballOrigin.x - screen.visibleFrame.minX), Double(ballOrigin.y - screen.visibleFrame.minY)]
        UserDefaults.standard.set(positions, forKey: FloatingBallSettings.positionsKey)
        UserDefaults.standard.set(key, forKey: FloatingBallSettings.lastDisplayKey)
    }

    private func clampToConnectedScreen() {
        guard let panel, panel.isVisible else { return }
        let screen = screenFor(panel.frame)
        activeDisplayID = IslandDisplay.available.first { $0.id == activeDisplayID }?.id ?? screenKey(screen)
        if FloatingBallSettings.rememberPosition,
           let point = (UserDefaults.standard.dictionary(forKey: FloatingBallSettings.positionsKey) as? [String: [Double]])?[screenKey(displayScreen)] {
            ballOrigin = NSPoint(x: displayScreen.visibleFrame.minX + point[0], y: displayScreen.visibleFrame.minY + point[1])
        }
        applyConfiguration()
    }

    private func screenAtPointer() -> NSScreen { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main! }
    private func screenFor(_ rect: NSRect) -> NSScreen {
        NSScreen.screens.max {
            let left = $0.frame.intersection(rect), right = $1.frame.intersection(rect)
            return left.width * left.height < right.width * right.height
        } ?? screenAtPointer()
    }
    private func screenKey(_ screen: NSScreen) -> String {
        IslandDisplay(screen: screen)!.id
    }
    private func legacyScreenKey(_ screen: NSScreen) -> String {
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
    private var actions: [String] { controller.pageActions }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(FloatingBallSettings.tileSize), spacing: 4),
              count: controller.columnCount)
    }

    var body: some View {
        Group {
            if controller.expanded {
                VStack(spacing: 6) {
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
                                        // 2026-11-23：热区圆角 10 → Theme.Radius.card（取值不变）
                                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                                }
                                .buttonStyle(.plain).help(action.title).accessibilityLabel(action.title)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    HStack(spacing: 12) {
                        // v266：悬浮球自己必须能进设置——否则关掉菜单栏/刘海后
                        // 用户只剩这颗球，却没有配置出口（入口统一要求）。
                        Button {
                            controller.collapse()
                            SettingsWindowController.shared.open(pane: "floatingBall")
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .help("打开悬浮球设置")
                        .accessibilityLabel("打开悬浮球设置")
                        Spacer(minLength: 0)
                        Button { controller.selectPage(controller.page - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(controller.page == 0).help("上一页")
                        Text("\(controller.page + 1) / \(controller.pageCount)").monospacedDigit().font(.system(size: 11))
                        Button { controller.selectPage(controller.page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(controller.page + 1 == controller.pageCount).help("下一页")
                    }.buttonStyle(.plain).frame(height: 24)
                }
            } else if DesktopPetSettings.isEnabled {
                // 海豚精灵模式：实体 Sprite，不套玻璃材质
                DesktopPetView(
                    appearance: DesktopPetSettings.appearance,
                    isDragging: controller.isDragging,
                    onTap: { controller.toggleExpanded() },
                    onDoubleTap: { controller.petDoubleTap() },
                    onOpenSettings: {
                        controller.collapse()
                        SettingsWindowController.shared.open(pane: "floatingBall")
                    },
                    onHide: { controller.hidePet() },
                    onQuit: { controller.quitPet() }
                )
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { _ in controller.dragChanged() }
                    .onEnded { _ in controller.dragEnded() })
            } else {
                Button(action: controller.toggleExpanded) {
                    VStack(spacing: 2) {
                        Image(systemName: "sparkle").font(.system(size: 17, weight: .semibold))
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 8))
                    }.frame(width: size, height: size).contentShape(Circle())
                }
                .buttonStyle(.plain).help("点击展开快捷窗；按住球面拖动，松手左右贴边")
                .accessibilityLabel("Kitnest 快捷入口").accessibilityHint("点击展开，按住拖动")
                .simultaneousGesture(DragGesture(minimumDistance: 4)
                    .onChanged { _ in controller.dragChanged() }
                    .onEnded { _ in controller.dragEnded() })
            }
        }
        .padding(controller.expanded ? 8 : 0)
        .foregroundStyle(.primary)
        // 统一玻璃面 glassPlate；海豚精灵是实体 Sprite 不套玻璃（R2：不混第二种玻璃实现）。
        // 展开面板 / 普通悬浮球仍走 glassPlate——真玻璃 + cardStroke 发丝边；
        // 阴影由窗口级 hasShadow 承担。壳圆角：收起 = size/2 正圆、展开 22 与球缘连续。
        .modifier(ConditionalGlassPlate(
            active: controller.expanded || !DesktopPetSettings.isEnabled,
            radius: controller.expanded ? 22 : size / 2))
        .onHover { $0 ? controller.pointerEntered() : controller.pointerLeft() }
        .onExitCommand { controller.collapse() }
    }
}

/// 悬浮球快捷窗里能放的组件。Lite 版没有中转、投屏与刘海，
/// 只留能独立渲染的页面；纯动作类（截图 / 识别 / 搜索）点一下直接执行。
enum FloatingBallModule: String, CaseIterable, Identifiable {
    case monitor, media, calendar, clipboard, tools, volume, search, capture, ocr, archive, statistics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monitor: return "性能监测"
        case .media: return "声音与播放"
        case .calendar: return "日程与待办"
        case .clipboard: return "剪贴板"
        case .tools: return "快捷工具"
        case .volume: return "系统音量"
        case .search: return "全局搜索"
        case .capture: return "截图与标注"
        case .ocr: return "识别与翻译"
        case .archive: return "压缩与解压"
        case .statistics: return "使用统计"
        }
    }
    var symbol: String {
        switch self {
        case .monitor: return "waveform.path.ecg"
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .clipboard: return "doc.on.clipboard"
        case .tools: return "square.grid.2x2"
        case .volume: return "speaker.wave.2"
        case .search: return "magnifyingglass"
        case .capture: return "viewfinder"
        case .ocr: return "text.viewfinder"
        case .archive: return "archivebox"
        case .statistics: return "chart.bar"
        }
    }
}

private struct FloatingBallModuleView: View {
    let module: FloatingBallModule

    var body: some View {
        Group {
            switch module {
            case .monitor:
                MonitorPerformanceContent()
            case .clipboard:
                ScrollView { ClipboardSectionView().padding() }
            case .calendar:
                ScrollView { CalendarSectionView().padding() }
            case .tools:
                ScrollView { ToolboxSectionView().padding() }
            case .media, .volume:
                AudioMixerPane()
            case .search, .capture, .ocr, .archive, .statistics:
                Text("\(module.title)会在主窗口里打开")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// 条件玻璃：海豚精灵（实体 Sprite）不套 glassPlate，展开面板 / 普通球仍走统一玻璃面。
private struct ConditionalGlassPlate: ViewModifier {
    let active: Bool
    let radius: CGFloat
    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.glassPlate(radius: radius)
        } else {
            content
        }
    }
}
