import Foundation
import SwiftUI

// MARK: - 使用手册 · 文档模型与解析器（2026-10-20）
//
// 数据源：docs/perfaudit/用户手册-FrsetNext.md（971 行，随包打进 Resources/Manual/）
// 结构：## 章 → ### 节 → #### 小节；每节自带内容块（段落/列表/表格/图片/代码/引用）。
// 目标：设置窗口内嵌「交互式树形手册」——左侧分支树（可展开/收起/搜索），
//       右侧内容区（含小节跳转、图片点击放大、上/下一节导航）。
//
// 解析器只覆盖本手册实际用到的 Markdown 子集（标题/段落/无序·有序列表/表格/
// 图片/引用/代码块/分隔线），不引入第三方依赖。

final class ManualNode: Identifiable {
    let id: String
    let title: String
    let level: Int
    var blocks: [ManualBlockItem] = []
    var children: [ManualNode] = []

    init(id: String, title: String, level: Int) {
        self.id = id
        self.title = title
        self.level = level
    }

    /// 子树内全部节点（含自身），先序
    func flatten() -> [ManualNode] {
        var out: [ManualNode] = [self]
        for c in children { out.append(contentsOf: c.flatten()) }
        return out
    }
}

/// 内容块 + 稳定 id（解析时按节内序号分配；分隔线等无自然标识的块也能稳定 ForEach）
struct ManualBlockItem: Identifiable {
    let id: String
    let block: ManualBlock
}

enum ManualBlock: Identifiable {
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case quote(String)
    case image(ref: String, caption: String?)
    case table(headers: [String], rows: [[String]])
    case code(String)
    case divider

    var id: String {
        switch self {
        case .paragraph(let s): return "p:" + String(s.prefix(48))
        case .bullets(let a): return "ul:" + String(a.first?.prefix(32) ?? "")
        case .numbered(let a): return "ol:" + String(a.first?.prefix(32) ?? "")
        case .quote(let s): return "q:" + String(s.prefix(32))
        case .image(let r, _): return "img:" + r
        case .table(let h, _): return "tb:" + h.joined(separator: "|")
        case .code(let s): return "code:" + String(s.prefix(24))
        case .divider: return "hr:\(UUID().uuidString)"
        }
    }
}

enum ManualDocument {
    /// 解析后的手册根节点集合 + 平铺索引（id → node）
    struct Doc {
        let roots: [ManualNode]
        let index: [String: ManualNode]
        let title: String
    }

    static func load(bundle: Bundle = .main) -> Doc {
        guard let url = bundle.url(forResource: "用户手册", withExtension: "md", subdirectory: "Manual"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            let fallback = ManualNode(id: "err", title: "手册未打包", level: 1)
            fallback.blocks = [ManualBlockItem(id: "err-b0",
                block: .paragraph("未找到 Resources/Manual/用户手册.md——请检查 build.sh 的资源打包步骤。"))]
            return Doc(roots: [fallback], index: ["err": fallback], title: "使用手册")
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Doc {
        var roots: [ManualNode] = []
        var stack: [ManualNode] = []
        var nextId = 0                        // v88 修：全局自增 ID（此前用「层级+序号」，
                                              // 跨章的 ### 会撞 id → 索引去重后丢节点、跳转串页）
        var docTitle = "使用手册"

        var buffer: [String] = []
        func flush(into node: ManualNode?) {
            guard let node, !buffer.isEmpty else { buffer = []; return }
            let parsed = parseBlocks(buffer)
            for (i, b) in parsed.enumerated() {
                node.blocks.append(ManualBlockItem(id: "\(node.id)-b\(i)", block: b))
            }
            buffer = []
        }

        let lines = text.components(separatedBy: .newlines)
        var inCodeFence = false

        for raw in lines {
            let line = raw
            // 代码块内的 # 不当标题
            if line.hasPrefix("```") { inCodeFence.toggle() }

            if !inCodeFence, let (level, title) = heading(of: line) {
                flush(into: stack.last)
                if level == 0 {
                    // `# 标题`：文档标题，不入树
                    docTitle = title
                    continue
                }
                nextId += 1
                let node = ManualNode(id: "n\(nextId)", title: title, level: level)
                while let last = stack.last, last.level >= level { stack.removeLast() }
                if let parent = stack.last {
                    parent.children.append(node)
                } else {
                    roots.append(node)
                }
                stack.append(node)
                continue
            }
            buffer.append(line)
        }
        flush(into: stack.last)

        var index: [String: ManualNode] = [:]
        for r in roots { for n in r.flatten() { index[n.id] = n } }
        return Doc(roots: roots, index: index, title: docTitle)
    }

    /// `#` 数量 → (层级, 标题)。`##`=1、`###`=2、`####`=3；`#`=0（文档标题）
    private static func heading(of line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 4 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // 去掉标题里的反引号（Markdown 行内代码）
        title = title.replacingOccurrences(of: "`", with: "")
        return (level - 1, title)
    }

    // MARK: - 块解析

    static func parseBlocks(_ lines: [String]) -> [ManualBlock] {
        var blocks: [ManualBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // 代码块
            if trimmed.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // 分隔线
            if trimmed.range(of: "^[-*_]{3,}$", options: .regularExpression) != nil {
                blocks.append(.divider); i += 1; continue
            }

            // 图片（单独一行）
            if let m = firstMatch(trimmed, pattern: "^!\\[([^\\]]*)\\]\\(([^)]+)\\)$") {
                let caption = m.count > 1 && !m[1].isEmpty ? m[1] : nil
                blocks.append(.image(ref: m[2], caption: caption))
                i += 1; continue
            }

            // 表格：| a | b |  +  分隔行 |---|---|
            if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(splitTableRow(t))
                    i += 1
                }
                if rows.count >= 2 {
                    let headers = rows[0]
                    let body = rows.dropFirst().filter { !isSeparatorRow($0) }
                    blocks.append(.table(headers: headers, rows: Array(body)))
                } else if let r = rows.first {
                    blocks.append(.table(headers: r, rows: []))
                }
                continue
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
            if trimmed.range(of: "^[0-9]+[.、] ", options: .regularExpression) != nil {
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.range(of: "^[0-9]+[.、] ", options: .regularExpression) != nil else { break }
                    if let r = t.range(of: "^[0-9]+[.、] ", options: .regularExpression) {
                        items.append(String(t[r.upperBound...]))
                    }
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // 段落：连续非空、非特殊行
            var para: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("|") || t.hasPrefix(">")
                    || t.hasPrefix("```") || t.hasPrefix("- ") || t.hasPrefix("* ")
                    || t.hasPrefix("![") { break }
                para.append(t)
                i += 1
            }
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))) }
        }
        return blocks
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy {
            $0.range(of: "^:?-{2,}:?$", options: .regularExpression) != nil
        }
    }

    private static func firstMatch(_ text: String, pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var out: [String] = []
        for idx in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: idx), in: text) { out.append(String(text[r])) }
            else { out.append("") }
        }
        return out
    }
}
