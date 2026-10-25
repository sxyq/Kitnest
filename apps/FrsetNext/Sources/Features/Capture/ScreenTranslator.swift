import AppKit
import CoreGraphics
import CoreText
import Foundation
import Vision

// MARK: - 屏幕翻译（eSearch「屏幕翻译」对齐，2026-10-19 用户需求）
//
// 组合既有组件（全部在本模块内，无跨模块引用）：
//   Vision OCR（OCRService.recognizeObservations，带归一化 boundingBox）
//   → AI 翻译会话（TranslationToolSession，批量一次调用 + 逐块回退）
//   → CoreGraphics 按坐标画回（块底色采样填充 + 译文 CoreText 自适应排版）
//   → 钉回原位（PinnedScreenshotManager.show(image:at:)）
//
// eSearch translate 实证语义：译文直接「替换」屏幕上对应文本块，
// 而不是另开结果窗——本实现产出一张「翻译后截图」钉在原选区位置。

public enum ScreenTranslator {

    // MARK: 排版参数

    /// 块内边距（像素，绘制译文时向内收缩，避免顶格）
    static let textInset: CGFloat = 3
    /// 块底填充外扩（盖住 OCR 框边缘残留的原文笔画）
    static let fillOutset: CGFloat = 2
    /// 单块最多翻译字符数（超长块截断保护 token）
    static let maxBlockChars = 600
    /// 一次批量翻译的最大块数（超过则分批）
    static let batchSize = 24

    // MARK: 入口

    /// 对截图执行屏幕翻译：OCR → 翻译 → 画回 → 钉到原选区位置。
    /// 非隔离入口（供任意上下文调用），内部统一跳主线程。
    /// - Parameters:
    ///   - image: 选区截图（像素）
    ///   - pinOrigin: 原选区在屏幕上的位置（AppKit 左下原点）；nil 则贴图窗按默认错位平铺
    public static func run(image: CGImage, pinOrigin: NSPoint?) {
        Task { @MainActor in
            await runAsync(image: image, pinOrigin: pinOrigin)
        }
    }

    @MainActor
    static func runAsync(image: CGImage, pinOrigin: NSPoint?) async {
        // ① OCR（带坐标）
        let observations: [OCRTextObservation]
        do {
            observations = try await OCRService.shared.recognizeObservations(image: image)
        } catch {
            Toast.show("屏幕翻译失败：文字识别出错", icon: "exclamationmark.triangle", isWarning: true)
            Log.error("Capture", "屏幕翻译 OCR 失败: \(error.localizedDescription)")
            return
        }
        let blocks = observations
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(80)
            .map { ($0, String($0.text.prefix(maxBlockChars))) }
        guard !blocks.isEmpty else {
            Toast.show("未读取到文字，无法翻译", icon: "exclamationmark.circle.fill")
            return
        }

        // ② 翻译（批量 + 回退）
        let texts = blocks.map { $0.1 }
        let translated: [String]
        do {
            translated = try await translateBlocks(texts)
        } catch {
            Toast.show("屏幕翻译失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true)
            Log.error("Capture", "屏幕翻译调用失败: \(error.localizedDescription)")
            return
        }

        // ③ 画回（后台线程渲染，图可能很大）
        let pairs = zip(blocks.map { $0.0 }, translated).map { ($0, $1) }
        let rendered = await Task.detached(priority: .userInitiated) {
            Self.render(image: image, blocks: pairs)
        }.value
        guard let rendered else {
            Toast.show("屏幕翻译失败：渲染出错", icon: "exclamationmark.triangle", isWarning: true)
            return
        }

        // ④ 落盘 + 钉回原位
        guard let data = ImageProcessor.pngData(rendered),
              let url = ScreenshotManager.shared.savePNG(data) else {
            Toast.show("屏幕翻译结果保存失败", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        ScreenshotManager.shared.registerCaptured(url: url, data: data)
        PinnedScreenshotManager.shared.show(image: rendered, at: pinOrigin)
        Toast.show("屏幕翻译完成，已钉回原位", icon: "character.book.closed")
        Log.info("Capture", "屏幕翻译完成：\(blocks.count) 块，输出 \(rendered.width)×\(rendered.height)")
    }

    // MARK: 翻译（批量一次调用，行号对齐；失败/错位回退逐块）

    /// v126（性能审计 F0483）：正则编译缓存，避免 parseNumberedLines 每次重新编译
    private static let numberedLineRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^\\s*(\\d{1,3})[.、)．]\\s*(.+)$")

    static func translateBlocks(_ texts: [String]) async throws -> [String] {
        var result = [String](repeating: "", count: texts.count)
        var start = 0
        while start < texts.count {
            let end = min(start + batchSize, texts.count)
            let slice = Array(texts[start..<end])
            let part = try await translateBatch(slice)
            for (offset, value) in part.enumerated() where start + offset < texts.count {
                result[start + offset] = value
            }
            start = end
        }
        return result
    }

    private static func translateBatch(_ texts: [String]) async throws -> [String] {
        // 批量：编号行 → 一次会话 → 行号解析回填
        let numbered = texts.enumerated()
            .map { "\($0.offset + 1). \($0.element.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        if let reply = try? await TranslationToolSession.shared.complete(numbered) {
            let parsed = parseNumberedLines(reply, expected: texts.count)
            if parsed.count == texts.count && parsed.allSatisfy({ !$0.isEmpty }) {
                return parsed
            }
        }
        // 回退：逐块翻译（OCR 常见碎块，串行即可）
        var out: [String] = []
        for text in texts {
            out.append((try? await TranslationToolSession.shared.complete(text)) ?? text)
        }
        return out
    }

    /// 解析「1. 译文」格式；行数不齐或编号缺失时返回空数组（由调用方回退）
    static func parseNumberedLines(_ reply: String, expected: Int) -> [String] {
        guard let regex = numberedLineRegex else { return [] }
        var map: [Int: String] = [:]
        for line in reply.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            if let m = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 3,
               let idx = Int(ns.substring(with: m.range(at: 1))) {
                map[idx] = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard map.count == expected, (1...expected).allSatisfy({ map[$0]?.isEmpty == false }) else { return [] }
        return (1...expected).compactMap { map[$0] }
    }

    // MARK: 画回渲染

    /// 把译文按 OCR 坐标画回原图（返回新图；失败返回 nil）。
    /// - 块底色：规范化 RGBA 缓冲上采样块外沿环带均值（通道序确定，与字节序无关）；
    /// - 译文：CoreText 绘制（原始 CGContext 无 NSGraphicsContext，NSString.draw 不可用），
    ///   按块高定字号，宽度装不下自动缩小，垂直居中左对齐换行。
    static func render(image: CGImage, blocks: [(OCRTextObservation, String)]) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        // 规范化 RGBA 缓冲：采样通道序确定的字节 + 高质量重绘
        guard let base = Self.rgbaBuffer(image: image, interpolation: .high) else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 翻转到左上原点坐标（Vision boundingBox 为左下原点归一化）
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        for (observation, translated) in blocks where !translated.isEmpty {
            let bb = observation.boundingBox
            let rect = CGRect(x: bb.minX * CGFloat(w), y: (1 - bb.maxY) * CGFloat(h),
                              width: bb.width * CGFloat(w), height: bb.height * CGFloat(h))
                .integral
            guard rect.width >= 6, rect.height >= 8 else { continue }

            // 底色：块外沿环带采样（RGBA 缓冲，通道序可靠）
            let bg = Self.sampleBackground(buffer: base, rect: rect)
            ctx.setFillColor(bg.cgColor)
            let fill = rect.insetBy(dx: -fillOutset, dy: -fillOutset)
            ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()

            // 译文排版：字号自适应（高度装不下则逐级缩小）
            let inner = rect.insetBy(dx: textInset, dy: textInset)
            var fontSize = min(28, max(9, inner.height * 0.82))
            var font = CTFontCreateWithName("PingFang SC" as CFString, fontSize, nil)
            var layout = Self.layout(translated, font: font, fontSize: fontSize, maxWidth: inner.width)
            while layout.height > inner.height + 1 && fontSize > 9 {
                fontSize = max(9, fontSize * 0.82)
                font = CTFontCreateWithName("PingFang SC" as CFString, fontSize, nil)
                layout = Self.layout(translated, font: font, fontSize: fontSize, maxWidth: inner.width)
            }

            let color = Self.foregroundColor(for: bg)
            let ctArgs = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color.usingColorSpace(.deviceRGB)?.cgColor ?? CGColor(gray: 0, alpha: 1)
            ] as CFDictionary
            var y = inner.minY + max(0, (inner.height - layout.height) / 2)
            for line in layout.lines {
                guard let attr = CFAttributedStringCreate(nil, line as CFString, ctArgs) else { continue }
                let ctLine = CTLineCreateWithAttributedString(attr)
                // CoreText 绘制（CG 坐标系，已翻转为左上原点）
                ctx.textPosition = CGPoint(x: inner.minX, y: y + fontSize * 0.86)
                CTLineDraw(ctLine, ctx)
                y += layout.lineHeight
                if y > inner.maxY { break }
            }
        }
        return ctx.makeImage()
    }

    // MARK: 渲染辅助

    /// 把任意位图规范化为 RGBA8888（bytesPerRow = w*4，通道序与字节序无关）
    static func rgbaBuffer(image: CGImage, interpolation: CGInterpolationQuality) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = interpolation
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 块外沿环带平均色（规范化 RGBA 缓冲；上下左右取带均值，避开文字本身）
    static func sampleBackground(buffer image: CGImage, rect: CGRect) -> NSColor {
        let w = image.width, h = image.height
        guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return .white }
        let bytesPerRow = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard bpp >= 3 else { return .white }

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let cx = max(0, min(w - 1, x)), cy = max(0, min(h - 1, y))
            let off = cy * bytesPerRow + cx * bpp
            return (Int(ptr[off]), Int(ptr[off + 1]), Int(ptr[off + 2]))   // RGBA
        }
        var rs = 0, gs = 0, bs = 0, count = 0
        let band = 4
        for x in stride(from: Int(rect.minX), to: max(Int(rect.minX) + 1, Int(rect.maxX)), by: max(2, Int(rect.width) / 24)) {
            for dy in [-band, -band / 2, band / 2, band] {
                let p = pixel(x, Int(rect.minY) + dy)
                rs += p.0; gs += p.1; bs += p.2; count += 1
            }
        }
        for y in stride(from: Int(rect.minY), to: max(Int(rect.minY) + 1, Int(rect.maxY)), by: max(2, Int(rect.height) / 8)) {
            for dx in [-band, band] {
                let p = pixel(Int(rect.minX) + dx, y)
                rs += p.0; gs += p.1; bs += p.2; count += 1
            }
        }
        guard count > 0 else { return .white }
        return NSColor(red: CGFloat(rs) / CGFloat(count) / 255,
                       green: CGFloat(gs) / CGFloat(count) / 255,
                       blue: CGFloat(bs) / CGFloat(count) / 255, alpha: 1)
    }

    /// 按背景亮度取黑/白前景（相对亮度公式）
    static func foregroundColor(for background: NSColor) -> NSColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        background.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return NSColor(white: luminance > 0.6 ? 0.08 : 0.96, alpha: 1)
    }

    /// 折行排版结果
    struct TextLayout {
        var lines: [String]
        var lineHeight: CGFloat
        var height: CGFloat { lineHeight * CGFloat(max(1, lines.count)) }
    }

    /// 给定字号与最大宽度折行（CoreText 测宽，兼容中英混排）
    static func layout(_ text: String, font: CTFont, fontSize: CGFloat, maxWidth: CGFloat) -> TextLayout {
        let lineHeight = ceil(fontSize * 1.28)
        func width(_ s: String) -> CGFloat {
            guard let attr = CFAttributedStringCreate(nil, s as CFString,
                                                      [kCTFontAttributeName: font] as CFDictionary) else { return 0 }
            let line = CTLineCreateWithAttributedString(attr)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        var lines: [String] = []
        var current = ""
        var currentWidth: CGFloat = 0
        for ch in text {
            let s = String(ch)
            let cw = width(s)
            if ch == "\n" || (currentWidth + cw > maxWidth && !current.isEmpty) {
                lines.append(current)
                current = ch == "\n" ? "" : s
                currentWidth = ch == "\n" ? 0 : cw
            } else {
                current += s
                currentWidth += cw
            }
        }
        if !current.isEmpty { lines.append(current) }
        return TextLayout(lines: lines.isEmpty ? [""] : lines, lineHeight: lineHeight)
    }
}
