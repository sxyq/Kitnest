import Foundation

// MARK: - 翻译 Provider 层（v147）
//
// 参照 ZTools 的做法：把「翻译」抽象成可插拔的 Provider —— 统一接口 + 注册表 +
// 用户可选默认项，而不是把某个厂商写死在会话里。
//
// 与 ZTools 的差异（有意为之）：
//   · 只做单进程内的协议抽象，不做插件沙箱（我们是原生 App，没有插件运行时）；
//   · Provider 由代码注册，用户选「用哪个 / 自动」，能力边界清晰、可测。
//
// 新增一个引擎 = 实现 `TranslationProvider` + 在注册表加一行，其余（设置页、
// 自动回落、流式适配、逐行对齐）全部复用。

/// 翻译场景：短句 / 整篇文档（文档要求一行对一行）
public enum TranslationMode {
    case plain
    case document
}

public protocol TranslationProvider: AnyObject {
    /// 稳定标识（写进偏好设置）
    var id: String { get }
    /// 设置页展示名
    var displayName: String { get }
    /// 一句话说明（质量/成本/是否要 Key）
    var summary: String { get }
    /// 是否依赖用户凭证
    var requiresCredential: Bool { get }
    /// 当前是否可用（凭证是否配好由调用时抛错决定）
    var isAvailable: Bool { get }

    func translate(_ text: String, to targetLanguage: String?, mode: TranslationMode) async throws -> String
    func translateLines(_ lines: [String], to targetLanguage: String?) async throws -> [String]

    /// 可选：流式输出（只有大模型支持；返回 nil 表示不支持，调用方退化为一次性）
    func stream(_ text: String, to targetLanguage: String?) -> AsyncThrowingStream<String, Error>?
}

public extension TranslationProvider {
    func stream(_ text: String, to targetLanguage: String?) -> AsyncThrowingStream<String, Error>? { nil }
}

// MARK: - 实现一：AI 大模型

public final class LLMTranslationProvider: TranslationProvider {
    public let id = "llm"
    public var displayName: String { "AI 大模型（\(AISettings.providerKind.displayName)）" }
    public var summary: String { "上下文、术语、长文最准；需要在设置里填 API Key" }
    public let requiresCredential = true

    private let serviceProvider: () -> LLMServiceProtocol?

    public init(serviceProvider: @escaping () -> LLMServiceProtocol? = { ServiceLocator.llmService }) {
        self.serviceProvider = serviceProvider
    }

    public var isAvailable: Bool { serviceProvider() != nil }

    public func translate(_ text: String, to targetLanguage: String?, mode: TranslationMode) async throws -> String {
        guard let service = serviceProvider() else { throw TranslationToolError.llmUnavailable }
        let target = resolvedTarget(targetLanguage, for: text)
        let system: String
        switch mode {
        case .plain:
            system = "你是专业翻译助手。请把用户提供的内容翻译成\(target)，保持专业术语与格式，只输出译文，不要加入解释。"
        case .document:
            system = """
            你是专业翻译引擎。输入是一张截图 OCR 出来的文字，可能含错字、断行、UI 标签、代码片段。
            请翻译成\(target)，并严格遵守：
            1) 严格保留原有换行与空行结构，一行对一行，不要把多行合并成一段；
            2) 只输出译文，不要解释、不要加标题或引号；
            3) 数字、URL、代码、文件路径、专有名词保持原样；
            4) OCR 明显错字请按上下文纠正后再翻译，不要照抄错字。
            """
        }
        return try await service.complete(prompt: "请翻译以下内容：\n\n" + text, system: system, model: nil)
    }

    public func translateLines(_ lines: [String], to targetLanguage: String?) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        guard let service = serviceProvider() else { throw TranslationToolError.llmUnavailable }
        let target = resolvedTarget(targetLanguage, for: lines.joined(separator: "\n"))
        let body = lines.enumerated()
            .map { "⟦\($0.offset + 1)⟧ \($0.element.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let system = """
        你是专业翻译引擎。输入每一行都以 ⟦n⟧ 开头（这是行号标记，不是正文）。
        请把每行翻译成\(target)，并严格遵守：
        1) 输出行数必须与输入完全相同，每行以 ⟦n⟧ 开头，后面只跟该行译文；
        2) 不要合并、拆分、省略任何行，也不要调整顺序；
        3) 只输出译文，不要解释；数字、URL、代码、专有名词保持原样。
        """
        let reply = try await service.complete(prompt: body, system: system, model: nil)
        let parsed = TranslationToolSession.parseMarkedLines(reply, expected: lines.count)
        guard parsed.count == lines.count, parsed.allSatisfy({ !$0.isEmpty }) else {
            throw TranslationToolError.formatMismatch
        }
        return parsed
    }

    public func stream(_ text: String, to targetLanguage: String?) -> AsyncThrowingStream<String, Error>? {
        guard let service = serviceProvider() else { return nil }
        let target = resolvedTarget(targetLanguage, for: text)
        let system = target.isEmpty
            ? "你是专业翻译助手。请在中文与英文之间自动判断源语言并互译，保持专业术语与格式，只输出译文，不要加入解释。"
            : "你是专业翻译助手。请把用户提供的内容翻译成\(target)，保持专业术语与格式，只输出译文，不要加入解释。"
        return service.stream(prompt: "请翻译以下内容：\n\n" + text, system: system, model: nil)
    }

    private func resolvedTarget(_ targetLanguage: String?, for text: String) -> String {
        if let t = targetLanguage, !t.isEmpty { return t }
        return TranslationToolSession.autoTarget(for: text)
    }
}

// MARK: - 实现二：360 快速通道（免 Key）

public final class QNWTranslationProvider: TranslationProvider {
    public let id = "qnw"
    public var displayName: String { "快速通道（360，免 Key）" }
    public var summary: String { "免 Key 免登录、逐句机翻；没配 Key 时的兜底，质量一般" }
    public let requiresCredential = false

    public init() {}

    public var isAvailable: Bool { true }

    public func translate(_ text: String, to targetLanguage: String?, mode: TranslationMode) async throws -> String {
        try await QNWTranslator.translate(text, to: targetLanguage)
    }

    public func translateLines(_ lines: [String], to targetLanguage: String?) async throws -> [String] {
        try await QNWTranslator.translateBlocks(lines, to: targetLanguage)
    }
}

// MARK: - 注册表

public final class TranslationProviderRegistry {
    public static let shared = TranslationProviderRegistry()

    /// 顺序即「自动」模式的优先级（质量优先 → 兜底）
    private let providers: [TranslationProvider]

    /// 顺序 = 「自动」模式的尝试顺序：外部 API 优先，本机离线翻译最后兜底
    public init(providers: [TranslationProvider] = [
        LLMTranslationProvider(),
        QNWTranslationProvider(),
        AppleTranslationProvider()
    ]) {
        self.providers = providers
    }

    public var all: [TranslationProvider] { providers }

    public func provider(id: String) -> TranslationProvider? {
        providers.first { $0.id == id }
    }

    /// 解析用户偏好：
    /// · "auto" → 全部（按优先级依次尝试，第一个成功即返回）
    /// · 具体 id → 只试它（失败就报错，符合「我只想用这个」的语义，
    ///   —— ZTools 的 getDefaultProvider 也是这个行为）
    public func resolve(preference: String) -> [TranslationProvider] {
        if preference == AISettings.translationAutoPreference { return providers }
        if let chosen = provider(id: preference) { return [chosen] }
        return providers
    }

    /// 当前实际会用的第一个可用 Provider（设置页文案/诊断用）
    public func effectiveProvider(preference: String) -> TranslationProvider? {
        resolve(preference: preference).first { $0.isAvailable }
    }
}
