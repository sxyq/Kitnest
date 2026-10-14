import AppKit
import CoreGraphics
import Foundation

// MARK: - 灰度签名（DeviceGray 8bpp）

/// 一张图的灰度签名：DeviceGray 8bpp 位图按行展开的字节序列（左上原点）。
/// 生成方式对齐原作 LongScreenshotStitcher（spec 15 @0x1004564b4）：
/// CGBitmapContextCreate(bitsPerComponent: 8, DeviceGray)，把原图等比缩到签名宽后绘入。
public struct GraySignature {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]
}

// MARK: - 长截图流式拼接器

/// 长截图流式拼接（原作 ObjC 可见类 `_TtC5Frset22LongScreenshotStitcher`，spec 15）：
/// 1) 恒等帧剔除：512 宽灰度签名 meanAbsDiff < 2.5 → 视为画面未滚动，丢弃；
/// 2) 动态搜索带：min(|累计δ|×scale×4 + 24, 64) 行，上界 0.12 × 高度，粗搜步进 24；
/// 3) 对齐评分：128 宽 DeviceGray 签名 + 行列步长 2 抽稀的平均绝对差；
/// 4) 追加门槛：最小重叠 2 行、新内容 < 15 行不追加（等待继续滚动）；
/// 5) 合成：画布规范化重绘 RGBA8888（bytesPerRow = w*4，插值 .low）。
final class LongScreenshotStitcher {

    // MARK: 算法常量（逐一对应 spec 15 反汇编证据）

    /// 滚动量过滤阈值 scrollingDeltaEpsilon（@0x1004395ec）
    static let scrollEpsilon: Double = 0.08
    /// 恒等帧判定阈值（512 宽灰度 meanAbsDiff，@0x100436da8）
    static let identityThreshold: Double = 2.5
    /// 恒等判定签名宽（@0x100436d58，w1=0x200）
    static let identitySignatureWidth = 512
    /// 对齐评分签名宽（@0x100436e0c）
    static let alignmentSignatureWidth = 128
    /// 动态搜索带基础行数（@0x100447814：+24）
    static let bandBaseRows = 24
    /// 动态搜索带系数（|δ|×scale×4）
    static let bandDeltaScale: Double = 4.0
    /// 动态搜索带上限（@0x100447878，0x40 钳制）
    static let bandMaxRows = 64
    /// 搜索上界比例：0.12 × 画布高（@0x100458b54）
    static let searchFraction: Double = 0.12
    /// 粗搜步进（@0x100458c68，umulh ÷24）
    static let coarseStep = 24
    /// 最小重叠行数（@0x100437044）
    static let minOverlapRows = 2
    /// 最小新内容行数：低于则不追加（@0x100436fd4 / 另一处 16 @0x1004372c0）
    static let minNewRows = 15

    // MARK: 状态

    /// 累积画布（规范化 RGBA8888）
    private(set) var canvas: CGImage?
    /// 画布像素宽（拼接过程中宽度恒定）
    private(set) var canvasWidth = 0
    /// 上一帧的恒等判定签名（512 宽）
    private var lastIdentitySignature: GraySignature?
    /// 已累计的追加行数（诊断用）
    private(set) var appendedRows = 0

    // MARK: 签名生成

    /// 生成灰度签名：等比缩到指定宽（高按比例，至少 1 行），DeviceGray 8bpp
    static func graySignature(_ image: CGImage, width: Int) -> GraySignature? {
        let w = max(1, min(width, image.width))
        let h = max(1, Int((CGFloat(image.height) * CGFloat(w) / CGFloat(max(image.width, 1))).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes,
                                  width: w, height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return GraySignature(width: w, height: h, bytes: bytes)
    }

    /// 平均绝对差（行、列均步长 2 抽稀，对齐原作 0x100456650）
    static func meanAbsDiff(_ a: GraySignature, _ b: GraySignature) -> Double {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard w > 0, h > 0 else { return .greatestFiniteMagnitude }
        var sum = 0
        var count = 0
        // 行、列均步长 2（adds #2 @0x10045677c / @0x1004567a8）
        var y = 0
        while y < h {
            let rowA = y * a.width, rowB = y * b.width
            var x = 0
            while x < w {
                sum += abs(Int(a.bytes[rowA + x]) - Int(b.bytes[rowB + x]))
                count += 1
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return .greatestFiniteMagnitude }
        return Double(sum) / Double(count)
    }

    // MARK: 追加一帧

    /// 追加一帧；返回是否产生了追加（false = 恒等帧丢弃 / 新内容不足 / 对齐失败）。
    /// - Parameters:
    ///   - frame: 本次采捕的选区帧
    ///   - pendingDelta: 自上帧以来的滚动累积量（AppKit 坐标向下为正的 deltaY）
    ///   - scale: 内容缩放（imgW / 选区宽，session 提供）
    @discardableResult
    func append(frame: CGImage, pendingDelta delta: Double, scale: Double) -> Bool {
        // ① 恒等帧剔除：与上一帧的 512 宽签名比较（@0x100436cf0）
        if let last = lastIdentitySignature,
           let sig = Self.graySignature(frame, width: Self.identitySignatureWidth),
           Self.meanAbsDiff(sig, last) < Self.identityThreshold {
            lastIdentitySignature = sig
            return false
        }
        lastIdentitySignature = Self.graySignature(frame, width: Self.identitySignatureWidth)

        // 首帧：直接作为画布
        guard let base = canvas else {
            guard let normalized = Self.normalized(frame) else { return false }
            canvas = normalized
            canvasWidth = normalized.width
            appendedRows = normalized.height
            return true
        }

        let frameH = frame.height
        guard frame.width == base.width, frameH > Self.minOverlapRows else {
            // 宽度不一致的帧无法对齐（理论上采捕原语保证同宽）
            return false
        }

        // ② 动态搜索带：min(|δ|×scale×4 + 24, 64)，上界 0.12×高（@0x100447814 / @0x100458b54）
        let band = min(Int(abs(delta) * scale * Self.bandDeltaScale) + Self.bandBaseRows, Self.bandMaxRows)
        var limit = min(band, Int(Double(base.height) * Self.searchFraction))
        limit = min(limit, base.height - 1, frameH - 1)
        guard limit >= Self.minOverlapRows else { return false }

        // ③ 粗搜（步进 24）+ 精搜（best ± coarseStep 内逐行），128 宽签名评分
        guard let frameSigTop = Self.topRegionSignature(frame) else { return false }
        let best = Self.searchAlignment(canvas: base,
                                        frameTopSignature: frameSigTop,
                                        frame: frame,
                                        limit: limit)
        guard let overlap = best else { return false }   // 候选分类返回 2 = 放弃（0x1004370c0）

        // ④ 追加判定：新内容 < 15 行不追加，等待继续滚动（@0x100436fd4）
        let newRows = frameH - overlap
        guard newRows >= Self.minNewRows else { return false }

        // ⑤ 合成到新画布（画布在上、新帧在下，重叠 newRows 行被覆盖）
        guard let merged = Self.composite(canvas: base, frame: frame, overlap: overlap) else { return false }
        canvas = merged
        appendedRows += newRows
        return true
    }

    // MARK: 对齐搜索

    /// 帧顶部区域的 128 宽签名（供画布底部区域对齐评分）
    private static func topRegionSignature(_ frame: CGImage) -> GraySignature? {
        graySignature(frame, width: alignmentSignatureWidth)
    }

    /// 在画布底部与帧顶部之间搜索最佳重叠行数。
    /// 评分对象：画布底部 overlap 行（灰度签名，宽 min(128, 帧宽)）vs 帧顶部 overlap 行。
    private static func searchAlignment(canvas: CGImage,
                                        frameTopSignature: GraySignature,
                                        frame: CGImage,
                                        limit: Int) -> Int? {
        // 画布整图的 128 宽签名（后续按行偏移取底部子区域比较）
        guard let canvasSig = graySignature(canvas, width: min(alignmentSignatureWidth, frame.width)) else { return nil }
        guard let frameSig = graySignature(frame, width: min(alignmentSignatureWidth, frame.width)) else { return nil }

        // 签名坐标 = 图像坐标 × (签名高 / 图像高)。签名等比缩放，行的比例一致。
        let canvasRatio = Double(canvasSig.height) / Double(canvas.height)
        let frameRatio = Double(frameSig.height) / Double(frame.height)

        func score(_ overlap: Int) -> Double {
            // 画布底部 overlap 行 → 签名中的对应行区间
            let cStart = Int(Double(canvas.height - overlap) * canvasRatio)
            let cRows = max(1, Int(Double(overlap) * canvasRatio))
            let cRegion = GraySignature(width: canvasSig.width, height: cRows,
                                        bytes: Array(canvasSig.bytes[(cStart * canvasSig.width)...]))
            // 帧顶部 overlap 行 → 签名中的对应行区间
            let fRows = max(1, Int(Double(overlap) * frameRatio))
            let fRegion = GraySignature(width: frameSig.width, height: fRows,
                                        bytes: Array(frameSig.bytes[..<(fRows * frameSig.width)]))
            return meanAbsDiff(cRegion, fRegion)
        }

        // 粗搜：自上而下步进 24（重叠大 → 先命中；分数相同保留更大重叠）
        var bestOverlap = -1
        var bestScore = Double.greatestFiniteMagnitude
        var overlap = limit
        while overlap >= minOverlapRows {
            let s = score(overlap)
            if s < bestScore {
                bestScore = s
                bestOverlap = overlap
            }
            overlap -= coarseStep
        }
        guard bestOverlap >= minOverlapRows else { return nil }

        // 精搜：best ± coarseStep 范围内逐行（0x10045965c）
        let fineLo = max(minOverlapRows, bestOverlap - coarseStep)
        let fineHi = min(limit, bestOverlap + coarseStep)
        overlap = fineHi
        while overlap >= fineLo {
            let s = score(overlap)
            if s < bestScore {
                bestScore = s
                bestOverlap = overlap
            }
            overlap -= 1
        }
        return bestOverlap
    }

    // MARK: 合成

    /// 把画布规范化为 RGBA8888（bytesPerRow = w*4，插值 .low，对齐 0x100443340）
    static func normalized(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 画布在上、新帧在下，重叠 overlap 行：帧整体画在 y = -(frameH - overlap) 之上，
    /// 即帧顶对齐画布底上移 overlap 行（CG 坐标左下原点）。
    private static func composite(canvas: CGImage, frame: CGImage, overlap: Int) -> CGImage? {
        let w = canvas.width
        let newH = canvas.height + frame.height - overlap
        guard w > 0, newH > 0 else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: w, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: newH))
        ctx.interpolationQuality = .low
        // 旧画布贴顶
        ctx.draw(canvas, in: CGRect(x: 0, y: CGFloat(newH - canvas.height), width: CGFloat(w), height: CGFloat(canvas.height)))
        // 新帧：顶部与画布底部重叠 overlap 行
        ctx.draw(frame, in: CGRect(x: 0, y: CGFloat(newH - canvas.height - (frame.height - overlap)),
                                   width: CGFloat(w), height: CGFloat(frame.height)))
        return ctx.makeImage()
    }
}
