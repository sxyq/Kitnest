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
    /// 侧边栏选中项
    @Published var selection: SettingsSidebarSelection = .category(.general)
    /// 「搜索与 AI」内部分段（0=搜索 1=AI）
    @Published var searchAISub = 0
    /// 「工具与快捷键」内部分段（0=工具 1=快捷键 2=截图）
    @Published var toolingSub = 0

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
        applyPaneMapping(pane)
    }

    private func applyPaneMapping(_ pane: String) {
        switch pane {
        case "general":                  selection = .category(.general)
        case "clipboard":                selection = .category(.clipboard)
        case "transfer":                 selection = .category(.transfer)
        case "search":                   selection = .category(.searchAI); searchAISub = 0
        case "ai":                       selection = .category(.searchAI); searchAISub = 1
        case "tools":                    selection = .category(.tooling); toolingSub = 0
        case "shortcuts":                selection = .category(.tooling); toolingSub = 1
        case "capture":                  selection = .category(.tooling); toolingSub = 2
        case "statistics":               selection = .category(.statistics)
        case "about":                    selection = .category(.about)
        case "monitor", "monitorSettings": selection = .monitorSettings
        case "monitor.widgets", "widgets", "barSettings": selection = .monitorWidgets
        case "manual", "help":           selection = .manual
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

        // v41：设置窗改「左侧大侧边栏（186）+ 内容区（754）」→ 940×620。
        // 内容区宽度与原 800×530 版的可用宽度（约 700）基本一致，设置页表单版式无需重排。
        let win = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "设置"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
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
        win.contentMinSize = NSSize(width: 940, height: 620)
        win.contentMaxSize = NSSize(width: 940, height: 620)
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
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
            win.contentView = hostingView
            // 内容视图换新 → 重挂官方圆形关闭钮（旧占位视图上的钮已移除）
            win.attachOfficialRoundCloseButton()
        }
        Log.info("Settings", "设置窗口已创建")
    }
}
