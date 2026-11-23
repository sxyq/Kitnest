import AppKit
import SwiftUI

enum LiquidGlass {

    /// 当前系统是否支持真·液态玻璃
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 用户是否开启「降低透明度」
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// 玻璃容器。返回 NSGlassEffectView（26+）或 NSVisualEffectView（回退）。
    /// 内容由 `embed(_:in:)` 装入。`Personalization.material == .solid` 时退化为不透明底。
    static func makeView(frame: NSRect = .zero,
                         cornerRadius: CGFloat,
                         material: NSVisualEffectView.Material = .hudWindow,
                         tint: NSColor? = nil,
                         solid: Bool, followsWindowFocus: Bool = true, systemGlass: Bool? = nil) -> NSView {
        let solid = solid || reduceTransparency
        // v202（用户：「焦点在不在这个 App 里玻璃效果完全两套，需要合并成唯一一种」）：
        // NSGlassEffectView 会随窗口 key/inactive 改变观感，无法固定。
        // 全工程统一改为 NSVisualEffectView + 固定 .inactive 状态——
        // 无论窗口是否 key、App 是否前台，玻璃浓淡完全一致（取用户要的「失焦态」）。
        if #available(macOS 26.0, *), !solid, followsWindowFocus, systemGlass ?? prefersSystemGlass {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            setCornerRadius(cornerRadius, on: glass)
            glass.tintColor = tint
            glass.autoresizingMask = [.width, .height]
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = false
            }
            return glass
        }
        // 回退 / 纯色：毛玻璃（原实现）；纯色与「降低透明度」都改不透明底
        let effect = NSVisualEffectView(frame: frame)
        effect.material = solid ? .windowBackground : material
        effect.blendingMode = solid ? .withinWindow : .behindWindow
        // 固定失焦态：不随 key window 改变浓淡（v202 用户「焦点两套观感」的解法）。
        // 2026-11-23 需求 B 六：这一档本身不会随焦点跳变（state 是硬钉的）；
        // 真正会跳的是上面 26+ 的 NSGlassEffectView —— SDK 头文件
        // (NSGlassEffectView.h) 里没有 state / isActive 之类的固定口子，
        // 失焦观感由系统管。要彻底钉死就走 `followsWindowFocus: false`
        // 回到本分支。任何后续重套样式请走 reapplyStyle（幂等 + 隐式动画），
        // 不要直接改这三个属性，否则会作废整窗采样 → 闪一下。
        effect.state = .inactive
        effect.wantsLayer = true
        if effect.layer == nil { effect.layer = CALayer() }
        setCornerRadius(cornerRadius, on: effect)
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        return effect
    }

    /// 是否使用 macOS 26 真玻璃（v205）。
    ///
    /// 用户：「玻璃质感需要跟 MacOS 自带的天气它这种玻璃质感一致，初始默认的」。
    /// 天气 App 用的是系统 Liquid Glass（NSGlassEffectView）；默认改为开启，
    /// 保持系统原生的折射/霜感。需要退回旧毛玻璃时：
    ///   `defaults write com.sxyq.frsetnext uiUseSystemGlass -bool NO`
    private static var prefersSystemGlass: Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: "uiUseSystemGlass") != nil else { return true }
        return d.bool(forKey: "uiUseSystemGlass")
    }

    /// 已存在的玻璃容器在「材质/圆角/着色」变更后重新套样式（个性化即改即生效）
    ///
    /// 2026-11-23（需求 B 六：「窗口失焦时 .inactive 态要平滑过渡，不能闪烁」）：
    /// 旧实现每次调用都无条件重设 `material / blendingMode / state` 三个属性——
    /// 哪怕值一个都没变，AppKit 也会作废整窗的玻璃采样并重采一遍，
    /// 肉眼就是「失焦瞬间玻璃闪一下」。`reapplyStyle` 又被 show 前、
    /// 数据刷新、外观切换等高频路径调用，等于把闪烁接到焦点切换上。
    ///
    /// 现在分两步：
    ///   1. **幂等**：三个值都未变时直接短路，完全不碰采样层（首选路径）；
    ///   2. **平滑**：真要改（降透明度切换 / 材质切换）时把赋值放进
    ///      `NSAnimationContext` 隐式动画，.inactive 态以淡入方式到位，
    ///      而不是硬切一帧。
    /// 着色（tint）与圆角不参与采样失效，照旧即时生效。
    static func reapplyStyle(on view: NSView, cornerRadius: CGFloat, tint: NSColor?,
                             solid: Bool) {
        setCornerRadius(cornerRadius, on: view)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = tint
            return
        }
        guard let effect = view as? NSVisualEffectView else {
            return
        }
        let solid = solid || reduceTransparency
        let targetMaterial: NSVisualEffectView.Material = solid ? .windowBackground : .hudWindow
        let targetBlending: NSVisualEffectView.BlendingMode = solid ? .withinWindow : .behindWindow
        // 与 makeView 一致：固定失焦态（不随 key window 改变浓淡）。
        let targetState: NSVisualEffectView.State = .inactive
        guard effect.material != targetMaterial
                || effect.blendingMode != targetBlending
                || effect.state != targetState else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.dFast
            context.allowsImplicitAnimation = true
            effect.material = targetMaterial
            effect.blendingMode = targetBlending
            effect.state = targetState
        }
    }

    /// 动画只更新几何，不重复设置材质与着色。
    static func setCornerRadius(_ radius: CGFloat, on view: NSView) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            view.layer?.cornerRadius = radius
            view.layer?.cornerCurve = .continuous
        }
    }

    /// 把内容装进玻璃容器并铺满
    ///
    /// v166.5：**不再用 `NSGlassEffectView.contentView`**。
    /// 该分支此前从未被走到（主面板一直用 NSVisualEffectView 回退路径），
    /// 2026-10-30 首次启用后实测崩溃：
    ///   `_postWindowNeedsUpdateConstraints` → NSException → SIGABRT
    /// （把 hosting view 塞进 contentView 后，AppKit 在约束更新时抛异常）。
    /// 统一 addSubview：玻璃在底、内容在上，与已验证多年的 NSVisualEffectView 路径同构。
    static func embed(_ content: NSView, in container: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// 一份内容卡片绘制实现，正式配置与内存展示只提供颜色。
public extension View {
    func glassCard(radius: CGFloat = Theme.Radius.card, fill: Color, stroke: Color) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: Theme.Stroke.hairline)
                    .allowsHitTesting(false)
            }
            .modifier(IslandGlowTarget(radius: radius))
            .islandGlowClip()
    }
}
