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

    // v128（流畅度）：搜索用纯文本一次性缓存（标题 + 全部块文本拼接）——
    // 原 nodeMatches 每次命中判定都要对每个块重算 plainText（数组 join），
    // 搜索框每敲一键全树节点都要重算一遍。解析完成后建一次，之后只读。
    private(set) var searchText = ""

    init(id: String, title: String, level: Int) {
        self.id = id
        self.title = title
        self.level = level
    }

    /// v128（流畅度）：解析完成后调用一次，固化 searchText（含自身全部块）
    func finalizeSearchText() {
        var parts: [String] = [title]
        parts.reserveCapacity(blocks.count + 1)
        for b in blocks { parts.append(b.block.plainText) }
        searchText = parts.joined(separator: " ")
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

    // v128（流畅度）：从 ManualView 的 private 扩展移入本文件——ManualNode.finalizeSearchText
    // 解析时一次性调用（原先每次搜索命中判定都重算 join）。
    var plainText: String {
        switch self {
        case .paragraph(let s): return s
        case .bullets(let a): return a.joined(separator: " ")
        case .numbered(let a): return a.joined(separator: " ")
        case .quote(let s): return s
        case .image(let r, let c): return "\(c ?? "") \(r)"
        case .table(let h, let rows): return h.joined(separator: " ") + " " + rows.flatMap { $0 }.joined(separator: " ")
        case .code(let s): return s
        case .divider: return ""
        }
    }
}

enum ManualDocument {
    /// 解析后的手册根节点集合 + 平铺索引（id → node）
    struct Doc {
        let roots: [ManualNode]
        let index: [String: ManualNode]
        let title: String
        // v128（流畅度）：父指针索引（子 id → 父 id）——parent(of:) 原来是递归扫树
        // （深度 × 节点数），面包屑/上一节每次 body 求值（搜索每键）都走一遍。
        // 解析时建好，查询 O(1)。
        let parentIndex: [String: String]
        // v128（流畅度）：先序平铺（上/下一节导航用）——原 flat 计算属性每次 body
        // 求值都重新 flatten 整棵树（递归分配数组），搜索每键都白付一遍。
        let flatNodes: [ManualNode]
    }

    static func load(bundle: Bundle = .main) -> Doc {
        guard let url = bundle.url(forResource: "用户手册", withExtension: "md", subdirectory: "Manual"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            let fallback = ManualNode(id: "err", title: "手册未打包", level: 1)
            fallback.blocks = [ManualBlockItem(id: "err-b0",
                block: .paragraph("未找到 Resources/Manual/用户手册.md——请检查 build.sh 的资源打包步骤。"))]
            return Doc(roots: [fallback], index: ["err": fallback], title: "使用手册",
                       parentIndex: [:], flatNodes: [fallback])
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
        var parentIndex: [String: String] = [:]
        var flatNodes: [ManualNode] = []
        func register(_ n: ManualNode, parentID: String?) {
            index[n.id] = n
            if let parentID { parentIndex[n.id] = parentID }
            // v128（流畅度）：解析时一次性固化搜索文本（见 ManualNode.searchText）
            n.finalizeSearchText()
            flatNodes.append(n)   // v128（流畅度）：先序平铺，供 navFooter 直读
            for c in n.children { register(c, parentID: n.id) }
        }
        for r in roots { register(r, parentID: nil) }
        return Doc(roots: roots, index: index, title: docTitle,
                   parentIndex: parentIndex, flatNodes: flatNodes)
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
            if matches(reDivider, trimmed) {
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
        !cells.isEmpty && cells.allSatisfy { matches(reSeparatorCell, $0) }
    }

    // v126（性能审计 F1881/F1883/F1884）：隐式正则编译缓存——`String.range(of:options:.regularExpression)`
    // 内部每次都重新编译 pattern，而 parseBlocks 对**每一行**（分隔线/有序列表）和
    // 表格的**每一个单元格**（isSeparatorRow）都会各编译一次；一篇 971 行手册就是上千次
    // 编译。改成一次性 static 编译 + 直接区间匹配，命中后零编译成本。
    private static let reDivider = try? NSRegularExpression(pattern: "^[-*_]{3,}$")
    private static let reNumberedItem = try? NSRegularExpression(pattern: "^[0-9]+[.、] ")
    private static let reSeparatorCell = try? NSRegularExpression(pattern: "^:?-{2,}:?$")

    /// 整串匹配（等价 `text.range(of: pattern, options: .regularExpression) != nil`）
    private static func matches(_ re: NSRegularExpression?, _ text: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 首个匹配区间（等价 `text.range(of: pattern, options: .regularExpression)`）
    private static func firstRange(_ re: NSRegularExpression?, _ text: String) -> Range<String.Index>? {
        guard let re,
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return r
    }

    // v125（性能审计 F1881）：正则缓存——原来每次调用都 NSRegularExpression(pattern:)，
    // 一篇手册解析会重复编译同一批 pattern。改为字典缓存，命中后零编译成本。
    private static var _reCache: [String: NSRegularExpression] = [:]

    private static func firstMatch(_ text: String, pattern: String) -> [String]? {
        let re: NSRegularExpression
        if let cached = _reCache[pattern] {
            re = cached
        } else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
            _reCache[pattern] = compiled
            re = compiled
        }
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
