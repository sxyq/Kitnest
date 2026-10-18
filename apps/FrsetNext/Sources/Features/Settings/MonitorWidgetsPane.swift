import AppKit
import SwiftUI

// MARK: - 设置 → 性能监测 → 部件设置（v55 重写）
//
// 用户要求：不要直接嵌入 STATS 的设置窗，而是用我们自己的设置体系重写，
// 功能范围覆盖 STATS 的全部能力。版式沿用本 App 设置页的分级结构：
//   一级标题：布局 / 模块 / 维护
//   二级标题：模块名（CPU、内存…）
//   三级标题：形态名 / 选项组（显示、外观、数据）
//
// 配置读写全部走引擎桥（键名与 Stats 一致，widgets.plist 互通）：
//   FSBarCfgBool / FSBarCfgStr / FSBarCfgInt / FSBarCfgSet
//   FSBarSetEnabledForms（每模块可多形态，与引擎一致）
//   FSBarGlobalSet（合并模块 / 间距 / 分隔线）

struct MonitorWidgetsPane: View {

    /// 配置写入后自增，驱动整页重绘（@Stored = 本项目无 macro 环境的 State）
    @Stored private var revision = 0
    @Stored private var confirmReset = false
    @Stored private var confirmReimport = false

    private var modules: [String] { (FSBarAllModules() as? [String]) ?? [] }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                layoutSection
                modulesSection
                maintenanceSection
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("初始化所有设置？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("初始化", role: .destructive) {
                FSBarResetToDefaults()
                FSBarReloadFromStore()
                bump()
            }
        } message: {
            Text("将清空当前部件配置并恢复出厂默认（不影响剪贴板等内容数据）。")
        }
        .alert("重新导入 Stats 配置？", isPresented: $confirmReimport) {
            Button("取消", role: .cancel) {}
            Button("导入", role: .destructive) {
                FSBarResetFromStats()
                FSBarReloadFromStore()
                bump()
            }
        } message: {
            Text("会用 Stats（eu.exelban.Stats）的偏好覆盖当前部件配置。")
        }
    }

    // MARK: - 一级：布局

    private var layoutSection: some View {
        SettingsSection(title: "布局") {
            SettingsGroupBox {
                SettingsRow(title: "合并模块",
                           subtitle: "关闭后每个部件各自占用一个菜单栏图标；开启后合并为一条，可调间距") {
                    Toggle("", isOn: mergedBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                if FSBarMergedEnabled() {
                    SettingsDivider()
                    SettingsRow(title: "模块间距") {
                        Picker("", selection: spacingBinding) {
                            ForEach(Self.spacingItems, id: \.0) { item in
                                Text(item.1).tag(item.0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    SettingsDivider()
                    SettingsRow(title: "分隔线",
                               subtitle: "模块之间画 1pt 竖线") {
                        Toggle("", isOn: separatorBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - 一级：模块（二级 = 模块名，三级 = 形态/选项组）

    private var modulesSection: some View {
        SettingsSection(title: "模块") {
            VStack(spacing: 10) {
                ForEach(modules, id: \.self) { module in
                    moduleCard(module)
                }
            }
        }
    }

    private func moduleCard(_ module: String) -> some View {
        let enabledForms = (FSBarEnabledForms(module) as? [String]) ?? []
        let allForms = (FSBarFormsForModule(module) as? [String]) ?? []
        let on = !enabledForms.isEmpty

        return VStack(spacing: 0) {
            // 二级标题：模块名 + 状态摘要 + 启用开关
            HStack(spacing: 8) {
                Image(systemName: Self.moduleSymbol(module))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(FSBarModuleName(module) ?? module)
                    .font(.system(size: 13, weight: .semibold))
                Text(summary(module: module, forms: enabledForms))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle("", isOn: enabledBinding(module: module, allForms: allForms, current: enabledForms))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            if on {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 0) {
                    // 形态多选（与引擎 FSBarEnabledForms 一致，可同时启用多个）
                    optionRow("部件形态") {
                        FlowLayout(spacing: 6) {
                            ForEach(allForms, id: \.self) { form in
                                formChip(module: module,
                                         form: form,
                                         active: enabledForms.contains(form),
                                         allForms: allForms,
                                         current: enabledForms)
                            }
                        }
                    }
                    optionRow("更新间隔") {
                        Picker("", selection: intervalBinding(module)) {
                            ForEach(Self.intervalItems, id: \.value) { item in
                                Text(item.label).tag(item.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if module == "Sensors" {
                        optionRow("传感器") {
                            Picker("", selection: sensorBinding(module)) {
                                ForEach(sensorKeys(module), id: \.self) { key in
                                    Text(key).tag(key)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                        }
                    }

                    // 每个启用形态的选项（三级标题 = 形态名）
                    ForEach(enabledForms, id: \.self) { form in
                        formOptionsBlock(module: module, form: form)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func formChip(module: String, form: String, active: Bool,
                          allForms: [String], current: [String]) -> some View {
        Button {
            // 保持当前顺序（菜单栏顺序 = FSBarEnabledForms 顺序，与 Stats 拖拽排序语义一致），
            // 新勾选的形态追加到末尾。
            var next = current
            if active { next.removeAll { $0 == form } }
            else { next.append(form) }
            FSBarSetEnabledForms(module, next)
            FSBarReloadFromStore()
            bump()
        } label: {
            HStack(spacing: 4) {
                if let preview = FormPreviewCache.image(module: module, form: form) {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 11)
                }
                Text(FSBarFormName(form) ?? form)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(active ? Color.accentColor.opacity(0.18)
                                      : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(active ? Color.accentColor.opacity(0.55) : .clear,
                                       lineWidth: 1)
            )
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(FSBarFormName(form) ?? form)
    }

    @ViewBuilder
    private func formOptionsBlock(module: String, form: String) -> some View {
        let groups = Self.optionGroups(module: module, form: form)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(FSBarFormName(form) ?? form)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    if !group.title.isEmpty {
                        Text(group.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .padding(.top, 4)
                    }
                    ForEach(Array(group.options.enumerated()), id: \.offset) { _, spec in
                        optionRow(spec.title) {
                            optionControl(module: module, form: form, spec: spec)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func optionControl(module: String, form: String, spec: OptionSpec) -> some View {
        switch spec.kind {
        case .toggle(let key, let def):
            Toggle("", isOn: boolBinding(module: module, form: form, key: key, def: def))
                .toggleStyle(.checkbox)
                .labelsHidden()
        case .menu(let key, let items, let def):
            Picker("", selection: stringBinding(module: module, form: form, key: key, def: def)) {
                ForEach(items, id: \.0) { item in
                    Text(item.1).tag(item.0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        case .color(let key, let def):
            ColorKeyControl(module: module, form: form, key: key, def: def) { bump() }
        }
    }

    // MARK: - 一级：维护

    private var maintenanceSection: some View {
        SettingsSection(title: "维护") {
            SettingsGroupBox {
                SettingsRow(title: "重新导入 Stats 配置",
                           subtitle: "用 Stats 的偏好覆盖当前部件配置") {
                    Button("选择文件") { confirmReimport = true }
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "初始化所有设置",
                           subtitle: "清空部件配置，恢复出厂默认") {
                    Button("初始化") { confirmReset = true }
                        .controlSize(.small)
                }
                SettingsDivider()
                HStack {
                    Text("配置与 Stats 共用 widgets.plist，两边改动互通。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(modules.count) 个模块")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 行

    private func optionRow<Control: View>(_ title: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .frame(minHeight: 26)
    }

    // MARK: - 绑定

    private var mergedBinding: Binding<Bool> {
        Binding(get: { FSBarMergedEnabled() },
                set: { on in
                    FSBarGlobalSet("CombinedModules", NSNumber(value: on))
                    FSBarReloadFromStore()
                    bump()
                })
    }

    private var spacingBinding: Binding<String> {
        Binding(get: {
            (FSBarGlobalRaw("CombinedModules_spacing") as? String) ?? "none"
        }, set: { value in
            FSBarGlobalSet("CombinedModules_spacing", value)
            FSBarReloadFromStore()
            bump()
        })
    }

    private var separatorBinding: Binding<Bool> {
        Binding(get: { FSBarMergedSeparator() },
                set: { on in
                    FSBarGlobalSet("CombinedModules_separator", NSNumber(value: on))
                    FSBarReloadFromStore()
                    bump()
                })
    }

    private func enabledBinding(module: String, allForms: [String], current: [String]) -> Binding<Bool> {
        Binding(get: { !current.isEmpty },
                set: { on in
                    if on {
                        let forms = current.isEmpty ? Array(allForms.prefix(1)) : current
                        FSBarSetEnabledForms(module, forms)
                    } else {
                        FSBarSetEnabledForms(module, [])
                    }
                    FSBarReloadFromStore()
                    bump()
                })
    }

    private func boolBinding(module: String, form: String, key: String, def: Bool) -> Binding<Bool> {
        Binding(get: { FSBarCfgBool(module, form, key, def) },
                set: { value in
                    FSBarCfgSet(module, form, key, NSNumber(value: value))
                    FSBarReloadFromStore()
                    bump()
                })
    }

    private func stringBinding(module: String, form: String, key: String, def: String) -> Binding<String> {
        Binding(get: { FSBarCfgStr(module, form, key, def) ?? def },
                set: { value in
                    FSBarCfgSet(module, form, key, value)
                    FSBarReloadFromStore()
                    bump()
                })
    }

    private func intervalBinding(_ module: String) -> Binding<Int> {
        Binding(get: { Int(FSBarCfgInt(module, nil, "updateInterval", 1)) },
                set: { value in
                    FSBarCfgSet(module, nil, "updateInterval", NSNumber(value: value))
                    FSBarReloadFromStore()
                    bump()
                })
    }

    private func sensorBinding(_ module: String) -> Binding<String> {
        Binding(get: { FSBarCfgStr(module, nil, "sensor", "PPBR") ?? "PPBR" },
                set: { value in
                    FSBarCfgSet(module, nil, "sensor", value)
                    FSBarReloadFromStore()
                    bump()
                })
    }

    private func sensorKeys(_ module: String) -> [String] {
        let keys = FSBarSensorKeysList() ?? []
        return keys.isEmpty ? ["PPBR"] : keys
    }

    private func summary(module: String, forms: [String]) -> String {
        guard let first = forms.first else { return "未在菜单栏显示" }
        let name = FSBarFormName(first) ?? first
        let interval = FSBarCfgInt(module, nil, "updateInterval", 1)
        let extra = forms.count > 1 ? " 等 \(forms.count) 种" : ""
        return "\(name)\(extra) · 每 \(interval) 秒"
    }

    private func bump() { revision &+= 1 }
}

// MARK: - 选项模型

private struct OptionSpec {
    enum Kind {
        case toggle(key: String, def: Bool)
        case menu(key: String, items: [(String, String)], def: String)
        case color(key: String, def: String)
    }
    let title: String
    let kind: Kind

    static func toggle(_ title: String, _ key: String, _ def: Bool) -> OptionSpec {
        OptionSpec(title: title, kind: .toggle(key: key, def: def))
    }
    static func menu(_ title: String, _ key: String, _ items: [(String, String)], _ def: String) -> OptionSpec {
        OptionSpec(title: title, kind: .menu(key: key, items: items, def: def))
    }
    static func color(_ title: String, _ key: String, _ def: String = "system") -> OptionSpec {
        OptionSpec(title: title, kind: .color(key: key, def: def))
    }
}

private struct OptionGroup {
    let title: String
    let options: [OptionSpec]
}

// MARK: - STATS 选项表（逐项对齐引擎设置窗）

fileprivate extension MonitorWidgetsPane {

    static let intervalItems: [(value: Int, label: String)] = [
        (1, "1 秒"), (2, "2 秒"), (3, "3 秒"), (5, "5 秒"),
        (10, "10 秒"), (15, "15 秒"), (30, "30 秒"), (60, "60 秒")
    ]

    static let spacingItems: [(String, String)] = [
        ("none", "无"), ("1", "1"), ("2", "2"), ("3", "3"), ("4", "4"),
        ("5", "5"), ("6", "6"), ("7", "7"), ("8", "8")
    ]

    static let alignItems: [(String, String)] = [
        ("left", "左对齐"), ("center", "居中"), ("right", "右对齐")
    ]
    static let scaleItems: [(String, String)] = [
        ("none", "无"), ("square", "平方"), ("cube", "立方"), ("logarithmic", "对数")
    ]
    static let historyItems: [(String, String)] = [
        ("30", "30"), ("60", "60"), ("90", "90"), ("120", "120")
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

    /// 每个形态的选项组（标题 / 选项），与 frset_barsettings.m 的 FSFormSettingsView 一一对应
    static func optionGroups(module: String, form: String) -> [OptionGroup] {
        switch form {
        case "mini":
            return [OptionGroup(title: "外观", options: [
                .toggle("标签", "label", module == "Sensors" || module == "Disk"),
                .color("颜色", "color"),
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
                    .menu("历史点数", "historyCount", historyItems, "60")
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
                    .color("下载颜色", "downloadColor"),
                    .color("上传颜色", "uploadColor"),
                    .menu("缩放", "scale", scaleItems, "none")
                ]),
                OptionGroup(title: "数据", options: [
                    .menu("历史点数", "historyCount", historyItems, "60")
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
                    .color("下载颜色", "downloadColor"),
                    .color("上传颜色", "uploadColor")
                ])
            ]
        case "memory":
            return [OptionGroup(title: "外观", options: [
                .color("颜色", "color"),
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
                .menu("图标", "icon", iconSymbols, "cpu")
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
        default: return "menubar.rectangle"
        }
    }
}

// MARK: - 颜色选择（预设色键 + 自定义 hex）

private struct ColorKeyControl: View {
    let module: String
    let form: String
    let key: String
    let def: String
    let onChange: () -> Void

    private var value: String { FSBarCfgStr(module, form, key, def) ?? def }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Self.presets, id: \.0) { item in
                    Button {
                        write(item.0)
                    } label: {
                        if item.0 == value { Label(item.1, systemImage: "checkmark") }
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
                ColorPicker("", selection: customBinding)
                    .labelsHidden()
                    .frame(width: 36)
            }
        }
    }

    private func write(_ newValue: String) {
        FSBarCfgSet(module, form, key, newValue)
        FSBarReloadFromStore()
        onChange()
    }

    private var customBinding: Binding<Color> {
        Binding(get: { Self.color(hex: value.replacingOccurrences(of: "custom:", with: "")) },
                set: { newColor in
                    let hex = Self.hex(newColor)
                    write("custom:" + hex)
                })
    }

    private func displayName(_ v: String) -> String {
        if v.hasPrefix("custom:") { return "自定义" }
        return Self.presets.first { $0.0 == v }?.1 ?? v
    }

    private func swatch(_ v: String) -> Color {
        if v.hasPrefix("custom:") {
            return Self.color(hex: v.replacingOccurrences(of: "custom:", with: ""))
        }
        switch v {
        case "system": return .accentColor
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

// MARK: - 形态预览缓存（引擎 FSBarRenderFormPreview 较贵，按 模块/形态/明暗 缓存）

private enum FormPreviewCache {
    private static var cache: [String: NSImage] = [:]

    static func image(module: String, form: String) -> NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(module)/\(form)/\(dark ? "d" : "l")"
        if let cached = cache[key] { return cached }
        guard let image = FSBarRenderFormPreview(module, form, dark) else { return nil }
        cache[key] = image
        return image
    }
}

// MARK: - 简易流式布局（形态 chips 自动换行，macOS 13 Layout）

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 620
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
