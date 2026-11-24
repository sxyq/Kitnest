import SwiftUI
import AppKit

// MARK: - 设置 · 工作流（v264）
//
// 一张有序步骤表，最多两个参数（路径 / 地址 / 仓库 / Token）。
// 不做拖拽排序：步骤顺序就是列表顺序，加/删/改即可——排序需求远小于「先能跑通」。

struct WorkflowSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "captureWorkflow", makeDraft: { WorkflowSettingsDraft() }) { draft in
            WorkflowSettingsContent(draft: draft)
        }
    }
}

final class WorkflowSettingsDraft: SettingsEditableDraft {
    @Published var workflows: [CaptureWorkflow]
    private var saved: [CaptureWorkflow]
    init() {
        let workflows = WorkflowStore.load()
        self.workflows = workflows
        self.saved = workflows
    }
    var isDirty: Bool { workflows != saved }
    func save() -> String? {
        if let reason = WorkflowStore.save(workflows) { return reason }
        objectWillChange.send()
        saved = workflows
        return nil
    }
    func discard() { workflows = WorkflowStore.load(); saved = workflows }
    func restoreDefaults() { workflows = [] }
}

private struct WorkflowSettingsContent: View {
    @ObservedObject var draft: WorkflowSettingsDraft
    @Environment(\.settingsTargetField) private var targetField
    private var workflows: [CaptureWorkflow] {
        get { draft.workflows }
        nonmutating set { draft.workflows = newValue }
    }

    var body: some View {
        SettingsSection("工作流") {
            SettingsGroupBox {
                Text("截图落盘后按顺序执行。失败时会暂停后续步骤，保留截图并允许只重试失败步骤。GitHub 和 Linear 凭证保存在系统钥匙串。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                ForEach(Array(workflows.enumerated()), id: \.element.id) { index, workflow in
                    workflowBlock(index: index)
                    if index < workflows.count - 1 {
                        SettingsDivider()
                    }
                }

                SettingsDivider()

                HStack(spacing: 8) {
                    Button("新建工作流") {
                        workflows.append(CaptureWorkflow(name: "工作流 \(workflows.count + 1)"))
                    }
                    .controlSize(.small)
                    Text("工作流配置保存在本机；服务凭证使用系统钥匙串。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: 单个工作流

    @ViewBuilder
    private func workflowBlock(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: binding(index, \.enabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                TextField("名称", text: binding(index, \.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer(minLength: 8)
                Button {
                    workflows.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            ForEach(Array(workflows[index].steps.enumerated()), id: \.element.id) { stepIndex, step in
                stepRow(workflow: index, step: stepIndex, stepValue: step)
            }

            Menu {
                ForEach(WorkflowStep.Kind.allCases) { kind in
                    Button(kind.title) {
                        workflows[index].steps.append(WorkflowStep(kind: kind, a: defaultArgument(for: kind)))
                    }
                }
            } label: {
                Label("添加步骤", systemImage: "plus.circle")
                    .font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 110)
        }
        .padding(.vertical, 8)
        .background(targetField == workflows[index].name ? Theme.accent.opacity(0.08) : Color.clear)
        // 2026-11-25（函数审查 NEEDS_FIX 落实）：视图身份必须绑稳定 UUID。
        // 旧实现绑在可编辑的 name 上——名称 TextField 每敲一个字符整块（含全部步骤行）
        // 销毁重建、输入焦点被打断。CaptureWorkflow 本就是 Identifiable。
        .id(workflows[index].id)
        .opacity(workflows[index].enabled ? 1 : 0.72)
    }

    @ViewBuilder
    private func stepRow(workflow: Int, step: Int, stepValue: WorkflowStep) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: stepValue.kind))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(stepValue.kind.title)
                .font(.system(size: 11.5))
                .frame(width: 118, alignment: .leading)

            if let titles = stepValue.kind.fieldTitles {
                TextField(titles.0, text: stepBinding(workflow, step, \.a))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(maxWidth: 230)
                if !titles.1.isEmpty {
                    Group {
                        if stepValue.kind == .github || stepValue.kind == .linear {
                            SecureField(titles.1, text: stepBinding(workflow, step, \.b))
                        } else {
                            TextField(titles.1, text: stepBinding(workflow, step, \.b))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: 170)
                }
            }

            Spacer(minLength: 4)
            Button {
                workflows[workflow].steps.remove(at: step)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func icon(for kind: WorkflowStep.Kind) -> String {
        switch kind {
        case .save:   return "folder"
        case .copy:   return "doc.on.doc"
        case .ocr:    return "text.viewfinder"
        case .pin:    return "pin"
        case .upload: return "arrow.up.circle"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .linear: return "square.stack.3d.up"
        }
    }

    private func defaultArgument(for kind: WorkflowStep.Kind) -> String {
        switch kind {
        case .save: return RecordingOptions.saveDirectory.path
        default:    return ""
        }
    }

    // MARK: 绑定

    private func binding<T>(_ index: Int, _ keyPath: WritableKeyPath<CaptureWorkflow, T>) -> Binding<T> {
        Binding(get: { workflows[index][keyPath: keyPath] },
                set: { workflows[index][keyPath: keyPath] = $0 })
    }

    private func stepBinding<T>(_ workflow: Int, _ step: Int,
                                _ keyPath: WritableKeyPath<WorkflowStep, T>) -> Binding<T> {
        Binding(get: { workflows[workflow].steps[step][keyPath: keyPath] },
                set: { workflows[workflow].steps[step][keyPath: keyPath] = $0 })
    }
}
