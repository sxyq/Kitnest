import AppKit

// MARK: - Markdown 块级渲染器（对齐逆向版 v82/v84/v97/v119）
//
// 逆向版（stats-recon/inject/frset_cardpreview.m）的渲染能力：
//   · 块级：标题层级 / 列表 / 引用 / 分隔线 / 代码块（fence 语言）/ 表格 / 流程图（mermaid·plantuml 简版）
//   · 代码语法高亮：VSCode 风格配色，12 语言（C/C++ Java Python Kotlin C# JS Swift Go Rust SQL Shell）
//     + 裸代码（无围栏）自动识别
//   · 行内富文本：粗体 / 斜体 / 行内代码（交给 AttributedString inline 解析）
//   · 可点击目录：标题自动生成，点击滚动到对应块
//   · 不改弹层尺寸；内部滚动（由 PreviewTextViewRepresentable 的 NSScrollView 承担）
//
// 本文件是上述能力的 Swift 重建：解析 → 块渲染 → 语法高亮 → 目录链接。
// 目录链接协议：frset-toc://loc=<字符位置>，由 PreviewTextViewRepresentable 拦截并滚动。

// MARK: - 块模型

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(indent: Int, ordered: Bool, marker: String, text: String)
    case quote(String)
    case divider
    case code(lang: String, code: String)
    case table(rows: [[String]])
}

// MARK: - 标题锚点（左侧目录用）

/// 一个可跳转的标题（location = 正文内字符偏移）
struct MarkdownHeading: Identifiable, Hashable {
    let level: Int
    let title: String
    let location: Int
    var id: Int { location }
    /// 目录缩进层级（H1 顶格，H2 缩进 10，H3 缩进 20，最多 3 级）
    var indent: CGFloat { CGFloat(max(0, min(2, level - 1))) * 10 }
}

// MARK: - 渲染器

enum PreviewMarkdownRenderer {

    /// 目录链接前缀（PreviewTextViewRepresentable 拦截）
    static let tocScheme = "frset-toc"

    // MARK: 缩放（2026-10-18 用户需求：整体文本部分 = 原来的 1.5 倍）
    //
    // 所有字号 / 行距 / 段距统一乘此系数；调用方无需改任何数值。
    // 注意：estimatedPopoverHeight 里的测高渲染也读同一系数（见 PreviewPopoverContentModel），
    // 保证"估算高度"与"实际渲染"一致，否则 popover 会裁切。
    static var scale: CGFloat = 1.5

    /// 字号/间距缩放辅助
    private static func s(_ value: CGFloat) -> CGFloat { value * scale }

    // MARK: 入口

    /// 把 markdown 文本渲染为带块级样式的富文本（含内联目录）。
    /// 注：预览弹层改用左侧目录侧栏，正文请走 `renderBody(_:)`；本方法保留给
    /// 需要「目录就在文首」的场景（导出/独立窗口）。
    static func render(_ text: String) -> NSAttributedString {
        let (body, headings) = renderBody(text)
        guard headings.count >= 2 else { return body }

        let offsetCandidate = renderTOC(headings.map { ($0.level, $0.title, $0.location) })
        let result = NSMutableAttributedString()
        result.append(offsetCandidate)
        let offset = result.length
        result.append(body)

        // 目录里的 loc 是正文内偏移——加上目录段长度才是整串位置
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: offset)) { value, range, _ in
            guard let url = value as? URL, url.scheme == tocScheme,
                  let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let locText = comp.queryItems?.first(where: { $0.name == "loc" })?.value,
                  let loc = Int(locText) else { return }
            var fixed = comp
            fixed.queryItems = [URLQueryItem(name: "loc", value: String(loc + offset))]
            if let newURL = fixed.url {
                result.addAttribute(.link, value: newURL, range: range)
            }
        }
        return result
    }

    /// 只渲染正文（不含内联目录），同时返回标题锚点——供左侧目录侧栏使用。
    static func renderBody(_ text: String) -> (body: NSAttributedString, headings: [MarkdownHeading]) {
        let blocks = parse(text)

        // 正文先渲染，记录标题位置（目录要用）
        var headingAnchors: [MarkdownHeading] = []
        let body = NSMutableAttributedString()
        for (idx, block) in blocks.enumerated() {
            let attr = render(block)
            if case .heading(let level, let title) = block {
                headingAnchors.append(MarkdownHeading(level: level, title: title, location: body.length))
            }
            body.append(attr)
            // 块间换行：块各自不带宽尾换行，这里统一补（缺了会所有块挤成一行）
            if idx < blocks.count - 1 {
                body.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
        }
        return (body, headingAnchors)
    }

    // MARK: 解析

    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        // 裸代码自动识别（v85）：无围栏且整体像代码 → 合成一个代码块
        if !normalized.contains("```"), looksLikeNakedCode(lines) {
            return [.code(lang: guessLanguage(lines), code: normalized)]
        }

        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 代码围栏
            if line.hasPrefix("```") {
                flushParagraph()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("```") { i += 1; break }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang: lang.lowercased(), code: code.joined(separator: "\n")))
                continue
            }

            // 空行
            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 标题
            if let m = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                flushParagraph()
                let hashes = line[line.startIndex..<m.upperBound].filter { $0 == "#" }.count
                let title = String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: hashes, text: title))
                i += 1
                continue
            }

            // 分隔线
            if line.range(of: "^([-*_])\\s*(\\1\\s*){2,}$", options: .regularExpression) != nil {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }

            // 引用（连续行合并）
            if line.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    quote.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            // 表格（连续 | 行）
            if line.hasPrefix("|") && line.hasSuffix("|") {
                flushParagraph()
                var rows: [[String]] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix("|"), l.hasSuffix("|") else { break }
                    if l.range(of: "^\\|[\\s:|-]+\\|$", options: .regularExpression) != nil {
                        i += 1; continue   // 分隔行
                    }
                    let cells = l.dropFirst().dropLast()
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    rows.append(cells)
                    i += 1
                }
                if !rows.isEmpty { blocks.append(.table(rows: rows)) }
                continue
            }

            // 列表
            if let m = line.range(of: "^(\\s*)([-*+]|\\d+[.)])\\s+", options: .regularExpression) {
                flushParagraph()
                let head = String(line[line.startIndex..<m.upperBound])
                let indentChars = head.prefix { $0 == " " || $0 == "\t" }.count
                let markerPart = String(line[m.lowerBound..<m.upperBound])
                let ordered = markerPart.trimmingCharacters(in: .whitespaces).first?.isNumber ?? false
                let marker = markerPart.trimmingCharacters(in: .whitespaces)
                let content = String(line[m.upperBound...])
                blocks.append(.listItem(indent: indentChars / 2, ordered: ordered, marker: marker, text: content))
                i += 1
                continue
            }

            // 普通段落
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        _ = lines
        return blocks
    }

    /// 裸代码启发式（对应 v85：无 ``` 但整体是代码）
    private static func looksLikeNakedCode(_ lines: [String]) -> Bool {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count >= 2 else { return false }
        let codeish = nonEmpty.filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("#include") || t.hasPrefix("import ")
                || t.hasPrefix("func ") || t.hasPrefix("let ") || t.hasPrefix("var ")
                || t.hasPrefix("def ") || t.hasPrefix("class ") || t.hasPrefix("struct ")
                || t.hasPrefix("return ") || t.hasPrefix("#!/") { return true }
            if t.hasSuffix(";") || t.hasSuffix("{") || t.hasSuffix("}") || t.hasSuffix(")") { return true }
            if t.contains(" = ") || t.contains("=>") || t.contains("->") { return true }
            return false
        }
        return Double(codeish.count) / Double(nonEmpty.count) >= 0.6
    }

    /// 裸代码语言猜测（只做高亮配色用；猜不到按通用处理）
    private static func guessLanguage(_ lines: [String]) -> String {
        let joined = lines.joined(separator: "\n")
        if joined.contains("#include") || joined.contains("std::") { return "cpp" }
        if joined.contains("def ") && joined.contains(":") { return "python" }
        if joined.contains("func ") && joined.contains("let ") { return "swift" }
        if joined.contains("import React") || joined.contains("const ") { return "js" }
        if joined.contains("SELECT ") || joined.contains("select ") { return "sql" }
        if joined.contains("#!/bin/") || joined.contains("echo ") { return "shell" }
        return ""
    }

    // MARK: 块渲染

    private static var baseSize: CGFloat { s(12.5) }
    private static var baseFont: NSFont { .systemFont(ofSize: baseSize) }
    private static var monoFont: NSFont { .monospacedSystemFont(ofSize: s(11.5), weight: .regular) }

    private static func paragraphStyle(lineSpacing: CGFloat = 2,
                                       before: CGFloat = 0,
                                       after: CGFloat = 3,
                                       headIndent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = s(lineSpacing)
        p.paragraphSpacingBefore = s(before)
        p.paragraphSpacing = s(after)
        p.headIndent = s(headIndent)
        p.firstLineHeadIndent = s(headIndent)
        return p
    }

    /// 行内 markdown（粗体/斜体/行内代码）→ 富文本；失败退回纯文本
    static func inlineAttributed(_ text: String, font: NSFont = baseFont) -> NSAttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        // 行内代码：等宽 + 浅底（AttributedString 已给 inlinePresentationIntent 的 code 情形）
        mutable.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let intent = value as? InlinePresentationIntent, intent.contains(.code) else { return }
            mutable.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular), range: range)
            mutable.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.07), range: range)
        }
        // 非粗体/斜体区间统一基字体（保留粗斜体字形）
        mutable.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let f = value as? NSFont else {
                mutable.addAttribute(.font, value: font, range: range)
                return
            }
            let traits = NSFontManager.shared.traits(of: f)
            var out = font
            if traits.contains(.boldFontMask) { out = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { out = NSFontManager.shared.convert(out, toHaveTrait: .italicFontMask) }
            mutable.addAttribute(.font, value: out, range: range)
        }
        return mutable
    }

    static func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let size: CGFloat = s(level <= 1 ? 16.5 : (level == 2 ? 14.5 : (level == 3 ? 13 : 12.5)))
            let font = NSFont.systemFont(ofSize: size, weight: level <= 3 ? .bold : .semibold)
            let attr = NSMutableAttributedString(attributedString: inlineAttributed(text, font: font))
            let ps = paragraphStyle(lineSpacing: 2, before: level <= 2 ? 10 : 7, after: 3)
            attr.addAttributes([.paragraphStyle: ps,
                                .foregroundColor: NSColor.labelColor],
                               range: NSRange(location: 0, length: attr.length))
            return attr

        case .paragraph(let text):
            let attr = NSMutableAttributedString(attributedString: inlineAttributed(text))
            let ps = paragraphStyle(lineSpacing: 2.4, after: 4)
            attr.addAttribute(.paragraphStyle, value: ps,
                              range: NSRange(location: 0, length: attr.length))
            return attr

        case .listItem(let indent, let ordered, let marker, let text):
            let bullet = ordered ? marker : "•"
            let head = String(repeating: "    ", count: indent) + bullet + "  "
            let font = baseFont
            let attr = NSMutableAttributedString(
                string: head,
                attributes: [.font: font,
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraphStyle(lineSpacing: 2, after: 1.5)])
            attr.append(inlineAttributed(text))
            return attr

        case .quote(let text):
            let font = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            let attr = NSMutableAttributedString(attributedString: inlineAttributed(text, font: font))
            let ps = paragraphStyle(lineSpacing: 2, before: 1, after: 4, headIndent: 12)
            attr.addAttributes([.paragraphStyle: ps,
                                .foregroundColor: NSColor.secondaryLabelColor],
                               range: NSRange(location: 0, length: attr.length))
            // 左侧引用条：在行首插一个竖线字形
            let bar = NSAttributedString(string: "▍ ", attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: ps
            ])
            let out = NSMutableAttributedString(attributedString: bar)
            out.append(attr)
            return out

        case .divider:
            let line = NSAttributedString(string: String(repeating: "─", count: 48), attributes: [
                .font: NSFont.systemFont(ofSize: s(9)),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraphStyle(lineSpacing: 0, before: 4, after: 4)
            ])
            return line

        case .code(let lang, let code):
            return renderCode(lang: lang, code: code)

        case .table(let rows):
            return renderTable(rows)
        }
    }

    // MARK: 代码块 + 语法高亮

    static func renderCode(lang: String, code: String) -> NSAttributedString {
        let lowered = lang.lowercased()
        let isDiagram = lowered.hasPrefix("mermaid") || lowered.hasPrefix("plantuml")

        // 流程图：真渲染成图片（不是把源码贴出来）
        if isDiagram, let image = MermaidRenderer.shared.image(for: code) {
            return renderDiagram(image: image, source: code)
        }

        let out = NSMutableAttributedString()
        // 语言标签（代码块美化：右上角小字，替代裸露的围栏标记）
        if !lang.isEmpty {
            out.append(NSAttributedString(string: lang + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: s(9), weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraphStyle(lineSpacing: 0, after: 1, headIndent: 6)
            ]))
        }

        let ps = paragraphStyle(lineSpacing: 1.5, before: 1, after: 5, headIndent: 6)
        let bg = NSColor.labelColor.withAlphaComponent(0.06)
        let lines = code.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let highlighted = highlight(line: line, lang: lang, font: monoFont)
            highlighted.addAttributes([.paragraphStyle: ps, .backgroundColor: bg],
                                      range: NSRange(location: 0, length: highlighted.length))
            out.append(highlighted)
            if idx < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: monoFont])) }
        }
        return out
    }

    /// 把流程图图片作为附件插入富文本；下方附一行可折叠的源码提示（灰色小字）
    private static func renderDiagram(image: NSImage, source: String) -> NSAttributedString {
        // 内容宽随 popover（480 - 2×18 边距 ≈ 444）；420 留余量防溢出
        let maxWidth: CGFloat = 420
        let scale = min(1, maxWidth / max(1, image.size.width))
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -2,
                                   width: image.size.width * scale,
                                   height: image.size.height * scale)
        let out = NSMutableAttributedString(attachment: attachment)
        out.addAttributes([.paragraphStyle: paragraphStyle(lineSpacing: 2, before: 6, after: 4)],
                          range: NSRange(location: 0, length: out.length))
        return out
    }

    // 12 语言关键字表（对应 v84：C/C++ Java Python Kotlin C# JS Swift Go Rust SQL Shell）
    private static let keywords: [String: Set<String>] = [
        "c": ["int","char","float","double","void","struct","enum","typedef","static","const","unsigned","signed","long","short","if","else","for","while","do","switch","case","default","break","continue","return","sizeof","goto","extern","volatile","inline"],
        "cpp": ["int","char","float","double","void","struct","class","enum","typedef","static","const","constexpr","unsigned","signed","long","short","if","else","for","while","do","switch","case","default","break","continue","return","sizeof","namespace","using","template","typename","public","private","protected","virtual","override","new","delete","nullptr","auto","true","false","try","catch","throw"],
        "java": ["public","private","protected","class","interface","extends","implements","static","final","void","int","long","double","float","boolean","char","String","if","else","for","while","do","switch","case","default","break","continue","return","new","null","true","false","try","catch","finally","throws","import","package","this","super","abstract","synchronized","volatile"],
        "python": ["def","class","import","from","as","if","elif","else","for","while","break","continue","return","yield","lambda","try","except","finally","raise","with","as","pass","None","True","False","and","or","not","in","is","global","nonlocal","assert","del","async","await"],
        "kotlin": ["fun","val","var","class","object","interface","data","sealed","enum","if","else","when","for","while","do","break","continue","return","try","catch","finally","throw","import","package","is","as","in","null","true","false","override","open","private","public","protected","internal","companion","init","constructor"],
        "csharp": ["public","private","protected","internal","class","struct","interface","enum","static","void","int","long","double","float","bool","string","char","var","if","else","for","foreach","while","do","switch","case","default","break","continue","return","new","null","true","false","try","catch","finally","throw","using","namespace","async","await","override","virtual","readonly","const"],
        "js": ["function","const","let","var","class","extends","if","else","for","while","do","switch","case","default","break","continue","return","new","null","undefined","true","false","try","catch","finally","throw","typeof","instanceof","async","await","import","export","from","of","in","this","super","yield","delete"],
        "swift": ["func","let","var","class","struct","enum","protocol","extension","import","if","else","guard","switch","case","default","for","while","repeat","break","continue","return","nil","true","false","try","catch","throw","throws","async","await","actor","some","any","in","where","self","super","init","deinit","public","private","fileprivate","internal","open","static","mutating","override","final","lazy","weak","unowned"],
        "go": ["func","package","import","var","const","type","struct","interface","map","chan","go","defer","select","switch","case","default","if","else","for","range","break","continue","return","nil","true","false","make","new","len","cap","append","copy","delete"],
        "rust": ["fn","let","mut","const","static","struct","enum","trait","impl","use","mod","pub","crate","self","super","if","else","match","for","while","loop","break","continue","return","true","false","Some","None","Ok","Err","unsafe","async","await","move","ref","type","where"],
        "sql": ["SELECT","FROM","WHERE","INSERT","INTO","VALUES","UPDATE","SET","DELETE","CREATE","TABLE","ALTER","DROP","INDEX","JOIN","LEFT","RIGHT","INNER","OUTER","ON","GROUP","BY","ORDER","HAVING","LIMIT","OFFSET","AS","AND","OR","NOT","NULL","IS","IN","LIKE","BETWEEN","DISTINCT","COUNT","SUM","AVG","MIN","MAX","PRIMARY","KEY","FOREIGN","REFERENCES","DEFAULT"],
        "shell": ["if","then","else","elif","fi","for","while","do","done","case","esac","function","return","exit","export","local","echo","cd","source","sudo","rm","mv","cp","ls","grep","awk","sed","cat","chmod","mkdir","pwd","set","unset","read","shift"]
    ]

    private static func normalizedLang(_ lang: String) -> String {
        switch lang {
        case "c++", "cc", "cxx", "hpp", "h": return "cpp"
        case "py": return "python"
        case "kt", "kts": return "kotlin"
        case "cs": return "csharp"
        case "javascript", "jsx", "ts", "tsx", "typescript": return "js"
        case "golang": return "go"
        case "rs": return "rust"
        case "sh", "bash", "zsh": return "shell"
        case "objective-c", "objc", "m": return "c"
        default: return lang
        }
    }

    /// 单行语法高亮（VSCode 风格配色；语义色随明暗自适应）
    static func highlight(line: String, lang: String, font: NSFont) -> NSMutableAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString(string: line, attributes: base)
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return out }

        let keywordColor = NSColor.systemPurple
        let stringColor = NSColor.systemRed
        let commentColor = NSColor.secondaryLabelColor
        let numberColor = NSColor.systemBlue
        let typeColor = NSColor.systemTeal

        // 注释（整行优先：// # -- /* *）
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("--")
            || (trimmed.hasPrefix("*") && !trimmed.hasPrefix("**")) || trimmed.hasPrefix("/*") {
            // 例外：markdown 标题已在上层分流；这里的 # 视为注释（shell/python）
            out.addAttribute(.foregroundColor, value: commentColor, range: full)
            return out
        }

        // 字符串
        let strPattern = "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'"
        if let re = try? NSRegularExpression(pattern: strPattern) {
            for m in re.matches(in: line, range: full) {
                out.addAttribute(.foregroundColor, value: stringColor, range: m.range)
            }
        }

        // 注释（行尾）
        if let range = line.range(of: "//") {
            let loc = line.distance(from: line.startIndex, to: range.lowerBound)
            if loc > 0 {
                // 不在字符串内才标（粗略：看前面引号数量）
                let prefix = String(line.prefix(loc))
                let quotes = prefix.filter { $0 == "\"" }.count
                if quotes % 2 == 0 {
                    out.addAttribute(.foregroundColor, value: commentColor, range: NSRange(location: loc, length: ns.length - loc))
                }
            }
        }

        // 数字
        if let re = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b") {
            for m in re.matches(in: line, range: full) {
                out.addAttribute(.foregroundColor, value: numberColor, range: m.range)
            }
        }

        // 关键字 / 类型
        let langKey = normalizedLang(lang)
        if let kw = keywords[langKey] {
            for word in kw {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                for m in re.matches(in: line, range: full) {
                    out.addAttribute(.foregroundColor, value: keywordColor, range: m.range)
                }
            }
        } else {
            // 未知语言：通用关键字集合（c+js 常见词）
            for word in ["if","else","for","while","return","func","function","class","struct","let","var","const","import","def","true","false","null","nil","new"] {
                let pattern = "\\b" + word + "\\b"
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                for m in re.matches(in: line, range: full) {
                    out.addAttribute(.foregroundColor, value: keywordColor, range: m.range)
                }
            }
        }

        // 类型名（大写开头，非全大写常量的词）
        if let re = try? NSRegularExpression(pattern: "\\b[A-Z][A-Za-z0-9_]{2,}\\b") {
            for m in re.matches(in: line, range: full) {
                let word = ns.substring(with: m.range)
                if word == word.uppercased() { continue }   // 常量不标
                out.addAttribute(.foregroundColor, value: typeColor, range: m.range)
            }
        }
        return out
    }

    // MARK: 表格

    private static func renderTable(_ rows: [[String]]) -> NSAttributedString {
        guard let first = rows.first else { return NSAttributedString() }
        let cols = rows.map(\.count).max() ?? first.count
        var widths = Array(repeating: 4, count: cols)
        for row in rows {
            for (c, cell) in row.enumerated() where c < cols {
                widths[c] = max(widths[c], cell.count)
            }
        }
        func pad(_ s: String, _ w: Int) -> String {
            let count = s.count
            return count >= w ? s : s + String(repeating: " ", count: w - count)
        }
        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            var line = ""
            for c in 0..<cols {
                let cell = c < row.count ? row[c] : ""
                line += pad(cell, widths[c]) + (c < cols - 1 ? " │ " : "")
            }
            let attr = NSMutableAttributedString(string: line, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: s(11), weight: r == 0 ? .semibold : .regular),
                .foregroundColor: r == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle(lineSpacing: 1.5, after: 1, headIndent: 4)
            ])
            out.append(attr)
            if r == 0 {
                out.append(NSAttributedString(string: String(repeating: "─", count: min(line.count, 60)) + "\n",
                                              attributes: [.font: NSFont.systemFont(ofSize: s(8)),
                                                           .foregroundColor: NSColor.tertiaryLabelColor]))
            } else if r < rows.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: monoFont]))
            }
        }
        return out
    }

    // MARK: 目录

    private static func renderTOC(_ anchors: [(level: Int, title: String, location: Int)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "目录\n", attributes: [
            .font: NSFont.systemFont(ofSize: s(10.5), weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle(lineSpacing: 2, after: 2)
        ]))
        for a in anchors {
            let indent = String(repeating: "  ", count: max(0, min(a.level - 1, 2)))
            let line = indent + "• " + a.title + "\n"
            var comp = URLComponents()
            comp.scheme = tocScheme
            comp.queryItems = [URLQueryItem(name: "loc", value: String(a.location))]
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: s(11.5)),
                .paragraphStyle: paragraphStyle(lineSpacing: 1.5, after: 0.5, headIndent: 4)
            ]
            if let url = comp.url {
                attrs[.link] = url
                attrs[.foregroundColor] = NSColor.labelColor
                attrs[.underlineStyle] = 0
            }
            out.append(NSAttributedString(string: line, attributes: attrs))
        }
        out.append(NSAttributedString(string: String(repeating: "─", count: 48) + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: s(9)),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle(lineSpacing: 0, before: 3, after: 5)
        ]))
        return out
    }
}
