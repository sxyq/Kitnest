import CoreGraphics
import Foundation

// MARK: - 物体抹除修复引擎（eSearch removeObj 对齐，2026-10-19 用户需求）
//
// 双引擎设计：
//   ① DiffusionInpainter（本文件，默认）：多分辨率 SOR 调和填充，纯 CoreGraphics，
//      零依赖、离线即时。对文字/电线/小物件（< 区域 20%）效果好。
//   ② LaMa（预留）：ONNX Runtime + LaMa 修复模型（输入 [1,3,H,W] 图 + [1,1,H,W]
//      mask），需引 onnxruntime-objc + 模型管理下载（~200MB）。引擎协议已留好插槽
//      （RemovalEngine），接入点见 `ObjectRemovalEngine.engines`；本轮默认走 ①。
//
// 调和填充算法（拉普拉斯方程 ∇²u = 0，洞外为 Dirichlet 边界）：
//   1) 全图降采样至 ≤384 工作分辨率，mask 同步降采样；
//   2) 大洞先在 1/2、1/4 分辨率预解，逐级上采样作初值（全局收敛保障）；
//   3) SOR 超松弛迭代（ω=1.85）：洞内像素取四邻均值 + 过松弛。
//      ★ 迭代全程用 Double 缓冲——UInt8 每轮量化截断构成"单向棘轮"
//        （上升增量 <1 被吞、下降至少降 1），实测会把整个解拖向 0（2026-10-19 教训）；
//   4) 最大变化量 < 0.05 提前退出；结果回写 UInt8、上采样、按羽化 mask 贴回原图。

/// 修复引擎协议（LaMa ONNX 未来接入点）
public protocol RemovalEngine {
    var name: String { get }
    /// - Parameters:
    ///   - image: 原图
    ///   - mask: 灰度图（非 0 = 待抹除区域），尺寸与原图一致
    func inpaint(image: CGImage, mask: CGImage) -> CGImage?
}

public enum ObjectRemovalEngine {
    /// 可用引擎（顺序即优先级；LaMa 接入后插到首位）
    public static var engines: [RemovalEngine] = [DiffusionInpainter()]

    /// 便捷入口：用首个引擎修复
    public static func inpaint(image: CGImage, mask: CGImage) -> CGImage? {
        guard let engine = engines.first else { return nil }
        return engine.inpaint(image: image, mask: mask)
    }
}

/// 多分辨率 SOR 调和填充（默认引擎）
public struct DiffusionInpainter: RemovalEngine {
    public let name = "扩散修复（离线）"

    public init() {}

    /// 工作分辨率上限（长边）
    static let workMaxSide = 384
    /// SOR 超松弛系数（0 < ω < 2 收敛；1.85 兼顾速度与稳定）
    static let omega = 1.85

    public func inpaint(image: CGImage, mask: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, mask.width == w, mask.height == h else { return nil }

        // ① 降采样工作尺寸
        let scale = min(1.0, CGFloat(Self.workMaxSide) / CGFloat(max(w, h)))
        let ww = max(2, Int(CGFloat(w) * scale))
        let wh = max(2, Int(CGFloat(h) * scale))

        guard let imgBuf = Self.downsample(image, w: ww, h: wh),
              let maskBuf = Self.downsample(mask, w: ww, h: wh) else { return nil }

        var isHole = [Bool](repeating: false, count: ww * wh)
        var holeCount = 0
        for i in 0..<(ww * wh) {
            isHole[i] = maskBuf[i * 4] > 24
            if isHole[i] { holeCount += 1 }
        }
        guard holeCount > 0, holeCount < ww * wh else { return image }   // 无洞 / 全洞

        // ② SOR 调和填充（Double 缓冲，多级初值）
        let solution = Self.solveLevels(imgBuf: imgBuf, isHole: isHole, w: ww, h: wh)

        // ③ 回写 UInt8 → 上采样 → 羽化贴回
        var filledBytes = [UInt8](repeating: 0, count: ww * wh * 4)
        for i in 0..<(ww * wh * 4) {
            let v = solution[i]
            filledBytes[i] = UInt8(min(255, max(0, v.rounded())))
        }
        guard let filledSmall = Self.bufferToImage(filledBytes, w: ww, h: wh),
              let filled = Self.upsample(filledSmall, w: w, h: h),
              let maskFeathered = Self.featherMask(mask, radius: 2) else { return nil }

        let baseBuf = Self.rgbaBytes(image)
        let fillBuf = Self.rgbaBytes(filled)
        let featherBuf = Self.rgbaBytes(maskFeathered)
        var ob = baseBuf
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let alpha = CGFloat(featherBuf[i]) / 255.0
            guard alpha > 0.004 else { continue }
            for c in 0..<3 {
                let base = CGFloat(ob[i + c])
                let fill = CGFloat(fillBuf[i + c])
                ob[i + c] = UInt8(min(255, max(0, base * (1 - alpha) + fill * alpha)))
            }
        }
        guard let provider = CGDataProvider(data: Data(ob) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: - 分级求解

    /// 多级求解：洞较大时先在 1/2、1/4 分辨率预解，逐级上采样作初值。
    /// 粗层像素少、少量迭代即全局收敛；细层只修高频。
    static func solveLevels(imgBuf: [UInt8], isHole: [Bool], w: Int, h: Int) -> [Double] {
        // 洞包围盒长边决定是否需要粗层预热
        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h { for x in 0..<w where isHole[y * w + x] {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }}
        let bboxLong = max(maxX - minX, maxY - minY)

        // 层序列（细 → 粗）：全层 + 视洞尺寸加 1/2、1/4 层
        var levels: [(w: Int, h: Int)] = [(w, h)]
        if bboxLong > 140 { levels.append((max(2, w / 2), max(2, h / 2))) }
        if bboxLong > 280 { levels.append((max(2, w / 4), max(2, h / 4))) }

        var solution: [Double]? = nil
        // 从最粗层往全层解
        for (index, level) in levels.enumerated().reversed() {
            let levelImg: [UInt8]
            let levelMask: [Bool]
            if level.w == w && level.h == h {
                levelImg = imgBuf; levelMask = isHole
            } else {
                levelImg = resampleRGBA(imgBuf, sw: w, sh: h, dw: level.w, dh: level.h)
                levelMask = nearestMask(isHole, sw: w, sh: h, dw: level.w, dh: level.h)
            }
            let iters = index == levels.count - 1 ? 400 : 220   // 最粗层多迭代
            solution = sorSolve(img: levelImg, isHole: levelMask, w: level.w, h: level.h,
                                iterations: iters, initial: solution,
                                upsampleFrom: index < levels.count - 1 ? levels[index + 1] : nil)
        }
        return solution ?? imgBuf.map { Double($0) }
    }

    /// SOR 调和填充核心。initial 非空时作为洞初值（应为上一粗层解的上采样）。
    static func sorSolve(img: [UInt8], isHole: [Bool], w: Int, h: Int,
                         iterations: Int, initial: [Double]?, upsampleFrom: (w: Int, h: Int)?) -> [Double] {
        var buf = [Double](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h * 4) { buf[i] = Double(img[i]) }

        // 洞包围盒（只扫洞区，省掉洞外 90%+ 扫描）
        var minX = w, minY = h, maxX = 0, maxY = 0
        var holeCount = 0
        for y in 0..<h { for x in 0..<w where isHole[y * w + x] {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            holeCount += 1
        }}
        guard holeCount > 0 else { return buf }

        // 洞初值：优先上层解上采样；否则边界环逐通道均值
        if let initSol = initial, let from = upsampleFrom {
            let up = nearestUpsample(initSol, sw: from.w, sh: from.h, dw: w, dh: h)
            for i in 0..<(w * h * 4) where isHole[i / 4] { buf[i] = up[i] }
        } else {
            var ringSum = [Double](repeating: 0, count: 3)
            var ringCount = 0
            for y in 0..<h { for x in 0..<w where isHole[y * w + x] {
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, nx < w, ny >= 0, ny < h, !isHole[ny * w + nx] else { continue }
                    let o = (ny * w + nx) * 4
                    ringSum[0] += buf[o]; ringSum[1] += buf[o + 1]; ringSum[2] += buf[o + 2]
                    ringCount += 1
                }
            }}
            guard ringCount > 0 else { return buf }
            let mean = ringSum.map { $0 / Double(ringCount) }
            for i in 0..<(w * h) where isHole[i] {
                buf[i * 4] = mean[0]; buf[i * 4 + 1] = mean[1]; buf[i * 4 + 2] = mean[2]
                buf[i * 4 + 3] = 255
            }
        }

        // SOR 迭代（原地 Gauss-Seidel + 超松弛；Double 全程，杜绝量化棘轮）
        let omega = Self.omega
        let threshold = 0.05
        for iter in 0..<iterations {
            var maxDelta = 0.0
            for y in minY...maxY {
                for x in minX...maxX {
                    let idx = y * w + x
                    guard isHole[idx] else { continue }
                    let o = idx * 4
                    // 四邻（含洞内像素——迭代中的近似值）
                    var sr = 0.0, sg = 0.0, sb = 0.0, count = 0.0
                    if x > 0 { let n = o - 4; sr += buf[n]; sg += buf[n + 1]; sb += buf[n + 2]; count += 1 }
                    if x < w - 1 { let n = o + 4; sr += buf[n]; sg += buf[n + 1]; sb += buf[n + 2]; count += 1 }
                    if y > 0 { let n = o - w * 4; sr += buf[n]; sg += buf[n + 1]; sb += buf[n + 2]; count += 1 }
                    if y < h - 1 { let n = o + w * 4; sr += buf[n]; sg += buf[n + 1]; sb += buf[n + 2]; count += 1 }
                    guard count > 0 else { continue }
                    let inv = 1.0 / count
                    let oldR = buf[o], oldG = buf[o + 1], oldB = buf[o + 2]
                    let newR = oldR + omega * (sr * inv - oldR)
                    let newG = oldG + omega * (sg * inv - oldG)
                    let newB = oldB + omega * (sb * inv - oldB)
                    buf[o] = newR; buf[o + 1] = newG; buf[o + 2] = newB; buf[o + 3] = 255
                    maxDelta = max(maxDelta, abs(newR - oldR), abs(newG - oldG), abs(newB - oldB))
                }
            }
            // 收敛提前退出（前 8 轮不判，避免初值阶段误判）
            if iter > 8 && maxDelta < threshold { break }
        }
        return buf
    }

    // MARK: - 重采样

    /// RGBA 缓冲最近邻缩放
    static func nearestMask(_ mask: [Bool], sw: Int, sh: Int, dw: Int, dh: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: dw * dh)
        for y in 0..<dh {
            let sy = min(sh - 1, y * sh / dh)
            for x in 0..<dw {
                let sx = min(sw - 1, x * sw / dw)
                out[y * dw + x] = mask[sy * sw + sx]
            }
        }
        return out
    }

    /// Double RGBA 缓冲最近邻上采样
    static func nearestUpsample(_ src: [Double], sw: Int, sh: Int, dw: Int, dh: Int) -> [Double] {
        var out = [Double](repeating: 0, count: dw * dh * 4)
        for y in 0..<dh {
            let sy = min(sh - 1, y * sh / dh)
            for x in 0..<dw {
                let sx = min(sw - 1, x * sw / dw)
                let s = (sy * sw + sx) * 4
                let d = (y * dw + x) * 4
                out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]; out[d + 3] = src[s + 3]
            }
        }
        return out
    }

    /// RGBA UInt8 缓冲缩放（CG medium 插值，用于层间降采样）
    static func resampleRGBA(_ rgba: [UInt8], sw: Int, sh: Int, dw: Int, dh: Int) -> [UInt8] {
        guard let img = bufferToImage(rgba, w: sw, h: sh) else {
            return [UInt8](repeating: 0, count: dw * dh * 4)
        }
        return downsample(img, w: dw, h: dh) ?? [UInt8](repeating: 0, count: dw * dh * 4)
    }

    // MARK: - 位图辅助（malloc 缓冲，规避 &array 桥接的未定义行为）

    /// bytes → CGImage
    static func bufferToImage(_ bytes: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// 任意图 → RGBA bytes（malloc 缓冲）
    static func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        let count = w * h * 4
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
        defer { ptr.deallocate() }
        memset(ptr, 0, count)
        if let ctx = CGContext(data: ptr, width: w, height: h,
                               bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Array(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    /// 灰度图 → bytes（malloc 缓冲）
    static func rgbaGray(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        let count = w * h
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
        defer { ptr.deallocate() }
        memset(ptr, 0, count)
        guard let ctx = CGContext(data: ptr, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Array(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    /// 降采样到指定尺寸（malloc 缓冲）
    static func downsample(_ image: CGImage, w: Int, h: Int) -> [UInt8]? {
        let count = w * h * 4
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 64)
        defer { ptr.deallocate() }
        memset(ptr, 0, count)
        guard let ctx = CGContext(data: ptr, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Array(UnsafeRawBufferPointer(start: ptr, count: count))
    }

    /// 上采样到指定尺寸（CGImage）
    static func upsample(_ image: CGImage, w: Int, h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// mask 羽化（2 次盒模糊近似高斯；输入输出均为灰度图）
    static func featherMask(_ mask: CGImage, radius: Int) -> CGImage? {
        let w = mask.width, h = mask.height
        guard var bytes = rgbaGray(mask) else { return nil }
        for _ in 0..<2 {
            bytes = boxBlurGray(bytes, w: w, h: h, radius: radius)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// 灰度盒模糊
    static func boxBlurGray(_ bytes: [UInt8], w: Int, h: Int, radius: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0, count = 0
                for dy in -radius...radius {
                    let ny = y + dy
                    guard ny >= 0, ny < h else { continue }
                    for dx in -radius...radius {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        sum += Int(bytes[ny * w + nx])
                        count += 1
                    }
                }
                out[y * w + x] = UInt8(sum / max(count, 1))
            }
        }
        return out
    }
}
