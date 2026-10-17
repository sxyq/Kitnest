import AppKit
import SwiftUI

// MARK: - 原版 Stats 模块面板（性能监测页正文，1:1 版式）
//
// 版式依据：/tmp/o_cpu*.png、o_mem.png、o_gpu.png、o_disk.png、o_network.png、
// o_sensor.png（2026-10-17 原版 Frset 1.3.12 实机逐标签截图，400×700 面板）。
//
// 与旧 MonitorDetailView（292 宽 popover 版）并存：
//   · 性能页（400 宽，StatsPageView）→ 本文件的 StatsModulePage
//   · 菜单栏模块状态项 popover（292 宽）→ 旧 MonitorDetailView
//
// 版式要点（逐项对照原版）：
//   分段环 = 红(系统)/蓝(用户)/灰(空闲)，中心大号百分比 + 小字说明；
//   分区标题 = 居中文字 + 两侧细线；键值行 = 左标签灰 12 / 右数值 13 等宽；
//   进程表 = 表头「进程 / 用量」+ 行（应用图标 + 名称 + 右值）。

public struct StatsModulePage: View {
    public let module: MonitorModuleID

    public init(module: MonitorModuleID) {
        self.module = module
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch module {
            case .cpu, .power: CPUStatsPanel()
            case .memory: MemoryStatsPanel()
            case .gpu: GPUStatsPanel()
            case .disk: DiskStatsPanel()
            case .network: NetworkStatsPanel()
            case .sensors: SensorsStatsPanel()
            case .battery: BatteryStatsPanel()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 通用组件

/// 环形进度（单色 / 分段）。原版线宽约 9pt（90pt 环）、7pt（60pt 环）。
struct StatsRing: View {
    var segments: [(value: Double, color: Color)]
    var lineWidth: CGFloat = 9
    var trackOpacity: Double = 0.12

    init(segments: [(value: Double, color: Color)], lineWidth: CGFloat = 9, trackOpacity: Double = 0.12) {
        self.segments = segments
        self.lineWidth = lineWidth
        self.trackOpacity = trackOpacity
    }

    init(value: Double, color: Color, lineWidth: CGFloat = 9) {
        self.segments = [(max(0, min(1, value)), color)]
        self.lineWidth = lineWidth
        self.trackOpacity = 0.12
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = (side - lineWidth) / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(trackOpacity), lineWidth: lineWidth)
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let start = segments.prefix(index).reduce(0) { $0 + max(0, $1.value) }
                    Circle()
                        .trim(from: max(0, min(1, start)),
                              to: max(0, min(1, start + segment.value)))
                        .stroke(segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: side, height: side)
            .position(x: center.x, y: center.y)
            .environment(\.statsRingRadius, radius)
        }
    }
}

private struct StatsRingRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = 40
}

extension EnvironmentValues {
    var statsRingRadius: CGFloat {
        get { self[StatsRingRadiusKey.self] }
        set { self[StatsRingRadiusKey.self] = newValue }
    }
}

/// 内存页左侧的半圆仪表（绿→黄→红 + 指针 + 下方状态文字）。
struct StatsHalfGauge: View {
    /// 0...1
    var value: Double
    var caption: String
    var captionColor: Color = .secondary

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lineWidth: CGFloat = 8
            let radius = min(w / 2, h) - lineWidth / 2
            let center = CGPoint(x: w / 2, y: h - 4)
            ZStack {
                // 三段底色：绿 / 黄 / 红
                ForEach(Array(gaugeSegments.enumerated()), id: \.offset) { index, seg in
                    Path { path in
                        path.addArc(center: center, radius: radius,
                                    startAngle: .degrees(180 + seg.start * 180),
                                    endAngle: .degrees(180 + seg.end * 180),
                                    clockwise: false)
                    }
                    .stroke(seg.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .opacity(index == gaugeIndex ? 1 : 0.35)
                }
                // 指针
                Path { path in
                    path.move(to: center)
                    let angle = Angle.degrees(180 + max(0, min(1, value)) * 180)
                    path.addLine(to: CGPoint(x: center.x + cos(angle.radians) * (radius - 2),
                                             y: center.y + sin(angle.radians) * (radius - 2)))
                }
                .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .position(center)
            }
        }
        .overlay(alignment: .bottom) {
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(captionColor)
                .offset(y: 14)
        }
    }

    private var gaugeSegments: [(start: Double, end: Double, color: Color)] {
        [
            (0.0, 0.5, Color(red: 0.30, green: 0.78, blue: 0.35)),
            (0.5, 0.75, Color(red: 0.96, green: 0.80, blue: 0.20)),
            (0.75, 1.0, Color(red: 0.92, green: 0.26, blue: 0.28))
        ]
    }

    private var gaugeIndex: Int {
        if value < 0.5 { return 0 }
        if value < 0.75 { return 1 }
        return 2
    }
}

/// 图例行：色点 + 标签 +（可选）右侧数值
struct StatsLegendRow: View {
    var color: Color
    var label: String
    var value: String
    var valueColor: Color = .primary
    var showsDot: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if showsDot {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 9, height: 9)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(showsDot ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}

/// 面积图（原版「负载历史 / 使用历史 / 速率历史」用）：细线 + 渐变填充。
struct StatsHistoryChart: View {
    var values: [Double]
    var color: Color
    var upperBound: Double? = nil
    var height: CGFloat = 74

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            MonitorAreaSparkline(values: values, color: color, upperBound: upperBound)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
        .frame(height: height)
    }
}

/// 双线图（网络/磁盘读写历史）。
struct StatsHistoryDualChart: View {
    var primaryValues: [Double]
    var secondaryValues: [Double]
    var primaryColor: Color
    var secondaryColor: Color
    var height: CGFloat = 74

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            ZStack {
                MonitorAreaSparkline(values: primaryValues, color: primaryColor)
                MonitorSparkline(values: secondaryValues)
                    .stroke(secondaryColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .frame(height: height)
    }
}

/// 进程表（原版「高占用进程」）：表头 + 行（应用图标 + 名称 + 右侧一/两列数值）
struct StatsProcTable: View {
    struct Column {
        var title: String
        var color: Color?
    }

    var title: String
    var columns: [Column]
    var items: [StatsProcItem]
    var subtitle: (StatsProcItem) -> String? = { _ in nil }
    var values: (StatsProcItem) -> [String]

    var body: some View {
        VStack(spacing: 6) {
            MonitorSectionTitle(title)
            HStack(spacing: 8) {
                Text("进程")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    if let color = column.color {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: 9, height: 9)
                            .frame(width: 86, alignment: .trailing)
                    } else {
                        Text(column.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 86, alignment: .trailing)
                    }
                }
            }
            ForEach(items) { item in
                HStack(spacing: 8) {
                    StatsAppIcon(name: item.name, size: 16)
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = subtitle(item), !note.isEmpty {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                    ForEach(Array(values(item).enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.system(size: 12).monospacedDigit())
                            .lineLimit(1)
                            .frame(width: 86, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// 进程图标：优先真实 app 图标（按可执行名反查 bundle），否则用通用方块（原版观感）。
struct StatsAppIcon: View {
    var name: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = Self.cachedIcon(for: name) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
    }

    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    private static func cachedIcon(for name: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        guard let icon = resolveIcon(name) else { return nil }
        cache[name] = icon
        return icon
    }

    private static func resolveIcon(_ name: String) -> NSImage? {
        // 常见进程名 → bundle 路径（只做低成本匹配，避免每次遍历 /Applications）
        let known: [String: String] = [
            "ChatGPT": "/Applications/ChatGPT.app",
            "Microsoft Edge": "/Applications/Microsoft Edge.app",
            "Microsoft Edge Helper": "/Applications/Microsoft Edge.app",
            "Codex": "/Applications/Codex.app",
            "Frset": "/Applications/Frset.app",
            "WorkBuddy": "/Applications/WorkBuddy.app",
            "WorkBuddy Helper": "/Applications/WorkBuddy.app",
            "Electron": "/Applications/Electron.app",
            "ZTools": "/Applications/ZTools.app"
        ]
        for (key, path) in known where name.hasPrefix(key) {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        return nil
    }
}

/// 核心占用方块条（原版「集群占用」上方：每核一个圆角块，性能核橙 / 能效核青，亮度=占用）
struct StatsCoreGrid: View {
    var fractions: [Double]
    var performanceCount: Int

    var body: some View {
        GeometryReader { geo in
            let count = max(1, fractions.count)
            let spacing: CGFloat = 3
            let width = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            HStack(spacing: spacing) {
                ForEach(Array(fractions.enumerated()), id: \.offset) { index, value in
                    let isPerformance = index < performanceCount
                    let color = isPerformance
                        ? Color(red: 0.98, green: 0.62, blue: 0.24)
                        : Color(red: 0.30, green: 0.78, blue: 0.78)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.28 + 0.72 * max(0, min(1, value))))
                        .frame(width: max(3, width))
                }
            }
        }
        .frame(height: 30)
    }
}

// MARK: - CPU

private struct CPUStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        return VStack(alignment: .leading, spacing: 12) {
            // 温度环 + 总占用分段环 + 图例（系统/用户/空闲/启动时间）
            HStack(alignment: .center, spacing: 16) {
                if let temperature = primaryTemperature() {
                    ZStack {
                        StatsRing(value: min(max(temperature / 110, 0), 1),
                                  color: Color(red: 0.98, green: 0.62, blue: 0.24),
                                  lineWidth: 8)
                        Text("\(Int(temperature.rounded()))°")
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    }
                    .frame(width: 62, height: 62)
                }
                ZStack {
                    StatsRing(segments: [
                        (max(0, min(1, sample.systemCPU)), MonitorColors.system),
                        (max(0, min(1, sample.userCPU)), MonitorColors.user),
                        (max(0, min(1, sample.idleCPU)), MonitorColors.idle)
                    ], lineWidth: 10)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(sample.cpuUsage))
                            .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        Text("总占用")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 7) {
                    StatsLegendRow(color: MonitorColors.system, label: "系统",
                                   value: MonitorFormat.percent(sample.systemCPU))
                    StatsLegendRow(color: MonitorColors.user, label: "用户",
                                   value: MonitorFormat.percent(sample.userCPU))
                    StatsLegendRow(color: MonitorColors.idle, label: "空闲",
                                   value: MonitorFormat.percent(sample.idleCPU))
                    HStack(spacing: 8) {
                        Text("启动时间")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(Self.uptimeText())
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            MonitorSectionTitle("负载历史")
            StatsHistoryChart(values: sampler.history.cpu, color: MonitorColors.user, upperBound: 1, height: 76)

            // 每核方块条（原版紧贴历史图下方，无标题）
            if !sample.perCore.isEmpty {
                StatsCoreGrid(fractions: sample.perCore,
                              performanceCount: max(0, stats.cpuSuperCores > 0 ? stats.cpuSuperCores : sample.perCore.count / 2))
                    .padding(.top, -4)
            }

            if stats.cpuSuperCores > 0 {
                MonitorSectionTitle("集群占用")
                StatsLegendRow(color: Color(red: 0.98, green: 0.62, blue: 0.24), label: "超级核心",
                               value: MonitorFormat.percent(stats.clusterSuperUsage))
                StatsLegendRow(color: Color(red: 0.30, green: 0.78, blue: 0.78), label: "能效核心",
                               value: MonitorFormat.percent(stats.clusterEffUsage))
            }

            MonitorSectionTitle("平均负载")
            HStack(spacing: 10) {
                loadCell("1 分钟", value: sample.loadAverage1m)
                loadCell("5 分钟", value: sample.loadAverage5m)
                loadCell("15 分钟", value: sample.loadAverage15m)
            }

            if !stats.procCPU.isEmpty {
                StatsProcTable(title: "高占用进程",
                               columns: [.init(title: "用量", color: nil)],
                               items: Array(stats.procCPU.prefix(5))) { item in
                    [String(format: "%.0f%%", item.cpu)]
                }
            }
        }
    }

    private func loadCell(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(MonitorFormat.load(value))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// CPU 温度：优先 STATS 全量 SMC 扫描（官方名表，M 系列 key 才读得到），
    /// 回退到 MonitorReader 的固定 key 表（老机型）。
    private func primaryTemperature() -> Double? {
        let stats = StatsDataProvider.shared.current
        if let hottest = stats.calcHottestCPU ?? stats.calcAverageCPU { return hottest }
        let cpuGroup = stats.sensors.filter { $0.category == 0 && $0.group == 1 }.map(\.value)
        if let peak = cpuGroup.max() { return peak }
        let temperatures = sampler.sample.temperatures
        for key in ["CPU 包温", "CPU 二极管", "CPU 邻近"] {
            if let value = temperatures[key] { return value }
        }
        return temperatures.values.first
    }

    static func uptimeText() -> String {
        let up = ProcessInfo.processInfo.systemUptime
        let days = Int(up) / 86400
        let hours = (Int(up) % 86400) / 3600
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        let minutes = (Int(up) % 3600) / 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
    }
}

// MARK: - 内存

private struct MemoryStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        let total = max(1, Double(stats.memTotal > 0 ? stats.memTotal : sample.memoryTotal))
        let used = Double(stats.memUsed > 0 ? stats.memUsed : sample.memoryUsed)
        let compressed = Double(stats.memCompressed)
        let wired = Double(stats.memWired)
        let appBytes = max(0, used - compressed - wired)
        let free = max(0, total - used)
        let pressure = max(0, min(1, used / total))
        let level = stats.memPressureLevel

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                StatsHalfGauge(value: pressure, caption: pressureCaption(level), captionColor: pressureColor(level))
                    .frame(width: 92, height: 62)

                ZStack {
                    StatsRing(segments: [
                        (max(0, min(1, used / total)), Color(red: 0.98, green: 0.35, blue: 0.38))
                    ], lineWidth: 10)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(used / total))
                            .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        Text("已用")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 7) {
                    StatsLegendRow(color: .clear, label: "已用",
                                   value: MonitorFormat.bytes(UInt64(used)), showsDot: false)
                    StatsLegendRow(color: .clear, label: "总量",
                                   value: MonitorFormat.bytes(UInt64(total)), showsDot: false)
                    StatsLegendRow(color: .clear, label: "交换区",
                                   value: MonitorFormat.bytes(stats.memSwapUsed > 0 ? stats.memSwapUsed : sample.swapUsed),
                                   showsDot: false)
                    StatsLegendRow(color: .clear, label: "内存压力", value: pressureCaption(level),
                                   valueColor: pressureColor(level), showsDot: false)
                }
                .frame(maxWidth: .infinity)
            }

            MonitorSectionTitle("使用历史")
            StatsHistoryChart(values: sampler.history.memory, color: MonitorColors.user, upperBound: 1, height: 72)

            MonitorSectionTitle("内存构成")
            GeometryReader { geo in
                HStack(spacing: 0) {
                    segment(width: geo.size.width * appBytes / total, color: MonitorColors.user)
                    segment(width: geo.size.width * wired / total, color: Color(red: 0.98, green: 0.62, blue: 0.24))
                    segment(width: geo.size.width * compressed / total, color: Color(red: 0.98, green: 0.35, blue: 0.38))
                    segment(width: geo.size.width * free / total, color: Color.primary.opacity(0.16))
                }
            }
            .frame(height: 10)

            VStack(alignment: .leading, spacing: 5) {
                StatsLegendRow(color: MonitorColors.user, label: "App 内存", value: MonitorFormat.bytes(UInt64(max(0, appBytes))))
                StatsLegendRow(color: Color(red: 0.98, green: 0.62, blue: 0.24), label: "联动内存", value: MonitorFormat.bytes(UInt64(wired)))
                StatsLegendRow(color: Color(red: 0.98, green: 0.35, blue: 0.38), label: "压缩内存", value: MonitorFormat.bytes(UInt64(compressed)))
                StatsLegendRow(color: Color.primary.opacity(0.16), label: "可用", value: MonitorFormat.bytes(UInt64(free)))
            }

            if !stats.procMem.isEmpty {
                StatsProcTable(title: "高占用进程",
                               columns: [.init(title: "内存", color: nil)],
                               items: Array(stats.procMem.prefix(5)),
                               subtitle: { _ in nil }) { item in
                    [MonitorFormat.bytes(UInt64(max(0, item.memBytes)))]
                }
            }
        }
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, width))
    }

    private func pressureCaption(_ level: Int32) -> String {
        switch level {
        case 2: return "警告"
        case 4: return "严重"
        case 1: return "正常"
        default: return sampler.sample.memoryPressure < 0.6 ? "正常" : "警告"
        }
    }

    private func pressureColor(_ level: Int32) -> Color {
        switch level {
        case 2: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case 4: return MonitorColors.system
        case 1: return .primary
        default: return sampler.sample.memoryPressure < 0.6 ? .primary : Color(red: 0.95, green: 0.55, blue: 0.15)
        }
    }
}

// MARK: - GPU

private struct GPUStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared

    var body: some View {
        let stats = StatsDataProvider.shared.current
        let usage = stats.gpuUsage >= 0 ? stats.gpuUsage / 100 : 0
        let renderer = stats.gpuRenderer >= 0 ? stats.gpuRenderer / 100 : usage
        let tiler = stats.gpuTiler >= 0 ? stats.gpuTiler / 100 : usage

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 26) {
                ring(value: usage, size: 66, fontSize: 15)
                ring(value: renderer, size: 92, fontSize: 19)
                ring(value: tiler, size: 66, fontSize: 15)
            }
            .frame(maxWidth: .infinity)

            MonitorSectionTitle("负载历史")
            StatsHistoryChart(values: sampler.history.gpu, color: MonitorColors.user, upperBound: 1, height: 76)

            MonitorSectionTitle("详细信息")
            StatsLegendRow(color: .clear, label: "型号", value: stats.gpuModel.isEmpty ? "—" : stats.gpuModel, showsDot: false)
            StatsLegendRow(color: .clear, label: "利用率", value: MonitorFormat.percent(usage), showsDot: false)
            StatsLegendRow(color: .clear, label: "渲染利用率", value: MonitorFormat.percent(renderer), showsDot: false)
            StatsLegendRow(color: .clear, label: "Tiler 利用率", value: MonitorFormat.percent(tiler), showsDot: false)
        }
    }

    private func ring(value: Double, size: CGFloat, fontSize: CGFloat) -> some View {
        ZStack {
            StatsRing(value: value, color: MonitorColors.user, lineWidth: size > 80 ? 10 : 8)
            Text(MonitorFormat.percent(value))
                .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 磁盘

private struct DiskStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @Stored private var showsDetails = true

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        let used = stats.diskTotalBytes > stats.diskFreeBytes ? stats.diskTotalBytes - stats.diskFreeBytes : 0
        let ratio = stats.diskTotalBytes > 0 ? Double(used) / Double(stats.diskTotalBytes) : 0

        return VStack(alignment: .leading, spacing: 12) {
            // 卷名行（原版：「Macintosh HD                    ⌄」）
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) { showsDetails.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(stats.diskModel.isEmpty ? "Macintosh HD" : stats.diskModel)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsDetails ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDetails {
                // 图例（蓝=读 / 红=写）+ 双线历史
                HStack(spacing: 12) {
                    legendValue(color: Color(red: 0.20, green: 0.52, blue: 0.98),
                                value: MonitorFormat.rate(sample.diskRead))
                    Spacer(minLength: 4)
                    legendValue(color: Color(red: 0.95, green: 0.27, blue: 0.30),
                                value: MonitorFormat.rate(sample.diskWrite))
                    Spacer(minLength: 4)
                }
                StatsHistoryDualChart(primaryValues: sampler.history.diskRead,
                                      secondaryValues: sampler.history.diskWrite,
                                      primaryColor: Color(red: 0.20, green: 0.52, blue: 0.98),
                                      secondaryColor: Color(red: 0.95, green: 0.27, blue: 0.30),
                                      height: 64)

                // 容量条
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(red: 0.20, green: 0.52, blue: 0.98))
                            .frame(width: geo.size.width * ratio)
                    }
                }
                .frame(height: 8)

                HStack {
                    Text("\(MonitorFormat.bytes(stats.diskTotalBytes)) 中剩余 \(MonitorFormat.bytes(stats.diskFreeBytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(MonitorFormat.percent(ratio))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }

                VStack(alignment: .leading, spacing: 6) {
                    StatsLegendRow(color: .clear, label: "总读取量", value: MonitorFormat.bytes(stats.smart?.totalRead ?? 0), showsDot: false)
                    StatsLegendRow(color: .clear, label: "总写入量", value: MonitorFormat.bytes(stats.smart?.totalWritten ?? 0), showsDot: false)
                    StatsLegendRow(color: .clear, label: "文件系统", value: stats.diskFileSystem.isEmpty ? "—" : stats.diskFileSystem, showsDot: false)
                    StatsLegendRow(color: .clear, label: "连接类型", value: stats.diskInterconnect.isEmpty ? "—" : stats.diskInterconnect, showsDot: false)
                }

                if let smart = stats.smart, smart.available {
                    MonitorSectionTitle("SMART")
                    VStack(alignment: .leading, spacing: 6) {
                        StatsLegendRow(color: .clear, label: "温度", value: "\(smart.temperatureC)°C",
                                       valueColor: MonitorColors.temperature, showsDot: false)
                        StatsLegendRow(color: .clear, label: "健康度", value: "\(smart.life)%",
                                       valueColor: smart.life < 30 ? MonitorColors.system : .primary, showsDot: false)
                        StatsLegendRow(color: .clear, label: "上电次数", value: "\(smart.powerCycles)", showsDot: false)
                        StatsLegendRow(color: .clear, label: "上电小时数", value: "\(smart.powerOnHours)", showsDot: false)
                        StatsLegendRow(color: .clear, label: "严重警告", value: smart.criticalWarning == 0 ? "无" : "0x\(String(smart.criticalWarning, radix: 16))",
                                       valueColor: smart.criticalWarning == 0 ? .primary : MonitorColors.system, showsDot: false)
                        StatsLegendRow(color: .clear, label: "可用空间", value: "\(stats.diskTotalBytes > 0 ? Int((Double(stats.diskFreeBytes) / Double(stats.diskTotalBytes) * 100).rounded()) : 0)%", showsDot: false)
                    }
                }

                if !stats.procDisk.isEmpty {
                    StatsProcTable(title: "高占用进程",
                                   columns: [.init(title: "", color: Color(red: 0.20, green: 0.52, blue: 0.98)),
                                             .init(title: "", color: Color(red: 0.95, green: 0.27, blue: 0.30))],
                                   items: Array(stats.procDisk.prefix(5))) { item in
                        [MonitorFormat.rate(UInt64(max(0, item.diskRead))),
                         MonitorFormat.rate(UInt64(max(0, item.diskWrite)))]
                    }
                }
            }
        }
    }

    private func legendValue(color: Color, value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
    }
}

// MARK: - 网络

private struct NetworkStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @ObservedObject private var diagnostics = NetworkDiagnostics.shared
    @Stored private var showsInterfacePicker = false

    var body: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current

        return VStack(alignment: .leading, spacing: 12) {
            MonitorSectionTitle("速率历史")
            HStack(spacing: 12) {
                legendValue(color: Color(red: 0.20, green: 0.52, blue: 0.98), value: MonitorFormat.rate(sample.netDownload))
                Spacer(minLength: 4)
                legendValue(color: Color(red: 0.95, green: 0.27, blue: 0.30), value: MonitorFormat.rate(sample.netUpload))
                Spacer(minLength: 4)
            }
            StatsHistoryDualChart(primaryValues: sampler.history.netDownload,
                                  secondaryValues: sampler.history.netUpload,
                                  primaryColor: Color(red: 0.20, green: 0.52, blue: 0.98),
                                  secondaryColor: Color(red: 0.95, green: 0.27, blue: 0.30),
                                  height: 70)

            VStack(alignment: .leading, spacing: 6) {
                StatsLegendRow(color: .clear, label: "峰值下载",
                               value: MonitorFormat.rate(MonitorExtra.current.netPeakDownload), showsDot: false)
                StatsLegendRow(color: .clear, label: "峰值上传",
                               value: MonitorFormat.rate(MonitorExtra.current.netPeakUpload), showsDot: false)
                StatsLegendRow(color: .clear, label: "累计下载",
                               value: MonitorFormat.bytes(MonitorExtra.current.netTotalIn), showsDot: false)
                StatsLegendRow(color: .clear, label: "累计上传",
                               value: MonitorFormat.bytes(MonitorExtra.current.netTotalOut), showsDot: false)
            }

            if stats.connStatus != .unknown {
                MonitorSectionTitle("网络连接")
                HStack(spacing: 6) {
                    Circle()
                        .fill(stats.connStatus == .online ? Color(red: 0.30, green: 0.78, blue: 0.35) : MonitorColors.system)
                        .frame(width: 7, height: 7)
                    Text(stats.connStatus == .online ? "已连接" : "未连接")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if !stats.connHistory.isEmpty {
                    StatsConnGrid(values: stats.connHistory)
                        .frame(height: 44)
                }
                VStack(alignment: .leading, spacing: 6) {
                    StatsLegendRow(color: .clear, label: "延迟", value: StatsFormat.ms(stats.connAvgLatencyMs), showsDot: false)
                    StatsLegendRow(color: .clear, label: "抖动", value: StatsFormat.ms(stats.connAvgJitterMs), showsDot: false)
                }
            }

            // ── 网络诊断（对照「鹅的IP」插件：内网 / 公网 / 归属 / 延迟 / DNS）
            diagnosticsSection

            if !stats.netInterface.isEmpty || !stats.netLocalIP.isEmpty {
                MonitorSectionTitle("接口")
                VStack(alignment: .leading, spacing: 6) {
                    if !stats.netInterface.isEmpty {
                        StatsLegendRow(color: .clear, label: "主接口", value: stats.netInterface, showsDot: false)
                    }
                    if !stats.netLocalIP.isEmpty {
                        StatsLegendRow(color: .clear, label: "本地 IP", value: stats.netLocalIP, showsDot: false)
                    }
                }
            }

            if !stats.procNet.isEmpty {
                StatsProcTable(title: "网络占用进程",
                               columns: [.init(title: "", color: Color(red: 0.20, green: 0.52, blue: 0.98)),
                                         .init(title: "", color: Color(red: 0.95, green: 0.27, blue: 0.30))],
                               items: Array(stats.procNet.prefix(5))) { item in
                    [MonitorFormat.rate(UInt64(max(0, item.diskRead))),
                     MonitorFormat.rate(UInt64(max(0, item.diskWrite)))]
                }
            }
        }
    }

    // MARK: 网络诊断

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MonitorSectionTitle("IP 信息")

            // 内网：可切换网卡
            HStack(spacing: 6) {
                Text("内网")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)
                Menu {
                    ForEach(diagnostics.interfaces) { item in
                        Button {
                            diagnostics.selectInterface(item.name)
                        } label: {
                            Text("\(item.name) · \(item.address)")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(diagnostics.selectedAddress)
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .lineLimit(1)
                        if diagnostics.interfaces.count > 1 {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer(minLength: 4)
                if !diagnostics.selectedInterface.isEmpty {
                    Text(diagnostics.selectedInterface)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            StatsLegendRow(color: .clear, label: "公网",
                           value: diagnostics.publicIP ?? (diagnostics.isLoading ? "查询中…" : "—"),
                           showsDot: false)
            StatsLegendRow(color: .clear, label: "归属",
                           value: diagnostics.publicLocation ?? "—",
                           showsDot: false)
            if diagnostics.isProxyLikely, let overseas = diagnostics.overseasIP {
                StatsLegendRow(color: .clear, label: "国外出口", value: overseas, showsDot: false)
                if let location = diagnostics.overseasLocation, !location.isEmpty {
                    StatsLegendRow(color: .clear, label: "位置", value: location, showsDot: false)
                }
            } else if diagnostics.publicIP != nil {
                StatsLegendRow(color: .clear, label: "代理", value: "未走代理", showsDot: false)
            }

            // 站点延迟（两列，与原版键值行同字号）
            if diagnostics.latencies.contains(where: { $0.milliseconds != nil }) {
                MonitorSectionTitle("站点延迟")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 6) {
                    ForEach(diagnostics.latencies) { site in
                        HStack(spacing: 4) {
                            Text(site.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(site.milliseconds.map { "\($0) ms" } ?? "超时")
                                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(site.milliseconds == nil ? .tertiary : .primary)
                        }
                    }
                }
            }

            if !diagnostics.dnsServers.isEmpty {
                MonitorSectionTitle("DNS 出口")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnostics.dnsServers.enumerated()), id: \.offset) { _, server in
                        Text(server)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .onAppear {
            // 首次进入或距上次超过 60 秒才重新探测（避免每次切页都打一轮外网请求）
            if diagnostics.lastRefresh == nil
                || Date().timeIntervalSince(diagnostics.lastRefresh!) > 60 {
                diagnostics.refresh()
            }
        }
    }

    private func legendValue(color: Color, value: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
        }
    }
}

/// 连通性网格（原版 5×24 绿/红方块）
private struct StatsConnGrid: View {
    var values: [Int]

    var body: some View {
        GeometryReader { geo in
            let columns = 24
            let rows = 5
            let total = columns * rows
            let spacing: CGFloat = 1.5
            let cell = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let visible = Array(values.suffix(total))
            VStack(spacing: spacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { col in
                            let index = row * columns + col
                            let offset = total - visible.count
                            let value = index >= offset ? visible[index - offset] : -1
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(color(for: value))
                                .frame(width: max(2, cell), height: max(2, cell))
                        }
                    }
                }
            }
        }
    }

    private func color(for value: Int) -> Color {
        switch value {
        case 1: return Color(red: 0.30, green: 0.78, blue: 0.35).opacity(0.85)
        case 0: return Color(red: 0.92, green: 0.26, blue: 0.28).opacity(0.85)
        default: return Color.primary.opacity(0.10)
        }
    }
}

// MARK: - 传感器（温度 / 电压 / 电流 / 功率）

private struct SensorsStatsPanel: View {
    var body: some View {
        let stats = StatsDataProvider.shared.current
        let temperatures = stats.sensors.filter { $0.category == 0 }
        let voltages = stats.sensors.filter { $0.category == 2 }
        let currents = stats.sensors.filter { $0.category == 3 }
        let powers = stats.sensors.filter { $0.category == 4 }

        return VStack(alignment: .leading, spacing: 12) {
            if !temperatures.isEmpty {
                SensorGroup(title: "温度", symbol: "thermometer.medium", color: MonitorColors.temperature,
                            items: orderedTemperatures(temperatures, stats: stats),
                            valueText: { String(format: "%.1f°C", $0.value) },
                            scaleMax: 110)
            }
            if !voltages.isEmpty {
                SensorGroup(title: "电压", symbol: "bolt.fill", color: Color(red: 0.20, green: 0.62, blue: 0.95),
                            items: voltages.sorted { $0.value > $1.value },
                            valueText: { String(format: "%.3f V", $0.value) },
                            scaleMax: nil)
            }
            if !currents.isEmpty {
                SensorGroup(title: "电流", symbol: "waveform.path", color: Color(red: 0.30, green: 0.70, blue: 0.40),
                            items: currents.sorted { $0.value > $1.value },
                            valueText: { String(format: "%.2f A", $0.value) },
                            scaleMax: nil)
            }
            if !powers.isEmpty {
                SensorGroup(title: "功率", symbol: "power", color: Color(red: 0.55, green: 0.40, blue: 0.85),
                            items: powers.sorted { $0.value > $1.value },
                            valueText: { String(format: "%.2f W", $0.value) },
                            scaleMax: nil)
            }
            if !stats.fans.isEmpty {
                MonitorSectionTitle("风扇")
                ForEach(stats.fans) { fan in
                    StatsLegendRow(color: .clear, label: fan.name,
                                   value: StatsFormat.rpm(fan.rpm), showsDot: false)
                }
            }
        }
    }

    /// 原版顺序：Average CPU / Hottest CPU / Average GPU / Hottest GPU / CPU Mb / 各核心
    private func orderedTemperatures(_ items: [StatsSensorItem], stats: StatsSnapshot) -> [StatsSensorItem] {
        var result: [StatsSensorItem] = []
        if let v = stats.calcAverageCPU {
            result.append(StatsSensorItem(key: "calc.avg.cpu", name: "Average CPU", category: 0, group: 1, value: v))
        }
        if let v = stats.calcHottestCPU {
            result.append(StatsSensorItem(key: "calc.max.cpu", name: "Hottest CPU", category: 0, group: 1, value: v))
        }
        if let v = stats.calcAverageGPU {
            result.append(StatsSensorItem(key: "calc.avg.gpu", name: "Average GPU", category: 0, group: 2, value: v))
        }
        if let v = stats.calcHottestGPU {
            result.append(StatsSensorItem(key: "calc.max.gpu", name: "Hottest GPU", category: 0, group: 2, value: v))
        }
        let rest = items
            .filter { !$0.name.hasPrefix("Average") && !$0.name.hasPrefix("Hottest") }
            .sorted { $0.value > $1.value }
        result.append(contentsOf: rest.prefix(12))
        return result
    }
}

private struct SensorGroup: View {
    var title: String
    var symbol: String
    var color: Color
    var items: [StatsSensorItem]
    var valueText: (StatsSensorItem) -> String
    var scaleMax: Double?

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                line
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 10))
                    Text(title).font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .fixedSize()
                line
            }
            .padding(.vertical, 4)

            ForEach(items, id: \.key) { item in
                HStack(spacing: 10) {
                    Text(item.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.10))
                            Capsule().fill(color)
                                .frame(width: geo.size.width * fraction(item))
                        }
                    }
                    .frame(height: 7)
                    Text(valueText(item))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
    }

    private func fraction(_ item: StatsSensorItem) -> Double {
        if let upper = scaleMax, upper > 0 { return Swift.max(0, Swift.min(1, item.value / upper)) }
        let peak = items.map(\.value).max() ?? 1
        return peak > 0 ? Swift.max(0.04, Swift.min(1, item.value / peak)) : 0
    }

    private var line: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
    }
}

// MARK: - 电池

private struct BatteryStatsPanel: View {
    @ObservedObject private var sampler = MonitorSampler.shared

    var body: some View {
        let stats = StatsDataProvider.shared.current
        let battery = stats.battery
        let level = battery.map { Double($0.percent) / 100 } ?? (sampler.sample.batteryLevel ?? 0)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    StatsRing(value: level,
                              color: battery?.isCharging == true
                                ? Color(red: 0.30, green: 0.78, blue: 0.35)
                                : Color(red: 0.20, green: 0.52, blue: 0.98),
                              lineWidth: 10)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(level))
                            .font(.system(size: 19, weight: .semibold).monospacedDigit())
                        Text(battery?.isCharging == true ? "充电中" : "电量")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)

                VStack(alignment: .leading, spacing: 7) {
                    StatsLegendRow(color: .clear, label: "状态",
                                   value: statusText(battery), showsDot: false)
                    StatsLegendRow(color: .clear, label: "剩余时间",
                                   value: StatsFormat.remaining(stats.batteryRemainSec), showsDot: false)
                    StatsLegendRow(color: .clear, label: "循环次数",
                                   value: "\(battery?.cycleCount ?? 0)", showsDot: false)
                    StatsLegendRow(color: .clear, label: "健康度",
                                   value: healthText(battery), showsDot: false)
                }
                .frame(maxWidth: .infinity)
            }

            MonitorSectionTitle("电池")
            VStack(alignment: .leading, spacing: 6) {
                StatsLegendRow(color: .clear, label: "温度",
                               value: String(format: "%.1f°C", battery?.temperature ?? 0), showsDot: false)
                StatsLegendRow(color: .clear, label: "电压",
                               value: StatsFormat.voltage(battery?.voltageMv ?? 0), showsDot: false)
                StatsLegendRow(color: .clear, label: "电流",
                               value: StatsFormat.amperage(battery?.amperageMa ?? 0), showsDot: false)
                StatsLegendRow(color: .clear, label: "设计容量",
                               value: StatsFormat.capacity(battery?.designCapacity ?? 0), showsDot: false)
                StatsLegendRow(color: .clear, label: "当前容量",
                               value: StatsFormat.capacity(battery?.currentCapacity ?? 0), showsDot: false)
            }

            if let battery, battery.adapterWatts > 0 || battery.adapterPowerW > 0 {
                MonitorSectionTitle("电源适配器")
                VStack(alignment: .leading, spacing: 6) {
                    StatsLegendRow(color: .clear, label: "标称功率",
                                   value: StatsFormat.watts(battery.adapterWatts), showsDot: false)
                    StatsLegendRow(color: .clear, label: "输入功率",
                                   value: StatsFormat.watts(battery.adapterPowerW), showsDot: false)
                    StatsLegendRow(color: .clear, label: "输入电压",
                                   value: String(format: "%.2f V", battery.adapterVoltageV), showsDot: false)
                    StatsLegendRow(color: .clear, label: "充电电流",
                                   value: StatsFormat.amperage(battery.chargingCurrentMa), showsDot: false)
                }
            }
        }
    }

    private func statusText(_ battery: StatsBattery?) -> String {
        guard let battery, battery.present else { return "无电池" }
        if battery.isCharging { return "充电中" }
        if battery.fullyCharged && battery.externalConnected { return "已充满" }
        if battery.externalConnected { return "已接电源" }
        return "放电中"
    }

    private func healthText(_ battery: StatsBattery?) -> String {
        guard let battery, battery.designCapacity > 0 else { return "—" }
        let health = min(1.2, Double(battery.maxCapacity) / Double(battery.designCapacity))
        return String(format: "%.0f%%", health * 100)
    }
}
