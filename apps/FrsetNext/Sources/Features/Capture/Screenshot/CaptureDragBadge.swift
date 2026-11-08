import AppKit
import CoreGraphics

// MARK: - 拖拽角标（v264 · 1Capture「截图后留一个可拖的载体」）
//
// 1Capture 的截图不是「存到某处再去拿」，而是截完就有一个缩略图角标，
// 直接拖进 Slack / 编辑器 / 访达。我们的图帘已经能拖，但那个是常驻形态，
// 用户得先开图帘。这个角标是**轻量补充**：不需要图帘，截完 N 秒内都在。
//
// 交互：
//   · 拖出 → 写文件 URL（public.file-url）+ PNG 数据（public.png），两个都放，
//     浏览器/聊天软件都能接；
//   · 单击 → 复制图片到剪贴板；
//   · 双击 → 在访达里显示；
//   · 到时间自动淡出，拖拽中不消失。

public final class CaptureDragBadgeController: NSObject {

    public static let shared = CaptureDragBadgeController()

    static let keyEnabled = "capture.dragBadge.enabled"
    static let keySeconds = "capture.dragBadge.seconds"

    /// v266（用户：「截图完成之后，它在右下角会出现一个预览窗，这个也需要删掉」）：
    /// 默认关。截完图不再自动弹缩略图挡住右下角；想要「拖进别的 App」的用户
    /// 仍可在 设置 → 截图与钉图 → 截图 → 截完即用 → 拖拽角标 里打开。
    public static var isEnabled: Bool {
        get { Preferences.shared.value(keyEnabled, default: false) }
        set { Preferences.shared.set(keyEnabled, newValue) }
    }

    /// 停留秒数（2–15）
    public static var seconds: Int {
        get { Preferences.shared.value(keySeconds, default: 6) }
        set { Preferences.shared.set(keySeconds, max(2, min(15, newValue))) }
    }

    private var panel: NSPanel?
    private var imageView: DragBadgeView?
    private var hideTask: Task<Void, Never>?
    private var currentURL: URL?
    private var currentImage: CGImage?

    public func show(image: CGImage, url: URL) {
        guard Self.isEnabled else { return }
        currentURL = url
        currentImage = image
        let side: CGFloat = 88
        let padding: CGFloat = 10
        let size = NSSize(width: side + padding * 2, height: side + padding * 2 + 16)

        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        panel.setContentSize(size)

        let view = imageView ?? DragBadgeView(frame: NSRect(origin: .zero, size: size))
        imageView = view
        view.controller = self
        view.thumbnail = image
        view.fileName = url.lastPathComponent
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view

        // 位置：鼠标所在屏幕右下角（避开 Dock：visibleFrame 已经扣掉 Dock 与菜单栏）
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.maxX - size.width - 24,
                                 y: visible.minY + 24)
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    /// 拖拽结束 / 用户点掉 → 立刻收
    public func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let seconds = Self.seconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(4)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    // MARK: 视图回调

    fileprivate func copyToPasteboard() {
        guard let image = currentImage else { return }
        ScreenshotManager.shared.copyToPasteboard(image)
        Toast.show("截图已复制", icon: "checkmark.circle.fill")
        dismiss()
    }

    fileprivate func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismiss()
    }

    fileprivate func beginDrag() -> NSDraggingItem? {
        guard let image = currentImage, let url = currentURL else { return nil }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(cgImage: image, size: NSSize(width: 88, height: 88))
        item.setDraggingFrame(NSRect(x: 10, y: 26, width: 88, height: 88), contents: preview)
        return item
    }

    /// 起拖后暂停倒计时（拖到一半消失会很难受）
    fileprivate func dragStarted() {
        hideTask?.cancel()
        hideTask = nil
    }

    fileprivate func dragEnded() {
        scheduleHide()
    }
}

// MARK: - 角标视图

private final class DragBadgeView: NSView, NSDraggingSource {

    weak var controller: CaptureDragBadgeController?
    var thumbnail: CGImage? { didSet { needsDisplay = true } }
    var fileName: String = ""
    private var isDragging = false
    /// 刚拖过一次：紧跟着的 mouseUp 不能再当单击（否则拖完顺手复制一张）
    private var didDrag = false
    /// 单击延迟执行，给双击留判定窗口
    private var pendingCopy: DispatchWorkItem?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let card = bounds.insetBy(dx: 1, dy: 1)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14).fill()
        ctx.restoreGState()

        let rect = NSRect(x: 10, y: 10, width: 88, height: 88)
        guard let image = thumbnail else { return }
        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        clip.addClip()
        // 等比填充 + 居中裁剪（与图帘卡片同一套算法意识：不拉伸）
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale
        let h = CGFloat(image.height) * scale
        let drawRect = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()

        let name = (fileName.isEmpty ? "截图" : fileName) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = name.size(withAttributes: attrs)
        name.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 96), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            // 双击：取消待执行的单击复制，改为在访达中显示
            pendingCopy?.cancel()
            pendingCopy = nil
            controller?.revealInFinder()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            // 拖拽结束后的 mouseUp 不是单击
            didDrag = false
            return
        }
        guard event.clickCount == 1 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.didDrag else { return }
            self.controller?.copyToPasteboard()
        }
        pendingCopy = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        pendingCopy?.cancel()
        pendingCopy = nil
        guard !isDragging, let item = controller?.beginDrag() else { return }
        isDragging = true
        controller?.dragStarted()
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 跨 App 是 copy；本 App 内也 copy（不把角标上的东西移走）
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        controller?.dragEnded()
    }
}
