import AppKit
import QuartzCore

// MARK: - 窗口级「从哪来、回哪去」展开 / 收回（v197，v198 修动画不生效）
//
// 用户原话：「这种从这个点扩散出来到整个面板，然后用面板收回这个点……从一个点扩散到
// 一个面，类似于苹果手机上的那个桌面的图标点开的效果。剪贴板预览也一样，其他的所有
// 动画都需要遵从这种从哪来回哪去」。
//
// 为什么放在窗口层而不是 SwiftUI：
//   · 主面板/预览窗的「面」= 窗口底玻璃 + SwiftUI 内容。只对 SwiftUI 内容做
//     scaleEffect 时，玻璃窗口仍是原尺寸铺在屏幕上，看起来只是内容缩放，不是「面
//     从一个点长出来」；
//   · layer.transform + layer.opacity 只走 GPU 合成，不触发 SwiftUI/AppKit 布局，
//     与 GSAP「只动 transform/opacity」的口径一致（monitor 独立窗 v71 已验证）。
//
// v198（用户「我让你加动效，你他妈全给我删了，现在没一点动效」）：
//   NSView 宿主层的隐式动画默认被关闭——直接改 `layer.transform`（哪怕包在
//   CATransaction 里）会**瞬间跳变**，看上去就是没动画。这里全部改成显式
//   CABasicAnimation（add(_:forKey:)），模型值先设终态、动画从初态插值。
//
// 数学：窗口内容层的 transform 默认绕 anchorPoint（中心）缩放。要让窗口内归一化
// 锚点 (u, v)（u 左→右、v 上→下，同 SwiftUI UnitPoint）保持不动，等价于
// T(d) · S(s) · T(-d)，其中 d = ((u-0.5)·W, (0.5-v)·H)（layer 坐标 y 向上）。
// 这样不用改 anchorPoint/position（改它们会与 AppKit 的布局打架）。
enum WindowReveal {

    /// 每个窗口最近一次展开用的锚点（收回时「回哪去」不用每个控制器自己记）
    private static var lastAnchors: [ObjectIdentifier: CGPoint] = [:]

    /// 以内容层归一化锚点为中心、按 `scale` 缩放后的 transform。
    static func transform(scale: CGFloat, around unit: CGPoint, in size: CGSize) -> CATransform3D {
        let dx = (unit.x - 0.5) * size.width
        let dy = (0.5 - unit.y) * size.height
        let scaleMatrix = CATransform3DMakeScale(scale, scale, 1)
        let translateOut = CATransform3DMakeTranslation(dx, dy, 0)
        let translateBack = CATransform3DMakeTranslation(-dx, -dy, 0)
        return CATransform3DConcat(translateOut, CATransform3DConcat(scaleMatrix, translateBack))
    }

    /// 入场：内容层从 `scale` + 透明，展开到 1 + 不透明。
    /// - Parameter unit: 锚点（窗口内容坐标归一化，0,0 = 左上）
    static func playIn(on window: NSWindow,
                       from unit: CGPoint,
                       scale: CGFloat = 0.92,
                       duration: TimeInterval,
                       timing: CAMediaTimingFunction = Theme.Motion.caEaseOut,
                       completion: (() -> Void)? = nil) {
        guard let view = window.contentView, let layer = view.layer else {
            completion?()
            return
        }
        layer.removeAllAnimations()
        let start = transform(scale: scale, around: unit, in: view.bounds.size)
        lastAnchors[ObjectIdentifier(window)] = unit
        let once = Once()
        let fire: () -> Void = { once.run { completion?() } }
        CATransaction.begin()
        CATransaction.setCompletionBlock(fire)
        addAnimation(to: layer, keyPath: "transform", from: start,
                     to: CATransform3DIdentity, duration: duration, timing: timing)
        addAnimation(to: layer, keyPath: "opacity", from: 0, to: 1,
                     duration: duration, timing: timing)
        // 模型值 = 终态（动画结束后停在这里，不会闪回）
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
        if UserDefaults.standard.bool(forKey: "probe.reveal") {
            let p0 = layer.presentation()
            Log.info("Motion", "add 后 keys=\(layer.animationKeys() ?? []) p0.opacity=\(p0?.opacity ?? -1) p0.m11=\((p0?.transform.m11 ?? -1))")
        }
        // 兜底：窗口被遮挡/动画被系统跳过时 completion 不触发
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08, execute: fire)
        probePresentation(layer: layer, duration: duration, tag: "展开")
    }

    /// 退场：内容层缩回 `unit` 点并淡出；completion 在动画结束后调用。
    /// 模型值保持终态（缩小的透明态），由调用方在 orderOut/close 后复位，
    /// 避免「动画刚结束又闪回一帧原尺寸」。
    static func playOut(on window: NSWindow,
                        to unit: CGPoint,
                        scale: CGFloat = 0.92,
                        duration: TimeInterval,
                        timing: CAMediaTimingFunction = Theme.Motion.caEaseIn,
                        completion: @escaping () -> Void) {
        guard let view = window.contentView, let layer = view.layer else {
            completion()
            return
        }
        layer.removeAllAnimations()
        let end = transform(scale: scale, around: unit, in: view.bounds.size)
        let once = Once()
        let fire: () -> Void = { once.run { completion() } }
        CATransaction.begin()
        CATransaction.setCompletionBlock(fire)
        addAnimation(to: layer, keyPath: "transform", from: CATransform3DIdentity,
                     to: end, duration: duration, timing: timing)
        addAnimation(to: layer, keyPath: "opacity", from: 1, to: 0,
                     duration: duration, timing: timing)
        layer.transform = end
        layer.opacity = 0
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08, execute: fire)
        probePresentation(layer: layer, duration: duration, tag: "收回")
    }

    private static func addAnimation(to layer: CALayer, keyPath: String,
                                     from: Any, to: Any,
                                     duration: TimeInterval,
                                     timing: CAMediaTimingFunction) {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = timing
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false   // completion 时统一 removeAllAnimations
        layer.add(anim, forKey: "reveal.\(keyPath)")
    }

    /// 一次性执行器（CATransaction 回调 + 计时兜底只跑一次）
    private final class Once {
        private var fired = false
        func run(_ body: () -> Void) {
            guard !fired else { return }
            fired = true
            body()
        }
    }

    /// 排障探针（probe.reveal=YES）：动画中段读 presentation 层的实际值。
    /// 若显式动画真的在跑：opacity ≈ 0.5、transform.m11 < 1；
    /// 若被系统跳过：opacity=1 / m11=1 —— 用来验证「是不是真在动」。
    private static func probePresentation(layer: CALayer, duration: TimeInterval, tag: String) {
        guard UserDefaults.standard.bool(forKey: "probe.reveal") else { return }
        // 用后台队列采样：主线程在首开布局期间会堵 100ms+，主队列 asyncAfter 会被推迟到
        // 动画结束才执行，读到的是终态（这是之前误判「动画没跑」的直接原因）。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + duration * 0.4) { [weak layer] in
            let p = layer?.presentation()
            let m11 = p?.transform.m11 ?? -1
            Log.info("Motion", String(format: "reveal%@中段：opacity=%.2f scale=%.3f keys=%@", tag, p?.opacity ?? -1, m11, (layer?.animationKeys() ?? []).description))
        }
    }

    // MARK: - 通用入口（弹窗类窗口统一从这里「从鼠标点展开、收回鼠标点」）

    /// 当前鼠标位置在窗口内的归一化锚点（= 用户点开的那个按钮/菜单项的位置）。
    /// 鼠标不在窗口内时退回顶边中点（菜单类窗口的常规展开方向）。
    static func unitAtMouse(for window: NSWindow) -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let frame = window.frame
        guard frame.width > 1, frame.height > 1 else { return CGPoint(x: 0.5, y: 0) }
        let u = (mouse.x - frame.minX) / frame.width
        let v = 1 - (mouse.y - frame.minY) / frame.height
        guard (0...1).contains(u), (0...1).contains(v) else { return CGPoint(x: 0.5, y: 0) }
        return CGPoint(x: u, y: v)
    }

    /// 通用入场：窗口上屏后，从鼠标点（或上次锚点）展开成整块面。
    static func playInFromMouse(on window: NSWindow,
                                scale: CGFloat = 0.94,
                                duration: TimeInterval = Personalization.shared.openAnimation.duration,
                                completion: (() -> Void)? = nil) {
        playIn(on: window, from: unitAtMouse(for: window),
               scale: scale, duration: duration, completion: completion)
    }

    /// 通用退场：缩回最近一次展开的锚点；调用方在 completion 里 close/orderOut。
    static func playOutToLastAnchor(on window: NSWindow,
                                    scale: CGFloat = 0.94,
                                    duration: TimeInterval = Personalization.shared.openAnimation.duration,
                                    timing: CAMediaTimingFunction = Theme.Motion.caEaseIn,
                                    completion: @escaping () -> Void) {
        let unit = lastAnchors[ObjectIdentifier(window)] ?? CGPoint(x: 0.5, y: 0.5)
        playOut(on: window, to: unit, scale: scale, duration: duration,
                timing: timing, completion: completion)
    }

    /// 复位内容层（orderOut / close 之后调用，避免下一次打开带着缩放态）
    static func reset(_ window: NSWindow) {
        guard let layer = window.contentView?.layer else { return }
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        lastAnchors[ObjectIdentifier(window)] = nil
    }
}
