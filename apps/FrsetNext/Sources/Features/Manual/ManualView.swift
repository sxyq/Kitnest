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

            HStack(spacing: 10) {
                Button("展开全部") { expanded = Set(allGroupIDs()) }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("收起全部") { expanded = [] }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(doc.index.count) 节")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: true) {
                let idx = searchIndex
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleRoots) { node in
                        // v128（流畅度）：树行改传命中/可见集合——原 matcher 闭包在每层
                        // 行都递归整棵子树判断可见性（节点 × 深度）；现退化为集合查表。
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

    /// 本节小节链接（交互式分支跳转）
    private func sectionLinks(_ node: ManualNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本节目录")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLinks(nodes: node.children) { n in selection = n.id }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
    }

    /// 上/下一节（按先序平铺）
    // v128（流畅度）：直读解析期平铺好的 flatNodes——原 flat 是计算属性，每次 body
    // 求值都 flatten 整棵树（递归分配数组），搜索每键都白付一遍。
    private var flat: [ManualNode] { doc.flatNodes }

    private func navFooter(_ node: ManualNode) -> some View {
        let list = flat
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

    private func allGroupIDs() -> [String] {
        // v128（流畅度）：复用解析期平铺（原 flatten 全树重建数组；仅按钮点击时调用，顺手统一）
        doc.flatNodes.filter { !$0.children.isEmpty }.map(\.id)
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
        // v126（性能审计 F1888）：去掉 flatten 中间数组——原实现在 ancestorPath 的每一层
        // 都把整棵文档树 flatten 成数组再线性扫（深度 × 节点数 次分配），而 navFooter
        // 每次 body 求值（搜索框每敲一键）都要走一遍。改为直接递归查找，命中即返回。
        // v128（流畅度）：再改为解析期建好的 parentIndex 查表 O(1)——原递归查找仍是
        // 每次 body 求值 × 每层祖先各扫一遍子树（面包屑 4 层 = 4 次全树扫描）。
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
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return (Set(doc.index.keys), Set(doc.index.keys))
        }
        var matched: Set<String> = []
        for (id, node) in doc.index where node.searchText.localizedCaseInsensitiveContains(q) {
            matched.insert(id)
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
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                        Text(n.title).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
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
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.accent.opacity(0.45))
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
                .glassCard(radius: Theme.Radius.control)

        case .divider:
            Divider().opacity(0.5)
        }
    }

    /// 行内 Markdown → AttributedString（与文件级 inlineMarkdown 同一实现）
    private func inline(_ s: String) -> AttributedString { inlineMarkdown(s) }
}

// MARK: - 图片

// 手册配图三级来源：随包资源 → 本地缓存 → 官网。
//
// 为什么演示动图不随包：37 段 GIF 合计 38 MB，DMG 会从 43 MB 涨到 81 MB，
// 而多数人只看两三章。这里改成按需取——第一次翻到某章时下载并落盘，
// 之后离线也能看。缓存目录 ~/Library/Caches/Kitnest/manual-gifs。
enum ManualImageLoader {
    /// 官网静态目录，由 tools/deploy_site.sh 一并发布
    static let remoteBase = "https://calorieai.sxyq27.online/kitnest-site/manual/gifs/"
    /// 在线手册首页（下载失败时的兜底入口）
    static let manualPage = "https://calorieai.sxyq27.online/kitnest-site/manual/"

    private static let memory = NSCache<NSString, NSImage>()

    static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kitnest/manual-gifs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func cachedFile(_ ref: String) -> URL {
        cacheDir.appendingPathComponent((ref as NSString).lastPathComponent)
    }

    /// 同步取：内存 → 随包 → 磁盘。都没有返回 nil，由调用方决定是否联网。
    static func load(_ ref: String) -> NSImage? {
        let name = (ref as NSString).lastPathComponent
        let key = name as NSString
        if let hit = memory.object(forKey: key) { return hit }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "png" : (name as NSString).pathExtension
        if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "Manual/shots"),
           let img = NSImage(contentsOf: url) {
            memory.setObject(img, forKey: key)
            return img
        }
        let cached = cachedFile(ref)
        if FileManager.default.fileExists(atPath: cached.path),
           let img = NSImage(contentsOf: cached) {
            memory.setObject(img, forKey: key)
            return img
        }
        return nil
    }

    /// 异步补：从官网拉一段，成功后落盘。回调在主线程。
    static func fetch(_ ref: String, done: @escaping (NSImage?) -> Void) {
        let name = (ref as NSString).lastPathComponent
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: remoteBase + encoded) else {
            done(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data) else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            // 先落盘再回调：下次开同一章不再联网
            try? data.write(to: cachedFile(ref), options: .atomic)
            memory.setObject(img, forKey: name as NSString)
            DispatchQueue.main.async { done(img) }
        }.resume()
    }
}

// MARK: - 动图播放
//
// SwiftUI 的 Image(nsImage:) 只画第一帧，GIF 会变成静图；必须落到 NSImageView
// 并打开 animates，才会真的动。

private struct ManualAnimatedImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.animates = true
        v.image = image
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        if v.image !== image {
            v.image = image
            v.animates = true
        }
    }

    // NSViewRepresentable 没有固有尺寸：不给 sizeThatFits 的话它会撑满正文区，
    // 4:3 的录屏被拉成竖条、右边还被窗口裁掉。这里按图片比例回报尺寸。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView,
                      context: Context) -> CGSize? {
        let s = image.size
        guard s.width > 1, s.height > 1 else { return nil }
        let limit = min(proposal.width ?? 520, 520)
        return CGSize(width: limit, height: (limit * s.height / s.width).rounded())
    }
}

private struct ManualImageView: View {
    let ref: String
    let caption: String?
    let onTap: () -> Void

    @Stored private var img: NSImage? = nil
    @Stored private var misses = 0

    private var failed: Bool { misses >= 1 && img == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let img {
                ManualAnimatedImage(image: img)
                    .frame(maxWidth: 520, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .onTapGesture(perform: onTap)
                    .help("点击查看大图")
            } else if failed {
                // 离线或取不到：不装作有内容，直接给在线入口
                Button {
                    if let url = URL(string: ManualImageLoader.manualPage) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.rectangle").font(.system(size: 12))
                        Text("演示动图未下载 · 点此在浏览器查看")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.accent.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.25), style: StrokeStyle(lineWidth: 0.7, dash: [3, 2])))
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在取演示动图…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(0.03)))
            }
            if let caption, !caption.isEmpty {
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
        }
        .onAppear(perform: start)
    }

    private func start() {
        if img != nil { return }
        if let hit = ManualImageLoader.load(ref) {
            img = hit
            return
        }
        ManualImageLoader.fetch(ref) { got in
            if let got { img = got } else { misses += 1 }
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
                // 大图也要能播：动图放大后仍是动图，不是冻在第一帧
                let s = image.size
                let k = min(940 / max(s.width, 1), 620 / max(s.height, 1), 1)
                ManualAnimatedImage(image: image)
                    .frame(width: (s.width * k).rounded(), height: (s.height * k).rounded())
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                Text(inlineMarkdown(c))
                    .font(.system(size: 11, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(isHeader ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if i < cells.count - 1 { Divider().opacity(0.25) }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isHeader ? Theme.cardFill : Color.clear)
    }

}

// v128（流畅度）：ManualBlock.plainText 移至 ManualDocument.swift——
// ManualNode.finalizeSearchText 在解析期一次性调用（原每次搜索命中判定都重算 join）。

/// 行内 Markdown → AttributedString（失败回退纯文本）。
/// v245：原本 ManualBlockView.inline 与 ManualTableView.inlineCell 各一份，合并到这里。
private func inlineMarkdown(_ s: String) -> AttributedString {
    if let a = try? AttributedString(
        markdown: s,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return a
    }
    return AttributedString(s)
}
