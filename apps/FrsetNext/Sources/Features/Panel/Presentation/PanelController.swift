import AppKit
import QuartzCore
import SwiftUI

/// 面板可见性状态（供根视图做缩放淡入动画）
public final class PanelPresentationState: ObservableObject {
    @Published public var visible = false
    /// 本次是否锚点（菜单栏图标）展开——根视图据此显示顶部三角指示器
    @Published public var anchored = false
    /// v197：展开 / 收回的锚点（面板内归一化坐标，0,0 = 左上）。
    /// 由 PanelController 按菜单栏图标的横坐标算出，窗口层动画据此「从图标长出来 / 收回图标」。
    @Published public var originUnit: CGPoint = CGPoint(x: 0.5, y: 0)
    /// v237：本次展开用的图标屏幕矩形（神灯漏斗的插槽）。收起时复用它，
    /// 保证「从哪来、回哪去」用的是同一个格子；无锚点路径（快捷键）由控制器兜一个。
    public var anchorRect: NSRect? = nil
    public init() {}
}

/// 主面板控制器（原作由 StatusBarController 协作开合面板，此处统一收敛为单例）。
/// 实现 Core/Runtime/Registry.swift 的 PanelControlling 协议，经 ServiceLocator.panel 供状态栏/热键模块调用。
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
        // v260（面板宽度设置无效的根因）：这里原来写 `default: 400`（Int 字面量），
        // 而 Preferences.value 是 `defaults.object(forKey:) as? T` —— 存进去的是
        // **Double**（applyPanelWidth 写的是 Double(width)），as? Int 必然失败，
        // 于是每次都读回默认值 400，用户在设置里选 360/440 完全不起作用。
        // 改成 Double 字面量，as? Double 才命中。
        let baseWidth = max(CGFloat(Preferences.shared.value(Preferences.Keys.panelWidth,
                                                         default: 400.0)), 320)
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
                                                         default: 400.0)), 320)
        target.size.width = baseWidth     // v73：宽度即选值，不乘 fontScale（见 prepare 注释）
        target.size.height = Theme.panelMaxHeight
        target.origin.y = f.maxY - target.height
        // v203（用户：「背景材质两个选项改了无效」）：材质重套必须在尺寸 guard 之前。
        // 旧顺序 guard 在前——尺寸没变（绝大多数时候）直接 return，
        // 「纯色卡片 / 毛玻璃」切换永远到不了 reapplyStyle。
        p.applyPersonalizedMaterial()
        // v194（用户「打开和收起的动画十分卡顿」）：尺寸没变就不 setFrame。
        // 旧实现每次 show 都 setFrame(display: true)，即使宽高完全一致也会触发
        // 一次整窗重绘 + 重排——恰好压在开合动画的第一帧上。
        guard target != f else { return }
        p.setFrame(target, display: true)
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
        // v173（2026-11-01 崩溃复盘）：**默认不预热**。
        //
        // 预热是在一个 `alphaValue = 0` 的离屏窗口上强行 `layoutSubtreeIfNeeded`
        // + `displayIfNeeded`，把 SwiftUI 的 AttributeGraph 先跑一遍。问题是这时候
        // 窗口本来不该参与显示周期，AppKit 会在 `_postWindowNeedsUpdateConstraints`
        // 里抛 NSInternalInconsistencyException → abort（SIGABRT）。
        //
        // 实测对照（同一台机器、同一份构建，冷启动各 8 次）：
        //   预热开 → 存活 6 / 崩 2
        //   预热关 → 存活 8 / 崩 0
        // 代价只是首次打开面板慢约 180ms，换掉 25% 的启动崩溃，值得。
        //
        // 需要复测预热时可以 `defaults write com.sxyq.frsetnext probe.warmup -bool YES`。
        if !UserDefaults.standard.bool(forKey: "probe.warmup") {
            Log.info("Panel", "跳过预热（v173：预热会触发启动崩溃，默认关闭）")
            return
        }
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

        // 关键（2026-11-01 崩溃复盘）：这里**不能**再 `RunLoop.current.run(until:)`。
        // 嵌套跑主 runloop 会把 display cycle 的更新重入进来，AppKit 在
        // `_postWindowNeedsUpdateConstraints / _postWindowNeedsLayout` 里抛
        // NSInternalInconsistencyException → abort（SIGABRT）。
        // 冷启动偶发「自己退出」就是这么来的（本机 11-01 崩了 4 次，栈都是这个）。
        //
        // 改成两段式：先让内容真布局一次，0.12s 后（下一轮 runloop）再收尾。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let p = self.panel else { return }
            self.presentation.visible = false
            p.contentView?.layoutSubtreeIfNeeded()
            p.orderOut(nil)
            p.alphaValue = oldAlpha
            let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            Log.info("Panel", String(format: "预热完成 %.0fms", ms))
        }
    }

    // MARK: - PanelControlling

    public func toggle() {
        toggle(atAnchor: nil)
    }

    /// 锚点开合（状态栏主图标点击）：展开时停到图标正下方并显示三角指示器
    public func toggle(atAnchor anchorRect: NSRect?) {
        // v247：收起动画进行中再点 → 直接掉头重开。
        // 原来这里会走 hide()，而 hide() 被 isHiding 挡住直接 return，
        // 用户连点时第二下、第三下全被吞掉——这就是「连续点击鬼畜」的来源。
        if isHiding, GenieWarp.isRunning, !GenieWarp.isOpening {
            show(atAnchor: anchorRect)
            return
        }
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
        let t0 = ProcessInfo.processInfo.systemUptime
        let wasVisible = p.isVisible
        hideGeneration += 1                 // 重开使旧预览完成回调与收尾失效。
        isHiding = false
        // v244：不再在开面板前 cancel 在途动画——那会把真窗 alpha 拉回 1，
        // 面板整块亮出来再重播一遍漏斗。掉头交给 GenieWarp 自己处理。
        // v244：神灯展开时先把窗口**停在屏幕外**再上屏做首次布局。
        // 抓快照必须让窗口「已渲染且不透明」，可窗口停在屏内就会先闪一整块面板，
        // 用户看到的就是「先展开一次、再重放一遍漏斗」。实测窗口可以停在屏外
        // 不被 AppKit 拉回，抓图仍然有效，抓完再「先透明、后移回原位」。
        let parked = GenieWarp.isEnabled && !wasVisible
        p.setFrameOrigin(parked ? parkOrigin(for: p, origin: origin) : origin)
        // v194/v197：入场动画等布局跑完再起，并且挪到**窗口内容层**（整块面板，
        // 含玻璃底）。旧实现只对 SwiftUI 内容做 scaleEffect，玻璃窗口始终原尺寸铺在
        // 屏上，看上去只是「内容缩放」，不是用户要的「从一个点扩散成一个面」。
        //
        // 顺序：① 先把内容层缩到菜单栏图标处并透明 → ② makeKey 在不可见状态完成首次
        // 布局（v173 关闭预热后首开仍要 ~100ms）→ ③ 布局结束后从锚点展开。
        let anchorUnit = revealUnit(anchor: anchorRect, windowOrigin: origin, size: p.frame.size)
        presentation.originUnit = anchorUnit
        presentation.anchorRect = anchorRect
        if !wasVisible {
            presentation.visible = true            // 内容态（动画由窗口层负责）
            p.contentView?.layer?.removeAllAnimations()
            p.contentView?.layer?.transform = WindowReveal.transform(
                scale: 0.90, around: anchorUnit, in: p.frame.size)
            p.contentView?.layer?.opacity = 0
            p.alphaValue = 1                       // 整窗 alpha 动画会逐帧重采样玻璃，弃用
        }
        NSApp.activate(ignoringOtherApps: true)    // v30：LSUIElement 需显式激活，否则被前端 app 抢焦点后立刻收起
        p.makeKeyAndOrderFront(nil)
        // makeKey 有可能把「key 窗口」约束回屏幕内，抓图前再钉一次停靠位
        if parked { p.setFrameOrigin(parkOrigin(for: p, origin: origin)) }
        p.contentView?.layoutSubtreeIfNeeded()     // 首帧布局在窗口透明时完成
        p.displayIfNeeded()
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
        // v195（GSAP 口径「减少同时进行的工作」）：采样器不要在过渡期间启动。
        // 采样回调会把 @Published 数据推进 SwiftUI，恰好与开合的第一批帧重叠——
        // 动画只该做合成，不该夹带整页重排。改为动画结束后再起（延迟 = 过渡时长）。
        let layoutMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        Log.info("Panel", "show: frame=\(Int(p.frame.width))x\(Int(p.frame.height)) anchored=\(presentation.anchored) origin=\(Int(origin.x)),\(Int(origin.y)) 布局=\(Int(layoutMs))ms")
        RenderProbe.snapshot(p, name: "panel", reason: "show")
        guard !wasVisible else {
            // 面板已在屏上（含「收起动画没跑完又被重新打开」）：取消在途的收回动画，
            // 把内容层拉回可见态，别让上一轮淡出继续把它藏掉。
            p.contentView?.layer?.removeAllAnimations()
            p.contentView?.layer?.transform = CATransform3DIdentity
            p.contentView?.layer?.opacity = 1
            MonitorSampler.shared.setHomePanelActive(true)
            presentation.visible = true
            // v244：漏斗正往回抽（或刚抽到一半）时又被打开 → 直接掉头，
            // 复用已有帧序列反向播，不重抓快照、不重渲染。
            if GenieWarp.isRunning {
                let d = Personalization.shared.openAnimation.duration
                _ = GenieWarp.shared.playIn(window: p,
                                            slot: anchorRect ?? defaultSlot(for: p),
                                            duration: d)
            }
            return
        }
        // 布局已完成：从菜单栏图标位置展开整块面板
        //
        // v237（用户：「展开和收起都需要同样的」）：改用 Dock 的「神灯」网格——
        // 整窗按网格从图标那 22pt 的方格里「倒」出来，两侧先弯成漏斗、再落位。
        // 抓不到窗口快照时（无录屏权限等）退回原有的缩放动画，功能不受影响。
        // v240：上一轮神灯收尾是「直接 orderOut、alpha 保持 0」（为了不闪回），
        // 这里必须先还原，否则面板会以全透明状态出现。
        p.alphaValue = 1
        let duration = Personalization.shared.openAnimation.duration
        let slot = anchorRect ?? defaultSlot(for: p)
        p.contentView?.layer?.removeAllAnimations()
        p.contentView?.layer?.transform = CATransform3DIdentity
        p.contentView?.layer?.opacity = 1      // 快照要抓完整不透明的面板
        let usedGenie = GenieWarp.shared.playIn(window: p, slot: slot, duration: duration,
                                                destination: origin)
        if !usedGenie {
            // 没走成神灯：先把窗口从屏外挪回原位再显示，否则会看不见面板
            if p.frame.origin != origin { p.setFrameOrigin(origin) }
            if PanelMotion.fallbackAnimationDisabled {
                // v243：调神灯手感期不叠第二套缩放动画，直接落位（alpha 上面已还原）
                p.alphaValue = 1
            } else {
                WindowReveal.playIn(on: p, from: anchorUnit, scale: 0.90, duration: duration)
            }
        }
        // 采样放到过渡结束之后：动画期间只做合成，不夹带 SwiftUI 重排
        DispatchQueue.main.asyncAfter(deadline: .now() + GenieWarp.duration(for: duration) + 0.02) { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            MonitorSampler.shared.setHomePanelActive(true)
        }
    }

    /// 入场/退场锚点：菜单栏图标在面板内的归一化位置。
    /// x 由图标中心决定（面板横向钳制到屏幕内后仍然对准图标）；y = 0 = 顶边。
    /// 无锚点路径（快捷键/深链）落在右上角，等价于「从状态栏右侧展开」。
    private func revealUnit(anchor: NSRect?, windowOrigin: NSPoint, size: NSSize) -> CGPoint {
        guard let anchor, anchor.width > 0, size.width > 0 else { return CGPoint(x: 1, y: 0) }
        let u = (anchor.midX - windowOrigin.x) / size.width
        return CGPoint(x: min(max(u, 0), 1), y: 0)
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


    /// v199：收起流程进行中（预览窗关闭回调丢失时靠超时兜底强制收，避免「点了别处面板不消失」）
    private var isHiding = false

    public func hide() {
        hide(completion: nil)
    }

    /// 截图等动作在本轮面板真实隐藏后执行；已经隐藏则立即执行。
    func hide(completion: (() -> Void)?) {
        guard let p = panel, p.isVisible else { completion?(); return }
        guard !isHiding else { return }
        isHiding = true
        hideGeneration += 1
        let gen = hideGeneration            // 本轮预览等待；进入动画后序号继续递增。
        TransientWindowCenter.shared.unregister(window: p)
        Log.info("Panel", "hide: 开始收起")
        RenderProbe.snapshot(p, name: "panel", reason: "hideStart")
        persistSize(p)
        presentation.visible = false
        // v247：正在展开就被要求收起 → 立刻掉头，不等预览关闭。
        // 原来这里要先等 dismiss 回调（最长 0.6s 兜底），展开动画照跑，
        // 用户看到的就是「点了没反应，然后突然抽走」。
        if GenieWarp.isOpening {
            performHide(p, completion: completion)
            return
        }
        // 原作行为（12 号 P8 waitsForPreviewClose）：面板收起前先等预览 popover 关闭
        MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .panelCollapse) { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            self.performHide(p, completion: completion)
        }
        // 兜底：预览窗收回动画被系统跳过 / 完成回调丢失时，0.6s 后强制进第二段
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak p] in
            guard let self, let p, p.isVisible, self.isHiding else { return }
            // v240（用户：「收纳动画重复播放，还有闪回」）：
            // 预览正常关闭时 performHide 早已开始，这个 0.6s 兜底若再调一次，
            // 会把收纳动画**重播一遍**；更糟的是第二次抓快照时窗口 alpha 已经是 0，
            // 抓到的是透明窗，播出来就是「动画中间整块消失一下」。
            guard self.hideGeneration == gen else { return }
            Log.warn("Panel", "收起超时（预览未关完），强制执行")
            self.performHide(p, completion: completion)
        }
    }

    /// hide() 第二段：预览已关闭，执行面板收回
    /// v197（用户「用面板收回这个点，从哪来回哪去」）：整块内容层（玻璃+内容）
    /// 缩回本次展开的锚点（菜单栏图标）并淡出，再 orderOut。
    /// 只动 transform/opacity，时长 = 内容过渡时长（与 WindowReveal 同一曲线系）。
    /// 完成回调 + 兜底计时器都走 `finish`，避免像监测窗历史 bug 那样
    /// 「CATransaction completion 不执行 → 窗口永远留在屏上」。
    private var hideGeneration = 0

    private func performHide(_ p: NSWindow, completion: (() -> Void)?) {
        // v244：展开的漏斗还没跑完就要收 → 不 cancel（cancel 会把 alpha 拉回 1，
        // 面板先整块闪一下再抽走）。改成让 playOut 自己掉头，画面停在当前帧继续收。
        hideGeneration += 1
        let token = hideGeneration
        let duration = Personalization.shared.openAnimation.duration
        let finish: () -> Void = { [weak self, weak p] in
            guard let self, let p, token == self.hideGeneration, self.isHiding else { return }
            p.contentView?.layer?.removeAllAnimations()
            p.contentView?.layer?.transform = CATransform3DIdentity
            p.contentView?.layer?.opacity = 1
            p.orderOut(nil)
            MonitorSampler.shared.setHomePanelActive(false)
            self.isHiding = false
            completion?()
        }
        // v237：收起也走神灯——面板吸回同一个图标格子。
        // 与展开共用 presentation.anchorRect，保证「从哪来、回哪去」是同一个点。
        let slot = presentation.anchorRect ?? defaultSlot(for: p)
        p.contentView?.layer?.removeAllAnimations()
        p.contentView?.layer?.transform = CATransform3DIdentity
        p.contentView?.layer?.opacity = 1
        let usedGenie = GenieWarp.shared.playOut(window: p, slot: slot,
                                                 duration: duration, completion: finish)
        if !usedGenie {
            if PanelMotion.fallbackAnimationDisabled {
                // v243：同上——神灯没跑起来就直收，别再播一遍缩放
                finish()
            } else {
                WindowReveal.playOut(on: p, to: presentation.originUnit, scale: 0.90,
                                     duration: duration, completion: finish)
            }
        }
        // 兜底：动画回调被系统跳过（窗口被遮挡/重复收起）时也一定收尾。
        // 神灯在跑时多等一会儿，别把覆盖窗上的动画提前掐断。
        DispatchQueue.main.asyncAfter(deadline: .now() + GenieWarp.duration(for: duration) + 0.35, execute: finish)
    }

    /// 神灯展开前的临时停靠位：屏幕上方之外（完全不可见，AppKit 不会拉回）。
    /// 只用于「抓快照」，抓完立刻透明并移回 origin。
    private func parkOrigin(for window: NSWindow, origin: NSPoint) -> NSPoint {
        let screen = window.screen ?? NSScreen.main
        let top = (screen?.frame.maxY ?? 0) + window.frame.height + 200
        return NSPoint(x: origin.x, y: top)
    }

    /// 无锚点路径（快捷键 / 深链打开）的兜底插槽：
    /// 面板上沿右侧的一个 22pt 方块，等价于「从状态栏那一带倒下来」。
    private func defaultSlot(for window: NSWindow) -> NSRect {
        let f = window.frame
        return NSRect(x: f.maxX - 46, y: f.maxY - 1, width: 22, height: 22)
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
