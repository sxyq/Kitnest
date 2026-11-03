import SwiftUI
import AppKit

// MARK: - 文本动作
//
// 对应原作的 `TranslationToolSession` / `ClipboardSummaryExecutionCoordinator`：
// 对一段已有文本执行摘要 / 润色 / 翻译，以及用户在设置页自定义的提示词工具。

public enum AISummaryAction: String, CaseIterable, Identifiable {
    case summarize
    case polish
    case translate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .summarize: return "摘要"
        case .polish:    return "润色"
        case .translate: return "翻译"
        }
    }

    public var systemImage: String {
        switch self {
        case .summarize: return "doc.text"
        case .polish:    return "sparkles"
        case .translate: return "character.book.closed"
        }
    }

    /// 该动作对应的 system 提示词
    public var systemPrompt: String {
        switch self {
        case .summarize:
            return "你是文本摘要助手。请用中文输出条理清晰的要点摘要，控制在原文的 1/4 长度内，使用短句与列表。"
        case .polish:
            return "你是中文写作润色助手。请在保持原意的前提下改善表达、修正语病与错别字，输出润色后的全文，不要加入解释。"
        case .translate:
            return "你是专业翻译助手。请在中文与英文之间自动判断源语言并互译，保持专业术语与格式，只输出译文。"
        }
    }

    /// 构造给模型的 user 提示
    public func prompt(for input: String) -> String {
        switch self {
        case .summarize: return "请对以下内容做摘要：\n\n" + input
        case .polish:    return "请润色以下内容：\n\n" + input
        case .translate: return "请翻译以下内容：\n\n" + input
        }
    }

    /// 设置项的默认动作持久化键关联
    public static var storedDefault: AISummaryAction {
        let raw = Preferences.shared.value(AISettings.keyDefaultAction, default: "") as String
        return AISummaryAction(rawValue: raw) ?? .summarize
    }

    public func saveAsDefault() {
        Preferences.shared.set(AISettings.keyDefaultAction, rawValue)
    }
}

// MARK: - 视图模型

public final class AISummaryViewModel: ObservableObject {
    @Published public var inputText: String
    @Published public var outputText: String = ""
    @Published public var isRunning: Bool = false
    @Published public var errorMessage: String?
    @Published public var activeAction: AISummaryAction?
    /// 当前运行的自定义工具 id（与 activeAction 二选一，用于按钮高亮）
    @Published public var activeToolID: String?
    @Published public var didCopy: Bool = false
    /// 设置页定义的自定义提示词工具
    @Published public var customTools: [CustomAITool] = []

    private var task: Task<Void, Never>?

    public init(inputText: String = "") {
        self.inputText = inputText
        self.customTools = CustomAIToolStore.shared.all()
    }

    /// 设置页增删工具后回到面板时刷新
    public func reloadTools() {
        customTools = CustomAIToolStore.shared.all()
    }

    // MARK: 内置动作

    public func run(_ action: AISummaryAction) {
        guard let text = validatedInput() else { return }
        activeAction = action
        activeToolID = nil
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: action.systemPrompt),
            LLMMessage(role: .user, content: action.prompt(for: text))
        ]
        start(messages: messages)
    }

    // MARK: 自定义工具

    public func runCustom(_ tool: CustomAITool) {
        guard let text = validatedInput() else { return }
        activeAction = nil
        activeToolID = tool.id
        let messages: [LLMMessage] = [
            LLMMessage(role: .system, content: tool.systemPrompt),
            LLMMessage(role: .user, content: tool.render(input: text))
        ]
        start(messages: messages)
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    public func copyResult() {
        let text = outputText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        // spec 13 §4：文本已复制场景（0x100412774，翻译/摘要结果复制）
        Toast.show("文本已复制", icon: "checkmark.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.didCopy = false }
    }

    /// 结果回写剪贴板条目：通过 AIEventBus 交给总控接线，AI 模块不直接触碰剪贴板模块
    public func saveToClipboard() {
        let text = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AIEventBus.emitResult(text)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.didCopy = false }
    }

    // MARK: 私有

    /// 校验输入；不合法时置错误并返回 nil
    private func validatedInput() -> String? {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "请先输入或粘贴要处理的文本。"
            return nil
        }
        guard !isRunning else { return nil }
        return text
    }

    private func start(messages: [LLMMessage]) {
        errorMessage = nil
        didCopy = false
        outputText = ""
        isRunning = true
        let model = LLMService.shared.currentModel
        task = Task { [self] in
            await perform(messages: messages, model: model)
        }
    }

    private func perform(messages: [LLMMessage], model: String) async {
        var accumulated = ""
        do {
            for try await piece in LLMService.shared.send(messages: messages, model: model, stream: true) {
                accumulated += piece
                let snapshot = accumulated
                await MainActor.run { self.outputText = snapshot }
            }
            await MainActor.run { self.isRunning = false }
        } catch {
            let partial = accumulated
            await MainActor.run {
                self.isRunning = false
                // 主动停止不报错；真实失败（如未配置 Key）必须如实提示，否则用户会以为「没反应」
                self.errorMessage = error.isLLMCancellation ? nil : error.localizedDescription
                self.outputText = partial
            }
        }
    }
}

// MARK: - 视图

public struct AISummaryView: View {
    @StateObject private var model: AISummaryViewModel

    public init(inputText: String = "") {
        _model = StateObject(wrappedValue: AISummaryViewModel(inputText: inputText))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            actionsRow
            if !model.customTools.isEmpty { customToolsRow }

            TextEditor(text: $model.inputText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 140)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if model.inputText.isEmpty {
                        Text("在此粘贴要处理的文本…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.isRunning && model.outputText.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在\(activeLabel)…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else if model.outputText.isEmpty {
                        Text("结果将显示在这里")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiaryText)
                    } else {
                        MarkdownText(model.outputText)
                            .font(.system(size: 13))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 90)

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            resultBar
        }
        .padding(12)
        .onAppear { model.reloadTools() }
    }

    private var activeLabel: String {
        if let tool = model.customTools.first(where: { $0.id == model.activeToolID }) { return tool.name }
        return model.activeAction?.title ?? "处理"
    }

    private var actionsRow: some View {
        HStack(spacing: 8) {
            ForEach(AISummaryAction.allCases) { action in
                Button {
                    model.run(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            Capsule().fill(model.activeAction == action && model.isRunning
                                           ? Theme.accent.opacity(0.18)
                                           : Color(NSColor.controlBackgroundColor))
                        }
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
            }
            Spacer()
            if model.isRunning {
                Button("停止") { model.stop() }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private var customToolsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("自定义")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.customTools) { tool in
                    Button {
                        model.runCustom(tool)
                    } label: {
                        Text(tool.name)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background {
                                Capsule().fill(model.activeToolID == tool.id && model.isRunning
                                               ? Theme.accent.opacity(0.18)
                                               : Color(NSColor.controlBackgroundColor))
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRunning)
                    .help(tool.systemPrompt)
                }
            }
        }
    }

    private var resultBar: some View {
        HStack {
            Button("复制") { model.copyResult() }
                .disabled(model.outputText.isEmpty)
            Button("存为剪贴板条目") { model.saveToClipboard() }
                .disabled(model.outputText.isEmpty)
                .help("结果通过 AIEventBus 交由剪贴板模块落库（is_generated_by_tool=1）")
            Spacer()
            if model.didCopy {
                Text("已处理")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("\(model.outputText.count) 字")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        .font(.system(size: 12))
    }
}
