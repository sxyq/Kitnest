import SwiftUI
import AppKit

// MARK: - 设置页签「工具」（id "tools", systemImage "wrench"）
// 内容：默认输出行为 + 各工具启用/禁用 + 日历显示项（农历）

public struct ToolSettingsPane: View {
    @Stored private var defaultAction: BuiltinTools.DefaultAction = BuiltinTools.defaultAction
    @Stored private var enabledMap: [String: Bool] = [:]
    @Stored private var showLunar: Bool = Preferences.shared.calendarShowLunar
    @Stored private var refreshTick = 0

    public init() {}

    public var body: some View {
        Form {
            Section("默认输出行为") {
                Picker("工具执行完成后", selection: $defaultAction) {
                    ForEach(BuiltinTools.DefaultAction.allCases, id: \.self) { action in
                        Text(action.rawValue).tag(action)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: defaultAction) { newValue in
                    BuiltinTools.setDefaultAction(newValue)
                }
                Text("「存为剪贴板条目」会经由 ToolboxEventBus 交给剪贴板模块，工具箱本身不直接依赖它。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("工具列表") {
                ForEach(ToolRegistry.all) { tool in
                    Toggle(isOn: Binding(
                        get: { enabledMap[tool.identifier] ?? true },
                        set: { newValue in
                            enabledMap[tool.identifier] = newValue
                            ToolRegistry.setEnabled(id: tool.identifier, newValue)
                            refreshTick += 1
                        }
                    )) {
                        HStack(spacing: 8) {
                            Image(systemName: tool.systemImage)
                                .frame(width: 18)
                            Text(tool.name)
                            Spacer()
                            Text(tool.category.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("已启用 \(enabledToolsCount) / \(ToolRegistry.all.count) 个工具")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("日历") {
                Toggle("显示农历 / 节气 / 节日", isOn: $showLunar)
                    .onChange(of: showLunar) { newValue in
                        Preferences.shared.set(Preferences.Keys.calendarShowLunar, newValue)
                    }
                Text("农历覆盖 \(LunarCalendar.coveredYears.lowerBound)-\(LunarCalendar.coveredYears.upperBound) 年；节气覆盖 \(LunarCalendar.solarTermYears.first ?? 0)-\(LunarCalendar.solarTermYears.last ?? 0) 年；法定节假日覆盖 \(HolidayManager.coveredYears) 年。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 420)
        .id(refreshTick)
        .onAppear {
            var map: [String: Bool] = [:]
            for tool in ToolRegistry.all { map[tool.identifier] = ToolRegistry.isEnabled(id: tool.identifier) }
            enabledMap = map
            showLunar = Preferences.shared.calendarShowLunar
            defaultAction = BuiltinTools.defaultAction
        }
    }

    private var enabledToolsCount: Int {
        ToolRegistry.all.filter { enabledMap[$0.identifier] ?? true }.count
    }
}
