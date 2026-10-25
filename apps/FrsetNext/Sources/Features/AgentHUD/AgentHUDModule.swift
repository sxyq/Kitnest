import AppKit
import Foundation
import SwiftUI

// MARK: - Agent HUD 模块入口（v130（AndroMeld/AgentHUD）：Agent HUD 核心接入 B1/B2/B3）
//
// 职责：
//   ① 启动用量监控（B1）与批准拦截框架（B3）；
//   ② 注册状态栏项「Agent 用量」（StatusItemRegistry 动态状态项：数字徽标 + 告警着色，
//      点击开 AgentHUDWindow）——形态适配：菜单栏工具，不做刘海；
//   ③ 深链 frsetnext://agenthud。
//
// 启动方式：AppBootstrap 属 App/（并行代理在改），本模块自举——
//   Panel 预热（启动约 2s）会构建 TransferDockView/CastView，其 onAppear 调
//   AgentHUDModule.startIfNeeded()；同时本模块实现 AppModule 协议，
//   App 层可加 `ModuleRegistry.register(AgentHUDModule.self)` 正式接入（一行，见汇报）。

public enum AgentHUDModule: AppModule {
    public static let identifier = "agenthud"

    private static var started = false

    /// 幂等启动（TransferDock 页 onAppear / 设置入口 / 深链均可调）
    public static func startIfNeeded() {
        guard !started else { return }
        started = true

        // B1：用量监控（5 分钟周期；后台扫描 ~/.claude/ 与 ~/.codex/）
        AgentUsageMonitor.shared.start()

        // B3：批准/提问拦截（监听 hook 输出文件 → 系统通知 + 点击跳转）
        AgentApprovalWatcher.shared.start()
        NSUserNotificationCenter.default.delegate = AgentApprovalClickHandler.shared

        // 状态栏项「Agent 用量」（StatusBarController 每 5s 同步注册表，自动出现）
        registerStatusItem()

        // 深链 frsetnext://agenthud（拦截 GURL 事件；其余深链原样交回 AppDelegate）
        AgentHUDDeepLink.install()

        Log.info("AgentHUD", "module started")
    }

    /// AppModule 协议入口（App 层正式注册时用）
    public static func start() {
        startIfNeeded()
    }

    // MARK: 状态栏项「Agent 用量」
    //
    // 走 StatusItemRegistry（Core 既有注册表，StatusBar 模块自动消费）：
    // 标题 = 用量数字徽标（今日 Token 或额度百分比），告警时按级别着色（B2）。
    // 注意：主图标右键菜单里的「Agent 用量」菜单项在 StatusBarMenuBuilder（StatusBar/ 不归
    // 本代理），如需放进主菜单，加一行 item 即可（见汇报「遗留」）。

    private static func registerStatusItem() {
        StatusItemRegistry.register(StatusItemDescriptor(
            id: "agenthud.usage",
            priority: 80,
            title: { statusTitle() },
            attributedTitle: { statusAttributedTitle() },
            onTap: {
                NSApp.activate(ignoringOtherApps: true)
                AgentHUDWindowController.shared.show()
            },
            popover: nil
        ))
    }

    /// 数字徽标：有额度显示「AI:87%」，无额度显示「AI:3.2M」（近 30 天 Token 缩写）
    private static func statusTitle() -> String {
        let monitor = AgentUsageMonitor.shared
        if let pct = monitor.quotas.map(\.usedPercent).max() {
            return "AI:\(Int(pct))%"
        }
        let total = monitor.usages.reduce(0) { $0 + $1.totalTokens }
        if total >= 1_000_000 { return String(format: "AI:%.1fM", Double(total) / 1_000_000) }
        if total >= 1_000 { return String(format: "AI:%.0fk", Double(total) / 1_000) }
        return "AI"
    }

    /// 告警着色（B2）：level 2 = 红（撑不到重置），1 = 橙（达阈值），0 = 默认色
    private static func statusAttributedTitle() -> NSAttributedString {
        let title = statusTitle()
        let color: NSColor
        switch AgentUsageMonitor.shared.alertLevel {
        case 2: color = .systemRed
        case 1: color = .systemOrange
        default: color = .labelColor
        }
        return NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: color,
        ])
    }
}

// MARK: - 深链 frsetnext://agenthud
//
// FrsetNextApp 的 URL switch 在 App/（并行代理在改，本代理不动）。
// 这里拦截 kAEGetURL('GURL') Apple Event：host == "agenthud" 自行开窗；
// **其余 URL 原样交回 AppDelegate 的 application(_:open:)**（默认处理器同款路径，
// settings/archive/panel 等既有深链行为不变）。App 层若改为 switch 里直接
// `case "agenthud": AgentHUDWindowController.shared.show()`，可移除本拦截。

public enum AgentHUDDeepLink {

    private static var installed = false

    public static func install() {
        guard !installed else { return }
        installed = true
        // kInternetEventClass = 'GURL' = 0x4755524C；kAEGetURL = 'GURL' = 0x4755524C
        let eventClass = AEEventClass(0x4755524C)
        let eventID = AEEventID(0x4755524C)
        NSAppleEventManager.shared().setEventHandler(
            Handler.shared,
            andSelector: #selector(Handler.handleGetURL(_:withReplyEvent:)),
            forEventClass: eventClass,
            andEventID: eventID)
        Log.info("AgentHUD", "深链拦截已安装：frsetnext://agenthud")
    }

    /// 供 App 层一行接线用：`case "agenthud": AgentHUDDeepLink.handle(url)`
    public static func handle(_ url: URL) {
        guard url.host == "agenthud" else { return }
        NSApp.activate(ignoringOtherApps: true)
        AgentHUDWindowController.shared.show()
    }

    final class Handler: NSObject {
        static let shared = Handler()

        @objc func handleGetURL(_ event: NSAppleEventDescriptor,
                                withReplyEvent reply: NSAppleEventDescriptor) {
            // keyDirectObject = '----' = 0x2D2D2D2D
            guard let raw = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D2D2D))?.stringValue,
                  let url = URL(string: raw) else { return }
            if url.host == "agenthud" {
                DispatchQueue.main.async { AgentHUDDeepLink.handle(url) }
                return
            }
            // 其余深链：交回 AppDelegate（NSApplicationDelegate 的 application(_:open:)）
            // ——与系统默认 kAEGetURL 处理器同款路径，既有深链（settings/archive/…）不受影响
            guard let delegate = NSApp.delegate else {
                Log.warn("AgentHUD", "深链转发失败（无 NSApp.delegate）：\(raw)")
                return
            }
            delegate.application?(NSApp, open: [url])
        }
    }
}
