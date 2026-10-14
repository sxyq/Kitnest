import Foundation

// MARK: - 查询条件

public struct ClipboardQuery {
    public var search: String = ""
    public var type: ClipboardItemType? = nil
    /// 仅笔记条目（is_note=1，05 号规格 B6：笔记走同一张表）
    public var noteOnly: Bool = false
    /// 仅工具回流条目（is_generated_by_tool=1，05 号规格 B10）
    public var toolGeneratedOnly: Bool = false
    public var tagID: String? = nil
    public var limit: Int = ClipboardRepository.defaultPageSize
    public var offset: Int = 0

    public init(search: String = "",
                type: ClipboardItemType? = nil,
                noteOnly: Bool = false,
                toolGeneratedOnly: Bool = false,
                tagID: String? = nil,
                limit: Int = ClipboardRepository.defaultPageSize,
                offset: Int = 0) {
        self.search = search
        self.type = type
        self.noteOnly = noteOnly
        self.toolGeneratedOnly = toolGeneratedOnly
        self.tagID = tagID
        self.limit = limit
        self.offset = offset
    }
}

// MARK: - 仓储层

/// clipboard_items 的全部 SQL 收敛在这里；所有值一律走 SQLiteValue 绑定（防注入）。
/// 本类无可变状态，底层 SQLiteDatabase 为 FULLMUTEX 连接，因此可安全跨线程共享。
public final class ClipboardRepository: @unchecked Sendable {

    public static let shared = ClipboardRepository()
    /// 主列表分页大小（UI 有 `loadMore`，默认 200）
    public static let defaultPageSize = 200

    private let db: SQLiteDatabase = DatabaseManager.shared.clipboard

    private static let columns = """
        id, type, content, title, subtitle, timestamp, source_app, image_path, thumbnail_path,
        is_generated_by_tool, is_note, source_tool_analytics_id, source_tool_keyword, text_path,
        rich_text_path, full_text_char_count, full_text_line_count, source_input, file_icon_key,
        image_dimension_unit, payload_key, storage_bytes, dedupe_key, alias_title
        """

    // MARK: 读

    public func fetch(_ query: ClipboardQuery) -> [ClipboardItem] {
        var sql = "SELECT \(Self.columns) FROM clipboard_items"
        var values: [SQLiteValue] = []
        var clauses: [String] = []

        if let type = query.type {
            clauses.append("type = ?")
            values.append(.text(type.rawValue))
        }
        if query.noteOnly { clauses.append("is_note = 1") }
        if query.toolGeneratedOnly { clauses.append("is_generated_by_tool = 1") }
        if let tagID = query.tagID {
            clauses.append(#"dedupe_key IN (SELECT item_dedupe_key FROM clipboard_item_tags WHERE tag_id = ?)"#)
            values.append(.text(tagID))
        }
        if !query.search.isEmpty {
            let pattern = SQLiteValue.text("%" + Self.escapeLike(query.search) + "%")
            var conditions = [#"content LIKE ? ESCAPE '\'"#, #"title LIKE ? ESCAPE '\'"#, #"alias_title LIKE ? ESCAPE '\'"#]
            values.append(contentsOf: [pattern, pattern, pattern])
            // B11：搜索同样覆盖图片条目的 OCR 文本（OCR 结果以文件落盘，见 ClipboardOCRTextStorage）
            let ocrKeys = ClipboardOCRTextStorage.matchingDedupeKeys(query: query.search)
            if !ocrKeys.isEmpty {
                let placeholders = Array(repeating: "?", count: ocrKeys.count).joined(separator: ",")
                conditions.append("dedupe_key IN (\(placeholders))")
                values.append(contentsOf: ocrKeys.map { SQLiteValue.text($0) })
            }
            clauses.append("(" + conditions.joined(separator: " OR ") + ")")
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY timestamp DESC LIMIT ? OFFSET ?"
        values.append(contentsOf: [.int(Int64(query.limit)), .int(Int64(query.offset))])

        do {
            let rows = try db.query(sql, values)
            var items = rows.map(Self.makeItem)
            TagStore.shared.attachTags(to: &items)
            return items
        } catch {
            Log.error("clipboard", "查询失败: \(error)")
            return []
        }
    }

    public func count(_ query: ClipboardQuery) -> Int {
        var sql = "SELECT COUNT(*) AS n FROM clipboard_items"
        var values: [SQLiteValue] = []
        var clauses: [String] = []
        if let type = query.type { clauses.append("type = ?"); values.append(.text(type.rawValue)) }
        if query.noteOnly { clauses.append("is_note = 1") }
        if query.toolGeneratedOnly { clauses.append("is_generated_by_tool = 1") }
        if let tagID = query.tagID {
            clauses.append(#"dedupe_key IN (SELECT item_dedupe_key FROM clipboard_item_tags WHERE tag_id = ?)"#)
            values.append(.text(tagID))
        }
        if !query.search.isEmpty {
            let pattern = SQLiteValue.text("%" + Self.escapeLike(query.search) + "%")
            var conditions = [#"content LIKE ? ESCAPE '\'"#, #"title LIKE ? ESCAPE '\'"#, #"alias_title LIKE ? ESCAPE '\'"#]
            values.append(contentsOf: [pattern, pattern, pattern])
            // B11：搜索同样覆盖图片条目的 OCR 文本（OCR 结果以文件落盘，见 ClipboardOCRTextStorage）
            let ocrKeys = ClipboardOCRTextStorage.matchingDedupeKeys(query: query.search)
            if !ocrKeys.isEmpty {
                let placeholders = Array(repeating: "?", count: ocrKeys.count).joined(separator: ",")
                conditions.append("dedupe_key IN (\(placeholders))")
                values.append(contentsOf: ocrKeys.map { SQLiteValue.text($0) })
            }
            clauses.append("(" + conditions.joined(separator: " OR ") + ")")
        }
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        return Int((try? db.scalarInt(sql, values)) ?? 0)
    }

    /// 按去重键取条目（去重命中 / 编辑前刷新用）
    public func item(dedupeKey: String) -> ClipboardItem? {
        guard let row = try? db.query(
            "SELECT \(Self.columns) FROM clipboard_items WHERE dedupe_key = ? LIMIT 1",
            [.text(dedupeKey)]).first else { return nil }
        var items = [Self.makeItem(row)]
        TagStore.shared.attachTags(to: &items)
        return items.first
    }

    public func exists(dedupeKey: String) -> Bool {
        ((try? db.scalarInt("SELECT COUNT(*) FROM clipboard_items WHERE dedupe_key = ?", [.text(dedupeKey)])) ?? 0) > 0
    }

    // MARK: 写

    /// 新增条目（字段与 schema 严格对应）
    public func insert(_ item: ClipboardItem) -> Bool {
        let sql = """
            INSERT INTO clipboard_items (
                id, type, content, title, subtitle, timestamp, source_app, image_path, thumbnail_path,
                is_generated_by_tool, is_note, source_tool_analytics_id, source_tool_keyword, text_path,
                rich_text_path, full_text_char_count, full_text_line_count, source_input, file_icon_key,
                image_dimension_unit, payload_key, storage_bytes, dedupe_key, alias_title
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        do {
            try db.run(sql, Self.bindings(item))
            return true
        } catch {
            // UNIQUE(dedupe_key) 冲突按"已存在"处理，交给上层刷新时间戳
            Log.warn("clipboard", "插入失败（可能去重冲突）: \(error)")
            return false
        }
    }

    /// 重复内容：更新时间戳置顶（去重置顶，05 号规格 B2）
    public func touch(dedupeKey: String, timestamp: Date = Date()) {
        try? db.run("UPDATE clipboard_items SET timestamp = ? WHERE dedupe_key = ?",
                    [.real(timestamp.timeIntervalSince1970), .text(dedupeKey)])
    }

    /// 编辑保存：回写 content + 长文本落盘元数据 + 占用统计
    public func updateContent(dedupeKey: String,
                              content: String,
                              textPath: String?,
                              charCount: Int?,
                              lineCount: Int?,
                              storageBytes: Int) {
        try? db.run("""
            UPDATE clipboard_items
               SET content = ?, text_path = ?, full_text_char_count = ?,
                   full_text_line_count = ?, storage_bytes = ?, title = ?
             WHERE dedupe_key = ?
            """, [.text(content),
                  textPath.map { SQLiteValue.text($0) } ?? .null,
                  charCount.map { SQLiteValue.int(Int64($0)) } ?? .null,
                  lineCount.map { SQLiteValue.int(Int64($0)) } ?? .null,
                  .int(Int64(storageBytes)),
                  .text(content.firstLineBrief),
                  .text(dedupeKey)])
    }

    /// 重命名（alias_title）
    public func updateAliasTitle(dedupeKey: String, aliasTitle: String?) {
        if let alias = aliasTitle, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? db.run("UPDATE clipboard_items SET alias_title = ? WHERE dedupe_key = ?",
                        [.text(alias), .text(dedupeKey)])
        } else {
            try? db.run("UPDATE clipboard_items SET alias_title = NULL WHERE dedupe_key = ?", [.text(dedupeKey)])
        }
    }

    /// 更新富文本 / 图片 / 通用字段（工具回流与 OCR 后回填用）
    public func updateFields(dedupeKey: String, richTextPath: String? = nil, imagePath: String? = nil,
                             thumbnailPath: String? = nil, storageBytes: Int? = nil, note: Bool? = nil) {
        if let richTextPath {
            try? db.run("UPDATE clipboard_items SET rich_text_path = ? WHERE dedupe_key = ?",
                        [.text(richTextPath), .text(dedupeKey)])
        }
        if let imagePath {
            try? db.run("UPDATE clipboard_items SET image_path = ? WHERE dedupe_key = ?",
                        [.text(imagePath), .text(dedupeKey)])
        }
        if let thumbnailPath {
            try? db.run("UPDATE clipboard_items SET thumbnail_path = ? WHERE dedupe_key = ?",
                        [.text(thumbnailPath), .text(dedupeKey)])
        }
        if let storageBytes {
            try? db.run("UPDATE clipboard_items SET storage_bytes = ? WHERE dedupe_key = ?",
                        [.int(Int64(storageBytes)), .text(dedupeKey)])
        }
        if let note {
            try? db.run("UPDATE clipboard_items SET is_note = ? WHERE dedupe_key = ?",
                        [.int(note ? 1 : 0), .text(dedupeKey)])
        }
    }

    // MARK: 删

    /// 删除条目并回收其全部落盘文件
    @discardableResult
    public func delete(dedupeKey: String) -> Bool {
        guard let row = try? db.query(
            "SELECT image_path, thumbnail_path, text_path, rich_text_path FROM clipboard_items WHERE dedupe_key = ? LIMIT 1",
            [.text(dedupeKey)]).first else { return false }
        do {
            try db.transaction { database in
                try database.run("DELETE FROM clipboard_items WHERE dedupe_key = ?", [.text(dedupeKey)])
                try database.run("DELETE FROM clipboard_item_tags WHERE item_dedupe_key = ?", [.text(dedupeKey)])
            }
        } catch {
            Log.error("clipboard", "删除失败: \(error)")
            return false
        }
        ClipboardFileStore.remove(row.string("image_path"))
        ClipboardFileStore.remove(row.string("thumbnail_path"))
        ClipboardFileStore.remove(row.string("text_path"))
        ClipboardFileStore.remove(row.string("rich_text_path"))
        ClipboardOCRTextStorage.remove(dedupeKey: dedupeKey)
        return true
    }

    // MARK: 清理辅助（双调度器共用）

    /// 早于 cutoff 的条目（时间保留期用）
    public func rowsOlderThan(_ cutoff: Date, limit: Int = 200) -> [ClipboardItem] {
        let rows = (try? db.query(
            "SELECT \(Self.columns) FROM clipboard_items WHERE timestamp < ? ORDER BY timestamp ASC LIMIT ?",
            [.real(cutoff.timeIntervalSince1970), .int(Int64(limit))])) ?? []
        return rows.map(Self.makeItem)
    }

    /// 最旧的若干条（容量超限用）
    public func oldestRows(limit: Int = 200) -> [ClipboardItem] {
        let rows = (try? db.query(
            "SELECT \(Self.columns) FROM clipboard_items ORDER BY timestamp ASC LIMIT ?",
            [.int(Int64(limit))])) ?? []
        return rows.map(Self.makeItem)
    }

    public func totalStorageBytes() -> Int64 {
        (try? db.scalarInt("SELECT COALESCE(SUM(storage_bytes), 0) FROM clipboard_items")) ?? 0
    }

    public func deleteAll(dedupeKeys: [String]) {
        guard !dedupeKeys.isEmpty else { return }
        try? db.transaction { database in
            for key in dedupeKeys {
                try? database.run("DELETE FROM clipboard_items WHERE dedupe_key = ?", [.text(key)])
                try? database.run("DELETE FROM clipboard_item_tags WHERE item_dedupe_key = ?", [.text(key)])
            }
        }
    }

    // MARK: 映射

    public static func makeItem(_ row: [String: SQLiteValue]) -> ClipboardItem {
        let type = ClipboardItemType(rawValue: row.string("type") ?? "text") ?? .text
        return ClipboardItem(
            id: row.string("id") ?? UUID().uuidString,
            type: type,
            content: row.string("content"),
            title: row.string("title"),
            subtitle: row.string("subtitle"),
            timestamp: Date(timeIntervalSince1970: row.real("timestamp")),
            sourceApp: row.string("source_app"),
            imagePath: row.string("image_path"),
            thumbnailPath: row.string("thumbnail_path"),
            isGeneratedByTool: row.bool("is_generated_by_tool"),
            isNote: row.bool("is_note"),
            sourceToolAnalyticsId: row.string("source_tool_analytics_id"),
            sourceToolKeyword: row.string("source_tool_keyword"),
            textPath: row.string("text_path"),
            richTextPath: row.string("rich_text_path"),
            fullTextCharCount: row.int("full_text_char_count") > 0 ? Int(row.int("full_text_char_count")) : nil,
            fullTextLineCount: row.int("full_text_line_count") > 0 ? Int(row.int("full_text_line_count")) : nil,
            sourceInput: row.string("source_input"),
            fileIconKey: row.string("file_icon_key"),
            imageDimensionUnit: row.string("image_dimension_unit"),
            payloadKey: row.string("payload_key"),
            storageBytes: Int(row.int("storage_bytes")),
            dedupeKey: row.string("dedupe_key") ?? "",
            aliasTitle: row.string("alias_title"),
            tagIDs: []
        )
    }

    public static func bindings(_ item: ClipboardItem) -> [SQLiteValue] {
        func optionalInt(_ v: Int?) -> SQLiteValue { v.map { SQLiteValue.int(Int64($0)) } ?? .null }
        func optionalText(_ v: String?) -> SQLiteValue { v.map { SQLiteValue.text($0) } ?? .null }
        return [
            .text(item.id),
            .text(item.type.rawValue),
            optionalText(item.content),
            optionalText(item.title),
            optionalText(item.subtitle),
            .real(item.timestamp.timeIntervalSince1970),
            optionalText(item.sourceApp),
            optionalText(item.imagePath),
            optionalText(item.thumbnailPath),
            .int(item.isGeneratedByTool ? 1 : 0),
            .int(item.isNote ? 1 : 0),
            optionalText(item.sourceToolAnalyticsId),
            optionalText(item.sourceToolKeyword),
            optionalText(item.textPath),
            optionalText(item.richTextPath),
            optionalInt(item.fullTextCharCount),
            optionalInt(item.fullTextLineCount),
            optionalText(item.sourceInput),
            optionalText(item.fileIconKey),
            optionalText(item.imageDimensionUnit),
            optionalText(item.payloadKey),
            .int(Int64(item.storageBytes)),
            .text(item.dedupeKey),
            optionalText(item.aliasTitle)
        ]
    }

    /// LIKE 转义：屏蔽用户输入的通配符，保证"所见即所搜"
    static func escapeLike(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case "%":  out += "\\%"
            case "_":  out += "\\_"
            default:   out.append(ch)
            }
        }
        return out
    }
}

// MARK: - 标题摘要（与读取器口径保持一致）

extension String {
    /// 首行摘要作为 title
    var firstLineBrief: String {
        let line = split(separator: "\n").first.map(String.init) ?? self
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 80 { return String(s.prefix(80)) + "…" }
        return s.isEmpty ? (self.isEmpty ? "" : String(self.prefix(80))) : s
    }
}
