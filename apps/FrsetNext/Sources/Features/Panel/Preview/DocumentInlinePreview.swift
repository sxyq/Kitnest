import AppKit
import Foundation
import QuickLookUI
import SwiftUI

/// Word 直接显示导入后的真实富文本；其他文档保留系统 QuickLook 内容视图。
@MainActor
struct DocumentInlinePreview: View {
    let url: URL

    nonisolated static let supportedExtensions: Set<String> = [
        "doc", "docx", "docm", "dot", "dotx", "rtf", "rtfd", "odt", "webarchive",
        "ppt", "pptx", "pptm", "pps", "ppsx", "key", "odp",
        "xls", "xlsx", "xlsm", "numbers", "ods", "csv",
        "pages", "pdf", "epub"
    ]

    private var wordType: NSAttributedString.DocumentType? {
        switch url.pathExtension.lowercased() {
        case "doc", "dot": return .docFormat
        case "docx", "docm", "dotx": return .officeOpenXML
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let type = wordType {
                WordInlineContent(url: url, type: type)
                    .id(url)
            } else {
                InlineQuickLookView(url: url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WordDocumentRevision: Hashable {
    let url: URL
    let modified: Date?
    let size: Int?

    init(url: URL) throws {
        self.url = URL(fileURLWithPath: url.standardizedFileURL.path)
        let values = try self.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        modified = values.contentModificationDate
        size = values.fileSize
    }
}

private struct WordDocumentContent {
    let text: NSAttributedString
    let pageBackground: NSColor?
}

@MainActor
private struct WordInlineContent: View {
    let url: URL
    let type: NSAttributedString.DocumentType
    @Stored private var document: WordDocumentContent?
    @Stored private var failure: String?

    var body: some View {
        Group {
            if let content = document {
                if content.text.length == 0 {
                    Text("文档正文为空").foregroundStyle(.secondary)
                } else {
                    AttributedTextView(content.text, showsTableGrid: false)
                        .background(Color(nsColor: content.pageBackground ?? .white))
                }
            } else if let failure {
                Text("无法读取正文：\(failure)").foregroundStyle(.secondary)
            } else {
                ProgressView("正在读取正文…")
            }
        }
        .task(id: url) {
            do {
                let revision = try await Task.detached(priority: .userInitiated) {
                    try WordDocumentRevision(url: url)
                }.value
                try Task.checkCancellation()
                let content = try await WordDocumentStore.load(revision, type: type)
                try Task.checkCancellation()
                document = content
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
}

/// 主线程只管理缓存与同文档在途任务；文件读取和 Office 导入不占用 UI 线程。
@MainActor
private enum WordDocumentStore {
    private final class Entry: NSObject {
        let revision: WordDocumentRevision
        let content: WordDocumentContent

        init(revision: WordDocumentRevision, content: WordDocumentContent) {
            self.revision = revision
            self.content = content
        }
    }

    private static let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.countLimit = 8
        return cache
    }()
    private static var loading: [WordDocumentRevision: Task<WordDocumentContent, Error>] = [:]

    static func cached(_ revision: WordDocumentRevision) -> WordDocumentContent? {
        guard let entry = cache.object(forKey: revision.url as NSURL),
              entry.revision == revision else { return nil }
        return entry.content
    }

    static func load(_ revision: WordDocumentRevision,
                     type: NSAttributedString.DocumentType) async throws -> WordDocumentContent {
        if let content = cached(revision) { return content }
        if let task = loading[revision] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) {
            var attributes: NSDictionary?
            let text = try NSAttributedString(url: revision.url,
                                              options: [.documentType: type], documentAttributes: &attributes)
            let rendered: NSAttributedString
            if type == .officeOpenXML {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    ArchiveCore.run(["e", "-so", "-y", revision.url.path, "word/document.xml"]) { code, data, message in
                        if code == 0 { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: NSError(domain: "WordPreview", code: Int(code),
                            userInfo: [NSLocalizedDescriptionKey: message])) }
                    }
                }
                rendered = try restoreOpenXMLFormatting(text, data: data)
            } else { rendered = text }
            return WordDocumentContent(text: rendered,
                                       pageBackground: attributes?[NSAttributedString.DocumentAttributeKey.backgroundColor] as? NSColor)
        }
        loading[revision] = task
        defer { loading[revision] = nil }
        let content = try await task.value
        cache.setObject(Entry(revision: revision, content: content), forKey: revision.url as NSURL)
        return content
    }

    /// 系统导入器把 w:b/i 的 val=0 当作开启，且忽略 tblGrid；按原文恢复这两项。
    nonisolated private static func restoreOpenXMLFormatting(_ text: NSAttributedString, data: Data) throws -> NSAttributedString {
        let xml = try XMLDocument(data: data)
        let result = NSMutableAttributedString(attributedString: text)
        let source = text.string as NSString
        var position = 0
        for case let run as XMLElement in try xml.nodes(forXPath: "//w:r[w:t]") {
            let value = run.elements(forName: "w:t").compactMap(\.stringValue).joined()
            let range = source.range(of: value, range: NSRange(location: position, length: source.length - position))
            guard range.location != NSNotFound, range.length > 0 else { continue }
            position = NSMaxRange(range)
            let properties = run.elements(forName: "w:rPr").first
            var removed: NSFontTraitMask = []
            if properties?.elements(forName: "w:b").first?.attribute(forName: "w:val")?.stringValue == "0" { removed.insert(.boldFontMask) }
            if properties?.elements(forName: "w:i").first?.attribute(forName: "w:val")?.stringValue == "0" { removed.insert(.italicFontMask) }
            if !removed.isEmpty {
                text.enumerateAttribute(.font, in: range, options: []) { font, part, _ in
                    if let font = font as? NSFont {
                        result.addAttribute(.font, value: NSFontManager.shared.convert(font, toNotHaveTrait: removed), range: part)
                    }
                }
            }
        }
        let tables = try xml.nodes(forXPath: "//w:tbl").compactMap { $0 as? XMLElement }
        // 2026-11-25（函数审查 NEEDS_FIX 落实）：非 Word 标准生成器产出的 docx 可能没有
        // w:tblGrid / w:w 属性，强解包会让悬停预览整 App 崩溃。全部改安全解包，
        // 缺列宽的表按空数组处理（后面 span/百分比计算都要判空跳过）。
        let grids: [[Double]] = tables.map { table in
            (table.elements(forName: "w:tblGrid").first?.elements(forName: "w:gridCol") ?? [])
                .compactMap { $0.attribute(forName: "w:w")?.stringValue.flatMap(Double.init) }
        }
        var tableIndices: [ObjectIdentifier: Int] = [:]
        var seenBlocks: Set<ObjectIdentifier> = []
        result.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: result.length), options: []) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in style.textBlocks {
                guard seenBlocks.insert(ObjectIdentifier(block)).inserted else { continue }
                let id = ObjectIdentifier(block.table)
                if tableIndices[id] == nil { tableIndices[id] = tableIndices.count }
                let index = tableIndices[id]!
                guard index < tables.count, index < grids.count else { return }
                let table = tables[index]
                let widths = grids[index]
                let start = block.startingColumn
                let end = start + block.columnSpan
                // 列号越界 / tblGrid 缺列 → 这一块按默认宽度处理，不崩也不乱设
                guard start >= 0, end <= widths.count, !widths.isEmpty else { return }
                let span = widths[start..<end].reduce(0, +)
                let total = widths.reduce(0, +)
                if total > 0 {
                    block.setContentWidth(CGFloat(span / total * 100), type: .percentageValueType)
                }
                var column = 0
                let rows = table.elements(forName: "w:tr")
                guard block.startingRow >= 0, block.startingRow < rows.count else { return }
                let cell = rows[block.startingRow].elements(forName: "w:tc").first { cell in
                    let span = Int(cell.elements(forName: "w:tcPr").first?.elements(forName: "w:gridSpan").first?
                        .attribute(forName: "w:val")?.stringValue ?? "1") ?? 1
                    defer { column += span }
                    return column == block.startingColumn
                }
                if cell?.elements(forName: "w:tcPr").first?.elements(forName: "w:vAlign").first?.attribute(forName: "w:val")?.stringValue == "top" {
                    block.verticalAlignment = .top
                }
            }
        }
        return result
    }
}

private struct InlineQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL {
            // 设置新条目本身已异步加载，无须再 refreshPreviewItem。
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
