// MARK: - 面板工具条（v236 三段式布局 + v271 图标按钮）
// 2026-11-23 由 PanelRootView.swift 拆出：纯类型搬家，无行为变化。

import SwiftUI

/// v271：底部工具条图标按钮。旧 toolbarIcon 用 .plain 样式，
/// 悬停无高亮、按下无反馈（用户原话：「没有动效啊！」）。
/// 现在：悬停圆角底色 + 图标染色，按压走 SpringyIconButtonStyle 弹簧缩放。
struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    let fontScale: CGFloat
    let accent: Color
    /// 激活态（如收藏筛选生效）：图标常驻强调色。
    var isActive: Bool = false
    var action: () -> Void

    /// 本工程 @State 宏不可用（SwiftUIMacros 缺失），按项目约定用 @Stored 兼容层。
    @Stored private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.scaledSystem(size: 14, scale: fontScale))
                .frame(width: 26, height: 26)
                .foregroundStyle(isActive || hovering ? accent : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? accent.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SpringyIconButtonStyle())
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - 页面过渡（v136：改按页实例化后，pageTransition(active:) 已弃用——
// 常驻层淡入淡出是「每帧合成全部页面」的根源；过渡改由 .transition(.opacity) 承担）

// MARK: - 顶栏三段式布局（v236）

/// 面板顶栏布局：**左图标组贴左、齿轮贴右、中间分段在整条工具条上居中**。
///
/// 为什么不用 `HStack + Spacer`：这样 Spacer 均分的只是「左组与齿轮**之后**」的剩余空间，
/// 左右两组宽度不等时中间那块必然偏移。实测左组 90pt（3×22 图标 + 2×12 间距）、
/// 齿轮 22pt，于是分段中心恒定右偏 34pt（用户：「顶部的主页监测没有居中」）。
/// 而分段本身随「设置 → 主面板页面」开关增删，宽度一直在变，所以需要一条
/// **与分段宽度无关**的居中规则。
///
/// 摆放规则：
/// 1. 中间块的中心 = 工具条中心；
/// 2. 若居中会压到左右两组，则按 `minGap` 向外让位（只有面板被压到极窄
///    且四段全开时才会发生）——宁可轻微偏一点，也绝不重叠。
struct PanelToolbarLayout: Layout {
    /// 中间块与左右两组之间至少留出的间距
    var minGap: CGFloat = 6
    /// 排障日志配额（只在 probe.toolbarLayout 打开时消耗，避免每帧刷日志）
    private static var logBudget = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealHeight = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 22
        return CGSize(width: proposal.width ?? 0,
                      height: proposal.height ?? idealHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        // 正常就是三段（左组 / 分段 / 齿轮）；数量不对时退化为等距排列，不做居中
        guard subviews.count == 3 else {
            var x = bounds.minX
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2),
                           proposal: ProposedViewSize(size))
                x += size.width + minGap
            }
            return
        }

        let leading = subviews[0], middle = subviews[1], trailing = subviews[2]
        let leadingSize = leading.sizeThatFits(.unspecified)
        let trailingSize = trailing.sizeThatFits(.unspecified)
        // 先按**理想宽度**量中间块。v236.1：此前直接按「居中允许的最大宽度」提方案，
        // 一旦这个值小于理想宽度，HStack 会把第一个 Text 压到连 0.8 缩字都放不下，
        // 于是「主页」被截成「…」（实测截图确认）。居中不能以牺牲文字为代价。
        let middleIdeal = middle.sizeThatFits(.unspecified)

        // 「居中」是硬约束：中间块宽度 W 时，左缘 = 中心 - W/2 必须让开左组，
        // 所以 W/2 ≤ 左侧到中心的余量，右侧同理。取两侧较小值就是居中允许的最大半宽。
        let leftHalf = bounds.midX - (bounds.minX + leadingSize.width + minGap)
        let rightHalf = (bounds.maxX - trailingSize.width - minGap) - bounds.midX
        let centerHalfMax = max(0, min(leftHalf, rightHalf))
        let centeredMax = centerHalfMax * 2
        let sideAvailable = max(0, bounds.width - leadingSize.width - trailingSize.width - 2 * minGap)

        var middleSize = middleIdeal
        var middleProposal = ProposedViewSize(middleIdeal)
        if middleIdeal.width > sideAvailable {
            // 只有「左右两组之间真的塞不下」才收紧——收紧就必然会缩字，
            // 所以宁可窄面板下轻微让位一两像素，也不为了凑居中把文字截成「…」。
            let target = max(1, sideAvailable)
            let fitted = middle.sizeThatFits(ProposedViewSize(width: target, height: bounds.height))
            middleSize = CGSize(width: min(fitted.width, target), height: fitted.height)
            middleProposal = ProposedViewSize(middleSize)
        }

        leading.place(at: CGPoint(x: bounds.minX, y: bounds.midY - leadingSize.height / 2),
                      proposal: ProposedViewSize(leadingSize))
        trailing.place(at: CGPoint(x: bounds.maxX - trailingSize.width,
                                   y: bounds.midY - trailingSize.height / 2),
                       proposal: ProposedViewSize(trailingSize))

        let centered = bounds.midX - middleSize.width / 2
        let minX = bounds.minX + leadingSize.width + minGap
        let maxX = bounds.maxX - trailingSize.width - minGap - middleSize.width
        // 装得下就绝对居中；两边真的挤到没有余量（minX > maxX）时保持居中，
        // 让中间块与自己那一侧的图标轻微重叠——视觉上仍是对称的，比整体右移更容易接受。
        let x = minX <= maxX ? min(max(centered, minX), maxX) : centered
        middle.place(at: CGPoint(x: x, y: bounds.midY - middleSize.height / 2),
                     proposal: middleProposal)

        // 排障：`defaults write com.sxyq.frsetnext probe.toolbarLayout -bool YES`
        // 打开后在日志里看到真实测得的宽度与偏移，便于核对「开关分段后是否还居中」。
        if UserDefaults.standard.bool(forKey: "probe.toolbarLayout"), Self.logBudget > 0 {
            Self.logBudget -= 1
            let offset = (x + middleSize.width / 2) - bounds.midX
            Log.info("Panel", String(
                format: "顶栏布局：宽%.0f 左组%.0f 齿轮%.0f 分段(理想%.0f/实际%.0f) 居中带%.0f 偏移%.1fpt",
                bounds.width, leadingSize.width, trailingSize.width,
                middleIdeal.width, middleSize.width, centeredMax, offset))
        }
    }
}
