import AppKit
import SwiftUI

// MARK: - 统计窗控制器（spec 17 §1 S7b/S11）

/// StatisticsWindowController：SwiftUI + NSWindow 底座
/// 窗体实证（stub 解码）：initWithContentRect:(0,0,800,800) styleMask:0x8003(titled+closable+fullSizeContentView)
/// backing:2 defer:0；空标题 + titlebarAppearsTransparent + 隐藏 close/mini/zoom 三按钮 + center()
public final class StatisticsWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = StatisticsWindowController()

    /// WindowManager 注册表窗口标识（spec 17 S11）
    public static let windowID = "statisticsWindow"

    private convenience init() {
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 800)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        self.init(window: window)
        window.title = ""                                   // 原作 setTitle: 传空串
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if #available(macOS 11.0, *) { window.titlebarSeparatorStyle = .none }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true   // 三按钮全隐藏
        }
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isOpaque = true
        window.isReleasedWhenClosed = false                 // setReleasedWhenClosed:（控制器复用同一窗）
        window.hidesOnDeactivate = false                    // setHidesOnDeactivate: 调用存在，取值 ⬜（统计窗取不隐藏）
        window.delegate = self
        window.contentView = NSHostingView(rootView: StatisticsRootView())
    }

    /// 打开统计窗（每次打开重建内容视图 → 数据/入场动画重放）
    public func openStatistics() {
        window?.contentView = NSHostingView(rootView: StatisticsRootView())
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        // S2：打开即埋点 statistics_open
        StatisticsManager.shared.record(AnalyticsEvent.statisticsOpen)
        // S7b：主队列 asyncAfter 1/30s（≈0.0333s，DOM 就绪后刷新）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
        Log.info("Statistics", "window opened")
    }

    // MARK: NSWindowDelegate（StatisticsWindowDelegate：窗生命周期/关闭清理）

    public func windowWillClose(_ notification: Notification) {
        Log.debug("Statistics", "window will close")
    }
}
