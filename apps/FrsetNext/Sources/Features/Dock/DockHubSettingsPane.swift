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
                Toggle("启用顶部刘海组件与 Dock 入口",
                       isOn: Binding(get: { draft.enabled }, set: { draft.enabled = $0 }))
                    .keyboardShortcut("d", modifiers: [.control, .command])
                    .help("⌃⌘D 调整开关；⌘S 保存，Esc 取消调整")
                Text("悬停屏幕顶部中央，展开工具、日历、媒体和窗口。没有刘海的屏幕显示紧凑顶栏。点击「完整窗」或 Dock 中的 Kitnest 打开完整控制台；设置与手册可从组件顶部直达。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("刘海入口无需辅助功能授权；读取与切换其他 App 的窗口需要辅助功能权限。窗口缩略图使用屏幕录制权限，Music 与 Spotify 使用自动化权限，日程使用日历权限。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("辅助功能授权…") { DockHubController.shared.requestAccessibility() }
                HStack {
                    Button("展开刘海组件") { DockHubController.shared.open(expanded: false) }
                    Button("打开完整控制台") { DockHubController.shared.open() }
                }
            }
        }
    }
}
