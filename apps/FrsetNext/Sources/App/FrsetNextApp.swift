import SwiftUI
import AppKit

/// 应用入口（菜单栏常驻应用：LSUIElement=1，不显示 Dock 图标）
@main
struct FrsetNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // 主界面由各模块自管理窗口（面板/设置/截图选区等），这里只保留一个空场景。
        // v85（2026-10-20 设置页卡死根因）：此前 `Settings { Color.clear.frame(1,1)
        // .onAppear { 转发到自管窗 + 收掉 SwiftUI 空窗 } }`——**两个设置窗同时存在并
        // 同时布局**（SwiftUI Settings scene 的空窗 + 自管 NSHostingView 窗），
        // 实测 sample 栈：NSWindow layoutIfNeeded → 多层 _layoutSubtreeWithOldSize
        // → NSHostingView.layout → GeometryReader 读 size → 再触发 layout，主线程死循环。
        // 现改为：scene 只放 EmptyView（不转发、不创建内容），⌘, 用 commands
        // 直接指向自管设置窗——永远只有一个设置窗参与布局。
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    ServiceLocator.settings?.open(pane: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
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
        // v84：退出前把个性化防抖窗口内的改动立即落盘（否则 150ms 内退出会丢设置）
        Personalization.shared.flushPendingPersist()
        LogArchive.shared.stop()
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
            case "monitor":
                // v74 深链：打开性能监测独立窗（部件点击/⌥P 的等价入口，便于排障）
                // v86：支持 frsetnext://monitor?module=memory 直达指定模块（排障/截图验证用）
                let moduleRaw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "module" })?.value
                let module = moduleRaw.flatMap(MonitorModuleID.init(rawValue:))
                MonitorPopoutWindowController.shared.open(module: module)
            case "longshot":
                // v74 排障/深链入口：直接进入长截图选区（等价 ⇧⌥L 与面板菜单「长截图」）
                LongScreenshotCoordinator.shared.beginSelection()
            case "panel":
                // 先激活：主面板 windowDidResignKey → hide（transient 行为），
                // 不激活时窗口成为 key 后立即 resign 被自动关闭（2026-10-16 实证）
                NSApp.activate(ignoringOtherApps: true)
                // v73 排障入口：frsetnext://panel?anchor=icon —— 用主图标实际 frame
                // 走锚点展开（验证「图标正下方 + 顶部三角」，等价左键点击路径）
                let anchorIcon = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "anchor" })?.value == "icon"
                // v74 深链：frsetnext://panel?monitor=sensors——面板打开后直达性能页指定模块
                let monitorRaw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "monitor" })?.value
                if let monitorRaw, let module = MonitorModuleID(rawValue: monitorRaw) {
                    MonitorCenterPresenter.shared.selectPerformance(module: module)
                }
                if anchorIcon,
                   let anchor = StatusBarController.shared.mainStatusItem?.button?.window?.frame {
                    Log.info("App", "URL 锚点展开：icon frame=\(anchor)")
                    ServiceLocator.panel?.show(atAnchor: anchor)
                } else {
                    ServiceLocator.panel?.show()
                }
            case "toast":
                // v89 视觉验收/排障深链：frsetnext://toast?text=已复制&icon=checkmark.circle.fill
                // 用途：不依赖具体业务路径即可复现全局提示，便于核对位置/样式/层级。
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let text = comps?.queryItems?.first(where: { $0.name == "text" })?.value ?? "已复制"
                let icon = comps?.queryItems?.first(where: { $0.name == "icon" })?.value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    Toast.show(text, icon: icon)
                }
            default:
                break
            }
        }
    }
}
