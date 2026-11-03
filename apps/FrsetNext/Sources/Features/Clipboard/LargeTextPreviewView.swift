import AppKit
import Foundation
import SwiftUI

// MARK: - 渲染开关（05 号规格 1.6：Preview*PreferenceStore）

/// Markdown 渲染开关：关闭时大文本按纯文本呈现（长文档更省资源）
public final class PreviewMarkdownPreferenceStore: ObservableObject {
    public static let shared = PreviewMarkdownPreferenceStore()
    private static let key = "preview.markdown.enabled"

    private init() {}

    public var isEnabled: Bool {
        get { Preferences.shared.value(Self.key, default: true) }
        set { Preferences.shared.set(Self.key, newValue) }
    }
}

/// JSON 高亮开关：关闭时 JSON 按纯文本呈现
public final class PreviewJSONPreferenceStore: ObservableObject {
    public static let shared = PreviewJSONPreferenceStore()
    private static let key = "preview.json.enabled"

    private init() {}

    public var isEnabled: Bool {
        get { Preferences.shared.value(Self.key, default: true) }
        set { Preferences.shared.set(Self.key, newValue) }
    }
}

// MARK: - 预览模式

public enum LargeTextPreviewMode: String, CaseIterable, Identifiable {
    case plain, markdown, json
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .plain: return "纯文本"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        }
    }

    /// 自动推断：JSON 优先，其次疑似 Markdown，否则纯文本
    public static func infer(from text: String) -> LargeTextPreviewMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // v126（性能审计 F0756）：JSON 判定只解析不回写（原 prettify(...) != nil 白跑一次全量序列化）
        if JSONHighlighter.isParseableJSON(trimmed), PreviewJSONPreferenceStore.shared.isEnabled { return .json }
        if PreviewMarkdownPreferenceStore.shared.isEnabled,
           // v126（性能审计 F0756）：Markdown 特征正则改缓存编译（原先每次 infer 都重编译）
           // v127：特征加入表格行（|…|）——纯表格粘贴此前会误判为纯文本
           JSONHighlighter.cachedRe(#"(?m)^\s*(#{1,6}\s|[-*+]\s|>\s|```|\d+\.\s|\|.+\|)"#)?
            .firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
            return .markdown
        }
        return .plain
    }
}

// MARK: - JSON 高亮（05 号规格 1.6：JSONHighlighter）

/// JSON 高亮：JSONSerialization 负责格式化（缩进/排序键），NSRegularExpression 负责着色。
/// 不使用外部依赖，全部为系统 API。
public enum JSONHighlighter {

    // v126（性能审计 F0756/F0758/F0765）：正则编译缓存。
    // 渲染路径对每个字符串匹配都重新 NSRegularExpression(pattern:)，
    // 一篇大 JSON / 长 Markdown 就是上千次编译；按 pattern 静态缓存，命中后零成本。
    // fileprivate：同文件的 MarkdownCodeSyntaxHighlighter / LargeTextPreviewMode 复用同一份缓存。
    // 加锁：infer/render 可能在非主线程调用（预览准备阶段），缓存字典需线程安全。
    private static let _reLock = NSLock()
    private static var _reCache: [String: NSRegularExpression] = [:]
    fileprivate static func cachedRe(_ pattern: String) -> NSRegularExpression? {
        _reLock.lock(); defer { _reLock.unlock() }
        if let hit = _reCache[pattern] { return hit }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        _reCache[pattern] = re
        return re
    }

    /// 规范化：能解析则输出 prettyPrinted 文本，否则返回 nil
    public static func prettify(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: pretty, encoding: .utf8) else { return nil }
        return string
    }

    /// v126（性能审计 F0756）：只判「是不是 JSON」而不产出 pretty 文本。
    /// infer 原先调用 prettify(...) != nil —— 为拿一个 Bool 跑完整解析 + 重新序列化 + UTF8 解码，
    /// 大文本预览打开时白付一次全量编解码。改为只解析不回写。
    public static func isParseableJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    public static func render(_ text: String, enabled: Bool = PreviewJSONPreferenceStore.shared.isEnabled) -> NSAttributedString {
        let source = (enabled ? (prettify(text) ?? text) : text)
        let result = NSMutableAttributedString(string: source,
                                               attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                            .foregroundColor: NSColor.labelColor])
        guard enabled else { return result }

        let full = NSRange(location: 0, length: (source as NSString).length)

        // ① 字符串：紧随冒号的视为 key，其余为字符串值
        if let strings = Self.cachedRe(#""(?:\\.|[^"\\])*""#) {
            for match in strings.matches(in: source, range: full) {
                let keyRange = NSRange(location: match.range.upperBound,
                                       length: min(8, max(0, full.length - match.range.upperBound)))
                let tail = (source as NSString).substring(with: keyRange)
                // v126（性能审计 F0758）：key 判定改缓存正则（原先每个字符串匹配都重编译一次）
                let isKey = Self.cachedRe(#"^\s*:"#)?.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)) != nil
                result.addAttribute(.foregroundColor,
                                    value: isKey ? NSColor.systemPurple : NSColor.systemGreen,
                                    range: match.range)
            }
        }
        // ② 数字 / 字面量
        if let literals = Self.cachedRe(#"\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#) {
            for match in literals.matches(in: source, range: full) {
                let token = (source as NSString).substring(with: match.range)
                let isBoolOrNull = token == "true" || token == "false" || token == "null"
                result.addAttribute(.foregroundColor,
                                    value: isBoolOrNull ? NSColor.systemOrange : NSColor.systemBlue,
                                    range: match.range)
            }
        }
        return result
    }
}

// MARK: - Markdown 高亮（05 号规格 1.6：MarkdownCodeSyntaxHighlighter）

/// Markdown 渲染：用 `AttributedString` 逐 run 拼装，识别 标题 / 粗体 / 行内代码 / 代码块 / 列表 / 表格。
/// 只覆盖常见的 6 类标记，不追求 CommonMark 全兼容（零外部依赖约束）。
public enum MarkdownCodeSyntaxHighlighter {

    public static func render(_ markdown: String, enabled: Bool = PreviewMarkdownPreferenceStore.shared.isEnabled) -> NSAttributedString {
        guard enabled else {
            return NSAttributedString(string: markdown,
                                      attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                   .foregroundColor: NSColor.labelColor])
        }

        // v127：表格块用 NSTextTable 真网格（列宽自适应 + 换行 + 边框自绘），
        // 其余行仍走 AttributedString 拼装——遇表格时 flush 已拼内容再衔接。
        let result = NSMutableAttributedString()
        var output = AttributedString()
        var isInsideCodeFence = false
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // 围栏开关：``` 行本身不输出（与主流渲染器一致）
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInsideCodeFence.toggle()
                i += 1
                continue
            }

            if isInsideCodeFence {
                appendRun(line + "\n", container: codeContainer, to: &output)
                i += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                appendRun("\n", container: bodyContainer, to: &output)
                i += 1
                continue
            }

            // 标题：# 前导，最多 6 级
            if let level = headingLevel(of: trimmed) {
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                appendInline(text, container: headingContainer(level: level), to: &output)
                appendRun("\n", container: bodyContainer, to: &output)
                i += 1
                continue
            }

            // 表格块（v127）：表头行 + 分隔行 + 数据行 → NSTextTable 真表格
            if isTableRowLine(trimmed), i + 1 < lines.count,
               isTableSeparatorLine(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                var block: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isTableRowLine(t) else { break }
                    block.append(t)
                    i += 1
                }
                if !output.characters.isEmpty {
                    result.append(NSAttributedString(output))
                    output = AttributedString()
                }
                result.append(tableAttributedString(block))
                continue
            }

            // 列表项
            if let bullet = bulletPrefix(of: trimmed) {
                appendRun(bullet + " ", container: bulletContainer, to: &output)
                appendInline(String(trimmed.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces),
                             container: bodyContainer, to: &output)
                appendRun("\n", container: bodyContainer, to: &output)
                i += 1
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                appendInline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces),
                             container: quoteContainer, to: &output)
                appendRun("\n", container: bodyContainer, to: &output)
                i += 1
                continue
            }

            appendInline(trimmed, container: bodyContainer, to: &output)
            appendRun("\n", container: bodyContainer, to: &output)
            i += 1
        }

        if !output.characters.isEmpty { result.append(NSAttributedString(output)) }
        return result
    }

    // MARK: 样式容器
    //
    // v127 关键修复：此前用 SwiftUI 作用域（c.font = SwiftUI.Font）——实测
    // AttributedString → NSAttributedString 桥接后字体停留在 "SwiftUI.Font" 自定义键，
    // NSTextView **不识别**（textStorage 读回 .font = nil）→ 预览的标题/粗体/配色
    // 全部被静默丢弃，表格的等宽对齐同样会失效。改用 AppKit 作用域
    // （c.appKit.font / .foregroundColor），桥接即原生 NSAttributedString.Key。

    private static var bodyContainer: AttributeContainer {
        var c = AttributeContainer()
        c.appKit.font = .systemFont(ofSize: 13)
        c.appKit.foregroundColor = .labelColor
        return c
    }

    private static var codeContainer: AttributeContainer {
        var c = AttributeContainer()
        c.appKit.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        c.appKit.foregroundColor = .systemGray
        return c
    }

    private static var bulletContainer: AttributeContainer {
        var c = AttributeContainer()
        c.appKit.font = .systemFont(ofSize: 13)
        c.appKit.foregroundColor = .systemBlue
        return c
    }

    private static var quoteContainer: AttributeContainer {
        var c = AttributeContainer()
        c.appKit.font = .systemFont(ofSize: 13)
        c.appKit.foregroundColor = .systemGray
        return c
    }

    private static func headingContainer(level: Int) -> AttributeContainer {
        var c = AttributeContainer()
        let size: CGFloat = [20, 17, 15, 14, 13, 13][min(max(level, 1), 6) - 1]
        c.appKit.font = .systemFont(ofSize: size, weight: .bold)
        c.appKit.foregroundColor = .labelColor
        return c
    }

    private static func inlineCodeContainer() -> AttributeContainer {
        var c = AttributeContainer()
        c.appKit.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        c.appKit.foregroundColor = .systemOrange
        return c
    }

    private static func boldContainer(base: AttributeContainer) -> AttributeContainer {
        var c = base
        let size = base.appKit.font?.pointSize ?? 13
        c.appKit.font = .systemFont(ofSize: size, weight: .bold)
        return c
    }

    // MARK: 行解析

    private static func headingLevel(of line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6, line.count > count else { return nil }
        // "#hashtag" 不是标题（# 后必须有空格）
        let after = line.dropFirst(count)
        guard after.first?.isWhitespace == true || after.first == "#" else { return nil }
        return count
    }

    private static func bulletPrefix(of line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return "•" }
        return nil
    }

    /// 行内标记：**粗体** / __粗体__ / `代码`
    private static func appendInline(_ text: String, container: AttributeContainer, to output: inout AttributedString) {
        // v126（性能审计 F0765）：每行都重新编译同一份行内正则（长文档数千次编译），改走缓存
        guard let regex = JSONHighlighter.cachedRe(#"(\*\*|__)(.+?)\1|`([^`]+)`"#) else {
            appendRun(text, container: container, to: &output)
            return
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: full)
        if matches.isEmpty {
            appendRun(text, container: container, to: &output)
            return
        }
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let plain = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                appendRun(plain, container: container, to: &output)
            }
            if match.range(at: 3).location != NSNotFound {
                // 行内代码
                let code = ns.substring(with: match.range(at: 3))
                appendRun(code, container: inlineCodeContainer(), to: &output)
            } else if match.range(at: 2).location != NSNotFound {
                // 粗体（剔除 ** / __ 定界符）
                let bold = ns.substring(with: match.range(at: 2))
                appendRun(bold, container: boldContainer(base: container), to: &output)
            } else {
                appendRun(ns.substring(with: match.range), container: container, to: &output)
            }
            cursor = match.range.upperBound
        }
        if cursor < ns.length {
            appendRun(ns.substring(from: cursor), container: container, to: &output)
        }
    }

    private static func appendRun(_ text: String, container: AttributeContainer, to output: inout AttributedString) {
        guard !text.isEmpty else { return }
        var run = AttributedString(text)
        run.setAttributes(container)
        output.append(run)
    }

    // MARK: 表格（v127：主页预览 Markdown 表格渲染修复）

    /// 表格行：以 | 开头（收尾 | 可选；单元格内转义 \| 不支持——预览场景可接受）
    private static func isTableRowLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.count >= 2
    }

    /// 分隔行：所有单元格都是 `---` / `:---:` 形态
    private static func isTableSeparatorLine(_ trimmed: String) -> Bool {
        guard isTableRowLine(trimmed) else { return false }
        let cells = parseTableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy {
            $0.range(of: #"^\s*:?-+:?\s*$"#, options: .regularExpression) != nil
        }
    }

    private static func parseTableCells(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Excel 风格真表格：NSTextTable 网格布局——列宽自适应内容、长文本在格内自动换行、
    /// 表头底纹加粗。**边框由 AttributedTextView 的网格绘制补上**（TextKit 文字表格
    /// 不自绘边框，运行时也无边框宽度 API，见 PreviewTextView.draw）。
    private static func tableAttributedString(_ block: [String]) -> NSAttributedString {
        guard block.count >= 2 else { return NSAttributedString() }
        let header = parseTableCells(block[0])
        let body = block.dropFirst(2).map(parseTableCells)
        let columnCount = max(header.count, body.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.collapsesBorders = false
        // 边框颜色给到块上（实际画线在 PreviewTextView，颜色配置保持一致来源）
        for edge: NSRectEdge in [.minX, .maxX, .minY, .maxY] {
            table.setBorderColor(NSColor.separatorColor, for: edge)
        }

        let doc = NSMutableAttributedString()
        func emit(_ cells: [String], row: Int, isHeader: Bool) {
            for col in 0..<columnCount {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                             startingColumn: col, columnSpan: 1)
                if isHeader {
                    block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08)
                }
                let para = NSMutableParagraphStyle()
                para.textBlocks = [block]
                para.paragraphSpacing = 0
                para.lineSpacing = 2
                let text = col < cells.count ? cells[col] : " "
                doc.append(NSAttributedString(
                    string: " " + text + " ",
                    attributes: [
                        .font: isHeader ? NSFont.systemFont(ofSize: 12, weight: .semibold)
                                        : NSFont.systemFont(ofSize: 12),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: para,
                    ]))
                // 单元格 = 段落：必须有段落分隔符，textBlocks 才能按格定位
                doc.append(NSAttributedString(string: "\n"))
            }
        }
        emit(header, row: 0, isHeader: true)
        for (r, row) in body.enumerated() { emit(row, row: r + 1, isHeader: false) }
        return doc
    }
}

// MARK: - 富文本承载视图

/// NSTextView 承载：上万行文本也保持流畅（相比 SwiftUI Text 有数量级优势）
public struct AttributedTextView: NSViewRepresentable {

    public let attributed: NSAttributedString

    public init(_ attributed: NSAttributedString) {
        self.attributed = attributed
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = PreviewTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textStorage?.setAttributedString(attributed)
        textView.refreshGridCache()
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PreviewTextView else { return }
        if textView.attributedString() != attributed {
            textView.textStorage?.setAttributedString(attributed)
            textView.refreshGridCache()
        }
    }
}

// MARK: - 预览文本视图（v127：为 Markdown 表格补画单元格边框）

/// TextKit 的 NSTextTable 只做网格布局、**不自绘边框**（运行时无边框宽度 API）。
/// 本子类在 draw 里遍历段落携带的 textBlocks，用 layoutManager 取每个单元格的
/// 精确矩形并描边——配合表头底纹即完整 Excel 观感。
final class PreviewTextView: NSTextView {

    /// 单元格矩形缓存（container 坐标，含 textContainerOrigin 偏移）
    private var gridRects: [NSRect] = []
    private var gridCacheSource: NSAttributedString?

    /// 重新收集全文 textBlocks 矩形（文本替换/宽度变化后调用）
    func refreshGridCache() {
        guard let storage = textStorage, let lm = layoutManager, let container = textContainer else {
            gridRects = []
            gridCacheSource = textStorage
            return
        }
        gridCacheSource = storage
        var rects: [NSRect] = []
        let full = NSRange(location: 0, length: storage.length)
        // 单元格内容都带独立 paragraphStyle，run 级枚举对无样式大文本只命中少量 run
        storage.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, charRange, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
            for block in style.textBlocks {
                let rect = lm.boundsRect(for: block, glyphRange: glyphRange)
                rects.append(rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            }
        }
        gridRects = rects
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if gridCacheSource !== textStorage { refreshGridCache() }
        guard !gridRects.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1.0)
        for rect in gridRects where rect.intersects(dirtyRect) {
            ctx.stroke(rect.integral.insetBy(dx: -0.5, dy: -0.5))
        }
        ctx.restoreGState()
    }

    override func layout() {
        super.layout()
        // 宽度变化 → 单元格矩形变化（只重算矩形，不重排文本）
        if gridCacheSource === textStorage {
            refreshGridCache()
            needsDisplay = true
        }
    }
}

