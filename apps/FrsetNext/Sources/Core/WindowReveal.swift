import AppKit
import QuartzCore

// MARK: - 窗口级「从哪来、回哪去」展开 / 收回（v197）
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
//     与 GSAP 「只动 transform/opacity」的口径一致（monitor 独立窗 v71 已验证）。
//
// 数学：窗口内容层的 `transform` 默认绕 anchorPoint（中心）缩放。要让窗口内归一化
// 锚点 (u, v)（u 左→右、v 上→下，同 SwiftUI UnitPoint）保持不动，等价于
// T(d) · S(s) · T(-d)，其中 d = ((u-0.5)·W, (0.5-v)·H)（layer 坐标 y 向上）。
// 这样不用改 anchorPoint/position（改它们会与 AppKit 的布局打架）。
enum WindowReveal {

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
        layer.transform = transform(scale: scale, around: unit, in: view.bounds.size)
        layer.opacity = 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak layer] in
            // 复位成模型值，下一次打开/切换不受上一次动画残留影响
            layer?.transform = CATransform3DIdentity
            layer?.opacity = 1
            completion?()
        }
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    /// 退场：内容层缩回 `unit` 点并淡出；completion 在动画结束后调用（层已复位）。
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
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak layer] in
            layer?.transform = CATransform3DIdentity
            layer?.opacity = 1
            completion()
        }
        layer.transform = transform(scale: scale, around: unit, in: view.bounds.size)
        layer.opacity = 0
        CATransaction.commit()
    }
}
