import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - 设置页签「快捷键」（id "shortcuts", systemImage "keyboard"）
//
// 两段内容：
//   ① 工具快捷键：为每个工具录入 / 清除一个全局热键（ToolShortcutStore 持久化，触发即打开该工具）；
//   ② 已注册快捷键：展示 ShortcutRegistry 的全部真实注册数据与注册失败原因（冲突 / 系统占用）。
//
// 说明：原作默认热键表尚未取得（specs/01 §13 待查 #7），故不预置任何默认组合，组合键由用户录制。

public struct ShortcutSettingsPane: View {
    @Stored private var shortcuts: [ShortcutDefinition] = []
    @Stored private var toolDisplays: [String: String] = [:]   // toolID -> 组合键展示文本
    @Stored private var toolFailures: [String: String] = [:]   // toolID -> 注册失败原因
    @Stored private var refreshTick = 0

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已注册 \(shortcuts.count) 个全局快捷键")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("刷新") { reload() }.buttonStyle(.bordered)
            }

            toolsSection

            Divider()

            registeredSection

            Text("说明：本模块使用 Carbon RegisterEventHotKey 注册全局热键；组合键至少需包含 ⌘/⌥/⌃ 之一。若组合已被系统或其他应用占用，注册会失败并在上方标出原因。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 360)
        .id(refreshTick)
        .onAppear(perform: reload)
    }

    // MARK: 工具快捷键

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("工具快捷键")
                .font(.system(size: 12, weight: .semibold))
            Text("为工具录入全局热键，触发时唤起主面板并打开该工具。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                ForEach(ToolRegistry.all) { tool in
                    HStack(spacing: 8) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 11))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(tool.name).font(.system(size: 11))
                        Spacer()
                        if let reason = toolFailures[tool.identifier] {
                            Text(reason)
                                .font(.system(size: 9))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                        ShortcutRecorderButton(
                            display: toolDisplays[tool.identifier],
                            onCapture: { keyCode, modifiers in
                                apply(ToolShortcutStore.set(toolID: tool.identifier,
                                                            keyCode: keyCode,
                                                            modifiers: modifiers),
                                      toolID: tool.identifier)
                            },
                            onClear: {
                                ToolShortcutStore.clear(toolID: tool.identifier)
                                reload()
                            })
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: 已注册快捷键（真实注册数据）

    @ViewBuilder
    private var registeredSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已注册快捷键")
                .font(.system(size: 12, weight: .semibold))
            if shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("尚未注册任何快捷键")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("各模块通过 ShortcutRegistry.register(id:title:keyCode:modifiers:handler:) 注册，注册结果会显示在这里。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Table(shortcuts) {
                    TableColumn("功能") { item in
                        Text(item.title).font(.system(size: 11))
                    }
                    TableColumn("快捷键") { item in
                        Text(item.display)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    TableColumn("状态") { item in
                        if let reason = ShortcutManager.shared.failureReason(id: item.id) {
                            Text("注册失败：\(reason)")
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                        } else {
                            Text("已生效")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(minHeight: 140)
            }
        }
    }

    // MARK: 数据

    private func apply(_ outcome: ToolShortcutStore.Outcome, toolID: String) {
        reload()
        // 未含有效修饰键时不会写入 ShortcutManager，故在刷新后补一条提示
        if case .empty = outcome { toolFailures[toolID] = "需包含 ⌘/⌥/⌃" }
    }

    private func reload() {
        shortcuts = ShortcutRegistry.all

        var displays: [String: String] = [:]
        var failures: [String: String] = [:]
        for tool in ToolRegistry.all {
            if let binding = ToolShortcutStore.binding(for: tool.identifier) {
                displays[tool.identifier] = ShortcutManager.display(keyCode: binding.keyCode,
                                                                    modifiers: binding.modifiers)
            }
            if let reason = ShortcutManager.shared.failureReason(id: ToolShortcutStore.registrationID(tool.identifier)) {
                failures[tool.identifier] = "录入未生效：\(reason)"
            }
        }
        toolDisplays = displays
        toolFailures = failures
        refreshTick += 1
    }
}
