import Foundation

// MARK: - 旧版 Gemini 配置迁移
//
// 对应原作 `LegacyGeminiMigrator` / `LegacyGeminiMigrationLedger`（规格 09 §1 / B6）。
//
// 背景：原作早期版本只有 Gemini 一家服务商，配置直接写在 UserDefaults 的旧键上；
// 引入多服务商后需要把旧配置一次性搬迁到新体系（凭证文件 + 厂商/地址/模型偏好）。
// 使用「迁移台账」（键 `legacy_gemini_migration_version`）保证只迁移一次，重启不会重复执行。
//
// 旧键名在规格「待查清单」中未确定，因此这里以候选清单探测（大小写/命名风格各异），
// 迁移后统一清理旧键，避免明文密钥长期残留在 UserDefaults 中。

public protocol LegacyGeminiSettingsStoring: AnyObject {
    /// 读取旧键；不存在或空白返回 nil
    func legacyString(_ key: String) -> String?
    /// 删除旧键
    func removeLegacy(_ key: String)
}

/// 默认实现：直接读写 UserDefaults（经 Preferences 封装）
public final class UserDefaultsLegacyGeminiStore: LegacyGeminiSettingsStoring {
    private let prefs: Preferences

    public init(prefs: Preferences = .shared) {
        self.prefs = prefs
    }

    public func legacyString(_ key: String) -> String? {
        let value = prefs.value(key, default: "") as String
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func removeLegacy(_ key: String) {
        prefs.set(key, nil)
    }
}

/// 迁移台账：记录已完成的迁移版本，防止重复迁移
public final class LegacyGeminiMigrationLedger {
    /// 与规格 §1 一致的台账键
    public static let key = "legacy_gemini_migration_version"
    public static let currentVersion = 1

    private let prefs: Preferences

    public init(prefs: Preferences = .shared) {
        self.prefs = prefs
    }

    public var version: Int { prefs.value(Self.key, default: 0) as Int }
    public var hasMigrated: Bool { version >= Self.currentVersion }

    public func markMigrated() {
        prefs.set(Self.key, Self.currentVersion)
    }
}

public final class LegacyGeminiMigrator {
    public static let shared = LegacyGeminiMigrator()

    public static let legacyAPIKeyKeys = ["gemini.apiKey", "gemini.api_key", "geminiAPIKey", "geminiApiKey"]
    public static let legacyBaseURLKeys = ["gemini.baseURL", "gemini.apiBaseURL", "geminiBaseURL"]
    public static let legacyModelKeys = ["gemini.model", "geminiModel"]

    private let store: LegacyGeminiSettingsStoring
    private let ledger: LegacyGeminiMigrationLedger
    private let credentials: LLMCredentialStoring

    public init(store: LegacyGeminiSettingsStoring = UserDefaultsLegacyGeminiStore(),
                ledger: LegacyGeminiMigrationLedger = LegacyGeminiMigrationLedger(),
                credentials: LLMCredentialStoring = CredentialStore.shared) {
        self.store = store
        self.ledger = ledger
        self.credentials = credentials
    }

    /// 执行一次性迁移。返回是否真正搬迁了数据（幂等）。
    @discardableResult
    public func migrateIfNeeded() -> Bool {
        guard !ledger.hasMigrated else { return false }

        var moved = false

        // 1) API Key → 凭证存储（Gemini）
        if !credentials.hasCredential(for: .gemini),
           let key = firstValue(Self.legacyAPIKeyKeys) {
            credentials.setCredential(key, for: .gemini)
            moved = true
            Log.info("AI", "已迁移旧版 Gemini 凭证")
        }

        // 2) 自定义地址（仅当用户尚未配置过 per-provider 地址时）
        if AISettings.baseURL(for: .gemini) == LLMProviderKind.gemini.defaultBaseURL,
           let url = firstValue(Self.legacyBaseURLKeys) {
            AISettings.setBaseURL(url, for: .gemini)
            moved = true
            Log.info("AI", "已迁移旧版 Gemini 服务地址")
        }

        // 3) 模型
        if AISettings.selectedModel.isEmpty,
           let model = firstValue(Self.legacyModelKeys) {
            AISettings.selectedModel = model
            moved = true
            Log.info("AI", "已迁移旧版 Gemini 模型")
        }

        // 4) 若用户从未选过厂商，而旧版明确是 Gemini → 默认切到 Gemini
        if moved, (Preferences.shared.value(Preferences.Keys.aiProvider, default: "") as String).isEmpty {
            AISettings.providerKind = .gemini
        }

        // 5) 清理旧键（无论是否搬迁到内容，都清理一次，避免明文长期留存）
        (Self.legacyAPIKeyKeys + Self.legacyBaseURLKeys + Self.legacyModelKeys).forEach(store.removeLegacy)

        ledger.markMigrated()
        return moved
    }

    private func firstValue(_ keys: [String]) -> String? {
        for key in keys {
            if let v = store.legacyString(key) { return v }
        }
        return nil
    }
}
