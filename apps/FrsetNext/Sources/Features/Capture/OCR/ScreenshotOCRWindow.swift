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
    /// v166.6：同 OCRReadOnlyScrollView —— 传 nil 会得到没有 textStorage 的空壳
    private let textView: SourceNSTextView = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 1,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        return SourceNSTextView(frame: .zero, textContainer: container)
    }()

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
        // v166.6：不能直接用 contentSize —— init 阶段滚动视图还是 0×0，
        // 会把这个视图钉死成 0 宽（文字排不出来）。真实宽度由 layout()/setText 补齐。
        textContainer?.containerSize = NSSize(width: max(scrollView.contentSize.width, 1),
                                              height: .greatestFiniteMagnitude)
        frame = NSRect(origin: .zero,
                       size: NSSize(width: max(scrollView.contentSize.width, 1),
                                    height: max(scrollView.contentSize.height, 1)))
    }
}

/// 识别结果滚动容器（对应原作 `OCRReadOnlyScrollView`）：只读、可选中复制。
final class OCRReadOnlyScrollView: NSScrollView {
    /// v166.6（用户：「点击后没有展现识别后的结果」）——**这就是根因**。
    ///
    /// 原来写成 `SourceNSTextView(frame: .zero, textContainer: nil)`。传 nil 时
    /// AppKit 不会替你建文本系统：`textStorage` / `layoutManager` 全是 nil，
    /// 于是 `textStorage?.setAttributedString(...)` 是**静默空操作**——
    /// 识别成功、窗口弹出、剪贴板也有内容，但右栏永远是一片空白。
    /// 这里显式搭一套 storage → layoutManager → container。
    let textView: SourceNSTextView = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 1,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return SourceNSTextView(frame: .zero, textContainer: container)
    }()

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

    // MARK: 流式呈现（v175）

    /// 正在"打字"时的完整文本（`text` 的 getter 要返回它，否则复制/翻译会拿到半截）
    private var streamFull = ""
    private var streamCursor = 0
    private var streamTimer: Timer?

    private var isStreaming: Bool { streamTimer != nil }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
         .foregroundColor: NSColor.labelColor]
    }

    var text: String {
        get { isStreaming ? streamFull : textView.string }
        set {
            cancelStream()
            streamFull = newValue
            applyAttributed(newValue)
        }
    }

    /// 逐段"打"出文本：OCR 结果 / 译文不再整块闪现。
    ///
    /// 速度按长度自适应（总时长约 0.8–1.2s），短文本每帧 2 字、长文本按比例提速；
    /// 期间只追加纯文本（每帧做一次链接检测太贵），打完后统一补 `.link` 属性。
    func stream(_ fullText: String) {
        cancelStream()
        streamFull = fullText
        streamCursor = 0
        applyAttributed("")
        let ns = fullText as NSString
        let total = ns.length
        guard total > 0 else { return }

        let step = max(2, Int(ceil(Double(total) / 72.0)))   // 72 帧 ≈ 1.2s
        let attributes = baseAttributes
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let remain = total - self.streamCursor
            guard remain > 0 else { self.finishStream(); return }
            let len = min(step, remain)
            let chunk = ns.substring(with: NSRange(location: self.streamCursor, length: len))
            self.streamCursor += len
            self.textView.textStorage?.append(
                NSAttributedString(string: chunk, attributes: attributes))
            if self.streamCursor >= total { self.finishStream() }
        }
        RunLoop.main.add(timer, forMode: .common)
        streamTimer = timer
    }

    func cancelStream() {
        streamTimer?.invalidate()
        streamTimer = nil
    }

    private func finishStream() {
        cancelStream()
        applyLinks()          // 打完了才做一次链接识别
        syncTextViewWidth()
    }

    private func applyAttributed(_ string: String) {
        // v151：识别出的网址做成可点击链接（用户拿 OCR 就是为了打开/复制链接）。
        // 只加 .link 属性，文本本身不变；复制仍然是纯文本。
        let attributed = NSMutableAttributedString(string: string, attributes: baseAttributes)
        textView.textStorage?.setAttributedString(attributed)
        applyLinks()
        syncTextViewWidth()      // v166.6：宽度必须在这里补一次，否则排版宽度为 0
        textView.scrollToBeginningOfDocument(nil)
    }

    private func applyLinks() {
        guard let storage = textView.textStorage else { return }
        let string = storage.string
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard full.length > 0 else { return }
        storage.removeAttribute(.link, range: full)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        detector.enumerateMatches(in: string, options: [], range: full) { result, _, _ in
            guard let result, let url = result.url else { return }
            storage.addAttribute(.link, value: url, range: result.range)
        }
    }

    /// v166.6（用户：「点击后没有展现识别后的结果」）：
    /// 文本视图的宽度此前只在 `configureInside`（init 阶段）用 `scrollView.contentSize` 定过，
    /// 而那一刻滚动视图还是 0×0 —— 于是 textView 宽度恒为 0，
    /// `widthTracksTextView = true` 又把 textContainer 宽度锁到 0，
    /// 结果文本**确实写进了 textStorage，但一个字都排不出来**（右栏一片空白）。
    /// 这里在每次设值 + 每次布局时按真实内容区宽度补齐。
    private func syncTextViewWidth() {
        let w = contentSize.width
        let h = contentSize.height
        guard w > 1, h > 1 else { return }
        var f = textView.frame
        f.size.width = w
        if f.size.height < h { f.size.height = h }
        if textView.frame != f { textView.frame = f }
        textView.textContainer?.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
    }

    override func layout() {
        super.layout()
        syncTextViewWidth()
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
    /// v139：译文页（第三个页签）——OCR 原文旁边直接给译文，不用再走「屏幕翻译」钉图
    private let translatedScroll = OCRReadOnlyScrollView(frame: .zero)
    /// 右栏页签切换（0 = 识别文本，1 = 二维码，2 = 翻译）
    private let tabControl = NSSegmentedControl(labels: ["识别文本", "二维码", "翻译"],
                                                trackingMode: .selectOne, target: nil, action: nil)
    private let rightPane = NSView()
    private let rightPaneLabel = NSTextField(labelWithString: "识别文本")

    var onCopy: (() -> Void)?
    var onReRecognize: (() -> Void)?
    /// v139：切到「翻译」页签/点翻译按钮时请求译文（由控制器发起，避免窗口自己依赖 AI 模块）
    var onTranslate: (() -> Void)?

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
        // v175：首次展示也走流式（短文本 0.3s 内打完，不会有"卡一下"的观感）
        if text.isEmpty { resultScroll.text = text } else { resultScroll.stream(text) }
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

        tabControl.frame = NSRect(x: 12, y: 10, width: 200, height: 24)
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.selectedSegment = 0
        tabControl.autoresizingMask = [.maxXMargin]
        bottom.addSubview(tabControl)

        // v166.8：底部给一个**看得见**的关闭按钮。
        // 左上角那个自绘圆形钮在静态状态是浅灰圆，压在同色灰底上几乎不可见
        // （用户实际反馈「没有方式去关闭」），不能只靠它。
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeTapped))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"      // Esc
        closeButton.frame = NSRect(x: size.width - 76, y: 8, width: 64, height: 28)
        closeButton.autoresizingMask = [.minXMargin]

        let copyButton = NSButton(title: "复制", target: self, action: #selector(copyTapped))
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: size.width - 240, y: 8, width: 64, height: 28)
        copyButton.autoresizingMask = [.minXMargin]

        let redoButton = NSButton(title: "重新识别", target: self, action: #selector(redoWrapped))
        redoButton.bezelStyle = .rounded
        redoButton.frame = NSRect(x: size.width - 172, y: 8, width: 92, height: 28)
        redoButton.autoresizingMask = [.minXMargin]

        bottom.addSubview(copyButton)
        bottom.addSubview(redoButton)
        bottom.addSubview(closeButton)
        container.addSubview(bottom)

        contentView = container
        // v166.8（用户：「这个弹窗没有方式去关闭」）：
        // 上面 `applyOfficialChrome()` 是在**替换 contentView 之前**调用的，
        // 圆形关闭钮被挂到了旧的默认 contentView 上，第 237 行换掉 contentView 后
        // 它就跟着旧视图消失了 —— 系统红绿灯又已被隐藏，于是窗口看起来完全没法关。
        // 换成自定义 contentView 之后必须重挂一次。
        attachOfficialRoundCloseButton()
    }

    /// Esc 关闭（结果窗没有系统红绿灯，键盘是最快的退出方式）
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    /// 右栏页签内容布局（识别文本 / 二维码 重叠切换）
    private func setupRightPane() {
        resultScroll.frame = NSRect(x: 0, y: 0, width: 380, height: 374)
        resultScroll.autoresizingMask = [.width, .height]
        translatedScroll.frame = NSRect(x: 0, y: 0, width: 380, height: 374)
        translatedScroll.autoresizingMask = [.width, .height]
        translatedScroll.isHidden = true
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
        rightPane.addSubview(translatedScroll)
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
    func setResultText(_ text: String) {
        // v175：重新识别／增量更新同样用流式，保持一致的观感
        if text.isEmpty { resultScroll.text = text } else { resultScroll.stream(text) }
    }

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
        let index = sender.selectedSegment
        resultScroll.isHidden = index != 0
        qrScroll.isHidden = index != 1
        translatedScroll.isHidden = index != 2
        rightPaneLabel.stringValue = index == 1 ? "二维码" : (index == 2 ? "翻译" : "识别文本")
        if index == 2 { onTranslate?() }
    }

    /// 选中「翻译」页签（外部入口用）
    func selectTranslateTab() {
        tabControl.selectedSegment = 2
        tabChanged(tabControl)
    }

    /// 译文文本（nil → 显示占位提示）
    func setTranslatedText(_ text: String?) {
        if let text {
            // v175：译文也逐段出现（译文通常有几百字，整块闪现很突兀）
            translatedScroll.stream(text)
        } else {
            translatedScroll.text = "翻译中…"
        }
    }

    var translatedText: String { translatedScroll.text }

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
    @objc private func closeTapped() { performClose(nil) }
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
    // v139：翻译状态 + 失焦自动关闭
    private var translated: String?
    private var isTranslating = false
    private var resignObserver: NSObjectProtocol?

    private override init() { super.init() }

    /// 展示识别结果窗（v130⑤：text/qrPayloads 为空表示对应页签无内容；已有窗口时只增量更新，
    /// 不用空文本覆盖已有 OCR 结果）
    public func show(sourceImage: CGImage, imageData: Data, text: String,
                     qrPayloads: [String] = [], selectQR: Bool = false,
                     autoTranslate: Bool = false) {
        self.sourceImage = sourceImage
        self.imageData = imageData
        if !text.isEmpty { translated = nil }   // 新文本 → 旧译文作废
        if let existing = window {
            if !text.isEmpty { existing.setResultText(text) }
            if !qrPayloads.isEmpty { existing.setQRPayloads(qrPayloads) }
            if selectQR { existing.selectQRTab(true) }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if autoTranslate { existing.selectTranslateTab() }
            return
        }
        let win = ScreenshotOCRResultWindow(sourceImage: sourceImage, text: text, qrPayloads: qrPayloads)
        win.delegate = self
        win.onCopy = { [weak self] in self?.copyResult() }
        win.onReRecognize = { [weak self] in self?.reRecognize() }
        win.onTranslate = { [weak self] in self?.translateCurrentText() }
        window = win
        // v166.6（用户：「点击后没有展现识别后的结果」）：
        // **取消「失焦即关」**。这条规则是 v139 为了「点别处要消失」加的，但它把
        // 「用户还没看到」和「用户看完了」当成同一件事 —— OCR 要跑几秒，
        // 这期间窗口一旦被任何东西抢走键盘焦点（切 app、脚本、输入法、系统弹窗），
        // 窗口就在 0.45+1.5 秒内自杀，用户只能看到「点了没反应」。
        // 结果窗是用户主动要看的产物，改成和预览窗一致：留着，直到用户自己关。
        if selectQR { win.selectQRTab(true) }
        win.center()
        // v166.6：**先激活、再成为 key**。反过来的话 app 不在前台时窗口拿不到 key，
        // 立刻触发上面的失焦规则，表现为「识别完了但什么都没弹出来」。
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        if autoTranslate { win.selectTranslateTab() }
        Log.info("Capture", "识别结果窗：已弹出（\(text.count) 字符，imageData=\(imageData.count)B, key=\(win.isKeyWindow), appActive=\(NSApp.isActive)）")
    }

    // MARK: 翻译（v139：结果窗第三个页签）

    private func translateCurrentText() {
        guard !isTranslating, let win = window else { return }
        let text = win.resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            Toast.show("没有可翻译的文字", icon: "exclamationmark.circle.fill")
            return
        }
        if let cached = translated, !cached.isEmpty {
            win.setTranslatedText(cached)   // 已有译文，直接复用
            return
        }
        isTranslating = true
        win.setTranslatedText(nil)          // 「翻译中…」
        Task { @MainActor in
            defer { self.isTranslating = false }
            do {
                let result = try await TranslationToolSession.shared.translateDocument(text)
                self.translated = result
                self.window?.setTranslatedText(result)
                Log.info("Capture", "截图翻译完成：\(text.count) 字符 → \(result.count) 字符")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.window?.setTranslatedText("翻译失败：\(message)")
                Toast.show("翻译失败：\(message)", icon: "exclamationmark.triangle", isWarning: true)
                Log.error("Capture", "截图翻译失败: \(error.localizedDescription)")
            }
        }
    }

    /// 排障用（v175）：`probe.ocrDemo=YES` 时用示例文本开一次结果窗，
    /// 用来核对「流式输出」到底有没有逐段出现（面板窗截不到，这个窗能截）。
    public func debugDemo() {
        let size = NSSize(width: 360, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.black
        ]
        ("OCR 流式输出示例\n第二行文字\n第三行文字" as NSString)
            .draw(in: NSRect(x: 16, y: 16, width: 320, height: 140), withAttributes: attrs)
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = image.tiffRepresentation else { return }

        let sample = """
        流式输出用于验证：这段文字应当逐段出现，而不是一次性整块闪出。
        第一段：识别结果窗右侧的文本框会按帧追加字符，总时长约 1.2 秒。
        第二段：译文页签同样走流式，等 AI 返回后再逐段铺开。
        第三段：https://www.swift.org 这样的链接会在打完之后变成可点击。
        """
        show(sourceImage: cg, imageData: data, text: sample)
    }

    public func close() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
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
                let text = try await OCRService.shared.recognizeText(imageData: data, quality: .thorough)
                // spec 13 §4：未读取到文字场景（0x10000d45c，重新识别为空）
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
                    return
                }
                self.window?.setResultText(text)
                self.translated = nil
                CaptureEventBus.onTextRecognized?(text)
            } catch {
                Toast.show("文字识别失败", icon: "exclamationmark.circle.fill")   // spec 13 §4：OCR 失败场景
                Log.error("Capture", "重新识别失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? ScreenshotOCRResultWindow) === window {
            window = nil
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
        }
    }
}
