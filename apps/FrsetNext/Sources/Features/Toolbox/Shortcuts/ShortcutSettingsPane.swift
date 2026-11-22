import SwiftUI

final class ShortcutSettingsDraft: SettingsEditableDraft {
    let entries = AppBootstrap.shortcutSettingsEntries
    @Published var values: [String: AppBootstrap.ShortcutBinding]
    private var savedValues: [String: AppBootstrap.ShortcutBinding]
    @Published var monitorExpanded = true

    init() {
        let values = Dictionary(uniqueKeysWithValues: AppBootstrap.shortcutSettingsEntries.map {
            ($0.id, AppBootstrap.shortcutSettingsValue(for: $0.id))
        })
        self.values = values
        savedValues = values
    }

    var isDirty: Bool { values != savedValues }

    func save() -> String? {
        let changed = values.filter { $0.value != savedValues[$0.key] }
        if let reason = AppBootstrap.applyShortcuts(changed) { return reason }
        objectWillChange.send()
        savedValues = values
        return nil
    }

    func discard() {
        values = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, AppBootstrap.shortcutSettingsValue(for: $0.id))
        })
        savedValues = values
    }

    func restoreDefaults() {
        values = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, AppBootstrap.defaultShortcutValue(for: $0.id))
        })
    }

    func restoreDefault(_ id: String) { values[id] = AppBootstrap.defaultShortcutValue(for: id) }

    func clear(_ id: String) {
        values[id] = AppBootstrap.ShortcutBinding(trigger: .unbound, keyCode: nil, modifiers: 0)
    }

    func selectTrigger(_ id: String, _ trigger: AppBootstrap.ShortcutBinding.Trigger) {
        if trigger == .unbound { clear(id) }
        else { values[id]!.trigger = trigger }
    }

    func record(_ id: String, keyCode: UInt32, modifiers: UInt32) {
        values[id] = AppBootstrap.ShortcutBinding(trigger: .combination, keyCode: keyCode, modifiers: modifiers)
    }
}

public struct ShortcutSettingsPane: View {
    @ObservedObject private var language = LanguageManager.shared
    private let targetID: String?
    private let groups: [(title: String, ids: [String])] = [
        ("面板与搜索", ["openFrset", "commandPalette", "openAndSearch"]),
        ("剪贴板", ["clipboardPanel", "floatingClipboard", "toggleClipboardRecording"]),
        ("截图与取色", ["screenshot", "screenshotCopy", "screenshotOCR", "screenshotTranslate",
                    "screenshotPin", "screenshotWindow", "longScreenshot", "colorpicker", "pinLast", "curtainToggle"]),
        ("录屏", ["recordingToggle", "recordingRegion"]),
        ("性能监测", ["openPerformance"]),
        ("选中文字", ["translateSelection", "summarizeSelection", "polishSelection"])
    ]

    public init(targetID: String? = nil) { self.targetID = targetID }

    public var body: some View {
        let _ = language.overrideDisplayLanguage
        SettingsDraftEditor(id: "shortcuts", makeDraft: { ShortcutSettingsDraft() }) { draft in
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(groups[index].title).font(.system(size: 12, weight: .semibold))
                        ForEach(groups[index].ids, id: \.self) { id in
                            if id == "openPerformance" {
                                DisclosureGroup(isExpanded: Binding(get: { draft.monitorExpanded }, set: { draft.monitorExpanded = $0 })) {
                                    shortcutRow("monitorPopout", draft: draft)
                                } label: {
                                    shortcutRow(id, title: "性能监测窗口", draft: draft)
                                }
                            } else {
                                shortcutRow(id, draft: draft)
                            }
                        }
                    }
                    Divider()
                }
                Text("截图界面打开时，再按当前截图快捷键可切换到近期复制")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(ToolCategory.allCases, id: \.self) { category in
                    let tools = ToolRegistry.all.filter { $0.category == category && $0.identifier != "colorpicker" }
                    if !tools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("工具 · \(category.title)").font(.system(size: 12, weight: .semibold))
                            ForEach(tools) { tool in
                                shortcutRow(ToolShortcutStore.registrationID(tool.identifier), draft: draft)
                            }
                        }
                        Divider()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("面板固定键").font(.system(size: 12, weight: .semibold))
                    staticRow("粘贴", key: "↩", id: "paste")
                    staticRow("搜索剪贴板", key: "⌘ F", id: "searchClipboard")
                    staticRow("搜索（面板内）", key: "⌘ K", id: "panelSearch")
                    staticRow("预览", key: "⎋", id: "preview")
                    staticRow("新建笔记", key: "⌘ N", id: "newNote")
                }
            }
            .font(.system(size: 12))
            .onAppear { if targetID == "monitorPopout" { draft.monitorExpanded = true } }
            .onChange(of: targetID) { if $0 == "monitorPopout" { draft.monitorExpanded = true } }
        }
    }

    /// 唯一录入行：设置入口 shortcuts#<id>，滚动目标为对应 .id(id)。
    private func shortcutRow(_ id: String, title: String? = nil, draft: ShortcutSettingsDraft) -> some View {
        let entry = draft.entries.first { $0.id == id }!
        let value = draft.values[id]!
        let rowTitle = title ?? (id.hasPrefix("tool.")
            ? ToolRegistry.tool(id: String(id.dropFirst(5)))?.name ?? entry.title
            : entry.title)
        return HStack(spacing: 8) {
            Text(rowTitle)
                .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            Picker("触发方式", selection: Binding(
                get: { draft.values[id]!.trigger },
                set: { draft.selectTrigger(id, $0) })) {
                Text("组合键").tag(AppBootstrap.ShortcutBinding.Trigger.combination)
                if AppBootstrap.supportsDoubleTap(for: id) {
                    Text("双按").tag(AppBootstrap.ShortcutBinding.Trigger.doubleTap)
                }
                Text("未绑定").tag(AppBootstrap.ShortcutBinding.Trigger.unbound)
            }
            .labelsHidden().frame(width: 100)
            if value.trigger == .doubleTap {
                Picker("双按修饰键", selection: Binding(
                    get: { draft.values[id]!.doubleTap },
                    set: { draft.values[id]!.doubleTap = $0 })) {
                    ForEach(DoubleTapModifier.allCases) { modifier in
                        Text(modifier.display).tag(modifier)
                    }
                }
                .labelsHidden().frame(width: 130)
            } else if value.trigger == .combination {
                ShortcutRecorderButton(
                    display: value.keyCode.map { ShortcutManager.display(keyCode: $0, modifiers: value.modifiers) },
                    onCapture: { draft.record(id, keyCode: $0, modifiers: $1) },
                    onClear: { draft.clear(id) })
                    .frame(width: 130)
            } else {
                Text("未绑定").foregroundStyle(.secondary).frame(width: 130)
            }
            Button("清除") { draft.clear(id) }
            Button("默认") { draft.restoreDefault(id) }.help("恢复「\(rowTitle)」默认快捷键")
        }
        .id(id)
    }

    private func staticRow(_ title: String, key: String, id: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            Text("固定键").frame(width: 100)
            Text(key).font(.system(size: 11, design: .monospaced)).frame(width: 130)
            Text("只读").frame(width: 90)
        }
        .foregroundStyle(.secondary)
        .id(id)
    }
}
