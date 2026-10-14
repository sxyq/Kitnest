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
                showsKeyboardHint: Bool = false) {
        self.id = item.id
        self.item = item
        self.source = source
        self.entry = entry
        self.sessionID = sessionID
        self.inlineText = inlineText
        self.showsKeyboardHint = showsKeyboardHint
        self.kind = PreviewPopoverContentModel.classify(item: item, fullText: inlineText)
    }

    // MARK: 分态判定

    /// 内容分态判定：图片/文件按条目类型；文本类按启发式细分（Markdown/JSON/代码/纯文本）
    public static func classify(item: ClipboardItem, fullText: String) -> Kind {
        switch item.type {
        case .image:
            return .image
        case .file:
            return .file
        case .richtext:
            // 富文本一律按普通文本渲染（RTF 数据由 fullText 读出纯文本）
            return item.textPath != nil ? .fileBackedText : .text
        case .text, .url:
            if item.textPath != nil { return .fileBackedText }
            if isJSONPreviewEligible(fullText) { return .json }
            if looksLikeMarkdown(fullText) { return .markdown }
            if looksLikeCode(fullText) { return .code }
            return .text
        }
    }

    /// JSON 预览资格（F16 __isJSONPreviewEligible）：首字符 { 或 [ 且可完整解析
    public static func isJSONPreviewEligible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return false }
        guard trimmed.count <= 200_000, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Markdown 启发式：标题/围栏/链接/强调/列表 等特征
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        var score = 0
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true).prefix(24) {
            let t = line.drop(while: { $0 == " " })
            if t.hasPrefix("# ") || t.hasPrefix("## ") || t.hasPrefix("### ") { score += 2 }
            if t.hasPrefix("```") { score += 2 }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("> ") { score += 1 }
            if t.contains("](") && t.contains("[") { score += 1 }
            if t.contains("**") { score += 1 }
            if score >= 3 { return true }
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
        case .text, .markdown, .json:
            let lineHeight: CGFloat = 17          // 13pt 字体行高（⬜ 原作值未探明）
            let padding: CGFloat = 20
            let lines = CGFloat(max(1, inlineText.lineCountEstimate))
            return min(maxPopoverHeight, max(textPreviewLoadingMinHeight, lines * lineHeight + padding))
        case .fileBackedText:
            // 落盘长文：先按 loading 占位高度呈现，全文加载后由内容撑开（≤ maxPopoverHeight）
            return textPreviewLoadingMinHeight
        case .code:
            let lineHeight: CGFloat = 16          // 等宽字体行高（⬜ 原作值未探明）
            let lines = CGFloat(max(1, inlineText.lineCountEstimate))
            return min(maxPopoverHeight, max(96, lines * lineHeight + 24))
        case .image:
            // 按图片像素宽高比 + popover 宽度估算，越屏约束在协调器侧再兜底
            let estimated = PreviewPopoverContentModel.imageDisplayHeight(item: item, contentWidth: 340) + 24
            return min(imagePreviewMaxPopoverHeight, max(textPreviewLoadingMinHeight, estimated))
        case .file:
            return 96
        }
    }

    /// 用 CGImageSource 元数据读图片尺寸（不解码像素，便宜）
    public static func imagePixelSize(item: ClipboardItem) -> CGSize? {
        let path = item.imagePath ?? item.thumbnailPath
        guard let path, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
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
