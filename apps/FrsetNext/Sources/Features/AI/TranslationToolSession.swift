import Foundation

// MARK: - 翻译工具会话（v147：Provider 调度器）
//
// 定位：对外仍是「翻译」这一个动作，内部不再关心具体引擎——按用户偏好从
// `TranslationProviderRegistry` 取候选 Provider，依次尝试，第一个成功即返回。
//
// 与 v146 的差别：那时是 `if engine == .quick { ... } else { ... }` 的硬分支；
// 现在是注册表 + 协议，新增引擎不改这里一行代码。

public enum TranslationToolError: Error, LocalizedError {
    case emptyInput
    case llmUnavailable
    case formatMismatch

    public var errorDescription: String? {
        switch self {
        case .emptyInput:     return "没有可翻译的文本。"
        case .llmUnavailable: return "没有可用的翻译引擎，请在「设置 → 搜索与 AI」中配置。"
        case .formatMismatch: return "译文格式不匹配，请重试。"
        }
    }
}

/// 翻译执行接口（规格 §2 实证协议名）
public protocol TranslationToolRequestExecuting: AnyObject {
    /// 流式翻译；targetLanguage 为 nil 时自动判断方向
    func translate(_ text: String, to targetLanguage: String?) -> AsyncThrowingStream<String, Error>
}

public final class TranslationToolSession: TranslationToolRequestExecuting {
    public static let shared = TranslationToolSession()

    /// 自动模式的语言说明文案（UI 下拉用）
    public static let autoLanguageLabel = "自动（中英互译）"

    /// 候选 Provider（延迟到调用时解析，避免模块启动顺序影响结果）
    private let providersProvider: () -> [TranslationProvider]

    public init(providersProvider: @escaping () -> [TranslationProvider] = {
        TranslationProviderRegistry.shared.resolve(preference: AISettings.translationProviderPreference)
    }) {
        self.providersProvider = providersProvider
    }

    /// 是否至少有一个可用引擎（快速通道永远可用 → 基本恒为 true）
    public var isAvailable: Bool {
        providersProvider().contains { $0.isAvailable }
    }

    /// 当前实际使用的引擎名（诊断/日志用）
    public var effectiveProviderName: String {
        let candidates = providersProvider().filter { $0.isAvailable }
        return candidates.first?.displayName ?? "无"
    }

    // MARK: - 执行

    public func translate(_ text: String, to targetLanguage: String? = nil) -> AsyncThrowingStream<String, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // spec 13 §4：未读取到文字场景（0x10000d45c，上游未取到可翻译文本）
            Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
            return AsyncThrowingStream { $0.finish(throwing: TranslationToolError.emptyInput) }
        }
        let candidates = providersProvider().filter { $0.isAvailable }
        guard let first = candidates.first else {
            return AsyncThrowingStream { $0.finish(throwing: TranslationToolError.llmUnavailable) }
        }
        // 支持流式的（大模型）直接流；不支持的拿整段再一次性吐出
        if let stream = first.stream(trimmed, to: targetLanguage) {
            return stream
        }
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.attempt { provider in
                        try await provider.translate(trimmed, to: targetLanguage, mode: .plain)
                    }
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 一次性翻译（用于「翻译后直接写回剪贴板」等无需逐字渲染的场景）
    public func complete(_ text: String, to targetLanguage: String? = nil) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // spec 13 §4：未读取到文字场景（0x10000d45c，上游未取到可翻译文本）
            Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
            throw TranslationToolError.emptyInput
        }
        return try await attempt { provider in
            try await provider.translate(trimmed, to: targetLanguage, mode: .plain)
        }
    }

    // MARK: - 语言判定（v139）

    /// CJK 字符占比（决定「中文→英文」还是「英文→中文」）
    public static func cjkRatio(_ text: String) -> Double {
        var cjk = 0, total = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            total += 1
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
                || (0x3000...0x303F).contains(v) || (0xFF00...0xFF60).contains(v) {
                cjk += 1
            }
        }
        return total == 0 ? 0 : Double(cjk) / Double(total)
    }

    /// 自动目标语言：源文以中文为主 → 英文；否则 → 简体中文
    public static func autoTarget(for text: String) -> String {
        cjkRatio(text) > 0.25 ? "English" : "简体中文"
    }

    // MARK: - 文档级翻译（v139：截图文字结果窗 / 翻译页签）

    /// 整段翻译：**保留换行与段落结构**（由 Provider 的 .document 模式保证）
    public func translateDocument(_ text: String, to targetLanguage: String? = nil) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationToolError.emptyInput }
        return try await attempt { provider in
            try await provider.translate(trimmed, to: targetLanguage, mode: .document)
        }
    }

    // MARK: - 逐块翻译（截图回绘用，行号严格对齐）

    /// 逐块翻译：行数与输入严格一致；Provider 内部各自保证（大模型用 ⟦n⟧ 协议，
    /// 快速通道靠接口逐行返回）。
    public func translateNumberedBlocks(_ texts: [String], to targetLanguage: String? = nil) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let candidates = providersProvider().filter { $0.isAvailable }
        guard !candidates.isEmpty else { throw TranslationToolError.llmUnavailable }
        var lastError: Error?
        for provider in candidates {
            do {
                return try await provider.translateLines(texts, to: targetLanguage)
            } catch {
                lastError = error
                Log.warn("AI", "逐块翻译 Provider「\(provider.displayName)」失败：\(error.localizedDescription)")
            }
        }
        throw lastError ?? TranslationToolError.formatMismatch
    }

    /// 解析 `⟦n⟧ 译文` / `n. 译文` 两种输出
    public static func parseMarkedLines(_ reply: String, expected: Int) -> [String] {
        let regexes = [
            try? NSRegularExpression(pattern: "^\\s*[⟦\\[]?(\\d{1,3})[⟧\\]]\\s*(.+)$"),
            try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})[.、)．]\\s*(.+)$")
        ].compactMap { $0 }
        for regex in regexes {
            var map: [Int: String] = [:]
            for line in reply.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let ns = trimmed as NSString
                if let m = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                   m.numberOfRanges >= 3, let idx = Int(ns.substring(with: m.range(at: 1))) {
                    map[idx] = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                }
            }
            if map.count == expected, (1...max(expected, 1)).allSatisfy({ map[$0]?.isEmpty == false }) {
                return (1...expected).compactMap { map[$0] }
            }
        }
        return []
    }

    // MARK: - 依次尝试

    /// 按优先级依次问候选 Provider，第一个成功即返回；全失败抛最后一个错误。
    private func attempt(_ body: (TranslationProvider) async throws -> String) async throws -> String {
        let candidates = providersProvider().filter { $0.isAvailable }
        guard !candidates.isEmpty else { throw TranslationToolError.llmUnavailable }
        var lastError: Error?
        for provider in candidates {
            do {
                return try await body(provider)
            } catch {
                lastError = error
                // 「自动」模式下这是预期路径（没配 Key），降到 debug 免得刷警告
                Log.debug("AI", "翻译 Provider「\(provider.displayName)」失败，尝试下一个：\(error.localizedDescription)")
            }
        }
        throw lastError ?? TranslationToolError.llmUnavailable
    }
}
