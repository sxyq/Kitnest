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

/// OCR 结果窗（对应原作 `ScreenshotOCRResultWindow`）：左「原文图」/ 右「识别文本 | 二维码」，底部操作条。
/// v130（SnowShot 对齐）⑤：右栏加「二维码」页签——截图自动识码命中时展示
/// 「识别到 N 个二维码」+ 每条 payload（点击打开链接 / 复制），与 OCR 文本合并同一面板。
final class ScreenshotOCRResultWindow: NSWindow {
    private let sourceScroll = ScreenshotOCRSourceScrollView(frame: .zero)
    private let resultScroll = OCRReadOnlyScrollView(frame: .zero)
    /// v130⑤：二维码页签内容（payload 列表）
    private let qrScroll = NSScrollView()
    private let qrStack = NSStackView()
    private var qrPayloads: [String] = []
    /// 右栏页签切换（0 = 识别文本，1 = 二维码）
    private let tabControl = NSSegmentedControl(labels: ["识别文本", "二维码"],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private let rightPane = NSView()
    private let rightPaneLabel = NSTextField(labelWithString: "识别文本")

    var onCopy: (() -> Void)?
    var onReRecognize: (() -> Void)?

    init(sourceImage: CGImage, text: String, qrPayloads: [String] = []) {
        let size = NSSize(width: 760, height: 480)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "识别结果"
        applyOfficialChrome()   // 官方外观：灰底 + 透明标题栏
        minSize = NSSize(width: 480, height: 320)
        isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]

        // 右栏容器：识别文本 / 二维码 两页签同位切换
        setupRightPane()
        resultScroll.text = text
        setQRPayloads(qrPayloads)

        // 左右分栏
        let split = NSSplitView(frame: NSRect(x: 0, y: 44, width: size.width, height: size.height - 44))
        split.isVertical = true
        split.dividerStyle = .thin
        split.arrangesAllSubviews = true
        split.autoresizingMask = [.width, .height]
        split.addArrangedSubview(labelled("原文", content: sourceScroll))
        split.addArrangedSubview(labelledRightPane())
        container.addSubview(split)

        sourceScroll.setImage(sourceImage)

        // 底部操作条
        let bottom = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: 44))
        bottom.autoresizingMask = [.width, .maxYMargin]

        tabControl.frame = NSRect(x: 12, y: 10, width: 190, height: 24)
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.selectedSegment = 0
        tabControl.autoresizingMask = [.maxXMargin]
        bottom.addSubview(tabControl)

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

    /// 右栏页签内容布局（识别文本 / 二维码 重叠切换）
    private func setupRightPane() {
        resultScroll.frame = NSRect(x: 0, y: 0, width: 380, height: 374)
        resultScroll.autoresizingMask = [.width, .height]
        qrScroll.frame = NSRect(x: 0, y: 0, width: 380, height: 374)
        qrScroll.autoresizingMask = [.width, .height]
        qrScroll.hasVerticalScroller = true
        qrScroll.borderType = .noBorder
        qrScroll.drawsBackground = false
        qrScroll.autohidesScrollers = true

        qrStack.orientation = .vertical
        qrStack.alignment = .leading
        qrStack.spacing = 8
        qrStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        qrStack.translatesAutoresizingMaskIntoConstraints = false
        qrScroll.documentView = qrStack
        // 宽度跟随滚动视图内容区，高度自适应（autolayout 文档视图）
        NSLayoutConstraint.activate([
            qrStack.widthAnchor.constraint(equalTo: qrScroll.contentView.widthAnchor),
        ])

        qrScroll.isHidden = true
        rightPane.frame = NSRect(x: 0, y: 0, width: 380, height: 374)
        rightPane.autoresizingMask = [.width, .height]
        rightPane.addSubview(resultScroll)
        rightPane.addSubview(qrScroll)
    }

    /// 右栏容器套标题（标题随页签切换改名）
    private func labelledRightPane() -> NSView {
        rightPaneLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        rightPaneLabel.textColor = .secondaryLabelColor
        rightPaneLabel.frame = NSRect(x: 8, y: 380, width: 200, height: 16)
        rightPaneLabel.autoresizingMask = [.width, .minYMargin]
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        holder.autoresizingMask = [.width, .height]
        holder.addSubview(rightPane)
        holder.addSubview(rightPaneLabel)
        return holder
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

    // MARK: v130（SnowShot 对齐）⑤：二维码页签

    /// 更新二维码 payload 并刷新页签标题（「二维码(N)」）
    func setQRPayloads(_ payloads: [String]) {
        qrPayloads = payloads
        rebuildQRRows()
        tabControl.setLabel(payloads.isEmpty ? "二维码" : "二维码(\(payloads.count))", forSegment: 1)
    }

    /// 选中二维码页签（识码命中自动跳转）
    func selectQRTab(_ qr: Bool) {
        tabControl.selectedSegment = qr && !qrPayloads.isEmpty ? 1 : 0
        tabChanged(tabControl)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        let qr = sender.selectedSegment == 1
        resultScroll.isHidden = qr
        qrScroll.isHidden = !qr
        rightPaneLabel.stringValue = qr ? "二维码" : "识别文本"
    }

    private func rebuildQRRows() {
        qrStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if qrPayloads.isEmpty {
            let empty = NSTextField(labelWithString: "未识别到二维码/条码")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            qrStack.addArrangedSubview(empty)
            return
        }
        let header = NSTextField(labelWithString: "识别到 \(qrPayloads.count) 个二维码")
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        qrStack.addArrangedSubview(header)
        for (i, payload) in qrPayloads.enumerated() {
            qrStack.addArrangedSubview(qrRow(payload, index: i))
        }
    }

    private func qrRow(_ payload: String, index: Int) -> NSView {
        let text = NSTextField(labelWithString: payload)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.lineBreakMode = .byTruncatingMiddle
        text.isSelectable = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let copy = NSButton(title: "复制", target: self, action: #selector(copyQR(_:)))
        copy.bezelStyle = .rounded
        copy.tag = index
        copy.controlSize = .small

        var views: [NSView] = [text, copy]
        if let url = URL(string: payload), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            let open = NSButton(title: "打开", target: self, action: #selector(openQR(_:)))
            open.bezelStyle = .rounded
            open.tag = index
            open.controlSize = .small
            views.append(open)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.distribution = .fill
        text.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return row
    }

    @objc private func copyQR(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < qrPayloads.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(qrPayloads[sender.tag], forType: .string)
        Toast.show("二维码内容已复制", icon: "checkmark.circle.fill")
    }

    @objc private func openQR(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < qrPayloads.count,
              let url = URL(string: qrPayloads[sender.tag]) else { return }
        if !NSWorkspace.shared.open(url) {
            Toast.show("无法打开链接", icon: "exclamationmark.circle.fill")
        }
    }

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

    /// 展示识别结果窗（v130⑤：text/qrPayloads 为空表示对应页签无内容；已有窗口时只增量更新，
    /// 不用空文本覆盖已有 OCR 结果）
    public func show(sourceImage: CGImage, imageData: Data, text: String,
                     qrPayloads: [String] = [], selectQR: Bool = false) {
        self.sourceImage = sourceImage
        self.imageData = imageData
        if let existing = window {
            if !text.isEmpty { existing.setResultText(text) }
            if !qrPayloads.isEmpty { existing.setQRPayloads(qrPayloads) }
            if selectQR { existing.selectQRTab(true) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = ScreenshotOCRResultWindow(sourceImage: sourceImage, text: text, qrPayloads: qrPayloads)
        win.delegate = self
        win.onCopy = { [weak self] in self?.copyResult() }
        win.onReRecognize = { [weak self] in self?.reRecognize() }
        window = win
        if selectQR { win.selectQRTab(true) }
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
