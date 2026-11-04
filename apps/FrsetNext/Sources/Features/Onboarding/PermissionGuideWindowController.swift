import AppKit
import SwiftUI

// MARK: - 权限引导窗控制器（重建版自研，替代原版 PermissionWindowController）
//
// 窗口形态对齐设置窗（SettingsWindowController）：
//   · 固定尺寸 660×600（SwiftUI 根视图同尺寸，防 NSHostingView 约束循环，见
//     SettingsWindowController.ensureWindow 头注：不固定尺寸会触发
//     "more Update Constraints in Window passes" 进程即死）；
//   · applyOfficialChrome() 官方灰底 + 圆形关闭钮；
//   · SwiftUI 内容延后一个 runloop 装载（同一 display cycle 内创建+装载会崩）；
//   · Esc 关闭；不做 setFrameAutosaveName（固定尺寸无记忆需求）。
//
// 入口：欢迎窗「权限设置」按钮 / 状态栏菜单「欢迎与权限…」/ 各模块权限失败时的
// 「去授权」动作（后续由各模块接线，本窗只负责展示）。

public final class PermissionGuideWindowController: NSObject {

    public static let shared = PermissionGuideWindowController()

    private var window: PermissionGuideWindow?

    private override init() { super.init() }

    // MARK: - 显示/关闭

    public func show() {
        Log.info("Onboarding", "权限引导窗 show")
        ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        PermissionCenter.shared.refreshAll()
        Task { await PermissionCenter.shared.probeScreenRecording() }
        RenderProbe.snapshot(window, name: "permissionGuide", reason: "show")
    }

    public func close() {
        Log.info("Onboarding", "权限引导窗 close")
        RenderProbe.snapshot(window, name: "permissionGuide", reason: "close")
        window?.orderOut(nil)
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - 窗口构建

    private func ensureWindow() {
        guard window == nil else { return }
        let win = PermissionGuideWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "权限引导"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = false   // v208：原生标题栏（唯一实现）
        win.applyOfficialChrome()
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 660, height: 600)
        win.contentMaxSize = NSSize(width: 660, height: 600)
        // v205：红黄绿三钮统一显示（固定尺寸窗口的黄/绿由系统置灰）
        win.center()
        win.contentView = NSView()
        window = win
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window else { return }
            let hostingView = NSHostingView(rootView: PermissionGuideView())
            hostingView.sizingOptions = []
            if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
            win.contentView = hostingView
        }
        Log.info("Onboarding", "权限引导窗已创建")
    }
}

// MARK: - 窗口子类（Esc 关闭）

final class PermissionGuideWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.type == .keyDown {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
