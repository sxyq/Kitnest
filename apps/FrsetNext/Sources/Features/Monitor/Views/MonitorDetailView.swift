import SwiftUI

/// 各模块详情面板（Stats 信息架构 × Frset 视觉），宽度控制在 300pt 内以适应 popover。
///
/// 通过顶部模块切换条可在 CPU / 内存 / 网络 / 磁盘 / 温度 / 电池之间切换。
/// 详情面板的选中模块状态（放在 ObservableObject 里，避免依赖 SwiftUI 的 @Stored 宏）
public final class MonitorDetailSelection: ObservableObject {
    @Published public var module: MonitorModuleID
    var chartPins: [String: MonitorTrendPoint] = [:]
    public init(_ module: MonitorModuleID = .cpu) { self.module = module }
}

struct MonitorPresentation {
    var order: [MonitorModuleID]? = nil
    var colors: [MonitorModuleID: Color] = [:]
    var interaction: ((Bool) -> Void)? = nil
    var previewInterval = 1.0
    var previewEnabled = true
    var previewTemperatures = true
    var previewFlowTopN = 4
}
private struct MonitorPresentationKey: EnvironmentKey {
    static let defaultValue = MonitorPresentation()
}
extension EnvironmentValues {
    var monitorPresentation: MonitorPresentation {
        get { self[MonitorPresentationKey.self] }
        set { self[MonitorPresentationKey.self] = newValue }
    }
}

/// 性能页正文容器：**主面板性能页与状态栏独立窗共用唯一实现**。
/// v196 起两处 topInset 都是 0（独立窗已去掉左上角关闭钮，不再需要让位），
/// 内外边距/滚动策略/模块选中态/数据源必须完全一致——任何一侧单独改版式
/// 都会造成用户看到的「两套 UI」。
public struct MonitorPerformanceContent: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    private let topInset: CGFloat

    public init(topInset: CGFloat = 0) { self.topInset = topInset }
    public var body: some View {
        Group {
            if isSettingsPreview {
                MonitorDetailView(pageMode: false, fixedWidth: nil)
            } else {
                LiveMonitorPerformanceContent()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.top, topInset)
    }
}

private struct LiveMonitorPerformanceContent: View {
    @ObservedObject private var presenter = MonitorCenterPresenter.shared
    var body: some View {
        MonitorDetailView(selection: presenter.monitorSelection, pageMode: false, fixedWidth: nil)
    }
}

public struct MonitorDetailView: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.monitorPresentation) private var presentation
    @StateObject private var previewSelection = MonitorDetailSelection()
    private let selection: MonitorDetailSelection
    private let pageMode: Bool
    private let fixedWidth: CGFloat?

    public init(selection: MonitorDetailSelection = MonitorCenterPresenter.shared.monitorSelection, pageMode: Bool = false, fixedWidth: CGFloat? = 292) {
        self.selection = selection
        self.pageMode = pageMode
        self.fixedWidth = fixedWidth
    }
    public var body: some View {
        if isSettingsPreview {
            let values = MonitorDetailPreviewValues.fixed
            MonitorDetailContent(selection: previewSelection, sample: previewSample, history: previewHistory,
                                 stats: previewStats, extra: values.extra, volumes: values.volumes,
                                 pageMode: pageMode, fixedWidth: fixedWidth)
        } else {
            LiveMonitorDetailView(selection: selection, pageMode: pageMode, fixedWidth: fixedWidth)
        }
    }

    private var previewSample: MonitorSample {
        var sample = MonitorDetailPreviewValues.fixed.sample
        if !presentation.previewTemperatures { sample.temperatures = [:] }
        return sample
    }
    private var previewStats: StatsSnapshot {
        var stats = MonitorDetailPreviewValues.fixed.stats
        if !presentation.previewTemperatures { stats.sensors.removeAll { $0.category == 0 } }
        return stats
    }
    private var previewHistory: MonitorSampler.History {
        var history = MonitorDetailPreviewValues.fixed.history
        if presentation.previewInterval != 1 {
            let end = history.timestamps.last!
            history.timestamps = history.timestamps.indices.map { end + Double($0 - 59) * presentation.previewInterval }
            history.intervals = Array(repeating: presentation.previewInterval, count: 60)
        }
        if !presentation.previewTemperatures { history.temperatures = [:] }
        return history
    }
}

private struct LiveMonitorDetailView: View {
    @ObservedObject var selection: MonitorDetailSelection
    @ObservedObject private var sampler = MonitorSampler.shared
    @ObservedObject private var memoryOptimizer = MemoryOptimizer.shared
    @ObservedObject private var volumeStore = DiskVolumeStore.shared
    let pageMode: Bool
    let fixedWidth: CGFloat?

    var body: some View {
        MonitorDetailContent(selection: selection, sample: sampler.sample, history: sampler.history,
                             stats: StatsDataProvider.shared.current, extra: MonitorExtra.current,
                             volumes: volumeStore.volumes, liveSampler: sampler,
                             memoryOptimizer: memoryOptimizer,
                             pageMode: pageMode, fixedWidth: fixedWidth)
    }
}

private struct MonitorDetailContent: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var selection: MonitorDetailSelection
    @Environment(\.monitorPresentation) private var presentation
    let sample: MonitorSample
    let history: MonitorSampler.History
    let stats: StatsSnapshot
    let extra: MonitorExtra.Snapshot
    let volumes: [DiskVolume]
    var liveSampler: MonitorSampler? = nil
    var memoryOptimizer: MemoryOptimizer? = nil
    /// 页面模式：只渲染模块内容，标签行与底栏由 StatsPageView 提供（宽度撑满、无固定 292 限宽）
    let pageMode: Bool
    /// 固定宽度（nil = 撑满容器；独立窗 v71 传 nil 消除两侧留白，菜单栏 popover 保留 292）
    let fixedWidth: CGFloat?
    /// 温度页：原始传感器列表默认折叠（v181 起主视图换成 4 条热区）
    @Stored private var showsAllTemperatures = false
    @Stored private var hoveredModule: MonitorModuleID? = nil
    @Stored private var thermalSensor = ""
    @FocusState private var focusedModule: MonitorModuleID?

    init(selection: MonitorDetailSelection, sample: MonitorSample, history: MonitorSampler.History,
         stats: StatsSnapshot, extra: MonitorExtra.Snapshot, volumes: [DiskVolume],
         liveSampler: MonitorSampler? = nil, memoryOptimizer: MemoryOptimizer? = nil,
         pageMode: Bool, fixedWidth: CGFloat?) {
        self.selection = selection; self.sample = sample; self.history = history
        self.stats = stats; self.extra = extra; self.volumes = volumes
        self.liveSampler = liveSampler; self.memoryOptimizer = memoryOptimizer
        self.pageMode = pageMode; self.fixedWidth = fixedWidth
    }

    public var body: some View {
        Group {
        if !pageMode && availableModules().isEmpty {
            Text("尚未启用监测模块，可在监测设置中开启")
                .font(.system(size: Theme.TextSize.body)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pageMode {
            detailBody
        } else {
            GeometryReader { geometry in
                if geometry.size.width >= 600 {
                    HStack(alignment: .top, spacing: 16) {
                        ScrollView(.vertical) {
                            VStack(spacing: 6) {
                                ForEach(availableModules(), id: \.self) { moduleButton($0, wide: true) }
                            }
                        }.islandGlowClip().frame(width: 150)
                        detailColumn
                    }
                } else {
                    VStack(spacing: 10) { modulePicker; Divider().opacity(0.5); detailColumn }
                }
            }
            .padding(12)
            .frame(width: fixedWidth, alignment: .leading)
        }
        }
        .onAppear { ensureSelection() }
        .onChange(of: availableModules()) { _ in ensureSelection() }
    }

    private func ensureSelection() {
        if pageMode { return }
        let modules = availableModules()
        if let first = modules.first, !modules.contains(selection.module) { selection.module = first }
    }

    private var detailColumn: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: true) { detailBody }.islandGlowClip()
            Divider().opacity(0.5)
            footer
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(selection.module.displayName, systemImage: selection.module.systemImage)
                    .font(.system(size: Theme.TextSize.title, weight: .semibold))
                Spacer()
                if isSettingsPreview {
                    Text(presentation.previewEnabled ? "模拟预览" : "监测已关闭")
                        .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                } else if !MonitorPreferences.isModuleEnabled(selection.module) {
                    Text("模块入口已关闭").font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                } else if liveSampler?.isRunning == false {
                    Text("监测已关闭").font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                }
            }
            if selection.module == .sensors {
                let sensors = Array(history.temperatures.keys).sorted()
                if !sensors.isEmpty {
                    Picker("温度传感器", selection: Binding(get: { sensorName }, set: { thermalSensor = $0 })) {
                        ForEach(sensors, id: \.self) { key in
                            Text(stats.sensors.first { $0.key == key }?.name ?? key).tag(key)
                        }
                    }
                } else {
                    Text((isSettingsPreview ? presentation.previewTemperatures : MonitorPreferences.showTemperatures) ? "尚未读取到温度传感器" : "温度采集已关闭")
                        .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                }
            }
            MonitorTrendChart(data: MonitorTrendData(module: selection.module, history: history, sensor: sensorName,
                                                    sensorLabel: stats.sensors.first { $0.key == sensorName }?.name,
                                                    tint: presentation.colors[selection.module]),
                              selection: selection, interaction: presentation.interaction)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sensorName: String {
        selection.module == .sensors ? (thermalSensor.isEmpty ? history.temperatures.keys.sorted().first ?? "" : thermalSensor) : ""
    }

    // MARK: - 模块切换

    /// v60：切换条不再横向滑动（用户反馈"网络/磁盘/温度/电池/GPU 要滑很久"）——
    /// 改自适应换行布局：宽够一行摆下，不够自动折行，全部模块直接可点。
    ///
    /// v82（2026-10-19 修复「GPU/内存等按钮点不动」）：选中胶囊此前用
    /// matchedGeometryEffect 且放在 `.background {}` 内——macOS SwiftUI 在该组合下
    /// 会生成一层不可见拦截视图，未选中按钮收不到点击（选中项自身有视觉反馈，
    /// 用户感知为「只有当前模块点得动、其他点不动」）。现改为普通条件填充，
    /// 显式 contentShape 保证整个胶囊区域可命中。
    private var modulePicker: some View {
        FlowHStack(spacing: 6, lineSpacing: 6) {
            ForEach(availableModules(), id: \.self) { module in
                moduleButton(module, wide: false)
            }
        }
    }

    private func moduleButton(_ module: MonitorModuleID, wide: Bool) -> some View {
        let selected = selection.module == module
        return Button { selection.module = module } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(module.displayName, systemImage: module.systemImage)
                    .font(.system(size: Theme.TextSize.small, weight: .medium))
                if wide { Text(currentValue(module)).font(.system(size: Theme.TextSize.caption).monospacedDigit()).foregroundStyle(.secondary) }
            }.frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, wide ? 10 : 7)
                .background(selected ? Theme.accent.opacity(0.14) : hoveredModule == module ? Theme.rowHoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(
                    focusedModule == module ? Theme.accent : selected ? Theme.accent.opacity(0.4) : .clear,
                    style: StrokeStyle(lineWidth: 1, dash: focusedModule == module ? [3, 2] : [])))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).focusable().focused($focusedModule, equals: module)
            .modifier(IslandGlowTarget(radius: Theme.Radius.control))
            .onHover { if $0 { hoveredModule = module } else if hoveredModule == module { hoveredModule = nil } }
            .onMoveCommand { direction in
                let modules = availableModules()
                guard let index = modules.firstIndex(of: module) else { return }
                let step = direction == .up || direction == .left ? -1 : 1
                let next = modules[min(max(index + step, 0), modules.count - 1)]
                focusedModule = next; selection.module = next
            }
            .accessibilityLabel(module.displayName + "，" + currentValue(module))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func currentValue(_ module: MonitorModuleID) -> String {
        if !isSettingsPreview && history.timestamps.isEmpty { return liveSampler?.isRunning == true ? "等待采样" : "监测已关闭" }
        switch module {
        case .cpu: return MonitorFormat.percent(sample.cpuUsage)
        case .gpu: return stats.gpuUsage >= 0 ? MonitorFormat.percent(stats.gpuUsage) : "GPU 尚无读数"
        case .memory: return MonitorFormat.bytes(sample.memoryUsed)
        case .network: return "↓ " + MonitorFormat.rate(sample.netDownload)
        case .disk: return "读 " + MonitorFormat.rate(sample.diskRead)
        case .sensors: return sample.temperatures.values.max().map(MonitorFormat.temperature) ?? "尚无传感器读数"
        case .power: return sample.powerWatts.map(MonitorFormat.power) ?? "整机传感器尚无读数"
        case .battery: return sample.batteryLevel.map(MonitorFormat.percent) ?? "未检测到电池"
        }
    }

    /// 可选模块：过滤掉无数据的项，但始终保留当前选中项
    /// v88（2026-10-20 用户反馈「监测设置改变后没有生效」）：设置里关掉的模块
    /// 此前只影响状态栏项、不从监测中心过滤——补上开关过滤（当前选中项保留，
    /// 避免选中态突然消失）。
    private func availableModules() -> [MonitorModuleID] {
        if isSettingsPreview, let order = presentation.order { return order }
        var modules: [MonitorModuleID] = []
        for module in presentation.order ?? [.cpu, .gpu, .memory, .network, .disk, .sensors, .power, .battery] {
            if !MonitorPreferences.isModuleEnabled(module) {
                continue
            }
            switch module {
            case .sensors:
                modules.append(module)
            case .battery:
                modules.append(module)
            case .gpu:
                modules.append(module)
            default:
                modules.append(module)
            }
        }
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

    // MARK: - 功耗（整机与芯片分开，不重复累加上下级传感器）

    private var powerPanel: some View {
        let sensors = stats.sensors.filter { $0.category == 4 }
        return VStack(alignment: .leading, spacing: 12) {
            powerOverview
            MonitorSectionTitle("供电流向")
            powerFlow
            MonitorSectionTitle("芯片功耗")
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    powerGrid(columns: 3).frame(minWidth: 426)
                    powerGrid(columns: 2)
                }
                Text("彩条表示占芯片合计的比例；芯片已计入整机。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).glassCard(radius: Theme.Radius.card)
            if !isSettingsPreview {
                CPUEnergyImpactSection(stats: stats)
                    .padding(12).glassCard(radius: Theme.Radius.card)
            }
            DisclosureGroup("读数说明与传感器") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("整机读取 PSTR 系统负载；适配器输入含充电。芯片各项按能量差分计算。— 表示尚无有效读数。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(sensors, id: \.key) { sensor in
                        MonitorRow(label: sensor.name, value: MonitorFormat.power(sensor.value))
                            .help("\(sensor.name) · \(sensor.key) · 独立传感器读数")
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 12))
            .padding(12).glassCard(radius: Theme.Radius.card)
        }
    }

    // 2026-11-15：主面板、状态栏展开页与设置预览共用曲线和流向，不再只是重排数字框。
    private var powerUsesBattery: Bool { stats.battery?.present == true && !sample.externalPower }

    private var powerOverview: some View {
        return VStack(alignment: .leading, spacing: 8) {
            Label(powerUsesBattery ? "电池供电" : "外部电源",
                  systemImage: powerUsesBattery ? "battery.75percent" : "powerplug.fill")
                .font(.system(size: Theme.TextSize.small)).foregroundStyle(.secondary)
            MonitorRow(label: "适配器输入（含充电）", value: sample.inputPowerWatts.map(MonitorFormat.power) ?? "尚无输入读数")
            Text("整机负载来自 PSTR；芯片合计与组件明细已包含在整机中，不重复相加。")
                .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var powerFlow: some View {
        let battery = BatteryFlowModel(battery: stats.battery)
        let hasBattery = stats.battery?.present == true
        let source = powerUsesBattery ? (battery.input.available ? battery.input.watts : nil) : sample.inputPowerWatts
        let input = MonitorFlowNode(id: "power-source", title: powerUsesBattery ? "电池放电" : "适配器输入",
                                    value: source ?? 0, valueText: source.map(MonitorFormat.power) ?? "—",
                                    systemImage: powerUsesBattery ? "battery.50percent" : "powerplug.fill",
                                    color: MonitorColors.temperature, available: source != nil)
        var branches = [MonitorFlowNode(id: "power-system", title: "整机负载",
                            value: sample.powerWatts ?? 0, valueText: sample.powerWatts.map(MonitorFormat.power) ?? "—",
                            systemImage: "desktopcomputer", color: MonitorColors.user, available: sample.powerWatts != nil)]
        if !powerUsesBattery, hasBattery, let charge = battery.branches.first(where: { $0.id == "charge" }) {
            branches.append(MonitorFlowNode(id: charge.id, title: charge.title, value: charge.watts,
                                valueText: MonitorFormat.power(charge.watts), systemImage: charge.systemImage,
                                color: MonitorColors.battery, available: charge.available))
        }
        return MonitorFlowCard(input: input, branches: branches, height: 88, plate: .gridded)
            .transaction { if reduceMotion { $0.animation = nil } }
            .help("适配器、整机与电池使用各自实测值；流带粗细按瓦数绘制")
    }

    private func powerGrid(columns: Int) -> some View {
        let metrics: [(String, Double?, String, Color)] = [
            ("CPU", sample.cpuPowerWatts, "cpu", MonitorColors.user),
            ("GPU", sample.gpuPowerWatts, "display", MonitorColors.download),
            ("神经网络引擎", sample.anePowerWatts, "brain", MonitorColors.wired),
            ("内存", sample.ramPowerWatts, "memorychip", MonitorColors.memory),
            ("内存控制器", sample.dcsPowerWatts, "arrow.left.arrow.right", MonitorColors.compressed),
            ("芯片合计", sample.chipPowerWatts, "square.stack.3d.up", MonitorColors.temperature)
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns), alignment: .leading, spacing: 16) {
            ForEach(metrics, id: \.0) { title, watts, symbol, color in
                powerMetric(title, watts: watts, symbol: symbol, color: color)
            }
        }
    }

    private func powerMetric(_ title: String, watts: Double?, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
            Text(watts.map(MonitorFormat.power) ?? "—")
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
            GeometryReader { meter in
                Capsule().fill(Color.primary.opacity(0.07))
                if let watts, let total = sample.chipPowerWatts, total > 0 {
                    Capsule().fill(color.gradient)
                        .frame(width: meter.size.width * min(1, max(0, watts / total)))
                }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - CPU

    private var cpuPanel: some View {
        let cores = isSettingsPreview ? 8 : Double(max(1, CPUHardware.logicalCores))

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    MonitorRow(label: "系统", value: MonitorFormat.percent(sample.systemCPU), color: MonitorColors.system)
                    MonitorRow(label: "用户", value: MonitorFormat.percent(sample.userCPU), color: MonitorColors.user)
                    MonitorRow(label: "空闲", value: MonitorFormat.percent(sample.idleCPU), color: .secondary)
                    // 启动时间（原版 v56：图例第四行"启动时间 4 天 19 小时"）
                    MonitorRow(label: "启动时间", value: isSettingsPreview ? "2 天 4 小时" : Self.uptimeText())
                }
            }

            // v183：芯片规格 + 热压力。原页面顶部只有两个环和四行数字，
            // 读不到温度传感器时还会空出半个环位——这里用一行把「这台机器是什么」补上。
            chipStrip(stats)
            if let temperature = primaryTemperature() {
                MonitorRow(label: "CPU 温度", value: MonitorFormat.temperature(temperature), color: MonitorColors.temperature)
            }

            // v183：每核心从小蓝块换成带刻度的迷你柱（核编号 + 百分比），
            // 集群占用从三行文字改成胶囊——原来「M0」还会凭空多出一行 0%。
            MonitorSectionTitle("核心占用（\(max(sample.perCore.count, 0)) 核）")
            if sample.perCore.isEmpty {
                Text("等待核心采样…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                MonitorCoreGrid(values: sample.perCore)
            }
            if stats.cpuSuperCores > 0 {
                HStack(spacing: 6) {
                    MonitorClusterPill(title: "性能核 P\(stats.cpuSuperCores)",
                                       value: stats.clusterSuperUsage,
                                       color: MonitorColors.user)
                    MonitorClusterPill(title: "能效核 E\(stats.cpuEffCores)",
                                       value: stats.clusterEffUsage,
                                       color: MonitorColors.download)
                    if stats.cpuMedCores > 0 {
                        MonitorClusterPill(title: "中核 M\(stats.cpuMedCores)",
                                           value: stats.clusterMedUsage,
                                           color: MonitorColors.memory)
                    }
                }
            }

            MonitorSectionTitle("平均负载")
            HStack(spacing: 10) {
                loadCell("1 分钟", value: extra.loadAverages[0])
                loadCell("5 分钟", value: extra.loadAverages[1])
                loadCell("15 分钟", value: extra.loadAverages[2])
            }
            // 负载是「排队任务数」不是百分比：不给核心数做分母，7.6 是高是低没人知道
            let perCore1 = extra.loadAverages[0] / cores
            Text("每核负载 \(MonitorFormat.load(perCore1))"
                 + " · \(MonitorFormat.load(extra.loadAverages[1] / cores))"
                 + " · \(MonitorFormat.load(extra.loadAverages[2] / cores))"
                 + "（> 1 表示有任务在排队）")
                .font(.system(size: 10))
                .foregroundStyle(perCore1 > 1 ? MonitorColors.compressed : Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            // v84（用户需求「归类 + 展开 + 图标 + 退出」）：高占用进程改用统一进程表——
            // 按 App 归类（Helper/Renderer 合并）、真实图标、点击展开组内明细、右键退出。
            let procs = Array(stats.procCPU.prefix(8))
            if !procs.isEmpty {
                StatsProcTable(title: "CPU 占用进程",
                               columns: [.init(title: "CPU")],
                               items: procs,
                               values: { [String(format: "%.0f%%", $0.cpu)] })
            }
        }
    }

    /// 芯片规格 + 热压力（一行，不占高度）
    private func chipStrip(_ stats: StatsSnapshot) -> some View {
        let thermal = isSettingsPreview ? (text: "热压力 正常", color: MonitorColors.memory) : CPUHardware.thermal
        var chip = isSettingsPreview ? "Apple M3 · 8 核" : "\(CPUHardware.brand) · \(CPUHardware.logicalCores) 核"
        if stats.cpuSuperCores > 0 && stats.cpuEffCores > 0 {
            chip += "（P\(stats.cpuSuperCores) + E\(stats.cpuEffCores)）"
        }
        chip += isSettingsPreview ? " · macOS 15.0" : " · macOS \(CPUHardware.osVersion)"

        return HStack(spacing: 7) {
            Image(systemName: "cpu")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            Text(chip)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(chip)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Circle().fill(thermal.color).frame(width: 5, height: 5)
                Text(thermal.text)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(thermal.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(thermal.color.opacity(0.10)))
            // 不被左侧芯片名挤扁（原来会被压到只剩半个字）
            .fixedSize()
            .help("热压力：\(thermal.text.replacingOccurrences(of: "热压力 ", with: ""))")
        }
    }

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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(MonitorFormat.load(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryTemperature() -> Double? {
        let temperatures = sample.temperatures
        for key in ["CPU 包温", "CPU 二极管", "CPU 邻近"] {
            if let value = temperatures[key] { return value }
        }
        if let any = temperatures.values.first { return any }
        // v183：温度采样受「采集温度」开关/传感器扫描节流影响，可能这一帧为空——
        // 兜底用温度页同一套热区（CPU 区最热那颗），避免顶部平白空出半个环位。
        return MonitorThermalZones
            .build(from: stats.sensors)
            .first(where: { $0.id == "cpu" })?
            .celsius
    }

    // MARK: - 内存

    private var memoryPanel: some View {
        let compressed = stats.memCompressed > 0 ? stats.memCompressed : extra.compressedMemory
        let wired = stats.memWired
        let app = max(0, Double(sample.memoryUsed) - Double(compressed) - Double(wired))
        let freeMemory = Double(sample.memoryTotal > sample.memoryUsed
                                ? sample.memoryTotal - sample.memoryUsed : 0)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                MonitorRow(label: "已用", value: MonitorFormat.bytes(sample.memoryUsed))
                MonitorRow(label: "总量", value: MonitorFormat.bytes(sample.memoryTotal))
                MonitorRow(label: "交换", value: MonitorFormat.bytes(sample.swapUsed))
                MonitorRow(label: "压缩", value: MonitorFormat.bytes(compressed), color: MonitorColors.compressed)
                MonitorRow(label: "压力状态", value: stats.memPressureLevel == 4 ? "严重" : stats.memPressureLevel == 2 ? "警告" : stats.memPressureLevel == 1 ? "正常" : "尚无系统压力读数",
                           color: stats.memPressureLevel == 4 ? MonitorColors.system : stats.memPressureLevel == 2 ? MonitorColors.compressed : MonitorColors.memory)
            }

            if let memoryOptimizer { MemoryOptimizeSection(optimizer: memoryOptimizer) }

            // v181：四段构成（应用 / 压缩 / 联动 / 空闲）。
            // 原实现把「总量 − 已用」当成「联动/空闲」一段，把 wired 和 free 混在一起，
            // 看图分不出「被系统锁住的」和「真的还能用」的——现在拆开，并单独标可回收量。
            MonitorSectionTitle("内存构成")
            MonitorStackedBar(segments: [
                .init(id: "app", value: app, color: MonitorColors.memory),
                .init(id: "compressed", value: Double(compressed), color: MonitorColors.compressed),
                .init(id: "wired", value: Double(stats.memWired), color: MonitorColors.wired),
                .init(id: "free", value: freeMemory, color: Color.primary.opacity(0.12))
            ], height: 10)
            HStack(spacing: 10) {
                legendItem("应用", color: MonitorColors.memory)
                legendItem("压缩", color: MonitorColors.compressed)
                legendItem("联动", color: MonitorColors.wired)
                legendItem("空闲", color: .secondary)
            }
            .font(.system(size: 11))
            // v216：只留数字，删掉「（压缩内存可被系统丢弃后重新换出）」解释。
            Text("可回收 ≈ \(MonitorFormat.bytes(MonitorFormat.u64(Double(compressed))))")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)

            // v84（用户需求「内存界面也要有进程占用排序」）：内存占用进程表——
            // 与 CPU 页同一组件（归类 + 图标 + 展开 + 右键退出），按 footprint 降序。
            let memProcs = Array(stats.procMem.prefix(8))
            if !memProcs.isEmpty {
                StatsProcTable(title: "内存占用进程",
                               columns: [.init(title: "内存")],
                               items: memProcs,
                               values: { [MonitorFormat.bytes(MonitorFormat.u64($0.memBytes))] })
            }
        }
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(.secondary)
        }
    }

    // MARK: - 可视化数据整形（v181）

    /// 各 App 的带宽分支（v183）：Top 4 + 其余聚合成「其他 N 个」。
    /// 阈值 512 B/s：低于此的进程是连接保活噪声，画成流带只会闪。
    /// 网络分流分支：按「最近 10 分钟窗口累计字节」排序，取设置的条数
    /// （设置 → 监测 → 网络 → 分流显示条数，默认 4）。
    /// 数值单位是**窗口内累计字节**，不是瞬时速率——用户要的是「这十分钟谁吃掉了带宽」。
    private func networkFlowNodes(_ snapshot: NetworkFlowTracker.Snapshot,
                                  limit: Int) -> [MonitorFlowNode] {
        let colors: [Color] = [MonitorColors.download, MonitorColors.upload,
                               MonitorColors.compressed, MonitorColors.wired,
                               MonitorColors.battery, MonitorColors.system,
                               MonitorColors.read, MonitorColors.write]
        guard !snapshot.entries.isEmpty else { return [] }

        var nodes = snapshot.entries.prefix(limit).enumerated().map { index, entry -> MonitorFlowNode in
            let detail = "10 分钟 \(MonitorFormat.bytes(MonitorFormat.u64(entry.totalBytes)))" +
                " · 当前 ↓\(MonitorFormat.rate(MonitorFormat.u64(entry.liveDown)))" +
                " ↑\(MonitorFormat.rate(MonitorFormat.u64(entry.liveUp)))"
            return MonitorFlowNode(id: entry.key,
                                   title: entry.name,
                                   value: entry.totalBytes,
                                   valueText: MonitorFormat.bytes(MonitorFormat.u64(entry.totalBytes)),
                                   systemImage: "app",
                                   color: colors[index % colors.count],
                                   available: true,
                                   compactValue: true,
                                   iconImage: isSettingsPreview ? nil : NetworkFlowIcon.icon(forPath: entry.iconPath),
                                   detail: detail,
                                   isActive: entry.liveTotal > 1024)
        }

        // 「其他」= 整机窗口总量 − 已列出的 App（不把看不见的进程算成 0）。
        // nettop 只给快照前 8 个进程，短时突发（几秒内下完的大文件）可能整段没被采样到，
        // 这部分记作「未采集」——标题如实区分，不能把没归因的流量说成某几个 App 用的。
        let listed = snapshot.entries.prefix(limit).reduce(0) { $0 + $1.totalBytes }
        let knownTotal = snapshot.entries.reduce(0) { $0 + $1.totalBytes }
        let restBytes = max(0, snapshot.nicTotalBytes - listed)
        let restCount = max(0, snapshot.entries.count - limit)
        let knownRest = max(0, knownTotal - listed)
        let unattributed = max(0, snapshot.nicTotalBytes - knownTotal)
        if restBytes > 64 * 1024 {
            let title: String
            if unattributed > knownRest {
                title = restCount > 0 ? "其他 \(restCount) 个 / 未采集" : "未采集"
            } else {
                title = restCount > 0 ? "其他 \(restCount) 个" : "其他"
            }
            nodes.append(MonitorFlowNode(
                id: "net-other",
                title: title,
                value: restBytes,
                valueText: MonitorFormat.bytes(MonitorFormat.u64(restBytes)),
                systemImage: "ellipsis",
                color: Color.primary.opacity(0.35),
                available: true,
                compactValue: true,
                detail: "整机窗口总量减去已列出的 App（其中未采集 \(MonitorFormat.bytes(MonitorFormat.u64(unattributed)))：nettop 只采前 8 个进程，且在两次采样之间退出的进程（如命令行下载）其流量无法归属）"))
        }
        return nodes
    }

    /// 窗口覆盖说明：不足 10 分钟如实写「已统计 X 分钟」，不假装满窗
    private func flowCoverageText(_ coverage: TimeInterval) -> String {
        // v216：删掉「按窗口流量排序」这类操作解释，只留统计时长本身。
        if coverage < 60 { return "刚开始统计 · 已 \(Int(max(0, coverage))) 秒" }
        let minutes = Int(coverage / 60)
        if minutes >= 10 { return "最近 10 分钟" }
        return "最近 \(minutes) 分钟"
    }

    // MARK: - 网络

    private var networkPanel: some View {
        let flowSnapshot = isSettingsPreview ? MonitorDetailPreviewValues.flow : NetworkFlowTracker.shared.snapshot()
        let netBranches = networkFlowNodes(flowSnapshot, limit: isSettingsPreview ? presentation.previewFlowTopN : MonitorPreferences.flowTopN)

        return VStack(alignment: .leading, spacing: 10) {
            // v183「带宽去哪了」：与充电/电池页**同一张流向图**（用户明确要求：
            // 「要的是跟充电那边类似的分流图，不是条形状的」）。
            // 之前的溢出根因在流向卡本身（固定 116pt 高 + 四格硬塞），已在
            // MonitorFlowCard 里改成按分支数反推高度、图标与数值同行、名字中间省略。
            //
            // v191（用户：「就跟其他的组件一样，就一直放在那，只是会变化它显示的那个 App」）：
            // 区块**不再**因为窗口里没数据就整块消失——没流量时给等高的空态，
            // 保证这个卡片的位置固定，用户打开永远看到它在那儿。
            MonitorSectionTitle("流量去哪了")
            if netBranches.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("最近 10 分钟没有 App 传输数据")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            } else {
                // 左侧总数 = 分支之和（含「其他 N 个」），保证「流带加起来 = 左边」
                let branchSum = netBranches.reduce(0) { $0 + $1.value }
                MonitorFlowCard(
                    input: MonitorFlowNode(
                        id: "net-in", title: "合计",
                        value: branchSum,
                        valueText: MonitorFormat.bytes(MonitorFormat.u64(branchSum)),
                        systemImage: "arrow.up.arrow.down",
                        color: MonitorColors.download,
                        available: true, compactValue: true),
                    branches: netBranches)
            }
            Text(flowCoverageText(flowSnapshot.coverage))
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            MonitorRow(label: "峰值下载", value: MonitorFormat.rate(extra.netPeakDownload), color: MonitorColors.download)
            MonitorRow(label: "峰值上传", value: MonitorFormat.rate(extra.netPeakUpload), color: MonitorColors.upload)
            MonitorRow(label: "累计下载", value: MonitorFormat.bytes(extra.netTotalIn))
            MonitorRow(label: "累计上传", value: MonitorFormat.bytes(extra.netTotalOut))

            // 连通性（官方 ConnectivityReader：ICMP → 1.1.1.1，1s/包）
            if stats.connStatus != .unknown {
                MonitorSectionTitle("连通性探测")
                HStack(spacing: 6) {
                    Circle()
                        .fill(stats.connStatus == .online ? MonitorColors.battery : MonitorColors.system)
                        .frame(width: 8, height: 8)
                    Text(stats.connStatus == .online ? "目标可达" : "目标未响应")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .help("探测 1.1.1.1 的响应；目标未响应时，本机仍可能正常联网。")
                // 连通性历史网格（30×3=90 格，最新在右下，官方同布局）
                if !stats.connHistory.isEmpty {
                    let columns = 30
                    let rows = 3
                    let totalSlots = columns * rows
                    // v183：右对齐——历史不足 90 个时，空格子留**左上**，
                    // 最新一格永远在右下。原来从左上开始填，刚启动会看到「第一行全空、
                    // 第二行半截有颜色」，像网格坏了。
                    let offset = max(0, totalSlots - stats.connHistory.count)
                    Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
                        ForEach(0..<rows, id: \.self) { row in
                            GridRow {
                                ForEach(0..<columns, id: \.self) { col in
                                    let slot = row * columns + col
                                    let index = slot - offset
                                    let value = index >= 0 && index < stats.connHistory.count
                                        ? stats.connHistory[index] : -1
                                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                                        .fill(connCellColor(value))
                                        .frame(height: 5)
                                }
                            }
                        }
                    }
                    .font(.system(size: 5))
                    .help("最近 90 次连通性探测，最新的在右下")
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
            // v84：统一进程表（归类 + 图标 + 展开 + 右键退出）
            if !stats.procNet.isEmpty {
                // 分流卡已经按 10 分钟窗口回答了「谁在吃带宽」，这张表只保留实时速率明细，
                // 默认折叠——两处并排展示同一批 App 是之前的冗余来源。
                DisclosureGroup {
                    StatsProcTable(title: "",
                                   columns: [.init(title: "下行"), .init(title: "上行")],
                                   items: Array(stats.procNet.prefix(8)),
                                   values: { item in
                                       [MonitorFormat.rate(MonitorFormat.u64(item.diskRead)),
                                        MonitorFormat.rate(MonitorFormat.u64(item.diskWrite))]
                                   })
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("进程明细（实时速率）")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                }
                .animation(reduceMotion ? nil : Theme.Motion.fast, value: stats.procNet.count)
            }

            // 端口占用（2026-10-20）：本机监听端口 + 进程归属 + 是否对外暴露。
            // 放在网络页最底部；页面本身在 ScrollView 内，窗口高度达上限后可滚动查看。
            if !isSettingsPreview { PortOccupancySection() }
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
        let used = stats.diskTotalBytes > stats.diskFreeBytes ? stats.diskTotalBytes - stats.diskFreeBytes : 0
        let purgeable: UInt64 = isSettingsPreview ? 24 * 1_073_741_824 : MonitorDiskSpace.purgeableBytes(freeBytes: stats.diskFreeBytes)
        return VStack(alignment: .leading, spacing: 10) {
            storageEntryButton

            MonitorRow(label: "峰值读取", value: MonitorFormat.rate(extra.diskPeakRead), color: MonitorColors.read)
            MonitorRow(label: "峰值写入", value: MonitorFormat.rate(extra.diskPeakWrite), color: MonitorColors.write)

            // 容量（官方 Disk 卡片：名称行/图表盒/容量条/图例/详情行）
            if stats.diskTotalBytes > 0 {
                // v181（用户：「磁盘容量构成：可清除 / 已用 / 空闲」）：
                // 原来只有「已用 vs 可用」两段——macOS 的「可用」其实还藏着一块
                // 系统按需回收的空间（快照/缓存/废纸篓），不画出来会让人以为盘要满了。
                MonitorSectionTitle("容量构成")
                VStack(spacing: 6) {
                    MonitorStackedBar(segments: [
                        .init(id: "used", value: Double(used - min(used, purgeable)),
                              color: MonitorColors.read),
                        .init(id: "purgeable", value: Double(min(used, purgeable)),
                              color: MonitorColors.compressed),
                        .init(id: "free", value: Double(stats.diskFreeBytes),
                              color: Color.primary.opacity(0.12))
                    ], height: 10)
                    HStack(spacing: 10) {
                        legendItem("已用 \(MonitorFormat.bytes(used))", color: MonitorColors.read)
                        if purgeable > 0 {
                            legendItem("可清除 \(MonitorFormat.bytes(purgeable))", color: MonitorColors.compressed)
                        }
                        legendItem("空闲 \(MonitorFormat.bytes(stats.diskFreeBytes))", color: .secondary)
                    }
                    .font(.system(size: 11))
                    MonitorRow(label: "总量", value: MonitorFormat.bytes(stats.diskTotalBytes))
                    // v211（用户：「总容量条下面那一串话需要删掉」）：删掉「可清除」的说明长句。
                }
                // v215：入口按钮移到上方「读写历史」图的左上角（不再单独占一行）。
            }

            // v217（用户：「插入 U 盘或其他盘符时自动加载出来」）：
            // 只在外置/可移动/网络卷存在时出现；内置启动卷已由上面的容量构成覆盖。
            if !volumes.isEmpty {
                MonitorSectionTitle("外置磁盘")
                ForEach(volumes) { volume in
                    externalVolumeCard(volume)
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
            // v84：统一进程表（归类 + 图标 + 展开 + 右键退出）
            if !stats.procDisk.isEmpty {
                StatsProcTable(title: "磁盘占用进程",
                               columns: [.init(title: "读"), .init(title: "写")],
                               items: Array(stats.procDisk.prefix(8)),
                               values: { item in
                                   [MonitorFormat.rate(MonitorFormat.u64(item.diskRead)),
                                    MonitorFormat.rate(MonitorFormat.u64(item.diskWrite))]
                               })
            }

            // v216（用户：「磁盘占用进程下面的那句统计来源删掉」）：删除整行脚注。

            // v211（用户：「把这个存储详情移到最后」）：文件系统/连接类型/型号
            // 从容量构成下方挪到整页末尾，先看动态数据，静态规格收尾。
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
        }
    }

    /// 外置卷卡片（v217）：名称 + 类型标签 + 容量条 + 已用/可用/总量
    private func externalVolumeCard(_ v: DiskVolume) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: v.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14)
                Text(v.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(v.isReadOnly ? "\(v.kindText) · 只读" : v.kindText)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }

            MonitorStackedBar(segments: [
                .init(id: "used", value: Double(v.used), color: MonitorColors.read),
                .init(id: "free", value: Double(max(0, v.free)), color: Color.primary.opacity(0.12))
            ], height: 6)

            HStack(spacing: 10) {
                Text("已用 \(MonitorFormat.bytes(UInt64(v.used)))")
                Text("可用 \(MonitorFormat.bytes(UInt64(max(0, v.free))))")
                Spacer(minLength: 0)
                Text("共 \(MonitorFormat.bytes(UInt64(v.total)))")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard(radius: Theme.Radius.card)
    }

    /// 存储管理入口（v215）
    ///
    /// 用户：「圆角不对，在当前比例下的圆角不对，按钮周围有一圈蓝色的框，
    /// 需要和周围的 UI 一致；不要单独在一行，放在统计图的左上角」。
    ///   · 20pt 高的小按钮配 `Radius.chip`（6pt）—— 之前 28pt 高配胶囊（半径 14）
    ///     在监测面板这种紧凑密度里过于「胶囊」，跟周围的方正行不搭；
    ///   · `focusable(false)` 去掉键盘焦点环（那圈蓝框）；
    ///   · 由调用方放进 ZStack 底层，折线覆盖在它上面。
    private var storageEntryButton: some View {
        Button {
            if !isSettingsPreview { StorageManagerWindowController.shared.show() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("存储管理")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(Theme.accent.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 0.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("全盘索引、按堆块下钻、把不需要的文件移到废纸篓")
    }

    // MARK: - 温度（传感器：官方名表 + 分类型分节 + 计算项 + 多风扇）

    private var sensorsPanel: some View {
        let temperatures = sample.temperatures
        let hasDeep = !stats.sensors.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            if temperatures.isEmpty && !hasDeep {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "thermometer.medium.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("未获取到传感器数据")
                        .font(.system(size: 12, weight: .medium))
                    // v216：删掉「本机 SMC 不可读…已优雅降级…」技术说明，
                    // 空状态只留一句结论。
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else if hasDeep {
                // 计算项（官方 initCalculatedSensors：Average/Hottest CPU/GPU）
                // v74：与温度行同标尺（20~110°C）加可视化条
                // v181（用户：「温度分区热区条（CPU/GPU/电池/SSD）+ 阈值色，替掉长列表」）：
                // 原来「计算项 4 行 + 温度 6 行 + 电压/电流/功率/能耗各 3 行」一屏全是数字条，
                // 现在先给 4 条按阈值着色的热区，原始传感器列表折叠在下面按需展开。
                let zones = MonitorThermalZones.build(from: stats.sensors)
                if !zones.isEmpty {
                    MonitorSectionTitle("热区")
                    MonitorZoneHeatStrip(zones: zones)
                }

                // 风扇（官方顺序：风扇节在最前）
                if !stats.fans.isEmpty {
                    MonitorSectionTitle("风扇")
                    ForEach(stats.fans) { fan in
                        sensorBarRow(name: fan.name,
                                     valueText: StatsFormat.rpm(fan.rpm),
                                     ratio: fan.percent,
                                     color: MonitorColors.temperature)
                    }
                }

                // 按类型分节（官方 Sensors 页顺序：温度 → 电压 → 电流 → 功率）
                temperatureDetailSection(items: stats.sensors)
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
                                    .font(.system(size: 11))
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

            if let level = sample.batteryLevel {
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
                if category == 0 {
                    // v74（用户需求）：温度可视化条——按注入版 v42 规格，
                    // 固定标尺 20~110°C 映射（温度同量纲，绝对值比相对最大值更有信息量），
                    // 颜色 sRGB(0.95,0.60,0.30)（注入版 MC_temperature）。
                    sensorBarRow(name: item.name,
                                 valueText: sensorValueText(item.value, unit: unit),
                                 ratio: min(1, max(0, (item.value - 20) / 90)),
                                 color: MonitorColors.temperature)
                } else {
                    MonitorRow(label: item.name, value: sensorValueText(item.value, unit: unit))
                }
            }
        }
    }

    /// 温度明细（折叠）：热区条之外想看「具体哪颗传感器」时才展开。
    /// 排序按温度降序，前 30 颗足够定位热点——200 多行全铺出来没人看。
    @ViewBuilder
    private func temperatureDetailSection(items: [StatsSensorItem]) -> some View {
        let filtered = items
            .filter { $0.category == 0 && $0.value > 0 && $0.value < 110 }
            .sorted { $0.value > $1.value }
        if !filtered.isEmpty {
            DisclosureGroup(isExpanded: $showsAllTemperatures) {
                ForEach(filtered.prefix(30), id: \.name) { item in
                    sensorBarRow(name: item.name,
                                 valueText: MonitorFormat.temperature(item.value),
                                 ratio: min(1, max(0, item.value / 110)),
                                 color: MonitorThermalZones.color(for: item.value))
                }
            } label: {
                Text("全部温度传感器（\(filtered.count)）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    /// 传感器行：名称 + 进度条 + 数值（Bar 规格对齐注入版 FSPUSensorRow）
    ///
    /// v211（用户：「温度相关的具体名称显示不完全，那个条可能太长了，可以缩短一点，
    /// 让文字显示完整」）：原来名称固定 92pt + lineLimit(1)，像 "CPU Core 3 Performance"
    /// 这类名字被截成 "CPU Core 3 P…"；进度条却吃掉了整行剩余宽度。
    /// 现在把条压到 68pt 定宽，名称列放宽到 168pt 且允许两行 + 字号下浮兜底，
    /// 完整名称始终可读（hover 还有 .help 全文）。风扇行复用同一个函数，两处不再各写一套。
    private func sensorBarRow(name: String, valueText: String, ratio: Double, color: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                .help(name)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color)
                        .frame(width: max(2, min(geo.size.width, geo.size.width * ratio)))
                }
            }
            .frame(width: 68, height: 6)
            Text(valueText)
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 62, alignment: .trailing)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 电池（官方 Battery 页：Dashboard + Health + 适配器段）

    /// 电池页：v190 起「充电」不再单开一页（用户：「充电不需要单开这个界面」）——
    /// 充放电状态 / 进度 / 功率 / 适配器规格并入本页；
    /// 整机能量流向留在「功耗」页，不再各画一张。

    private var batteryPanel: some View {
        // v178（用户：电池展示界面按 Status Trio 改）：整页重做——
        // 功耗流向图 + 明细 + CPU 能耗影响 + 低电量模式，实现在 BatteryPanel.swift。
        // 这里只做接线：监测窗的「电池」页与 Stats 面板共用同一个实现，不写两份。
        BatteryStatsPanel(previewStats: isSettingsPreview ? stats : nil,
                          previewSample: isSettingsPreview ? sample : nil)
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
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

            // v216：删掉「数据来源：IOAccelerator PerformanceStatistics」脚注。
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text("刷新间隔 \(String(format: "%.1f", isSettingsPreview ? presentation.previewInterval : MonitorPreferences.refreshInterval))s")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                liveSampler?.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("立即刷新")
            .disabled(isSettingsPreview)
            Button {
                if !isSettingsPreview { StatsBarEngine.openSettings() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("菜单栏部件设置（Stats 风格：形态 / 间距 / 分隔线）")
            .disabled(isSettingsPreview)
            Button {
                if !isSettingsPreview { ServiceLocator.settings?.open(pane: "monitor") }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("打开监测设置")
            .disabled(isSettingsPreview)
        }
    }
}

// MARK: - 深数据共享组件（进程排行行 / 双值列）

/// 进程排行行（名称 + 自定义数值区）

/// 双数值（左/右，等宽右对齐——官方进程表列序用）
private struct StatsDualValue: View {
    let left: String
    let right: String

    var body: some View {
        HStack(spacing: 8) {
            Text(left).monospacedDigit().frame(width: 62, alignment: .trailing)
            Text(right).monospacedDigit().frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 11))
    }
}


struct MonitorDetailPreviewValues {
    var sample = MonitorSample()
    var history = MonitorSampler.History()
    var stats = StatsSnapshot()
    var extra = MonitorExtra.Snapshot()
    var volumes: [DiskVolume] = []

    static let flow = NetworkFlowTracker.Snapshot(entries: [
        .init(key: "browser", name: "浏览器", iconPath: "", downBytes: 160_000_000, upBytes: 12_000_000,
              liveDown: 2_400_000, liveUp: 300_000),
        .init(key: "kitnest", name: "Kitnest", iconPath: "", downBytes: 20_000_000, upBytes: 8_000_000,
              liveDown: 400_000, liveUp: 100_000),
        .init(key: "editor", name: "编辑器", iconPath: "", downBytes: 12_000_000, upBytes: 4_000_000, liveDown: 100_000, liveUp: 30_000),
        .init(key: "download", name: "下载工具", iconPath: "", downBytes: 8_000_000, upBytes: 1_000_000, liveDown: 200_000, liveUp: 10_000),
        .init(key: "sync", name: "同步", iconPath: "", downBytes: 4_000_000, upBytes: 8_000_000, liveDown: 30_000, liveUp: 100_000),
        .init(key: "mail", name: "邮件", iconPath: "", downBytes: 2_000_000, upBytes: 1_000_000, liveDown: 10_000, liveUp: 10_000)
    ], nicTotalBytes: 200_000_000, nicDownBytes: 180_000_000, nicUpBytes: 20_000_000, coverage: 600)

    static let fixed: Self = {
        var value = Self()
        let gb: UInt64 = 1_073_741_824
        let date = Date(timeIntervalSince1970: 1_794_499_200)
        value.sample.cpuUsage = 0.38
        value.sample.systemCPU = 0.12; value.sample.userCPU = 0.26; value.sample.idleCPU = 0.62
        value.sample.perCore = [0.32, 0.54, 0.46, 0.38, 0.22, 0.18, 0.29, 0.34]
        value.sample.memoryTotal = 16 * gb; value.sample.memoryUsed = 10 * gb
        value.sample.memoryPressure = 0.48; value.sample.swapUsed = gb
        value.sample.netDownload = 2_800_000; value.sample.netUpload = 400_000
        value.sample.diskRead = 18_000_000; value.sample.diskWrite = 7_000_000
        value.sample.temperatures = ["CPU 包温": 48, "GPU": 43, "电池": 31]
        value.sample.batteryLevel = 0.75; value.sample.powerWatts = 24.6
        value.sample.inputPowerWatts = 36; value.sample.cpuPowerWatts = 8.4; value.sample.gpuPowerWatts = 4.2
        value.sample.anePowerWatts = 0.4; value.sample.ramPowerWatts = 1.2
        value.sample.dcsPowerWatts = 0.6; value.sample.chipPowerWatts = 16.8
        value.sample.powerIsInput = false; value.sample.isCharging = true; value.sample.externalPower = true
        let wave = (0..<60).map { 0.35 + 0.1 * sin(Double($0) * 0.3) }
        value.history.cpu = wave; value.history.memory = wave.map { $0 + 0.18 }
        value.history.gpu = wave.map { $0 * 0.7 }
        value.history.power = (0..<60).map { 24.6 + 5 * sin(Double($0 - 59) * 0.3) }
        value.history.netDownload = wave.map { $0 * 8_000_000 }
        value.history.netUpload = wave.map { $0 * 1_200_000 }
        value.history.diskRead = wave.map { $0 * 50_000_000 }
        value.history.diskWrite = wave.map { $0 * 20_000_000 }
        value.extra.compressedMemory = 2 * gb; value.extra.loadAverages = [2.4, 2.1, 1.8]
        value.extra.netTotalIn = 180_000_000; value.extra.netTotalOut = 20_000_000
        value.extra.netPeakDownload = 4_000_000; value.extra.netPeakUpload = 900_000
        value.extra.diskPeakRead = 24_000_000; value.extra.diskPeakWrite = 11_000_000
        value.extra.updatedAt = date
        value.stats.gpuUsage = 0.24; value.stats.gpuRenderer = 0.2; value.stats.gpuTiler = 0.12
        value.stats.gpuModel = "Apple M3"; value.stats.gpuTemperature = 43
        value.stats.cpuSuperCores = 4; value.stats.cpuEffCores = 4
        value.stats.clusterSuperUsage = 0.46; value.stats.clusterEffUsage = 0.25
        value.stats.memTotal = 16 * gb; value.stats.memUsed = 10 * gb
        value.stats.memWired = 2 * gb; value.stats.memCompressed = 2 * gb; value.stats.memPressureLevel = 1
        value.stats.diskTotalBytes = 512 * gb; value.stats.diskFreeBytes = 180 * gb
        value.stats.diskFileSystem = "APFS"; value.stats.diskModel = "示例 SSD"; value.stats.diskInterconnect = "PCIe"
        value.stats.smart = .init(available: true, temperatureC: 36, life: 97, powerCycles: 120,
                                 powerOnHours: 860, criticalWarning: 0, availableSpare: 100,
                                 totalRead: 5120 * gb, totalWritten: 2048 * gb)
        value.stats.connStatus = .online; value.stats.connHistory = Array(repeating: 1, count: 90)
        value.stats.connAvgLatencyMs = 12.4; value.stats.connAvgJitterMs = 1.2
        value.stats.netInterface = "en0 · 示例"; value.stats.netLocalIP = "192.0.2.10"
        value.stats.sensors = [
            .init(key: "TC0P", name: "CPU 包温", category: 0, group: 1, value: 48),
            .init(key: "TG0P", name: "GPU", category: 0, group: 2, value: 43),
            .init(key: "TB0T", name: "电池", category: 0, group: 3, value: 31)
        ]
        value.stats.fans = [.init(index: 0, name: "风扇", rpm: 1800, percent: 0.3)]
        value.stats.battery = .init(present: true, percent: 75, isCharging: true, externalConnected: true,
                                   fullyCharged: false, cycleCount: 120, designCapacity: 5200, nominalCapacity: 5000,
                                   maxCapacity: 4850, currentCapacity: 3600, temperature: 31, voltageMv: 12000,
                                   amperageMa: 1200, adapterPowerW: 36, batteryPowerW: 14.4,
                                   adapterVoltageV: 20, adapterWatts: 65, chargingCurrentMa: 1800, chargingVoltageV: 20)
        value.stats.batteryRemainSec = 2400; value.stats.updatedAt = date
        value.volumes = [.init(path: "/preview/Travel SSD", name: "Travel SSD", total: Int64(256 * gb),
                               free: Int64(96 * gb), isInternal: false, isRemovable: true,
                               isEjectable: true, isReadOnly: false, isLocal: true)]
        value.history.timestamps = (0..<60).map { date.timeIntervalSince1970 + Double($0 - 59) }
        value.history.intervals = Array(repeating: 1, count: 60)
        value.history.memoryPressure = (0..<60).map { $0 >= 20 && $0 < 38 ? 2 : 1 }
        value.history.battery = (0..<60).map { 0.75 - Double(59 - $0) * 0.0001 }
        for (name, temperature) in value.sample.temperatures {
            value.history.temperatures[name] = (0..<60).map { temperature + 2 * sin(Double($0 - 59) * 0.2) }
        }
        value.history.cpu[59] = value.sample.cpuUsage
        value.history.gpu[59] = value.stats.gpuUsage
        value.history.netDownload[59] = Double(value.sample.netDownload)
        value.history.netUpload[59] = Double(value.sample.netUpload)
        value.history.diskRead[59] = Double(value.sample.diskRead)
        value.history.diskWrite[59] = Double(value.sample.diskWrite)
        value.stats.procCPU = [
            .init(pid: -101, name: "浏览器", cpu: 72, memBytes: 1_400_000_000, diskRead: 900_000, diskWrite: 120_000,
                  children: [.init(pid: -102, name: "浏览器 Helper", cpu: 50, memBytes: 900_000_000, diskRead: 600_000, diskWrite: 80_000)]),
            .init(pid: -103, name: "编辑器", cpu: 24, memBytes: 820_000_000, diskRead: 300_000, diskWrite: 150_000),
            .init(pid: -104, name: "Kitnest", cpu: 4, memBytes: 180_000_000, diskRead: 20_000, diskWrite: 10_000)
        ]
        value.stats.procMem = value.stats.procCPU
        value.stats.procDisk = value.stats.procCPU
        return value
    }()
}
