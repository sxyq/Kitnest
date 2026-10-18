import SwiftUI

/// 设置 → 监测 页签（id "monitor"，图标 gauge）
///
/// 全部开关经 MonitorPreferences → Preferences（monitor.* 键）持久化。
public final class MonitorSettingsState: ObservableObject {
    /// 偏好变化后自增，用于驱动 SwiftUI 重绘
    @Published public var version: Int = 0
    public init() {}
}

public struct MonitorSettingsPane: View {
    @ObservedObject private var state: MonitorSettingsState
    @ObservedObject private var sampler = MonitorSampler.shared

    public init(state: MonitorSettingsState = MonitorSettingsState()) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                generalSection
                Divider()
                modulesSection
                Divider()
                advancedSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: MonitorPreferences.didChangeNotification)) { _ in
            bump()
        }
    }

    // MARK: - 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Theme.sectionHeader("通用")
            Toggle("启用系统监测", isOn: Binding(
                get: { MonitorPreferences.isEnabled },
                set: { MonitorPreferences.isEnabled = $0; bump() }
            ))
            .font(.system(size: 13))

            HStack(spacing: 10) {
                Text("刷新间隔")
                    .font(.system(size: 13))
                Slider(
                    value: Binding(
                        get: { MonitorPreferences.refreshInterval },
                        set: { MonitorPreferences.refreshInterval = $0; bump() }
                    ),
                    in: 0.5...10,
                    step: 0.5
                )
                Text(String(format: "%.1fs", MonitorPreferences.refreshInterval))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Divider()

            // 菜单栏部件（STATS 引擎）——v54：完整设置已内嵌到「性能监测 → 部件设置」页
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("菜单栏部件")
                        .font(.system(size: 13))
                    Text("形态 / 颜色 / 间距 / 每模块选项（功能对齐 Stats，全部内嵌在「部件设置」）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开部件设置") {
                    SettingsWindowController.shared.open(pane: "monitor.widgets")
                }
                .font(.system(size: 12))
            }
        }
    }

    // MARK: - 模块开关

    private var modulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.sectionHeader("模块")
            Text("控制面板监测中心显示哪些模块；关闭的模块不再采集。菜单栏部件的显隐在「菜单栏部件」设置里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(MonitorModuleID.allCases, id: \.rawValue) { module in
                HStack(spacing: 8) {
                    Image(systemName: module.systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Toggle(module.displayName, isOn: Binding(
                        get: { MonitorPreferences.isModuleEnabled(module) },
                        set: { MonitorPreferences.setModuleEnabled(module, $0); bump() }
                    ))
                    .font(.system(size: 13))
                    Spacer()
                    Text(statusLine(for: module))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 高级

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Theme.sectionHeader("高级")
            Toggle("采集温度（SMC）", isOn: Binding(
                get: { MonitorPreferences.showTemperatures },
                set: { MonitorPreferences.showTemperatures = $0; bump() }
            ))
            .font(.system(size: 13))
            Text("温度读取受系统限制，读不到时会自动降级为空，不影响其他指标。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("清空历史与峰值") {
                    sampler.resetHistory()
                }
                Button("恢复默认设置") {
                    MonitorPreferences.resetToDefaults()
                    bump()
                }
                Spacer()
                Text("已采样 \(sampler.tick) 次")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - 辅助

    private func statusLine(for module: MonitorModuleID) -> String {
        let sample = sampler.sample
        switch module {
        case .power: return MonitorStatusItems.powerDetailText()
        case .cpu: return MonitorFormat.percent(sample.cpuUsage)
        case .memory: return "\(MonitorFormat.bytes(sample.memoryUsed)) / \(MonitorFormat.bytes(sample.memoryTotal))"
        case .network: return MonitorFormat.directionalRate(upload: sample.netUpload, download: sample.netDownload)
        case .disk: return MonitorFormat.diskRate(read: sample.diskRead, write: sample.diskWrite)
        case .sensors:
            if let value = sample.temperatures.values.max() { return MonitorFormat.temperature(value) }
            return "无数据"
        case .battery:
            if let level = sample.batteryLevel { return MonitorFormat.percent(level) }
            return "无电池"
        case .gpu:
            let usage = StatsDataProvider.shared.current.gpuUsage
            return usage >= 0 ? MonitorFormat.percent(usage) : "无数据"
        }
    }

    private func bump() { state.version &+= 1 }
}
