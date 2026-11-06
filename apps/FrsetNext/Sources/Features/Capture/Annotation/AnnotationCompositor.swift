import AppKit
import CoreGraphics
import CoreImage

// MARK: - 标注工具与数据模型

/// 标注工具类型（对应原作截图工具条的箭头 / 矩形 / 文字等）
///
/// v220（对齐 1Capture）：按「形状 / 标注 / 强调 / 遮盖 / 画笔」五组排列，
/// 新增 备注、计数点、聚光灯、放大镜、模糊 五个工具。
public enum AnnotationTool: String, CaseIterable, Identifiable {
    // 形状
    case rectangle, ellipse, arrow
    // 标注
    case text, remark, counter, highlighter
    // 强调
    case spotlight, magnifier
    // 遮盖
    case mosaic, blur, eraser, removal
    // 画笔
    case pen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rectangle:  return "矩形"
        case .ellipse:    return "椭圆"
        case .arrow:      return "箭头"
        case .text:       return "文字"
        case .remark:     return "备注"
        case .counter:    return "计数点"
        case .highlighter: return "荧光"
        case .spotlight:  return "聚光灯"
        case .magnifier:  return "放大镜"
        case .mosaic:     return "马赛克"
        case .blur:       return "模糊"
        case .eraser:     return "橡皮"
        case .removal:    return "抹除"
        case .pen:        return "画笔"
        }
    }

    /// 键盘快捷键（单键；与 Flameshot / SuperSnip 的直觉一致）
    public var shortcut: String {
        switch self {
        case .rectangle: return "R"
        case .ellipse:   return "O"
        case .arrow:     return "A"
        case .text:      return "T"
        case .remark:    return "N"
        case .counter:   return "1"
        case .highlighter: return "H"
        case .spotlight: return "S"
        case .magnifier: return "G"
        case .mosaic:    return "M"
        case .blur:      return "B"
        case .eraser:    return "E"
        case .removal:   return "D"
        case .pen:       return "P"
        }
    }

    public var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse:   return "circle"
        case .arrow:     return "arrow.up.right"
        case .text:      return "text.cursor"        // textformat 在 mac SDK 不存在，会回退显示「格式」
        case .remark:    return "text.bubble"
        case .counter:   return "1.circle"
        case .highlighter: return "highlighter"
        case .spotlight: return "circle.dashed"
        case .magnifier: return "magnifyingglass"
        case .mosaic:    return "squareshape.split.3x3"
        case .blur:      return "circle.dotted"
        case .eraser:    return "eraser"
        case .removal:   return "wand.and.rays.inverse"
        case .pen:       return "pencil"            // pencil.tip 部分 SDK 缺失
        }
    }

    /// 笔刷类工具（沿轨迹涂抹，用 brushWidth 而不是 lineWidth）
    public var isBrush: Bool {
        switch self {
        case .mosaic, .blur, .eraser, .removal: return true
        default: return false
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
    /// 文字字重（0 常规 / 1 中粗 / 2 加粗；仅 .text 用，字体配置弹层可改）
    public var weight: Int
    /// 文字换行宽度（图像像素；0 = 不换行）。
    /// 存「逻辑文本」+ 换行宽度，绘制时才软换行——调字号后文字会按新字宽**重新排**，
    /// 不会退化成一整条冲出画面（2026-10-20 用户实障：长文提交后截断/溢出）。
    public var wrapWidth: CGFloat
    /// v220：工具的自有参数（各工具含义不同，0 = 用默认值）
    /// - spotlight：压暗强度 0–1（默认 0.55）
    /// - magnifier：放大倍数（默认 2.0）
    /// - blur：高斯半径（默认 16）
    /// - counter：无
    public var aux: CGFloat

    public init(id: UUID = UUID(),
                tool: AnnotationTool,
                points: [CGPoint],
                text: String? = nil,
                colorHex: String = "#FF3B30",
                lineWidth: CGFloat = 3,
                blockSize: CGFloat = 10,
                weight: Int = 1,
                wrapWidth: CGFloat = 0,
                aux: CGFloat = 0) {
        self.id = id
        self.tool = tool
        self.points = points
        self.text = text
        self.colorHex = colorHex
        self.lineWidth = lineWidth
        self.blockSize = blockSize
        self.weight = weight
        self.wrapWidth = wrapWidth
        self.aux = aux
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
        // 模糊图层同理：CIGaussianBlur 整图一次，按半径缓存
        var blurCache: [Int: CGImage] = [:]
        let blurProvider: (CGFloat) -> CGImage? = { radius in
            let key = Int(radius)
            if let hit = blurCache[key] { return hit }
            guard let img = blurred(base, radius: radius) else { return nil }
            blurCache[key] = img
            return img
        }
        draw(annotations, in: CGRect(x: 0, y: 0, width: w, height: h),
             base: base, mosaicCache: provider, blurCache: blurProvider)
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    // MARK: 绘制

    /// 在当前 NSGraphicsContext 中绘制标注。`rect` 为可绘制区域（左上原点坐标），
    /// 用于把坐标裁剪掉落在画面外的部分。
    /// 把成图切圆角（透明角）。radius 单位是**像素**。
    /// v176：截图编辑器「圆角」用，复制/保存时生效。
    public static func roundedCorners(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        guard radius > 0, w > 0, h > 0 else { return image }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.clear(rect)
        let r = min(radius, CGFloat(min(w, h)) / 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    public static func draw(_ annotations: [Annotation], in rect: CGRect, base: CGImage? = nil,
                            mosaicCache: ((CGFloat) -> CGImage?)? = nil,
                            blurCache: ((CGFloat) -> CGImage?)? = nil) {
        guard let clip = NSGraphicsContext.current else { return }
        clip.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        // 聚光灯是「背景压暗层」，必须先画：否则后面画的备注/放大镜/模糊
        // 会被它一起压暗（实测备注框只剩一条暗红底、文字看不清）。
        for annotation in annotations where annotation.tool == .spotlight {
            draw(annotation, base: base, mosaicCache: mosaicCache, blurCache: blurCache)
        }
        for annotation in annotations where annotation.tool != .spotlight {
            draw(annotation, base: base, mosaicCache: mosaicCache, blurCache: blurCache)
        }
        clip.restoreGraphicsState()
    }

    private static func draw(_ a: Annotation, base: CGImage? = nil,
                             mosaicCache: ((CGFloat) -> CGImage?)? = nil,
                             blurCache: ((CGFloat) -> CGImage?)? = nil) {
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
        case .blur:
            // 模糊笔刷：同一套笔触遮罩，把「像素化图层」换成「高斯模糊图层」
            drawMosaicBrush(a, base: base, fallbackColor: color,
                            pixelated: blurCache?(blurRadius(a)))
        case .remark:
            drawRemark(a, color: color)
        case .counter:
            drawCounter(a, color: color)
        case .spotlight:
            drawSpotlight(a, base: base)
        case .magnifier:
            drawMagnifier(a, base: base)
        case .eraser:
            return   // 橡皮不产生图元（在画布上直接删标注）
        case .removal:
            return   // 抹除不产生图元（在画布上直接修底图像素，画布另有涂抹预览）
        case .text:
            guard let anchor = a.points.first, let text = a.text, !text.isEmpty else { return }
            let font = NSFont.systemFont(ofSize: fontSize(for: a.lineWidth), weight: fontWeight(a.weight))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            (displayText(text, wrapWidth: a.wrapWidth, font: font) as NSString)
                .draw(at: anchor, withAttributes: attrs)
        }
    }

    /// 马赛克笔刷：沿轨迹铺像素化底图，笔触 = 圆头圆角的**粗描边区域**。
    ///
    /// 关键：必须先把路径转成「描边轮廓」（`replacePathWithStrokedPath`）再裁剪。
    /// 直接 `addClip` 会把开放折线**隐式闭合**成多边形——描出来的是一块介于轨迹和直线之间的
    /// 色块（旧版实障：马赛克看起来像线条/三角形，而不是画笔），笔刷宽度也完全不生效。
    ///
    /// 参考实现：Snipaste（笔刷大小与单元格大小两个独立参数）、Flameshot（滚轮调笔触粗细）、
    /// js-screenshot（pixelate 图层 + round stroke 遮罩）。
    private static func drawMosaicBrush(_ a: Annotation,
                                        base: CGImage?,
                                        fallbackColor: NSColor,
                                        pixelated: CGImage?) {
        let width = max(4, a.lineWidth)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        guard let pixelated, let base, !a.points.isEmpty else {
            // 无底图（纯预览）时用半透明色带表示笔触范围
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if a.points.count == 1, let p = a.points.first {
                path.appendOval(in: CGRect(x: p.x - width / 2, y: p.y - width / 2,
                                           width: width, height: width))
                fallbackColor.withAlphaComponent(0.22).setFill()
                path.fill()
            } else if let first = a.points.first {
                path.move(to: first)
                for p in a.points.dropFirst() { path.line(to: p) }
                fallbackColor.withAlphaComponent(0.22).setStroke()
                path.stroke()
            }
            return
        }

        let size = CGSize(width: CGFloat(base.width), height: CGFloat(base.height))
        strokeMosaic(into: ctx, pixelated: pixelated, size: size,
                     points: a.points, width: width)
    }

    /// 把一段马赛克笔触直接画进当前上下文（左上原点、单位为图像像素的坐标系）。
    /// 不生成整图中间层：裁剪后只栅格化笔触覆盖的区域，拖拽时每帧都便宜。
    public static func strokeMosaic(into ctx: CGContext,
                                    pixelated: CGImage,
                                    size: CGSize,
                                    points: [CGPoint],
                                    width: CGFloat) {
        guard !points.isEmpty, size.width >= 1, size.height >= 1 else { return }
        let strokeWidth = max(2, width)

        ctx.saveGState()
        // ① 笔触几何：开放折线 → 描边轮廓 → 裁剪区
        let path = CGMutablePath()
        if points.count == 1 {
            // 单击落点：给一个极小线段，配合圆头端帽得到一个正圆
            let p = points[0]
            path.move(to: CGPoint(x: p.x - 0.01, y: p.y))
            path.addLine(to: CGPoint(x: p.x + 0.01, y: p.y))
        } else {
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
        }
        ctx.addPath(path)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()

        // ② 在「左上原点」坐标里画图需要再翻一次；否则马赛克内容会上下颠倒
        //    （旧版第二个实障：马赛克块里显示的是镜像位置的画面）
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(pixelated, in: CGRect(origin: .zero, size: size))

        ctx.restoreGState()
    }

    // MARK: v220 新工具（对齐 1Capture）

    /// 备注：起点圆点 + 折线 + 带底色的文本框
    private static func drawRemark(_ a: Annotation, color: NSColor) {
        guard a.points.count >= 2, let anchor = a.points.first, let box = a.points.last else { return }
        let dot = max(4, a.lineWidth * 0.8)
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: anchor.x - dot / 2, y: anchor.y - dot / 2,
                                    width: dot, height: dot)).fill()

        let font = NSFont.systemFont(ofSize: fontSize(for: a.lineWidth), weight: fontWeight(a.weight))
        let text = a.text ?? ""
        let pad: CGFloat = max(6, a.lineWidth * 1.2)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        let boxRect = CGRect(x: box.x, y: box.y,
                             width: max(40, measured.width + pad * 2),
                             height: max(font.pointSize, measured.height) + pad * 2)

        // 折线：从起点先竖后横接到文本框左缘中点
        let attach = CGPoint(x: boxRect.minX, y: boxRect.midY)
        let path = NSBezierPath()
        path.move(to: anchor)
        path.line(to: CGPoint(x: anchor.x, y: attach.y))
        path.line(to: attach)
        path.lineWidth = max(1, a.lineWidth * 0.35)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.withAlphaComponent(0.75).setStroke()
        path.stroke()

        // 文本框：白底 + 同色描边，压在深色截图上也能读
        let plate = NSBezierPath(roundedRect: boxRect, xRadius: pad * 0.6, yRadius: pad * 0.6)
        NSColor.white.withAlphaComponent(0.94).setFill()
        plate.fill()
        color.withAlphaComponent(0.55).setStroke()
        plate.lineWidth = max(1, a.lineWidth * 0.3)
        plate.stroke()

        (text as NSString).draw(at: CGPoint(x: boxRect.minX + pad, y: boxRect.minY + pad),
                                withAttributes: attrs)
    }

    /// 计数点：实心圆 + 白色序号
    private static func drawCounter(_ a: Annotation, color: NSColor) {
        guard let p = a.points.first else { return }
        let d = max(20, a.lineWidth * 1.6)
        let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        color.setFill()
        NSBezierPath(ovalIn: r).fill()
        // 白色描边：同色背景上也浮得起来
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = max(1, d * 0.06)
        ring.stroke()

        let text = a.text ?? "1"
        let font = NSFont.systemFont(ofSize: d * 0.52, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                                withAttributes: attrs)
    }

    /// 聚光灯：整图压暗，按目标区域 even-odd 挖洞
    private static func drawSpotlight(_ a: Annotation, base: CGImage?) {
        guard let base, let hole = rect(of: a) else { return }
        let full = CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height))
        let dim = a.aux > 0 ? min(0.92, max(0.1, a.aux)) : 0.55
        let radius = min(16, min(hole.width, hole.height) * 0.12)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 走 CGContext 的 evenOdd：NSBezierPath 的 windingRule 在 flipped 上下文里
        // 实测没生效（整屏压暗、洞不出现），CG 这条路是确定的。
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(full)
        path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
        ctx.fillPath(using: .evenOdd)
        // 洞的边缘给一圈发丝亮边，暗底上能看清范围
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(max(1, a.lineWidth * 0.25))
        ctx.addPath(CGPath(roundedRect: hole.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 放大镜：把源图局部放大画进圆框
    private static func drawMagnifier(_ a: Annotation, base: CGImage?) {
        guard let base, let r = rect(of: a) else { return }
        let side = min(r.width, r.height)
        guard side >= 12 else { return }
        let center = CGPoint(x: r.midX, y: r.midY)
        let zoom = a.aux > 1 ? a.aux : 2.0
        let srcSide = side / zoom
        // CGImage.cropping(to:) 的 rect 是**左上原点**（不是 CG 绘图那套左下原点）——
        // 按左下算会裁到图像底部，圆里就是空白（实测踩过一次）。
        let src = CGRect(x: center.x - srcSide / 2,
                         y: center.y - srcSide / 2,
                         width: srcSide, height: srcSide)
        guard let cropped = base.cropping(to: src) else { return }

        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - side / 2, y: center.y - side / 2,
                                                 width: side, height: side))
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            // flipped 上下文里画 CGImage 会上下颠倒，绕框中心再翻一次
            ctx.translateBy(x: 0, y: center.y * 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(x: center.x - side / 2, y: center.y - side / 2,
                                         width: side, height: side))
            ctx.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()

        circle.lineWidth = max(2, side * 0.035)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        circle.stroke()
        // 外侧再一圈深色：浅背景上不至于糊掉
        let outer = NSBezierPath(ovalIn: CGRect(x: center.x - side / 2 - 1, y: center.y - side / 2 - 1,
                                                width: side + 2, height: side + 2))
        outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.25).setStroke()
        outer.stroke()
    }

    /// 模糊笔刷的半径：blockSize 在这里当「强度」用
    static func blurRadius(_ a: Annotation) -> CGFloat {
        a.aux > 0 ? max(2, a.aux) : max(6, a.blockSize * 1.2)
    }

    /// 模糊整图：**降采样 + 高质量插值放大**，纯 CoreGraphics。
    ///
    /// 不用 CIGaussianBlur：这台机器上 `CIContext.createCGImage` 对 2× 大图返回的是纯白，
    /// 笔触遮罩裁出来就是一块白（实测两次）。降采样放大在视觉上就是模糊，
    /// 且没有色彩空间/预乘的坑，2000×1400 图只要几毫秒。
    public static func blurred(_ base: CGImage, radius: CGFloat) -> CGImage? {
        let w = base.width, h = base.height
        guard radius >= 1, w > 4, h > 4 else { return base }
        // 半径 → 缩小因子：radius 12 ≈ 3×，radius 60 ≈ 15×
        let factor = max(2.0, radius / 4.0)
        let sw = max(2, Int(CGFloat(w) / factor))
        let sh = max(2, Int(CGFloat(h) / factor))

        guard let small = CGContext(data: nil, width: sw, height: sh,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        small.interpolationQuality = .high
        small.draw(base, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let down = small.makeImage() else { return nil }

        guard let big = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        big.interpolationQuality = .high
        big.draw(down, in: CGRect(x: 0, y: 0, width: w, height: h))
        return big.makeImage()
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
    static func fontSize(for lineWidth: CGFloat) -> CGFloat {
        max(12, min(lineWidth * 6, 72))
    }

    /// 字重映射（0 常规 / 1 中粗 / 2 加粗）
    static func fontWeight(_ value: Int) -> NSFont.Weight {
        switch value {
        case 0: return .regular
        case 2: return .bold
        default: return .semibold
        }
    }

    /// 文字标注的包围盒（图像像素、左上原点）。
    /// 与 `draw` 里 `(text as NSString).draw(at:)` 的落笔点一致：锚点即文本框左上角，
    /// 向下延伸排版高度（多行文本按行高累计）。选中框、拖动命中、字号联动都用它。
    static func textBounds(_ a: Annotation) -> CGRect? {
        guard a.tool == .text, let anchor = a.points.first,
              let text = a.text, !text.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: fontSize(for: a.lineWidth), weight: fontWeight(a.weight))
        // 与 draw 同一口径：先按 wrapWidth 软换行，再按段落排版算高度
        let rect = (displayText(text, wrapWidth: a.wrapWidth, font: font) as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return CGRect(x: anchor.x, y: anchor.y,
                      width: max(4, rect.width), height: max(font.pointSize, rect.height))
    }

    /// 实际绘制/测量用的文本：按 `wrapWidth`（图像像素）软换行。
    /// 0 或过窄 = 不换行。手动换行（\n）保留为段落边界，段内再按宽度折行。
    static func displayText(_ text: String, wrapWidth: CGFloat, font: NSFont) -> String {
        guard wrapWidth > 8 else { return text }
        return wrapText(text, font: font, maxWidth: wrapWidth)
    }

    /// 按最大宽度硬换行（逐字符，CJK 友好），与内联输入框的 `.byCharWrapping` 同算法，
    /// 保证「输入时看到的换行」与「提交后画布上的换行」一致。
    static func wrapText(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 8 else { return text }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var current = ""
            for ch in paragraph {
                let candidate = current + String(ch)
                let width = (candidate as NSString).size(withAttributes: [.font: font]).width
                if width > maxWidth, !current.isEmpty {
                    lines.append(current)
                    current = String(ch)
                } else {
                    current = candidate
                }
            }
            lines.append(current)
        }
        return lines.joined(separator: "\n")
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
