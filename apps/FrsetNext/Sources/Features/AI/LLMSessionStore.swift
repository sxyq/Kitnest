import Foundation

// MARK: - 会话持久化
//
// 复用 Storage 已建好的 llm_sessions / llm_messages 两张表（schema 见 Storage/Database.swift），
// 不新建任何表，避免与其它模块抢 schema。

public final class LLMSessionStore {
    public static let shared = LLMSessionStore()

    private var db: SQLiteDatabase { DatabaseManager.shared.clipboard }

    public init() {}

    // MARK: 会话

    /// 新建会话
    @discardableResult
    public func createSession(title: String = "新会话",
                              provider: LLMProviderKind = AISettings.providerKind,
                              model: String? = nil) -> LLMChatSession {
        let now = Date()
        let session = LLMChatSession(title: title,
                                     messages: [],
                                     provider: provider,
                                     model: model ?? AISettings.selectedModel,
                                     createdAt: now,
                                     updatedAt: now)
        do {
            try db.run("""
                INSERT INTO llm_sessions(id, title, provider, model, created_at, updated_at)
                VALUES(?,?,?,?,?,?);
                """, [.text(session.id), .text(session.title), .text(session.provider.rawValue),
                      .text(session.model ?? ""), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        } catch {
            Log.error("AI", "新建会话失败：\(error.localizedDescription)")
        }
        return session
    }

    /// 会话列表（不含消息体，避免一次性拉全文）
    public func listSessions(limit: Int = 50) -> [LLMChatSession] {
        guard let rows = try? db.query("""
            SELECT id, title, provider, model, created_at, updated_at
            FROM llm_sessions ORDER BY updated_at DESC LIMIT ?;
            """, [.int(Int64(limit))]) else { return [] }
        return rows.compactMap { row in
            guard let id = row.string("id") else { return nil }
            let created = Date(timeIntervalSince1970: row.real("created_at"))
            let updated = Date(timeIntervalSince1970: row.real("updated_at"))
            return LLMChatSession(id: id,
                                  title: row.string("title") ?? "新会话",
                                  messages: [],
                                  provider: LLMProviderKind(rawValue: row.string("provider") ?? "") ?? .anthropic,
                                  model: row.string("model"),
                                  createdAt: created,
                                  updatedAt: updated)
        }
    }

    /// 读取单个会话（含消息）
    public func loadSession(id: String) -> LLMChatSession? {
        guard let rows = try? db.query("""
            SELECT id, title, provider, model, created_at, updated_at
            FROM llm_sessions WHERE id = ?;
            """, [.text(id)]), let row = rows.first else { return nil }
        var session = LLMChatSession(id: id,
                                     title: row.string("title") ?? "新会话",
                                     messages: [],
                                     provider: LLMProviderKind(rawValue: row.string("provider") ?? "") ?? .anthropic,
                                     model: row.string("model"),
                                     createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                                     updatedAt: Date(timeIntervalSince1970: row.real("updated_at")))
        session.messages = messages(for: id)
        return session
    }

    /// 重命名
    public func renameSession(id: String, title: String) {
        do {
            try db.run("UPDATE llm_sessions SET title = ?, updated_at = ? WHERE id = ?;",
                       [.text(title), .real(Date().timeIntervalSince1970), .text(id)])
        } catch {
            Log.error("AI", "重命名会话失败：\(error.localizedDescription)")
        }
    }

    /// 更新会话使用的模型
    public func updateSession(id: String, model: String) {
        do {
            try db.run("UPDATE llm_sessions SET model = ? WHERE id = ?;", [.text(model), .text(id)])
        } catch {
            Log.error("AI", "更新会话模型失败：\(error.localizedDescription)")
        }
    }

    /// 删除会话（外键级联删除消息）
    public func deleteSession(id: String) {
        do {
            try db.run("DELETE FROM llm_messages WHERE session_id = ?;", [.text(id)])
            try db.run("DELETE FROM llm_sessions WHERE id = ?;", [.text(id)])
        } catch {
            Log.error("AI", "删除会话失败：\(error.localizedDescription)")
        }
    }

    /// 清空全部会话
    public func clearAll() {
        do {
            try db.transaction { database in
                try database.run("DELETE FROM llm_messages;")
                try database.run("DELETE FROM llm_sessions;")
            }
        } catch {
            Log.error("AI", "清空会话失败：\(error.localizedDescription)")
        }
    }

    // MARK: 消息

    @discardableResult
    public func appendMessage(sessionID: String, role: LLMMessage.Role, content: String) -> LLMMessage {
        let message = LLMMessage(role: role, content: content)
        let now = Date().timeIntervalSince1970
        do {
            try db.run("""
                INSERT INTO llm_messages(id, session_id, role, content, created_at)
                VALUES(?,?,?,?,?);
                """, [.text(message.id), .text(sessionID), .text(role.rawValue), .text(content), .real(now)])
            try db.run("UPDATE llm_sessions SET updated_at = ? WHERE id = ?;", [.real(now), .text(sessionID)])
        } catch {
            Log.error("AI", "追加消息失败：\(error.localizedDescription)")
        }
        return message
    }

    public func messages(for sessionID: String) -> [LLMMessage] {
        guard let rows = try? db.query("""
            SELECT id, role, content, created_at FROM llm_messages
            WHERE session_id = ? ORDER BY created_at ASC;
            """, [.text(sessionID)]) else { return [] }
        return rows.compactMap { row in
            guard let id = row.string("id"), let roleRaw = row.string("role"),
                  let role = LLMMessage.Role(rawValue: roleRaw) else { return nil }
            return LLMMessage(id: id, role: role, content: row.string("content") ?? "")
        }
    }

    /// 首次有用户发言时，用发言内容自动命名会话（模仿常见聊天产品的行为）
    public func autoTitle(sessionID: String, from content: String) {
        guard let rows = try? db.query("SELECT title FROM llm_sessions WHERE id = ?;", [.text(sessionID)]),
              let title = rows.first?.string("title"), title == "新会话" || title.isEmpty else { return }
        let cut = content.replacingOccurrences(of: "\n", with: " ")
        let shortened = cut.count > 24 ? String(cut.prefix(24)) + "…" : cut
        guard !shortened.isEmpty else { return }
        renameSession(id: sessionID, title: shortened)
    }

    // MARK: - 全局搜索（供总控在 App 层注册检索源）

    /// 在所有会话的标题与消息内容中做子串匹配。
    /// 本方法只返回 AI 侧的中立结果类型，**不引用任何其它模块的搜索类型**（契约 §1.3）；
    /// 由总控在 App 层把它映射成检索框架的条目并注册（与剪贴板源的做法一致）。
    public func searchSessions(query: String, limit: Int = 8) -> [LLMSessionSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let pattern = Self.likePattern(q)
        guard let rows = try? db.query("""
            SELECT id, title, updated_at FROM llm_sessions
            WHERE title LIKE ? ESCAPE '\\'
               OR id IN (SELECT session_id FROM llm_messages WHERE content LIKE ? ESCAPE '\\')
            ORDER BY updated_at DESC LIMIT ?;
            """, [.text(pattern), .text(pattern), .int(Int64(limit))]) else { return [] }

        return rows.compactMap { row -> LLMSessionSearchHit? in
            guard let id = row.string("id") else { return nil }
            let title = row.string("title") ?? "新会话"
            let matchesTitle = title.range(of: q, options: .caseInsensitive) != nil
            var snippet = ""
            var role: LLMMessage.Role?
            if !matchesTitle, let hit = firstMatchingMessage(sessionID: id, pattern: pattern, query: q) {
                snippet = hit.snippet
                role = hit.role
            }
            return LLMSessionSearchHit(id: id,
                                       title: title,
                                       snippet: snippet,
                                       role: role,
                                       matchesTitle: matchesTitle,
                                       updatedAt: Date(timeIntervalSince1970: row.real("updated_at")))
        }
    }

    private func firstMatchingMessage(sessionID: String,
                                      pattern: String,
                                      query: String) -> (snippet: String, role: LLMMessage.Role)? {
        guard let rows = try? db.query("""
            SELECT content, role FROM llm_messages
            WHERE session_id = ? AND content LIKE ? ESCAPE '\\'
            ORDER BY created_at ASC LIMIT 1;
            """, [.text(sessionID), .text(pattern)]),
              let row = rows.first,
              let content = row.string("content") else { return nil }
        return (Self.snippet(from: content, around: query),
                row.string("role").flatMap(LLMMessage.Role.init(rawValue:)) ?? .assistant)
    }

    /// 把用户输入转成 LIKE 模式，转义 `%` `_` `\` 通配符，避免误匹配
    private static func likePattern(_ query: String) -> String {
        var escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "%", with: "\\%")
        escaped = escaped.replacingOccurrences(of: "_", with: "\\_")
        return "%" + escaped + "%"
    }

    /// 截取命中词前后的一段上下文作为摘要
    private static func snippet(from content: String, around query: String, radius: Int = 30) -> String {
        let flat = content.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: query, options: .caseInsensitive) else {
            return flat.count > radius * 2 ? String(flat.prefix(radius * 2)) + "…" : flat
        }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var text = String(flat[start..<end])
        if start != flat.startIndex { text = "…" + text }
        if end != flat.endIndex { text += "…" }
        return text
    }
}

// MARK: - 搜索结果（AI 侧中立类型）

/// 会话搜索结果。总控在 App 层把它映射为检索框架的条目（避免 AI 模块引用其它模块的搜索类型）。
public struct LLMSessionSearchHit: Identifiable, Sendable {
    public let id: String          // 会话 id
    public let title: String
    public let snippet: String     // 命中的消息片段；标题命中时为空串
    public let role: LLMMessage.Role?
    public let matchesTitle: Bool
    public let updatedAt: Date

    public init(id: String, title: String, snippet: String,
                role: LLMMessage.Role?, matchesTitle: Bool, updatedAt: Date) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.role = role
        self.matchesTitle = matchesTitle
        self.updatedAt = updatedAt
    }
}
