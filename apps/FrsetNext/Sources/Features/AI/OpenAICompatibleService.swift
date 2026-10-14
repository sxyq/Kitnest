import Foundation

// MARK: - OpenAI 兼容适配器
//
// 端点：POST {base}/v1/chat/completions
// 鉴权：Authorization: Bearer {key}
// 覆盖：OpenAI、DeepSeek、豆包火山方舟、月之暗面 Kimi、智谱、Groq、Together 等所有 OpenAI 协议网关
// 流式：SSE，choices[0].delta.content 携带增量，结束时下发 `data: [DONE]`

public final class OpenAICompatibleService: LLMProviderAdapting {
    public static let shared = OpenAICompatibleService()

    public let kind: LLMProviderKind = .openAICompatible
    public let credentialStore: LLMCredentialStoring
    public let defaultModel: String = "gpt-4o-mini"

    public var baseURL: URL {
        get { AISettings.baseURL(for: .openAICompatible) }
        set { AISettings.setBaseURL(newValue.absoluteString, for: .openAICompatible) }
    }

    public init(credentialStore: LLMCredentialStoring = CredentialStore.shared) {
        self.credentialStore = credentialStore
    }

    // MARK: - 请求构造

    public func makeRequest(_ request: LLMCompletionRequest, credential: String) throws -> URLRequest {
        let endpoint = normalizedBase() + "/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("OpenAI 兼容服务地址不合法：\(endpoint)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        if request.stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.timeoutInterval = LLMTransport.requestTimeout

        let body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": request.stream,
            "temperature": request.temperature,
            "max_tokens": request.maxTokens
        ]
        // 部分国产网关不接受 max_tokens 超过上下文（如 qwen）；保持传入，失败时由中文错误提示引导调小
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    public func makeModelsRequest(credential: String) throws -> URLRequest {
        let endpoint = normalizedBase() + "/models"
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("OpenAI 兼容服务地址不合法：\(endpoint)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = LLMTransport.requestTimeout
        return req
    }

    // MARK: - 响应解析

    public func parseStreamLine(_ line: String) throws -> String? {
        guard let payload = LLMJSON.ssePayload(line) else { return nil }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let choices = dict["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    public func parseComplete(_ data: Data) throws -> String {
        let dict = try LLMJSON.object(data)
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let choices = dict["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.decoding("OpenAI 兼容响应缺少 choices[0].message")
        }
        // 兼容 reasoning_content（部分推理模型把正文拆到两个字段）
        let content = message["content"] as? String ?? ""
        return content
    }

    public func parseModelIDs(_ data: Data) throws -> [String] {
        let dict = try LLMJSON.object(data)
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let list = dict["data"] as? [[String: Any]] else { return [] }
        // 过滤非对话模型，避免下拉里出现 embedding / tts / dall-e
        return list.compactMap { entry -> String? in
            guard let id = entry["id"] as? String else { return nil }
            let lower = id.lowercased()
            let blocked = ["embedding", "tts", "whisper", "dall-e", "moderation", "rerank", "babbage", "davinci"]
            guard !blocked.contains(where: { lower.contains($0) }) else { return nil }
            return id
        }.sorted()
    }

    public func readableError(from data: Data) -> String? {
        guard let dict = try? LLMJSON.object(data) else { return nil }
        return LLMJSON.errorMessage(dict)
    }

    /// OpenAI 协议在流末尾下发 `data: [DONE]`。部分网关（或经代理时）不会随即关闭连接，
    /// 若不识别该行，客户端会一直等到超时，因此把它当作终止行。
    public func isTerminalLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "data: [DONE]" || trimmed == "data:[DONE]" || trimmed == "[DONE]"
    }

    // MARK: - 私有

    /// 地址规范化：用户常填 https://api.deepseek.com / ...com/v1 / ...com/v1/chat/completions
    /// 目标是收敛到 `.../v1` 前缀
    private func normalizedBase() -> String {
        var s = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let schemeRange = s.range(of: "://") {
            // scheme 内的 // 要保留，只裁剪路径部分的多余斜杠
            var pathPart = String(s[schemeRange.upperBound...])
            while pathPart.hasSuffix("/chat/completions") {
                pathPart = String(pathPart.dropLast("/chat/completions".count))
            }
            while pathPart.hasSuffix("/models") { pathPart = String(pathPart.dropLast("/models".count)) }
            s = String(s[..<schemeRange.upperBound]) + pathPart
        }
        // 已有版本前缀则不重复拼接
        let knownPrefixes = ["/v1", "/v2", "/v3", "/v4", "/api/v1", "/openai/v1"]
        guard !knownPrefixes.contains(where: { s.hasSuffix($0) }) else { return s }
        return s + "/v1"
    }
}
