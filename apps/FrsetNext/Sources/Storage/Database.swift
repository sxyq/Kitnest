import Foundation
import SQLite3

// MARK: - 轻量 SQLite 封装（贴近原作：libsqlite3 直连，schema 与 clipboard.sqlite 对齐）

/// SQLITE_TRANSIENT 是 C 宏，Swift 不自动导入，这里手工构造
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteValue {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public struct DatabaseError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public final class SQLiteDatabase {
    public let path: String
    private var handle: OpaquePointer?

    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw DatabaseError(message: "open failed(\(rc)): \(msg)")
        }
        handle = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit { if let h = handle { sqlite3_close(h) } }

    public func exec(_ sql: String) throws {
        guard let h = handle else { throw DatabaseError(message: "db closed") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError(message: "exec failed: \(msg)\nSQL: \(sql)")
        }
    }

    private func bindValues(_ stmt: OpaquePointer?, _ values: [SQLiteValue]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null:        sqlite3_bind_null(stmt, idx)
            case .int(let n):  sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case .blob(let d): sqlite3_bind_blob(stmt, idx, (d as NSData).bytes, Int32(d.count), SQLITE_TRANSIENT)
            }
        }
    }

    public func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        guard let h = handle else { throw DatabaseError(message: "db closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DatabaseError(message: "prepare failed: \(String(cString: sqlite3_errmsg(h)))")
        }
        defer { sqlite3_finalize(s) }
        bindValues(s, values)
        if sqlite3_step(s) != SQLITE_DONE {
            throw DatabaseError(message: "step failed: \(String(cString: sqlite3_errmsg(h)))")
        }
    }

    public func lastInsertRowID() -> Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    public func query(_ sql: String, _ values: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        guard let h = handle else { throw DatabaseError(message: "db closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DatabaseError(message: "prepare failed: \(String(cString: sqlite3_errmsg(h)))")
        }
        defer { sqlite3_finalize(s) }
        bindValues(s, values)
        var rows: [[String: SQLiteValue]] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let count = sqlite3_column_count(s)
            var row: [String: SQLiteValue] = [:]
            for i in 0..<count {
                guard let cName = sqlite3_column_name(s, i) else { continue }
                let name = String(cString: cName)
                switch sqlite3_column_type(s, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(s, i))
                case SQLITE_FLOAT:   row[name] = .real(sqlite3_column_double(s, i))
                case SQLITE_TEXT:
                    if let p = sqlite3_column_text(s, i) { row[name] = .text(String(cString: p)) }
                    else { row[name] = .null }
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(s, i))
                    if let p = sqlite3_column_blob(s, i) { row[name] = .blob(Data(bytes: p, count: n)) }
                    else { row[name] = .null }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func scalarInt(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int64 {
        let rows = try query(sql, values)
        if case .int(let n)? = rows.first?.values.first { return n }
        return 0
    }

    /// 事务包装
    public func transaction<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try exec("BEGIN;")
        do {
            let r = try body(self)
            try exec("COMMIT;")
            return r
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }
}

// MARK: - 便捷取值

public extension Dictionary where Key == String, Value == SQLiteValue {
    func string(_ k: String) -> String? { if case .text(let s)? = self[k] { return s }; return nil }
    func int(_ k: String) -> Int64 { if case .int(let n)? = self[k] { return n }; return 0 }
    func real(_ k: String) -> Double { if case .real(let d)? = self[k] { return d }; return 0 }
    func bool(_ k: String) -> Bool { int(k) != 0 }
}

// MARK: - 数据库管理（schema 与实机 clipboard.sqlite 一致）

public final class DatabaseManager {
    public static let shared = DatabaseManager()

    public let clipboard: SQLiteDatabase
    public let statistics: SQLiteDatabase

    private init() {
        let base = AppDirectories.base
        do {
            clipboard = try SQLiteDatabase(path: base.appendingPathComponent("clipboard.sqlite").path)
            statistics = try SQLiteDatabase(path: base.appendingPathComponent("statistics.sqlite").path)
            try migrate()
        } catch {
            fatalError("DatabaseManager init failed: \(error)")
        }
    }

    private func migrate() throws {
        try clipboard.exec("""
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            content TEXT,
            title TEXT,
            subtitle TEXT,
            timestamp REAL NOT NULL,
            source_app TEXT,
            image_path TEXT,
            thumbnail_path TEXT,
            is_generated_by_tool INTEGER DEFAULT 0,
            is_note INTEGER DEFAULT 0,
            source_tool_analytics_id TEXT,
            source_tool_keyword TEXT,
            text_path TEXT,
            rich_text_path TEXT,
            full_text_char_count INTEGER,
            full_text_line_count INTEGER,
            source_input TEXT,
            file_icon_key TEXT,
            image_dimension_unit TEXT,
            payload_key TEXT,
            storage_bytes INTEGER DEFAULT 0,
            dedupe_key TEXT NOT NULL UNIQUE,
            alias_title TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_items_timestamp ON clipboard_items(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_items_type ON clipboard_items(type, timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_items_tool ON clipboard_items(is_generated_by_tool, timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_items_note ON clipboard_items(is_note, timestamp DESC);

        CREATE TABLE IF NOT EXISTS tags (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            color_hex TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_name ON tags(name COLLATE NOCASE);

        CREATE TABLE IF NOT EXISTS clipboard_item_tags (
            item_dedupe_key TEXT NOT NULL,
            tag_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (item_dedupe_key, tag_id),
            FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS file_type_icons (
            icon_key TEXT PRIMARY KEY,
            handler_bundle_id TEXT,
            icon_path TEXT,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS llm_sessions (
            id TEXT PRIMARY KEY,
            title TEXT,
            provider TEXT,
            model TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS llm_messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY (session_id) REFERENCES llm_sessions(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS tool_invocations (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            input TEXT,
            output TEXT,
            created_at REAL NOT NULL
        );
        """)

        try statistics.exec("""
        CREATE TABLE IF NOT EXISTS daily_stats (
            day TEXT PRIMARY KEY,
            capture_count INTEGER DEFAULT 0,
            screenshot_count INTEGER DEFAULT 0,
            ocr_count INTEGER DEFAULT 0,
            tool_count INTEGER DEFAULT 0,
            ai_request_count INTEGER DEFAULT 0
        );
        """)
    }

    // MARK: - 统计埋点

    public func bumpStat(_ column: String, day: String? = nil) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
        let d = day ?? fmt.string(from: Date())
        let allowed = Set(["capture_count", "screenshot_count", "ocr_count", "tool_count", "ai_request_count"])
        guard allowed.contains(column) else { return }
        try? statistics.exec("INSERT INTO daily_stats(day,\(column)) VALUES('\(d)',1) " +
            "ON CONFLICT(day) DO UPDATE SET \(column)=\(column)+1;")
    }
}
