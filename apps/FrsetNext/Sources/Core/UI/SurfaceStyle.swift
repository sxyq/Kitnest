import SwiftUI

// MARK: - 四类表面职责（需求 B 九，v285）
//
// 在 v179「结构面真玻璃 / 内容卡不叠模糊」两级规则之上，把全产品的
// 背景语义收敛为四类。**只路由到既有实现**（glassPlate / glassCard /
// whiteGlassCard / GlassSurface），不新建主题系统：
//
//   1. 主内容底板 .contentBase   —— 主要阅读内容：低噪声实底，不做动态模糊。
//      窗口级由 UnifiedGlassBackingView / applyOfficialChrome 提供；
//      内容区用本修饰器等于「不额外加层」（防止根玻璃与正文底衬重复）。
//   2. 普通卡片   .card          —— 内容分组卡：不逐卡建 NSGlassEffectView；
//      实色轻填充 + 0.5pt 发丝边（glassCard）。
//   3. 悬浮玻璃   .floatingGlass —— 浮在内容之上的控制层：真玻璃/毛玻璃
//      （glassPlate）+ 浮动阴影（Theme.Shadow.floating）。
//   4. 临时浮层   .transient     —— Popover/HUD/详情卡：玻璃 + 柔投影
//      （Theme.Shadow.transient），可读、可关闭、不常驻。
//
// 边缘高光克制：结构面描边统一走 cardStroke（个性化可调），不画双高光；
// 阴影只出现在 3/4 两类，普通卡片与主内容不配阴影。
// 浅色与深色分别给值（WhiteGlassCard 内已分色），不靠自动反转。

enum SurfaceKind {
    /// 主内容底板：不加层（窗口玻璃已衬底），避免玻璃与正文底衬重复
    case contentBase
    /// 普通内容卡片：轻填充 + 发丝边，无模糊无阴影
    case card
    /// 重要悬浮玻璃控制层：真玻璃 + 浮动阴影
    case floatingGlass
    /// 临时 Popover / HUD / 独立浮层：玻璃 + 柔投影
    case transient
}

struct SurfaceStyle: ViewModifier {
    let kind: SurfaceKind
    var radius: CGFloat = Theme.Radius.card

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch kind {
        case .contentBase:
            // 窗口级玻璃已由 UnifiedGlassBackingView 提供；内容区不再叠层。
            content
        case .card:
            content.glassCard(radius: radius)
        case .floatingGlass:
            content
                .glassPlate(radius: radius)
                .shadow(color: .black.opacity(Theme.Shadow.floating.opacity),
                        radius: Theme.Shadow.floating.radius,
                        x: 0, y: Theme.Shadow.floating.y)
        case .transient:
            content
                .glassPlate(radius: max(radius, Theme.Radius.card))
                .shadow(color: .black.opacity(Theme.Shadow.transient.opacity),
                        radius: Theme.Shadow.transient.radius,
                        x: 0, y: Theme.Shadow.transient.y)
        }
    }
}

extension View {
    /// 四类表面统一入口。卡片/浮层从这里取样式，不再各写一份背景。
    func surface(_ kind: SurfaceKind,
                 radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(SurfaceStyle(kind: kind, radius: radius))
    }

    /// 交互状态底（悬停/按下/选中）统一口径。
    /// 列表行、图块、按钮底都从这里取，不各写透明度。
    func stateFill(pressed: Bool = false, selected: Bool = false, isDark: Bool = false) -> some View {
        background {
            if selected {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.State.selected(isDark: isDark))
            } else if pressed {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.State.press)
            }
        }
    }
}
