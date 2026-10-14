import AppKit
import CoreGraphics

// MARK: - 取色器

/// 取色视图：全屏透明层，跟随光标显示放大镜与色值，点击取色并复制 HEX
final class EyedropperView: NSView {
    /// 屏幕快照（设备像素）
    private let snapshot: CGImage?
    /// 快照对应的像素缓冲（读单点颜色用）
    private let buffer: RGBABuffer?
    private var currentPoint: NSPoint?
    private var currentColor: NSColor?

    /// 取色完成（nil 表示取消）
    var onPick: ((NSColor?) -> Void)?

    init(frame frameRect: NSRect, snapshot: CGImage?) {
        self.snapshot = snapshot
        self.buffer = snapshot.flatMap { ImageProcessor.rgbaBuffer($0) }
        super.init(frame: frameRect)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 视图坐标 → 缓冲像素坐标
    private func pixel(at point: NSPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let buffer = buffer, bounds.width > 0, bounds.height > 0 else { return nil }
        let sx = CGFloat(buffer.width) / bounds.width
        let sy = CGFloat(buffer.height) / bounds.height
        let x = Int(min(max(point.x * sx, 0), CGFloat(buffer.width - 1)))
        // 视图坐标左下原点 → 缓冲左上原点
        let y = Int(min(max((bounds.height - point.y) * sy, 0), CGFloat(buffer.height - 1)))
        return buffer.colorAt(x: x, y: y)
    }

    /// (r,g,b) 0~255 → NSColor
    private func makeColor(_ rgb: (r: UInt8, g: UInt8, b: UInt8)) -> NSColor {
        let r: CGFloat = CGFloat(rgb.r) / 255
        let g: CGFloat = CGFloat(rgb.g) / 255
        let b: CGFloat = CGFloat(rgb.b) / 255
        let components: [CGFloat] = [r, g, b, 1]
        return NSColor(colorSpace: .sRGB, components: components, count: 4)
    }

    override func mouseMoved(with event: NSEvent) {
        let point: NSPoint = convert(event.locationInWindow, from: nil)
        currentPoint = point
        if let rgb = pixel(at: point) {
            currentColor = makeColor(rgb)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point: NSPoint = convert(event.locationInWindow, from: nil)
        if let rgb = pixel(at: point) {
            onPick?(makeColor(rgb))
        } else {
            onPick?(nil)
        }
    }

    /// 右键 / Esc 取消（Esc 由窗口 keyDown 处理，右键在此拦截）
    override func rightMouseDown(with event: NSEvent) { onPick?(nil) }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let point = currentPoint,
              let color = currentColor else { return }

        // 只画放大镜与色板，不做全屏压暗（否则取到的颜色不准）
        let loupeSize: CGFloat = 96
        let zoom: CGFloat = 8
        var origin = NSPoint(x: point.x + 16, y: point.y + 16)
        if origin.x + loupeSize > bounds.maxX { origin.x = point.x - 16 - loupeSize }
        if origin.y + loupeSize > bounds.maxY { origin.y = point.y - 16 - loupeSize }
        let loupe = NSRect(x: max(0, origin.x), y: max(0, origin.y), width: loupeSize, height: loupeSize)

        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.9))
        ctx.fill(loupe.insetBy(dx: -3, dy: -3))

        if let snapshot = snapshot {
            ctx.interpolationQuality = .none
            let side = loupeSize / zoom
            let sx = CGFloat(snapshot.width) / bounds.width
            let sy = CGFloat(snapshot.height) / bounds.height
            let srcCenter = CGPoint(x: point.x * sx, y: (bounds.height - point.y) * sy)
            let src = CGRect(x: srcCenter.x - side / 2, y: srcCenter.y - side / 2, width: side, height: side)
            let clamped = src.intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
            if !clamped.isNull, !clamped.isEmpty, let piece = snapshot.cropping(to: clamped) {
                let dest = CGRect(x: loupe.minX + (clamped.minX - src.minX) / side * loupeSize,
                                  y: loupe.minY + (clamped.minY - src.minY) / side * loupeSize,
                                  width: clamped.width / side * loupeSize,
                                  height: clamped.height / side * loupeSize)
                ctx.draw(piece, in: dest)
            }
        }

        // 中心十字
        ctx.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: loupe.midX - 6, y: loupe.midY))
        ctx.addLine(to: CGPoint(x: loupe.midX + 6, y: loupe.midY))
        ctx.move(to: CGPoint(x: loupe.midX, y: loupe.midY - 6))
        ctx.addLine(to: CGPoint(x: loupe.midX, y: loupe.midY + 6))
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.stroke(loupe)

        // 色值标签：#RRGGBB / R,G,B
        let text = "\(Self.hex(of: color))   \(Self.rgbText(of: color))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attrs)
        var labelY = loupe.minY - 26
        if labelY < 0 { labelY = loupe.maxY + 6 }
        let labelRect = NSRect(x: max(0, min(loupe.minX, bounds.maxX - size.width - 12)),
                               y: labelY,
                               width: size.width + 12, height: 22)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.9))
        ctx.fill(labelRect)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: labelRect.minX + 1, y: labelRect.minY + 1, width: 20, height: 20))
        text.draw(at: NSPoint(x: labelRect.minX + 24, y: labelRect.minY + 4), withAttributes: attrs)
    }

    // MARK: 色值工具

    /// HEX 字符串（#RRGGBB）
    public static func hex(of color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// "R, G, B" 文本
    public static func rgbText(of color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "0, 0, 0" }
        return "\(Int(round(rgb.redComponent * 255))), \(Int(round(rgb.greenComponent * 255))), \(Int(round(rgb.blueComponent * 255)))"
    }
}

// MARK: - 取色窗口

final class EyedropperWindow: NSWindow {
    let pickerView: EyedropperView

    init(screen: NSScreen, snapshot: CGImage?) {
        self.pickerView = EyedropperView(frame: NSRect(origin: .zero, size: screen.frame.size), snapshot: snapshot)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = pickerView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc 取消
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pickerView.onPick?(nil) }
    }
}

// MARK: - 取色器入口

/// 全屏取色：点击后把 HEX 复制到剪贴板并回写到可观察状态
public final class Eyedropper: ObservableObject {
    public static let shared = Eyedropper()

    @Published public private(set) var isPicking = false
    @Published public var hex: String = ""
    @Published public var rgbText: String = ""
    @Published public var message: String?

    private var window: EyedropperWindow?
    /// 程序化取色的挂起回调（同一时刻至多一个）
    private var pendingPick: ((String?) -> Void)?

    private init() {}

    /// 开始取色（鼠标所在屏幕）
    public func start() {
        // 手动取色会顶掉可能挂起的程序化请求，先以 nil 收尾，避免 continuation 悬挂
        resolvePending(nil)
        beginSession()
    }

    /// 程序化取色：启动一次取色会话并回调结果（供 `EyedropperPickBridge` 复用）。
    /// 无论用户取色、取消，还是无权限 / 无可用屏幕，`completion` 都**恰好被调用一次**。
    public func pickColor(completion: @escaping (String?) -> Void) {
        // 上一个请求若仍挂起，先以 nil 结束（不能让它悬挂）
        resolvePending(nil)

        guard CGPreflightScreenCaptureAccess() else {
            message = "需要「屏幕录制」权限才能取色"
            completion(nil)
            return
        }
        guard let screen = screenUnderMouse() else {
            completion(nil)
            return
        }
        finish(nil)                 // 关闭可能残留的旧窗口（内部 resolvePending 此时为 no-op）
        pendingPick = completion    // 必须在 finish 之后登记，避免被 finish 误清
        NSApp.activate(ignoringOtherApps: true)
        presentPicker(on: screen)
    }

    /// 结束取色（传 nil 表示只是关闭窗口）
    public func finish(_ color: NSColor?) {
        window?.orderOut(nil)
        window = nil
        isPicking = false
        // 兜底：任何关闭路径都不允许让 await 的调用方悬挂
        resolvePending(nil)
    }

    // MARK: 会话（手动 / 程序化共用同一套 UI 与取色逻辑）

    private func beginSession() {
        guard CGPreflightScreenCaptureAccess() else {
            message = "需要「屏幕录制」权限才能取色"
            return
        }
        guard let screen = screenUnderMouse() else { return }
        finish(nil)
        NSApp.activate(ignoringOtherApps: true)
        presentPicker(on: screen)
    }

    private func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func presentPicker(on screen: NSScreen) {
        let snapshot = ScreenSnapshot.cgCapture(screen: screen)
        let window = EyedropperWindow(screen: screen, snapshot: snapshot)
        window.pickerView.onPick = { [weak self] color in
            guard let self = self else { return }
            let hex = color.map { EyedropperView.hex(of: $0) }
            if let color = color, let hex = hex {
                self.hex = hex
                self.rgbText = EyedropperView.rgbText(of: color)
                self.copyHexToPasteboard(hex)
                CaptureEventBus.onTextRecognized?(hex)
                self.message = "已复制 \(hex)"
            } else {
                self.message = nil
            }
            // 先恢复等待者（取消 → nil），再关闭窗口（finish 内的兜底此时为 no-op）
            self.resolvePending(hex)
            self.finish(nil)
        }
        self.window = window
        isPicking = true
        window.makeKeyAndOrderFront(nil)
    }

    /// 取出并清空挂起回调，以给定值结束；无挂起时为 no-op
    private func resolvePending(_ hex: String?) {
        let pending = pendingPick
        pendingPick = nil
        pending?(hex)
    }

    /// 复制 HEX 到剪贴板
    public func copyHexToPasteboard(_ hex: String? = nil) {
        let text = hex ?? self.hex
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
