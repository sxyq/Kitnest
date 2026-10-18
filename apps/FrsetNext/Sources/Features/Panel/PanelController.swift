import AppKit
import SwiftUI

/// 面板可见性状态（供 SwiftUI 根视图做缩放淡入动画）
public final class PanelPresentationState: ObservableObject {
    @Published public var visible = false
    public init() {}
}

/// 主面板控制器（原作由 StatusBarController 协作开合面板，此处统一收敛为单例）。
/// 实现 Core/Registry.swift 的 PanelControlling 协议，经 ServiceLocator.panel 供状态栏/热键模块调用。
public class PanelController: NSObject, PanelControlling, NSWindowDelegate {
    public static let shared = PanelController()

    private var panel: FloatingPanel?
    private let presentation = PanelPresentationState()
    /// 启动空闲预热是否已排期（避免重复）
    private var warmupScheduled = false

    private override init() {
        super.init()
    }

    // MARK: - 生命周期

    /// 创建面板与内容（幂等）。由 PanelModule.start() 调用，并注入 ServiceLocator.panel。
    public func prepare() {
        guard panel == nil else { return }
        // 原版主面板是固定 400×700（v60：性能页已删，高度恒定不再缩放）。
        // 宽度仍允许用户拖拽后持久化；高度不读持久化值——避免历史矮高度残留。
        // v66：视觉宽 = 持久基准宽 × 字号缩放（个性化联动）
        let baseWidth = CGFloat(Preferences.shared.value(Preferences.Keys.panelWidth,
                                                         default: 400))
        let width = baseWidth * Personalization.shared.fontScale
        let height = Theme.panelMaxHeight

        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              rootView: PanelRootView(
                                presentation: presentation,
                                onDismiss: { [weak self] in self?.hide() },
                                onOpenSettings: { [weak self] in
                                    // 设置窗口由 07 号模块经 ServiceLocator 注入，此处不引用其具体类型
                                    ServiceLocator.settings?.open(pane: nil)
                                    self?.hide()
                                }))
        p.delegate = self
        panel = p
        ServiceLocator.panel = self
        // Toast 定位（原作 0x1002bf3d0）：面板所在屏优先——面板可见时通知卡落在面板屏中线
        ToastAnchor.windowProvider = { [weak self] in self?.panel }
        // v66 个性化：字号缩放变更 → 窗口宽高联动（重设为动态默认尺寸，保持顶边）
        NotificationCenter.default.addObserver(forName: Personalization.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, let p = self.panel, p.isVisible else { return }
            let f = p.frame
            var target = f
            let baseWidth = CGFloat(Preferences.shared.value(Preferences.Keys.panelWidth,
                                                             default: 400))
            target.size.width = baseWidth * Personalization.shared.fontScale
            target.size.height = Theme.panelMaxHeight
            target.origin.y = f.maxY - target.height
            p.setFrame(target, display: true)
            p.applyPersonalizedMaterial()
        }
        scheduleWarmup()
        Log.info("Panel", "prepared \(Int(width))x\(Int(height))")
    }

    // MARK: - 首次显示预热

    /// 启动 2s 后在空闲时离屏布局一次整棵面板视图树。
    ///
    /// 背景（2026-10-19 实测）：面板三页（主页/性能/中转）常驻，第一次
    /// `makeKeyAndOrderFront` 会在同一个调用里做完整 SwiftUI 布局 —— sample 显示
    /// 400ms 左右全部耗在 `updateConstraintsIfNeeded → NSHostingView.minSize → ViewGraph`，
    /// 表现就是「点部件后要等一下才弹出来」。把这次布局提前到启动空闲期、以 alpha=0
    /// 离屏完成，点击路径上的首次显示就只剩窗口上屏 + 0.18s 淡入。
    private func scheduleWarmup() {
        guard !warmupScheduled else { return }
        warmupScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.warmupPanel()
        }
    }

    private func warmupPanel() {
        guard let p = panel, !p.isVisible, p.alphaValue == 1 else { return }
        let t0 = ProcessInfo.processInfo.systemUptime
        let oldAlpha = p.alphaValue
        p.alphaValue = 0                 // 离屏不可见：不留白闪
        p.orderFrontRegardless()         // 只上屏、不激活 app、不抢 key

        // 关键：presentation.visible=false 时根视图是 opacity 0 / scale 0.93，
        // SwiftUI 会跳过不可见子树的布局（实测预热只花 45ms，等于没热）。
        // 预热期间先置 true，让内容真正布局一次；结束后再复位。
        presentation.visible = true
        p.contentView?.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        // 给 SwiftUI 一个显示周期，把 AttributeGraph 真正跑完
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))

        presentation.visible = false
        p.contentView?.layoutSubtreeIfNeeded()
        p.orderOut(nil)
        p.alphaValue = oldAlpha
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        Log.info("Panel", String(format: "预热完成 %.0fms", ms))
    }

    // MARK: - PanelControlling

    public func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    public func show() {
        prepare()
        guard let p = panel else { return }
        p.level = isPinned ? .statusBar : .floating   // 置顶状态应用到新建/复用窗口
        MainPanelPreviewPopoverCoordinator.shared.prepareForPanelAppear()
        p.setFrameOrigin(rightEdgeOrigin(for: p.frame.size))
        presentation.visible = true                // 触发 SwiftUI 缩放淡入
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)    // v30：LSUIElement 需显式激活，否则被前端 app 抢焦点后立刻收起
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Personalization.shared.openAnimation.fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    /// v30：按锚点打开主面板（STATS 部件点击 → 打开主面板直达监测页，
    /// 注入版 FSSettlePanel(alignX: YES) 同款定位）：
    ///   · 顶边 = 屏幕可见区顶 - 2pt（菜单栏下缘，任何路径都校）
    ///   · x    = 锚点中心 - 面板宽/2，钳制在可见区内（仅"打开时"校）
    public func show(atAnchor anchorRect: NSRect) {
        let t0 = ProcessInfo.processInfo.systemUptime
        prepare()
        guard let p = panel else { return }
        MainPanelPreviewPopoverCoordinator.shared.prepareForPanelAppear()
        p.setFrameOrigin(anchorOrigin(anchorRect, for: p.frame.size))
        presentation.visible = true
        p.alphaValue = 0
        let tAct = ProcessInfo.processInfo.systemUptime
        NSApp.activate(ignoringOtherApps: true)
        let tKey = ProcessInfo.processInfo.systemUptime
        p.makeKeyAndOrderFront(nil)
        let t1 = ProcessInfo.processInfo.systemUptime
        Log.info("Panel", String(format: "show(anchor): 激活 %.0fms + 上屏 %.0fms（总 %.0fms）",
                                 (tKey - tAct) * 1000, (t1 - tKey) * 1000, (t1 - t0) * 1000))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }, completionHandler: {
            let t2 = ProcessInfo.processInfo.systemUptime
            Log.info("Panel", String(format: "show(anchor): 淡入完成 +%.0fms", (t2 - t1) * 1000))
        })
    }

    /// 面板是否可见（外部导航判定：注入版"面板已开则只切模块、不重开"）
    public var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// 监测独立窗口定位用：主面板当前 frame（不可见时 nil）
    public var panelFrameForPopout: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// v30：位置收敛——仅顶边（注入版 FSSettlePanel(alignX: NO)：切模块/改高度时
    /// 不动 x，避免横向跳动）
    public func settleTopEdge() {
        guard let p = panel, p.isVisible else { return }
        guard let screen = p.screen ?? NSScreen.main else { return }
        let targetTop = screen.visibleFrame.maxY - 2
        let f = p.frame
        if abs(f.maxY - targetTop) > 0.5 {
            p.setFrameOrigin(NSPoint(x: f.origin.x, y: targetTop - f.size.height))
        }
    }

    public func hide() {
        guard let p = panel, p.isVisible else { return }
        persistSize(p)
        presentation.visible = false
        // 原作行为（12 号 P8 waitsForPreviewClose）：面板收起前先等预览 popover 关闭
        MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .panelCollapse) { [weak self] in
            self?.performHide(p)
        }
    }

    /// hide() 第二段：预览已关闭，执行面板淡出
    private func performHide(_ p: NSWindow) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in
            p?.orderOut(nil)
            p?.alphaValue = 1
        })
    }

    /// 全局唤起预留接口：具体热键注册由 ShortcutManager/状态栏模块接线，
    /// 热键触发后调用 ServiceLocator.panel?.toggle() 或本方法即可。
    open func handleGlobalShortcut() {
        toggle()
    }

    // MARK: - 私有

    /// 屏幕右上角、菜单栏图标下方（与实机截图一致：面板停靠屏幕右侧）
    private func rightEdgeOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 80, y: 80) }
        let vf = screen.visibleFrame
        return NSPoint(x: vf.maxX - size.width - 10,
                       y: vf.maxY - size.height - 2)
    }

    /// v30：锚点定位（注入版 FSSettlePanel 同规则）：x = 锚点中心 - 宽/2，
    /// 钳制在屏幕可见区内（±6pt 边距）；顶边 = 菜单栏下缘 - 2pt
    private func anchorOrigin(_ anchor: NSRect, for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return rightEdgeOrigin(for: size) }
        let vf = screen.visibleFrame
        var x = NSMidX(anchor) - size.width * 0.5
        let minX = vf.origin.x + 6
        let maxX = vf.maxX - size.width - 6
        if maxX >= minX { x = max(minX, min(x, maxX)) } else { x = minX }
        return NSPoint(x: x, y: vf.maxY - size.height - 2)
    }

    // MARK: - 尺寸持久化（v60：性能页高度自适应已随该页删除）

    private func persistSize(_ p: NSWindow) {
        Preferences.shared.set(Preferences.Keys.panelWidth, Double(p.frame.width))
        Preferences.shared.set(Preferences.Keys.panelHeight, Double(p.frame.height))
    }

    // MARK: - NSWindowDelegate（点外/失焦自动关闭 + 尺寸持久化）

    /// 置顶窗口（官方齿轮菜单「置顶窗口 ⌘P」）：
    /// 开启后面板不因失焦自动收起，并抬升到 .statusBar 层级保持在最前。
    /// 持久化到偏好（重启后保持勾选态）。
    public var isPinned: Bool {
        get { Preferences.shared.value(Preferences.Keys.panelPinned, default: false) }
        set {
            Preferences.shared.set(Preferences.Keys.panelPinned, newValue)
            panel?.level = newValue ? .statusBar : .floating
            Log.info("Panel", newValue ? "置顶窗口：开" : "置顶窗口：关")
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        // 排障/截图专用：FRSET_PANEL_PIN=1 时面板不因失焦自动收起
        // （终端脚本没有辅助功能权限，无法把焦点交回本 app，不加这个开关就截不到面板）
        if ProcessInfo.processInfo.environment["FRSET_PANEL_PIN"] == "1" { return }
        // 置顶窗口：不自动收起（官方菜单勾选态）
        if isPinned { return }
        guard let p = panel, (notification.object as? NSWindow) === p else { return }
        // 本 app 自己的 sheet 取得 key 时不关闭面板：SwiftUI 的 sheet 是独立窗口，
        // 呈现瞬间父面板会 resignKey——照旧 hide() 的话面板被藏、sheet 变成无父浮窗
        // 飘到屏幕左下（2026-10-17 实测复现）。原 .transient 语义只针对
        // "点到面板外/切到别的 app"，此处按 app 是否仍在前台 + key 是否为 sheet 收窄。
        if NSApp.isActive, let key = NSApp.keyWindow, key !== p, key.isVisible,
           key.isSheet || key.sheetParent != nil {
            return
        }
        // 原作 .transient 行为：点击面板外任意处即关闭。
        // v53 例外：本 app 的常驻预览窗（单击条目打开）取得 key 时保持面板——
        // 用户是"边看列表边看预览"，面板收起会打断浏览。
        if NSApp.isActive, let key = NSApp.keyWindow, key !== p, key.isVisible,
           key.identifier?.rawValue == "frset.clipboardPreview" {
            return
        }
        // v65 例外：主面板预览 popover（applicationDefined，成为 key window）——
        // 预览的关闭由协调器统一仲裁（点外/Esc/hoverOut/滚动出视口），面板保持。
        if NSApp.isActive, let key = NSApp.keyWindow, key !== p, key.isVisible,
           key.identifier?.rawValue == "frset.panelPreviewPopover" {
            return
        }
        hide()
    }

    public func windowDidResize(_ notification: Notification) {
        guard let p = panel, (notification.object as? NSWindow) === p, p.isVisible else { return }
        persistSize(p)
    }

    public func windowWillClose(_ notification: Notification) {
        presentation.visible = false
    }
}
