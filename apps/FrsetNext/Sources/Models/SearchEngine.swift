import Foundation

// MARK: - 搜索引擎模型与数据中心（specs/18 §2/§4.2）
//
// 原作 SearchServiceManager（classobj 0x100acdaf0）等价实现：
// - 字段语义：builtInEngines / customEngines / engineOrder / _activeBarItems；
// - 内置 11 个引擎 URL 模板逐字对齐原作字面量表（@0x100b4f920-0x100b4fb30）；
// - 自定义引擎与排序/激活集按需落盘 UserDefaults（specs/18 §3.2 推断）。

/// 搜索引擎（内置与自定义同一模型；自定义项 isBuiltIn == false）
public struct SearchEngine: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    /// URL 模板，含 {query} 占位符（Google 翻译额外含 {tl} 目标语言占位符）
    public var urlTemplate: String
    /// SF Symbol 图标名（原作图标资源 ⬜ 未探明，重建用 SF Symbol 近似）
    public var systemImage: String
    public var isBuiltIn: Bool

    public init(id: String, name: String, urlTemplate: String, systemImage: String, isBuiltIn: Bool) {
        self.id = id; self.name = name; self.urlTemplate = urlTemplate
        self.systemImage = systemImage; self.isBuiltIn = isBuiltIn
    }
}

// MARK: 数据中心（原作 SearchServiceManager 等价）

public final class SearchServiceManager: ObservableObject {
    public static let shared = SearchServiceManager()

    // defaults 键（对齐原作键簇 @0x100b4df20 语义；customEngines/engineOrder 按需落盘）
    private enum Keys {
        static let customEngines = "customEngines"
        static let engineOrder = "engineOrder"
        static let activeBarItems = "activeBarItems"
        static let clearSearchInputAfterWebAction = "clearSearchInputAfterWebAction"
    }

    // MARK: 内置 11 引擎（URL 模板照抄 specs/18 §4.2 实证字面量）

    public static let builtInEngines: [SearchEngine] = [
        SearchEngine(id: "google",       name: "Google",       urlTemplate: "https://google.com/search?q={query}",                     systemImage: "magnifyingglass", isBuiltIn: true),
        SearchEngine(id: "chatgpt",      name: "ChatGPT",      urlTemplate: "https://chatgpt.com/?q={query}",                          systemImage: "sparkles", isBuiltIn: true),
        SearchEngine(id: "bing",         name: "Bing",         urlTemplate: "https://www.bing.com/search?q={query}",                   systemImage: "magnifyingglass", isBuiltIn: true),
        SearchEngine(id: "baidu",        name: "百度",          urlTemplate: "https://www.baidu.com/s?wd={query}",                      systemImage: "magnifyingglass", isBuiltIn: true),
        SearchEngine(id: "yandex",       name: "Yandex",       urlTemplate: "https://yandex.com/search/?text={query}",                 systemImage: "magnifyingglass", isBuiltIn: true),
        SearchEngine(id: "claude",       name: "Claude",       urlTemplate: "https://claude.ai/new?q={query}",                         systemImage: "sparkles", isBuiltIn: true),
        SearchEngine(id: "github",       name: "GitHub",       urlTemplate: "https://github.com/search?q={query}",                     systemImage: "chevron.left.forwardslash.chevron.right", isBuiltIn: true),
        SearchEngine(id: "duckduckgo",   name: "DuckDuckGo",   urlTemplate: "https://duckduckgo.com/?q={query}",                       systemImage: "shield.lefthalf.filled", isBuiltIn: true),
        SearchEngine(id: "naver",        name: "Naver",        urlTemplate: "https://search.naver.com/search.naver?query={query}",     systemImage: "magnifyingglass", isBuiltIn: true),
        SearchEngine(id: "yahoo-japan",  name: "Yahoo! Japan", urlTemplate: "https://search.yahoo.co.jp/search?p={query}",             systemImage: "magnifyingglass", isBuiltIn: true),
        SearchEngine(id: "google-translate", name: "Google 翻译", urlTemplate: "https://translate.google.com/?sl=auto&tl={tl}&text={query}&op=translate", systemImage: "character.book.closed", isBuiltIn: true),
    ]

    /// 自定义引擎表单默认 URL 占位（原作 'Search URL Placeholder' 键值）
    public static let customEngineURLPlaceholder = "https://example.com/search?q={query}"

    /// 默认激活集（原作 ⬜ 未探明，specs/18 §4.2 建议以 Google/百度/ChatGPT 起步）
    private static let defaultActiveBarItems = ["google", "baidu", "chatgpt"]

    /// 自定义引擎名称长度上限（原作 "Name Too Long Limit" 校验）
    public static let customEngineNameLimit = 20

    @Published public private(set) var customEngines: [SearchEngine] = []
    /// 全量引擎显示序（内置 + 自定义，按 engineOrder 排列；未入表的排后面保持默认序）
    @Published public private(set) var allEngines: [SearchEngine] = []
    /// 搜索栏激活集（_activeBarItems：出现在搜索栏的引擎 id，保序）
    @Published public private(set) var activeBarItems: [String] = []

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: 派生数据

    /// 搜索栏当前激活的引擎（保序）
    public var activeBarEngines: [SearchEngine] {
        activeBarItems.compactMap { id in allEngines.first { $0.id == id } }
    }

    /// 「搜索或打开链接后清空输入框」行为开关（键 clearSearchInputAfterWebAction；原作默认值未探明，取 true）
    public var clearSearchInputAfterWebAction: Bool {
        get { defaults.object(forKey: Keys.clearSearchInputAfterWebAction) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.clearSearchInputAfterWebAction) }
    }

    // MARK: 搜索动作

    /// 由模板构造可打开的搜索 URL（{query} → URL 编码后的关键词；{tl} → 目标语言码）
    public static func searchURL(for engine: SearchEngine, query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var template = engine.urlTemplate
            .replacingOccurrences(of: "{query}", with: encoded)
        if template.contains("{tl}") {
            let target = Self.translateTargetLanguage
            template = template.replacingOccurrences(of: "{tl}", with: target)
        }
        return URL(string: template)
    }

    /// Google 翻译 {tl} 目标语言（跟随显示语言，简单映射）
    private static var translateTargetLanguage: String {
        switch LanguageManager.shared.resolvedLanguageCode {
        case "zh-Hans", "zh-Hant-HK", "zh-Hant-TW": return "zh-CN"
        case "ja": return "ja"
        case "ko": return "ko"
        default: return "en"
        }
    }

    // MARK: 搜索栏管理

    /// 把引擎添加到搜索栏（操作后调用方自行 Toast「已添加至搜索栏」）
    public func addToSearchBar(engineID: String) {
        guard !activeBarItems.contains(engineID) else { return }
        activeBarItems.append(engineID)
        persistActiveBarItems()
    }

    /// 从搜索栏移除；最后 1 项时阻止（原作 "Search Bar Minimum Alert"）
    /// - Returns: 是否成功移除
    @discardableResult
    public func removeFromSearchBar(engineID: String) -> Bool {
        guard activeBarItems.count > 1 else { return false }
        activeBarItems.removeAll { $0 == engineID }
        persistActiveBarItems()
        return true
    }

    /// 搜索栏内移动（拖拽排序唯一入口；调用方负责落 hasSeenSearchBarOrderingTip 一次性提示）
    ///
    /// - Parameters:
    ///   - fromOffsets: 被拖动项在激活集中的下标集合（拖拽源）
    ///   - toOffset: 目标插入位。**注意语义**：`Array.move(fromOffsets:toOffset:)` 的 toOffset 取
    ///     「移除前」的数组坐标——向下拖需传 `目标下标 + 1` 才落在目标行原位，向上拖直接传目标下标。
    ///     调用方（Settings/SearchSettingsPane）负责这层换算。
    public func moveInSearchBar(fromOffsets: IndexSet, toOffset: Int) {
        activeBarItems.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistActiveBarItems()
    }

    // MARK: 自定义引擎

    public func addCustomEngine(name: String, urlTemplate: String) {
        let engine = SearchEngine(id: "custom-\(UUID().uuidString)",
                                  name: name,
                                  urlTemplate: urlTemplate,
                                  systemImage: "wrench.and.screwdriver",
                                  isBuiltIn: false)
        customEngines.append(engine)
        rebuildOrder()
        persistCustomEngines()
    }

    public func deleteCustomEngine(engineID: String) {
        customEngines.removeAll { $0.id == engineID }
        activeBarItems.removeAll { $0 == engineID }
        persistActiveBarItems()
        rebuildOrder()
        persistCustomEngines()
    }

    /// 更新自定义引擎（行内编辑表单保存；引擎 id 保持不变，落盘键与新增路径一致）
    /// - Returns: 是否命中并更新
    @discardableResult
    public func updateCustomEngine(id: String, name: String, urlTemplate: String) -> Bool {
        guard let index = customEngines.firstIndex(where: { $0.id == id }) else { return false }
        customEngines[index].name = name
        customEngines[index].urlTemplate = urlTemplate
        rebuildOrder()
        persistCustomEngines()
        return true
    }

    /// 从 defaults 重新装载（配置导入后调用，使搜索页立即反映导入结果）
    public func reloadFromDefaults() {
        load()
    }

    // MARK: 排序

    /// 全量引擎列表内移动（设置页引擎区上下移）
    public func moveEngine(engineID: String, up: Bool) {
        guard let idx = allEngines.firstIndex(where: { $0.id == engineID }) else { return }
        let target = up ? idx - 1 : idx + 1
        guard allEngines.indices.contains(target) else { return }
        allEngines.swapAt(idx, target)
        persistEngineOrder()
    }

    // MARK: 重置（原作 "Reset Search Settings"）

    public func resetToDefaults() {
        customEngines = []
        activeBarItems = Self.defaultActiveBarItems
        allEngines = Self.builtInEngines
        defaults.removeObject(forKey: Keys.customEngines)
        defaults.removeObject(forKey: Keys.engineOrder)
        persistActiveBarItems()
    }

    // MARK: 持久化

    private func load() {
        if let data = defaults.data(forKey: Keys.customEngines),
           let decoded = try? JSONDecoder().decode([SearchEngine].self, from: data) {
            customEngines = decoded
        }
        let order = defaults.stringArray(forKey: Keys.engineOrder) ?? []
        let byID = (Self.builtInEngines + customEngines).reduce(into: [String: SearchEngine]()) { $0[$1.id] = $1 }
        // engineOrder 表内的按表序，表外按默认序补齐（防键缺失/引擎增删后的孤儿 id）
        var ordered = order.compactMap { byID[$0] }
        for engine in Self.builtInEngines + customEngines where !ordered.contains(where: { $0.id == engine.id }) {
            ordered.append(engine)
        }
        allEngines = ordered
        activeBarItems = defaults.stringArray(forKey: Keys.activeBarItems) ?? Self.defaultActiveBarItems
        // 激活集清洗：只保留仍存在的引擎；空集回默认（保证"至少一项"不变式）
        activeBarItems.removeAll { id in !ordered.contains(where: { $0.id == id }) }
        if activeBarItems.isEmpty { activeBarItems = Self.defaultActiveBarItems }
    }

    private func rebuildOrder() {
        let byID = (Self.builtInEngines + customEngines).reduce(into: [String: SearchEngine]()) { $0[$1.id] = $1 }
        var ordered = allEngines.compactMap { byID[$0.id] }
        for engine in Self.builtInEngines + customEngines where !ordered.contains(where: { $0.id == engine.id }) {
            ordered.append(engine)
        }
        allEngines = ordered
        defaults.set(allEngines.map(\.id), forKey: Keys.engineOrder)
    }

    private func persistCustomEngines() {
        defaults.set(try? JSONEncoder().encode(customEngines), forKey: Keys.customEngines)
    }

    private func persistActiveBarItems() {
        defaults.set(activeBarItems, forKey: Keys.activeBarItems)
    }

    private func persistEngineOrder() {
        defaults.set(allEngines.map(\.id), forKey: Keys.engineOrder)
    }
}
