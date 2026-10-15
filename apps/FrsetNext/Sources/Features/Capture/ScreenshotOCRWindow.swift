import AppKit
import CoreGraphics

// MARK: - 原文 / 结果文本视图

/// 原文文本视图：可选中、默认不可编辑（对应原作 `SourceNSTextView`）。
final class SourceNSTextView: NSTextView {
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        font = .systemFont(ofSize: 12)
        textContainerInset = NSSize(width: 6, height: 6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
}

/// 原文滚动容器（对应原作 `ScreenshotOCRSourceScrollView`）：
/// 默认展示原文图片；来源为文本时可切换成 `SourceNSTextView`。
final class ScreenshotOCRSourceScrollView: NSScrollView {
    private let imageView = NSImageView()
    private let textView = SourceNSTextView(frame: .zero, textContainer: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        borderType = .noBorder
        drawsBackground = false
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    /// 展示原文图片（按其像素尺寸铺满文档区，可滚动查看细节）
    func setImage(_ image: CGImage) {
        let nsImage = ImageProcessor.nsImage(image)
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 0, y: 0, width: max(image.width, 1), height: max(image.height, 1))
        documentView = imageView
    }

    /// 展示原文文本
    func setSourceText(_ text: String) {
        textView.configureInside(self)
        textView.string = text
        documentView = textView
    }
}

/// 文本视图放进滚动视图的常规配置（宽度跟随、纵向自适应）
private extension NSTextView {
    func configureInside(_ scrollView: NSScrollView) {
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: scrollView.contentSize.width,
                                              height: .greatestFiniteMagnitude)
        frame = NSRect(origin: .zero, size: scrollView.contentSize)
    }
}

/// 识别结果滚动容器（对应原作 `OCRReadOnlyScrollView`）：只读、可选中复制。
final class OCRReadOnlyScrollView: NSScrollView {
    let textView = SourceNSTextView(frame: .zero, textContainer: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        borderType = .noBorder
        drawsBackground = false
        autohidesScrollers = true
        textView.isEditable = false       // 只读，符合「识别结果」定位
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.configureInside(self)
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.scrollToBeginningOfDocument(nil)
        }
    }
}

// MARK: - OCR 结果窗

/// OCR 结果窗（对应原作 `ScreenshotOCRResultWindow`）：左「原文图」/ 右「识别文本」，底部操作条。
final class ScreenshotOCRResultWindow: NSWindow {
    private let sourceScroll = ScreenshotOCRSourceScrollView(frame: .zero)
    private let resultScroll = OCRReadOnlyScrollView(frame: .zero)

    var onCopy: (() -> Void)?
    var onReRecognize: (() -> Void)?

    init(sourceImage: CGImage, text: String) {
        let size = NSSize(width: 760, height: 480)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "识别结果"
        minSize = NSSize(width: 480, height: 320)
        isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]

        // 左右分栏
        let split = NSSplitView(frame: NSRect(x: 0, y: 44, width: size.width, height: size.height - 44))
        split.isVertical = true
        split.dividerStyle = .thin
        split.arrangesAllSubviews = true
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(labelled("原文", content: sourceScroll))
        split.addArrangedSubview(labelled("识别文本", content: resultScroll))
        container.addSubview(split)

        sourceScroll.setImage(sourceImage)
        resultScroll.text = text

        // 底部操作条
        let bottom = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: 44))
        bottom.autoresizingMask = [.width, .maxYMargin]

        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyTapped))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: size.width - 210, y: 8, width: 80, height: 28)
        copyButton.autoresizingMask = [.minXMargin]

        let redoButton = NSButton(title: "重新识别", target: self, action: #selector(redoWrapped))
        redoButton.bezelStyle = .rounded
        redoButton.frame = NSRect(x: size.width - 122, y: 8, width: 100, height: 28)
        redoButton.autoresizingMask = [.minXMargin]

        bottom.addSubview(copyButton)
        bottom.addSubview(redoButton)
        container.addSubview(bottom)

        contentView = container
    }

    /// 给滚动视图套一个带标题的容器
    private func labelled(_ title: String, content: NSView) -> NSView {
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        holder.autoresizingMask = [.width, .height]
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 8, y: 380, width: 200, height: 16)
        label.autoresizingMask = [.width, .minYMargin]
        content.frame = NSRect(x: 0, y: 0, width: 380, height: 374)
        content.autoresizingMask = [.width, .height]
        holder.addSubview(content)
        holder.addSubview(label)
        return holder
    }

    // MARK: 状态

    /// 当前（可能被用户就地修改过的）识别文本
    var resultText: String { resultScroll.text }
    func setResultText(_ text: String) { resultScroll.text = text }

    // MARK: 动作

    @objc private func copyTapped() { onCopy?() }
    @objc private func redoWrapped() { onReRecognize?() }
}

// MARK: - OCR 结果窗控制器

/// 结果窗管理（对应原作 `ScreenshotOCRWindowController` / `ResultWindowDelegate`）：
/// 持有源图与图片数据，负责复制、重新识别、窗口生命周期。
public final class ScreenshotOCRWindowController: NSObject, NSWindowDelegate {
    public static let shared = ScreenshotOCRWindowController()

    private var window: ScreenshotOCRResultWindow?
    private var sourceImage: CGImage?
    private var imageData: Data?
    private var isRecognizing = false

    private override init() { super.init() }

    /// 展示识别结果窗
    public func show(sourceImage: CGImage, imageData: Data, text: String) {
        self.sourceImage = sourceImage
        self.imageData = imageData
        if let existing = window {
            existing.setResultText(text)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = ScreenshotOCRResultWindow(sourceImage: sourceImage, text: text)
        win.delegate = self
        win.onCopy = { [weak self] in self?.copyResult() }
        win.onReRecognize = { [weak self] in self?.reRecognize() }
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.close()
        window = nil
    }

    // MARK: 动作

    private func copyResult() {
        guard let text = window?.resultText, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        CaptureEventBus.onTextRecognized?(text)
    }

    private func reRecognize() {
        guard !isRecognizing, let data = imageData else { return }
        isRecognizing = true
        Task { @MainActor in
            defer { self.isRecognizing = false }
            do {
                let text = try await OCRService.shared.recognizeText(imageData: data)
                // spec 13 §4：未读取到文字场景（0x10000d45c，重新识别为空）
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
                    return
                }
                self.window?.setResultText(text)
                CaptureEventBus.onTextRecognized?(text)
            } catch {
                Toast.show("文字识别失败", icon: "exclamationmark.circle.fill")   // spec 13 §4：OCR 失败场景
                Log.error("Capture", "重新识别失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? ScreenshotOCRResultWindow) === window { window = nil }
    }
}
