import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图拼接

/// 把多张「滚动连续截图」拼成一张长图。
///
/// 算法（贪心、按行匹配）：
/// 1. 统一宽度：以第一张的宽度为基准，其余等比缩放；
/// 2. 逐对相邻图做重叠检测：把上一张底部的 o 行与下一张顶部的 o 行做成"行平均色"签名，
///    枚举 o（从大到小）取差异最小的那个作为重叠高度；
/// 3. 差异过大（超过阈值）判定为无重叠，按 0 处理；
/// 4. 按重叠量累加偏移，画到一张大画布上。
///
/// 与原作差异：原作的长截图走滚动捕获（逐屏自动滚动 + 拼接），重建版采用
/// "用户手动提供多张截图再拼接"的简化路径；匹配上这里只用行平均色的贪心搜索
/// （O(n·maxOverlap)），未做原作可能使用的特征点/模板匹配，速度够用、实现可控。
public enum Stitcher {

    public struct Result {
        public let image: CGImage
        /// 相邻两张之间检测到的重叠像素高度
        public let overlaps: [Int]
    }

    /// 行平均色差异阈值（0~255 单通道均值差，超过则认为两张图不连续）
    private static let diffThreshold: Float = 22.0
    /// 最小 / 最大重叠比例（相对两张图中较矮那张的高度）
    private static let minOverlapRatio: CGFloat = 0.02
    private static let maxOverlapRatio: CGFloat = 0.6

    /// 拼接 CGImage 序列（至少两张）
    public static func stitch(_ images: [CGImage]) -> Result? {
        guard images.count >= 2 else { return nil }

        let width = images[0].width
        // ① 统一宽度并解码成像素缓冲
        var buffers: [RGBABuffer] = []
        var normalized: [CGImage] = []
        for image in images {
            if image.width == width {
                guard let buf = ImageProcessor.rgbaBuffer(image) else { return nil }
                buffers.append(buf)
                normalized.append(image)
            } else {
                guard let buf = ImageProcessor.rgbaBuffer(image, targetWidth: width) else { return nil }
                buffers.append(buf)
                if buf.height != image.height {
                    normalized.append(ImageProcessor.resized(image, to: CGSize(width: width, height: buf.height)))
                } else {
                    normalized.append(image)
                }
            }
        }
        guard buffers.count == normalized.count, buffers.count >= 2 else { return nil }

        // ② 逐对检测重叠
        var overlaps: [Int] = []
        for i in 0..<(buffers.count - 1) {
            overlaps.append(detectOverlap(top: buffers[i], bottom: buffers[i + 1]))
        }

        // ③ 计算画布高度（用缓冲高度，保证与缩放后的图一致）
        var totalHeight = buffers[0].height
        for i in 1..<buffers.count {
            totalHeight += buffers[i].height - overlaps[i - 1]
        }
        guard totalHeight > 0, width > 0 else { return nil }

        // ④ 合成（CG 坐标左上原点，从上往下排）
        guard let ctx = CGContext(data: nil,
                                  width: width, height: totalHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))
        ctx.interpolationQuality = .high

        var penY = totalHeight          // 当前绘制行的"顶部"位置（CG 坐标）
        for i in 0..<normalized.count {
            penY -= buffers[i].height
            ctx.draw(normalized[i], in: CGRect(x: 0, y: penY, width: width, height: buffers[i].height))
            if i + 1 < normalized.count { penY += overlaps[i] }
        }

        guard let output = ctx.makeImage() else { return nil }
        return Result(image: output, overlaps: overlaps)
    }

    /// 从文件 URL 拼接
    public static func stitch(urls: [URL]) -> Result? {
        let images = urls.compactMap { ImageProcessor.cgImage(from: $0) }
        guard images.count == urls.count else { return nil }
        return stitch(images)
    }

    // MARK: 重叠检测

    /// 在上一张底部与下一张顶部之间寻找最佳重叠行数
    private static func detectOverlap(top: RGBABuffer, bottom: RGBABuffer) -> Int {
        let shorter = min(top.height, bottom.height)
        let maxOverlap = min(Int(CGFloat(shorter) * maxOverlapRatio), shorter - 1)
        let minOverlap = max(2, Int(CGFloat(shorter) * minOverlapRatio))
        guard maxOverlap >= minOverlap else { return 0 }

        var bestOverlap = 0
        var bestScore = Float.greatestFiniteMagnitude

        // 从大到小枚举：分数相同时保留更大的重叠（滚屏步长通常偏大）
        var overlap = maxOverlap
        while overlap >= minOverlap {
            let score = rowDiff(top: top, bottom: bottom, overlap: overlap)
            if score < bestScore {
                bestScore = score
                bestOverlap = overlap
            }
            overlap -= 1
        }

        // 差异过大 → 判定两张图不连续，不重叠
        return bestScore <= diffThreshold ? bestOverlap : 0
    }

    /// 上一张底部 overlap 行 与 下一张顶部 overlap 行 的平均单通道色差
    private static func rowDiff(top: RGBABuffer, bottom: RGBABuffer, overlap: Int) -> Float {
        let topStart = top.height - overlap
        var sum: Float = 0
        var count: Float = 0
        for r in 0..<overlap {
            guard let a = top.rowMean(topStart + r), let b = bottom.rowMean(r) else { continue }
            sum += abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
            count += 1
        }
        return count > 0 ? sum / count : Float.greatestFiniteMagnitude
    }
}
