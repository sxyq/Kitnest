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
final class LongScreenshotEditorContainerView: NSView {
    let scrollView: LongScreenshotImageScrollView
    private let toolbar = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 44))

    init(document: LongScreenshotEditorDocumentView,
         onSave: @escaping () -> Void,
         onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        scrollView = LongScreenshotImageScrollView(document: document)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 640, height: 480)))

        scrollView.frame = NSRect(x: 0, y: 44, width: 640, height: 436)
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        let save = NSButton(title: "保存", target: nil, action: nil)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 640 - 232, y: 8, width: 72, height: 28)
        save.autoresizingMask = [.minXMargin]
        let copy = NSButton(title: "复制", target: nil, action: nil)
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: 640 - 156, y: 8, width: 72, height: 28)
        copy.autoresizingMask = [.minXMargin]
        let close = NSButton(title: "关闭", target: nil, action: nil)
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 640 - 80, y: 8, width: 72, height: 28)
        close.autoresizingMask = [.minXMargin]

        // 目标-动作桥接（NSButton 无 onAction，用闭包包装器）
        ClosureButtonAction.bind(save) { onSave() }
        ClosureButtonAction.bind(copy) { onCopy() }
        ClosureButtonAction.bind(close) { onClose() }

        toolbar.frame = NSRect(x: 0, y: 0, width: 640, height: 44)
        toolbar.autoresizingMask = [.width]
        toolbar.addSubview(save)
        toolbar.addSubview(copy)
        toolbar.addSubview(close)
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        // DocumentView 初始居中 + 钳制（0x10044cdbc）
        scrollView.document?.fitCentered(in: scrollView.contentSize)
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
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: 880, height: 640)),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "长截图"
        minSize = NSSize(width: 480, height: 360)
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
                ScreenshotManager.shared.registerCaptured(url: url, data: data, playSound: true)
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
