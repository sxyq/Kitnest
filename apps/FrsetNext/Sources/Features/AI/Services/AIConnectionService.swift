import Foundation

// MARK: - 连通性测试
//
// 对应原作的 `AIProviderConnectionService` / `AIProviderConnectionController`：
// 用户在设置页点「测试连接」时，先用临时凭证 + 临时地址试跑（不污染已保存的配置），
// 返回可供 UI 直接展示的中文结论。

public struct AIConnectionTestResult: Sendable {
    public let ok: Bool
    public let message: String
    public let models: [String]
    public let elapsed: TimeInterval

    public init(ok: Bool, message: String, models: [String] = [], elapsed: TimeInterval = 0) {
        self.ok = ok; self.message = message; self.models = models; self.elapsed = elapsed
    }
}

public final class AIProviderConnectionService {
    public static let shared = AIProviderConnectionService()

    public init() {}

    /// 测试一组候选配置
    /// - Parameters:
    ///   - provider: 厂商
    ///   - baseURL: 候选地址（nil 表示沿用已保存地址）
    ///   - model: 候选模型（nil 表示用厂商默认）
    ///   - apiKey: 候选密钥（nil 表示沿用已保存凭证）
    public func test(provider: LLMProviderKind,
                     baseURL: String?,
                     model: String?,
                     apiKey: String?) async -> AIConnectionTestResult {
        let started = Date()

        // 1) 用临时凭证构造实例，避免把测试用的半成品写进 CredentialStore
        var staging: [LLMProviderKind: String] = [:]
        staging[provider] = apiKey ?? CredentialStore.shared.credential(for: provider)
        let ephemeralStore = InMemoryCredentialStore(staging)

        let candidateURL: URL
        if let baseURL {
            let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                candidateURL = provider.defaultBaseURL
            } else {
                guard let url = URL(string: raw), url.scheme != nil else {
                    return AIConnectionTestResult(ok: false, message: "服务地址无效：\(raw)")
                }
                candidateURL = url
            }
        } else {
            candidateURL = AISettings.baseURL(for: provider)
        }

        let adapter: any LLMProviderAdapting
        switch provider {
        case .anthropic:        adapter = AnthropicService(credentialStore: ephemeralStore, baseURL: candidateURL)
        case .gemini:           adapter = GeminiService(credentialStore: ephemeralStore, baseURL: candidateURL)
        case .openAICompatible: adapter = OpenAICompatibleService(credentialStore: ephemeralStore, baseURL: candidateURL)
        case .ollama:           adapter = OllamaService(credentialStore: ephemeralStore, baseURL: candidateURL)
        }

        let chosenModel = (model?.isEmpty == false) ? model! : adapter.defaultModel

        // 3) 优先做目录探测（不消耗 token）
        do {
            let models = try await adapter.availableModels
            let head = models.prefix(3).joined(separator: "、")
            let elapsed = Date().timeIntervalSince(started)
            if models.contains(chosenModel) {
                return AIConnectionTestResult(ok: true,
                                              message: "连接成功，模型 \(chosenModel) 可用（共 \(models.count) 个：\(head)…）",
                                              models: models,
                                              elapsed: elapsed)
            }
            return AIConnectionTestResult(ok: true,
                                          message: "连接成功，但模型清单中未找到 \(chosenModel)。可用模型：\(head)…",
                                          models: models,
                                          elapsed: elapsed)
        } catch {
            // 4) 目录端点常被网关屏蔽 → 退化为一次性极小对话探测
            Log.info("AI", "模型探测失败，改用对话探测：\(error.localizedDescription)")
        }

        do {
            let reply = try await adapter.complete(
                messages: [LLMMessage(role: .user, content: "回复 OK 两个字")],
                model: chosenModel)
            let elapsed = Date().timeIntervalSince(started)
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIConnectionTestResult(ok: true,
                                          message: "连接成功（模型目录不可用，已通过对话验证）。模型回复：\(LLMTransport.truncate(trimmed, limit: 40))",
                                          models: [chosenModel],
                                          elapsed: elapsed)
        } catch {
            return AIConnectionTestResult(ok: false,
                                          message: error.localizedDescription,
                                          models: [],
                                          elapsed: Date().timeIntervalSince(started))
        }
    }

}
