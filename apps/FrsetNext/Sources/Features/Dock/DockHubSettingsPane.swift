import SwiftUI

final class DockHubSettingsDraft: SettingsEditableDraft {
    @Published var enabled = DockHubController.savedEnabled
    @Published private var saved = DockHubController.savedEnabled
    var isDirty: Bool { enabled != saved }
    func save() -> String? {
        DockHubController.shared.setEnabled(enabled)
        saved = enabled
        return nil
    }
    func discard() { enabled = saved }
    func restoreDefaults() { enabled = true }
}

struct DockHubSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "dock", makeDraft: { DockHubSettingsDraft() }) { draft in
            VStack(alignment: .leading, spacing: 16) {
                Toggle("在 Dock 显示 Kitnest，并启用悬停操作",
                       isOn: Binding(get: { draft.enabled }, set: { draft.enabled = $0 }))
                    .keyboardShortcut("d", modifiers: [.control, .command])
                    .help("⌃⌘D 调整开关；⌘S 保存，Esc 取消调整")
                Text("悬停 Kitnest 打开快捷操作；悬停其他 App 选择窗口。Music、Spotify 和日历显示对应控制。点击 Kitnest 图标打开完整控制台。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("悬停与切换窗口需要辅助功能权限。窗口缩略图使用屏幕录制权限；音乐控制使用播放器自动化权限，日程使用日历权限。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("辅助功能授权…") { DockHubController.shared.requestAccessibility() }
                Button("打开控制台") { DockHubController.shared.open() }
            }
        }
    }
}
