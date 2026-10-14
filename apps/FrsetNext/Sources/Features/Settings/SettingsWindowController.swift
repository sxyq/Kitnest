import AppKit
import SwiftUI

// MARK: - 设置窗口控制器
// 原 App 用 SwiftUI Settings scene；重建改为独立 NSWindow + NSHostingView，
// 便于其他模块通过 ServiceLocator.settings?.open(pane:) 程序化唤起并直达指定页签。

/// 设置窗口内 SwiftUI 层与 AppKit 层共享的选中页签状态
final class SettingsUIState: ObservableObject {
    @Published var selectedPaneID: String
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
            uiState.selectedPaneID = pane
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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "设置"
        win.isReleasedWhenClosed = false
        win.center()
        // 记忆窗口位置（系统级 autosave；首次无存档时保持居中）
        win.setFrameAutosaveName("FrsetNext.SettingsWindowFrame")

        let root = SettingsRootView(state: uiState)
        win.contentView = NSHostingView(rootView: root)
        window = win
        Log.info("Settings", "设置窗口已创建")
    }
}
