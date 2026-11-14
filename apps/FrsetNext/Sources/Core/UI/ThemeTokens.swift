import SwiftUI
import QuartzCore

/// 正式界面与独立展示包共用的无服务依赖设计令牌。
public enum Theme {
    public enum TextSize {
        /// 辅助信息下限（脚注、单位、"近 3 秒"这类）；正文一律 ≥ 11
        public static let micro: CGFloat = 10
        public static let caption: CGFloat = 11       // 最小可用正文字号（HIG 下限）
        public static let small: CGFloat = 12
        public static let body: CGFloat = 13
        public static let title: CGFloat = 15
        /// 指标数值（大号等宽数字）
        public static let metric: CGFloat = 17
    }

    public enum Radius {
        /// 内容卡片（设置分组、统计卡、流向图卡）
        public static let card: CGFloat = 10
        /// HUD 级大圆角（存储 Treemap 的块；v260 从 26pt 字面量收编，
        /// 不参与窗口/卡片分档，避免为了过 lint 把视觉半径改小）
        public static let hud: CGFloat = 26
        /// 控件（按钮底、输入框、缩略图容器）
        public static let control: CGFloat = 8
        /// 小标签 / 徽标底
        public static let chip: CGFloat = 6
        /// 进度条端点、极小色块
        public static let micro: CGFloat = 4
        /// 通知条胶囊半高（GlassSurface 需要数值，不能直接用 Capsule()）
        public static let pill: CGFloat = 30
    }

    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let emphasis: CGFloat = 1
    }

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 20
    }

    public enum Motion {
        // 单次交互
        public static let tap: Animation = .easeOut(duration: 0.12)
        public static let fast: Animation = .easeOut(duration: 0.16)
        public static let page: Animation = .easeOut(duration: 0.22)
        public static let slow: Animation = .easeOut(duration: 0.45)

        // 弹簧四档（跟手 / 标准 / 柔和 / 回弹）
        public static let springSnappy: Animation = .spring(response: 0.22, dampingFraction: 0.85)
        public static let spring: Animation = .spring(response: 0.28, dampingFraction: 0.86)
        public static let springSoft: Animation = .spring(response: 0.34, dampingFraction: 0.86)
        public static let springBouncy: Animation = .spring(response: 0.24, dampingFraction: 0.62)

        // 连续循环
        public static let loop: Animation = .linear(duration: 0.9)
        public static let progress: Animation = .linear(duration: 0.2)

        // AppKit / CoreAnimation 侧（时长单列，避免与 SwiftUI 混用）
        public static let dTap: TimeInterval = 0.12
        public static let dFast: TimeInterval = 0.16
        public static let dPage: TimeInterval = 0.22
        public static let caLinear = CAMediaTimingFunction(name: .linear)
        public static let caEaseOut = CAMediaTimingFunction(controlPoints: 0.22, 0, 0, 1)
        public static let caEaseIn = CAMediaTimingFunction(name: .easeIn)
        public static let caEaseInEaseOut = CAMediaTimingFunction(name: .easeInEaseOut)
        /// 入场「略冲过」曲线（监测独立窗）
        public static let caBackOut = CAMediaTimingFunction(controlPoints: 0.22, 1.05, 0.36, 1)
    }

    public static var rowHoverFill: Color { Color.primary.opacity(0.055) }

    public static let tertiaryText = Color.primary.opacity(0.55)

    public static let secondaryText = Color.secondary

    public static let cardBackground = Color(NSColor.controlBackgroundColor).opacity(0.6)

    public static let separator = Color(NSColor.separatorColor).opacity(0.5)

    public static func accent(for color: Color?) -> Color { color ?? .accentColor }

    public static func cardFillAlpha(lift: Double, isDark: Bool) -> CGFloat {
        isDark ? 0.035 + 0.065 * lift : 0.55 + 0.43 * lift
    }

    public static func cardStrokeAlpha(strength: Double, isDark: Bool) -> CGFloat {
        isDark ? 0.02 + 0.16 * strength : 0.02 + 0.14 * strength
    }
}
