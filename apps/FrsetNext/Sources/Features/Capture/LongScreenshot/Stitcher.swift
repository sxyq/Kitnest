import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图拼接（多图模式）

/// 把多张「滚动连续截图」拼成一张长图。
///
/// 算法（灰度签名对齐，对齐原作 LongScreenshotStitcher 的评分家族）：
/// 1. 统一宽度：以第一张的宽度为基准，其余等比缩放；
/// 2. 逐对相邻图做重叠检测：把上一张底部 o 行与下一张顶部 o 行各自生成
///    128 宽 DeviceGray 8bpp 灰度签名，按「行、列均步长 2 抽稀」的平均绝对差评分；
/// 3. 重叠搜索带：min(2%~60%) 全枚举贪心（多图模式没有滚动量可依，
///    保留全范围搜索；最小重叠 2 行、评分相同时保留更大重叠）；
/// 4. 差异过大（超过阈值）判定为无重叠，按 0 处理；
/// 5. 按重叠量累加偏移，规范化重绘到 RGBA8888 画布（bytesPerRow = w*4）。
///
/// 流式采捕（被动滚轮驱动 + 恒等帧剔除 + 动态搜索带）见 LongScreenshotStitcher。
public enum Stitcher {

    public struct Result {
        public let image: CGImage
        /// 相邻两张之间检测到的重叠像素高度
        public let overlaps: [Int]
    }

    /// 灰度签名宽（原作对齐签名宽 = min(imgW, 128)，spec 15 §3②）
    private static let signatureWidth = 128
    /// 差异阈值（平均绝对差，0~255 灰度；超过则认为两张图不连续）
    private static let diffThreshold: Double = 22.0
    /// 最小 / 最大重叠比例（相对两张图中较矮那张的高度）
    private static let minOverlapRatio: CGFloat = 0.02
    private static let maxOverlapRatio: CGFloat = 0.6
    /// 最小重叠行数（原作常量，spec 15 @0x100437044）
    private static let minOverlapRows = 2
    // v128（内存优化）：单次拼接帧数上限。N 帧会在合成前全量驻留解码产物，
    // 100 张 2000×1500 截图峰值可达 GB 级。超出直接拒绝（调用方提示分批），
    // 不静默丢帧——丢帧会产出错位长图。
    public static let maxStitchFrames = 24

    /// 拼接 CGImage 序列（至少两张）
    public static func stitch(_ images: [CGImage]) -> Result? {
        guard images.count >= 2 else { return nil }
        // v128（内存优化）：帧数上限，超出拒绝
        guard images.count <= maxStitchFrames else { return nil }

        let width = images[0].width
        // ① 统一宽度并解码成像素缓冲
        // v128（内存优化）：原 buffers 数组整段驻留每帧 RGBA 像素（w×h×4 字节/帧），
        // 但后续只读 buffers[i].height（③④ 的行高）——像素数据纯属白占。
        // 改为只留 height；解码缓冲逐帧释放（guard 保留「解码失败 → nil」语义）。
        var heights: [Int] = []
        var normalized: [CGImage] = []
        for image in images {
            if image.width == width {
                guard let buf = ImageProcessor.rgbaBuffer(image) else { return nil }
                heights.append(buf.height)
                normalized.append(image)
            } else {
                guard let buf = ImageProcessor.rgbaBuffer(image, targetWidth: width) else { return nil }
                heights.append(buf.height)
                if buf.height != image.height {
                    normalized.append(ImageProcessor.resized(image, to: CGSize(width: width, height: buf.height)))
                } else {
                    normalized.append(image)
                }
            }
        }
        guard heights.count == normalized.count, heights.count >= 2 else { return nil }

        // ② 逐对检测重叠
        var overlaps: [Int] = []
        for i in 0..<(heights.count - 1) {
            overlaps.append(detectOverlap(top: normalized[i], bottom: normalized[i + 1]))
        }

        // ③ 计算画布高度（用缓冲高度，保证与缩放后的图一致）
        var totalHeight = heights[0]
        for i in 1..<heights.count {
            totalHeight += heights[i] - overlaps[i - 1]
        }
        guard totalHeight > 0, width > 0 else { return nil }

        // ④ 合成（规范化 RGBA8888 画布，CG 坐标左上原点、从上往下排）
        guard let ctx = CGContext(data: nil,
                                  width: width, height: totalHeight,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))
        ctx.interpolationQuality = .low

        var penY = totalHeight          // 当前绘制行的"顶部"位置（CG 坐标）
        for i in 0..<normalized.count {
            penY -= heights[i]
            ctx.draw(normalized[i], in: CGRect(x: 0, y: penY, width: width, height: heights[i]))
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

    // MARK: 重叠检测（灰度签名对齐）

    /// 在上一张底部与下一张顶部之间寻找最佳重叠行数
    private static func detectOverlap(top: CGImage, bottom: CGImage) -> Int {
        let shorter = min(top.height, bottom.height)
        let maxOverlap = min(Int(CGFloat(shorter) * maxOverlapRatio), shorter - 1)
        let minOverlap = max(minOverlapRows, Int(CGFloat(shorter) * minOverlapRatio))
        guard maxOverlap >= minOverlap else { return 0 }

        // 顶部图底部 o 行、底部图顶部 o 行的灰度签名（宽 128，按需生成）
        func sig(_ image: CGImage, rows: Int, fromTop: Bool) -> GraySignature? {
            let rect = fromTop
                ? CGRect(x: 0, y: 0, width: image.width, height: rows)
                : CGRect(x: 0, y: image.height - rows, width: image.width, height: rows)
            guard let piece = image.cropping(to: rect.integral) else { return nil }
            return LongScreenshotStitcher.graySignature(piece, width: signatureWidth)
        }

        var bestOverlap = 0
        var bestScore = Double.greatestFiniteMagnitude
        var overlap = maxOverlap
        while overlap >= minOverlap {
            // 分数相同时保留更大的重叠（滚屏步长通常偏大），故用严格小于
            if let a = sig(top, rows: overlap, fromTop: false),
               let b = sig(bottom, rows: overlap, fromTop: true) {
                let score = LongScreenshotStitcher.meanAbsDiff(a, b)
                if score < bestScore {
                    bestScore = score
                    bestOverlap = overlap
                }
            }
            overlap -= 1
        }

        // 差异过大 → 判定两张图不连续，不重叠
        return bestScore <= diffThreshold ? bestOverlap : 0
    }
}
