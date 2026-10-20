import AppKit
import CoreGraphics

// MARK: - 标注工具与数据模型

/// 标注工具类型（对应原作截图工具条的箭头 / 矩形 / 文字等）
public enum AnnotationTool: String, CaseIterable, Identifiable {
    // 前 5 个是原版截图标注就有的；后 4 个对齐 ZTools「剪贴板图片涂改」插件 + eSearch removeObj
    case rectangle, ellipse, arrow, pen, text, highlighter, mosaic, eraser, removal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse:   return "椭圆"
        case .arrow:     return "箭头"
        case .pen:       return "画笔"
        case .text:      return "文字"
        case .highlighter: return "荧光"
        case .mosaic:    return "马赛克"
        case .eraser:    return "橡皮"
        case .removal:   return "抹除"
        }
    }

    /// 键盘快捷键（单键；与 Flameshot / SuperSnip 的直觉一致）
    public var shortcut: String {
        switch self {
        case .rectangle: return "R"
        case .ellipse:   return "O"
        case .arrow:     return "A"
        case .pen:       return "P"
        case .text:      return "T"
        case .highlighter: return "H"
        case .mosaic:    return "M"
        case .eraser:    return "E"
        case .removal:   return "D"
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .pen:       return "pencil"            // pencil.tip 部分 SDK 缺失
        case .text:      return "text.cursor"        // textformat 在 mac SDK 不存在，会回退显示「格式」
        case .highlighter: return "highlighter"
        case .mosaic:    return "squareshape.split.3x3"
        case .eraser:    return "eraser"
        case .removal:   return "wand.and.rays.inverse"
        }
    }
}

/// 一条标注。坐标一律使用**原图像素坐标、左上原点**，
/// 这样合成器与画布可以共用同一套坐标，与缩放无关。
public struct Annotation: Identifiable, Hashable {
    public let id: UUID
    public var tool: AnnotationTool
    /// 形状类：`[起点, 终点]`；画笔：全部途经点；文字：`[锚点]`
    public var points: [CGPoint]
    public var text: String?
    public var colorHex: String
    public var lineWidth: CGFloat
    /// 马赛克块大小（图像像素；8–16 之间观感最好，越小越容易被还原）
    public var blockSize: CGFloat

    public init(id: UUID = UUID(),
                tool: AnnotationTool,
                points: [CGPoint],
                text: String? = nil,
                colorHex: String = "#FF3B30",
                lineWidth: CGFloat = 3,
                blockSize: CGFloat = 10) {
        self.id = id
        self.tool = tool
        self.points = points
        self.text = text
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.blockSize = blockSize
    }
}

// MARK: - 标注合成

/// 标注合成器：把标注列表绘制到底图上，产出新的 CGImage。
///
/// 对应原作 `AnnotationCompositor`（191 类清单）。实现要点：
/// - 底图在标准 CG 坐标系（左下原点）绘制，保证方向正确；
/// - 之后对上下文做一次翻转，使标注可以用「左上原点」的图像像素坐标直接绘制；
/// - 形状/文字统一走 AppKit（NSBezierPath / NSAttributedString），与画布预览共用 `draw`，避免两套逻辑。
public enum AnnotationCompositor {

    // MARK: 合成入口

    /// 把标注烧录进底图；无标注时原样返回底图。
    public static func composite(base: CGImage, annotations: [Annotation]) -> CGImage? {
        guard !annotations.isEmpty else { return base }
        let w = base.width, h = base.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // ① 底图：标准 CG 坐标系，正常方向
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        // ② 翻转成左上原点，标注坐标即可直接使用
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // ③ 用 AppKit 绘制（NSString 在 flipped 上下文里方向才正确）
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        // 马赛克像素化图层：同块大小只算一次（导出/复制路径没有画布的缓存）
        var mosaicCache: [Int: CGImage] = [:]
        let provider: (CGFloat) -> CGImage? = { block in
            let key = Int(block)
            if let hit = mosaicCache[key] { return hit }
            guard let img = pixelated(base, block: block) else { return nil }
            mosaicCache[key] = img
            return img
        }
        draw(annotations, in: CGRect(x: 0, y: 0, width: w, height: h),
             base: base, mosaicCache: provider)
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    // MARK: 绘制

    /// 在当前 NSGraphicsContext 中绘制标注。`rect` 为可绘制区域（左上原点坐标），
    /// 用于把坐标裁剪掉落在画面外的部分。
    public static func draw(_ annotations: [Annotation], in rect: CGRect, base: CGImage? = nil,
                            mosaicCache: ((CGFloat) -> CGImage?)? = nil) {
        guard let clip = NSGraphicsContext.current else { return }
        clip.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        for annotation in annotations { draw(annotation, base: base, mosaicCache: mosaicCache) }
        clip.restoreGraphicsState()
    }

    private static func draw(_ a: Annotation, base: CGImage? = nil,
                             mosaicCache: ((CGFloat) -> CGImage?)? = nil) {
        let color = color(fromHex: a.colorHex)
        switch a.tool {
        case .rectangle:
            guard let r = rect(of: a) else { return }
            let path = NSBezierPath(rect: r)
            apply(path, color: color, lineWidth: a.lineWidth)
        case .ellipse:
            guard let r = rect(of: a) else { return }
            let path = NSBezierPath(ovalIn: r)
            apply(path, color: color, lineWidth: a.lineWidth)
        case .arrow:
            drawArrow(a, color: color)
        case .pen:
            guard a.points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: a.points[0])
            for p in a.points.dropFirst() { path.line(to: p) }
            apply(path, color: color, lineWidth: a.lineWidth)
        case .highlighter:
            // 荧光笔：同画笔轨迹，但更粗且半透明（压字不挡字）
            guard a.points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: a.points[0])
            for p in a.points.dropFirst() { path.line(to: p) }
            path.lineWidth = a.lineWidth * 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.withAlphaComponent(0.35).setStroke()
            path.stroke()
        case .mosaic:
            // 画笔式马赛克：沿轨迹铺像素化图层（遮罩 = 圆头笔触），支持任意笔刷宽度
            drawMosaicBrush(a, base: base, fallbackColor: color,
                            pixelated: mosaicCache?(a.blockSize))
        case .eraser:
            return   // 橡皮不产生图元（在画布上直接删标注）
        case .removal:
            return   // 抹除不产生图元（在画布上直接修底图像素，画布另有涂抹预览）
        case .text:
            guard let anchor = a.points.first, let text = a.text, !text.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize(for: a.lineWidth), weight: .semibold),
                .foregroundColor: color
            ]
            (text as NSString).draw(at: anchor, withAttributes: attrs)
        }
    }

    /// 马赛克笔刷：把「像素化底图」裁剪进笔触路径里。
    /// 参考实现：SuperSnip（像素化笔刷 + 笔刷尺寸）、js-screenshot（blockSize/brushSize 分离）、
    /// Flameshot（块均值重采样）。像素化图层由调用方缓存，拖动时零重算。
    private static func drawMosaicBrush(_ a: Annotation,
                                        base: CGImage?,
                                        fallbackColor: NSColor,
                                        pixelated: CGImage?) {
        let width = max(4, a.lineWidth)
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if a.points.count == 1, let p = a.points.first {
            path.appendOval(in: CGRect(x: p.x - width / 2, y: p.y - width / 2,
                                       width: width, height: width))
        } else {
            guard let first = a.points.first else { return }
            path.move(to: first)
            for p in a.points.dropFirst() { path.line(to: p) }
        }

        guard let pixelated, let base, let ctx = NSGraphicsContext.current?.cgContext else {
            // 无底图（纯预览）时用半透明色带表示笔触范围
            fallbackColor.withAlphaComponent(0.22).setStroke()
            fallbackColor.withAlphaComponent(0.22).setFill()
            if a.points.count == 1 { path.fill() } else { path.stroke() }
            return
        }

        ctx.saveGState()
        if a.points.count == 1 {
            // 单击落一个点：填充圆
            path.addClip()
        } else {
            path.addClip()
        }
        ctx.interpolationQuality = .none
        ctx.draw(pixelated, in: CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height)))
        ctx.restoreGState()
    }

    /// 像素化：按 block 尺寸缩小再放大（nearest）。块内取均值，不是模糊滤镜。
    public static func pixelated(_ base: CGImage, block: CGFloat) -> CGImage? {
        let b = max(4, block)
        let smallW = max(1, Int(round(CGFloat(base.width) / b)))
        let smallH = max(1, Int(round(CGFloat(base.height) / b)))
        guard let ctx = CGContext(data: nil, width: smallW, height: smallH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: smallW, height: smallH))
        return ctx.makeImage()
    }

    private static func drawArrow(_ a: Annotation, color: NSColor) {
        guard a.points.count >= 2, let p0 = a.points.first, let p1 = a.points.last else { return }
        let path = NSBezierPath()
        path.move(to: p0)
        path.line(to: p1)

        let angle = atan2(p1.y - p0.y, p1.x - p0.x)
        let head = max(10, a.lineWidth * 4)
        for delta in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            let tip = CGPoint(x: p1.x + cos(angle + delta) * head,
                              y: p1.y + sin(angle + delta) * head)
            path.move(to: p1)
            path.line(to: tip)
        }
        apply(path, color: color, lineWidth: a.lineWidth)
    }

    private static func apply(_ path: NSBezierPath, color: NSColor, lineWidth: CGFloat) {
        path.lineWidth = max(1, lineWidth)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// 形状类标注的规范化矩形（左上原点）
    static func rect(of a: Annotation) -> CGRect? {
        guard a.points.count >= 2 else { return nil }
        let p0 = a.points.first!, p1 = a.points.last!
        return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                      width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    }

    /// 文字字号随线宽联动（细→小、粗→大），保证视觉一致
    private static func fontSize(for lineWidth: CGFloat) -> CGFloat {
        max(12, min(lineWidth * 6, 72))
    }

    // MARK: 颜色工具（HEX ↔ NSColor，sRGB）

    public static func color(fromHex hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return .systemRed }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    public static func hex(of color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#FF3B30" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
