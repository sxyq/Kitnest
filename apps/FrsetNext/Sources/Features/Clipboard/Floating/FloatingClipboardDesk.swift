import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 悬浮剪贴板「工作台」（v191 全新设计）
//
// 参照（用户 2026-11-03 指定，要求"一模一样"）：
//   · 无标题栏的大圆角浮窗，**搜索常驻顶部**，打开即可打字（不用先点搜索框）
//   · 一行分类：全部 / 文本 / 图片 / 链接 / 文件 / 代码 / 颜色 / 工具 / 笔记
//   · 双列瀑布卡片，卡片没有标题行，内容直接铺满
//   · 左下角来源 App 图标，右下角相对时间
//   · 粘完即走（面板立刻消失，焦点回到原 App）
//   · 网格 / 列表两种布局 + 三档卡片大小
//
// 与旧实现（240×290 单列 12 条 + 底部三个图标）的区别是"能独立用完全程"：
// 搜索优先、卡片可扫读、键盘闭环、粘完即走。


/// 十六进制色串 → Color（#RGB / #RRGGBB；解析失败退回强调色）
private func floatingClipColor(from hex: String) -> Color {
    var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if text.hasPrefix("#") { text.removeFirst() }
    if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
    guard text.count == 6, let value = UInt32(text, radix: 16) else { return Theme.accent }
    return Color(nsColor: NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                                 green: CGFloat((value >> 8) & 0xFF) / 255,
                                 blue: CGFloat(value & 0xFF) / 255,
                                 alpha: 1))
}

// MARK: - 布局与档位

public enum FloatingClipLayout: String, CaseIterable, Sendable {
    case grid, list

    public var label: String { self == .grid ? "网格" : "列表" }
    public var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

public enum FloatingClipCardSize: String, CaseIterable, Sendable {
    case small, medium, large

    public var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    /// 网格列数
    public var columns: Int {
        switch self {
        case .small: return 3
        case .medium: return 2
        case .large: return 2
        }
    }

    /// 卡片最小高度（内容多的卡片可以更高，形成瀑布感）
    public var minHeight: CGFloat {
        switch self {
        case .small: return 92
        case .medium: return 136
        case .large: return 190
        }
    }

    /// 内容区最多显示几行文字
    public var textLines: Int {
        switch self {
        case .small: return 3
        case .medium: return 5
        case .large: return 8
        }
    }
}

// MARK: - 数据源

/// 悬浮工作台的数据源：按「分类 + 搜索词」查 SQLite，主线程发布结果。
///
/// 为什么不复用 `FloatingClipboardStore`：那个只取最近 12 条且没有分类/搜索查询能力；
/// 这里要的是"能在几万条历史里立刻找到那一条"，必须走 `ClipboardRepository` 的 SQL 过滤。
public final class FloatingClipDeskStore: ObservableObject {

    public static let shared = FloatingClipDeskStore()
    public let settingsPreview: Bool

    @Published public private(set) var items: [ClipboardItem] = []
    @Published public private(set) var totalInKind: Int = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadedKind: ClipboardFilterKind = .all
    @Published public private(set) var loadedSearch: String = ""
    private var loadedTagFilterID: String?

    /// 当前分类（切换后立刻重新查询）
    @Published public var kind: ClipboardFilterKind = .all {
        didSet { selectedIndex = 0; reload(debounce: false) }
    }
    /// 搜索词（输入即筛，内部 60ms 防抖）
    @Published public var search: String = "" {
        didSet { selectedIndex = 0; reload(debounce: true) }
    }
    /// 键盘光标（网格里的序号）
    @Published public var selectedIndex: Int = 0

    /// v260（滚动掉帧）：当前选中条目的 id。
    /// 列表改成按 `item.id` 直接遍历后就不需要 index 了，判选中走这个。
    public var selectedItemID: String? {
        items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
    }

    /// v260：按条目选中（列表按 id 遍历后不再有 index 可用）。
    /// 查找是 O(n)，但只在点击时走一次，不在滚动热路径上。
    public func select(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = index
        }
    }

    /// 布局（网格 / 列表）
    @Published public var layout: FloatingClipLayout = FloatingClipPrefs.layout {
        didSet { if !settingsPreview { FloatingClipPrefs.layout = layout } }
    }
    /// 标签筛选（nil = 不筛）
    @Published public var tagFilterID: String? = nil {
        didSet { selectedIndex = 0; reload(debounce: false) }
    }
    /// 卡片档位（决定网格列数，键盘上下移动按列数跳）
    @Published public var cardSize: FloatingClipCardSize = FloatingClipPrefs.cardSize {
        didSet { if !settingsPreview { FloatingClipPrefs.cardSize = cardSize } }
    }
    /// 两栏分隔比例（左栏卡片区占整宽的比例，v193）
    /// 拖动过程中不落盘（每帧写偏好太吵），松手时才 persistSplitRatio()。
    @Published public var splitRatio: CGFloat = FloatingClipPrefs.splitRatio
    /// 右侧预览栏的内容模型（选中项的完整预览）
    @Published public private(set) var previewModel: PreviewPopoverContentModel?

    /// 粘贴后回调（由窗口控制器挂上"收起面板"）
    public var onPaste: ((@escaping () -> Void) -> Void)?

    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "frset.clipdesk.query", qos: .userInitiated)
    private var observer: NSObjectProtocol?

    public init(settingsPreview: Bool = false) {
        self.settingsPreview = settingsPreview
        if settingsPreview { return }
        observer = NotificationCenter.default.addObserver(
            forName: ClipboardManager.itemsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.reload(debounce: true)
            }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: 查询

    /// 重新查询（debounce = true 用于输入过程中，避免每个字符打一次 SQL）
    public func reload(debounce: Bool = false) {
        if settingsPreview { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fetch() }
        pending = work
        if debounce {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        } else {
            work.perform()
        }
    }

    private func fetch() {
        let kind = self.kind
        let search = self.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapping = kind.queryMapping
        var query = ClipboardQuery()
        query.type = mapping.type
        query.noteOnly = mapping.noteOnly
        query.toolGeneratedOnly = mapping.toolGeneratedOnly
        query.generatedSourceKeyword = mapping.generatedSourceKeyword
        query.codeLikeOnly = mapping.codeLikeOnly
        query.urlLikeOnly = (kind == .link)   // v202：链接分类兼容历史 text 条目
        query.search = search
        query.tagID = tagFilterID
        query.limit = 120          // 屏幕一屏装不下这么多，够滚动两屏
        query.offset = 0

        isLoading = true
        queue.async { [weak self] in
            let fetched = autoreleasepool { ClipboardRepository.shared.fetch(query) }
            DispatchQueue.main.async {
                guard let self else { return }
                // 查询期间用户又改了条件：丢弃这次结果，避免列表和分类/搜索不一致
                guard kind == self.kind,
                      search == self.search.trimmingCharacters(in: .whitespacesAndNewlines),
                      query.tagID == self.tagFilterID else { return }
                let selectedID = self.selectedItemID
                let queryChanged = kind != self.loadedKind || search != self.loadedSearch
                    || query.tagID != self.loadedTagFilterID
                self.items = fetched
                self.totalInKind = fetched.count
                self.loadedKind = kind
                self.loadedSearch = search
                self.loadedTagFilterID = query.tagID
                self.isLoading = false
                if !queryChanged, let selectedID, let index = fetched.firstIndex(where: { $0.id == selectedID }) {
                    self.selectedIndex = index
                } else if self.selectedIndex >= fetched.count {
                    self.selectedIndex = max(0, fetched.count - 1)
                }
                self.rebuildPreviewModel()
            }
        }
    }

    // MARK: 操作

    /// 先收起非激活面板、归还键盘焦点，再写剪贴板并粘贴。
    public func paste(_ item: ClipboardItem, asPlainText: Bool = false) {
        onPaste? {
            ClipboardManager.shared.copy(item, autoPaste: true, asPlainText: asPlainText)
        }
    }

    public func pasteSelected() {
        guard items.indices.contains(selectedIndex) else { return }
        paste(items[selectedIndex])
    }

    /// 删除并保持光标位置合理
    public func delete(_ item: ClipboardItem) {
        ClipboardManager.shared.delete(item)
        reload(debounce: true)
    }

    // MARK: 右侧预览栏（v193）

    /// 当前选中项
    public var selectedItem: ClipboardItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// 重建右侧预览内容。
    ///
    /// 全文读取（落盘长文本 / RTF）会碰磁盘，因此放后台队列再回主线程发布；
    /// 否则选中一条长文本时主线程要同步读一次文件，滑动会顿。
    public func rebuildPreviewModel() {
        if settingsPreview { return }
        guard let item = selectedItem else {
            previewModel = nil
            return
        }
        let session = UUID()
        queue.async { [weak self] in
            let text = PreviewPopoverDataBridge.shared.fullText(for: item)
            let model = PreviewPopoverContentModel(item: item,
                                                  source: .floatingPreview,
                                                  entry: .mainList,
                                                  sessionID: session,
                                                  inlineText: text)
            DispatchQueue.main.async {
                guard let self, self.selectedItem?.id == item.id else { return }
                self.previewModel = model
            }
        }
    }

    /// 分隔比例落盘（拖动结束时调用一次）
    public func persistSplitRatio() {
        if !settingsPreview { FloatingClipPrefs.splitRatio = splitRatio }
    }

    // MARK: 键盘移动

    public func moveSelection(_ dx: Int, _ dy: Int, columns: Int) {
        guard !items.isEmpty else { return }
        var index = min(max(0, selectedIndex), items.count - 1)
        if dy != 0 {
            index += dy * max(1, columns)
        } else if dx != 0 {
            index += dx
        }
        selectedIndex = min(max(0, index), items.count - 1)
    }
}


// MARK: - 悬浮工作台偏好（布局 / 档位）

public enum FloatingClipPrefs {
    static let layoutKey = "floatingClip.layout"
    static let cardSizeKey = "floatingClip.cardSize"

    public static var layout: FloatingClipLayout {
        get { FloatingClipLayout(rawValue: Preferences.shared.value(layoutKey, default: "grid")) ?? .grid }
        set { Preferences.shared.set(layoutKey, newValue.rawValue) }
    }

    public static var cardSize: FloatingClipCardSize {
        get { FloatingClipCardSize(rawValue: Preferences.shared.value(cardSizeKey, default: "medium")) ?? .medium }
        set { Preferences.shared.set(cardSizeKey, newValue.rawValue) }
    }

    /// 两栏分隔比例（v193）：左栏卡片区占整宽的比例
    static let splitRatioKey = "floatingClip.splitRatio"
    public static var splitRatio: CGFloat {
        get {
            // v193：默认 0.52——两侧接近对半，Markdown/代码预览不会只剩一条缝。
            let v = CGFloat(Preferences.shared.value(splitRatioKey, default: 0.52))
            return min(0.78, max(0.22, v))
        }
        set { Preferences.shared.set(splitRatioKey, Double(min(0.78, max(0.22, newValue)))) }
    }
}

// MARK: - 主视图

public struct FloatingClipboardDeskView: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.settingsPreviewClipboardItems) private var previewItems
    @Stored private var previewSessionID = UUID()

    @ObservedObject private var store: FloatingClipDeskStore
    /// v203：玻璃四滑块（通透度/磨砂/卡片亮度/描边）要即拖即生效——
    /// 根视图自己观察个性化；只靠 frsetThemeChrome 时子树不保证重绘。
    @ObservedObject private var personalization: Personalization
    @ObservedObject private var appearanceState = AppearanceState.shared
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight
    @Stored private var showsTags = false
    @FocusState private var searchFocused: Bool

    public init(store: FloatingClipDeskStore = .shared,
                personalization: Personalization = .shared) {
        self.store = store
        self.personalization = personalization
    }

    private var appearance: ThemeAppearance {
        ThemeAppearance(personalization: personalization,
                        isMidnight: previewIsMidnight ?? appearanceState.isMidnight)
    }

    private var displayedItems: [ClipboardItem] { isSettingsPreview ? previewItems : store.items }
    private var displayedPreview: PreviewPopoverContentModel? {
        if isSettingsPreview, let item = previewItems.first {
            return PreviewPopoverContentModel(item: item, source: .floatingPreview,
                                              sessionID: previewSessionID, inlineText: item.content ?? "")
        }
        return store.previewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // v208：使用 macOS 原生标题栏（红绿灯 + 系统材质），这里只留 32pt 净空
            Color.clear.frame(height: 32)
            searchBar
            categoryBar
            Divider().opacity(0.45)
            content
            footer
        }
        // 根视图必须填满窗口而不是给出 fitting 尺寸：
        // 否则 NSHostingView 会把「一整列卡片的总高」当成窗口高度请求，窗口被撑到屏幕外。
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous))
        .overlay(
            // v260：描边强度下调。深色下 primary 就是白色，8% 的白描边会在
            // 窗口外圈画出一道明显「线框」（用户反馈的「四周曲线 + 外部线框」）。
            // 边缘交给阴影表达就够了，这里只留一丝极淡的界线。
            RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.045), lineWidth: 0.5)
        )
        .tint(appearance.accent)
        .environment(\.settingsPreviewPersonalization, personalization)
        .onAppear {
            if isSettingsPreview { return }
            store.reload(debounce: false)
            // 打开即可打字：不等用户点搜索框
            if !isSettingsPreview { DispatchQueue.main.async { searchFocused = true } }
        }
        // 选中项变了 → 右侧预览跟着换
        .onChange(of: store.selectedIndex) { _ in
            if isSettingsPreview { return }
            store.rebuildPreviewModel()
        }
    }

    // MARK: 顶部搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.scaledSystem(size: 12, weight: .medium, scale: appearance.fontScale))
                .foregroundStyle(.secondary)

            TextField("搜索剪贴板", text: $store.search)
                .textFieldStyle(.plain)
                .font(.scaledSystem(size: 13, scale: appearance.fontScale))
                .focused($searchFocused)
                .onSubmit { store.pasteSelected() }

            if !store.search.isEmpty {
                Button {
                    store.search = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.scaledSystem(size: 11, scale: appearance.fontScale))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }

            Spacer(minLength: 4)

            Text("\(displayedItems.count)")
                .font(.scaledSystem(size: 10, scale: appearance.fontScale).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 分类

    private var categoryBar: some View {
        HStack(spacing: 12) {
            ForEach(ClipboardFilterKind.allCases) { kind in
                Button {
                    store.kind = kind
                    searchFocused = true
                } label: {
                    Text(kind.label)
                        .font(.scaledSystem(size: 12, weight: store.kind == kind ? .semibold : .regular, scale: appearance.fontScale))
                        .foregroundStyle(store.kind == kind ? appearance.accent : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Button {
                showsTags.toggle()
                if showsTags { TagStore.shared.refresh() }
            } label: {
                Image(systemName: store.tagFilterID == nil ? "tag" : "tag.fill")
                    .font(.scaledSystem(size: 11, scale: appearance.fontScale))
                    .foregroundStyle(store.tagFilterID == nil ? Color.secondary : appearance.accent)
            }
            .buttonStyle(.plain)
            .help("按标签筛选")
            .popover(isPresented: $showsTags, arrowEdge: .bottom) {
                tagPopover
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: 标签浮层

    private var tagPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("按标签筛选")
                    .font(.scaledSystem(size: 11, weight: .semibold, scale: appearance.fontScale))
                Spacer()
                if store.tagFilterID != nil {
                    Button("清除") {
                        store.tagFilterID = nil
                        showsTags = false
                    }
                    .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                    .buttonStyle(.plain)
                    .foregroundStyle(appearance.accent)
                }
            }
            Divider()
            if TagStore.shared.tags.isEmpty {
                Text("还没有标签")
                    .font(.scaledSystem(size: 11, scale: appearance.fontScale))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(TagStore.shared.tags) { tag in
                            Button {
                                store.tagFilterID = (store.tagFilterID == tag.id) ? nil : tag.id
                                showsTags = false
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(floatingClipColor(from: tag.colorHex))
                                        .frame(width: 8, height: 8)
                                    Text(tag.name)
                                        .font(.scaledSystem(size: 11, scale: appearance.fontScale))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if store.tagFilterID == tag.id {
                                        Image(systemName: "checkmark")
                                            .font(.scaledSystem(size: 9, weight: .bold, scale: appearance.fontScale))
                                            .foregroundStyle(appearance.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(10)
        .frame(width: 200)
    }

    // MARK: 内容（两栏：卡片栏 + 预览栏）

    /// v193（用户：「独立打开那个分离剪贴板的…两栏，两个方块，然后可以拖动的交互」）
    ///
    /// 左侧「卡片栏」= 可扫读的卡片网格（原来的内容区）；
    /// 右侧「预览栏」= 当前选中项的完整预览（复用主面板那套渲染器，
    /// Markdown / JSON / 代码 / 图片 / 富文本都走同一份实现，不另造一套）；
    /// 中间的分隔条**可以拖动**，比例会记住。
    ///
    /// 为什么值得做：原来只能「双击粘贴」，看不到条目到底长什么样——
    /// 挑一条要粘的代码，得先粘到编辑器才知道对不对。
    private var content: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                cardsPane
                    .frame(width: max(220, geo.size.width * store.splitRatio))
                SplitDivider(ratio: $store.splitRatio,
                             totalWidth: geo.size.width,
                             onCommit: { store.persistSplitRatio() })
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: Self.splitSpace)
        }
    }

    /// 分隔条用的命名坐标系（拖动起点要换算成整宽比例）
    private static let splitSpace = "deskSplit"

    /// 左栏：卡片网格 / 列表
    @ViewBuilder
    private var cardsPane: some View {
        if displayedItems.isEmpty {
            emptyState
        } else if store.layout == .grid {
            gridContent
        } else {
            listContent
        }
    }

    /// 右栏：选中项的完整预览
    @ViewBuilder
    private var previewPane: some View {
        ZStack {
            // 内嵌区底色：比窗口底暗一档，把「预览面板」和「卡片面」分成两块
            appearance.insetFill
            if let model = displayedPreview {
                PreviewPopoverContentView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    // v193：内嵌预览栏比原来的弹层窄，代码/OCR 操作条可能比栏宽；
                    // 不裁切会越过中缝画到卡片栏上（实测截图里就是压线）。
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.scaledSystem(size: 22, weight: .light, scale: appearance.fontScale))
                        .foregroundStyle(.quaternary)
                    Text(store.items.isEmpty ? "选一条看内容" : "预览栏")
                        .font(.scaledSystem(size: 12, scale: appearance.fontScale))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
                .strokeBorder(appearance.cardStroke, lineWidth: Theme.Stroke.hairline)
        )
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: store.search.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.scaledSystem(size: 28, weight: .light, scale: appearance.fontScale))
                .foregroundStyle(.quaternary)
            Text(store.search.isEmpty ? "这个分类还没有记录" : "没有匹配「\(store.search)」的条目")
                .font(.scaledSystem(size: 12, scale: appearance.fontScale))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 双列瀑布：每列是一个独立的 LazyVStack，卡片高度按内容自然变化，
    /// 下一张不跟着上一张的行高走（LazyVGrid 会把整行等高，看起来像表格）。
    private var gridContent: some View {
        let columns = store.cardSize.columns
        return ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(0..<columns), id: \.self) { column in
                        LazyVStack(spacing: 10) {
                            ForEach(columnItems(column, of: columns), id: \.element.id) { pair in
                                card(pair.element, index: pair.offset)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .padding(12)
            }
            .onChange(of: store.selectedIndex) { newValue in
                guard store.items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(store.items[newValue].id, anchor: .center)
                }
            }
        }
    }

    /// 某一列要显示的条目（按下标取模分列，保证顺序稳定）
    private func columnItems(_ column: Int,
                             of columns: Int) -> [(offset: Int, element: ClipboardItem)] {
        Array(displayedItems.enumerated()).filter { $0.offset % columns == column }
    }

    private func card(_ item: ClipboardItem, index: Int) -> some View {
        FloatingClipCard(item: item,
                         size: store.cardSize,
                         isSelected: index == store.selectedIndex,
                         personalization: personalization)
            .onTapGesture(count: 2) { store.paste(item) }
            .onTapGesture { store.selectedIndex = index }
            .contextMenu { ClipboardRowMenuContent(item: item) }
            .onDrag { dragProvider(for: item) }
            .id(item.id)
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    // v260（滚动掉帧）：原来每次 body 求值都构造一份
                    // Array(items.enumerated())（n 个元组 + 一堆 ARC 释放），
                    // 滚动时每帧一次。改成直接遍历 items、按稳定的 item.id 认行，
                    // 判选中用 selectedItemID，零临时分配。
                    ForEach(displayedItems, id: \.id) { item in
                        FloatingClipListRow(item: item, isSelected: store.selectedItemID == item.id,
                                            personalization: personalization)
                            .onTapGesture(count: 2) { store.paste(item) }
                            .onTapGesture { store.select(item) }
                            .contextMenu { ClipboardRowMenuContent(item: item) }
                            .onDrag { dragProvider(for: item) }
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: store.selectedIndex) { newValue in
                guard store.items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(store.items[newValue].id, anchor: .center)
                }
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text(statusText)
                .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            // 卡片档位（列表布局下不显示）
            if store.layout == .grid {
                HStack(spacing: 2) {
                    ForEach(FloatingClipCardSize.allCases, id: \.self) { size in
                        Button {
                            store.cardSize = size
                        } label: {
                            Text(size.label)
                                .font(.scaledSystem(size: 10, weight: store.cardSize == size ? .semibold : .regular, scale: appearance.fontScale))
                                .foregroundStyle(store.cardSize == size ? appearance.accent : Color.secondary)
                                .frame(width: 18, height: 18)
                                .background {
                                    if store.cardSize == size {
                                        RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                                            .fill(appearance.accent.opacity(0.14))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 布局切换
            ForEach(FloatingClipLayout.allCases, id: \.self) { item in
                Button {
                    store.layout = item
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.scaledSystem(size: 11, scale: appearance.fontScale))
                        .foregroundStyle(store.layout == item ? appearance.accent : Color.secondary)
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.plain)
                .help(item.label)
            }

            // v200：底部不再放关闭 ✕——改用系统标题栏左上角红绿灯；
            // Esc 仍可收起（窗口键盘监听在，见 FloatingClipboardWindowController）。
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(footerBackground)
    }

    private var statusText: String {
        if isSettingsPreview { return "示例内容 · \(previewItems.count) 条" }
        if store.isLoading { return "正在筛选…" }
        let kindText = store.kind == .all ? "全部" : store.kind.label
        let searchText = store.loadedSearch.isEmpty ? "" : " · 「\(store.loadedSearch)」"
        return "\(kindText)\(searchText) · \(store.items.count) 条"
    }

    // MARK: 背景

    private var panelBackground: some View {
        GlassSurface(cornerRadius: appearance.cornerRadius,
                     tint: Color(NSColor.windowBackgroundColor).opacity(0.72))
    }

    private var footerBackground: some View {
        Group {
            if previewIsMidnight ?? appearanceState.isMidnight {
                appearance.cardFill
            } else {
                Color.primary.opacity(0.04)
            }
        }
    }

    // MARK: 拖拽

    /// 拖出去的内容：文本给纯文本 + RTF，图片给临时 PNG 的 file URL，文件给 file URL
    private func dragProvider(for item: ClipboardItem) -> NSItemProvider {
        switch item.type {
        case .image:
            if let path = item.imagePath {
                let url = ClipboardFileStore.url(forRelativePath: path)
                if NSItemProvider(contentsOf: url) != nil {
                    return NSItemProvider(contentsOf: url)!
                }
            }
            return NSItemProvider(object: item.displayTitle as NSString)
        case .file:
            let first = (item.content ?? "").split(separator: "\n").first.map(String.init) ?? ""
            if !first.isEmpty {
                return NSItemProvider(contentsOf: URL(fileURLWithPath: first)) ?? NSItemProvider()
            }
            return NSItemProvider(object: item.displayTitle as NSString)
        case .richtext:
            let provider = NSItemProvider(object: ClipboardManager.shared.fullText(for: item) as NSString)
            if let data = item.richTextPath.flatMap({ ClipboardFileStore.read($0) }) {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier,
                                                    visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        case .text, .url:
            return NSItemProvider(object: ClipboardManager.shared.fullText(for: item) as NSString)
        }
    }
}

// MARK: - 网格卡片

private struct FloatingClipCard: View {
    let item: ClipboardItem
    let size: FloatingClipCardSize
    let isSelected: Bool
    @ObservedObject var personalization: Personalization
    @ObservedObject private var appearanceState = AppearanceState.shared
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight

    @Stored private var isHovering = false

    private var appearance: ThemeAppearance {
        ThemeAppearance(personalization: personalization,
                        isMidnight: previewIsMidnight ?? appearanceState.isMidnight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bodyContent
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            footLine
        }
        .padding(9)
        .frame(minHeight: size.minHeight, alignment: .topLeading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(isSelected ? appearance.accent.opacity(0.75) : appearance.cardStroke,
                        lineWidth: isSelected ? 1.5 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onHover { isHovering = $0 }
        .help(item.displayTitle)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            // v193（原版实拍对照）：卡片是「比窗口底亮一档」的实面，
            // 不再用 primary.opacity(0.055)——在浅色下那是灰砖，卡片之间没有层次。
            .fill(appearance.cardFill)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(appearance.accent.opacity(isHovering ? 0.06 : (isSelected ? 0.08 : 0)))
            }
    }

    // MARK: 按类型排版（没有标题行，内容直接铺满）

    @ViewBuilder
    private var bodyContent: some View {
        switch item.type {
        case .image:
            imageBody
        case .url:
            linkBody
        case .file:
            fileBody
        default:
            if isColorItem {
                colorBody
            } else if isCodeLike {
                codeBody
            } else {
                textBody(isNote: item.isNote)
            }
        }
    }

    private var imageBody: some View {
        Group {
            if let path = item.imagePath ?? item.thumbnailPath,
               let image = ClipboardImageStorage.image(relativePath: path) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: size.minHeight - 34)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            } else {
                placeholder(symbol: "photo", text: "图片")
            }
        }
    }

    private var linkBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(.scaledSystem(size: 10, weight: .semibold, scale: appearance.fontScale))
                    .foregroundStyle(appearance.accent)
                if !host.isEmpty {
                    Text(host)
                        .font(.scaledSystem(size: 11, weight: .medium, scale: appearance.fontScale))
                        .lineLimit(1)
                }
            }
            Text(pathText)
                .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                .foregroundStyle(.secondary)
                .lineLimit(size.textLines)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
    }

    private var fileBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: firstFilePath))
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(firstFilePath.isEmpty ? item.displayTitle : (firstFilePath as NSString).lastPathComponent)
                    .font(.scaledSystem(size: 11, weight: .medium, scale: appearance.fontScale))
                    .lineLimit(2)
            }
            if fileCount > 1 {
                Text("等 \(fileCount) 个文件")
                    .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func textBody(isNote: Bool) -> some View {
        Text(bodyText)
            .font(.scaledSystem(size: isNote ? 12 : 11.5, scale: appearance.fontScale))
            .lineLimit(size.textLines)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var codeBody: some View {
        Text(bodyText)
            .font(.scaledSystem(size: 10.5, design: .monospaced, scale: appearance.fontScale))
            .lineLimit(size.textLines)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.primary.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colorBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(hexColor ?? .gray)
                .frame(height: size.minHeight - 52)
            Text(hexText)
                .font(.scaledSystem(size: 10, design: .monospaced, scale: appearance.fontScale))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 底行（左 App 图标、右相对时间）

    private var footLine: some View {
        HStack(spacing: 4) {
            if personalization.showSourceBadge, let app = item.sourceApp, !app.isEmpty,
               let icon = ClipboardAppIconCache.icon(forAppName: app) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            } else if item.isNote {
                Image(systemName: "note.text")
                    .font(.scaledSystem(size: 9, scale: appearance.fontScale))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 2)
            Text(item.timestamp.relativeText)
                .font(.scaledSystem(size: 9, scale: appearance.fontScale))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
    }

    // MARK: 取值

    private var bodyText: String {
        let raw = item.content ?? item.title ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCodeLike: Bool {
        guard item.type == .text else { return false }
        let text = bodyText
        guard text.count > 8 else { return false }
        let signals = ["{", "}", ";", "func ", "def ", "class ", "import ", "let ", "const ", "=>", "SELECT "]
        return signals.contains { text.contains($0) }
    }

    private var isColorItem: Bool {
        let text = bodyText.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("#") && (text.count == 7 || text.count == 4) && hexColor != nil
    }

    private var hexText: String { bodyText.trimmingCharacters(in: .whitespaces).uppercased() }

    private var hexColor: Color? {
        var text = bodyText.trimmingCharacters(in: .whitespaces).uppercased()
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return Color(nsColor: NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                                     green: CGFloat((value >> 8) & 0xFF) / 255,
                                     blue: CGFloat(value & 0xFF) / 255,
                                     alpha: 1))
    }

    private var host: String {
        guard let url = URL(string: bodyText), let h = url.host else { return "" }
        return h.replacingOccurrences(of: "www.", with: "")
    }

    private var pathText: String {
        guard let url = URL(string: bodyText) else { return bodyText }
        var text = url.path
        if text.isEmpty || text == "/" { text = bodyText }
        if let q = url.query, !q.isEmpty { text += "?\(q)" }
        return text
    }

    private var firstFilePath: String {
        (item.content ?? "").split(separator: "\n").first.map(String.init) ?? ""
    }

    private var fileCount: Int {
        (item.content ?? "").split(separator: "\n").count
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.scaledSystem(size: 18, weight: .light, scale: appearance.fontScale))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: size.minHeight - 34)
    }
}

// MARK: - 列表行

private struct FloatingClipListRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    @ObservedObject var personalization: Personalization
    @ObservedObject private var appearanceState = AppearanceState.shared
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight
    @Stored private var isHovering = false

    private var appearance: ThemeAppearance {
        ThemeAppearance(personalization: personalization,
                        isMidnight: previewIsMidnight ?? appearanceState.isMidnight)
    }

    var body: some View {
        HStack(spacing: 9) {
            ClipboardThumbnailView(item: item,
                                   size: appearance.thumbSize * 26 / PersonalizationDensity.standard.thumbSize,
                                   corner: 5,
                                   personalization: personalization)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle)
                    .font(.scaledSystem(size: 12, scale: appearance.fontScale))
                    .lineLimit(1)
                Text(item.timestamp.relativeText)
                    .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if personalization.showSourceBadge, let app = item.sourceApp, !app.isEmpty,
               let icon = ClipboardAppIconCache.icon(forAppName: app) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(isSelected ? appearance.accent.opacity(0.14)
                      : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - 可拖动的两栏分隔条（v193）

/// 左「卡片栏」与右「预览栏」之间的分隔条。
///
/// 拖动换算：DragGesture 的 `startLocation` 取自命名坐标系 `deskSplit`
/// （= 整个 HStack 的左边缘），加上 `translation` 得到分隔条的绝对 x，
/// 再除以总宽得到比例——不能用局部坐标，否则拖多少比例都不对。
private struct SplitDivider: View {
    @Binding var ratio: CGFloat
    let totalWidth: CGFloat
    let onCommit: () -> Void
    @Stored private var isHovering = false

    var body: some View {
        Color.clear
            .frame(width: 11)
            .contentShape(Rectangle())
            .overlay(alignment: .center) {
                ZStack {
                    Rectangle()
                        .fill(Color.primary.opacity(isHovering ? 0.5 : 0.28))
                        .frame(width: 1)
                    VStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(Color.primary.opacity(isHovering ? 0.42 : 0.24))
                                .frame(width: 3, height: 3)
                        }
                    }
                }
            }
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("deskSplit"))
                    .onChanged { value in
                        let x = value.startLocation.x + value.translation.width
                        ratio = min(0.78, max(0.22, x / max(1, totalWidth)))
                    }
                    .onEnded { _ in onCommit() }
            )
            .help("拖动调整两栏比例")
    }
}
