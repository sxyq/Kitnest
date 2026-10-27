import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图流式拼接器（v151：NCC 对齐内核）
//
// 历史教训（v68-v150）：
//   · v68-v149 维护「世界坐标并集画布」，每帧重绘整张画布 O(n²)，宽度还会漂移；
//   · v150 改成定宽画布只追加条带（方向对），但对齐用的是「绝对像素差 + 最差行惩罚」：
//       – 阈值 maxAlignScore=8 对真实网页几乎不可能满足（文字行亚像素错位就差 20+）；
//       – 吸顶导航栏在画面顶部一动不动，dy=0 反而拿高分；
//       – 一旦某帧失败，下一帧会因为「和上次采样帧相同」被静默跳过——整段内容永久丢失。
//     实测（2026-10-27 用户机器）：滚动十几屏，画布始终停在首帧 1015×445。
//
// v151 重做对齐：
//   1. **行投影粗搜**：先按每行灰度均值做一维 NCC，全范围（≈±帧高）扫一遍，成本 O(行数)；
//   2. **二维 NCC 精校**：对粗搜 top-N 候选做逐像素 NCC（亮度均值/方差归一化），
//      亚像素错位、整体明暗变化都不影响得分，正确位移通常 >0.98；
//   3. **忽略顶部 13%**：吸顶导航/固定工具条不参与匹配，避免 dy=0 拿高分；
//   4. **上帧兜底**：画布对齐失败时，改用「上一帧成功追加的帧」做参照（短位移必然有重叠）；
//   5. **不再静默丢弃**：只有与「上次成功追加的帧」几乎完全相同才跳过；失败帧下个 tick 会重试。

/// RGBA8888 像素缓冲（bytesPerRow = w*4，左上原点行序）
struct LongShotRGBA {
    let w: Int
    let h: Int
    var bytes: [UInt8]

    /// 用 malloc 分配上下文内存（&array 桥接指针生命周期不保证，合成后内容会脱节）
    private static func drawToBuffer(_ image: CGImage, w: Int, h: Int) -> [UInt8] {
        let count = w * h * 4
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
        defer { ptr.deallocate() }
        memset(ptr, 0, count)
        if let ctx = CGContext(data: ptr, width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Array(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    init(image: CGImage) {
        let w = image.width, h = image.height
        self.w = w
        self.h = h
        self.bytes = Self.drawToBuffer(image, w: w, h: h)
    }

    init(w: Int, h: Int, bytes: [UInt8]) {
        self.w = w; self.h = h; self.bytes = bytes
    }
}

final class LongScreenshotStitcher {

    // MARK: - 追加结果

    enum Outcome {
        /// 追加了 rows 行新内容（首帧时 = 帧高）
        case appended(rows: Int)
        /// 没有可追加的新内容（内容没变 / 向上滚动 / 位移过小）
        case unchanged(String)
        /// 对齐失败（找不到可信位移、横向漂移、尺寸不一致）
        case failed(String)

        var isAppended: Bool { if case .appended = self { return true }; return false }
    }

    // MARK: - 算法常量

    /// 滚动量过滤阈值
    static let scrollEpsilon: Double = 0.08
    /// 恒等帧判定阈值（512 宽灰度签名 meanAbsDiff）——只用来过滤**完全静止**的画面
    static let identityThreshold: Double = 1.2
    /// 恒等判定签名宽
    static let identitySignatureWidth = 512
    /// 最小新内容（像素）：1-2px 抖动不追加
    static let minNewRows = 2
    /// 最小重叠（占帧高的比例）：低于这个比例「空白对空白」容易误判。
    /// v152：25% → 18%。25% 时最大可对齐位移只有 75% 帧高，且大位移下重叠区
    /// 扣掉吸顶栏后不足阈值 → 快速滚动整段丢失（实测 5320px 处开始连续失败）。
    static let minOverlapFraction: Double = 0.18
    /// 忽略画面顶部比例（吸顶导航、固定工具条）
    static let topSkipFraction: Double = 0.13
    /// 接受对齐的最低 NCC（真实文字页面正确对齐通常 >0.97）
    static let minNCC: Double = 0.90
    /// 允许的横向位移（超过视为画面横向漂移/误匹配，整帧丢弃）
    static let maxHorizontalDrift = 1
    /// 画布高度上限（像素，防内存爆炸：1285×20000×4 ≈ 103MB）
    static let maxCanvasSide = 20000
    /// 对齐过程追踪（排障用；nil 时零开销）
    static var trace: ((String) -> Void)?
    /// 最近一次搜索的候选摘要（排障用，失败日志会带上）
    static var lastNote = "-"

    // MARK: - 状态

    /// 画布宽度（= 帧宽，恒定不变）
    private(set) var canvasWidth = 0
    /// 画布高度（像素）
    private(set) var canvasHeight = 0
    /// 画布像素（RGBA，行优先；长度恒为 canvasWidth*canvasHeight*4）
    private var bytes: [UInt8] = []
    /// 画布灰度（行优先；长度恒为 canvasWidth*canvasHeight）——对齐用，避免逐次重算
    private var gray: [UInt8] = []
    /// 画布每行灰度均值（对齐粗搜用）
    private var rowMeans: [Double] = []
    /// 上一次**成功追加**那帧的签名（唯一的「无变化」判定基准）
    private var lastAppendedSignature: GraySignature?
    /// 上一次成功追加的帧（画布对齐失败时的兜底参照）
    private var anchorFrame: FrameRef?
    /// 已追加的新内容行数（不含首帧）
    private(set) var appendedRows = 0
    /// 最后一次成功追加的位移
    private(set) var lastOffset = (dx: 0, dy: 0)
    /// 最后一次成功追加的时间
    private(set) var lastAppendAt: CFAbsoluteTime = 0
    /// 最近一次未追加的原因（诊断）
    private(set) var lastReason = ""
    /// 曾经因对齐失败而丢掉内容（收尾时提示用户）
    private(set) var didDropContent = false
    /// 连续对齐失败次数
    private var consecutiveFailures = 0
    /// 整帧重同步次数（上限 4，防止异常场景无限追加）
    private var resyncCount = 0

    private var cachedImage: CGImage?
    private var cachedHeight = -1

    /// 一帧的灰度缓存（作为兜底参照）
    private struct FrameRef {
        let gray: [UInt8]
        let w: Int
        let h: Int
        let rowMeans: [Double]
    }

    /// 当前累积画布（延迟生成：采集期不生成，收尾时才做一次）
    var canvas: CGImage? {
        if let cachedImage, cachedHeight == canvasHeight { return cachedImage }
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }
        let need = canvasWidth * canvasHeight * 4
        guard bytes.count >= need else { return nil }
        var copy = Array(bytes[0..<need])
        let ctx = CGContext(data: &copy, width: canvasWidth, height: canvasHeight,
                            bitsPerComponent: 8, bytesPerRow: canvasWidth * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let img = ctx?.makeImage() else { return nil }
        cachedImage = img
        cachedHeight = canvasHeight
        return img
    }

    // MARK: - 灰度签名（恒等帧判定用）

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

    /// 平均绝对差（行、列均步长 2 抽稀）
    static func meanAbsDiff(_ a: GraySignature, _ b: GraySignature) -> Double {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        guard w > 0, h > 0 else { return .greatestFiniteMagnitude }
        var sum = 0
        var count = 0
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

    // MARK: - 追加一帧

    /// 追加一帧（只追加底部新露出的条带）。
    /// - Parameters:
    ///   - frame: 本次采样的选区帧（像素尺寸应与画布同宽）
    ///   - hintDY: 上一次 tick 以来累积的滚动量（像素，仅用于多候选之间的取舍）
    @discardableResult
    func append(frame: CGImage, hintDY: Double, scrollSinceAppend: Double = 0) -> Outcome {
        let raw = LongShotRGBA(image: frame)
        guard raw.w > 0, raw.h > 0 else {
            lastReason = "无法解码帧"
            return .failed(lastReason)
        }
        var fb = raw

        // 帧宽必须与画布一致；±4px 以内（同步回退路径可能差 1-2px）重绘对齐，
        // 超过就丢帧——宽度不一致继续拼会把整幅图拉宽。
        if canvasWidth > 0, fb.w != canvasWidth {
            guard abs(fb.w - canvasWidth) <= 4,
                  let fixed = Self.redraw(image: frame, width: canvasWidth) else {
                lastReason = "帧宽 \(fb.w) 与画布 \(canvasWidth) 不一致"
                return .failed(lastReason)
            }
            fb = LongShotRGBA(image: fixed)
        }

        let sig = Self.graySignature(frame, width: Self.identitySignatureWidth)
        // 与上次**成功追加**的内容完全相同 → 跳过（静止画面不该每 100ms 跑一次搜索）。
        // 注意：绝不能拿「上次采样帧」当基准——那会让失败帧之后的画面被误判为没变化，
        // 整段内容再也进不了画布（v150 的致命 bug）。
        if let last = lastAppendedSignature, let sig,
           Self.meanAbsDiff(sig, last) < Self.identityThreshold {
            lastReason = "与上次追加内容相同"
            return .unchanged(lastReason)
        }

        let fg = Self.grayBuffer(fb)
        let fRowMeans = Self.rowMeans(fg, w: fb.w, h: fb.h)

        // ① 首帧：直接作为画布
        if bytes.isEmpty {
            bytes = fb.bytes
            gray = fg
            rowMeans = fRowMeans
            canvasWidth = fb.w
            canvasHeight = fb.h
            lastAppendedSignature = sig
            anchorFrame = FrameRef(gray: fg, w: fb.w, h: fb.h, rowMeans: fRowMeans)
            lastOffset = (0, 0)
            appendedRows = 0
            lastAppendAt = CFAbsoluteTimeGetCurrent()
            cachedImage = nil
            cachedHeight = -1
            lastReason = ""
            return .appended(rows: fb.h)
        }

        guard fb.w == canvasWidth else {
            lastReason = "帧宽不一致"
            return .failed(lastReason)
        }
        let frameH = fb.h
        guard frameH > 32, canvasHeight > 32 else {
            lastReason = "画布/帧过小"
            return .failed(lastReason)
        }

        let hint = Int(hintDY.rounded())
        var off = Self.searchOffset(refGray: gray, refW: canvasWidth, refH: canvasHeight,
                                    refRowMeans: rowMeans,
                                    frameGray: fg, frameW: fb.w, frameH: frameH,
                                    frameRowMeans: fRowMeans,
                                    hintDY: hint, priorDY: lastOffset.dy)
        // ② 兜底：与上一帧成功追加的帧对齐（此时它就在画布底部，位移=要追加的行数）
        if off == nil, let anchor = anchorFrame, anchor.w == fb.w {
            off = Self.searchOffset(refGray: anchor.gray, refW: anchor.w, refH: anchor.h,
                                    refRowMeans: anchor.rowMeans,
                                    frameGray: fg, frameW: fb.w, frameH: frameH,
                                    frameRowMeans: fRowMeans,
                                    hintDY: hint, priorDY: lastOffset.dy)
        }

        guard let off else {
            consecutiveFailures += 1
            // v151：连续失败说明画面已经跳到搜索窗之外（滚动过快、目标 App 自己跳转）。
            // 与其把后面所有内容一起丢掉（旧实现就是永久卡死），不如整帧追加并记下
            // 「这段可能重复/缺行」，让用户至少拿到完整的后半段。
            // 纯色/空白帧：没有任何可对齐的纹理，整帧追加只会把空白重复一段。
            // 这种「失败」是正常的（用户已经滚到页面底部），不要重同步。
            let skipTop = min(frameH / 3, Int(Double(frameH) * Self.topSkipFraction))
            if Self.isLowTexture(Array(fRowMeans[skipTop...])) {
                lastReason = "画面为空白，无可对齐内容"
                return .unchanged(lastReason)
            }
            // 是否真的跳了一屏：优先用「上次成功追加以来的累计滚动量」，它比计时可靠——
            // 目标窗口在后台重绘时可能连续几帧都是半成品（NCC 0.8 左右、无次峰），
            // 那是渲染问题，不是跳跃，整帧重同步只会把画布搞乱。
            let sinceLastAppend = CFAbsoluteTimeGetCurrent() - lastAppendAt
            let jumpedFar = abs(scrollSinceAppend) > Double(frameH) * 0.7
            let stalledTooLong = sinceLastAppend > 2.5 && consecutiveFailures >= 6
            if (jumpedFar || stalledTooLong), resyncCount < 2, canvasHeight >= frameH {
                resyncCount += 1
                didDropContent = true
                // 重同步也只追加「非吸顶层」：顶部 13% 可能是固定的导航栏，
                // 整帧塞进画布会在图中间印出一条重复的导航。
                let rows = frameH - skipTop
                let strip = Self.strip(fb, startRow: skipTop, rows: rows, dx: 0, width: canvasWidth)
                Self.appendStrip(&bytes, &gray, &rowMeans,
                                 strip: strip, rows: rows, width: canvasWidth)
                canvasHeight += rows
                appendedRows += rows
                lastOffset = (0, rows)
                lastAppendedSignature = sig
                anchorFrame = FrameRef(gray: fg, w: fb.w, h: fb.h, rowMeans: fRowMeans)
                lastAppendAt = CFAbsoluteTimeGetCurrent()
                cachedImage = nil
                cachedHeight = -1
                lastReason = "重同步：整帧追加（第 \(resyncCount) 次）"
                consecutiveFailures = 0
                return .appended(rows: rows)
            }
            if consecutiveFailures >= 3 { didDropContent = true }
            lastReason = "对齐失败（无候选）｜" + Self.lastNote
            return .failed(lastReason)
        }
        // ③ 横向漂移：长截图只允许竖向滚动，横向超过阈值说明误匹配
        guard abs(off.dx) <= Self.maxHorizontalDrift else {
            consecutiveFailures += 1
            lastReason = "横向漂移 \(off.dx)px"
            return .failed(lastReason)
        }
        // ④ 向上滚动：不裁剪画布（回弹/回看不应删掉已采内容），等用户回滚
        guard off.dy >= Self.minNewRows else {
            if off.dy < -Self.minNewRows {
                lastReason = "向上滚动（dy=\(off.dy)）"
            } else {
                lastReason = "没有新内容（dy=\(off.dy)）"
            }
            return .unchanged(lastReason)
        }
        // ⑤ 追加底部 dy 行
        guard canvasHeight + off.dy <= Self.maxCanvasSide else {
            lastReason = "画布已达 \(Self.maxCanvasSide)px 上限"
            return .failed(lastReason)
        }
        let startRow = frameH - off.dy
        guard startRow >= 0, off.dy < frameH else {
            lastReason = "位移 \(off.dy) 超过帧高 \(frameH)"
            return .failed(lastReason)
        }
        let strip = Self.strip(fb, startRow: startRow, rows: off.dy, dx: off.dx, width: canvasWidth)
        Self.appendStrip(&bytes, &gray, &rowMeans,
                         strip: strip, rows: off.dy, width: canvasWidth)
        canvasHeight += off.dy
        appendedRows += off.dy
        lastOffset = (off.dx, off.dy)
        lastAppendedSignature = sig
        anchorFrame = FrameRef(gray: fg, w: fb.w, h: fb.h, rowMeans: fRowMeans)
        lastAppendAt = CFAbsoluteTimeGetCurrent()
        cachedImage = nil
        cachedHeight = -1
        lastReason = ""
        consecutiveFailures = 0
        return .appended(rows: off.dy)
    }

    // MARK: - 横向重裁（框选里混进静止后台时，只保留滚动区）

    /// 把已有画布横向裁到 `xRange`（像素，左闭右开），并同步灰度/行均值。
    /// 返回 false 表示无需或无法裁剪（调用方保持原样）。
    @discardableResult
    func recrop(xRange: Range<Int>) -> Bool {
        guard canvasWidth > 0, canvasHeight > 0 else { return false }
        let oldW = canvasWidth
        let x0 = max(0, xRange.lowerBound)
        let x1 = min(oldW, xRange.upperBound)
        let newW = x1 - x0
        guard newW >= 32, newW < oldW else { return false }
        guard bytes.count >= oldW * canvasHeight * 4,
              gray.count >= oldW * canvasHeight else { return false }

        let rowBytesNew = newW * 4
        var nb = [UInt8](repeating: 0, count: newW * canvasHeight * 4)
        var ng = [UInt8](repeating: 0, count: newW * canvasHeight)
        nb.withUnsafeMutableBufferPointer { dst in
            bytes.withUnsafeBufferPointer { src in
                for y in 0..<canvasHeight {
                    let s = y * oldW * 4 + x0 * 4
                    let d = y * rowBytesNew
                    memcpy(dst.baseAddress! + d, src.baseAddress! + s, rowBytesNew)
                }
            }
        }
        ng.withUnsafeMutableBufferPointer { dst in
            gray.withUnsafeBufferPointer { src in
                for y in 0..<canvasHeight {
                    let s = y * oldW + x0
                    let d = y * newW
                    memcpy(dst.baseAddress! + d, src.baseAddress! + s, newW)
                }
            }
        }
        bytes = nb
        gray = ng
        canvasWidth = newW
        rowMeans = Self.rowMeans(ng, w: newW, h: canvasHeight)
        anchorFrame = nil            // 旧参照是旧宽度，直接作废
        lastOffset = (0, 0)
        cachedImage = nil
        cachedHeight = -1
        lastReason = "已裁到滚动区 \(x0)..<\(x1)"
        return true
    }

    // MARK: - 像素搬运

    /// 从帧里取 [startRow, startRow+rows) 的条带（dx≠0 时逐行平移，边缘像素钳制）
    private static func strip(_ fb: LongShotRGBA, startRow: Int, rows: Int, dx: Int, width: Int) -> [UInt8] {
        let rowBytes = width * 4
        if dx == 0 {
            let start = startRow * fb.w * 4
            return Array(fb.bytes[start..<(start + rows * rowBytes)])
        }
        var out = [UInt8](repeating: 255, count: rows * rowBytes)
        for r in 0..<rows {
            let srcRow = (startRow + r) * fb.w * 4
            let dstRow = r * rowBytes
            var x = 0
            while x < width {
                var sx = x - dx
                if sx < 0 { sx = 0 } else if sx >= fb.w { sx = fb.w - 1 }
                let si = srcRow + sx * 4
                let di = dstRow + x * 4
                out[di] = fb.bytes[si]
                out[di + 1] = fb.bytes[si + 1]
                out[di + 2] = fb.bytes[si + 2]
                out[di + 3] = 255
                x += 1
            }
        }
        return out
    }

    /// 追加条带到画布（同时维护灰度与行均值）
    private static func appendStrip(_ bytes: inout [UInt8], _ gray: inout [UInt8], _ rowMeans: inout [Double],
                                    strip: [UInt8], rows: Int, width: Int) {
        let rowBytes = width * 4
        let need = (gray.count / max(width, 1) + rows) * rowBytes
        // 容量按几何级数增长，避免每隔几十行就整块 memcpy（O(n²)）
        if bytes.capacity < need {
            bytes.reserveCapacity(max(need, min(maxCanvasSide * rowBytes, bytes.count * 2)))
        }
        bytes.append(contentsOf: strip)

        var g = [UInt8](repeating: 0, count: rows * width)
        var means = [Double](repeating: 0, count: rows)
        for r in 0..<rows {
            var sum = 0
            for x in 0..<width {
                let i = r * rowBytes + x * 4
                // 整数灰度（BT.601 近似）
                let v = (Int(strip[i]) * 77 + Int(strip[i + 1]) * 150 + Int(strip[i + 2]) * 29) >> 8
                g[r * width + x] = UInt8(v)
                sum += v
            }
            means[r] = Double(sum) / Double(width)
        }
        gray.append(contentsOf: g)
        rowMeans.append(contentsOf: means)
    }

    /// 把帧重绘到指定宽度（保持高度）——只用于 ±4px 的宽度归一化
    private static func redraw(image: CGImage, width: Int) -> CGImage? {
        guard width > 0, image.height > 0,
              let ctx = CGContext(data: nil, width: width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return ctx.makeImage()
    }

    // MARK: - 灰度/行均值

    private static func grayBuffer(_ fb: LongShotRGBA) -> [UInt8] {
        var g = [UInt8](repeating: 0, count: fb.w * fb.h)
        fb.bytes.withUnsafeBufferPointer { src in
            g.withUnsafeMutableBufferPointer { dst in
                var i = 0, o = 0
                while o < dst.count {
                    dst[o] = UInt8((Int(src[i]) * 77 + Int(src[i + 1]) * 150 + Int(src[i + 2]) * 29) >> 8)
                    i += 4
                    o += 1
                }
            }
        }
        return g
    }

    private static func rowMeans(_ g: [UInt8], w: Int, h: Int) -> [Double] {        var out = [Double](repeating: 0, count: h)
        guard w > 0 else { return out }
        let step = max(1, w / 320)      // 每行最多采 320 个点
        for y in 0..<h {
            var sum = 0
            var n = 0
            var x = 0
            while x < w {
                sum += Int(g[y * w + x])
                n += 1
                x += step
            }
            out[y] = n > 0 ? Double(sum) / Double(n) : 0
        }
        return out
    }

    /// 行均值几乎没有起伏 = 纯色/空白画面（没有可对齐的纹理）
    private static func isLowTexture(_ means: [Double]) -> Bool {
        guard means.count > 4 else { return true }
        let n = Double(means.count)
        let mean = means.reduce(0, +) / n
        let varr = means.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return varr < 1.0
    }

    // MARK: - 对齐搜索（行投影粗搜 + 二维 NCC 精校）

    private struct Candidate {
        let dx: Int
        let dy: Int
        let ncc: Double
    }

    /// 在参照图（画布或上一帧）里搜索当前帧的竖向位移。
    ///
    /// 约定：**帧第 0 行对应参照图第 (refH - frameH + dy) 行**。
    /// `dy > 0` = 内容向下滚（底部露出新内容），要追加的正是帧的最后 dy 行。
    static func searchOffset(refGray: [UInt8], refW: Int, refH: Int,
                             refRowMeans: [Double],
                             frameGray: [UInt8], frameW: Int, frameH: Int,
                             frameRowMeans: [Double],
                             hintDY: Int, priorDY: Int) -> (dx: Int, dy: Int)? {
        lastNote = "-"
        guard refW == frameW, refW > 16, refH > 32, frameH > 32 else { return nil }

        // 顶部吸顶层不参与匹配；底部 2 行也不参与（个别 App 有明显描边抖动）
        let fSkip = min(frameH / 3, Int(Double(frameH) * topSkipFraction))
        let fEnd = max(fSkip + 16, frameH - 2)
        let minOverlap = max(24, Int(Double(frameH) * minOverlapFraction))
        let maxDy = frameH - minOverlap
        guard maxDy > 8, refH > minOverlap else { return nil }

        /// 某个 dy 下「实际可用于比对」的帧行区间。
        /// 关键：位移接近帧高时重叠只剩一百多行，再扣掉吸顶栏就不足最小重叠，
        /// 旧写法会直接判「无候选」——快速滚动时表现为整段丢失。
        /// 这里把吸顶跳过量按剩余重叠自适应收缩，保证至少 minOverlap 行可比。
        func usableRows(_ dy: Int) -> (top: Int, start: Int, end: Int)? {
            let top = refH - frameH + dy
            let end = min(frameH, refH - top)
            guard end > 0 else { return nil }
            let start = min(min(fSkip, fEnd), max(0, end - minOverlap))
            guard end - start >= minOverlap else { return nil }
            return (top, start, end)
        }

        // MARK: 一维 NCC（行均值）
        func ncc1D(_ dy: Int) -> Double {
            guard let u = usableRows(dy) else { return -1 }
            let top = u.top
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0
            var f = u.start
            while f < u.end {
                let r = top + f
                if r >= 0, r < refH {
                    let a = frameRowMeans[f], b = refRowMeans[r]
                    sa += a; sb += b
                    saa += a * a; sbb += b * b; sab += a * b
                    n += 1
                }
                f += 1
            }
            guard n >= Double(minOverlap) else { return -1 }
            let cov = n * sab - sa * sb
            let va = n * saa - sa * sa
            let vb = n * sbb - sb * sb
            guard va > 1e-3, vb > 1e-3 else { return -1 }   // 一侧无纹理：不可信
            return cov / (va * vb).squareRoot()
        }

        var coarse: [(dy: Int, score: Double)] = []
        var dy = -maxDy
        while dy <= maxDy {
            let s = ncc1D(dy)
            if s > 0.15 { coarse.append((dy, s)) }
            dy += 2
        }
        guard !coarse.isEmpty else { return nil }
        coarse.sort { $0.score > $1.score }

        // 取 top-5（相互间隔 >6px，避免同一个峰的邻居占满配额）
        var seeds: [Int] = []
        for c in coarse where seeds.count < 5 {
            if seeds.allSatisfy({ abs($0 - c.dy) > 6 }) { seeds.append(c.dy) }
        }
        // 关键：内容重复（列表/表格/等高段落）时，粗搜的第一名可能是「另一个长得一样的段」。
        // 滚动量提示和上次位移必须无条件进入候选——它们才是真实位移的强先验。
        // 符号存疑（滚轮方向可能被系统反转），两个方向都放进去，交给 NCC 裁决。
        for extra in [hintDY, -hintDY, priorDY, -priorDY]
        where abs(extra) >= 4 && abs(extra) <= maxDy {
            if seeds.allSatisfy({ abs($0 - extra) > 6 }) { seeds.append(extra) }
        }
        guard !seeds.isEmpty else { return nil }

        // MARK: 二维 NCC（逐像素，灰度）
        func ncc2D(_ dx: Int, _ dy: Int, xStep: Int) -> Double {
            guard let u = usableRows(dy) else { return -1 }
            let top = u.top
            var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0
            var f = u.start
            while f < u.end {
                let r = top + f
                guard r >= 0, r < refH else { f += 1; continue }
                let fRow = f * frameW
                let rRow = r * refW
                var x = 0
                while x < frameW {
                    let rx = x + dx
                    if rx >= 0, rx < refW {
                        let a = Double(frameGray[fRow + x])
                        let b = Double(refGray[rRow + rx])
                        sa += a; sb += b
                        saa += a * a; sbb += b * b; sab += a * b
                        n += 1
                    }
                    x += xStep
                }
                f += 1
            }
            guard n > 0 else { return -1 }
            let cov = n * sab - sa * sb
            let va = n * saa - sa * sa
            let vb = n * sbb - sb * sb
            guard va > 1e-3, vb > 1e-3 else { return -1 }
            return cov / (va * vb).squareRoot()
        }

        // 精校：每个种子 dy ±7（1px 步进），先只校竖向
        var refined: [Candidate] = []
        for seed in seeds {
            var y = max(-maxDy, seed - 7)
            let yEnd = min(maxDy, seed + 7)
            while y <= yEnd {
                let s = ncc2D(0, y, xStep: 5)
                if s > 0.5 { refined.append(Candidate(dx: 0, dy: y, ncc: s)) }
                y += 1
            }
        }
        guard !refined.isEmpty else { return nil }
        refined.sort { $0.ncc > $1.ncc }

        if let trace {
            let seedsText = seeds.map(String.init).joined(separator: ",")
            let topCoarse = coarse.prefix(5)
                .map { "\($0.dy):" + String(format: "%.3f", $0.score) }
                .joined(separator: " ")
            let topRefined = refined.prefix(5)
                .map { "\($0.dy):" + String(format: "%.3f", $0.ncc) }
                .joined(separator: " ")
            trace("refH=\(refH) frameH=\(frameH) skip=\(fSkip) maxDy=\(maxDy)｜粗搜 \(topCoarse)｜种子 \(seedsText)｜精修 \(topRefined)")
        }

        // 横向：长截图不该横移，dx=0 是默认答案。只有当某个横向偏移能把 NCC 明显拉高
        // （>0.02）时才考虑——否则文字页面上 ±1px 的分数抖动会让它「漂」出 3px 再被丢弃，
        // 一帧丢弃就可能让画布落后超过一屏，整场采集再也接不上。
        var best = refined[0]
        let nccAtZero = ncc2D(0, best.dy, xStep: 4)
        if nccAtZero > best.ncc { best = Candidate(dx: 0, dy: best.dy, ncc: nccAtZero) }
        var dxCand = -2
        while dxCand <= 2 {
            if dxCand != 0 {
                let s = ncc2D(dxCand, best.dy, xStep: 4)
                if s > best.ncc + 0.02 { best = Candidate(dx: dxCand, dy: best.dy, ncc: s) }
            }
            dxCand += 1
        }

        // 多候选歧义：内容高度重复（表格/列表）时会有多个高分峰。
        // 用滚动量提示（取绝对值，避免滚轮符号因设备反转）在「相差 ≤0.01」的候选里挑最接近的。
        if abs(hintDY) >= 4 {
            let near = refined.filter { abs(abs($0.dy) - abs(hintDY)) <= 8 }
                .max { $0.ncc < $1.ncc }
            if let near, near.ncc >= best.ncc - 0.01, abs(near.dy) > 8 {
                best = Candidate(dx: best.dx, dy: near.dy, ncc: near.ncc)
            }
        }

        // 命中搜索窗边界 = 真实位移可能更大，本帧无法可信对齐
        guard abs(best.dy) < maxDy - 2 else {
            lastNote = String(format: "best %.3f @dy=%d 贴边(band=%d)", best.ncc, best.dy, maxDy)
            return nil
        }
        // 接受条件：① 分数够高；或 ② 分数中等但**峰值显著高于次峰**——真实网页顶部
        // 常有 15-25% 高的吸顶栏/固定工具条，它们不参与位移，会把整体 NCC 拉低到
        // 0.8x；这种情况下「位移唯一」比「分数绝对值」更能说明问题。
        if best.ncc < minNCC {
            let distinct = refined.filter { abs($0.dy - best.dy) > 8 }
            let runnerUp = distinct.map(\.ncc).max() ?? 0
            // 两种可接受的「次优场景」：
            // ① 有可比候选，且明显低于最优（差距 ≥0.06）
            // ② 压根没有第二个候选（其余候选都没过 0.5 的入围线）——这本身就是
            //    「位移唯一」的证据，只要分数不太低（≥0.86）就接受。
            //    （纯色/半成品帧的孤峰通常在 0.6-0.8，仍会被挡掉。）
            let clearWinner = !distinct.isEmpty && best.ncc >= 0.80
                && runnerUp <= best.ncc - 0.06
            let uniqueStrong = distinct.isEmpty && best.ncc >= 0.86
            guard clearWinner || uniqueStrong else {
                lastNote = String(format: "best %.3f @dy=%d 低于阈值%.2f（次峰%.3f）",
                                  best.ncc, best.dy, minNCC, runnerUp)
                return nil
            }
            lastNote = String(format: "ncc %.3f @dy=%d（次峰%.3f，峰值判定通过）",
                              best.ncc, best.dy, runnerUp)
            return (best.dx, best.dy)
        }
        lastNote = String(format: "ncc %.3f @dy=%d", best.ncc, best.dy)
        return (best.dx, best.dy)
    }
}

// MARK: - 灰度签名（恒等帧判定，原作同款数据结构）

public struct GraySignature {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]
}
