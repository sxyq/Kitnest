import Combine
import SwiftUI

protocol SettingsEditableDraft: ObservableObject {
    var isDirty: Bool { get }
    func save() -> String?
    func discard()
    func restoreDefaults()
}

/// 生命周期属于设置窗口；页面只借用草稿，切页不提交。
final class SettingsEditingSession: ObservableObject {
    private struct Entry {
        let draft: AnyObject
        let isDirty: () -> Bool
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
        register(id: "monitorWidgets") { MonitorWidgetsSettingsDraft() }
        register(id: "captureAppearance") { CaptureAppearanceDraft() }
        register(id: "recordingAppearance") { RecordingAppearanceDraft() }
        register(id: "searchDisplay") { SearchDisplayDraft() }
        register(id: "transferLocal") { LocalTransferSettingsDraft() }
    }

    func register<D: SettingsEditableDraft>(id: String, makeDraft: @escaping () -> D) {
        factories[id] = { [weak self] in _ = self?.draft(id: id, makeDraft: makeDraft) }
    }

    func draft<D: SettingsEditableDraft>(id: String, makeDraft: @escaping () -> D) -> D {
        if let entry = entries[id] { return entry.draft as! D }
        let draft = makeDraft()
        entries[id] = Entry(draft: draft, isDirty: { draft.isDirty }, save: draft.save,
                            discard: draft.discard, restoreDefaults: draft.restoreDefaults,
                            observation: draft.objectWillChange.sink { [weak self] _ in
                                self?.objectWillChange.send()
                            })
        register(id: id, makeDraft: makeDraft)
        return draft
    }

    var dirtyIDs: Set<String> { Set(entries.filter { $0.value.isDirty() }.map(\.key)) }

    func isDirty(page: SettingsPage) -> Bool {
        !dirtyIDs.isDisjoint(with: page.editingDraftIDs)
    }

    func restoreAllDefaults() {
        for makeDraft in Array(factories.values) { makeDraft() }
        for entry in entries.values { entry.restoreDefaults() }
        allDefaultsPrepared = true
    }

    func saveAll() -> String? {
        for id in entries.keys.sorted() where entries[id]!.isDirty() {
            if let reason = entries[id]!.save() { return reason }
        }
        allDefaultsPrepared = false
        return nil
    }

    func discardAll() {
        for entry in entries.values { entry.discard() }
        allDefaultsPrepared = false
    }

    func end() {
        entries.removeAll()
        allDefaultsPrepared = false
        generation &+= 1
    }
}

extension SettingsPage {
    var editingDraftIDs: Set<String> {
        switch self {
        case .generalPersonal: return [PersonalizationSettingsPart.shared.draftID]
        case .generalPanel: return [PersonalizationSettingsPart.mainPanel.draftID]
        case .generalWindows: return [PersonalizationSettingsPart.floatingWindow.draftID]
        case .generalNotifications: return [PersonalizationSettingsPart.notification.draftID]
        case .captureActions: return [PersonalizationSettingsPart.captureToolbar.draftID]
        case .clipboardAppearance: return [PersonalizationSettingsPart.clipboardAppearance.draftID]
        case .clipboardFloating: return [PersonalizationSettingsPart.floatingClipboard.draftID]
        case .generalMenuBar: return ["menuBar"]
        case .monitorWidgets: return ["monitorWidgets"]
        case .search: return ["searchDisplay"]
        case .transferLocal: return ["transferLocal"]
        case .capture(.pin): return ["pin"]
        case .capture(.curtain): return ["curtain"]
        case .capture(.capture): return ["captureAppearance"]
        case .capture(.recording): return ["recordingAppearance"]
        default: return []
        }
    }
}

struct SettingsDraftEditor<D: SettingsEditableDraft, Content: View>: View {
    @EnvironmentObject private var session: SettingsEditingSession
    let id: String
    let makeDraft: () -> D
    let content: (D) -> Content

    init(id: String, makeDraft: @escaping () -> D, @ViewBuilder content: @escaping (D) -> Content) {
        self.id = id
        self.makeDraft = makeDraft
        self.content = content
    }

    var body: some View {
        SettingsDraftEditorContent(draft: session.draft(id: id, makeDraft: makeDraft), content: content)
    }
}

private struct SettingsDraftEditorContent<D: SettingsEditableDraft, Content: View>: View {
    @ObservedObject var draft: D
    @EnvironmentObject private var session: SettingsEditingSession
    @Stored private var result: String?
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
                     draft.isDirty ? "未保存 · 预览实时更新" : "已保存")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("恢复本模块默认") { draft.restoreDefaults(); result = nil }
                Button("取消") {
                    if session.allDefaultsPrepared { session.discardAll() }
                    else { draft.discard() }
                    result = nil
                }
                Button(session.allDefaultsPrepared ? "保存全部默认" : "保存") {
                    if let reason = session.allDefaultsPrepared ? session.saveAll() : draft.save() {
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
