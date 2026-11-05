import AppKit
import Foundation
import SwiftUI

// MARK: - 渲染开关（05 号规格 1.6：Preview*PreferenceStore）

/// Markdown 渲染开关：关闭时大文本按纯文本呈现（长文档更省资源）

/// JSON 高亮开关：关闭时 JSON 按纯文本呈现

// MARK: - 预览模式


// MARK: - JSON 高亮（05 号规格 1.6：JSONHighlighter）

/// JSON 高亮：JSONSerialization 负责格式化（缩进/排序键），NSRegularExpression 负责着色。
/// 不使用外部依赖，全部为系统 API。

// MARK: - Markdown 高亮（05 号规格 1.6：MarkdownCodeSyntaxHighlighter）

/// Markdown 渲染：用 `AttributedString` 逐 run 拼装，识别 标题 / 粗体 / 行内代码 / 代码块 / 列表 / 表格。
/// 只覆盖常见的 6 类标记，不追求 CommonMark 全兼容（零外部依赖约束）。

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

