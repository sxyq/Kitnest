import SwiftUI
import AppKit

/// 应用入口（菜单栏常驻应用：LSUIElement=1，不显示 Dock 图标）
@main
struct FrsetNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // 主界面由各模块自管理窗口（面板/设置/截图选区等），这里只保留一个空场景。
        // v66 重要：`Settings { }` scene 会**自动注册 ⌘, 快捷键**——此前用户按 ⌘, 弹出的
        // 是 SwiftUI 的**空设置窗**（900×450 空白、title="FrsetNext设置"），
        // 而真正的设置窗（SettingsWindowController，940×620）从未打开。
        // 现在 scene 内容在出现时**转发**到自管设置窗，并收掉 SwiftUI 的空窗。
        Settings {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    DispatchQueue.main.async {
                        ServiceLocator.settings?.open(pane: nil)
                        // 收掉 SwiftUI Settings scene 的空窗：
                        // 标题含「设置」且非当前 key（自管窗已 makeKey）、宽 < 940（自管窗恒 940）
                        for w in NSApp.windows where w.isVisible
                            && w.title.contains("设置")
                            && w !== NSApp.keyWindow
                            && w.frame.width < 940 {
                            w.orderOut(nil)
                        }
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // v43：菜单栏监控「唯一一套」护栏——先于任何模块启动执行。
        // 菜单栏监控的唯一实现是 STATS 合并条；多开实例/官方原版同跑都会各画一套，
        // 表现为菜单栏出现重复的 CPU/RAM/SSD 组件（用户 2026-10-18 反馈）。
        guard enforceSingleMenubarOwner() else { return }

        // 不显示 Dock 图标（菜单栏应用）
        NSApp.setActivationPolicy(.accessory)
        AppBootstrap.start()
        Log.info("App", "启动完成")

        // 排障探针（2026-10-18）：FRSET_TOAST_PROBE=1 时启动 2s 后弹一条通知条，
        // 用于验证菜单栏通知条窗口在真机上确实可见（截图后"无提示"类问题的最小复现）。
        // 只在显式设置环境变量时执行，平时零开销、不打扰。
        if ProcessInfo.processInfo.environment["FRSET_TOAST_PROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Toast.show("提示条自检", icon: "checkmark.circle.fill")
            }
        }
    }

    /// 菜单栏监控「唯一一套」：STATS 合并条。
    ///
    /// 两道防线：
    /// 1. **同 bundle 多实例** → 新实例立即退出。每个进程都会 `StatsBarEngine.start()`
    ///    建一套合并条（同一个 NSStatusBar 上并列），菜单栏就出现重复组件。
    /// 2. **官方原版 Frset.app 在跑** → 原版的 STATS 注入引擎也会画一套合并条，且与本 app
    ///    共用 `~/Library/Application Support/FrsetStats/widgets.plist` 与 `engine.log`。
    ///    无法从进程内阻止它，因此只提示用户退出原版（避免误以为是我们重复创建）。
    private func enforceSingleMenubarOwner() -> Bool {
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != getpid() }
            if let existing = others.first {
                Log.info("App", "已有实例在运行（pid=\(existing.processIdentifier)）→ 本实例退出，保证菜单栏只有一套监控组件")
                existing.activate(options: [.activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return false
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let originals = NSRunningApplication.runningApplications(withBundleIdentifier: "com.maoux.frset")
            guard !originals.isEmpty else { return }
            Log.info("App", "检测到官方原版 Frset 在运行：它的注入引擎会重复绘制一套菜单栏组件")
            Toast.show("官方原版 Frset 正在运行，会重复绘制一套菜单栏监控组件，建议退出原版",
                       icon: "exclamationmark.triangle.fill", isWarning: true)
        }
        return true
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
