import AppKit
import SwiftUI

// MARK: - 欢迎窗控制器（重建版自研，替代原版 WelcomeWindowController/WelcomeWindowDelegate）
//
// 触发策略：
//   · 首次启动（onboarding.welcomeSeenVersion 为空或旧于当前 ONBOARDING_VERSION）自动弹出；
//   · 大版本功能地图更新时提升 ONBOARDING_VERSION → 老用户也能看到新版导览；
//   · 之后可从状态栏菜单「欢迎与权限…」手动打开（入口见 StatusBarMenuBuilder）。
//
// 「开始使用」= 写 seenVersion + 关窗。引导不强制走完：权限引导窗可跳过，
// 核心权限缺失时仅在各功能实际触发时按原有逻辑提示（ScreenshotManager 等）。

public final class WelcomeWindowController: NSObject {

    public static let shared = WelcomeWindowController()

    /// 当前引导版本：功能地图发生较大变化时 +1，老用户会重新看到欢迎窗
    /// v183：补上文件归档、监测三页拆分、剪贴板就地预览等新能力 → 2
    public static let onboardingVersion = 2

    private var window: WelcomeWindow?

    private override init() { super.init() }

    // MARK: - 首启判定

    /// 是否应该展示欢迎窗（首启或引导版本过旧）
    public static var shouldPresentOnLaunch: Bool {
        let seen = UserDefaults.standard.integer(forKey: Preferences.Keys.onboardingWelcomeSeenVersion)
        return seen < onboardingVersion
    }

    // MARK: - 显示 / 关闭

    public func show() {
        Log.info("Onboarding", "欢迎窗 show")
        ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        RenderProbe.snapshot(window, name: "welcome", reason: "show")
    }

    /// 「开始使用」：标记已看 + 关闭
    public func finishOnboarding() {
        UserDefaults.standard.set(WelcomeWindowController.onboardingVersion,
                                  forKey: Preferences.Keys.onboardingWelcomeSeenVersion)
        Log.info("Onboarding", "欢迎窗完成，seenVersion=\(WelcomeWindowController.onboardingVersion)")
        close()
    }

    public func close() {
        RenderProbe.snapshot(window, name: "welcome", reason: "close")
        window?.orderOut(nil)
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - 窗口构建（形态对齐 SettingsWindowController：固定尺寸 + 官方外观 + 延后装载）

    private func ensureWindow() {
        guard window == nil else { return }
        let win = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "欢迎"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = false   // v208：原生标题栏（唯一实现）
        win.applyOfficialChrome()
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        // 固定尺寸：NSHostingView 会把 fitting size 折成窗口尺寸请求，不固定会触发
        // Update Constraints 循环（2026-10-16 实测崩溃，见 SettingsWindowController 头注）
        win.contentMinSize = NSSize(width: 760, height: 620)
        win.contentMaxSize = NSSize(width: 760, height: 620)
        // v205：红黄绿三钮统一显示（固定尺寸窗口的黄/绿由系统置灰）
        win.center()
        win.contentView = NSView()
        window = win
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window else { return }
            let hostingView = NSHostingView(rootView: WelcomeView())
            hostingView.sizingOptions = []
            if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
            win.contentView = hostingView
        }
        Log.info("Onboarding", "欢迎窗已创建")
    }
}

// MARK: - 窗口子类（Esc = 稍后再说：直接关，不标记已看，下次启动还会出现）

final class WelcomeWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.type == .keyDown {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
