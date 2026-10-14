import Foundation
import CommonCrypto

// MARK: - 凭证提交审计日志
//
// 对应原作 `AICredentialJournalStore` + `AICredentialCommitCoordinator`（规格 09 §1 / B4）。
//
// 安全约束：审计日志**只记录动作与指纹，绝不落地明文密钥**。
//   · 指纹 = 密钥 SHA-256 的前 12 个十六进制字符，仅用于「是否同一把 key」的比对；
//   · 追加写入 $ApplicationSupport/FrsetNext/ai-credential-journal.jsonl（权限 0600）；
//   · 每行一个 JSON 对象（JSON Lines），便于追加与人工排查，损坏行会被跳过而非整体失败。
//
// 用途：用户反馈「我的 key 是不是被覆盖了」时可回溯提交历史；也满足规格 B4 的审计要求。

public struct AICredentialJournalEntry: Codable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable {
        case save, remove, clear
    }

    public let id: String
    public let timestamp: Date
    /// 厂商 rawValue（clear 动作用 "*"）
    public let provider: String
    public let action: Action
    /// 密钥指纹（前 12 位十六进制）；删除/清空时为 nil
    public let fingerprint: String?

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                provider: String,
                action: Action,
                fingerprint: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.action = action
        self.fingerprint = fingerprint
    }
}

public final class AICredentialJournalStore {
    public static let shared = AICredentialJournalStore()

    /// 单文件最多保留的条目数（超出时保留最新的若干条，避免无限增长）
    public static let maxEntries = 500

    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppDirectories.base.appendingPathComponent("ai-credential-journal.jsonl")
    }

    /// 记录一次凭证提交（secret 仅用于计算指纹，不会写入文件）
    public func record(action: AICredentialJournalEntry.Action,
                       provider: LLMProviderKind,
                       secret: String? = nil) {
        record(action: action, providerRaw: provider.rawValue, secret: secret)
    }

    /// 记录一次全局动作（如清空全部凭证）
    public func recordGlobal(action: AICredentialJournalEntry.Action) {
        record(action: action, providerRaw: "*", secret: nil)
    }

    /// 读取最近 n 条（时间升序返回）
    public func entries(limit: Int = 200) -> [AICredentialJournalEntry] {
        lock.lock(); defer { lock.unlock() }
        let all = Self.loadAll(fileURL: fileURL)
        guard limit < all.count else { return all }
        return Array(all.suffix(limit))
    }

    public func clear() {
        lock.lock()
        try? FileManager.default.removeItem(at: fileURL)
        lock.unlock()
    }

    // MARK: - 私有

    private func record(action: AICredentialJournalEntry.Action,
                        providerRaw: String,
                        secret: String?) {
        let fp = secret.flatMap { $0.isEmpty ? nil : Self.fingerprint($0) }
        let entry = AICredentialJournalEntry(provider: providerRaw, action: action, fingerprint: fp)
        lock.lock()
        var lines = Self.loadAll(fileURL: fileURL)
        lines.append(entry)
        if lines.count > Self.maxEntries { lines = Array(lines.suffix(Self.maxEntries)) }
        let text = lines.compactMap { Self.encodeLine($0) }.joined(separator: "\n")
        do {
            try (text + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.error("Credential", "写入审计日志失败：\(error.localizedDescription)")
        }
        lock.unlock()
    }

    private static func encodeLine(_ entry: AICredentialJournalEntry) -> String? {
        guard let data = try? JSONEncoder().encode(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func loadAll(fileURL: URL) -> [AICredentialJournalEntry] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AICredentialJournalEntry.self, from: data)
        }
    }

    /// SHA-256 前 12 位十六进制（用系统 CommonCrypto，避免自研哈希的实现风险）
    private static func fingerprint(_ secret: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let bytes = Array(secret.utf8)
        CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 凭证提交协调器（写入 + 审计的单一入口）

public final class AICredentialCommitCoordinator {
    public static let shared = AICredentialCommitCoordinator()

    public let store: LLMCredentialStoring
    public let journal: AICredentialJournalStore

    public init(store: LLMCredentialStoring = CredentialStore.shared,
                journal: AICredentialJournalStore = .shared) {
        self.store = store
        self.journal = journal
    }

    /// 提交凭证：空值等价于删除；成功后记录审计日志
    public func commit(_ value: String?, for provider: LLMProviderKind) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            store.setCredential(nil, for: provider)
            journal.record(action: .remove, provider: provider)
        } else {
            store.setCredential(trimmed, for: provider)
            journal.record(action: .save, provider: provider, secret: trimmed)
        }
    }

    public func remove(for provider: LLMProviderKind) {
        store.removeCredential(for: provider)
        journal.record(action: .remove, provider: provider)
    }

    public func clearAll() {
        store.clear()
        journal.recordGlobal(action: .clear)
    }
}
