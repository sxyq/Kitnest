import AppKit
import Foundation
import SwiftUI

// MARK: - 预览内容视图族（specs/12：MainPanelPreviewPopoverSlotHostView + PreviewPopoverView 内容态）
//
// 宿主视图挂进 NSPopover（contentViewController = NSHostingController），
// 内部按 PreviewPopoverContentModel.Kind 分态渲染：
// 文本 / 落盘长文本（异步+代际防串）/ Markdown（滚动记忆）/ JSON（截断）/ 代码（尺寸阶梯+行号）/ 图片（QR 分支）/ 文件。

// MARK: - Slot 宿主视图

/// popover 内容根视图（原作 MainPanelPreviewPopoverSlotHostView）
public struct MainPanelPreviewPopoverSlotHostView: View {
    let model: PreviewPopoverContentModel
    let onClose: (MainPanelPreviewPopoverCloseReason) -> Void

    public var body: some View {
        VStack(spacing: 0) {
            if model.showsKeyboardHint {
                hintBar
            }
            PreviewPopoverContentView(model: model)
        }
        .frame(width: contentWidth, height: contentHeight)
        .onPreviewPopoverHoverChanged { inside in
            MainPanelPreviewPopoverCoordinator.shared.popoverHoverChanged(inside)
        }
        .onExitCommand { onClose(.escape) }        // Esc 关闭
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// F6 一次性提示（文案实证 "Click or Space to preview" @0x100b43c10）
    private var hintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
            Text("Click or Space to preview · 单击或按空格预览")
                .font(.system(size: 10))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.separator)
    }

    // MARK: 尺寸（F13/F14：文本高度上限 / 图片高度上限 / 代码尺寸阶梯）

    private var contentWidth: CGFloat {
        let c = MainPanelPreviewPopoverCoordinator.shared
        if model.kind == .code {
            let lines = model.inlineText.lineCountEstimate
            if lines <= 15 { return c.codePreviewMinWidth }
            if lines <= 60 { return c.codePreviewMediumWidth }
            return c.codePreviewMaxWidth
        }
        return c.popoverWidth
    }

    private var contentHeight: CGFloat {
        let c = MainPanelPreviewPopoverCoordinator.shared
        if model.kind == .code {
            // 代码尺寸阶梯：行数 → compact / min / max 三档
            let lines = CGFloat(model.inlineText.lineCountEstimate)
            let lineHeight: CGFloat = 16          // 等宽 12pt 行高（⬜ 原作值未探明）
            let raw = lines * lineHeight + c.codePreviewContentPadding * 2
            if lines <= 15 {
                return min(c.codePreviewCompactMaxHeight, max(c.codePreviewCompactMinHeight, raw))
            }
            return min(c.codePreviewMaxHeight, max(c.codePreviewMinHeight, raw))
        }
        return model.estimatedPopoverHeight(
            maxPopoverHeight: c.maxPopoverHeight,
            imagePreviewMaxPopoverHeight: c.imagePreviewMaxPopoverHeight,
            textPreviewLoadingMinHeight: c.textPreviewLoadingMinHeight)
    }
}

// MARK: - 分态路由

public struct PreviewPopoverContentView: View {
    let model: PreviewPopoverContentModel

    public var body: some View {
        switch model.kind {
        case .text:
            PreviewTextContentView(text: model.inlineText)
        case .fileBackedText:
            PreviewFileBackedTextView(model: model)
        case .markdown:
            PreviewMarkdownTextView(model: model)
        case .json:
            PreviewJSONTextView(model: model)
        case .code:
            PreviewCodeTextView(model: model)
        case .image:
            PreviewImageView(model: model)
        case .file:
            PreviewFileView(model: model)
        }
    }
}

// MARK: - 文本基座（NSScrollView + NSTextView，支持滚动偏移恢复与上报）

struct PreviewTextViewRepresentable: NSViewRepresentable {
    var attributedText: NSAttributedString
    var monospaced: Bool = false
    var showsLineNumbers: Bool = false
    var initialScrollOffset: CGFloat? = nil
    var onScrollOffsetChanged: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        if showsLineNumbers {
            let ruler = PreviewLineNumberRulerView(textView: textView)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        textView.textStorage?.setAttributedString(attributedText)

        context.coordinator.onScroll = onScrollOffsetChanged
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(ScrollCoordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)

        if let offset = initialScrollOffset, offset > 0 {
            // Markdown/长文滚动位置恢复（F15 restore request）
            DispatchQueue.main.async {
                scrollView.contentView.bounds.origin.y = offset
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onScroll = onScrollOffsetChanged
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if context.coordinator.lastText != attributedText.string {
            context.coordinator.lastText = attributedText.string
            textView.textStorage?.setAttributedString(attributedText)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ScrollCoordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> ScrollCoordinator { ScrollCoordinator() }

    final class ScrollCoordinator: NSObject {
        var onScroll: ((CGFloat) -> Void)?
        var lastText: String?

        @objc func boundsDidChange(_ note: Notification) {
            guard let clipView = note.object as? NSClipView else { return }
            onScroll?(clipView.bounds.origin.y)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - 行号标尺（代码预览；与 05 号 CodeLineNumberRulerView 职责相邻，本类为面板侧私有实现）

final class PreviewLineNumberRulerView: NSRulerView {
    private weak var attachedTextView: NSTextView?

    init(textView: NSTextView) {
        self.attachedTextView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 28
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = attachedTextView,
              let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage,
              let container = textView.textContainer else { return }

        let content = textStorage.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        var lineNumber = content.substring(to: charRange.location)
            .components(separatedBy: "\n").count
        var charIndex = charRange.location

        while charIndex < NSMaxRange(charRange) {
            let lineRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyph = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: lineGlyph.location, effectiveRange: nil)
            let y = fragment.minY - visible.minY + textView.textContainerInset.height
            let label = NSAttributedString(string: "\(lineNumber)", attributes: attributes)
            label.draw(in: NSRect(x: 2, y: y, width: ruleThickness - 4, height: fragment.height))
            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }
}

// MARK: - 态 1：短文本

struct PreviewTextContentView: View {
    let text: String

    var body: some View {
        PreviewTextViewRepresentable(
            attributedText: NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor
                ]))
    }
}

// MARK: - 态 2：落盘长文本（F17：LoadTask + LoadGeneration 代际防串）

struct PreviewFileBackedTextView: View {
    let model: PreviewPopoverContentModel
    @Stored private var loadState: FilePreviewLoadState = .idle
    @Stored private var showIndicator = false
    @Stored private var loadGeneration = 0

    var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                // loading 占位：textPreviewLoadingMinHeight + 指示器延时显示（F13 previewLoadingIndicatorDelay）
                ZStack {
                    Color.clear
                    if showIndicator {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: MainPanelPreviewPopoverCoordinator.shared.textPreviewLoadingMinHeight)
            case .loaded(let text):
                PreviewTextViewRepresentable(
                    attributedText: NSAttributedString(
                        string: text,
                        attributes: [.font: NSFont.systemFont(ofSize: 13),
                                     .foregroundColor: NSColor.labelColor]))
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.item.dedupeKey) {
            await loadFullText()
        }
    }

    private func loadFullText() async {
        let generation = loadGeneration + 1
        loadGeneration = generation
        loadState = .loading
        showIndicator = false

        // 指示器延时：期间完成则不闪指示器
        let delay = MainPanelPreviewPopoverCoordinator.shared.previewLoadingIndicatorDelay
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard loadGeneration == generation, !Task.isCancelled else { return }
        showIndicator = true

        // 全文 IO 移出主线程（读落盘文件）
        let item = model.item
        let text = await Task.detached(priority: .userInitiated) {
            PreviewPopoverDataBridge.shared.fullText(for: item)
        }.value
        guard loadGeneration == generation, !Task.isCancelled else { return }   // 代际防串
        if text.isEmpty {
            loadState = .failed("内容为空")
        } else {
            loadState = .loaded(text)
        }
    }
}

// MARK: - 态 3：Markdown（F15：滚动位置记忆 + 恢复）

struct PreviewMarkdownTextView: View {
    let model: PreviewPopoverContentModel
    @Stored private var rendered: NSAttributedString

    init(model: PreviewPopoverContentModel) {
        self.model = model
        self._rendered = Stored(wrappedValue: Self.render(model.inlineText))
    }

    static func render(_ text: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 13)
        if let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            // 统一基字体（Markdown 解析出的属性优先保留颜色/粗细，字体尺寸归一）
            mutable.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: mutable.length))
            mutable.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                 range: NSRange(location: 0, length: mutable.length))
            return mutable
        }
        return NSAttributedString(string: text,
                                  attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
    }

    var body: some View {
        PreviewTextViewRepresentable(
            attributedText: rendered,
            initialScrollOffset: MainPanelPreviewPopoverCoordinator.shared
                .markdownScrollState(for: model.item.dedupeKey)?.scrollOffset,
            onScrollOffsetChanged: { offset in
                // 块帧表/偏移快照：重开预览回到原滚动位（P10）
                MainPanelPreviewPopoverCoordinator.shared.rememberMarkdownScroll(
                    dedupeKey: model.item.dedupeKey,
                    state: MarkdownScrollState(scrollOffset: offset))
            })
    }
}

// MARK: - 态 4：JSON（F16：资格判定 + jsonPreviewCharCap 截断）

struct PreviewJSONTextView: View {
    let model: PreviewPopoverContentModel
    @Stored private var displayText: String

    init(model: PreviewPopoverContentModel) {
        self.model = model
        self._displayText = Stored(wrappedValue: Self.prepare(model.inlineText))
    }

    static func prepare(_ raw: String) -> String {
        let cap = MainPanelPreviewPopoverCoordinator.shared.jsonPreviewCharCap
        // 先截断再尝试美化：超长 JSON 美化代价过高，失败则原样截断展示
        let truncated = raw.count > cap
            ? String(raw.prefix(cap)) + "\n…（已截断，共 \(raw.count) 字符）"
            : raw
        if let data = truncated.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let prettyData = try? JSONSerialization.data(withJSONObject: object,
                                                        options: [.prettyPrinted, .sortedKeys]),
           let pretty = String(data: prettyData, encoding: .utf8) {
            return pretty
        }
        return truncated
    }

    var body: some View {
        PreviewTextViewRepresentable(
            attributedText: NSAttributedString(
                string: displayText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]),
            monospaced: true)
    }
}

// MARK: - 态 5：代码（F14 尺寸阶梯 + 行号标尺）

struct PreviewCodeTextView: View {
    let model: PreviewPopoverContentModel

    var body: some View {
        PreviewTextViewRepresentable(
            attributedText: NSAttributedString(
                string: model.inlineText,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor
                ]),
            monospaced: true,
            showsLineNumbers: true)
    }
}

// MARK: - 态 6：图片（F12 缩略→大图重建 / F13 QR 头尾高度分支）

struct PreviewImageView: View {
    let model: PreviewPopoverContentModel
    @Stored private var thumbnail: NSImage?
    @Stored private var fullImage: NSImage?
    @Stored private var needsFullRebuild = true
    @Stored private var isQRCode = false

    private var displayImage: NSImage? { fullImage ?? thumbnail }

    /// 头尾高度分支：QR / 普通图片
    private var headerFooterHeight: CGFloat {
        let c = MainPanelPreviewPopoverCoordinator.shared
        return isQRCode
            ? c.imagePreviewHeaderFooterHeightForQRCode
            : c.imagePreviewHeaderFooterHeightForRegularImage
    }

    var body: some View {
        VStack(spacing: 0) {
            if let image = displayImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(ProgressView().controlSize(.small))
            }
            // 图片 OCR 文本区块（数据桥注入；无则不占位）
            if let ocr = PreviewPopoverDataBridge.shared.ocrText(for: model.item), !ocr.isEmpty {
                Divider().padding(.vertical, 4)
                PreviewTextViewRepresentable(
                    attributedText: NSAttributedString(
                        string: ocr,
                        attributes: [.font: NSFont.systemFont(ofSize: 11),
                                     .foregroundColor: NSColor.secondaryLabelColor]))
                    .frame(maxHeight: 120)
            }
        }
        .padding(.vertical, MainPanelPreviewPopoverCoordinator.shared.imagePreviewVerticalPaddingHeight)
        // F13 头尾高度分支：QR 图保留更大头尾高度，普通图片更紧凑
        .frame(minHeight: headerFooterHeight * 2 + MainPanelPreviewPopoverCoordinator.shared.imagePreviewVerticalPaddingHeight * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.item.dedupeKey) {
            await loadImages()
        }
    }

    @MainActor
    private func loadImages() async {
        guard let fullPath = model.item.imagePath else { return }
        let fullURL = URL(fileURLWithPath: fullPath)
        let thumbnailURL = model.item.thumbnailPath.map { URL(fileURLWithPath: $0) }
        let loader = PreviewImageLoader.shared

        // P9 步骤 1：缩略图先行
        thumbnail = await withCheckedContinuation { continuation in
            loader.loadImage(at: fullURL, thumbnailURL: thumbnailURL,
                             needsFullRebuild: false) { continuation.resume(returning: $0) }
        }

        // P9 步骤 2：previewNeedsFullRebuild → 大图重建
        let full = await withCheckedContinuation { continuation in
            loader.loadImage(at: fullURL, thumbnailURL: thumbnailURL,
                             needsFullRebuild: needsFullRebuild) { continuation.resume(returning: $0) }
        }
        if let full, !Task.isCancelled {
            fullImage = full
            // QR 检测移出主线程（头尾高度分支依据）
            let image = full
            isQRCode = await Task.detached(priority: .utility) {
                PreviewImageLoader.detectQRCode(in: image)
            }.value
        }
        needsFullRebuild = false
    }
}

// MARK: - 态 7：文件

struct PreviewFileView: View {
    let model: PreviewPopoverContentModel

    private var paths: [String] {
        (model.item.content ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(path)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
            }
            if paths.isEmpty {
                Text(model.item.displayTitle)
                    .font(.system(size: 12))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
