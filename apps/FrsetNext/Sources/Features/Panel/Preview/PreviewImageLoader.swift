import AppKit
import CoreGraphics
import CoreImage
import Foundation

// MARK: - 预览图片加载器（specs/12 F12，PreviewImageLoader）
//
// 原作实证：
// - 专用串行解码队列 label "com.frset.preview-image-decoder"（cstring @0x100b424c0，
//   创建函数 0x1000446c0：objc_allocWithZone → setName → set qos）；
// - 缓存尺寸上限 previewCacheMaxWidth/Height（reflstr 0x100af8490-0x100af8879）；
// - 按屏 previewBackingScale 渲染；缩略 → 大图 previewNeedsFullRebuild。
// 数值⬜ 的默认值见常量区注释。

public final class PreviewImageLoader {

    public static let shared = PreviewImageLoader()

    /// 专用解码队列（label 与 qos 沿原作实证）
    private let decoderQueue = DispatchQueue(label: "com.frset.preview-image-decoder",
                                             qos: .userInitiated)

    /// 解码缓存上限宽（pt；⬜ 原作值未探明，取视网膜屏 popover 内容常见上限）
    public var previewCacheMaxWidth: CGFloat = 1600
    /// 解码缓存上限高（pt；⬜ 原作值未探明）
    public var previewCacheMaxHeight: CGFloat = 1600
    /// 屏幕倍率（按屏渲染；present 时刷新）
    public var previewBackingScale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    /// 解码结果缓存（NSCache 自动响应内存压力）
    private let cache = NSCache<NSString, NSImage>()

    /// 同一 URL 的去重请求表：避免缩略→大图重建期间重复解码
    private var inFlight: [NSString: [(NSImage?) -> Void]] = [:]
    private let lock = NSLock()

    public init() {
        cache.countLimit = 32
    }

    // MARK: 对外加载

    /// 加载图片：先缩略（thumbnailPath 优先），needsFullRebuild=true 时再解码大图（P9）
    /// - Parameters:
    ///   - url: 大图文件路径
    ///   - thumbnailURL: 缩略图文件路径（nil 时直接解码大图）
    ///   - needsFullRebuild: true = previewNeedsFullRebuild（大图重建）
    ///   - completion: 主线程回调
    public func loadImage(at url: URL,
                          thumbnailURL: URL? = nil,
                          needsFullRebuild: Bool,
                          completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(url: url, full: needsFullRebuild) as NSString
        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            completion(cached)
            return
        }
        inFlight[key, default: []].append(completion)
        lock.unlock()

        let full = needsFullRebuild
        let thumbURL = thumbnailURL
        let maxWidth = previewCacheMaxWidth
        let maxHeight = previewCacheMaxHeight
        let backingScale = previewBackingScale

        decoderQueue.async { [weak self] in
            // 大图重建：按缓存上限 × 屏幕倍率解码；缩略：小尺寸解码
            let maxPixel: CGFloat = full
                ? max(maxWidth, maxHeight) * backingScale
                : 320 * backingScale
            let sourceURL = (!full && thumbURL != nil) ? thumbURL! : url
            let image = Self.decode(sourceURL, maxPixel: maxPixel)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lock.lock()
                let waiters = self.inFlight.removeValue(forKey: key) ?? []
                if let image { self.cache.setObject(image, forKey: key) }
                self.lock.unlock()
                waiters.forEach { $0(image) }
            }
        }
    }

    /// 二维码检测（QR 头尾高度分支 F13 用）：在解码队列上调用，避免阻塞主线程
    public static func detectQRCode(in image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                        context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyLow]) else { return false }
        let ciImage = CIImage(cgImage: cgImage)
        return !(detector.features(in: ciImage).isEmpty)
    }

    // MARK: 内部

    private func cacheKey(url: URL, full: Bool) -> String {
        (full ? "full:" : "thumb:") + url.path
    }

    /// 用 ImageIO 按最大边长解码（下采样，避免整图常驻内存）
    private static func decode(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
