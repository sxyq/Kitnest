import SwiftUI

// MARK: - 迷你折线（状态栏 / 卡片用）

/// 由数值数组绘制的折线（自适应归一化，支持固定上限）
///
/// v183（用户：「线条十分的差劲」）：原实现是逐点 `addLine` 的折线——
/// 60 个采样点在 300pt 宽里每段只有 5pt，锯齿、拐角生硬。现在改成
/// **Catmull-Rom 转三次贝塞尔**的平滑曲线（控制点做上下钳制，不会冲出色带），
/// 并支持 `slots`：按固定时间窗口右对齐，新点从右边进、旧点向左移，
/// 不再「点少时把整条线拉伸铺满」（那会让曲线每来一个点就整体抖一下）。
public struct MonitorSparkline: Shape {
    public var values: [Double]
    /// 归一化上限；nil 时取数组最大值
    public var upperBound: Double?
    /// 固定槽位数（时间窗口）；nil = 按实际点数铺满（旧行为）
    public var slots: Int?

    public init(values: [Double], upperBound: Double? = nil, slots: Int? = nil) {
        self.values = values
        self.upperBound = upperBound
        self.slots = slots
    }

    public func path(in rect: CGRect) -> Path {
        let points = MonitorSparkline.points(values: values, upperBound: upperBound,
                                             slots: slots, in: rect)
        guard points.count > 1 else { return Path() }
        return MonitorSparkline.smoothPath(points, in: rect)
    }

    /// 采样点 → 坐标（Y 轴共享同一 upperBound；X 轴按槽位右对齐）
    static func points(values: [Double], upperBound: Double?, slots: Int?,
                       in rect: CGRect) -> [CGPoint] {
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let maxValue: Double = {
            if let bound = upperBound, bound > 0 { return bound }
            return max(values.max() ?? 0, 0.0001)
        }()
        let slotCount = max(slots ?? values.count, values.count)
        let step = rect.width / CGFloat(max(1, slotCount - 1))
        let offset = slotCount - values.count
        return values.enumerated().map { index, raw in
            let value = min(max(raw.isFinite ? raw : 0, 0), maxValue)
            let x = rect.minX + step * CGFloat(offset + index)
            let y = rect.maxY - CGFloat(value / maxValue) * rect.height
            return CGPoint(x: x, y: y)
        }
    }

    /// 平滑路径：Catmull-Rom（张力 1/6）→ 三次贝塞尔
    static func smoothPath(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            var c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                             y: p1.y + (p2.y - p0.y) / 6.0)
            var c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                             y: p2.y - (p3.y - p1.y) / 6.0)
            // 只钳制 Y：峰值/谷值处的三次曲线会向外冲，冲出色带就会「画出负数」
            c1.y = min(max(c1.y, rect.minY), rect.maxY)
            c2.y = min(max(c2.y, rect.minY), rect.maxY)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

/// 面积形状：折线 + 闭合到底边（用于渐变填充）
public struct MonitorAreaShape: Shape {
    public var values: [Double]
    public var upperBound: Double?
    public var slots: Int?

    public init(values: [Double], upperBound: Double? = nil, slots: Int? = nil) {
        self.values = values
        self.upperBound = upperBound
        self.slots = slots
    }

    public func path(in rect: CGRect) -> Path {
        let points = MonitorSparkline.points(values: values, upperBound: upperBound,
                                             slots: slots, in: rect)
        guard let first = points.first, let last = points.last, points.count > 1 else {
            return Path()
        }
        var path = MonitorSparkline.smoothPath(points, in: rect)
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 折线 + 下方渐变填充（详情面板使用）
public struct MonitorAreaSparkline: View {
    public let values: [Double]
    public let color: Color
    public let upperBound: Double?
    public var slots: Int?
    public var lineWidth: CGFloat

    public init(values: [Double], color: Color, upperBound: Double? = nil,
                slots: Int? = nil, lineWidth: CGFloat = 1.6) {
        self.values = values
        self.color = color
        self.upperBound = upperBound
        self.slots = slots
        self.lineWidth = lineWidth
    }

    public var body: some View {
        MonitorAreaShape(values: values, upperBound: upperBound, slots: slots)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.28), color.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                MonitorSparkline(values: values, upperBound: upperBound, slots: slots)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth,
                                                      lineCap: .round, lineJoin: .round))
            )
            // v183：去掉 drawingGroup()——它把整条曲线离屏栅格化，
            // 细线在非整数倍缩放下会发灰发糊，正是「线条差劲」的来源之一。
    }
}

// MARK: - 迷你柱状（每核 CPU）

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
