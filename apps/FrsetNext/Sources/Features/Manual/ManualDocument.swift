import Foundation
import SwiftUI

// MARK: - 使用手册 · 每功能一篇文档，按元数据组成分类与功能两级导航。

final class ManualNode: Identifiable {
    let id: String
    let title: String
    let level: Int
    let demoID: String?
    let symbol: String
    var blocks: [ManualBlockItem] = []
    var children: [ManualNode] = []

    var demoSteps: [String] {
        for item in blocks {
            if case .numbered(let steps) = item.block { return steps }
        }
        return []
    }

    /// 解析时缓存标题与正文，供搜索直接读取。
    private(set) var searchText = ""

    init(id: String, title: String, level: Int, demoID: String? = nil, symbol: String = "book.closed") {
        self.id = id
        self.title = title
        self.level = level
        self.demoID = demoID
        self.symbol = symbol
    }

    /// v128（流畅度）：解析完成后调用一次，固化 searchText（含自身全部块）
    func finalizeSearchText() {
        var parts: [String] = [title]
        parts.reserveCapacity(blocks.count + 1)
        for b in blocks { parts.append(b.block.plainText) }
        searchText = parts.joined(separator: " ")
    }

}

/// 内容块 + 稳定 id（解析时按节内序号分配；分隔线等无自然标识的块也能稳定 ForEach）
struct ManualBlockItem: Identifiable {
    let id: String
    let block: ManualBlock
}

enum ManualBlock: Identifiable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)

    var id: String {
        switch self {
        case .heading(let s): return "h:" + s
        case .paragraph(let s): return "p:" + String(s.prefix(48))
        case .bullets(let a): return "ul:" + String(a.first?.prefix(32) ?? "")
        case .numbered(let a): return "ol:" + String(a.first?.prefix(32) ?? "")
        case .quote(let s): return "q:" + String(s.prefix(32))
        }
    }

    var plainText: String {
        switch self {
        case .heading(let s): return s
        case .paragraph(let s): return s
        case .bullets(let a): return a.joined(separator: " ")
        case .numbered(let a): return a.joined(separator: " ")
        case .quote(let s): return s
        }
    }
}

enum ManualDocument {
    /// 解析后的手册根节点集合 + 平铺索引（id → node）
    struct Doc {
        let roots: [ManualNode]
        let index: [String: ManualNode]
        let title: String
        /// 功能 id → 分类 id。
        let parentIndex: [String: String]
        /// 仅包含功能，供前后页导航使用。
        let flatNodes: [ManualNode]
        let loadError: String?
    }

    static func load(bundle: Bundle = .main) -> Doc {
        var roots: [ManualNode] = []
        var index: [String: ManualNode] = [:]
        var parentIndex: [String: String] = [:]
        let urls = (bundle.urls(forResourcesWithExtension: "md", subdirectory: "Manual/Guides") ?? [])
            .filter { !$0.lastPathComponent.hasPrefix("._") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        do {
            for url in urls {
                let (category, node) = parse(try String(contentsOf: url, encoding: .utf8),
                                             id: url.deletingPathExtension().lastPathComponent)
                let groupTitle = displayCategory(category)
                let categoryID = "category:" + groupTitle
                if index[categoryID] == nil {
                    let group = ManualNode(id: categoryID, title: groupTitle, level: 1)
                    group.finalizeSearchText()
                    roots.append(group)
                    index[categoryID] = group
                }
                index[categoryID]?.children.append(node)
                index[node.id] = node
                parentIndex[node.id] = categoryID
            }
        } catch {
            return Doc(roots: [], index: [:], title: "使用手册", parentIndex: [:], flatNodes: [],
                       loadError: "无法读取手册：\(error.localizedDescription)")
        }
        let order = ["开始使用", "剪贴板", "截图与录屏", "文件与传输", "搜索与 AI", "工具箱", "电脑状态", "日常与设置"]
        roots.sort { (order.firstIndex(of: $0.title) ?? order.count) < (order.firstIndex(of: $1.title) ?? order.count) }
        return Doc(roots: roots, index: index, title: "使用手册", parentIndex: parentIndex,
                   flatNodes: roots.flatMap(\.children), loadError: nil)
    }

    /// 把内部编号合并成用户找得到的功能分类；文章仍保持独立。
    private static func displayCategory(_ raw: String) -> String {
        switch raw.prefix(2) {
        case "01": return "开始使用"
        case "02": return "剪贴板"
        case "03", "04": return "截图与录屏"
        case "05": return "电脑状态"
        case "06": return "文件与传输"
        case "07": return "搜索与 AI"
        case "08": return "工具箱"
        case "09": return "日常与设置"
        default: return raw.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "其他功能"
        }
    }

    /// 一篇功能文档的标题、分类和演示元数据；正文标题不进入导航树。
    static func parse(_ text: String, id: String) -> (category: String, node: ManualNode) {
        var title = ""
        var metadata: [String: String] = [:]
        var body: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("<!-- "), line.hasSuffix(" -->") {
                let parts = line.dropFirst(5).dropLast(4).split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    metadata[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else { body.append(line) }
        }
        let node = ManualNode(id: id, title: title, level: 2, demoID: metadata["demo"],
                              symbol: metadata["symbol"] ?? "book.closed")
        node.blocks = parseBlocks(body).enumerated().map {
            ManualBlockItem(id: "\(id)-b\($0.offset)", block: $0.element)
        }
        node.finalizeSearchText()
        return (metadata["category"] ?? "", node)
    }

    // MARK: - 块解析

    static func parseBlocks(_ lines: [String]) -> [ManualBlock] {
        var blocks: [ManualBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("## ") {
                blocks.append(.heading(String(trimmed.dropFirst(3))))
                i += 1; continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            // 无序列表
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") || t.hasPrefix("* ") {
                        items.append(String(t.dropFirst(2)))
                        i += 1
                    } else if !t.isEmpty, !t.hasPrefix("|"), !t.hasPrefix("#"),
                              !t.hasPrefix("```"), (lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t")) {
                        // 列表项续行
                        if let last = items.popLast() { items.append(last + " " + t) }
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.bullets(items))
                continue
            }

            // 有序列表
            if firstRange(reNumberedItem, trimmed) != nil {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let r = firstRange(reNumberedItem, t) else { break }
                    items.append(String(t[r.upperBound...]))
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // 段落：连续非空、非特殊行
            var para: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("## ") || t.hasPrefix(">")
                    || t.hasPrefix("- ") || t.hasPrefix("* ")
                    || firstRange(reNumberedItem, t) != nil { break }
                para.append(t)
                i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))) }
        }
        return blocks
    }

    private static let reNumberedItem = try? NSRegularExpression(pattern: "^[0-9]+[.、] ")

    /// 首个匹配区间（等价 `text.range(of: pattern, options: .regularExpression)`）
    private static func firstRange(_ re: NSRegularExpression?, _ text: String) -> Range<String.Index>? {
        guard let re,
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return r
    }

}
