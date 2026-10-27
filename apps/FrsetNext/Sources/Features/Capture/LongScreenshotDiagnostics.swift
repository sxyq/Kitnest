import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图拼接自检（v150）
//
// 为什么需要它：拼接算法的回归只有在「已知位移的连续帧」上才能量出来，而真机
// 验证要拖鼠标/滚动目标窗口。这里用**合成长图 + 已知位移切片**回灌拼接器，
// 在 App 内跑一遍并写日志——不碰鼠标、不依赖任何窗口。
//
// 入口：frsetnext://longshotcheck
// 判据：画布宽度 == 帧宽；画布高度 == 最后一个成功位移 + 帧高；与源图逐行比对
//       最差行差 < 8（0 表示逐像素一致）。

enum LongScreenshotDiagnostics {

    static func runStitcherCheck() {
        DispatchQueue.global(qos: .userInitiated).async {
            let W = 480, H = 3600, FH = 500
            guard let src = makeSource(width: W, height: H) else {
                Log.error("Capture", "长截图自检：合成源图失败")
                return
            }
            // 已知位移序列（含 1-3px 抖动、不均匀步长、一次快速大跳）
            let offsets = [0, 170, 391, 640, 903, 1150, 1399, 1650, 1902, 2150,
                           2401, 2650, 2902, 3100]
            let stitcher = LongScreenshotStitcher()
            var prev = 0
            var appendedFrames = 0
            var lines: [String] = []

            for (index, off) in offsets.enumerated() {
                guard let frame = src.cropping(to: CGRect(x: 0, y: off, width: W, height: FH)) else {
                    lines.append("#\(index) off=\(off) 切片失败")
                    continue
                }
                let hint = Double(off - prev)
                prev = off
                let outcome = stitcher.append(frame: frame, hintDY: hint)
                if outcome.isAppended { appendedFrames += 1 }
                lines.append("#\(index) off=\(off) hint=\(Int(hint)) → \(describe(outcome))"
                             + "（d=(\(stitcher.lastOffset.dx),\(stitcher.lastOffset.dy))）")
                // 中途重复一帧（模拟用户停住不动）→ 必须是 unchanged
                if index == 4 {
                    let again = stitcher.append(frame: frame, hintDY: 0)
                    lines.append("   ↳ 重复帧 → \(describe(again))")
                }
            }
            // 反向滚动（回看）→ 必须是 unchanged，且画布不能被裁短
            let beforeReverse = stitcher.canvasHeight
            if let back = src.cropping(to: CGRect(x: 0, y: 1900, width: W, height: FH)) {
                let outcome = stitcher.append(frame: back, hintDY: -400)
                lines.append("↳ 向上滚动 → \(describe(outcome))，画布高度 \(beforeReverse) → \(stitcher.canvasHeight)")
            }

            let lastOffset = offsets.last ?? 0
            let expectedH = lastOffset + FH
            let widthOK = stitcher.canvasWidth == W
            let heightOK = abs(stitcher.canvasHeight - expectedH) <= 2

            // 与源图逐行比对（只看共同高度）
            var worst = 0.0
            var badRows = 0
            if let canvas = stitcher.canvas {
                let canvasBuf = LongShotRGBA(image: canvas)
                let srcBuf = LongShotRGBA(image: src)
                let rows = min(canvasBuf.h, expectedH, srcBuf.h)
                var y = 0
                while y < rows {
                    var sum = 0, n = 0, x = 0
                    while x < W {
                        let a = (y * canvasBuf.w + x) * 4
                        let b = (y * srcBuf.w + x) * 4
                        sum += abs(Int(canvasBuf.bytes[a]) - Int(srcBuf.bytes[b]))
                            + abs(Int(canvasBuf.bytes[a + 1]) - Int(srcBuf.bytes[b + 1]))
                            + abs(Int(canvasBuf.bytes[a + 2]) - Int(srcBuf.bytes[b + 2]))
                        n += 3
                        x += 2
                    }
                    let d = Double(sum) / Double(max(n, 1))
                    if d > worst { worst = d }
                    if d > 8 { badRows += 1 }
                    y += 1
                }
            }

            let ok = widthOK && heightOK && worst < 8
            Log.info("Capture", "长截图自检 \(ok ? "通过 ✓" : "失败 ✗")："
                     + "画布 \(stitcher.canvasWidth)×\(stitcher.canvasHeight)（期望 \(W)×\(expectedH)），"
                     + "追加 \(appendedFrames)/\(offsets.count) 帧，"
                     + "与源图最差行差 \(String(format: "%.2f", worst))，超阈值行 \(badRows)")
            for line in lines {
                Log.info("Capture", "  自检 \(line)")
            }
        }
    }

    /// 用合成长图打开预览窗（排障：验证等比缩放 / 初始滚动位置）
    static func showPreviewDemo() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = makeSource(width: 480, height: 3600) else { return }
            DispatchQueue.main.async {
                LongScreenshotPreviewController.shared.show(image: src)
                Log.info("Capture", "长截图预览演示：480×3600（排障用）")
            }
        }
    }

    private static func describe(_ outcome: LongScreenshotStitcher.Outcome) -> String {
        switch outcome {
        case .appended(let rows): return "追加 \(rows) 行"
        case .unchanged(let why): return "未追加（\(why)）"
        case .failed(let why):    return "失败（\(why)）"
        }
    }

    /// 合成一张「无周期性」的长图：随机行高/缩进/字号/色块 + 唯一编号
    private static func makeSource(width: Int, height: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        func r(_ n: Int) -> Int { Int(rnd() % UInt64(max(1, n))) }
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
                     "hotel", "india", "juliet", "kilo", "lima", "mike", "november"]

        var y = 6
        var i = 1
        while y < height - 30 {
            let rowH = 14 + r(20)
            let indent = r(48)
            if r(10) < 2 {
                let w = 40 + r(300)
                NSColor(calibratedWhite: CGFloat(180 + r(60)) / 255.0, alpha: 1).setFill()
                NSRect(x: CGFloat(indent), y: CGFloat(height - y - rowH), width: CGFloat(w), height: CGFloat(rowH)).fill()
            } else {
                let token = String(format: "%06x", Int(rnd() % 0xFFFFFF))
                var text = String(format: "%03d [%@] ", i, token)
                for _ in 0..<(2 + r(5)) { text += words[r(words.count)] + " " }
                text += "#\(i * 37 % 9973)"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: CGFloat(10 + r(7)), weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: CGFloat(r(70)) / 255.0, alpha: 1)
                ]
                (text as NSString).draw(at: NSPoint(x: CGFloat(indent), y: CGFloat(height - y - rowH)),
                                         withAttributes: attrs)
            }
            y += rowH + 3
            i += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
}
