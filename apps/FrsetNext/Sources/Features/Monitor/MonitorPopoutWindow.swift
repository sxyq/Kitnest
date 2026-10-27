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

/// v74：无标题栏玻璃面板（borderless 默认 canBecomeKey=false，需显式放行，
/// 否则「点外/失焦收起」依赖的 key 状态永远不会发生）
final class MonitorPopoutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 窗口内容根：detail 自带模块切换条 + 底栏（fixedWidth=nil 撑满）；
/// 内容高度经偏好异步上报控制器（驱动窗口平滑 resize）
/// 独立窗滚动复位信号：窗口是长期复用的，SwiftUI ScrollView 会**保留上次滚动位置**。
/// 用户在温度长列表滚到底再关窗，下次点部件重开时顶部模块切换条会停在视口外，
/// 看起来就是「面板上面没有切换按钮」——每次 open 递增 token 强制滚回顶部。
private final class PopoutScrollState: ObservableObject {
    @Published var resetToken = 0
}

private struct PopoutRootView: View {
    @ObservedObject var scrollState: PopoutScrollState
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")   // 滚动锚点
                    // v75：与主面板性能页**共用 MonitorPerformanceContent**（唯一实现）。
                    // 唯一差异 = 顶部 22pt，让出左上角自绘关闭钮（borderless 窗无标题栏）。
                    // 选中态共用 MonitorCenterPresenter.shared.monitorSelection，
                    // 两个入口永远显示同一个模块、同一份数据、同一个刷新节奏。
                    MonitorPerformanceContent(topInset: 22)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        })
                }
            }
            .onChange(of: scrollState.resetToken) { _ in
                proxy.scrollTo("top", anchor: .top)
            }
            .onPreferenceChange(ContentHeightKey.self) { height in
                onHeightChange(height)
            }
        }
    }
}

public final class MonitorPopoutWindowController: NSWindowController, NSWindowDelegate {
    public static let shared = MonitorPopoutWindowController()

    /// 无指定模块时的回退（记忆上次查看的模块）
    private var lastModule: MonitorModuleID = .cpu
    /// 滚动复位信号（每次打开回到顶部）
    private let scrollState = PopoutScrollState()

    /// 与主面板性能页**共用**的模块选中态（唯一一套）
    private var sharedSelection: MonitorDetailSelection {
        MonitorCenterPresenter.shared.monitorSelection
    }

    private convenience init() {
        self.init(window: nil)
        let host = NSHostingView(rootView: PopoutRootView(scrollState: scrollState) { [weak self] height in
            self?.resize(toContentHeight: height)
        }
        // 主题统一入口：监测独立窗的强调色 + Midnight（此前两者都没接）
        .frsetThemeChrome())
        host.sizingOptions = []          // 内容不反驱窗口大小（高度由控制器按测量值动画过渡）

        // v74 修正（用户 2026-10-19 再次指出「两套不一样」）：上一版只换了材质，
        // 窗口仍是 .titled（系统标题栏悬浮在 fullSizeContentView 顶部）——
        // **顶部模块切换条 modulePicker 被标题栏区域压住/挤掉**，看起来「上面没有
        // 切换按钮、只有对应模块的内容」，与主页 Performance 页不是同一套。
        // 现彻底对齐「状态栏部件点开的 popover」形态：
        //   · borderless 面板（无标题栏、无红绿灯），自定义圆角关闭钮
        //   · 玻璃 = NSVisualEffectView(.popover)，12pt 连续圆角，圆角裁剪
        //   · canBecomeKey = true（点外/失焦收起依赖 key 状态）
        //   · isMovableByWindowBackground = true（可拖动）
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 12
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)

        let window = MonitorPopoutPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                                        styleMask: [.borderless, .fullSizeContentView],
                                        backing: .buffered, defer: false)
        window.title = "性能监测"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 320, height: 200)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.contentView = glass
        window.attachOfficialRoundCloseButton()
        window.delegate = self
        self.window = window
        // 点外/失焦收起统一由 TransientWindowCenter 仲裁（本文件不再单写监听）
    }

    private override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    // MARK: 开关

    /// 窗口当前是否可见
    public var isVisible: Bool { window?.isVisible == true }

    /// 开/关动画序号（v71 白屏实障修复）：dismissPopout 的 completion 原来用
    /// `isVisible` 判断「动画期间是否重开」——但动画结束时窗口尚未 orderOut，
    /// isVisible 恒为 true → completion 永远 return → orderOut 永不执行、
    /// layer.opacity 停在 0 → contentView 透明露出窗口灰底 = 白屏（titlebar 仍在）。
    /// 现改用 token：open 递增，dismiss 记录起点，completion 发现 token 变了
    /// （期间重开过）才跳过收起。
    private var appearToken = 0

    /// 收起流程幂等锁（防全局/本地/轮询/resign 多路重复触发互相打断动画）
    private var isDismissing = false
    /// 最近一次收起的时刻（供状态项做「刚被这次点击关掉」的去抖判断）
    private var lastDismissUptime: TimeInterval = 0

    /// 当前展示的模块（状态项 toggle 判断用；与主面板性能页同一选中态）
    public var currentModule: MonitorModuleID { sharedSelection.module }

    /// 最近 interval 秒内是否刚收起过（状态项 mouseUp 晚于监视器 mouseDown 触发时，
    /// 避免同一图标点击被「先关后开」重新拉起来）
    public func wasJustDismissed(within interval: TimeInterval = 0.6) -> Bool {
        ProcessInfo.processInfo.systemUptime - lastDismissUptime < interval
    }

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
        // v86：显式模块优先——窗口已经打开时也要切过去（深链 monitor?module=memory 用）
        if let module { sharedSelection.module = module; lastModule = module }
        guard let w = window, !isVisible else { return }
        // 无显式模块（⌥M / URL / 快捷键）时沿用**共享选中态**当前模块，
        // 不再用独立窗自己的 lastModule——否则刚在主页性能页选好温度，
        // 从状态栏打开又跳回 CPU，两个入口就像两套东西。
        let target = module ?? sharedSelection.module
        lastModule = target
        sharedSelection.module = target
        appearToken += 1                       // v71：递增，令在途 dismiss completion 失效
        isDismissing = false                   // 重开：清掉上一次收起的幂等锁
        scrollState.resetToken += 1            // 回到顶部：顶部模块切换条必须可见
        w.contentView?.layer?.removeAllAnimations()
        w.contentView?.layer?.transform = CATransform3DIdentity   // 兜底复位（白屏态重开）
        w.contentView?.layer?.opacity = 1
        w.setFrameOrigin(origin(for: w.frame.size, anchor: anchor))
        w.alphaValue = 1
        // v71：layer 级入场动画（GPU 合成）——从锚点方向「长出来」
        playAppearAnimation(anchor: anchor)
        // v74（2026-10-19 用户反馈「点其他位置无法收起」）：
        // LSUIElement 未前台时窗口可能成不了 key → resignKey 永不触发；
        // 且本 app 辅助功能未授权，全局监视器可能收不到事件。
        // 现在四路冗余：① 激活+key ② 全局监视器 ③ 本 app 内监视器 ④ 按键轮询兜底
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // 点外收起：统一注册到 TransientWindowCenter（全工程唯一实现）
        TransientWindowCenter.shared.register(
            window: w,
            onDismiss: { [weak self] in self?.dismissPopout() })
        // 采样门控：窗口可见期间用用户刷新间隔
        MonitorSampler.shared.setPanelActive(true)
        Log.info("Monitor", "监测独立窗口：打开（\(target.displayName)）")
        // 诊断（排查「点外不关」必备）：0.2s 后记录是否真的成为 key/激活
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let w = self.window, w.isVisible else { return }
            Log.info("Monitor", "开窗态：appActive=\(NSApp.isActive) isKey=\(w.isKeyWindow)")
        }
        RenderProbe.snapshot(w, name: "monitorPopout", reason: "open")
    }

    /// 取消在途收起（点外监视器先于 statusItem 的 mouseUp 触发时，
    /// 用户其实是在「切换模块」，不能让窗口在 0.2s 后照旧收起）
    private func cancelDismiss() {
        guard isDismissing else { return }
        isDismissing = false
        appearToken += 1
        window?.contentView?.layer?.removeAllAnimations()
        window?.contentView?.layer?.transform = CATransform3DIdentity
        window?.contentView?.layer?.opacity = 1
        Log.info("Monitor", "取消在途收起（切换模块/重开）")
    }

    /// 窗口已开时部件再点：只切模块，不挪窗口位置
    public func showModule(_ module: MonitorModuleID) {
        guard isVisible else { open(module: module); return }
        cancelDismiss()                        // 若点外监视器已抢先触发收起，先撤销
        lastModule = module
        sharedSelection.module = module
        Log.info("Monitor", "监测独立窗口：切换模块（\(module.displayName)）")
    }

    // MARK: 布局（v71：内容高度驱动，各模块框大小可不同）

    /// 内容高度变化 → 窗口高度平滑过渡（顶边贴菜单栏不动；clamp 200~屏高-40）。
    /// animator 帧动画与 layer 入场动画可并存（frame 动画改窗口、transform 改内容层）。
    ///
    /// v88（2026-10-20 用户反馈「GPU 页高度很短却留大片空白，应自适应匹配」）：
    /// 原下限 480 会把内容仅 ~350 的短页撑出底部空白；改为 200 下限，
    /// 窗口高度=内容高度，短页不再留白。
    func resize(toContentHeight height: CGFloat) {
        guard let w = window, height > 1 else { return }
        let screen = w.screen ?? Self.screen(for: nil)
        let maxH = min(880, (screen?.visibleFrame.height ?? 900) - 40)
        let target = max(200, min(maxH, height))
        guard abs(target - w.frame.height) > 1 else { return }
        var frame = w.frame
        frame.origin.y -= (target - frame.height)   // 顶边固定，向下增高
        frame.size.height = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.dPage
            ctx.timingFunction = Theme.Motion.caEaseOut
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
        CATransaction.setAnimationTimingFunction(Theme.Motion.caBackOut)
        CATransaction.setCompletionBlock { [weak self] in
            self?.window?.contentView?.layer?.transform = CATransform3DIdentity
            self?.window?.contentView?.layer?.opacity = 1
        }
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    /// 退场：缩小 + 上移 + 淡出，**200ms 硬兜底强制 orderOut**。
    /// 历史 bug（本轮定位）：原实现只在 CATransaction completion 里 orderOut，
    /// 窗口被遮挡/动画被系统跳过/重复 dismiss 打断动画时 completion 不执行 →
    /// 日志有「dismiss」但没有「已收起」，窗口永远留在屏上，用户以为「点外不关」。
    public func dismissPopout() {
        guard let w = window, w.isVisible else {
            // 已不可见：注销注册与采样门控（幂等）
            if let w = window { TransientWindowCenter.shared.unregister(window: w) }
            MonitorSampler.shared.setPanelActive(false)
            return
        }
        guard !isDismissing else { return }    // 多路触发（全局/本地/轮询/resign）只跑一次
        isDismissing = true
        lastDismissUptime = ProcessInfo.processInfo.systemUptime
        let token = appearToken
        Log.info("Monitor", "监测独立窗口：dismiss")
        RenderProbe.snapshot(w, name: "monitorPopout", reason: "dismiss")
        if let layer = w.contentView?.layer {
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setAnimationDuration(Theme.Motion.dFast)
            CATransaction.setAnimationTimingFunction(Theme.Motion.caEaseIn)
            layer.transform = CATransform3DConcat(
                CATransform3DMakeScale(0.96, 0.96, 1),
                CATransform3DMakeTranslation(0, -8, 0))
            layer.opacity = 0
            CATransaction.setCompletionBlock { [weak self] in
                self?.finishDismiss(token: token)
            }
            CATransaction.commit()
        }
        // 硬兜底：无论动画回调是否执行，0.2s 后一定收尾（幂等）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.finishDismiss(token: token)
        }
    }

    /// 收尾（幂等）：orderOut + 复位图层 + 卸监听 + 关采样门控
    private func finishDismiss(token: Int) {
        guard isDismissing else { return }
        guard let w = window else { isDismissing = false; return }
        // 期间 open()/cancelDismiss 递增过 token = 已重开 → 放弃本次收起
        guard appearToken == token else {
            isDismissing = false
            Log.info("Monitor", "dismiss 被重开打断，跳过收起")
            return
        }
        isDismissing = false
        w.orderOut(nil)
        w.contentView?.layer?.removeAllAnimations()
        w.contentView?.layer?.transform = CATransform3DIdentity
        w.contentView?.layer?.opacity = 1
        TransientWindowCenter.shared.unregister(window: w)
        MonitorSampler.shared.setPanelActive(false)
        Log.info("Monitor", "监测独立窗口：已收起")
        RenderProbe.snapshot(w, name: "monitorPopout", reason: "dismissDone")
    }

    /// 入场起点横移：从锚点相对窗口中心的水平距离反向补偿（视觉上从部件图标处展开）
    private func anchorDx(anchor: NSRect?) -> CGFloat {        guard let w = window, let anchor, anchor.width > 0, w.frame.width > 0 else { return 0 }
        let anchorCenterX = anchor.midX - w.frame.minX
        let ratio = max(0, min(1, anchorCenterX / w.frame.width))
        return (0.5 - ratio) * w.frame.width
    }

    // MARK: 定位

    /// 定位：锚点下方（顶边贴菜单栏 -2pt、x 对齐锚点中心、钳制可见区）或右上贴边
    private func origin(for size: NSSize, anchor: NSRect?) -> NSPoint {
        let screen = Self.screen(for: anchor)
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

    /// 屏幕选择（v71 实障修复）：NSScreen.main 在 LSUIElement 无 key window 时常为 nil，
    /// 旧代码落到 1440×900 虚拟屏 fallback 钳制——真实屏 1280 宽时 x=1046 不被钳制，
    /// 窗口超出右缘 145pt（用户实障：chips 第二行/网络等被裁）。
    /// 现按锚点坐标命中屏优先，退回 NSScreen.main → 主屏链。
    private static func screen(for anchor: NSRect?) -> NSScreen? {
        if let anchor, anchor.width > 0 {
            let pt = NSPoint(x: anchor.midX, y: anchor.midY)
            if let hit = NSScreen.screens.first(where: {
                NSMouseInRect(pt, $0.frame, false)
            }) { return hit }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

// MARK: - NSWindowDelegate（点外即消）

extension MonitorPopoutWindowController {
    public func windowDidResignKey(_ notification: Notification) {
        // 排障/截图专用：FRSET_PANEL_PIN=1 时不因失焦自动收起（与主面板同探针）
        if ProcessInfo.processInfo.environment["FRSET_PANEL_PIN"] == "1" { return }
        // 本 app 仍在前台 = 换 key 的是自家窗口（状态栏图标点击 / 预览窗等）。
        // 这条路径不能直接收起：状态项 action 是 mouseUp 才触发，先收起会被
        // openMonitor/showModule 重新拉起来，表现为「点了图标不关」。
        // 真正的「点外」会触发 didResignActive（切到别的 app）或点击监视器。
        if NSApp.isActive {
            Log.info("Monitor", "resignKey：app 仍活跃（本 app 内部换 key），交由点击目标处理")
            return
        }
        Log.info("Monitor", "点外：windowDidResignKey（app 已失活）→ 收起")
        // 统一入口（Core/TransientWindows）：置顶/可见性由中心判定
        if let w = window {
            TransientWindowCenter.shared.requestDismiss(window: w)
        } else {
            dismissPopout()
        }
    }

}

