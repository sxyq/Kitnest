import AppKit
import SwiftUI

enum IslandPage: String, Codable, CaseIterable, Identifiable {
    case clipboard, transfer, search, media, calendar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: return "剪贴板"
        case .transfer: return "中转"
        case .search: return "搜索"
        case .media: return "媒体"
        case .calendar: return "日历"
        }
    }
    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .transfer: return "tray"
        case .search: return "magnifyingglass"
        case .media: return "music.note"
        case .calendar: return "calendar"
        }
    }
}

struct IslandConfiguration: Codable, Equatable {
    var enabled = false
    var hoverOpens = true
    var hoverDelay = 0.15
    var collapseDelay = 0.3
    var width = 560.0
    var visibleRows = 4
    var glass = false
    var shoulders = true
    var followPointerScreen = false
    var pages = IslandPage.allCases
    static let key = "island.configuration"
    static var saved: Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
}

final class IslandSettingsDraft: SettingsEditableDraft {
    @Published var value = IslandConfiguration.saved
    private var saved = IslandConfiguration.saved
    var isDirty: Bool { value != saved }
    func save() -> String? {
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: IslandConfiguration.key)
            saved = value
            IslandController.shared.apply(value)
            return nil
        } catch { return "保存顶部刘海设置失败：\(error.localizedDescription)" }
    }
    func discard() { value = saved }
    func restoreDefaults() { value = IslandConfiguration() }
    func move(_ page: IslandPage, by offset: Int) {
        let index = value.pages.firstIndex(of: page)!
        value.pages.swapAt(index, index + offset)
    }
}

struct IslandSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "island", makeDraft: { IslandSettingsDraft() }) { draft in
            IslandSettingsContent(draft: draft)
        }
    }
}

private struct IslandSettingsContent: View {
    @ObservedObject var draft: IslandSettingsDraft
    @Stored private var expanded = true
    @Stored private var page = IslandPage.clipboard
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IslandSurface(configuration: draft.value, expanded: expanded, page: $page,
                          notchWidth: 0, notchHeight: 0, height: 210,
                          onCollapse: { expanded.toggle() }, onOpen: { expanded = true },
                          onSettings: {}, onFullWindow: {}, onReorder: { draft.value.pages = $0 },
                          summary: "周五交付", detail: "3 个文件") {
                ClipboardSectionView()
                    .environment(\.isSettingsPreview, true)
                    .environment(\.settingsPreviewClipboardItems, SettingsPreviewSamples.clipboardItems)
            }
            .frame(height: 220, alignment: .top)
            Button(expanded ? "演示收起" : "演示展开") { expanded.toggle() }
            Toggle("启用顶部刘海", isOn: $draft.value.enabled)
            Toggle("悬停展开", isOn: $draft.value.hoverOpens)
            if draft.value.hoverOpens {
                HStack {
                    Text("停留 \(Int(draft.value.hoverDelay * 1000)) 毫秒")
                    Slider(value: $draft.value.hoverDelay, in: 0...1, step: 0.05)
                }
            }
            HStack {
                Text("移开后 \(Int(draft.value.collapseDelay * 1000)) 毫秒收起")
                Slider(value: $draft.value.collapseDelay, in: 0...2, step: 0.05)
            }
            HStack {
                Text("展开宽度 \(Int(draft.value.width))")
                Slider(value: $draft.value.width, in: 480...640, step: 20)
            }
            Stepper("列表显示 \(draft.value.visibleRows) 行", value: $draft.value.visibleRows, in: 3...8)
            Toggle("毛玻璃材质", isOn: $draft.value.glass)
            Toggle("两侧连接弧", isOn: $draft.value.shoulders)
            Toggle("打开时跟随鼠标所在屏幕", isOn: $draft.value.followPointerScreen)
            Text("功能排列 · 拖动顶部入口，或用下面的按钮调整")
                .font(.system(size: 12, weight: .medium))
            ForEach(IslandPage.allCases) { item in
                HStack {
                    Toggle(item.title, isOn: Binding(get: { draft.value.pages.contains(item) }, set: { on in
                        if on { draft.value.pages.append(item) }
                        else { draft.value.pages.removeAll { $0 == item } }
                    }))
                    Spacer()
                    if let index = draft.value.pages.firstIndex(of: item) {
                        Button { draft.move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).help("向前移动\(item.title)")
                        Button { draft.move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == draft.value.pages.count - 1).help("向后移动\(item.title)")
                    }
                }
            }
            Text("这里只调整预览。保存后应用到顶部刘海；主面板与独立窗口保持原有样式。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }
}
