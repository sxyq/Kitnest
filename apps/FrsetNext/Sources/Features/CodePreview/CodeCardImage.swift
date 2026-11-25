import AppKit

// MARK: - 代码卡片图（导出/分享用：圆角卡片 + 标题条 + 语法配色）
//
// 用途：工具箱「代码预览」的产物、以及需要贴到聊天窗口时的一键图片。
// 与屏幕上看到的完全同源（同一主题、同一词法、同一字体），避免"预览一套、导出另一套"。

public enum CodeCardImage {

    /// 2026-11-25（二轮复核 high）：lockFocusFlipped 是主线程 API（AppKit 绘制上下文）。
    /// 工具路径（ToolRegistry.run 是 nonisolated async）在后台线程调它 → 告警/空图，
    /// 并发时还可能踩 AppKit 线程断言。显式标 @MainActor，调用方切回主线程。
    @MainActor
    public static func render(code: String,
                              options: CodeRenderOptions,
                              width: CGFloat = 720) -> NSImage? {
        guard !code.isEmpty else { return nil }

        let padding: CGFloat = 16
        let headerHeight: CGFloat = 32
        let textWidth = max(120, width - padding * 2)
        let attributed = CodeHighlighter.exportAttributed(code, options: options)

        // 量高：与绘制使用同一个容器宽度，保证不截断
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.glyphRange(for: container)
        let textHeight = max(24, layout.usedRect(for: container).height)

        // 2026-11-25：高度必须有上限。3000 行 ≈ 5.2 万点，2x 下位图超 10 万像素高，
        // lockFocus 会直接失败（返回空图）。截断到 8192pt 并在卡片底部标注。
        let maxCardHeight: CGFloat = 8192
        let rawHeight = headerHeight + padding * 2 + textHeight
        let truncated = rawHeight > maxCardHeight
        let height = min(rawHeight, maxCardHeight)
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
        let lineCount = code.reduce(1) { count, character in
            character == "\n" || character == "\r" || character == "\r\n" ? count + 1 : count
        }
        let headerText = NSAttributedString(string: "\(languageName.uppercased())   ·   \(lineCount) 行", attributes: [
            .font: CodeHighlighter.font(size: 10, bold: true),
            .foregroundColor: theme.lineNumber,
            .kern: 0.6,
        ])
        headerText.draw(at: NSPoint(x: padding, y: (headerHeight - headerText.size().height) / 2))

        // 正文（超限时按可用高度裁切，末尾补一行提示）
        let bodyHeight = truncated ? max(24, height - headerHeight - padding * 2 - 18) : textHeight
        attributed.draw(in: NSRect(x: padding, y: headerHeight + padding,
                                   width: textWidth, height: bodyHeight))
        if truncated {
            NSAttributedString(string: "… 内容过长，卡片已截断", attributes: [
                .font: CodeHighlighter.font(size: 10, bold: true),
                .foregroundColor: theme.lineNumber,
            ]).draw(at: NSPoint(x: padding, y: height - padding - 14))
        }

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
