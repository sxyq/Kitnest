import SwiftUI

enum IslandChartStyle: String, CaseIterable, Identifiable {
    case area = "面积", line = "曲线", bars = "柱状"
    var id: String { rawValue }
}

/// 只消费现有采样器；固定曲线仅用于设置预览。
struct IslandMonitorChart: View {
    let metric: IslandMetric
    var style = IslandChartStyle.area
    var seconds = 60
    var compact = false
    var previewOnly = false
    var tint: Color? = nil
    @ObservedObject private var sampler = MonitorSampler.shared
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.isFocused) private var focused
    @Stored private var cursor: Int? = nil
    @Stored private var pinned = false

    private var preview: Bool { previewOnly || isSettingsPreview }
    private var color: Color { tint ?? metric.color }
    private var values: [Double] { Self.values(for: metric, sampler: sampler, preview: preview, count: seconds) }
    private var upperBound: Double { Self.upperBound(for: metric, values: values, sampler: sampler, preview: preview) }

    static func values(for metric: IslandMetric, sampler: MonitorSampler, preview: Bool, count: Int = 60) -> [Double] {
        if preview { return count == 30 ? Array(metric.values.suffix(12)) : metric.values }
        guard sampler.isRunning, sampler.tick > 0 else { return [] }
        let history = sampler.history
        let values: [Double]
        switch metric {
        case .cpu: values = history.cpu.map { $0 * 100 }
        case .gpu:
            values = StatsDataProvider.shared.current.gpuUsage >= 0 ? history.gpu.map { $0 * 100 } : []
        case .memory:
            values = history.memory.map { $0 * Double(sampler.sample.memoryTotal) / 1_073_741_824 }
        case .network: values = history.netDownload.map { $0 / 1024 }
        case .power: values = sampler.sample.powerWatts == nil ? [] : history.power
        case .battery: values = sampler.sample.batteryLevel.map { [$0 * 100] } ?? []
        }
        return Array(values.suffix(count))
    }

    static func upperBound(for metric: IslandMetric, values: [Double], sampler: MonitorSampler, preview: Bool) -> Double {
        if preview { return metric.upperBound }
        switch metric {
        case .cpu, .gpu, .battery: return 100
        case .memory: return max(Double(sampler.sample.memoryTotal) / 1_073_741_824, 1)
        case .network, .power: return max((values.max() ?? 0) * 1.15, 1)
        }
    }

    var body: some View {
        let values = values
        VStack(spacing: compact ? 2 : 6) {
            if values.isEmpty {
                Text(sampler.isRunning ? "暂无\(metric.title)读数" : "监测已关闭")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                let index = min(cursor ?? values.count - 1, values.count - 1)
                HStack {
                    Text(metric.format(values[index])).monospacedDigit().foregroundStyle(color)
                    Spacer(minLength: 2)
                    if !compact { Text(positionLabel(index, count: values.count)).foregroundStyle(.secondary) }
                }.font(.system(size: Theme.TextSize.caption))
                HStack(spacing: 8) {
                    if !compact {
                        VStack {
                            Text(upperBound.formatted(.number.precision(.fractionLength(1))))
                            Spacer()
                            Text((upperBound / 2).formatted(.number.precision(.fractionLength(1))))
                            Spacer()
                            Text("0")
                        }.font(.system(size: Theme.TextSize.micro)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
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
                            if cursor != nil || values.count == 1 {
                                let point = CGPoint(x: xPosition(index, count: values.count) * geometry.size.width,
                                                    y: geometry.size.height * (1 - values[index] / upperBound))
                                Path { path in
                                    path.move(to: CGPoint(x: point.x, y: 0))
                                    path.addLine(to: CGPoint(x: point.x, y: geometry.size.height))
                                }.stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                                Circle().fill(color).frame(width: 6, height: 6).position(point)
                            }
                        }
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if !pinned {
                                switch phase {
                                case .active(let point): cursor = self.index(at: point.x, width: geometry.size.width, count: values.count)
                                case .ended: cursor = nil
                                }
                            }
                        }
                        .onTapGesture { pinned.toggle(); if cursor == nil { cursor = values.count - 1 } }
                        .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { value in
                            cursor = self.index(at: value.location.x, width: geometry.size.width, count: values.count)
                            pinned = true
                        })
                    }
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? color : .clear, lineWidth: 1))
                    .focusable()
                    .onMoveCommand { direction in
                        if direction == .left || direction == .right {
                            cursor = min(max(index + (direction == .left ? -1 : 1), 0), values.count - 1)
                            pinned = true
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(metric.title)\(style.rawValue)图，方向键查看采样，点击固定数值")
                    .accessibilityValue(metric.format(values[index]))
                }
                if !compact {
                    HStack {
                        Text(preview ? "−\(seconds) 秒" : "最近 \(values.count) 个采样")
                        Spacer()
                        Text("现在")
                    }.font(.system(size: Theme.TextSize.micro)).foregroundStyle(.secondary).padding(.leading, 38)
                }
            }
        }
        .onChange(of: metric) { _ in cursor = nil; pinned = false }
        .onChange(of: seconds) { _ in cursor = nil; pinned = false }
    }

    private func positionLabel(_ index: Int, count: Int) -> String {
        let position = index == count - 1 ? "当前" : preview
            ? "−\(Int(Double(count - 1 - index) / Double(max(count - 1, 1)) * Double(seconds))) 秒"
            : "前 \(count - 1 - index) 个采样"
        return position + (pinned ? " · 固定" : "")
    }

    private func xPosition(_ index: Int, count: Int) -> CGFloat {
        count == 1 ? 1 : CGFloat(index) / CGFloat(count - 1)
    }

    private func index(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        min(max(Int((x / max(width, 1) * CGFloat(count - 1)).rounded()), 0), count - 1)
    }

    @ViewBuilder private func plot(_ values: [Double], size: CGSize) -> some View {
        switch style {
        case .area:
            MonitorAreaSparkline(values: values, color: color, upperBound: upperBound, lineWidth: compact ? 1.2 : 1.8)
        case .line:
            MonitorSparkline(values: values, upperBound: upperBound)
                .stroke(color, style: StrokeStyle(lineWidth: compact ? 1.2 : 1.8, lineCap: .round, lineJoin: .round))
        case .bars:
            HStack(alignment: .bottom, spacing: compact ? 2 : 4) {
                ForEach(values.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(cursor == index ? 1 : 0.65))
                        .frame(height: size.height * values[index] / upperBound)
                }
            }.frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct IslandMonitorPage: View {
    @ObservedObject var controller: IslandController
    @Binding var selectedMetric: IslandMetric
    var previewOnly: Bool
    @ObservedObject private var sampler = MonitorSampler.shared
    @Stored private var chartStyle = IslandChartStyle.area
    @Stored private var chartCount = 60

    var body: some View {
        HStack(spacing: 10) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(controller.metricOrder) { metric in
                        let values = IslandMonitorChart.values(for: metric, sampler: sampler, preview: previewOnly)
                        let color = controller.configuration.color(for: metric)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Button { selectedMetric = metric } label: { Text(metric.title).font(.system(size: 11)) }
                                    .buttonStyle(IslandButtonStyle())
                                Spacer(minLength: 0)
                                Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.secondary)
                                    .draggable("metric:" + metric.rawValue)
                            }
                            Button { selectedMetric = metric } label: {
                                Text(values.last.map(metric.format) ?? "暂无读数")
                                    .font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(IslandButtonStyle())
                            MonitorAreaSparkline(values: values, color: color,
                                upperBound: IslandMonitorChart.upperBound(for: metric, values: values, sampler: sampler, preview: previewOnly))
                                .frame(height: 18).allowsHitTesting(false)
                        }.padding(10)
                            .background(selectedMetric == metric ? color.opacity(0.10) : IslandLayout.cardFill)
                            .glassCard(radius: IslandLayout.cardRadius, fill: .clear, stroke: selectedMetric == metric ? color.opacity(0.55) : IslandLayout.cardStroke)
                            .dropDestination(for: String.self) { values, _ in
                                guard let value = values.first, value.hasPrefix("metric:"),
                                      let source = IslandMetric(rawValue: String(value.dropFirst(7))) else { return false }
                                controller.metricOrder.islandMove(source, to: controller.metricOrder.firstIndex(of: metric)!)
                                return true
                            }
                    }
                }
            }.islandGlowClip().frame(width: 220)
            VStack(spacing: 10) {
                HStack {
                    Text(selectedMetric.title + " · " + selectedMetric.unit).fontWeight(.medium)
                    Spacer()
                    Text(previewOnly ? "设置预览" : "现有系统采样").foregroundStyle(.secondary)
                }.font(.system(size: 11))
                HStack(spacing: 12) {
                    Picker("图形", selection: $chartStyle) {
                        ForEach(IslandChartStyle.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                    Picker("范围", selection: $chartCount) {
                        Text(previewOnly ? "30 秒" : "30 点").tag(30)
                        Text(previewOnly ? "60 秒" : "60 点").tag(60)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 112)
                }
                IslandMonitorChart(metric: selectedMetric, style: chartStyle, seconds: chartCount,
                    previewOnly: previewOnly, tint: controller.configuration.color(for: selectedMetric))
                let values = IslandMonitorChart.values(for: selectedMetric, sampler: sampler, preview: previewOnly, count: chartCount)
                HStack {
                    statistic("平均", value: values.isEmpty ? "—" : selectedMetric.format(values.reduce(0, +) / Double(values.count)))
                    statistic("峰值", value: values.max().map(selectedMetric.format) ?? "—")
                    statistic("当前", value: values.last.map(selectedMetric.format) ?? "—")
                }
                Text("悬停查看 · 点击固定 · 拖动或方向键定位").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassCard(radius: IslandLayout.cardRadius, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
        }
    }

    private func statistic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().fontWeight(.medium)
        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
    }
}
