import AppKit
import CoreGraphics

// MARK: - 标注工具自检（v226）
//
// 用户：「这些工具需要你一个一个实测，确保没有问题」。
//
// 本机没有鼠标模拟权限（CGEvent / NSEvent 全局监听都被系统拒绝），
// 靠点画布逐个验证不现实。改走「合成器级」自检：
//   1. 造一张固定底图（文字 + 色块，供放大镜/模糊/聚光灯取样）；
//   2. 每个工具单独画一条标注，走 `AnnotationCompositor.composite`；
//   3. 与无标注的底图逐像素比对，统计差异像素与差异包围盒；
//   4. 拼一张 4×4 联系表 + 一份文本报告写进 /tmp。
//
// 判据：除橡皮/抹除（本就不产生图元）外，差异像素必须 ≥ 30。

public enum AnnotationSelfTest {

    public struct Result {
        public let tool: AnnotationTool
        public let diffPixels: Int
        public let changedRect: CGRect
        public let pass: Bool
        public let note: String
    }

    static let canvasW = 420
    static let canvasH = 320

    /// 跑全部 14 个工具，返回结果 + 两张产物路径
    @discardableResult
    public static func run() -> [Result] {
        guard let base = makeBase() else { return [] }
        let baseline = pixels(of: base)

        var results: [Result] = []
        var previews: [(AnnotationTool, CGImage)] = []

        for tool in AnnotationTool.allCases {
            let spec = sample(for: tool)
            let out = AnnotationCompositor.composite(base: base, annotations: spec.annotations) ?? base
            let d = diff(baseline, pixels(of: out))
            let expectsInk = !spec.expectsNoInk
            let pass = expectsInk ? (d.count >= 30) : (d.count == 0)
            results.append(Result(tool: tool,
                                  diffPixels: d.count,
                                  changedRect: d.rect,
                                  pass: pass,
                                  note: spec.note))
            previews.append((tool, out))
        }

        writeReport(results)
        writeSheet(previews)
        return results
    }

    // MARK: 每个工具的样例标注

    private struct Spec {
        let annotations: [Annotation]
        let expectsNoInk: Bool
        let note: String
    }

    private static func sample(for tool: AnnotationTool) -> Spec {
        let red = "#FF3B30"
        switch tool {
        case .rectangle:
            return Spec(annotations: [Annotation(tool: .rectangle,
                                                 points: [CGPoint(x: 30, y: 30), CGPoint(x: 150, y: 110)],
                                                 colorHex: red, lineWidth: 4)],
                        expectsNoInk: false, note: "矩形描边")

        case .ellipse:
            return Spec(annotations: [Annotation(tool: .ellipse,
                                                 points: [CGPoint(x: 170, y: 30), CGPoint(x: 290, y: 110)],
                                                 colorHex: red, lineWidth: 4)],
                        expectsNoInk: false, note: "椭圆描边")

        case .arrow:
            return Spec(annotations: [Annotation(tool: .arrow,
                                                 points: [CGPoint(x: 30, y: 130), CGPoint(x: 150, y: 190)],
                                                 colorHex: red, lineWidth: 4)],
                        expectsNoInk: false, note: "箭头 + 箭头头部")

        case .text:
            return Spec(annotations: [Annotation(tool: .text, points: [CGPoint(x: 170, y: 130)],
                                                 text: "文字 Test", colorHex: red,
                                                 lineWidth: 4, weight: 1)],
                        expectsNoInk: false, note: "文字落笔")

        case .remark:
            return Spec(annotations: [Annotation(tool: .remark,
                                                 points: [CGPoint(x: 40, y: 250), CGPoint(x: 120, y: 200)],
                                                 text: "备注说明", colorHex: red, lineWidth: 4, weight: 1)],
                        expectsNoInk: false, note: "起点圆 + 折线 + 白底文本框")

        case .counter:
            return Spec(annotations: [Annotation(tool: .counter, points: [CGPoint(x: 200, y: 210)],
                                                 text: "1", colorHex: red, lineWidth: 26)],
                        expectsNoInk: false, note: "实心圆 + 白色序号")

        case .highlighter:
            return Spec(annotations: [Annotation(tool: .highlighter,
                                                 points: [CGPoint(x: 30, y: 270), CGPoint(x: 200, y: 268)],
                                                 colorHex: "#FFD60A", lineWidth: 4)],
                        expectsNoInk: false, note: "半透明粗笔触")

        case .spotlight:
            return Spec(annotations: [Annotation(tool: .spotlight,
                                                 points: [CGPoint(x: 240, y: 170), CGPoint(x: 380, y: 300)],
                                                 colorHex: red, lineWidth: 9, aux: 0.55)],
                        expectsNoInk: false, note: "整图压暗 + 挖洞（差异应覆盖大半画面）")

        case .magnifier:
            // 圆放大到 140，取样区覆盖三行文字，方便肉眼判断「是否上下颠倒」
            return Spec(annotations: [Annotation(tool: .magnifier,
                                                 points: [CGPoint(x: 230, y: 45), CGPoint(x: 370, y: 185)],
                                                 colorHex: red, lineWidth: 9, aux: 2.0)],
                        expectsNoInk: false, note: "圆内 2× 放大（底图此处有三行文字）")

        case .mosaic:
            // 必须涂在有细节的地方（文字/边界）：纯色块像素化后颜色不变，
            // 差异会有但肉眼看不出效果（第二版踩了这个）
            return Spec(annotations: [Annotation(tool: .mosaic,
                                                 points: (0...8).map { CGPoint(x: 250 + CGFloat($0) * 18, y: 60) },
                                                 colorHex: red, lineWidth: 26, blockSize: 10)],
                        expectsNoInk: false, note: "笔触内像素化（须落在文字上才看得出）")

        case .blur:
            // 涂在第三行文字上（与马赛克错开一行，便于分别观察）
            return Spec(annotations: [Annotation(tool: .blur,
                                                 points: (0...8).map { CGPoint(x: 250 + CGFloat($0) * 18, y: 118) },
                                                 colorHex: red, lineWidth: 26, blockSize: 16)],
                        expectsNoInk: false, note: "笔触内降采样模糊（须落在文字上）")

        case .eraser:
            return Spec(annotations: [Annotation(tool: .eraser,
                                                 points: [CGPoint(x: 30, y: 30), CGPoint(x: 150, y: 110)],
                                                 colorHex: red, lineWidth: 4)],
                        expectsNoInk: true, note: "不产生图元（靠画布删标注，预期零差异）")

        case .removal:
            return Spec(annotations: [Annotation(tool: .removal,
                                                 points: [CGPoint(x: 30, y: 30), CGPoint(x: 150, y: 110)],
                                                 colorHex: red, lineWidth: 4)],
                        expectsNoInk: true, note: "不产生图元（改底图像素，预期零差异）")

        case .pen:
            return Spec(annotations: [Annotation(tool: .pen,
                                                 points: [CGPoint(x: 30, y: 180), CGPoint(x: 70, y: 150),
                                                          CGPoint(x: 110, y: 185), CGPoint(x: 150, y: 155)],
                                                 colorHex: red, lineWidth: 4)],
                        expectsNoInk: false, note: "多段折线")
        }
    }

    // MARK: 底图

    static func makeBase() -> CGImage? {
        let w = canvasW, h = canvasH
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 色块（聚光灯/马赛克/模糊的取样对象）
        let blocks: [(NSColor, CGFloat, CGFloat)] = [
            (NSColor.systemBlue, 30, 40), (NSColor.systemOrange, 120, 40), (NSColor.systemGreen, 210, 40)
        ]
        for (color, x, y) in blocks {
            ctx.setFillColor(color.withAlphaComponent(0.45).cgColor)
            // CG 原点左下，这里换算成左上坐标显示
            ctx.fill(CGRect(x: x, y: CGFloat(h) - y - 70, width: 80, height: 70))
        }

        // 文字（放大镜取样）：三行，字号够大
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
        ]
        ("放大镜取样 SAMPLE" as NSString).draw(at: CGPoint(x: 245, y: 45), withAttributes: attrs)
        ("第二行 LINE TWO" as NSString).draw(at: CGPoint(x: 245, y: 78), withAttributes: attrs)
        ("第三行 LINE 3" as NSString).draw(at: CGPoint(x: 245, y: 111), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        return ctx.makeImage()
    }

    // MARK: 像素比对

    private static func pixels(of image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return buf
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func diff(_ a: [UInt8], _ b: [UInt8]) -> (count: Int, rect: CGRect) {
        guard a.count == b.count, !a.isEmpty else { return (0, .zero) }
        var count = 0
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        let stride = canvasW * 4
        var i = 0
        while i < a.count {
            // 任一通道差 > 6 视为变化（避开亚像素抖动）
            let d = abs(Int(a[i]) - Int(b[i]))
                + abs(Int(a[i + 1]) - Int(b[i + 1]))
                + abs(Int(a[i + 2]) - Int(b[i + 2]))
            if d > 6 {
                count += 1
                let p = i / 4
                let x = p % canvasW, y = p / canvasW
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            i += 4
        }
        _ = stride
        guard count > 0 else { return (0, .zero) }
        return (count, CGRect(x: minX, y: minY,
                              width: maxX - minX + 1, height: maxY - minY + 1))
    }

    // MARK: 产物

    private static func writeReport(_ results: [Result]) {
        func pad(_ s: String, _ n: Int) -> String {
            // 中文按 2 字宽算，保证列对齐（String(format:) 的 %-10@ 对 NSString 无效）
            let width = s.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) }
            return s + String(repeating: " ", count: max(0, n - width))
        }
        var lines: [String] = []
        lines.append("标注工具自检  \(canvasW)×\(canvasH)  共 \(results.count) 项")
        lines.append(pad("工具", 14) + pad("差异", 8) + pad("结果", 6) + pad("差异区域", 20) + "说明")
        for r in results {
            let rect = r.changedRect == .zero
                ? "—"
                : "\(Int(r.changedRect.minX)),\(Int(r.changedRect.minY)) \(Int(r.changedRect.width))×\(Int(r.changedRect.height))"
            lines.append(pad(r.tool.rawValue, 14)
                         + pad("\(r.diffPixels)", 8)
                         + pad(r.pass ? "PASS" : "FAIL", 6)
                         + pad(rect, 20)
                         + r.note)
        }
        let failed = results.filter { !$0.pass }
        lines.append("")
        lines.append(failed.isEmpty
                     ? "结论：全部通过（\(results.count)/\(results.count)）"
                     : "结论：\(failed.count) 项未通过 → \(failed.map(\.tool.rawValue).joined(separator: ", "))")
        let text = lines.joined(separator: "\n")
        try? text.write(toFile: "/tmp/annot_selftest.txt", atomically: true, encoding: .utf8)
        Log.info("Capture", "标注自检完成：\n\(text)")
    }

    /// 4 列联系表：每格是「底图 + 该工具标注」的缩略，格下写工具名与差异数
    private static func writeSheet(_ previews: [(AnnotationTool, CGImage)]) {
        let cols = 4
        let cellW: CGFloat = 220, cellH: CGFloat = 190
        let rows = (previews.count + cols - 1) / cols
        let size = NSSize(width: cellW * CGFloat(cols) + 20,
                          height: cellH * CGFloat(rows) + 20)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        for (i, item) in previews.enumerated() {
            let c = i % cols, r = i / cols
            let x = 10 + CGFloat(c) * cellW
            let y = size.height - 10 - CGFloat(r + 1) * cellH
            let image = NSImage(cgImage: item.1, size: NSSize(width: canvasW, height: canvasH))
            image.draw(in: NSRect(x: x + 10, y: y + 28, width: cellW - 20, height: cellH - 42),
                       from: .zero, operation: .sourceOver, fraction: 1)
            NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
            NSBezierPath(rect: NSRect(x: x + 10, y: y + 28, width: cellW - 20, height: cellH - 42)).stroke()

            let label = "\(i + 1). \(item.0.title)  \(item.0.rawValue)"
            (label as NSString).draw(at: NSPoint(x: x + 10, y: y + 8),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                 .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)])
        }
        img.unlockFocus()
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = ImageProcessor.pngData(cg) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/annot_selftest.png"))
    }
}
