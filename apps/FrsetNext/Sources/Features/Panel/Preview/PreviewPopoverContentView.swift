import QuickLookThumbnailing
import QuickLookUI
import UniformTypeIdentifiers
import AppKit
import Foundation
import SwiftUI

// MARK: - 预览内容视图族（specs/12：PreviewPopoverContentView 内容态）
//
// v71：原 MainPanelPreviewPopoverSlotHostView（NSPopover 宿主 + 📌/hint 条）随 popover
// 底座退役——hover/单击统一由 ClipboardPreviewWindowView（完整头部）承载本视图族。

// MARK: - 分态路由

public struct PreviewPopoverContentView: View {
    let model: PreviewPopoverContentModel
    /// 「按代码看」：用户手动把 Markdown / JSON / 纯文本强制切到代码视图
    var forceCode: Bool = false
    var usesWindowChrome = true

    @ViewBuilder
    public var body: some View {
        if usesWindowChrome { contents.frsetThemeChrome() }
        else { contents }
    }

    private var contents: some View {
        VStack(spacing: 0) {
            content
            // v74（用户需求）：文本内容命中网盘链接时，底部给出「复制/打开/解析下载」操作条
            if let link = CloudDriveLinkDetector.detect(in: model.inlineText) {
                CloudLinkPreviewAction(link: link)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if forceCode, isTextual {
            PreviewCodeTextView(model: model)
        } else {
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
                PreviewFileView(model: model, showsQuickLook: usesWindowChrome)
            case .richText:
                PreviewRichTextView(model: model)
            }
        }
    }

    /// 能切到代码视图的内容（图片/文件/富文本不参与）
    private var isTextual: Bool {
        switch model.kind {
        case .text, .fileBackedText, .markdown, .json, .code: return true
        case .image, .file, .richText: return false
        }
    }
}

// MARK: - 富文本保真渲染（v65）

/// RTF → NSAttributedString → AttributedTextView（NSTextView 承载：完整字体/颜色/列表保真）。
/// 文档语义底色：RTF 通常按白纸排版，固定 textBackgroundColor（浅色=白）保证显式黑色
/// 正文字号在深色系统外观下也不至于隐形（深色下的双向反色留待后续按需增强）。
private struct PreviewRichTextView: View {
    let model: PreviewPopoverContentModel
    /// 直接复用模型中已解析的正文。
    private let attributed: NSAttributedString

    init(model: PreviewPopoverContentModel) {
        self.model = model
        self.attributed = model.richAttributed
            ?? NSAttributedString(string: model.inlineText,
                                  attributes: [.font: NSFont.systemFont(ofSize: 13)])
    }

    var body: some View {
        AttributedTextView(attributed)
            // v106：置空让液态玻璃透出（原实底会盖住玻璃面）
            .background(Color.clear)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 文本基座（NSScrollView + NSTextView，支持滚动偏移恢复与上报）

/// 可回源复制的预览文本视图（v87）：⌘C 把选区按「渲染↔源」映射回 Markdown 源文本。
/// 渲染后的正文丢了 `#`、表格竖线等标记，直接复制与纯文本预览「复制即源文」的口径不一致。
final class PreviewSourceTextView: NSTextView {
    var isSettingsPreview = false
    var sourceText: String?
    var sourceSegments: [(rendered: NSRange, source: NSRange)]?

    override func copy(_ sender: Any?) {
        if isSettingsPreview { return }
        let sel = selectedRange()
        guard sel.length > 0,
              let source = sourceText as NSString?,
              let segments = sourceSegments, !segments.isEmpty else {
            super.copy(sender)
            return
        }
        var pieces: [String] = []
        for seg in segments {
            let inter = NSIntersectionRange(seg.rendered, sel)
            guard inter.length > 0 else { continue }
            let src = seg.source
            if inter == seg.rendered {
                pieces.append(source.substring(with: src))
            } else {
                // 段内部分选中：按字符比例近似裁剪源切片（渲染长度≈源长度，误差一个标记符号级）
                let r0 = seg.rendered.length > 0
                    ? Double(inter.location - seg.rendered.location) / Double(seg.rendered.length) : 0
                let r1 = seg.rendered.length > 0
                    ? Double(inter.location + inter.length - seg.rendered.location) / Double(seg.rendered.length) : 1
                let s = src.location + Int((Double(src.length) * r0).rounded(.down))
                let e = src.location + min(src.length, Int((Double(src.length) * r1).rounded(.up)))
                pieces.append(source.substring(with: NSRange(location: s, length: max(0, e - s))))
            }
        }
        guard !pieces.isEmpty else {
            super.copy(sender)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pieces.joined(separator: "\n"), forType: .string)
    }
}

struct PreviewTextViewRepresentable: NSViewRepresentable {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    var attributedText: NSAttributedString
    var monospaced: Bool = false
    var showsLineNumbers: Bool = false
    var initialScrollOffset: CGFloat? = nil
    var onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
    /// 外部请求滚动到指定字符位置（左侧目录点击）；nil = 无请求
    var scrollRequest: Int? = nil
    /// 回源复制（v87）：Markdown 渲染正文丢了 `#`/表格竖线等标记，
    /// ⌘C 时按「渲染区间 ↔ 源区间」映射回源文本，与纯文本预览的复制口径统一
    var sourceText: String? = nil
    var sourceSegments: [(rendered: NSRange, source: NSRange)]? = nil
    /// 整块底色（代码态用；nil = 透明，跟随外层）
    var background: NSColor? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PreviewSourceTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.isSettingsPreview = isSettingsPreview
        textView.sourceText = sourceText
        textView.sourceSegments = sourceSegments
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)   // 2026-10-18：1.5 倍字号下略加内边距
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
        if let background {
            scrollView.drawsBackground = true
            scrollView.backgroundColor = background
            textView.drawsBackground = false
        } else {
            scrollView.drawsBackground = false
        }
        let text = attributedText.string
        if showsLineNumbers {
            let ruler = CodeLineNumberRuler(textView: textView)
            ruler.updateText(text)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }

        textView.textStorage?.setAttributedString(attributedText)
        context.coordinator.lastText = text

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
        if let sourceView = textView as? PreviewSourceTextView {
            sourceView.isSettingsPreview = isSettingsPreview
            sourceView.sourceText = sourceText
            sourceView.sourceSegments = sourceSegments
        }
        let text = attributedText.string
        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            (scrollView.verticalRulerView as? CodeLineNumberRuler)?.updateText(text)
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
                if (textView as? PreviewSourceTextView)?.isSettingsPreview == true { return true }
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

// MARK: - 态 1：短文本

struct PreviewTextContentView: View {
    let text: String

    var body: some View {
        PreviewTextViewRepresentable(
            attributedText: NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 19.5),   // 13 × 1.5（整体文本放大，2026-10-18）
                    .foregroundColor: NSColor.labelColor
                ]))
    }
}

// MARK: - 落盘长文档的 Markdown 渲染（全文异步加载完成后使用）
//
// 与内联条目的 PreviewMarkdownTextView 同渲染口径（1.5 倍字号 + 左侧目录），
// 区别仅在数据来源是落盘全文。

struct MarkdownFilePreviewBody: View {
    let text: String
    let restoreKey: String
    /// v181：窄容器（归档窗口右栏）关掉左侧目录，把宽度让给正文
    var showsTOC: Bool = true
    @Stored private var rendered: NSAttributedString? = nil
    @Stored private var headings: [MarkdownHeading] = []
    @Stored private var sourceSegments: [(rendered: NSRange, source: NSRange)] = []
    @Stored private var scrollRequest: Int? = nil
    @Stored private var activeHeading: Int? = nil

    init(text: String, restoreKey: String, showsTOC: Bool = true) {
        self.text = text
        self.restoreKey = restoreKey
        self.showsTOC = showsTOC
    }

    var body: some View {
        Group {
            if let rendered {
                MarkdownPreviewBody(
                    text: text,
                    scrollRestoreKey: restoreKey,
                    rendered: rendered,
                    headings: headings,
                    sourceSegments: sourceSegments,
                    scrollRequest: $scrollRequest,
                    activeHeading: $activeHeading,
                    showsTOC: showsTOC)
            } else {
                PreviewLoadingIndicator(delay: MainPanelPreviewPopoverCoordinator.shared.previewLoadingIndicatorDelay)
                    .frame(maxWidth: .infinity, minHeight: MainPanelPreviewPopoverCoordinator.shared.textPreviewLoadingMinHeight)
            }
        }
        .task(id: text) {
            rendered = nil
            let parsed = await Task.detached(priority: .userInitiated) {
                PreviewMarkdownRenderer.renderBody(text)
            }.value
            guard !Task.isCancelled else { return }
            rendered = parsed.body
            headings = parsed.headings
            sourceSegments = parsed.segments
        }
    }
}

// MARK: - 态 2：落盘长文本

struct PreviewFileBackedTextView: View {
    private enum LoadState {
        case loading
        case markdown(PreviewPopoverContentModel)
        case json(JSONDocument)
        case code(NSAttributedString)
        case text(String)
        case empty
    }

    let model: PreviewPopoverContentModel
    @Stored private var loadState: LoadState = .loading

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                PreviewLoadingIndicator(delay: MainPanelPreviewPopoverCoordinator.shared.previewLoadingIndicatorDelay)
                    .frame(maxWidth: .infinity, minHeight: MainPanelPreviewPopoverCoordinator.shared.textPreviewLoadingMinHeight)
            case .markdown(let markdown):
                PreviewMarkdownTextView(model: markdown)
            case .json(let document):
                JSONInspectorView(document: document, compact: true)
            case .code(let attributed):
                PreviewTextViewRepresentable(attributedText: attributed, monospaced: true, showsLineNumbers: true)
            case .text(let text):
                PreviewTextContentView(text: text)
            case .empty:
                Text("内容为空")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.sessionID) {
            await loadFullText()
        }
    }

    private func loadFullText() async {
        loadState = .loading

        let work = Task.detached(priority: .userInitiated) { [model] () -> LoadState in
            let text = PreviewPopoverDataBridge.shared.fullText(for: model.item)
            guard !Task.isCancelled, !text.isEmpty else { return .empty }
            switch PreviewPopoverContentModel.classifyRawText(text) {
            case .markdown:
                return .markdown(PreviewPopoverContentModel(item: model.item, source: model.source,
                    entry: model.entry, sessionID: model.sessionID, inlineText: text, kindOverride: .markdown))
            case .json:
                if let document = JSONDocument(text: text) { return .json(document) }
                return .text(text)
            case .code:
                return .code(PreviewMarkdownRenderer.renderCodeBody(text))
            default:
                return .text(text)
            }
        }
        let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
        guard !Task.isCancelled else { return }
        loadState = result
    }
}

private struct PreviewLoadingIndicator: View {
    let delay: TimeInterval
    @Stored private var isVisible = false

    var body: some View {
        Color.clear
            .overlay { if isVisible { ProgressView().controlSize(.small) } }
            .task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled { isVisible = true }
            }
    }
}

// MARK: - 态 3：Markdown（F15：滚动位置记忆 + 恢复）

struct PreviewMarkdownTextView: View {
    let model: PreviewPopoverContentModel
    @Stored private var rendered: NSAttributedString?
    @Stored private var headings: [MarkdownHeading] = []
    @Stored private var sourceSegments: [(rendered: NSRange, source: NSRange)] = []
    @Stored private var scrollRequest: Int? = nil
    @Stored private var activeHeading: Int? = nil

    init(model: PreviewPopoverContentModel) {
        self.model = model
    }

    var body: some View {
        Group {
            if let rendered {
                MarkdownPreviewBody(
                    text: model.inlineText,
                    scrollRestoreKey: model.item.dedupeKey,
                    rendered: rendered,
                    headings: headings,
                    sourceSegments: sourceSegments,
                    scrollRequest: $scrollRequest,
                    activeHeading: $activeHeading)
            } else {
                ProgressView("正在排版…").controlSize(.small)
            }
        }
        .task(id: model.sessionID) {
            let text = model.inlineText
            let parsed = await Task.detached(priority: .userInitiated) {
                PreviewMarkdownRenderer.renderBody(text)
            }.value
            guard !Task.isCancelled else { return }
            rendered = parsed.body
            headings = parsed.headings
            sourceSegments = parsed.segments
        }
    }
}

// MARK: - Markdown 正文视图（内联条目与落盘长文档共用）
//
// 2026-10-18：从 PreviewMarkdownTextView 抽出——落盘长文本（长 Markdown/TXT 文档）
// 加载全文后若判定为 Markdown，也走同一套「左侧目录 + 富文本正文」渲染。

struct MarkdownPreviewBody: View {
    let text: String
    /// 滚动记忆键（clipboard 条目用 dedupeKey；落盘文档也复用它）
    let scrollRestoreKey: String
    let rendered: NSAttributedString
    let headings: [MarkdownHeading]
    /// 渲染区间 ↔ 源文本区间（⌘C 回源复制）
    let sourceSegments: [(rendered: NSRange, source: NSRange)]
    @Binding var scrollRequest: Int?
    @Binding var activeHeading: Int?
    /// v181：是否显示左侧目录。窄容器（如归档窗口右栏被挤窄时）关掉，
    /// 否则 180pt 目录会把正文压成一条细缝。默认 true = 弹层里的原行为不变。
    var showsTOC: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            if showsTOC, headings.count >= 1 {
                PreviewTOCSidebar(headings: headings, activeLocation: activeHeading) { heading in
                    activeHeading = heading.location
                    scrollRequest = heading.location
                }
                // 目录框宽度（用户需求 2026-10-18：比原来的 142 宽一些）
                .frame(width: 180)
                Divider().opacity(0.5)
            }
            PreviewTextViewRepresentable(
                attributedText: rendered,
                initialScrollOffset: MainPanelPreviewPopoverCoordinator.shared
                    .markdownScrollState(for: scrollRestoreKey)?.scrollOffset,
                onScrollOffsetChanged: { offset in
                    // 块帧表/偏移快照：重开预览回到原滚动位（P10）
                    MainPanelPreviewPopoverCoordinator.shared.rememberMarkdownScroll(
                        dedupeKey: scrollRestoreKey,
                        state: MarkdownScrollState(scrollOffset: offset))
                },
                scrollRequest: scrollRequest,
                sourceText: text,
                sourceSegments: sourceSegments)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
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
                                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                        .fill(isActive ? Color.primary.opacity(0.09)
                                                       : (hovered == heading.location ? Theme.cardFill : Color.clear))
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

// MARK: - 态 4：JSON（树形 / 表格）

struct PreviewJSONTextView: View {
    let model: PreviewPopoverContentModel

    var body: some View {
        // JSON 不再是「一屏 pretty-print 文本」：树形 / 表格双视图（见 JSONInspectorView）。
        // 大文件（>5MB）走主面板拖放 → 独立检视器窗口，popover 只做快速看结构。
        JSONInspectorView(text: model.inlineText, compact: true)
    }
}

// MARK: - 态 5：代码（可换主题/语言 + 富文本复制）

struct PreviewCodeTextView: View {
    let model: PreviewPopoverContentModel

    var body: some View {
        // 统一走 CodePreviewView：语言/主题/行号/换行/字号都在这一个框里调，
        // 复制默认给富文本（Word 可直接粘）。自动识别失败时可在语言菜单里手动指定。
        CodePreviewView(code: model.inlineText, fileName: sourceFileName)
    }

    /// 条目带文件名（如 a.swift）时按扩展名锁定语言
    private var sourceFileName: String? {
        guard let title = model.item.title, !title.isEmpty else { return nil }
        let lower = title.lowercased()
        let known = ["swift", "py", "js", "ts", "jsx", "tsx", "java", "kt", "go", "rs",
                     "c", "cpp", "cc", "h", "hpp", "cs", "m", "mm", "rb", "php", "sql",
                     "sh", "bash", "zsh", "json", "yml", "yaml", "toml", "xml", "html",
                     "css", "scss", "md", "lua", "r", "pl", "dart", "ps1", "diff", "patch"]
        guard let dot = lower.lastIndex(of: ".") else { return nil }
        let ext = String(lower[lower.index(after: dot)...])
        return known.contains(ext) ? title : nil
    }
}

// MARK: - 态 6：图片（F12 缩略→大图重建 / F13 QR 头尾高度分支）

struct PreviewImageContent: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geo in
            let tall = image.size.height > image.size.width * 1.6
            let scale = min(1, min((geo.size.width - 24) / image.size.width,
                                  tall ? 1 : geo.size.height / image.size.height))
            let width = image.size.width * scale
            let height = image.size.height * scale
            if tall {
                ScrollView(.vertical) {
                    Image(nsImage: image).resizable()
                        .frame(width: width, height: height)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Image(nsImage: image).resizable()
                    .frame(width: width, height: height)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

struct PreviewImageView: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.settingsPreviewImage) private var previewImage
    let model: PreviewPopoverContentModel
    @Stored private var thumbnail: NSImage?
    @Stored private var fullImage: NSImage?
    @Stored private var needsFullRebuild = true
    @Stored private var isQRCode = false
    /// 解码失败（文件缺失/损坏）→ 显示占位，不留无限转圈
    @Stored private var didFailToLoad = false
    /// OCR 文本（已缓存的先显示；没有则给「识别文本」按钮现算）
    @Stored private var ocrText = ""
    /// 整理后的 OCR 文本（v169：合并版面折行、去噪声空格，仅用于显示）
    @Stored private var tidiedOCR = ""
    @Stored private var ocrBusy = false
    @Stored private var ocrError: String?

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
                PreviewImageContent(image: image)
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

            // 图片下方的操作行：识别/复制识别文本（2026-10-20 用户需求）
            if displayImage != nil {
                ocrActionBar
            }

            // 图片 OCR 文本区块（缓存 / 现算结果；无则不占位）
            if !ocrText.isEmpty {
                Divider().padding(.vertical, 4)
                PreviewTextViewRepresentable(
                    attributedText: OCRTextTidy.attributed(tidiedOCR.isEmpty ? ocrText : tidiedOCR))
                    .frame(maxHeight: 160)
            } else if let ocrError {
                Text(ocrError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
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
                    // v209：去掉 .regularMaterial（第二种玻璃实现），
                    // 内联按钮统一用内容卡样式（与全 App 卡片同一配方）
                    .background(Capsule().fill(Theme.cardFill))
                    .overlay {
                        Capsule().strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline)
                    }
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
            if isSettingsPreview { return }
            let raw = PreviewPopoverDataBridge.shared.ocrText(for: model.item) ?? ""
            ocrText = raw
            tidiedOCR = OCRTextTidy.tidy(raw)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardOCRTextChanged)) { note in
            guard !isSettingsPreview, note.object as? String == model.item.dedupeKey else { return }
            let raw = PreviewPopoverDataBridge.shared.ocrText(for: model.item) ?? ""
            ocrText = raw
            tidiedOCR = OCRTextTidy.tidy(raw)
            ocrError = nil
        }
    }

    // MARK: 图片下方：识别 / 复制文本

    private var ocrActionBar: some View {
        HStack(spacing: 8) {
            if ocrBusy {
                ProgressView().controlSize(.mini)
                Text("识别中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !ocrText.isEmpty {
                smallAction("复制文本", icon: "doc.on.doc", prominent: true) { copyOCR() }
                smallAction("重新识别", icon: "arrow.clockwise") { recognizeNow() }
                Spacer(minLength: 4)
                Text("\(ocrText.count) 字")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                smallAction("识别文本", icon: "text.viewfinder") { recognizeNow() }
                Spacer(minLength: 4)
                Text(ocrHint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private var ocrHint: String {
        ocrError == nil ? "图中文字可识别后复制" : "识别失败，可重试"
    }

    private func smallAction(_ title: String, icon: String,
                             prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                if prominent {
                    Capsule(style: .continuous).fill(Theme.accent)
                } else {
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.07))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func copyOCR() {
        if isSettingsPreview { ocrError = "复制效果演示，不写入剪贴板"; return }
        let text = ocrText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("已复制识别文本", icon: "doc.on.doc")
    }

    /// 现算/重算 OCR：走「设置 → 截图 → 文字识别」指定的引擎，结果回写缓存
    private func recognizeNow() {
        if isSettingsPreview {
            ocrText = "山间日落 · 固定图片"
            tidiedOCR = ocrText
            return
        }
        guard let path = model.item.imagePath else {
            ocrError = "读不到图片文件"
            return
        }
        let url = ClipboardFileStore.url(forRelativePath: path)
        ocrBusy = true
        ocrError = nil
        let item = model.item
        Task {
            // v126（性能审计 F2079）：文件读取放后台队列——原实现主线程同步
            // Data(contentsOf:)，大图会卡 UI 一帧以上。
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            guard let data, !data.isEmpty else {
                await MainActor.run {
                    ocrBusy = false
                    ocrError = "读不到图片文件"
                }
                return
            }
            do {
                let text = try await PreviewPopoverDataBridge.shared.recognizeImage(data)
                await MainActor.run {
                    ocrText = text
                    tidiedOCR = OCRTextTidy.tidy(text)
                    ocrBusy = false
                    if !text.isEmpty {
                        PreviewPopoverDataBridge.shared.saveOCRText(text, for: item)
                    } else {
                        ocrError = "没有识别到文字"
                    }
                }
            } catch {
                await MainActor.run {
                    ocrBusy = false
                    ocrError = error.localizedDescription
                }
            }
        }
    }

    /// 当前图片交给标注编辑器。跨模块走通知（Panel 不直接引用 Capture 类型）：
    /// 关预览 → 发 frset.clipboard.editImage → Capture 模块用标注编辑器打开。
    private func editImage() {
        if isSettingsPreview { ocrError = "标注入口演示，不打开正式窗口"; return }
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
        if isSettingsPreview { fullImage = previewImage; needsFullRebuild = false; return }
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
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Stored private var previewFeedback = ""
    let model: PreviewPopoverContentModel
    var showsQuickLook = true

    private var paths: [String] {
        (model.item.content ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 单文件且是可内联渲染的文档（docx/pptx/xlsx/pdf/pages…）
    private func isDocumentPath(_ path: String) -> Bool {
        DocumentInlinePreview.supportedExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// 文件名 + 路径 + 操作按钮（大图/小图两种布局共用）
    @ViewBuilder
    private func fileInfo(_ path: String, showsName: Bool = true, showsPath: Bool = true) -> some View {
        let displayPath = model.displayPath ?? path
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text((path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            if showsPath { Button {
                if isSettingsPreview { previewFeedback = "复制路径演示"; return }
                ClipboardManager.shared.copyText(displayPath, successMessage: "已复制路径")
            } label: {
                Text(displayPath).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).help("点击复制完整路径")
            .accessibilityLabel("复制路径 \(displayPath)") }
            if paths.count == 1 {
                HStack(spacing: 6) {
                    // 快速查看：Word/PPT 可翻页看全文（系统 QuickLook）
                    if showsQuickLook { Button("快速查看") {
                        if isSettingsPreview { previewFeedback = "快速查看入口演示"; return }
                        QuickLookPresenter.shared.show(URL(fileURLWithPath: path))
                    }
                    .controlSize(.mini) }
                    Button("打开") {
                        if isSettingsPreview { previewFeedback = "打开入口演示"; return }
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .controlSize(.mini)
                    Button("在 Finder 中显示") {
                        if isSettingsPreview { previewFeedback = "Finder 入口演示"; return }
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .controlSize(.mini)
                    Button("压缩…") {
                        if isSettingsPreview { previewFeedback = "压缩入口演示"; return }
                        ArchiveCreateWindowController.show(files: [URL(fileURLWithPath: path)])
                    }
                    .controlSize(.mini)
                    if isArchivePath(path) {
                        Button("编辑归档") {
                            if isSettingsPreview { previewFeedback = "归档入口演示"; return }
                            ArchiveBrowserWindowController.show(url: URL(fileURLWithPath: path))
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
    }

    /// 单文件且是压缩包（多选时不做归档内展开，避免一次起多个 7zz）
    private func isArchivePath(_ path: String) -> Bool {
        paths.count == 1 && ArchiveCore.isArchive(URL(fileURLWithPath: path))
    }

    var body: some View {
        if !isSettingsPreview, let url = model.fileURL,
           model.fileIsDirectory || isArchivePath(url.path) || model.fileText != .idle || model.fileImage != nil || isDocumentPath(url.path) {
            VStack(alignment: .leading, spacing: 0) {
                fileContent(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                fileInfo(url.path, showsName: false,
                         showsPath: !model.fileIsDirectory && !isArchivePath(url.path))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                fileList
            }.padding(12)
        }
    }

    @ViewBuilder
    private func fileContent(_ url: URL) -> some View {
        if model.fileIsDirectory || isArchivePath(url.path) {
            FileContainerPreview(path: url.path)
        } else if model.fileText == .loading {
            ProgressView("正在读取预览…").controlSize(.small)
        } else if let textModel = model.fileTextModel {
            switch textModel.kind {
            case .markdown: PreviewMarkdownTextView(model: textModel)
            case .json: PreviewJSONTextView(model: textModel)
            case .code: PreviewCodeTextView(model: textModel)
            default: PreviewTextContentView(text: textModel.inlineText)
            }
        } else if case .failed(let message) = model.fileText {
            Text(message).foregroundStyle(.secondary)
        } else if let image = model.fileImage {
            PreviewImageContent(image: image)
        } else {
            DocumentInlinePreview(url: url)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paths, id: \.self) { path in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        PreviewFileThumb(path: path,
                                         size: isSettingsPreview || isArchivePath(path) ? 72
                                              : (paths.count == 1 ? 260 : 44))
                        fileInfo(path)
                        Spacer(minLength: 0)
                    }
                }
            }
            fileActions
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var fileActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !paths.isEmpty {
                HStack(spacing: 6) {
                    Button(paths.count > 1 ? "压缩所选 \(paths.count) 项…" : "压缩…") {
                        if isSettingsPreview { previewFeedback = "压缩入口演示，不操作文件"; return }
                        ArchiveCreateWindowController.show(
                            files: paths.map { URL(fileURLWithPath: $0) })
                    }
                    .controlSize(.mini)
                    Spacer(minLength: 0)
                }
            }
            if !previewFeedback.isEmpty {
                Text(previewFeedback).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}


// MARK: - 文件缩略图分级解码（v111 P0-c，FR-103；ArcZip 悬停预览③解码层同口径）
//
// 分级：图片 → ImageIO/NSImage；PDF → CGPDFDocument 首页渲染；
//       其余（Office / 压缩包 / 任意二进制）→ QLThumbnailGenerator 兜底。
// 缓存：NSCache 上限自动回收（FR-105 临时产物纪律的内存侧对应物）。
// 两段式：先出系统文件图标，解码完成后原位替换（FR-104 观感：无闪白）。

private enum PreviewFileThumbCache {
    static let store: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 60
        return c
    }()
}

private enum PreviewFileThumbnailLoader {

    static func decode(path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if FilePreviewBuilder.imageExtensions.contains(ext) {
            return await withCheckedContinuation { continuation in
                PreviewImageLoader.shared.loadImage(at: url, needsFullRebuild: false) {
                    continuation.resume(returning: $0)
                }
            }
        }
        if ext == "pdf" {
            return await Task.detached(priority: .userInitiated) { renderPDF(url: url) }.value
        }
        return await qlThumbnail(url: url)
    }

    /// PDF 首页渲染（CGPDFDocument，D1：Office 二进制只浏览，PDF 给渲染预览）
    private static func renderPDF(url: URL) -> NSImage? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let w = max(1, Int(box.width * scale)), h = max(1, Int(box.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let c = ctx.cgContext
        c.setFillColor(NSColor.white.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        c.scaleBy(x: scale, y: scale)
        c.drawPDFPage(page)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: box.width, height: box.height))
    }

    /// QLThumbnailGenerator 兜底（Office/任意格式，FR-103 第 4/5 档）
    private static func qlThumbnail(url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 512, height: 512),
            scale: 2,
            representationTypes: .all)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }
}

/// 缩略图视图：先图标、异步解码后替换（缓存命中即时）
private struct PreviewFileThumb: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    let path: String
    let size: CGFloat
    @Stored private var image: NSImage?

    /// v167（用户：「Word / PPT 预览就是一个文件图标，我要的是文件内容」）：
    /// 文档类改为**内联 QuickLook 渲染**。
    /// 根因：QLThumbnailGenerator 走的是「缩略图」通道，系统对 Office 只提供图标，
    /// 于是预览框里永远是一张 Word 图标；QLPreviewView 走的是「预览」通道，
    /// 能把 docx/pptx/xlsx/pages/key 等真实排版渲染出来（实测 docx 封面/表格/目录完整）。
    private var inlineDocument: Bool {
        if isSettingsPreview { return false }
        guard size >= 120 else { return false }       // 多选时的小格子仍用图标，避免起一堆渲染器
        return DocumentInlinePreview.supportedExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if inlineDocument {
                DocumentInlinePreview(url: URL(fileURLWithPath: path))
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: FileIconResolver.icon(forPath: path))
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .glassCard(radius: 6)
        .onAppear { if !isSettingsPreview && !inlineDocument { load() } }
    }

    private func load() {
        if let hit = PreviewFileThumbCache.store.object(forKey: path as NSString) {
            image = hit
            return
        }
        let p = path
        Task {
            let img = await PreviewFileThumbnailLoader.decode(path: p)
            if let img {
                PreviewFileThumbCache.store.setObject(img, forKey: p as NSString)
            }
            await MainActor.run { image = img }
        }
    }
}


// MARK: - 快速查看（v118）：系统 QLPreviewPanel（Word/PPT 可翻页看全文）

import QuickLookUI

final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPresenter()
    private var current: URL?

    func show(_ url: URL) {
        current = url
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { current == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        current as NSURL?
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

// MARK: - OCR 文本整理（v169）

/// 用户反馈：「预览图片时下面 OCR 自动识别的文字没有整理，可读性差」。
///
/// OCR 给出的是**版面行**，不是语义段落：一句话常被硬切成好几行，行内还夹着
/// OCR 自己插的孤立空格。这里做**保守**整理：
///   1. 裁行尾空白；连续空行压成一个（空行视为段落边界，不跨越合并）
///   2. 上一行不以句末标点收尾、下一行也不是列表项 → 视为同一句，合并
///   3. 中文与中文合并**不加空格**；拉丁文之间补一个空格
///   4. 中文与中文之间的孤立空格删掉（OCR 常见噪声）
///
/// 刻意不做：不重排段落、不删短行（可能是页码/表格单元）、不跨空行合并、
/// 表格型内容（行多且每行很短）完全不做行合并 —— 宁可少整理，
/// 也不要把两栏排版或表格揉成一团。
enum OCRTextTidy {

    /// 句末：见到就断段
    private static let sentenceEnd: Set<Character> = ["。", "！", "？", "…", ".", "!", "?"]
    /// 句中：收尾时说明这句被版面宽度折断了，应当接回下一行
    private static let softEnd: Set<Character> = ["，", "、", "；", "：", ",", ";", ":", "-", "—"]

    private static let listMarkers: Set<Character> = [
        "•", "-", "*", "·", "▪", "●", "○", "◆", "■", "□"
    ]

    static func tidy(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let nonEmpty = lines.filter { !$0.isEmpty }
        let looksTabular = nonEmpty.count >= 6
            && nonEmpty.reduce(0) { $0 + $1.count } / max(1, nonEmpty.count) < 10

        var out: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { out.append(current); current = "" }
        }

        for line in lines {
            if line.isEmpty {
                flush()
                continue
            }
            if current.isEmpty {
                current = line
                continue
            }
            if looksTabular {
                flush()
                current = line
                continue
            }
            if let first = line.first, listMarkers.contains(first) {
                flush()
                current = line
                continue
            }
            if shouldMerge(current, line) {
                current = merge(current, line)
            } else {
                flush()
                current = line
            }
        }
        flush()

        return out.map { squeezeSpaces($0) }.joined(separator: "\n")
    }

    /// 是否把下一行接回当前行（**保守**：只接「明显被版面宽度折断」的句子）
    /// 显示样式（v169）：11.5pt + 行距 2.5 + 段间距 6。
    /// 原来直接用 11pt 无行距渲染，OCR 的行本来就密，挤在一起读不动。
    static func attributed(_ text: String) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2.5
        para.paragraphSpacing = 6
        para.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ])
    }

    private static func shouldMerge(_ current: String, _ next: String) -> Bool {
        guard let first = next.first else { return false }
        // 列表项 / 编号 / 装饰符开头 → 一定是新的一条
        if listMarkers.contains(first) || "0123456789#&©®|·".contains(first) { return false }
        // 上一行已经说完一句 → 断段
        if let last = current.last, sentenceEnd.contains(last) { return false }
        // 逗号/顿号收尾且有一定长度 → 被折断，接回
        if let last = current.last, softEnd.contains(last), current.count >= 12 { return true }
        // 行本身够长（超过一般卡片宽度）且没有句末标点 → 被折断，接回
        if current.count >= 30 { return true }
        return false
    }

    private static func merge(_ head: String, _ tail: String) -> String {
        guard let h = head.last, let t = tail.first else { return head + tail }
        if h.isCJK || t.isCJK { return head + tail }
        if head.hasSuffix(" ") { return head + tail }
        return head + " " + tail
    }

    /// 删掉中文与中文之间的空格（OCR 噪声），保留英文词间空格
    private static func squeezeSpaces(_ line: String) -> String {
        guard line.contains(" ") else { return line }
        var result = ""
        result.reserveCapacity(line.count)
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " ", i > 0, i + 1 < chars.count,
               chars[i - 1].isCJK, chars[i + 1].isCJK {
                i += 1
                continue
            }
            result.append(c)
            i += 1
        }
        return result
    }
}

extension Character {
    /// 中日韩字符或全角标点（用于决定合并时要不要补空格）
    var isCJK: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x3000...0x303F).contains(v)
            || (0x4E00...0x9FFF).contains(v)
            || (0x3400...0x4DBF).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }
}


// MARK: - 文件图标（v170）

/// 按路径取文件图标；**原文件不在时按扩展名兜底**。
///
/// `NSWorkspace.icon(forFile:)` 对不存在的路径返回一张空白通用文档，
/// 剪贴板里指向 `/tmp/xxx.zip` 这类已被系统清理的条目，行里就成了「没有预览图」。
/// 这里先判断存在性，不在就退回 `UTType` 的类型图标（zip 仍是 zip 图标）。
enum FileIconResolver {
    static func icon(forPath path: String) -> NSImage {
        if FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let ext = URL(fileURLWithPath: path).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}
