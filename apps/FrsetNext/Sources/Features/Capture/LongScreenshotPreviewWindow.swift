import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图编辑器文档视图

/// 编辑器 DocumentView（原作 LongScreenshotEditorDocumentView）：
/// 初始居中且尺寸钳制——size = min(请求尺寸, scrollView 可视尺寸)，
/// 超限时 setFrameSize 后 setFrameOrigin((fw-vw)/2, (fh-vh)/2)（spec 15 §3④，0x10044cdbc-0x10044ce74）。
final class LongScreenshotEditorDocumentView: NSView {
    let image: CGImage
    /// 图片在文档视图内的绘制矩形（水平居中；宽度不足容器时两侧留白）
    private var imageRect: NSRect = .zero

    init(image: CGImage) {
        self.image = image
        // 请求尺寸 = 图像点尺寸（72dpi 基准）
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: image.width, height: image.height)))
        imageRect = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: imageRect)
    }

    /// 按容器宽度等比缩放（v150 修复「预览里也被拉扁 / 一打开是空白」）
    ///
    /// 关键：**不要改 documentView.frame.origin**。NSClipView 会按 bounds.origin 再偏移
    /// 一次，两边都设等于偏移算两遍——实测 dirtyRect 落在图片之外，整窗空白。
    /// 现在文档宽度至少铺满容器、图片在文档内水平居中，origin 恒为 (0,0)，
    /// 竖向位置完全交给 clipView.scroll(to:)。
    func fitCentered(in containerSize: NSSize) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, containerSize.width > 0, containerSize.height > 0 else { return }
        let scale = min(1, containerSize.width / iw)
        let drawW = max(1, (iw * scale).rounded())
        let drawH = max(1, (ih * scale).rounded())
        let docW = max(containerSize.width, drawW)
        setFrameSize(NSSize(width: docW, height: drawH))
        setFrameOrigin(.zero)
        imageRect = NSRect(x: ((docW - drawW) / 2).rounded(), y: 0, width: drawW, height: drawH)
        needsDisplay = true
    }
}

// MARK: - 编辑器滚动视图 / 容器视图

/// 滚动视图封装（原作 LongScreenshotImageScrollView / LongScreenshotEditorScrollView，
/// 均有 init(coder:) fatalError 骨架 0x10044c060）
final class LongScreenshotImageScrollView: NSScrollView {
    init(document: LongScreenshotEditorDocumentView) {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        allowsMagnification = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = document
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    var document: LongScreenshotEditorDocumentView? { documentView as? LongScreenshotEditorDocumentView }
}

/// 编辑器容器（原作 LongScreenshotEditorContainerView）：滚动视图 + 底部工具条
///
/// 2026-10-18 重写布局（用户反馈"提示窗太小"）：
///   旧实现内容区固定 640×480 且不随窗口缩放——窗口 880×640 里内容只占一角，
///   长截图预览显得很小。现在：
///   · scrollView 撑满工具条以上全部区域（autoresizing + layout 双保险）
///   · 工具条贴底、按钮靠右随宽度重排
///   · 窗口尺寸由窗口侧按图像尺寸钳制到屏幕可视区（见 LongScreenshotEditorWindow.init）
final class LongScreenshotEditorContainerView: NSView {
    let scrollView: LongScreenshotImageScrollView
    private let toolbar = NSView(frame: .zero)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private static let toolbarHeight: CGFloat = 48
    private static let buttonW: CGFloat = 76
    private static let buttonH: CGFloat = 30
    /// 只定位一次：之后用户滚动/改窗口大小时不要把人拉回顶部
    private var didPositionInitially = false

    init(document: LongScreenshotEditorDocumentView,
         onSave: @escaping () -> Void,
         onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        scrollView = LongScreenshotImageScrollView(document: document)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 960, height: 700)))
        autoresizingMask = [.width, .height]

        scrollView.frame = bounds.insetBy(dx: 0, dy: 0)
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        for (btn, action) in [(saveButton, onSave), (copyButton, onCopy), (closeButton, onClose)] {
            btn.bezelStyle = .rounded
            btn.autoresizingMask = [.minXMargin]
            ClosureButtonAction.bind(btn, handler: action)
            toolbar.addSubview(btn)
        }
        saveButton.keyEquivalent = "\r"
        toolbar.autoresizingMask = [.width, .minYMargin]
        addSubview(toolbar)
        layoutEditor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        layoutEditor()
        // DocumentView 按容器宽度等比缩放（0x10044cdbc）
        scrollView.document?.fitCentered(in: scrollView.contentSize)
        // 首次显示滚到顶部：NSClipView 会忽略 documentView.frame.origin 的负值，
        // 必须通过 clipView.scroll(to:) 定位，否则长图一打开停在**底部**（页脚）。
        // 注意：首次 layout 时 clipView 尺寸可能还是 0——此时算出的 maxY = 文档高，
        // 会把可视区滚到图片**上方**（全白空白）。必须等尺寸就绪再定位。
        if !didPositionInitially, let doc = scrollView.document {
            let clip = scrollView.contentView
            if clip.bounds.height > 1, doc.frame.height > 1 {
                didPositionInitially = true
                let maxY = max(0, doc.frame.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: 0, y: maxY))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    private func layoutEditor() {
        let bar = Self.toolbarHeight
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bar)
        scrollView.frame = NSRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))

        let w = Self.buttonW, h = Self.buttonH, y = (bar - h) / 2
        var x = bounds.width - 16 - w
        closeButton.frame = NSRect(x: x, y: y, width: w, height: h)
        x -= (w + 10)
        copyButton.frame = NSRect(x: x, y: y, width: w, height: h)
        x -= (w + 10)
        saveButton.frame = NSRect(x: x, y: y, width: w, height: h)
    }
}

/// target-action → 闭包 的轻量桥接（编辑器工具条按钮用）
final class ClosureButtonAction: NSObject {
    private let handler: () -> Void
    private init(handler: @escaping () -> Void) { self.handler = handler }

    static func bind(_ button: NSButton, handler: @escaping () -> Void) {
        let target = ClosureButtonAction(handler: handler)
        button.target = target
        button.action = #selector(fire(_:))
        objc_setAssociatedObject(button, "frset.closureAction", target, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc private func fire(_ sender: NSButton?) { handler() }
}

// MARK: - 编辑器窗口 / 控制器

/// 编辑窗（原作 LongScreenshotEditorWindow + LongScreenshotEditorWindowController）
final class LongScreenshotEditorWindow: NSWindow {
    init(document: LongScreenshotEditorDocumentView,
         onSave: @escaping () -> Void,
         onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        let container = LongScreenshotEditorContainerView(document: document,
                                                          onSave: onSave,
                                                          onCopy: onCopy,
                                                          onClose: onClose)
        // 窗口按图像像素宽自适应（旧实现固定 ÷2 假设 Retina，1x 屏上会显得很小），
        // 钳制到屏幕可视区 85%；内容区再按宽度等比缩放（见 fitCentered）。
        let img = document.image
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let docW = CGFloat(img.width)
        let docH = CGFloat(img.height)
        let wantW = min(max(docW + 48, 760), screen.width * 0.85)
        let wantH = min(max(docH + 48 + 56, 560), screen.height * 0.85)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: wantW, height: wantH)),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "长截图"
        applyOfficialChrome()   // 官方外观：灰底 + 透明标题栏
        minSize = NSSize(width: 640, height: 460)
        isReleasedWhenClosed = false
        contentView = container
        // v166.8：同 ScreenshotOCRResultWindow —— 换 contentView 后重挂自绘关闭钮
        attachOfficialRoundCloseButton()
        center()
    }
}

/// 预览/编辑器入口（原作 LongScreenshotPreviewController）：
/// 会话收尾产物进入这里（spec 15 §3④：DocumentView 居中、钳制到可视区）。
final class LongScreenshotPreviewController: NSObject, NSWindowDelegate {
    static let shared = LongScreenshotPreviewController()

    private var window: LongScreenshotEditorWindow?

    private override init() { super.init() }

    func show(image: CGImage) {
        window?.close()
        let document = LongScreenshotEditorDocumentView(image: image)
        let editor = LongScreenshotEditorWindow(
            document: document,
            onSave: { [weak self] in
                guard let self = self, let doc = self.window?.contentView as? LongScreenshotEditorContainerView,
                      let image = doc.scrollView.document?.image,
                      let data = ImageProcessor.pngData(image),
                      let url = ScreenshotManager.shared.savePNG(data) else { return }
                ScreenshotManager.shared.registerCaptured(url: url, data: data, playSound: true, mode: "long")   // v130②
            },
            onCopy: { [weak self] in
                guard let self = self, let doc = self.window?.contentView as? LongScreenshotEditorContainerView,
                      let image = doc.scrollView.document?.image else { return }
                ScreenshotManager.shared.copyToPasteboard(image)
            },
            onClose: { [weak self] in self?.window?.performClose(nil) })
        editor.delegate = self
        window = editor
        editor.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? LongScreenshotEditorWindow) === window { window = nil }
    }
}

// MARK: - 采集中实时预览卡（v176）

/// 长截图采集中，选区旁边一张小卡片：随画布增长实时变大。
///
/// 原版（Frset 长截图）在滚动采集时右侧就有这么一张预览，用户能一边滚一边确认
/// 「截到哪儿了」。我们此前只有采集结束后的编辑器，过程中只有一个高度数字。
///
/// 实现要点：
/// - 面板 `ignoresMouseEvents`，不挡滚动、不抢焦点；
/// - 放在选区外侧（右优先，放不下放左），**不会**被截进画面；
/// - 只显示画布**顶部**一段（按宽度缩放后裁到 288pt 高），长图不会缩成细条。
final class LongScreenshotLivePreviewPanel: NSPanel {

    private final class FlippedCard: NSView {
        override var isFlipped: Bool { true }
    }

    private let card = FlippedCard()
    private let imageView = NSImageView()
    private let sizeLabel = NSTextField(labelWithString: "")

    private let padding: CGFloat = 8
    private let footerH: CGFloat = 18
    private let contentW: CGFloat = 156

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 172, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor
        card.layer?.masksToBounds = true
        contentView = card

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        card.addSubview(imageView)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.textColor = NSColor.secondaryLabelColor
        sizeLabel.alignment = .right
        card.addSubview(sizeLabel)

        let caption = NSTextField(labelWithString: "长截图")
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.textColor = NSColor.secondaryLabelColor
        card.addSubview(caption)
        self.captionLabel = caption
    }

    private var captionLabel: NSTextField!

    /// 更新预览（`selection` 是 AppKit 坐标下的选区，用来定位）
    func update(image: CGImage, near selection: NSRect) {
        let scale = contentW / CGFloat(max(1, image.width))
        let maxImageH: CGFloat = 288
        let visibleSrcH = max(1, min(CGFloat(image.height),
                                     (maxImageH / max(scale, 0.0001)).rounded()))
        let cropRect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: visibleSrcH)
        let cropped = image.cropping(to: cropRect) ?? image
        imageView.image = NSImage(cgImage: cropped,
                                  size: NSSize(width: cropRect.width, height: cropRect.height))

        let displayH = max(24, (visibleSrcH * scale).rounded())
        let cardW = contentW + padding * 2
        let cardH = displayH + footerH + padding * 2

        setContentSize(NSSize(width: cardW, height: cardH))
        imageView.frame = NSRect(x: padding, y: padding, width: contentW, height: displayH)
        captionLabel.frame = NSRect(x: padding, y: padding + displayH + 1,
                                    width: 60, height: 13)
        sizeLabel.frame = NSRect(x: cardW - padding - 90, y: padding + displayH + 1,
                                 width: 90, height: 13)
        sizeLabel.stringValue = "\(image.width)×\(image.height)"

        place(near: selection)
        if !isVisible { orderFrontRegardless() }
    }

    /// 排障（v176）：不跑真实会话，直接渲染一张长图到预览卡上，用来核对样式与位置
    static var debugInstance: LongScreenshotLivePreviewPanel?

    static func debugShow(image: CGImage, near selection: NSRect) {
        let panel = LongScreenshotLivePreviewPanel()
        debugInstance = panel
        panel.update(image: image, near: selection)
        Log.info("Capture", "排障：长截图预览卡已显示（\(image.width)×\(image.height)）")
    }

    /// 选区外侧（右优先），顶边与选区对齐；放不下就翻到左侧
    private func place(near selection: NSRect) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = frame.size
        var x = selection.maxX + 16
        if x + size.width > vf.maxX - 8 { x = selection.minX - size.width - 16 }
        if x < vf.minX + 8 { x = vf.minX + 8 }
        var y = selection.maxY - size.height
        if y < vf.minY + 8 { y = vf.minY + 8 }
        if y + size.height > vf.maxY - 8 { y = vf.maxY - size.height - 8 }
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
