import Foundation

// MARK: - AI 偏好读写
//
// Core/Preferences.Keys 已提供 aiProvider / aiModel / aiBaseURL 三个键，
// 其余 AI 专属键在这个文件内集中定义（不修改 Core，保持契约 §1.1）。

public enum AISettings {
    /// 采样温度
    public static let keyTemperature = "ai.temperature"
    /// 单次回复最大 token
    public static let keyMaxTokens = "ai.maxTokens"
    /// 摘要面板的默认动作（对应 AISummaryAction.rawValue）
    public static let keyDefaultAction = "ai.defaultAction"
    /// 助手系统提示词
    public static let keySystemPrompt = "ai.systemPrompt"

    /// 每厂商独立的 Base URL 键（默认值回落 Core 提供的 ai.baseURL，再回落到内置常量）
    public static func baseURLKey(for provider: LLMProviderKind) -> String {
        "ai.baseURL.\(provider.rawValue)"
    }

    private static let prefs = Preferences.shared

    // MARK: 厂商

    public static var providerKind: LLMProviderKind {
        get {
            let raw = prefs.value(Preferences.Keys.aiProvider, default: LLMProviderKind.anthropic.rawValue)
            return LLMProviderKind(rawValue: raw) ?? .anthropic
        }
        set { prefs.set(Preferences.Keys.aiProvider, newValue.rawValue) }
    }

    public static func baseURL(for provider: LLMProviderKind) -> URL {
        let perProvider = prefs.value(baseURLKey(for: provider), default: "") as String
        let shared = prefs.value(Preferences.Keys.aiBaseURL, default: "") as String
        let chosen = perProvider.isEmpty ? shared : perProvider
        let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return provider.defaultBaseURL
        }
        return url
    }

    public static func setBaseURL(_ value: String, for provider: LLMProviderKind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            prefs.set(baseURLKey(for: provider), nil)
        } else {
            prefs.set(baseURLKey(for: provider), trimmed)
        }
    }

    // MARK: 模型

    /// 用户显式选择的模型（空串表示跟随厂商默认）
    public static var selectedModel: String {
        get { (prefs.value(Preferences.Keys.aiModel, default: "") as String).trimmingCharacters(in: .whitespaces) }
        set { prefs.set(Preferences.Keys.aiModel, newValue) }
    }

    // MARK: 生成参数

    public static var temperature: Double {
        let v = prefs.value(keyTemperature, default: 0.7)
        return min(max(v, 0.0), 2.0)
    }

    public static var maxTokens: Int {
        let v = prefs.value(keyMaxTokens, default: 4096)
        return min(max(v, 256), 200_000)
    }

    // MARK: 系统提示词

    public static let fallbackSystemPrompt =
        "你是 Frset 内置的中文助手。回答请简洁、结构化，优先使用中文；除非用户明确要求，不要输出冗长免责声明。"

    public static var systemPrompt: String {
        let v = prefs.value(keySystemPrompt, default: "") as String
        return v.isEmpty ? fallbackSystemPrompt : v
    }
}
