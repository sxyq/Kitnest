import Foundation

// MARK: - AI 体系协议层
//
// 原作（Frset 1.3.12）在二进制元数据中保留了 11 个自有协议，
// 其中 `LLMProviderAdapting` / `AICredentialStoring` / `LLMCredentialReading` 等构成
// 「协议 + 依赖注入」的多厂商架构证据。本文件按同样的分层正向重建：
//
//   LLMRequestBuilding   —— 请求体/URL/鉴权头构造（各家不同）
//   LLMResponseParsing   —— 响应解析（SSE 增量 / 一次性 JSON / 模型列表）
//   LLMCredentialStoring —— 凭证存取（实现见 CredentialStore）
//   LLMProviderAdapting  —— 门面协议，聚合以上三者 + 流式/一次性调用
//
// 三家适配器只需实现「构造」与「解析」两个切面，
// send/complete/availableModels 由协议扩展给出默认实现（等于原作的模板方法）。

// MARK: - 错误

public enum LLMError: Error, LocalizedError {
    case missingCredential(LLMProviderKind)
    case invalidConfiguration(String)
    case httpStatus(Int, String)
    case decoding(String)
    case network(String)
    case provider(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let kind):
            return "尚未配置 \(kind.displayName) 的 API Key，请先到「设置 → AI」中填写。"
        case .invalidConfiguration(let detail):
            return "AI 配置无效：\(detail)"
        case .httpStatus(let code, let detail):
            let msg = detail.isEmpty ? "服务端未给出原因" : detail
            return "请求失败（HTTP \(code)）：\(msg)"
        case .decoding(let detail):
            return "响应解析失败：\(detail)"
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .provider(let detail):
            return "AI 服务返回错误：\(detail)"
        case .cancelled:
            return "已取消生成。"
        }
    }
}

// MARK: - 请求参数

/// 一次补全请求的中立描述（与具体厂商无关）
public struct LLMCompletionRequest: Sendable {
    public var messages: [LLMMessage]
    public var model: String
    public var stream: Bool
    public var temperature: Double
    public var maxTokens: Int

    public init(messages: [LLMMessage],
                model: String,
                stream: Bool = true,
                temperature: Double = 0.7,
                maxTokens: Int = 4096) {
        self.messages = messages
        self.model = model
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// 取出 system 角色的全部内容（Anthropic/Gemini 需要单独传 system 字段）
    public var systemPrompt: String? {
        let texts = messages.filter { $0.role == .system }.map { $0.content }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n\n")
    }

    /// 对话轮次（剔除 system）
    public var conversation: [LLMMessage] {
        messages.filter { $0.role != .system }
    }
}

// MARK: - 凭证存取

public protocol LLMCredentialStoring: AnyObject {
    /// 读取某厂商的凭证；未配置返回 nil
    func credential(for provider: LLMProviderKind) -> String?
    /// 写入（传 nil 等价于删除）
    func setCredential(_ value: String?, for provider: LLMProviderKind)
    /// 删除
    func removeCredential(for provider: LLMProviderKind)
    /// 清空全部
    func clear()
    /// 是否存在有效凭证（协议扩展给出默认实现）
    func hasCredential(for provider: LLMProviderKind) -> Bool
}

public extension LLMCredentialStoring {
    func hasCredential(for provider: LLMProviderKind) -> Bool {
        guard let v = credential(for: provider) else { return false }
        return !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 请求构造

public protocol LLMRequestBuilding: AnyObject {
    var kind: LLMProviderKind { get }
    /// 服务地址（可由偏好覆盖，便于接私有网关）
    var baseURL: URL { get set }
    /// 未显式指定模型时的兜底模型
    var defaultModel: String { get }

    /// 构造补全请求
    func makeRequest(_ request: LLMCompletionRequest, credential: String) throws -> URLRequest
    /// 构造模型发现请求
    func makeModelsRequest(credential: String) throws -> URLRequest
}

// MARK: - 响应解析

public protocol LLMResponseParsing: AnyObject {
    /// 解析流式一行（`data:` 前缀已剥离的载荷，或 NDJSON 整行）；返回本次增量文本，无增量返回 nil
    func parseStreamLine(_ line: String) throws -> String?
    /// 解析一次性响应
    func parseComplete(_ data: Data) throws -> String
    /// 解析列表
    func parseModelIDs(_ data: Data) throws -> [String]
    /// 从错误响应体中提取可读信息
    func readableError(from data: Data) -> String?
    /// 该行是否意味着流已自然结束（如 Anthropic 的 message_stop）。
    /// 场景：部分网关不会主动关闭连接，若不识别结束事件，客户端会一直等到超时。
    func isTerminalLine(_ line: String) -> Bool
}

// MARK: - 厂商适配器门面

public protocol LLMProviderAdapting: AnyObject, LLMRequestBuilding, LLMResponseParsing {
    var credentialStore: LLMCredentialStoring { get }
    /// 拉取可用模型（默认实现：makeModelsRequest → parseModelIDs）
    var availableModels: [String] { get async throws }
    /// 统一调用入口；stream=false 时只产出一个完整串
    func send(messages: [LLMMessage], model: String?, stream: Bool) -> AsyncThrowingStream<String, Error>
    /// 一次性补全
    func complete(messages: [LLMMessage], model: String?) async throws -> String
    /// 取凭证，缺失时抛出中文可读错误（Ollama 等本地服务可覆写为空凭证）
    func requireCredential() throws -> String
}

// MARK: - 默认实现（模板方法）

public extension LLMProviderAdapting {
    var availableModels: [String] {
        get async throws {
            let credential = try requireCredential()
            let request = try makeModelsRequest(credential: credential)
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkResponse(response, data)
            let ids = try parseModelIDs(data)
            // 某些网关不开放 /models，兜底返回默认模型，避免 UI 出现空列表
            return ids.isEmpty ? [defaultModel] : ids
        }
    }

    func requireCredential() throws -> String {
        guard let key = credentialStore.credential(for: kind),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.missingCredential(kind)
        }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func send(messages: [LLMMessage], model: String?, stream: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let job = Task {
                do {
                    let credential = try requireCredential()
                    var request = try makeRequest(
                        LLMCompletionRequest(messages: messages,
                                             model: model ?? defaultModel,
                                             stream: stream,
                                             temperature: AISettings.temperature,
                                             maxTokens: AISettings.maxTokens),
                        credential: credential)

                    if !stream {
                        request.timeoutInterval = LLMTransport.requestTimeout
                        let (data, response) = try await URLSession.shared.data(for: request)
                        try checkResponse(response, data)
                        continuation.yield(try parseComplete(data))
                        continuation.finish()
                        return
                    }

                    let parser: (Data) -> String? = { [self] data in readableError(from: data) }
                    let buffer = LLMLineBuffer()
                    for try await chunk in LLMTransport.streamBytes(request, refineError: parser) {
                        try Task.checkCancellation()
                        for line in buffer.ingest(chunk) {
                            if isTerminalLine(line) {
                                continuation.finish()
                                return
                            }
                            if let delta = try parseStreamLine(line), !delta.isEmpty {
                                continuation.yield(delta)
                            }
                        }
                    }
                    // 收尾：冲刷最后一行（服务端未以换行结束时）
                    for line in buffer.flush() {
                        if isTerminalLine(line) { break }
                        if let delta = try parseStreamLine(line), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in job.cancel() }
        }
    }

    func complete(messages: [LLMMessage], model: String?) async throws -> String {
        var full = ""
        for try await piece in send(messages: messages, model: model, stream: false) {
            full += piece
        }
        return full
    }

    /// HTTP 状态校验：优先用各厂商自己的错误信息格式翻译成中文口径
    func checkResponse(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode >= 400 else { return }
        let raw = LLMTransport.truncate(String(data: data, encoding: .utf8) ?? "", limit: 300)
        throw LLMError.httpStatus(http.statusCode, readableError(from: data) ?? raw)
    }
}

public extension LLMResponseParsing {
    func isTerminalLine(_ line: String) -> Bool { false }
}

// MARK: - 取消判定

public extension Error {
    /// 是否为「用户主动取消」类错误。
    /// 门面层会把 CancellationError 统一包装成 `LLMError.cancelled`，因此两处都要识别，
    /// 否则 UI 会把「点停止」误报成红色错误提示。
    var isLLMCancellation: Bool {
        if self is CancellationError { return true }
        if let llm = self as? LLMError, case .cancelled = llm { return true }
        return false
    }
}

// MARK: - 厂商显示名

public extension LLMProviderKind {
    /// 设置页/UI 展示用中文名
    var displayName: String {
        switch self {
        case .anthropic:        return "Anthropic Claude"
        case .gemini:           return "Google Gemini"
        case .openAICompatible: return "OpenAI 兼容"
        case .ollama:           return "Ollama（本地）"
        }
    }

    var iconName: String {
        switch self {
        case .anthropic:        return "brain"
        case .gemini:           return "sparkles"
        case .openAICompatible: return "chevron.left.for.chevron.right"
        case .ollama:           return "desktopcomputer"
        }
    }

    /// 该厂商是否需要 API Key
    var needsCredential: Bool {
        switch self {
        case .ollama: return false
        default:      return true
        }
    }

    /// 偏好里该厂商的固定服务地址（用户可在设置页覆盖）
    var defaultBaseURL: URL {
        let raw: String
        switch self {
        case .anthropic:        raw = "https://api.anthropic.com"
        case .gemini:           raw = "https://generativelanguage.googleapis.com"
        case .openAICompatible: raw = "https://api.openai.com"
        case .ollama:           raw = "http://localhost:11434"
        }
        return URL(string: raw)!
    }
}
