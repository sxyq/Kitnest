import SwiftUI

// MARK: - 设置窗口根视图
// 左侧竖向页签栏（图标 + 文字，选中态胶囊高亮）+ 右侧内容区。
// 页签完全由 SettingsPaneRegistry 驱动，其他模块注册即自动出现。

struct SettingsRootView: View {
    @ObservedObject var state: SettingsUIState

    /// 注册表快照（已按约定顺序排序）
    private var panes: [SettingsPaneDescriptor] { SettingsPaneRegistry.all }

    /// 当前页签：优先取 state 指定 id；找不到时回退到第一个
    private var currentPane: SettingsPaneDescriptor? {
        panes.first { $0.id == state.selectedPaneID } ?? panes.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentArea
        }
        .frame(width: 720, height: 520)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 左侧页签栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(panes, id: \.id) { pane in
                paneButton(pane)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("FrsetNext")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("正向重建版")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .padding(.top, 14)
        .frame(width: 168)
    }

    private func paneButton(_ pane: SettingsPaneDescriptor) -> some View {
        let isSelected = currentPane?.id == pane.id
        return Button {
            state.selectedPaneID = pane.id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                // 选中态胶囊高亮（对齐原版选中底色，改为竖排）
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: - 右侧内容区

    @ViewBuilder
    private var contentArea: some View {
        if let pane = currentPane {
            ScrollView {
                pane.build()
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            // 无页签注册时的空状态
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("暂无设置项")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("各功能模块可通过 SettingsPaneRegistry 注册设置页签")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
