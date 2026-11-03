import AppKit

// MARK: - 代码卡片图（导出/分享用：圆角卡片 + 标题条 + 语法配色）
//
// 用途：工具箱「代码预览」的产物、以及需要贴到聊天窗口时的一键图片。
// 与屏幕上看到的完全同源（同一主题、同一词法、同一字体），避免"预览一套、导出另一套"。

public enum CodeCardImage {

    public static func render(code: String,
                              options: CodeRenderOptions,
                              width: CGFloat = 720) -> NSImage? {
        let normalized = CodeHighlighter.normalize(code, tabWidth: options.tabWidth)
        guard !normalized.isEmpty else { return nil }

        let padding: CGFloat = 16
        let headerHeight: CGFloat = 32
        let textWidth = max(120, width - padding * 2)
        let attributed = CodeHighlighter.exportAttributed(normalized, options: options)

        // 量高：与绘制使用同一个容器宽度，保证不截断
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.glyphRange(for: container)
        let textHeight = max(24, layout.usedRect(for: container).height)

        let height = headerHeight + padding * 2 + textHeight
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        let theme = options.theme
        let rect = NSRect(origin: .zero, size: size)
        let radius: CGFloat = Theme.Radius.window

        // 卡片底
        let card = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        theme.background.setFill()
        card.fill()
        ctx.saveGState()
        card.addClip()

        // 标题条
        theme.gutter.setFill()
        NSRect(x: 0, y: 0, width: width, height: headerHeight).fill()
        theme.border.setFill()
        NSRect(x: 0, y: headerHeight - 1, width: width, height: 1).fill()

        let languageName = CodeLanguageCatalog.displayName(options.language)
        let lineCount = CodeHighlighter.statistics(normalized).lines
        let headerText = NSAttributedString(string: "\(languageName.uppercased())   ·   \(lineCount) 行", attributes: [
            .font: CodeHighlighter.font(size: 10, bold: true),
            .foregroundColor: theme.lineNumber,
            .kern: 0.6,
        ])
        headerText.draw(at: NSPoint(x: padding, y: (headerHeight - headerText.size().height) / 2))

        // 正文
        attributed.draw(in: NSRect(x: padding, y: headerHeight + padding,
                                   width: textWidth, height: textHeight))

        // 细边框（避免浅色主题在白色背景上"没有边界"）
        ctx.restoreGState()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        theme.border.setStroke()
        border.stroke()

        image.unlockFocus()
        return image
    }
}
