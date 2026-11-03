import SwiftUI

// MARK: - JSON 可视化（树形 + 表格，像数据库表那样看层级）
//
// 为什么不做「纯文本 pretty-print」：大 JSON（几 MB）铺开就是几千行文本，既看不出结构也翻不到重点。
// 这里把 JSON 当成一棵树 / 一张表来看：
//   · 树形：层级缩进 + 类型徽标 + 值预览 + 子节点计数，逐层展开
//   · 表格：根是对象数组时，把键并集变成列（像数据库表），行号列固定
//
// 性能策略：
//   · 解析一次（JSONSerialization），节点数上限 20000，超过即标记 isTruncated（只保留前段）
//   · 子级**懒构建**：折叠时不建子节点模型，首次展开才生成（深/宽 JSON 展开单层成本可控）
//   · 渲染用 LazyVStack + 递归子列表，不一次性铺开
//   · 表格列只扫前 500 个元素推导键并集，避免为几 MB 文件扫全量

enum JSONNodeKind {
    case object, array, string, number, bool, null

    /// 单字符徽标（中性色，不用彩色区分类型——靠形状语义区分）
    var badge: String {
        switch self {
        case .object: return "{ }"
        case .array: return "[ ]"
        case .string: return "\" \""
        case .number: return "#"
        case .bool: return "T/F"
        case .null: return "∅"
        }
    }
}

/// 树节点（引用语义：展开状态与子级缓存要能被多处视图共享）
final class JSONNodeModel: ObservableObject, Identifiable {
    let id: String                 // 稳定路径，如 $.users[3].name
    let key: String?               // 对象成员名；数组元素为 nil
    let index: Int?                // 数组元素下标（树形左侧显示真实下标）
    let kind: JSONNodeKind
    let preview: String            // 单行值预览
    let path: String
    private(set) var childCount: Int

    private let raw: Any
    private var builtChildren: [JSONNodeModel]?

    @Published private(set) var children: [JSONNodeModel] = []
    @Published private(set) var isExpanded = false

    init(key: String?, index: Int? = nil, raw: Any, path: String, depth: Int) {
        self.key = key
        self.index = index
        self.raw = raw
        self.path = path
        self.id = path

        // 深度保护：超过 64 层不再建子级（防御性 JSON 深递归）
        let canDescend = depth < 64

        switch raw {
        case let dict as [String: Any]:
            kind = .object
            childCount = canDescend ? dict.count : 0
            preview = "{\(dict.count) 项}"
        case let array as [Any]:
            kind = .array
            childCount = canDescend ? array.count : 0
            preview = "[\(array.count) 项]"
        case let string as String:
            kind = .string
            childCount = 0
            preview = string.count > 80 ? "\"" + String(string.prefix(80)) + "…\"" : "\"\(string)\""
        case let number as NSNumber:
            kind = .number
            childCount = 0
            preview = number.stringValue
        case let bool as Bool:
            kind = .bool
            childCount = 0
            preview = bool ? "true" : "false"
        default:
            kind = .null
            childCount = 0
            preview = "null"
        }
    }

    var isExpandable: Bool { childCount > 0 }

    /// 只构建子级、不改展开态：表格视图每次求值都要读子级，
    /// 用 toggle() 会一次展开一次收起（旧实现表格行会闪）。
    func ensureChildren() {
        if builtChildren == nil {
            builtChildren = Self.makeChildren(raw: raw, parentPath: path, depth: 0)
            children = builtChildren ?? []
        }
    }

    /// 首次展开时才生成子节点模型（懒构建）
    func toggle() {
        if !isExpanded && builtChildren == nil {
            builtChildren = Self.makeChildren(raw: raw, parentPath: path, depth: 0)
            children = builtChildren ?? []
        }
        isExpanded.toggle()
    }


    private static func makeChildren(raw: Any, parentPath: String, depth: Int) -> [JSONNodeModel] {
        var result: [JSONNodeModel] = []
        switch raw {
        case let dict as [String: Any]:
            // 键按首次出现顺序（JSONSerialization 的字典无序，这里按本地化排序保持稳定）
            let keys = dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for key in keys {
                let childPath = "\(parentPath).\(key)"
                result.append(JSONNodeModel(key: key, raw: dict[key]!,
                                            path: childPath, depth: depth + 1))
            }
        case let array as [Any]:
            for (offset, value) in array.enumerated() {
                let childPath = "\(parentPath)[\(offset)]"
                result.append(JSONNodeModel(key: nil, index: offset, raw: value,
                                            path: childPath, depth: depth + 1))
            }
        default:
            break
        }
        return result
    }
}

/// 文档：一次解析 + 节点计数（截断保护）
final class JSONDocument: ObservableObject {
    let root: JSONNodeModel
    let totalNodeCount: Int
    let isTruncated: Bool

    static let maxNodes = 20000

    /// 解析来源（JSONL = 一行一条 JSON 的多行记录，2026-10-20 用户实证
    /// 「这个 json 文件没有自动完成解析」——JSONL 旧判定直接失败落纯文本）
    let isJSONL: Bool
    /// 原始文本（「原始」视图用；JSONL 保留行结构）
    let sourceText: String
    /// JSONL 行统计（对齐 jlens：有效行 / 错误行可见，坏行不再整份报废）
    let sourceLineCount: Int
    let validLineCount: Int
    /// 解析失败的行号（1 起，最多记 50 条，避免坏文件撑爆 UI）
    let errorLines: [Int]

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allLines = trimmed.components(separatedBy: "\n")
        var object: Any?
        var isJSONL = false
        var validLines = 0
        var errors: [Int] = []

        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            object = parsed
            validLines = allLines.count
        } else {
            // JSONL 回退：**逐行容错**——坏行跳过并记下行号，其余记录照常展示。
            // 旧实现只要有一行坏就整份失败，最后落到纯文本，等于这个文件白打开。
            var records: [Any] = []
            for (index, line) in allLines.enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                if let d = t.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
                   o is [String: Any] || o is [Any] {
                    records.append(o)
                    validLines += 1
                } else if errors.count < 50 {
                    errors.append(index + 1)
                }
            }
            // 有效行太少就不认（普通文本每行都会失败，避免把散文当 JSON）
            guard !records.isEmpty, records.count >= errors.count else { return nil }
            object = records
            isJSONL = true
        }
        guard let object else { return nil }
        self.isJSONL = isJSONL
        self.sourceText = trimmed
        self.sourceLineCount = allLines.count
        self.validLineCount = validLines
        self.errorLines = errors
        root = JSONNodeModel(key: nil, raw: object, path: "$", depth: 0)
        // 计数单独走一遍（不建模型，成本低；上限到了就停）
        var count = 0
        var truncated = false
        func walk(_ value: Any) {
            if truncated { return }
            count += 1
            if count > Self.maxNodes { truncated = true; return }
            switch value {
            case let dict as [String: Any]:
                for v in dict.values { walk(v) }
            case let array as [Any]:
                for v in array { walk(v) }
            default:
                break
            }
        }
        walk(object)
        totalNodeCount = count
        isTruncated = truncated
    }
}

// MARK: - 双视图容器（树形 / 表格）

struct JSONInspectorView: View {
    @ObservedObject private var document: JSONDocument
    @Stored private var mode: JSONViewMode = .tree
    @Stored private var searchText: String = ""
    /// 树形搜索命中的节点路径（含其所有祖先，便于自动展开到命中处）
    @Stored private var matchedPaths: Set<String> = []
    /// 表格交互状态（排序/列筛选/分页）：引用类型，弹层与主表格共享同一份（v191）
    @StateObject private var tableState = JSONTableState()
    @Stored private var matchCount: Int = 0
    private let compact: Bool

    init(text: String, compact: Bool = false, initialMode: JSONViewMode = .tree,
         initialQuery: String = "") {
        // 解析失败时给一个空的根节点（调用方已判过 kind，这里是兜底）
        self.init(document: JSONDocument(text: text) ?? JSONDocument(text: "null")!,
                  compact: compact, initialMode: initialMode, initialQuery: initialQuery)
    }

    /// 已有解析结果时直接复用（独立窗自己解析过一次，内部视图不再重复解析大文件）
    init(document: JSONDocument, compact: Bool = false, initialMode: JSONViewMode = .tree,
         initialQuery: String = "") {
        self.compact = compact
        _searchText = Stored(wrappedValue: initialQuery)
        // 首层自动展开：折叠的根节点只有一行，看不出结构（原版 JSON 预览打开即可见第一层）
        if document.root.isExpandable, !document.root.isExpanded { document.root.toggle() }
        _document = ObservedObject(wrappedValue: document)
        // 记录型（对象数组 / JSONL）默认进「表格」——像数据库表一样直接看数据
        var mode = initialMode
        if mode == .tree, document.root.kind == .array {
            if document.root.children.isEmpty { document.root.ensureChildren() }
            let sample = document.root.children.prefix(20)
            if !sample.isEmpty, sample.allSatisfy({ $0.kind == .object }) { mode = .table }
        }
        _mode = Stored(wrappedValue: mode)
    }

    enum JSONViewMode: String, CaseIterable {
        case tree = "树形"
        case table = "表格"
        case cards = "卡片"
        case raw = "原始"
    }

    private var fontSize: CGFloat { compact ? 11 : 12.5 }
    private var rowHeight: CGFloat { compact ? 22 : 26 }
    /// 左列（key）固定宽度：右侧值列越长越能看清，key 只做索引用
    private var keyWidth: CGFloat { compact ? 84 : 104 }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var body: some View {
        // 外层 GeometryReader 把内容宽度钉死成窗口宽度：
        // 表格/工具条的固有宽度一旦超过窗口，SwiftUI 会整体居中溢出，
        // 左右两侧被裁（实测「树形」首个分段和行号列都被切掉）。
        GeometryReader { geo in
            VStack(spacing: 0) {
                toolbar
                if document.isTruncated {
                    banner("文件过大，仅解析前 \(Self.maxNodesText) 个节点")
                }
                if document.isJSONL {
                    jsonlBanner
                }
                Divider().opacity(0.5)
                content
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear(perform: refreshMatches)
        .onChange(of: searchText) { _ in refreshMatches() }
        .onChange(of: mode) { newMode in
            // 表格/卡片视图不依赖 matchedPaths，跳过递归；树形才需要
            if newMode == .tree { refreshMatches() }
        }
    }

    private static let maxNodesText = "2 万"

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.cardFill)
    }

    /// JSONL 行统计（对齐 jlens：有效行 / 错误行都要看得见）
    @ViewBuilder
    private var jsonlBanner: some View {
        let total = document.sourceLineCount
        let valid = document.validLineCount
        let bad = document.errorLines
        HStack(spacing: 8) {
            Image(systemName: bad.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(bad.isEmpty ? Color.secondary : Color.orange)
            Text("JSONL · 共 \(total) 行 · 有效 \(valid) 行")
            if !bad.isEmpty {
                Text("· 错误 \(bad.count) 行")
                    .foregroundStyle(Color.orange)
                Text("（第 \(bad.prefix(6).map(String.init).joined(separator: "、"))\(bad.count > 6 ? "…" : "") 行）")
            }
            Spacer(minLength: 4)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.cardFill)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("视图", selection: $mode) {
                ForEach(JSONViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 132 装不下「树形/表格/卡片/原始」四个分段：控件内部内容居中溢出，
            // 首个分段会被窗口左边缘裁掉（实测「树形」只剩「形」）
            .frame(width: compact ? 152 : 180)

            Spacer(minLength: 4)

            if !query.isEmpty, mode == .tree {
                Text("匹配 \(matchCount) 处")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索 key / 值", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .frame(width: compact ? 118 : 168)
        }
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .tree:
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    JSONTreeList(node: document.root, depth: 0, fontSize: fontSize,
                                 rowHeight: rowHeight, keyWidth: keyWidth,
                                 filterActive: !query.isEmpty, matchedPaths: matchedPaths,
                                 query: query)
                }
                .padding(.vertical, 4)
            }
        case .table:
            JSONTableView(document: document, fontSize: fontSize, query: query, state: tableState)
        case .cards:
            JSONCardsView(document: document, fontSize: fontSize, filter: searchText)
        case .raw:
            JSONRawView(document: document, fontSize: fontSize)
        }
    }

    // MARK: 搜索索引（树形）

    /// 一次递归把「命中节点 + 其祖先」收进集合：树形搜索才能自动展开到命中处，
    /// 否则折叠着的树搜什么都看不见（旧实现只是给可见行加了个底色）。
    private func refreshMatches() {
        guard !query.isEmpty else {
            matchedPaths = []
            matchCount = 0
            return
        }
        var paths: Set<String> = []
        var hits = 0
        var budget = 6000          // 深/宽 JSON 下限制遍历量，避免一次输入卡死
        _ = collectMatches(document.root, query: query, paths: &paths,
                           hits: &hits, budget: &budget)
        matchedPaths = paths
        matchCount = hits
    }

    @discardableResult
    private func collectMatches(_ node: JSONNodeModel, query: String,
                                paths: inout Set<String>, hits: inout Int,
                                budget: inout Int) -> Bool {
        if budget <= 0 { return false }
        budget -= 1
        var selfHit = false
        if let key = node.key, key.localizedCaseInsensitiveContains(query) { selfHit = true }
        if node.preview.localizedCaseInsensitiveContains(query) { selfHit = true }
        if selfHit { hits += 1 }

        var childHit = false
        if node.isExpandable {
            node.ensureChildren()
            for child in node.children {
                if collectMatches(child, query: query, paths: &paths,
                                   hits: &hits, budget: &budget) {
                    childHit = true
                }
                if budget <= 0 { break }
            }
        }
        if selfHit || childHit { paths.insert(node.path) }
        return selfHit || childHit
    }
}

// MARK: - 卡片视图（记录逐张卡片：序号 + 键值行；对齐 jlens 卡片态）

/// 值预览去引号：字符串节点的 preview 带 JSON 引号，表/卡视图里显得脏
private func displayValue(_ s: String) -> String {
    var v = s.trimmingCharacters(in: .whitespaces)
    if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
        v = String(v.dropFirst().dropLast())
    }
    return v
}

private struct JSONCardsView: View {
    let document: JSONDocument
    let fontSize: CGFloat
    let filter: String

    private var records: [JSONNodeModel] {
        if document.root.children.isEmpty { document.root.ensureChildren() }
        // 根是对象 → 一张卡；根是数组 → 每元素一张卡
        let list = document.root.kind == .array ? document.root.children : [document.root]
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(list.prefix(500)) }
        return Array(list.filter { node in
            node.ensureChildren()
            if let k = node.key, k.lowercased().contains(q) { return true }
            return node.children.contains { child in
                (child.key ?? "").lowercased().contains(q) || child.preview.lowercased().contains(q)
            }
        }.prefix(500))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(records.enumerated()), id: \.offset) { index, node in
                    card(node: node, index: index)
                }
            }
            .padding(10)
        }
    }

    private func card(node: JSONNodeModel, index: Int) -> some View {
        node.ensureChildren()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(index + 1)")
                    .font(.system(size: fontSize - 1, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Divider().opacity(0.4)
            ForEach(node.children) { child in
                HStack(alignment: .top, spacing: 8) {
                    Text(child.key ?? "值")
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(1)
                    Text(displayValue(child.preview))
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - 原始视图（pretty-print 文本 / JSONL 原行，可选中复制）

private struct JSONRawView: View {
    let document: JSONDocument
    let fontSize: CGFloat

    private var pretty: String {
        guard !document.isJSONL else { return document.sourceText }
        if let data = document.sourceText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: out, encoding: .utf8) {
            return s
        }
        return document.sourceText
    }

    var body: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            Text(pretty)
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }
}

// MARK: - 树形列表（递归 + 懒渲染）

private struct JSONTreeList: View {
    @ObservedObject var node: JSONNodeModel
    let depth: Int
    let fontSize: CGFloat
    let rowHeight: CGFloat
    let keyWidth: CGFloat
    /// 搜索态：只渲染命中分支，并自动展开到命中处
    let filterActive: Bool
    let matchedPaths: Set<String>
    let query: String

    private var visible: Bool { !filterActive || matchedPaths.contains(node.path) }

    /// 本行自身命中（不含"只是祖先"的情况），用于底色高亮
    private var isHit: Bool {
        guard filterActive, !query.isEmpty else { return false }
        if let key = node.key, key.localizedCaseInsensitiveContains(query) { return true }
        return node.preview.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        if visible {
            LazyVStack(alignment: .leading, spacing: 0) {
                row
                if node.isExpandable, node.isExpanded || filterActive {
                    ForEach(node.children.filter { !filterActive || matchedPaths.contains($0.path) }) { child in
                        JSONTreeList(node: child, depth: depth + 1,
                                     fontSize: fontSize, rowHeight: rowHeight,
                                     keyWidth: keyWidth, filterActive: filterActive,
                                     matchedPaths: matchedPaths, query: query)
                    }
                }
            }
        }
    }

    private var row: some View {
        Button {
            guard filterActive == false else { return }   // 搜索态由命中集合控制展开
            withAnimation(Theme.Motion.fast) { node.toggle() }
        } label: {
            HStack(spacing: 4) {
                // 展开箭头（叶子节点占位对齐）
                Group {
                    if node.isExpandable {
                        Image(systemName: (node.isExpanded || filterActive) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10, height: 10)
                .foregroundStyle(.secondary)

                if let key = node.key {
                    Text(key)
                        .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // 左列固定窄：key 只是索引，值才是重点
                        .frame(width: keyWidth, alignment: .leading)
                } else if depth == 0 {
                    Text("[$]")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: keyWidth, alignment: .leading)
                } else {
                    // 数组元素：显示真实下标（此前用 depth-1 占位，所有元素都显示 [0]）
                    Text("[\(node.index ?? 0)]")
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: keyWidth, alignment: .leading)
                }

                Text(node.kind.badge)
                    .font(.system(size: fontSize - 3, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 18, alignment: .leading)

                Text(node.preview)
                    .font(.system(size: fontSize - 0.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 右列吃掉剩余宽度：长值/长路径能看到更多，窗口变宽时自动多显字符
                    .frame(maxWidth: .infinity, alignment: .leading)

                if node.isExpandable {
                    Text("· \(node.childCount)")
                        .font(.system(size: fontSize - 3, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize()
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 6)
            .padding(.trailing, 8)      // 右侧子项计数不再贴窗口边缘被裁
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHit ? Theme.accent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 表格视图（对象数组 → 数据库表；对象 → 键值表；标量数组 → 序号表）
//
// 2026-10-20：此前只有「根是对象数组」才有表，对象根直接显示「表格视图需要对象数组」，
// 用户拿一份普通对象 JSON 点表格只会看到死路。现在按根类型自动选表型。
//
// 2026-11-03（对齐 jlens）：补上三件表格该有的事——
//   · 全局搜索在表格里也生效（旧实现搜索框对表格完全无效）
//   · 每列「筛选此列」：勾选该列的去重值（Excel 式），可多列叠加
//   · 点单元格看完整值（长字符串/嵌套对象在表格里只能看一行）

// MARK: - 表格交互状态（v191）
//
// 为什么单独抽一个 class：
//   原来 sortKey / columnFilters / page 都用 `@Stored`（= @StateObject 包装）。
//   `JSONTableView` 是值类型，**列筛选弹层**（popover）里的 Toggle 闭包捕获的是
//   一份 struct 副本，它写 `columnFilters` 只写进副本的 StateObject storage，
//   主表格那份没变 → 勾了选项、表格却纹丝不动（2026-11-03 鼠标实测复现：
//   group 勾 A 后仍是 257 行）。@StateObject 的 storage 不跨副本共享。
//   改成引用类型后，父视图持有一份、弹层与主表格拿的是同一个实例，@Published
//   一改动两边同时刷新。
private final class JSONTableState: ObservableObject {
    /// 排序列（nil = 原序；点表头切换 升/降）
    @Published var sortKey: String? = nil
    @Published var sortAscending: Bool = true
    /// 每列勾选的值（键 = 列名）；全部勾选 = 不过滤
    @Published var columnFilters: [String: Set<String>] = [:]
    @Published var filterPopoverColumn: String? = nil
    @Published var detail: JSONCellDetail? = nil
    /// 当前页（0 基）。搜索/筛选/排序变化后由 safePage 夹到有效范围。
    @Published var page: Int = 0
}

private struct JSONTableView: View {
    let document: JSONDocument
    let fontSize: CGFloat
    let query: String

    @ObservedObject var state: JSONTableState

    private struct Column {
        let key: String
        let width: CGFloat
    }

    private enum Shape {
        case objectRows      // 根 = 对象数组（每个元素变一行，键并集变列）
        case keyValue        // 根 = 对象（键 / 值 两列）
        case scalars         // 根 = 标量数组（序号 / 值）
        case unsupported
    }

    private var shape: Shape {
        switch document.root.kind {
        case .object:
            return .keyValue
        case .array:
            if document.root.children.isEmpty { document.root.ensureChildren() }
            let rows = document.root.children.prefix(200)
            let objectLike = rows.filter { $0.kind == .object || $0.kind == .array }
            return objectLike.isEmpty ? .scalars : .objectRows
        default:
            return .unsupported
        }
    }

    private var columns: [Column] {
        switch shape {
        case .keyValue:
            return [Column(key: "键", width: fontSize * 9),
                    Column(key: "值", width: fontSize * 12)]
        case .scalars:
            return [Column(key: "值", width: fontSize * 12)]
        case .objectRows:
            var order: [String] = []
            var maxLength: [String: Int] = [:]
            for row in document.root.children.prefix(500) {
                if row.children.isEmpty { row.ensureChildren() }
                for child in row.children {
                    let key = child.key ?? ""
                    if maxLength[key] == nil {
                        order.append(key)
                        maxLength[key] = key.count
                    } else {
                        maxLength[key] = max(maxLength[key] ?? 0, key.count)
                    }
                }
            }
            return order.map { key in
                // 单列最宽 140：10 列的常见记录表刚好塞进 980 宽的窗口；
                // 更宽的列不再撑爆窗口（超宽时整表可横向滚动）
                Column(key: key, width: min(140, max(64, CGFloat(maxLength[key] ?? 0) * fontSize * 0.62 + 28)))
            }
        case .unsupported:
            return []
        }
    }

    /// 表格实际宽度：列宽 + 每列左右 8pt 内边距 + 行号列
    private var tableWidth: CGFloat {
        34 + columns.reduce(0) { $0 + $1.width + 8 }
    }

    /// 真实行数（未被 500 行上限截断的那个数）
    private var totalRowCount: Int {
        switch shape {
        case .unsupported: return 0
        default:
            if document.root.children.isEmpty { document.root.ensureChildren() }
            return document.root.children.count
        }
    }

    /// 每页行数（v191：对齐 jlens 的真分页；旧实现只渲染前 500 行 + 一句"仅显示前 500 行"）
    private static let pageSize = 500
    /// 表格处理行数上限：超大 JSON（十万级）全量字符串化会把窗口卡住，
    /// 超过这个数就不再进表格（仍可在树形里看，或用搜索缩小范围）
    private static let maxTableRows = 50_000
    /// 表格顶部的滚动锚点（翻页后回到这里）
    private static let tableTopID = "jsonTableTop"

    /// 未过滤、未排序的全部行（列筛选的去重值从这里取，避免"筛完只剩一个选项"）
    private var allRows: [(index: Int, cells: [String])] {
        switch shape {
        case .keyValue:
            if document.root.children.isEmpty { document.root.ensureChildren() }
            return document.root.children.prefix(Self.maxTableRows).enumerated().map { index, child in
                (index, [child.key ?? "", displayValue(child.preview)])
            }
        case .scalars:
            if document.root.children.isEmpty { document.root.ensureChildren() }
            return document.root.children.prefix(Self.maxTableRows).enumerated().map { index, child in
                (index, [child.preview])
            }
        case .objectRows:
            let cols = columns.map { $0.key }
            return document.root.children.prefix(Self.maxTableRows).enumerated().map { index, row in
                row.ensureChildren()
                var map: [String: String] = [:]
                for child in row.children { if let key = child.key { map[key] = child.preview } }
                return (index, cols.map { displayValue(map[$0] ?? "—") })
            }
        case .unsupported:
            return []
        }
    }

    private var rowValues: [(index: Int, cells: [String])] {
        var rows = allRows

        // ① 全局搜索：任意列包含查询词
        if !query.isEmpty {
            rows = rows.filter { row in
                row.cells.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        // ② 每列勾选值（多列 AND）
        let activeFilters = state.columnFilters.filter { !$0.value.isEmpty }
        if !activeFilters.isEmpty, !columns.isEmpty {
            rows = rows.filter { row in
                for (key, values) in activeFilters {
                    guard let colIndex = columns.firstIndex(where: { $0.key == key }),
                          row.cells.count > colIndex else { continue }
                    if !values.contains(row.cells[colIndex]) { return false }
                }
                return true
            }
        }

        // ③ 点表头排序
        if let key = state.sortKey, !rows.isEmpty, let colIndex = columns.firstIndex(where: { $0.key == key }) {
            let asc = state.sortAscending
            rows.sort { a, b in
                let av = a.cells.count > colIndex ? a.cells[colIndex] : ""
                let bv = b.cells.count > colIndex ? b.cells[colIndex] : ""
                if let an = Double(av), let bn = Double(bv) {
                    return asc ? an < bn : an > bn
                }
                return asc ? av.localizedCaseInsensitiveCompare(bv) == .orderedAscending
                           : av.localizedCaseInsensitiveCompare(bv) == .orderedDescending
            }
        }
        return rows
    }

    // MARK: 分页（v191：对齐 jlens）

    /// 过滤后的总行数
    private var filteredRowCount: Int { rowValues.count }
    /// 总页数（至少 1 页，空结果也显示「第 1 / 1 页」）
    private var pageCount: Int { max(1, (filteredRowCount + Self.pageSize - 1) / Self.pageSize) }
    /// 当前页（越界自动夹到有效范围——搜索/筛选后行数变少时不会停在空页）
    private var safePage: Int { min(max(0, state.page), pageCount - 1) }
    /// 当前页要渲染的行
    private var pagedRows: [(index: Int, cells: [String])] {
        let start = safePage * Self.pageSize
        guard start < filteredRowCount else { return [] }
        return Array(rowValues.dropFirst(start).prefix(Self.pageSize))
    }

    /// 某列的去重值（最多 60 个，按出现顺序前 500 行统计）
    private func distinctValues(for column: String) -> [String] {
        guard let colIndex = columns.firstIndex(where: { $0.key == column }) else { return [] }
        var seen: Set<String> = []
        var order: [String] = []
        for row in allRows where row.cells.count > colIndex {
            let value = row.cells[colIndex]
            if seen.insert(value).inserted {
                order.append(value)
                if order.count >= 60 { break }
            }
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func tapHeader(_ key: String) {
        if state.sortKey == key {
            state.sortAscending.toggle()
        } else {
            state.sortKey = key
            state.sortAscending = true
        }
    }

    private func toggleFilterValue(column: String, value: String) {
        var values = state.columnFilters[column] ?? []
        if values.contains(value) { values.remove(value) } else { values.insert(value) }
        state.columnFilters[column] = values.isEmpty ? nil : values
    }

    private func isFiltered(column: String, value: String) -> Bool {
        guard let values = state.columnFilters[column], !values.isEmpty else { return false }
        return values.contains(value)
    }

    var body: some View {
        if columns.isEmpty {
            VStack(spacing: 8) {
                Text("当前 JSON 是单个值，没有可展开的表格")
                    .font(.system(size: fontSize))
                Text("请切回树形查看")
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if hasActiveFilter {
                    HStack(spacing: 6) {
                        Text("显示 \(rowValues.count) / \(allRows.count) 行")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if !query.isEmpty { Text("· 搜索「\(query)」").font(.system(size: 10)).foregroundStyle(.secondary) }
                        Spacer()
                        Button("清除筛选") {
                            state.columnFilters = [:]
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Theme.cardFill)
                }
                ScrollViewReader { tableProxy in
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header.id(Self.tableTopID)
                        if rowValues.isEmpty, !query.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11))
                                Text("当前表格视图无匹配。嵌套层级里的匹配请切到「树形」搜索。")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                        ForEach(pagedRows, id: \.index) { row in
                            HStack(spacing: 0) {
                                // v191：行号用 verbatim——Text("\(int)") 会走本地化数字格式，
                                // 第 3 页起显示成「1,001」，和前面几页的「501」不齐（列宽也吃不消）
                                Text(verbatim: "\(row.index + 1)")
                                    .font(.system(size: fontSize - 2, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .frame(width: 34, alignment: .leading)
                                ForEach(Array(row.cells.enumerated()), id: \.offset) { colIndex, value in
                                    let isLast = colIndex == row.cells.count - 1
                                    let width = columns[min(colIndex, columns.count - 1)].width
                                    Button {
                                        state.detail = JSONCellDetail(column: columns[min(colIndex, columns.count - 1)].key,
                                                                value: value,
                                                                rowNumber: row.index + 1)
                                    } label: {
                                        Text(value)
                                            .font(.system(size: fontSize - 1, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(width: isLast ? nil : width, alignment: .leading)
                                            .frame(maxWidth: isLast ? .infinity : nil, alignment: .leading)
                                            .padding(.horizontal, 4)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("点击查看完整值")
                                }
                            }
                            .frame(height: 26)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(row.index.isMultiple(of: 2) ? Color.primary.opacity(0.02) : Color.clear)
                        }
                    }
                    .frame(minWidth: tableWidth + 16, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.visible)
                // 翻页后回到表格顶部：否则新一页从上一页的滚动偏移开始，用户看到的是半截
                .onChange(of: safePage) { _ in
                    tableProxy.scrollTo(Self.tableTopID, anchor: .top)
                }
                }

                // v191（对齐 jlens）：真分页——每页 500 行，翻页不出表格；
                // 旧实现只渲染前 500 行 + 一句"仅显示前 500 行"，后面的数据看不到。
                if filteredRowCount > Self.pageSize || totalRowCount > Self.maxTableRows {
                    HStack(spacing: 6) {
                        if totalRowCount > Self.maxTableRows {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 10))
                            Text("共 \(totalRowCount) 行，表格最多处理 \(Self.maxTableRows) 行 · 其余请用搜索或树形查看")
                                .font(.system(size: 10))
                        } else {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 9))
                            Text("第 \(safePage + 1) / \(pageCount) 页 · 共 \(filteredRowCount) 行")
                                .font(.system(size: 10).monospacedDigit())
                        }
                        Spacer()
                        if filteredRowCount > Self.pageSize {
                            Button { state.page = max(0, safePage - 1) } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(safePage <= 0)
                            .help("上一页")

                            Button { state.page = min(pageCount - 1, safePage + 1) } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(safePage >= pageCount - 1)
                            .help("下一页")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Theme.cardFill)
                }
            }
            .sheet(item: $state.detail) { item in
                JSONCellDetailView(detail: item, fontSize: fontSize)
            }
            // 搜索/筛选一变，结果集就变了：回到第 1 页（否则可能停在越界的空白页）
            .onChange(of: query) { _ in state.page = 0 }
            .onChange(of: state.columnFilters) { _ in state.page = 0 }
        }
    }

    private var hasActiveFilter: Bool {
        !query.isEmpty || state.columnFilters.contains { !$0.value.isEmpty }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: fontSize - 2, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            ForEach(columns, id: \.key) { column in
                HStack(spacing: 0) {
                    Button {
                        tapHeader(column.key)
                    } label: {
                        HStack(spacing: 3) {
                            Text(column.key)
                                .lineLimit(1)
                            if state.sortKey == column.key {
                                Image(systemName: state.sortAscending ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                            }
                        }
                        .font(.system(size: fontSize - 2, weight: .semibold))
                        .foregroundStyle(state.sortKey == column.key ? Theme.accent : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("点击按此列排序")

                    Button {
                        state.filterPopoverColumn = (state.filterPopoverColumn == column.key) ? nil : column.key
                    } label: {
                        Image(systemName: isColumnFiltered(column.key)
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(isColumnFiltered(column.key) ? Theme.accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("筛选此列")
                    .popover(isPresented: Binding(
                        get: { state.filterPopoverColumn == column.key },
                        set: { if !$0 { state.filterPopoverColumn = nil } })) {
                        filterPopover(for: column.key)
                    }
                }
                .frame(width: column.width, alignment: .leading)
                .padding(.horizontal, 4)
            }
        }
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill)
    }

    private func isColumnFiltered(_ column: String) -> Bool {
        !(state.columnFilters[column]?.isEmpty ?? true)
    }

    private func filterPopover(for column: String) -> some View {
        let values = distinctValues(for: column)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(column)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("清除") { state.columnFilters[column] = nil }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(!isColumnFiltered(column))
            }
            Divider()
            if values.isEmpty {
                Text("此列没有可筛选的值")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(values, id: \.self) { value in
                            Toggle(isOn: Binding(
                                get: { isFiltered(column: column, value: value) },
                                set: { _ in toggleFilterValue(column: column, value: value) })) {
                                Text(value.isEmpty ? "（空）" : value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 230)
            }
        }
        .padding(10)
        .frame(width: 244)
    }
}

// MARK: - 单元格详情（点表格里的一格看完整值）

private struct JSONCellDetail: Identifiable {
    let id = UUID()
    let column: String
    let value: String
    let rowNumber: Int
}

private struct JSONCellDetailView: View {
    let detail: JSONCellDetail
    let fontSize: CGFloat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("第 \(detail.rowNumber) 行 · \(detail.column)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail.value, forType: .string)
                    Toast.show("已复制", icon: "doc.on.doc")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                Button("关闭") { dismiss() }
                    .font(.system(size: 11))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(detail.value)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 420, minHeight: 260)
    }
}
