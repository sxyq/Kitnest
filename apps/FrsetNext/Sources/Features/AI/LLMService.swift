import Foundation

// MARK: - LLM 门面
//
// 对应原作 `LLMService`：对外只有一个门面，内部按偏好路由到具体适配器。
// 同时实现 Core 的 `LLMServiceProtocol`，供其它模块（截图 OCR 后处理、工具箱翻译等）
// 通过 `ServiceLocator.llmService` 调用，无需知道厂商细节。

public final class LLMService: LLMServiceProtocol {
    public static let shared = LLMService()

    public let resolver: LLMResolver
    private let lock = NSLock()
    private var _provider: any LLMProviderAdapting

    public init(resolver: LLMResolver = .shared) {
        self.resolver = resolver
        self._provider = resolver.currentProvider
    }

    /// 偏好变更后重建适配器和模型缓存
    public func reload() {
        lock.lock()
        _provider = resolver.currentProvider
        lock.unlock()
        Log.info("AI", "LLMService 已加载厂商：\(AISettings.providerKind.displayName) 模型：\(currentModel)")
    }

    public var provider: any LLMProviderAdapting {
        lock.lock(); defer { lock.unlock() }
        return _provider
    }

    public var providerKind: LLMProviderKind { provider.kind }

    public var currentModel: String { resolver.effectiveModel() }

    /// 该厂商是否已配置凭证（本地 Ollama 恒为 true）
    public var isConfigured: Bool {
        provider.kind.needsCredential ? resolver.credentialStore.hasCredential(for: provider.kind) : true
    }

    // MARK: - 消息级能力（UI 与工具直接使用）

    public func send(messages: [LLMMessage],
                     model: String? = nil,
                     stream: Bool = true) -> AsyncThrowingStream<String, Error> {
        let target = provider
        let chosen = model ?? currentModel
        let wrapped = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                DatabaseManager.shared.bumpStat("ai_request_count")
                do {
                    for try await piece in target.send(messages: withSystemIfNeeded(messages),
                                                       model: chosen,
                                                       stream: stream) {
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return wrapped
    }

    public func complete(messages: [LLMMessage], model: String? = nil) async throws -> String {
        var text = ""
        for try await piece in send(messages: messages, model: model, stream: false) {
            text += piece
        }
        return text
    }

    // MARK: - LLMServiceProtocol（跨模块契约）

    public func complete(prompt: String, system: String?, model: String?) async throws -> String {
        let messages = Self.buildMessages(prompt: prompt, system: system)
        return try await complete(messages: messages, model: model)
    }

    public func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        let messages = Self.buildMessages(prompt: prompt, system: system)
        return send(messages: messages, model: model, stream: true)
    }

    /// 把「单段提问 + 可选 system」包装成消息数组
    public static func buildMessages(prompt: String, system: String?) -> [LLMMessage] {
        var list: [LLMMessage] = []
        let sys = (system?.isEmpty == false) ? system! : AISettings.systemPrompt
        if !sys.isEmpty { list.append(LLMMessage(role: .system, content: sys)) }
        list.append(LLMMessage(role: .user, content: prompt))
        return list
    }

    /// 当用户没有显式传 system 时，补上默认助手提示词（且不重复追加）
    private func withSystemIfNeeded(_ messages: [LLMMessage]) -> [LLMMessage] {
        guard !messages.contains(where: { $0.role == .system }) else { return messages }
        let sys = AISettings.systemPrompt
        guard !sys.isEmpty else { return messages }
        return [LLMMessage(role: .system, content: sys)] + messages
    }
}
