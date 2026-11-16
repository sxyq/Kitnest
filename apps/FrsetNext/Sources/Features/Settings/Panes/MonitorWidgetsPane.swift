import AppKit
import SwiftUI

final class MonitorWidgetsSettingsDraft: SettingsEditableDraft {
    enum Scope { case widgets, arrangement }
    let scope: Scope
    static let arrangementKeys: Set<String> = ["CombinedModules", "Widgets_spacing", "CombinedModules_spacing",
        "CombinedModules_separator", "CombinedModules_separatorColor", "Widgets_order"]
    @Published var configuration: [String: Any]
    @Published var selectedModule = "CPU"
    @Published var previewDark = false
    private var saved: [String: Any]
    let modules = FSBarAllModules() as? [String] ?? []

    init(scope: Scope = .widgets) {
        self.scope = scope
        let values = FSBarConfigurationSnapshot() as? [String: Any] ?? [:]
        configuration = values
        saved = values
    }

    private func owns(_ key: String) -> Bool {
        if scope == .arrangement { return Self.arrangementKeys.contains(key) }
        return !key.hasSuffix("_updateInterval") && modules.contains {
            key.hasPrefix($0 + "_") || ($0 == "Power" && (key.hasPrefix("CPUPower_") || key.hasPrefix("GPUPower_")))
        }
    }
    var isDirty: Bool {
        !NSDictionary(dictionary: configuration.filter { owns($0.key) })
            .isEqual(to: saved.filter { owns($0.key) })
    }
    var orderedModules: [String] { FSBarOrderedModules(configuration) as? [String] ?? modules }
    var merged: Bool {
        get { bool("CombinedModules", default: false) }
        set { configuration["CombinedModules"] = newValue }
    }
    var spacing: Double {
        get { FSBarConfigurationSpacing(configuration) }
        set {
            configuration["Widgets_spacing"] = String(format: "%.1f", newValue)
        }
    }
    func bool(_ key: String, default value: Bool) -> Bool {
        (configuration[key] as? NSNumber)?.boolValue ?? value
    }
    func string(_ key: String, default value: String) -> String {
        if let number = configuration[key] as? NSNumber { return number.stringValue }
        return configuration[key] as? String ?? value
    }
    func forms(_ module: String) -> [String] {
        FSBarConfiguredForms(module, configuration) as? [String] ?? []
    }
    var powerMetrics: [String] {
        FSBarPowerMetrics(configuration) as? [String] ?? []
    }
    func setForms(_ module: String, _ forms: [String]) {
        if module == "Power" {
            let metrics = powerMetrics
            if configuration["Power_metrics"] == nil || (!forms.isEmpty && metrics.isEmpty) {
                configuration["Power_metrics"] = (metrics.isEmpty ? MonitorWidgetsPane.powerMetricItems.map(\.0) : metrics)
                    .joined(separator: ",")
            }
        }
        configuration[module + "_widget"] = forms.joined(separator: ",")
    }
    func setPowerMetric(_ metric: String, _ enabled: Bool) {
        var selected = powerMetrics
        if configuration["Power_metrics"] == nil {
            configuration["Power_widget"] = forms("Power").joined(separator: ",")
        }
        if enabled { selected.append(metric) }
        else { selected.removeAll { $0 == metric } }
        configuration["Power_metrics"] = MonitorWidgetsPane.powerMetricItems.map(\.0)
            .filter(selected.contains).joined(separator: ",")
    }
    func move(_ module: String, by offset: Int) {
        var order = orderedModules
        let index = order.firstIndex(of: module)!
        order.swapAt(index, index + offset)
        configuration["Widgets_order"] = order
    }
    func moveForm(_ module: String, _ form: String, by offset: Int) {
        var order = forms(module)
        let index = order.firstIndex(of: form)!
        order.swapAt(index, index + offset)
        setForms(module, order)
    }
    func restoreModule(_ module: String) {
        let prefixes = module == "Power" ? ["Power_", "CPUPower_", "GPUPower_"] : [module + "_"]
        for key in Array(configuration.keys) where owns(key) && prefixes.contains(where: { key.hasPrefix($0) }) {
            configuration.removeValue(forKey: key)
        }
        let defaults = FSBarDefaultConfiguration() as? [String: Any] ?? [:]
        for (key, value) in defaults where owns(key) && prefixes.contains(where: { key.hasPrefix($0) }) { configuration[key] = value }
    }
    func restoreDefaults() {
        discard()
        for key in Array(configuration.keys) where owns(key) {
            configuration.removeValue(forKey: key)
        }
        let defaults = FSBarDefaultConfiguration() as? [String: Any] ?? [:]
        for (key, value) in defaults where owns(key) {
            configuration[key] = value
        }
    }
    func discard() {
        let values = FSBarConfigurationSnapshot() as? [String: Any] ?? [:]
        configuration = values
        saved = values
    }
    func importStats() {
        restoreDefaults()
        let imported = FSBarImportedConfiguration() as? [String: Any] ?? [:]
        for (key, value) in imported where owns(key) { configuration[key] = value }
    }
    func refreshUnownedValues() {
        let current = FSBarConfigurationSnapshot() as? [String: Any] ?? [:]
        configuration = current.filter { !owns($0.key) }.merging(configuration.filter { owns($0.key) }) { _, draft in draft }
    }
    func save() -> String? {
        let changed = configuration.filter { key, value in
            owns(key) && !NSObjectEqual(value, saved[key])
        }
        let removed = saved.keys.filter { owns($0) && configuration[$0] == nil }
        if let reason = FSBarSaveConfiguration(changed, removed) { return reason }
        saved = configuration
        FSBarReloadFromStore()
        return nil
    }

    private func NSObjectEqual(_ value: Any, _ other: Any?) -> Bool {
        guard let other else { return false }
        return (value as! NSObject).isEqual(other)
    }
}

struct MonitorWidgetsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "monitorWidgets", makeDraft: { MonitorWidgetsSettingsDraft() }) { draft in
            MonitorWidgetsContent(draft: draft)
                .onAppear { draft.refreshUnownedValues() }
        }
    }
}

private struct MonitorWidgetsContent: View {
    @ObservedObject var draft: MonitorWidgetsSettingsDraft
    @Environment(\.settingsTargetField) private var targetField

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroupBox {
                Text("菜单栏预览 · 固定示例数值").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("数值槽按格式定宽；读数、单位变化与充电状态不会移动相邻部件。标签、单位及排列调整先预览，保存后应用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("背景场景", selection: $draft.previewDark) {
                    Text("浅色背景").tag(false)
                    Text("深色背景").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 220)
                ScrollView(.horizontal) {
                    MonitorWidgetsPreview(configuration: draft.configuration, modules: [draft.selectedModule], dark: draft.previewDark)
                        .fixedSize().padding(8)
                }
                .background(draft.previewDark ? Color(.sRGB, white: 0.12, opacity: 1) : Color(.sRGB, white: 0.94, opacity: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if draft.forms(draft.selectedModule).isEmpty {
                    Text("当前部件已隐藏").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                SettingsRow(title: "选择部件") {
                    Picker("选择部件", selection: $draft.selectedModule) {
                        ForEach(draft.orderedModules, id: \.self) { module in
                            Text(FSBarModuleName(module) ?? module).tag(module)
                        }
                    }.labelsHidden().frame(width: 180)
                }
            }
            moduleCard(draft.selectedModule)
            SettingsGroupBox {
                SettingsRow(title: "重新导入 Stats 配置", subtitle: "只替换当前草稿；保存后应用") {
                    Button("重新导入") { draft.importStats() }.controlSize(.small)
                }
            }
        }
        .onAppear { selectTarget(targetField) }
        .onChange(of: targetField) { selectTarget($0) }
    }

    private func selectTarget(_ target: String?) {
        if let module = target, draft.modules.contains(module) { draft.selectedModule = module }
    }

    private func moduleCard(_ module: String) -> some View {
        let enabled = draft.forms(module)
        let all = FSBarFormsForModule(module) as? [String] ?? []
        return SettingsGroupBox {
            HStack(spacing: 8) {
                Label(FSBarModuleName(module) ?? module, systemImage: MonitorWidgetsPane.moduleSymbol(module))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("恢复默认") { draft.restoreModule(module) }.controlSize(.small)
                Toggle("显示" + (FSBarModuleName(module) ?? module), isOn: Binding(
                    get: { !draft.forms(module).isEmpty },
                    set: { draft.setForms(module, $0 ? Array(all.prefix(1)) : []) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if module == "Power" {
                Text("第一排整机，第二排 CPU 与 GPU；关闭指标后紧凑重排。整机是系统负载，适配器输入另列；CPU/GPU 按能量差分计算。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if module == "Power" {
                SettingsDivider()
                optionRow("监测指标") {
                    HStack(spacing: 12) {
                        ForEach(MonitorWidgetsPane.powerMetricItems, id: \.0) { item in
                            Toggle(item.1, isOn: Binding(
                                get: { draft.powerMetrics.contains(item.0) },
                                set: { draft.setPowerMetric(item.0, $0) }))
                                .toggleStyle(.checkbox).font(.system(size: 11))
                        }
                    }
                }
            }
            if !enabled.isEmpty {
                SettingsDivider()
                FlowHStack(spacing: 6, lineSpacing: 6) {
                    ForEach(all, id: \.self) { form in
                        Toggle(FSBarFormName(form) ?? form, isOn: Binding(
                            get: { draft.forms(module).contains(form) },
                            set: { on in
                                var next = draft.forms(module)
                                if on { next.append(form) } else { next.removeAll { $0 == form } }
                                draft.setForms(module, next)
                            }))
                            .toggleStyle(.checkbox).font(.system(size: 11))
                    }
                }
                if module == "Sensors" {
                    optionRow("传感器") {
                        Picker("传感器", selection: stringBinding("Sensors_sensor", "PPBR")) {
                            ForEach(sensorKeys, id: \.self) { key in
                                Text(StatsDataProvider.sensorDisplayName(key)).tag(key)
                            }
                        }.labelsHidden()
                    }
                }
                ForEach(Array(enabled.enumerated()), id: \.element) { offset, form in
                    HStack {
                        Text(FSBarFormName(form) ?? form).font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button { draft.moveForm(module, form, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(offset == 0).help("上移形态")
                        Button { draft.moveForm(module, form, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(offset == enabled.count - 1).help("下移形态")
                    }.padding(.top, 6)
                    ForEach(Array(MonitorWidgetsPane.optionGroups(module: module, form: form).enumerated()), id: \.offset) { _, group in
                        ForEach(Array(group.options.enumerated()), id: \.offset) { _, spec in
                            optionRow(spec.title) {
                                optionControl(keyPrefix: module + "_" + form + "_", spec: spec)
                                    .accessibilityLabel(spec.title)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sensorKeys: [String] {
        let selected = draft.string("Sensors_sensor", default: "PPBR")
        return Array(Set((FSBarSensorKeysList() as? [String] ?? []) + [selected])).sorted()
    }
    private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }.frame(minHeight: 26)
    }
    private func boolBinding(_ key: String, _ value: Bool) -> Binding<Bool> {
        Binding(get: { draft.bool(key, default: value) }, set: { draft.configuration[key] = $0 })
    }
    private func stringBinding(_ key: String, _ value: String) -> Binding<String> {
        Binding(get: { draft.string(key, default: value) }, set: { draft.configuration[key] = $0 })
    }
    private func numberBinding(_ key: String, _ value: String) -> Binding<Double> {
        Binding(get: { Double(draft.string(key, default: value))! },
                set: { draft.configuration[key] = String(format: "%.0f", $0) })
    }
    @ViewBuilder private func optionControl(keyPrefix: String, spec: OptionSpec) -> some View {
        switch spec.kind {
        case .toggle(let key, let value):
            Toggle(spec.title, isOn: boolBinding(keyPrefix + key, value)).labelsHidden().toggleStyle(.checkbox)
        case .menu(let key, let items, let value):
            Picker(spec.title, selection: stringBinding(keyPrefix + key, value)) {
                ForEach(items, id: \.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().fixedSize()
        case .color(let key, let value):
            ColorKeyControl(value: stringBinding(keyPrefix + key, value))
        case .slider(let key, let value, let min, let max, let step, let unit):
            HStack {
                Slider(value: numberBinding(keyPrefix + key, value), in: min...max, step: step).frame(width: 130)
                Text(draft.string(keyPrefix + key, default: value) + unit).monospacedDigit().frame(width: 50)
            }
        }
    }
}

struct MenuBarArrangementPane: View {
    var body: some View {
        SettingsDraftEditor(id: "menuBarArrangement", makeDraft: { MonitorWidgetsSettingsDraft(scope: .arrangement) }) { draft in
            MenuBarArrangementContent(draft: draft).onAppear { draft.refreshUnownedValues() }
        }
    }
}

private struct MenuBarArrangementContent: View {
    @ObservedObject var draft: MonitorWidgetsSettingsDraft
    var body: some View {
        SettingsGroupBox {
            Picker("背景场景", selection: $draft.previewDark) {
                Text("浅色背景").tag(false)
                Text("深色背景").tag(true)
            }
            .pickerStyle(.segmented).frame(width: 220)
            ScrollView(.horizontal) {
                MonitorWidgetsPreview(configuration: draft.configuration, modules: draft.orderedModules, dark: draft.previewDark)
                    .fixedSize().padding(8)
            }
            .background(draft.previewDark ? Color(.sRGB, white: 0.12, opacity: 1) : Color(.sRGB, white: 0.94, opacity: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            SettingsRow(title: "合并模块", subtitle: "拆分模式由系统保留每项 16pt 间隙；排列顺序用于合并条") {
                Toggle("合并模块", isOn: $draft.merged).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow(title: "部件间距", subtitle: "同时作用于内部留白和合并条间距") {
                Slider(value: $draft.spacing, in: 0...24, step: 0.5).frame(width: 150)
                Text(String(format: "%.1f pt", draft.spacing)).monospacedDigit().frame(width: 50)
            }
            if draft.merged {
                SettingsRow(title: "分隔线") {
                    Toggle("分隔线", isOn: Binding(get: { draft.bool("CombinedModules_separator", default: true) },
                        set: { draft.configuration["CombinedModules_separator"] = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if draft.bool("CombinedModules_separator", default: true) {
                    SettingsRow(title: "分隔线颜色") {
                        ColorKeyControl(value: Binding(get: { draft.string("CombinedModules_separatorColor", default: "monochrome") },
                            set: { draft.configuration["CombinedModules_separatorColor"] = $0 }))
                    }
                }
            }
            SettingsDivider()
            ForEach(Array(draft.orderedModules.enumerated()), id: \.element) { index, module in
                SettingsRow(title: FSBarModuleName(module) ?? module) {
                    Button { draft.move(module, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).help("上移模块")
                    Button { draft.move(module, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index == draft.orderedModules.count - 1).help("下移模块")
                }
            }
            SettingsRow(title: "重新导入 Stats 排列", subtitle: "只替换排列草稿；保存后应用") {
                Button("重新导入") { draft.importStats() }.controlSize(.small)
            }
        }
    }
}

private struct MonitorWidgetsPreview: NSViewRepresentable {
    let configuration: [String: Any]
    let modules: [String]
    var dark: Bool? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        FSBarCreateConfiguredPreview(modules, configuration, dark ?? (colorScheme == .dark))!
    }
    func updateNSView(_ view: NSView, context: Context) {
        FSBarUpdateConfiguredPreview(view, modules, configuration, dark ?? (colorScheme == .dark))
        view.invalidateIntrinsicContentSize()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: nsView.frame.width, height: 22)
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        view.subviews.forEach { $0.removeFromSuperview() }
    }
}

struct OptionSpec {
    enum Kind {
        case toggle(key: String, def: Bool)
        case menu(key: String, items: [(String, String)], def: String)
        case color(key: String, def: String)
        /// v134：数值滑条（存储仍为字符串；step 对齐后写回整数串）
        case slider(key: String, def: String, min: Double, max: Double, step: Double, unit: String)
    }
    let title: String
    let kind: Kind

    static func toggle(_ title: String, _ key: String, _ def: Bool) -> OptionSpec {
        OptionSpec(title: title, kind: .toggle(key: key, def: def))
    }
    static func menu(_ title: String, _ key: String, _ items: [(String, String)], _ def: String) -> OptionSpec {
        OptionSpec(title: title, kind: .menu(key: key, items: items, def: def))
    }
    static func color(_ title: String, _ key: String, _ def: String = "systemAccent") -> OptionSpec {
        OptionSpec(title: title, kind: .color(key: key, def: def))
    }
    /// v134：数值滑条（如 历史点数 10–120）
    static func slider(_ title: String, _ key: String, _ def: String,
                       _ min: Double, _ max: Double, _ step: Double, unit: String = "") -> OptionSpec {
        OptionSpec(title: title, kind: .slider(key: key, def: def, min: min, max: max, step: step, unit: unit))
    }
}

struct OptionGroup {
    let title: String
    let options: [OptionSpec]
}

// MARK: - STATS 选项表（逐项对齐引擎设置窗）

extension MonitorWidgetsPane {

    // v134：intervalItems/spacingItems/historyItems 已改滑条，档位表移除

    static let alignItems: [(String, String)] = [
        ("left", "左对齐"), ("center", "居中"), ("right", "右对齐")
    ]
    static let scaleItems: [(String, String)] = [
        ("none", "无"), ("square", "平方"), ("cube", "立方"), ("logarithmic", "对数")
    ]
    static let pictogramItems: [(String, String)] = [
        ("none", "无"), ("dots", "圆点"), ("arrows", "箭头"), ("chars", "字符")
    ]
    static let pictogramColors: [(String, String)] = [
        ("none", "无"), ("default", "默认色"), ("transparent", "无活动时透明"), ("constant", "固定色")
    ]
    static let batteryItems: [(String, String)] = [
        ("none", "无"), ("percentage", "百分比"), ("time", "时间"),
        ("percentageAndTime", "百分比 + 时间"), ("timeAndPercentage", "时间 + 百分比")
    ]
    static let iconSymbols: [(String, String)] = [
        ("cpu", "cpu"), ("memorychip", "memorychip"), ("internaldrive", "internaldrive"),
        ("arrow.up.arrow.down", "arrow.up.arrow.down"), ("thermometer.medium", "thermometer.medium"),
        ("battery.100", "battery.100"), ("display", "display"), ("bolt.fill", "bolt.fill"), ("fan", "fan")
    ]
    static let powerMetricItems: [(String, String)] = [
        ("Power", "整机"), ("CPUPower", "CPU"), ("GPUPower", "GPU")
    ]

    /// 每个形态的选项组（标题 / 选项），与 frset_barsettings.m 的 FSFormSettingsView 一一对应
    static func optionGroups(module: String, form: String) -> [OptionGroup] {
        if module == "Power" {
            switch form {
            case "mini":
                return [OptionGroup(title: "外观", options: [
                    .toggle("标签", "label", true), .color("颜色", "color", "monochrome")
                ])]
            case "line_chart":
                return [
                    OptionGroup(title: "显示", options: [
                        .toggle("标签", "label", true),
                        .toggle("边框", "box", true),
                        .toggle("外框", "frame", false)
                    ]),
                    OptionGroup(title: "外观", options: [
                        .color("颜色", "color", "monochrome")
                    ]),
                    OptionGroup(title: "数据", options: [
                        .slider("历史点数", "historyCount", "60", 10, 120, 10, unit: " 点")
                    ])
                ]
            case "icon":
                return [
                    OptionGroup(title: "显示", options: [
                        .toggle("标签", "label", true), .color("颜色", "color", "monochrome")
                    ]),
                    OptionGroup(title: "图标", options: [
                        .menu("图标", "icon", iconSymbols, moduleSymbol(module))
                    ])
                ]
            default:
                return []
            }
        }
        switch form {
        case "mini":
            return [OptionGroup(title: "外观", options: [
                .toggle("标签", "label", module == "Sensors" || module == "Disk" || module.hasSuffix("Power")),
                .color("颜色", "color", "monochrome"),
                .menu("对齐", "alignment", alignItems, "left")
            ])]
        case "line_chart":
            return [
                OptionGroup(title: "显示", options: [
                    .toggle("标签", "label", false),
                    .toggle("数值", "value", false),
                    .toggle("边框", "box", true),
                    .toggle("外框", "frame", false)
                ]),
                OptionGroup(title: "外观", options: [
                    .color("颜色", "color"),
                    .toggle("数值随颜色", "valueColor", false),
                    .menu("缩放", "scale", scaleItems, "none")
                ]),
                OptionGroup(title: "数据", options: [
                    .slider("历史点数", "historyCount", "60", 10, 120, 10, unit: " 点")
                ])
            ]
        case "bar_chart":
            return [OptionGroup(title: "外观", options: [
                .toggle("标签", "label", false),
                .color("颜色", "color"),
                .toggle("边框", "box", true),
                .toggle("外框", "frame", false)
            ])]
        case "pie_chart", "tachometer":
            return [OptionGroup(title: "外观", options: [
                .toggle("标签", "label", false),
                .toggle("单色强调", "monochrome", false)
            ])]
        case "network_chart":
            return [
                OptionGroup(title: "显示", options: [
                    .toggle("标签", "label", false),
                    .toggle("边框", "box", false),
                    .toggle("外框", "frame", false),
                    .toggle("反向顺序", "reversedOrder", false)
                ]),
                OptionGroup(title: "外观", options: [
                    .color("下载颜色", "downloadColor", "secondBlue"),
                    .color("上传颜色", "uploadColor", "secondRed"),
                    .menu("缩放", "scale", scaleItems, "none")
                ]),
                OptionGroup(title: "数据", options: [
                    .slider("历史点数", "historyCount", "60", 10, 120, 10, unit: " 点")
                ])
            ]
        case "speed":
            return [
                OptionGroup(title: "显示", options: [
                    .menu("数值", "displayValue", [("oi", "输出/输入"), ("io", "输入/输出"),
                                                  ("o", "输出"), ("i", "输入")], "oi"),
                    .menu("排列", "mode", [("oneRow", "单行"), ("twoRows", "双行")], "twoRows")
                ]),
                OptionGroup(title: "图元", options: [
                    .menu("图元", "icon", pictogramItems, "dots"),
                    .menu("图元着色", "iconColor", pictogramColors, "default"),
                    .menu("图元对齐", "iconAlignment", [("left", "左"), ("right", "右")], "left")
                ]),
                OptionGroup(title: "数值", options: [
                    .toggle("显示数值", "value", true),
                    .menu("数值着色", "valueColor", pictogramColors, "default"),
                    .menu("数值对齐", "valueAlignment", alignItems, "left"),
                    .toggle("单位", "units", true)
                ]),
                OptionGroup(title: "颜色", options: [
                    .toggle("单色强调", "monochrome", false),
                    .color("下载颜色", "downloadColor", "secondBlue"),
                    .color("上传颜色", "uploadColor", "secondRed")
                ])
            ]
        case "ring":
            return [OptionGroup(title: "外观", options: [
                .toggle("标签", "label", false),
                .color("颜色", "color"),
                .toggle("单色强调", "monochrome", false)
            ])]
        case "wave":
            return [
                OptionGroup(title: "显示", options: [
                    .toggle("标签", "label", false)
                ]),
                OptionGroup(title: "外观", options: [
                    .color("颜色", "color")
                ]),
                OptionGroup(title: "数据", options: [
                    .slider("历史点数", "historyCount", "60", 10, 120, 10, unit: " 点")
                ])
            ]
        case "dots":
            return [OptionGroup(title: "外观", options: [
                .toggle("标签", "label", false),
                .color("颜色", "color"),
                .toggle("单色强调", "monochrome", false)
            ])]
        case "bar":
            return [OptionGroup(title: "外观", options: [
                .toggle("标签", "label", false),
                .color("颜色", "color")
            ])]
        case "memory":
            return [OptionGroup(title: "外观", options: [
                .color("颜色", "color", "monochrome"),
                .toggle("显示符号", "symbols", true),
                .toggle("反向顺序", "orderReversed", false)
            ])]
        case "battery":
            return [OptionGroup(title: "外观", options: [
                .menu("附加信息", "display", batteryItems, "percentage"),
                .color("颜色", "color")
            ])]
        case "icon":
            return [OptionGroup(title: "图标", options: [
                .menu("图标", "icon", iconSymbols, moduleSymbol(module))
            ])]
        default:
            return []   // label / state / run_cat 没有额外选项
        }
    }

    static func moduleSymbol(_ module: String) -> String {
        switch module {
        case "CPU": return "cpu"
        case "RAM": return "memorychip"
        case "GPU": return "display"
        case "Disk": return "internaldrive"
        case "Network": return "arrow.up.arrow.down"
        case "Sensors": return "thermometer.medium"
        case "Battery": return "battery.100"
        case "Power": return "bolt.fill"
        case "CPUPower": return "cpu"
        case "GPUPower": return "display"
        default: return "menubar.rectangle"
        }
    }
}

// MARK: - 颜色选择（预设色键 + 自定义 hex）

private struct ColorKeyControl: View {
    @Binding var value: String

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Self.presets, id: \.0) { item in
                    Button {
                        write(item.0)
                    } label: {
                        if item.0 == value || (item.0 == "system" && value == "systemAccent") {
                            Label(item.1, systemImage: "checkmark")
                        }
                        else { Text(item.1) }
                    }
                }
                Divider()
                Button("自定义…") {
                    write("custom:" + (value.hasPrefix("custom:") ? String(value.dropFirst(7)) : "#4A90E2"))
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(swatch(value))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                    Text(displayName(value))
                        .font(.system(size: 11))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if value.hasPrefix("custom:") {
                ColorPicker("", selection: customBinding, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36)
            }
        }
    }

    private func write(_ newValue: String) {
        value = newValue
    }

    private var customBinding: Binding<Color> {
        Binding(get: { Self.color(hex: value.replacingOccurrences(of: "custom:", with: "")) },
                set: { newColor in
                    let hex = Self.hex(newColor)
                    write("custom:" + hex)
                })
    }

    private func displayName(_ v: String) -> String {
        if v == "systemAccent" { return "强调色" }
        if v.hasPrefix("custom:") { return "自定义" }
        return Self.presets.first { $0.0 == v }?.1 ?? v
    }

    private func swatch(_ v: String) -> Color {
        if v.hasPrefix("custom:") {
            return Self.color(hex: v.replacingOccurrences(of: "custom:", with: ""))
        }
        switch v {
        case "system", "systemAccent": return .accentColor
        case "monochrome": return .primary
        case "utilization", "pressure": return .gray
        case "clear": return .clear
        case "white": return .white
        case "black": return .black
        case "red", "secondRed": return .red
        case "green", "secondGreen": return .green
        case "blue", "secondBlue": return .blue
        case "yellow", "secondYellow": return .yellow
        case "orange", "secondOrange": return .orange
        case "purple", "secondPurple": return .purple
        case "pink": return .pink
        case "brown", "secondBrown": return .brown
        case "cyan": return .cyan
        case "magenta": return .pink
        case "teal": return .teal
        case "indigo": return .indigo
        case "darkGray": return Color(white: 0.35)
        case "lightGray": return Color(white: 0.8)
        case "secondGray", "gray": return .gray
        default: return .gray
        }
    }

    static func color(hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .accentColor }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static let presets: [(String, String)] = [
        ("utilization", "随占用"), ("pressure", "随压力"),
        ("system", "强调色"), ("monochrome", "单色"),
        ("clear", "透明"), ("white", "白"), ("black", "黑"),
        ("gray", "灰"), ("secondGray", "次级灰"), ("darkGray", "深灰"), ("lightGray", "浅灰"),
        ("red", "红"), ("secondRed", "次级红"), ("green", "绿"), ("secondGreen", "次级绿"),
        ("blue", "蓝"), ("secondBlue", "次级蓝"), ("yellow", "黄"), ("secondYellow", "次级黄"),
        ("orange", "橙"), ("secondOrange", "次级橙"), ("purple", "紫"), ("secondPurple", "次级紫"),
        ("brown", "棕"), ("secondBrown", "次级棕"), ("cyan", "青"), ("magenta", "品红"),
        ("pink", "粉"), ("teal", "蓝绿"), ("indigo", "靛蓝")
    ]
}

