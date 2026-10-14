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
        if JSONHighlighter.prettify(trimmed) != nil, PreviewJSONPreferenceStore.shared.isEnabled { return .json }
        if PreviewMarkdownPreferenceStore.shared.isEnabled,
           trimmed.range(of: #"(?m)^\s*(#{1,6}\s|[-*+]\s|>\s|```|\d+\.\s)"#, options: .regularExpression) != nil {
            return .markdown
        }
        return .plain
    }
}

// MARK: - JSON 高亮（05 号规格 1.6：JSONHighlighter）

/// JSON 高亮：JSONSerialization 负责格式化（缩进/排序键），NSRegularExpression 负责着色。
/// 不使用外部依赖，全部为系统 API。
public enum JSONHighlighter {

    /// 规范化：能解析则输出 prettyPrinted 文本，否则返回 nil
    public static func prettify(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: pretty, encoding: .utf8) else { return nil }
        return string
    }

    public static func render(_ text: String, enabled: Bool = PreviewJSONPreferenceStore.shared.isEnabled) -> NSAttributedString {
        let source = (enabled ? (prettify(text) ?? text) : text)
        let result = NSMutableAttributedString(string: source,
                                               attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                            .foregroundColor: NSColor.labelColor])
        guard enabled else { return result }

        let full = NSRange(location: 0, length: (source as NSString).length)

        // ① 字符串：紧随冒号的视为 key，其余为字符串值
        if let strings = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#) {
            for match in strings.matches(in: source, range: full) {
                let keyRange = NSRange(location: match.range.upperBound,
                                       length: min(8, max(0, full.length - match.range.upperBound)))
                let tail = (source as NSString).substring(with: keyRange)
                let isKey = tail.range(of: #"^\s*:"#, options: .regularExpression) != nil
                result.addAttribute(.foregroundColor,
                                    value: isKey ? NSColor.systemPurple : NSColor.systemGreen,
                                    range: match.range)
            }
        }
        // ② 数字 / 字面量
        if let literals = try? NSRegularExpression(pattern: #"\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#) {
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

/// Markdown 渲染：用 `AttributedString` 逐 run 拼装，识别 标题 / 粗体 / 行内代码 / 代码块 / 列表。
/// 只覆盖常见的 5 类标记，不追求 CommonMark 全兼容（零外部依赖约束）。
public enum MarkdownCodeSyntaxHighlighter {

    public static func render(_ markdown: String, enabled: Bool = PreviewMarkdownPreferenceStore.shared.isEnabled) -> NSAttributedString {
        guard enabled else {
            return NSAttributedString(string: markdown,
                                      attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                   .foregroundColor: NSColor.labelColor])
        }

        var output = AttributedString()
        var isInsideCodeFence = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            // 围栏开关：``` 行本身不输出（与主流渲染器一致）
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInsideCodeFence.toggle()
                continue
            }

            if isInsideCodeFence {
                appendRun(line + "\n", container: codeContainer, to: &output)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                appendRun("\n", container: bodyContainer, to: &output)
                continue
            }

            // 标题：# 前导，最多 6 级
            if let level = headingLevel(of: trimmed) {
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                appendInline(text, container: headingContainer(level: level), to: &output)
                appendRun("\n", container: bodyContainer, to: &output)
                continue
            }

            // 列表项
            if let bullet = bulletPrefix(of: trimmed) {
                appendRun(bullet + " ", container: bulletContainer, to: &output)
                appendInline(String(trimmed.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces),
                             container: bodyContainer, to: &output)
                appendRun("\n", container: bodyContainer, to: &output)
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                appendInline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces),
                             container: quoteContainer, to: &output)
                appendRun("\n", container: bodyContainer, to: &output)
                continue
            }

            appendInline(trimmed, container: bodyContainer, to: &output)
            appendRun("\n", container: bodyContainer, to: &output)
        }

        return NSAttributedString(output)
    }

    // MARK: 样式容器

    private static var bodyContainer: AttributeContainer {
        var c = AttributeContainer()
        c.font = .system(size: 13)
        c.foregroundColor = Color(NSColor.labelColor)
        return c
    }

    private static var codeContainer: AttributeContainer {
        var c = AttributeContainer()
        c.font = .system(size: 12, design: .monospaced)
        c.foregroundColor = Color(NSColor.systemGray)
        return c
    }

    private static var bulletContainer: AttributeContainer {
        var c = AttributeContainer()
        c.font = .system(size: 13)
        c.foregroundColor = Color(NSColor.systemBlue)
        return c
    }

    private static var quoteContainer: AttributeContainer {
        var c = AttributeContainer()
        c.font = .system(size: 13)
        c.foregroundColor = Color(NSColor.systemGray)
        return c
    }

    private static func headingContainer(level: Int) -> AttributeContainer {
        var c = AttributeContainer()
        let size: CGFloat = [20, 17, 15, 14, 13, 13][min(max(level, 1), 6) - 1]
        c.font = .system(size: size, weight: .bold)
        c.foregroundColor = Color(NSColor.labelColor)
        return c
    }

    private static func inlineCodeContainer() -> AttributeContainer {
        var c = AttributeContainer()
        c.font = .system(size: 12, design: .monospaced)
        c.foregroundColor = Color(NSColor.systemOrange)
        return c
    }

    private static func boldContainer(base: AttributeContainer) -> AttributeContainer {
        var c = base
        c.font = .system(size: 13, weight: .bold)
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
        let pattern = #"(\*\*|__)(.+?)\1|`([^`]+)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
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
}

// MARK: - 富文本承载视图

/// NSTextView 承载：上万行文本也保持流畅（相比 SwiftUI Text 有数量级优势）
public struct AttributedTextView: NSViewRepresentable {

    public let attributed: NSAttributedString

    public init(_ attributed: NSAttributedString) {
        self.attributed = attributed
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textStorage?.setAttributedString(attributed)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.attributedString() != attributed {
            textView.textStorage?.setAttributedString(attributed)
        }
    }
}

// MARK: - 大文本预览（05 号规格 1.3：LargeTextPreviewContainerView）

public struct LargeTextPreviewView: View {

    public let text: String
    @Stored private var mode: LargeTextPreviewMode

    public init(text: String, mode: LargeTextPreviewMode? = nil) {
        self.text = text
        self._mode = Stored(wrappedValue: mode ?? LargeTextPreviewMode.infer(from: text))
    }

    public var body: some View {
        VStack(spacing: 8) {
            Picker("渲染", selection: $mode) {
                ForEach(LargeTextPreviewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            AttributedTextView(rendered)
                .frame(minHeight: 240)
        }
        .padding(12)
    }

    private var rendered: NSAttributedString {
        switch mode {
        case .plain:
            return NSAttributedString(string: text,
                                      attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                   .foregroundColor: NSColor.labelColor])
        case .markdown:
            return MarkdownCodeSyntaxHighlighter.render(text)
        case .json:
            return JSONHighlighter.render(text)
        }
    }
}

/// 条目级预览容器：自动取全文（长文本走落盘文件读取）
public struct LargeTextPreviewContainerView: View {

    public let item: ClipboardItem
    @Stored private var text: String = ""
    @Stored private var isLoaded = false

    public init(item: ClipboardItem) { self.item = item }

    public var body: some View {
        Group {
            if text.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 320, minHeight: 200)
            } else {
                LargeTextPreviewView(text: text)
            }
        }
        .navigationTitle(item.displayTitle)
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            text = ClipboardManager.shared.fullText(for: item)
        }
    }
}
