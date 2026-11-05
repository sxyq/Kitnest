import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

// MARK: - 标注画布

/// 标注画布：显示底图 + 已画标注 + 正在拖拽的草稿。
/// 视图为 flipped（左上原点），并把「图像像素坐标」通过 CTM 映射到视图坐标，
/// 因此标注坐标在整个编辑器里始终是同一套，落盘时交给 AnnotationCompositor。
final class AnnotationCanvasView: NSView {
    /// 底图（抹除工具会原地替换为修复结果）
    var image: CGImage
    /// 已确认的标注
    private(set) var annotations: [Annotation] = []
    /// 当前工具与样式
    var tool: AnnotationTool = .rectangle {
        didSet {
            // 换工具即取消文字选中（选中框只属于文字工具）
            if tool != .text, selectedTextID != nil { selectText(nil) }
            updateCursor(nil)
            needsDisplay = true
        }
    }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3 { didSet { needsDisplay = true } }
    /// 马赛克笔刷直径（图像像素）与块大小（像素）
    var brushWidth: CGFloat = 120 { didSet { needsDisplay = true } }
    var mosaicBlock: CGFloat = 16
    /// 文字字号（与线宽同刻度：fontSize = value * 6）
    var textSize: CGFloat = 1
    /// 标注变化回调（用于刷新撤销按钮可用态）
    var onChange: (() -> Void)?
    /// 键盘事件回调（工具条快捷键 / ⌘Z 等；返回 true 表示已处理）
    var onKey: ((NSEvent) -> Bool)?
    /// 滚轮调粗细（Snipaste / Flameshot 惯例）：+1 / -1 档
    var onSizeDelta: ((CGFloat) -> Void)?

    /// 撤销栈：标注追加 / 标注改写（移动·改字号·改色）/ 抹除前的底图快照
    private enum EditOp {
        case annotation(Annotation)
        /// 同一条标注的属性改写（文字移动/改字号/改色）
        case modify(old: Annotation, new: Annotation)
        /// 底图替换（抹除）：同时记录新旧图，撤销/重做都能还原
        case imageSnapshot(old: CGImage, new: CGImage)
    }
    private var ops: [EditOp] = []
    /// 重做栈（v100：撤销后可重做；产生新编辑时清空）
    private var redoOps: [EditOp] = []
    /// 笔刷光标位置（图像坐标）与悬停跟踪
    private var cursorPoint: CGPoint?
    private var trackingAreaRef: NSTrackingArea?
    /// 马赛克像素化缓存（按块大小；底图变化时失效）
    private var mosaicPixelCache: [Int: CGImage] = [:]
    /// 高斯模糊缓存（按半径；底图变化时失效）
    private var blurImageCache: [Int: CGImage] = [:]
    private var mosaicCacheBase: CGImage?
    /// 抹除工具：正在涂抹的轨迹（图像像素坐标、左上原点）
    private var removalStroke: [CGPoint]?
    /// 橡皮正在滑动擦除（v71：拖拽路径连续删除命中标注，与画笔滑动一致）
    private var isErasing = false
    private var draft: Annotation?
    private var dragStart: CGPoint?
    /// 备注工具：已点下的起点（等第二次点击放文本框）
    private var remarkAnchor: CGPoint?
    /// 备注工具：正在输入的这条备注的起点
    private var remarkStart: CGPoint?
    /// 计数点序号（只增不减——撤销后新落的点不会复用旧号码）
    private var counterSeq = 0

    init(image: CGImage) {
        // CGImageSourceCreateImageAtIndex 产出的图像是**惰性解码**的：每次 draw 都可能重新解码。
        // 编辑器每帧都要画底图（光标环/笔触都触发重绘），惰性解码会让「移动橡皮擦」直接卡死。
        // 进编辑器时一次性解成设备 RGB 位图，后续每帧只做贴图。
        self.image = Self.decoded(image)
        super.init(frame: .zero)
        wantsLayer = true
    }

    /// 一次性解码到内存位图（RGBA8，sRGB），返回可高速重复绘制的 CGImage
    private static func decoded(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// v130（SnowShot 对齐）②：恢复未完成标注（历史窗「继续标注」载入的快照）
    func restore(annotations: [Annotation]) {
        guard !annotations.isEmpty else { return }
        self.annotations.append(contentsOf: annotations)
        onChange?()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 坐标换算

    /// 底图在视图内的等比居中矩形
    /// v181：左侧给竖排工具栏让出的宽度（图像区域从这里开始）。
    /// 竖栏是「浮在画布上」的，如果图像铺满整幅，左缘 44pt 会被竖栏压住没法标注；
    /// 让出这一条后工具永远不盖内容，代价是图像略缩、左边多一条灰底。
    var leadingInset: CGFloat = 0 {
        didSet { if leadingInset != oldValue { needsDisplay = true } }
    }

    private var fitRect: CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let availW = max(1, bounds.width - leadingInset)
        let scale = min(availW / iw, bounds.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: leadingInset + (availW - w) / 2, y: (bounds.height - h) / 2,
                      width: w, height: h)
    }

    /// 成图圆角（视图坐标点）。0 = 直角。
    /// v176（用户：「截图的边角圆角是可以调的，在编辑栏里」）：编辑区实时按它裁切，
    /// 复制/保存的成图也按它切（像素半径 = cornerRadius / imageScale）。
    var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }

    private var imageScale: CGFloat {
        let iw = CGFloat(image.width)
        return iw > 0 ? fitRect.width / iw : 1
    }

    private func imagePoint(_ viewPoint: NSPoint) -> CGPoint {
        let f = fitRect, s = imageScale
        guard s > 0 else { return .zero }
        return CGPoint(x: (viewPoint.x - f.minX) / s, y: (viewPoint.y - f.minY) / s)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let frameStart = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - frameStart) * 1000
            if ms > 40 {
                Log.warn("Capture", "标注画布重绘 \(Int(ms))ms（dirty \(Int(dirtyRect.width))×\(Int(dirtyRect.height))）")
            }
        }
        EditorBackdrop.color.setFill()
        bounds.fill()

        let f = fitRect
        guard f.width > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let radius = max(0, cornerRadius)

        // 图片投影：让截图从画布上「浮」起来（工具条改为悬浮胶囊后需要这层空间关系）
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 16,
                      color: CGColor(gray: 0, alpha: 0.30))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: f, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(f)
        }
        ctx.restoreGState()

        // 底图：临时还原成 CG 常规坐标系，避免在 flipped 视图里上下颠倒
        ctx.saveGState()
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: f, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
            ctx.clip()
        }
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: f.minX, y: bounds.height - f.maxY, width: f.width, height: f.height))
        ctx.restoreGState()

        // 1px 描边：浅色底上给图片一个确定的边界（圆角时沿圆角走）
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.10))
        ctx.setLineWidth(1)
        let borderRect = f.insetBy(dx: 0.5, dy: 0.5)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: borderRect, cornerWidth: radius, cornerHeight: radius,
                               transform: nil))
            ctx.strokePath()
        } else {
            ctx.stroke(borderRect)
        }
        ctx.restoreGState()

        // 标注：图像像素坐标 → 视图坐标
        ctx.saveGState()
        ctx.translateBy(x: f.minX, y: f.minY)
        let scale = imageScale   // v126（性能审计 F0279）：计算属性外提，draw 内多处引用
        ctx.scaleBy(x: scale, y: scale)
        let canvasRect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        if mosaicCacheBase !== image {
            mosaicPixelCache.removeAll()
            blurImageCache.removeAll()
            mosaicCacheBase = image
        }
        let mosaicProvider: (CGFloat) -> CGImage? = { [weak self] block in
            guard let self else { return nil }
            let key = Int(block)
            if let cached = self.mosaicPixelCache[key] { return cached }
            guard let p = AnnotationCompositor.pixelated(self.image, block: block) else { return nil }
            self.mosaicPixelCache[key] = p
            return p
        }
        let blurProvider: (CGFloat) -> CGImage? = { [weak self] radius in
            guard let self else { return nil }
            let key = Int(radius)
            if let cached = self.blurImageCache[key] { return cached }
            guard let b = AnnotationCompositor.blurred(self.image, radius: radius) else { return nil }
            self.blurImageCache[key] = b
            return b
        }
        AnnotationCompositor.draw(annotations, in: canvasRect, base: image,
                                  mosaicCache: mosaicProvider, blurCache: blurProvider)
        if let draft = draft {
            AnnotationCompositor.draw([draft], in: canvasRect, base: image,
                                      mosaicCache: mosaicProvider, blurCache: blurProvider)
        }

        // 备注工具：起点已点下、还没放文本框时，画一个准星提示「再点空白处」
        if let anchor = remarkAnchor {
            let r = max(5, 8 / max(scale, 0.01))
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            ctx.setLineWidth(3 / max(scale, 0.01))
            ctx.strokeEllipse(in: CGRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(Theme.accentNS.cgColor)
            ctx.setLineWidth(1.5 / max(scale, 0.01))
            ctx.strokeEllipse(in: CGRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2))
        }
        // 笔刷光标环：白描边 + 深色内描边，任何底色上都看得清
        if let p = cursorPoint, let radius = brushRingRadius {
            ctx.saveGState()
            let base = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            ctx.setLineWidth(3 / max(scale, 0.01))
            ctx.strokeEllipse(in: base)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(1.2 / max(scale, 0.01))
            ctx.strokeEllipse(in: base)
            ctx.restoreGState()
        }
        // 抹除涂抹预览（半透明蓝，线宽 = 实际笔刷直径）
        if let stroke = removalStroke, stroke.count >= 1 {
            ctx.saveGState()
            let br = brushRadius   // v126（性能审计 F0279）：计算属性外提
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.35))
            ctx.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.45))
            ctx.setLineWidth(br * 2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if stroke.count == 1 {
                let p = stroke[0]
                ctx.fillEllipse(in: CGRect(x: p.x - br, y: p.y - br,
                                           width: br * 2, height: br * 2))
            } else {
                let path = CGMutablePath()
                path.move(to: stroke[0])
                for p in stroke.dropFirst() { path.addLine(to: p) }
                ctx.addPath(path)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // 选中文字的选择框：虚线胶囊 + 淡蓝底（提示「这段文字可以被拖动/改字号」），
        // 四角与边中点是控制点——拖动即按比例改字号
        if let a = selectedText, let r = AnnotationCompositor.textBounds(a) {
            let s = scale   // v126（性能审计 F0279）：复用已外提的 imageScale
            let vr = CGRect(x: f.minX + r.minX * s - 6,
                            y: f.minY + r.minY * s - 5,
                            width: r.width * s + 12,
                            height: r.height * s + 10)
            let path = NSBezierPath.continuousRoundedRect(vr, radius: 4)
            Theme.accentNS.withAlphaComponent(0.10).setFill()
            path.fill()
            Theme.accentNS.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 1.2
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()

            // 控制点：实心方块 + 白描边（角）；边中点稍扁
            for (handle, rect) in handleRects(for: vr) {
                // v156：控制点也走 G2（原来 x/y 半径 2 / 2.5 的圆弧；5pt 见方，
                // 这点椭圆差异肉眼不可见，统一成 2.5 后与其它圆角同一条曲线）
                let dot = NSBezierPath.continuousRoundedRect(rect, radius: 2.5)
                Theme.accentNS.setFill()
                dot.fill()
                NSColor.white.withAlphaComponent(0.95).setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
        }
    }

    // MARK: 命中测试（橡皮擦用）

    /// 判断某个标注是否被点中：形状类看包围盒，画笔/荧光看轨迹邻近点，
    /// 文字看锚点附近。容差按线宽放大，小图元也点得到。
    private func hitTest(_ a: Annotation, at point: CGPoint) -> Bool {
        let tolerance = max(6, a.lineWidth * 2)
        switch a.tool {
        case .rectangle, .ellipse:
            guard let r = AnnotationCompositor.rect(of: a) else { return false }
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .mosaic, .blur:
            // 笔刷型：命中 = 落在笔触覆盖范围内（半径 = 笔刷直径/2 + 容差）
            return distanceToPolyline(point, a.points) <= max(4, a.lineWidth / 2) + 4
        case .arrow:
            return a.points.contains { hypot($0.x - point.x, $0.y - point.y) <= tolerance }
        case .pen, .highlighter:
            return a.points.contains { hypot($0.x - point.x, $0.y - point.y) <= tolerance * 1.5 }
        case .text:
            guard let r = AnnotationCompositor.textBounds(a) else { return false }
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .counter:
            guard let p = a.points.first else { return false }
            return hypot(p.x - point.x, p.y - point.y) <= max(8, a.lineWidth) + 2
        case .remark:
            // 起点圆 + 文本框落点都算命中
            return a.points.contains { hypot($0.x - point.x, $0.y - point.y) <= tolerance * 2 }
        case .spotlight, .magnifier:
            guard let r = AnnotationCompositor.rect(of: a) else { return false }
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .eraser, .removal:
            return false
        }
    }

    /// 点到折线的最短距离（马赛克笔触命中测试用）
    private func distanceToPolyline(_ p: CGPoint, _ points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .greatestFiniteMagnitude }
        guard points.count > 1 else { return hypot(first.x - p.x, first.y - p.y) }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 <= 0.0001 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            best = min(best, hypot(proj.x - p.x, proj.y - p.y))
        }
        return best
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        // 正在输入文字时，先提交未完成的文本（与原版「点别处即落字」一致）
        if textEditor != nil { finishTextEditing(commit: true) }

        let ip = imagePoint(convert(event.locationInWindow, from: nil))
        updateCursor(ip)

        // 换到别的工具时，未完成的备注起点作废
        if tool != .remark { remarkAnchor = nil }

        if tool == .counter {
            // 计数点：点一下落一个序号，连续点连续加（v220）
            counterSeq = max(counterSeq + 1,
                             annotations.filter { $0.tool == .counter }.count + 1)
            let a = Annotation(tool: .counter, points: [ip],
                               text: "\(counterSeq)",
                               colorHex: AnnotationCompositor.hex(of: color),
                               lineWidth: strokeWidth(for: .counter))
            annotations.append(a)
            record(.annotation(a))
            onChange?()
            needsDisplay = true
            return
        }

        if tool == .remark {
            // 备注：第一次点目标定起点，第二次点空白处放文本框（v220）
            if let start = remarkAnchor {
                remarkAnchor = nil
                remarkStart = start
                beginTextEditing(at: convert(event.locationInWindow, from: nil))
            } else {
                remarkAnchor = ip
                needsDisplay = true
            }
            return
        }

        if tool == .eraser {
            // 橡皮擦的是「标注」而不是像素：v71 支持滑动——按下即擦，拖拽路径连续擦
            isErasing = true
            eraseAt(ip)
            return
        }

        if tool == .text {
            let viewPoint = convert(event.locationInWindow, from: nil)
            // ① 先测控制点（画在文字框外沿，必须早于文字命中——否则点控制点会被当成"点空白"取消选中）
            if selectedTextID != nil, let handle = handleHit(at: viewPoint), let hit = selectedText {
                activeHandle = handle
                handleDragStart = viewPoint
                handleStartScale = hit.lineWidth
                handleStartCenter = textSelectionViewRect().map { CGPoint(x: $0.midX, y: $0.midY) }
                textDragOld = hit
                return
            }
            // ② 点文字（含选中框内边距）→ 选中 + 弹字体配置；按住拖 = 移动
            if let hit = textAnnotation(at: ip) {
                if selectedTextID != hit.id {
                    selectText(hit)
                    if let rect = textSelectionViewRect() {
                        showFontPopover(for: hit, at: rect)
                    }
                } else if let rect = textSelectionViewRect(), fontPopover?.isShown != true {
                    // 已选中再点一次：弹层被关掉后重新打开（拖动/缩放时弹层保持打开）
                    showFontPopover(for: hit, at: rect)
                }
                textDragOld = hit
                textDragAnchor = hit.points.first
                textDragMoved = false
                dragStart = ip
                return
            }
            closeFontPopover()
            if selectedTextID != nil { selectText(nil) }
            beginTextEditing(at: viewPoint)
            return
        }

        if tool == .removal {
            removalStroke = [ip]
            needsDisplay = true
            return
        }

        dragStart = ip
    }

    override func mouseDragged(with event: NSEvent) {
        updateCursor(imagePoint(convert(event.locationInWindow, from: nil)))
        if tool == .eraser, isErasing {
            // 滑动擦除：拖拽路径上每个命中的标注都删（同画笔滑动体验）
            eraseAt(imagePoint(convert(event.locationInWindow, from: nil)))
            return
        }
        if tool == .removal {
            let ip = imagePoint(convert(event.locationInWindow, from: nil))
            removalStroke?.append(ip)
            needsDisplay = true
            return
        }
        // 文字：拖控制点 = 按比例改字号（框随字号涨缩）
        if tool == .text, activeHandle != nil, let start = handleDragStart {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let center = handleStartCenter ?? viewPoint
            let d0 = max(6, hypot(start.x - center.x, start.y - center.y))
            let d1 = hypot(viewPoint.x - center.x, viewPoint.y - center.y)
            let target = min(12, max(1, (handleStartScale * d1 / d0)))
            if abs(target - (selectedText?.lineWidth ?? 0)) > 0.05 {
                applyTextSizeToSelection(target)
            }
            return
        }
        // 文字：拖动选中的文本框（松手才进撤销栈）
        if tool == .text, let old = textDragOld, let origin = textDragAnchor, let start = dragStart {
            let ip = imagePoint(convert(event.locationInWindow, from: nil))
            let dx = ip.x - start.x, dy = ip.y - start.y
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
            textDragMoved = true
            if let index = annotations.firstIndex(where: { $0.id == old.id }) {
                annotations[index].points = [CGPoint(x: origin.x + dx, y: origin.y + dy)]
                needsDisplay = true
            }
            return
        }
        guard let start = dragStart else { return }
        let ip = imagePoint(convert(event.locationInWindow, from: nil))
        if tool == .pen || tool == .highlighter || tool.isBrush {
            if draft == nil {
                draft = Annotation(tool: tool, points: [start],
                                   colorHex: AnnotationCompositor.hex(of: color),
                                   lineWidth: strokeWidth(for: tool),
                                   blockSize: mosaicBlock)
            }
            // 采样抽稀：事件频率高时避免几万个点把路径撑爆（1.2px 以内不记）
            if let last = draft?.points.last,
               hypot(ip.x - last.x, ip.y - last.y) < 1.2 {
                return
            }
            draft?.points.append(ip)
        } else {
            draft = Annotation(tool: tool, points: [start, ip],
                               colorHex: AnnotationCompositor.hex(of: color),
                               lineWidth: strokeWidth(for: tool))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        updateCursor(imagePoint(convert(event.locationInWindow, from: nil)))
        if tool == .eraser {
            isErasing = false
            return
        }
        if tool == .removal {
            defer { removalStroke = nil; needsDisplay = true }
            guard var stroke = removalStroke, !stroke.isEmpty else { return }
            let ip = imagePoint(convert(event.locationInWindow, from: nil))
            stroke.append(ip)
            applyRemoval(stroke: stroke)
            return
        }
        // 文字：拖动/缩放结束
        if tool == .text {
            defer {
                textDragOld = nil; textDragAnchor = nil; textDragMoved = false; dragStart = nil
                activeHandle = nil; handleDragStart = nil; handleStartCenter = nil
            }
            // 控制点缩放：每档都已进撤销栈（连续操作会合并），这里只同步工具条
            if activeHandle != nil {
                onTextSelectionChange?(selectedText)
                return
            }
            guard textDragMoved, let old = textDragOld,
                  let updated = annotations.first(where: { $0.id == old.id }) else { return }
            record(.modify(old: old, new: updated))
            onTextSelectionChange?(updated)
            return
        }
        defer { dragStart = nil; draft = nil; needsDisplay = true }
        guard let start = dragStart else { return }
        let ip = imagePoint(convert(event.locationInWindow, from: nil))
        let finished: Annotation?
        if tool == .pen || tool == .highlighter || tool.isBrush {
            var a = draft ?? Annotation(tool: tool, points: [start],
                                        colorHex: AnnotationCompositor.hex(of: color),
                                        lineWidth: strokeWidth(for: tool),
                                        blockSize: mosaicBlock)
            a.points.append(ip)
            finished = a
        } else {
            finished = Annotation(tool: tool, points: [start, ip],
                                  colorHex: AnnotationCompositor.hex(of: color),
                                  lineWidth: strokeWidth(for: tool))
        }
        if let a = finished, isValid(a) {
            annotations.append(a)
            record(.annotation(a))
            onChange?()
            if a.tool == .mosaic {
                Log.info("Capture", "马赛克笔触：\(a.points.count) 点，直径 \(Int(a.lineWidth))px，块 \(Int(a.blockSize))px")
            }
        }
    }

    // MARK: 物体抹除（eSearch removeObj 对齐）

    /// 抹除笔刷半径（细/中/粗 → 16/32/64 直径）
    var brushRadius: CGFloat { max(8, brushWidth) / 2 }

    /// 各工具落笔宽度：马赛克用独立笔刷直径，其余用线宽
    private func strokeWidth(for tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .mosaic, .blur: return max(8, brushWidth)
        case .highlighter: return max(2, lineWidth)
        // 聚光灯只用它算边缘描边，放大镜只用它算外圈，都该比线条细
        case .spotlight: return max(2, lineWidth * 0.3)
        case .magnifier: return max(2, lineWidth * 0.6)
        // 计数点直径 = lineWidth * 1.6（见 drawCounter）
        case .counter: return max(12, lineWidth)
        default: return max(1, lineWidth)
        }
    }

    /// 笔刷光标环半径（图像像素；非笔刷工具返回 nil，不显示环）
    private var brushRingRadius: CGFloat? {
        switch tool {
        case .mosaic, .blur: return max(8, brushWidth) / 2
        case .pen: return max(1, lineWidth) / 2
        case .highlighter: return max(2, lineWidth) * 2
        case .eraser, .removal: return brushRadius
        default: return nil
        }
    }

    // MARK: 光标跟踪 / 键盘

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingAreaRef { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        // 文字工具：控制点 → 十字（拖=改字号）；文字上 → 抓手；空白 → 文本光标
        if tool == .text {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if selectedTextID != nil, handleHit(at: viewPoint) != nil {
                NSCursor.crosshair.set()
                return
            }
            let overText = textAnnotation(at: imagePoint(viewPoint)) != nil
            (overText ? NSCursor.openHand : NSCursor.iBeam).set()
            return
        }
        guard brushRingRadius != nil else { return }
        updateCursor(imagePoint(convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        if tool == .text {
            NSCursor.iBeam.set()
            return
        }
        if brushRingRadius != nil {
            updateCursor(imagePoint(convert(event.locationInWindow, from: nil)))
            NSCursor.crosshair.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        updateCursor(nil)
        NSCursor.arrow.set()
    }

    /// 移动笔刷光标：只把「旧环 ∪ 新环」标脏。
    /// 之前每次 mouseMoved 都是整张画布重绘（底图 + 全部标注），
    /// 2K/4K 截图上移动橡皮擦会掉到个位数帧率。
    private func updateCursor(_ point: CGPoint?) {
        let oldRect = cursorRingRect(for: cursorPoint)
        cursorPoint = point
        let newRect = cursorRingRect(for: point)
        switch (oldRect, newRect) {
        case let (old?, new?):
            setNeedsDisplay(old.union(new))
        default:
            // 至少一侧没有环：整块重绘一次（进入/离开笔刷状态，代价可接受）
            needsDisplay = true
        }
    }

    /// 笔刷环在视图坐标下的占位（含 2pt 描边与阴影余量）
    private func cursorRingRect(for imagePoint: CGPoint?) -> CGRect? {
        guard let imagePoint, let radius = brushRingRadius else { return nil }
        let scale = imageScale
        let center = CGPoint(x: fitRect.minX + imagePoint.x * scale,
                             y: fitRect.minY + imagePoint.y * scale)
        let r = radius * scale + 4
        return CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
    }

    override func keyDown(with event: NSEvent) {
        // 选中文字时：Delete/⌫ 删除、Esc 取消选中（都不再走工具快捷键）
        if selectedTextID != nil {
            if event.keyCode == 51 || event.keyCode == 117 {
                deleteSelectedText()
                return
            }
            if event.keyCode == 53 {
                selectText(nil)
                return
            }
        }
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// 橡皮：删除命中点处的一个标注（从后往前找第一个命中）。
    /// v71：进撤销栈（此前橡皮删除不可撤销）；滑动时每个命中图元各占一条撤销记录。
    private func eraseAt(_ ip: CGPoint) {
        guard let index = annotations.lastIndex(where: { hitTest($0, at: ip) }) else { return }
        let victim = annotations.remove(at: index)
        record(.annotation(victim))
        needsDisplay = true
        onChange?()
    }

    /// 对涂抹轨迹执行修复：轨迹 → 灰度 mask → ObjectRemovalEngine → 替换底图
    private func applyRemoval(stroke: [CGPoint]) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, stroke.count >= 1 else { return }

        // mask：灰度位图，白色圆头线连轨迹（坐标是顶部原点系 → CG 画时翻转 y）
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: w * h, alignment: 64)
        guard let mctx = CGContext(data: ptr, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)) else {
            ptr.deallocate()
            return
        }
        defer { ptr.deallocate() }
        memset(ptr, 0, w * h)
        mctx.setFillColor(gray: 1, alpha: 1)
        mctx.setStrokeColor(gray: 1, alpha: 1)
        let r = brushRadius
        if stroke.count == 1 {
            let p = stroke[0]
            mctx.fillEllipse(in: CGRect(x: p.x - r, y: CGFloat(h) - p.y - r, width: r * 2, height: r * 2))
        } else {
            let path = CGMutablePath()
            let first = CGPoint(x: stroke[0].x, y: CGFloat(h) - stroke[0].y)
            path.move(to: first)
            for p in stroke.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: CGFloat(h) - p.y)) }
            mctx.addPath(path)
            mctx.setLineWidth(r * 2)
            mctx.setLineCap(.round)
            mctx.setLineJoin(.round)
            mctx.strokePath()
        }
        guard let mask = mctx.makeImage() else { return }

        // v182（用户：「最底部那个工具选中后没有正确使用」）：
        // 修复是秒级 CPU 活，原实现同步跑在主线程且失败只写日志——
        // 表现就是「涂了没反应」。现在后台算 + 全程给反馈。
        let base = image
        Toast.show("正在抹除…", icon: "wand.and.rays.inverse")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cleaned = ObjectRemovalEngine.inpaint(image: base, mask: mask)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let cleaned else {
                    Log.warn("Capture", "抹除：修复引擎返回空")
                    Toast.show("抹除失败：修复引擎返回空", icon: "exclamationmark.triangle")
                    return
                }
                let old = self.image
                self.image = cleaned
                self.mosaicPixelCache.removeAll(); self.mosaicCacheBase = nil
                self.record(.imageSnapshot(old: old, new: cleaned))
                self.onChange?()
                self.needsDisplay = true
                Toast.show("已抹除", icon: "wand.and.rays.inverse")
                Log.info("Capture", "抹除：修复完成（轨迹 \(stroke.count) 点，笔刷直径 \(Int(r * 2))px）")
            }
        }
    }

    /// 过滤误点产生的过小标注
    private func isValid(_ a: Annotation) -> Bool {
        switch a.tool {
        case .rectangle, .ellipse:
            guard a.points.count >= 2 else { return false }
            return abs(a.points[0].x - a.points[1].x) >= 2 || abs(a.points[0].y - a.points[1].y) >= 2
        case .arrow:
            guard a.points.count >= 2 else { return false }
            let dx = a.points[0].x - a.points[1].x, dy = a.points[0].y - a.points[1].y
            return (dx * dx + dy * dy).squareRoot() >= 6
        case .pen, .highlighter:
            return a.points.count >= 2
        case .mosaic, .blur:
            // 画笔式：单击落一个点、拖动成笔触都算有效
            return !a.points.isEmpty
        case .spotlight, .magnifier:
            guard a.points.count >= 2 else { return false }
            let w = abs(a.points[0].x - a.points[1].x)
            let h = abs(a.points[0].y - a.points[1].y)
            return min(w, h) >= 12
        case .counter, .remark:
            return true
        case .eraser, .removal:
            return false
        case .text:
            return true
        }
    }

    // MARK: 文字：内联输入（虚线框随字宽）+ 选中（拖边框改字号 / 点开字体配置）

    /// 正在编辑的文字框（虚线框，宽度随输入内容增长）与它的锚点（图像像素坐标）
    private var textEditor: NSTextField?
    private var textEditorBox: NSView?
    private var textEditorBorder: CAShapeLayer?
    private var textAnchor: CGPoint?
    /// 画布上选中的文字标注（点一下选中并弹字体配置；可拖动、可拖边框改字号、可删）
    private(set) var selectedTextID: UUID?
    /// 选中态变化回调（窗口同步工具条的字号/颜色）
    var onTextSelectionChange: ((Annotation?) -> Void)?
    /// 拖动文字时的原始值（松手才进撤销栈）
    private var textDragOld: Annotation?
    private var textDragAnchor: CGPoint?
    private var textDragMoved = false
    /// 正在拖的控制点（非空 = 按比例改字号，而不是移动）
    private var activeHandle: TextHandle?
    private var handleDragStart: CGPoint?
    private var handleStartScale: CGFloat = 1
    /// 拖控制点时选中框的中心（缩放基准点，固定住避免反馈抖动）
    private var handleStartCenter: CGPoint?
    /// 字体配置弹层（点中文字后弹出）
    private var fontPopover: NSPopover?
    private let fontModel = TextFontModel()

    /// 选中框的 8 个控制点（角 + 边中点）
    enum TextHandle: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        case left, right, top, bottom
    }

    /// 当前选中的文字标注
    private var selectedText: Annotation? {
        guard let id = selectedTextID else { return nil }
        return annotations.first { $0.id == id }
    }

    /// 命中最上层的文字标注（包围盒判定，容差 6px）
    private func textAnnotation(at ip: CGPoint) -> Annotation? {
        annotations.last { a in
            guard a.tool == .text, let r = AnnotationCompositor.textBounds(a) else { return false }
            return r.insetBy(dx: -6, dy: -6).contains(ip)
        }
    }

    /// 选中框在视图坐标下的矩形（与 draw() 的虚线框同口径）
    private func textSelectionViewRect() -> CGRect? {
        guard let a = selectedText, let r = AnnotationCompositor.textBounds(a) else { return nil }
        let s = imageScale, f = fitRect
        return CGRect(x: f.minX + r.minX * s - 6,
                      y: f.minY + r.minY * s - 5,
                      width: r.width * s + 12,
                      height: r.height * s + 10)
    }

    /// 控制点矩形（视图坐标；角 12×12，边中点 14×12——比视觉略大，方便抓）
    private func handleRects(for rect: CGRect) -> [(TextHandle, CGRect)] {
        let size: CGFloat = 12
        func square(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
        }
        func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
        }
        return [
            (.topLeft, square(rect.minX, rect.minY)),
            (.topRight, square(rect.maxX, rect.minY)),
            (.bottomLeft, square(rect.minX, rect.maxY)),
            (.bottomRight, square(rect.maxX, rect.maxY)),
            (.top, pill(rect.midX, rect.minY, 12, 10)),
            (.bottom, pill(rect.midX, rect.maxY, 12, 10)),
            (.left, pill(rect.minX, rect.midY, 10, 12)),
            (.right, pill(rect.maxX, rect.midY, 10, 12)),
        ]
    }

    /// 命中控制点（容差 4pt）
    private func handleHit(at viewPoint: CGPoint) -> TextHandle? {
        guard let rect = textSelectionViewRect() else { return nil }
        return handleRects(for: rect).first { $0.1.insetBy(dx: -4, dy: -4).contains(viewPoint) }?.0
    }

    /// 选中 / 取消选中文字
    func selectText(_ annotation: Annotation?) {
        if annotation == nil { closeFontPopover() }
        selectedTextID = annotation?.id
        onTextSelectionChange?(annotation)
        needsDisplay = true
    }

    /// 改选中文字的字号（工具条滑杆 / 滚轮 / [ ] / 拖控制点 都走这里）
    func applyTextSizeToSelection(_ value: CGFloat) {
        mutateSelectedText { $0.lineWidth = value }
    }

    /// 改选中文字的颜色
    func applyColorToSelection(_ hex: String) {
        mutateSelectedText { $0.colorHex = hex }
    }

    /// 改选中文字的字重（0 标准 / 1 中粗 / 2 加粗）
    func applyWeightToSelection(_ value: Int) {
        mutateSelectedText { $0.weight = value }
    }

    /// 删除选中文字（Delete / ⌫）
    func deleteSelectedText() {
        guard let id = selectedTextID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let victim = annotations.remove(at: index)
        record(.annotation(victim))
        closeFontPopover()
        selectText(nil)
        onChange?()
    }

    private func mutateSelectedText(_ body: (inout Annotation) -> Void) {
        guard let id = selectedTextID,
              let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let old = annotations[index]
        var updated = old
        body(&updated)
        guard updated != old else { return }
        annotations[index] = updated
        record(.modify(old: old, new: updated))
        onTextSelectionChange?(updated)
        // 弹层里的滑杆/字重/颜色跟着外部改动同步（拖控制点、工具条滑杆都会走到这里）
        if fontPopover?.isShown == true {
            fontModel.size = Double(updated.lineWidth)
            fontModel.weight = updated.weight
            fontModel.colorHex = updated.colorHex
        }
        needsDisplay = true
    }

    // MARK: 字体配置弹层

    /// 点中文字 → 选中 + 弹出字体配置（字号 / 字重 / 颜色 / 删除）
    private func showFontPopover(for annotation: Annotation, at rect: CGRect) {
        fontModel.size = Double(annotation.lineWidth)
        fontModel.weight = annotation.weight
        fontModel.colorHex = annotation.colorHex
        fontModel.onSize = { [weak self] value in self?.applyTextSizeToSelection(CGFloat(value)) }
        fontModel.onWeight = { [weak self] value in self?.applyWeightToSelection(value) }
        fontModel.onColor = { [weak self] hex in self?.applyColorToSelection(hex) }
        fontModel.onDelete = { [weak self] in
            self?.deleteSelectedText()
            self?.closeFontPopover()
        }
        fontModel.onClose = { [weak self] in self?.closeFontPopover() }

        let popover = fontPopover ?? makeFontPopover()
        fontPopover = popover
        if popover.isShown { popover.close() }
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    private func makeFontPopover() -> NSPopover {
        let popover = NSPopover()
        // .applicationDefined：弹层不自动吞点击。之前用 .transient 时，第二次点控制点
        // 的那次按下被弹层拿去「关闭自己」，根本不传到画布——表现为「拖边框没反应」。
        // 现在由本类显式关闭（换选中/Esc/点空白/换工具），拖动与缩放期间弹层保持打开。
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: TextFontPopoverView(model: fontModel))
        return popover
    }

    func closeFontPopover() {
        fontPopover?.close()
    }

    // MARK: 内联输入框（虚线框，宽度随文字增长）

    /// 圆角矩形 CGPath（NSBezierPath.cgPath 需 macOS 14，部署目标 13 —— 手工构造）
    private static func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        return path
    }

    private func beginTextEditing(at viewPoint: CGPoint) {
        closeFontPopover()
        let anchor = imagePoint(viewPoint)
        let fontPx = AnnotationCompositor.textFontSize(scale: textSize)
        let displayFont = max(13, fontPx * imageScale)
        let font = NSFont.systemFont(ofSize: displayFont,
                                     weight: AnnotationCompositor.fontWeight(1))

        // 起始宽度只按占位符算（≈3 个字）；之后随文字生长，到上限自动换行、框高随行长
        let placeholder = "输入文字"
        let seedWidth = ceil((placeholder as NSString).size(withAttributes: [.font: font]).width)
        let boxH = ceil(displayFont * 1.9)
        var boxW = min(520, max(110, seedWidth + 28))
        var origin = CGPoint(x: viewPoint.x - 8, y: viewPoint.y - boxH / 2)
        origin.x = min(max(6, origin.x), max(6, bounds.width - boxW - 6))
        origin.y = min(max(6, origin.y), max(6, bounds.height - boxH - 6))

        let box = NSView(frame: NSRect(x: origin.x, y: origin.y, width: boxW, height: boxH))
        box.wantsLayer = true
        // 虚线框：极淡底 + 强调色虚线描边（提示「这里是输入区」，不压住画面）
        let border = CAShapeLayer()
        border.lineWidth = 1.4
        border.lineDashPattern = [5, 4]
        border.fillColor = NSColor.textBackgroundColor.withAlphaComponent(0.88).cgColor
        border.strokeColor = Theme.accentNS.withAlphaComponent(0.95).cgColor
        border.path = Self.roundedRectPath(box.bounds, radius: 7)
        box.layer?.addSublayer(border)
        textEditorBorder = border

        let fieldH = ceil(displayFont * 1.35)
        let field = NSTextField(frame: NSRect(x: 12, y: (boxH - fieldH) / 2,
                                              width: boxW - 24, height: fieldH))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = color
        field.placeholderString = "输入文字，回车确认"
        // 多行 + 自动换行：长文换行继续显示，不再被 .byClipping 切掉
        //（回车仍 = 确认；⇧回车 才插入换行，见 doCommandBy）
        // 按字符断行（CJK 友好），提交时用同一算法硬换行，保证画布上与预览一致
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.lineBreakMode = .byCharWrapping
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldSubmitted)
        box.addSubview(field)
        addSubview(box)
        textEditorBox = box
        textEditor = field
        textAnchor = anchor
        window?.makeFirstResponder(field)
        Log.info("Capture", "标注：内联输入框（字号 \(Int(fontPx))px／屏显 \(Int(displayFont))pt，初始宽 \(Int(boxW)))")
    }

    /// 文字换行宽度（图像像素）：画布宽 82% 与「锚点右侧剩余宽」取小——
    /// 点在画面右半边时收窄换行，文字就不会冲出画面被窗口切掉。
    private func textWrapWidth(for anchor: CGPoint) -> CGFloat {
        let margin: CGFloat = 32
        return min(CGFloat(image.width) * 0.82,
                   max(240, CGFloat(image.width) - anchor.x - margin))
    }

    /// 输入内容变化 → 框随文字生长：
    ///   · 单行放得下：宽度 = 文字宽 + 内边距，向右生长；
    ///   · 放不下：宽度封顶（画布 ~80%），文字换行，框高随行数增长（上边不动，向下长）。
    private func updateEditorBoxSize() {
        guard let field = textEditor, let box = textEditorBox, let border = textEditorBorder else { return }
        let font = field.font ?? .systemFont(ofSize: 13)
        let shown = field.stringValue.isEmpty
            ? (field.placeholderString ?? "输入文字")
            : field.stringValue

        let padX: CGFloat = 28      // 左右各 12 + 光标余量
        let padY: CGFloat = 18      // 上下留白
        // 宽度上限 = 提交时的换行宽度（视图坐标），保证「输入框看到的换行」=「画布上的换行」
        let wrapPts = (textAnchor.map { textWrapWidth(for: $0) } ?? (fitRect.width * 0.82)) / max(imageScale, 0.01)
        let maxW = min(bounds.width - 12, max(180, wrapPts))

        // 单行宽度（不换行）
        let unwrapped = ceil((shown as NSString).size(withAttributes: [.font: font]).width)
        let singleLine = unwrapped + padX <= maxW
        let targetWidth = singleLine ? max(110, unwrapped + padX) : maxW

        // 高度：按 targetWidth 内的排版高度算（单行时就是一个行高）
        let textRect = (shown as NSString).boundingRect(
            with: CGSize(width: max(20, targetWidth - padX), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let targetHeight = max(34, ceil(textRect.height) + padY)

        guard abs(targetWidth - box.frame.width) > 0.5
            || abs(targetHeight - box.frame.height) > 0.5 else { return }

        var frame = box.frame
        // 宽度：左边缘不动；贴到右边缘时改为右不动，避免长文飞出画布
        if frame.maxX + (targetWidth - frame.width) > bounds.width - 6 {
            frame.origin.x = max(6, bounds.width - 6 - targetWidth)
        }
        // 高度：上边缘不动，向下生长；超出画布底部则整体上移
        if frame.maxY + (targetHeight - frame.height) > bounds.height - 6 {
            frame.origin.y = max(6, bounds.height - 6 - targetHeight)
        }
        frame.size.width = targetWidth
        frame.size.height = targetHeight
        box.frame = frame

        // 文字区：水平内边距 12，垂直居中
        let innerH = max(ceil(displayFontSize(of: font) * 1.35), ceil(textRect.height))
        field.frame = NSRect(x: 12, y: max(6, (targetHeight - innerH) / 2),
                             width: targetWidth - 24, height: innerH)
        border.path = Self.roundedRectPath(box.bounds, radius: 7)
    }

    private func displayFontSize(of font: NSFont) -> CGFloat { font.pointSize }

    @objc private func textFieldSubmitted() {
        finishTextEditing(commit: true)
    }

    /// 提交或取消内联文字。提交空串等价于取消。
    func finishTextEditing(commit: Bool) {
        guard let field = textEditor else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = textAnchor
        textEditor = nil
        textAnchor = nil
        textEditorBorder = nil
        textEditorBox?.removeFromSuperview()
        textEditorBox = nil
        window?.makeFirstResponder(self)
        guard commit, !raw.isEmpty, let anchor else { remarkStart = nil; needsDisplay = true; return }

        // 备注（v220）：起点 + 文本框两个点，走 .remark 标注而不是普通文字
        if let start = remarkStart {
            remarkStart = nil
            let remark = Annotation(tool: .remark, points: [start, anchor], text: raw,
                                    colorHex: AnnotationCompositor.hex(of: color),
                                    lineWidth: textSize,
                                    weight: 1)
            annotations.append(remark)
            record(.annotation(remark))
            needsDisplay = true
            onChange?()
            return
        }

        // 存「逻辑文本 + 换行宽度」（图像像素）：绘制时按此宽度软换行，调字号后自动重排
        let wrapWidthImage = textWrapWidth(for: anchor)
        let a = Annotation(tool: .text, points: [anchor], text: raw,
                           colorHex: AnnotationCompositor.hex(of: color),
                           lineWidth: textSize,
                           weight: 1,
                           wrapWidth: wrapWidthImage)
        annotations.append(a)
        record(.annotation(a))
        // 落字后自动选中 + 弹字体配置：与「点已有文字」同一套交互
        selectText(a)
        if let rect = textSelectionViewRect() {
            showFontPopover(for: a, at: rect)
        }
        needsDisplay = true
        onChange?()
    }

    // MARK: 操作（供工具条调用）

    var canUndo: Bool { !ops.isEmpty }
    var canRedo: Bool { !redoOps.isEmpty }

    /// 记录一次编辑：入撤销栈并清空重做栈。
    /// 连续改写同一条标注（拖字号滑杆 / 拖动文字）合并成一条，避免撤销栈被几十个中间态塞满。
    private func record(_ op: EditOp) {
        if case .modify(let old, let new) = op,
           case .modify(let prevOld, let prevNew)? = ops.last,
           prevNew.id == new.id {
            ops[ops.count - 1] = .modify(old: prevOld, new: new)
            redoOps.removeAll()
            needsDisplay = true
            onChange?()
            return
        }
        ops.append(op)
        redoOps.removeAll()
        needsDisplay = true
        onChange?()
    }

    func undo() {
        guard let op = ops.popLast() else { return }
        redoOps.append(op)
        apply(op, forward: false)
        needsDisplay = true
        onChange?()
    }

    func redo() {
        guard let op = redoOps.popLast() else { return }
        ops.append(op)
        apply(op, forward: true)
        needsDisplay = true
        onChange?()
    }

    private func apply(_ op: EditOp, forward: Bool) {
        switch op {
        case .annotation(let a):
            if forward { annotations.append(a) }
            else { annotations.removeAll { $0.id == a.id } }
        case .modify(let old, let new):
            if let index = annotations.firstIndex(where: { $0.id == new.id }) {
                annotations[index] = forward ? new : old
            }
            // 撤销/重做后同步选中态：被还原的那段文字如果还选中着，工具条数字要跟着回退
            if selectedTextID == new.id {
                onTextSelectionChange?(forward ? new : old)
            }
        case .imageSnapshot(let old, let new):
            image = forward ? new : old
            mosaicPixelCache.removeAll(); mosaicCacheBase = nil
        }
    }

    func clear() {
        guard !annotations.isEmpty || canUndo else { return }
        annotations.removeAll()
        ops.removeAll()
        redoOps.removeAll()
        if selectedTextID != nil { selectText(nil) }
        needsDisplay = true
        onChange?()
    }

    /// 合成结果（无标注则返回原图）；设了圆角就再切一次圆角
    func composite() -> CGImage? {
        guard let base = AnnotationCompositor.composite(base: image, annotations: annotations) else {
            return nil
        }
        let rounded: CGImage
        if cornerRadius > 0 {
            let scale = max(imageScale, 0.0001)
            rounded = AnnotationCompositor.roundedCorners(base, radius: cornerRadius / scale) ?? base
        } else {
            rounded = base
        }
        // v220：水印只在导出时盖上去，编辑预览不受影响
        return Watermark.applied(to: rounded)
    }

    /// 排障：预置一组覆盖五个新工具的示例标注（kitnest://annotate?demo=1）
    func installDemoNewTools() {
        // 底图可能是 Retina 2×（NSImage 1000×700 → CGImage 2000×1400）。
        // 坐标按「设计稿 1000 宽」写，再乘比例，五个工具才不会挤在左上角。
        let s = CGFloat(image.width) / 1000
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        var list: [Annotation] = []
        list.append(Annotation(tool: .counter, points: [P(90, 110)], text: "1",
                               colorHex: "#FF3B30", lineWidth: 26 * s))
        list.append(Annotation(tool: .counter, points: [P(90, 205)], text: "2",
                               colorHex: "#FF3B30", lineWidth: 26 * s))
        // 备注：起点在标题下方，文本框放到右上空白
        list.append(Annotation(tool: .remark,
                               points: [P(260, 150), P(400, 70)],
                               text: "这里的间距和上面不一致",
                               colorHex: "#FF3B30", lineWidth: 3 * s, weight: 1))
        // 聚光灯：框住左侧三色块
        list.append(Annotation(tool: .spotlight,
                               points: [P(30, 290), P(350, 530)],
                               colorHex: "#FF3B30", lineWidth: 8 * s, aux: 0.6))
        // 放大镜：取正文最上面几行
        list.append(Annotation(tool: .magnifier,
                               points: [P(620, 55), P(800, 235)],
                               colorHex: "#FF3B30", lineWidth: 8 * s, aux: 2.0))
        // 模糊：横穿正文中段（避开放大镜圆）
        list.append(Annotation(tool: .blur,
                               points: (0...12).map { P(580 + CGFloat($0) * 28, 300) },
                               colorHex: "#FF3B30", lineWidth: 36 * s, blockSize: 20 * s))

        annotations = list
        counterSeq = 2
        needsDisplay = true
        onChange?()
    }

    /// 滚轮调粗细：Snipaste / Flameshot 的通用手势（纵向滚轮才生效，避免误触横向滑动）
    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) > abs(event.scrollingDeltaX), abs(dy) >= 0.5 else {
            super.scrollWheel(with: event)
            return
        }
        onSizeDelta?(dy > 0 ? 1 : -1)
    }

    // MARK: 验收探针（无鼠标环境）

    /// 在画布中心打开内联文字框，1.2s 后落字并选中。
    /// 仅用于截图验收「输入框尺寸 / 选中框 / 字号联动」，由 defaults 键 probe.annotate 打开。
    func runAnnotateTextProbe() {
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        beginTextEditing(at: point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, let field = self.textEditor else { return }
            // 长文本：验证「超宽自动换行、不截断」
            field.stringValue = "这是一段比较长的标注文字用来验证输入框超出宽度后会自动换行不再截断 Aa 123"
            self.updateEditorBoxSize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.finishTextEditing(commit: true)
                // 落字后选中 + 弹字体配置；再推大字号验证「拖边框/滑杆改字号」链路
                if let a = self.selectedText, let r = self.textSelectionViewRect() {
                    self.showFontPopover(for: a, at: r)
                    self.applyTextSizeToSelection(min(12, a.lineWidth + 3))
                }
            }
        }
    }
}

// MARK: - 内联文字输入

extension AnnotationCanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        // 失焦（点画布别处 / Tab）也落字，与「所见即所得」一致
        finishTextEditing(commit: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        // 每敲一个字：虚线框宽跟着文字走（左边缘不动，向右生长）
        updateEditorBoxSize()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishTextEditing(commit: false)
            return true
        }
        // 多行输入框里回车默认是「换行」；这里改成语义：回车 = 确认，⇧回车 = 插入换行
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishTextEditing(commit: true)
            return true
        }
        return false
    }
}

// MARK: - 竖排工具栏落位容器

/// 竖栏要「贴着画布左缘、垂直居中，且只有胶囊本身吃鼠标」：
/// - 用一个铺满内容区的透明容器负责定位，窗口缩放时重新居中（居中基准是画布区，不含底部工具条）；
/// - 容器的 `hitTest` 只放行胶囊矩形，其余返回 nil → 点击直接落到下面的画布。
///   少了这条，覆盖全窗口的透明层会把画布的绘制/拖拽事件全挡住（最容易踩的坑）。
private final class ToolRailHost: NSView {
    /// 竖栏距内容区左缘（画布左侧留白由它推出来，见 `canvas.leadingInset`）
    static let railLeft: CGFloat = 16

    private let host: NSView
    /// 底部工具条占的高度（这截不属于画布，居中时扣掉）
    var bottomInset: CGFloat = 0

    init(host: NSView) {
        self.host = host
        super.init(frame: .zero)
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeRail()
    }

    /// 贴左缘 + 垂直居中；画布太矮时收一点高度，避免压到上下沿
    func placeRail() {
        let canvasH = max(0, bounds.height - bottomInset)
        let h = min(ToolRailMetrics.height, max(120, canvasH - 24))
        let y = bottomInset + max(6, (canvasH - h) / 2)
        host.frame = NSRect(x: Self.railLeft, y: y, width: ToolRailMetrics.width, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard host.frame.insetBy(dx: -2, dy: -2).contains(p) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - 标注编辑器窗口

/// 标注编辑器窗口：画布 + 左缘竖排工具栏 + 底部悬浮工具条（样式/操作）。
/// 工具条 2026-10-20 全面重做：图标工具分组 + 上下文样式（颜色/笔刷/马赛克块大小）
/// + 撤销/重做 + 主次操作；配套快捷键（R/O/A/P/H/M/T/E/D、⌘Z/⇧⌘Z/⌘C/⌘S、Esc）。
/// v181：9 个工具移到画布左边竖栏（方案 B），底部只留样式 + 操作共 9 项。
final class AnnotationEditorWindow: NSWindow {
    let canvas: AnnotationCanvasView
    /// 工具条状态（v71 SwiftUI 化后由本模型驱动选中态与撤销可用态）
    let toolbarModel = EditorToolbarModel()

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?

    /// 工具条高度（画布下方悬浮胶囊的容纳区）
    private static let toolbarHeight: CGFloat = 84
    /// 画布最小高度：必须容得下左侧竖排工具条（竖栏 + 上下各 14pt 留白），
    /// 否则小图（如 200×120）打开时竖栏会贴到窗口上下沿。
    private static var minCanvasHeight: CGFloat { max(300, ToolRailMetrics.height + 28) }

    init(image: CGImage) {
        let maxW: CGFloat = 960, maxH: CGFloat = 720
        let scale = min(1, min(maxW / CGFloat(image.width), maxH / CGFloat(image.height)))
        let canvasW = max(880, CGFloat(image.width) * scale)
        let canvasH = max(Self.minCanvasHeight, CGFloat(image.height) * scale)
        let size = NSSize(width: canvasW, height: canvasH + Self.toolbarHeight)

        canvas = AnnotationCanvasView(image: image)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "标注截图  ·  \(image.width) × \(image.height)"
        // v209：统一窗口外观入口（原生标题栏 + 原生红黄绿 + 统一玻璃底 + 系统圆角），
        // 在 contentView 装配完成后调用。画布自身仍是不透明灰底，保证看图校色；
        // 玻璃只出现在画布外的工具区/边缘。
        // 标题文字在标准标题栏下必定可见、可拖（透明标题栏会吞标题，历史踩过）。
        minSize = NSSize(width: 880, height: Self.minCanvasHeight + Self.toolbarHeight)
        isReleasedWhenClosed = false
        canvas.frame = NSRect(x: 0, y: Self.toolbarHeight, width: canvasW, height: canvasH)
        canvas.autoresizingMask = [.width, .height]
        // 竖栏占的那条留给灰底：图像从竖栏右侧开始，标注时不会被工具条挡住在左缘画不了
        canvas.leadingInset = ToolRailHost.railLeft + ToolRailMetrics.width + 12
        canvas.onChange = { [weak self] in self?.refreshActions() }
        canvas.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        canvas.onSizeDelta = { [weak self] delta in self?.adjustSize(by: delta) }
        // 选中文字 → 工具条显示「这段文字」的字号/颜色，滑杆直接改它
        canvas.onTextSelectionChange = { [weak self] annotation in
            guard let self else { return }
            self.toolbarModel.textSelectionActive = annotation != nil
            guard let annotation else { return }
            self.toolbarModel.textSize = Double(annotation.lineWidth)
            self.toolbarModel.color = Color(nsColor: AnnotationCompositor.color(fromHex: annotation.colorHex))
        }
        canvas.tool = AnnotationTool.allCases[toolbarModel.toolIndex]
        // 默认粗细随图幅走（3000px 级截图默认给粗，避免「细到看不见」）
        toolbarModel.applyImageDefaults(imageWidth: image.width)
        canvas.lineWidth = CGFloat(toolbarModel.lineWidth)
        canvas.brushWidth = CGFloat(toolbarModel.brushWidth)
        canvas.textSize = CGFloat(toolbarModel.textSize)
        canvas.mosaicBlock = CGFloat(toolbarModel.mosaicBlock)
        // 鼠标移动事件必须由**窗口**开启（NSWindow 属性）；画布侧靠 trackingArea(.mouseMoved) 接收，
        // 第一响应者负责 keyDown——两者缺一都会表现为「橡皮圈不跟手 / 快捷键无效」。
        acceptsMouseMovedEvents = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = true
        container.wantsLayer = true
        container.addSubview(canvas)

        // v181（方案 B）：9 个工具竖排浮在画布左缘，底部胶囊只留样式与操作。
        // 必须加在 canvas 之后（同层里后加的在上），否则被画布盖住点不到。
        let rail = ToolRailHost(host: buildToolRail())
        rail.bottomInset = Self.toolbarHeight
        rail.frame = container.bounds
        rail.autoresizingMask = [.width, .height]
        container.addSubview(rail)
        rail.placeRail()

        let toolbar = buildToolbar(width: canvasW)
        toolbar.frame = NSRect(x: 0, y: 0, width: canvasW, height: Self.toolbarHeight)
        toolbar.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(toolbar)
        contentView = container
        // v209：全 App 唯一窗口外观入口（原生标题栏 + 原生红黄绿 + 统一玻璃底）
        applyOfficialChrome()

        refreshActions()
    }

    // MARK: 竖排工具栏

    /// 画布左缘的 9 个工具（竖排胶囊）。窗口只负责给它一个贴边居中的框，
    /// 内部布局全在 SwiftUI 侧（`AnnotationToolRailView`），尺寸取自 `ToolRailMetrics`。
    private func buildToolRail() -> NSView {
        let root = AnnotationToolRailView(
            model: toolbarModel,
            onTool: { [weak self] index in self?.toolbarDidSelectTool(index) }
        )
        .frsetThemeChrome()

        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        return host
    }

    // MARK: 工具条

    private func buildToolbar(width: CGFloat) -> NSView {
        let root = VStack(spacing: 0) {
            Spacer(minLength: 0)
            AnnotationToolbarView(
                model: toolbarModel,
                onColor: { [weak self] color in self?.toolbarDidChangeColor(NSColor(color)) },
                onSize: { [weak self] value in self?.toolbarDidChangeSize(CGFloat(value)) },
                onBlock: { [weak self] value in self?.toolbarDidChangeBlock(value) },
                onCorner: { [weak self] value in self?.canvas.cornerRadius = CGFloat(value) },
                onUndo: { [weak self] in self?.undoTapped(); self?.refocusCanvas() },
                onRedo: { [weak self] in self?.redoTapped(); self?.refocusCanvas() },
                onClear: { [weak self] in self?.clearTapped(); self?.refocusCanvas() },
                onLong: { [weak self] in self?.longScreenshotTapped() },
                onCopy: { [weak self] in self?.copyTapped() },
                onSave: { [weak self] in self?.saveTapped() },
                onClose: { [weak self] in self?.closeTapped() }
            )
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 主题统一入口：标注工具条的强调色（复制按钮/选中态）跟个性化走
        .frsetThemeChrome()

        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.toolbarHeight)
        host.autoresizingMask = [.width]
        return host
    }

    /// 工具条回调 → 画布/窗口动作（集中在一处，SwiftUI 侧不持有 NSWindow）
    func toolbarDidSelectTool(_ index: Int) {
        let tool = AnnotationTool.allCases[index]
        canvas.tool = tool
        // 切到文字/笔刷时把它们各自的尺寸同步给画布
        switch tool {
        case .text: canvas.textSize = CGFloat(toolbarModel.textSize)
        case .highlighter: canvas.lineWidth = CGFloat(toolbarModel.highlighterWidth)
        case .eraser, .mosaic, .removal: canvas.brushWidth = CGFloat(toolbarModel.brushWidth)
        default: canvas.lineWidth = CGFloat(toolbarModel.lineWidth)
        }
        refocusCanvas()
    }

    func toolbarDidChangeColor(_ color: NSColor) {
        canvas.color = color
        // 有选中的文字时，改色直接落到这段文字上（不然用户会觉得「选了却改不动」）
        if canvas.tool == .text, canvas.selectedTextID != nil {
            canvas.applyColorToSelection(AnnotationCompositor.hex(of: color))
        }
        refocusCanvas()
    }

    func toolbarDidChangeSize(_ value: CGFloat) {
        switch toolbarModel.activeTool {
        case .text:
            canvas.textSize = value
            // 选中了某段文字：滑杆改的是它，而不是只改「下一个文字的默认字号」
            if canvas.selectedTextID != nil { canvas.applyTextSizeToSelection(value) }
        case .highlighter: canvas.lineWidth = value
        case .eraser, .mosaic, .removal: canvas.brushWidth = value
        default: canvas.lineWidth = value
        }
        refocusCanvas()
    }

    func toolbarDidChangeBlock(_ value: Int) {
        canvas.mosaicBlock = CGFloat(value)
        refocusCanvas()
    }

    /// 滚轮/方括号调尺寸：同时更新工具条数值与画布
    func adjustSize(by delta: CGFloat) {
        toolbarModel.nudgeSize(by: Double(delta))
        toolbarDidChangeSize(CGFloat(toolbarModel.sizeValue))
        canvas.needsDisplay = true
    }

    private func refreshActions() {
        toolbarModel.canUndo = canvas.canUndo
        toolbarModel.canRedo = canvas.canRedo
    }

    /// 工具条动作后把第一响应者还给画布：否则焦点被 SwiftUI 宿主视图拿走，
    /// 之后快捷键（R/M/⌘Z…）与鼠标光圈都不再工作。
    private func refocusCanvas() {
        if firstResponder !== canvas {
            makeFirstResponder(canvas)
        }
    }

    // MARK: 动作

    private func selectTool(_ tool: AnnotationTool) {
        guard let index = AnnotationTool.allCases.firstIndex(of: tool) else { return }
        toolbarModel.toolIndex = index
        canvas.tool = tool
        switch tool {
        case .text: canvas.textSize = CGFloat(toolbarModel.textSize)
        case .highlighter: canvas.lineWidth = CGFloat(toolbarModel.highlighterWidth)
        case .eraser, .mosaic, .removal: canvas.brushWidth = CGFloat(toolbarModel.brushWidth)
        default: canvas.lineWidth = CGFloat(toolbarModel.lineWidth)
        }
    }

    @objc private func undoTapped() { canvas.undo() }
    @objc private func redoTapped() { canvas.redo() }
    @objc private func clearTapped() { canvas.clear() }

    /// 长截图入口（spec 15 F1）：有标注先弹确认框（清除标注），随后进入选区→滚动采捕会话
    @objc private func longScreenshotTapped() {
        guard LongScreenshotCoordinator.confirmClearAnnotations(hasAnnotations: !canvas.annotations.isEmpty) else { return }
        canvas.clear()
        closeTapped()
        LongScreenshotCoordinator.shared.beginSelection()
    }

    @objc private func copyTapped() {
        guard let image = canvas.composite() else { return }
        onCopy?(image)
    }

    @objc private func saveTapped() {
        guard let image = canvas.composite() else { return }
        onSave?(image)
    }

    @objc private func closeTapped() { performClose(nil) }

    // MARK: 键盘

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods.contains(.command) {
            switch chars {
            case "z":
                if mods.contains(.shift) { canvas.redo() } else { canvas.undo() }
                return true
            case "c":
                copyTapped(); return true
            case "s":
                saveTapped(); return true
            default:
                return false
            }
        }
        guard mods.isEmpty else { return false }

        if event.keyCode == 53 { closeTapped(); return true }   // Esc
        switch chars {
        case "r": selectTool(.rectangle); return true
        case "o": selectTool(.ellipse); return true
        case "a": selectTool(.arrow); return true
        case "p": selectTool(.pen); return true
        case "h": selectTool(.highlighter); return true
        case "m": selectTool(.mosaic); return true
        case "t": selectTool(.text); return true
        case "e": selectTool(.eraser); return true
        case "d": selectTool(.removal); return true
        // [ ] 调当前工具粗细/笔刷直径（Photoshop / Flameshot 惯例）
        case "[": adjustSize(by: -2); return true
        case "]": adjustSize(by: 2); return true
        default: return false
        }
    }
}

// MARK: - 标注编辑器控制器

/// 标注编辑器入口：把一张图（最近截图 / 文件）载入编辑器；
/// 复制 / 保存分别复用 ScreenshotManager 的剪贴板与落盘逻辑，保证与截图主流程一致。
public final class AnnotationEditorController: NSObject, NSWindowDelegate {
    public static let shared = AnnotationEditorController()

    private var window: AnnotationEditorWindow?
    /// v130（SnowShot 对齐）②：当前编辑图的来源路径（关闭时把未完成标注快照写回截图历史）
    private var sourcePath: String?

    private override init() { super.init() }

    /// 打开最近一张截图；没有则返回 false（由调用方决定是否弹文件选择）
    @discardableResult
    public func openLatest() -> Bool {
        guard let first = ScreenshotManager.shared.recent.first else { return false }
        open(url: first.url)
        return true
    }

    public func open(url: URL) {
        open(url: url, annotationState: "")
    }

    /// v130②：打开图片并恢复未完成标注（历史窗「继续标注」入口）。
    /// `annotationState` 为历史库 annotation_state 列的 JSON；空串 = 无快照。
    public func open(url: URL, annotationState: String) {
        guard let image = ImageProcessor.cgImage(from: url) else {
            Log.warn("Capture", "标注：无法读取图片 \(url.lastPathComponent)")
            return
        }
        open(image: image)
        sourcePath = url.path
        if let restored = AnnotationStateSnapshot.decode(annotationState), !restored.isEmpty {
            window?.canvas.restore(annotations: restored)
            Log.info("Capture", "标注：已恢复未完成标注 \(restored.count) 条")
        }
    }

    /// 排障（v176）：打开编辑器 + 设 24 圆角 + 导出成图到 /tmp，
    /// 用来核对「圆角真的落到成图」，而不仅是画布预览。
    public func debugCornerDemo() {
        let size = NSSize(width: 420, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.90, alpha: 1).setFill()
        NSRect(x: 24, y: 24, width: 372, height: 90).fill()
        ("圆角预览示例" as NSString).draw(at: NSPoint(x: 24, y: 170),
            withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold),
                             .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        open(image: cg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let editor = self?.window else { return }
            editor.toolbarModel.cornerRadius = 24
            editor.canvas.cornerRadius = 24
            if let out = editor.canvas.composite(), let data = ImageProcessor.pngData(out) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/annot_round.png"))
                Log.info("Capture", "排障：圆角成图已写 /tmp/annot_round.png（\(out.width)×\(out.height)）")
            }
        }
    }

    /// 排障：打开一张演示图并预置覆盖五个新工具的标注（kitnest://annotate?demo=1）
    /// 同时把合成结果写 /tmp/annot_newtools.png——无鼠标环境也能核对绘制效果。
    public func debugNewToolsDemo() {
        let size = NSSize(width: 1000, height: 700)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        ("新标注工具验收" as NSString).draw(at: NSPoint(x: 60, y: 640),
            withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold),
                             .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)])

        // 正文：放大镜/模糊的取样对象（NSImage 左下原点 → 图上 y 100..600）
        let body = (1...14).map { "第 \($0) 行：放大镜与模糊的取样区域" }.joined(separator: "\n")
        (body as NSString).draw(in: NSRect(x: 600, y: 120, width: 380, height: 500),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15),
                             .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1)])

        // 色块：聚光灯的取样对象（图上 y 300..520）
        for (i, c) in [NSColor.systemBlue, NSColor.systemOrange, NSColor.systemGreen].enumerated() {
            c.withAlphaComponent(0.35).setFill()
            NSRect(x: 40 + i * 110, y: 180, width: 90, height: 220).fill()
        }
        img.unlockFocus()
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        open(image: cg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let editor = self?.window else { return }
            editor.canvas.installDemoNewTools()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let out = editor.canvas.composite(), let data = ImageProcessor.pngData(out) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/annot_newtools.png"))
                    Log.info("Capture", "排障：新工具成图已写 /tmp/annot_newtools.png（\(out.width)×\(out.height)）")
                }
            }
        }
    }

    /// 仅用于验收 v181「工具竖排到画布左侧」：打开一张接近真实截图尺寸的图，
    /// 并把两个关键点的 hitTest 结果写 /tmp/rail_probe.txt（无辅助功能权限时可脚本验收）。
    public func debugRailProbe() {
        let size = NSSize(width: 1200, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.90, alpha: 1).setFill()
        NSRect(x: 0, y: 120, width: 1200, height: 220).fill()
        ("左侧竖排工具栏验收" as NSString).draw(at: NSPoint(x: 60, y: 620),
            withAttributes: [.font: NSFont.systemFont(ofSize: 44, weight: .bold),
                             .foregroundColor: NSColor.black])
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        open(image: cg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let editor = self?.window, let content = editor.contentView else { return }
            func who(_ p: NSPoint) -> String {
                guard let v = content.hitTest(p) else { return "nil(穿透)" }
                var chain: [String] = []
                var cur: NSView? = v
                while let c = cur, c !== content {
                    chain.append(String(describing: type(of: c)))
                    cur = c.superview
                }
                return chain.joined(separator: " < ")
            }
            let railPoint = NSPoint(x: 24, y: content.bounds.midY)
            let canvasPoint = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
            let report = """
            content = \(Int(content.bounds.width))×\(Int(content.bounds.height))
            rail    = \(Int(ToolRailMetrics.width))×\(Int(ToolRailMetrics.height))
            railPoint(24, midY)   -> \(who(railPoint))
            canvasPoint(midX,midY) -> \(who(canvasPoint))

            """
            try? report.write(toFile: "/tmp/rail_probe.txt", atomically: true, encoding: .utf8)
            Log.info("Capture", "rail 探针：\(report.replacingOccurrences(of: "\n", with: " | "))")
        }
    }

    public func open(image: CGImage, tool: AnnotationTool? = nil) {
        // 编辑器是单实例：旧窗口（含深链/贴图/剪贴板多入口开的）一律收掉，
        // 否则会出现「两个编辑器叠着、输入框落在旧窗口上」的幽灵状态。
        for w in NSApp.windows where w is AnnotationEditorWindow { w.close() }
        window = nil
        sourcePath = nil   // v130②：无文件来源（仅内存图）不写标注快照
        let editor = AnnotationEditorWindow(image: image)
        if let tool, let index = AnnotationTool.allCases.firstIndex(of: tool) {
            editor.toolbarModel.toolIndex = index
            editor.canvas.tool = tool
        }
        editor.delegate = self
        editor.onCopy = { image in
            ScreenshotManager.shared.copyToPasteboard(image)
        }
        editor.onSave = { image in
            guard let data = ImageProcessor.pngData(image),
                  let url = ScreenshotManager.shared.savePNG(data) else { return }
            ScreenshotManager.shared.registerCaptured(url: url, data: data, mode: "annotate")   // v130②
        }
        window = editor
        editor.center()
        editor.makeKeyAndOrderFront(nil)
        // 画布为第一响应者：笔刷光标圈（mouseMoved）与工具快捷键（keyDown）才能收到事件
        editor.makeFirstResponder(editor.canvas)
        NSApp.activate(ignoringOtherApps: true)
        // 无鼠标环境的视觉验收钩子（probe.annotate = 1）
        if UserDefaults.standard.bool(forKey: "probe.annotate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                editor.canvas.runAnnotateTextProbe()
            }
        }
        Log.info("Capture", "标注：编辑器窗口已显示（\(Int(editor.frame.width))×\(Int(editor.frame.height))）origin=\(editor.frame.origin) screen=\(NSScreen.main?.frame.size ?? .zero)")
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? AnnotationEditorWindow) === window {
            // v130（SnowShot 对齐）②：关闭时若有未保存标注，快照写回截图历史库
            // （annotation_state 列 → 下次「继续标注」恢复）；已保存走 onSave 新记录，不覆盖。
            if let path = sourcePath, let canvas = window?.canvas, !canvas.annotations.isEmpty {
                CaptureHistoryStore.shared.updateAnnotationState(
                    path: path, json: AnnotationStateSnapshot.encode(canvas.annotations))
            }
            sourcePath = nil
            window = nil
        }
    }
}
