import AppKit
import SwiftUI

// MARK: - 代码预览视图（框内可调：语言 / 主题 / 行号 / 换行 / 字号 / 复制）
//
// 交互参照 highlightcode.com：所有开关都在**同一个框的工具条**里，
// 改完立刻重排，不弹二级面板。复制默认就是富文本（Word 可直接粘）。

public enum CodePreviewPreferences {
    static let themeKey = "code.preview.theme"
    static let fontSizeKey = "code.preview.fontSize"
    static let lineNumbersKey = "code.preview.lineNumbers"
    static let wrapKey = "code.preview.wraps"

    public static var themeID: String? {
        let v = Preferences.shared.value(themeKey, default: "")
        return v.isEmpty ? nil : v
    }
    public static var fontSize: Double {
        let v = Preferences.shared.value(fontSizeKey, default: 0.0)
        return v > 0 ? v : 12.5
    }
    public static var showsLineNumbers: Bool {
        Preferences.shared.value(lineNumbersKey, default: true)
    }
    public static var wraps: Bool {
        Preferences.shared.value(wrapKey, default: false)
    }
}

public struct CodePreviewView: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview

    public let code: String
    /// 已知文件名（用于按扩展名锁定语言）
    public let fileName: String?

    @Stored private var languageID: String
    @Stored private var themeID: String
    @Stored private var fontSize: Double
    @Stored private var showsLineNumbers: Bool
    @Stored private var wraps: Bool
    @Stored private var copiedFlash = false
    @Stored private var cached: NSAttributedString
    /// 已完成的渲染键，切换配置期间不呈现旧配色。
    @Stored private var cachedKey: String = ""

    public init(code: String, fileName: String? = nil) {
        self.code = code
        self.fileName = fileName
        let savedTheme = CodePreviewPreferences.themeID
        let initialTheme = savedTheme.map { CodeThemeCatalog.theme(id: $0) } ?? CodeThemeCatalog.systemDefault
        _languageID = Stored(wrappedValue: "auto")
        _themeID = Stored(wrappedValue: initialTheme.id)
        let size = CodePreviewPreferences.fontSize
        _fontSize = Stored(wrappedValue: size)
        _showsLineNumbers = Stored(wrappedValue: CodePreviewPreferences.showsLineNumbers)
        _wraps = Stored(wrappedValue: CodePreviewPreferences.wraps)
        _cached = Stored(wrappedValue: NSAttributedString())
    }

    // MARK: 派生状态

    private var theme: CodeTheme { CodeThemeCatalog.theme(id: themeID) }

    // SwiftUI 侧的颜色桥（NSColor 不是 ShapeStyle，统一转一次）
    private var bg: Color { Color(nsColor: theme.background) }
    private var gutterFill: Color { Color(nsColor: theme.gutter) }
    private var borderFill: Color { Color(nsColor: theme.border) }
    private var fg: Color { Color(nsColor: theme.plain) }
    private var muted: Color { Color(nsColor: theme.lineNumber) }

    private var resolvedLanguage: String {
        if languageID == "auto" {
            return CodeLanguageCatalog.detect(code, fileName: fileName)
        }
        return languageID
    }

    /// 影响高亮结果的输入组合。值一变就必须重新着色（见 body 里的 onChange）。
    private var renderKey: String {
        "\(themeID)|\(fontSize)|\(languageID)"
    }

    private var options: CodeRenderOptions {
        CodeRenderOptions(language: resolvedLanguage,
                          theme: theme,
                          fontSize: CGFloat(fontSize),
                          showsLineNumbers: showsLineNumbers)
    }

    private var statistics: (lines: Int, characters: Int) {
        CodeHighlighter.statistics(code)
    }

    // MARK: 视图

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(borderFill).frame(height: 1)
            codeArea
            Rectangle().fill(borderFill).frame(height: 1)
            statusBar
        }
        .background(bg)
        // 切主题时让宿主窗口的 appearance / 底色跟着变（否则标题栏停在旧主题的明暗上）
        .background {
            if !isSettingsPreview {
                WindowThemeSync(isDark: theme.isDark, background: theme.background)
                    .allowsHitTesting(false)
            }
        }
        .task(id: renderKey) { await rebuild() }
        .onChange(of: renderKey) { _ in persist() }
        .onChange(of: showsLineNumbers) { _ in persist() }
        .onChange(of: wraps) { _ in persist() }
    }

    // MARK: 工具条

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Theme.Space.sm) {
            languageMenu
            themeMenu
            Spacer(minLength: Theme.Space.sm)
            toolbarToggle(icon: "list.number",
                          active: showsLineNumbers,
                          help: showsLineNumbers ? "隐藏行号" : "显示行号") {
                showsLineNumbers.toggle()
            }
            toolbarToggle(icon: "text.alignleft",
                          active: wraps,
                          help: wraps ? "关闭自动换行（可横向滚动）" : "自动换行") {
                wraps.toggle()
            }
            fontSizeControls
            Rectangle().fill(borderFill).frame(width: 1, height: 14)
            copyButton
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 38)
        .background(gutterFill)
        }
        .frame(height: 38)
    }

    private var languageMenu: some View {
        Menu {
            Picker("语言", selection: $languageID) {
                Text("自动识别").tag("auto")
                Divider()
                ForEach(CodeLanguageCatalog.all.filter { $0.id != "auto" }) { lang in
                    Text(lang.name).tag(lang.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            chipLabel {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(languageID == "auto"
                         ? "自动 · \(CodeLanguageCatalog.displayName(resolvedLanguage))"
                         : CodeLanguageCatalog.displayName(resolvedLanguage))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 132, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.55)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("选择语言（自动识别按内容特征判断）")
    }

    private var themeMenu: some View {
        Menu {
            Picker("风格", selection: $themeID) {
                ForEach(CodeThemeCatalog.themes) { t in
                    Text(t.name).tag(t.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            chipLabel {
                HStack(spacing: 5) {
                    HStack(spacing: 1.5) {
                        ForEach(Array(theme.swatch.enumerated()), id: \.offset) { pair in
                            Circle()
                                .fill(Color(nsColor: pair.element))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(width: 18, height: 10)
                    Text(theme.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.55)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("切换配色风格（14 套内置主题）")
    }

    private func chipLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundStyle(fg.opacity(0.92))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(fg.opacity(0.09))
            )
    }

    private func toolbarToggle(icon: String, active: Bool, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? bg : fg.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(active ? fg.opacity(0.85) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    private var fontSizeControls: some View {
        HStack(spacing: 0) {
            Button {
                fontSize = max(9, fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("缩小字号")
            Text("\(Int(fontSize))")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(width: 18)
            Button {
                fontSize = min(24, fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 24)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("放大字号")
        }
        .foregroundStyle(fg.opacity(0.8))
    }

    private var copyButton: some View {
        HStack(spacing: 2) {
            Button {
                copyRichText()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedFlash ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copiedFlash ? (isSettingsPreview ? "复制演示" : "已复制") : "复制")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(bg)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(fg.opacity(0.88))
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("复制为富文本：带配色与行号，可直接粘到 Word / Pages / 飞书")

            Menu {
                Button("复制为富文本") { copyRichText() }
                Button("复制为图片") { copyAsImage() }
                Divider()
                Button("复制纯文本") { copyPlainText() }
                Button("复制 HTML 源码") { copyHTMLSource() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(fg.opacity(0.7))
                    .frame(width: 14, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .help("更多复制方式")
        }
    }

    // MARK: 代码区

    private var codeArea: some View {
        Group {
            if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("没有可预览的代码")
                    .font(.system(size: 12))
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cachedKey != renderKey {
                ProgressView("正在着色…").controlSize(.small)
            } else {
                CodeTextViewRepresentable(attributed: cached,
                                          theme: theme,
                                          fontSize: CGFloat(fontSize),
                                          showsLineNumbers: showsLineNumbers,
                                          wraps: wraps)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 状态条

    private var statusBar: some View {
        let count = statistics
        return HStack(spacing: Theme.Space.sm) {
            Text("\(count.lines) 行 · \(count.characters) 字符")
            Text("·")
            Text(CodeLanguageCatalog.displayName(resolvedLanguage))
            if languageID == "auto" { Text("（自动识别）") }
            Spacer(minLength: 8)
            Text("⌘C 复制富文本").opacity(0.75)
        }
        .font(.system(size: 10))
        .foregroundStyle(muted)
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 22)
        .background(gutterFill)
    }

    // MARK: 动作

    private func rebuild() async {
        let key = renderKey
        let text = code
        let renderOptions = options
        let rendered = await Task.detached(priority: .userInitiated) {
            CodeHighlighter.attributed(text, options: renderOptions)
        }.value
        guard !Task.isCancelled else { return }
        cached = rendered
        cachedKey = key
    }

    private func persist() {
        if isSettingsPreview { return }
        Preferences.shared.set(CodePreviewPreferences.themeKey, themeID)
        Preferences.shared.set(CodePreviewPreferences.fontSizeKey, fontSize)
        Preferences.shared.set(CodePreviewPreferences.lineNumbersKey, showsLineNumbers)
        Preferences.shared.set(CodePreviewPreferences.wrapKey, wraps)
    }

    private func copyRichText() {
        if isSettingsPreview { copiedFlash = true; return }
        let ok = CodeRichCopy.copyRichText(code, options: options)
        flashCopied(ok: ok, message: "已复制富文本，可直接粘到 Word")
    }

    /// 复制为图片（贴到聊天工具/文档里不会掉格式，等同 highlightcode 的导出图）
    private func copyAsImage() {
        if isSettingsPreview { copiedFlash = true; return }
        guard let image = CodeCardImage.render(code: code, options: options, width: 760) else {
            Toast.show("图片生成失败", icon: "exclamationmark.triangle")
            return
        }
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.writeObjects([image])
        flashCopied(ok: ok, message: "已复制图片")
    }

    private func copyPlainText() {
        if isSettingsPreview { copiedFlash = true; return }
        let ok = CodeRichCopy.copyPlainText(CodeHighlighter.normalize(code, tabWidth: 4))
        flashCopied(ok: ok, message: "已复制纯文本")
    }

    private func copyHTMLSource() {
        if isSettingsPreview { copiedFlash = true; return }
        let payload = CodeRichCopy.makePayload(code, options: options, includeRTF: false)
        let ok = CodeRichCopy.copyPlainText(payload.html)
        flashCopied(ok: ok, message: "已复制 HTML 源码")
    }

    private func flashCopied(ok: Bool, message: String) {
        guard ok else {
            Toast.show("复制失败", icon: "exclamationmark.triangle")
            return
        }
        Toast.show(message, icon: "doc.on.doc")
        copiedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedFlash = false }
    }
}

// MARK: - NSTextView 承载（主题底色 + 行号标尺 + 横向滚动）

struct CodeTextViewRepresentable: NSViewRepresentable {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    let attributed: NSAttributedString
    let theme: CodeTheme
    let fontSize: CGFloat
    let showsLineNumbers: Bool
    let wraps: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodePreviewTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        textView.isSettingsPreview = isSettingsPreview
        textView.cardBackground = theme.background
        textView.cardBorder = theme.border
        textView.fontSize = fontSize
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.autoresizingMask = wraps ? [.width] : []
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        textView.wrapsEnabled = wraps
        if let container = textView.textContainer {
            container.widthTracksTextView = wraps
            // v191：换行时**不要**写 0 宽（会把文本排到容器外，屏幕一片空白）
            container.containerSize = wraps
                ? NSSize(width: max(160, textView.bounds.width - textView.textContainerInset.width * 2),
                         height: CGFloat.greatestFiniteMagnitude)
                : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.allowsUndo = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = true
        // v192.1：**必须用 100% 主题色**。
        // 上一版为了"玻璃感"降到 90%，结果浅色主题的纯白被窗口底污染成 #F5F5F7，
        // 深色主题也被抬灰——切主题时"背景变了、颜色却不对"就是这么来的。
        // 玻璃感由窗口圆角 + 阴影 + 工具条/行号槽的层次承担，不靠代码区透光。
        scrollView.backgroundColor = theme.background
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wraps
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let ruler = CodeLineNumberRuler(textView: textView, theme: theme, fontSize: fontSize)
        ruler.updateText(attributed.string)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = showsLineNumbers
        scrollView.rulersVisible = showsLineNumbers

        textView.textStorage?.setAttributedString(attributed)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        scrollView.backgroundColor = theme.background
        scrollView.hasHorizontalScroller = !wraps
        scrollView.hasVerticalRuler = showsLineNumbers
        scrollView.rulersVisible = showsLineNumbers

        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        if let codeView = textView as? CodePreviewTextView {
            codeView.isSettingsPreview = isSettingsPreview
            codeView.wrapsEnabled = wraps     // didSet 里会同步容器宽度
        }
        if let container = textView.textContainer {
            container.widthTracksTextView = wraps
            if !wraps {
                container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
            }
        }
        let ruler = scrollView.verticalRulerView as? CodeLineNumberRuler
        if textView.attributedString() != attributed {
            let offset = scrollView.contentView.bounds.origin
            let text = attributed.string
            if textView.string != text { ruler?.updateText(text) }
            textView.textStorage?.setAttributedString(attributed)
            scrollView.contentView.scroll(to: offset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if let ruler {
            ruler.theme = theme
            if ruler.fontSize != fontSize { ruler.fontSize = fontSize }
            ruler.needsDisplay = true
        }
        if let codeView = textView as? CodePreviewTextView {
            codeView.cardBackground = theme.background
            codeView.cardBorder = theme.border
            codeView.fontSize = fontSize
            codeView.wrapsEnabled = wraps
            codeView.syncWrapContainer()      // 同值不触发 didSet，这里兜底同步一次
        }
    }
}

// MARK: - 代码文本视图（⌘C 直接给富文本）
//
// 普通 NSTextView 的 ⌘C 只写纯文本 —— 工具条写着「⌘C 复制富文本」就自相矛盾了。
// 这里覆盖 copy：有选区就复制选区，没有就复制全文，并且同时写 HTML + RTF，
// 颜色/斜体沿用屏幕上已经渲染好的那份，不再二次着色。

final class CodePreviewTextView: NSTextView {
    var isSettingsPreview = false

    var cardBackground: NSColor = .textBackgroundColor
    var cardBorder: NSColor = .separatorColor
    var fontSize: CGFloat = 12.5

    /// v191（实测发现的 bug）：开自动换行后整篇代码变成空白，只剩行号。
    /// 根因是换行分支把 `containerSize.width` 设成了 **0** 再交给
    /// `widthTracksTextView` —— 首帧文本容器宽度就是 0，NSTextView 按 0 宽排版，
    /// 每行都排到容器外，屏幕上什么都不剩。
    /// 现在：容器宽度始终取「当前视图宽度 − 左右内边距」，并在每次改尺寸时同步。
    var wrapsEnabled = false {
        didSet { syncWrapContainer() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncWrapContainer()
    }

    /// 自动换行时把文本容器钉到可视宽度；关闭换行时放开成无限宽（横向滚动）
    func syncWrapContainer() {
        guard let container = textContainer else { return }
        if wrapsEnabled {
            let usable = bounds.width - textContainerInset.width * 2
            container.containerSize = NSSize(width: max(160, usable),
                                             height: CGFloat.greatestFiniteMagnitude)
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                             height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func copy(_ sender: Any?) {
        if isSettingsPreview { return }
        let selection = selectedRange()
        let full = NSRange(location: 0, length: textStorage?.length ?? 0)
        let range = selection.length > 0 ? selection : full
        guard range.length > 0,
              let slice = textStorage?.attributedSubstring(from: range) else {
            super.copy(sender)
            return
        }
        if CodeRichCopy.copyAttributed(slice,
                                       background: cardBackground,
                                       border: cardBorder,
                                       fontSize: fontSize) {
            Toast.show("已复制富文本", icon: "doc.on.doc")
        } else {
            super.copy(sender)
        }
    }
}

// MARK: - 行号标尺（按主题色绘制，跟随滚动）

final class CodeLineNumberRuler: NSRulerView {

    var theme: CodeTheme?
    var fontSize: CGFloat { didSet { updateThickness() } }
    private weak var attachedTextView: NSTextView?
    private var lineStarts = [0]

    init(textView: NSTextView, theme: CodeTheme? = nil, fontSize: CGFloat = 12) {
        self.attachedTextView = textView
        self.theme = theme
        self.fontSize = fontSize
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("CodeLineNumberRuler 不走 coder")
    }

    override var isFlipped: Bool { true }

    // 使用与 NSTextView 字符区间一致的 UTF-16 偏移。
    func updateText(_ text: String) {
        let content = text as NSString
        let length = content.length
        lineStarts = [0]
        var start = 0
        while start < length {
            var end = 0
            var contentsEnd = 0
            content.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                                 for: NSRange(location: start, length: 0))
            if contentsEnd < end { lineStarts.append(end) }
            start = end
        }
        updateThickness()
        needsDisplay = true
    }

    private func updateThickness() {
        let thickness = theme == nil ? 28 : CGFloat(max(2, String(lineStarts.count).count)) * (fontSize * 0.62) + 18
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        if let theme {
            theme.gutter.setFill()
            bounds.fill()
            theme.border.setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }

        guard let textView = attachedTextView,
              let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage,
              let container = textView.textContainer else { return }

        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }

        let attributes: [NSAttributedString.Key: Any]
        if let theme {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.lineBreakMode = .byClipping
            attributes = [.font: CodeHighlighter.font(size: max(8, fontSize * 0.78)),
                          .foregroundColor: theme.lineNumber, .paragraphStyle: paragraph]
        } else {
            attributes = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                          .foregroundColor: NSColor.secondaryLabelColor]
        }

        var low = 0
        var high = lineStarts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= charRange.location { low = middle }
            else { high = middle }
        }
        let inset: CGFloat = theme == nil ? 2 : 6
        let labelWidth = ruleThickness - (theme == nil ? 4 : 14)
        for i in low..<lineStarts.count {
            let start = lineStarts[i]
            if start >= NSMaxRange(charRange) { break }
            let end = i + 1 < lineStarts.count ? lineStarts[i + 1] : textStorage.length
            let lineRange = NSRange(location: start, length: end - start)
            let lineGlyph = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: lineGlyph.location, effectiveRange: nil)
            let y = fragment.minY - visible.minY + textView.textContainerInset.height
            ("\(i + 1)" as NSString).draw(in: NSRect(x: inset, y: y, width: labelWidth, height: fragment.height),
                                        withAttributes: attributes)
        }
    }
}

// MARK: - 窗口外观跟随主题（v192.1）

/// 让宿主窗口的 appearance / 底色跟随代码主题。
///
/// 为什么需要：窗口打开时只在当时保存的主题上设一次 `window.appearance`。
/// 用户随后在工具条里换主题时，代码区背景会重画，
/// 但窗口外观不会——于是出现「上黑下白」：深色主题打开、切成浅色主题后，
/// 标题栏还是深色（用户截图 2026-11-03）。
///
/// 这里把同步挂到视图树上：themeID 变化 → body 重算 → updateNSView → 改窗口外观。
/// 用 alphaValue=0 而不是 isHidden，保证视图确实在层级里（能拿到 window）。
private struct WindowThemeSync: NSViewRepresentable {
    let isDark: Bool
    let background: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.alphaValue = 0
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let name: NSAppearance.Name = isDark ? .darkAqua : .aqua
            if window.appearance?.name != name {
                window.appearance = NSAppearance(named: name)
            }
            // 窗口必须是"不透明"的：主题底色是完整色值，半透明会让标题栏与内容区
            // 采样到不同底衬，出现上下色差
            if window.isOpaque == false { window.isOpaque = true }
            if window.backgroundColor != background {
                window.backgroundColor = background
            }
        }
    }
}
