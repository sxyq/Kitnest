import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图编辑器文档视图

/// 编辑器 DocumentView（原作 LongScreenshotEditorDocumentView）：
/// 初始居中且尺寸钳制——size = min(请求尺寸, scrollView 可视尺寸)，
/// 超限时 setFrameSize 后 setFrameOrigin((fw-vw)/2, (fh-vh)/2)（spec 15 §3④，0x10044cdbc-0x10044ce74）。
final class LongScreenshotEditorDocumentView: NSView {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
        // 请求尺寸 = 图像点尺寸（72dpi 基准）
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: image.width, height: image.height)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
    }

    /// 钳制到容器可视尺寸并居中（对齐原作居中/钳制逻辑）
    func fitCentered(in containerSize: NSSize) {
        let requested = NSSize(width: image.width, height: image.height)
        var size = requested
        var clamped = false
        if size.width > containerSize.width {
            size.width = containerSize.width
            clamped = true
        }
        if size.height > containerSize.height {
            size.height = containerSize.height
            clamped = true
        }
        if clamped {
            setFrameSize(size)
        }
        if containerSize.width > size.width || containerSize.height > size.height {
            let x = (containerSize.width - size.width) / 2
            let y = (containerSize.height - size.height) / 2
            setFrameOrigin(NSPoint(x: max(0, x), y: max(0, y)))
        }
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
        // DocumentView 初始居中 + 钳制（0x10044cdbc）
        scrollView.document?.fitCentered(in: scrollView.contentSize)
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
        // 2026-10-18：窗口按图像尺寸自适应（旧实现固定 880×640 / 内容 640×480，长截图显得很小）。
        // 取图像点尺寸（Retina 2x → ÷2）+ 工具条 48 + 边距，钳制到屏幕可视区 85%，下限 760×560。
        let img = document.image
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let docW = CGFloat(img.width) / 2
        let docH = CGFloat(img.height) / 2
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
