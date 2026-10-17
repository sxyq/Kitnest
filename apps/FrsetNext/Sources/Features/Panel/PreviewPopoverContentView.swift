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
    /// 固定模式（📌）：开 = hover 离开不收起，点别处才关；选择跨启动记忆
    @Stored private var pinned = MainPanelPreviewPopoverCoordinator.shared.previewPinned

    public var body: some View {
        VStack(spacing: 0) {
            pinBar
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
        /// 📌 固定开关（预览右上角小图标）
    private var pinBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                let newValue = !pinned
                MainPanelPreviewPopoverCoordinator.shared.previewPinned = newValue
                pinned = newValue
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundStyle(pinned ? Color.primary : Color.secondary)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinned ? "固定中：点击别处才会关闭（点击取消固定）"
                         : "固定预览：移开鼠标不再自动收起")
        }
        .padding(.horizontal, 8)
        .frame(height: 18)
    }

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
    /// 外部请求滚动到指定字符位置（左侧目录点击）；nil = 无请求
    var scrollRequest: Int? = nil

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
        // 目录跳转 / 外链点击（v82「可点击目录」重建）：委托 + 链接样式
        textView.delegate = context.coordinator
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        context.coordinator.textView = textView

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
        // 左侧目录点击 → 滚动到对应标题（同一请求只执行一次）
        if let request = scrollRequest, context.coordinator.lastScrollRequest != request {
            context.coordinator.lastScrollRequest = request
            context.coordinator.scrollToCharacter(request, in: textView)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: ScrollCoordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> ScrollCoordinator { ScrollCoordinator() }

    final class ScrollCoordinator: NSObject, NSTextViewDelegate {
        var onScroll: ((CGFloat) -> Void)?
        var lastText: String?
        var lastScrollRequest: Int?
        weak var textView: NSTextView?

        @objc func boundsDidChange(_ note: Notification) {
            guard let clipView = note.object as? NSClipView else { return }
            onScroll?(clipView.bounds.origin.y)
        }

        // 目录链接（frset-toc://loc=N）→ 滚动到标题；http(s) → 系统浏览器
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let u = link as? URL { url = u }
            else if let s = link as? String { url = URL(string: s) }
            else { url = nil }
            guard let url else { return false }

            if url.scheme == PreviewMarkdownRenderer.tocScheme {
                let comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if let locText = comp?.queryItems?.first(where: { $0.name == "loc" })?.value,
                   let loc = Int(locText) {
                    scrollToCharacter(loc, in: textView)
                }
                return true
            }
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        func scrollToCharacter(_ index: Int, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            let length = (textView.string as NSString).length
            guard length > 0 else { return }
            let clamped = min(max(0, index), length - 1)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: clamped, length: 1),
                actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.y += textView.textContainerInset.height
            rect.size.height += 8
            textView.scrollToVisible(rect)
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
    @Stored private var headings: [MarkdownHeading] = []
    @Stored private var scrollRequest: Int? = nil
    @Stored private var activeHeading: Int? = nil

    init(model: PreviewPopoverContentModel) {
        self.model = model
        let parsed = Self.render(model.inlineText)
        self._rendered = Stored(wrappedValue: parsed.body)
        self._headings = Stored(wrappedValue: parsed.headings)
    }

    /// 正文 + 标题锚点（目录由左侧栏渲染，不再贴在文首）
    static func render(_ text: String) -> (body: NSAttributedString, headings: [MarkdownHeading]) {
        PreviewMarkdownRenderer.renderBody(text)
    }

    var body: some View {
        HStack(spacing: 0) {
            if headings.count >= 2 {
                PreviewTOCSidebar(headings: headings, activeLocation: activeHeading) { heading in
                    activeHeading = heading.location
                    scrollRequest = heading.location
                }
                .frame(width: 142)
                Divider().opacity(0.5)
            }
            PreviewTextViewRepresentable(
                attributedText: rendered,
                initialScrollOffset: MainPanelPreviewPopoverCoordinator.shared
                    .markdownScrollState(for: model.item.dedupeKey)?.scrollOffset,
                onScrollOffsetChanged: { offset in
                    // 块帧表/偏移快照：重开预览回到原滚动位（P10）
                    MainPanelPreviewPopoverCoordinator.shared.rememberMarkdownScroll(
                        dedupeKey: model.item.dedupeKey,
                        state: MarkdownScrollState(scrollOffset: offset))
                },
                scrollRequest: scrollRequest)
        }
    }
}

// MARK: - 左侧目录侧栏（原版：目录在左边，颜色中性）

struct PreviewTOCSidebar: View {
    let headings: [MarkdownHeading]
    let activeLocation: Int?
    let onSelect: (MarkdownHeading) -> Void

    @Stored private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("目录")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(headings) { heading in
                        let isActive = activeLocation == heading.location
                        Button {
                            onSelect(heading)
                        } label: {
                            Text(heading.title)
                                .font(.system(size: 11.5,
                                              weight: isActive ? .medium : .regular))
                                .foregroundStyle(isActive ? Color.primary
                                                          : (hovered == heading.location ? Color.primary : Color.secondary))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.leading, heading.indent)
                                .padding(.vertical, 4)
                                .background {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(isActive ? Color.primary.opacity(0.09)
                                                       : (hovered == heading.location ? Color.primary.opacity(0.05) : Color.clear))
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in hovered = inside ? heading.location : nil }
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.02))
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
        // JSON 不再是「一屏 pretty-print 文本」：树形 / 表格双视图（见 JSONInspectorView）。
        // 大文件（>5MB）走主面板拖放 → 独立检视器窗口，popover 只做快速看结构。
        JSONInspectorView(text: model.inlineText, compact: true)
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
    /// 解码失败（文件缺失/损坏）→ 显示占位，不留无限转圈
    @Stored private var didFailToLoad = false

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
            } else if didFailToLoad {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                            Text("无法预览这张图片")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
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
        .overlay(alignment: .topTrailing) {
            if displayImage != nil {
                Button {
                    editImage()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 11))
                        Text("标注")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("用标注工具改这张图（画笔/矩形/箭头/文字/荧光/马赛克）")
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

    /// 当前图片交给标注编辑器。跨模块走通知（Panel 不直接引用 Capture 类型）：
    /// 关预览 → 发 frset.clipboard.editImage → Capture 模块用标注编辑器打开。
    private func editImage() {
        guard let image = displayImage else {
            Log.info("panel.preview", "标注：没有可编辑的图片")
            return
        }
        Log.info("panel.preview", "标注：发送编辑请求（\(Int(image.size.width))×\(Int(image.size.height))）")
        MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .programmatic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: Notification.Name("frset.clipboard.editImage"),
                                            object: image)
        }
    }

    @MainActor
    private func loadImages() async {
        guard let fullPath = model.item.imagePath else {
            didFailToLoad = true
            return
        }
        // 注意：item.imagePath / thumbnailPath 存的是**相对路径**（"images/xxx.png"），
        // 必须经 ClipboardFileStore 解析到应用支持目录；直接用 URL(fileURLWithPath:)
        // 会相对当前工作目录解析 → 文件不存在 → 永远转圈（2026-10-17 实测）。
        let fullURL = ClipboardFileStore.url(forRelativePath: fullPath)
        let thumbnailURL = model.item.thumbnailPath.map { ClipboardFileStore.url(forRelativePath: $0) }
        let loader = PreviewImageLoader.shared

        // P9 步骤 1：缩略图先行（几十毫秒内先出图，避免空白等待）
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
        didFailToLoad = (fullImage == nil && thumbnail == nil)
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
