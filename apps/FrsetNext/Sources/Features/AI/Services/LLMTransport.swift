import Foundation

// MARK: - 网络传输层
//
// 需求：所有请求必须可取消 —— 因此不使用 `URLSession.shared.bytes(for:)`，
// 而是自建 dataTask + 自定义 delegate（对应原作的 `AIProviderURLSessionDelegate`），
// 把字节通过 AsyncThrowingStream 吐给上层；stream 被终止时同步 cancel 底层 task。

/// 流式委托：把服务端下发的字节切片按到达顺序转发，并负责 HTTP 状态校验
public final class AIProviderURLSessionDelegate: NSObject, URLSessionDataDelegate {
    private let onData: (Data) -> Void
    private let onFinish: (Error?) -> Void
    /// 把响应体翻译成各厂商自己的错误描述（避免把整坨 JSON 甩给用户）
    private let refineError: ((Data) -> String?)?
    private var statusCode: Int = 200
    private var errorBody = Data()

    public init(onData: @escaping (Data) -> Void,
                onFinish: @escaping (Error?) -> Void,
                refineError: ((Data) -> String?)? = nil) {
        self.onData = onData
        self.onFinish = onFinish
        self.refineError = refineError
        super.init()
    }

    public func urlSession(_ session: URLSession,
                           dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard statusCode >= 400 else { onData(data); return }
        // 错误响应体单独攒起来，用于拼中文报错
        errorBody.append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onFinish(error)
        } else if statusCode >= 400 {
            let raw = String(data: errorBody, encoding: .utf8) ?? ""
            let detail = refineError?(errorBody) ?? LLMTransport.truncate(raw, limit: 300)
            onFinish(LLMError.httpStatus(statusCode, detail))
        } else {
            onFinish(nil)
        }
    }
}

public enum LLMTransport {
    /// 单条请求超时
    public static let requestTimeout: TimeInterval = 60
    /// 整体资源超时（流式长连接）
    public static let resourceTimeout: TimeInterval = 600


    /// 流式读取：产出服务端原始字节切片
    /// - Parameter refineError: 把错误响应体翻译成厂商口径的可读文案
    public static func streamBytes(_ request: URLRequest,
                                   timeout: TimeInterval = requestTimeout,
                                   refineError: ((Data) -> String?)? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
            let box = SessionBox()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = resourceTimeout
            config.httpAdditionalHeaders = ["Accept": "text/event-stream", "Cache-Control": "no-cache"]

            let delegate = AIProviderURLSessionDelegate(
                onData: { continuation.yield($0) },
                onFinish: { error in
                    if let error { continuation.finish(throwing: error) }
                    else { continuation.finish() }
                    box.invalidate()
                },
                refineError: refineError
            )
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            box.session = session

            let task = session.dataTask(with: request)
            task.resume()

            continuation.onTermination = { @Sendable _ in
                // Swift 并发取消 → 立即终止底层请求，符合「可取消」硬约束
                task.cancel()
                box.invalidate()
            }
        }
    }

    /// 带连接池清理的 session 持有盒
    private final class SessionBox {
        var session: URLSession?
        private let lock = NSLock()
        func invalidate() {
            lock.lock()
            let s = session
            session = nil
            lock.unlock()
            s?.invalidateAndCancel()
        }
    }

    public static func truncate(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

// MARK: - 行缓冲
//
// SSE（`data: xxx\n\n`）与 NDJSON（整行一个 JSON）都按 \n 切行，
// 但 TCP 分片可能切断一行，因此需要跨 chunk 攒行。

public final class LLMLineBuffer {
    private var remainder = Data()

    @discardableResult
    public func ingest(_ data: Data) -> [String] {
        remainder.append(data)
        return drain(force: false)
    }

    public func flush() -> [String] {
        drain(force: true)
    }

    private func drain(force: Bool) -> [String] {
        var lines: [String] = []
        // v126（性能审计 F0224）：单趟扫描收集行边界，末尾一次性裁剪。
        // 原实现每行都 range(of: Data([0x0A])) 从头搜索 + removeSubrange 整段前移
        //（每行一次 O(n) 拷贝，一个 chunk 攒出几十行就是 O(n²)）——SSE 流式回包是 AI 热路径。
        var cursor = remainder.startIndex
        var lineStart = remainder.startIndex
        while let nl = remainder[cursor...].firstIndex(of: 0x0A) {
            if let line = String(data: remainder[lineStart..<nl], encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
            cursor = remainder.index(after: nl)
            lineStart = cursor
        }
        if lineStart > remainder.startIndex {
            remainder.removeSubrange(remainder.startIndex..<lineStart)
        }
        if force, !remainder.isEmpty {
            if let tail = String(data: remainder, encoding: .utf8) {
                let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
            remainder.removeAll()
        }
        return lines
    }
}

// MARK: - JSON 便捷取值

public enum LLMJSON {
    public static func object(_ data: Data) throws -> [String: Any] {
        let any = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = any as? [String: Any] else {
            let raw = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw LLMError.decoding("响应不是 JSON 对象：\(LLMTransport.truncate(raw, limit: 200))")
        }
        return dict
    }

    /// 取出服务商返回的错误描述（各家字段名不同，统一兜底）
    public static func errorMessage(_ dict: [String: Any]) -> String? {
        if let err = dict["error"] as? [String: Any] {
            return err["message"] as? String ?? err["type"] as? String
        }
        if let err = dict["error"] as? String { return err }
        if let msg = dict["message"] as? String, let ok = dict["success"] as? Bool, !ok { return msg }
        return nil
    }

    /// 通用 SSE 载荷预处理：剥离 `data:` 前缀，识别 `[DONE]`
    public static func ssePayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        return payload
    }

    /// 流式行的通用载荷提取：优先按 SSE `data:` 处理；若整行本身是 JSON（部分网关 / NDJSON 服务直接吐裸 JSON），原样返回
    public static func streamPayload(_ line: String) -> String? {
        if let sse = ssePayload(line) { return sse }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        return trimmed
    }
}
