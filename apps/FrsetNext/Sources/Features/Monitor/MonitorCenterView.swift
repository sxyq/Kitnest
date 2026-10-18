import SwiftUI

/// 主面板「监测中心」区段：2 列卡片网格，点击卡片弹出对应模块详情。
///
/// 通过 PanelSectionRegistry 注册（id "monitor", priority 10）。
/// 卡片点击后的详情展示状态（放在 ObservableObject 里，避免依赖 SwiftUI 的 @Stored 宏）
/// 面板顶部三段：主页 / 性能监测 / 中转站
public enum PanelCenterPage {
    case home, performance, transfer
}

public final class MonitorCenterPresenter: ObservableObject {
    /// 非 nil = 主面板停在「性能监测」页并选中该模块；nil = 主面板在「主页」。
    /// STATS 合并条部件点击走 StatsBarEngine.openMonitor → 这里预排，首帧即对应模块页。
    @Published public var presented: MonitorModuleID?
    /// 分段控件从「主页」切回「性能监测」时恢复的模块（原版记忆上次停留的标签）。
    @Published public var lastModule: MonitorModuleID = .cpu
    @Published public var isCollapsed: Bool = false

    /// 当前是否处于性能监测页
    public var isPerformance: Bool { presented != nil && !showsTransferDock }

    /// 第三页：中转站（文件暂存与转发）。与性能页互斥：进中转站时清掉模块选中。
    @Published public var showsTransferDock = false

    /// 面板当前主页面（三段：主页 / 性能监测 / 中转站）
    public var activePage: PanelCenterPage {
        if showsTransferDock { return .transfer }
        return presented == nil ? .home : .performance
    }

    public func selectHome() {
        showsTransferDock = false
        presented = nil
    }

    public func selectTransferDock() {
        presented = nil
        showsTransferDock = true
    }

    /// 切页（分段控件）：主页 ↔ 性能监测
    public func selectPerformance(_ on: Bool) {
        showsTransferDock = false
        presented = on ? lastModule : nil
    }

    /// 「文件中转」入口是否启用（设置 → 常规 → 功能，v41 新增开关）。
    /// 关闭时主面板顶部的第三段页签隐藏，设置窗口侧边栏也不显示该入口。
    public static var isTransferDockEnabled: Bool {
        Preferences.shared.value(Preferences.Keys.panelTransferDock, default: true)
    }

    /// v30：共享实例。STATS 部件点击 → 打开主面板直达对应模块页
    /// （注入版 FSOpenPanelAtModule 同款语义：打开前预排，首帧即监测页）。
    /// 面板区段注册处与外部导航共用同一实例。
    public static let shared = MonitorCenterPresenter()

    public init() {}
}

public struct MonitorCenterView: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    /// 外部可注入（总控若需要在面板内联动可传入同一实例）
    @ObservedObject private var presenter: MonitorCenterPresenter
    private let compact: Bool
    @Stored private var preferencesRevision = 0

    public init(presenter: MonitorCenterPresenter = .shared, compact: Bool = false) {
        self.presenter = presenter
        self.compact = compact
    }

    private var isCollapsed: Bool { presenter.isCollapsed }

    private func setCollapsed(_ value: Bool) { presenter.isCollapsed = value }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                compactSummary
            } else {
                header
                if !isCollapsed {
                    Group {
                        powerBanner
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            ForEach(visibleModules().filter { $0 != .power }, id: \.self) { module in
                                Button {
                                    presenter.presented = module
                                } label: {
                                    MonitorCenterCard(module: module, sample: sampler.sample, history: sampler.history)
                                }
                                .buttonStyle(.plain)
                                .hoverLift(1.015)
                            }
                        }
                    }
                    // 展开/收起：上缘锚定的缩放 + 淡入，收起只淡出（不压扁内容）
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity
                    ))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MonitorPreferences.didChangeNotification)) { _ in
            preferencesRevision += 1
        }
        // 详情 sheet 由 PanelRootView 统一挂载（v124：主页/性能两页常驻后，
        // 同一 presenter 若在本视图与 compact 实例各挂一个 sheet 会重复呈现）。
    }

    private var compactSummary: some View {
        HStack(alignment: .top, spacing: 16) {
            if MonitorPreferences.isModuleEnabled(.network) {
                VStack(alignment: .leading, spacing: 12) {
                    compactNetworkRow("↑ 上传", value: sampler.sample.netUpload,
                                      history: sampler.history.netUpload, color: MonitorColors.upload)
                    compactNetworkRow("↓ 下载", value: sampler.sample.netDownload,
                                      history: sampler.history.netDownload, color: MonitorColors.download)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("系统使用率").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach([MonitorModuleID.cpu, .memory, .disk].filter {
                    MonitorPreferences.isModuleEnabled($0)
                }, id: \.self) { module in
                    Button { presenter.presented = module } label: {
                        compactUsageRow(module)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var cardBackground: Color { Theme.cardBackground }

    private func compactNetworkRow(_ title: String, value: UInt64,
                                   history: [Double], color: Color) -> some View {
        Button { presenter.presented = .network } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(MonitorFormat.rate(value))
                        .font(.system(size: 16, weight: .medium).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7)
                    MonitorSparkline(values: history)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 48, height: 18)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func compactUsageRow(_ module: MonitorModuleID) -> some View {
        let sample = sampler.sample
        let value: Double = module == .cpu ? sample.cpuUsage : sample.memoryPressure
        return HStack(spacing: 7) {
            Image(systemName: module.systemImage).frame(width: 14)
            if module == .disk {
                Text(MonitorFormat.diskRate(read: sample.diskRead, write: sample.diskWrite))
                    .font(.system(size: 9).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Text(MonitorFormat.percent(value)).monospacedDigit().frame(width: 34, alignment: .leading)
                HStack(spacing: 2) {
                    ForEach(0..<10) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Double(index) < value * 10 ?
                                  (module == .memory ? MonitorColors.memory : MonitorColors.user) : Color.primary.opacity(0.1))
                            .frame(width: 3, height: 9)
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    // MARK: - 整机功耗横条（2026-10-16，最主要参数横向展示）
    //
    // 语义：接电 = 输入（充电中带 ⚡），放电 = 输出（整机功耗）。
    // 全宽横条突出显示，位于卡片网格上方；读不到功率数据时整条隐藏。

    @ViewBuilder
    private var powerBanner: some View {
        if MonitorPreferences.isEnabled,
           MonitorPreferences.isModuleEnabled(.power),
           let watts = sampler.sample.powerWatts {
            let sample = sampler.sample
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: sample.powerIsInput ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(sample.powerIsInput ? MonitorColors.battery : MonitorColors.user)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: sample.powerIsInput
                         ? (sample.isCharging ? "输入（充电）" : "输入")
                         : "输出")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(MonitorFormat.power(watts))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                }
                Spacer(minLength: 0)
                if let level = sample.batteryLevel {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(MonitorFormat.percent(level))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        Text("电池")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .help("整机功耗：接电显示输入功率（充电中），放电显示输出功耗")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Theme.sectionHeader("性能监测")
            Spacer()
            Menu {
                Toggle("启用", isOn: Binding(get: { MonitorPreferences.isEnabled },
                    set: { MonitorPreferences.isEnabled = $0 }))
                Toggle("合并", isOn: Binding(get: { MonitorPreferences.combinedMode },
                    set: { MonitorPreferences.combinedMode = $0 }))
                Divider()
                ForEach(MonitorModuleID.allCases, id: \.self) { module in
                    Toggle(module.displayName, isOn: Binding(
                        get: { MonitorPreferences.isModuleEnabled(module) },
                        set: { MonitorPreferences.setModuleEnabled(module, $0) }))
                }
            } label: { Label("显示", systemImage: "slider.horizontal.3") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if !MonitorPreferences.isEnabled {
                Text("已关闭")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                ServiceLocator.settings?.open(pane: "monitor")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("监测设置")
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    setCollapsed(!isCollapsed)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 180))
            }
            .buttonStyle(SpringyIconButtonStyle())
            .help(isCollapsed ? "展开" : "收起")
        }
    }

    // MARK: - 可见模块

    private func visibleModules() -> [MonitorModuleID] {
        guard MonitorPreferences.isEnabled else { return [] }
        var modules = MonitorModuleID.allCases.filter { MonitorPreferences.isModuleEnabled($0) }
        if !MonitorPreferences.showTemperatures || sampler.sample.temperatures.isEmpty {
            modules.removeAll { $0 == .sensors }
        }
        if sampler.sample.batteryLevel == nil {
            modules.removeAll { $0 == .battery }
        }
        if StatsDataProvider.shared.current.gpuUsage < 0 {
            modules.removeAll { $0 == .gpu }
        }
        return modules
    }
}

// MARK: - 单张卡片

private struct MonitorCenterCard: View {
    let module: MonitorModuleID
    let sample: MonitorSample
    let history: MonitorSampler.History

    var body: some View {
        MonitorCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: module.systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(accent)
                        .frame(width: 14)
                    Text(module.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(headline)
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subheadline)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                sparkline
                    .frame(height: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        switch module {
        case .power:
            HStack(spacing: 4) {
                Image(systemName: sample.powerIsInput ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(sample.powerIsInput ? MonitorColors.battery : MonitorColors.user)
                Text(sample.powerIsInput ? "输入" : "输出")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .cpu:
            MonitorAreaSparkline(values: history.cpu, color: MonitorColors.user, upperBound: 1)
        case .memory:
            MonitorAreaSparkline(values: history.memory, color: MonitorColors.memory, upperBound: 1)
        case .network:
            ZStack {
                MonitorAreaSparkline(values: history.netDownload, color: MonitorColors.download)
                MonitorSparkline(values: history.netUpload)
                    .stroke(MonitorColors.upload, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        case .disk:
            ZStack {
                MonitorAreaSparkline(values: history.diskRead, color: MonitorColors.read)
                MonitorSparkline(values: history.diskWrite)
                    .stroke(MonitorColors.write, style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        case .sensors:
            MonitorBarChart(values: temperatureBars(), color: MonitorColors.temperature, spacing: 3)
        case .battery:
            MonitorRing(value: sample.batteryLevel ?? 0, lineWidth: 4, color: MonitorColors.battery)
                .frame(width: 22, height: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .gpu:
            MonitorAreaSparkline(values: history.gpu, color: MonitorColors.user, upperBound: 1)
        }
    }

    private func temperatureBars() -> [Double] {
        sample.temperatures.values.map { min(1, max(0, ($0 - 20) / 80)) }
    }

    private var accent: Color {
        switch module {
        case .power: return MonitorColors.battery
        case .cpu: return MonitorColors.user
        case .memory: return MonitorColors.memory
        case .network: return MonitorColors.download
        case .disk: return MonitorColors.read
        case .sensors: return MonitorColors.temperature
        case .battery: return MonitorColors.battery
        case .gpu: return MonitorColors.user
        }
    }

    private var headline: String {
        switch module {
        case .power:
            return sample.powerWatts.map { MonitorFormat.power($0) } ?? "—"
        case .cpu: return MonitorFormat.percent(sample.cpuUsage)
        case .memory: return MonitorFormat.percent(sample.memoryPressure)
        case .network: return MonitorFormat.rate(sample.netDownload)
        case .disk: return MonitorFormat.rate(sample.diskRead)
        case .sensors:
            if let first = sample.temperatures.values.max() { return MonitorFormat.temperature(first) }
            return "—"
        case .battery:
            if let level = sample.batteryLevel { return MonitorFormat.percent(level) }
            return "—"
        case .gpu:
            let usage = StatsDataProvider.shared.current.gpuUsage
            return usage >= 0 ? MonitorFormat.percent(usage) : "—"
        }
    }

    private var subheadline: String {
        switch module {
        case .power:
            if sample.powerIsInput { return sample.isCharging ? "输入 \u{00B7} 充电中" : "输入 \u{00B7} 接电源" }
            return "输出 \u{00B7} 电池供电"
        case .cpu: return "系统 \(MonitorFormat.percent(sample.systemCPU)) · 用户 \(MonitorFormat.percent(sample.userCPU))"
        case .memory: return "\(MonitorFormat.bytes(sample.memoryUsed)) / \(MonitorFormat.bytes(sample.memoryTotal))"
        case .network: return "↑ \(MonitorFormat.rate(sample.netUpload))"
        case .disk: return "写 \(MonitorFormat.rate(sample.diskWrite))"
        case .sensors:
            if sample.temperatures.isEmpty { return "无传感器数据" }
            return "\(sample.temperatures.count) 个传感器"
        case .battery: return "电量"
        case .gpu:
            let stats = StatsDataProvider.shared.current
            return stats.gpuModel.isEmpty ? "GPU 占用" : stats.gpuModel
        }
    }
}

// MARK: - sheet 用的 Identifiable 包装

extension MonitorModuleID: Identifiable {
    public var id: String { rawValue }
}
