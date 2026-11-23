import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 悬浮剪贴板「工作台」（v191 全新设计）
//
// 参照（用户 2026-11-03 指定，要求"一模一样"）：
//   · 无标题栏的大圆角浮窗，**搜索常驻顶部**，打开即可打字（不用先点搜索框）
//   · 一行分类：全部 / 文本 / 图片 / 链接 / 文件 / 代码 / 颜色 / 工具 / 已存
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
public final class FloatingClipDeskStore: ObservableObject {

    public static let shared = FloatingClipDeskStore()
    public let settingsPreview: Bool

    @Published public private(set) var items: [ClipboardItem] = []
    @Published private(set) var scrollRequest = 0
    let hoverSuppression = ClipboardRowHoverSuppressionController()
    @Published public private(set) var totalInKind: Int = 0
    @Published public private(set) var isLoading = false
    @Published public private(set) var loadedKind: ClipboardFilterKind = .all
    @Published public private(set) var loadedSearch: String = ""
    private var loadedTagFilterID: String?
    private var loadedFavoriteLevel: Int?
    private var loadedFavoriteOnly: Bool = false
    private var loadedRecentOnly: Bool = false
    private var loadedTagGroupID: String?
    private let queryStateLock = NSLock()
    private var queryGeneration = 0

    /// 当前分类（切换后立刻重新查询）
    @Published public var kind: ClipboardFilterKind = .all {
        didSet { if oldValue != kind { reload(debounce: false) } }
    }
    /// 搜索词（输入即筛，内部 60ms 防抖）
    @Published public var search: String = "" {
        didSet { if oldValue != search { reload(debounce: true) } }
    }
    /// 键盘光标（网格里的序号）
    @Published public var selectedIndex: Int = 0

    /// v286 统一交互层：hover 预览跟随项。悬停只改这个 id（预览栏跟随），
    /// 不夺走 selectedIndex 的主动选中；主动点击/键盘移动时清空。
    @Published public var hoveredItemID: String?

    /// v260（滚动掉帧）：当前选中条目的 id。
    /// 列表改成按 `item.id` 直接遍历后就不需要 index 了，判选中走这个。
    public var selectedItemID: String? {
        items.indices.contains(selectedIndex) ? items[selectedIndex].id : nil
    }

    /// v260：按条目选中（列表按 id 遍历后不再有 index 可用）。
    /// 查找是 O(n)，但只在点击时走一次，不在滚动热路径上。
    /// v286 统一交互层：hovering=true 只让预览栏跟随悬停项（hoveredItemID），
    /// 不改 selectedIndex、不夺走主动选中；hovering=false（点击）才真正选中。
    public func select(_ item: ClipboardItem, hovering: Bool = false) {
        if hovering {
            if hoverSuppression.isHoverSuppressed { return }
            if hoveredItemID == item.id { return }
            guard items.contains(where: { $0.id == item.id }) else { return }
            hoveredItemID = item.id
            rebuildPreviewModel(debounce: true)
            return
        }
        // 主动点击：清掉 hover 跟随，预览回到选中项。
        let hadHover = hoveredItemID != nil
        hoveredItemID = nil
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if selectedIndex != index {
                selectedIndex = index
                rebuildPreviewModel()
                scrollRequest += 1
            } else if hadHover || previewRequestedItem == item {
                // 从 hover 跟随切回主动选中（同项也重建），或重点已选项强制刷新。
                rebuildPreviewModel()
            }
        }
    }

    /// v286：鼠标离开卡片区（View 的 onHover(false) 调用）：预览回到主动选中项。
    public func clearHover() {
        guard hoveredItemID != nil else { return }
        hoveredItemID = nil
        rebuildPreviewModel(debounce: true)
    }

    /// 布局（网格 / 列表）
    @Published public var layout: FloatingClipLayout = FloatingClipPrefs.layout {
        didSet { if !settingsPreview { FloatingClipPrefs.layout = layout } }
    }
    /// 标签筛选（nil = 不筛）
    @Published public var tagFilterID: String? = nil {
        didSet { if oldValue != tagFilterID { reload(debounce: false) } }
    }
    /// 收藏等级筛选（nil=不限；1/2/3=按 resource_favorites.level 精确匹配）
    @Published public var favoriteLevel: Int? = nil {
        didSet { if oldValue != favoriteLevel { reload(debounce: false) } }
    }
    /// 全部收藏（任意等级；与 favoriteLevel 互补，两个都为 false/nil 才不限收藏）
    @Published public var favoriteOnly: Bool = false {
        didSet { if oldValue != favoriteOnly { reload(debounce: false) } }
    }
    /// 最近使用（24 小时窗口）
    @Published public var recentOnly: Bool = false {
        didSet { if oldValue != recentOnly { reload(debounce: false) } }
    }
    /// 标签分组筛选（nil=不限；按 tags.group_id 匹配）
    @Published public var tagGroupID: String? = nil {
        didSet { if oldValue != tagGroupID { reload(debounce: false) } }
    }
    /// 卡片档位（决定网格列数，键盘上下移动按列数跳）
    @Published public var cardSize: FloatingClipCardSize = FloatingClipPrefs.cardSize {
        didSet { if !settingsPreview { FloatingClipPrefs.cardSize = cardSize } }
    }
    /// 两栏分隔比例（左栏卡片区占整宽的比例，v193）
    /// 拖动过程中不落盘（每帧写偏好太吵），松手时才 persistSplitRatio()。
    @Published public var splitRatio: CGFloat = FloatingClipPrefs.splitRatio
    @Published public var hoverPreviewEnabled = FloatingClipPrefs.hoverPreviewEnabled {
        didSet { if !settingsPreview { FloatingClipPrefs.hoverPreviewEnabled = hoverPreviewEnabled } }
    }
    /// 右侧预览栏的内容模型（选中项的完整预览）
    @Published public private(set) var previewModel: PreviewPopoverContentModel?

    /// 粘贴后回调（由窗口控制器挂上"收起面板"）
    public var onPaste: ((@escaping () -> Void) -> Void)?

    private var pending: DispatchWorkItem?
    private var queryWork: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?
    private var previewRequestedItem: ClipboardItem?
    private final class CachedPreview: NSObject {
        let model: PreviewPopoverContentModel
        init(_ model: PreviewPopoverContentModel) { self.model = model }
    }
    private let previewCache: NSCache<NSString, CachedPreview> = {
        let cache = NSCache<NSString, CachedPreview>()
        cache.countLimit = 8
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private let queue = DispatchQueue(label: "frset.clipdesk.query", qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var tagObserver: NSObjectProtocol?
    private var previewSource: [ClipboardItem] = []
    private var previewContents: [String: PreviewPopoverContentModel] = [:]

    public func setPreviewItems(_ source: [ClipboardItem]) {
        guard settingsPreview, previewSource != source else { return }
        previewSource = source
        previewContents = Dictionary(uniqueKeysWithValues: source.map { item in
            (item.id, PreviewPopoverContentModel(item: item, source: .floatingPreview,
                sessionID: UUID(), inlineText: item.content ?? ""))
        })
        reload()
    }

    public init(settingsPreview: Bool = false) {
        self.settingsPreview = settingsPreview
        if settingsPreview { return }
        observer = NotificationCenter.default.addObserver(
            forName: ClipboardManager.itemsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard FloatingClipboardPinState.shared.isVisible else { return }
                self?.reload(debounce: true)
            }
        tagObserver = NotificationCenter.default.addObserver(
            forName: TagStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] note in self?.applyTagChange(note) }
    }

    deinit {
        pending?.cancel()
        queryWork?.cancel()
        previewTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let tagObserver { NotificationCenter.default.removeObserver(tagObserver) }
    }

    // MARK: 查询

    /// 重新查询（debounce = true 用于输入过程中，避免每个字符打一次 SQL）
    public func reload(debounce: Bool = false) {
        if settingsPreview {
            let selectedID = selectedItemID
            items = previewSource.filter {
                kind.matches($0) && (search.isEmpty ||
                    ($0.content ?? $0.displayTitle).localizedCaseInsensitiveContains(search))
            }
            totalInKind = items.count
            selectedIndex = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
            rebuildPreviewModel()
            return
        }
        queryStateLock.lock()
        queryGeneration += 1
        queryStateLock.unlock()
        pending?.cancel()
        queryWork?.cancel()
        isLoading = true
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.fetch()
        }
        pending = work
        if debounce {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        } else {
            work.perform()
        }
    }

    private func fetch(append: Bool = false) {
        let kind = self.kind
        let search = self.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = ClipboardQuery(filter: kind, search: search, tagID: tagFilterID,
                                   favoriteOnly: favoriteOnly,
                                   favoriteLevel: favoriteLevel, tagGroupID: tagGroupID,
                                   recentOnly: recentOnly,
                                   limit: append ? 120 : max(120, items.count),
                                   offset: append ? items.count : 0)
        queryStateLock.lock()
        let generation = queryGeneration
        queryStateLock.unlock()
        let currentTotal = totalInKind

        isLoading = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrentQuery(generation) else { return }
            let fetched = autoreleasepool { ClipboardRepository.shared.fetch(query) }
            let total = append ? currentTotal : ClipboardRepository.shared.count(query)
            DispatchQueue.main.async {
                guard self.isCurrentQuery(generation) else { return }
                // 查询期间用户又改了条件：丢弃这次结果，避免列表和分类/搜索不一致
                guard kind == self.kind,
                      search == self.search.trimmingCharacters(in: .whitespacesAndNewlines),
                      query.tagID == self.tagFilterID,
                      query.favoriteOnly == self.favoriteOnly,
                      query.favoriteLevel == self.favoriteLevel,
                      query.recentOnly == self.recentOnly,
                      query.tagGroupID == self.tagGroupID else { return }
                self.queryWork = nil
                let selectedID = self.selectedItemID
                let queryChanged = kind != self.loadedKind || search != self.loadedSearch
                    || query.tagID != self.loadedTagFilterID
                    || query.favoriteOnly != self.loadedFavoriteOnly
                    || query.favoriteLevel != self.loadedFavoriteLevel
                    || query.recentOnly != self.loadedRecentOnly
                    || query.tagGroupID != self.loadedTagGroupID
                let updated: [ClipboardItem]
                if append {
                    let existingIDs = Set(self.items.map(\.id))
                    updated = self.items + fetched.filter { !existingIDs.contains($0.id) }
                } else {
                    updated = fetched
                }
                if self.items != updated { self.items = updated }
                if self.totalInKind != total { self.totalInKind = total }
                self.loadedKind = kind
                self.loadedSearch = search
                self.loadedTagFilterID = query.tagID
                self.loadedFavoriteOnly = query.favoriteOnly
                self.loadedFavoriteLevel = query.favoriteLevel
                self.loadedRecentOnly = query.recentOnly
                self.loadedTagGroupID = query.tagGroupID
                self.isLoading = false
                // v286 分类切换保位置：新列表里还有原选中项就落到它现在的
                // index，只有找不到时才回 0（原实现 queryChanged 一律回顶）。
                let index = selectedID.flatMap { id in updated.firstIndex { $0.id == id } }
                let restored: Int
                if let index {
                    restored = index
                } else if queryChanged {
                    restored = 0
                } else {
                    restored = min(self.selectedIndex, max(0, updated.count - 1))
                }
                if self.selectedIndex != restored { self.selectedIndex = restored }
                if queryChanged { self.scrollRequest += 1 }
                self.rebuildPreviewModel()
            }
        }
        queryWork = work
        queue.async(execute: work)
    }

    private func isCurrentQuery(_ generation: Int) -> Bool {
        queryStateLock.lock()
        defer { queryStateLock.unlock() }
        return generation == queryGeneration
    }

    private func applyTagChange(_ note: Notification) {
        guard !settingsPreview, let info = note.userInfo else { return }
        if info["mappingReplaced"] as? Bool == true {
            if FloatingClipboardPinState.shared.isVisible { reload(debounce: true) }
            return
        }
        let tagID = info["tagID"] as? String
        if info["removed"] as? Bool == true, tagFilterID == tagID {
            tagFilterID = nil
            return
        }
        guard FloatingClipboardPinState.shared.isVisible else { return }
        let keys = Set(info["keys"] as? [String] ?? [])
        if !keys.isEmpty {
            var updated = items
            for index in updated.indices where keys.contains(updated[index].dedupeKey) {
                updated[index].tagIDs = TagStore.shared.tagIDs(forDedupeKey: updated[index].dedupeKey)
            }
            if updated != items { items = updated }
        }
        if tagFilterID == tagID || isLoading {
            reload(debounce: false)
        } else if keys.contains(previewTargetItem?.dedupeKey ?? "") {
            // 预览目标（悬停项优先）的标签变了才需要重建预览
            rebuildPreviewModel()
        }
    }

    // MARK: 操作

    public func loadMoreIfNeeded(_ item: ClipboardItem) {
        guard !settingsPreview, !isLoading, item.id == items.last?.id, items.count < totalInKind else { return }
        fetch(append: true)
    }

    /// 先收起非激活面板、归还键盘焦点，再写剪贴板并粘贴。
    public func paste(_ item: ClipboardItem, asPlainText: Bool = false) {
        if settingsPreview { select(item); return }
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
        if settingsPreview { previewSource.removeAll { $0.id == item.id }; reload(); return }
        ClipboardManager.shared.delete(item)
    }

    // MARK: 右侧预览栏（v193）

    /// 当前选中项
    public var selectedItem: ClipboardItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// v286：预览栏目标——悬停项优先（仍在列表中才生效），否则回落到主动选中项。
    public var previewTargetItem: ClipboardItem? {
        if let id = hoveredItemID, let item = items.first(where: { $0.id == id }) {
            return item
        }
        return selectedItem
    }

    /// 重建右侧预览内容。
    ///
    /// 全文读取（落盘长文本 / RTF）会碰磁盘，因此放后台队列再回主线程发布；
    /// 否则选中一条长文本时主线程要同步读一次文件，滑动会顿。
    /// v286：目标取 `previewTargetItem`（悬停项优先，回落选中项），hover 只影响预览。
    public func rebuildPreviewModel(debounce: Bool = false) {
        let target = previewTargetItem
        if settingsPreview { previewModel = target.flatMap { previewContents[$0.id] }; return }
        if let item = target, previewModel?.item == item {
            previewTask?.cancel()
            previewRequestedItem = nil
            return
        }
        if let item = target, let cached = previewCache.object(forKey: item.id as NSString),
           cached.model.item == item {
            previewTask?.cancel()
            previewRequestedItem = nil
            previewModel = cached.model
            return
        }
        if debounce, previewRequestedItem == target { return }
        previewTask?.cancel()
        previewRequestedItem = target
        guard let item = target else {
            previewModel = nil
            return
        }
        // 2026-11-19：悬停仅合并最终选择，取消的任务在读盘前退出。
        previewTask = Task { @MainActor [weak self] in
            if debounce { try? await Task.sleep(nanoseconds: 60_000_000) }
            guard !Task.isCancelled else { return }
            let loader = Task.detached(priority: .userInitiated) { () -> PreviewPopoverContentModel? in
                guard !Task.isCancelled else { return nil }
                let text = PreviewPopoverDataBridge.shared.fullText(for: item)
                guard !Task.isCancelled else { return nil }
                return PreviewPopoverContentModel(item: item, source: .floatingPreview,
                    sessionID: UUID(), inlineText: text, fullTextLoaded: true)
            }
            let model = await withTaskCancellationHandler(operation: { await loader.value },
                                                          onCancel: { loader.cancel() })
            guard !Task.isCancelled, let self, self.previewTargetItem == item else { return }
            self.previewRequestedItem = nil
            self.previewTask = nil
            self.previewModel = model
            if let model, model.inlineText.utf8.count <= 1_048_576,
               [.text, .fileBackedText, .markdown, .json, .code].contains(model.kind) {
                self.previewCache.setObject(CachedPreview(model), forKey: item.id as NSString,
                                            cost: model.inlineText.utf8.count)
            }
        }
    }

    func suspendPreview() {
        queryStateLock.lock()
        queryGeneration += 1
        queryStateLock.unlock()
        pending?.cancel()
        queryWork?.cancel()
        pending = nil
        isLoading = false
        previewTask?.cancel()
        previewRequestedItem = nil
        previewModel = nil
        hoveredItemID = nil
        previewCache.removeAllObjects()
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
        index = min(max(0, index), items.count - 1)
        guard selectedIndex != index else { return }
        hoverSuppression.suppressUntilMouseMove()
        hoveredItemID = nil // 键盘移动也是主动选中，预览跟随光标而非悬停项
        selectedIndex = index
        rebuildPreviewModel()
        scrollRequest += 1
    }
}


// MARK: - 悬浮工作台偏好（布局 / 档位）

public enum FloatingClipPrefs {
    static let layoutKey = "floatingClip.layout"
    static let cardSizeKey = "floatingClip.cardSize"
    static let hoverPreviewKey = "floatingClip.hoverPreview"
    public static var hoverPreviewEnabled: Bool {
        get { Preferences.shared.value(hoverPreviewKey, default: true) }
        set { Preferences.shared.set(hoverPreviewKey, newValue) }
    }

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
    /// v287 三栏工作台：侧栏宽度
    static let sidebarWidthKey = "floatingClip.sidebarWidth"
    public static var sidebarWidth: CGFloat {
        get {
            let v = CGFloat(Preferences.shared.value(sidebarWidthKey, default: 190))
            return min(280, max(140, v))
        }
        set { Preferences.shared.set(sidebarWidthKey, Double(min(280, max(140, newValue)))) }
    }
}

// MARK: - 主视图

public struct FloatingClipboardDeskView: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.settingsPreviewClipboardItems) private var previewItems
    @Environment(\.settingsPreviewClipboardSelection) private var previewSelection

    @ObservedObject private var store: FloatingClipDeskStore
    @ObservedObject private var tagStore = TagStore.shared
    /// v203：玻璃四滑块（通透度/磨砂/卡片亮度/描边）要即拖即生效——
    /// 根视图自己观察个性化；只靠 frsetThemeChrome 时子树不保证重绘。
    @ObservedObject private var personalization: Personalization
    @ObservedObject private var appearanceState = AppearanceState.shared
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight
    @Stored private var showsTags = false
    @Stored private var isManagingTags = false
    @FocusState private var searchFocused: Bool
    /// v287 三栏工作台：标签分组展开/折叠
    @Stored private var expandedTagGroups: Set<String> = []
    /// v287 三栏工作台：侧栏宽度（拖拽可调，落盘记忆）
    @Stored private var sidebarWidth: CGFloat = FloatingClipPrefs.sidebarWidth

    public init(store: FloatingClipDeskStore = .shared,
                personalization: Personalization = .shared) {
        self.store = store
        self.personalization = personalization
    }

    private var appearance: ThemeAppearance {
        ThemeAppearance(personalization: personalization,
                        isMidnight: previewIsMidnight ?? appearanceState.isMidnight)
    }

    private var displayedItems: [ClipboardItem] { store.items }
    private var displayedPreview: PreviewPopoverContentModel? { store.previewModel }

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
        // v287：三栏工作台加宽到 720（侧栏 190 + 卡片/预览 530）
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous))
        .overlay(
            // v260：描边强度下调。深色下 primary 就是白色，8% 的白描边会在
            // 窗口外圈画出一道明显「线框」（用户反馈的「四周曲线 + 外部线框」）。
            // 2026-11-23：结构面描边统一 cardStroke（跟随「描边」滑块可调）+ hairline，
            // 不再手写 primary 0.045 / 0.5 字面量。
            RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: Theme.Stroke.hairline)
        )
        .tint(appearance.accent)
        .environment(\.settingsPreviewPersonalization, personalization)
        .sheet(isPresented: $isManagingTags) { TagManagementSheet() }
        .onReceive(NotificationCenter.default.publisher(for: TagStore.manageRequestedNotification)) { note in
            if !isSettingsPreview, note.object as? String == "floating" { isManagingTags = true }
        }
        .onAppear {
            if isSettingsPreview {
                store.setPreviewItems(previewItems)
                if let item = store.items.first(where: { $0.id == previewSelection?.wrappedValue }) { store.select(item) }
                return
            }
            // 打开即可打字：不等用户点搜索框
            if !isSettingsPreview { DispatchQueue.main.async { searchFocused = true } }
        }
        // 选中项变了 → 右侧预览跟着换
        .onChange(of: store.selectedItemID) { _ in
            if isSettingsPreview { previewSelection?.wrappedValue = store.selectedItemID }
        }
        .onChange(of: previewSelection?.wrappedValue) { id in
            if isSettingsPreview, let item = store.items.first(where: { $0.id == id }) { store.select(item) }
        }
        .onChange(of: previewItems) { if isSettingsPreview { store.setPreviewItems($0) } }
        .onMoveCommand { direction in
            switch direction {
            case .left: store.moveSelection(-1, 0, columns: store.cardSize.columns)
            case .right: store.moveSelection(1, 0, columns: store.cardSize.columns)
            case .up: store.moveSelection(0, -1, columns: store.layout == .grid ? store.cardSize.columns : 1)
            case .down: store.moveSelection(0, 1, columns: store.layout == .grid ? store.cardSize.columns : 1)
            @unknown default: break
            }
        }
        // v287 三栏工作台：Esc 逐级退回（标签 → 分组 → 收藏等级 → 最近 → 类型 → 全部）
        .onExitCommand {
            if store.tagFilterID != nil {
                store.tagFilterID = nil
            } else if store.tagGroupID != nil {
                store.tagGroupID = nil
            } else if store.favoriteLevel != nil {
                store.favoriteLevel = nil
            } else if store.favoriteOnly {
                store.favoriteOnly = false
            } else if store.recentOnly {
                store.recentOnly = false
            } else if store.kind != .all {
                store.kind = .all
            }
            // 都到底了就交给默认行为（窗口收起由 FloatingClipboardWindowController 处理）
        }
        // v287：回车粘贴由搜索框 onSubmit 提供（自动聚焦 → 输入筛选 → 方向键选中 → 回车粘贴），
        // 不另加全局 NSEvent 监听（会和搜索框输入冲突，且 macOS 13 无 onKeyPress）
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
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
            ForEach(ClipboardFilterKind.contentCases) { kind in
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
            if !isSettingsPreview {
                Menu {
                    Button("清空当前剪贴板") { ClipboardManager.shared.clearCurrentPasteboard() }
                    Button("剪贴板设置") { ServiceLocator.settings?.open(pane: "clipboard") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("剪贴板操作")
            }
            Rectangle()
                .fill(Color.secondary.opacity(0.24))
                .frame(width: 1, height: 14)
            Button {
                // v287：收藏是独立维度，不再占用 kind——在「文本」里点收藏仍是文本+收藏
                store.favoriteOnly.toggle()
                if !store.favoriteOnly { store.favoriteLevel = nil }
                searchFocused = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.favoriteOnly ? "star.fill" : "star")
                    Text("收藏")
                }
                .font(.scaledSystem(size: 12, weight: store.favoriteOnly ? .semibold : .regular,
                                    scale: appearance.fontScale))
                .foregroundStyle(store.favoriteOnly ? appearance.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("只显示收藏条目")
            .accessibilityLabel("收藏")
            Button {
                if isSettingsPreview { return }
                showsTags.toggle()
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
            if tagStore.tags.isEmpty {
                Text("还没有标签")
                    .font(.scaledSystem(size: 11, scale: appearance.fontScale))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(tagStore.tags) { tag in
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
            Divider()
            Button("管理标签…") {
                showsTags = false
                NotificationCenter.default.post(name: TagStore.manageRequestedNotification, object: "floating")
            }
            .font(.scaledSystem(size: 11, scale: appearance.fontScale))
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 200)
    }

    // MARK: 内容（三栏：分类导航 + 卡片栏 + 预览栏，v287）

    /// v287（用户需求：三栏工作台）：
    /// 左侧「分类导航栏」= 固定分类 + 收藏等级 + 标签分组 + 已存项目 + 分类管理；
    /// 中间「卡片栏」= 原有卡片网格/列表（复用 FloatingClipCard / FloatingClipListRow）；
    /// 右侧「预览栏」= 原有选中项预览（复用 FloatingClipPreview）。
    /// 宽窄自适应：窗口宽度 < 820 时收起预览栏（卡片占满右区），< 620 时侧栏收窄到 140。
    private var content: some View {
        GeometryReader { outerGeo in
            let isWide = outerGeo.size.width > 820
            let effectiveSidebarWidth: CGFloat = outerGeo.size.width < 620 ? 140 : sidebarWidth
            HStack(spacing: 0) {
                sidebarPane
                    .frame(width: effectiveSidebarWidth)
                SplitSidebarDivider(width: $sidebarWidth)
                if isWide {
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            cardsPane
                                .frame(width: geo.size.width * store.splitRatio)
                            SplitDivider(ratio: $store.splitRatio,
                                         totalWidth: geo.size.width,
                                         onCommit: { store.persistSplitRatio() })
                            previewPane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .coordinateSpace(name: Self.splitSpace)
                    }
                } else {
                    cardsPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
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
            // 2026-11-23（需求 B 五：「预览文字可读，不被玻璃透射干扰」）：
            // 预览是长文阅读面，底必须**切断玻璃透射**——否则壁纸/桌面会从正文
            // 底下透出来，小字号对比度塌掉。先铺一层不透明阅读底（与窗口同源色），
            // 再压 insetFill 的内嵌暗度，把「预览面板」和「卡片面」分成两块的
            // 层次感保留，但文字落在稳定底上。
            appearance.readingBase
            // 内嵌区底色：比窗口底暗一档，把「预览面板」和「卡片面」分成两块
            appearance.insetFill
            if let model = displayedPreview {
                FloatingClipPreview(model: model).equatable()
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

    // MARK: 左侧分类导航栏（v287 三栏工作台）

    private var sidebarPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                // v287 性能：LazyVStack 按需渲染，大量标签不卡顿
                LazyVStack(alignment: .leading, spacing: 1) {
                    // 固定分类（v287：三个筛选维度正交——类型 kind / 收藏等级 / 标签分组，
                    // 侧栏切等级不清空顶部类型，切类型不清空等级）
                    sidebarSectionHeader("记录")
                    sidebarRow(icon: "tray.full", label: "全部记录", count: store.totalInKind,
                               isActive: store.kind == .all && store.favoriteLevel == nil
                                   && !store.favoriteOnly && !store.recentOnly
                                   && store.tagGroupID == nil && store.tagFilterID == nil) {
                        store.kind = .all; store.favoriteLevel = nil; store.favoriteOnly = false
                        store.recentOnly = false; store.tagGroupID = nil; store.tagFilterID = nil
                    }
                    sidebarRow(icon: "clock", label: "最近使用",
                               isActive: store.recentOnly) {
                        store.recentOnly = true
                        store.favoriteLevel = nil; store.favoriteOnly = false
                        store.tagGroupID = nil; store.tagFilterID = nil
                    }

                    // 收藏等级
                    sidebarSectionHeader("收藏")
                    sidebarRow(icon: "star", label: "全部收藏",
                               isActive: store.favoriteOnly && store.favoriteLevel == nil) {
                        store.favoriteOnly = true; store.favoriteLevel = nil
                        store.recentOnly = false
                    }
                    sidebarRow(icon: "star", label: "普通", indent: 1,
                               isActive: store.favoriteLevel == 1) {
                        store.favoriteOnly = true; store.favoriteLevel = 1; store.recentOnly = false
                    }
                    sidebarRow(icon: "star.fill", label: "重要", indent: 1,
                               isActive: store.favoriteLevel == 2) {
                        store.favoriteOnly = true; store.favoriteLevel = 2; store.recentOnly = false
                    }
                    sidebarRow(icon: "pin.fill", label: "置顶", indent: 1,
                               isActive: store.favoriteLevel == 3) {
                        store.favoriteOnly = true; store.favoriteLevel = 3; store.recentOnly = false
                    }

                    // 已存项目
                    sidebarSectionHeader("项目")
                    sidebarRow(icon: "bookmark", label: "已存项目",
                               isActive: store.kind == .note) {
                        store.kind = .note; store.favoriteLevel = nil; store.favoriteOnly = false
                        store.recentOnly = false; store.tagGroupID = nil; store.tagFilterID = nil
                    }

                    // 标签分组
                    sidebarSectionHeader("标签分组")
                    if tagStore.groups.isEmpty && tagStore.tags.isEmpty {
                        Text("还没有标签")
                            .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14).padding(.vertical, 4)
                    } else {
                        ForEach(tagStore.groups) { group in
                            sidebarTagGroup(group)
                        }
                        // 未分组标签
                        let ungrouped = tagStore.tags.filter { $0.groupID == nil }
                        if !ungrouped.isEmpty {
                            ForEach(ungrouped) { tag in
                                sidebarTagRow(tag, indent: 0)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Divider().opacity(0.3)
            // 分类管理
            Button {
                NotificationCenter.default.post(name: TagStore.manageRequestedNotification, object: "floating")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                    Text("分类管理")
                        .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        // v287：侧栏磨砂表面（glass-unify 交付的第五类表面：sidebarFill + sidebarFrost，不叠模糊）
        .surface(.sidebar)
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.scaledSystem(size: 9, weight: .semibold, scale: appearance.fontScale))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func sidebarRow(icon: String, label: String, count: Int? = nil,
                            indent: Int = 0, isActive: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.scaledSystem(size: 10, scale: appearance.fontScale))
                    .frame(width: 14)
                Text(label)
                    .font(.scaledSystem(size: 11, weight: isActive ? .semibold : .regular, scale: appearance.fontScale))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let count {
                    Text("\(count)")
                        .font(.scaledSystem(size: 9, scale: appearance.fontScale).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(isActive ? appearance.accent : Color.primary.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.leading, CGFloat(indent) * 12)
            .frame(height: 24)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(appearance.accent.opacity(0.12))
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sidebarTagGroup(_ group: TagGroup) -> some View {
        let isExpanded = expandedTagGroups.contains(group.id)
        let groupTags = tagStore.tags.filter { $0.groupID == group.id }
        let isGroupActive = store.tagGroupID == group.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expandedTagGroups.remove(group.id) } else { expandedTagGroups.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.scaledSystem(size: 8, scale: appearance.fontScale))
                        .frame(width: 10)
                    Circle()
                        .fill(floatingClipColor(from: group.colorHex))
                        .frame(width: 7, height: 7)
                    Text(group.name)
                        .font(.scaledSystem(size: 11, weight: isGroupActive ? .semibold : .regular, scale: appearance.fontScale))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(groupTags.count)")
                        .font(.scaledSystem(size: 9, scale: appearance.fontScale).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(isGroupActive ? appearance.accent : Color.primary.opacity(0.75))
                .padding(.horizontal, 14)
                .frame(height: 24)
                .background {
                    if isGroupActive {
                        RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                            .fill(appearance.accent.opacity(0.12))
                            .padding(.horizontal, 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                store.tagGroupID = group.id; store.tagFilterID = nil
            })
            if isExpanded {
                ForEach(groupTags) { tag in
                    sidebarTagRow(tag, indent: 1)
                }
            }
        }
    }

    private func sidebarTagRow(_ tag: Tag, indent: Int) -> some View {
        SidebarTagRow(tag: tag, indent: indent,
                      isActive: store.tagFilterID == tag.id,
                      appearance: appearance) {
            store.tagGroupID = tag.groupID
            store.tagFilterID = (store.tagFilterID == tag.id) ? nil : tag.id
        }
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
        GeometryReader { geo in
        let columns = min(store.cardSize.columns, max(1, Int((geo.size.width - 14) / 150)))
        let columnWidth = (geo.size.width - 24 - CGFloat(columns - 1) * 10) / CGFloat(columns)
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(0..<columns), id: \.self) { column in
                        LazyVStack(spacing: 10) {
                            ForEach(columnItems(column, of: columns), id: \.element.id) { pair in
                                card(pair.element, index: pair.offset)
                            }
                        }
                        .frame(width: columnWidth, alignment: .top)
                    }
                }
                .padding(12)
            }
            .onChange(of: store.scrollRequest) { _ in
                guard let id = store.selectedItemID else { return }
                DispatchQueue.main.async {
                    withAnimation(PanelMotion.animation(.easeOut(duration: 0.12))) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        }
    }

    /// 某一列要显示的条目（按下标取模分列，保持原有卡片瀑布顺序）
    private func columnItems(_ column: Int,
                             of columns: Int) -> [(offset: Int, element: ClipboardItem)] {
        let items = displayedItems
        return stride(from: column, to: items.count, by: columns).map { index in
            (offset: index, element: items[index])
        }
    }

    private func card(_ item: ClipboardItem, index: Int) -> some View {
        FloatingClipCard(item: item,
                         size: store.cardSize,
                         isSelected: index == store.selectedIndex,
                         personalization: personalization)
            .onTapGesture(count: 2) { store.paste(item) }
            .onTapGesture { store.select(item) }
            .onHover { hovering in
                if hovering && store.hoverPreviewEnabled {
                    store.select(item, hovering: true)
                } else if !hovering {
                    store.clearHover()
                }
            }
            .contextMenu {
                if !isSettingsPreview {
                    ClipboardRowMenuContent(item: item, managementSource: "floating",
                                            onPreview: { store.select(item) }, onPaste: { store.paste(item) })
                }
            }
            .focusable()
            .accessibilityLabel(item.displayTitle)
            .accessibilityAddTraits(index == store.selectedIndex ? .isSelected : [])
            .onDrag { dragProvider(for: item) }
            .onAppear { store.loadMoreIfNeeded(item) }
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
                            .onHover { hovering in
                if hovering && store.hoverPreviewEnabled {
                    store.select(item, hovering: true)
                } else if !hovering {
                    store.clearHover()
                }
            }
                            .contextMenu {
                                if !isSettingsPreview {
                                    ClipboardRowMenuContent(item: item, managementSource: "floating",
                                                            onPreview: { store.select(item) }, onPaste: { store.paste(item) })
                                }
                            }
                            .focusable()
                            .accessibilityLabel(item.displayTitle)
                            .onDrag { dragProvider(for: item) }
                            .onAppear { store.loadMoreIfNeeded(item) }
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: store.scrollRequest) { _ in
                guard let id = store.selectedItemID else { return }
                DispatchQueue.main.async {
                    withAnimation(PanelMotion.animation(.easeOut(duration: 0.12))) {
                        proxy.scrollTo(id, anchor: .center)
                    }
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
        // v287：三个筛选维度正交，状态栏按生效维度拼装
        var parts: [String] = [store.kind == .all ? "全部" : store.kind.label]
        if store.recentOnly { parts.append("最近24小时") }
        if let level = store.favoriteLevel {
            parts.append(FavoriteLevel(rawValue: level)?.title ?? "收藏")
        } else if store.favoriteOnly {
            parts.append("收藏")
        }
        if store.tagGroupID != nil { parts.append("分组") }
        if let tagID = store.tagFilterID {
            parts.append(TagStore.shared.tags.first { $0.id == tagID }?.name ?? "标签")
        }
        let searchText = store.loadedSearch.isEmpty ? "" : " · 「\(store.loadedSearch)」"
        return "\(parts.joined(separator: " · "))\(searchText) · \(store.totalInKind) 条"
    }

    // MARK: 背景

    /// 展开窗**唯一**主玻璃面（2026-11-23 需求 B 二：「只用一种主玻璃背景，
    /// 不能嵌套多层不同玻璃」）。
    ///
    /// 全窗就这一层 `GlassSurface`（真玻璃/毛玻璃 → 通透度底衬 → 磨砂霜感）；
    /// 窗口侧 `applyOfficialChrome(glassBacking: false)` 明确不再铺
    /// `installUnifiedGlassBackground` 的第二层玻璃底。其余区域一律**不叠模糊**：
    ///   · 卡片 / 列表行 → `.surface(.card)`（实色 cardFill + 发丝边，无采样）
    ///   · 底栏         → `windowSurface` 实色（见 footerBackground）
    ///   · 右侧预览栏   → `readingBase` 不透明阅读底 + `insetFill` 暗度
    /// 新增区域请沿用这三类，不要再引一层玻璃——两层采样既掉帧又会糊内容。
    private var panelBackground: some View {
        GlassSurface(cornerRadius: appearance.cornerRadius,
                     tint: Color(NSColor.windowBackgroundColor).opacity(0.72))
    }

    private var footerBackground: some View {
        // 2026-11-23（需求 B：工具条走 floatingGlass 口径）：底栏是嵌在窗内的
        // 控制条（不是浮层），不能再叠一层 glassPlate 采样——按主面板底部工具条
        // 同一口径（审计 A-1）：只铺一层通透度底衬 windowSurface（Midnight 走
        // 同源底色），与窗口玻璃面同配方，两个玻璃滑块继续生效。
        appearance.windowSurface
    }

    // MARK: 拖拽

    /// 拖出去的内容：文本给纯文本 + RTF，图片给临时 PNG 的 file URL，文件给 file URL
    /// v287：额外注册 dedupeKey 自定义表示，供侧栏拖放打标签用
    private func dragProvider(for item: ClipboardItem) -> NSItemProvider {
        if isSettingsPreview { return NSItemProvider() }
        let provider: NSItemProvider
        switch item.type {
        case .image:
            if let path = item.imagePath {
                let url = ClipboardFileStore.url(forRelativePath: path)
                if NSItemProvider(contentsOf: url) != nil {
                    provider = NSItemProvider(contentsOf: url)!
                } else {
                    provider = NSItemProvider(object: item.displayTitle as NSString)
                }
            } else {
                provider = NSItemProvider(object: item.displayTitle as NSString)
            }
        case .file:
            let first = (item.content ?? "").split(separator: "\n").first.map(String.init) ?? ""
            if !first.isEmpty {
                provider = NSItemProvider(contentsOf: URL(fileURLWithPath: first)) ?? NSItemProvider()
            } else {
                provider = NSItemProvider(object: item.displayTitle as NSString)
            }
        case .richtext:
            let p = NSItemProvider(object: ClipboardManager.shared.fullText(for: item) as NSString)
            if let data = item.richTextPath.flatMap({ ClipboardFileStore.read($0) }) {
                p.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier,
                                                    visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            provider = p
        case .text, .url:
            provider = NSItemProvider(object: ClipboardManager.shared.fullText(for: item) as NSString)
        }
        // v287：注册 dedupeKey（应用内拖放识别用，不影响外部拖出）
        let key = item.dedupeKey
        provider.registerDataRepresentation(forTypeIdentifier: "com.sxyq.frsetnext.dedupekey",
                                            visibility: .ownProcess) { completion in
            completion(key.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

/// 选择尚未完成时保留当前渲染结果；相同会话不重复解析正文或解码图片。
private struct FloatingClipPreview: View, Equatable {
    let model: PreviewPopoverContentModel

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model.sessionID == rhs.model.sessionID
    }

    var body: some View { PreviewPopoverContentView(model: model) }
}

// MARK: - 网格卡片

private struct FloatingClipCard: View {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.settingsPreviewImage) private var previewImage
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
        // 2026-11-23（需求 B 四：「点击/悬停前后底色不能跳变，hover 态用 stateFill
        // 而非换材质」）：交互反馈统一走 `stateFill`——悬停/选中都是**垫在
        // 卡面填充之上**的一层 wash，不换材质、不动 .surface(.card) 的 cardFill，
        // 所以指针移入/移出、点击选中前后底色稳定，只有叠加的反馈在变。
        // 顺序保证 wash 在 cardFill 之上、文字之下（放在 .surface(.card) 之前）。
        .stateFill(hovered: isHovering, selected: isSelected, accent: appearance.accent,
                   radius: Theme.Radius.card)
        // 2026-11-23（需求 B：内容卡统一 card 表面）：底面/发丝边/裁切走
        // .surface(.card)（= glassCard：cardFill + cardStroke + 圆角一次到位，
        // 与全 App 内容卡同一实现）；选中描边保留为覆盖层（功能语义不动）。
        .surface(.card)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(appearance.accent.opacity(0.75), lineWidth: 1.5)
            }
        }
        .onHover { isHovering = $0 }
        .help(item.displayTitle)
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
            // v282：浮动窗卡片最大也就 ~200pt 宽，按 320px 降采样解码即可，
            // 没必要把整张截图读进来（同 ClipboardSectionView 的行卡）。
            if let image = isSettingsPreview ? previewImage :
                ClipboardImageStorage.thumbnail(relativePath: item.imagePath ?? item.thumbnailPath,
                                                maxPixel: 320) {
                GeometryReader { geo in
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                    .frame(height: size.minHeight - 34)
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
                Image(nsImage: isSettingsPreview ? NSWorkspace.shared.icon(for: .pdf) : NSWorkspace.shared.icon(forFile: firstFilePath))
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
            }
            if !item.tagIDs.isEmpty { ClipboardTagBadges(item: item) }
            if item.isNote { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("已存") }
            Spacer(minLength: 2)
            if !isSettingsPreview { ClipboardFavoriteButton(item: item) }
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
    @Environment(\.isSettingsPreview) private var isSettingsPreview
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
                                   // 2026-11-23：缩略图圆角 5 → Theme.Radius.control
                                   // （与 ClipboardSectionView 同类调用的 8pt 对齐）
                                   corner: Theme.Radius.control,
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
            if !item.tagIDs.isEmpty { ClipboardTagBadges(item: item) }
            if item.isNote { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("已存") }
            if !isSettingsPreview { ClipboardFavoriteButton(item: item) }
            if personalization.showSourceBadge, let app = item.sourceApp, !app.isEmpty,
               let icon = ClipboardAppIconCache.icon(forAppName: app) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 13, height: 13)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // 2026-11-23（需求 B 四）：交互反馈统一走 `stateFill`（悬停 / 选中），
        // 不再各写透明度。悬停/选中都是垫在行底之上的一层 wash——不换材质，
        // 指针移入/移出、点击选中前后行底色稳定，只有叠加的反馈在变。
        .stateFill(hovered: isHovering, selected: isSelected, accent: appearance.accent,
                   radius: Theme.Radius.chip)
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

/// v287 三栏工作台：侧栏与卡片区之间的可拖分隔条
private struct SplitSidebarDivider: View {
    @Binding var width: CGFloat
    @Stored private var isHovering = false

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(Color.primary.opacity(isHovering ? 0.4 : 0.18))
                    .frame(width: 1)
            }
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        width = min(280, max(140, width + value.translation.width))
                    }
                    .onEnded { _ in FloatingClipPrefs.sidebarWidth = width }
            )
            .help("拖动调整侧栏宽度")
    }
}

// MARK: - v287 三栏工作台：侧栏标签行（支持拖放打标签）

private struct SidebarTagRow: View {
    let tag: Tag
    let indent: Int
    let isActive: Bool
    let appearance: ThemeAppearance
    let action: () -> Void
    @Stored private var isDropTarget = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .font(.scaledSystem(size: 9, scale: appearance.fontScale))
                    .frame(width: 14)
                Text(tag.name)
                    .font(.scaledSystem(size: 10, weight: isActive ? .semibold : .regular, scale: appearance.fontScale))
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .foregroundStyle(isActive ? appearance.accent : Color.primary.opacity(0.65))
            .padding(.horizontal, 14)
            .padding(.leading, CGFloat(indent) * 12)
            .frame(height: 22)
            .background {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(appearance.accent.opacity(0.2))
                        .padding(.horizontal, 6)
                } else if isActive {
                    RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                        .fill(appearance.accent.opacity(0.12))
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
            for provider in providers {
                // 优先读 dedupeKey 自定义表示（内部拖放）
                _ = provider.loadDataRepresentation(forTypeIdentifier: "com.sxyq.frsetnext.dedupekey") { data, _ in
                    guard let data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return }
                    DispatchQueue.main.async {
                        TagStore.shared.assign(tagID: tag.id, toDedupeKey: key)
                        NotificationCenter.default.post(name: TagStore.didChangeNotification, object: nil,
                                                        userInfo: ["keys": [key]])
                    }
                }
            }
            return true
        }
    }
}
