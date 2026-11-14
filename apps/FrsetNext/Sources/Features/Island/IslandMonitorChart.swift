import SwiftUI

enum IslandChartStyle: String, CaseIterable, Identifiable {
    case area = "面积", line = "曲线", bars = "柱状"
    var id: String { rawValue }
}

/// 首页与详情共享正式监测曲线；鼠标定位状态只更新当前图表。
struct IslandMonitorChart: View {
    let metric: IslandMetric
    var style = IslandChartStyle.area
    var seconds = 60
    var compact = false
    @Stored private var cursor: Int? = nil
    @Stored private var pinned = false
    @Environment(\.isFocused) private var focused
    private var values: [Double] { seconds == 30 ? Array(metric.values.suffix(12)) : metric.values }

    var body: some View {
        let values = values
        let index = cursor ?? values.count - 1
        VStack(spacing: compact ? 2 : 6) {
            HStack {
                Text(metric.format(values[index])).monospacedDigit().foregroundStyle(metric.color)
                Spacer()
                Text(cursor == nil ? "当前" : "−\(Int(Double(values.count - 1 - index) / Double(values.count - 1) * Double(seconds))) 秒\(pinned ? " · 固定" : "")")
                    .foregroundStyle(.secondary)
            }.font(.system(size: Theme.TextSize.caption))
            HStack(spacing: 8) {
                if !compact {
                    VStack {
                        Text(metric.upperBound.formatted(.number.precision(.fractionLength(0))))
                        Spacer()
                        Text((metric.upperBound / 2).formatted(.number.precision(.fractionLength(0))))
                        Spacer()
                        Text("0")
                    }.font(.system(size: Theme.TextSize.micro)).foregroundStyle(.secondary).frame(width: 25, alignment: .trailing)
                }
                GeometryReader { geometry in
                    ZStack {
                        Path { path in
                            for row in 0...2 {
                                let y = geometry.size.height * CGFloat(row) / 2
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }.stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                        plot(values, size: geometry.size)
                        if cursor != nil {
                            let point = CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * geometry.size.width,
                                                y: geometry.size.height * (1 - values[index] / metric.upperBound))
                            Path { path in
                                path.move(to: CGPoint(x: point.x, y: 0))
                                path.addLine(to: CGPoint(x: point.x, y: geometry.size.height))
                            }.stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                            Circle().fill(metric.color).frame(width: 6, height: 6).position(point)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if !pinned {
                            switch phase {
                            case .active(let point): cursor = self.index(at: point.x, width: geometry.size.width)
                            case .ended: cursor = nil
                            }
                        }
                    }
                    .onTapGesture { pinned.toggle(); if cursor == nil { cursor = values.count - 1 } }
                    .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                        cursor = self.index(at: value.location.x, width: geometry.size.width)
                        pinned = true
                    })
                }
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? metric.color : .clear, lineWidth: 1))
                .focusable()
                .onMoveCommand { direction in
                    if direction == .left || direction == .right {
                        cursor = min(max(index + (direction == .left ? -1 : 1), 0), values.count - 1)
                        pinned = true
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(metric.title)\(style.rawValue)图，方向键查看时间点，点击固定数值")
                .accessibilityValue(metric.format(values[index]))
            }
            if !compact {
                HStack {
                    Text("−\(seconds) 秒")
                    Spacer()
                    Text("−\(seconds / 2) 秒")
                    Spacer()
                    Text("现在")
                }.font(.system(size: Theme.TextSize.micro)).foregroundStyle(.secondary).padding(.leading, 33)
            }
        }
        .onChange(of: metric) { _ in cursor = nil; pinned = false }
        .onChange(of: seconds) { _ in cursor = nil; pinned = false }
    }

    private func index(at x: CGFloat, width: CGFloat) -> Int {
        min(max(Int((x / width * CGFloat(values.count - 1)).rounded()), 0), values.count - 1)
    }

    @ViewBuilder private func plot(_ values: [Double], size: CGSize) -> some View {
        switch style {
        case .area:
            MonitorAreaSparkline(values: values, color: metric.color, upperBound: metric.upperBound, lineWidth: compact ? 1.2 : 1.8)
        case .line:
            MonitorSparkline(values: values, upperBound: metric.upperBound)
                .stroke(metric.color, style: StrokeStyle(lineWidth: compact ? 1.2 : 1.8, lineCap: .round, lineJoin: .round))
        case .bars:
            HStack(alignment: .bottom, spacing: compact ? 2 : 4) {
                ForEach(values.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(metric.color.opacity(cursor == index ? 1 : 0.65))
                        .frame(height: size.height * values[index] / metric.upperBound)
                }
            }.frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}
