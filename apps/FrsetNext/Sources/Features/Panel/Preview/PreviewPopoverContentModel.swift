import AppKit
import Foundation
import SwiftUI

// MARK: - 预览内容模型（specs/12 §4.4，PreviewPopoverContentModel）
//
// 职责：持有条目 + 分态（文本/落盘长文/Markdown/JSON/代码/图片/文件）+ 会话信息，
// 并提供内容资格判定（JSON eligibility / Markdown / 代码启发式）与 popover 高度估算。

public struct PreviewPopoverContentModel: Identifiable {

    /// 呈现来源（case 名实证 @0x100aecdb6 / @0x100aecde2）
    public enum Source: String {
        case mainPreview
        case floatingPreview
    }

    /// 入口多态（specs/12 F19：主列表 / 过滤会话 / 搜索工具结果）
    public enum Entry: String {
        case mainList
        case filterSession
        case searchToolResult
    }

    /// 内容分态
    public enum Kind: Equatable {
        case text                     // 短文本（内联）
        case fileBackedText           // 落盘长文本（异步加载，F17）
        case markdown                 // Markdown（滚动记忆恢复，F15）
        case json                     // JSON（资格判定 + 字符截断，F16）
        case code                     // 代码（尺寸阶梯，F14）
        case image                    // 图片（PreviewImageLoader + QR 分支，F12/F13）
        case file                     // 文件条目（路径列表）
        case richText                 // 富文本（v65：RTF 保真渲染，不再降级纯文本）
    }

    public let id: String             // 沿用 item.id
    public let item: ClipboardItem
    public let source: Source
    public let entry: Entry
    public let sessionID: UUID        // __previewSessionID（F9，每次呈现新会话）
    public let kind: Kind
    /// 已就绪的全文（短文本直接带上；fileBackedText 这里只放内联前缀，全文由视图异步加载）
    public let inlineText: String
    /// 是否显示键盘预览一次性提示（F6：clipboard_keyboard_preview_hint_consumed 未消费时）
    public let showsKeyboardHint: Bool

    public init(item: ClipboardItem,
                source: Source,
                entry: Entry = .mainList,
                sessionID: UUID,
                inlineText: String,
                showsKeyboardHint: Bool = false,
                kindOverride: Kind? = nil) {
        self.id = item.id
        self.item = item
        self.source = source
        self.entry = entry
        self.sessionID = sessionID
        self.inlineText = inlineText
        self.showsKeyboardHint = showsKeyboardHint
        // v53：常驻预览窗编辑保存后，内容已在内存里（可能是刚落盘的新文件），
        // 按条目分类会走 fileBackedText 去读旧路径 → 用 kindOverride 直接指定渲染态。
        self.kind = kindOverride ?? PreviewPopoverContentModel.classify(item: item, fullText: inlineText)
    }

    /// v53：纯文本内容分态（不看条目的 textPath）——编辑保存后的即时预览用
    ///
    /// v182（用户：「剪贴栏里复制的 Python 代码没有正确展现」）：
    /// 原顺序是 Markdown → 代码，而 Python 的 `__init__` / `__future__` 命中
    /// 「__ 加粗」弱信号（两行即够阈值），整个 .py 文件被当文档渲染。
    /// 现在先看代码强度：**代码感强且 Markdown 强信号 ≤1 条**就按代码渲染。
    public static func classifyRawText(_ text: String) -> Kind {
        if isJSONPreviewEligible(text) { return .json }
        let strength = codeStrength(text)
        if strength.ratio >= 0.55 && strength.lines >= 3 && markdownStrongCount(text) <= 1 {
            return .code
        }
        if looksLikeMarkdown(text) { return .markdown }
        if strength.ratio >= 0.45 && strength.lines >= 3 { return .code }
        if looksLikeCode(text) { return .code }
        return .text
    }

    /// 命中的 Markdown 强信号条数（标题/围栏/列表/引用/表格/粗体/行内码/链接/分隔线）
    public static func markdownStrongCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        var hits = 0
        for re in markdownStrongRegexes where re.firstMatch(in: trimmed, options: [], range: range) != nil {
            hits += 1
        }
        return hits
    }

    /// 代码强度：前 80 行非空行里「像代码」的比例（0…1）与样本行数
    public static func codeStrength(_ text: String) -> (ratio: Double, lines: Int) {
        let sample = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(80)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !sample.isEmpty else { return (0, 0) }
        var codey = 0
        for t in sample {
            // Markdown 结构行不算代码（`# 注释` 除外：`#!` / `#include` 走代码）
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
                || t.hasPrefix("> ") || t.hasPrefix("|")
                || (t.hasPrefix("#") && !t.hasPrefix("#!")) {
                continue
            }
            if isCodeLine(t) { codey += 1 }
        }
        return (Double(codey) / Double(sample.count), sample.count)
    }

    private static func isCodeLine(_ t: String) -> Bool {
        let prefixes = [
            "def ", "class ", "import ", "from ", "return ", "if ", "elif ", "else:",
            "for ", "while ", "try:", "except", "finally:", "with ", "lambda ", "async ",
            "await ", "yield ", "pass", "raise ", "assert ", "global ", "nonlocal ",
            "func ", "struct ", "enum ", "extension ", "guard ", "switch ", "case ",
            "public ", "private ", "internal ", "static ", "let ", "var ", "const ",
            "function ", "=>", "console.", "SELECT ", "INSERT ", "UPDATE ", "DELETE ",
            "CREATE ", "package ", "using ", "namespace ", "fn ", "impl ", "pub ",
            "#include", "#import", "#!", "@", "self.", "this.", "do ", "then", "end "
        ]
        for p in prefixes where t.hasPrefix(p) { return true }
        if t.hasSuffix(":") || t.hasSuffix("{") || t.hasSuffix("}") || t.hasSuffix(";")
            || t.hasSuffix(",") || t.hasSuffix(")") || t.hasSuffix("*/") { return true }
        if t.hasPrefix("    ") || t.hasPrefix("\t") { return true }
        if t.contains(" = ") || t.contains("==") || t.contains("->") || t.contains("=>") { return true }
        return false
    }

    // MARK: 分态判定

    /// 内容分态判定：图片/文件按条目类型；文本类按启发式细分（Markdown/JSON/代码/纯文本）
    ///
    /// v87（2026-10-20 用户反馈「预览不统一：有些没用 Markdown 展现、目录不是都有」）：
    /// 文本类**全部**走同一条启发式链（classifyRawText：JSON → Markdown → 代码 → 纯文本），
    /// 不再因「富文本无 RTF 数据」等路径短路成纯文本。
    public static func classify(item: ClipboardItem, fullText: String) -> Kind {
        switch item.type {
        case .image:
            return .image
        case .file:
            return .file
        case .richtext:
            // v65：有 RTF 数据 → 富文本保真渲染（此前一律降级纯文本，用户反馈渲染错误）；
            // 无 RTF 数据（历史条目）与纯文本同一条启发式链，避免渲染口径分叉
            if PreviewPopoverDataBridge.shared.richTextAttributed(for: item) != nil { return .richText }
            return item.textPath != nil ? .fileBackedText : classifyRawText(fullText)
        case .text, .url:
            // 落盘长文本统一进 fileBackedText（加载全文后同样走 classifyRawText 链）
            if item.textPath != nil { return .fileBackedText }
            return classifyRawText(fullText)
        }
    }

    /// v65 富文本保真渲染数据（RTF → NSAttributedString；经数据桥，App 总控接线）
    public var richAttributed: NSAttributedString? {
        PreviewPopoverDataBridge.shared.richTextAttributed(for: item)
    }

    /// JSON 预览资格（F16 __isJSONPreviewEligible）：单根 JSON 或 **JSONL**
    /// （一行一条 JSON 的多行记录——2026-10-20 用户实证 JSONL 文件不自动解析，
    /// 旧判定只认单根，多根直接落纯文本）。JSONL 要求 ≥2 个有效行且每行都是
    /// 对象/数组（防把两行普通文本误判）。
    public static func isJSONPreviewEligible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 200_000 else { return false }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return true
        }
        // JSONL：每行独立可解析且为对象/数组。
        // 2026-11-03：允许少量坏行（有效行 ≥ 坏行即可）——检视器已经能跳过坏行并
        // 标出行号，这里再"全有或全无"就会把带一两行脏数据的 JSONL 又踢回纯文本。
        var good = 0
        var bad = 0
        for line in trimmed.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let d = t.data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
               o is [String: Any] || o is [Any] {
                good += 1
            } else {
                bad += 1
            }
        }
        return good >= 2 && good >= bad
    }

    /// Markdown 强信号正则（v126 性能审计 F1094：静态预编译，避免每次调用隐式编译 10 条）
    private static let markdownStrongRegexes: [NSRegularExpression] = [
        "(?m)^#{1,6}\\s+\\S",                 // 标题
        "(?m)^#{1,6}[\\u4e00-\\u9fff]",       // 中文标题（`#标题` 无空格——中文 Markdown 高频写法）
        "(?m)^\\s*```",                        // 围栏代码
        "(?m)^\\s*([-*+]|\\d+[.)])\\s+\\S",  // 列表
        "(?m)^\\s*>\\s+\\S",                 // 引用
        "(?m)^\\s*\\|.*\\|\\s*$",            // 表格行
        "\\*\\*[^*\\n]+\\*\\*",              // 粗体
        "`[^`\\n]+`",                          // 行内代码
        "\\[[^\\]\\n]+\\]\\([^)\\n]+\\)",     // 链接
        "(?m)^\\s*([-*_])(\\s*\\1){2,}\\s*$"   // 分隔线
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Markdown 启发式：标题/围栏/链接/强调/列表 等特征
    ///
    /// 2026-10-18 放宽（用户反馈"有些文本能渲染 Markdown 有些不能"）：
    ///   · 扫描行数 24 → 40（长文档特征更靠后）
    ///   · 新增特征：分隔线 / 表格 / H4+ / 有序列表 / 行内代码 / 引用块
    ///   · 阈值 3 → 2（`- ` 列表 + `**粗体**` 这类两特征组合已是明确 Markdown 信号；
    ///     误判风险低——被误判的普通文本只是按 Markdown 样式排版，内容不丢）
    /// 落盘长文本（fileBackedText）加载后也走本判定（见 PreviewFileBackedTextView）。
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // ① 强信号：命中任意一条就按 Markdown 渲染。
        //    这些模式在普通文本里几乎不会出现，误判成本也只是「排版更好看」，内容不会丢。
        // v126（性能审计 F1094）：原 range(of:options:.regularExpression) 每次调用把 10 个
        // 模式各隐式编译一遍（Swift 不缓存正则），改为静态预编译一次、逐条匹配即用。
        let strongPatterns = Self.markdownStrongRegexes
        for re in strongPatterns {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if re.firstMatch(in: trimmed, options: [], range: range) != nil { return true }
        }

        // ② 弱信号：短文本（≤ 240 字）里两条即判定；长文本维持原来的累计口径
        var score = 0
        // v182：`__` 只有在**内容含空格/CJK**时才算加粗（`__强调文本__`）。
        // 原来是 `contains("__")` —— Python 的 `__init__` / `__future__` 每行都算一分，
        // 两行就够阈值，于是 .py 文件被判成 Markdown。
        let boldUnderscore = try? NSRegularExpression(pattern: "__[^_\\n]*[ \\t\\u4e00-\\u9fff][^_\\n]*__")
        for line in trimmed.split(separator: "\n", maxSplits: 60, omittingEmptySubsequences: true).prefix(40) {
            let t = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            if let re = boldUnderscore {
                let r = NSRange(t.startIndex..., in: t)
                if re.firstMatch(in: t, options: [], range: r) != nil { score += 1 }
            }
            if t.contains("~~") { score += 1 }
            if score >= 2 { return true }
        }
        return false
    }

    /// 代码启发式：多行 + 括号/分号/常见语言关键字/稳定缩进
    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4 else { return false }
        var hits = 0
        for line in lines.prefix(30) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(";") || t.hasSuffix("{") || t.hasSuffix("}") { hits += 1 }
            for keyword in ["func ", "class ", "struct ", "import ", "def ", "return ", "const ", "let ", "var ", "public ", "#include"] {
                if t.hasPrefix(keyword) { hits += 1; break }
            }
        }
        // 首行缩进稳定（至少 3 行有前导空白）
        let indented = lines.prefix(30).filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        if indented >= 3 { hits += 1 }
        return hits >= 3
    }
}

// MARK: - 行数估算（面板领地内私有口径，避免依赖 Clipboard 模块扩展）

extension String {
    var lineCountEstimate: Int {
        guard !isEmpty else { return 1 }
        var count = 1
        for ch in self where ch == "\n" { count += 1 }
        return count
    }
}

// MARK: - Markdown 滚动记忆（specs/12 F15：块帧表 + 偏移 + 恢复）

/// Markdown/长文预览的滚动位置快照；键 = item.dedupeKey，存于协调器。
/// blockFrames 对应原作 __markdownPreviewBlockFrames（块 id → 视口帧），重建版按"首可见块 + 偏移"近似。
public struct MarkdownScrollState: Equatable {
    public var scrollOffset: CGFloat
    public var anchorBlockID: String?
    public var blockFrames: [String: CGRect]

    public init(scrollOffset: CGFloat = 0, anchorBlockID: String? = nil, blockFrames: [String: CGRect] = [:]) {
        self.scrollOffset = scrollOffset
        self.anchorBlockID = anchorBlockID
        self.blockFrames = blockFrames
    }
}

// MARK: - 落盘长文本加载状态（specs/12 F17）

/// __fileBackedPreviewLoadState 的枚举映射：idle → loading → loaded/failed
public enum FilePreviewLoadState: Equatable {
    case idle
    case loading
    case loaded(String)
    case failed(String)
}
