import AppKit
import CoreGraphics
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
        didSet { cursorPoint = nil; needsDisplay = true }
    }
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3 { didSet { needsDisplay = true } }
    /// 马赛克笔刷直径（图像像素）与块大小（像素）
    var brushWidth: CGFloat = 36 { didSet { needsDisplay = true } }
    var mosaicBlock: CGFloat = 10
    /// 标注变化回调（用于刷新撤销按钮可用态）
    var onChange: (() -> Void)?
    /// 键盘事件回调（工具条快捷键 / ⌘Z 等；返回 true 表示已处理）
    var onKey: ((NSEvent) -> Bool)?

    /// 撤销栈：标注追加 / 抹除前的底图快照
    private enum EditOp {
        case annotation(Annotation)
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
    private var mosaicCacheBase: CGImage?
    /// 抹除工具：正在涂抹的轨迹（图像像素坐标、左上原点）
    private var removalStroke: [CGPoint]?
    /// 橡皮正在滑动擦除（v71：拖拽路径连续删除命中标注，与画笔滑动一致）
    private var isErasing = false
    private var draft: Annotation?
    private var dragStart: CGPoint?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 坐标换算

    /// 底图在视图内的等比居中矩形
    private var fitRect: CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
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
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()

        let f = fitRect
        guard f.width > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 底图：临时还原成 CG 常规坐标系，避免在 flipped 视图里上下颠倒
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: f.minX, y: bounds.height - f.maxY, width: f.width, height: f.height))
        ctx.restoreGState()

        // 标注：图像像素坐标 → 视图坐标
        ctx.saveGState()
        ctx.translateBy(x: f.minX, y: f.minY)
        ctx.scaleBy(x: imageScale, y: imageScale)
        let canvasRect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        if mosaicCacheBase !== image {
            mosaicPixelCache.removeAll()
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
        AnnotationCompositor.draw(annotations, in: canvasRect, base: image, mosaicCache: mosaicProvider)
        if let draft = draft {
            AnnotationCompositor.draw([draft], in: canvasRect, base: image, mosaicCache: mosaicProvider)
        }
        // 笔刷光标环：白描边 + 深色内描边，任何底色上都看得清
        if let p = cursorPoint, let radius = brushRingRadius {
            ctx.saveGState()
            let base = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            ctx.setLineWidth(3 / max(imageScale, 0.01))
            ctx.strokeEllipse(in: base)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(1.2 / max(imageScale, 0.01))
            ctx.strokeEllipse(in: base)
            ctx.restoreGState()
        }
        // 抹除涂抹预览（半透明蓝，线宽 = 实际笔刷直径）
        if let stroke = removalStroke, stroke.count >= 1 {
            ctx.saveGState()
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.35))
            ctx.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.45))
            ctx.setLineWidth(brushRadius * 2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if stroke.count == 1 {
                let p = stroke[0]
                ctx.fillEllipse(in: CGRect(x: p.x - brushRadius, y: p.y - brushRadius,
                                           width: brushRadius * 2, height: brushRadius * 2))
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
    }

    // MARK: 命中测试（橡皮擦用）

    /// 判断某个标注是否被点中：形状类看包围盒，画笔/荧光看轨迹邻近点，
    /// 文字看锚点附近。容差按线宽放大，小图元也点得到。
    private func hitTest(_ a: Annotation, at point: CGPoint) -> Bool {
        let tolerance = max(6, a.lineWidth * 2)
        switch a.tool {
        case .rectangle, .ellipse, .mosaic:
            guard let r = AnnotationCompositor.rect(of: a) else { return false }
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .arrow:
            return a.points.contains { hypot($0.x - point.x, $0.y - point.y) <= tolerance }
        case .pen, .highlighter:
            return a.points.contains { hypot($0.x - point.x, $0.y - point.y) <= tolerance * 1.5 }
        case .text:
            guard let anchor = a.points.first else { return false }
            return hypot(anchor.x - point.x, anchor.y - point.y) <= max(20, a.lineWidth * 8)
        case .eraser, .removal:
            return false
        }
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let ip = imagePoint(convert(event.locationInWindow, from: nil))
        cursorPoint = ip

        if tool == .eraser {
            // 橡皮擦的是「标注」而不是像素：v71 支持滑动——按下即擦，拖拽路径连续擦
            isErasing = true
            eraseAt(ip)
            return
        }

        if tool == .text {
            if let text = promptText(), !text.isEmpty {
                let a = Annotation(tool: .text, points: [ip], text: text,
                                   colorHex: AnnotationCompositor.hex(of: color),
                                   lineWidth: lineWidth)
                annotations.append(a)
                record(.annotation(a))
                needsDisplay = true
                onChange?()
            }
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
        cursorPoint = imagePoint(convert(event.locationInWindow, from: nil))
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
        guard let start = dragStart else { return }
        let ip = imagePoint(convert(event.locationInWindow, from: nil))
        if tool == .pen || tool == .highlighter || tool == .mosaic {
            if draft == nil {
                draft = Annotation(tool: tool, points: [start],
                                   colorHex: AnnotationCompositor.hex(of: color),
                                   lineWidth: strokeWidth(for: tool),
                                   blockSize: mosaicBlock)
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
        cursorPoint = imagePoint(convert(event.locationInWindow, from: nil))
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
        defer { dragStart = nil; draft = nil; needsDisplay = true }
        guard let start = dragStart else { return }
        let ip = imagePoint(convert(event.locationInWindow, from: nil))
        let finished: Annotation?
        if tool == .pen || tool == .highlighter || tool == .mosaic {
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
        }
    }

    // MARK: 物体抹除（eSearch removeObj 对齐）

    /// 抹除笔刷半径（细/中/粗 → 16/32/64 直径）
    var brushRadius: CGFloat { max(8, brushWidth) / 2 }

    /// 各工具落笔宽度：马赛克用独立笔刷直径，其余用线宽
    private func strokeWidth(for tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .mosaic: return max(8, brushWidth)
        case .highlighter: return max(2, lineWidth)
        default: return max(1, lineWidth)
        }
    }

    /// 笔刷光标环半径（图像像素；非笔刷工具返回 nil，不显示环）
    private var brushRingRadius: CGFloat? {
        switch tool {
        case .mosaic: return max(8, brushWidth) / 2
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
        guard brushRingRadius != nil else { return }
        cursorPoint = imagePoint(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        if brushRingRadius != nil {
            cursorPoint = imagePoint(convert(event.locationInWindow, from: nil))
            NSCursor.crosshair.set()
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
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

        let old = image
        guard let cleaned = ObjectRemovalEngine.inpaint(image: image, mask: mask) else {
            Log.warn("Capture", "抹除：修复引擎返回空")
            return
        }
        image = cleaned
        mosaicPixelCache.removeAll(); mosaicCacheBase = nil
        record(.imageSnapshot(old: old, new: cleaned))
        onChange?()
        Log.info("Capture", "抹除：修复完成（轨迹 \(stroke.count) 点，笔刷直径 \(Int(r * 2))px）")
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
        case .mosaic:
            // 画笔式：单击落一个点、拖动成笔触都算有效
            return !a.points.isEmpty
        case .eraser, .removal:
            return false
        case .text:
            return true
        }
    }

    private func promptText() -> String? {
        let alert = NSAlert()
        alert.messageText = "输入标注文字"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: 操作（供工具条调用）

    var canUndo: Bool { !ops.isEmpty }
    var canRedo: Bool { !redoOps.isEmpty }

    /// 记录一次编辑：入撤销栈并清空重做栈
    private func record(_ op: EditOp) {
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
        needsDisplay = true
        onChange?()
    }

    /// 合成结果（无标注则返回原图）
    func composite() -> CGImage? {
        AnnotationCompositor.composite(base: image, annotations: annotations)
    }
}

// MARK: - 标注编辑器窗口

/// 标注编辑器窗口：上方画布 + 下方浮动工具条。
/// 工具条 2026-10-20 全面重做：图标工具分组 + 上下文样式（颜色/笔刷/马赛克块大小）
/// + 撤销/重做 + 主次操作；配套快捷键（R/O/A/P/H/M/T/E/D、⌘Z/⇧⌘Z/⌘C/⌘S、Esc）。
final class AnnotationEditorWindow: NSWindow {
    let canvas: AnnotationCanvasView
    /// 工具条状态（v71 SwiftUI 化后由本模型驱动选中态与撤销可用态）
    let toolbarModel = EditorToolbarModel()

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?

    /// 工具条高度（画布下方固定条）
    private static let toolbarHeight: CGFloat = 58

    init(image: CGImage) {
        let maxW: CGFloat = 960, maxH: CGFloat = 720
        let scale = min(1, min(maxW / CGFloat(image.width), maxH / CGFloat(image.height)))
        let canvasW = max(880, CGFloat(image.width) * scale)
        let canvasH = max(300, CGFloat(image.height) * scale)
        let size = NSSize(width: canvasW, height: canvasH + Self.toolbarHeight)

        canvas = AnnotationCanvasView(image: image)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "标注截图"
        applyOfficialChrome()   // 官方外观：灰底 + 透明标题栏
        minSize = NSSize(width: 880, height: 300 + Self.toolbarHeight)
        isReleasedWhenClosed = false
        canvas.frame = NSRect(x: 0, y: Self.toolbarHeight, width: canvasW, height: canvasH)
        canvas.autoresizingMask = [.width, .height]
        canvas.onChange = { [weak self] in self?.refreshActions() }
        canvas.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        canvas.tool = AnnotationTool.allCases[toolbarModel.toolIndex]
        // 鼠标移动事件必须由**窗口**开启（NSWindow 属性）；画布侧靠 trackingArea(.mouseMoved) 接收，
        // 第一响应者负责 keyDown——两者缺一都会表现为「橡皮圈不跟手 / 快捷键无效」。
        acceptsMouseMovedEvents = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = true
        container.addSubview(canvas)

        let toolbar = buildToolbar(width: canvasW)
        toolbar.frame = NSRect(x: 0, y: 0, width: canvasW, height: Self.toolbarHeight)
        toolbar.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(toolbar)
        contentView = container

        refreshActions()
    }

    // MARK: 工具条

    private func buildToolbar(width: CGFloat) -> NSView {
        let host = NSHostingView(rootView: EditorToolbarView(
            model: toolbarModel,
            onTool: { [weak self] index in
                self?.canvas.tool = AnnotationTool.allCases[index]
                self?.refocusCanvas()
            },
            onColor: { [weak self] color in
                self?.canvas.color = NSColor(color)
                self?.refocusCanvas()
            },
            onLineWidth: { [weak self] value in
                self?.canvas.lineWidth = CGFloat(value)
                self?.refocusCanvas()
            },
            onBrushWidth: { [weak self] value in
                self?.canvas.brushWidth = CGFloat(value)
                self?.refocusCanvas()
            },
            onBlock: { [weak self] value in
                self?.canvas.mosaicBlock = CGFloat(value)
                self?.refocusCanvas()
            },
            onUndo: { [weak self] in self?.undoTapped(); self?.refocusCanvas() },
            onRedo: { [weak self] in self?.redoTapped(); self?.refocusCanvas() },
            onClear: { [weak self] in self?.clearTapped(); self?.refocusCanvas() },
            onLong: { [weak self] in self?.longScreenshotTapped() },
            onCopy: { [weak self] in self?.copyTapped() },
            onSave: { [weak self] in self?.saveTapped() },
            onClose: { [weak self] in self?.closeTapped() }
        ))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.toolbarHeight)
        host.autoresizingMask = [.width]
        return host
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
        case "[": canvas.undo(); return true
        case "]": canvas.redo(); return true
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

    private override init() { super.init() }

    /// 打开最近一张截图；没有则返回 false（由调用方决定是否弹文件选择）
    @discardableResult
    public func openLatest() -> Bool {
        guard let first = ScreenshotManager.shared.recent.first else { return false }
        open(url: first.url)
        return true
    }

    public func open(url: URL) {
        guard let image = ImageProcessor.cgImage(from: url) else {
            Log.warn("Capture", "标注：无法读取图片 \(url.lastPathComponent)")
            return
        }
        open(image: image)
    }

    public func open(image: CGImage) {
        window?.close()
        let editor = AnnotationEditorWindow(image: image)
        editor.delegate = self
        editor.onCopy = { image in
            ScreenshotManager.shared.copyToPasteboard(image)
        }
        editor.onSave = { image in
            guard let data = ImageProcessor.pngData(image),
                  let url = ScreenshotManager.shared.savePNG(data) else { return }
            ScreenshotManager.shared.registerCaptured(url: url, data: data)
        }
        window = editor
        editor.center()
        editor.makeKeyAndOrderFront(nil)
        // 画布为第一响应者：笔刷光标圈（mouseMoved）与工具快捷键（keyDown）才能收到事件
        editor.makeFirstResponder(editor.canvas)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("Capture", "标注：编辑器窗口已显示（\(Int(editor.frame.width))×\(Int(editor.frame.height))）")
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? AnnotationEditorWindow) === window { window = nil }
    }
}

// MARK: - 工具条状态与视图（2026-10-20 重做）

/// 工具条状态：当前工具、颜色、线宽、马赛克笔刷/块大小、撤销重做可用态
final class EditorToolbarModel: ObservableObject {
    @Published var toolIndex = 2                 // 默认箭头（截图后最常用）
    @Published var color: Color = Color(nsColor: .systemRed)
    @Published var lineWidth: Double = 3
    /// 笔刷类工具（马赛克/橡皮/抹除）的直径
    @Published var brushWidth: Double = 36
    /// 马赛克块大小（像素）
    @Published var mosaicBlock: Int = 10
    @Published var canUndo = false
    @Published var canRedo = false

    var activeTool: AnnotationTool {
        let all = AnnotationTool.allCases
        return all[max(0, min(toolIndex, all.count - 1))]
    }
    /// 当前工具是否笔刷类
    var isBrushTool: Bool {
        switch activeTool {
        case .mosaic, .eraser, .removal: return true
        default: return false
        }
    }
    /// 当前工具是否需要颜色
    var usesColor: Bool {
        switch activeTool {
        case .mosaic, .eraser, .removal: return false
        default: return true
        }
    }
}

/// 工具条：图标工具分组 + 上下文样式 + 撤销/重做 + 主次操作。
private struct EditorToolbarView: View {
    @ObservedObject var model: EditorToolbarModel
    var onTool: (Int) -> Void
    var onColor: (Color) -> Void
    var onLineWidth: (Double) -> Void
    var onBrushWidth: (Double) -> Void
    var onBlock: (Int) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onClear: () -> Void
    var onLong: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClose: () -> Void

    /// 预设色（与 macOS 系统色一致；马赛克/橡皮不显示）
    private static let palette: [String] = ["#FF3B30", "#FF9500", "#FFCC00",
                                            "#34C759", "#0A84FF", "#FFFFFF", "#1C1C1E"]

    var body: some View {
        HStack(spacing: 9) {
            toolCluster
            Spacer(minLength: 12)
            styleCluster
            divider
            actionCluster
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Color(nsColor: OfficialChrome.windowBackground))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }

    // MARK: 工具

    private var toolCluster: some View {
        HStack(spacing: 2) {
            ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.offset) { index, tool in
                ToolbarIconButton(symbol: tool.systemImage,
                                  selected: model.toolIndex == index,
                                  help: "\(tool.title)  \(tool.shortcut)") {
                    model.toolIndex = index
                    onTool(index)
                }
                // 工具分组：形状 / 画笔 / 文字与修复，中间留一点呼吸
                if index == 2 || index == 5 {
                    Rectangle().fill(Color.primary.opacity(0.10))
                        .frame(width: 0.5, height: 16)
                        .padding(.horizontal, 3)
                }
            }
        }
    }

    // MARK: 样式（颜色 / 笔刷 / 块大小）

    private var styleCluster: some View {
        HStack(spacing: 8) {
            if model.usesColor {
                colorCluster
            }
            sizeControl
            if model.activeTool == .mosaic {
                blockControl
            }
        }
    }

    private var colorCluster: some View {
        HStack(spacing: 5) {
            ForEach(Self.palette, id: \.self) { hex in
                let color = Color(nsColor: AnnotationCompositor.color(fromHex: hex))
                Button {
                    model.color = color
                    onColor(color)
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.8))
                        .overlay {
                            if isSameColor(model.color, color) {
                                Circle().stroke(Color.accentColor, lineWidth: 2)
                                    .frame(width: 18, height: 18)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("颜色 \(hex)")
            }
            ColorWellButton(current: NSColor(model.color)) { picked in
                model.color = picked
                onColor(picked)
            }
        }
    }

    /// 粗细 / 笔刷直径：一条滑杆 + 实时圆点预览 + 数值
    private var sizeControl: some View {
        let isBrush = model.isBrushTool
        let value = isBrush ? model.brushWidth : model.lineWidth
        let range: ClosedRange<Double> = isBrush ? 8...80 : 1...20
        let preview = max(2.5, min(14, isBrush ? value / 5 : value + 1))
        return HStack(spacing: 6) {
            Circle()
                .fill(model.usesColor ? model.color : Color.primary.opacity(0.55))
                .frame(width: preview, height: preview)
                .frame(width: 14, height: 14)
            Slider(value: Binding(
                get: { value },
                set: { newValue in
                    if isBrush { model.brushWidth = newValue; onBrushWidth(newValue) }
                    else { model.lineWidth = newValue; onLineWidth(newValue) }
                }), in: range)
                .controlSize(.small)
                .tint(Color.accentColor)
                .frame(width: 96)
            Text(isBrush ? "\(Int(value))" : String(format: "%.0f", value))
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
        }
        .help(isBrush ? "笔刷直径（像素）" : "线条粗细")
    }

    /// 马赛克块大小：6 / 10 / 16（块越小越容易被还原，块越大越糊）
    private var blockControl: some View {
        HStack(spacing: 4) {
            Text("块")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Picker("", selection: Binding(
                get: { model.mosaicBlock },
                set: { model.mosaicBlock = $0; onBlock($0) })) {
                Text("6").tag(6)
                Text("10").tag(10)
                Text("16").tag(16)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 92)
        }
        .help("马赛克块大小（像素）")
    }

    // MARK: 操作

    private var actionCluster: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(symbol: "arrow.uturn.backward",
                              enabled: model.canUndo,
                              help: "撤销  ⌘Z", action: onUndo)
            ToolbarIconButton(symbol: "arrow.uturn.forward",
                              enabled: model.canRedo,
                              help: "重做  ⇧⌘Z", action: onRedo)
            ToolbarIconButton(symbol: "trash", help: "清空标注", action: onClear)
            ToolbarIconButton(symbol: "arrow.down.to.line", help: "长截图", action: onLong)

            divider

            Button(action: onCopy) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                    Text("复制").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Color.accentColor))
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("复制到剪贴板  ⌘C")

            ToolbarIconButton(symbol: "square.and.arrow.down", help: "保存  ⌘S", action: onSave)
            ToolbarIconButton(symbol: "xmark", help: "关闭  Esc", action: onClose)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 0.5, height: 20)
            .padding(.horizontal, 2)
    }

    private func isSameColor(_ a: Color, _ b: Color) -> Bool {
        let na = NSColor(a).usingColorSpace(.sRGB)
        let nb = NSColor(b).usingColorSpace(.sRGB)
        guard let na, let nb else { return false }
        return abs(na.redComponent - nb.redComponent) < 0.02
            && abs(na.greenComponent - nb.greenComponent) < 0.02
            && abs(na.blueComponent - nb.blueComponent) < 0.02
    }
}

/// 工具条图标按钮：选中态强调色、悬停浅底、禁用态降透明度；带 tooltip
private struct ToolbarIconButton: View {
    let symbol: String
    var selected: Bool = false
    var enabled: Bool = true
    let help: String
    let action: () -> Void
    @Stored private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(enabled ? 0.85 : 0.35))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16)
                              : (hovering ? Color.primary.opacity(0.07) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(selected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
        .disabled(!enabled)
    }
}


// MARK: - 自定义颜色（替换系统 ColorPicker 在工具条里被拉宽的问题）

/// 一个彩虹圆点：点击打开系统取色面板，回调所选颜色。
private struct ColorWellButton: View {
    let current: NSColor
    let onPick: (Color) -> Void

    var body: some View {
        Button {
            ColorPanelBridge.shared.present(current: current) { ns in
                onPick(Color(nsColor: ns))
            }
        } label: {
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red]),
                    center: .center))
                .frame(width: 15, height: 15)
                .overlay(Circle().stroke(Color.primary.opacity(0.22), lineWidth: 0.8))
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("自定义颜色…")
    }
}

/// NSColorPanel 桥（单例持有 target，避免面板 action 丢失）
private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func present(current: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = current
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}
