import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - OCR 全链路自检（v145）
//
// 用途：不依赖鼠标操作，验证「截图识字」这条链路的真实效果——
//   合成一张含典型错字的中文样张 → 先只跑 Apple Vision，再跑 Vision + 本地 PP-OCR，
//   把两者的**识别文本、耗时、进程内存**都写进日志。
//
// 为什么需要它：本地 OCR 改成了子进程（PPOCROCREmote），真机验收不能只测「子进程能起来」，
// 还要证明它**接进了 OCRService 的复核环节**、并且确实把 Vision 的错字纠正了。
enum OCRDiagnostics {

    /// 样张里刻意放了三个历史实测中 Vision 会错的地方：
    /// 「下面的路径」曾认成「下面钓路径」、「请重试」曾认成「诱重试」、
    /// 「支持」整词丢失。PP-OCR 应该能把它们修正回来。
    static let sampleLines = [
        "系统设置里找不到这个选项，你可以按下面的路径操作：",
        "错误码 E1024：连接超时，请重试。",
        "支持 macOS 14+ / Apple Silicon"
    ]

    static func runPipelineCheck() {
        guard let image = makeSample() else {
            Log.warn("Capture", "OCR 自检：样张生成失败")
            return
        }
        let sizeText = "\(image.width)x\(image.height)"
        let before = residentMB()
        Log.info("Capture", "OCR 自检 开始：样张 \(sizeText)，进程内存 \(fmt(before)) MB，"
                 + "真值「\(sampleLines.joined(separator: " / "))」")

        Task {
            let t0 = CFAbsoluteTimeGetCurrent()
            let visionOnly = (try? await OCRService.shared.recognizeText(image: image, quality: .fast)) ?? ""
            let t1 = CFAbsoluteTimeGetCurrent()
            let peakAfterVision = residentMB()

            let withPPOCR = (try? await OCRService.shared.recognizeText(image: image, quality: .thorough)) ?? ""
            let t2 = CFAbsoluteTimeGetCurrent()
            let peakAfterThorough = residentMB()

            // 等子进程收尾，再看内存是否回到基线
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let settled = residentMB()

            Log.info("Capture", "OCR 自检 仅Vision \(Int((t1 - t0) * 1000))ms → "
                     + oneLine(visionOnly))
            Log.info("Capture", "OCR 自检 含本地PPOCR \(Int((t2 - t1) * 1000))ms → "
                     + oneLine(withPPOCR))
            Log.info("Capture", "OCR 自检 内存：识别前 \(fmt(before)) → Vision后 \(fmt(peakAfterVision))"
                     + " → PP-OCR后 \(fmt(peakAfterThorough)) → 1.5s后 \(fmt(settled)) MB")
            let same = normalized(visionOnly) == normalized(withPPOCR)
            Log.info("Capture", "OCR 自检 结论：\(same ? "两者一致（PP-OCR 未改字或未生效）" : "PP-OCR 已改写结果")"
                     + "；与真值完全一致=\(normalized(withPPOCR) == normalized(sampleLines.joined()))")

            await runSmallURLCheck()
        }
    }

    // MARK: - v151：大画布上的小链接（用户实测「认不出网址」的复现样本）

    private static let urlTruth = "in.pinterest.com/pin/1059120037362840070/"

    /// 1600×900 深色画布 + 把真实截图里的链接条按**原生尺寸**贴进去：
    /// 复现用户实测的失败场景（原生尺寸下 Vision 一行都检测不到，放大 2× 才读得出）。
    /// 素材：Resources/OCR/sample-url.png（438×68，公开的 Pinterest 链接，无个人信息）
    private static func makeSmallURLDump() -> CGImage? {
        let bundleURL = Bundle.main.url(forResource: "sample-url", withExtension: "png", subdirectory: "OCR")
            ?? Bundle.main.url(forResource: "sample-url", withExtension: "png")
        guard let url = bundleURL,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let strip = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            Log.warn("Capture", "OCR 小字链接自检：缺少 sample-url.png 素材，跳过")
            return nil
        }
        let w = 1600, h = 900
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(strip, in: CGRect(x: 200, y: 400,
                                   width: CGFloat(strip.width), height: CGFloat(strip.height)))
        return ctx.makeImage()
    }

    private static func runSmallURLCheck() async {
        guard let image = makeSmallURLDump() else { return }
        Log.info("Capture", "OCR 小字链接自检 开始：\(image.width)×\(image.height) 深色画布 + 12pt 灰字，真值「\(urlTruth)」")
        for quality in [("fast", OCRQuality.fast), ("thorough", OCRQuality.thorough)] {
            let t0 = CFAbsoluteTimeGetCurrent()
            let text = (try? await OCRService.shared.recognizeText(image: image, quality: quality.1)) ?? ""
            let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let hit = normalized(text).contains(normalized(urlTruth))
            Log.info("Capture", "OCR 小字链接自检 \(quality.0) \(ms)ms → \(oneLine(text))"
                     + "（命中真值=\(hit)）")
        }
    }

    // MARK: - 样张

    private static func makeSample() -> CGImage? {
        let fontSize: CGFloat = 14
        let lineHeight = ceil(fontSize * 1.7)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "PingFang SC", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black
        ]
        let maxWidth = (sampleLines.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 320) + 30
        let width = Int(ceil(maxWidth))
        let height = Int(ceil(lineHeight * CGFloat(sampleLines.count) + 24))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, line) in sampleLines.enumerated() {
            let y = height - 12 - Int(lineHeight) * (index + 1)
            (line as NSString).draw(at: NSPoint(x: 15, y: y), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: - 工具

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " / ")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && $0 != "\n" }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1024 / 1024 : -1
    }
}
