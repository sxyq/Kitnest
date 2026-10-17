import AppKit
import SwiftUI

// MARK: - 设置窗口控制器
// 原 App 用 SwiftUI Settings scene；重建改为独立 NSWindow + NSHostingView，
// 便于其他模块通过 ServiceLocator.settings?.open(pane:) 程序化唤起并直达指定页签。

/// 设置窗口内 SwiftUI 层与 AppKit 层共享的选中页签状态
final class SettingsUIState: ObservableObject {
    @Published var selectedPaneID: String
    @Published var detailPaneID: String?
    init(selectedPaneID: String = "general") {
        self.selectedPaneID = selectedPaneID
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
    /// SwiftUI 根视图的选中状态（open(pane:) 由此驱动页签跳转）
    private let uiState = SettingsUIState()

    private override init() {
        super.init()
    }

    // MARK: SettingsWindowControlling

    /// 打开设置窗口；pane 传页签 id（如 "general"/"shortcuts"），nil 保持当前页
    public func open(pane: String?) {
        ensureWindow()
        if let pane {
            if ["general", "search", "tools", "shortcuts", "about"].contains(pane) {
                uiState.selectedPaneID = pane
                uiState.detailPaneID = nil
            } else {
                uiState.detailPaneID = pane
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.orderOut(nil)
    }

    /// 窗口是否正在显示（状态栏菜单勾选态可用）
    public var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - 窗口构建

    private func ensureWindow() {
        guard window == nil else { return }

        let win = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 530),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "设置"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        // 不使用 setFrameAutosaveName：原版设置窗固定 800×562（zoom/miniaturize 已隐藏），
        // 无尺寸记忆需求；且 autosave 会在 display cycle 内用旧帧（914pt）覆盖目标尺寸，
        // 与后续强制 562 构成约束更新循环，触发
        // NSWindow._postWindowNeedsUpdateConstraints 异常（2026-10-16 实测崩溃）。
        // 固定窗口尺寸上下限（原版设置窗 800×562 不可 resize）：
        // 不设时 SwiftUI 的 NSHostingView.updateWindowContentSizeExtremaIfNecessary
        // 会在首次 layout cycle 内请求窗口尺寸变更，同样触发该异常族。
        win.contentMinSize = NSSize(width: 800, height: 530)
        win.contentMaxSize = NSSize(width: 800, height: 530)
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
            guard let self, let win = self.window else { return }
            let hostingView = NSHostingView(rootView: SettingsRootView(state: self.uiState))
            hostingView.sizingOptions = []
            if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
            win.contentView = hostingView
        }
        Log.info("Settings", "设置窗口已创建")
    }
}
