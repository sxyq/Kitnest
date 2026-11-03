import AppKit
import Foundation

// v130（SnowShot 对齐）②：截图历史
//
// Snow Shot 记录每次截图，可搜索、继续未完成的标注、复用之前的截图。
// 本文件是历史存储：
//   · SQLite 表 capture_history(id, path, thumb_path, created_at, mode,
//     width, height, ocr_text, annotation_state)——用 Storage/Database.swift 的
//     SQLiteDatabase（只调用，不改它），独立库文件 capture-history.sqlite；
//   · 缩略图落 ~/Library/Application Support/FrsetNext/capture-history/；
//   · 上限 500 条，超出淘汰最旧 + 清理孤儿缩略图；
//   · annotation_state 存「未完成标注」的 JSON 快照（AnnotationStateSnapshot），
//     历史窗「继续标注」可恢复到标注编辑器。

// MARK: - 历史条目

public struct CaptureHistoryItem: Identifiable, Hashable {
    public let id: String
    public let path: String
    public let thumbPath: String
    public let createdAt: Date
    /// 截图模式（CaptureMode.rawValue 或扩展标签，如 "area"/"full"/"window"/"long"）
    public let mode: String
    public let width: Int
    public let height: Int
    public let ocrText: String
    public let annotationState: String

    public var url: URL { URL(fileURLWithPath: path) }
    public var thumbnailURL: URL? { thumbPath.isEmpty ? nil : URL(fileURLWithPath: thumbPath) }
}

// MARK: - 未完成标注快照（annotation_state 列的 JSON 形态）

/// 一条标注的可序列化快照（与 AnnotationCompositor.Annotation 字段一一对应）
struct AnnotationStateSnapshot: Codable {
    struct Item: Codable {
        var tool: String
        var points: [Double]          // 扁平化 [x0,y0,x1,y1,…]
        var text: String?
        var colorHex: String
        var lineWidth: Double
        var blockSize: Double
        var weight: Int
        var wrapWidth: Double
    }
    var items: [Item]
    var updatedAt: Double

    static func encode(_ annotations: [Annotation]) -> String {
        let snap = AnnotationStateSnapshot(
            items: annotations.map { a in
                Item(tool: a.tool.rawValue,
                     points: a.points.flatMap { [Double($0.x), Double($0.y)] },
                     text: a.text, colorHex: a.colorHex,
                     lineWidth: Double(a.lineWidth), blockSize: Double(a.blockSize),
                     weight: a.weight, wrapWidth: Double(a.wrapWidth))
            },
            updatedAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(snap) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode(_ json: String) -> [Annotation]? {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let snap = try? JSONDecoder().decode(AnnotationStateSnapshot.self, from: data) else { return nil }
        return snap.items.compactMap { item in
            guard let tool = AnnotationTool(rawValue: item.tool) else { return nil }
            var pts: [CGPoint] = []
            var i = 0
            while i + 1 < item.points.count {
                pts.append(CGPoint(x: item.points[i], y: item.points[i + 1]))
                i += 2
            }
            return Annotation(tool: tool, points: pts, text: item.text,
                              colorHex: item.colorHex,
                              lineWidth: CGFloat(item.lineWidth),
                              blockSize: CGFloat(item.blockSize),
                              weight: item.weight,
                              wrapWidth: CGFloat(item.wrapWidth))
        }
    }
}

// MARK: - 历史存储

public final class CaptureHistoryStore {
    public static let shared = CaptureHistoryStore()

    /// 上限 500 条（SnowShot 对齐：超出淘汰最旧）
    public static let maxEntries = 500

    private let db: SQLiteDatabase
    private let dir = AppDirectories.sub("capture-history")
    private let queue = DispatchQueue(label: "com.frset.capture-history")

    /// 历史变化通知（历史窗刷新用）
    public static let didChangeNotification = Notification.Name("frset.captureHistory.changed")

    private init() {
        let path = AppDirectories.base.appendingPathComponent("capture-history.sqlite").path
        do {
            db = try SQLiteDatabase(path: path)
        } catch {
            fatalError("CaptureHistoryStore init failed: \(error)")
        }
        try? db.exec("""
        CREATE TABLE IF NOT EXISTS capture_history (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            thumb_path TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            mode TEXT NOT NULL DEFAULT '',
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0,
            ocr_text TEXT NOT NULL DEFAULT '',
            annotation_state TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_capture_history_created ON capture_history(created_at DESC);
        """)
    }

    // MARK: 写入

    /// 一张截图落盘后入库：异步读图片头拿尺寸 + 生成缩略图，再插入并做 500 条淘汰
    @discardableResult
    public func record(url: URL, mode: String) -> String {
        let id = UUID().uuidString
        let path = url.path
        queue.async { [weak self] in
            guard let self else { return }
            let (w, h) = Self.pixelSize(of: url)
            let thumbPath = self.makeThumbnail(for: url, id: id)
            try? self.db.run(
                "INSERT INTO capture_history(id, path, thumb_path, created_at, mode, width, height, ocr_text, annotation_state) " +
                "VALUES(?,?,?,?,?,?,?,'','')",
                [.text(id), .text(path), .text(thumbPath),
                 .real(Date().timeIntervalSince1970), .text(mode), .int(Int64(w)), .int(Int64(h))])
            self.pruneLocked()
            self.notifyChange()
        }
        return id
    }

    /// OCR 文本回填（识别完成后按文件路径匹配最近一条）
    public func updateOCR(path: String, text: String) {
        queue.async { [weak self] in
            guard let self, !text.isEmpty else { return }
            try? self.db.run(
                "UPDATE capture_history SET ocr_text = ? WHERE id = " +
                "(SELECT id FROM capture_history WHERE path = ? ORDER BY created_at DESC LIMIT 1)",
                [.text(text), .text(path)])
            self.notifyChange()
        }
    }

    /// 未完成标注快照回填（标注编辑器关闭时若有未保存标注）
    public func updateAnnotationState(path: String, json: String) {
        queue.async { [weak self] in
            guard let self, !json.isEmpty else { return }
            try? self.db.run(
                "UPDATE capture_history SET annotation_state = ? WHERE id = " +
                "(SELECT id FROM capture_history WHERE path = ? ORDER BY created_at DESC LIMIT 1)",
                [.text(json), .text(path)])
        }
    }

    // MARK: 查询 / 删除

    /// 查询历史（按时间倒序）。`query` 空 = 全量；否则按 OCR 文本 / 模式 / 日期串模糊匹配。
    public func items(query: String = "", mode: String? = nil, limit: Int = 500) -> [CaptureHistoryItem] {
        queue.sync {
            var sql = "SELECT * FROM capture_history WHERE 1=1"
            var values: [SQLiteValue] = []
            if let mode, !mode.isEmpty, mode != "all" {
                sql += " AND mode = ?"
                values.append(.text(mode))
            }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                // OCR 文本 / 文件路径 / 模式 / 创建日期（yyyy-MM-dd 或 M月d日）任一命中
                sql += " AND (ocr_text LIKE ? OR path LIKE ? OR mode LIKE ? OR " +
                       "strftime('%Y-%m-%d', created_at, 'unixepoch', 'localtime') LIKE ?)"
                let like = "%\(q)%"
                values.append(contentsOf: [.text(like), .text(like), .text(like), .text(like)])
            }
            sql += " ORDER BY created_at DESC LIMIT ?"
            values.append(.int(Int64(limit)))
            let rows = (try? self.db.query(sql, values)) ?? []
            return rows.map { Self.item(from: $0) }
        }
    }

    public func delete(id: String) {
        queue.async { [weak self] in
            guard let self else { return }
            // 连缩略图一起删
            if let rows = try? self.db.query("SELECT thumb_path FROM capture_history WHERE id = ?", [.text(id)]) {
                for r in rows {
                    if let p = r.string("thumb_path"), !p.isEmpty {
                        try? FileManager.default.removeItem(atPath: p)
                    }
                }
            }
            try? self.db.run("DELETE FROM capture_history WHERE id = ?", [.text(id)])
            self.notifyChange()
        }
    }

    public func item(id: String) -> CaptureHistoryItem? {
        queue.sync {
            let rows = (try? self.db.query("SELECT * FROM capture_history WHERE id = ?", [.text(id)])) ?? []
            return rows.first.map { Self.item(from: $0) }
        }
    }

    // MARK: 淘汰与清理

    /// 超过 500 条淘汰最旧 + 清理孤儿缩略图（磁盘上有、库里没有的）
    private func pruneLocked() {
        guard let n = try? self.db.scalarInt("SELECT COUNT(*) FROM capture_history") else { return }
        if n > Int64(Self.maxEntries) {
            let overflow = n - Int64(Self.maxEntries)
            if let rows = try? self.db.query(
                "SELECT id, thumb_path FROM capture_history ORDER BY created_at ASC LIMIT ?", [.int(overflow)]) {
                for r in rows {
                    if let p = r.string("thumb_path"), !p.isEmpty {
                        try? FileManager.default.removeItem(atPath: p)
                    }
                    if let id = r.string("id") {
                        try? self.db.run("DELETE FROM capture_history WHERE id = ?", [.text(id)])
                    }
                }
            }
        }
        cleanOrphanThumbnails()
    }

    /// 孤儿缩略图清理（库里已无记录引用的文件）
    private func cleanOrphanThumbnails() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let rows = (try? db.query("SELECT thumb_path FROM capture_history")) ?? []
        let known = Set(rows.compactMap { $0.string("thumb_path") })
        for name in files where name.hasPrefix("thumb-") {
            let full = dir.appendingPathComponent(name).path
            if !known.contains(full) {
                try? fm.removeItem(atPath: full)
            }
        }
    }

    // MARK: 工具

    private static func item(from row: [String: SQLiteValue]) -> CaptureHistoryItem {
        CaptureHistoryItem(
            id: row.string("id") ?? "",
            path: row.string("path") ?? "",
            thumbPath: row.string("thumb_path") ?? "",
            createdAt: Date(timeIntervalSince1970: row.real("created_at")),
            mode: row.string("mode") ?? "",
            width: Int(row.int("width")),
            height: Int(row.int("height")),
            ocrText: row.string("ocr_text") ?? "",
            annotationState: row.string("annotation_state") ?? "")
    }

    /// 图片像素尺寸（只读文件头，不解码整图）
    private static func pixelSize(of url: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return (w, h)
    }

    /// 生成缩略图（最长边 240）落盘，返回路径；失败返回 ""
    private func makeThumbnail(for url: URL, id: String) -> String {
        guard let cg = ImageProcessor.cgImage(from: url) else { return "" }
        let scaled = ImageProcessor.scaled(cg, maxSide: 240)
        guard let data = ImageProcessor.pngData(scaled) else { return "" }
        let out = dir.appendingPathComponent("thumb-\(id).png")
        do {
            try data.write(to: out)
            return out.path
        } catch {
            return ""
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: CaptureHistoryStore.didChangeNotification, object: nil)
        }
    }
}
