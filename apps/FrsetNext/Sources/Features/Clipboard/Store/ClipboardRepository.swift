import Foundation

// MARK: - 查询条件

public struct ClipboardQuery {
    public var search: String = ""
    public var type: ClipboardItemType? = nil
    /// 仅笔记条目（is_note=1，05 号规格 B6：笔记走同一张表）
    public var noteOnly: Bool = false
    /// 仅工具回流条目（is_generated_by_tool=1，05 号规格 B10）
    public var toolGeneratedOnly: Bool = false
    /// 工具回流来源关键词（过滤项 .color → "colorpicker"；specs/14 §6，证据不足取来源映射）
    public var generatedSourceKeyword: String? = nil
    /// 代码特征启发式（过滤项 .code；原作为内容特征分类，specs/14 §7 规则未探明，此为 SQL 级近似）
    public var codeLikeOnly: Bool = false
    /// 链接特征：同时命中 type='url' 与「纯文本但内容是链接」的历史条目
    /// （v202：复制链接时系统粘贴板同时带 .string，旧读取逻辑把它存成了 text，
    /// 「链接」分类因此漏掉绝大多数历史数据）
    public var urlLikeOnly: Bool = false
    public var tagID: String? = nil
    public var limit: Int = ClipboardRepository.defaultPageSize
    public var offset: Int = 0

    public init(search: String = "",
                type: ClipboardItemType? = nil,
                noteOnly: Bool = false,
                toolGeneratedOnly: Bool = false,
                generatedSourceKeyword: String? = nil,
                codeLikeOnly: Bool = false,
                urlLikeOnly: Bool = false,
                tagID: String? = nil,
                limit: Int = ClipboardRepository.defaultPageSize,
                offset: Int = 0) {
        self.search = search
        self.type = type
        self.noteOnly = noteOnly
        self.toolGeneratedOnly = toolGeneratedOnly
        self.generatedSourceKeyword = generatedSourceKeyword
        self.codeLikeOnly = codeLikeOnly
        self.urlLikeOnly = urlLikeOnly
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

    private static func appendClauses(_ query: ClipboardQuery, clauses: inout [String], values: inout [SQLiteValue]) {
        if let type = query.type {
            clauses.append("type = ?")
            values.append(.text(type.rawValue))
        }
        if query.noteOnly { clauses.append("is_note = 1") }
        if query.toolGeneratedOnly { clauses.append("is_generated_by_tool = 1") }
        if let keyword = query.generatedSourceKeyword {
            clauses.append("source_tool_keyword = ?")
            values.append(.text(keyword))
        }
        if query.urlLikeOnly {
            // v202：链接分类 = 原始 .url 条目 + 内容本身是链接的文本条目
            clauses.append("""
                (type = 'url'
                 OR content LIKE 'http://%'
                 OR content LIKE 'https://%'
                 OR content LIKE 'www.%')
                """)
        }
        if query.codeLikeOnly {
            // v202：代码过滤收紧——必须多行，且命中代码特征；
            // 旧规则只要出现 `;` 或 `{` 就把整段文案算代码，误判太多。
            // 单行极短代码（如 `let a = 1`）不再进代码分类，优先保证准确率。
            clauses.append("""
                (instr(content, char(10)) > 0
                 AND (content LIKE '%func %'
                      OR content LIKE '%class %'
                      OR content LIKE '%struct %'
                      OR content LIKE '%import %'
                      OR content LIKE '%def %'
                      OR content LIKE '%const %'
                      OR content LIKE '%let %'
                      OR content LIKE '%var %'
                      OR content LIKE '%function %'
                      OR content LIKE '%=>%'
                      OR content LIKE '%</%'
                      OR content LIKE '%<?php%'
                      OR content LIKE '%#include%'
                      OR content LIKE '%SELECT %'
                      OR content LIKE '%{%'))
                """)
        }
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
    }

    // MARK: 读

    public func fetch(_ query: ClipboardQuery) -> [ClipboardItem] {
        var sql = "SELECT \(Self.columns) FROM clipboard_items"
        var values: [SQLiteValue] = []
        var clauses: [String] = []
        Self.appendClauses(query, clauses: &clauses, values: &values)
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
        Self.appendClauses(query, clauses: &clauses, values: &values)
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
    /// v126（性能审计 F0660）：逐字符 `out +=` 改 Array + join（Swift String 拼接是 O(n²) 放大）
    static func escapeLike(_ text: String) -> String {
        var out = [Character]()
        out.reserveCapacity(text.count + 8)
        for ch in text {
            switch ch {
            case "\\": out.append(contentsOf: "\\\\")
            case "%":  out.append(contentsOf: "\\%")
            case "_":  out.append(contentsOf: "\\_")
            default:   out.append(ch)
            }
        }
        return String(out)
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
