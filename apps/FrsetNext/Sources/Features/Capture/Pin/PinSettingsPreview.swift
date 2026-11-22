import AppKit
import SwiftUI

/// 固定图像数据仅在内存生成；钉图、图帘共用，不采集桌面。
enum CapturePreviewImage {
    static let image: CGImage = {
        let image = NSImage(size: NSSize(width: 640, height: 384), flipped: false) { rect in
            NSColor(white: 0.98, alpha: 1).setFill()
            rect.fill()
            NSColor(white: 0.92, alpha: 1).setFill()
            NSRect(x: 0, y: 338, width: 640, height: 46).fill()
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(20 + index * 22), y: 355, width: 12, height: 12)).fill()
            }
            ("Kitnest · 周五计划" as NSString).draw(at: NSPoint(x: 28, y: 279),
                withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                                 .foregroundColor: NSColor(white: 0.16, alpha: 1)])
            for (index, text) in ["整理设计素材", "确认页面布局", "导出完成的作品"].enumerated() {
                (text as NSString).draw(at: NSPoint(x: 30, y: CGFloat(222 - index * 49)),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 18),
                                     .foregroundColor: NSColor(white: 0.4, alpha: 1)])
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }()
}

/// 仅拥有场景内的位置和计时；图像、按钮、气泡使用正式组件。
final class PinPreviewScene: NSView {
    private let imageView: PinImageView
    private let toolbar = PinToolbarView()
    private let closeButton = PinCloseButton()
    private let status = NSTextField(labelWithString: "")
    private var bubble: PinBubbleView?
    private let interactive: Bool
    private var pinAppearance = PinAppearance.defaults
    private var offset = NSPoint.zero
    private var scale: CGFloat = 1
    private var dragOrigin: NSPoint?
    private var dragOffset = NSPoint.zero
    private var hideTask: Task<Void, Never>?
    private var toolbarHovered = false

    init(interactive: Bool) {
        self.interactive = interactive
        imageView = PinImageView(image: CapturePreviewImage.image, frame: .zero, appearance: .defaults)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityElement(interactive)
        setAccessibilityRole(.group)
        setAccessibilityLabel("钉图预览：方向键移动，加减缩放，0 复位，回车显示控制条")
        imageView.wantsLayer = true
        addSubview(imageView)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        addSubview(status)
        if interactive {
            addSubview(toolbar)
            addSubview(closeButton)
            toolbar.onAnnotate = { [weak self] in self?.feedback("标注演示：不打开编辑器") }
            toolbar.onCopy = { [weak self] in self?.feedback("拷贝演示：不写剪贴板") }
            toolbar.onMore = { [weak self] in
                guard let self else { return }
                self.scale = self.scale == 1 ? 0.8 : 1
                self.needsLayout = true
                self.feedback("更多演示：切换场景缩放")
            }
            toolbar.onResetZoom = { [weak self] in self?.setScale(1) }
            toolbar.onGripDown = { [weak self] in self?.mouseDown(with: $0) }
            toolbar.onGripDrag = { [weak self] in self?.mouseDragged(with: $0) }
            toolbar.onHoverChange = { [weak self] inside in
                self?.toolbarHovered = inside
                if inside { self?.showChrome() }
            }
            toolbar.onBubble = { [weak self] model, _ in self?.showBubble(model) }
            closeButton.onClick = { [weak self] in
                self?.stop()
                self?.imageView.isHidden = true
                self?.toolbar.isHidden = true
                self?.closeButton.isHidden = true
                self?.feedback("已在场景内关闭；移入场景重新显示")
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    override var acceptsFirstResponder: Bool { interactive }
    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }
    override func becomeFirstResponder() -> Bool {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        return true
    }
    override func resignFirstResponder() -> Bool { layer?.borderWidth = 0; return true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: offset.x -= 8
        case 124: offset.x += 8
        case 125: offset.y -= 8
        case 126: offset.y += 8
        case 24, 69: setScale(min(1.15, scale + 0.05)); return
        case 27, 78: setScale(max(0.55, scale - 0.05)); return
        case 29, 82: offset = .zero; setScale(1); return
        case 36: showChrome(); return
        case 53: toolbar.isHidden = true; closeButton.isHidden = true; showBubble(nil); return
        default: super.keyDown(with: event); return
        }
        needsLayout = true
        showChrome()
        feedback(pinAppearance.magnet ? "方向键移动 · 边缘自动吸附" : "方向键移动 · 吸附已关闭")
    }

    func update(appearance: PinAppearance, reduceTransparency: Bool) {
        let changed = self.pinAppearance != appearance
        self.pinAppearance = appearance
        toolbar.reduceTransparency = reduceTransparency
        toolbar.needsDisplay = true
        imageView.pinAppearance = appearance
        imageView.needsDisplay = true
        imageView.layer?.shadowColor = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = appearance.shadow ? 0.3 : 0
        imageView.layer?.shadowRadius = 10
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // 只改变演示的合成透明度，不改草稿数值。
        imageView.alphaValue = 1
        if changed, interactive { showChrome() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let available = bounds.insetBy(dx: interactive ? 14 : 12, dy: interactive ? 24 : 12)
        let width = min(360, min(available.width, available.height / 0.6)) * scale
        let size = NSSize(width: width, height: width * 0.6)
        var origin = NSPoint(x: bounds.midX - size.width / 2 + offset.x,
                             y: bounds.midY - size.height / 2 + offset.y)
        let visible = bounds.insetBy(dx: 8, dy: 8)
        origin.x = min(max(visible.minX, origin.x), visible.maxX - size.width)
        origin.y = min(max(visible.minY, origin.y), visible.maxY - size.height)
        if pinAppearance.magnet, offset != .zero {
            origin = PinMagnet.snapped(origin: origin, size: size, visible: visible, others: [])
        }
        let imageFrame = NSRect(origin: origin, size: size)
        imageView.frame = imageFrame
        imageView.layer?.shadowPath = CGPath(roundedRect: imageView.bounds,
            cornerWidth: CGFloat(pinAppearance.cornerRadius), cornerHeight: CGFloat(pinAppearance.cornerRadius), transform: nil)
        toolbar.frame = NSRect(x: imageView.frame.midX - PinToolbarView.barWidth / 2,
            y: imageView.frame.minY + 10, width: PinToolbarView.barWidth, height: PinToolbarView.Metrics.height)
        toolbar.updateZoom(percent: Int((scale * 100).rounded()))
        closeButton.frame = NSRect(x: imageView.frame.minX + 8, y: imageView.frame.maxY - 26, width: 18, height: 18)
        status.frame = NSRect(x: 8, y: 4, width: bounds.width - 16, height: 16)
        if let bubble {
            bubble.frame.origin = NSPoint(x: bounds.midX - bubble.frame.width / 2, y: toolbar.frame.maxY + 4)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactive else { return nil }
        let hit = super.hitTest(point)
        return hit === imageView || hit === status ? self : hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        if interactive {
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        imageView.isHidden = false
        showChrome()
    }
    override func mouseMoved(with event: NSEvent) { showChrome() }
    override func mouseExited(with event: NSEvent) {
        hideTask?.cancel()
        toolbar.isHidden = true
        closeButton.isHidden = true
        showBubble(nil)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { setScale(1); return }
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragOffset = offset
        showChrome()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset = NSPoint(x: dragOffset.x + point.x - start.x, y: dragOffset.y + point.y - start.y)
        needsLayout = true
        feedback(pinAppearance.magnet ? "拖动：距边缘 8 pt 自动吸附" : "拖动：自动吸附已关闭")
    }
    override func scrollWheel(with event: NSEvent) {
        setScale(min(1.15, max(0.55, scale - event.scrollingDeltaY / 150)))
    }
    override func magnify(with event: NSEvent) {
        setScale(min(1.15, max(0.55, scale + event.magnification)))
    }
    private func setScale(_ value: CGFloat) {
        scale = value
        needsLayout = true
        feedback("缩放 \(Int((scale * 100).rounded()))%")
        showChrome()
    }
    private func feedback(_ text: String) { status.stringValue = text }
    private func showBubble(_ model: PinBubbleModel?) {
        bubble?.removeFromSuperview()
        bubble = model.map { PinBubbleView(model: $0) }
        if let bubble { addSubview(bubble) }
        needsLayout = true
    }
    private func showChrome() {
        toolbar.isHidden = false
        closeButton.isHidden = false
        hideTask?.cancel()
        guard pinAppearance.chromeAutoHide > 0 else { return }
        let seconds = pinAppearance.chromeAutoHide
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard let self, !self.toolbarHovered else { return }
            self.toolbar.isHidden = true
            self.closeButton.isHidden = true
            self.showBubble(nil)
            self.feedback("静止 \(seconds) 秒：控制条已收起")
        }
    }
    func stop() {
        hideTask?.cancel()
        imageView.layer?.removeAllAnimations()
        showBubble(nil)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
}
