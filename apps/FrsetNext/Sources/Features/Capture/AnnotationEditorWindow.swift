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
    var tool: AnnotationTool = .rectangle
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    /// 标注变化回调（用于刷新撤销按钮可用态）
    var onChange: (() -> Void)?

    /// 撤销栈：标注追加 / 抹除前的底图快照
    private enum EditOp {
        case annotation(Annotation)
        case imageSnapshot(CGImage)
    }
    private var ops: [EditOp] = []
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
        AnnotationCompositor.draw(annotations, in: canvasRect, base: image)
        if let draft = draft { AnnotationCompositor.draw([draft], in: canvasRect, base: image) }
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
                ops.append(.annotation(a))
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
        if tool == .pen || tool == .highlighter {
            if draft == nil {
                draft = Annotation(tool: tool, points: [start],
                                   colorHex: AnnotationCompositor.hex(of: color),
                                   lineWidth: lineWidth)
            }
            draft?.points.append(ip)
        } else {
            draft = Annotation(tool: tool, points: [start, ip],
                               colorHex: AnnotationCompositor.hex(of: color),
                               lineWidth: lineWidth)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
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
        if tool == .pen || tool == .highlighter {
            var a = draft ?? Annotation(tool: tool, points: [start],
                                        colorHex: AnnotationCompositor.hex(of: color),
                                        lineWidth: lineWidth)
            a.points.append(ip)
            finished = a
        } else {
            finished = Annotation(tool: tool, points: [start, ip],
                                  colorHex: AnnotationCompositor.hex(of: color),
                                  lineWidth: lineWidth)
        }
        if let a = finished, isValid(a) {
            annotations.append(a)
            ops.append(.annotation(a))
            onChange?()
        }
    }

    // MARK: 物体抹除（eSearch removeObj 对齐）

    /// 抹除笔刷半径（细/中/粗 → 16/32/64 直径）
    var brushRadius: CGFloat { lineWidth * 4 }

    /// 橡皮：删除命中点处的一个标注（从后往前找第一个命中）。
    /// v71：进撤销栈（此前橡皮删除不可撤销）；滑动时每个命中图元各占一条撤销记录。
    private func eraseAt(_ ip: CGPoint) {
        guard let index = annotations.lastIndex(where: { hitTest($0, at: ip) }) else { return }
        let victim = annotations.remove(at: index)
        ops.append(.annotation(victim))
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
        ops.append(.imageSnapshot(old))
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
            guard a.points.count >= 2 else { return false }
            return abs(a.points[0].x - a.points[1].x) >= 4 && abs(a.points[0].y - a.points[1].y) >= 4
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

    func undo() {
        guard let op = ops.popLast() else { return }
        switch op {
        case .annotation(let a):
            annotations.removeAll { $0.id == a.id }
        case .imageSnapshot(let old):
            image = old
        }
        needsDisplay = true
        onChange?()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        annotations.removeAll()
        ops.removeAll()
        needsDisplay = true
        onChange?()
    }

    /// 合成结果（无标注则返回原图）
    func composite() -> CGImage? {
        AnnotationCompositor.composite(base: image, annotations: annotations)
    }
}

// MARK: - 标注编辑器窗口

/// 标注编辑器窗口：上方画布 + 下方工具条（工具 / 颜色 / 粗细 / 撤销 / 清空 / 复制 / 保存）
final class AnnotationEditorWindow: NSWindow {
    let canvas: AnnotationCanvasView
    /// 工具条状态（v71 SwiftUI 化后由本模型驱动选中态与撤销可用态）
    let toolbarModel = EditorToolbarModel()

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?

    init(image: CGImage) {
        let maxW: CGFloat = 960, maxH: CGFloat = 720
        let scale = min(1, min(maxW / CGFloat(image.width), maxH / CGFloat(image.height)))
        let canvasW = max(880, CGFloat(image.width) * scale)
        let canvasH = max(300, CGFloat(image.height) * scale)
        let size = NSSize(width: canvasW, height: canvasH + 44)

        canvas = AnnotationCanvasView(image: image)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "标注截图"
        applyOfficialChrome()   // 官方外观：灰底 + 透明标题栏
        minSize = NSSize(width: 880, height: 300)   // v71：工具条单行所需最小宽度
        isReleasedWhenClosed = false
        canvas.frame = NSRect(x: 0, y: 44, width: canvasW, height: canvasH)
        canvas.autoresizingMask = [.width, .height]
        canvas.onChange = { [weak self] in self?.refreshUndo() }

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = true
        container.addSubview(canvas)

        let toolbar = buildToolbar(width: canvasW)
        toolbar.frame = NSRect(x: 0, y: 0, width: canvasW, height: 44)
        toolbar.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(toolbar)
        contentView = container

        refreshUndo()
    }

    // MARK: 工具条

    private func buildToolbar(width: CGFloat) -> NSView {
        // v71（用户实障：控件重叠、橡皮处色块压字）：工具条改 SwiftUI FlowHStack
        // 自适应流式布局（Core/FlowLayout 唯一实现），控件按内容尺寸排列不再
        // 硬坐标重叠；窗口 minWidth 880 保证单行放得下。
        let host = NSHostingView(rootView: EditorToolbarView(
            model: toolbarModel,
            onTool: { [weak self] index in
                self?.canvas.tool = AnnotationTool.allCases[index]
            },
            onColor: { [weak self] color in
                self?.canvas.color = NSColor(color)
            },
            onWidth: { [weak self] index in
                self?.canvas.lineWidth = [2, 4, 8][index]
            },
            onUndo: { [weak self] in self?.undoTapped() },
            onClear: { [weak self] in self?.clearTapped() },
            onLong: { [weak self] in self?.longScreenshotTapped() },
            onCopy: { [weak self] in self?.copyTapped() },
            onSave: { [weak self] in self?.saveTapped() },
            onClose: { [weak self] in self?.closeTapped() }
        ))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 44)
        host.autoresizingMask = [.width]
        return host
    }

    private func refreshUndo() { toolbarModel.canUndo = canvas.canUndo }

    // MARK: 动作

    @objc private func undoTapped() { canvas.undo() }
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
        NSApp.activate(ignoringOtherApps: true)
        Log.info("Capture", "标注：编辑器窗口已显示（\(Int(editor.frame.width))×\(Int(editor.frame.height))）")
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? AnnotationEditorWindow) === window { window = nil }
    }
}

// MARK: - 工具条（v71：SwiftUI FlowHStack 自适应布局）

/// 工具条状态：选中态与撤销可用态（画布 onChange → refreshUndo 同步 canUndo）
final class EditorToolbarModel: ObservableObject {
    @Published var toolIndex = 0
    @Published var color: Color = .red
    @Published var widthIndex = 1
    @Published var canUndo = false
}

/// 工具条视图：控件按内容尺寸流式排列（一行放不下自动折行，不再硬坐标重叠）
private struct EditorToolbarView: View {
    @ObservedObject var model: EditorToolbarModel
    var onTool: (Int) -> Void
    var onColor: (Color) -> Void
    var onWidth: (Int) -> Void
    var onUndo: () -> Void
    var onClear: () -> Void
    var onLong: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onClose: () -> Void

    var body: some View {
        FlowHStack(spacing: 8, lineSpacing: 6) {
            Picker("", selection: Binding(
                    get: { model.toolIndex },
                    set: { model.toolIndex = $0; onTool($0) })) {
                ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.offset) { index, tool in
                    Text(tool.title).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ColorPicker("", selection: Binding(
                    get: { model.color },
                    set: { model.color = $0; onColor($0) }), supportsOpacity: false)
                .labelsHidden()
                .fixedSize()

            Picker("", selection: Binding(
                    get: { model.widthIndex },
                    set: { model.widthIndex = $0; onWidth($0) })) {
                Text("细").tag(0)
                Text("中").tag(1)
                Text("粗").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            toolbarButton("撤销", systemImage: "arrow.uturn.backward", enabled: model.canUndo, action: onUndo)
            toolbarButton("清空", systemImage: "trash", action: onClear)
            toolbarButton("长截图", systemImage: "scroll.down", action: onLong)
            Spacer(minLength: 4)
            toolbarButton("复制", systemImage: "doc.on.doc", action: onCopy)
            toolbarButton("保存", systemImage: "square.and.arrow.down", action: onSave)
            toolbarButton("关闭", systemImage: "xmark", action: onClose)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color(nsColor: OfficialChrome.windowBackground))
    }

    private func toolbarButton(_ title: String, systemImage: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .opacity(enabled ? 1 : 0.5)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
