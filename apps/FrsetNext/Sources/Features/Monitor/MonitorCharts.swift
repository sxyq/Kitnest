import SwiftUI

// MARK: - 迷你折线（状态栏 / 卡片用）

/// 由数值数组绘制的折线（自适应归一化，支持固定上限）
public struct MonitorSparkline: Shape {
    public var values: [Double]
    /// 归一化上限；nil 时取数组最大值
    public var upperBound: Double?

    public init(values: [Double], upperBound: Double? = nil) {
        self.values = values
        self.upperBound = upperBound
    }

    public func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let maxValue: Double = {
            if let bound = upperBound, bound > 0 { return bound }
            return max(values.max() ?? 0, 0.0001)
        }()
        var path = Path()
        let stepX = rect.width / Double(values.count - 1)
        for (index, raw) in values.enumerated() {
            let value = min(max(raw, 0), maxValue)
            let x = rect.minX + stepX * Double(index)
            let y = rect.maxY - (value / maxValue) * rect.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

/// 面积形状：折线 + 闭合到底边（用于渐变填充）
public struct MonitorAreaShape: Shape {
    public var values: [Double]
    public var upperBound: Double?

    public init(values: [Double], upperBound: Double? = nil) {
        self.values = values
        self.upperBound = upperBound
    }

    public func path(in rect: CGRect) -> Path {
        var path = MonitorSparkline(values: values, upperBound: upperBound).path(in: rect)
        guard values.count > 1 else { return path }
        let startX = rect.minX
        let endX = rect.maxX
        path.addLine(to: CGPoint(x: endX, y: rect.maxY))
        path.addLine(to: CGPoint(x: startX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 折线 + 下方渐变填充（详情面板使用）
public struct MonitorAreaSparkline: View {
    public let values: [Double]
    public let color: Color
    public let upperBound: Double?

    public init(values: [Double], color: Color, upperBound: Double? = nil) {
        self.values = values
        self.color = color
        self.upperBound = upperBound
    }

    public var body: some View {
        MonitorAreaShape(values: values, upperBound: upperBound)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.30), color.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                MonitorSparkline(values: values, upperBound: upperBound)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            )
            .drawingGroup()
    }
}

// MARK: - 迷你柱状（每核 CPU）

/// 一组 0..1 数值的柱状条
public struct MonitorBarChart: View {
    public let values: [Double]
    public let color: Color
    public var spacing: CGFloat = 2

    public init(values: [Double], color: Color, spacing: CGFloat = 2) {
        self.values = values
        self.color = color
        self.spacing = spacing
    }

    public var body: some View {
        GeometryReader { proxy in
            let count = max(1, values.count)
            let width = max(1, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<count, id: \.self) { index in
                    let raw = index < values.count ? values[index] : 0
                    let ratio = min(1, max(0, raw.isFinite ? raw : 0))
                    RoundedRectangle(cornerRadius: min(2, width / 3), style: .continuous)
                        .fill(color.opacity(0.35 + 0.65 * ratio))
                        .frame(width: width, height: max(1, proxy.size.height * CGFloat(ratio)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
    }
}

// MARK: - 环形图（CPU / 内存占比）

/// 单值环形进度（Stats 语义色）
///
/// v84（2026-10-20 用户反馈「环状图左侧与上侧被截断」）：SwiftUI 的
/// `Circle().stroke(lineWidth:)` 是**描边居中于路径**——路径取 bounds 内接圆，
/// 于是描边有 `lineWidth/2` 画到 frame 之外（66pt 环 + 7pt 线 → 四边各溢 3.5pt），
/// 被容器裁掉后表现为左上缺边（视觉重心所在）。修复：路径按半个线宽内缩
/// （`inset(by: lineWidth/2)`），描边恰好贴合 frame，外径不变、不再被裁。
public struct MonitorRing: View {
    public let value: Double
    public let lineWidth: CGFloat
    public let color: Color

    public init(value: Double, lineWidth: CGFloat = 8, color: Color = .blue) {
        self.value = value
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: min(1, max(0, value.isFinite ? value : 0)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - 堆叠条（内存构成）

/// 分段堆叠条（每段 0..1 的相对占比，内部归一化）
public struct MonitorStackedBar: View {
    public struct Segment: Identifiable {
        public let id: String
        public let value: Double
        public let color: Color

        public init(id: String, value: Double, color: Color) {
            self.id = id
            self.value = value
            self.color = color
        }
    }

    public let segments: [Segment]
    public var height: CGFloat = 10

    public init(segments: [Segment], height: CGFloat = 10) {
        self.segments = segments
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(0) { $0 + max(0, $1.value) }, 0.0001)
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    let ratio = max(0, segment.value) / total
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, proxy.size.width * CGFloat(ratio)))
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
    }
}

// MARK: - 语义色（沿用 Stats 配色语义）

public enum MonitorColors {
    public static let system = Color(red: 0.90, green: 0.25, blue: 0.28)   // 系统态：红
    public static let user = Color(red: 0.24, green: 0.55, blue: 0.95)     // 用户态：蓝
    public static let idle = Color.gray.opacity(0.45)                      // 空闲：灰
    public static let memory = Color(red: 0.35, green: 0.72, blue: 0.55)   // 内存：绿
    public static let compressed = Color(red: 0.95, green: 0.72, blue: 0.30)
    public static let wired = Color(red: 0.60, green: 0.45, blue: 0.85)
    public static let upload = Color(red: 0.95, green: 0.55, blue: 0.35)   // 上传：橙
    public static let download = Color(red: 0.30, green: 0.70, blue: 0.90) // 下载：青
    public static let read = Color(red: 0.35, green: 0.72, blue: 0.55)
    public static let write = Color(red: 0.90, green: 0.40, blue: 0.55)
    public static let temperature = Color(red: 0.95, green: 0.60, blue: 0.30)
    public static let battery = Color(red: 0.40, green: 0.78, blue: 0.45)
}

// MARK: - 小组件

/// 卡片容器（Liquid Glass 镀边：斜向高光 + 细亮边 + 内阴影；不叠第二层模糊）
public struct MonitorCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(10)
            .background(GlassCardBackground(cornerRadius: Theme.cornerRadius))
    }
}

/// 「标签 + 等宽数值」行
public struct MonitorRow: View {
    public let label: String
    public let value: String
    public var color: Color = .primary

    public init(label: String, value: String, color: Color = .primary) {
        self.label = label
        self.value = value
        self.color = color
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// 分区标题（原版 Stats 版式：居中文字 + 两侧细线，如「──── 负载历史 ────」）
public struct MonitorSectionTitle: View {
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 10) {
            line
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
            line
        }
        .padding(.vertical, 5)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.5)
    }
}
