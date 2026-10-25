import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图流式拼接器（v68：二维向量对齐）
//
// 原 spec 15 实现为「画布在上、新帧在下」的单向（纵向向下）拼接；
// v68 扩展为 eSearch 式任意方向：每帧在世界坐标系里做二维平移搜索
//（对上一帧的位移 dx, dy ∈ 上下左右/斜向均可），画布按并集自动扩展。
//
// 两级搜索（签名空间量化的 ±1 行误差在噪声内容下不可接受，改为缓冲直评）：
//   A) 粗搜：画布/帧各做 4×4 盒式降采样灰度缓冲（平滑噪声），全窗搜索最优位移；
//   B) 精修：最优 ±4px 内在全分辨率 RGBA 缓冲上逐像素评分（步进 2 抽稀）。
// 阈值族沿用 spec 15（恒等 2.5 / 最小重叠 2 / 最小新内容 15）。

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

    /// 转回 CGImage
    func makeImage() -> CGImage? {
        var b = bytes
        let ctx = CGContext(data: &b, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }
}

/// 盒式降采样灰度缓冲（4×4 均值 → 单字节）
struct DownsampledGray {
    let w: Int
    let h: Int
    var bytes: [UInt8]
    static let factor = 4

    init(_ buf: LongShotRGBA) {
        let f = Self.factor
        let w = max(1, buf.w / f), h = max(1, buf.h / f)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0
                for dy in 0..<f {
                    let sy = min(buf.h - 1, y * f + dy)
                    let row = sy * buf.w * 4
                    for dx in 0..<f {
                        let sx = min(buf.w - 1, x * f + dx)
                        let off = row + sx * 4
                        // 灰度 = 亮度近似（R+2G+B >> 2）
                        sum += Int(buf.bytes[off]) + 2 * Int(buf.bytes[off + 1]) + Int(buf.bytes[off + 2])
                    }
                }
                out[y * w + x] = UInt8(min(255, sum / (f * f * 4)))
            }
        }
        self.w = w
        self.h = h
        self.bytes = out
    }

    /// 子区平均绝对差（步进 2 抽稀）；两区代表同一世界区域（尺寸应相等）
    func diff(against other: DownsampledGray,
              selfRect: CGRect, otherRect: CGRect) -> Double {
        let rw = min(Int(selfRect.width), Int(otherRect.width))
        let rh = min(Int(selfRect.height), Int(otherRect.height))
        guard rw >= 2, rh >= 2 else { return .greatestFiniteMagnitude }
        let sx0 = Int(selfRect.minX), sy0 = Int(selfRect.minY)
        let ox0 = Int(otherRect.minX), oy0 = Int(otherRect.minY)
        var sum = 0, count = 0
        var y = 0
        while y < rh {
            let sy = sy0 + y
            let ty = oy0 + y
            guard sy >= 0, sy < h, ty >= 0, ty < other.h else { return .greatestFiniteMagnitude }
            var x = 0
            while x < rw {
                let sx = sx0 + x
                let tx = ox0 + x
                guard sx >= 0, sx < w, tx >= 0, tx < other.w else { return .greatestFiniteMagnitude }
                sum += abs(Int(bytes[sy * w + sx]) - Int(other.bytes[ty * other.w + tx]))
                count += 1
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return .greatestFiniteMagnitude }
        return Double(sum) / Double(count)
    }
}

final class LongScreenshotStitcher {

    // MARK: 算法常量

    /// 滚动量过滤阈值 scrollingDeltaEpsilon（@0x1004395ec）
    static let scrollEpsilon: Double = 0.08
    /// 恒等帧判定阈值（全帧签名 meanAbsDiff，@0x100436da8）
    static let identityThreshold: Double = 2.5
    /// 恒等判定签名宽（@0x100436d58，w1=0x200）
    static let identitySignatureWidth = 512
    /// 搜索窗基础像素（原作 +24 保留为下限）
    static let bandBaseRows = 28
    /// 搜索窗系数（|δ|×scale×4 保留）
    static let bandDeltaScale: Double = 4.0
    /// 搜索窗上限（二维扩展放宽：64 → 96）
    static let bandMaxRows = 96
    /// 粗搜步进（降采样空间；1 格 = 4px）
    static let coarseStep = 1
    /// 精修半径（全分辨率像素；覆盖一个降采样格 4px）
    static let fineRadius = 5
    /// 最小重叠（每维；原作 2 行保留）
    static let minOverlapRows = 2
    /// 最小新内容行当量：低于则不追加（原作 15 保留）
    static let minNewRows = 15
    /// 对齐可接受分数上限（降采样灰度均值差）
    static let maxAlignScore: Double = 8.0
    /// 精修候选数（粗搜 top-N 都精修，防半格偏差漏真值）
    static let fineSeedCount = 16
    /// 画布单边上限（像素，防内存爆炸）
    static let maxCanvasSide = 16000

    // MARK: 状态（世界坐标：第一帧左上角为原点，向右/向下为正）

    /// 累积画布
    private(set) var canvas: CGImage?
    private var canvasBuf: LongShotRGBA?
    private var canvasSmall: DownsampledGray?
    /// 画布像素 (0,0) 在世界坐标系中的位置
    private(set) var canvasOriginX = 0
    private(set) var canvasOriginY = 0
    /// 上一帧的世界位置（左上角）
    private var lastFrameWorldX = 0
    private var lastFrameWorldY = 0
    /// 上一帧的恒等判定签名
    private var lastIdentitySignature: GraySignature?
    /// 已累计的新增行当量（诊断用）
    private(set) var appendedRows = 0
    /// 诊断：最后一次对齐位移
    private(set) var lastOffset = (dx: 0, dy: 0)

    // MARK: 灰度签名（恒等帧判定用，原作同款）

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

    // MARK: 追加一帧（二维）

    /// 追加一帧；返回是否产生了追加（false = 恒等帧丢弃 / 新内容不足 / 对齐失败）。
    /// - Parameters:
    ///   - frame: 本次采捕的选区帧
    ///   - hintDX/hintDY: 滚动累积量（像素；方向语义不保证，仅作搜索窗宽参考）
    ///   - scale: 内容缩放（imgW / 选区宽，session 提供）
    @discardableResult
    func append(frame: CGImage, hintDX: Double, hintDY: Double, scale: Double) -> Bool {
        // ① 恒等帧剔除（全帧签名，@0x100436cf0）
        // v126（性能审计 F0399）：graySignature 只算一次，避免重复 CGImage→灰度缩放
        let newSig = Self.graySignature(frame, width: Self.identitySignatureWidth)
        if let last = lastIdentitySignature,
           let sig = newSig,
           Self.meanAbsDiff(sig, last) < Self.identityThreshold {
            lastIdentitySignature = sig
            return false
        }
        lastIdentitySignature = newSig

        // 首帧：直接作为画布（世界原点即首帧左上角）
        guard let base = canvas else {
            let buf = LongShotRGBA(image: frame)
            canvas = buf.makeImage()
            canvasBuf = buf
            canvasSmall = DownsampledGray(buf)
            canvasOriginX = 0
            canvasOriginY = 0
            lastFrameWorldX = 0
            lastFrameWorldY = 0
            appendedRows = buf.h
            return true
        }

        let frameW = frame.width
        let frameH = frame.height
        // v68 二维：画布会随横向拼接变宽，帧只与「上一帧」同宽（采捕原语保证），不再要求与画布同宽
        guard frameH > Self.minOverlapRows, let curBuf = canvasBuf, let curSmall = canvasSmall else {
            return false
        }

        // ② 二级对齐搜索
        let band = min(Int(max(abs(hintDX), abs(hintDY)) * scale * Self.bandDeltaScale) + Self.bandBaseRows,
                       Self.bandMaxRows)
        // v126（性能审计 F0399）：去掉冗余二次解包（上方已有 curBuf/curSmall）
        guard let offset = Self.searchOffset(canvasBuf: curBuf,
                                             canvasSmall: curSmall,
                                             canvasOriginX: canvasOriginX,
                                             canvasOriginY: canvasOriginY,
                                             lastFrameX: lastFrameWorldX,
                                             lastFrameY: lastFrameWorldY,
                                             frame: frame,
                                             band: band) else {
            return false
        }
        guard offset.dx != 0 || offset.dy != 0 else { return false }   // 无位移

        // ③ 追加判定：新增面积行当量（四向扩张都计入）< minNewRows 不追加，等待继续滚动
        let newLeft = lastFrameWorldX + offset.dx
        let newTop = lastFrameWorldY + offset.dy
        let newRight = newLeft + frameW
        let newBottom = newTop + frameH
        let canvasRight = canvasOriginX + curBuf.w
        let canvasBottom = canvasOriginY + curBuf.h
        let extraH = max(newBottom - canvasBottom, canvasOriginY - newTop)
        let extraW = max(newRight - canvasRight, canvasOriginX - newLeft)
        let newRowsEquivalent = max(extraH, extraW * frameH / max(frameW, 1))
        guard newRowsEquivalent >= Self.minNewRows else { return false }

        // ④ 世界并集扩展画布 + 新帧绘制到其世界位置
        let newOriginX = min(canvasOriginX, lastFrameWorldX + offset.dx)
        let newOriginY = min(canvasOriginY, lastFrameWorldY + offset.dy)
        let unionW = max(canvasRight, newRight) - newOriginX
        let unionH = max(canvasBottom, newBottom) - newOriginY
        guard unionW <= Self.maxCanvasSide, unionH <= Self.maxCanvasSide else {
            Log.warn("Capture", "长截图：画布超过 \(Self.maxCanvasSide)px 上限，停止扩展")
            return false
        }

        // 合成：malloc 缓冲上下文绘制（一次绘制同时产出 CGImage 与评分用字节）
        let unionCount = unionW * unionH * 4
        let uptr = UnsafeMutableRawPointer.allocate(byteCount: unionCount, alignment: 64)
        defer { uptr.deallocate() }
        memset(uptr, 0, unionCount)
        guard let unionCtx = CGContext(data: uptr, width: unionW, height: unionH,
                                       bitsPerComponent: 8, bytesPerRow: unionW * 4,
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        unionCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        unionCtx.fill(CGRect(x: 0, y: 0, width: unionW, height: unionH))
        unionCtx.interpolationQuality = .low
        // 世界（左上原点）→ CG（左下原点）：y_cg = unionH - (worldY + height)
        // 世界 y（左上原点，可为负）→ CG y（左下原点）：y_cg = unionH - (worldY - newOriginY) - height
        unionCtx.draw(base,
                      in: CGRect(x: CGFloat(canvasOriginX - newOriginX),
                                 y: CGFloat(unionH - (canvasOriginY - newOriginY) - curBuf.h),
                                 width: CGFloat(curBuf.w), height: CGFloat(curBuf.h)))
        unionCtx.draw(frame,
                      in: CGRect(x: CGFloat(lastFrameWorldX + offset.dx - newOriginX),
                                 y: CGFloat(unionH - (lastFrameWorldY + offset.dy - newOriginY) - frameH),
                                 width: CGFloat(frameW), height: CGFloat(frameH)))
        guard let merged = unionCtx.makeImage() else { return false }
        let mergedBytes = Array(UnsafeRawBufferPointer(start: uptr, count: unionCount))

        canvas = merged
        canvasBuf = LongShotRGBA(w: unionW, h: unionH, bytes: mergedBytes)
        canvasSmall = DownsampledGray(canvasBuf!)
        canvasOriginX = newOriginX
        canvasOriginY = newOriginY
        lastFrameWorldX += offset.dx
        lastFrameWorldY += offset.dy
        appendedRows += newRowsEquivalent
        lastOffset = offset
        return true
    }

    // MARK: 二级对齐搜索

    /// A) 降采样空间全窗粗搜（band/4 格，步进 coarseStep）
    /// B) 全分辨率精修（最优 ±fineRadius 像素，步进 2 抽稀）
    static func searchOffset(canvasBuf: LongShotRGBA,
                             canvasSmall: DownsampledGray,
                             canvasOriginX: Int, canvasOriginY: Int,
                             lastFrameX: Int, lastFrameY: Int,
                             frame: CGImage,
                             band: Int) -> (dx: Int, dy: Int)? {
        let frameBuf = LongShotRGBA(image: frame)
        let frameSmall = DownsampledGray(frameBuf)
        let f = DownsampledGray.factor

        // 帧在降采样空间的大小
        let fsW = frameSmall.w, fsH = frameSmall.h

        // v126（性能审计 F0400）：循环不变量外提——canvas 原点换算只算一次
        let cx = canvasOriginX / f
        let cy = canvasOriginY / f

        func coarseScore(_ dx: Int, _ dy: Int) -> Double {
            // 帧世界位置（像素）→ 降采样空间
            let fx = (lastFrameX + dx) / f
            let fy = (lastFrameY + dy) / f
            // 帧相对画布的重叠（降采样坐标系）
            let ox = max(fx, cx), oy = max(fy, cy)
            let or = min(fx + fsW, cx + canvasSmall.w)
            let ob = min(fy + fsH, cy + canvasSmall.h)
            guard or - ox >= 2, ob - oy >= 2 else { return .greatestFiniteMagnitude }
            // 以「帧」为基准区，画布平移对齐比较
            return frameSmall.diff(against: canvasSmall,
                                   selfRect: CGRect(x: ox - fx, y: oy - fy, width: or - ox, height: ob - oy),
                                   otherRect: CGRect(x: ox - cx, y: oy - cy, width: or - ox, height: ob - oy))
        }

        // A) 粗搜（零中心 ±band/4 格），收集全部候选
        // v126（性能审计 F0400）：循环边界 band/f 外提
        let bandF = band / f
        var candidates: [(dx: Int, dy: Int, score: Double)] = []
        var dy = -bandF
        while dy <= bandF {
            var dx = -bandF
            while dx <= bandF {
                let s = coarseScore(dx * f, dy * f)
                if s < .greatestFiniteMagnitude {
                    candidates.append((dx * f, dy * f, s))
                }
                dx += Self.coarseStep
            }
            dy += Self.coarseStep
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.score < $1.score }

        // B) 全分辨率精修：粗搜 top-N 候选各 ±fineRadius 逐像素评分（降采样空间的
        //    半格偏差无法区分真伪，真值常落在次优候选的邻域内）
        // v126（性能审计 F0400）：热路径属性访问外提为局部常量，减少间接寻址
        let fbW = frameBuf.w, fbH = frameBuf.h
        let cbW = canvasBuf.w, cbH = canvasBuf.h
        let fbBytes = frameBuf.bytes, cbBytes = canvasBuf.bytes
        var fineDx = candidates[0].dx, fineDy = candidates[0].dy
        var bestScore = Double.greatestFiniteMagnitude
        let seeds = candidates.prefix(Self.fineSeedCount)
        for seed in seeds {
            for ddy in (seed.dy - Self.fineRadius)...(seed.dy + Self.fineRadius) {
                for ddx in (seed.dx - Self.fineRadius)...(seed.dx + Self.fineRadius) {
                let fx = lastFrameX + ddx, fy = lastFrameY + ddy
                let ox = max(fx, canvasOriginX), oy = max(fy, canvasOriginY)
                let or = min(fx + fbW, canvasOriginX + cbW)
                let ob = min(fy + fbH, canvasOriginY + cbH)
                guard or - ox >= Self.minOverlapRows, ob - oy >= Self.minOverlapRows else { continue }
                var sum = 0, count = 0
                var y = oy
                while y < ob {
                    let srcRow = (y - fy) * fbW + (ox - fx)
                    let dstRow = (y - canvasOriginY) * cbW + (ox - canvasOriginX)
                    var x = 0
                    while x < or - ox {
                        let a = srcRow + x, b = dstRow + x
                        let dr = Int(fbBytes[a * 4]) - Int(cbBytes[b * 4])
                        let dg = Int(fbBytes[a * 4 + 1]) - Int(cbBytes[b * 4 + 1])
                        let db = Int(fbBytes[a * 4 + 2]) - Int(cbBytes[b * 4 + 2])
                        sum += abs(dr) + abs(dg) + abs(db)
                        count += 3
                        x += 2
                    }
                    y += 2
                }
                guard count > 0 else { continue }
                let s = Double(sum) / Double(count)
                if s < bestScore {
                    bestScore = s
                    fineDx = ddx
                    fineDy = ddy
                }
                }
            }
        }

        guard bestScore <= Self.maxAlignScore * 3 else {
            Log.debug("Capture", "长截图：精修分数 \(String(format: "%.1f", bestScore)) 超过上限，本帧放弃")
            return nil
        }
        return (fineDx, fineDy)
    }
}

// MARK: - 灰度签名（恒等帧判定，原作同款数据结构）

public struct GraySignature {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]
}
