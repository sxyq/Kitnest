import AppKit
import CoreGraphics
import CoreText
import CoreImage

// MARK: - 录屏叠加层绘制（按键 / 点击）
//
// 每帧都要出图，所以这里只画**很小的画布**（按键条 ~720×110，点击环 160×160），
// 再由录制器按位置合成到整帧上。不要按视频分辨率建位图——
// 4K/60fps 下一帧全画布就是 33MB，光分配就能把帧率打下来。

public enum RecordingCompositor {

    // MARK: 出图缓存（2026-11-26 修复 medium）
    //
    // 键帽条与点击环的内容都是「少量离散状态」：一次录制里 pixelScale 与
    // reduceTransparency 固定，键帽内容只在按键变化时变，点击环只随 progress 变。
    // 因此把结果按状态记忆化，避免 30–60fps 下每帧重复建位图（键帽条约 316KB/帧）。
    // 缓存都有上界，命中失败就重画，不会随录制时长增长。

    private struct KeyOverlayKey: Hashable {
        let texts: [String]
        let scaleKey: Int
        let reduceTransparency: Bool
    }

    private static let keyCacheLock = NSLock()
    private static var keyCacheKey: KeyOverlayKey?
    private static var keyCacheImage: CGImage?

    private struct ClickOverlayKey: Hashable {
        let step: Int
        let isRight: Bool
        let scaleKey: Int
        let reduceTransparency: Bool
    }

    /// progress 量化档数：0.65s 生命周期内约 25 帧，视觉上足够平滑
    private static let clickSteps = 24
    private static let clickCacheLock = NSLock()
    private static var clickCache: [ClickOverlayKey: CGImage] = [:]
    /// 256 档 × 2 色 × 2 透明度理论上界；这里只保留最近用到的，1 次录制实际 ~50 张
    private static let clickCacheLimit = 64

    /// 清掉出图缓存（录完一次后释放位图占用；预览下次重绘会自己重建）
    static func clearCaches() {
        keyCacheLock.lock()
        keyCacheKey = nil
        keyCacheImage = nil
        keyCacheLock.unlock()
        clickCacheLock.lock()
        clickCache.removeAll()
        clickCacheLock.unlock()
    }

    /// 按键条：最多显示 4 个键帽，右对齐贴着画面底部居中
    /// - Parameter pixelScale: 视频像素 / 点（Retina 录制时 2）
    /// - Parameter now: 保留给淡出用；当前键帽条不做逐键淡出（TTL 到期整条消失）
    public static func keyOverlay(keys: [RecordedKey], now: CFTimeInterval,
                                  pixelScale: CGFloat, reduceTransparency: Bool = false) -> CGImage? {
        let visible = keys.suffix(4)
        guard !visible.isEmpty else { return nil }
        let cacheKey = KeyOverlayKey(texts: visible.map(\.text),
                                     scaleKey: Int((pixelScale * 100).rounded()),
                                     reduceTransparency: reduceTransparency)
        keyCacheLock.lock()
        if keyCacheKey == cacheKey, let cached = keyCacheImage {
            keyCacheLock.unlock()
            return cached
        }
        keyCacheLock.unlock()
        let pad: CGFloat = 10 * pixelScale
        let capH: CGFloat = 46 * pixelScale
        let gap: CGFloat = 8 * pixelScale
        let font = NSFont.systemFont(ofSize: 20 * pixelScale, weight: .semibold)

        var widths: [CGFloat] = []
        for key in visible {
            let w = (key.text as NSString).size(withAttributes: [.font: font]).width
            widths.append(max(w + 26 * pixelScale, capH))
        }
        let totalW = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)) + pad * 2
        let height = capH + pad * 2
        guard totalW > 1,
              let ctx = CGContext(data: nil, width: Int(totalW.rounded()), height: Int(height.rounded()),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: totalW, height: height))
        let bg = NSColor(calibratedWhite: 0.08, alpha: reduceTransparency ? 1 : 0.82).cgColor
        let stroke = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor

        var x = pad
        for (index, key) in visible.enumerated() {
            let w = widths[index]
            let rect = CGRect(x: x, y: pad, width: w, height: capH)
            let path = CGPath(roundedRect: rect, cornerWidth: 9 * pixelScale,
                              cornerHeight: 9 * pixelScale, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(bg)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(1 * pixelScale)
            ctx.strokePath()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: key.text,
                                                                          attributes: attrs))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2,
                                       y: rect.midY - bounds.height / 2 - bounds.origin.y * 0)
            CTLineDraw(line, ctx)
            x += w + gap
        }
        guard let image = ctx.makeImage() else { return nil }
        keyCacheLock.lock()
        keyCacheKey = cacheKey
        keyCacheImage = image
        keyCacheLock.unlock()
        return image
    }

    /// 点击环：160×160 画布，progress 0→1 时半径扩散、透明度衰减
    /// progress 按 1/24 量化后记忆化（2026-11-26 修复）：合成路径每帧对每个存活点击调用，
    /// 直接复用量化后的位图，不再每帧新建 CGContext。
    public static func clickOverlay(progress: CGFloat, isRight: Bool,
                                    pixelScale: CGFloat, reduceTransparency: Bool = false) -> CGImage? {
        let clamped = max(0, min(1, progress))
        let step = Int((clamped * CGFloat(clickSteps)).rounded())
        let cacheKey = ClickOverlayKey(step: step, isRight: isRight,
                                       scaleKey: Int((pixelScale * 100).rounded()),
                                       reduceTransparency: reduceTransparency)
        clickCacheLock.lock()
        let cached = clickCache[cacheKey]
        clickCacheLock.unlock()
        if let cached { return cached }

        guard let image = drawClickOverlay(progress: CGFloat(step) / CGFloat(clickSteps),
                                          isRight: isRight, pixelScale: pixelScale,
                                          reduceTransparency: reduceTransparency) else { return nil }
        clickCacheLock.lock()
        if clickCache.count >= clickCacheLimit { clickCache.removeAll(keepingCapacity: true) }
        clickCache[cacheKey] = image
        clickCacheLock.unlock()
        return image
    }

    private static func drawClickOverlay(progress: CGFloat, isRight: Bool,
                                         pixelScale: CGFloat, reduceTransparency: Bool) -> CGImage? {
        let side = 160 * pixelScale
        guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let center = CGPoint(x: side / 2, y: side / 2)
        // progress 已由 clickOverlay 钳制并量化，这里直接用
        let clamped = progress
        let color = isRight
            ? CGColor(red: 0.28, green: 0.62, blue: 1, alpha: 1)
            : CGColor(red: 1, green: 0.42, blue: 0.28, alpha: 1)

        // 中心点
        ctx.setFillColor(color.copy(alpha: reduceTransparency ? 1 : 0.95) ?? color)
        ctx.fillEllipse(in: CGRect(x: center.x - 7 * pixelScale, y: center.y - 7 * pixelScale,
                                   width: 14 * pixelScale, height: 14 * pixelScale))
        // 扩散环（两圈：主环 + 稍慢的尾环）
        for (offset, alpha) in [(CGFloat(0), CGFloat(0.9)), (CGFloat(0.14), CGFloat(0.35))] {
            let t = max(0, clamped - offset) / (1 - offset)
            guard t > 0 else { continue }
            let radius = (10 + 58 * t) * pixelScale
            ctx.setStrokeColor(color.copy(alpha: reduceTransparency ? 1 : alpha * (1 - t)) ?? color)
            ctx.setLineWidth((5 - 3 * t) * pixelScale)
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
        }
        return ctx.makeImage()
    }

    /// 正式录制和设置示意图共用同一合成；输入由调用方提供，这里不采集设备或键鼠。
    static func composite(image: CIImage, camera: CIImage?, options: RecordingOptions,
                          keys: [RecordedKey], clicks: [RecordedClick], now: CFTimeInterval,
                          pixelScale: CGFloat, regionOrigin: CGPoint = .zero,
                          reduceTransparency: Bool = false) -> CIImage {
        var result = image
        let size = image.extent.size
        if options.cameraEnabled, let camera {
            let rect = cameraRect(videoSize: size, corner: options.cameraCorner, widthFraction: options.cameraScale)
            let transform = CGAffineTransform(scaleX: rect.width / max(camera.extent.width, 1),
                                              y: rect.height / max(camera.extent.height, 1))
            let overlay = camera.transformed(by: transform)
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: size.height - rect.maxY))
            result = overlay.composited(over: result)
        }
        if options.showClicks,
           let layer = clickLayer(clicks: clicks, now: now, size: size, pixelScale: pixelScale,
                                  regionOrigin: regionOrigin, reduceTransparency: reduceTransparency) {
            // 2026-11-26 修复（medium）：整帧只叠一次点击层，不再「每个点击一个 composited 节点」
            result = layer.composited(over: result)
        }
        if options.showKeys, let strip = keyOverlay(keys: keys, now: now, pixelScale: pixelScale,
                                                    reduceTransparency: reduceTransparency) {
            let overlay = CIImage(cgImage: strip)
                .transformed(by: CGAffineTransform(translationX: (size.width - CGFloat(strip.width)) / 2,
                                                  y: 28 * pixelScale))
            result = overlay.composited(over: result)
        }
        return result
    }

    /// 把这一帧所有存活点击环合并成**一张**覆盖层位图（2026-11-26 修复 medium）。
    ///
    /// 原实现是「每个点击建一个 CIImage 节点再逐次 composited」，clicks 上限 12 →
    /// 每帧 12 个新节点。这里先在一张只覆盖「点击联合矩形」的小位图上把所有环画好，
    /// 再整层叠到主帧（1 次 composite）。
    /// 唯一例外：联合矩形过大（多点散布全屏）时不合并，退回逐环 composited ——
    /// 否则又会回到「按整帧建位图」的老陷阱（4K 一帧 33MB）。
    private static func clickLayer(clicks: [RecordedClick], now: CFTimeInterval, size: CGSize,
                                   pixelScale: CGFloat, regionOrigin: CGPoint,
                                   reduceTransparency: Bool) -> CIImage? {
        /// CI 坐标（左下原点）下的环位置与尺寸
        var rings: [(image: CGImage, x: CGFloat, y: CGFloat)] = []
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for click in clicks {
            let progress = CGFloat((now - click.time) / RecordingInputMonitor.clickTTL)
            guard let ring = clickOverlay(progress: progress, isRight: click.isRight,
                                          pixelScale: pixelScale,
                                          reduceTransparency: reduceTransparency) else { continue }
            let side = CGFloat(ring.width)
            let cx = (click.point.x - regionOrigin.x) * pixelScale
            let cy = (click.point.y - regionOrigin.y) * pixelScale
            // 越界剔除（与旧行为一致：完全在帧外的点击不参与合成）
            guard cx > -side, cy > -side, cx < size.width + side, cy < size.height + side else { continue }
            let x = cx - side / 2
            let y = size.height - cy - side / 2
            rings.append((image: ring, x: x, y: y))
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x + side); maxY = max(maxY, y + side)
        }
        guard let first = rings.first else { return nil }
        if rings.count == 1 {
            return CIImage(cgImage: first.image)
                .transformed(by: CGAffineTransform(translationX: first.x, y: first.y))
        }

        let unionW = maxX - minX
        let unionH = maxY - minY
        let unionArea = unionW * unionH
        // 200 万像素（2x 下约 8MB）以内才合并；超过就走逐环叠加
        if unionArea > 2_000_000 {
            var layer = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: CGRect(origin: .zero, size: size))
            for ring in rings {
                layer = CIImage(cgImage: ring.image)
                    .transformed(by: CGAffineTransform(translationX: ring.x, y: ring.y))
                    .composited(over: layer)
            }
            return layer
        }

        let w = Int(unionW.rounded(.up))
        let h = Int(unionH.rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.interpolationQuality = .none
        for ring in rings {
            let side = CGFloat(ring.image.width)
            ctx.draw(ring.image, in: CGRect(x: ring.x - minX, y: ring.y - minY,
                                            width: side, height: side))
        }
        guard let merged = ctx.makeImage() else { return nil }
        return CIImage(cgImage: merged)
            .transformed(by: CGAffineTransform(translationX: minX, y: minY))
    }

    /// 摄像头画中画：按角与比例算矩形（**视频像素坐标，左上原点**）
    public static func cameraRect(videoSize: CGSize, corner: RecordingCorner,
                                  widthFraction: CGFloat) -> CGRect {
        let margin = videoSize.width * 0.02
        // 4:3 竖版画中画（人脸比 16:9 占的地方更合适）
        let w = videoSize.width * max(0.10, min(0.35, widthFraction))
        let h = w * 4 / 3
        switch corner {
        case .bottomRight: return CGRect(x: videoSize.width - w - margin, y: videoSize.height - h - margin, width: w, height: h)
        case .bottomLeft:  return CGRect(x: margin, y: videoSize.height - h - margin, width: w, height: h)
        case .topRight:    return CGRect(x: videoSize.width - w - margin, y: margin, width: w, height: h)
        case .topLeft:     return CGRect(x: margin, y: margin, width: w, height: h)
        }
    }
}
