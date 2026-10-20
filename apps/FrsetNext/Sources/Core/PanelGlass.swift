import SwiftUI

// MARK: - 面板内的三档玻璃层级
//
// 用户反馈（2026-10-20）：卡片纯白太亮、与面板背景玻璃差距太大；底部悬浮条的玻璃感又和卡片不同。
// 按 HIG「玻璃表达层级」收敛为三档，各司其职：
//
//   1) 面板/窗口玻璃（L0）：LiquidGlassBackground（真材质模糊）——结构最底层，已有
//   2) 内容卡（L1，card）：半透明淡白 + 极弱斜高光 + 0.5pt 亮边，**不做模糊**
//      （列表里逐卡叠模糊会掉帧；靠透明度与高光与背景拉开层次，而不是靠白度）
//   3) 悬浮控件（L2，floating）：真材质模糊 + 淡白 tint + 投影——浮在内容之上，
//      玻璃感明显强于卡片，形成第三种质感
//
// 三档共用同一套明暗自适应与「降低透明度」回退。
//
// 2026-10-20 全量接入个性化（用户：改颜色/材质后玻璃面要跟着变）：
//   · 强调色：`tint` 参数传 Theme.accent 即可在高亮态着色；
//   · Midnight：卡片底/亮边改吃 Midnight 色板（经 environment 注入，不反向依赖）；
//   · 背景材质（ui.panel.material）：纯色卡片时浮层不用真材质，改不透明底；
//   · 圆角（ui.corner.radius）：调用点统一传 Theme.cornerRadius。

enum PanelGlassTier {
    /// 内容卡：日历卡 / 剪贴板行
    case card
    /// 悬浮控件：底部工具条、浮动胶囊
    case floating
}

struct PanelGlassSurface: ViewModifier {
    let tier: PanelGlassTier
    var cornerRadius: CGFloat = 12
    /// 额外叠加色（如 hover 的 accent 提亮）
    var tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    /// Midnight 覆盖（根视图 frsetThemeChrome 注入；非 Midnight 全为 nil/false）
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground
    /// 个性化材质（纯色卡片 / 毛玻璃）
    @ObservedObject private var personalization = Personalization.shared
    /// 辅助功能「降低透明度」：卡片与浮条都退回更实的底
    private var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Midnight 时底色改用冷黑蓝色板，而不是淡白
    private var isMidnight: Bool { midnightCardBackground != nil }

    func body(content: Content) -> some View {
        content.background(background)
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch tier {
        case .card:
            ZStack {
                shape.fill(cardBase)
                shape.fill(
                    LinearGradient(
                        colors: [cardHighlight, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                shape.strokeBorder(cardBorder, lineWidth: 0.5)
                if let tint { shape.fill(tint) }
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.03),
                    radius: 3, x: 0, y: 1)

        case .floating:
            ZStack {
                shape.fill(floatingBase)
                shape.fill(floatingTint)
                shape.strokeBorder(cardBorder, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10),
                    radius: 12, x: 0, y: 4)
        }
    }

    // MARK: 配色（明暗 / Midnight / 材质 三向自适应）

    /// 卡片底：淡白，比旧版 0.76 明显收，和玻璃背景只差一个层次
    private var cardBase: Color {
        if let midnight = midnightCardBackground {
            return midnight.opacity(0.92)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.055)
            : Color.white.opacity(reduceTransparency ? 0.72 : 0.42)
    }

    /// 斜向高光：只给一点点，避免「白塑料」观感
    private var cardHighlight: Color {
        if isMidnight { return Color.white.opacity(0.045) }
        return colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.20)
    }

    private var cardBorder: Color {
        if isMidnight { return Color.white.opacity(0.12) }
        return colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.50)
    }

    /// 浮层底：毛玻璃（默认）/ 纯色（个性化 ui.panel.material = solid）
    private var floatingBase: AnyShapeStyle {
        let solid = personalization.material == .solid || reduceTransparency
        if solid {
            if let midnight = midnightCardBackground {
                return AnyShapeStyle(midnight.opacity(0.96))
            }
            return AnyShapeStyle(
                colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.88)
            )
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    /// 浮条额外白 tint（材质之上再压一层，保证内容可读）
    private var floatingTint: Color {
        if isMidnight { return Color.white.opacity(0.03) }
        return colorScheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.16)
    }
}

extension View {
    /// 内容卡（日历/剪贴板行）。圆角默认跟个性化 `ui.corner.radius`。
    func panelGlassCard(cornerRadius: CGFloat? = nil, tint: Color? = nil) -> some View {
        modifier(PanelGlassSurface(tier: .card,
                                   cornerRadius: cornerRadius ?? Theme.cornerRadius,
                                   tint: tint))
    }

    /// 悬浮控件（底部工具条等）。圆角默认跟个性化。
    func panelGlassFloating(cornerRadius: CGFloat? = nil) -> some View {
        modifier(PanelGlassSurface(tier: .floating,
                                   cornerRadius: cornerRadius ?? Theme.cornerRadius))
    }
}
