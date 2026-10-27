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
    let kind: JSONNodeKind
    let preview: String            // 单行值预览
    let path: String
    private(set) var childCount: Int

    private let raw: Any
    private var builtChildren: [JSONNodeModel]?

    @Published private(set) var children: [JSONNodeModel] = []
    @Published private(set) var isExpanded = false

    init(key: String?, raw: Any, path: String, depth: Int) {
        self.key = key
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
                result.append(JSONNodeModel(key: key, raw: dict[key]!, path: childPath, depth: depth + 1))
            }
        case let array as [Any]:
            for (index, value) in array.enumerated() {
                let childPath = "\(parentPath)[\(index)]"
                result.append(JSONNodeModel(key: nil, raw: value, path: childPath, depth: depth + 1))
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

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var object: Any?
        var isJSONL = false
        if let data = trimmed.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            object = parsed
        } else {
            // JSONL 回退：逐行解析，全部有效行合成对象数组（表格/卡片直接当记录表用）
            var records: [Any] = []
            for line in trimmed.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { continue }
                guard let d = t.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
                      o is [String: Any] || o is [Any] else {
                    records = []
                    break
                }
                records.append(o)
            }
            guard !records.isEmpty else { return nil }
            object = records
            isJSONL = true
        }
        guard let object else { return nil }
        self.isJSONL = isJSONL
        self.sourceText = trimmed
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
    private let compact: Bool

    init(text: String, compact: Bool = false, initialMode: JSONViewMode = .tree) {
        self.compact = compact
        // 解析失败时给一个空的根节点（调用方已判过 kind，这里是兜底）
        let document = JSONDocument(text: text) ?? JSONDocument(text: "null")!
        // 首层自动展开：折叠的根节点只有一行，看不出结构（原版 JSON 预览打开即可见第一层）
        if document.root.isExpandable { document.root.toggle() }
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if document.isTruncated {
                Text("文件过大，仅解析前 \(Self.maxNodesText) 个节点")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04))
            }
            Divider().opacity(0.5)
            content
        }
    }

    private static let maxNodesText = "2 万"

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("视图", selection: $mode) {
                ForEach(JSONViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: compact ? 108 : 132)

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("筛选 key / 值", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                                 rowHeight: rowHeight, keyWidth: keyWidth, filter: searchText)
                }
                .padding(.vertical, 4)
            }
        case .table:
            JSONTableView(document: document, fontSize: fontSize)
        case .cards:
            JSONCardsView(document: document, fontSize: fontSize, filter: searchText)
        case .raw:
            JSONRawView(document: document, fontSize: fontSize)
        }
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
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
    let filter: String

    private var matched: Bool {
        filter.isEmpty ? true :
            (node.key?.localizedCaseInsensitiveContains(filter) ?? false) ||
            node.preview.localizedCaseInsensitiveContains(filter)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            row
            if node.isExpanded {
                ForEach(node.children) { child in
                    JSONTreeList(node: child, depth: depth + 1,
                                 fontSize: fontSize, rowHeight: rowHeight,
                                 keyWidth: keyWidth, filter: filter)
                }
            }
        }
    }

    private var row: some View {
        Button {
            withAnimation(Theme.Motion.fast) { node.toggle() }
        } label: {
            HStack(spacing: 4) {
                // 展开箭头（叶子节点占位对齐）
                Group {
                    if node.isExpandable {
                        Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
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
                } else {
                    Text("[\(depth == 0 ? "$" : "\(depth - 1)")]")
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
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(matched ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 表格视图（对象数组 → 数据库表；对象 → 键值表；标量数组 → 序号表）
//
// 2026-10-20：此前只有「根是对象数组」才有表，对象根直接显示「表格视图需要对象数组」，
// 用户拿一份普通对象 JSON 点表格只会看到死路。现在按根类型自动选表型。

private struct JSONTableView: View {
    let document: JSONDocument
    let fontSize: CGFloat
    /// 排序列（nil = 原序；点表头切换 升/降）
    @Stored private var sortKey: String? = nil
    @Stored private var sortAscending: Bool = true

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
                Column(key: key, width: min(180, max(64, CGFloat(maxLength[key] ?? 0) * fontSize * 0.62 + 28)))
            }
        case .unsupported:
            return []
        }
    }

    private var rowValues: [(index: Int, cells: [String])] {
        var rows: [(index: Int, cells: [String])]
        switch shape {
        case .keyValue:
            if document.root.children.isEmpty { document.root.ensureChildren() }
            return document.root.children.enumerated().map { index, child in
                (index, [child.key ?? "", displayValue(child.preview)])
            }
        case .scalars:
            if document.root.children.isEmpty { document.root.ensureChildren() }
            return document.root.children.prefix(500).enumerated().map { index, child in
                (index, [child.preview])
            }
        case .objectRows:
            let cols = columns.map { $0.key }
            return document.root.children.prefix(500).enumerated().map { index, row in
                row.ensureChildren()
                var map: [String: String] = [:]
                for child in row.children { if let key = child.key { map[key] = child.preview } }
                return (index, cols.map { displayValue(map[$0] ?? "—") })
            }
        case .unsupported:
            rows = []
        }
        // 点表头排序（升/降切换；再点恢复原序需要点第三下——两次内完成常用操作）
        if let key = sortKey, !rows.isEmpty, let colIndex = columns.firstIndex(where: { $0.key == key }) {
            let asc = sortAscending
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

    private func tapHeader(_ key: String) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
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
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(rowValues, id: \.index) { row in
                        HStack(spacing: 0) {
                            if shape != .scalars {
                                Text("#\(row.index + 1)")
                                    .font(.system(size: fontSize - 2, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .frame(width: 34, alignment: .leading)
                            } else {
                                Text("\(row.index + 1)")
                                    .font(.system(size: fontSize - 2, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .frame(width: 34, alignment: .leading)
                            }
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { colIndex, value in
                                let isLast = colIndex == row.cells.count - 1
                                let width = columns[min(colIndex, columns.count - 1)].width
                                Text(value)
                                    .font(.system(size: fontSize - 1, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: isLast ? nil : width, alignment: .leading)
                                    .frame(maxWidth: isLast ? .infinity : nil, alignment: .leading)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .frame(height: 26)
                        .background(row.index.isMultiple(of: 2) ? Color.primary.opacity(0.02) : Color.clear)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(size: fontSize - 2, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            ForEach(columns, id: \.key) { column in
                Button {
                    tapHeader(column.key)
                } label: {
                    HStack(spacing: 3) {
                        Text(column.key)
                            .lineLimit(1)
                        if sortKey == column.key {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .font(.system(size: fontSize - 2, weight: .semibold))
                    .foregroundStyle(sortKey == column.key ? Theme.accent : Color.secondary)
                    .frame(width: column.width, alignment: .leading)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击按此列排序")
            }
        }
        .frame(height: 24)
        .background(Color.primary.opacity(0.05))
    }
}
