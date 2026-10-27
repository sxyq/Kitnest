import SwiftUI
import AppKit

// MARK: - 极简 Markdown 渲染
//
// 只需要「加粗 / 行内代码 / 代码块 / 列表 / 标题」五类即可满足 AI 回帖阅读，
// 用系统 AttributedString 的 Markdown 解析器，避免自研布局。

public struct MarkdownText: View {
    private let content: String

    public init(_ content: String) { self.content = content }

    public var body: some View {
        Group {
            if let attributed = try? AttributedString(
                markdown: content,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(attributed)
            } else {
                Text(content)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 消息气泡

private struct ChatBubble: View {
    let role: LLMMessage.Role
    let content: String
    var isStreaming: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if role == .user { Spacer(minLength: 24) }

            VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
                Text(role == .user ? "我" : role == .assistant ? "助手" : "系统")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                MarkdownText(content)
                    .font(.system(size: 13))
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(role == .user ? Theme.accent.opacity(0.16) : Color(NSColor.controlBackgroundColor))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // 打字光标效果
                        if isStreaming {
                            Text("▌").font(.system(size: 13)).foregroundStyle(.secondary)
                                .offset(x: -6, y: -6)
                        }
                    }
            }

            if role != .user { Spacer(minLength: 24) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - 视图模型

public final class AIChatViewModel: ObservableObject {
    @Published public var messages: [LLMMessage] = []
    @Published public var draft: String = ""
    @Published public var streamingText: String = ""
    @Published public var isStreaming: Bool = false
    @Published public var errorMessage: String?
    @Published public var availableModels: [String] = []
    @Published public var isLoadingModels: Bool = false
    @Published public var provider: LLMProviderKind = AISettings.providerKind
    @Published public var selectedModel: String = AISettings.selectedModel

    private var session: LLMChatSession?
    private var streamTask: Task<Void, Never>?

    public init() {
        // 首次进入时先把缓存模型铺上去，避免下拉空白
        availableModels = LLMResolver.shared.cachedModels(for: AISettings.providerKind) ?? []
    }

    // MARK: 意图

    public var effectiveModel: String {
        selectedModel.isEmpty ? LLMService.shared.currentModel : selectedModel
    }

    public func onAppear() {
        provider = AISettings.providerKind
        selectedModel = AISettings.selectedModel
        guard session == nil else { return }
        // 打开时接管最近一次会话，方便接着聊
        if let latest = LLMSessionStore.shared.listSessions(limit: 1).first,
           let loaded = LLMSessionStore.shared.loadSession(id: latest.id) {
            session = loaded
            messages = loaded.messages
        }
        // 未配置凭证时不自动拉模型列表：否则每次打开都会弹出「尚未配置 API Key」的错误横幅。
        // 用户仍可在顶部模型菜单里手动点「刷新模型列表」。
        if LLMService.shared.isConfigured {
            Task { await refreshModels() }
        }
    }

    public func refreshModels() async {
        await MainActor.run { isLoadingModels = true }
        do {
            let list = try await LLMResolver.shared.availableModels(forceRefresh: true)
            await MainActor.run {
                self.availableModels = list
                self.isLoadingModels = false
            }
        } catch {
            await MainActor.run {
                self.isLoadingModels = false
                self.errorMessage = "拉取模型列表失败：\(error.localizedDescription)"
            }
        }
    }

    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        errorMessage = nil
        streamingText = ""
        isStreaming = true

        let activeSession = ensureSession()
        let userMessage = LLMSessionStore.shared.appendMessage(sessionID: activeSession.id, role: .user, content: text)
        LLMSessionStore.shared.autoTitle(sessionID: activeSession.id, from: text)
        messages.append(userMessage)

        let history = messages
        let model = effectiveModel
        streamTask = Task { [self] in
            await performStream(history: history, model: model, sessionID: activeSession.id)
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    public func startNewChat() {
        stop()
        let created = LLMSessionStore.shared.createSession(provider: provider, model: selectedModel)
        session = created
        messages = []
        streamingText = ""
        isStreaming = false
        errorMessage = nil
    }


    // MARK: 私有

    private func ensureSession() -> LLMChatSession {
        if let session { return session }
        let created = LLMSessionStore.shared.createSession(provider: provider, model: selectedModel)
        session = created
        return created
    }

    private func performStream(history: [LLMMessage], model: String, sessionID: String) async {
        var reply = ""
        do {
            for try await piece in LLMService.shared.send(messages: history, model: model, stream: true) {
                reply += piece
                let snapshot = reply
                await MainActor.run { self.streamingText = snapshot }
            }
            let finished = reply
            await MainActor.run { self.commit(reply: finished, sessionID: sessionID) }
        } catch {
            let partial = reply
            await MainActor.run {
                // 用户主动停止：不弹错误；其余错误如实提示（保留已产出的内容）
                self.errorMessage = error.isLLMCancellation ? nil : error.localizedDescription
                self.finishPartial(reply: partial, sessionID: sessionID)
            }
        }
    }

    private func commit(reply: String, sessionID: String) {
        guard !reply.isEmpty else {
            isStreaming = false
            streamingText = ""
            return
        }
        let message = LLMSessionStore.shared.appendMessage(sessionID: sessionID, role: .assistant, content: reply)
        messages.append(message)
        streamingText = ""
        isStreaming = false
    }

    private func finishPartial(reply: String, sessionID: String) {
        if !reply.isEmpty {
            let message = LLMSessionStore.shared.appendMessage(sessionID: sessionID, role: .assistant, content: reply)
            messages.append(message)
        }
        streamingText = ""
        isStreaming = false
    }
}

// MARK: - 主视图

public struct AIChatView: View {
    @StateObject private var model = AIChatViewModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let error = model.errorMessage {
                errorBanner(error)
            }
            Divider()
            composer
        }
        .onAppear { model.onAppear() }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.provider.iconName)
                .foregroundStyle(.tint)
            Text(model.provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Menu {
                if model.availableModels.isEmpty {
                    Text("尚无模型，请到设置页点击刷新")
                } else {
                    ForEach(model.availableModels, id: \.self) { item in
                        Button(item) { model.selectedModel = item; AISettings.selectedModel = item }
                    }
                }
                Divider()
                Button("刷新模型列表") { Task { await model.refreshModels() } }
            } label: {
                HStack(spacing: 4) {
                    Text(model.selectedModel.isEmpty ? model.effectiveModel : model.selectedModel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 180)

            if model.isLoadingModels { ProgressView().controlSize(.small) }

            Spacer()

            Button(action: { model.startNewChat() }) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("新建会话")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 消息区

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.messages.isEmpty && !model.isStreaming {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.tertiaryText)
                            Text("在下方输入内容开始对话")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("未配置 API Key 时请先到「设置 → AI」填写")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    }

                    ForEach(model.messages) { message in
                        ChatBubble(role: message.role, content: message.content)
                            .id(message.id)
                    }

                    if model.isStreaming {
                        ChatBubble(role: .assistant,
                                   content: model.streamingText.isEmpty ? "正在思考…" : model.streamingText,
                                   isStreaming: !model.streamingText.isEmpty)
                            .id("streaming")
                    }
                }
            }
            .onChange(of: model.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(lastAnchor(), anchor: .bottom) }
            }
            .onChange(of: model.streamingText) { _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
        .frame(minHeight: 160)
    }

    private func lastAnchor() -> String {
        model.messages.last?.id ?? "streaming"
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("知道了") { model.errorMessage = nil }
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.10))
    }

    // MARK: 输入区

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $model.draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 34, maxHeight: 96)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }

            if model.isStreaming {
                Button(action: { model.stop() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("停止生成")
            } else {
                Button(action: { model.send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.borderless)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("发送（⌘↩）")
            }
        }
        .padding(10)
    }
}

// MARK: - 面板区段容器

/// 面板区段容器：在「聊天」与「文本工具」之间切换
/// 注：不使用 @State —— SwiftUI 的 State 在新工具链里是外部宏，
/// swiftc -typecheck 单独跑时不加载宏插件会报错，统一放到 ObservableObject 里规避。
public struct AISectionView: View {
    @StateObject private var state = AISectionState()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.tab) {
                ForEach(AISectionTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Group {
                switch state.tab {
                case .chat:  AIChatView()
                case .tools: AISummaryView()
                }
            }
            .frame(minHeight: 320)
        }
    }
}

public final class AISectionState: ObservableObject {
    @Published public var tab: AISectionTab = .chat
    public init() {}
}

public enum AISectionTab: String, CaseIterable, Identifiable, Hashable {
    case chat, tools
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .chat:  return "对话"
        case .tools: return "摘要 / 润色 / 翻译"
        }
    }
}
