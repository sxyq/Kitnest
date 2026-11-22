import SwiftUI
import AppKit

public struct ToolSettingsPane: View {
    public enum Part: String, CaseIterable {
        case collection, aiText, calendar
        var draftID: String { self == .calendar ? "calendar" : "tools.\(rawValue)" }
    }
    private let part: Part
    public init(part: Part = .collection) { self.part = part }

    @ViewBuilder public var body: some View {
        switch part {
        case .collection:
            SettingsDraftEditor(id: part.draftID, makeDraft: { ToolCollectionSettingsDraft() }) { draft in
                ToolCollectionSettingsContent(draft: draft)
            }
        case .aiText:
            SettingsDraftEditor(id: part.draftID, makeDraft: { AITextSettingsDraft() }) { draft in
                AITextSettingsContent(draft: draft)
            }
        case .calendar:
            SettingsDraftEditor(id: part.draftID, makeDraft: { CalendarSettingsDraft() }) { draft in
                CalendarToolSettingsContent(draft: draft)
            }
        }
    }
}

final class ToolCollectionSettingsDraft: SettingsEditableDraft {
    @Published var enabled: [String: Bool]
    private var saved: [String: Bool]
    init() {
        let current = Dictionary(uniqueKeysWithValues: ToolRegistry.all.map {
            ($0.identifier, ToolRegistry.isEnabled(id: $0.identifier))
        })
        enabled = current
        saved = current
    }
    var isDirty: Bool { enabled != saved }
    func save() -> String? {
        for (id, value) in enabled where value != saved[id] { ToolRegistry.setEnabled(id: id, value) }
        guard UserDefaults.standard.synchronize() else { return "工具启用设置写入磁盘失败，调整已保留" }
        objectWillChange.send()
        saved = enabled
        return nil
    }
    func discard() {
        enabled = Dictionary(uniqueKeysWithValues: ToolRegistry.all.map {
            ($0.identifier, ToolRegistry.isEnabled(id: $0.identifier))
        })
        saved = enabled
    }
    func restoreDefaults() { enabled = enabled.mapValues { _ in true } }
}

private struct ToolCollectionSettingsContent: View {
    @ObservedObject var draft: ToolCollectionSettingsDraft
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.settingsTargetField) private var targetField
    var body: some View {
        let _ = language.overrideDisplayLanguage
        SettingsSection("工具集合") {
            SettingsGroupBox {
                ForEach(ToolRegistry.all) { tool in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.name).font(.system(size: 12, weight: .medium))
                            Text("/\(tool.keyword) · \(tool.toolDescription)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(shortcutDisplay(tool.identifier))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("快捷键设置") {
                                let id = tool.identifier == "colorpicker" ? "colorpicker" : ToolShortcutStore.registrationID(tool.identifier)
                                ServiceLocator.settings?.open(pane: "shortcuts#\(id)")
                            }
                            .buttonStyle(.link)
                        }
                        Toggle("启用", isOn: Binding(get: { draft.enabled[tool.identifier]! },
                            set: { draft.enabled[tool.identifier] = $0 }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button("打开") {
                            ToolboxUIState.shared.open(tool.identifier)
                            ServiceLocator.panel?.show()
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 8)
                    .background(targetField == tool.name ? Theme.accent.opacity(0.08) : Color.clear)
                    .id(tool.name)
                    SettingsDivider()
                }
                Button("自定义 AI 文本工具") { ServiceLocator.settings?.open(pane: "aiText") }
                    .buttonStyle(.link).padding(.vertical, 8)
                SettingsDivider()
                SettingsRow(title: "音频混音器", subtitle: "独立工具窗口 · 即时操作") {
                    Button("打开音频混音器") { ToolboxUIState.shared.open("audioMixer") }
                        .controlSize(.small)
                }
                SettingsDivider()
                SettingsRow(title: "使用统计", subtitle: "独立统计窗口 · 即时操作") {
                    Button("打开使用统计") { StatisticsWindowController.shared.openStatistics() }
                        .controlSize(.small)
                }
            }
        }
    }
    private func shortcutDisplay(_ id: String) -> String {
        let binding = id == "colorpicker" ? AppBootstrap.shortcutBinding(for: "colorpicker") : ToolShortcutStore.binding(for: id)
        return binding.map { ShortcutManager.display(keyCode: $0.keyCode, modifiers: $0.modifiers) } ?? "未设置"
    }
}

final class AITextSettingsDraft: SettingsEditableDraft {
    @Published var action = AISummaryAction.storedDefault
    @Published var output = BuiltinTools.defaultAction
    @Published var customTools = CustomAIToolStore.shared.all()
    @Published var newToolName = ""
    @Published var newToolSystemPrompt = ""
    @Published var newToolTemplate = "请处理以下内容：\n\n{input}"
    private var savedAction = AISummaryAction.storedDefault
    private var savedOutput = BuiltinTools.defaultAction
    private var savedTools = CustomAIToolStore.shared.all()
    var isDirty: Bool {
        action != savedAction || output != savedOutput || customTools != savedTools ||
        !newToolName.isEmpty || !newToolSystemPrompt.isEmpty || newToolTemplate != "请处理以下内容：\n\n{input}"
    }
    func save() -> String? {
        if !newToolName.isEmpty || !newToolSystemPrompt.isEmpty || newToolTemplate != "请处理以下内容：\n\n{input}" {
            if let reason = addCustomTool() { return reason }
        }
        if customTools != savedTools {
            do { _ = try JSONEncoder().encode(customTools) }
            catch { return "保存自定义提示词失败：\(error.localizedDescription)" }
        }
        if action != savedAction { action.saveAsDefault() }
        if output != savedOutput { BuiltinTools.setDefaultAction(output) }
        for tool in savedTools where !customTools.contains(where: { $0.id == tool.id }) {
            CustomAIToolStore.shared.delete(id: tool.id)
        }
        for tool in customTools where !savedTools.contains(tool) { CustomAIToolStore.shared.upsert(tool) }
        guard UserDefaults.standard.synchronize() else { return "AI 文本工具设置写入磁盘失败，调整已保留" }
        objectWillChange.send()
        savedAction = action
        savedOutput = output
        savedTools = customTools
        return nil
    }
    func discard() {
        action = AISummaryAction.storedDefault
        output = BuiltinTools.defaultAction
        customTools = CustomAIToolStore.shared.all()
        savedAction = action
        savedOutput = output
        savedTools = customTools
        clearNewTool()
    }
    func restoreDefaults() {
        action = .summarize
        output = .copy
        customTools = []
        clearNewTool()
    }
    func addCustomTool() -> String? {
        let name = newToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = newToolTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !template.isEmpty else { return "请填写工具名称与提示词模板。" }
        customTools.append(CustomAITool(name: name,
            systemPrompt: newToolSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines), promptTemplate: template))
        clearNewTool()
        return nil
    }
    private func clearNewTool() {
        newToolName = ""
        newToolSystemPrompt = ""
        newToolTemplate = "请处理以下内容：\n\n{input}"
    }
}

private struct AITextSettingsContent: View {
    @ObservedObject var draft: AITextSettingsDraft
    @Stored private var message: String?
    var body: some View {
        VStack(spacing: 20) {
            SettingsSection("默认动作") {
                SettingsGroupBox {
                    SettingsRow(title: "文本动作") {
                        Picker("", selection: $draft.action) {
                            ForEach(AISummaryAction.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                    SettingsDivider()
                    SettingsRow(title: "结果处理") {
                        Picker("", selection: $draft.output) {
                            ForEach(BuiltinTools.DefaultAction.allCases, id: \.rawValue) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                }
            }
            SettingsSection("自定义提示词") {
                SettingsGroupBox {
                    ForEach(draft.customTools) { tool in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tool.name).font(.system(size: 12, weight: .medium))
                                Text(tool.systemPrompt.isEmpty ? tool.promptTemplate : tool.systemPrompt)
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("删除") { draft.customTools.removeAll { $0.id == tool.id } }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 8)
                        .id(tool.name)
                        SettingsDivider()
                    }
                    VStack(spacing: 8) {
                        TextField("工具名称", text: $draft.newToolName).textFieldStyle(.roundedBorder)
                        TextField("系统提示词（可选）", text: $draft.newToolSystemPrompt).textFieldStyle(.roundedBorder)
                        TextField("提示词模板，用 {input} 代表待处理文本", text: $draft.newToolTemplate, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        HStack {
                            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer()
                            Button("添加到草稿") { message = draft.addCustomTool() }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 9)
                    .id("自定义提示词")
                    Text("添加、删除和默认动作均在保存后生效。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 8)
                }
            }
        }
    }
}

private struct CalendarToolSettingsContent: View {
    @ObservedObject var draft: CalendarSettingsDraft
    var body: some View {
        let calendar = CalendarService.calendar(firstWeekday: draft.firstWeekday)
        let previewDate = calendar.startOfDay(for: SettingsPreviewSamples.date)
        let event: (String, String, Int, Int, Int) -> CalendarEvent = { id, title, offset, hour, minute in
            let day = calendar.date(byAdding: .day, value: offset, to: previewDate)!
            let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            return CalendarEvent(id: id, title: title, startDate: start)
        }
        let previewEvents = [
            event("island-preview-sync", "项目同步", 0, 14, 0),
            event("island-preview-review", "设计评审", 0, 16, 30),
            event("island-preview-plan", "交付计划", 3, 10, 0),
            event("island-preview-review-two", "需求梳理", 8, 15, 0)
        ]
        let selectedDate = calendar.date(byAdding: .day, value: 3, to: previewDate)!
        VStack(spacing: 20) {
            SettingsSection("日历") {
                SettingsGroupBox {
                    SettingsRow(title: "首页显示日历") {
                        Toggle("", isOn: $draft.showCalendar)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "显示农历") {
                        Toggle("", isOn: $draft.showLunar)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingsDivider()
                    SettingsRow(title: "一周起始日") {
                        Picker("", selection: $draft.firstWeekday) {
                            Text("周日").tag(1)
                            Text("周一").tag(2)
                            if draft.firstWeekday == 7 { Text("周六（当前值）").tag(7) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
            }
            SettingsSection("预览") {
                if draft.showCalendar {
                    CalendarSectionView(firstWeekday: draft.firstWeekday, previewDate: previewDate,
                                        previewEvents: previewEvents, previewSelectedDate: selectedDate,
                                        showLunar: draft.showLunar)
                        .environment(\.isSettingsPreview, true)
                } else {
                    Text("首页日历已隐藏（草稿）").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
