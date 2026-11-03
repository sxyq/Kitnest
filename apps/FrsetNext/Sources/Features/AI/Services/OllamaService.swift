import Foundation

// MARK: - Ollama 本地适配器
//
// 端点：POST http://localhost:11434/api/chat（无鉴权）
// 流式：NDJSON——每行一个完整 JSON，与前三家的 SSE 格式不同
// 模型列表：GET /api/tags

public final class OllamaService: LLMProviderAdapting {
    public static let shared = OllamaService()

    public let kind: LLMProviderKind = .ollama
    public let credentialStore: LLMCredentialStoring
    public let defaultModel: String = "llama3.2"

    public var baseURL: URL {
        get { AISettings.baseURL(for: .ollama) }
        set { AISettings.setBaseURL(newValue.absoluteString, for: .ollama) }
    }

    public init(credentialStore: LLMCredentialStoring = CredentialStore.shared) {
        self.credentialStore = credentialStore
    }

    /// 本地服务无需凭证
    public func requireCredential() throws -> String { "" }

    // MARK: - 请求构造

    public func makeRequest(_ request: LLMCompletionRequest, credential: String) throws -> URLRequest {
        let endpoint = normalizedBase() + "/api/chat"
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("Ollama 服务地址不合法：\(endpoint)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = LLMTransport.requestTimeout

        var body: [String: Any] = [
            "model": request.model.isEmpty ? defaultModel : request.model,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": request.stream,
            "options": [
                "temperature": request.temperature,
                "num_predict": request.maxTokens
            ]
        ]
        // system 作为首条 message 传入（Ollama 的 chat API 没有独立 system 字段时的通用做法）
        if let system = request.systemPrompt, !system.isEmpty, request.messages.first?.role != .system {
            var list = request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            list.insert(["role": "system", "content": system], at: 0)
            body["messages"] = list
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    public func makeModelsRequest(credential: String) throws -> URLRequest {
        let endpoint = normalizedBase() + "/api/tags"
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("Ollama 服务地址不合法：\(endpoint)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = LLMTransport.requestTimeout
        return req
    }

    // MARK: - 响应解析

    public func parseStreamLine(_ line: String) throws -> String? {
        guard let payload = LLMJSON.streamPayload(line) else { return nil }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        if let err = dict["error"] as? String { throw LLMError.provider(err) }
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let message = dict["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    public func parseComplete(_ data: Data) throws -> String {
        let dict = try LLMJSON.object(data)
        if let err = dict["error"] as? String { throw LLMError.provider(err) }
        if let message = dict["message"] as? [String: Any] {
            return message["content"] as? String ?? ""
        }
        // 部分版本直接返回 response 字段
        return dict["response"] as? String ?? ""
    }

    public func parseModelIDs(_ data: Data) throws -> [String] {
        let dict = try LLMJSON.object(data)
        guard let list = dict["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String ?? $0["model"] as? String }.sorted()
    }

    public func readableError(from data: Data) -> String? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = dict["error"] as? String { return err }
        return LLMJSON.errorMessage(dict)
    }

    /// Ollama 的 NDJSON 流以 `{"done":true}` 收尾；识别它可在连接不被主动关闭时立即结束。
    /// 仅当该行不再携带增量文本时才判定为终止行，避免个别版本把收尾文本放在 done 行里被丢弃。
    public func isTerminalLine(_ line: String) -> Bool {
        guard let payload = LLMJSON.streamPayload(line),
              let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              (dict["done"] as? Bool) == true else { return false }
        let content = (dict["message"] as? [String: Any])?["content"] as? String
        return (content ?? "").isEmpty
    }

    // MARK: - 私有

    private func normalizedBase() -> String {
        var s = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/api", "/v1"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s
    }
}
