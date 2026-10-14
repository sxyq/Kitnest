import SwiftUI

/// 各模块详情面板（Stats 信息架构 × Frset 视觉），宽度控制在 300pt 内以适应 popover。
///
/// 通过顶部模块切换条可在 CPU / 内存 / 网络 / 磁盘 / 温度 / 电池之间切换。
/// 详情面板的选中模块状态（放在 ObservableObject 里，避免依赖 SwiftUI 的 @Stored 宏）
public final class MonitorDetailSelection: ObservableObject {
    @Published public var module: MonitorModuleID
    public init(_ module: MonitorModuleID = .cpu) { self.module = module }
}

public struct MonitorDetailView: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @ObservedObject private var selection: MonitorDetailSelection

    public init(module: MonitorModuleID = .cpu) {
        self.selection = MonitorDetailSelection(module)
    }

    public init(selection: MonitorDetailSelection) {
        self.selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            modulePicker
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.5)
            footer
        }
        .padding(12)
        .frame(width: 292)
    }

    // MARK: - 模块切换

    private var modulePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(availableModules(), id: \.self) { module in
                    Button {
                        selection.module = module
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: module.systemImage)
                                .font(.system(size: 10))
                            Text(module.displayName)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selection.module == module ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(selection.module == module ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 可选模块：过滤掉无数据的项，但始终保留当前选中项
    private func availableModules() -> [MonitorModuleID] {
        var modules: [MonitorModuleID] = []
        for module in MonitorModuleID.allCases {
            switch module {
            case .sensors:
                if MonitorPreferences.showTemperatures { modules.append(module) }
            case .battery:
                if sampler.sample.batteryLevel != nil || selection.module == .battery { modules.append(module) }
            default:
                modules.append(module)
            }
        }
        if !modules.contains(selection.module) { modules.append(selection.module) }
        return modules
    }

    // MARK: - 内容分发

    @ViewBuilder
    private var content: some View {
        switch selection.module {
        case .cpu: cpuPanel
        case .memory: memoryPanel
        case .network: networkPanel
        case .disk: diskPanel
        case .sensors: sensorsPanel
        case .battery: batteryPanel
        }
    }

    // MARK: - CPU

    private var cpuPanel: some View {
        let sample = sampler.sample
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    MonitorRing(value: sample.cpuUsage, lineWidth: 7, color: MonitorColors.user)
                        .frame(width: 66, height: 66)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(sample.cpuUsage))
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        Text("总占用")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    MonitorRow(label: "系统", value: MonitorFormat.percent(sample.systemCPU), color: MonitorColors.system)
                    MonitorRow(label: "用户", value: MonitorFormat.percent(sample.userCPU), color: MonitorColors.user)
                    MonitorRow(label: "空闲", value: MonitorFormat.percent(sample.idleCPU), color: .secondary)
                    if let temperature = primaryTemperature() {
                        MonitorRow(label: "CPU 温度", value: MonitorFormat.temperature(temperature), color: MonitorColors.temperature)
                    }
                }
            }

            MonitorSectionTitle("使用历史")
            MonitorAreaSparkline(
                values: sampler.history.cpu,
                color: MonitorColors.user,
                upperBound: 1
            )
            .frame(height: 46)

            MonitorSectionTitle("每核心（\(max(sample.perCore.count, 0)) 核）")
            MonitorBarChart(values: sample.perCore, color: MonitorColors.user)
                .frame(height: 40)

            MonitorSectionTitle("平均负载")
            HStack(spacing: 10) {
                loadCell("1 分钟", value: sample.loadAverage1m)
                loadCell("5 分钟", value: sample.loadAverage5m)
                loadCell("15 分钟", value: sample.loadAverage15m)
            }
        }
    }

    private func loadCell(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(MonitorFormat.load(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryTemperature() -> Double? {
        let temperatures = sampler.sample.temperatures
        for key in ["CPU 包温", "CPU 二极管", "CPU 邻近"] {
            if let value = temperatures[key] { return value }
        }
        return temperatures.values.first
    }

    // MARK: - 内存

    private var memoryPanel: some View {
        let sample = sampler.sample
        let compressed = sample.compressedMemory
        let app = Double(sample.memoryUsed) - Double(min(compressed, sample.memoryUsed))
        let rest = Double(sample.memoryTotal) - Double(sample.memoryUsed)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    MonitorRing(value: sample.memoryPressure, lineWidth: 7, color: MonitorColors.memory)
                        .frame(width: 66, height: 66)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(sample.memoryPressure))
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        Text("已用")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    MonitorRow(label: "已用", value: MonitorFormat.bytes(sample.memoryUsed))
                    MonitorRow(label: "总量", value: MonitorFormat.bytes(sample.memoryTotal))
                    MonitorRow(label: "Swap", value: MonitorFormat.bytes(sample.swapUsed))
                    MonitorRow(label: "压缩", value: MonitorFormat.bytes(compressed), color: MonitorColors.compressed)
                }
            }

            MonitorSectionTitle("内存构成")
            MonitorStackedBar(segments: [
                .init(id: "app", value: app, color: MonitorColors.memory),
                .init(id: "compressed", value: Double(compressed), color: MonitorColors.compressed),
                .init(id: "wired", value: max(0, rest), color: MonitorColors.wired)
            ], height: 10)
            HStack(spacing: 10) {
                legendItem("应用", color: MonitorColors.memory)
                legendItem("压缩", color: MonitorColors.compressed)
                legendItem("联动/空闲", color: MonitorColors.wired)
            }
            .font(.system(size: 9))

            MonitorSectionTitle("使用历史")
            MonitorAreaSparkline(values: sampler.history.memory, color: MonitorColors.memory, upperBound: 1)
                .frame(height: 46)

            MonitorRow(label: "内存压力", value: MonitorFormat.percentFine(sample.memoryPressure))
        }
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
        }
    }

    // MARK: - 网络

    private var networkPanel: some View {
        let sample = sampler.sample
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down").font(.system(size: 10))
                        Text("下载").font(.system(size: 10))
                    }
                    .foregroundStyle(MonitorColors.download)
                    Text(MonitorFormat.rate(sample.netDownload))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up").font(.system(size: 10))
                        Text("上传").font(.system(size: 10))
                    }
                    .foregroundStyle(MonitorColors.upload)
                    Text(MonitorFormat.rate(sample.netUpload))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            MonitorSectionTitle("速率历史")
            ZStack {
                MonitorAreaSparkline(values: sampler.history.netDownload, color: MonitorColors.download)
                MonitorSparkline(values: sampler.history.netUpload)
                    .stroke(MonitorColors.upload, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
            .frame(height: 52)

            MonitorRow(label: "峰值下载", value: MonitorFormat.rate(MonitorExtra.current.netPeakDownload), color: MonitorColors.download)
            MonitorRow(label: "峰值上传", value: MonitorFormat.rate(MonitorExtra.current.netPeakUpload), color: MonitorColors.upload)
            MonitorRow(label: "累计下载", value: MonitorFormat.bytes(MonitorExtra.current.netTotalIn))
            MonitorRow(label: "累计上传", value: MonitorFormat.bytes(MonitorExtra.current.netTotalOut))
        }
    }

    // MARK: - 磁盘

    private var diskPanel: some View {
        let sample = sampler.sample
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("读取").font(.system(size: 10)).foregroundStyle(MonitorColors.read)
                    Text(MonitorFormat.rate(sample.diskRead))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("写入").font(.system(size: 10)).foregroundStyle(MonitorColors.write)
                    Text(MonitorFormat.rate(sample.diskWrite))
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            MonitorSectionTitle("读写历史")
            ZStack {
                MonitorAreaSparkline(values: sampler.history.diskRead, color: MonitorColors.read)
                MonitorSparkline(values: sampler.history.diskWrite)
                    .stroke(MonitorColors.write, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
            .frame(height: 52)

            MonitorRow(label: "峰值读取", value: MonitorFormat.rate(MonitorExtra.current.diskPeakRead), color: MonitorColors.read)
            MonitorRow(label: "峰值写入", value: MonitorFormat.rate(MonitorExtra.current.diskPeakWrite), color: MonitorColors.write)
            Text("统计来源：IOKit IOBlockStorageDriver（不支持时显示为 0）")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 温度

    private var sensorsPanel: some View {
        let temperatures = sampler.sample.temperatures
        let sorted = temperatures.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 10) {
            if sorted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "thermometer.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("未获取到传感器数据")
                        .font(.system(size: 12, weight: .medium))
                    Text("本机 SMC 不可读（常见于未授权或非 Apple 芯片环境），已优雅降级，不影响其他指标。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(sorted, id: \.key) { item in
                        MonitorCard {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.key)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(MonitorFormat.temperature(item.value))
                                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(MonitorColors.temperature)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if let level = sampler.sample.batteryLevel {
                MonitorRow(label: "电池电量", value: MonitorFormat.percent(level), color: MonitorColors.battery)
            }
        }
    }

    // MARK: - 电池

    private var batteryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let level = sampler.sample.batteryLevel {
                HStack(spacing: 14) {
                    ZStack {
                        MonitorRing(value: level, lineWidth: 7, color: MonitorColors.battery)
                            .frame(width: 66, height: 66)
                        Text(MonitorFormat.percent(level))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        MonitorRow(label: "电量", value: MonitorFormat.percent(level), color: MonitorColors.battery)
                        MonitorRow(label: "状态", value: level > 0.2 ? "正常" : "偏低")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "battery.0")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("未检测到电池（台式机或电源信息不可用）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text("刷新间隔 \(String(format: "%.1f", MonitorPreferences.refreshInterval))s")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                sampler.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("立即刷新")
            Button {
                ServiceLocator.settings?.open(pane: "monitor")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("打开监测设置")
        }
    }
}
