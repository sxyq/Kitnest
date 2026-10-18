import AppKit
import SwiftUI

// MARK: - 性能监测独立窗口（v59）
//
// 用户需求：状态栏点开的性能界面应当能「独立成单独的窗口」。
// 实现：性能页页脚「弹出」按钮（或 ⌥M）把当前模块内容挂到一个可缩放的
// 常驻小窗里 —— 内容复用 MonitorDetailView（自带模块切换条，切模块零成本），
// 窗口用 official chrome（灰底 + 圆形关闭钮），floating 层级可叠在别的 App 上。
//
// 与主面板的关系：完全独立（自己一份 MonitorDetailSelection），两边可看不同模块；
// 再次 ⌥M / 再点按钮 = 关闭。

public final class MonitorPopoutWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = MonitorPopoutWindowController()

    /// 独立窗口自己的模块选中态（不与主面板共享）
    private var selection: MonitorDetailSelection

    private convenience init() {
        let selection = MonitorDetailSelection(.cpu)
        let root = MonitorDetailView(selection: selection, pageMode: false)
            .padding(14)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "性能监测"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 340, height: 480)
        window.contentView = NSHostingView(rootView: root)
        window.applyOfficialChrome()
        window.attachOfficialRoundCloseButton()
        self.init(window: window)
        self.selection = selection
        window.delegate = self
    }

    private override init(window: NSWindow?) {
        self.selection = MonitorDetailSelection(.cpu)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    // MARK: 开关

    /// ⌥M / 页脚按钮：可见则收起，否则按 module（缺省 = 面板当前模块）打开
    public func toggle(module: MonitorModuleID? = nil) {
        if window?.isVisible == true {
            dismissPopout()
        } else {
            open(module: module)
        }
    }

    public func open(module: MonitorModuleID? = nil) {
        guard let w = window else { return }
        let target = module
            ?? MonitorCenterPresenter.shared.presented
            ?? MonitorCenterPresenter.shared.lastModule
        selection.module = target
        w.setFrameOrigin(topRightOrigin(for: w.frame.size))
        w.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
        }
        Log.info("Monitor", "监测独立窗口：打开（\(target.displayName)）")
    }

    /// 与 NSWindowController.close 区分：这里是"动画收起窗口"
    public func dismissPopout() {
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            w.animator().alphaValue = 0
        }, completionHandler: { [weak w] in
            w?.orderOut(nil)
            w?.alphaValue = 1
        })
        Log.info("Monitor", "监测独立窗口：关闭")
    }

    /// 右上角贴边（菜单栏下留 2pt、右缘留 8pt；主面板也停在右上时往左让位）
    private func topRightOrigin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = visible.maxX - size.width - 8
        if let panelFrame = PanelController.shared.panelFrameForPopout,
           panelFrame.maxY > visible.maxY - 60 {
            x = min(x, panelFrame.minX - size.width - 12)
        }
        let y = visible.maxY - size.height - 2
        return NSPoint(x: max(visible.minX + 8, x), y: y)
    }
}
