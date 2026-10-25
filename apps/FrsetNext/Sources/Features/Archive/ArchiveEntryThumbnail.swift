import AppKit
import AVFoundation
import QuickLookThumbnailing

// MARK: - 归档条目缩略图（v123）
//
// 仿 ArcZip 的 `ContentThumbnailDecoder` 分级解码：**不是自己去渲染 Office**，
// 而是「把条目解到临时文件 → 按类型选最合适的手段出图 → 让系统 QuickLook 兜底」。
//
//   · 图片（png/jpg/heic/webp/gif/tiff…）→ ImageIO 缩略（快、省内存）
//   · PDF                                → CoreGraphics 首页直渲（不用 PDFKit，与原版一致）
//   · 视频（mp4/mov/m4v…）               → AVAssetImageGenerator 首帧
//   · 文本 / 代码 / json / md            → CoreText 自渲染前几十行（白底黑字，像文档）
//   · Office（docx/xlsx/pptx/pages…）     → 解到临时盘 → QLThumbnailGenerator（带超时）
//   · 其余                               → 不出图，退回类型图标
//
// 缓存 key 里带归档的 mtime，归档一改缓存自动失效。

enum ArchiveEntryThumbnail {

    // v128（内存优化）：原缓存无界，缩略图解码后驻留只涨不落。
    // 加 countLimit=64 + totalCostLimit=24MB，写入按像素字节记账（w*h*4）。
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        c.totalCostLimit = 24 * 1024 * 1024
        return c
    }()
    /// 并发上限：同时最多 3 个解压任务，避免 30 个条目一起拉 7zz 进程把机器拖住
    private static let limiter = DispatchSemaphore(value: 3)

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "ico", "icns"
    ]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    private static let textExts: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "yml", "yaml", "csv", "tsv",
        "swift", "py", "js", "ts", "jsx", "tsx", "html", "htm", "css", "scss",
        "sh", "bash", "zsh", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "m", "mm",
        "sql", "toml", "ini", "conf", "log", "plist", "gitignore"
    ]
    private static let officeExts: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "epub"
    ]

    /// 这个条目值不值得解出来出图（不值得就直接用类型图标，省一次解压）
    static func canRender(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExts.contains(ext) || videoExts.contains(ext) || textExts.contains(ext) { return true }
        if officeExts.contains(ext) || ext == "pdf" { return true }
        return false
    }

    static func load(archive: URL, entry: ArchiveEntry, size: CGFloat,
                     completion: @escaping (NSImage?) -> Void) {
        guard !entry.isDirectory, canRender(entry.name) else {
            completion(nil)
            return
        }
        let key = cacheKey(archive: archive, entry: entry, size: size)
        if let hit = cache.object(forKey: key) {
            completion(hit)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            limiter.wait()
            ArchiveCore.extractEntryToTemp(url: archive, entry: entry) { tmp, _ in
                guard let tmp else {
                    limiter.signal()
                    completion(nil)
                    return
                }
                render(url: tmp, size: size) { image in
                    try? FileManager.default.removeItem(at: tmp)
                    limiter.signal()
                    // v128（内存优化）：按像素字节记账，配合 totalCostLimit 控制缓存驻留
                    if let image {
                        cache.setObject(image, forKey: key,
                                        cost: Int(image.size.width * image.size.height * 4))
                    }
                    DispatchQueue.main.async { completion(image) }
                }
            }
        }
    }

    // MARK: 分派

    private static func render(url: URL, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        // v128（内存优化）：包 autoreleasepool——解码 CGImage / NSAttributedString /
        // NSBitmapImageRep 产生大量临时对象，而本函数跑在 GCD 后台队列（无 run loop
        // 边界不自动 drain）。同步类型在池内出图（缓存/回调持有后跨池存活无碍）；
        // video/QL 异步回调在各自队列，由其回调边界自行释放。
        autoreleasepool {
            let ext = url.pathExtension.lowercased()
            if imageExts.contains(ext) {
                completion(imageThumbnail(url: url, pixels: size * 2))
                return
            }
            if ext == "pdf" {
                completion(pdfFirstPage(url: url, maxPixels: size * 2))
                return
            }
            if videoExts.contains(ext) {
                videoFirstFrame(url: url, maxPixels: size * 2, completion: completion)
                return
            }
            if textExts.contains(ext) {
                completion(textPreview(url: url, pixels: size * 2))
                return
            }
            // Office / 其他：系统 QuickLook（ArcZip 同款：物化后交给 QL）
            qlThumbnail(url: url, pixels: size * 2, completion: completion)
        }
    }

    // MARK: 各类型实现

    private static func imageThumbnail(url: URL, pixels: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, pixels)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func pdfFirstPage(url: URL, maxPixels: CGFloat) -> NSImage? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = maxPixels / max(box.width, box.height)
        let w = max(1, Int(box.width * scale)), h = max(1, Int(box.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let c = ctx.cgContext
        c.setFillColor(NSColor.white.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        c.scaleBy(x: scale, y: scale)
        c.drawPDFPage(page)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    private static func videoFirstFrame(url: URL, maxPixels: CGFloat,
                                        completion: @escaping (NSImage?) -> Void) {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cg, _, _, _ in
            guard let cg else { completion(nil); return }
            completion(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
        }
    }

    /// 文本首屏：白底黑字、等宽字体，按容器截断（等价于 ArcZip 的 CoreText 自渲染，但不做分页）
    private static func textPreview(url: URL, pixels: CGFloat) -> NSImage? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let head = String(raw.prefix(1200))
        let w = pixels, h = pixels
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: max(5, pixels / 28), weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: para
        ]
        (head as NSString).draw(
            in: NSRect(x: pixels * 0.05, y: pixels * 0.05,
                       width: w * 0.9, height: h * 0.9),
            withAttributes: attrs)

        // 底部渐隐，看起来像"还有更多内容"
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: 0, width: w, height: h * 0.12).fill()
        return image
    }

    private static func qlThumbnail(url: URL, pixels: CGFloat,
                                    completion: @escaping (NSImage?) -> Void) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixels, height: pixels),
            scale: 2,
            representationTypes: .all)
        var finished = false
        let lock = NSLock()

        func finish(_ image: NSImage?) {
            lock.lock()
            if finished { lock.unlock(); return }
            finished = true
            lock.unlock()
            completion(image)
        }

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            finish(rep?.nsImage)
        }
        // 超时保护（Office 首次生成可能卡住，不能拖死整个网格）
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            finish(nil)
        }
    }

    // MARK: 缓存 key

    private static func cacheKey(archive: URL, entry: ArchiveEntry, size: CGFloat) -> NSString {
        let attrs = try? FileManager.default.attributesOfItem(atPath: archive.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(archive.path)|\(Int(mtime))|\(entry.path)|\(Int(size))" as NSString
    }
}
