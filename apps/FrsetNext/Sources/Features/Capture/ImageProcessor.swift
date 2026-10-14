import AppKit
import CoreGraphics
import ImageIO

// MARK: - 图像处理工具（缩放 / 裁剪 / 格式转换 / 像素缓冲）

public enum ImageProcessor {

    // MARK: 格式转换

    /// CGImage → PNG 数据（截图落盘统一用 PNG，无损、支持透明）
    public static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// CGImage → JPEG 数据（长截图体积过大时用）
    public static func jpegData(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, opts)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: 缩放

    /// 等比缩放到指定最长边（返回新图，输入不变）
    public static func scaled(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let side = max(w, h)
        guard side > maxSide, maxSide > 0 else { return image }
        let ratio = maxSide / side
        return resized(image, to: CGSize(width: max(w * ratio, 1), height: max(h * ratio, 1)))
    }

    /// 强制缩放到目标尺寸（用于长截图统一宽度）
    public static func resized(_ image: CGImage, to size: CGSize) -> CGImage {
        let w = max(Int(size.width.rounded()), 1)
        let h = max(Int(size.height.rounded()), 1)
        guard let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: 裁剪

    /// 按"点坐标"的屏幕矩形裁剪屏幕快照。
    /// - Parameters:
    ///   - image: 屏幕快照（设备像素，左上原点）
    ///   - rect:  屏幕全局坐标（点，左下原点，AppKit 坐标系）
    ///   - screenFrame: 该快照对应的屏幕 frame（点）
    public static func crop(_ image: CGImage, rectInPoints rect: CGRect, screenFrame: CGRect) -> CGImage? {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        let sx = CGFloat(image.width) / screenFrame.width
        let sy = CGFloat(image.height) / screenFrame.height
        // 先转到快照内相对坐标（左下原点），再翻成 CGImage 的左上原点
        var r = CGRect(x: (rect.minX - screenFrame.minX) * sx,
                       y: (rect.minY - screenFrame.minY) * sy,
                       width: rect.width * sx,
                       height: rect.height * sy)
        r.origin.y = CGFloat(image.height) - r.maxY
        r = r.integral
        r = r.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, !r.isEmpty, r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    // MARK: 互转

    /// CGImage → NSImage（按像素尺寸，避免 NSImage 默认 72dpi 造成的缩放错觉）
    public static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// 从 Data 解码出 CGImage（优先走 ImageIO，避免 NSImage 的线程/尺寸坑）
    public static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 从文件 URL 解码出 CGImage
    public static func cgImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - 像素缓冲（放大镜取色 / 长截图行匹配共用）

/// 32 位 RGBA 像素缓冲，行优先、左上原点（与 CGContext 一致）
public struct RGBABuffer {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// 取整行平均色（0~255），用于行相似度比较
    public func rowMean(_ y: Int) -> (r: Float, g: Float, b: Float)? {
        guard y >= 0, y < height, width > 0 else { return nil }
        var sr = 0, sg = 0, sb = 0
        let base = y * width * 4
        for x in 0..<width {
            let i = base + x * 4
            sr += Int(pixels[i]); sg += Int(pixels[i + 1]); sb += Int(pixels[i + 2])
        }
        let f = Float(width)
        return (Float(sr) / f, Float(sg) / f, Float(sb) / f)
    }

    /// 取单点颜色（0~255）
    public func colorAt(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }
}

public extension ImageProcessor {
    /// 把 CGImage 解码到 RGBA 缓冲（可同时缩放到指定宽度）
    static func rgbaBuffer(_ image: CGImage, targetWidth: Int? = nil) -> RGBABuffer? {
        let w = targetWidth ?? image.width
        guard w > 0, image.width > 0, image.height > 0 else { return nil }
        let h = targetWidth == nil ? image.height
              : max(Int((CGFloat(image.height) * CGFloat(w) / CGFloat(image.width)).rounded()), 1)
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &raw,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBABuffer(width: w, height: h, pixels: raw)
    }
}
