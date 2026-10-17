import SwiftUI
import AppKit

public struct ToolSettingsPane: View {
    @Stored private var revision = 0
    @Stored private var confirmReset = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("名称").frame(width: 112, alignment: .leading)
                Text("关键词").frame(width: 102, alignment: .leading)
                Text("描述").frame(width: 264, alignment: .leading)
                Text("快捷键").frame(width: 152, alignment: .leading)
                Spacer()
                Text("更多")
            }
            .foregroundStyle(.secondary)
            .frame(height: 26)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ToolRegistry.all) { tool in
                        toolRow(tool)
                        Divider()
                    }
                }
            }
            .scrollIndicators(.hidden)

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
            }
            .buttonStyle(.link)
            .frame(height: 32)
            .padding(.top, 8)
        }
        .font(.system(size: 12))
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
                .frame(width: 264, alignment: .leading)
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
                .frame(width: 152)
            Spacer(minLength: 12)
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
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .frame(height: 46.5)
    }
}
