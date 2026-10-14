import SwiftUI

/// 主面板「监测中心」区段：2 列卡片网格，点击卡片弹出对应模块详情。
///
/// 通过 PanelSectionRegistry 注册（id "monitor", priority 10）。
/// 卡片点击后的详情展示状态（放在 ObservableObject 里，避免依赖 SwiftUI 的 @Stored 宏）
public final class MonitorCenterPresenter: ObservableObject {
    @Published public var presented: MonitorModuleID?
    @Published public var isCollapsed: Bool = false

    public init() {}
}

public struct MonitorCenterView: View {
    @ObservedObject private var sampler = MonitorSampler.shared
    /// 外部可注入（总控若需要在面板内联动可传入同一实例）
    @ObservedObject private var presenter: MonitorCenterPresenter

    public init(presenter: MonitorCenterPresenter = MonitorCenterPresenter()) {
        self.presenter = presenter
    }

    private var isCollapsed: Bool { presenter.isCollapsed }

    private func setCollapsed(_ value: Bool) { presenter.isCollapsed = value }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !isCollapsed {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(visibleModules(), id: \.self) { module in
                        Button {
                            presenter.presented = module
                        } label: {
                            MonitorCenterCard(module: module, sample: sampler.sample, history: sampler.history)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { presenter.presented != nil },
            set: { if !$0 { presenter.presented = nil } }
        )) {
            MonitorDetailView(module: presenter.presented ?? .cpu)
                .padding(8)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Theme.sectionHeader("监测中心")
            Spacer()
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
                withAnimation(.easeOut(duration: 0.18)) { setCollapsed(!isCollapsed) }
            } label: {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
        }
    }

    private func temperatureBars() -> [Double] {
        sample.temperatures.values.map { min(1, max(0, ($0 - 20) / 80)) }
    }

    private var accent: Color {
        switch module {
        case .cpu: return MonitorColors.user
        case .memory: return MonitorColors.memory
        case .network: return MonitorColors.download
        case .disk: return MonitorColors.read
        case .sensors: return MonitorColors.temperature
        case .battery: return MonitorColors.battery
        }
    }

    private var headline: String {
        switch module {
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
        }
    }

    private var subheadline: String {
        switch module {
        case .cpu: return "系统 \(MonitorFormat.percent(sample.systemCPU)) · 用户 \(MonitorFormat.percent(sample.userCPU))"
        case .memory: return "\(MonitorFormat.bytes(sample.memoryUsed)) / \(MonitorFormat.bytes(sample.memoryTotal))"
        case .network: return "↑ \(MonitorFormat.rate(sample.netUpload))"
        case .disk: return "写 \(MonitorFormat.rate(sample.diskWrite))"
        case .sensors:
            if sample.temperatures.isEmpty { return "无传感器数据" }
            return "\(sample.temperatures.count) 个传感器"
        case .battery: return "电量"
        }
    }
}

// MARK: - sheet 用的 Identifiable 包装

extension MonitorModuleID: Identifiable {
    public var id: String { rawValue }
}
