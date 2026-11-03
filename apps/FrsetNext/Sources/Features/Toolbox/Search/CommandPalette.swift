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
        case command = "命令"
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let kind: Kind
    /// 开关类：返回当前态；执行后回查刷新
    public let isOn: (() -> Bool)?
    /// 斜杠命令的额外匹配词（命令 token + 别名），其它类型为空
    public let matchTerms: [String]
    public let handler: () -> Void

    public init(id: String, title: String, subtitle: String = "", systemImage: String,
                kind: Kind, isOn: (() -> Bool)? = nil,
                matchTerms: [String] = [], handler: @escaping () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.systemImage = systemImage; self.kind = kind
        self.isOn = isOn; self.matchTerms = matchTerms
        self.handler = handler
    }
}

public enum CommandCatalog {

    /// 全量目录（每次打开时构建，保证开关态新鲜）
    // v126（性能审计 F1356）：调用频率核实——build 只在命令面板每次打开时执行一次
    // （CommandPaletteState.init），非启动常驻热点，无需缓存；只做轻量优化：
    // 预留容量避免 ~40 个条目追加过程中的多次扩容。
    /// 斜杠命令编目（v172）：`/uuid` `/time` `/apollo` … 选中即调起对应工具。
    @MainActor
    public static func buildSlash() -> [CommandItem] {
        SlashCommandCatalog.build().map { cmd in
            let terms = ([cmd.token] + cmd.aliases).map { $0.lowercased() }
            return CommandItem(id: "slash.\(cmd.id)",
                               title: cmd.title,
                               subtitle: cmd.subtitle,
                               systemImage: cmd.systemImage,
                               kind: .command,
                               matchTerms: terms) {
                cmd.run()
            }
        }
    }

    @MainActor
    public static func build() -> [CommandItem] {
        var items: [CommandItem] = []
        items.reserveCapacity(48)

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
            // v97：与齿轮菜单一致的生效反馈（Toast 明示新状态）
            let paused = ClipboardManager.shared.isRecordingPaused
            Toast.show(paused ? "已暂停记录剪贴板" : "已恢复剪贴板记录",
                       icon: paused ? "pause.fill" : "play.fill")
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
    /// v198：收回动画进行中（防止 toggle 重入重复 close）
    private var isClosing = false

    private override init() { super.init() }

    public func toggle() {
        if let panel, panel.isVisible {
            closeAnimated()
        } else {
            show()
        }
    }

    /// v198：收回动画——缩回上次展开的鼠标点，再 close
    private func closeAnimated() {
        guard let p = panel, !isClosing else { return }
        isClosing = true
        WindowReveal.playOutToLastAnchor(on: p) { [weak self, weak p] in
            p?.close()
            self?.isClosing = false
            if self?.panel === p { self?.panel = nil }
        }
    }

    public func show(slash: Bool = false) {
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        panel?.close()
        let p = CommandPalettePanel(initialQuery: slash ? "/" : "")
        panel = p
        p.centerInScreen()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // v198：从触发点（快捷键/菜单）展开整块面板
        WindowReveal.playInFromMouse(on: p, scale: 0.94)
    }

    /// 命令执行前的收尾（面板已关时不做事）
    public func dismissForCommand() {
        guard let p = panel else { return }
        WindowReveal.playOutToLastAnchor(on: p) { [weak p] in p?.close() }
        panel = nil
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? CommandPalettePanel) === panel { panel = nil }
    }
}

/// 命令面板窗口（Spotlight 式顶部浮窗）
final class CommandPalettePanel: NSPanel, NSWindowDelegate {

    private var onClose: (() -> Void)?

    init(initialQuery: String = "") {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 470),
                   styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "命令面板"
        // v179：内容铺满整窗。原先 .titled 但没 fullSizeContentView，
        // 换成玻璃后上方会露出一条白色标题栏（截图确认），与「一整块玻璃」不符。
        titleVisibility = .hidden
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        titlebarAppearsTransparent = true

        let controller = CommandPaletteState(initialQuery: initialQuery)
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
    /// 斜杠命令池（v172）
    private let slashAll: [CommandItem]

    /// 命令模式：查询以 `/` 开头
    var isSlashMode: Bool {
        query.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    init(initialQuery: String = "") {
        all = CommandCatalog.build()
        slashAll = CommandCatalog.buildSlash()
        if !initialQuery.isEmpty { query = initialQuery }
        items = initialQuery.hasPrefix("/") ? slashAll : all
    }

    /// 点按钮 / 再点一次：在「命令模式」与「普通模式」之间切换
    func toggleSlashMode() {
        if isSlashMode {
            query = ""
        } else {
            query = "/"
        }
        selectedIndex = 0
        refilter()
    }

    /// FuzzyMatcher 过滤 + 评分排序
    func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces)

        // ── 命令模式：只列工具命令，按 token / 别名命中 ──
        if q.hasPrefix("/") {
            let token = String(q.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            if token.isEmpty {
                publish(slashAll)
                return
            }
            var scored: [(item: CommandItem, score: Int)] = []
            for item in slashAll {
                var best: Int?
                for term in item.matchTerms {
                    if term == token { best = 10_000; break }
                    if term.hasPrefix(token) {
                        best = max(best ?? 0, 5_000 - (term.count - token.count))
                    } else if let m = FuzzyMatcher.match(token, in: term) {
                        best = max(best ?? 0, m.score)
                    }
                }
                if let b = best { scored.append((item, b)) }
            }
            scored.sort { $0.score > $1.score }
            publish(scored.map { $0.item })
            return
        }

        guard !q.isEmpty else {
            publish(all)
            return
        }
        // v126（性能审计 F1356）：删除恒假分支（q 已被上方 guard 排空），
        // 并预留容量——refilter 在每次按键防抖后执行，是本文件真正的热路径。
        // v128（流畅度）：复核无 O(n²)——单趟匹配 O(n) + 排序 O(n log n)，n≈40。
        // 但结果无变化时也会写 @Published 触发整列表重绘（40 行 CommandRowView），
        // 故比对 id 序列后只在真变化时发布（40 条 String 比对远比 40 行重绘便宜）。
        var scored: [(item: CommandItem, score: Int)] = []
        scored.reserveCapacity(all.count)
        for item in all {
            if let m = FuzzyMatcher.match(q, in: item.title) {
                scored.append((item, m.score))
            }
        }
        scored.sort { $0.score > $1.score }
        publish(scored.map { $0.item })
    }

    /// 结果发布（id 序列不变则不触发整列表重绘）
    private func publish(_ next: [CommandItem]) {
        if next.map(\.id) != items.map(\.id) {
            items = next
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
                Image(systemName: state.isSlashMode ? "terminal" : "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(state.isSlashMode ? Theme.accent : Color.secondary)
                    .frame(width: 16)
                TextField(state.isSlashMode
                          ? "输入命令名：uuid / time / apollo / json…"
                          : "搜索命令、开关、设置页、工具…",
                          text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: state.isSlashMode ? .monospaced : .default))
                    .focused($focused)
                    .onSubmit { state.executeSelected() }
                    .onChange(of: state.query) { _ in state.refilter() }

                // v172（用户：「添加一个按钮，点击之后就自动输入斜杠，展示这一系列命令」）
                // 点一下补 `/` 进命令模式，再点一下清空回普通搜索。
                Button {
                    state.toggleSlashMode()
                    focused = true
                } label: {
                    Text("/")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(state.isSlashMode ? Theme.accent : Color.secondary)
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(state.isSlashMode
                                      ? Theme.accent.opacity(0.18)
                                      : Color.primary.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .strokeBorder(state.isSlashMode ? Theme.accent.opacity(0.45)
                                                                : Color.clear, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("命令模式：列出全部斜杠命令（如 /uuid、/time、/apollo）")
                .accessibilityLabel("斜杠命令")

                Text("⌥K")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
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
                Text(state.isSlashMode
                     ? "/ 命令模式 · 输入名字筛选 · ↵ 执行 · Esc 关闭"
                     : "↑↓ 选择 · ↵ 执行 · Esc 关闭")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Text("\(state.items.count) 项")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .frame(width: 660, height: 470)
        // v179：原来是一块 99% 不透明官方灰（等于不透明），与主面板的真玻璃不是一套。
        // 统一走 glassPlate：26+ 真玻璃 / 旧系统毛玻璃 / 纯色偏好退化为不透明底。
        .glassPlate()
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
                .foregroundStyle(selected ? Theme.accent : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
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
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.12) : Color.clear)
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
