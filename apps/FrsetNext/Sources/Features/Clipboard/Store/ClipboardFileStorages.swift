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
}

// MARK: - OCR 文本落盘（图片条目的可搜索副产品，05 号规格 B11）

public extension Notification.Name {
    static let clipboardOCRTextChanged = Notification.Name("frset.clipboardOCRTextChanged")
}

public enum ClipboardOCRTextStorage {
    public static let directoryName = "ocr"

    /// 以去重键命名，天然保证一个条目一份 OCR 结果
    /// OCR 结果文件相对路径（去重键中的 `/` 替换为 `_`，与 write/read/remove 同口径）
    public static func relativePath(dedupeKey: String) -> String {
        let safe = dedupeKey.replacingOccurrences(of: "/", with: "_")
        return "\(directoryName)/\(safe).txt"
    }

    /// 文件名主体（= 去重键的 safe 形式），与 loadIndex/检索命中返回口径一致
    private static func keyName(forRelativePath relative: String) -> String {
        URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent
    }

    public static func write(_ text: String, dedupeKey: String) {
        let relative = relativePath(dedupeKey: dedupeKey)
        guard let data = text.data(using: .utf8) else { return }
        guard ClipboardFileStore.write(data, toRelativePath: relative) else { return }
        // v126（性能审计 F0576）：写入即更新内存索引，避免下次检索退化为全盘重扫
        indexLock.lock()
        if textIndex != nil {
            let lower = text.lowercased()
            let bytes = lower.utf8.count
            // 2026-11-26 修复（low）：增量写入同样受总字节预算约束（见 indexByteBudget）
            if indexBytes + bytes <= indexByteBudget {
                textIndex?[keyName(forRelativePath: relative)] = lower
                indexBytes += bytes
            }
        }
        indexLock.unlock()
        // 自动识别可能晚于预览打开；落盘后通知当前图片，不重建窗口或重复识别。
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipboardOCRTextChanged, object: dedupeKey)
        }
    }

    public static func read(dedupeKey: String) -> String? {
        ClipboardTextStorage.read(relativePath(dedupeKey: dedupeKey))
    }

    public static func remove(dedupeKey: String) {
        let relative = relativePath(dedupeKey: dedupeKey)
        ClipboardFileStore.remove(relative)
        // v126（性能审计 F0576）：删除同步失效索引条目
        indexLock.lock()
        if let removed = textIndex?.removeValue(forKey: keyName(forRelativePath: relative)) {
            // 2026-11-26：同步扣减已计入的字节，保证预算记账与索引内容一致
            indexBytes = max(0, indexBytes - removed.utf8.count)
        }
        indexLock.unlock()
    }

    // v126（性能审计 F0576）：OCR 检索内存索引。
    // 原实现每次搜索都重新枚举 ocr/ 目录并把最多 2000 份文件全部读盘 + 转小写
    //（searchText 每敲一个字触发 reload → fetch → matchingDedupeKeys，等于按键全量 IO 扫描）。
    // 改为惰性构建的 文件名主体 → 小写全文 索引，检索变成纯内存 contains；
    // write/remove 增量维护，重启后首次检索重建一次。
    private static let indexLock = NSLock()
    private static var textIndex: [String: String]? = nil
    /// 索引已计入的小写全文总字节（2026-11-26 修复，low）
    private static var indexBytes: Int = 0
    /// OCR 索引常驻内存的字节兜底上限（2026-11-26 修复，low）：
    /// 原 maxFiles=2000 只约束条目数，单份 OCR 很长（整页文档照片）时仍可驻留数十 MB。
    /// 按小写全文的 UTF-8 字节累计，超预算的条目不纳入索引（与 maxFiles 是同一种
    /// 「容量优先、宁可少命中」的取舍），避免内存无界。
    private static let indexByteBudget = 8 * 1024 * 1024

    static func invalidateIndex() {
        indexLock.lock(); defer { indexLock.unlock() }
        textIndex = nil
        indexBytes = 0
    }

    /// 构建/取用索引（含 maxFiles 与总字节双重上限，语义与原扫描一致）
    private static func loadIndex(maxFiles: Int) -> [String: String] {
        indexLock.lock(); defer { indexLock.unlock() }
        if let cached = textIndex { return cached }
        var built: [String: String] = [:]
        var builtBytes = 0
        let directory = AppDirectories.sub(directoryName)
        if let enumerator = FileManager.default.enumerator(at: directory,
                                                           includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles]) {
            var scanned = 0
            while let file = enumerator.nextObject() as? URL {
                guard file.pathExtension == "txt" else { continue }
                scanned += 1
                if scanned > maxFiles { break }
                guard let data = try? Data(contentsOf: file),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let lower = text.lowercased()
                let bytes = lower.utf8.count
                // 2026-11-26 修复：超预算的单份 OCR 跳过（continue 而非 break——
                // 枚举顺序不保证，跳过大文件还能收下后面的小文件）
                if builtBytes + bytes > indexByteBudget { continue }
                built[file.deletingPathExtension().lastPathComponent] = lower
                builtBytes += bytes
            }
        }
        textIndex = built
        indexBytes = builtBytes
        return built
    }

    /// 检索 OCR 文本命中的条目去重键（05 号规格 B11：搜索覆盖 OCR 文本）。
    /// OCR 结果以文件落盘（`ocr/<dedupeKey>.txt`），命中后由仓储层拼进 SQL 的
    /// `dedupe_key IN (...)`，从而与分页/排序保持一致。
    /// v126（性能审计 F0576）：走内存索引匹配，不再每次搜索读盘扫描（返回口径不变）。
    public static func matchingDedupeKeys(query: String, maxFiles: Int = 2000) -> Set<String> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let needle = trimmed.lowercased()
        let index = loadIndex(maxFiles: maxFiles)
        var hits: Set<String> = []
        for (name, text) in index where text.contains(needle) {
            hits.insert(name)
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
    }

    /// 原图写盘 + 生成 200px 缩略图
    public static func store(imageData: Data, id: String = UUID().uuidString) -> StoredImage? {
        // v280（2026-11-22 用户：「重点优化最终存储占用」）：系统剪贴板里的截屏常是
        // 未压缩 TIFF（实测单张 42MB、images/ 累计 1.0GB）。写盘前按内容重编码：
        // 大图 → HEIC（带 alpha 也不丢）/ 退 JPEG，只有在确实更小（<70%）时才替换。
        let payload = Self.reencodedIfSmaller(imageData)
        let data = payload.data
        let ext = payload.ext
        let relative = "\(imageDirectoryName)/\(id).\(ext)"
        guard ClipboardFileStore.write(data, toRelativePath: relative) else { return nil }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return StoredImage(imagePath: relative, thumbnailPath: nil,
                               byteCount: data.count)
        }
        let thumbRelative = "\(thumbnailDirectoryName)/\(id).png"
        let thumbnailPath: String? = makeThumbnail(from: source, toRelativePath: thumbRelative) ? thumbRelative : nil
        return StoredImage(imagePath: relative,
                           thumbnailPath: thumbnailPath,
                           byteCount: data.count)
    }

    /// 大图重编码：>1.5MB 才尝试；HEIC 优先（支持 alpha），失败退 JPEG；收益不足 30% 就放弃。
    private static func reencodedIfSmaller(_ data: Data) -> (data: Data, ext: String) {
        guard data.count > 1_500_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (data, fileExtension(for: data)) }
        let alpha = image.alphaInfo
        let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
        for (type, ext, quality) in [("public.heic", "heic", 0.90), ("public.jpeg", "jpg", 0.90)] {
            if ext == "jpg" && hasAlpha { continue }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }
            let encoded = out as Data
            if encoded.count < Int(Double(data.count) * 0.7) { return (encoded, ext) }
        }
        return (data, fileExtension(for: data))
    }

    @discardableResult
    private static func makeThumbnail(from source: CGImageSource, toRelativePath path: String) -> Bool {
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
    // v128（内存优化）：补 totalCostLimit=16MB + 写入按像素字节记账（w*h*4），
    // 防 80 张大图（原图直存时可到数 MB/张）把小堆吃穿。
    private static let imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 80
        c.totalCostLimit = 16 * 1024 * 1024
        return c
    }()

    public static func image(relativePath: String?) -> NSImage? {
        guard let path = relativePath, !path.isEmpty else { return nil }
        if let hit = imageCache.object(forKey: path as NSString) { return hit }
        guard let data = ClipboardFileStore.read(path), let img = NSImage(data: data) else { return nil }
        // v128（内存优化）：按像素字节记账，配合 totalCostLimit 控制缓存驻留
        imageCache.setObject(img, forKey: path as NSString,
                             cost: Int(img.size.width * img.size.height * 4))
        return img
    }

    /// 行缩略图专用：按目标像素边长**降采样解码**，不把原图整张读进内存。
    ///
    /// v282（用户：「全方位性能优化……CPU 占用、存储表现」）：
    /// `image(relativePath:)` 是给预览窗要原图用的，但剪贴板列表每行只画 50pt
    /// （1x 屏也就 50px、2x 100px）。原来的行卡直接走同一个入口，等于为了一行
    /// 50pt 的卡片把 2940×1912 的整图（≈22MB 位图）解码出来——一屏 20 行就是
    /// 400MB 级别的瞬时分配，HEIC 还要走一次完整解码流水线，滚动必然掉帧。
    ///
    /// 这里用 ImageIO 的 thumbnail API：解码器只解到目标尺寸（`kCGImageSourceThumbnailMaxPixelSize`），
    /// 顺带处理 EXIF 方向。缓存按「路径@边长」分桶，换缩略图档位不会互相顶掉。
    public static func thumbnail(relativePath: String?, maxPixel: CGFloat) -> NSImage? {
        guard let path = relativePath, !path.isEmpty, maxPixel > 0 else { return nil }
        let px = max(32, Int((maxPixel * 2).rounded()))      // 2x 上限，够视网膜屏
        let key = "\(path)@\(px)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(
            ClipboardFileStore.url(forRelativePath: path) as CFURL, nil) else {
            return image(relativePath: path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: px
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return image(relativePath: path)
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        imageCache.setObject(img, forKey: key, cost: cg.width * cg.height * 4)
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

    /// v126（性能审计 F0657）：判据短路版超限判定。
    /// `totalBytes = max(db, disk)` 必须两次全量计量（1 次 SQL SUM + 5 次目录遍历）；
    /// 而超限判定只需布尔结果——先算便宜的数据库口径，已超限时直接返回，
    /// 免掉 5 次目录树遍历（清理循环每批都要判一次，短路后是数量级差异）。
    /// 语义与 `totalBytes > target` 完全等价（max(a,b) > t ⟺ a > t || b > t）。
    public func exceeds(_ target: Int64) -> Bool {
        if databaseBytes > target { return true }
        return Int64(diskBytes) > target
    }
}
