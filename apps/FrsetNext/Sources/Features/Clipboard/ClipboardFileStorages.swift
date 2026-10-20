import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - 相对路径工具

/// 所有落盘文件以 **相对 AppDirectories.base 的路径** 存库（如 "images/xxx.png"），
/// 好处：换机/迁移 sandbox 容器时行数据仍然可解析（与原作 image_path 口径一致）。
public enum ClipboardFileStore {

    public static var baseURL: URL { AppDirectories.base }

    public static func url(forRelativePath path: String) -> URL {
        return baseURL.appendingPathComponent(path)
    }

    /// 写入并返回是否成功；父目录自动创建
    @discardableResult
    public static func write(_ data: Data, toRelativePath path: String) -> Bool {
        let url = url(forRelativePath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error("clipboard", "写文件失败 \(path): \(error)")
            return false
        }
    }

    public static func read(_ path: String) -> Data? {
        try? Data(contentsOf: url(forRelativePath: path))
    }

    public static func remove(_ path: String?) {
        guard let path = path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(at: url(forRelativePath: path))
    }

    public static func fileSize(_ path: String?) -> Int {
        guard let path = path, !path.isEmpty else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(forRelativePath: path).path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 子目录整体字节数（用于容量清理的真实磁盘口径）
    public static func directorySize(_ name: String) -> Int {
        let url = AppDirectories.sub(name)
        var total: Int = 0
        let enumerator = FileManager.default.enumerator(at: url,
                                                        includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles])
        while let file = enumerator?.nextObject() as? URL {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += size
        }
        return total
    }
}

// MARK: - 长文本落盘（05 号规格 B3）

public enum ClipboardTextStorage {
    public static let directoryName = "texts"

    /// 长文本写盘：返回相对路径与实际字节数
    public static func write(_ text: String, id: String = UUID().uuidString) -> (path: String, bytes: Int)? {
        let relative = "\(directoryName)/\(id).txt"
        guard let data = text.data(using: .utf8) else { return nil }
        guard ClipboardFileStore.write(data, toRelativePath: relative) else { return nil }
        return (relative, data.count)
    }

    public static func read(_ relativePath: String) -> String? {
        guard let data = ClipboardFileStore.read(relativePath) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func remove(_ relativePath: String?) { ClipboardFileStore.remove(relativePath) }
}

// MARK: - 富文本落盘

public enum ClipboardRichTextStorage {
    public static let directoryName = "rich_texts"

    public static func write(_ data: Data, id: String = UUID().uuidString) -> String? {
        let relative = "\(directoryName)/\(id).rtf"
        guard ClipboardFileStore.write(data, toRelativePath: relative) else { return nil }
        return relative
    }

    public static func read(_ relativePath: String) -> NSAttributedString? {
        guard let data = ClipboardFileStore.read(relativePath) else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    public static func remove(_ relativePath: String?) { ClipboardFileStore.remove(relativePath) }
}

// MARK: - OCR 文本落盘（图片条目的可搜索副产品，05 号规格 B11）

public enum ClipboardOCRTextStorage {
    public static let directoryName = "ocr"

    /// 以去重键命名，天然保证一个条目一份 OCR 结果
    public static func write(_ text: String, dedupeKey: String) {
        let safe = dedupeKey.replacingOccurrences(of: "/", with: "_")
        let relative = "\(directoryName)/\(safe).txt"
        guard let data = text.data(using: .utf8) else { return }
        ClipboardFileStore.write(data, toRelativePath: relative)
    }

    public static func read(dedupeKey: String) -> String? {
        let safe = dedupeKey.replacingOccurrences(of: "/", with: "_")
        return ClipboardTextStorage.read("\(directoryName)/\(safe).txt")
    }

    public static func remove(dedupeKey: String) {
        let safe = dedupeKey.replacingOccurrences(of: "/", with: "_")
        ClipboardFileStore.remove("\(directoryName)/\(safe).txt")
    }

    /// 检索 OCR 文本命中的条目去重键（05 号规格 B11：搜索覆盖 OCR 文本）。
    /// OCR 结果以文件落盘（`ocr/<dedupeKey>.txt`），此处做**有界扫描**（默认最多 2000 份），
    /// 命中后由仓储层拼进 SQL 的 `dedupe_key IN (...)`，从而与分页/排序保持一致。
    public static func matchingDedupeKeys(query: String, maxFiles: Int = 2000) -> Set<String> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let directory = AppDirectories.sub(directoryName)
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let needle = trimmed.lowercased()
        var hits: Set<String> = []
        var scanned = 0
        while let file = enumerator.nextObject() as? URL {
            guard file.pathExtension == "txt" else { continue }
            scanned += 1
            if scanned > maxFiles { break }
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8),
                  text.lowercased().contains(needle) else { continue }
            hits.insert(file.deletingPathExtension().lastPathComponent)
        }
        return hits
    }
}

// MARK: - 图片与缩略图（05 号规格 B4）

public enum ClipboardImageStorage {

    public static let imageDirectoryName = "images"
    public static let thumbnailDirectoryName = "thumbnails"
    /// 缩略图最长边
    public static let thumbnailMaxPixelSize: Int = 200

    public struct StoredImage {
        public let imagePath: String?
        public let thumbnailPath: String?
        public let byteCount: Int
        public let pixelSize: CGSize
    }

    /// 原图写盘 + 生成 200px 缩略图
    public static func store(imageData: Data, id: String = UUID().uuidString) -> StoredImage? {
        let ext = Self.fileExtension(for: imageData)
        let relative = "\(imageDirectoryName)/\(id).\(ext)"
        guard ClipboardFileStore.write(imageData, toRelativePath: relative) else { return nil }

        let thumbRelative = "\(thumbnailDirectoryName)/\(id).png"
        let thumbnailPath: String? = makeThumbnail(from: imageData, toRelativePath: thumbRelative) ? thumbRelative : nil
        return StoredImage(imagePath: relative,
                           thumbnailPath: thumbnailPath,
                           byteCount: imageData.count,
                           pixelSize: Self.pixelSize(of: imageData))
    }

    /// ImageIO 缩放：只读解码到目标尺寸，避免整图常驻内存
    @discardableResult
    public static func makeThumbnail(from data: Data, toRelativePath path: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        let url = ClipboardFileStore.url(forRelativePath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// v101 性能审计：缩略图缓存（此前每次行渲染都 Data(contentsOf:) 读盘+解码，
    /// 滑动掉帧的行级主因）——NSCache 自动回收，上限 80 张
    private static let imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 80
        return c
    }()

    public static func image(relativePath: String?) -> NSImage? {
        guard let path = relativePath, !path.isEmpty else { return nil }
        if let hit = imageCache.object(forKey: path as NSString) { return hit }
        guard let data = ClipboardFileStore.read(path), let img = NSImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: path as NSString)
        return img
    }

    // MARK: 内部

    private static func fileExtension(for data: Data) -> String {
        let head = data.prefix(16)
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" }
        return "tiff"
    }

    private static func pixelSize(of data: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return .zero }
        return CGSize(width: w, height: h)
    }
}

// MARK: - 存储用量统计（05 号规格 1.1：ClipboardStorageUsageProvider）

public final class ClipboardStorageUsageProvider {
    public static let shared = ClipboardStorageUsageProvider()

    /// 数据库口径：所有条目 storage_bytes 之和
    public var databaseBytes: Int64 { ClipboardRepository.shared.totalStorageBytes() }

    /// 磁盘口径：实际落盘子目录字节数
    public var diskBytes: Int {
        ClipboardFileStore.directorySize(ClipboardImageStorage.imageDirectoryName)
            + ClipboardFileStore.directorySize(ClipboardImageStorage.thumbnailDirectoryName)
            + ClipboardFileStore.directorySize(ClipboardTextStorage.directoryName)
            + ClipboardFileStore.directorySize(ClipboardRichTextStorage.directoryName)
            + ClipboardFileStore.directorySize(ClipboardOCRTextStorage.directoryName)
    }

    /// 对外统一取较大者，避免任一口径低估导致清理不及时
    public var totalBytes: Int64 { max(databaseBytes, Int64(diskBytes)) }
}
