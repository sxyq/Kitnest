import SwiftUI

/// 监测设置沿用设置窗口的草稿生命周期，保存时只应用本页实际改动的字段。
public final class MonitorSettingsState: SettingsEditableDraft {
    struct Values: Equatable {
        var enabled = true
        var interval = 2.0
        var modules = Dictionary(uniqueKeysWithValues: MonitorModuleID.allCases.map { ($0, $0.enabledByDefault) })
        var temperatures = true
        var keepAlive = true
        var topN = 4
        var widgetIntervals = Dictionary(uniqueKeysWithValues: (FSBarAllModules() as? [String] ?? []).map { ($0, 1.0) })

        static func saved() -> Self {
            var value = Self()
            value.enabled = MonitorPreferences.isEnabled
            value.interval = MonitorPreferences.refreshInterval
            value.modules = Dictionary(uniqueKeysWithValues: MonitorModuleID.allCases.map { ($0, MonitorPreferences.isModuleEnabled($0)) })
            value.temperatures = MonitorPreferences.showTemperatures
            value.keepAlive = MonitorPreferences.networkKeepAlive
            value.topN = MonitorPreferences.flowTopN
            let configuration = FSBarConfigurationSnapshot() as? [String: Any] ?? [:]
            for module in value.widgetIntervals.keys {
                let raw = configuration[module + "_updateInterval"]
                value.widgetIntervals[module] = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) ?? 1
            }
            return value
        }
    }
    @Published var values = Values.saved()
    private var savedValues = Values.saved()
    var isDirty: Bool { values != savedValues }
    let barModules = FSBarAllModules() as? [String] ?? []
    let previewSelection = MonitorDetailSelection()
    public init() {}

    func save() -> String? {
        var intervals: [String: Any] = [:]
        for module in barModules where values.widgetIntervals[module] != savedValues.widgetIntervals[module] {
            intervals[module + "_updateInterval"] = String(format: "%.0f", values.widgetIntervals[module]!)
        }
        if !intervals.isEmpty {
            if let reason = FSBarSaveConfiguration(intervals, []) { return reason }
            FSBarReloadFromStore()
        }
        if values.enabled != savedValues.enabled { MonitorPreferences.isEnabled = values.enabled }
        if values.interval != savedValues.interval {
            MonitorPreferences.refreshInterval = values.interval
        }
        for module in MonitorModuleID.allCases where values.modules[module] != savedValues.modules[module] {
            MonitorPreferences.setModuleEnabled(module, values.modules[module]!)
        }
        if values.temperatures != savedValues.temperatures { MonitorPreferences.showTemperatures = values.temperatures }
        if values.keepAlive != savedValues.keepAlive {
            MonitorPreferences.networkKeepAlive = values.keepAlive
            NetworkFlowTracker.shared.applyKeepAlivePreference()
        }
        if values.topN != savedValues.topN { MonitorPreferences.flowTopN = values.topN }
        guard UserDefaults.standard.synchronize() else { return "监测设置写入磁盘失败，调整已保留" }
        values = Values.saved(); savedValues = values
        return nil
    }
    func discard() { values = Values.saved(); savedValues = values }
    func restoreDefaults() { discard(); values = Values() }

}

public struct MonitorSettingsPane: View {
    public init() {}
    public var body: some View {
        SettingsDraftEditor(id: "monitorSettings", makeDraft: { MonitorSettingsState() }) { state in
            MonitorSettingsContent(state: state)
        }
    }
}

private struct MonitorSettingsContent: View {
    @ObservedObject var state: MonitorSettingsState
    @Stored private var operationResult: String? = nil
    private var order: [MonitorModuleID] { [.cpu, .gpu, .memory, .network, .disk, .sensors, .power, .battery] }
    private var visibleModules: [MonitorModuleID] { order.filter { state.values.modules[$0] == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection("监测预览") {
                MonitorDetailView(settingsSelection: state.previewSelection, fixedWidth: nil)
                    .environment(\.isSettingsPreview, true)
                    .environment(\.monitorPresentation, MonitorPresentation(order: visibleModules,
                        previewInterval: state.values.interval, previewEnabled: state.values.enabled,
                        previewTemperatures: state.values.temperatures, previewFlowTopN: state.values.topN))
                    .frame(height: 360)
                Text("固定模拟采样 · 可选择模块、定位与固定读数；保存才改变正式监测")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
            }
            SettingsSection("通用") {
                Toggle("启用系统监测", isOn: $state.values.enabled)
                SettingsRow(title: "刷新间隔") {
                    Slider(value: $state.values.interval, in: 0.5...10, step: 0.5).frame(width: 180)
                    Text(String(format: "%.1f 秒", state.values.interval)).monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Button("打开菜单栏部件设置") { SettingsWindowController.shared.open(pane: "monitor.widgets") }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            SettingsSection("模块显隐") {
                Text("决定主面板、刘海和独立监测窗中的模块入口。菜单栏部件在“部件设置”中调整。")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(order, id: \.self) { module in
                        Toggle(isOn: Binding(get: { state.values.modules[module]! }, set: { state.values.modules[module] = $0 })) {
                            Label(module.displayName, systemImage: module.systemImage)
                        }
                        .id(module.displayName)
                    }
                }
            }
            SettingsSection("菜单栏部件独立采样") {
                Text("每个部件单独保存间隔；主监测刷新间隔不覆盖这些数值。")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                ForEach(state.barModules, id: \.self) { module in
                    SettingsRow(title: FSBarModuleName(module) ?? module) {
                        Slider(value: Binding(get: { state.values.widgetIntervals[module]! },
                            set: { state.values.widgetIntervals[module] = $0 }), in: 1...60, step: 1).frame(width: 180)
                        Text(String(format: "%.0f 秒", state.values.widgetIntervals[module]!))
                            .monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
            }
            SettingsSection("网络") {
                Toggle("后台持续统计", isOn: $state.values.keepAlive)
                Text("开启后后台累计最近 10 分钟的应用流量；关闭后仅在监测页面可见时统计。")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                SettingsRow(title: "分流显示条数") {
                    Picker("分流显示条数", selection: $state.values.topN) {
                        ForEach([3, 4, 5, 6, 8], id: \.self) { Text("\($0) 个").tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
            }
            SettingsSection("温度") {
                Toggle("采集温度（SMC）", isOn: $state.values.temperatures)
                Text("关闭后停止补充温度采样；读不到传感器时显示对应状态。")
                    .font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
            }
            SettingsSection("即时操作") {
                Button("清空正式历史与峰值") {
                    MonitorSampler.shared.resetHistory()
                    NetworkFlowTracker.shared.reset()
                    operationResult = "正式历史与峰值已清空；设置草稿保持不变"
                }
                if let operationResult {
                    Text(operationResult).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
