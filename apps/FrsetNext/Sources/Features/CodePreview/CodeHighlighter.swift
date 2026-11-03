import AppKit

// MARK: - 代码高亮渲染（词法 → 富文本）
//
// 一个入口同时服务三处：
//   ① 预览窗内的代码视图（屏幕渲染）
//   ② 复制为富文本（RTF / HTML，粘到 Word 保留配色）
//   ③ 独立「代码美化」窗
// 三者用**同一份** attributed 结果，保证「看到什么就复制到什么」。

public struct CodeRenderOptions {
    /// 已解析的语言 id（不是 "auto"）
    public var language: String
    public var theme: CodeTheme
    public var fontSize: CGFloat
    /// 屏幕渲染时行号由标尺画；导出/复制时需要把行号写进文本
    public var showsLineNumbers: Bool
    public var tabWidth: Int

    public init(language: String,
                theme: CodeTheme,
                fontSize: CGFloat = 12.5,
                showsLineNumbers: Bool = true,
                tabWidth: Int = 4) {
        self.language = language
        self.theme = theme
        self.fontSize = fontSize
        self.showsLineNumbers = showsLineNumbers
        self.tabWidth = tabWidth
    }
}

public enum CodeHighlighter {

    // MARK: 字体

    /// 代码字体：优先 Menlo（Word/macOS 都有，粘贴后不会换字形），退回系统等宽
    public static func font(size: CGFloat, bold: Bool = false) -> NSFont {
        let base = NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        guard bold else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    // MARK: 文本规范化

    /// 制表符展开 + 换行统一（行号与缩进对齐都依赖这一步）
    public static func normalize(_ code: String, tabWidth: Int) -> String {
        var text = code.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.contains("\t") {
            // 按列对齐展开：制表位是 tabWidth 的整数倍，而不是无脑替换
            var out = ""
            out.reserveCapacity(text.count + 64)
            var column = 0
            for ch in text {
                if ch == "\t" {
                    let pad = max(1, tabWidth - column % tabWidth)
                    out += String(repeating: " ", count: pad)
                    column += pad
                } else if ch == "\n" {
                    out.append(ch)
                    column = 0
                } else {
                    out.append(ch)
                    column += 1
                }
            }
            text = out
        }
        return text
    }

    public static func paragraphStyle(fontSize: CGFloat, headIndent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = (fontSize * 0.34).rounded()
        p.paragraphSpacing = 0
        // 不设 lineBreakMode：默认按词换行，容器宽度决定是否真的换行。
        // （早先设 .byClipping 会让「自动换行」开关彻底失效——容器再窄也裁掉不折行）
        p.headIndent = headIndent
        p.tabStops = []
        return p
    }

    // MARK: 屏幕渲染

    /// 屏幕用：行号由 NSTextView 的标尺绘制，正文不含行号
    public static func attributed(_ code: String, options: CodeRenderOptions) -> NSAttributedString {
        let text = normalize(code, tabWidth: options.tabWidth)
        let font = font(size: options.fontSize)
        let style = paragraphStyle(fontSize: options.fontSize)
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: options.theme.plain,
            .paragraphStyle: style,
        ])
        guard (text as NSString).length > 0 else { return result }

        let tokens = CodeLexer.tokens(in: text, language: options.language)
        let italicFont = italic(font)
        let full = NSRange(location: 0, length: (text as NSString).length)
        for token in tokens {
            let range = NSIntersectionRange(token.range, full)
            guard range.length > 0 else { continue }
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: options.theme.color(for: token.kind)
            ]
            if token.kind == .comment { attrs[.font] = italicFont }
            result.addAttributes(attrs, range: range)
        }
        return result
    }

    // MARK: 导出用（含行号）

    /// 复制/导出用：行号写进文本（Word 里没有标尺，只能靠字符对齐）
    public static func exportAttributed(_ code: String, options: CodeRenderOptions) -> NSAttributedString {
        let body = attributed(code, options: options)
        guard options.showsLineNumbers else { return body }

        let text = body.string as NSString
        let lineCount = max(1, text.components(separatedBy: "\n").count)
        let digits = String(lineCount).count
        let bodyFont = font(size: options.fontSize)
        let gutterFont = font(size: options.fontSize * 0.82)
        let gutterColor = options.theme.lineNumber

        let out = NSMutableAttributedString()
        var lineIndex = 0
        var location = 0
        while location <= text.length {
            var lineEnd = location
            while lineEnd < text.length && text.character(at: lineEnd) != 10 { lineEnd += 1 }
            let number = String(format: "%\(digits)d  ", lineIndex + 1)
            out.append(NSAttributedString(string: number, attributes: [
                .font: gutterFont, .foregroundColor: gutterColor,
            ]))
            out.append(body.attributedSubstring(from: NSRange(location: location, length: lineEnd - location)))
            if lineEnd < text.length {
                out.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            }
            lineIndex += 1
            location = lineEnd + 1
            if lineEnd >= text.length { break }
        }
        return out
    }

    // MARK: 统计

    public static func statistics(_ code: String) -> (lines: Int, characters: Int) {
        let normalized = code.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.isEmpty ? 1 : normalized.components(separatedBy: "\n").count
        return (lines, normalized.count)
    }

    /// 代码里最长一行（字符数），用于决定窗口默认宽度
    public static func longestLine(_ code: String) -> Int {
        code.replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
            .map(\.count)
            .max() ?? 0
    }
}
