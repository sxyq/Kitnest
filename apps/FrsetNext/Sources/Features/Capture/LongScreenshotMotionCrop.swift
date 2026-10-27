import AppKit
import CoreGraphics
import Foundation

// MARK: - 框选内「正在滚动」区域的检测（v152）
//
// 需求（用户实测）：框选一块区域时，里面常常同时包含
//   · 前台正在滚动的窗口（内容在动）
//   · 后台静止的窗口 / 侧边栏 / 桌面（完全不动）
// 整幅做位移对齐会被静止部分主导（它在任何 dy 下都「完美吻合」），
// 拼出来就是「静止背景 + 错乱的内容」。
//
// 做法：比较前后两帧的**逐列差异**——
//   · 静止列：两帧同位置像素几乎相同 → 差异 ≈ 0
//   · 滚动列：内容整体上移，同位置像素差异很大（文字边缘全变）
// 对差异做闭运算（填掉行间空白造成的小缺口），取最长的一段作为「运动区」，
// 之后所有帧都按这个区间裁剪，画布也同步重裁，输出就只剩滚动窗口。
//
// 为什么按列不按行：滚动是竖向位移，同一列的像素会整列被替换；同一行则可能
// 恰好是空白行，任何 dy 都一样。列的判别力更强、也更稳定。

enum LongScreenshotMotionCrop {

    /// 分析前后两帧，返回「正在运动」的像素列区间（左闭右开）。
    /// - Returns: nil 表示整幅都在动（正常长截图），或无法判断（不裁剪）
    static func movingColumns(previous: CGImage, current: CGImage) -> Range<Int>? {
        let w = current.width, h = current.height
        guard previous.width == w, previous.height == h, w > 64, h > 64 else { return nil }

        // 4×4 降采样成灰度，成本 O(w*h/16)，594×494 ≈ 18k 次比较
        let sw = max(32, w / 4)
        let sh = max(32, h / 4)
        guard let a = gray(previous, w: sw, h: sh),
              let b = gray(current, w: sw, h: sh) else { return nil }

        // 逐列平均绝对差
        var colDiff = [Double](repeating: 0, count: sw)
        var sum = 0.0
        for y in 0..<sh {
            let row = y * sw
            for x in 0..<sw {
                let d = abs(Int(a[row + x]) - Int(b[row + x]))
                colDiff[x] += Double(d)
                sum += Double(d)
            }
        }
        let rows = Double(sh)
        for x in 0..<sw { colDiff[x] /= rows }
        let meanAll = sum / Double(sw * sh)

        // 阈值：既要有绝对下限（噪声），也要明显高于全图平均（区分「整体在动」）
        let noiseFloor = 5.0
        let moving = colDiff.map { $0 >= max(noiseFloor, meanAll * 2.0) }

        // 闭运算：填掉 ≤ 8 个降采样列（≈32px）的空隙（空白列、行间距）
        var closed = moving
        var x = 0
        while x < sw {
            if !closed[x] {
                var j = x
                while j < sw, !closed[j] { j += 1 }
                let gap = j - x
                if x > 0, j < sw, gap <= 8 {
                    for k in x..<j { closed[k] = true }
                }
                x = j
            } else {
                x += 1
            }
        }

        // 取最长连续运动段
        var bestStart = -1, bestLen = 0
        var i = 0
        while i < sw {
            guard closed[i] else { i += 1; continue }
            var j = i
            while j < sw, closed[j] { j += 1 }
            if j - i > bestLen { bestLen = j - i; bestStart = i }
            i = j
        }
        guard bestStart >= 0, bestLen > 0 else { return nil }

        // 只裁掉「确实有一大块静止区」的情况：
        //   · 运动区至少覆盖 25% 宽度且 ≥ 160px
        //   · 且确实存在 ≥ 8% 宽度的静止区（否则整幅都在动，不必裁）
        let x0 = bestStart * 4
        let x1 = min(w, (bestStart + bestLen) * 4)
        let movingWidth = x1 - x0
        guard movingWidth >= max(160, Int(Double(w) * 0.25)) else { return nil }
        guard w - movingWidth >= max(24, Int(Double(w) * 0.08)) else { return nil }

        // 关键：运动区两侧往往还有同一窗口的空白留白（页面左边距、列表缩进），
        // 它们本身不变化，但属于滚动窗口的一部分——直接按运动列裁会切字。
        // 做法：向外找最近的「强竖直边缘」（列均值突变 = 面板/窗口边界），
        // 吸附到那里；找不到才退回 8px 小外扩。
        let cols = columnMeans(current)
        func edgeSearch(from: Int, to: Int, step: Int) -> Int? {
            var best: Int?
            var bestDelta = 6.0          // 至少 6 级灰度差才算「边」
            var x = from
            while step > 0 ? x < to : x > to {
                let i = min(max(x, 1), w - 1)
                let d = abs(cols[i] - cols[i - 1])
                if d > bestDelta { bestDelta = d; best = i }
                x += step
            }
            return best
        }
        let leftLimit = max(0, x0 - max(120, w / 3))
        let rightLimit = min(w, x1 + max(80, w / 6))
        let left = edgeSearch(from: max(leftLimit, x0 - 1), to: leftLimit - 1, step: -1) ?? max(0, x0 - 8)
        let right = edgeSearch(from: min(x1 + 1, rightLimit - 1), to: rightLimit, step: 1) ?? min(w, x1 + 8)
        return left..<max(left + 32, right)
    }

    /// 两个区间是否高度重合（用于「连续两次检测一致才锁定」）
    static func similar(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        let inter = max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
        let union = max(a.upperBound, b.upperBound) - min(a.lowerBound, b.lowerBound)
        guard union > 0 else { return false }
        return Double(inter) / Double(union) >= 0.8
    }

    /// 每列灰度均值（全分辨率、按行抽样）——用于找竖直边界
    private static func columnMeans(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        guard let g = gray(image, w: w, h: h) else { return [Double](repeating: 0, count: w) }
        var out = [Double](repeating: 0, count: w)
        let step = max(1, h / 240)
        var rows = 0
        var y = 0
        while y < h {
            let row = y * w
            for x in 0..<w { out[x] += Double(g[row + x]) }
            rows += 1
            y += step
        }
        if rows > 0 { for x in 0..<w { out[x] /= Double(rows) } }
        return out
    }

    private static func gray(_ image: CGImage, w: Int, h: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }
}
