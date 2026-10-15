import SwiftUI

// MARK: - 设置窗口根视图
// 左侧竖向页签栏（图标 + 文字，选中态胶囊高亮）+ 右侧内容区。
// 页签完全由 SettingsPaneRegistry 驱动，其他模块注册即自动出现。

struct SettingsRootView: View {
    @ObservedObject var state: SettingsUIState

    // Midnight 主题覆盖（由 .frsetAppearanceTheme() 注入；非 Midnight 时全为 nil/false）
    @Environment(\.midnightBaseBackgroundOverride) private var midnightBaseBackground
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground
    @Environment(\.usesMidnightTextColor) private var usesMidnightTextColor
    @Environment(\.midnightTextColorOverride) private var midnightTextColor

    /// 注册表快照（已按约定顺序排序）
    private var panes: [SettingsPaneDescriptor] { SettingsPaneRegistry.all }

    /// 当前页签：优先取 state 指定 id；找不到时回退到第一个
    private var currentPane: SettingsPaneDescriptor? {
        panes.first { $0.id == state.selectedPaneID } ?? panes.first
    }

    /// 正文色：Midnight 且 usesMidnightTextColor 为真时用冷白蓝，否则系统 primary
    private var bodyTextColor: Color {
        (usesMidnightTextColor ? midnightTextColor : nil) ?? .primary
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            contentArea
        }
        .frame(width: 720, height: 520)
        .background(midnightBaseBackground ?? Color(NSColor.windowBackgroundColor))
        .foregroundStyle(bodyTextColor)
        // Midnight 主题注入器挂载点（注入器与四个 EnvironmentKey 在共享层 Core/AppearanceTheme.swift）
        .frsetAppearanceTheme()
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
        // Midnight：侧栏用卡片底色与内容区拉开层次（原作 Midnight 侧栏底衬色值 ⬜ 未探明，
        // 此处取 MidnightTheme.cardBackground 近似；非 Midnight 不铺底色）
        .background {
            if let card = midnightCardBackground { card }
        }
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
            .foregroundStyle(isSelected ? Color.white : bodyTextColor)
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
