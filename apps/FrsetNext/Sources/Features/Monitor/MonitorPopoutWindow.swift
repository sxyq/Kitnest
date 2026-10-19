import AppKit
import QuartzCore
import SwiftUI

// MARK: - 性能监测独立窗口（v59 新建，v60 定为唯一性能界面，v63 交互对齐主面板）
//
// v71（2026-10-19 用户需求「布局留白 / 框大小可不一致 / 展开动画不流畅」）：
//   · 布局：内容撑满窗口宽度（fixedWidth=nil，原 292 限宽是 380 窗内两侧大留白的根源），
//     窗口高度**内容驱动**（GeometryReader 异步测量 → animator 平滑过渡，
//     各模块内容多少不同 → 窗口高低可不同，顶边贴菜单栏不动）；
//   · 动画：SwiftUI scaleEffect 换成 **contentView.layer 的 CA 动画**（GPU 合成，
//     ScrollView 内容不参与逐帧重绘——原实现每帧主线程 layout+合成导致卡顿）。
//     进出场 = 锚点横向偏移 + scale 0.93→1 + 上移 12 + 淡入，timing 类弹簧；
//   · 交互不变：点外即消 / 部件锚点展开 / 切模块不挪位置 / 采样门控。
// 链路：部件点击（带锚点）/ ⌥P / ⌥M → open；再点部件 = 切模块不重定位。

/// 内容高度偏好键（异步测量 → 控制器 resize）
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// 窗口内容根：detail 自带模块切换条 + 底栏（fixedWidth=nil 撑满）；
/// 内容高度经偏好异步上报控制器（驱动窗口平滑 resize）
private struct PopoutRootView: View {
    let detail: MonitorDetailView
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            detail
                .background(GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                })
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            onHeightChange(height)
        }
    }
}

public final class MonitorPopoutWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = MonitorPopoutWindowController()

    /// 独立窗口自己的模块选中态（唯一一套，不再与主面板共享）
    private var selection: MonitorDetailSelection
    /// 无指定模块时的回退（记忆上次查看的模块）
    private var lastModule: MonitorModuleID = .cpu

    private convenience init() {
        self.init(window: nil)
        let detail = MonitorDetailView(selection: selection, pageMode: false, fixedWidth: nil)
        let host = NSHostingView(rootView: PopoutRootView(detail: detail) { [weak self] height in
            self?.resize(toContentHeight: height)
        })
        host.sizingOptions = []          // 内容不反驱窗口大小（高度由控制器按测量值动画过渡）
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
    /// 预热后首开只剩定位 + 入场动画。
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
        // v71：layer 级入场动画（GPU 合成）——从锚点方向「长出来」
        playAppearAnimation(anchor: anchor)
        w.makeKeyAndOrderFront(nil)
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

    // MARK: 布局（v71：内容高度驱动，各模块框大小可不同）

    /// 内容高度变化 → 窗口高度平滑过渡（顶边贴菜单栏不动；clamp 480~屏高-40）。
    /// animator 帧动画与 layer 入场动画可并存（frame 动画改窗口、transform 改内容层）。
    func resize(toContentHeight height: CGFloat) {
        guard let w = window, height > 1 else { return }
        let screen = w.screen ?? NSScreen.main
        let maxH = min(880, (screen?.visibleFrame.height ?? 900) - 40)
        let target = max(480, min(maxH, height))
        guard abs(target - w.frame.height) > 1 else { return }
        var frame = w.frame
        frame.origin.y -= (target - frame.height)   // 顶边固定，向下增高
        frame.size.height = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(frame, display: true)
        }
    }

    // MARK: 动画（v71：contentView.layer CA 动画，GPU 合成不卡顿）

    /// 入场：从锚点横向偏移 + scale 0.93→1 + 上移 12 + 淡入（timing 类弹簧 0.28s）
    private func playAppearAnimation(anchor: NSRect?) {
        guard let layer = window?.contentView?.layer else { return }
        layer.removeAllAnimations()
        let dx = anchorDx(anchor: anchor)
        let start = CATransform3DConcat(
            CATransform3DMakeScale(0.93, 0.93, 1),
            CATransform3DMakeTranslation(dx, -12, 0)
        )
        layer.transform = start
        layer.opacity = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.28)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.22, 1.05, 0.36, 1))
        CATransaction.setCompletionBlock { [weak self] in
            self?.window?.contentView?.layer?.transform = CATransform3DIdentity
            self?.window?.contentView?.layer?.opacity = 1
        }
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    /// 退场：缩小 + 上移 + 淡出（0.18s easeIn），完成后 orderOut；期间重开则取消
    public func dismissPopout() {
        guard let w = window, w.isVisible else { return }
        guard let layer = w.contentView?.layer else {
            w.orderOut(nil)
            MonitorSampler.shared.setPanelActive(false)
            return
        }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        layer.transform = CATransform3DConcat(
            CATransform3DMakeScale(0.95, 0.95, 1),
            CATransform3DMakeTranslation(0, -8, 0))
        layer.opacity = 0
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            if self.isVisible { return }   // 动画期间重开（open 已重置 transform）→ 不收起
            self.window?.orderOut(nil)
            self.window?.contentView?.layer?.transform = CATransform3DIdentity
            self.window?.contentView?.layer?.opacity = 1
            MonitorSampler.shared.setPanelActive(false)
        }
        CATransaction.commit()
        Log.info("Monitor", "监测独立窗口：关闭")
    }

    /// 入场起点横移：从锚点相对窗口中心的水平距离反向补偿（视觉上从部件图标处展开）
    private func anchorDx(anchor: NSRect?) -> CGFloat {
        guard let w = window, let anchor, anchor.width > 0, w.frame.width > 0 else { return 0 }
        let anchorCenterX = anchor.midX - w.frame.minX
        let ratio = max(0, min(1, anchorCenterX / w.frame.width))
        return (0.5 - ratio) * w.frame.width
    }

    // MARK: 定位

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
