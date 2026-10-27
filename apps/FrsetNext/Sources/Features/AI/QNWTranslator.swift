import Foundation

// MARK: - 360 快速翻译通道（免 Key）
//
// 来源：ZTools 官方「翻译助手」插件（pluginId: translator）用的就是这条接口，
// 拆包可见 `https://ai.api.360qnw.com/api/oauth/translation`，POST 表单
// `query / lang / tolang`，**不需要 API Key、不需要登录**。
//
// 实测（2026-10-27）：
//   · 单行：`hello world` → `你好，世界`
//   · 多行：一次提交 3 行，返回 3 段且顺序不变 → 可以**按行对齐**，适合 OCR 文档兜底
//   · 代价：逐句机翻，没有上下文/术语一致性，质量明显低于大模型
//
// 定位：**兜底通道**。用户没配 Key、或大模型调用失败时用它，保证「翻译」这个动作不会
// 直接失败；有 Key 时默认仍走大模型。
enum QNWTranslator {

    /// 接口地址（与 ZTools 插件一致）
    private static let endpoint = URL(string: "https://ai.api.360qnw.com/api/oauth/translation")!

    /// 单请求最大字符数（按行切块，避免超长文本被截断或超时）
    private static let maxChunkCharacters = 1200

    // MARK: - 对外

    /// 翻译整段文本，**保留原有行结构**（一行对一行）。
    static func translate(_ text: String, to targetLanguage: String?) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationToolError.emptyInput }
        let target = targetLanguage.flatMap { $0.isEmpty ? nil : $0 }
            ?? TranslationToolSession.autoTarget(for: trimmed)
        let langCode = languageCode(for: target, source: trimmed)

        var output: [String] = []
        for chunk in chunks(of: trimmed) {
            let segments = try await request(chunk, to: langCode)
            let lines = chunk.components(separatedBy: "\n")
            if segments.count == lines.count {
                // 行数对齐：空行原样保留（接口对空行不一定返回段）
                var index = 0
                for line in lines {
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        output.append(line)
                    } else if index < segments.count {
                        output.append(segments[index])
                        index += 1
                    }
                }
            } else {
                // 行数对不上（接口按句切分）：退化为整段拼接，至少不丢内容
                output.append(contentsOf: segments)
            }
        }
        let joined = output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw TranslationToolError.formatMismatch }
        return joined
    }

    /// 逐块翻译（截图回绘用）：输入每块文本，输出等长数组
    static func translateBlocks(_ texts: [String], to targetLanguage: String?) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let joined = texts.joined(separator: "\n")
        let translated = try await translate(joined, to: targetLanguage)
        let lines = translated.components(separatedBy: "\n")
        guard lines.count == texts.count else { throw TranslationToolError.formatMismatch }
        return lines
    }

    // MARK: - 语言码

    /// 目标语言文案（"English" / "简体中文" ...）→ 360 的语言码
    static func languageCode(for target: String, source: String) -> String {
        let t = target.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }

        if has("english", "英文", "英语") { return "en" }
        if has("繁体", "繁體", "traditional") { return "cht" }
        if has("简体", "簡體", "中文", "chinese", "汉语", "漢語") { return "zh" }
        if has("日语", "日文", "japanese") { return "jp" }
        if has("韩语", "韩文", "korean") { return "kor" }
        if has("法语", "french") { return "fra" }
        if has("德语", "德文", "german") { return "de" }
        if has("西班牙", "spanish") { return "spa" }
        if has("俄语", "俄文", "russian") { return "ru" }
        if has("葡萄牙", "portuguese") { return "pt" }
        if has("意大利", "italian") { return "it" }
        if has("泰语", "泰文", "thai") { return "th" }
        if has("阿拉伯", "arabic") { return "ara" }
        // 兜底：按源文判断方向（中文为主 → 英文；否则 → 简体中文）
        return TranslationToolSession.cjkRatio(source) > 0.25 ? "en" : "zh"
    }

    // MARK: - 请求

    private static func request(_ text: String, to languageCode: String) async throws -> [String] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        let boundary = "FrsetBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
            body.append(value.data(using: .utf8) ?? Data())
            body.append("\r\n".data(using: .utf8) ?? Data())
        }
        appendField("query", text)
        appendField("lang", "auto")
        appendField("tolang", languageCode)
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QNWError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QNWError.network("响应无效")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QNWError.network("HTTP \(http.statusCode)")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw QNWError.decode
        }
        guard envelope.code == 0 else {
            throw QNWError.api(envelope.code, envelope.msg ?? "")
        }
        let segments = envelope.data?.trans_result.map { $0.dst } ?? []
        guard !segments.isEmpty else { throw QNWError.empty }
        return segments
    }

    // MARK: - 切块

    /// 按行累计切块：每块不超过 maxChunkCharacters，且不切断单行
    private static func chunks(of text: String) -> [String] {
        guard text.count > maxChunkCharacters else { return [text] }
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if !current.isEmpty, current.count + line.count + 1 > maxChunkCharacters {
                result.append(current)
                current = line
            } else {
                current = current.isEmpty ? line : current + "\n" + line
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - 响应模型

    private struct Segment: Decodable {
        let src: String?
        let dst: String
    }
    private struct Payload: Decodable {
        let from: String?
        let to: String?
        let trans_result: [Segment]
    }
    private struct Envelope: Decodable {
        let code: Int
        let msg: String?
        let data: Payload?
    }
}

// MARK: - 错误

enum QNWError: Error, LocalizedError {
    case network(String)
    case decode
    case api(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .network(let detail): return "快速翻译通道网络异常（\(detail)）"
        case .decode:              return "快速翻译通道返回格式异常"
        case .api(let code, let message):
            return "快速翻译通道报错（code \(code)\(message.isEmpty ? "" : "：\(message)")）"
        case .empty:               return "快速翻译通道未返回译文"
        }
    }
}
