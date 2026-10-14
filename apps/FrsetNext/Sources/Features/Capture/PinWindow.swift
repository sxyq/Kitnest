import AppKit
import CoreGraphics

// MARK: - 屏幕钉图

/// 钉图内容视图：显示图片，支持拖动移动、滚轮缩放、悬停出现关闭按钮
final class PinImageView: NSView {
    private let image: CGImage
    private let aspect: CGFloat
    var onClose: (() -> Void)?

    private var isHovering = false
    private var dragWindowOrigin: NSPoint?
    private var dragMouseOrigin: NSPoint?

    /// 关闭按钮区域（右上角，视图坐标）
    private var closeButtonRect: NSRect {
        NSRect(x: bounds.maxX - 24, y: bounds.maxY - 24, width: 18, height: 18)
    }

    init(image: CGImage, frame frameRect: NSRect) {
        self.image = image
        self.aspect = CGFloat(image.width) / max(CGFloat(image.height), 1)
        super.init(frame: frameRect)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { false }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let path = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)

        // 边框
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()

        // 悬停时右上角显示关闭按钮
        if isHovering {
            let r = closeButtonRect
            ctx.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.85))
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(1.6)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: r.minX + 5, y: r.minY + 5))
            ctx.addLine(to: CGPoint(x: r.maxX - 5, y: r.maxY - 5))
            ctx.move(to: CGPoint(x: r.maxX - 5, y: r.minY + 5))
            ctx.addLine(to: CGPoint(x: r.minX + 5, y: r.maxY - 5))
            ctx.strokePath()
        }
    }

    // MARK: 交互

    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent)  { isHovering = false; needsDisplay = true }

    /// 鼠标全局位置 = 窗口原点 + locationInWindow（borderless 窗口无标题栏偏移）
    private func globalMouse(_ event: NSEvent) -> NSPoint? {
        guard let window = window else { return nil }
        return NSPoint(x: window.frame.origin.x + event.locationInWindow.x,
                       y: window.frame.origin.y + event.locationInWindow.y)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHovering, closeButtonRect.contains(point) { onClose?(); return }
        dragWindowOrigin = window?.frame.origin
        dragMouseOrigin = globalMouse(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window,
              let mouse0 = dragMouseOrigin,
              let origin0 = dragWindowOrigin,
              let mouse1 = globalMouse(event) else { return }
        window.setFrameOrigin(NSPoint(x: origin0.x + mouse1.x - mouse0.x,
                                      y: origin0.y + mouse1.y - mouse0.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragWindowOrigin = nil
        dragMouseOrigin = nil
    }

    /// 滚轮缩放（以窗口中心为锚点）
    override func scrollWheel(with event: NSEvent) {
        guard let window = window else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let factor: CGFloat = delta > 0 ? 1.05 : 1 / 1.05
        let frame = window.frame
        var width = frame.width * factor
        width = max(80, min(width, 3200))
        let height = width / max(aspect, 0.0001)
        let dx = (frame.width - width) / 2
        let dy = (frame.height - height) / 2
        window.setFrame(NSRect(x: frame.minX + dx, y: frame.minY + dy, width: width, height: height), display: true)
        needsDisplay = true
    }

    /// 右键关闭
    override func rightMouseDown(with event: NSEvent) { onClose?() }
}

// MARK: - 钉图窗口

/// 无边框浮动面板：始终在最上层
final class PinWindow: NSPanel {
    init(image: CGImage, origin: NSPoint) {
        let maxSide: CGFloat = 720
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: max(w * scale, 60), height: max(h * scale, 60))
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = PinImageView(image: image, frame: NSRect(origin: .zero, size: size))
        view.onClose = { [weak self] in self?.close() }
        self.contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 钉图控制器

/// 管理所有钉图窗口（Esc 一键关闭全部）
public final class PinWindowController: NSObject {
    public static let shared = PinWindowController()

    private var windows: [PinWindow] = []
    private var keyMonitor: Any?

    private override init() { super.init() }

    /// 把一张图钉到屏幕中央（可指定左上角位置）
    @discardableResult
    public func show(image: CGImage, at origin: NSPoint? = nil) -> Bool {
        let count = windows.count
        // 多张钉图错位平铺，避免完全重叠
        let offset = CGFloat(count % 6) * 24
        let position = origin ?? NSPoint(x: 160 + offset, y: 160 + offset)
        let window = PinWindow(image: image, origin: position)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        installKeyMonitor()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: window)
        return true
    }

    /// 把图片文件钉到屏幕上
    @discardableResult
    public func show(url: URL) -> Bool {
        guard let image = ImageProcessor.cgImage(from: url) else { return false }
        return show(image: image)
    }

    /// 关闭全部钉图
    public func closeAll() {
        for window in windows { window.close() }
        windows.removeAll()
        removeKeyMonitor()
    }

    // MARK: 私有

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 = Esc
            if event.keyCode == 53 { self?.closeAll(); return nil }
            return event
        }
    }

    private func removeKeyMonitor() {
        guard let monitor = keyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        keyMonitor = nil
    }

    @objc private func windowDidClose(_ note: Notification) {
        guard let window = note.object as? PinWindow else { return }
        windows.removeAll { $0 === window }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        if windows.isEmpty { removeKeyMonitor() }
    }
}
