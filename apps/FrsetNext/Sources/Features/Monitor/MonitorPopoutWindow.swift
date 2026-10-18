import AppKit
import SwiftUI

// MARK: - 性能监测独立窗口（v59 新建，v60 定为唯一性能界面，v63 交互对齐主面板）
//
// v63（2026-10-19 用户澄清）：
//   · **点外即消正是想要的行为**——恢复失焦自动关闭（与主面板一致，招之即来挥之即去）；
//   · 展开位置/动画：从**状态栏部件图标**处展开（顶边贴菜单栏、x 对齐锚点中心，
//     钳制可见区），动画与主面板同款「长出来」弹簧（scale 0.93→1 anchor top +
//     下移进入 + 淡入，response 0.24 / damping 0.82），不再是生硬的 alpha 淡入；
//   · 模块切换：窗口尺寸固定（NSHostingView.sizingOptions = [] 禁止内容反驱窗口，
//     此前切模块时窗口随内容 320×529 之类跳变 = 「切换动画不对」的根源），
//     内容改在固定窗口内滚动。
// 链路：部件点击（带锚点）/ ⌥P / ⌥M → open；再点部件 = 切模块不重定位。
// 窗口可见期间 MonitorSampler 用用户刷新间隔（门控在 open/dismiss 挂接）。

/// 独立窗内容的进出场状态（驱动「长出来」弹簧动画）
public final class PopoutPresentation: ObservableObject {
    @Published public var visible = false
}

/// 窗口内容根：固定尺寸内滚动 + 进出场弹簧（主面板同款参数）
private struct PopoutRootView: View {
    @ObservedObject var presentation: PopoutPresentation
    let detail: MonitorDetailView

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            detail
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaleEffect(presentation.visible ? 1 : 0.93, anchor: .top)
        .offset(y: presentation.visible ? 0 : -10)
        .opacity(presentation.visible ? 1 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: presentation.visible)
    }
}

public final class MonitorPopoutWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = MonitorPopoutWindowController()

    /// 独立窗口自己的模块选中态（唯一一套，不再与主面板共享）
    private var selection: MonitorDetailSelection
    /// 进出场动画状态
    private let presentation = PopoutPresentation()
    /// 无指定模块时的回退（记忆上次查看的模块）
    private var lastModule: MonitorModuleID = .cpu

    private convenience init() {
        // 先走 designated init（selection/presentation 就绪），再把 rootView
        // 装进窗口——保证 PopoutRootView 观察的 presentation 与 controller
        // 操作的是**同一个实例**（此前两处各自 new，open() 置 visible 打在
        // 无人观察的实例上，内容恒 opacity 0 = 空白窗）。
        self.init(window: nil)
        let detail = MonitorDetailView(selection: selection, pageMode: false)
        let host = NSHostingView(rootView: PopoutRootView(presentation: presentation, detail: detail))
        host.sizingOptions = []          // 内容不反驱窗口大小（固定尺寸，切模块不跳变）
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "性能监测"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 340, height: 480)
        window.contentView = host
        window.applyOfficialChrome()
        window.attachOfficialRoundCloseButton()
        window.delegate = self
        self.window = window
    }

    private override init(window: NSWindow?) {
        self.selection = MonitorDetailSelection(.cpu)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    // MARK: 开关

    /// 窗口当前是否可见
    public var isVisible: Bool { window?.isVisible == true }

    // MARK: 空闲预热（v62）

    private var warmupDone = false

    /// 启动空闲期离屏布局一次（与主面板 warmup 同模式，3s 错峰避免争抢）。
    /// 预热后首开只剩定位 + 「长出来」动画。
    public func scheduleWarmup(after delay: TimeInterval = 3.0) {
        guard !warmupDone else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isVisible, let w = self.window, w.alphaValue == 1 else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            w.orderFrontRegardless()      // 只上屏、不激活、不抢 key
            w.contentView?.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            w.orderOut(nil)
            self.warmupDone = true
            Log.info("Monitor", String(format: "监测独立窗口预热完成 %.0fms",
                                      (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
    }

    /// ⌥M：可见则收起，否则按 module（缺省 = 上次查看的模块）打开
    public func toggle(module: MonitorModuleID? = nil) {
        if isVisible {
            dismissPopout()
        } else {
            open(module: module)
        }
    }

    /// 打开。anchor = 状态栏部件屏幕坐标（部件点击传入）——窗口在其正下方展开，
    /// x 对齐锚点中心并钳制可见区；nil（⌥P/⌥M）回退右上贴边（主面板停靠时让位）。
    public func open(module: MonitorModuleID? = nil, anchor: NSRect? = nil) {
        guard let w = window, !isVisible else { return }
        let target = module ?? lastModule
        lastModule = target
        selection.module = target
        w.setFrameOrigin(origin(for: w.frame.size, anchor: anchor))
        w.alphaValue = 1
        presentation.visible = false
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // 下一拍触发「长出来」弹簧（同帧置 true 无状态变化、动画不发生）
        DispatchQueue.main.async { [weak self] in
            self?.presentation.visible = true
        }
        // 采样门控：窗口可见期间用用户刷新间隔
        MonitorSampler.shared.setPanelActive(true)
        Log.info("Monitor", "监测独立窗口：打开（\(target.displayName)）")
    }

    /// 窗口已开时部件再点：只切模块，不挪窗口位置
    public func showModule(_ module: MonitorModuleID) {
        guard isVisible else { open(module: module); return }
        lastModule = module
        selection.module = module
        Log.info("Monitor", "监测独立窗口：切换模块（\(module.displayName)）")
    }

    /// 「点外即消」收起：内容弹簧退出（visible=false），0.22s 后 orderOut；
    /// 期间再次 open（visible 置回 true）则跳过 orderOut。
    public func dismissPopout() {
        guard let w = window, w.isVisible else { return }
        presentation.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self, let w = self.window, !self.presentation.visible else { return }
            w.orderOut(nil)
            // 门控复位：窗口隐藏后回到空闲采样节奏
            MonitorSampler.shared.setPanelActive(false)
        }
        Log.info("Monitor", "监测独立窗口：关闭")
    }

    /// 定位：锚点下方（顶边贴菜单栏 -2pt、x 对齐锚点中心、钳制可见区）或右上贴边
    private func origin(for size: NSSize, anchor: NSRect?) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let anchor, anchor.width > 0, anchor.midX > 0 {
            var x = NSMidX(anchor) - size.width * 0.5
            let minX = visible.origin.x + 6
            let maxX = visible.maxX - size.width - 6
            if maxX >= minX { x = max(minX, min(x, maxX)) } else { x = minX }
            return NSPoint(x: x, y: visible.maxY - size.height - 2)
        }
        var x = visible.maxX - size.width - 8
        if let panelFrame = PanelController.shared.panelFrameForPopout,
           panelFrame.maxY > visible.maxY - 60 {
            x = min(x, panelFrame.minX - size.width - 12)
        }
        return NSPoint(x: max(visible.minX + 8, x), y: visible.maxY - size.height - 2)
    }
}

// MARK: - NSWindowDelegate（点外即消）

extension MonitorPopoutWindowController {
    public func windowDidResignKey(_ notification: Notification) {
        // 排障/截图专用：FRSET_PANEL_PIN=1 时不因失焦自动收起（与主面板同探针）
        if ProcessInfo.processInfo.environment["FRSET_PANEL_PIN"] == "1" { return }
        dismissPopout()
    }
}
