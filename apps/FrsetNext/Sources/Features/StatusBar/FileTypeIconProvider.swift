import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

// MARK: - 文件类型图标缓存

/// FileTypeIconProvider：按扩展名 / UTType 取系统图标，落盘 PNG 缓存 + 库内 file_type_icons 记录 + 内存 LRU
/// 内存 → 磁盘 → 系统（NSWorkspace）三级；系统取到后写回磁盘与数据库
public final class FileTypeIconProvider {

    public static let shared = FileTypeIconProvider()

    /// 内存 LRU 容量（按图标数量计）
    private static let memoryCapacity = 128

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private var lruOrder: [String] = []          // 头部最近使用
    private let iconDirectory: URL = AppDirectories.sub("icons")

    private init() {}

    // MARK: 对外接口

    /// 按扩展名取图标（"pdf" / ".pdf" 均可）
    public func icon(forExtension ext: String) -> NSImage {
        let key = Self.normalize(ext)
        guard !key.isEmpty else { return NSWorkspace.shared.icon(for: .item) }

        if let hit = memoryIcon(key) { return hit }
        if let disk = diskIcon(key) { remember(key, disk); return disk }

        let image = systemIcon(forExtension: key)
        let path = writePNG(image, key: key)
        if let path { persist(key: key, handler: handlerBundleID(forExtension: key), path: path) }
        remember(key, image)
        return image
    }

    /// 按文件 URL 取图标（走扩展名缓存链）
    public func icon(forFileURL url: URL) -> NSImage {
        icon(forExtension: url.pathExtension)
    }

    /// 清空内存缓存（磁盘缓存保留）
    public func clearMemoryCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll(); lruOrder.removeAll()
    }

    /// 缓存目录（供设置页展示/清理）
    public var cacheDirectory: URL { iconDirectory }

    // MARK: 系统取图

    private func systemIcon(forExtension ext: String) -> NSImage {
        // 优先用 UTType（macOS 11+，能识别 public.* 体系）
        if let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        // 无法推断 UTType（自定义扩展名）→ 通用文稿图标
        return NSWorkspace.shared.icon(for: .item)
    }

    /// 默认打开该类型的应用 bundle id（LaunchServices）
    private func handlerBundleID(forExtension ext: String) -> String? {
        guard let type = UTType(filenameExtension: ext) else { return nil }
        let unmanaged = LSCopyDefaultApplicationURLForContentType(type.identifier as CFString, .all, nil)
        guard let cfURL = unmanaged?.takeRetainedValue(),
              let bundle = Bundle(url: cfURL as URL) else { return nil }
        return bundle.bundleIdentifier
    }

    // MARK: 磁盘缓存

    private func diskURL(_ key: String) -> URL {
        let safe = key.map { c -> Character in
            (c.isLetter || c.isNumber || c == "_" || c == "-") ? c : "_"
        }
        return iconDirectory.appendingPathComponent("\(String(safe)).png")
    }

    private func diskIcon(_ key: String) -> NSImage? {
        let url = diskURL(key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        return image
    }

    private func writePNG(_ image: NSImage, key: String) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            Log.warn("FileTypeIcon", "PNG 编码失败: \(key)")
            return nil
        }
        let url = diskURL(key)
        do {
            try data.write(to: url)
            return url.path
        } catch {
            Log.error("FileTypeIcon", "写盘失败 \(url.path): \(error)")
            return nil
        }
    }

    // MARK: 数据库记录（file_type_icons）

    private func persist(key: String, handler: String?, path: String) {
        do {
            try DatabaseManager.shared.clipboard.run(
                """
                INSERT INTO file_type_icons(icon_key, handler_bundle_id, icon_path, updated_at)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(icon_key) DO UPDATE SET
                    handler_bundle_id = excluded.handler_bundle_id,
                    icon_path = excluded.icon_path,
                    updated_at = excluded.updated_at;
                """,
                [.text(key), handler.map { SQLiteValue.text($0) } ?? .null, .text(path), .real(Date().timeIntervalSince1970)]
            )
        } catch {
            Log.error("FileTypeIcon", "写缓存记录失败 \(key): \(error)")
        }
    }

    /// 读取缓存记录（用于调试/设置页展示）
    public func cachedRecord(key: String) -> FileTypeIcon? {
        do {
            let rows = try DatabaseManager.shared.clipboard.query(
                "SELECT icon_key, handler_bundle_id, icon_path, updated_at FROM file_type_icons WHERE icon_key = ?;",
                [.text(Self.normalize(key))]
            )
            guard let row = rows.first else { return nil }
            return FileTypeIcon(iconKey: row.string("icon_key") ?? key,
                                handlerBundleId: row.string("handler_bundle_id"),
                                iconPath: row.string("icon_path"),
                                updatedAt: Date(timeIntervalSince1970: row.real("updated_at")))
        } catch {
            Log.error("FileTypeIcon", "读缓存记录失败 \(key): \(error)")
            return nil
        }
    }

    // MARK: 内存 LRU

    private func memoryIcon(_ key: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        guard let image = cache[key] else { return nil }
        touchLocked(key)
        return image
    }

    private func remember(_ key: String, _ image: NSImage) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = image
        touchLocked(key)
        while lruOrder.count > Self.memoryCapacity, let victim = lruOrder.popLast() {
            cache.removeValue(forKey: victim)
        }
    }

    /// 把 key 移到 LRU 头部（调用方已持锁）
    private func touchLocked(_ key: String) {
        if let idx = lruOrder.firstIndex(of: key) { lruOrder.remove(at: idx) }
        lruOrder.insert(key, at: 0)
    }

    // MARK: 工具

    /// 归一化扩展名：去前导点、转小写
    private static func normalize(_ ext: String) -> String {
        var s = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(".") { s.removeFirst() }
        return s.lowercased()
    }
}
