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
    @ObservedObject private var memoryOptimizer = MemoryOptimizer.shared
    /// 模块切换条的高亮胶囊（matchedGeometry：选中项滑动而非瞬移）
    @Namespace private var tabNamespace
    /// 页面模式：只渲染模块内容，标签行与底栏由 StatsPageView 提供（宽度撑满、无固定 292 限宽）
    private let pageMode: Bool

    public init(module: MonitorModuleID = .cpu, pageMode: Bool = false) {
        self.selection = MonitorDetailSelection(module)
        self.pageMode = pageMode
    }

    public init(selection: MonitorDetailSelection, pageMode: Bool = false) {
        self.selection = selection
        self.pageMode = pageMode
    }

    public var body: some View {
        if pageMode {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                modulePicker
                Divider().opacity(0.5)
                content
                    .id(selection.module)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider().opacity(0.5)
                footer
            }
            .padding(12)
            .frame(width: 292)
        }
    }

    // MARK: - 模块切换

    /// v60：切换条不再横向滑动（用户反馈"网络/磁盘/温度/电池/GPU 要滑很久"）——
    /// 改自适应换行布局：宽够一行摆下，不够自动折行，全部模块直接可点。
    private var modulePicker: some View {
        FlowHStack(spacing: 6, lineSpacing: 6) {
            ForEach(availableModules(), id: \.self) { module in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection.module = module
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: module.systemImage)
                            .font(.system(size: 10))
                        Text(module.displayName)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        // 选中胶囊用 matchedGeometry 滑动（灵动切换，不闪）
                        if selection.module == module {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.18))
                                .matchedGeometryEffect(id: "modulePill", in: tabNamespace)
                        }
                    }
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(selection.module == module ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 可选模块：过滤掉无数据的项，但始终保留当前选中项
    private func availableModules() -> [MonitorModuleID] {
        var modules: [MonitorModuleID] = []
        let stats = StatsDataProvider.shared.current
        for module in MonitorModuleID.allCases {
            switch module {
            case .sensors:
                if MonitorPreferences.showTemperatures { modules.append(module) }
            case .battery:
                if sampler.sample.batteryLevel != nil || selection.module == .battery { modules.append(module) }
            case .gpu:
                // 有 GPU 数据（IOAccelerator 可读）才显示
                if stats.gpuUsage >= 0 || selection.module == .gpu { modules.append(module) }
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
        case .power: powerPanel
        case .cpu: cpuPanel
        case .memory: memoryPanel
        case .network: networkPanel
        case .disk: diskPanel
        case .sensors: sensorsPanel
        case .battery: batteryPanel
        case .gpu: gpuPanel
        }
    }

    // MARK: - 功耗（2026-10-16：整机能量流，输入=充电 / 输出=放电功耗）

    private var powerPanel: some View {
        let sample = sampler.sample
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: sample.powerIsInput ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(sample.powerIsInput ? MonitorColors.battery : MonitorColors.user)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: sample.powerIsInput
                         ? (sample.isCharging ? "输入（充电中）" : "输入（接电源）")
                         : "输出（电池供电）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(sample.powerWatts.map { MonitorFormat.power($0) } ?? "—")
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                }
            }

            if let level = sampler.sample.batteryLevel {
                MonitorRow(label: "电池电量", value: MonitorFormat.percent(level), color: MonitorColors.battery)
            }
            MonitorRow(label: "电源", value: sample.externalPower ? "已连接适配器" : "电池供电")
            Text("数据源：AppleSmartBattery PowerTelemetryData（接电取 SystemPowerIn / 充入电池功率；放电取电池放电功率绝对值）")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - CPU

    private var cpuPanel: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                // 温度环（原版 v56 布局：橙色环 + "81°"，总占用环左侧）
                if let temperature = primaryTemperature() {
                    ZStack {
                        MonitorRing(value: min(max(temperature / 100.0, 0), 1), lineWidth: 7,
                                    color: MonitorColors.temperature)
                            .frame(width: 66, height: 66)
                        Text(MonitorFormat.temperature(temperature))
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    }
                }
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
                    // 启动时间（原版 v56：图例第四行"启动时间 4 天 19 小时"）
                    MonitorRow(label: "启动时间", value: Self.uptimeText())
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

            // CPU 集群（Apple Silicon：E/P/S 分簇占用行；Intel 不显示）
            if stats.cpuSuperCores >= 0 {
                MonitorSectionTitle("集群占用（S\(stats.cpuSuperCores) / E\(stats.cpuEffCores)\(stats.cpuMedCores >= 0 ? " / M\(stats.cpuMedCores)" : "")）")
                VStack(spacing: 3) {
                    MonitorRow(label: "性能核（P/S）", value: MonitorFormat.percent(stats.clusterSuperUsage), color: MonitorColors.user)
                    MonitorRow(label: "能效核（E）", value: MonitorFormat.percent(stats.clusterEffUsage), color: MonitorColors.download)
                    if stats.cpuMedCores >= 0 {
                        MonitorRow(label: "中核（M）", value: MonitorFormat.percent(stats.clusterMedUsage), color: MonitorColors.memory)
                    }
                }
            }

            MonitorSectionTitle("平均负载")
            HStack(spacing: 10) {
                loadCell("1 分钟", value: sample.loadAverage1m)
                loadCell("5 分钟", value: sample.loadAverage5m)
                loadCell("15 分钟", value: sample.loadAverage15m)
            }

            // 高占用进程（原版 v56 底部段：进程名 + 用量%）
            let procs = Array(StatsDataProvider.shared.current.procCPU.prefix(5))
            if !procs.isEmpty {
                MonitorSectionTitle("高占用进程")
                VStack(spacing: 3) {
                    ForEach(procs) { proc in
                        HStack(spacing: 6) {
                            Text(proc.name)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(String(format: "%.0f%%", proc.cpu))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// 启动时长文案（原版 v56："4 天 19 小时"）
    private static func uptimeText() -> String {
        let up = ProcessInfo.processInfo.systemUptime
        let days = Int(up) / 86400
        let hours = (Int(up) % 86400) / 3600
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        let minutes = (Int(up) % 3600) / 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(minutes) 分钟"
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

            MemoryOptimizeSection(optimizer: memoryOptimizer)

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
        let stats = StatsDataProvider.shared.current
        return VStack(alignment: .leading, spacing: 10) {
            // v93 布局（逆向版同款）：左列上下两行速率 + 右侧曲线，曲线独立右半区
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down").font(.system(size: 10))
                            Text("下载").font(.system(size: 10))
                        }
                        .foregroundStyle(MonitorColors.download)
                        Text(MonitorFormat.rate(sample.netDownload))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up").font(.system(size: 10))
                            Text("上传").font(.system(size: 10))
                        }
                        .foregroundStyle(MonitorColors.upload)
                        Text(MonitorFormat.rate(sample.netUpload))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 112, alignment: .leading)

                ZStack {
                    MonitorAreaSparkline(values: sampler.history.netDownload, color: MonitorColors.download)
                    MonitorSparkline(values: sampler.history.netUpload)
                        .stroke(MonitorColors.upload, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            }

            MonitorRow(label: "峰值下载", value: MonitorFormat.rate(MonitorExtra.current.netPeakDownload), color: MonitorColors.download)
            MonitorRow(label: "峰值上传", value: MonitorFormat.rate(MonitorExtra.current.netPeakUpload), color: MonitorColors.upload)
            MonitorRow(label: "累计下载", value: MonitorFormat.bytes(MonitorExtra.current.netTotalIn))
            MonitorRow(label: "累计上传", value: MonitorFormat.bytes(MonitorExtra.current.netTotalOut))

            // 连通性（官方 ConnectivityReader：ICMP → 1.1.1.1，1s/包）
            if stats.connStatus != .unknown {
                MonitorSectionTitle("网络连接")
                HStack(spacing: 6) {
                    Circle()
                        .fill(stats.connStatus == .online ? MonitorColors.battery : MonitorColors.system)
                        .frame(width: 8, height: 8)
                    Text(stats.connStatus == .online ? "已连接" : "未连接")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // 连通性历史网格（30×3=90 格，最新在右下，官方同布局）
                if !stats.connHistory.isEmpty {
                    let columns = 30
                    let rows = 3
                    Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
                        ForEach(0..<rows, id: \.self) { row in
                            GridRow {
                                ForEach(0..<columns, id: \.self) { col in
                                    let index = row * columns + col
                                    let value = index < stats.connHistory.count ? stats.connHistory[index] : -1
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(connCellColor(value))
                                        .frame(height: 5)
                                }
                            }
                        }
                    }
                    .font(.system(size: 5))
                }
                MonitorRow(label: "延迟", value: StatsFormat.ms(stats.connAvgLatencyMs))
                MonitorRow(label: "抖动", value: StatsFormat.ms(stats.connAvgJitterMs))
            }

            // 接口（官方接口段：真实 BSD 名 + 本地 IP）
            if !stats.netInterface.isEmpty || !stats.netLocalIP.isEmpty {
                MonitorSectionTitle("接口")
                if !stats.netInterface.isEmpty {
                    MonitorRow(label: "主接口", value: stats.netInterface)
                }
                if !stats.netLocalIP.isEmpty {
                    MonitorRow(label: "本地 IP", value: stats.netLocalIP)
                }
            }

            // 网络高占用进程（官方 nettop -P -L 1 -n 差分；C 层 down/up 复用 disk_r/disk_w）
            if !stats.procNet.isEmpty {
                MonitorSectionTitle("网络占用进程")
                StatsProcRows(items: stats.procNet) { item in
                    StatsDualValue(left: MonitorFormat.rate(UInt64(max(0, item.diskRead))), right: MonitorFormat.rate(UInt64(max(0, item.diskWrite))))
                }
            }
        }
    }

    /// 连通性格子颜色（官方：系统绿/红/灰）
    private func connCellColor(_ value: Int) -> Color {
        switch value {
        case 1: return MonitorColors.battery
        case 0: return MonitorColors.system
        default: return Color.primary.opacity(0.12)
        }
    }

    // MARK: - 磁盘

    private var diskPanel: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        let used = stats.diskTotalBytes > stats.diskFreeBytes ? stats.diskTotalBytes - stats.diskFreeBytes : 0
        let usedRatio = stats.diskTotalBytes > 0 ? Double(used) / Double(stats.diskTotalBytes) : 0
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

            // 容量（官方 Disk 卡片：名称行/图表盒/容量条/图例/详情行）
            if stats.diskTotalBytes > 0 {
                MonitorSectionTitle("容量")
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(MonitorColors.read)
                                .frame(width: geo.size.width * usedRatio)
                        }
                    }
                    .frame(height: 10)
                    HStack(spacing: 10) {
                        legendItem("已用 \(MonitorFormat.bytes(used))", color: MonitorColors.read)
                        legendItem("可用 \(MonitorFormat.bytes(stats.diskFreeBytes))", color: .secondary)
                    }
                    .font(.system(size: 9))
                    MonitorRow(label: "总量", value: MonitorFormat.bytes(stats.diskTotalBytes))
                }
            }

            // 详情（文件系统/连接类型/型号——官方同源）
            if !stats.diskFileSystem.isEmpty || !stats.diskInterconnect.isEmpty || !stats.diskModel.isEmpty {
                MonitorSectionTitle("详情")
                if !stats.diskFileSystem.isEmpty {
                    MonitorRow(label: "文件系统", value: stats.diskFileSystem)
                }
                if !stats.diskInterconnect.isEmpty {
                    MonitorRow(label: "连接类型", value: stats.diskInterconnect)
                }
                if !stats.diskModel.isEmpty {
                    MonitorRow(label: "型号", value: stats.diskModel)
                        .lineLimit(1)
                }
            }

            // NVMe SMART（官方 updateSMARTInterval 30s 缓存）
            if let smart = stats.smart, smart.available {
                MonitorSectionTitle("NVMe SMART")
                MonitorRow(label: "温度", value: "\(smart.temperatureC) °C", color: MonitorColors.temperature)
                MonitorRow(label: "健康度", value: "\(smart.life) %", color: smart.life < 30 ? MonitorColors.system : MonitorColors.battery)
                MonitorRow(label: "上电次数", value: "\(smart.powerCycles)")
                MonitorRow(label: "上电小时", value: "\(smart.powerOnHours) h")
                MonitorRow(label: "严重警告", value: smart.criticalWarning == 0 ? "无" : "0x\(String(smart.criticalWarning, radix: 16))", color: smart.criticalWarning == 0 ? .secondary : MonitorColors.system)
                MonitorRow(label: "可用备用", value: "\(smart.availableSpare) %")
                MonitorRow(label: "终身读取", value: MonitorFormat.bytes(smart.totalRead))
                MonitorRow(label: "终身写入", value: MonitorFormat.bytes(smart.totalWritten))
            }

            // 按进程磁盘 I/O（官方 proc_pid_rusage 差分）
            if !stats.procDisk.isEmpty {
                MonitorSectionTitle("磁盘占用进程")
                StatsProcRows(items: stats.procDisk) { item in
                    StatsDualValue(left: MonitorFormat.rate(UInt64(max(0, item.diskRead))), right: MonitorFormat.rate(UInt64(max(0, item.diskWrite))))
                }
            }

            Text("统计来源：IOKit IOBlockStorageDriver + NVMe SMART 插件接口（官方同源）")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 温度（传感器：官方名表 + 分类型分节 + 计算项 + 多风扇）

    private var sensorsPanel: some View {
        let temperatures = sampler.sample.temperatures
        let stats = StatsDataProvider.shared.current
        let hasDeep = !stats.sensors.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            if temperatures.isEmpty && !hasDeep {
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
            } else if hasDeep {
                // 计算项（官方 initCalculatedSensors：Average/Hottest CPU/GPU）
                if stats.calcAverageCPU != nil || stats.calcAverageGPU != nil {
                    MonitorSectionTitle("计算项")
                    if let v = stats.calcAverageCPU { MonitorRow(label: "Average CPU", value: MonitorFormat.temperature(v)) }
                    if let v = stats.calcHottestCPU { MonitorRow(label: "Hottest CPU", value: MonitorFormat.temperature(v)) }
                    if let v = stats.calcAverageGPU { MonitorRow(label: "Average GPU", value: MonitorFormat.temperature(v)) }
                    if let v = stats.calcHottestGPU { MonitorRow(label: "Hottest GPU", value: MonitorFormat.temperature(v)) }
                }

                // 风扇（官方顺序：风扇节在最前）
                if !stats.fans.isEmpty {
                    MonitorSectionTitle("风扇")
                    ForEach(stats.fans) { fan in
                        HStack(spacing: 8) {
                            Text(fan.name)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 92, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                                    RoundedRectangle(cornerRadius: 2).fill(MonitorColors.temperature)
                                        .frame(width: geo.size.width * fan.percent)
                                }
                            }
                            .frame(height: 6)
                            Text(StatsFormat.rpm(fan.rpm))
                                .font(.system(size: 10).monospacedDigit())
                                .frame(width: 76, alignment: .trailing)
                        }
                    }
                }

                // 按类型分节（官方 Sensors 页顺序：温度 → 电压 → 电流 → 功率）
                sensorCategorySection(title: "温度", category: 0, unit: .celsius, items: stats.sensors)
                sensorCategorySection(title: "电压", category: 2, unit: .voltage, items: stats.sensors)
                sensorCategorySection(title: "电流", category: 3, unit: .ampere, items: stats.sensors)
                sensorCategorySection(title: "功率", category: 4, unit: .watt, items: stats.sensors)
                sensorCategorySection(title: "能耗", category: 5, unit: .wattHour, items: stats.sensors)
            } else {
                // 降级：Swift 采样器的温度卡片网格（无官方名表时）
                let sorted = temperatures.sorted { $0.value > $1.value }
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

    /// 传感器单位（官方数值格式）
    private enum SensorUnit {
        case celsius, voltage, ampere, watt, wattHour
    }

    /// 按类型分节渲染（官方 Sensors 页结构；裁剪规则：温度<110、电压<300、电流<100）
    @ViewBuilder
    private func sensorCategorySection(title: String, category: Int, unit: SensorUnit, items: [StatsSensorItem]) -> some View {
        let filtered: [(name: String, value: Double)] = items
            .filter { $0.category == category }
            .filter { item in
                switch category {
                case 0: return item.value < 110
                case 2: return item.value < 300
                case 3: return item.value < 100
                default: return true
                }
            }
            .sorted { $0.value > $1.value }
            .map { ($0.name, $0.value) }
        if !filtered.isEmpty {
            MonitorSectionTitle("\(title)（\(filtered.count)）")
            // 限行控高：温度 6 行、电压/电流/功率/能耗各 3 行
            // （官方弹窗可滚动，我方弹窗限高控长——对齐注入版 v26 的既定策略与用户"一页别太长"取向）
            let limit = (category == 0) ? 6 : 3
            ForEach(filtered.prefix(limit), id: \.name) { item in
                MonitorRow(label: item.name, value: sensorValueText(item.value, unit: unit))
            }
        }
    }

    // MARK: - 电池（官方 Battery 页：Dashboard + Health + 适配器段）

    private var batteryPanel: some View {
        let stats = StatsDataProvider.shared.current
        let batt = stats.battery
        let level = batt.map { Double($0.percent) / 100 } ?? sampler.sample.batteryLevel
        return VStack(alignment: .leading, spacing: 10) {
            if let level, let batt {
                HStack(spacing: 14) {
                    ZStack {
                        MonitorRing(value: level, lineWidth: 7, color: MonitorColors.battery)
                            .frame(width: 66, height: 66)
                        Text(MonitorFormat.percent(level))
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        // 状态徽章（官方四态：充电中/电池供电/已连接电源/暂停）
                        HStack(spacing: 5) {
                            Circle()
                                .fill(batt.isCharging ? MonitorColors.battery : (batt.externalConnected ? MonitorColors.download : MonitorColors.temperature))
                                .frame(width: 7, height: 7)
                            Text(batteryStatusText(batt))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if stats.batteryRemainSec > 0 {
                            MonitorRow(label: "剩余时间", value: StatsFormat.remaining(stats.batteryRemainSec))
                        }
                        if batt.maxCapacity > 0 || batt.designCapacity > 0 {
                            MonitorRow(label: "最大容量", value: StatsFormat.capacity(batt.maxCapacity))
                            MonitorRow(label: "设计容量", value: StatsFormat.capacity(batt.designCapacity))
                        }
                    }
                }

                // 健康度进度条（官方 Health 段）
                if batt.designCapacity > 0 && batt.maxCapacity > 0 {
                    let health = Swift.min(1, Double(batt.maxCapacity) / Double(batt.designCapacity))
                    MonitorSectionTitle("健康度")
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.1))
                                RoundedRectangle(cornerRadius: 3).fill(health > 0.8 ? MonitorColors.battery : MonitorColors.temperature)
                                    .frame(width: geo.size.width * health)
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int((health * 100).rounded())) %")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                MonitorSectionTitle("电池")
                MonitorRow(label: "循环次数", value: "\(batt.cycleCount)")
                if batt.temperature > 0 { MonitorRow(label: "温度", value: MonitorFormat.temperature(batt.temperature), color: MonitorColors.temperature) }
                MonitorRow(label: "电压", value: StatsFormat.voltage(batt.voltageMv))
                MonitorRow(label: "电流", value: StatsFormat.amperage(batt.amperageMa))
                MonitorRow(label: "电池功率", value: StatsFormat.watts(batt.batteryPowerW))

                // 电源适配器段（官方 v27：正在充电/功率(PDTR/标称W)/电流/电压）
                if batt.externalConnected {
                    MonitorSectionTitle("电源适配器")
                    MonitorRow(label: "正在充电", value: batt.isCharging ? "是" : "否")
                    MonitorRow(label: "适配器功率", value: "\(StatsFormat.watts(batt.adapterPowerW)) / \(StatsFormat.watts(batt.adapterWatts))")
                    MonitorRow(label: "充电电流", value: StatsFormat.amperage(batt.chargingCurrentMa))
                    MonitorRow(label: "适配器电压", value: StatsFormat.voltage(batt.adapterVoltageV * 1000))
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

    /// 电池状态文案（官方四态）
    private func batteryStatusText(_ batt: StatsBattery) -> String {
        if batt.isCharging { return "充电中" }
        if batt.externalConnected { return "已连接电源" }
        return "电池供电"
    }

    /// 传感器值按官方单位格式化（温度 %.1f°C / 电压 %.3f V / 电流 %.2f A / 功率 %.2f W / 能耗 %.2f Wh）
    private func sensorValueText(_ value: Double, unit: SensorUnit) -> String {
        switch unit {
        case .celsius: return MonitorFormat.temperature(value)
        case .voltage: return StatsFormat.voltage(value)
        case .ampere: return StatsFormat.amperage(value)
        case .watt: return StatsFormat.watts(value)
        case .wattHour: return StatsFormat.wattHours(value)
        }
    }

    // MARK: - GPU（官方 GPU 页：Usage history + Details）

    private var gpuPanel: some View {
        let stats = StatsDataProvider.shared.current
        let usage = stats.gpuUsage >= 0 ? stats.gpuUsage : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    MonitorRing(value: usage ?? 0, lineWidth: 7, color: MonitorColors.user)
                        .frame(width: 66, height: 66)
                    VStack(spacing: 0) {
                        Text(usage.map { MonitorFormat.percent($0) } ?? "—")
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        Text("GPU 占用")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !stats.gpuModel.isEmpty {
                        MonitorRow(label: "型号", value: stats.gpuModel)
                            .lineLimit(1)
                    }
                    if stats.gpuRenderer >= 0 {
                        MonitorRow(label: "渲染利用率", value: MonitorFormat.percent(stats.gpuRenderer), color: MonitorColors.download)
                    }
                    if stats.gpuTiler >= 0 {
                        MonitorRow(label: "平铺利用率", value: MonitorFormat.percent(stats.gpuTiler), color: MonitorColors.memory)
                    }
                    if stats.gpuTemperature > 0 {
                        MonitorRow(label: "GPU 温度", value: MonitorFormat.temperature(stats.gpuTemperature), color: MonitorColors.temperature)
                    }
                }
            }

            MonitorSectionTitle("使用历史")
            MonitorAreaSparkline(values: sampler.history.gpu, color: MonitorColors.user, upperBound: 1)
                .frame(height: 46)

            Text("数据来源：IOAccelerator PerformanceStatistics（Apple Silicon）")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
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
                StatsBarEngine.openSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("菜单栏部件设置（Stats 风格：形态 / 间距 / 分隔线）")
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

// MARK: - 深数据共享组件（进程排行行 / 双值列）

/// 进程排行行（名称 + 自定义数值区）
private struct StatsProcRows: View {    let items: [StatsProcItem]
    @ViewBuilder let value: (StatsProcItem) -> StatsDualValue

    var body: some View {
        VStack(spacing: 3) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    value(item)
                }
            }
        }
    }
}

/// 双数值（左/右，等宽右对齐——官方进程表列序用）
private struct StatsDualValue: View {
    let left: String
    let right: String

    var body: some View {
        HStack(spacing: 8) {
            Text(left).monospacedDigit().frame(width: 62, alignment: .trailing)
            Text(right).monospacedDigit().frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 10))
    }
}

