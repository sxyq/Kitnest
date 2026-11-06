import SwiftUI

/// 各模块详情面板（Stats 信息架构 × Frset 视觉），宽度控制在 300pt 内以适应 popover。
///
/// 通过顶部模块切换条可在 CPU / 内存 / 网络 / 磁盘 / 温度 / 电池之间切换。
/// 详情面板的选中模块状态（放在 ObservableObject 里，避免依赖 SwiftUI 的 @Stored 宏）
public final class MonitorDetailSelection: ObservableObject {
    @Published public var module: MonitorModuleID
    public init(_ module: MonitorModuleID = .cpu) { self.module = module }
}

/// 性能页正文容器：**主面板性能页与状态栏独立窗共用唯一实现**。
/// v196 起两处 topInset 都是 0（独立窗已去掉左上角关闭钮，不再需要让位），
/// 内外边距/滚动策略/模块选中态/数据源必须完全一致——任何一侧单独改版式
/// 都会造成用户看到的「两套 UI」。
public struct MonitorPerformanceContent: View {
    @ObservedObject private var presenter = MonitorCenterPresenter.shared
    private let topInset: CGFloat

    public init(topInset: CGFloat = 0) {
        self.topInset = topInset
    }

    public var body: some View {
        MonitorDetailView(selection: presenter.monitorSelection,
                          pageMode: false, fixedWidth: nil)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .padding(.top, topInset)
    }
}

public struct MonitorDetailView: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    @ObservedObject private var selection: MonitorDetailSelection
    @ObservedObject private var memoryOptimizer = MemoryOptimizer.shared
    /// v183：网络页的 1 秒实时脉冲（与通用采样节奏解耦）
    @ObservedObject private var netPulse = NetworkPulse.shared
    /// v217：外置卷（U 盘 / 移动硬盘 / 网络盘）——插拔时由系统通知自动刷新
    @ObservedObject private var volumeStore = DiskVolumeStore.shared
    /// 页面模式：只渲染模块内容，标签行与底栏由 StatsPageView 提供（宽度撑满、无固定 292 限宽）
    private let pageMode: Bool
    /// 固定宽度（nil = 撑满容器；独立窗 v71 传 nil 消除两侧留白，菜单栏 popover 保留 292）
    private let fixedWidth: CGFloat?
    /// 温度页：原始传感器列表默认折叠（v181 起主视图换成 4 条热区）
    @Stored private var showsAllTemperatures = false

    public init(module: MonitorModuleID = .cpu, pageMode: Bool = false) {
        self.selection = MonitorDetailSelection(module)
        self.pageMode = pageMode
        self.fixedWidth = 292
    }

    public init(selection: MonitorDetailSelection, pageMode: Bool = false, fixedWidth: CGFloat? = 292) {
        self.selection = selection
        self.pageMode = pageMode
        self.fixedWidth = fixedWidth
    }

    public var body: some View {
        if pageMode {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                modulePicker
                Divider().opacity(0.5)
                // v82（2026-10-19 修复「GPU/内存等按钮点不动」）：滚动区只包内容区，
                // 切换条/底栏固定。此前整页（含 modulePicker）由外层 ScrollView 包裹，
                // macOS SwiftUI 下 ScrollView 的手势/命中容器会拦截其直接子级按钮的
                // 点击（页签在 toolbar 里可点、模块按钮在 ScrollView 里点不动即为实证）。
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .id(selection.module)
                        .transition(PanelMotion.transition(.opacity.combined(with: .offset(y: 8))))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().opacity(0.5)
                footer
            }
            .padding(12)
            .frame(width: fixedWidth, alignment: .leading)
        }
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
                Button {
                    Log.info("Monitor", "切换模块: \(module.displayName)（原 \(selection.module.displayName)）")
                    withAnimation(PanelMotion.animation(Theme.Motion.springSoft)) {
                        selection.module = module
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: module.systemImage)
                            .font(.system(size: 11))
                        Text(module.displayName)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        if selection.module == module {
                            Capsule(style: .continuous)
                                .fill(Theme.accent.opacity(0.18))
                        }
                    }
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(selection.module == module ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 0.5)
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                // v183：深链/键盘切换后第一个胶囊会吃焦点环，看着像「两个都选中」
                .focusable(false)
            }
        }
    }

    /// 可选模块：过滤掉无数据的项，但始终保留当前选中项
    /// v88（2026-10-20 用户反馈「监测设置改变后没有生效」）：设置里关掉的模块
    /// 此前只影响状态栏项、不从监测中心过滤——补上开关过滤（当前选中项保留，
    /// 避免选中态突然消失）。
    private func availableModules() -> [MonitorModuleID] {
        var modules: [MonitorModuleID] = []
        let stats = StatsDataProvider.shared.current
        for module in MonitorModuleID.allCases {
            if !MonitorPreferences.isModuleEnabled(module), selection.module != module {
                continue
            }
            switch module {
            case .sensors:
                if MonitorPreferences.showTemperatures { modules.append(module) }
            case .battery:
                if sampler.sample.batteryLevel != nil || selection.module == module { modules.append(module) }
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
        let stats = StatsDataProvider.shared.current
        // v183：大数字与流向图**必须同源**。原来大数字取 MonitorReader 的 powerWatts、
        // 流向图取电池适配器读数，同一时刻能显示 19.7W / 20.17W 两个值——
        // 用户看到的就是「一个页面两个数」。现在以流向图的输入为准，读不到才回退。
        let flow = BatteryFlowModel(battery: stats.battery)
        let headlineWatts = flow.input.available ? flow.input.watts : sample.powerWatts
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
                    Text(headlineWatts.map { MonitorFormat.power($0) } ?? "—")
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                }
            }

            // v181：复用电池页那张流向图（来源 → 流带 → 分支），两个页面口径统一。
            // 分支只画真拿到读数的：机型不给显示器/USB 功率就没有这两条，绝不补 0 W。
            let powerBranches = flow.branches + powerExtraBranches(stats.sensors)
            if !powerBranches.isEmpty {
                MonitorSectionTitle("电源流向")
                MonitorFlowCard(input: flowNode(flow.input),
                                branches: powerBranches.map(flowNode))
                // v216（用户：「其他界面的这种说明性文字全部都删掉」）：删掉流带口径说明。
            }
            // v183：应用级能耗（原来在电池页，属于「电被谁用了」→ 功耗页）
            CPUEnergyImpactSection(stats: stats)

            // v216：删掉「数据源：AppleSmartBattery PowerTelemetryData…」脚注。
        }
    }

    // MARK: - CPU

    private var cpuPanel: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        let history = sampler.history.cpu
        let average = history.isEmpty
            ? sample.cpuUsage
            : history.reduce(0, +) / Double(history.count)
        let peak = history.max() ?? sample.cpuUsage
        let cores = Double(max(1, CPUHardware.logicalCores))

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
                            .font(.system(size: 11))
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

            // v183：芯片规格 + 热压力。原页面顶部只有两个环和四行数字，
            // 读不到温度传感器时还会空出半个环位——这里用一行把「这台机器是什么」补上。
            chipStrip(stats)

            MonitorSectionTitle("使用历史")
            HStack(spacing: 6) {
                Text("当前 \(MonitorFormat.percent(sample.cpuUsage))")
                    .foregroundStyle(MonitorColors.user)
                Spacer(minLength: 4)
                Text("均值 \(MonitorFormat.percent(average)) · 峰值 \(MonitorFormat.percent(peak))")
                    .foregroundStyle(Theme.tertiaryText)
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            ZStack(alignment: .bottomLeading) {
                historyGrid
                MonitorAreaSparkline(
                    values: history,
                    color: MonitorColors.user,
                    upperBound: 1,
                    slots: MonitorSampler.historyCapacity,
                    lineWidth: 1.6
                )
                if history.count < 10 {
                    // 刚启动时历史只有几个点，曲线是贴在右边的一小截——
                    // 不说明的话看起来就像「图没画出来」
                    Text("采样中 \(history.count)/\(MonitorSampler.historyCapacity) · 约 1 分钟后曲线完整")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 4)
                        .padding(.bottom, 2)
                }
            }
            .frame(height: 52)

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
                loadCell("1 分钟", value: sample.loadAverage1m)
                loadCell("5 分钟", value: sample.loadAverage5m)
                loadCell("15 分钟", value: sample.loadAverage15m)
            }
            // 负载是「排队任务数」不是百分比：不给核心数做分母，7.6 是高是低没人知道
            let perCore1 = sample.loadAverage1m / cores
            Text("每核负载 \(MonitorFormat.load(perCore1))"
                 + " · \(MonitorFormat.load(sample.loadAverage5m / cores))"
                 + " · \(MonitorFormat.load(sample.loadAverage15m / cores))"
                 + "（> 1 表示有任务在排队）")
                .font(.system(size: 10))
                .foregroundStyle(perCore1 > 1 ? MonitorColors.compressed : Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            // v84（用户需求「归类 + 展开 + 图标 + 退出」）：高占用进程改用统一进程表——
            // 按 App 归类（Helper/Renderer 合并）、真实图标、点击展开组内明细、右键退出。
            let procs = Array(StatsDataProvider.shared.current.procCPU.prefix(8))
            if !procs.isEmpty {
                StatsProcTable(title: "CPU 占用进程",
                               columns: [.init(title: "CPU")],
                               items: procs,
                               values: { [String(format: "%.0f%%", $0.cpu)] })
            }
        }
    }

    /// 历史曲线的参考网格（25% / 50% / 75%），空图时也不至于是一块空白
    private var historyGrid: some View {
        GeometryReader { geo in
            Path { path in
                for index in 1...3 {
                    let y = geo.size.height * CGFloat(index) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.primary.opacity(0.06),
                    style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
    }

    /// 芯片规格 + 热压力（一行，不占高度）
    private func chipStrip(_ stats: StatsSnapshot) -> some View {
        let thermal = CPUHardware.thermal
        var chip = "\(CPUHardware.brand) · \(CPUHardware.logicalCores) 核"
        if stats.cpuSuperCores > 0 && stats.cpuEffCores > 0 {
            chip += "（P\(stats.cpuSuperCores) + E\(stats.cpuEffCores)）"
        }
        chip += " · macOS \(CPUHardware.osVersion)"

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
        let temperatures = sampler.sample.temperatures
        for key in ["CPU 包温", "CPU 二极管", "CPU 邻近"] {
            if let value = temperatures[key] { return value }
        }
        if let any = temperatures.values.first { return any }
        // v183：温度采样受「采集温度」开关/传感器扫描节流影响，可能这一帧为空——
        // 兜底用温度页同一套热区（CPU 区最热那颗），避免顶部平白空出半个环位。
        return MonitorThermalZones
            .build(from: StatsDataProvider.shared.current.sensors)
            .first(where: { $0.id == "cpu" })?
            .celsius
    }

    // MARK: - 内存

    private var memoryPanel: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        let compressed = stats.memCompressed > 0 ? stats.memCompressed : sample.compressedMemory
        let wired = stats.memWired
        let app = max(0, Double(sample.memoryUsed) - Double(compressed) - Double(wired))
        let freeMemory = Double(sample.memoryTotal > sample.memoryUsed
                                ? sample.memoryTotal - sample.memoryUsed : 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    MonitorRing(value: sample.memoryPressure, lineWidth: 7, color: MonitorColors.memory)
                        .frame(width: 66, height: 66)
                    VStack(spacing: 0) {
                        Text(MonitorFormat.percent(sample.memoryPressure))
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        Text("已用")
                            .font(.system(size: 11))
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

            MonitorSectionTitle("使用历史")
            MonitorAreaSparkline(values: sampler.history.memory, color: MonitorColors.memory, upperBound: 1)
                .frame(height: 46)

            MonitorRow(label: "内存压力", value: MonitorFormat.percentFine(sample.memoryPressure))

            // v84（用户需求「内存界面也要有进程占用排序」）：内存占用进程表——
            // 与 CPU 页同一组件（归类 + 图标 + 展开 + 右键退出），按 footprint 降序。
            let memProcs = Array(StatsDataProvider.shared.current.procMem.prefix(8))
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
                                   iconImage: NetworkFlowIcon.icon(forPath: entry.iconPath),
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

    /// 电池流向节点 → 通用流向节点
    private func flowNode(_ node: BatteryFlowNode) -> MonitorFlowNode {
        MonitorFlowNode(id: node.id,
                        title: node.title,
                        value: node.watts,
                        valueText: node.available ? BatteryEnergySampler.wattsText(node.watts) : "—",
                        systemImage: node.systemImage,
                        color: node.color,
                        available: node.available)
    }

    /// 机型提供的额外功耗分支（显示器 / USB）。
    /// 只在 SMC 真有对应功率传感器（category = 4 功率）时出现——没读数不补 0。
    private func powerExtraBranches(_ sensors: [StatsSensorItem]) -> [BatteryFlowNode] {
        let powerSensors = sensors.filter { $0.category == 4 && $0.value > 0.05 && $0.value < 500 }
        let specs: [(id: String, title: String, icon: String,
                     keys: [String], color: Color)] = [
            ("display", "显示器", "display",
             ["pdb", "display", "backlight", "panel"], MonitorColors.compressed),
            ("usb", "USB", "cable.connector",
             ["usb", "d1", "d2", "d3", "d4"], MonitorColors.wired),
        ]
        return specs.compactMap { spec in
            let hits = powerSensors.filter { item in
                let key = item.key.lowercased(), name = item.name.lowercased()
                return spec.keys.contains { key.hasPrefix($0) || name.contains($0) }
            }
            guard let worst = hits.max(by: { $0.value < $1.value }) else { return nil }
            return BatteryFlowNode(id: spec.id, title: spec.title, watts: worst.value,
                                   systemImage: spec.icon, color: spec.color, available: true)
        }
    }

    // MARK: - 网络

    private var networkPanel: some View {
        let sample = sampler.sample
        let stats = StatsDataProvider.shared.current
        // v183：优先用 1 秒脉冲（C 引擎的 1s 网络速率），保证数字与曲线是「活的」；
        // 脉冲还没起来（刚打开 / g_snap 无效）时退回通用采样，绝不显示空白。
        let liveDown = netPulse.down.isEmpty ? Double(sample.netDownload) : netPulse.currentDown
        let liveUp = netPulse.up.isEmpty ? Double(sample.netUpload) : netPulse.currentUp
        let downHistory = netPulse.down.isEmpty ? sampler.history.netDownload : netPulse.down
        let upHistory = netPulse.up.isEmpty ? sampler.history.netUpload : netPulse.up
        let flowSnapshot = NetworkFlowTracker.shared.snapshot()
        let netBranches = networkFlowNodes(flowSnapshot, limit: MonitorPreferences.flowTopN)

        return VStack(alignment: .leading, spacing: 10) {
            MonitorNetworkThroughputCard(down: liveDown, up: liveUp,
                                         downHistory: downHistory, upHistory: upHistory)
                .onAppear { netPulse.activate() }
                .onDisappear { netPulse.deactivate() }

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
                .animation(Theme.Motion.fast, value: stats.procNet.count)
            }

            // 端口占用（2026-10-20）：本机监听端口 + 进程归属 + 是否对外暴露。
            // 放在网络页最底部；页面本身在 ScrollView 内，窗口高度达上限后可滚动查看。
            PortOccupancySection()
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
        let purgeable = MonitorDiskSpace.purgeableBytes(freeBytes: stats.diskFreeBytes)
        return VStack(alignment: .leading, spacing: 10) {
            // v211（用户：「最顶上的读取和写入两个数字要删掉，因为下面有，重复了」）：
            // 原来页首两个大号实时读写速率与下面「峰值读取 / 峰值写入」及读写历史重复，
            // 现在直接从「读写历史」开始；实时速率仍可在状态栏部件/STATS 里看。
            MonitorSectionTitle("读写历史")
            // v183：读写**共享同一 Y 轴量程**。原来两条线各自归一化，
            // 写入量只有读取的 1/10 时也会画成一样高——图不可信。
            let diskPeak = MonitorChartScale.niceCeiling(
                max(sampler.history.diskRead.max() ?? 0, sampler.history.diskWrite.max() ?? 0))
            ZStack(alignment: .topLeading) {
                // 三层顺序（用户：「统计图的线条是可以覆盖在它上面的」）：
                // ① 面积填充在最底 → ② 按钮压在填充上（文字不会被色块糊住）
                // → ③ 折线画在最顶，从按钮上面穿过去。
                ZStack {
                    MonitorAreaSparkline(values: sampler.history.diskRead,
                                         color: MonitorColors.read,
                                         upperBound: diskPeak,
                                         slots: MonitorSampler.historyCapacity)
                    MonitorSparkline(values: sampler.history.diskWrite,
                                     upperBound: diskPeak,
                                     slots: MonitorSampler.historyCapacity)
                        .stroke(MonitorColors.write, style: StrokeStyle(lineWidth: 1.5,
                                                                        lineCap: .round, lineJoin: .round))
                }
                // 让点击穿透到上面的按钮（Shape 的填充区默认会吃掉 hitTest）
                .allowsHitTesting(false)
                .frame(height: 52)

                storageEntryButton
                    .padding(.top, 3)
                    .padding(.leading, 2)

                // 顶层再画一遍写入折线，盖在按钮上方
                MonitorSparkline(values: sampler.history.diskWrite,
                                 upperBound: diskPeak,
                                 slots: MonitorSampler.historyCapacity)
                    .stroke(MonitorColors.write, style: StrokeStyle(lineWidth: 1.5,
                                                                    lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                    .frame(height: 52)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 52)

            MonitorRow(label: "峰值读取", value: MonitorFormat.rate(MonitorExtra.current.diskPeakRead), color: MonitorColors.read)
            MonitorRow(label: "峰值写入", value: MonitorFormat.rate(MonitorExtra.current.diskPeakWrite), color: MonitorColors.write)

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
            if !volumeStore.volumes.isEmpty {
                MonitorSectionTitle("外置磁盘")
                ForEach(volumeStore.volumes) { volume in
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
            StorageManagerWindowController.shared.show()
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
        let temperatures = sampler.sample.temperatures
        let stats = StatsDataProvider.shared.current
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
                .frame(width: 168, alignment: .leading)
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
        BatteryStatsPanel()
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
                            .font(.system(size: 11))
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

            // v216：删掉「数据来源：IOAccelerator PerformanceStatistics」脚注。
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text("刷新间隔 \(String(format: "%.1f", MonitorPreferences.refreshInterval))s")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                sampler.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("立即刷新")
            Button {
                StatsBarEngine.openSettings()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("菜单栏部件设置（Stats 风格：形态 / 间距 / 分隔线）")
            Button {
                ServiceLocator.settings?.open(pane: "monitor")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("打开监测设置")
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

