import Foundation

// MARK: - L10n 基建（specs/18 §6）
//
// 原作机制还原：
// - 键面 = 英文句子本身（en.lproj 中 key == value），代码直接引用英文键；
// - 查翻译缺失时回退键面（英文句）——回退策略即"键即英文兜底"；
// - `language` defaults 键存覆盖值（"auto" = 跟随系统，其余为语言码）；
// - 切换广播 `languageDidChange` 通知，全 UI 刷新（不重启 App）。
//
// 本轮只落基建 + 中文起步：存量中文文案保持现状，新代码可用 L10n.t("英文键面")，
// 翻译表随后补（specs/11 §4 铁律：不批量臆造 793 键）。

/// 轻量翻译入口
/// 用法：`L10n.t("Advanced Settings")` —— 键面为英文句，命中当前语言翻译则返回译文，否则原样返回英文键面
public enum L10n {

    /// 取键面在当前生效语言下的译文；缺失回退键面本身（英文兜底，对齐原作）
    public static func t(_ key: String) -> String {
        guard let code = LanguageManager.shared.resolvedLanguageCode else { return key }
        guard code != "en" else { return key }   // 英文键面即原文，无需查表
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// 当前语言是否为 RTL（阿拉伯语；原作反射串 isRightToLeftLanguage）
    public static var isRightToLeft: Bool {
        LanguageManager.shared.resolvedLanguageCode == "ar"
    }
}

// MARK: - 语言管理器（原作 LanguageManager，classobj 0x100acc840）

/// 语言持久化与切换（defaults 键 "language" 对齐原作；通知名 "languageDidChange" 对齐原作）
public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()

    /// defaults 键（原作键面："language"）
    private static let defaultsKey = "language"
    /// 通知名（原作 0x100b4aba0："languageDidChange"）
    public static let languageDidChange = Notification.Name("languageDidChange")

    /// 名称显示覆盖："auto" = 跟随系统，其余为 22 语言码之一
    @Published public private(set) var overrideDisplayLanguage: String

    /// 22 语言码常量（原作 .lproj 目录实测：specs/18 §3.4）
    public static let availableLanguages: [String] = [
        "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko", "nl",
        "pl", "pt-BR", "ru", "sv", "th", "tr", "uk", "vi",
        "zh-Hans", "zh-Hant-HK", "zh-Hant-TW",
    ]

    /// 各语言自称（下拉显示名；原作数据源未探明，按语言自称惯例补齐）
    public static let displayNames: [String: String] = [
        "ar": "العربية",
        "de": "Deutsch",
        "en": "English",
        "es": "Español",
        "fr": "Français",
        "hi": "हिन्दी",
        "id": "Bahasa Indonesia",
        "it": "Italiano",
        "ja": "日本語",
        "ko": "한국어",
        "nl": "Nederlands",
        "pl": "Polski",
        "pt-BR": "Português (Brasil)",
        "ru": "Русский",
        "sv": "Svenska",
        "th": "ไทย",
        "tr": "Türkçe",
        "uk": "Українська",
        "vi": "Tiếng Việt",
        "zh-Hans": "简体中文",
        "zh-Hant-HK": "繁體中文（香港）",
        "zh-Hant-TW": "繁體中文（台灣）",
    ]

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.overrideDisplayLanguage = defaults.string(forKey: Self.defaultsKey) ?? "auto"
    }

    /// 实际生效的语言码：覆盖值非 auto 时用覆盖值；否则按系统首选语言匹配 22 表（含区域码前缀匹配）；
    /// 系统语言不在表内时回退英文（nil = 用键面原文）
    public var resolvedLanguageCode: String? {
        if overrideDisplayLanguage != "auto" { return overrideDisplayLanguage }
        for preferred in Locale.preferredLanguages {
            if Self.availableLanguages.contains(preferred) { return preferred }
            // 区域码前缀匹配（如 "zh-Hans-CN" → "zh-Hans"、"pt-BR" 变体）
            if let match = Self.availableLanguages.first(where: { preferred.hasPrefix($0) }) {
                return match
            }
        }
        return nil   // 英文兜底：键面即英文
    }

    /// 切换语言：写 defaults 并广播（触发全 UI 刷新，不重启 App）
    public func apply(_ code: String) {
        let normalized = Self.availableLanguages.contains(code) || code == "auto" ? code : "auto"
        overrideDisplayLanguage = normalized
        defaults.set(normalized, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.languageDidChange, object: nil)
        Log.info("L10n", "显示语言已切换: \(normalized)")
    }
}
