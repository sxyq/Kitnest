import Combine
import SwiftUI

protocol SettingsEditableDraft: ObservableObject {
    var isDirty: Bool { get }
    func save() -> String?
    func discard()
    func restoreDefaults()
    func isDirty(in scope: String) -> Bool
    func save(in scope: String) -> String?
    func discard(in scope: String)
    func restoreDefaults(in scope: String)
}

extension SettingsEditableDraft {
    func isDirty(in scope: String) -> Bool { isDirty }
    func save(in scope: String) -> String? { save() }
    func discard(in scope: String) { discard() }
    func restoreDefaults(in scope: String) { restoreDefaults() }
}

final class CalendarSettingsDraft: SettingsEditableDraft {
    @Published var firstWeekday = Preferences.shared.calendarFirstWeekday
    @Published var showCalendar = Preferences.shared.value("showCalendar", default: true)
    @Published var showLunar = Preferences.shared.calendarShowLunar
    private var savedFirstWeekday = Preferences.shared.calendarFirstWeekday
    private var savedCalendar = Preferences.shared.value("showCalendar", default: true)
    private var savedLunar = Preferences.shared.calendarShowLunar

    var isDirty: Bool { firstWeekday != savedFirstWeekday || showCalendar != savedCalendar || showLunar != savedLunar }
    func save() -> String? {
        objectWillChange.send()
        if firstWeekday != savedFirstWeekday { Preferences.shared.calendarFirstWeekday = firstWeekday }
        if showCalendar != savedCalendar { Preferences.shared.set("showCalendar", showCalendar) }
        if showLunar != savedLunar { Preferences.shared.calendarShowLunar = showLunar }
        guard UserDefaults.standard.synchronize() else { return "日历设置写入磁盘失败，调整已保留" }
        savedFirstWeekday = firstWeekday
        savedCalendar = showCalendar; savedLunar = showLunar
        return nil
    }
    func discard() {
        firstWeekday = Preferences.shared.calendarFirstWeekday
        showCalendar = Preferences.shared.value("showCalendar", default: true)
        showLunar = Preferences.shared.calendarShowLunar
        savedFirstWeekday = firstWeekday
        savedCalendar = showCalendar; savedLunar = showLunar
    }
    func restoreDefaults() { firstWeekday = 1; showCalendar = true; showLunar = true }
}

/// 生命周期属于设置窗口；页面只借用草稿，切页不提交。
final class SettingsEditingSession: ObservableObject {
    private struct Entry {
        let draft: AnyObject
        let isDirty: () -> Bool
        let scopedDirty: (String) -> Bool
        let scopedSave: (String) -> String?
        let scopedDiscard: (String) -> Void
        let scopedDefaults: (String) -> Void
        let save: () -> String?
        let discard: () -> Void
        let restoreDefaults: () -> Void
        let observation: AnyCancellable
    }

    private var entries: [String: Entry] = [:]
    private var factories: [String: () -> Void] = [:]
    @Published private(set) var allDefaultsPrepared = false
    @Published private(set) var generation = 0

    init() {
        for scope in PersonalizationSettingsPart.allCases {
            register(id: scope.draftID) { AppearanceSettingsDraft(scope: scope) }
        }
        register(id: "pin") { PinSettingsDraft() }
        register(id: "curtain") { CurtainSettingsDraft() }
        register(id: "menuBar") { MenuBarSettingsDraft() }
        register(id: "calendar") { CalendarSettingsDraft() }
        register(id: "monitorWidgets") { MonitorWidgetsSettingsDraft() }
        register(id: "monitorSettings") { MonitorSettingsState() }
        register(id: "searchDisplay") { SearchDisplayDraft() }
        register(id: "clipboardHistory") { ClipboardHistorySettingsDraft() }
        register(id: "clipboardCapture") { ClipboardCaptureSettingsDraft() }
        register(id: "shortcuts") { ShortcutSettingsDraft() }
        register(id: "startup") { StartupSettingsDraft() }
        register(id: "haptics") { HapticSettingsDraft() }
        register(id: "about") { AboutSettingsDraft() }
        register(id: "menuBarArrangement") { MonitorWidgetsSettingsDraft(scope: .arrangement) }
        for section in CaptureSettingsPane.Section.allCases {
            register(id: section.draftID) { CaptureSettingsDraft(section: section) }
        }
        register(id: "recording") { RecordingSettingsDraft() }
        register(id: "captureWorkflow") { WorkflowSettingsDraft() }
        register(id: "tools.collection") { ToolCollectionSettingsDraft() }
        register(id: "tools.aiText") { AITextSettingsDraft() }
        register(id: "aiProvider") { AIProviderSettingsViewModel() }
    }

    func register<D: SettingsEditableDraft>(id: String, makeDraft: @escaping () -> D) {
        factories[id] = { [weak self] in _ = self?.draft(id: id, makeDraft: makeDraft) }
    }

    func draft<D: SettingsEditableDraft>(id: String, makeDraft: @escaping () -> D) -> D {
        if let entry = entries[id] { return entry.draft as! D }
        let draft = makeDraft()
        entries[id] = Entry(draft: draft, isDirty: { draft.isDirty }, scopedDirty: draft.isDirty(in:),
                            scopedSave: draft.save(in:), scopedDiscard: draft.discard(in:), scopedDefaults: draft.restoreDefaults(in:), save: draft.save,
                            discard: draft.discard, restoreDefaults: draft.restoreDefaults,
                            observation: draft.objectWillChange.sink { [weak self] _ in
                                self?.objectWillChange.send()
                            })
        register(id: id, makeDraft: makeDraft)
        return draft
    }

    var dirtyIDs: Set<String> { Set(entries.filter { $0.value.isDirty() }.map(\.key)) }

    func isDirty(page: SettingsPage) -> Bool {
        if let scope = page.editingScope {
            return page.editingDraftIDs.contains { entries[$0]?.scopedDirty(scope) == true }
        }
        return !dirtyIDs.isDisjoint(with: page.editingDraftIDs)
    }

    func restoreAllDefaults() {
        for id in personalizationDraftIDs { factories[id]?() }
        for id in personalizationDraftIDs {
            if let scope = personalizationScopes[id] { entries[id]?.scopedDefaults(scope) }
            else { entries[id]?.restoreDefaults() }
        }
        allDefaultsPrepared = true
    }

    func saveAll() -> String? {
        let ids = allDefaultsPrepared ? personalizationDraftIDs : Set(entries.keys)
        for id in ids.sorted() {
            guard let entry = entries[id] else { continue }
            if allDefaultsPrepared, let scope = personalizationScopes[id] {
                if entry.scopedDirty(scope), let reason = entry.scopedSave(scope) { return reason }
            } else if entry.isDirty(), let reason = entry.save() { return reason }
        }
        allDefaultsPrepared = false
        return nil
    }

    func discardAll() {
        let ids = allDefaultsPrepared ? personalizationDraftIDs : Set(entries.keys)
        for id in ids {
            if allDefaultsPrepared, let scope = personalizationScopes[id] { entries[id]?.scopedDiscard(scope) }
            else { entries[id]?.discard() }
        }
        allDefaultsPrepared = false
    }

    func end() {
        entries.removeAll()
        allDefaultsPrepared = false
        generation &+= 1
    }

    private var personalizationDraftIDs: Set<String> {
        Set(PersonalizationSettingsPart.allCases.map(\.draftID)).union(["pin", "curtain", "menuBar", "menuBarArrangement", "monitorWidgets", "capture.watermark", "recording", "searchDisplay"])
    }
    private let personalizationScopes = ["recording": "effects", "searchDisplay": "display"]
}

extension SettingsPage {
    var editingDraftIDs: Set<String> {
        switch self {
        case .haptics: return ["haptics"]
        case .generalStart: return ["startup"]
        case .generalPersonal: return [PersonalizationSettingsPart.shared.draftID]
        case .appearanceText: return [PersonalizationSettingsPart.textAndRadius.draftID]
        case .panelBackground: return [PersonalizationSettingsPart.panelBackground.draftID]
        case .generalPanel: return [PersonalizationSettingsPart.mainPanel.draftID]
        case .generalWindows: return [PersonalizationSettingsPart.floatingWindow.draftID]
        case .generalNotifications: return [PersonalizationSettingsPart.notification.draftID]
        case .captureActions: return [PersonalizationSettingsPart.captureToolbar.draftID]
        case .clipboardAppearance: return [PersonalizationSettingsPart.clipboardAppearance.draftID]
        case .clipboardFloating: return [PersonalizationSettingsPart.floatingClipboard.draftID]
        case .generalMenuBar: return ["menuBar"]
        case .menuBarArrangement: return ["menuBarArrangement"]
        case .monitorWidgets: return ["monitorWidgets"]
        case .monitorSettings: return ["monitorSettings"]
        case .search: return ["searchDisplay"]
        case .clipboardHistory: return ["clipboardHistory"]
        case .clipboardCapture: return ["clipboardCapture"]
        case .shortcuts: return ["shortcuts"]
        case .tools: return ["tools.collection"]
        case .aiText: return ["tools.aiText"]
        case .ai: return ["aiProvider"]
        case .calendar: return ["calendar"]
        case .about: return ["about"]
        case .capture(.pin): return ["pin"]
        case .capture(.curtain): return ["curtain"]
        case .capture(.capture): return ["capture.capture"]
        case .ocr: return ["capture.ocr"]
        case .watermark: return ["capture.watermark"]
        case .capture(.recording): return ["recording"]
        case .capture(.workflow): return ["captureWorkflow"]
        default: return []
        }
    }
    var editingScope: String? {
        switch self {
        default: return nil
        }
    }
}

struct SettingsDraftEditor<D: SettingsEditableDraft, Content: View>: View {
    @EnvironmentObject private var session: SettingsEditingSession
    let id: String
    let makeDraft: () -> D
    let content: (D) -> Content
    let scope: String?

    init(id: String, scope: String? = nil, makeDraft: @escaping () -> D, @ViewBuilder content: @escaping (D) -> Content) {
        self.id = id
        self.scope = scope
        self.makeDraft = makeDraft
        self.content = content
    }

    var body: some View {
        SettingsDraftEditorContent(draft: session.draft(id: id, makeDraft: makeDraft), scope: scope, content: content)
    }
}

private struct SettingsDraftEditorContent<D: SettingsEditableDraft, Content: View>: View {
    @ObservedObject var draft: D
    @EnvironmentObject private var session: SettingsEditingSession
    @Stored private var result: String?
    let scope: String?
    let content: (D) -> Content

    var body: some View {
        VStack(spacing: 16) {
            content(draft)
            Divider()
            if let result {
                Text(result).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(session.allDefaultsPrepared ? "全部默认已准备 · 保存才生效" :
                     (scope.map { draft.isDirty(in: $0) } ?? draft.isDirty) ? "未保存 · 预览实时更新" : "已保存")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("恢复本页默认") {
                    if let scope { draft.restoreDefaults(in: scope) } else { draft.restoreDefaults() }
                    result = nil
                }
                Button("取消") {
                    if session.allDefaultsPrepared { session.discardAll() }
                    else if let scope { draft.discard(in: scope) }
                    else { draft.discard() }
                    result = nil
                }
                Button(session.allDefaultsPrepared ? "保存全部默认" : "保存") {
                    if let reason = session.allDefaultsPrepared ? session.saveAll() : (scope.map { draft.save(in: $0) } ?? draft.save()) {
                        result = reason
                    } else {
                        result = "已保存并应用"
                        Toast.show("已保存并应用", icon: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}
