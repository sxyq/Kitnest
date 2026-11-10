import Foundation

// MARK: - Anthropic Claude 适配器
//
// 端点：POST {base}/v1/messages
// 鉴权：x-api-key + anthropic-version 头（与其它三家的 Authorization 体系不同）
// 流式：SSE，事件 `content_block_delta` 携带 `delta.text` 增量

public final class AnthropicService: LLMProviderAdapting {
    public static let shared = AnthropicService()

    public let kind: LLMProviderKind = .anthropic
    public let credentialStore: LLMCredentialStoring
    private let baseURLOverride: URL?
    public let defaultModel: String = "claude-3-5-sonnet-latest"

    /// 版本号固定（官方推荐的最低可用版本，缺失会返回 400）
    private static let apiVersion = "2023-06-01"

    public var baseURL: URL {
        get { baseURLOverride ?? AISettings.baseURL(for: .anthropic) }
        set { AISettings.setBaseURL(newValue.absoluteString, for: .anthropic) }
    }

    public init(credentialStore: LLMCredentialStoring = CredentialStore.shared, baseURL: URL? = nil) {
        self.credentialStore = credentialStore
        self.baseURLOverride = baseURL
    }

    // MARK: - 请求构造

    public func makeRequest(_ request: LLMCompletionRequest, credential: String) throws -> URLRequest {
        let endpoint = normalizedBase() + "/v1/messages"
        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidConfiguration("Anthropic 服务地址不合法：\(endpoint)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(credential, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.timeoutInterval = LLMTransport.requestTimeout

        var body: [String: Any] = [
            "model": request.model,
            "messages": request.conversation.map { ["role": $0.role.rawValue, "content": $0.content] },
            "max_tokens": request.maxTokens,
            "stream": request.stream
        ]
        if let system = request.systemPrompt, !system.isEmpty { body["system"] = system }
        if request.temperature > 0 { body["temperature"] = request.temperature }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    public func makeModelsRequest(credential: String) throws -> URLRequest {
        guard let url = URL(string: normalizedBase() + "/v1/models?limit=1000") else {
            throw LLMError.invalidConfiguration("Anthropic 服务地址不合法：\(baseURL.absoluteString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(credential, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = LLMTransport.requestTimeout
        return req
    }

    // MARK: - 响应解析

    public func parseStreamLine(_ line: String) throws -> String? {
        guard let payload = LLMJSON.ssePayload(line) else { return nil }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            // 非 JSON 的 data 行（极少见）直接忽略，避免打断整条流
            return nil
        }
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let type = dict["type"] as? String else { return nil }
        guard type == "content_block_delta" else { return nil }   // message_start/stop/ping 均无文本
        guard let delta = dict["delta"] as? [String: Any] else { return nil }
        return delta["text"] as? String
    }

    public func parseComplete(_ data: Data) throws -> String {
        let dict = try LLMJSON.object(data)
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let content = dict["content"] as? [[String: Any]] else {
            throw LLMError.decoding("Anthropic 响应缺少 content 字段")
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        return text
    }

    public func parseModelIDs(_ data: Data) throws -> [String] {
        let dict = try LLMJSON.object(data)
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let list = dict["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }

    public func readableError(from data: Data) -> String? {
        guard let dict = try? LLMJSON.object(data) else { return nil }
        return LLMJSON.errorMessage(dict)
    }

    /// Anthropic 的 `message_stop` 表示本次消息结束；识别它可以避免部分网关不关连接导致的超时。
    /// 注意：不同网关的 JSON 空格风格不一致（`{"type":"x"}` 与 `{"type": "x"}` 都合法），
    /// 因此按 JSON 解析判定，而不是做字符串包含匹配。
    public func isTerminalLine(_ line: String) -> Bool {
        guard let payload = LLMJSON.ssePayload(line),
              let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return false }
        return (dict["type"] as? String) == "message_stop"
    }

    // MARK: - 私有

    /// 规范化地址：用户可能填 "https://api.anthropic.com/" 或带自定义路径
    private func normalizedBase() -> String {
        var s = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // 兼容常见的 /v1 尾缀写法，避免拼出 /v1/v1/messages
        if s.hasSuffix("/v1") { s = String(s.dropLast(3)) }
        return s
    }
}
