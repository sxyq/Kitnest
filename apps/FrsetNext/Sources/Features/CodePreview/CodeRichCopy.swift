import AppKit

// MARK: - 富文本复制（粘到 Word / Pages / 备忘录 / 邮件里保留配色）
//
// 只写纯文本 = 用户拿到的是一坨灰字，还得自己重排；这里同时放三种类型：
//   · public.html  → Word / Pages / 飞书 优先取它（能带整块底色，最接近截图效果）
//   · public.rtf   → 不支持 HTML 的富文本编辑器兜底（颜色/字体保留）
//   · public.utf8-plain-text → 纯文本编辑器
// 整块底色靠 HTML 的表格单元格实现；RTF 用字符背景色近似（Word 会渲染成字符底纹）。

public enum CodeRichCopy {

    // MARK: 入口

    /// 复制为富文本（主按钮／⌘C）
    @discardableResult
    public static func copyRichText(_ code: String, options: CodeRenderOptions) -> Bool {
        let payload = makePayload(code, options: options)
        return write(html: payload.html, rtf: payload.rtf, plain: payload.plain)
    }

    /// 复制「当前已有的」富文本（预览器里选中一段时用：颜色/字重沿用屏幕上的渲染结果）
    @discardableResult
    public static func copyAttributed(_ attributed: NSAttributedString,
                                      background: NSColor,
                                      border: NSColor,
                                      fontSize: CGFloat = 12.5) -> Bool {
        guard attributed.length > 0 else { return false }
        let firstColor = attributed.length > 0
            ? (attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            : nil
        let html = makeHTML(spansHTML(attributed),
                            background: background,
                            border: border,
                            gutter: background.blended(withFraction: 0.06, of: .white) ?? background,
                            textColor: firstColor ?? .labelColor,
                            mutedColor: background.blended(withFraction: 0.45, of: .gray) ?? .gray,
                            header: nil,
                            fontSize: fontSize,
                            tabWidth: 4)
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.backgroundColor, value: background, range: full)
        let rtf = mutable.rtf(from: full,
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return write(html: html, rtf: rtf, plain: attributed.string)
    }

    /// 复制为纯文本（保留内容，不带格式）
    @discardableResult
    public static func copyPlainText(_ code: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(code, forType: .string)
    }

    private static func write(html: String, rtf: Data?, plain: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(html, forType: .html)
        if let rtf { item.setData(rtf, forType: .rtf) }
        item.setString(plain, forType: .string)
        return pasteboard.writeObjects([item])
    }

    // MARK: 载荷

    public struct Payload {
        public let html: String
        public let rtf: Data?
        public let plain: String
    }

    public static func makePayload(_ code: String, options: CodeRenderOptions) -> Payload {
        let attributed = CodeHighlighter.exportAttributed(code, options: options)
        let theme = options.theme
        let html = makeHTML(spansHTML(attributed),
                            background: theme.background,
                            border: theme.border,
                            gutter: theme.gutter,
                            textColor: theme.plain,
                            mutedColor: theme.lineNumber,
                            header: "\(CodeLanguageCatalog.displayName(options.language)) · \(CodeHighlighter.statistics(code).lines) 行",
                            fontSize: options.fontSize,
                            tabWidth: options.tabWidth)
        let rtf = makeRTF(attributed, background: theme.background)
        let plain = attributed.string
        return Payload(html: html, rtf: rtf, plain: plain)
    }

    // MARK: RTF

    private static func makeRTF(_ attributed: NSAttributedString, background: NSColor) -> Data? {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)
        guard full.length > 0 else { return nil }
        // 整块底色：RTF 没有「卡片」，用字符底纹近似（Word 里是一条贴着文字的底色带）
        mutable.addAttribute(.backgroundColor, value: background, range: full)
        return mutable.rtf(from: full,
                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: HTML

    /// 把富文本逐 run 转成 span（颜色 + 斜体），换行交给 <pre>
    private static func spansHTML(_ attributed: NSAttributedString) -> String {
        var spans = ""
        let ns = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let escaped = escapeHTML(ns.substring(with: range))
            var styles: [String] = []
            if let color = attrs[.foregroundColor] as? NSColor {
                styles.append("color:\(color.codeHexString)")
            }
            if let font = attrs[.font] as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
                styles.append("font-style:italic")
            }
            if styles.isEmpty {
                spans += escaped
            } else {
                spans += "<span style=\"\(styles.joined(separator: ";"))\">\(escaped)</span>"
            }
        }
        return spans
    }

    private static func makeHTML(_ spans: String,
                                 background: NSColor,
                                 border: NSColor,
                                 gutter: NSColor,
                                 textColor: NSColor,
                                 mutedColor: NSColor,
                                 header: String?,
                                 fontSize: CGFloat,
                                 tabWidth: Int) -> String {
        let fontStack = "Menlo,SFMono-Regular,Consolas,'Liberation Mono',monospace"
        let headerRow: String
        if let header {
            headerRow = """
            <tr><td style="padding:7px 14px;background:\(gutter.codeHexString);\
            border-bottom:1px solid \(border.codeHexString);\
            font-family:\(fontStack);font-size:10px;letter-spacing:0.08em;text-transform:uppercase;\
            color:\(mutedColor.codeHexString);">\
            \(escapeHTML(header))</td></tr>
            """
        } else {
            headerRow = ""
        }
        return """
        <html><head><meta charset="utf-8"></head><body \
        style="margin:0;background:transparent;"><!--StartFragment-->
        <table cellspacing="0" cellpadding="0" border="0" \
        style="border-collapse:separate;border-spacing:0;background:\(background.codeHexString);\
        border:1px solid \(border.codeHexString);border-radius:8px;overflow:hidden;">
        \(headerRow)
        <tr><td style="padding:12px 16px;">
        <pre style="margin:0;font-family:\(fontStack);font-size:\(Int(fontSize.rounded()))px;\
        line-height:\(String(format: "%.1f", fontSize * 1.5))px;color:\(textColor.codeHexString);\
        white-space:pre;tab-size:\(tabWidth);">\(spans)</pre>
        </td></tr></table><!--EndFragment--></body></html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }
}
