import Foundation

// MARK: - 模型发现缓存
//
// 每次打开设置页都拉 /models 会造成明显卡顿，且各家都有配额限制；
// 这里做「内存 + 偏好双层缓存 + TTL」，对应原作的 `AIProviderModelDiscoveryCache`。

public final class AIProviderModelDiscoveryCache {
    public static let shared = AIProviderModelDiscoveryCache()

    /// 缓存有效期
    public let ttl: TimeInterval = 30 * 60

    private struct Entry {
        let models: [String]
        let updatedAt: Date
    }
    private let lock = NSLock()
    private var memory: [String: Entry] = [:]

    private func key(for provider: LLMProviderKind) -> String { "ai.models.\(provider.rawValue)" }
    private func timeKey(for provider: LLMProviderKind) -> String { "ai.models.\(provider.rawValue).updatedAt" }

    /// 读取缓存（过期返回 nil）
    public func models(for provider: LLMProviderKind) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        let k = key(for: provider)
        if let entry = memory[k], Date().timeIntervalSince(entry.updatedAt) < ttl { return entry.models }
        let prefs = Preferences.shared
        let stored = prefs.value(k, default: "") as String
        guard !stored.isEmpty else { return nil }
        let updatedAt = prefs.value(timeKey(for: provider), default: 0.0)
        guard Date().timeIntervalSince1970 - updatedAt < ttl else { return nil }
        guard let data = stored.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        memory[k] = Entry(models: list, updatedAt: Date(timeIntervalSince1970: updatedAt))
        return list
    }

    public func store(_ models: [String], for provider: LLMProviderKind) {
        lock.lock()
        let k = key(for: provider)
        memory[k] = Entry(models: models, updatedAt: Date())
        lock.unlock()
        guard let data = try? JSONEncoder().encode(models),
              let text = String(data: data, encoding: .utf8) else { return }
        let prefs = Preferences.shared
        prefs.set(k, text)
        prefs.set(timeKey(for: provider), Date().timeIntervalSince1970)
    }

    public func invalidate(_ provider: LLMProviderKind) {
        lock.lock()
        memory.removeValue(forKey: key(for: provider))
        lock.unlock()
        let prefs = Preferences.shared
        prefs.set(key(for: provider), nil)
        prefs.set(timeKey(for: provider), nil)
    }

    public func invalidateAll() {
        for kind in LLMProviderKind.allCases { invalidate(kind) }
    }
}

// MARK: - 厂商解析器
//
// 对应原作的 `LLMResolver`：根据偏好决定「用哪家 + 用哪个模型」，并统一做模型发现缓存。

public final class LLMResolver {
    public static let shared = LLMResolver()

    public let credentialStore: LLMCredentialStoring
    private let cache: AIProviderModelDiscoveryCache

    public init(credentialStore: LLMCredentialStoring = CredentialStore.shared,
                cache: AIProviderModelDiscoveryCache = .shared) {
        self.credentialStore = credentialStore
        self.cache = cache
    }

    /// 构造指定厂商的适配器实例（每次新建，保证切换地址/凭证后立即生效）
    public func provider(for kind: LLMProviderKind) -> any LLMProviderAdapting {
        switch kind {
        case .anthropic:        return AnthropicService(credentialStore: credentialStore)
        case .gemini:           return GeminiService(credentialStore: credentialStore)
        case .openAICompatible: return OpenAICompatibleService(credentialStore: credentialStore)
        case .ollama:           return OllamaService(credentialStore: credentialStore)
        }
    }

    /// 当前生效的适配器（依据 Preferences.Keys.aiProvider）
    public var currentProvider: any LLMProviderAdapting { provider(for: AISettings.providerKind) }

    /// 当前生效的模型名：用户选择 > 厂商默认
    public func effectiveModel(for kind: LLMProviderKind? = nil) -> String {
        let selected = AISettings.selectedModel
        if !selected.isEmpty { return selected }
        return provider(for: kind ?? AISettings.providerKind).defaultModel
    }

    /// 拉取模型列表（forceRefresh=true 时无视缓存）
    public func availableModels(for kind: LLMProviderKind? = nil,
                                forceRefresh: Bool = false) async throws -> [String] {
        let provider = provider(for: kind ?? AISettings.providerKind)
        let target = provider.kind
        if !forceRefresh, let cached = cache.models(for: target) { return cached }
        do {
            let list = try await provider.availableModels
            cache.store(list, for: target)
            return list
        } catch {
            // 网络不可用时退回到上次缓存，避免 UI 直接空掉
            if let stale = cache.models(for: target) { return stale }
            throw error
        }
    }

    /// 缓存中的模型（可能为 nil）
    public func cachedModels(for kind: LLMProviderKind) -> [String]? {
        cache.models(for: kind)
    }
}
