import SwiftUI

// MARK: - 五类表面职责（需求 B 九，v285；v285.1 补侧栏磨砂）
//
// 在 v179「结构面真玻璃 / 内容卡不叠模糊」两级规则之上，把全产品的
// 背景语义收敛为五类。**只路由到既有实现**（glassPlate / glassCard /
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
//   5. 侧栏磨砂   .sidebar       —— 分类导航栏（2026-11-23 需求 B 三）：
//      微暗底衬 + 霜感两层（sidebarFill + sidebarFrost），**不另加模糊**
//      （窗口玻璃已采样）。比 contentBase 实一点、比 floatingGlass 透一点，
//      与中间卡片区有微妙区分但不抢戏。
//
// 边缘高光克制：结构面描边统一走 cardStroke（个性化可调），不画双高光；
// 阴影只出现在 3/4 两类，普通卡片 / 主内容 / 侧栏不配阴影。
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
    /// 分类导航栏：轻微磨砂（底衬 + 霜感，不叠模糊），与卡片区微妙区分
    case sidebar
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
        case .sidebar:
            // 不裁切：侧栏是整列通栏，圆角由窗口自身给。
            content.modifier(SidebarFrostModifier())
        }
    }
}

/// 侧栏磨砂（需求 B 三）：微暗底衬 + 霜感两层，压在窗口玻璃之上。
///
/// **不另加模糊**——侧栏坐在窗口玻璃上，采样由窗口那层做过，再叠一层只会掉帧；
/// 「磨砂感」由霜感薄雾提供。两层都跟随个性化（底衬跟 Midnight、霜感跟「磨砂」滑块），
/// 所以自己观察 Personalization（同 GlassCard 的做法，只靠父视图不保证重绘）。
private struct SidebarFrostModifier: ViewModifier {
    @ObservedObject private var personalization = Personalization.shared
    @ObservedObject private var appearance = AppearanceState.shared
    @Environment(\.settingsPreviewPersonalization) private var previewPersonalization
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight

    func body(content: Content) -> some View {
        let colors = ThemeAppearance(personalization: previewPersonalization ?? personalization,
                                     isMidnight: previewIsMidnight ?? appearance.isMidnight)
        content.background {
            // 顺序同 GlassSurface：底衬在下、霜感在上（霜感压在底衬之上才看得见）
            colors.sidebarFill
            colors.sidebarFrost
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
    ///
    /// 2026-11-23（需求 B 四：「点击/悬停前后底色不能跳变，hover 态用 stateFill
    /// 而非换材质」）：补齐 `hovered` 一档（注释里一直写着「悬停/按下/选中」，
    /// 实现却漏了悬停），并允许传入 `radius` / `accent`：
    ///   · 卡片/行自己有既定圆角（card 10 / chip 6），底要贴着同一弧度走；
    ///   · 选中底跟随个性化强调色，`accent` 显式传入即可即时重绘；
    ///   · 明暗由 `\.colorScheme` 自动取，调用方不用各自传。
    /// 三档都是**垫在卡面填充之上**的一层 wash（不换材质、不动 cardFill），
    /// 所以悬停/按下/选中前后底色稳定，只有叠加的交互反馈在变。
    func stateFill(hovered: Bool = false, pressed: Bool = false, selected: Bool = false,
                   accent: Color? = nil,
                   radius: CGFloat = Theme.Radius.control) -> some View {
        modifier(StateFillModifier(hovered: hovered, pressed: pressed, selected: selected,
                                   accent: accent, radius: radius))
    }
}

/// 交互状态底（悬停 / 按下 / 选中）的统一绘制。
/// 明暗自适应；三档互斥，优先级 选中 > 按下 > 悬停。
private struct StateFillModifier: ViewModifier {
    var hovered: Bool
    var pressed: Bool
    var selected: Bool
    var accent: Color?
    var radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            if selected {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.State.selected(isDark: colorScheme == .dark, accent: accent))
            } else if pressed {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.State.press)
            } else if hovered {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.State.hover)
            }
        }
    }
}
