import AppKit
import SwiftUI

// MARK: - 统计窗控制器（spec 17 §1 S7b/S11）

/// StatisticsWindowController：SwiftUI + NSWindow 底座
/// 采用同机原版使用统计.png 的整窗 800×562 pt，保留现有单例和窗口标识。
/// 空标题与透明标题栏，仅显示关闭按钮。
public final class StatisticsWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = StatisticsWindowController()

    /// WindowManager 注册表窗口标识（spec 17 S11）
    public static let windowID = "statisticsWindow"

    private convenience init() {
        // contentRect 直接取整窗目标尺寸 800×562（与设置窗同一模式）：
        // 原写法 530 + installContent 内 setFrame 562 会多一次帧变更；
        // 统计窗无 setFrameAutosaveName，不存在旧帧覆盖问题。
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 530)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        self.init(window: window)
        window.title = ""                                   // 原作 setTitle: 传空串
        window.titleVisibility = .hidden
        // v260：标题栏/分隔线/isOpaque 全部由 applyOfficialChrome() 唯一入口决定，
        // 这里不再各写一套（v208 的 .automatic 分隔线正是深色下红绿灯下方那条色带）。
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        // 官方外观：统一灰底（同设置窗——fullSizeContentView + 透明标题栏下
        // 根视图固定 530 而内容区 562，露底必须是官方灰，否则上下白条）
        window.applyOfficialChrome()
        window.isReleasedWhenClosed = false                 // setReleasedWhenClosed:（控制器复用同一窗）
        window.hidesOnDeactivate = false                    // setHidesOnDeactivate: 调用存在，取值 ⬜（统计窗取不隐藏）
        window.delegate = self
        installContent(in: window)
    }

    private func installContent(in window: NSWindow) {
        // 固定尺寸上下限：防止 SwiftUI extrema 更新在 layout cycle 内触发
        // NSWindow._postWindowNeedsUpdateConstraints 异常（同设置窗，2026-10-16 实证）
        window.contentMinSize = NSSize(width: 800, height: 530)
        window.contentMaxSize = NSSize(width: 800, height: 530)
        // SwiftUI 内容延后一个 runloop 装载：窗口创建/显示与 NSHostingView 首次布局
        // 若落在同一 display cycle，AppKit 在 updateConstraints observer 内收到
        // 次级窗口约束更新请求即抛 NSException（与设置窗同源，2026-10-16 实证）。
        window.contentView = NSView()
        DispatchQueue.main.async {
            let hostingView = NSHostingView(rootView: StatisticsRootView())
            hostingView.sizingOptions = []
            if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
            window.contentView = hostingView

        }
    }

    /// 打开统计窗（每次打开重建内容视图 → 数据/入场动画重放）
    public func openStatistics() {
        if let window { installContent(in: window) }
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        // S2：打开即埋点 statistics_open
        StatisticsManager.shared.record(AnalyticsEvent.statisticsOpen)
        // v198：从触发点（菜单/状态栏）展开整块统计窗
        if let w = window { WindowReveal.playInFromMouse(on: w) }
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
