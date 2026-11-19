import SwiftUI

// MARK: - 使用手册 · 分类与功能导航、原生演示和完整功能正文。

public struct ManualPaneView: View {
    // 注：本机工具链缺 SwiftUIMacros 插件，@State 宏不可用 → 项目统一用 @Stored（StateCompat）
    @Stored private var doc = ManualDocument.load()
    @Stored private var selection: String?
    @Stored private var expanded: Set<String> = []
    @Stored private var query: String = ""
    private let quickStartID = "manual:quick-start"

    public init() {}

    private var current: ManualNode? {
        guard let selection, let node = doc.index[selection] else { return nil }
        return node
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
            detail
        }
        .onAppear {
            selection = quickStartID
            query = ""
            expanded = Set(doc.roots.prefix(1).map(\.id))
        }
    }

    // MARK: - 左：分支树

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索手册…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .glassCard(radius: 6)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Button { selection = quickStartID } label: {
                Label("从这里开始", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(selection == quickStartID ? Theme.accent.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == quickStartID ? Theme.accent : Color.primary)
            .padding(.horizontal, 8)
            .padding(.bottom, 5)

            HStack(spacing: 10) {
                Text("按功能分类")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(doc.roots.count) 类")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: true) {
                let idx = searchIndex
                VStack(alignment: .leading, spacing: 1) {
                    if visibleRoots.isEmpty {
                        Text(query.isEmpty ? "暂无手册内容" : "未找到相关功能，请换个关键词。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(visibleRoots) { node in
                        ManualTreeRow(node: node,
                                      selection: $selection,
                                      expanded: $expanded,
                                      query: query,
                                      matched: idx.matched,
                                      visible: idx.visible)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - 右：内容

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 0).id("manual-top")
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, visibleRoots.isEmpty {
                        Text("未找到相关功能，请换个关键词。")
                            .foregroundStyle(.secondary)
                    } else if selection == quickStartID {
                        quickStart
                    } else if let node = current {
                        breadcrumb(for: node)
                        Text(node.title)
                            .font(.system(size: 19, weight: .semibold))
                            .textSelection(.enabled)

                        if node.level == 1 {
                            sectionLinks(node)
                        } else {
                            ManualDemoView(title: node.title, demoID: node.demoID ?? "tools",
                                           symbol: node.symbol, steps: node.demoSteps)
                                .id(node.id)
                            ForEach(node.blocks) { item in ManualBlockView(block: item.block) }
                            navFooter(node)
                        }
                    } else {
                        Text(doc.loadError ?? (doc.roots.isEmpty ? "手册内容尚未随应用提供。" : "从左侧选择功能开始阅读"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.008))
            .onChange(of: selection) { _ in
                proxy.scrollTo("manual-top", anchor: .top)
                if let selection, let categoryID = doc.parentIndex[selection] { expanded.insert(categoryID) }
            }
            .onChange(of: query) { _ in proxy.scrollTo("manual-top", anchor: .top) }
        }
    }

    private var quickStart: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("你想做什么？").font(.system(size: 22, weight: .semibold))
            Text("选一个常见任务，查看操作步骤和示例演示；全部功能按左侧类别整理。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                quickStartCard("找回复制过的内容", detail: "查看历史记录，再次复制或粘贴。",
                               symbol: "doc.on.clipboard", guide: "02-01-剪贴板历史")
                quickStartCard("截屏并提取文字", detail: "框选画面，识别文字并复制。",
                               symbol: "viewfinder", guide: "03-11-文字识别")
                quickStartCard("把文件发到手机", detail: "选择传输方式，查看发送结果。",
                               symbol: "iphone.and.arrow.right.inward", guide: "06-02-手机直传")
                quickStartCard("设置刘海与多屏", detail: "选择显示屏幕，了解另一块屏幕的入口。",
                               symbol: "display.2", guide: "01-03-刘海工作台与多屏")
            }
        }
    }

    private func quickStartCard(_ title: String, detail: String, symbol: String, guide: String) -> some View {
        Button { selection = guide } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Label("查看步骤与演示", systemImage: "arrow.right")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .padding(13).frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .glassCard(radius: Theme.Radius.card)
        }
        .buttonStyle(.plain)
    }

    /// 面包屑：祖先路径（点击可回跳）
    private func breadcrumb(for node: ManualNode) -> some View {
        let path = ancestorPath(node)
        return HStack(spacing: 5) {
            ForEach(path) { p in
                Button(p.title) { selection = p.id }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(selection == p.id ? Theme.accent : .secondary)
                if p.id != path.last?.id {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 分类页展示功能卡，点击进入完整正文。
    private func sectionLinks(_ node: ManualNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("选择要了解的功能")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLinks(nodes: node.children) { n in selection = n.id }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
    }

    private func navFooter(_ node: ManualNode) -> some View {
        let list = doc.flatNodes
        let idx = list.firstIndex(where: { $0.id == node.id }) ?? 0
        let prev = idx > 0 ? list[idx - 1] : nil
        let next = idx + 1 < list.count ? list[idx + 1] : nil
        return HStack(spacing: 10) {
            if let prev {
                Button { selection = prev.id } label: {
                    Label(prev.title, systemImage: "chevron.left")
                        .font(.system(size: 11)).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let next {
                Button { selection = next.id } label: {
                    HStack(spacing: 4) {
                        Text(next.title).lineLimit(1)
                        Image(systemName: "chevron.right")
                    }.font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
    }

    // MARK: - 树辅助

    private func ancestorPath(_ node: ManualNode) -> [ManualNode] {
        var path: [ManualNode] = [node]
        var cur = node
        while let parent = parent(of: cur) {
            path.insert(parent, at: 0)
            cur = parent
        }
        return path
    }

    private func parent(of node: ManualNode) -> ManualNode? {
        guard let parentID = doc.parentIndex[node.id] else { return nil }
        return doc.index[parentID]
    }

    /// 搜索命中集合 + 可见（命中 + 祖先）集合
    // v128（流畅度）：visibleRoots 原来对每个根递归 subtreeMatches，而 ManualTreeRow
    // 的 visibleChildren 又对每层子节点再递归一遍（节点 × 深度 次重复扫描），
    // 且命中判定每次都要对每个块重算 plainText（数组 join）。改为：
    // · 判定走解析期固化的 searchText（不再每键重拼文本）；
    // · 一次性算出「命中节点 id 集合」与「命中子树祖先并集」，行过滤退化为集合查表。
    private var searchIndex: (matched: Set<String>, visible: Set<String>) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return (Set(doc.index.keys), Set(doc.index.keys))
        }
        var matched: Set<String> = []
        for (id, node) in doc.index where node.searchText.localizedCaseInsensitiveContains(q) {
            matched.insert(id)
            if node.level == 1 { matched.formUnion(node.children.map(\.id)) }
        }
        // 命中节点的所有祖先也可见（父行要显示才能展开到命中行）
        var visible = matched
        for id in matched {
            var cur = id
            while let parentID = doc.parentIndex[cur] {
                visible.insert(parentID)
                cur = parentID
            }
        }
        return (matched, visible)
    }

    private var visibleRoots: [ManualNode] {
        let idx = searchIndex
        return doc.roots.filter { idx.visible.contains($0.id) }
    }
}

// MARK: - 树行

private struct ManualTreeRow: View {
    let node: ManualNode
    @Binding var selection: String?
    @Binding var expanded: Set<String>
    let query: String
    // v128（流畅度）：命中/可见集合替代 matcher 闭包——原 visibleChildren 每次 body
    // 求值都对整棵子树递归 subtreeMatches（搜索每键 × 树行数 = 节点² 量级），
    // 现在两次 Set 查表。
    let matched: Set<String>
    let visible: Set<String>

    private var isExpanded: Binding<Bool> {
        Binding(get: { expanded.contains(node.id) || !query.isEmpty },
                set: { on in
                    if on { expanded.insert(node.id) } else { expanded.remove(node.id) }
                })
    }

    private var visibleChildren: [ManualNode] {
        node.children.filter { visible.contains($0.id) }
    }

    var body: some View {
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(visibleChildren) { child in
                    ManualTreeRow(node: child, selection: $selection,
                                  expanded: $expanded, query: query,
                                  matched: matched, visible: visible)
                        .padding(.leading, 8)
                }
            } label: {
                row
            }
            .disclosureGroupStyle(ManualDisclosureStyle())
        }
    }

    private var row: some View {
        let selected = selection == node.id
        let dimmed = !query.isEmpty && !matched.contains(node.id)
        return Button { selection = node.id } label: {
            HStack(spacing: 5) {
                Image(systemName: node.level == 1 ? "folder" : node.symbol)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(node.title)
                    .font(.system(size: node.level == 1 ? 12 : 11.5,
                                  weight: node.level == 1 ? .medium : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.accent : (dimmed ? Color.secondary.opacity(0.5) : Color.primary))
    }
}

/// 树展开三角样式（小号、缩进紧凑）
private struct ManualDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Button {
                    withAnimation(Theme.Motion.fast) { configuration.isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 11, height: 11)
                }
                .buttonStyle(.plain)
                configuration.label
            }
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 7)
            }
        }
    }
}

// MARK: - 功能卡

private struct FlowLinks: View {
    let nodes: [ManualNode]
    let onTap: (ManualNode) -> Void
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(nodes) { n in
                Button { onTap(n) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: n.symbol).foregroundStyle(Theme.accent)
                            .frame(width: 20)
                        Text(n.title).font(.system(size: 12, weight: .medium))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .glassCard(radius: Theme.Radius.chip)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 内容块渲染

private struct ManualBlockView: View {
    let block: ManualBlock

    var body: some View {
        switch block {
        case .heading(let title):
            Text(inline(title))
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 10)
                .textSelection(.enabled)
        case .paragraph(let s):
            Text(inline(s))
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .textSelection(.enabled)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(inline(item))
                            .font(.system(size: 12.5))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 2)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(i + 1).")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(inline(item))
                            .font(.system(size: 12.5))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }

        case .quote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.accent.opacity(0.45))
                    .frame(width: 3)
                Text(inline(s))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        }
    }

    /// 行内 Markdown → AttributedString（与文件级 inlineMarkdown 同一实现）
    private func inline(_ s: String) -> AttributedString { inlineMarkdown(s) }
}

/// 行内强调格式转为富文本。
private func inlineMarkdown(_ s: String) -> AttributedString {
    if let a = try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return a
    }
    return AttributedString(s)
}
