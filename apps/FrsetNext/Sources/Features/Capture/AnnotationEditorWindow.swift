import AppKit
import CoreGraphics

// MARK: - 标注画布

/// 标注画布：显示底图 + 已画标注 + 正在拖拽的草稿。
/// 视图为 flipped（左上原点），并把「图像像素坐标」通过 CTM 映射到视图坐标，
/// 因此标注坐标在整个编辑器里始终是同一套，落盘时交给 AnnotationCompositor。
final class AnnotationCanvasView: NSView {
    let image: CGImage
    /// 已确认的标注
    private(set) var annotations: [Annotation] = []
    /// 当前工具与样式
    var tool: AnnotationTool = .rectangle
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    /// 标注变化回调（用于刷新撤销按钮可用态）
    var onChange: (() -> Void)?

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
        case .eraser:
            return false
        }
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let ip = imagePoint(convert(event.locationInWindow, from: nil))

        if tool == .eraser {
            // 橡皮擦的是「标注」而不是像素：从后往前找第一个命中的图元删掉
            if let index = annotations.lastIndex(where: { hitTest($0, at: ip) }) {
                annotations.remove(at: index)
                needsDisplay = true
                onChange?()
            }
            return
        }

        if tool == .text {
            if let text = promptText(), !text.isEmpty {
                annotations.append(Annotation(tool: .text, points: [ip], text: text,
                                              colorHex: AnnotationCompositor.hex(of: color),
                                              lineWidth: lineWidth))
                needsDisplay = true
                onChange?()
            }
            return
        }
        dragStart = ip
    }

    override func mouseDragged(with event: NSEvent) {
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
            onChange?()
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
        case .mosaic:
            guard a.points.count >= 2 else { return false }
            return abs(a.points[0].x - a.points[1].x) >= 4 && abs(a.points[0].y - a.points[1].y) >= 4
        case .eraser:
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

    var canUndo: Bool { !annotations.isEmpty }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
        onChange?()
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        annotations.removeAll()
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

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?

    private let undoButton = NSButton(title: "撤销", target: nil, action: nil)

    init(image: CGImage) {
        let maxW: CGFloat = 960, maxH: CGFloat = 720
        let scale = min(1, min(maxW / CGFloat(image.width), maxH / CGFloat(image.height)))
        let canvasW = max(520, CGFloat(image.width) * scale)
        let canvasH = max(300, CGFloat(image.height) * scale)
        let size = NSSize(width: canvasW, height: canvasH + 44)

        canvas = AnnotationCanvasView(image: image)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "标注截图"
        applyOfficialChrome()   // 官方外观：灰底 + 透明标题栏
        minSize = NSSize(width: 420, height: 300)
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
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 44))

        let tools = NSSegmentedControl(labels: AnnotationTool.allCases.map { $0.title },
                                       trackingMode: .selectOne,
                                       target: self, action: #selector(toolChanged(_:)))
        tools.selectedSegment = 0
        tools.frame = NSRect(x: 10, y: 8, width: 372, height: 28)

        let colorWell = NSColorWell(frame: NSRect(x: 392, y: 8, width: 40, height: 28))
        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))

        let widths = NSSegmentedControl(labels: ["细", "中", "粗"],
                                        trackingMode: .selectOne,
                                        target: self, action: #selector(widthChanged(_:)))
        widths.selectedSegment = 1
        widths.frame = NSRect(x: 368, y: 8, width: 120, height: 28)

        undoButton.target = self
        undoButton.action = #selector(undoTapped)
        undoButton.bezelStyle = .rounded
        undoButton.frame = NSRect(x: 496, y: 8, width: 60, height: 28)

        let clearButton = NSButton(title: "清空", target: self, action: #selector(clearTapped))
        clearButton.bezelStyle = .rounded
        clearButton.frame = NSRect(x: 560, y: 8, width: 60, height: 28)

        let longButton = NSButton(title: "长截图", target: self, action: #selector(longScreenshotTapped))
        longButton.bezelStyle = .rounded
        longButton.frame = NSRect(x: width - 266, y: 8, width: 60, height: 28)
        longButton.autoresizingMask = [.minXMargin]

        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyTapped))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: width - 200, y: 8, width: 60, height: 28)
        copyButton.autoresizingMask = [.minXMargin]

        let saveButton = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: width - 134, y: 8, width: 60, height: 28)
        saveButton.autoresizingMask = [.minXMargin]

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeTapped))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: width - 68, y: 8, width: 60, height: 28)
        closeButton.autoresizingMask = [.minXMargin]

        for view in [tools, colorWell, widths, undoButton, clearButton, longButton, copyButton, saveButton, closeButton] {
            bar.addSubview(view)
        }
        return bar
    }

    private func refreshUndo() { undoButton.isEnabled = canvas.canUndo }

    // MARK: 动作

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let index = max(0, min(sender.selectedSegment, AnnotationTool.allCases.count - 1))
        canvas.tool = AnnotationTool.allCases[index]
    }

    @objc private func colorChanged(_ sender: NSColorWell) { canvas.color = sender.color }

    @objc private func widthChanged(_ sender: NSSegmentedControl) {
        canvas.lineWidth = [2, 4, 8][max(0, min(sender.selectedSegment, 2))]
    }

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
