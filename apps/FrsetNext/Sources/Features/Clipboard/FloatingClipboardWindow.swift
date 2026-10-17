import AppKit
import Foundation
import SwiftUI

// MARK: - 浮动窗几何与钉住状态（05 号规格 1.4 + B8）

/// 浮动窗状态：几何 + 可见性 + 钉住位，全部落到 Preferences（`floatingClipboard.*`）
public final class FloatingClipboardPinState: ObservableObject {

    public static let shared = FloatingClipboardPinState()

    /// 实测尺寸：240×290
    public static let defaultWidth: CGFloat = 240
    public static let defaultHeight: CGFloat = 290

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
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .participatesInCycle]
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        minSize = NSSize(width: 200, height: 220)
        standardWindowButton(.closeButton)?.isHidden = false
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

    private init() {
        let panel = FloatingClipboardPanel(contentRect: FloatingClipboardPinState.shared.clampedFrame())
        super.init(window: panel)
        panel.delegate = self
        // Midnight 主题注入器挂载点（注入器与四个 EnvironmentKey 在共享层 Core/AppearanceTheme.swift）
        let root = FloatingClipboardContentView()
            .environmentObject(store)
            .frsetAppearanceTheme()
        panel.contentView = NSHostingView(rootView: root)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现（浮动窗走代码构建）") }

    public func show() {
        store.setVisible(true)
        store.refresh()
        window?.setFrame(state.clampedFrame(), display: true)
        window?.orderFrontRegardless()
    }

    public func hide() {
        store.setVisible(false)
        window?.orderOut(nil)
    }

    public func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    /// 双击修饰键呼出（原版 AppKitDoubleTapMonitor 语义）：把窗口挪到鼠标附近再显示。
    public func showNearMouse() {
        let mouse = NSEvent.mouseLocation
        var frame = state.clampedFrame()
        frame.origin = CGPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height / 2)
        store.setVisible(true)
        store.refresh()
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
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
}

// MARK: - 浮动窗内容（SwiftUI）

/// 浮动窗内容：标题栏 + 最近条目列表；行交互 = 单击预览、双击粘贴（specs/14 F9）
public struct FloatingClipboardContentView: View {

    @EnvironmentObject private var store: FloatingClipboardStore
    // Midnight 主题覆盖（由 .frsetAppearanceTheme() 注入；非 Midnight 时全为 nil/false）
    @Environment(\.midnightBaseBackgroundOverride) private var midnightBaseBackground
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground
    @Environment(\.usesMidnightTextColor) private var usesMidnightTextColor
    @Environment(\.midnightTextColorOverride) private var midnightTextColor

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
            header
            Divider()
            if store.recentItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text("还没有剪贴板记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.recentItems) { item in
                            FloatingRow(item: item)
                                .contextMenu { ClipboardRowMenuContent(item: item) }
                        }
                    }
                    .padding(6)
                }
            }
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

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clipboard.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("剪贴板")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(action: { store.setPinned(!store.isPinned) }) {
                Image(systemName: store.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("钉住：始终置顶")
            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Midnight：标题栏用卡片底色与列表区拉开层次（非 Midnight 不铺底色）
        .background {
            if let card = midnightCardBackground { card }
        }
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
