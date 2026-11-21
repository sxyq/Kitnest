import SwiftUI

enum IslandChartStyle: String, CaseIterable, Identifiable {
    case area = "面积", line = "曲线", bars = "柱状"
    var id: String { rawValue }
}

/// 组件只负责尺寸组织，图表与完整监测页使用同一时间、读数和交互实现。
struct IslandMonitorChart: View {
    let metric: IslandMetric
    var style = IslandChartStyle.area
    var previewOnly = false
    var tint: Color? = nil
    var size: IslandWidgetSize? = nil
    var controller: IslandController? = nil
    @Environment(\.isSettingsPreview) private var isSettingsPreview

    var body: some View {
        Group {
            if previewOnly || isSettingsPreview {
                IslandMonitorWidget(data: MonitorTrendData(module: MonitorModuleID(rawValue: metric.rawValue)!,
                    history: MonitorDetailPreviewValues.fixed.history, tint: tint),
                    style: style, size: size, controller: controller,
                    metric: metric, previewOnly: true)
            } else {
                LiveIslandMonitorWidget(metric: metric, tint: tint, style: style, size: size, controller: controller)
            }
        }
    }
}

private struct LiveIslandMonitorWidget: View {
    let metric: IslandMetric
    let tint: Color?
    let style: IslandChartStyle
    let size: IslandWidgetSize?
    let controller: IslandController?
    @ObservedObject private var sampler = MonitorSampler.shared

    var body: some View {
        IslandMonitorWidget(data: MonitorTrendData(module: MonitorModuleID(rawValue: metric.rawValue)!,
            history: sampler.history, tint: tint), style: style, size: size, controller: controller,
            metric: metric, previewOnly: false)
    }
}

private struct IslandMonitorWidget: View {
    let data: MonitorTrendData
    let style: IslandChartStyle
    let size: IslandWidgetSize?
    let controller: IslandController?
    /// v270：点击整张卡 → 打开该指标详情（不是回到泛化面板）。
    var metric: IslandMetric? = nil
    var previewOnly = false
    @Stored private var widgetStyle = IslandChartStyle.area

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if size == .square {
                Picker("图形", selection: $widgetStyle) {
                    ForEach(IslandChartStyle.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            MonitorTrendChart(data: data, compact: true, showAxes: false,
                style: size == .square ? widgetStyle : style,
                interaction: {
                    if $0 { controller?.beginInteraction() } else { controller?.endInteraction() }
                })
                // 只给图表本体挂点击：样式 Picker 与拖动游标都还能正常用。
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !previewOnly, let metric else { return }
                    controller?.openMonitorDetail(metric)
                }
                .help(previewOnly ? "" : "点击查看 \(metric?.title ?? "") 详情")
        }
    }
}
