import AppKit
import CoreGraphics

// MARK: - 截图态按键监视器

/// 截图进行中监听 Esc / Delete / 右键：任一触发即放弃本次截图。
/// 用本地监视器而不是窗口 keyDown，是因为覆盖层是 borderless 窗口，
/// 在部分场景下（输入法、其它 App 抢焦点）不一定能拿到 keyDown。
final class DeleteKeyMonitor {
    private var monitor: Any?
    private let handler: (NSEvent) -> Bool

    /// - Parameter handler: 返回 true 表示事件已被消费（不再向下传递）
    init(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            return self.handler(event) ? nil : event
        }
    }

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    }
}

// MARK: - 放大镜

/// 像素级放大镜：把屏幕快照的一小块按整数倍放大显示（关闭插值，保留硬边像素）
final class ScreenshotMagnifierView: NSView {
    var snapshot: CGImage?
    /// 采样点（快照像素坐标，左上原点）
    var samplePoint: CGPoint = .zero
    /// 放大倍数
    var zoom: CGFloat = 8

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext, let image = snapshot, zoom > 0 else { return }

        ctx.interpolationQuality = .none
        // 源区域：以采样点为中心的一块正方形（单位：快照像素）
        let side = bounds.width / zoom
        let src = CGRect(x: samplePoint.x - side / 2,
                         y: samplePoint.y - side / 2,
                         width: side, height: side)
        let clamped = src.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !clamped.isNull, !clamped.isEmpty, let piece = image.cropping(to: clamped) {
            // 把裁剪出来的区域映射回放大区域的正确位置（边缘越界时留白）
            let dest = CGRect(x: (clamped.minX - src.minX) / side * bounds.width,
                              y: (clamped.minY - src.minY) / side * bounds.height,
                              width: clamped.width / side * bounds.width,
                              height: clamped.height / side * bounds.height)
            ctx.draw(piece, in: dest)
        }

        // 中心十字（对准当前采样的那个像素）
        let cx = bounds.midX, cy = bounds.midY
        ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx - 6, y: cy)); ctx.addLine(to: CGPoint(x: cx + 6, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - 6)); ctx.addLine(to: CGPoint(x: cx, y: cy + 6))
        ctx.strokePath()
    }
}

/// 放大镜外框：圆角 + 白边 + 阴影，负责跟随光标定位
final class ScreenshotMagnifierContainerView: NSView {
    let magnifierView = ScreenshotMagnifierView()
    private let inset: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(magnifierView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        magnifierView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    /// 把放大镜放到光标附近（贴边时自动翻到另一侧），并更新采样内容
    func follow(pointInView point: NSPoint, viewSize: NSSize, snapshot: CGImage?) {
        magnifierView.snapshot = snapshot
        if let snapshot = snapshot {
            let sx = CGFloat(snapshot.width) / max(viewSize.width, 1)
            let sy = CGFloat(snapshot.height) / max(viewSize.height, 1)
            // 视图坐标（左下原点）→ 快照像素坐标（左上原点）
            magnifierView.samplePoint = CGPoint(x: point.x * sx, y: (viewSize.height - point.y) * sy)
        }

        let size = frame.size
        var origin = NSPoint(x: point.x + 18, y: point.y + 18)
        if origin.x + size.width > viewSize.width { origin.x = point.x - 18 - size.width }
        if origin.y + size.height > viewSize.height { origin.y = point.y - 18 - size.height }
        origin.x = max(0, min(origin.x, viewSize.width - size.width))
        origin.y = max(0, min(origin.y, viewSize.height - size.height))
        frame = NSRect(origin: origin, size: size)
        magnifierView.needsDisplay = true
    }
}

// MARK: - 覆盖层视图

/// 全屏覆盖层：拖拽选区 + 尺寸标签 + 十字准星 + 放大镜
final class ScreenshotOverlayView: NSView {
    /// 选区确认回调，参数是视图内矩形（左下原点，点坐标）
    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// 该屏幕的快照（用于放大镜与最终裁剪，可为 nil → 放大镜隐藏）
    var snapshot: CGImage?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let magnifier = ScreenshotMagnifierContainerView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
    private var keyMonitor: DeleteKeyMonitor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        magnifier.isHidden = true
        addSubview(magnifier)
        keyMonitor = DeleteKeyMonitor { [weak self] event in
            guard let self = self else { return false }
            if event.type == .rightMouseDown { self.onCancel?(); return true }
            // 53 = Esc，51 = Delete
            if event.keyCode == 53 || event.keyCode == 51 { self.onCancel?(); return true }
            return false
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var acceptsFirstResponder: Bool { true }

    /// 当前选区（拖拽过程中实时计算）
    private var selectionRect: CGRect? {
        guard let a = startPoint, let b = currentPoint else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        magnifier.isHidden = snapshot == nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
        if let p = currentPoint {
            magnifier.follow(pointInView: p, viewSize: bounds.size, snapshot: snapshot)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard startPoint == nil else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        if let p = currentPoint {
            magnifier.isHidden = snapshot == nil
            magnifier.follow(pointInView: p, viewSize: bounds.size, snapshot: snapshot)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect else {
            onCancel?()
            return
        }
        magnifier.isHidden = true
        // 太小的选区视为误点，直接放弃
        guard rect.width >= 4, rect.height >= 4 else {
            onCancel?()
            return
        }
        onCommit?(rect)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor(calibratedWhite: 0, alpha: 0.35)

        if let rect = selectionRect {
            // v109（2026-10-21 用户：「第一次拉伸十分卡顿、没反应要第二次」）：
            // 全屏 evenOdd 路径填充在每次拖拽重绘都遍历 7.6M 像素——
            // 照录屏覆盖层 v62 方案改「选区外 4 个矩形」压暗，成本降到边框级。
            let r = rect.intersection(bounds)
            dim.setFill()
            NSRect(x: bounds.minX, y: bounds.minY,
                   width: bounds.width, height: max(0, r.minY - bounds.minY)).fill()
            NSRect(x: bounds.minX, y: r.maxY,
                   width: bounds.width, height: max(0, bounds.maxY - r.maxY)).fill()
            NSRect(x: bounds.minX, y: r.minY,
                   width: max(0, r.minX - bounds.minX), height: r.height).fill()
            NSRect(x: r.maxX, y: r.minY,
                   width: max(0, bounds.maxX - r.maxX), height: r.height).fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1
            border.stroke()

            drawHandles(rect)
            drawSizeLabel(rect)
        } else {
            dim.setFill()
            bounds.fill()
        }

        if let p = currentPoint { drawCrosshair(p) }
    }

    /// 四角小方块把手
    private func drawHandles(_ rect: CGRect) {
        let s: CGFloat = 5
        NSColor.white.setFill()
        for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.minY),
                       (rect.minX, rect.maxY), (rect.maxX, rect.maxY)] {
            NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s).fill()
        }
    }

    /// 尺寸标签：显示 W × H，贴选区左上角，越界时自动翻到下方/左侧
    private func drawSizeLabel(_ rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        let boxW = size.width + 12
        let boxH: CGFloat = 20

        var x = rect.minX
        var y = rect.maxY + 6
        if y + boxH > bounds.maxY { y = rect.minY - boxH - 6 }
        x = max(0, min(x, bounds.maxX - boxW))
        y = max(0, min(y, bounds.maxY - boxH))

        let box = NSRect(x: x, y: y, width: boxW, height: boxH)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: x + 6, y: y + 3), withAttributes: attrs)
    }

    /// 十字准星（贯穿全屏的虚线）
    private func drawCrosshair(_ point: NSPoint) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: point.y))
        path.line(to: NSPoint(x: bounds.maxX, y: point.y))
        path.move(to: NSPoint(x: point.x, y: bounds.minY))
        path.line(to: NSPoint(x: point.x, y: bounds.maxY))
        NSColor(white: 1, alpha: 0.55).setStroke()
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
        path.setLineDash(nil, count: 0, phase: 0)
    }
}

// MARK: - 覆盖层窗口

/// 每个屏幕一个覆盖层窗口：无边框、置顶（screenSaver 级）、透明背景
final class ScreenshotOverlayWindow: NSWindow {
    let overlayView: ScreenshotOverlayView

    init(screen: NSScreen, snapshot: CGImage?) {
        self.overlayView = ScreenshotOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = overlayView
        overlayView.snapshot = snapshot
    }

    /// borderless 窗口默认不接受键盘，这里放开以便响应 Esc
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
