import SwiftUI
import AppKit

private struct MonitorChartInput: NSViewRepresentable {
    enum Action {
        case hover(CGFloat), exit, click(CGFloat), drag(CGFloat), dragEnd, move(Int), toggle, focus(Bool)
    }
    let action: (Action) -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { view.action = action }

    final class InputView: NSView {
        var action: ((Action) -> Void)?
        private var start = NSPoint.zero
        private var dragging = false
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func viewDidMoveToWindow() { window?.acceptsMouseMovedEvents = true }
        override func updateTrackingAreas() {
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseMoved(with event: NSEvent) { action?(.hover(convert(event.locationInWindow, from: nil).x)) }
        override func mouseExited(with event: NSEvent) { action?(.exit) }
        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            dragging = false
            window?.makeFirstResponder(self)
        }
        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if !dragging && hypot(point.x - start.x, point.y - start.y) < 3 { return }
            dragging = true
            action?(.drag(point.x))
        }
        override func mouseUp(with event: NSEvent) {
            if dragging { action?(.dragEnd) }
            else { action?(.click(convert(event.locationInWindow, from: nil).x)) }
            dragging = false
        }
        override func becomeFirstResponder() -> Bool { action?(.focus(true)); return true }
        override func resignFirstResponder() -> Bool { action?(.focus(false)); return true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: action?(.move(-1))
            case 124: action?(.move(1))
            case 36, 76: action?(.toggle)
            default: super.keyDown(with: event)
            }
        }
    }
}

/// 图表的查看对象按采样时间保存，历史滚动后不会指向另一帧。
struct MonitorTrendPoint: Equatable {
    let time: Double
    let interval: Double
    let values: [Double?]
}

struct MonitorTrendData {
    let module: MonitorModuleID
    let key: String
    let names: [String]
    let colors: [Color]
    let points: [MonitorTrendPoint]
    let fixedUpper: Double?
    let interval: Double
    let visiblePoints: [MonitorTrendPoint]
    let suggestedUpper: Double
    var hasReadings: Bool { points.contains { $0.values.contains { $0 != nil } } }
    var start: Double { (points.last?.time ?? 0) - interval * Double(MonitorSampler.historyCapacity - 1) }
    var end: Double { points.last?.time ?? 0 }

    init(module: MonitorModuleID, history: MonitorSampler.History, sensor: String = "", sensorLabel: String? = nil, tint: Color? = nil) {
        self.module = module
        key = module.rawValue + ":" + sensor
        interval = history.intervals.last ?? 1
        let series: [[Double]]
        switch module {
        case .cpu:
            names = ["CPU 占用"]; colors = [tint ?? MonitorColors.user]
            series = [history.cpu.map { $0 * 100 }]; fixedUpper = 100
        case .gpu:
            names = ["GPU 占用"]; colors = [tint ?? MonitorColors.wired]
            series = [history.gpu.map { $0 * 100 }]; fixedUpper = 100
        case .memory:
            names = ["内存压力"]; colors = [tint ?? MonitorColors.memory]
            series = [history.memoryPressure.map { $0 == 1 ? 0 : $0 == 2 ? 1 : $0 == 4 ? 2 : .nan }]; fixedUpper = 2
        case .network:
            names = ["下载", "上传"]; colors = [tint ?? MonitorColors.download, MonitorColors.upload]
            series = [history.netDownload, history.netUpload]; fixedUpper = nil
        case .disk:
            names = ["读取", "写入"]; colors = [tint ?? MonitorColors.read, MonitorColors.write]
            series = [history.diskRead, history.diskWrite]; fixedUpper = nil
        case .sensors:
            names = [sensorLabel ?? (sensor.isEmpty ? "温度" : sensor)]; colors = [tint ?? MonitorColors.temperature]
            series = [history.temperatures[sensor] ?? []]; fixedUpper = nil
        case .power:
            names = ["整机负载"]; colors = [tint ?? MonitorColors.temperature]
            series = [history.power]; fixedUpper = nil
        case .battery:
            names = ["电量"]; colors = [tint ?? MonitorColors.battery]
            series = [history.battery.map { $0 * 100 }]; fixedUpper = 100
        }
        points = history.timestamps.enumerated().map { index, time in
            MonitorTrendPoint(time: time, interval: history.intervals[index], values: series.map {
                index < $0.count && $0[index].isFinite ? $0[index] : nil
            })
        }
        let cutoff = (points.last?.time ?? 0) - interval * Double(MonitorSampler.historyCapacity - 1)
        visiblePoints = points.filter { $0.time >= cutoff }
        suggestedUpper = fixedUpper ?? MonitorChartScale.niceCeiling(series.flatMap { $0.filter(\.isFinite) }.max() ?? 1,
            floorValue: module == .network || module == .disk ? 1024 : 1)
    }

    func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        switch module {
        case .cpu, .gpu, .battery: return String(format: "%.1f%%", value)
        case .memory: return value >= 2 ? "严重" : value >= 1 ? "警告" : "正常"
        case .network, .disk: return MonitorFormat.rate(MonitorFormat.u64(value))
        case .sensors: return MonitorFormat.temperature(value) + "C"
        case .power: return MonitorFormat.power(value)
        }
    }
}

/// 趋势图画法：面积（带渐变填充）或柱状。
enum MonitorChartStyle { case area, bars }

/// 正式界面与设置预览共用；鼠标移动只更新本图的查看状态。
struct MonitorTrendChart: View {
    let data: MonitorTrendData
    var selection: MonitorDetailSelection? = nil
    var compact = false
    var showAxes = true
    var style = MonitorChartStyle.area
    var interaction: ((Bool) -> Void)? = nil
    @Stored private var hovered: MonitorTrendPoint? = nil
    @Stored private var fixed: MonitorTrendPoint? = nil
    @Stored private var scale: Double = 1
    @Stored private var dragging = false
    @Stored private var activeKey = ""
    @Stored private var focused = false
    private var upper: Double { data.fixedUpper ?? (activeKey == data.key ? max(scale, data.suggestedUpper) : data.suggestedUpper) }
    private var reading: MonitorTrendPoint? { activeKey == data.key ? fixed ?? hovered ?? data.points.last : data.points.last }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            if compact {
                if data.names.count > 1 {
                    VStack(alignment: .leading, spacing: 2) { legend }
                } else {
                    Text(data.format(reading?.values.first ?? nil))
                        .font(.system(size: Theme.TextSize.metric, weight: .semibold).monospacedDigit())
                        .foregroundStyle(data.colors[0])
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { legend }
                    VStack(alignment: .leading, spacing: 5) { legend }
                }
                HStack {
                    Text(reading.map { timeText($0.time) } ?? "等待采样")
                    Spacer(minLength: 4)
                    if fixed != nil {
                        Button("返回最新") { unpin() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    } else {
                        Text(hovered == nil ? "当前" : "查看采样").foregroundStyle(.secondary)
                    }
                }.font(.system(size: Theme.TextSize.caption).monospacedDigit())
            }
            HStack(spacing: 8) {
                if showAxes && !compact {
                    VStack(alignment: .trailing) {
                        Text(data.hasReadings ? data.format(upper) : "—")
                        Spacer()
                        Text(data.hasReadings ? data.format(upper / 2) : "—")
                        Spacer()
                        Text(data.hasReadings ? data.format(0) : "—")
                    }.font(.system(size: Theme.TextSize.caption).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 74)
                }
                plot
            }
            if showAxes && !compact {
                HStack {
                    Text(data.points.isEmpty ? "等待首个采样" : timeText(data.start))
                    Spacer()
                    if !data.points.isEmpty { Text(timeText(data.end)) }
                }.font(.system(size: Theme.TextSize.caption).monospacedDigit())
                    .foregroundStyle(.secondary).padding(.leading, 82)
                Text(fixed.map { point in
                    point.time < data.start ? "已固定 · 采样已离开当前范围" : "已固定 · 采样继续更新"
                } ?? "悬停查看 · 点击固定 · 拖动或方向键定位")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
            }
        }
        .transaction { $0.animation = nil }
        .onAppear { restoreSelection() }
        .onChange(of: data.key) { _ in restoreSelection() }
        .onChange(of: data.end) { _ in
            if data.suggestedUpper > scale { scale = data.suggestedUpper }
        }
        .onDisappear { if dragging { interaction?(false); dragging = false } }
    }

    @ViewBuilder private var legend: some View {
        ForEach(data.names.indices, id: \.self) { index in
            HStack(spacing: 5) {
                Circle().fill(data.colors[index]).frame(width: 6, height: 6)
                Text(data.names[index]).foregroundStyle(.secondary)
                Text(data.format(reading?.values[index])).monospacedDigit().foregroundStyle(data.colors[index])
            }.font(.system(size: Theme.TextSize.small, weight: .medium))
        }
    }

    private var plot: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
                    var grid = Path()
                    for row in 0...2 {
                        let y = rect.minY + rect.height * CGFloat(row) / 2
                        grid.move(to: CGPoint(x: rect.minX, y: y))
                        grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                    context.stroke(grid, with: .color(.primary.opacity(0.10)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    drawSeries(context: &context, rect: rect)
                    if let reading, reading.time >= data.start, reading.time <= data.end {
                        let x = xPosition(reading.time, rect: rect)
                        var marker = Path()
                        marker.move(to: CGPoint(x: x, y: rect.minY))
                        marker.addLine(to: CGPoint(x: x, y: rect.maxY))
                        context.stroke(marker, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        for index in data.names.indices {
                            if let value = reading.values[index] {
                                let y = rect.maxY - CGFloat(min(upper, max(0, value)) / upper) * rect.height
                                context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(data.colors[index]))
                            }
                        }
                    }
                }.allowsHitTesting(false)
                if !data.hasReadings {
                    Text("暂无\(data.names[0])读数")
                        .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                }
            }
            .overlay {
                MonitorChartInput { action in
                    switch action {
                    case .hover(let x):
                        if fixed == nil {
                            let value = nearest(at: x, width: geometry.size.width)
                            if hovered != value { hovered = value }
                        }
                    case .exit: hovered = nil
                    case .click(let x):
                        pin(nearest(at: x, width: geometry.size.width))
                    case .drag(let x):
                        if !dragging { dragging = true; interaction?(true) }
                        pin(nearest(at: x, width: geometry.size.width))
                    case .dragEnd: dragging = false; interaction?(false)
                    case .move(let step):
                        let points = data.visiblePoints
                        guard !points.isEmpty else { return }
                        let current = reading?.time ?? data.end
                        let index = points.indices.min(by: { abs(points[$0].time - current) < abs(points[$1].time - current) })!
                        let point = points[min(max(index + step, 0), points.count - 1)]
                        if fixed == nil { hovered = point } else { pin(point) }
                    case .toggle:
                        if fixed != nil { unpin() } else { pin(reading) }
                    case .focus(let value): focused = value
                    }
                }
            }
        }
        .frame(minHeight: compact ? 24 : 130, maxHeight: compact ? .infinity : 160)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(focused ? Theme.accent : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if focused {
                Button(fixed == nil ? "固定采样" : "解除固定") {
                    if fixed != nil { unpin() } else { pin(reading) }
                }.focusable(false)
                    .font(.system(size: Theme.TextSize.caption)).buttonStyle(.plain)
                    .padding(5).background(.regularMaterial, in: Capsule())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(data.module.displayName)趋势图，方向键定位，回车固定或解除固定")
        .accessibilityValue(reading.map { timeText($0.time) + "，" + data.format($0.values[0]) } ?? "等待采样")
    }

    private func drawSeries(context: inout GraphicsContext, rect: CGRect) {
        for series in data.names.indices {
            var run: [CGPoint] = []
            var previous: MonitorTrendPoint? = nil
            for point in data.visiblePoints {
                if let prior = previous, point.time - prior.time > max(prior.interval, point.interval) * 2.5 {
                    drawRun(run, series: series, context: &context, rect: rect); run.removeAll(keepingCapacity: true)
                }
                if let value = point.values[series] {
                    run.append(CGPoint(x: xPosition(point.time, rect: rect), y: rect.maxY - CGFloat(min(upper, max(0, value)) / upper) * rect.height))
                } else {
                    drawRun(run, series: series, context: &context, rect: rect); run.removeAll(keepingCapacity: true)
                }
                previous = point
            }
            drawRun(run, series: series, context: &context, rect: rect)
        }
    }

    private func drawRun(_ points: [CGPoint], series: Int, context: inout GraphicsContext, rect: CGRect) {
        guard let first = points.first, let last = points.last else { return }
        let color = data.colors[series]
        if style == .bars {
            let width = max(1, rect.width / CGFloat(MonitorSampler.historyCapacity) - 2)
            for point in points {
                context.fill(Path(roundedRect: CGRect(x: point.x - width / 2, y: point.y, width: width, height: max(1, rect.maxY - point.y)), cornerSize: CGSize(width: 2, height: 2)), with: .color(color.opacity(0.75)))
            }
        } else if points.count == 1 {
            context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)), with: .color(color))
        } else {
            var line = Path()
            if data.module == .memory {
                line.move(to: first)
                for index in 1..<points.count {
                    line.addLine(to: CGPoint(x: points[index].x, y: points[index - 1].y))
                    line.addLine(to: points[index])
                }
            } else { line = MonitorSparkline.smoothPath(points, in: rect) }
            if style == .area && series == 0 {
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                area.addLine(to: CGPoint(x: first.x, y: rect.maxY)); area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.20), color.opacity(0.02)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
            }
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: compact ? 1.3 : 1.8, lineCap: .round, lineJoin: .round, dash: series == 0 ? [] : [5, 2]))
        }
    }

    private func xPosition(_ time: Double, rect: CGRect) -> CGFloat {
        rect.minX + CGFloat((time - data.start) / (data.interval * Double(MonitorSampler.historyCapacity - 1))) * rect.width
    }
    private func nearest(at x: CGFloat, width: CGFloat) -> MonitorTrendPoint? {
        let time = data.start + min(max(Double((x - 3) / max(width - 6, 1)), 0), 1) * (data.end - data.start)
        return data.visiblePoints.min(by: { abs($0.time - time) < abs($1.time - time) })
    }
    private func pin(_ point: MonitorTrendPoint?) {
        if fixed != point { fixed = point }
        selection?.chartPins[data.key] = point
    }
    private func unpin() { fixed = nil; hovered = nil; selection?.chartPins[data.key] = nil }
    private func restoreSelection() { hovered = nil; fixed = selection?.chartPins[data.key]; scale = data.suggestedUpper; activeKey = data.key }
    private func timeText(_ time: Double) -> String {
        Date(timeIntervalSince1970: time).formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2)))
    }
}

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
            let lower = min(p1.y, p2.y)
            let upper = max(p1.y, p2.y)
            c1.x = min(max(c1.x, p1.x), p2.x)
            c2.x = min(max(c2.x, p1.x), p2.x)
            c1.y = min(max(c1.y, lower), upper)
            c2.y = min(max(c2.y, lower), upper)
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
