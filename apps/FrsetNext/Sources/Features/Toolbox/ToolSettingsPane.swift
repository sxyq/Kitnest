import SwiftUI
import AppKit

public struct ToolSettingsPane: View {
    @Stored private var revision = 0
    @Stored private var confirmReset = false
    /// 划词运行（官方工具页底部「划词运行 ⓘ [开关]」，2026-10-18 补齐）
    @AppStorage("tools.selectionRun") private var selectionRun = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("名称").frame(width: 112, alignment: .leading)
                Text("关键词").frame(width: 102, alignment: .leading)
                Text("描述").frame(width: 210, alignment: .leading)
                Text("快捷键").frame(width: 130, alignment: .leading)
                Spacer()
                Text("更多")
            }
            .foregroundStyle(.secondary)
            .frame(height: 26)

            // 2026-10-20 统一版式：去掉内层 ScrollView（外层 panePage 已滚动），
            // 整个表格收进浅色圆角卡片，与常规/剪贴板/数据页同构。
            LazyVStack(spacing: 0) {
                ForEach(ToolRegistry.all) { tool in
                    toolRow(tool)
                    Divider()
                }
            }

            HStack(spacing: 42) {
                Button {
                    ServiceLocator.settings?.open(pane: "ai")
                } label: {
                    Label("自定义 AI 工具", systemImage: "plus")
                }
                Button { confirmReset = true } label: {
                    Label("重置工具", systemImage: "arrow.clockwise")
                }
                Spacer()
                // 官方工具页底部右侧：划词运行 ⓘ [开关]
                HStack(spacing: 6) {
                    Text("划词运行")
                        .foregroundStyle(.secondary)
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("选中文本后显示划词工具栏（需辅助功能权限）")
                    Toggle("", isOn: $selectionRun)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .buttonStyle(.link)
            .frame(height: 32)
            .padding(.top, 8)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .id(revision)
        .confirmationDialog("恢复工具默认设置？", isPresented: $confirmReset) {
            Button("恢复默认设置") {
                for tool in ToolRegistry.all {
                    ToolRegistry.setEnabled(id: tool.identifier, true)
                    ToolShortcutStore.clear(toolID: tool.identifier)
                }
                BuiltinTools.setDefaultAction(.copy)
                revision += 1
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func toolRow(_ tool: ToolDescriptor) -> some View {
        HStack(spacing: 0) {
            Text(tool.name).frame(width: 112, alignment: .leading)
            Text("/" + tool.keyword)
                .foregroundStyle(.secondary)
                .frame(width: 102, alignment: .leading)
            Text(tool.toolDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 210, alignment: .leading)
            ShortcutRecorderButton(
                display: ToolShortcutStore.binding(for: tool.identifier).map {
                    ShortcutManager.display(keyCode: $0.keyCode, modifiers: $0.modifiers)
                },
                onCapture: { code, modifiers in
                    _ = ToolShortcutStore.set(toolID: tool.identifier, keyCode: code, modifiers: modifiers)
                    revision += 1
                },
                onClear: {
                    ToolShortcutStore.clear(toolID: tool.identifier)
                    revision += 1
                })
                .frame(width: 130)
            Spacer(minLength: 12)
            // 官方「更多」列：✓ 启用勾选（行内可见）+ ⋯ 菜单
            HStack(spacing: 8) {
                Button {
                    let enabled = ToolRegistry.isEnabled(id: tool.identifier)
                    ToolRegistry.setEnabled(id: tool.identifier, !enabled)
                    revision += 1
                } label: {
                    Image(systemName: ToolRegistry.isEnabled(id: tool.identifier) ? "checkmark" : "")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .foregroundStyle(ToolRegistry.isEnabled(id: tool.identifier) ? Theme.accent : Color.clear)
                }
                .buttonStyle(.plain)
                .help("启用")
                Menu {
                Toggle("启用", isOn: Binding(
                    get: { ToolRegistry.isEnabled(id: tool.identifier) },
                    set: {
                        ToolRegistry.setEnabled(id: tool.identifier, $0)
                        revision += 1
                    }))
                Button("打开工具") {
                    ToolboxUIState.shared.open(tool.identifier)
                    ServiceLocator.panel?.show()
                }
                if let reason = ShortcutManager.shared.failureReason(id: ToolShortcutStore.registrationID(tool.identifier)) {
                    Text(reason)
                }
            } label: {
                // 原版「更多」按钮为齿轮形（AX desc=齿轮形状，2026-10-18 纯净原版核验）
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            }
        }
        .frame(height: 42)   // 8 行一屏（官方工具页 8 行全显示，2026-10-18）
    }
}
