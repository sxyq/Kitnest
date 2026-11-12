import AppKit
import SwiftUI

// MARK: - 设置窗口控制器
// 原 App 用 SwiftUI Settings scene；重建改为独立 NSWindow + NSHostingView，
// 便于其他模块通过 ServiceLocator.settings?.open(pane:) 程序化唤起并直达指定页签。

/// 设置窗口内 SwiftUI 层与 AppKit 层共享的选中状态。
///
/// v41：设置窗改为「左侧大侧边栏 + 内容区」后，选中态从「顶部页签 id」升级为
/// 侧边栏选中项（设置分类 / 性能模块 / 监测设置）。`selectPane(_:)` 保留
/// 旧 pane id 到侧边栏项的映射，外部模块（ServiceLocator.settings?.open(pane:)）
/// 无需改动即可直达对应位置。
final class SettingsUIState: ObservableObject {
    @Published var selectedPaneID: String
    @Published var detailPaneID: String?
    /// 侧边栏选中项 = 二级页（v272：常规/剪贴板/文件中转也各自拆成多页）
    @Published var selection: SettingsPage = .generalStart
    /// 搜索框与外部切页共用；保留已有搜索探针初值。
    @Published var query: String = UserDefaults.standard.string(forKey: "probe.settingsSearch") ?? ""

    init(selectedPaneID: String = "general") {
        self.selectedPaneID = selectedPaneID
        applyPaneMapping(selectedPaneID)
    }

    /// 旧 pane id → 侧边栏位置映射（含多合一分类的内部子页）
    func selectPane(_ pane: String) {
        Log.info("settings", "selectPane: \(pane)")
        Log.breadcrumb("Settings", "切页 \(pane)")   // v84：卡死定位面包屑
        selectedPaneID = pane
        detailPaneID = nil
        query = ""
        applyPaneMapping(pane)
    }

    private func applyPaneMapping(_ pane: String) {
        switch pane {
        // 常规（v272 拆成五页；旧 id "general" 落到第一页）
        case "general", "startup", "general.startup":
            selection = .generalStart
        case "panel", "general.panel", "appearance.panel":
            selection = .generalPanel
        case "windows", "general.windows", "floating", "appearance.windows":
            selection = .generalWindows
        case "personalization", "general.personalization", "appearance":
            selection = .generalPersonal
        case "menubar", "general.menubar", "menuBar":
            selection = .generalMenuBar
        case "notifications", "general.notifications":
            selection = .generalNotifications
        case "capture.actions", "capture.toolbar":
            selection = .captureActions
        case "audio":                            selection = .audio
        // 剪贴板
        case "clipboard", "clipboard.history":   selection = .clipboardHistory
        case "clipboard.capture":                selection = .clipboardCapture
        case "clipboard.floating", "floatingClipboard": selection = .clipboardFloating
        case "clipboard.appearance": selection = .clipboardAppearance
        // 文件中转
        case "transfer", "transfer.display":     selection = .transferDisplay
        case "transfer.cast", "cast":            selection = .transferCast
        case "transfer.scan", "scan":            selection = .transferScan
        case "transfer.cloud", "cloud":          selection = .transferCloud
        case "transfer.local", "local":          selection = .transferLocal
        // 搜索与 AI
        case "search":                           selection = .search
        case "ai":                               selection = .ai
        // 工具与快捷键
        case "tools":                            selection = .tools
        case "shortcuts":                        selection = .shortcuts
        // 截图（v234 独立成一级；v271 拆成五块，深链各自直达）
        case "capture":                          selection = .capture(.capture)
        case "pin", "pinSettings":               selection = .capture(.pin)
        case "shelf", "shelfSettings", "curtain", "curtainSettings":
            selection = .capture(.curtain)
        case "recording", "record":              selection = .capture(.recording)
        case "workflow":                         selection = .capture(.workflow)
        // 页脚常驻
        case "statistics":                       selection = .statistics
        case "about":                            selection = .about
        case "manual", "help":                   selection = .manual
        // 性能监测
        case "monitor", "monitorSettings":       selection = .monitorSettings
        case "monitor.widgets", "widgets", "barSettings": selection = .monitorWidgets
        default:
            // 排障/直达：pane = "monitor.cpu" / "monitor.memory" … → 性能监测模块页
            if pane.hasPrefix("monitor."),
               let module = MonitorModuleID(rawValue: String(pane.dropFirst("monitor.".count))) {
                selection = .monitorModule(module)
            }
        }
    }
}

/// 自定义 NSWindow：支持 Esc 键关闭
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // keyCode 53 = Esc
        if event.keyCode == 53, event.type == .keyDown {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

public final class SettingsWindowController: NSObject, SettingsWindowControlling {
    public static let shared = SettingsWindowController()

    /// 复用同一窗口实例（isReleasedWhenClosed 已关，关闭只是移出屏幕）
    private var window: SettingsWindow?
    /// v198：收回动画进行中（防止重复 close / 重入）
    private var isClosing = false
    /// SwiftUI 根视图的选中状态（open(pane:) 由此驱动页签跳转）
    private let uiState = SettingsUIState()

    private override init() {
        super.init()
    }

    // MARK: SettingsWindowControlling

    /// 打开设置窗口；pane 传旧页签 id（如 "general"/"shortcuts"/"monitor"），
    /// nil 保持当前位置。v41：所有 id 映射到侧边栏二级项（见 SettingsUIState）。
    /// v202（审查 finding-2）：关闭动画代际——open 期间递增，旧收尾自动失效
    private var closeGeneration = 0

    public func open(pane: String?) {
        Log.info("settings", "open(pane:\(pane ?? "nil")) called, window=\(window == nil ? "nil" : "exists")")
        // v84：设置窗打开埋点（齿轮菜单 / ⌘, / 各处「设置」入口共用）
        StatisticsManager.shared.record(.settingsOpen)
        ensureWindow()
        Log.info("settings", "ensureWindow done, window=\(window != nil ? "exists" : "nil")")
        if let pane {
            uiState.selectPane(pane)
        } else {
            // v272（2026-11-11）：复用窗口重开时显示选中行，保留页面和搜索输入。
            let currentPage = uiState.selection
            uiState.selection = currentPage
        }
        NSApp.activate(ignoringOtherApps: true)
        // v202：取消在途 close——复位动画/图层与 isClosing，
        // 否则旧 close 的 completion 会把刚重开的窗口 orderOut（审查 finding-2）
        closeGeneration += 1
        isClosing = false
        if let w = window {
            w.contentView?.layer?.removeAllAnimations()
            WindowReveal.reset(w)
        }
        let wasVisible = window?.isVisible == true
        window?.makeKeyAndOrderFront(nil)
        // v198：首次打开从触发点（齿轮/快捷键/菜单）展开整块设置窗
        if !wasVisible, let w = window { WindowReveal.playInFromMouse(on: w) }
        Log.info("settings", "open 显示完成 visible=\(window?.isVisible ?? false) frame=\(window.map { String(describing: $0.frame) } ?? "nil")")
        RenderProbe.snapshot(window, name: "settings", reason: "open")
    }

    public func close() {
        Log.info("settings", "close()")
        RenderProbe.snapshot(window, name: "settings", reason: "close")
        guard let w = window, w.isVisible, !isClosing else { return }
        isClosing = true
        let token = closeGeneration
        WindowReveal.playOutToLastAnchor(on: w) { [weak self, weak w] in
            guard let self, token == self.closeGeneration else { return }
            w?.orderOut(nil)
            if let w { WindowReveal.reset(w) }
            self.isClosing = false
        }
    }

    /// 窗口是否正在显示（状态栏菜单勾选态可用）
    public var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - 窗口构建

    private func ensureWindow() {
        guard window == nil else { return }

        // v41：设置窗改「左侧大侧边栏（186）+ 内容区（754）」→ 940×620；
        // v271：截图拆成五个侧边栏项后导航变长，默认高度提到 720（屏幕 ≥ 800pt 均放得下）。
        // 内容区宽度与原 800×530 版的可用宽度（约 700）基本一致，设置页表单版式无需重排。
        // 排障探针：`defaults write com.sxyq.frsetnext probe.settingsHeight -float 1000`
        // 可临时把设置窗拉高，用来一次截完长页面（例如合并后的「截图与钉图」）。
        // 默认 720（v271 起），探针可拉到 1040。
        // 注意类型：UserDefaults 里存的是 Double，写成 `CGFloat(value(default: 620.0))`
        // 会让泛型推断成 CGFloat，`as? CGFloat` 失败后静默退回 620（v263 实测踩过）。
        let probeHeight: Double = Preferences.shared.value("probe.settingsHeight", default: 720.0)
        let windowHeight = min(max(CGFloat(probeHeight), 720), 1040)
        let win = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "设置"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = false   // v208：原生标题栏（唯一实现）
        // 官方外观：统一灰底（根视图固定 530 而内容区 562，上下露底必须是官方灰，
        // 否则露出系统默认白 → 上下白条，2026-10-18 用户实测）
        win.applyOfficialChrome()
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        // 不使用 setFrameAutosaveName：原版设置窗固定 800×562（zoom/miniaturize 已隐藏），
        // 无尺寸记忆需求；且 autosave 会在 display cycle 内用旧帧（914pt）覆盖目标尺寸，
        // 与后续强制 562 构成约束更新循环，触发
        // NSWindow._postWindowNeedsUpdateConstraints 异常（2026-10-16 实测崩溃）。
        // 固定窗口尺寸上下限（原版设置窗 800×562 不可 resize）：
        // 不设时 SwiftUI 的 NSHostingView.updateWindowContentSizeExtremaIfNecessary
        // 会在首次 layout cycle 内请求窗口尺寸变更，同样触发该异常族。
        win.contentMinSize = NSSize(width: 940, height: windowHeight)
        win.contentMaxSize = NSSize(width: 940, height: windowHeight)
        if windowHeight != 620 {
            Log.info("settings", "窗口尺寸探针：probe=\(probeHeight) 采用=\(windowHeight)")
        }
        // v270（红绿灯「空心环」定论，日志实证）：styleMask 必须同时含
        // .miniaturizable 与 .resizable。缺任一个，AppKit 会把对应按钮判为**禁用**，
        // macOS 27 对禁用态的画法就是「空心灰圈」——红点仍实心，于是呈现
        // 「一个粉红实心 + 两个空心灰圈」的分层假象（14:31 前 style=32771，
        // 补上后 style=32783，三颗灯恢复实心）。窗口仍是固定尺寸（min=max），
        // 绿钮点了不会变尺寸，但外观/点击态与系统一致。
        win.center()
        // SwiftUI 内容**延后一个 runloop** 装载：窗口创建与 NSHostingView 首次布局
        // 若落在同一 display cycle，AppKit 在 updateConstraints observer 内收到
        // 次级窗口约束更新请求即抛 NSException（2026-10-16 三组崩溃栈实证：
        // _postWindowNeedsUpdateConstraints / UpdateConstraints observer → _crashOnException）。
        // 分 cycle 后该链路不再成立。占位空视图避免装载前出现无内容窗口。
        win.contentView = NSView()
        window = win
        DispatchQueue.main.async { [weak self] in
            Log.info("settings", "async mount block fired, self=\(self != nil)")
            guard let self, let win = self.window else { return }
            Log.info("settings", "hosting view mounting (SettingsRootView)")
            let hostingView = NSHostingView(rootView: SettingsRootView(state: self.uiState))
            Log.info("settings", "hosting view mounted, sizing=\(hostingView.fittingSize)")
            hostingView.sizingOptions = []
            if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
            win.setOfficialContent(hostingView)

        }
        Log.info("Settings", "设置窗口已创建")
    }
}
