import Foundation
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - 图片压缩（本地重采样 + JPEG/PNG 重编码）
// 与原作差异说明：原作 TinyPNG 走网络 API（api.tinify.com，需 API Key、有配额、压缩率更高且支持 WebP）；
// 本实现为**纯本地**方案：CoreGraphics 重采样降尺寸 + JPEG 有损重编码，不联网、无 Key、无配额，
// 压缩率略低（尤其对已优化过的 PNG），但零隐私外发。详见 ToolOutput.note。

public enum ImageCompressor {
    public struct InputInfo {
        var isPNG: Bool
        var hasAlpha: Bool
        var format: String
    }
    public static func inputInfo(path: String) throws -> InputInfo {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw CompressError(message: "无法读取图片：\((path as NSString).lastPathComponent)") }
        guard CGImageSourceGetCount(source) == 1 else { throw CompressError(message: "动图不参与静态图片压缩") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return InputInfo(isPNG: (type as String) == UTType.png.identifier,
                         hasAlpha: (properties?[kCGImagePropertyHasAlpha] as? Bool) == true,
                         format: UTType(type as String)?.preferredFilenameExtension?.uppercased() ?? "图片")
    }
    public struct Result {
        public var originalBytes: Int
        public var compressedBytes: Int
        public var pixelSize: CGSize
        public var image: NSImage
        public var fileURL: URL?

        public var savedPercent: Double {
            guard originalBytes > 0 else { return 0 }
            return Double(originalBytes - compressedBytes) / Double(originalBytes)
        }
    }

    /// 压缩图片文件
    /// - Parameters:
    ///   - path: 输入文件路径（png/jpg/heic 等 CGImageSource 可解码的格式）
    ///   - maxDimension: 最长边上限（0 表示保持原始尺寸）
    ///   - quality: JPEG 压缩质量 0..1
    ///   - asPNG: true 输出 PNG（无损），false 输出 JPEG
    public static func compress(path: String,
                                maxDimension: CGFloat,
                                quality: Double,
                                asPNG: Bool) throws -> Result {
        let url = URL(fileURLWithPath: path)
        let imageData = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw CompressError(message: "无法读取图片：\(url.lastPathComponent)（可能不是支持的图片格式）")
        }
        let cgImage: CGImage?
        if maxDimension > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDimension
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            // maxDimension <= 0：保持原始尺寸（不做缩略图重采样）
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        }
        guard let cgImage else {
            throw CompressError(message: "图片解码失败：\(url.lastPathComponent)")
        }

        let originalBytes = imageData.count
        let data = try encode(cgImage, quality: quality, asPNG: asPNG)

        let ext = asPNG ? "png" : "jpg"
        let outDir = AppDirectories.sub("toolbox")
        let name = url.deletingPathExtension().lastPathComponent
        let outURL = outDir.appendingPathComponent("\(name)-压缩-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try data.write(to: outURL)
        } catch {
            throw CompressError(message: "写出失败：\(error.localizedDescription)")
        }
        guard let image = NSImage(contentsOf: outURL) else {
            throw CompressError(message: "压缩结果解码失败：\(outURL.lastPathComponent)")
        }

        return Result(originalBytes: originalBytes,
                      compressedBytes: data.count,
                      pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                      image: image,
                      fileURL: outURL)
    }

    static func encode(_ image: CGImage, quality: Double, asPNG: Bool) throws -> Data {
        let output = NSMutableData()
        let type: String = asPNG ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else {
            throw CompressError(message: "无法创建图片编码器（目标格式：\(asPNG ? "PNG" : "JPEG")）")
        }
        let properties: [CFString: Any] = asPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.05), 1.0)]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CompressError(message: "图片编码失败")
        }
        return output as Data
    }

    public struct CompressError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// 字节数友好显示
    public static func byteText(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.2f MB", kb / 1024)
    }
}

// MARK: - 二维码生成（CoreImage CIQRCodeGenerator）

public enum QRCodeGenerator {
    /// 生成二维码图片
    /// - Parameters:
    ///   - text: 待编码文本（中文亦可，内部按 UTF-8 编码）
    ///   - size: 输出边长（点）
    ///   - correction: 纠错等级 L / M / Q / H
    public static func image(from text: String, size: CGFloat = 512, correction: String = "M") -> NSImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correctionLevel(correction), forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        // 放大时用 nearest 采样，保持模块边缘锐利（避免默认插值导致的模糊）
        let extent = output.extent
        let scale = max(1, size / max(extent.width, 1))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    private static func correctionLevel(_ level: String) -> String {
        switch level.uppercased() {
        case "L": return "L"
        case "Q": return "Q"
        case "H": return "H"
        default:  return "M"
        }
    }
}
