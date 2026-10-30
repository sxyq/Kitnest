import AppKit
import SwiftUI

/// 面板可见性状态（供 SwiftUI 根视图做缩放淡入动画）
public final class PanelPresentationState: ObservableObject {
    @Published public var visible = false
    /// 本次是否锚点（菜单栏图标）展开——根视图据此显示顶部三角指示器
    @Published public var anchored = false
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
        // v73：**不再乘 fontScale**。「设置 → 个性化 → 面板宽度」的选项
        // （360/400/440）即最终视觉宽度；此前「宽度 × 字号缩放」与内容
        // scaleEffect 三重叠加，360×0.9=324 是用户所见「比例怪/按钮挤一堆」
        // 的直接来源。字号缩放档位只影响字号（待接入全局字体缩放），不参与窗口宽。
        let baseWidth = max(CGFloat(Preferences.shared.value(Preferences.Keys.panelWidth,
                                                         default: 400)), 320)
        let width = baseWidth
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
        // v71 修正：去掉 isVisible guard。用户典型流：面板 → 设置（面板被 hide）→
        // 改字号 → 重开面板；隐藏时 return 会导致尺寸永不更新，重开还是旧尺寸
        // =「个性化完全无效」的实障根因（运行中点击无效，冷启动才生效）。
        NotificationCenter.default.addObserver(forName: Personalization.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.syncPanelFrameToPersonalization()
        }
        scheduleWarmup()
        Log.info("Panel", "prepared \(Int(width))x\(Int(height))")
    }

    /// 按当前个性化（字号缩放 + 面板宽度键）校准面板尺寸（顶边不动）。
    /// 通知链路与 show() 双入口调用；面板隐藏时同步无害（下次打开即新尺寸）。
    private func syncPanelFrameToPersonalization() {
        guard let p = panel else { return }
        let f = p.frame
        var target = f
        let baseWidth = max(CGFloat(Preferences.shared.value(Preferences.Keys.panelWidth,
                                                         default: 400)), 320)
        target.size.width = baseWidth     // v73：宽度即选值，不乘 fontScale（见 prepare 注释）
        target.size.height = Theme.panelMaxHeight
        target.origin.y = f.maxY - target.height
        p.setFrame(target, display: true)
        p.applyPersonalizedMaterial()
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

    /// 锚点开合（状态栏主图标点击）：展开时停到图标正下方并显示三角指示器
    public func toggle(atAnchor anchorRect: NSRect?) {
        if panel?.isVisible == true { hide() } else { show(atAnchor: anchorRect) }
    }

    public func show() {
        show(atAnchor: nil)
    }

    /// v73（2026-10-19 用户反馈）：主面板三处回归修复——
    /// ① 宽度污染：persistSize 曾把 SwiftUI 压窄的形态（167pt）写进 panel.width，
    ///    此后每次启动都读窄值，按钮全挤一起。prepare/sync 增加下限钳制（<320 丢弃旧值）；
    /// ② 位置：无 anchor 时仍走右缘（快捷键等路径），有 anchor 时停到图标正下方；
    /// ③ 动画：presentation.anchored 驱动根视图顶部三角 + scaleEffect(anchor:.top)
    ///    「从图标长出来」，与监测独立窗（e466a3c）同款弹簧。
    public func show(atAnchor anchorRect: NSRect?) {
        prepare()
        guard let p = panel else { return }
        // v84（2026-10-20）：面板打开埋点（主图标 / 快捷键 / 深链统一收口）
        StatisticsManager.shared.record(.panelOpen)
        Log.breadcrumb("Panel", "打开面板")
        // 主面板与「性能监测独立窗」互斥：两个都开时不仅叠窗，还会出现
        // 「同一时刻两套数据/两套刷新节奏」的观感（用户多次反馈）。
        MonitorPopoutWindowController.shared.dismissPopout()
        // v71：打开时按当前个性化校准尺寸（防通知漏收/隐藏期间变更）
        syncPanelFrameToPersonalization()
        p.level = isPinned ? .statusBar : .floating   // 置顶状态应用到新建/复用窗口
        MainPanelPreviewPopoverCoordinator.shared.prepareForPanelAppear()
        let origin: NSPoint
        if let anchorRect {
            origin = anchorOrigin(anchorRect, for: p.frame.size)
            presentation.anchored = true
        } else {
            origin = rightEdgeOrigin(for: p.frame.size)
            presentation.anchored = false
        }
        p.setFrameOrigin(origin)
        presentation.visible = true                // 触发 SwiftUI 缩放淡入
        p.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)    // v30：LSUIElement 需显式激活，否则被前端 app 抢焦点后立刻收起
        p.makeKeyAndOrderFront(nil)
        // 统一「点外/失焦收起」：全工程唯一实现（Core/TransientWindows）
        TransientWindowCenter.shared.register(
            window: p,
            isPinned: { [weak self] in
                // v166.5：排障 pin 必须在这里也生效。面板的收起由本中心三路仲裁
                // （失活通知 / 本地点外 / resignKey），只挡 resignKey 挡不住
                // didResignActive 那条路——自动化截图时面板照样 0.9s 就没。
                if PanelController.debugPinned { return true }
                return self?.isPinned ?? false
            },
            allowsClickIn: { win in
                // 自家 sheet / 预览窗取得 key 时保持面板（原先散落在 resignKey 里的三条例外）
                if win.isSheet || win.sheetParent != nil { return true }
                let id = win.identifier?.rawValue
                return id == "frset.clipboardPreview" || id == "frset.panelPreviewPopover"
            },
            onDismiss: { [weak self] in self?.hide() })
        // 主面板可见期间按用户间隔采样（与独立窗同一节奏；不含此项时主面板
        // 性能页处于「隐藏态 5s」降频，而独立窗是 1.5s——用户说的两套时间）
        MonitorSampler.shared.setHomePanelActive(true)
        Log.info("Panel", "show: frame=\(Int(p.frame.width))x\(Int(p.frame.height)) anchored=\(presentation.anchored) origin=\(Int(origin.x)),\(Int(origin.y))")
        RenderProbe.snapshot(p, name: "panel", reason: "show")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Personalization.shared.openAnimation.fadeDuration
            ctx.timingFunction = Theme.Motion.caEaseOut
            p.animator().alphaValue = 1
        }
    }

    /// v30：按锚点打开主面板（STATS 部件点击 → 打开主面板直达监测页，
    /// 注入版 FSSettlePanel(alignX: YES) 同款定位）：
    ///   · 顶边 = 屏幕可见区顶 - 2pt（菜单栏下缘，任何路径都校）
    ///   · x    = 锚点中心 - 面板宽/2，钳制在可见区内（仅"打开时"校）
    /// v73：本方法已由上方 show(atAnchor:) 统一实现（含 anchored 三角态），此处删除旧副本。

    /// 面板是否可见（外部导航判定：注入版"面板已开则只切模块、不重开"）
    public var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// 监测独立窗口定位用：主面板当前 frame（不可见时 nil）
    public var panelFrameForPopout: NSRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// RenderProbe 渲染健康探针用（只读窗口引用，v71 白屏排查）
    public var panelWindowForProbe: NSWindow? { panel }


    public func hide() {
        guard let p = panel, p.isVisible else { return }
        TransientWindowCenter.shared.unregister(window: p)
        Log.info("Panel", "hide: 开始收起")
        RenderProbe.snapshot(p, name: "panel", reason: "hideStart")
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
            MonitorSampler.shared.setHomePanelActive(false)
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
        // v73：下限保护——只持久化用户主动拖拽后的合理尺寸。
        // SwiftUI 内容 fitting 曾把窗口压到 167pt，windowDidResize 照单全写，
        // 污染 panel.width 导致此后每次启动都窄（按钮挤压回归）。
        guard p.frame.width >= 320, p.frame.height >= 400 else {
            Log.info("Panel", "persistSize: 忽略异常尺寸 \(Int(p.frame.width))x\(Int(p.frame.height))（低于下限）")
            return
        }
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
            // v84：置顶开启埋点（只在开启时记一次，关闭不记）
            if newValue { StatisticsManager.shared.record(.alwaysOnTopEnable) }
            Log.info("Panel", newValue ? "置顶窗口：开" : "置顶窗口：关")
        }
    }

    /// 排障/截图专用：面板不因失焦自动收起。
    /// 两种开启方式：环境变量 `FRSET_PANEL_PIN=1`，或启动参数 `--args --panel-pin`
    /// （后者不需要 `launchctl setenv` 权限，`open -a … --args` 即可）。
    static var debugPinned: Bool {
        if ProcessInfo.processInfo.environment["FRSET_PANEL_PIN"] == "1" { return true }
        return ProcessInfo.processInfo.arguments.contains("--panel-pin")
    }

    public func windowDidResignKey(_ notification: Notification) {
        if PanelController.debugPinned { return }
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
        // v166.5 例外：面板内 SwiftUI `.popover` 弹出的子窗。
        // 这类窗口由系统创建、我们拿不到实例，只能靠内容宿主打 identifier
        // （PanelChildWindow.swift）。没有这条时，「连接手机」弹层的表现是
        // 出现一瞬就被当成「点了外面」连面板一起收起 —— 用户报的「闪一下就没了」。
        if NSApp.isActive, let key = NSApp.keyWindow, key !== p, key.isVisible,
           PanelChildWindow.isPanelChild(key) {
            return
        }
        TransientWindowCenter.shared.requestDismiss(window: p)
    }

    public func windowDidResize(_ notification: Notification) {
        guard let p = panel, (notification.object as? NSWindow) === p, p.isVisible else { return }
        persistSize(p)
    }

    public func windowWillClose(_ notification: Notification) {
        presentation.visible = false
    }
}
