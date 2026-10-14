import Foundation

// MARK: - Google Gemini 适配器
//
// 端点：POST {base}/v1beta/models/{model}:streamGenerateContent?alt=sse&key={key}
//      一次性则使用 :generateContent?key={key}
// 鉴权：API Key 走 query string（这是 Gemini 与其它三家最大的差异）
// 角色映射：assistant → model

public final class GeminiService: LLMProviderAdapting {
    public static let shared = GeminiService()

    public let kind: LLMProviderKind = .gemini
    public let credentialStore: LLMCredentialStoring
    public let defaultModel: String = "gemini-2.0-flash"

    private static let apiVersion = "v1beta"

    public var baseURL: URL {
        get { AISettings.baseURL(for: .gemini) }
        set { AISettings.setBaseURL(newValue.absoluteString, for: .gemini) }
    }

    public init(credentialStore: LLMCredentialStoring = CredentialStore.shared) {
        self.credentialStore = credentialStore
    }

    // MARK: - 请求构造

    public func makeRequest(_ request: LLMCompletionRequest, credential: String) throws -> URLRequest {
        let model = request.model.isEmpty ? defaultModel : request.model
        let verb = request.stream ? "streamGenerateContent" : "generateContent"
        var components = URLComponents(string: normalizedBase() + "/\(Self.apiVersion)/models/\(model):\(verb)")
        components?.queryItems = [URLQueryItem(name: "key", value: credential)]
        if request.stream {
            components?.queryItems?.append(URLQueryItem(name: "alt", value: "sse"))
        }
        guard let url = components?.url else {
            throw LLMError.invalidConfiguration("Gemini 服务地址不合法：\(baseURL.absoluteString)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if request.stream { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        req.timeoutInterval = LLMTransport.requestTimeout

        var body: [String: Any] = [
            "contents": request.conversation.map { msg -> [String: Any] in
                ["role": msg.role == .assistant ? "model" : "user",
                 "parts": [["text": msg.content]]]
            },
            "generationConfig": [
                "temperature": request.temperature,
                "maxOutputTokens": request.maxTokens
            ]
        ]
        if let system = request.systemPrompt, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    public func makeModelsRequest(credential: String) throws -> URLRequest {
        var components = URLComponents(string: normalizedBase() + "/\(Self.apiVersion)/models")
        components?.queryItems = [URLQueryItem(name: "key", value: credential)]
        guard let url = components?.url else {
            throw LLMError.invalidConfiguration("Gemini 服务地址不合法：\(baseURL.absoluteString)")
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
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let candidates = dict["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    public func parseComplete(_ data: Data) throws -> String {
        let dict = try LLMJSON.object(data)
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let candidates = dict["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMError.decoding("Gemini 响应缺少 candidates.content.parts")
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    public func parseModelIDs(_ data: Data) throws -> [String] {
        let dict = try LLMJSON.object(data)
        if let err = LLMJSON.errorMessage(dict) { throw LLMError.provider(err) }
        guard let list = dict["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry -> String? in
            guard let name = entry["name"] as? String else { return nil }
            // 只保留支持内容生成的模型（图像/嵌入模型不可用于对话）
            if let methods = entry["supportedGenerationMethods"] as? [String],
               !methods.contains(where: { $0 == "generateContent" }) { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
    }

    public func readableError(from data: Data) -> String? {
        guard let dict = try? LLMJSON.object(data) else { return nil }
        return LLMJSON.errorMessage(dict)
    }

    // MARK: - 私有

    private func normalizedBase() -> String {
        var s = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/v1beta", "/v1"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s
    }
}
