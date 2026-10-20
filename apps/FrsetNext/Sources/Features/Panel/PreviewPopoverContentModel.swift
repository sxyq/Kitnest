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
    public static func classifyRawText(_ text: String) -> Kind {
        if isJSONPreviewEligible(text) { return .json }
        if looksLikeMarkdown(text) { return .markdown }
        if looksLikeCode(text) { return .code }
        return .text
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

    /// JSON 预览资格（F16 __isJSONPreviewEligible）：首字符 { 或 [ 且可完整解析
    public static func isJSONPreviewEligible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        guard trimmed.count <= 200_000, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

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
        let strongPatterns = [
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
        ]
        for pattern in strongPatterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil { return true }
        }

        // ② 弱信号：短文本（≤ 240 字）里两条即判定；长文本维持原来的累计口径
        var score = 0
        for line in trimmed.split(separator: "\n", maxSplits: 60, omittingEmptySubsequences: true).prefix(40) {
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            if t.contains("__") { score += 1 }
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

    // MARK: 高度估算（F13/F14；数值⬜ 的默认值见 MainPanelPreviewPopoverCoordinator 常量区）

    /// popover 内容高度估算：按分态给出确定高度（上限由协调器常量约束）
    public func estimatedPopoverHeight(maxPopoverHeight: CGFloat,
                                       imagePreviewMaxPopoverHeight: CGFloat,
                                       textPreviewLoadingMinHeight: CGFloat) -> CGFloat {
        switch kind {
        case .markdown:
            // Markdown 里有代码块、表格、mermaid 流程图（图片附件）——按行数估算会严重偏矮，
            // 直接把渲染结果量一遍（渲染一次的成本远低于高度不足导致的裁切）。
            let parsed = PreviewMarkdownTextView.render(inlineText)
            // 内容宽 = 协调器 popoverWidth - 36 内边距；有目录时正文区再窄 181（180 + 分隔线）
            let tocWidth: CGFloat = parsed.headings.count >= 1 ? 181 : 0
            let width: CGFloat = MainPanelPreviewPopoverCoordinator.shared.popoverWidth - 36 - tocWidth
            let rect = parsed.body.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading])
            return min(maxPopoverHeight, max(textPreviewLoadingMinHeight, ceil(rect.height) + 24))
        case .json:
            // JSON 走树形/表格视图（JSONInspectorView），没有「行数」可估；
            // 给一个固定可用高度，避免树只露出两三行就被裁掉
            return min(maxPopoverHeight, max(360, textPreviewLoadingMinHeight))
        case .text:
            let lineHeight: CGFloat = 25.5        // 19.5pt 字体的行高（2026-10-18：13×1.5 字号）
            let padding: CGFloat = 30
            let lines = CGFloat(max(1, inlineText.lineCountEstimate))
            return min(maxPopoverHeight, max(textPreviewLoadingMinHeight, lines * lineHeight + padding))
        case .fileBackedText:
            // 落盘长文：先按 loading 占位高度呈现，全文加载后由内容撑开（≤ maxPopoverHeight）
            return textPreviewLoadingMinHeight
        case .code:
            let lineHeight: CGFloat = 23          // 高亮后等宽字体 17pt 的实际行高
            let lines = CGFloat(max(1, inlineText.lineCountEstimate))
            return min(maxPopoverHeight, max(96, lines * lineHeight + 24))
        case .image:
            // 按图片像素宽高比 + popover 宽度估算，越屏约束在协调器侧再兜底
            let estimated = PreviewPopoverContentModel.imageDisplayHeight(item: item, contentWidth: 340) + 24
            return min(imagePreviewMaxPopoverHeight, max(textPreviewLoadingMinHeight, estimated))
        case .richText:
            // 渲染量高（同 Markdown 策略：一次 boundingRect 换高度准确）
            let width = MainPanelPreviewPopoverCoordinator.shared.popoverWidth - 36
            let attributed = richAttributed ?? NSAttributedString(string: inlineText)
            let rect = attributed.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
            return min(maxPopoverHeight, max(textPreviewLoadingMinHeight, ceil(rect.height) + 24))
        case .file:
            return 96
        }
    }

    /// 用 CGImageSource 元数据读图片尺寸（不解码像素，便宜）
    public static func imagePixelSize(item: ClipboardItem) -> CGSize? {
        let path = item.imagePath ?? item.thumbnailPath
        // 相对路径必须经存储层解析（否则 CGImageSource 打不开 → 预估高度永远是默认值）
        guard let path else { return nil }
        let url = ClipboardFileStore.url(forRelativePath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        guard let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 图片按内容宽度等比缩放后的显示高度
    public static func imageDisplayHeight(item: ClipboardItem, contentWidth: CGFloat) -> CGFloat {
        guard let pixel = imagePixelSize(item: item), pixel.width > 0 else { return 200 }
        let scale = min(1, contentWidth / pixel.width)
        return max(80, pixel.height * scale)
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
