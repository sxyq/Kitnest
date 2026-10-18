import AppKit
import SwiftUI

// MARK: - 性能监测独立窗口（v59 新建，v60 定为唯一性能界面）
//
// v60（2026-10-19 用户决策）：性能监测只保留这一套——
//   · 主面板里的「性能监测」页已删除（两套重复实现会打架）；
//   · 状态栏部件点击 / ⌥P / ⌥M 都直达本窗口：未开时打开，已开时只切模块；
//   · 失焦不自动消失（与主面板的"点外即收"不同，这里是常驻浮窗，招之即来
//     挥之即去 = 再点部件 / ⌥M / 关闭按钮）；
//   · 窗口可见期间 MonitorSampler 用用户刷新间隔（采样门控从主面板迁移过来）。
// 实现：内容复用 MonitorDetailView（模块切换条点击直切，自适应换行），
// 窗口 official chrome（灰底 + 圆形关闭钮），floating 层级可叠在别的 App 上。

public final class MonitorPopoutWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = MonitorPopoutWindowController()

    /// 独立窗口自己的模块选中态（唯一一套，不再与主面板共享）
    private var selection: MonitorDetailSelection
    /// 无指定模块时的回退（记忆上次查看的模块）
    private var lastModule: MonitorModuleID = .cpu

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

    /// 窗口当前是否可见
    public var isVisible: Bool { window?.isVisible == true }

    /// ⌥M：可见则收起，否则按 module（缺省 = 上次查看的模块）打开
    public func toggle(module: MonitorModuleID? = nil) {
        if isVisible {
            dismissPopout()
        } else {
            open(module: module)
        }
    }

    public func open(module: MonitorModuleID? = nil) {
        guard let w = window, !isVisible else { return }
        let target = module ?? lastModule
        lastModule = target
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
        // 采样门控：窗口可见期间用用户刷新间隔（原主面板性能页的节奏迁移至此）
        MonitorSampler.shared.setPanelActive(true)
        Log.info("Monitor", "监测独立窗口：打开（\(target.displayName)）")
    }

    /// 窗口已开时部件再点：只切模块，不挪窗口位置、不重播动画
    public func showModule(_ module: MonitorModuleID) {
        guard isVisible else { open(module: module); return }
        lastModule = module
        selection.module = module
        Log.info("Monitor", "监测独立窗口：切换模块（\(module.displayName)）")
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
            // 门控复位：窗口隐藏后回到空闲采样节奏
            MonitorSampler.shared.setPanelActive(false)
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
