import AppKit
import SwiftUI

// MARK: - 命令面板（vorssaint CommandBarCatalog 对齐，2026-10-19 用户需求）
//
// 把「一堆功能」收敛成「一个工具箱」的统一入口：
//   ⌥K（全局热键，可在设置 → 快捷键改绑）或主面板内 ⌘K 呼出浮动窗；
//   FuzzyMatcher 模糊搜索 + ↑↓ 导航 + ↵ 执行 + Esc 关闭。
//
// 目录（CommandCatalog）聚合五类条目：
//   · 动作 —— 截图全家桶 / 贴图管理 / 打开面板与设置
//   · 开关 —— 剪贴板记录暂停、截图提示音、OCR 结果窗、动作工具条、Toast 跟随等
//   · 设置页 —— SettingsPaneRegistry 注册的全部页签直达
//   · 工具 —— ToolRegistry 启用工具（在工具箱 UI 打开）
//   · 监测 —— 性能监测独立窗

/// 一条命令
public struct CommandItem: Identifiable {
    public enum Kind: String {
        case action = "动作"
        case toggle = "开关"
        case settings = "设置"
        case tool = "工具"
        case monitor = "监测"
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let kind: Kind
    /// 开关类：返回当前态；执行后回查刷新
    public let isOn: (() -> Bool)?
    public let handler: () -> Void

    public init(id: String, title: String, subtitle: String = "", systemImage: String,
                kind: Kind, isOn: (() -> Bool)? = nil, handler: @escaping () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.systemImage = systemImage; self.kind = kind
        self.isOn = isOn; self.handler = handler
    }
}

public enum CommandCatalog {

    /// 全量目录（每次打开时构建，保证开关态新鲜）
    @MainActor
    public static func build() -> [CommandItem] {
        var items: [CommandItem] = []

        // ① 动作：截图全家桶
        for mode in CaptureMode.allCases {
            items.append(CommandItem(id: "capture.\(mode.rawValue)",
                                     title: mode.title,
                                     subtitle: "截图",
                                     systemImage: mode.systemImage,
                                     kind: .action) {
                CaptureModule.capture(mode)
            })
        }
        items.append(CommandItem(id: "capture.screenTranslate",
                                 title: "屏幕翻译（选区 → 译文贴回原位）",
                                 subtitle: "截图",
                                 systemImage: "character.book.closed",
                                 kind: .action) {
            ScreenshotManager.shared.captureAndScreenTranslate()
        })
        items.append(CommandItem(id: "capture.closePins",
                                 title: "关闭全部贴图",
                                 subtitle: "截图",
                                 systemImage: "pin.slash",
                                 kind: .action) {
            PinnedScreenshotManager.shared.closeAll()
        })
        items.append(CommandItem(id: "capture.annotateLatest",
                                 title: "标注最近一张截图",
                                 subtitle: "截图",
                                 systemImage: "pencil.and.outline",
                                 kind: .action) {
            _ = ScreenshotManager.shared.annotateLatest()
        })

        // ② 监测
        items.append(CommandItem(id: "monitor.popout",
                                 title: "性能监测独立窗",
                                 subtitle: "开关面板",
                                 systemImage: "gauge",
                                 kind: .monitor) {
            MonitorPopoutWindowController.shared.toggle()
        })
        items.append(CommandItem(id: "panel.open",
                                 title: "打开主面板",
                                 subtitle: "面板",
                                 systemImage: "rectangle.inset.filled",
                                 kind: .monitor) {
            NSApp.activate(ignoringOtherApps: true)
            ServiceLocator.panel?.show()
        })

        // ③ 开关（Preferences / Manager 状态直读写）
        items.append(CommandItem(id: "toggle.clipboardRecording",
                                 title: "暂停 / 恢复剪贴板记录",
                                 subtitle: "剪贴板",
                                 systemImage: "pause.circle",
                                 kind: .toggle,
                                 isOn: { !ClipboardManager.shared.isRecordingPaused },
                                 handler: {
            ClipboardManager.shared.isRecordingPaused.toggle()
        }))
        items.append(CommandItem(id: "toggle.captureSound",
                                 title: "截图提示音",
                                 subtitle: "截图",
                                 systemImage: "speaker.wave.2",
                                 kind: .toggle,
                                 isOn: { Preferences.shared.value(Preferences.Keys.captureSound, default: true) },
                                 handler: {
            let v = Preferences.shared.value(Preferences.Keys.captureSound, default: true)
            Preferences.shared.set(Preferences.Keys.captureSound, !v)
        }))
        items.append(CommandItem(id: "toggle.ocrResultWindow",
                                 title: "OCR 后弹出结果窗",
                                 subtitle: "截图",
                                 systemImage: "macwindow.on.rectangle",
                                 kind: .toggle,
                                 isOn: { ScreenshotManager.shared.ocrShowResultWindow },
                                 handler: {
            ScreenshotManager.shared.ocrShowResultWindow.toggle()
        }))
        items.append(CommandItem(id: "toggle.actionToolbar",
                                 title: "框选后显示动作工具条",
                                 subtitle: "截图",
                                 systemImage: "filemenu.and.selection",
                                 kind: .toggle,
                                 isOn: { CaptureActionChain.showToolbarAfterSelection },
                                 handler: {
            CaptureActionChain.showToolbarAfterSelection.toggle()
        }))
        items.append(CommandItem(id: "toggle.toastFollowPanel",
                                 title: "通知条跟随主面板",
                                 subtitle: "个性化",
                                 systemImage: "arrow.down.to.line.compact",
                                 kind: .toggle,
                                 isOn: { Personalization.shared.toastFollowPanel },
                                 handler: {
            Personalization.shared.toastFollowPanel.toggle()
        }))

        // ③.5 音频混音器
        items.append(CommandItem(id: "audio.mixer",
                                 title: "音频混音器（系统音量 / 设备 / 有声 App）",
                                 subtitle: "音频",
                                 systemImage: "speaker.wave.2",
                                 kind: .settings) {
            NSApp.activate(ignoringOtherApps: true)
            ServiceLocator.settings?.open(pane: "audio")
        })

        // ④ 设置页直达
        for pane in SettingsPaneRegistry.all {
            items.append(CommandItem(id: "settings.\(pane.id)",
                                     title: "设置：\(pane.title)",
                                     subtitle: "设置页",
                                     systemImage: pane.systemImage,
                                     kind: .settings) {
                NSApp.activate(ignoringOtherApps: true)
                ServiceLocator.settings?.open(pane: pane.id)
            })
        }

        // ⑤ 工具箱工具（在工具箱 UI 打开该工具）
        for tool in ToolRegistry.enabledTools {
            items.append(CommandItem(id: "tool.\(tool.identifier)",
                                     title: tool.name,
                                     subtitle: "工具 · \(tool.category.title)",
                                     systemImage: tool.systemImage,
                                     kind: .tool) {
                NSApp.activate(ignoringOtherApps: true)
                ServiceLocator.panel?.show()
                ToolboxUIState.shared.open(tool.identifier)
            })
        }

        return items
    }
}

// MARK: - 面板控制器

public final class CommandPaletteController: NSObject, NSWindowDelegate {
    public static let shared = CommandPaletteController()

    private var panel: CommandPalettePanel?

    private override init() { super.init() }

    public func toggle() {
        if let panel, panel.isVisible {
            panel.close()
            self.panel = nil
        } else {
            show()
        }
    }

    public func show() {
        panel?.close()
        let p = CommandPalettePanel()
        panel = p
        p.centerInScreen()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? CommandPalettePanel) === panel { panel = nil }
    }
}

/// 命令面板窗口（Spotlight 式顶部浮窗）
final class CommandPalettePanel: NSPanel, NSWindowDelegate {

    private var onClose: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                   styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "命令面板"
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        titlebarAppearsTransparent = true

        let controller = CommandPaletteState()
        controller.onDismiss = { [weak self] in self?.close() }
        onClose = { [weak controller] in controller?.onDismiss = nil }
        let host = NSHostingView(rootView: CommandPaletteView(state: controller))
        contentView = host
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    func centerInScreen() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                               y: vf.maxY - size.height - vf.height * 0.12))
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - 状态（@Stored；无宏工程）

@MainActor
final class CommandPaletteState: ObservableObject {
    @Published var query = ""
    @Published var items: [CommandItem] = []
    @Published var selectedIndex = 0

    var onDismiss: (() -> Void)?

    private let all: [CommandItem]

    init() {
        all = CommandCatalog.build()
        items = all
    }

    /// FuzzyMatcher 过滤 + 评分排序
    func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            items = all
            selectedIndex = min(selectedIndex, max(items.count - 1, 0))
            return
        }
        var scored: [(item: CommandItem, score: Int)] = []
        if q.isEmpty {
            items = all
        } else {
            for item in all {
                if let m = FuzzyMatcher.match(q, in: item.title) {
                    scored.append((item, m.score))
                }
            }
            scored.sort { $0.score > $1.score }
            items = scored.map { $0.item }
        }
        if !items.isEmpty {
            selectedIndex = min(max(selectedIndex, 0), items.count - 1)
        } else {
            selectedIndex = 0
        }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
    }

    func executeSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        onDismiss?()
        item.handler()
    }
}

// MARK: - 视图

struct CommandPaletteView: View {
    @ObservedObject var state: CommandPaletteState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索命令、开关、设置页、工具…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { state.executeSelected() }
                    .onChange(of: state.query) { _ in state.refilter() }
                Text("⌥K")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                            CommandRowView(item: item, selected: index == state.selectedIndex)
                                .id(item.id)
                                .onHover { hovering in
                                    if hovering { state.selectedIndex = index }
                                }
                                .onTapGesture { state.executeSelected() }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: state.selectedIndex) { newIndex in
                    if let item = state.items[safe: newIndex] {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack(spacing: 12) {
                Text("↑↓ 选择 · ↵ 执行 · Esc 关闭")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(state.items.count) 项")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .frame(width: 660, height: 470)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: OfficialChrome.windowBackground).opacity(0.99)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(keyHandler)
        .onAppear {
            state.refilter()
            focused = true
        }
    }

    /// ↑↓/Esc 键盘导航（本地事件监听，文本框不吞方向键）
    private var keyHandler: some View {
        EmptyView()
            .background(
                KeyEventCatcher { event in
                    switch event.keyCode {
                    case 0x7D: state.move(-1); return true     // ↓
                    case 0x7E: state.move(1); return true      // ↑
                    case 0x35: state.onDismiss?(); return true // Esc
                    default: return false
                    }
                }
            )
    }
}

private struct CommandRowView: View {
    let item: CommandItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.kind == .toggle, let isOn = item.isOn {
                Toggle("", isOn: .constant(isOn()))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                    .disabled(true)
            }
            Text(item.kind.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - 键盘事件捕获（本地监视器，视图生命周期内生效）

private struct KeyEventCatcher: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyEventCatcherView {
        let v = KeyEventCatcherView()
        v.handler = handler
        return v
    }

    func updateNSView(_ nsView: KeyEventCatcherView, context: Context) {
        nsView.handler = handler
    }
}

private final class KeyEventCatcherView: NSView {
    var handler: ((NSEvent) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, let handler = self.handler else { return event }
                return handler(event) ? nil : event
            }
        } else if window == nil, let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    }
}

// MARK: - Array 安全索引

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
