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

        // spec 17 §0/§1b D7：原作为事件名驱动的窄表（重建早期臆测的 daily_stats 宽表必改）
        try statistics.exec("""
        CREATE TABLE IF NOT EXISTS usage_daily_metrics (
            day TEXT NOT NULL,
            event_name TEXT NOT NULL,
            count INTEGER NOT NULL,
            PRIMARY KEY (day, event_name)
        );
        CREATE INDEX IF NOT EXISTS idx_usage_daily_metrics_day ON usage_daily_metrics(day);
        CREATE TABLE IF NOT EXISTS app_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        migrateLegacyDailyStats()
    }

    /// 旧臆测宽表 daily_stats(day, capture_count, …) → 原作窄表 usage_daily_metrics 的一次性迁移：
    /// ① 列名映射为 spec 17 §4 事件名；② day 由 yyyyMMdd 规范为 yyyy-MM-dd（D7 实证格式）；
    /// ③ 迁移完 DROP 旧表。幂等：daily_stats 不存在时直接返回。
    private func migrateLegacyDailyStats() {
        let legacyRows = (try? statistics.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='daily_stats'")) ?? []
        guard !legacyRows.isEmpty else { return }
        let legacyMap: [(column: String, event: String)] = [
            ("capture_count", "clipboard_capture"),
            ("screenshot_count", "screenshot_capture"),
            ("ocr_count", "ocr_use"),
            ("tool_count", "tool_execute_success"),
            // 原作 59 键中无 AI 请求事件；保留为重建扩展事件名（不影响窄表结构）
            ("ai_request_count", "ai_request_count"),
        ]
        if let rows = try? statistics.query("SELECT * FROM daily_stats") {
            for r in rows {
                guard let rawDay = r.string("day") else { continue }
                let day = Self.normalizedDay(rawDay)
                for m in legacyMap where r.int(m.column) > 0 {
                    try? statistics.run(
                        "INSERT INTO usage_daily_metrics(day, event_name, count) VALUES(?,?,?) " +
                        "ON CONFLICT(day, event_name) DO UPDATE SET count = usage_daily_metrics.count + excluded.count",
                        [.text(day), .text(m.event), .int(r.int(m.column))])
                }
            }
        }
        try? statistics.exec("DROP TABLE IF EXISTS daily_stats;")
        Log.info("Database", "migrated legacy daily_stats → usage_daily_metrics")
    }

    /// day 串规范化：8 位 yyyyMMdd → yyyy-MM-dd；已是标准格式则原样返回
    static func normalizedDay(_ s: String) -> String {
        if s.count == 8, let d = Int(s) {
            return String(format: "%04d-%02d-%02d", d / 10000, (d / 100) % 100, d % 100)
        }
        return s
    }

    // MARK: - 统计埋点

    /// 旧列名 → spec 17 §4 事件名（bumpStat 公开签名保持不变，全工程调用点零改动）
    private static let legacyColumnEventMap: [String: String] = [
        "capture_count": "clipboard_capture",
        "screenshot_count": "screenshot_capture",
        "ocr_count": "ocr_use",
        "tool_count": "tool_execute_success",
        "ai_request_count": "ai_request_count",
    ]

    /// 兼容入口：签名保持不变，内部改走 StatisticsManager 窄表累加（spec 17 D7）
    public func bumpStat(_ column: String, day: String? = nil) {
        guard let event = Self.legacyColumnEventMap[column] else { return }
        let d = day.map(Self.normalizedDay) ?? StatisticsManager.dayString()
        StatisticsManager.shared.record(event, day: d)
    }
}

// MARK: - 埋点事件枚举（spec 17 §8：54 个枚举事件；另 5 个裸串事件直接字符串 record）

public enum AnalyticsEvent: String, CaseIterable {
    case panelOpen, historyCopy, autoPastePrompt, historyBatchCopy, historyEditSave
    case noteEditorOpen, noteCreateSuccess, noteSave, historyMultiSelect
    case historyBatchDelete, historyBatchTagAdd, historyBatchTagRemove
    case clipboardCapture, clipboardRecordingStateChange
    case searchExecute, toolExecuteSuccess, ocrUse, translationUse
    case webSearchOpen, browserOpen, screenshotCapture, colorPickSuccess
    case alwaysOnTopEnable, floatingClipboardActivate
    case networkInfoClick, activityMonitorClick
    case calendarExpand, calendarDayOpen, calendarDateSelect
    case calendarEventDetailOpen, calendarPermissionAction, calendarExternalOpen
    case settingsOpen, changelogClick, rateAppClick, rateAppRequest, helpFeedbackClick
    case settingsExportSuccess, settingsImportSuccess
    case proPageView, proPurchaseClick, proPurchaseSuccess, proPurchaseFailed
    case proRestoreSuccess, proRestoreFailed
    case whatsNewView, paywallView, paywallUpgradeClick, paywallUnlockOnceClick
    case paywallMaybeLaterClick, paywallIncludedClick, paywallTrialStart
    case statisticsOpen

    /// DB 事件名：camelCase → snake_case（historyCopy → history_copy）
    public var eventName: String {
        var out = ""
        out.reserveCapacity(rawValue.count + 4)
        for ch in rawValue {
            if ch.isUppercase {
                if !out.isEmpty { out.append("_") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - 统计管理器（原作 StatisticsManager：statistics.sqlite 窄表 + 串行队列 + 去重）

public final class StatisticsManager {
    public static let shared = StatisticsManager()

    /// 专用串行队列（spec 17 D2：com.frset.statistics.queue）
    private let queue = DispatchQueue(label: "com.frset.statistics.queue")
    /// statistics.sqlite（DatabaseManager 已打开并启用 WAL，D1）
    public let db: SQLiteDatabase
    /// 事件去重状态（D3：lastEventTime + dedupeWindows）
    private var lastEventTime: [String: Date] = [:]
    private var dedupeWindows: [String: TimeInterval] = [:]
    /// 操作组事件（screenshot/selection/tool/ocr 四组；spec 成员 ⬜，推断为高频操作事件）
    private static let operationEventNames: Set<String> = [
        AnalyticsEvent.clipboardCapture.eventName,
        AnalyticsEvent.screenshotCapture.eventName,
        AnalyticsEvent.colorPickSuccess.eventName,
        AnalyticsEvent.ocrUse.eventName,
        AnalyticsEvent.translationUse.eventName,
        AnalyticsEvent.toolExecuteSuccess.eventName,
        AnalyticsEvent.searchExecute.eventName,
    ]
    /// 去重窗口默认时长（spec ⬜，推断 1 秒：连续复制/连点只计 1 次）
    private static let defaultDedupeWindow: TimeInterval = 1.0

    /// 开关门控（D5：UserDefaults 键 analyticsEnabled，默认开）
    public var analyticsEnabled: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: "analyticsEnabled") == nil ? true : d.bool(forKey: "analyticsEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "analyticsEnabled") }
    }

    /// 全部已跟踪事件名（54 枚举 + 5 裸串 = 59，spec 17 §4）
    public var trackedEventNames: Set<String> {
        var names = Set(AnalyticsEvent.allCases.map { $0.eventName })
        names.formUnion(Self.bareStringEvents)
        // 重建扩展事件：ai_request_count 由旧 bumpStat("ai_request_count") 路径写入
        // （LLMService 等调用点），并非枚举 case。此前未列入本集合 → record 写入成功，
        // 但 Q3/Q4/Q5 的 `event_name IN (...)` 绑定把它过滤掉，统计窗永不显示（静默丢失）。
        // 原作 53 事件中无此项，属重建的有意扩展（见 specs/17 §4 注释），故在此显式并入。
        names.insert("ai_request_count")
        return names
    }
    /// 裸串事件（主面板 4 个 + 权限 1 个）
    public static let bareStringEvents: Set<String> = [
        "main_panel_item", "main_panel_preview", "main_panel_search_result",
        "main_panel_keyboard", "permission_granted",
    ]

    private init() {
        db = DatabaseManager.shared.statistics
        ensureInstallDate()
    }

    // MARK: 写入

    /// 埋点 +1（D7：TimeZone.current + "yyyy-MM-dd"，ON CONFLICT 累加；去重窗口内跳过）
    public func record(_ event: String, day: String? = nil) {
        guard analyticsEnabled else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let d = day ?? Self.dayString()
            if Self.operationEventNames.contains(event) {
                let window = self.dedupeWindows[event] ?? Self.defaultDedupeWindow
                if let last = self.lastEventTime[event], Date().timeIntervalSince(last) < window { return }
                self.lastEventTime[event] = Date()
            }
            try? self.db.run(
                "INSERT INTO usage_daily_metrics(day, event_name, count) VALUES(?,?,1) " +
                "ON CONFLICT(day, event_name) DO UPDATE SET count = MAX(0, usage_daily_metrics.count) + 1",
                [.text(d), .text(event)])
        }
    }

    public func record(_ event: AnalyticsEvent) { record(event.eventName) }

    /// 批量落库恢复（D4：崩溃/挂起后补写挂起的 +1 记录，条目 = (事件名, 增量, day)）
    public func recordBatch(_ events: [(String, Int, String)]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = try? self.db.transaction { db in
                for (event, delta, day) in events where delta != 0 {
                    try db.run(
                        "INSERT INTO usage_daily_metrics(day, event_name, count) VALUES(?,?,?) " +
                        "ON CONFLICT(day, event_name) DO UPDATE SET count = MAX(0, usage_daily_metrics.count) + excluded.count",
                        [.text(day), .text(event), .int(Int64(delta))])
                }
            }
        }
    }

    // MARK: 查询（Q1-Q8，照 spec 17 §5 映射；所有查询对 count<=0 归零）

    /// Q1 全量按事件总计 → __totalCounts
    public func totalCounts() -> [String: Int] {
        queue.sync {
            guard let rows = try? db.query(
                "SELECT event_name, SUM(CASE WHEN count > 0 THEN count ELSE 0 END) AS total " +
                "FROM usage_daily_metrics GROUP BY event_name") else { return [:] }
            var out: [String: Int] = [:]
            for r in rows { if let n = r.string("event_name") { out[n] = Int(r.int("total")) } }
            return out
        }
    }

    /// Q2 指定日按事件 → __todayCounts
    public func todayCounts(day: String, events: [String]) -> [String: Int] {
        guard !events.isEmpty else { return [:] }
        let ph = Array(repeating: "?", count: events.count).joined(separator: ",")
        let values = [.text(day)] + events.map { SQLiteValue.text($0) }
        return queue.sync {
            guard let rows = try? db.query(
                "SELECT event_name, CASE WHEN count > 0 THEN count ELSE 0 END AS c " +
                "FROM usage_daily_metrics WHERE day = ? AND event_name IN (\(ph))", values) else { return [:] }
            var out: [String: Int] = [:]
            for r in rows { if let n = r.string("event_name") { out[n] = Int(r.int("c")) } }
            return out
        }
    }

    /// Q3 活跃天数 → __activeDaysCount
    public func activeDaysCount(events: [String]) -> Int {
        guard !events.isEmpty else { return 0 }
        let ph = Array(repeating: "?", count: events.count).joined(separator: ",")
        let values = events.map { SQLiteValue.text($0) }
        return queue.sync {
            Int((try? db.scalarInt(
                "SELECT COUNT(DISTINCT day) FROM usage_daily_metrics " +
                "WHERE event_name IN (\(ph)) AND count > 0", values)) ?? 0)
        }
    }

    /// Q4 每日总计（热力图）→ [(day, total)]
    public func dailyTotals(since: String, events: [String]) -> [(String, Int)] {
        guard !events.isEmpty else { return [] }
        let ph = Array(repeating: "?", count: events.count).joined(separator: ",")
        let values: [SQLiteValue] = [.text(since)] + events.map { .text($0) }
        return queue.sync {
            guard let rows = try? db.query(
                "SELECT day, SUM(CASE WHEN count > 0 THEN count ELSE 0 END) AS total FROM usage_daily_metrics " +
                "WHERE day >= ? AND event_name IN (\(ph)) GROUP BY day ORDER BY day ASC", values) else { return [] }
            return rows.compactMap { r in r.string("day").map { ($0, Int(r.int("total"))) } }
        }
    }

    /// Q5 每日按事件（最近 30 天分解柱图）→ [(day, event, count)]
    public func dailyBreakdowns(since: String, events: [String]) -> [(String, String, Int)] {
        guard !events.isEmpty else { return [] }
        let ph = Array(repeating: "?", count: events.count).joined(separator: ",")
        let values: [SQLiteValue] = [.text(since)] + events.map { .text($0) }
        return queue.sync {
            guard let rows = try? db.query(
                "SELECT day, event_name, CASE WHEN count > 0 THEN count ELSE 0 END AS c " +
                "FROM usage_daily_metrics WHERE day >= ? AND event_name IN (\(ph)) " +
                "ORDER BY day ASC, event_name ASC", values) else { return [] }
            return rows.compactMap { r in
                guard let d = r.string("day"), let e = r.string("event_name") else { return nil }
                return (d, e, Int(r.int("c")))
            }
        }
    }

    /// Q6 单事件总计（metricConfigs 单卡/tooltip）
    public func total(event: String) -> Int {
        queue.sync {
            Int((try? db.scalarInt(
                "SELECT COALESCE(SUM(CASE WHEN count > 0 THEN count ELSE 0 END), 0) " +
                "FROM usage_daily_metrics WHERE event_name = ?", [.text(event)])) ?? 0)
        }
    }

    /// Q7 评分请求口径：history_copy + screenshot_capture 之和（D8）
    public func reviewRequestUsage() -> Int {
        queue.sync {
            Int((try? db.scalarInt(
                "SELECT COALESCE(SUM(CASE WHEN count > 0 THEN count ELSE 0 END), 0) " +
                "FROM usage_daily_metrics WHERE event_name IN ('history_copy','screenshot_capture')")) ?? 0)
        }
    }

    /// Q8 导出全量（设置导出携带统计数据）
    public func exportAll() -> [(String, String, Int)] {
        queue.sync {
            guard let rows = try? db.query(
                "SELECT day, event_name, count FROM usage_daily_metrics ORDER BY day ASC") else { return [] }
            return rows.compactMap { r in
                guard let d = r.string("day"), let e = r.string("event_name") else { return nil }
                return (d, e, Int(r.int("count")))
            }
        }
    }

    /// Q8 导入合并：事务内 MAX(旧, 新, 0)，不覆盖削减（S12）
    public func importMerge(_ rows: [(String, String, Int)]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            _ = try? self.db.transaction { db in
                for (day, event, count) in rows {
                    try db.run(
                        "INSERT INTO usage_daily_metrics(day, event_name, count) VALUES(?,?,?) " +
                        "ON CONFLICT(day, event_name) DO UPDATE SET " +
                        "count = MAX(usage_daily_metrics.count, excluded.count, 0)",
                        [.text(day), .text(event), .int(Int64(max(count, 0)))])
                }
            }
        }
    }

    // MARK: app_meta / install_date（D6：惰性初始化）

    private func ensureInstallDate() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let metaRows = (try? self.db.query(
                "SELECT value FROM app_meta WHERE key = 'install_date'")) ?? []
            if metaRows.isEmpty {
                try? self.db.run("INSERT OR IGNORE INTO app_meta(key, value) VALUES('install_date', ?)",
                                 [.text(Self.dayString())])
            }
        }
    }

    /// 安装日期（yyyy-MM-dd；无记录时返回 nil）
    public func installDate() -> String? {
        queue.sync {
            guard let rows = try? db.query("SELECT value FROM app_meta WHERE key = 'install_date'") else { return nil }
            return rows.first?.string("value")
        }
    }

    // MARK: 工具

    /// day 串格式 = yyyy-MM-dd（TimeZone.current，D7 小字符串立即数实证）
    public static func dayString(from date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: date)
    }
}
