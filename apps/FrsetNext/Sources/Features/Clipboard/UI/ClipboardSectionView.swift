import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 主面板区段（05 号规格 1.3：ClipboardSectionView）

/// 剪贴板区段：搜索框 + 过滤栏 + 行列表。
/// 数据来源直接观察 `ClipboardManager`（ObservableObject），避免中间 store 带来的双重真相。
public struct ClipboardSectionView: View {

    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var tagStore = TagStore.shared
    /// 面板当前页（主页/性能监测/中转站）——非主页时要禁用列表的 hover 追踪
    /// （2026-10-18 幽灵预览修复：三页 ZStack 常驻，透明主页的 NSTrackingArea
    ///  仍在接收 mouseMoved，会在性能页/中转站页上误弹预览）
    @ObservedObject private var pagePresenter = MonitorCenterPresenter.shared

    @Stored private var summaryState = SummaryState()
    // 注意：裸 swiftc 自检无 SwiftUIMacros 插件，@State 不可用（CONTRACT §7.4）→ 用 @Stored
    @Stored private var scrollProxy = ClipboardTableScrollProxy()

    private var isPageActive: Bool { pagePresenter.activePage == .home }

    public init() {}

    public var body: some View {
        // 原版主页的剪贴板**没有**区段标题、搜索框和过滤栏——就是一条条的行；
        // 搜索走面板顶部搜索框（Toolbox 的 SearchSectionView），标签过滤/浮动窗/刷新收进右键菜单与状态栏菜单。
        VStack(spacing: 0) {
            list
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            // 面板复用：清理预览协调器的抑制/未决 WorkItem（specs/12 prepareForPanelAppear）
            // 经 ServiceLocator.panelPreview 协议调用，不引用 Panel 具体类型（CONTRACT §1.3）
            ServiceLocator.panelPreview?.prepareForPanelAppear()
            manager.reload(reset: true)
            tagStore.refresh()
        }
        .alert(summaryState.title, isPresented: $summaryState.isPresented) {
            Button("好") { summaryState.reset() }
        } message: {
            Text(summaryState.message)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Theme.sectionHeader("剪贴板")
            Spacer()
            ClipboardTagFilterMenu(selectedTagID: Binding(get: { manager.tagFilterID },
                                                          set: { manager.tagFilterID = $0 }))
            Button {
                FloatingClipboardWindowController.shared.toggle()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("打开/关闭浮动窗")
            Button {
                manager.reload(reset: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
    }

    // MARK: 列表（specs/14 §4：NSTableView 宿主，行交互族在 ClipboardTableHostView）

    private var list: some View {
        Group {
            if manager.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(manager.searchText.isEmpty ? "还没有剪贴板记录" : "没有匹配的结果")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ClipboardTableHostView(manager: manager,
                                       scrollProxy: scrollProxy,
                                       isActive: isPageActive,
                                       onCopy: { manager.copy($0) },
                                       onEdit: { ClipboardItemEditWindowRecord.open(for: $0) },
                                       onSummarize: { item in
                                           Task { await runSummary(for: item) }
                                       },
                                       onDelete: { item in
                                           ServiceLocator.panelPreview?.notifyItemRemoved(itemID: item.id)
                                           manager.delete(item)
                                       })
                    // v91（2026-10-20 用户：「日历与剪贴板没有统一宽度」）：
                    // 此前只锁高度，NSScrollView 的固有宽度参与布局 → 表格比
                    // 日历卡（maxWidth: .infinity）窄约 6pt。锁满宽后行卡与日历卡同宽。
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: AI 摘要

    private func runSummary(for item: ClipboardItem) async {
        do {
            let summary = try await ClipboardSummaryExecutionCoordinator.shared.summarize(item)
            summaryState.show(title: "AI 摘要", message: summary)
        } catch {
            summaryState.show(title: "摘要失败", message: error.localizedDescription)
        }
    }
}

// MARK: - 摘要提示状态

private struct SummaryState {
    var isPresented = false
    var title = ""
    var message = ""

    mutating func show(title: String, message: String) {
        self.title = title; self.message = message; self.isPresented = true
    }
    mutating func reset() {
        self.title = ""; self.message = ""; self.isPresented = false
    }
}

// MARK: - 过滤栏（05 号规格 1.3 + specs/14 §3.6：九类型项 + 回顶按钮）

// MARK: - 标签过滤入口（05 号规格 B6：按标签过滤）

/// 头部标签下拉：选中某个标签后，列表只显示该标签下的条目；再选一次取消。
public struct ClipboardTagFilterMenu: View {

    @ObservedObject private var tagStore = TagStore.shared
    @Binding public var selectedTagID: String?

    public init(selectedTagID: Binding<String?>) { self._selectedTagID = selectedTagID }

    public var body: some View {
        Menu {
            Button("全部标签") { selectedTagID = nil }
            if !tagStore.tags.isEmpty { Divider() }
            ForEach(tagStore.tags) { tag in
                Button {
                    selectedTagID = (selectedTagID == tag.id) ? nil : tag.id
                } label: {
                    Label(tag.name, systemImage: selectedTagID == tag.id ? "checkmark" : "tag")
                }
            }
            if tagStore.tags.isEmpty { Text("暂无标签") }
        } label: {
            Image(systemName: selectedTagID == nil ? "tag" : "tag.fill")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("按标签过滤")
    }
}

// MARK: - 行

/// 菜单动作描述（05 号规格 1.3：ClipboardMenuActionItem）
public struct ClipboardMenuActionItem: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let isEnabled: Bool
    public let action: () -> Void

    public init(id: String = UUID().uuidString, title: String, systemImage: String,
                isEnabled: Bool = true, action: @escaping () -> Void) {
        self.id = id; self.title = title; self.systemImage = systemImage
        self.isEnabled = isEnabled; self.action = action
    }
}

/// 剪贴板条目 → 可投递文件（v112 空投联动；两个菜单实现共用）
/// 图片 → 图片文件；文件 → 原文件；文本/富文本/URL → 文本文件。磁盘上不存在则 nil。
extension ClipboardItem {
    public var airDropFileURL: URL? {
        let fm = FileManager.default
        switch type {
        case .image:
            if let p = imagePath, fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
            return nil
        case .file:
            if let c = content, fm.fileExists(atPath: c) { return URL(fileURLWithPath: c) }
            return nil
        case .text, .richtext, .url:
            if let p = textPath, fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
            return nil
        }
    }
}

/// 右键菜单内容（复制/编辑/标签/预览/AI摘要/删除）
public struct ClipboardRowMenuContent: View {

    @ObservedObject private var tagStore = TagStore.shared
    public let item: ClipboardItem
    @Binding public var newTagName: String

    public init(item: ClipboardItem, newTagName: Binding<String> = .constant("")) {
        self.item = item
        self._newTagName = newTagName
    }

    public var body: some View {
        actionsView
        Divider()
        Menu("标签") {
            ForEach(tagStore.tags) { tag in
                Button {
                    tagStore.toggle(tagID: tag.id, dedupeKey: item.dedupeKey)
                } label: {
                    Label(tag.name, systemImage: item.tagIDs.contains(tag.id) ? "checkmark" : "tag")
                }
            }
            if tagStore.tags.isEmpty { Text("暂无标签") }
            Divider()
            TextField("新建标签…", text: $newTagName, onCommit: {
                guard let created = tagStore.create(name: newTagName) else { newTagName = ""; return }
                tagStore.assign(tagID: created.id, toDedupeKey: item.dedupeKey)
                newTagName = ""
            })
        }
    }

    private var actionsView: some View {
        ForEach(actions) { action in
            Button(action: action.action) {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(!action.isEnabled)
        }
    }

    /// 菜单项集合：AI 摘要在无 LLM 服务时被禁用
    private var actions: [ClipboardMenuActionItem] {
        let manager = ClipboardManager.shared
        let canSummarize = ClipboardSummaryExecutionCoordinator.shared.isAvailable
        return [
            ClipboardMenuActionItem(id: "copy", title: "复制", systemImage: "doc.on.doc") { manager.copy(item) },
            // v112 空投联动：条目文件 → 系统空投面板（经通知走 App 层接线）
            ClipboardMenuActionItem(id: "airDrop", title: "隔空投送", systemImage: "dot.radiowaves.left.and.right",
                                    isEnabled: item.airDropFileURL != nil) {
                if let url = item.airDropFileURL {
                    NotificationCenter.default.post(name: .frsetAirDropFiles, object: nil,
                                                    userInfo: ["urls": [url]])
                }
            },
            ClipboardMenuActionItem(id: "edit", title: "编辑", systemImage: "pencil") {
                ClipboardItemEditWindowRecord.open(for: item)
            },
            ClipboardMenuActionItem(id: "rename", title: "重命名", systemImage: "character.cursor.ibeam") {
                ClipboardItemEditWindowRecord.open(for: item)
            },
            ClipboardMenuActionItem(id: "note", title: item.isNote ? "取消笔记标记" : "标记为笔记",
                                    systemImage: "note.text") { manager.setNote(item, isNote: !item.isNote) },
            ClipboardMenuActionItem(id: "summary", title: "AI 摘要", systemImage: "sparkles",
                                    isEnabled: canSummarize) {
                Task { _ = try? await ClipboardSummaryExecutionCoordinator.shared.summarizeAndWriteBack(item) }
            },
            ClipboardMenuActionItem(id: "delete", title: "删除", systemImage: "trash") { manager.delete(item) }
        ]
    }
}

// MARK: - 行视图

/// 主列表行（NSTableView 宿主渲染）。点击分派不在这里：
/// 单击/双击/右键由 RowHostingView 处理（specs/14 §3.2/§3.7）；
/// hover 高亮由 ClipboardTableView 的跟踪回调驱动（抑制语义见 ClipboardRowHoverSuppressionController）。
public struct ClipboardRow: View {

    /// v66 个性化（徽章显隐/缩略图档位变更 → 行即时刷新）
    @ObservedObject private var personalization = Personalization.shared

    public let item: ClipboardItem
    /// 是否处于 hover 高亮态（由表格宿主设置）
    public let isHighlighted: Bool
    public let onCopy: () -> Void
    public let onEdit: () -> Void
    public let onSummarize: () -> Void

    @ObservedObject private var tagStore = TagStore.shared

    public init(item: ClipboardItem,
                isHighlighted: Bool,
                onCopy: @escaping () -> Void,
                onEdit: @escaping () -> Void,
                onSummarize: @escaping () -> Void) {
        self.item = item
        self.isHighlighted = isHighlighted
        self.onCopy = onCopy; self.onEdit = onEdit
        self.onSummarize = onSummarize
    }

    public var body: some View {
        // 原版行式（400 宽面板实测）：50pt 缩略图 + 单行标题 + 「时间 · 详情」，
        // hover 时右侧出现 ↓（复制）/ ↵（复制并粘贴）两个图标；行底为浅色圆角卡。
        // 2026-10-18 补齐官方「来源应用徽章」：缩略图右下角小图标（bundleId → icon）。
        // v66：徽章显隐走「个性化」（默认开）；缩略图边长走密度/覆盖档位。
        HStack(spacing: 12) {
            ClipboardThumbnailView(item: item, size: Personalization.shared.effectiveThumbSize, corner: 8)
                .overlay(alignment: .bottomTrailing) {
                    if Personalization.shared.showSourceBadge, let badge = sourceAppBadge {
                        Image(nsImage: badge)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 0.75)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isHighlighted {
                HStack(spacing: 10) {
                    iconButton("arrow.down", help: "复制") { onCopy() }
                    iconButton("return.left", help: "复制并粘贴") {
                        ClipboardManager.shared.copy(item, autoPaste: true)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        // v156（用户：「这些色彩需要回退，当前版本非常鲜艳…中间没有什么间距，
        // 蓝色框会直接填满」）：
        // v153 把行做成「整行铺强调色 + 无行距」，hover 时就是一条贴边的蓝砖。
        // 现在拆成两级、都内缩：
        //   · hover（这里）——中性色、内缩 6pt、G2 圆角，只做「指针在这行」的提示；
        //   · 选中（AppKit 的 ClipboardRowChromeView 绘制）——同样内缩，低透明度强调色。
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isHighlighted ? Theme.rowHoverFill : Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
        }
        // 分隔线内缩到文字左缘（跟随缩略图），两端留白——满宽横线会让行看起来像表格而不是列表
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator.opacity(0.5))
                .frame(height: 0.5)
                .padding(.leading, 14)
                .padding(.trailing, 10)
        }
        // v129（内存）：移除 v112「宽度实证」的 GeometryReader 埋点——每行一个
        // GeometryReader + onAppear/onChange 各打一条 Log（字符串格式化 + 落盘），
        // 列表滚动/布局抖动时是每行每帧的分配churn（non-object 小块 + CFString），
        // 实证完成后属纯调试残留。
    }

    /// 来源应用图标（官方行式：缩略图右下角徽章；sourceApp 优先 bundleId）
    private var sourceAppBadge: NSImage? {
        guard let name = item.sourceApp, !name.isEmpty else { return nil }
        return ClipboardAppIconCache.icon(forAppName: name)
    }

    /// 副行：「3分钟前 · 341 个字符」/「1分钟前 · 291×465 pt」/「1分钟前 · rgb(24,24,24) · /picker」
    private var subline: String {
        var parts: [String] = [item.timestamp.relativeText]
        if let detail = detailText, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    private var detailText: String? {
        switch item.type {
        case .text, .richtext:
            // 原版副行第二段：字符数（"341 个字符"）；取色/工具条目显示来源标记
            if let input = item.sourceInput, !input.isEmpty {
                let keyword = item.sourceToolKeyword.map { " · /\($0)" } ?? ""
                return input + keyword
            }
            let count = item.fullTextCharCount ?? item.content?.count ?? 0
            return count > 0 ? "\(count) 个字符" : nil
        case .image:
            return imagePixelSize() ?? "图片"
        case .url:
            if let host = item.content.flatMap({ URL(string: $0)?.host }) { return host }
            return "链接"
        case .file:
            guard let first = item.content?.split(separator: "\n").first.map(String.init) else { return nil }
            let path = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if let size = imagePixelSize(at: path) { return size }
            return (path as NSString).lastPathComponent
        }
    }

    private func imagePixelSize() -> String? {
        guard let path = item.imagePath else { return nil }
        let url = ClipboardFileStore.url(forRelativePath: path)
        return Self.imageSizeText(at: url.path)
    }

    private func imagePixelSize(at path: String) -> String? {
        Self.imageSizeText(at: path)
    }

    // v126（性能审计 F0685）：图片像素尺寸文本缓存。
    // 行 body 每次求值都 CGImageSourceCreateWithURL 读盘取元数据（滑动时每帧×每行），
    // 而图片落盘后尺寸不变——按路径缓存，滚动热路径零 IO。
    // v128（内存优化）：原缓存无界，按路径无限增长。加 countLimit=512
    // （字符串条目小，可多留；文本类无需 totalCostLimit）。
    private static let sizeTextCache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 512
        return c
    }()

    private static func imageSizeText(at path: String) -> String? {
        if let hit = sizeTextCache.object(forKey: path as NSString) { return hit as String }
        // v128（内存优化）：包 autoreleasepool——滚动热路径每行 body 求值都可能
        // CGImageSource 读盘取元数据（产生 CFString/NSDictionary 桥接对象），
        // 列表重绘是成批触发，不显式 drain 会堆积
        return autoreleasepool {
            // v101 性能审计：原实现 NSImage(contentsOfFile:) 整图解码只为取像素宽高——
            // 图片行每次 body 求值都同步解码整图（滑动掉帧源）。改 ImageIO 只读元数据。
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width > 0, height > 0 else { return nil }
            let text = "\(width)×\(height) pt"
            sizeTextCache.setObject(text as NSString, forKey: path as NSString)
            return text
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 缩略图

/// 行缩略图：图片走磁盘缩略图，文件走系统图标，其余走类型符号
public struct ClipboardThumbnailView: View {

    public let item: ClipboardItem
    public let size: CGFloat
    public let corner: CGFloat

    public init(item: ClipboardItem, size: CGFloat = Theme.thumbSize, corner: CGFloat = 6) {
        self.item = item; self.size = size; self.corner = corner
    }

    public var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let fileIcon = fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        // v181/v182：缩略图卡统一玻璃卡（自带裁切 + 发丝边）
        .glassCard(radius: corner)
    }

    private var image: NSImage? {
        ClipboardImageStorage.image(relativePath: item.thumbnailPath ?? item.imagePath)
    }

    // v137（性能审计 #6）：行卡文件图标缓存——NSWorkspace.icon(forFile:) 每次 body
    // 求值都走 IconServices 查找/生成（滚动时每帧×每行），图标本身不随时间变化，
    // 按路径缓存即可（countLimit 256，与 AppIconCache 同口径）
    private static let fileIconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    private var fileIcon: NSImage? {
        guard item.type == .file, let path = item.content?.split(separator: "\n").first else { return nil }
        let filePath = String(path)
        let key = filePath as NSString
        if let hit = Self.fileIconCache.object(forKey: key) { return hit }

        // v170（用户：「剪贴板里的压缩包预览图没有给出来」）：
        // 原来无条件调 `NSWorkspace.icon(forFile:)`。当原文件已不在（剪贴板里的
        // /tmp/xxx.zip 被系统清理、或文件被移走）时，它返回的是**一张空白通用文档**，
        // 行看起来就是「没有预览图」。
        // 文件还在 → 用真实图标（保留 Finder 里的自定义图标）；
        // 文件已不在 → 按扩展名取**类型图标**（zip 仍是 zip 图标），不再是一张白纸。
        if FileManager.default.fileExists(atPath: filePath) {
            let icon = NSWorkspace.shared.icon(forFile: filePath)
            Self.fileIconCache.setObject(icon, forKey: key)
            return icon
        }
        let ext = URL(fileURLWithPath: filePath).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        return NSWorkspace.shared.icon(for: type)
    }

    private var symbolName: String {
        switch item.type {
        case .text: return "doc.plaintext"
        case .richtext: return "doc.richtext"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

// MARK: - 颜色扩展

public extension Color {
    /// 支持 #RRGGBB / #RGB 两种写法
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["#"])
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        let r = Double((number >> 16) & 0xff) / 255
        let g = Double((number >> 8) & 0xff) / 255
        let b = Double(number & 0xff) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
