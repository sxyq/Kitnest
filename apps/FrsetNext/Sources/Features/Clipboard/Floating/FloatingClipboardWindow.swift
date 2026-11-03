import AppKit
import Foundation
import SwiftUI

// MARK: - 浮动窗几何与钉住状态（05 号规格 1.4 + B8）

/// 浮动窗状态：几何 + 可见性 + 钉住位，全部落到 Preferences（`floatingClipboard.*`）
public final class FloatingClipboardPinState: ObservableObject {

    public static let shared = FloatingClipboardPinState()

    /// v191：悬浮剪贴板改成"能独立用完全程"的工作台——默认 680×520，可缩放
    /// （旧版 240×290 只是主面板列表的缩小版，装不下卡片网格与分类行）
    public static let defaultWidth: CGFloat = 680
    public static let defaultHeight: CGFloat = 520

    private let preferences = Preferences.shared

    private init() {}

    public var originX: CGFloat {
        let v = preferences.value(Preferences.Keys.floatingOriginX, default: -1.0)
        return v < 0 ? Self.centeredOriginX : v
    }
    public var originY: CGFloat {
        let v = preferences.value(Preferences.Keys.floatingOriginY, default: -1.0)
        return v < 0 ? Self.centeredOriginY : v
    }
    public var width: CGFloat {
        let v = preferences.value(Preferences.Keys.floatingWidth, default: Double(Self.defaultWidth))
        return v > 0 ? v : Self.defaultWidth
    }
    public var height: CGFloat {
        let v = preferences.value(Preferences.Keys.floatingHeight, default: Double(Self.defaultHeight))
        return v > 0 ? v : Self.defaultHeight
    }

    /// v191：工作台版式迁移。
    /// 旧版是 240×290 的单列小列表，用户还可能拖到过很怪的高度（实测存过 478×1074，
    /// 那是 SwiftUI fitting-size 把窗口撑大的历史产物）。升到工作台后旧值一律作废，
    /// 一次性重置成 680×520；之后用户自己缩放的尺寸正常保留。
    private static let layoutVersionKey = "floatingClipboard.layoutVersion"
    private static let currentLayoutVersion = 2

    public func migrateLayoutIfNeeded() {
        let saved: Int = preferences.value(Self.layoutVersionKey, default: 0)
        guard saved < Self.currentLayoutVersion else { return }
        preferences.set(Preferences.Keys.floatingWidth, Double(Self.defaultWidth))
        preferences.set(Preferences.Keys.floatingHeight, Double(Self.defaultHeight))
        preferences.set(Self.layoutVersionKey, Self.currentLayoutVersion)
    }

    /// 是否可见（持久化，下次启动自动恢复）
    public var isVisible: Bool {
        get { preferences.value(Preferences.Keys.floatingVisible, default: false) }
        set { preferences.set(Preferences.Keys.floatingVisible, newValue) }
    }

    /// 钉住：始终置顶显示（不随主面板关闭而隐藏）
    public var isPinned: Bool {
        get { preferences.value(Preferences.Keys.floatingPinned, default: true) }
        set { preferences.set(Preferences.Keys.floatingPinned, newValue) }
    }

    public func save(frame: NSRect) {
        preferences.set(Preferences.Keys.floatingOriginX, Double(frame.origin.x))
        preferences.set(Preferences.Keys.floatingOriginY, Double(frame.origin.y))
        preferences.set(Preferences.Keys.floatingWidth, Double(frame.size.width))
        preferences.set(Preferences.Keys.floatingHeight, Double(frame.size.height))
    }

    /// 屏幕尺寸变化后可能越界，取回可视的兜底坐标
    public func clampedFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 200, y: 200, width: width, height: height)
        }
        let visible = screen.visibleFrame
        let w = min(width, visible.width)
        let h = min(height, visible.height)
        let x = min(max(originX, visible.minX), max(visible.maxX - w, visible.minX))
        let y = min(max(originY, visible.minY), max(visible.maxY - h, visible.minY))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private static var centeredOriginX: CGFloat {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return screen.midX - Self.defaultWidth / 2
    }
    private static var centeredOriginY: CGFloat {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return screen.midY - Self.defaultHeight / 2
    }
}

// MARK: - 浮动面板（05 号规格 1.4：FloatingClipboardPanel）

/// 独立 NSPanel：默认 240×290，置顶在所有空间之上，背景可拖动
public final class FloatingClipboardPanel: NSPanel {

    public init(contentRect: NSRect) {
        // v201（用户：「只有红绿灯悬在那，没有一条横向界面和下面连在一起」）：
        // 标准标题栏与内容之间出现了断层。改为 fullSizeContentView + 透明标题栏：
        // 内容铺满整窗（含标题栏区域），同一块玻璃底从红绿灯一直连到底部；
        // SwiftUI 根视图顶部留 28pt 给红绿灯，标题文字隐藏。
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable,
                               .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        title = "悬浮剪贴板"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
        // fullSizeContentView 下 hosting 盖住标题栏，窗口拖动改由「空白背景拖动」承担
        // （卡片/搜索框有自己的手势，不会误拖整个窗口）
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 520, height: 380)
    }

    /// 面板不夺取键盘焦点，保证复制/粘贴目标仍是原来的前台应用
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

// MARK: - 浮动窗内容数据源（05 号规格 1.4：FloatingClipboardStore）

/// 浮动窗的独立数据源：只维护"最近 N 条"，并订阅 ClipboardManager 的变更广播
public final class FloatingClipboardStore: ObservableObject {

    @Published public private(set) var recentItems: [ClipboardItem] = []
    @Published public var isVisible: Bool = FloatingClipboardPinState.shared.isVisible
    @Published public var isPinned: Bool = FloatingClipboardPinState.shared.isPinned
    /// 「搜索剪贴板」模式的过滤词（原版 ClipboardFilterBarView 的 FilterBar_Search）
    @Published public var searchText: String = ""

    /// 过滤后的列表（搜索词为空 = 全部最近条目）
    public var filteredItems: [ClipboardItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return recentItems }
        return recentItems.filter { item in
            let title = (item.aliasTitle?.isEmpty == false) ? item.aliasTitle! : (item.title ?? item.content ?? "")
            return title.localizedCaseInsensitiveContains(q)
                || (item.content?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    public static let recentLimit = 12

    private var observer: NSObjectProtocol?

    public init() {
        observer = NotificationCenter.default.addObserver(
            forName: ClipboardManager.itemsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func refresh() {
        ClipboardManager.shared.recentItems(limit: Self.recentLimit) { [weak self] items in
            self?.recentItems = items
        }
    }

    public func setVisible(_ visible: Bool) {
        isVisible = visible
        FloatingClipboardPinState.shared.isVisible = visible
    }

    public func setPinned(_ pinned: Bool) {
        isPinned = pinned
        FloatingClipboardPinState.shared.isPinned = pinned
    }
}

// MARK: - 浮动窗控制器（05 号规格 1.4：FloatingClipboardWindowController）

/// 宿主 NSHostingView 渲染 SwiftUI 内容；位置在本地
public final class FloatingClipboardWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = FloatingClipboardWindowController()

    public let state = FloatingClipboardPinState.shared
    public let store = FloatingClipboardStore()
    private var didRestoreVisibility = false
    /// v198：收回动画进行中（重复 hide 不重播）
    private var isHiding = false

    private init() {
        FloatingClipboardPinState.shared.migrateLayoutIfNeeded()
        let panel = FloatingClipboardPanel(contentRect: FloatingClipboardPinState.shared.clampedFrame())
        super.init(window: panel)
        panel.delegate = self
        // 主题统一入口：强调色（个性化）+ Midnight 注入（注入器与 EnvironmentKey 在共享层）
        let root = FloatingClipboardDeskView()
            .frsetThemeChrome()
            // v202：精确忽略容器顶部安全区（标题栏 32pt）。实测 host 虽铺满全窗，
            // 但 safeAreaInsets.top=32 仍会让 SwiftUI 内容整体下移 → 红绿灯悬空。
            .ignoresSafeArea(.container, edges: .top)
        // v201 修正（用户截图：红绿灯仍与白色内容分离、悬在透明区域上方）：
        // fullSizeContentView 下 NSHostingView 默认会把标题栏算进 safe area，
        // 内容（连同背景）整体下移 28pt，顶部只剩透明窗 + 红绿灯。
        // 关掉 safeArea 后背景铺到窗顶，红绿灯压在同一块玻璃上。
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        // v201 修正2（启动崩溃 SIGABRT：_postWindowNeedsLayout / NSHostingView.setFrameSize）：
        // 直接拿 hosting 当 contentView，窗口首帧 placement 时会同步 resize 它并抛
        // NSInternalInconsistencyException（与 v173 预热崩溃同族）。
        // 与主面板 FloatingPanel 同构：普通 NSView 容器 + Auto Layout 约束装 hosting，
        // 窗口改尺寸时由约束系统消化，不再在 display cycle 里同步 setFrameSize。
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        if UserDefaults.standard.bool(forKey: "probe.floatLayout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Log.info("Clipboard", "悬浮窗布局：window=\(panel.frame.size) content=\(panel.contentView?.frame.size ?? .zero) "
                         + "host=\(host.frame.size) safeTop=\(host.safeAreaInsets.top) layoutRect=\(panel.contentLayoutRect.size)")
            }
        }
        // 粘完即走：面板立刻收起，焦点回到原来的 App
        FloatingClipDeskStore.shared.onPaste = { [weak self] in self?.hide() }
        installKeyMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现（浮动窗走代码构建）") }

    /// v202（审查 finding-1）：收起动画的兜底计时器无法取消——用代际 token 让旧收尾失效
    private var revealGeneration = 0

    public func show() {
        Log.info("Clipboard", "悬浮工作台 show（visible -> true）")
        revealGeneration += 1          // 让上一轮收起的 completion/计时器失效
        isHiding = false
        store.setVisible(true)
        store.refresh()
        // v201：只在尺寸真的变化时才 setFrame——启动恢复时窗口已按同一 frame 创建，
        // 重复 setFrame 会在首帧 placement 里同步重排 hosting（崩溃诱因）。
        let target = state.clampedFrame()
        if window?.frame != target { window?.setFrame(target, display: true) }
        window?.orderFrontRegardless()
        // v198：从触发点（鼠标/工具栏按钮）展开成整块工作台
        if let w = window { WindowReveal.playInFromMouse(on: w) }
    }

    public func hide() {
        Log.info("Clipboard", "悬浮工作台 hide")
        store.setVisible(false)
        guard let w = window, w.isVisible else { return }
        let token = revealGeneration
        WindowReveal.playOutToLastAnchor(on: w) { [weak self, weak w] in
            guard let self, token == self.revealGeneration else { return }
            w?.orderOut(nil)
            if let w { WindowReveal.reset(w) }
            self.isHiding = false
        }
        isHiding = true
    }

    public func toggle() {
        Log.info("Clipboard", "悬浮工作台 toggle（当前 isVisible=\(window?.isVisible == true)，window=\(window == nil ? "nil" : "ok")）")
        if window?.isVisible == true {
            hide()
        } else {
            StatisticsManager.shared.record(.floatingClipboardActivate)
            show()
        }
    }

    /// 双击修饰键呼出（原版 AppKitDoubleTapMonitor 语义）：把窗口挪到鼠标附近再显示。
    public func showNearMouse() {
        revealGeneration += 1
        isHiding = false
        let mouse = NSEvent.mouseLocation
        var frame = state.clampedFrame()
        frame.origin = CGPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height / 2)
        store.setVisible(true)
        store.refresh()
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
        if let w = window { WindowReveal.playInFromMouse(on: w) }
    }

    /// App 启动时调用：恢复上次的可见状态
    public func restoreVisibilityIfNeeded() {
        guard !didRestoreVisibility else { return }
        didRestoreVisibility = true
        if state.isVisible { show() }
    }

    // MARK: NSWindowDelegate

    public func windowDidMove(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        state.save(frame: frame)
    }

    public func windowDidResize(_ notification: Notification) {
        guard let frame = window?.frame else { return }
        state.save(frame: frame)
    }

    public func windowWillClose(_ notification: Notification) {
        store.setVisible(false)
    }

    // MARK: - 键盘闭环（v191）
    //
    // 设计要点：**搜索框永远持有焦点**，网格光标只是一个索引状态。
    // 这样避免了「焦点在卡片上就打不了字」的老问题；方向键由本地监听器接管，
    // 只有在搜索框为空时才用来移动卡片光标（有字时留给文本光标）。
    //
    // 键位：↑↓←→ 移动 · Enter 粘贴 · ⌥Enter 纯文本 · 空格 预览 · ⌘1–9 直贴 ·
    //       ⌘⌫ 删除 · Esc 两级（先清搜索词，再收起）

    private var keyMonitor: Any?

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.window, panel.isKeyWindow else { return event }
            // 中文输入法正在组字：一律放行，别把候选词吃成快捷键
            if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }

            let store = FloatingClipDeskStore.shared
            let columns = store.layout == .grid ? store.cardSize.columns : 1
            let command = event.modifierFlags.contains(.command)
            let option = event.modifierFlags.contains(.option)

            // ⌘1–9：直接粘贴第 N 个
            if command, !option,
               let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), (1...9).contains(digit) {
                let index = digit - 1
                if store.items.indices.contains(index) { store.paste(store.items[index]) }
                return nil
            }
            // ⌘⌫：删除当前光标项
            if command, event.keyCode == 51 {
                if store.items.indices.contains(store.selectedIndex) {
                    store.delete(store.items[store.selectedIndex])
                }
                return nil
            }

            switch event.keyCode {
            case 53:                       // Esc：两级
                if !store.search.isEmpty {
                    store.search = ""
                } else {
                    self.hide()
                }
                return nil
            case 36, 76:                   // Enter：粘贴（⌥ = 纯文本）
                guard store.items.indices.contains(store.selectedIndex) else { return nil }
                let item = store.items[store.selectedIndex]
                if option {
                    ClipboardManager.shared.copy(item, autoPaste: false)
                    Toast.show("已复制纯文本", icon: "doc.on.doc")
                    self.hide()
                } else {
                    store.paste(item)
                }
                return nil
            case 49:                       // 空格：预览（不粘贴）
                guard store.items.indices.contains(store.selectedIndex) else { return nil }
                ServiceLocator.panelPreview?.presentPreview(for: store.items[store.selectedIndex],
                                                            anchorRectInWindow: .zero,
                                                            anchorView: nil,
                                                            isFloatingSource: true)
                return nil
            case 126:                      // ↑
                store.moveSelection(0, -1, columns: columns)
                return nil
            case 125:                      // ↓
                store.moveSelection(0, 1, columns: columns)
                return nil
            case 123:                      // ←
                if store.search.isEmpty {
                    store.moveSelection(-1, 0, columns: columns)
                    return nil
                }
                return event
            case 124:                      // →
                if store.search.isEmpty {
                    store.moveSelection(1, 0, columns: columns)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

// MARK: - 浮动窗内容（SwiftUI）

/// 浮动窗内容：最近条目列表 + 底部工具条（对齐原版 ClipboardFilterBarView，2026-10-18 实机核验）。
/// 原版悬浮窗**没有标题栏**，底部悬浮条从左到右：🔍 搜索剪贴板 / ✏️ 编辑 / 📌 钉住 / ↑ 回到顶部。
/// 行交互 = 单击预览、双击粘贴（specs/14 F9）
public struct FloatingClipboardContentView: View {

    @EnvironmentObject private var store: FloatingClipboardStore
    // Midnight 主题覆盖（由 .frsetAppearanceTheme() 注入；非 Midnight 时全为 nil/false）
    @Environment(\.midnightBaseBackgroundOverride) private var midnightBaseBackground
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground
    @Environment(\.usesMidnightTextColor) private var usesMidnightTextColor
    @Environment(\.midnightTextColorOverride) private var midnightTextColor
    /// 「搜索剪贴板」模式开关（🔍）
    @Stored private var isSearchMode = false
    /// 回到顶部（↑）用
    @Stored private var scrollTrigger = 0

    public init() {}

    /// 正文色：Midnight 且 usesMidnightTextColor 为真时用冷白蓝，否则系统 primary
    private var bodyTextColor: Color {
        (usesMidnightTextColor ? midnightTextColor : nil) ?? .primary
    }

    /// 窗口底色：Midnight 用深冷黑蓝基底，否则沿用系统窗底 + 0.94 透明度
    private var windowBackground: Color {
        guard let base = midnightBaseBackground else {
            return Color(NSColor.windowBackgroundColor).opacity(0.94)
        }
        return base.opacity(0.96)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if isSearchMode {
                searchField
                Divider()
            }
            if store.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(store.searchText.isEmpty ? "还没有剪贴板记录" : "没有匹配的条目")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(store.filteredItems) { item in
                                FloatingRow(item: item)
                                    .contextMenu { ClipboardRowMenuContent(item: item) }
                                    .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: scrollTrigger) { _ in
                        if let first = store.filteredItems.first {
                            proxy.scrollTo(first.id, anchor: .top)
                        }
                    }
                }
            }
            filterBar
        }
        .frame(minWidth: 200, minHeight: 220)
        .background {
            // 悬浮剪贴板同样是结构面：macOS 26+ 铺 Liquid Glass，旧系统/Midnight 用实底
            if midnightBaseBackground == nil {
                LiquidGlassBackground(cornerRadius: Theme.cornerRadius,
                                      tint: Color(NSColor.windowBackgroundColor).opacity(0.55))
            } else {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(windowBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .foregroundStyle(bodyTextColor)
        .onAppear { store.refresh() }
    }

    /// 搜索框（搜索模式下显示在列表上方；对齐原版「搜索剪贴板」入口）
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 底部工具条（原版 ClipboardFilterBarView：🔍 搜索剪贴板 / 📌 钉住 / ↑ 回到顶部）
    private var filterBar: some View {
        HStack(spacing: 18) {
            barButton("magnifyingglass", help: "搜索剪贴板", active: isSearchMode) {
                isSearchMode.toggle()
                if !isSearchMode { store.searchText = "" }
            }
            Spacer(minLength: 0)
            barButton(store.isPinned ? "pin.fill" : "pin", help: "钉住：始终置顶") {
                store.setPinned(!store.isPinned)
            }
            barButton("arrow.up.to.line", help: "回到顶部") {
                scrollTrigger += 1
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if let card = midnightCardBackground { card }
        }
    }

    private func barButton(_ symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(active ? Theme.accent : Color.secondary)
                .frame(width: 22, height: 22)
                .background {
                    if active { Circle().fill(Theme.accent.opacity(0.14)) }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 浮动窗行：紧凑单行（缩略图 28pt + 一行摘要）
/// 行交互（specs/14 F9/C9，whatsNew 实证 `0xb57d56`）：**单击=预览、双击=粘贴**；
/// 悬停预览走协调器 `.floatingPreview` 源（总开关 hoverPreviewInFloatingClipboardEnabled）。
private struct FloatingRow: View {
    let item: ClipboardItem
    @Stored private var isHovering = false
    // @State 宏在本自检工具链不可用（CONTRACT §7.4）→ @Stored
    @Stored private var rowFrameInWindow: CGRect = .zero

    var body: some View {
        rowContent
            // 锚点：行在 window 坐标系的框（macOS SwiftUI .global 即 window 坐标）
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { rowFrameInWindow = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { rowFrameInWindow = $0 }
            })
            .onHover { hovering in
                isHovering = hovering
                ServiceLocator.panelPreview?.rowHover(
                    hovering, item: item,
                    anchorRectProvider: { rowFrameInWindow },
                    isFloatingSource: true)
            }
            // 双击 = 粘贴（先注册 count:2，避免被 count:1 吞掉）
            .onTapGesture(count: 2) {
                ClipboardManager.shared.copy(item)
            }
            // 单击 = 预览（不复制）
            .onTapGesture(count: 1) {
                ServiceLocator.panelPreview?.presentPreview(
                    for: item,
                    anchorRectInWindow: rowFrameInWindow,
                    anchorView: nil,
                    isFloatingSource: true)
            }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            ClipboardThumbnailView(item: item, size: 28, corner: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.aliasTitle?.isEmpty == false) ? item.aliasTitle! : (item.displayTitle))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(item.timestamp.relativeText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(isHovering ? Theme.accent.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
