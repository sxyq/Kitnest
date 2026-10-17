import SwiftUI
import AppKit

/// 应用入口（菜单栏常驻应用：LSUIElement=1，不显示 Dock 图标）
@main
struct FrsetNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // 主界面由各模块自管理窗口（面板/设置/截图选区等），这里只保留一个空场景
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不显示 Dock 图标（菜单栏应用）
        NSApp.setActivationPolicy(.accessory)
        AppBootstrap.start()
        Log.info("App", "启动完成")
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppBootstrap.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ServiceLocator.panel?.show()
        return true
    }

    /// 程序化唤起入口：等价原版 `StatusBarController.showSettingsWindow:` 的 @objc
    /// 可调用能力。用法：open "frsetnext://settings?pane=general"
    /// （pane: general/search/tools/shortcuts/about；缺省 general）
    /// 签名依据 macOS 13 SDK：ObjC 为 application:openURLs:（NSArray，10.13+），
    /// Swift renamed import 为 application(_:open:)，参数 [URL]。
    /// 满足 NSApplicationDelegate 该 optional 要求即自动生成 ObjC 入口（有 To 符号）。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, url.scheme == "frsetnext" else { return }
        Log.info("App", "URL 唤起: \(url.absoluteString)")
        // 窗口创建延后到下一 runloop：Apple Event 处理上下文内创建 NSWindow +
        // NSHostingView 会在 display cycle layout observer 中触发次级约束更新，
        // 导致 NSWindow._postWindowNeedsUpdateConstraints 异常（2026-10-16 实测：
        // 最小视图同样复现，与视图内容无关）。
        DispatchQueue.main.async {
            switch url.host {
            case "settings":
                let pane = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "pane" })?.value
                ServiceLocator.settings?.open(pane: pane)
            case "statistics":
                StatisticsWindowController.shared.openStatistics()
            case "panel":
                // 先激活：主面板 windowDidResignKey → hide（transient 行为），
                // 不激活时窗口成为 key 后立即 resign 被自动关闭（2026-10-16 实证）
                NSApp.activate(ignoringOtherApps: true)
                ServiceLocator.panel?.show()
            default:
                break
            }
        }
    }
}
