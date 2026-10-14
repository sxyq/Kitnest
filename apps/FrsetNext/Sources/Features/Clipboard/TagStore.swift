import Foundation

// MARK: - 标签仓储（tags + clipboard_item_tags，05 号规格 B6）

/// 标签总管：CRUD + 分配 + 内存索引。
/// 说明：`tags.name` 上有 `UNIQUE COLLATE NOCASE`，重名插入会抛约束错误，
/// 这里捕获后返回同名既有标签（等价于 NSUniqueConstraint 的幂等 upsert 行为）。
public final class TagStore: ObservableObject {

    public static let shared = TagStore()

    @Published public private(set) var tags: [Tag] = []

    private let db: SQLiteDatabase = DatabaseManager.shared.clipboard
    /// dedupeKey -> tagID 列表（内存索引，避免每行一次 SQL）
    private var mapping: [String: [String]] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: 加载

    public func refresh() {
        do {
            let rows = try db.query("SELECT id, name, color_hex, created_at, updated_at FROM tags ORDER BY updated_at DESC")
            let loadedTags = rows.map { row -> Tag in
                Tag(id: row.string("id") ?? UUID().uuidString,
                    name: row.string("name") ?? "",
                    colorHex: row.string("color_hex") ?? "#8E8E93",
                    createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                    updatedAt: Date(timeIntervalSince1970: row.real("updated_at")))
            }
            let linkRows = try db.query(#"SELECT item_dedupe_key, tag_id FROM clipboard_item_tags"#)
            var loadedMapping: [String: [String]] = [:]
            for row in linkRows {
                guard let key = row.string("item_dedupe_key"), let tagID = row.string("tag_id") else { continue }
                loadedMapping[key, default: []].append(tagID)
            }
            lock.lock()
            self.mapping = loadedMapping
            lock.unlock()
            DispatchQueue.main.async { self.tags = loadedTags }
        } catch {
            Log.error("clipboard", "标签加载失败: \(error)")
        }
    }

    /// 给查询出来的条目填充 tagIDs（批量，无 N+1）
    public func attachTags(to items: inout [ClipboardItem]) {
        guard !items.isEmpty else { return }
        lock.lock()
        let snapshot = mapping
        lock.unlock()
        for index in items.indices {
            items[index].tagIDs = snapshot[items[index].dedupeKey] ?? []
        }
    }

    public func tags(for dedupeKey: String) -> [Tag] {
        lock.lock()
        let ids = Set(mapping[dedupeKey] ?? [])
        lock.unlock()
        return tags.filter { ids.contains($0.id) }
    }

    // MARK: 写

    @discardableResult
    public func create(name: String, colorHex: String = "#8E8E93") -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let tag = Tag(name: trimmed, colorHex: colorHex, createdAt: now, updatedAt: now)
        do {
            try db.run("INSERT INTO tags(id, name, color_hex, created_at, updated_at) VALUES (?,?,?,?,?)",
                       [.text(tag.id), .text(tag.name), .text(tag.colorHex),
                        .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            refresh()
            return tag
        } catch {
            // 重名（NOCASE）→ 返回既有标签
            Log.info("clipboard", "标签重名，复用既有: \(trimmed)")
            return tags.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
    }

    public func rename(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try db.run("UPDATE tags SET name = ?, updated_at = ? WHERE id = ?",
                       [.text(trimmed), .real(Date().timeIntervalSince1970), .text(id)])
        } catch { Log.warn("clipboard", "标签改名失败: \(error)") }
        refresh()
    }

    public func setColor(id: String, colorHex: String) {
        try? db.run("UPDATE tags SET color_hex = ?, updated_at = ? WHERE id = ?",
                    [.text(colorHex), .real(Date().timeIntervalSince1970), .text(id)])
        refresh()
    }

    public func delete(id: String) {
        // clipboard_item_tags 外键 ON DELETE CASCADE，关联行自动清理
        try? db.run("DELETE FROM tags WHERE id = ?", [.text(id)])
        refresh()
    }

    // MARK: 分配

    public func assign(tagID: String, toDedupeKey key: String) {
        try? db.run("INSERT OR IGNORE INTO clipboard_item_tags(item_dedupe_key, tag_id, created_at) VALUES (?,?,?)",
                    [.text(key), .text(tagID), .real(Date().timeIntervalSince1970)])
        refresh()
    }

    public func unassign(tagID: String, fromDedupeKey key: String) {
        try? db.run("DELETE FROM clipboard_item_tags WHERE item_dedupe_key = ? AND tag_id = ?", [.text(key), .text(tagID)])
        refresh()
    }

    /// 菜单勾选用：已分配则取消，否则分配
    public func toggle(tagID: String, dedupeKey: String) {
        lock.lock()
        let already = (mapping[dedupeKey] ?? []).contains(tagID)
        lock.unlock()
        if already { unassign(tagID: tagID, fromDedupeKey: dedupeKey) }
        else { assign(tagID: tagID, toDedupeKey: dedupeKey) }
    }

    /// 某标签下的全部条目去重键（过滤栏"按标签筛选"用）
    public func dedupeKeys(forTagID tagID: String) -> [String] {
        let rows = (try? db.query("SELECT item_dedupe_key FROM clipboard_item_tags WHERE tag_id = ?", [.text(tagID)])) ?? []
        return rows.compactMap { $0.string("item_dedupe_key") }
    }
}
