import Foundation

// MARK: - 翻译工具会话
//
// 对应原作 `TranslationToolSession` + 实证协议 `TranslationToolRequestExecuting`（规格 09 §1 / §2）。
//
// 定位：把「划词 / 截图 OCR 得到的文本」翻成目标语言，供面板、截图取词、工具箱等入口复用。
// 依赖注入：只依赖 Core 的 `LLMServiceProtocol`（经 ServiceLocator 注入），
// 因此本类不耦合任何具体厂商实现，未注入时失败路径也保持优雅（返回中文可读错误）。

public enum TranslationToolError: Error, LocalizedError {
    case emptyInput
    case llmUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyInput:     return "没有可翻译的文本。"
        case .llmUnavailable: return "AI 服务尚未就绪，请稍后重试或在「设置 → AI」中检查配置。"
        }
    }
}

/// 翻译执行接口（规格 §2 实证协议名）
public protocol TranslationToolRequestExecuting: AnyObject {
    /// 流式翻译；targetLanguage 为 nil 时由模型自动判断源语言并中英互译
    func translate(_ text: String, to targetLanguage: String?) -> AsyncThrowingStream<String, Error>
}

public final class TranslationToolSession: TranslationToolRequestExecuting {
    public static let shared = TranslationToolSession()

    /// 自动模式的语言说明文案（UI 下拉用）
    public static let autoLanguageLabel = "自动（中英互译）"

    /// 语言解析延迟到调用时进行，避免模块启动顺序影响注入结果
    private let llmProvider: () -> LLMServiceProtocol?

    public init(llmProvider: @escaping () -> LLMServiceProtocol? = { ServiceLocator.llmService }) {
        self.llmProvider = llmProvider
    }

    /// LLM 能力是否可用（未注入时 UI 应禁用翻译入口）
    public var isAvailable: Bool { llmProvider() != nil }

    // MARK: - 执行

    public func translate(_ text: String, to targetLanguage: String? = nil) -> AsyncThrowingStream<String, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // spec 13 §4：未读取到文字场景（0x10000d45c，上游未取到可翻译文本）
            Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
            return AsyncThrowingStream { $0.finish(throwing: TranslationToolError.emptyInput) }
        }
        guard let service = llmProvider() else {
            return AsyncThrowingStream { $0.finish(throwing: TranslationToolError.llmUnavailable) }
        }
        return service.stream(prompt: userPrompt(for: trimmed),
                              system: systemPrompt(target: targetLanguage),
                              model: nil)
    }

    /// 一次性翻译（用于「翻译后直接写回剪贴板」等无需逐字渲染的场景）
    public func complete(_ text: String, to targetLanguage: String? = nil) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // spec 13 §4：未读取到文字场景（0x10000d45c，上游未取到可翻译文本）
        guard !trimmed.isEmpty else {
            Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
            throw TranslationToolError.emptyInput
        }
        guard let service = llmProvider() else { throw TranslationToolError.llmUnavailable }
        return try await service.complete(prompt: userPrompt(for: trimmed),
                                          system: systemPrompt(target: targetLanguage),
                                          model: nil)
    }

    // MARK: - 提示词

    private func systemPrompt(target: String?) -> String {
        let language = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if language.isEmpty {
            return "你是专业翻译助手。请在中文与英文之间自动判断源语言并互译，保持专业术语与格式，只输出译文，不要加入解释。"
        }
        return "你是专业翻译助手。请把用户提供的内容翻译成\(language)，保持专业术语与格式，只输出译文，不要加入解释。"
    }

    private func userPrompt(for text: String) -> String {
        "请翻译以下内容：\n\n" + text
    }
}
