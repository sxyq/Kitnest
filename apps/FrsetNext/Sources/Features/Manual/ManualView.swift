import AppKit
import SwiftUI

// MARK: - 使用手册 · 设置内嵌交互式树形手册（2026-10-20）
//
// 布局：左侧分支树（可展开/收起/搜索）+ 右侧内容区（小节跳转 / 图片点击放大 /
// 上·下一节导航 / 面包屑）。数据来自随包资源 Resources/Manual/用户手册.md +
// Resources/Manual/shots/*.png（build.sh 拷贝 Resources/ 进 bundle）。
//
// 交互点：
//   · 树节点 DisclosureGroup 展开收起（章节默认全展开）
//   · 搜索框实时过滤（命中标题或正文，自动展开命中路径）
//   · 内容区顶部小节链接（点击跳转）、底部上/下一节
//   · 手册截图点击 → 大图预览（Esc/点击关闭）

public struct ManualPaneView: View {
    // 注：本机工具链缺 SwiftUIMacros 插件，@State 宏不可用 → 项目统一用 @Stored（StateCompat）
    @Stored private var doc = ManualDocument.load()
    @Stored private var selection: String?
    @Stored private var expanded: Set<String> = []
    @Stored private var query: String = ""
    @Stored private var zoom: ZoomImage?

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
            // 默认选中第一节的内容节点（章节点本身只有「本节目录」，打开即空）
            if selection == nil {
                selection = doc.roots.first?.children.first?.id ?? doc.roots.first?.id
            }
            if expanded.isEmpty {
                expanded = Set(doc.roots.map(\.id))   // 章节默认展开
            }
        }
        .sheet(item: $zoom) { z in
            ZoomSheet(image: z.image, title: z.title) { zoom = nil }
        }
    }

    // MARK: - 左：分支树

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField("搜索手册…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)

            HStack(spacing: 10) {
                Button("展开全部") { expanded = Set(allGroupIDs()) }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("收起全部") { expanded = [] }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(doc.index.count) 节")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleRoots) { node in
                        ManualTreeRow(node: node,
                                      selection: $selection,
                                      expanded: $expanded,
                                      query: query,
                                      matcher: nodeMatches)
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
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let node = current {
                    breadcrumb(for: node)
                    Text(node.title)
                        .font(.system(size: 19, weight: .semibold))
                        .textSelection(.enabled)

                    if !node.children.isEmpty {
                        sectionLinks(node)
                    }

                    ForEach(node.blocks) { item in
                        ManualBlockView(block: item.block) { ref, title in
                            if let img = ManualImageLoader.load(ref) {
                                zoom = ZoomImage(image: img, title: title ?? ref)
                            }
                        }
                    }

                    navFooter(node)
                } else {
                    Text("从左侧选择章节开始阅读").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.008))
    }

    /// 面包屑：祖先路径（点击可回跳）
    private func breadcrumb(for node: ManualNode) -> some View {
        let path = ancestorPath(node)
        return HStack(spacing: 5) {
            ForEach(path) { p in
                Button(p.title) { selection = p.id }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(selection == p.id ? Color.accentColor : .secondary)
                if p.id != path.last?.id {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// 本节小节链接（交互式分支跳转）
    private func sectionLinks(_ node: ManualNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本节目录")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLinks(nodes: node.children) { n in selection = n.id }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
    }

    /// 上/下一节（按先序平铺）
    private var flat: [ManualNode] { doc.roots.flatMap { $0.flatten() } }

    private func navFooter(_ node: ManualNode) -> some View {
        let list = flat
        let idx = list.firstIndex(where: { $0.id == node.id }) ?? 0
        let prev = idx > 0 ? list[idx - 1] : nil
        let next = idx + 1 < list.count ? list[idx + 1] : nil
        return HStack(spacing: 10) {
            if let prev {
                Button { selection = prev.id } label: {
                    Label(prev.title, systemImage: "chevron.left")
                        .font(.system(size: 10.5)).lineLimit(1)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let next {
                Button { selection = next.id } label: {
                    HStack(spacing: 4) {
                        Text(next.title).lineLimit(1)
                        Image(systemName: "chevron.right")
                    }.font(.system(size: 10.5))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
    }

    // MARK: - 树辅助

    private func allGroupIDs() -> [String] {
        doc.roots.flatMap { $0.flatten() }.filter { !$0.children.isEmpty }.map(\.id)
    }

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
        for root in doc.roots {
            for n in root.flatten() where n.children.contains(where: { $0.id == node.id }) {
                return n
            }
        }
        return nil
    }

    /// 搜索命中：标题或正文包含关键词（空查询恒真）
    private func nodeMatches(_ node: ManualNode) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if node.title.localizedCaseInsensitiveContains(q) { return true }
        for b in node.blocks where b.block.plainText.localizedCaseInsensitiveContains(q) { return true }
        return false
    }

    /// 搜索时可见的根：自身或任一后代命中
    private var visibleRoots: [ManualNode] {
        doc.roots.filter { subtreeMatches($0) }
    }

    private func subtreeMatches(_ node: ManualNode) -> Bool {
        if nodeMatches(node) { return true }
        return node.children.contains { subtreeMatches($0) }
    }
}

// MARK: - 树行

private struct ManualTreeRow: View {
    let node: ManualNode
    @Binding var selection: String?
    @Binding var expanded: Set<String>
    let query: String
    let matcher: (ManualNode) -> Bool

    private var isExpanded: Binding<Bool> {
        Binding(get: { expanded.contains(node.id) || !query.isEmpty },
                set: { on in
                    if on { expanded.insert(node.id) } else { expanded.remove(node.id) }
                })
    }

    private var visibleChildren: [ManualNode] {
        node.children.filter { subtreeMatches($0) }
    }

    private func subtreeMatches(_ n: ManualNode) -> Bool {
        if matcher(n) { return true }
        return n.children.contains { subtreeMatches($0) }
    }

    var body: some View {
        if node.children.isEmpty {
            row
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(visibleChildren) { child in
                    ManualTreeRow(node: child, selection: $selection,
                                  expanded: $expanded, query: query, matcher: matcher)
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
        let dimmed = !query.isEmpty && !matcher(node)
        return Button { selection = node.id } label: {
            HStack(spacing: 5) {
                if node.level >= 3 {
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 3, height: 3)
                }
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
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : (dimmed ? Color.secondary.opacity(0.5) : Color.primary))
    }
}

/// 树展开三角样式（小号、缩进紧凑）
private struct ManualDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { configuration.isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
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

// MARK: - 小节链接横排

private struct FlowLinks: View {
    let nodes: [ManualNode]
    let onTap: (ManualNode) -> Void
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(nodes) { n in
                Button { onTap(n) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(n.title).font(.system(size: 10.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
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
    let onImageTap: (String, String?) -> Void

    var body: some View {
        switch block {
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
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.45))
                    .frame(width: 3)
                Text(inline(s))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)

        case .image(let ref, let caption):
            ManualImageView(ref: ref, caption: caption) { onImageTap(ref, caption) }

        case .table(let headers, let rows):
            ManualTableView(headers: headers, rows: rows)

        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))

        case .divider:
            Divider().opacity(0.5)
        }
    }

    /// 行内 Markdown → AttributedString（失败回退纯文本）
    private func inline(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(s)
    }
}

// MARK: - 图片

enum ManualImageLoader {
    static func load(_ ref: String) -> NSImage? {
        let name = (ref as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Manual/shots") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

private struct ManualImageView: View {
    let ref: String
    let caption: String?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let img = ManualImageLoader.load(ref) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 560, maxHeight: 420, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .onTapGesture(perform: onTap)
                    .help("点击查看大图")
            } else {
                // 缺失截图占位：也为「一一截图补齐」提供清单线索
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 12))
                    Text("截图待补：\(ref)")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.orange.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.3), style: StrokeStyle(lineWidth: 0.7, dash: [3, 2])))
            }
            if let caption, !caption.isEmpty {
                Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ZoomImage: Identifiable {
    let image: NSImage
    let title: String
    var id: String { title }
}

private struct ZoomSheet: View {
    let image: NSImage
    let title: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 940, maxHeight: 620)
            }
        }
        .padding(14)
        .frame(width: 960, height: 700)
        .onExitCommand(perform: dismiss)
    }
}

// MARK: - 表格

private struct ManualTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            row(headers, isHeader: true)
            Divider().opacity(0.4)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                row(r, isHeader: false)
                    .background(i % 2 == 1 ? Color.primary.opacity(0.025) : Color.clear)
                if i < rows.count - 1 { Divider().opacity(0.2) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                Text(inlineCell(c))
                    .font(.system(size: 11, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(isHeader ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if i < cells.count - 1 { Divider().opacity(0.25) }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isHeader ? Color.primary.opacity(0.05) : Color.clear)
    }

    private func inlineCell(_ s: String) -> AttributedString {
        if let a = try? AttributedString(markdown: s,
                                         options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return a
        }
        return AttributedString(s)
    }
}

// MARK: - 块文本（搜索用）

private extension ManualBlock {
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
