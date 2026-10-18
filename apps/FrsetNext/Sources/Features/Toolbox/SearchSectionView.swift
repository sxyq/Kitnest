import SwiftUI
import AppKit
import Combine
import WebKit

// MARK: - 全局搜索区段（id "search", priority 5，排在主面板最前）
//
// v50（2026-10-18 用户需求三连）：
//   ① 网页预览不再直接加载必应/谷歌整页（大页面只能看到局部区域）——改为
//      「搜索结果列表」：离屏 WKWebView 抓取搜索页 + JS 提取结果（标题/链接/摘要），
//      过滤掉原网页的导航/广告等杂物；点击某条结果才在预览 WebView 里打开该页面。
//      实测：Bing ✓ 10 条、DuckDuckGo ✓ 10 条；Google/百度有安全验证墙（Google 动态
//      渲染 DOM、百度出"安全验证"页）→ 显示提示 + 一键浏览器打开。
//   ② Everything 接入确认：本地文件检索 = 系统自带 Spotlight 索引 `mdfind`
//      （Windows 版 Everything 是 NTFS 专属，macOS 官方对应物即 mdfind，毫秒级全盘
//      文件名搜索，实测 0.15s）。本轮补**类型筛选**：全部/文稿/图片/影音/压缩/文件夹。
//   ③ 输入关键词后由用户自选分类：搜索框下新增分类 chips（全部/网页/剪贴板/文件/工具），
//      单选聚焦某类；每类内再提供二级筛选（网页=引擎、文件=类型、剪贴板=条目类型）。
//   分类显隐（眼睛）与设置页开关沿用 v47 键位，仅在「全部」视图中生效。

/// 「打开并搜索」全局热键（specs/19 openAndSearch）的聚焦接缝：
/// App 层唤起主面板后发出该通知，本区段收到后把搜索框设为第一响应者。
public extension Notification.Name {
    static let frsetFocusPanelSearch = Notification.Name("frset.focusPanelSearch")
}

public struct SearchResultItem: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: String          // SF Symbol 名称
    public let action: () -> Void

    public init(id: String = UUID().uuidString,
                title: String,
                subtitle: String? = nil,
                icon: String = "magnifyingglass",
                action: @escaping () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.icon = icon; self.action = action
    }
}

public enum SearchHookRegistry {
    private static let lock = NSLock()
    private static var sources: [(String) async -> [SearchResultItem]] = []

    /// 注册一个检索源（返回该源中匹配关键词的结果）
    public static func register(_ handler: @escaping (String) async -> [SearchResultItem]) {
        lock.lock(); defer { lock.unlock() }
        sources.append(handler)
    }

    /// 并发汇总所有检索源的结果（任一源抛错则跳过，不影响整体）
    public static func search(_ query: String) async -> [SearchResultItem] {
        let snapshot: [(String) async -> [SearchResultItem]] = {
            lock.lock(); defer { lock.unlock() }
            return sources
        }()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await withTaskGroup(of: [SearchResultItem].self) { group in
            for source in snapshot {
                group.addTask { await source(trimmed) }
            }
            var collected: [SearchResultItem] = []
            for await items in group { collected.append(contentsOf: items) }
            return collected
        }
    }
}

// MARK: 内置默认数据源：工具名检索

public enum ToolboxSearchSource {
    public static func register() {
        SearchHookRegistry.register { query in
            // 原版占位符「搜索或输入 / 使用工具」：输入 / 即进入工具模式——
            // 裸 "/" 列出全部启用工具，"/关键词" 按关键词过滤（2026-10-18 对齐）
            if query == "/" {
                return ToolRegistry.enabledTools.map { tool in
                    Self.item(for: tool)
                }
            }
            let keyword: String
            if query.hasPrefix("/") {
                keyword = String(query.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
            } else {
                keyword = query.lowercased()
            }
            return ToolRegistry.enabledTools.compactMap { tool in
                let haystack = [tool.name, tool.identifier, tool.keyword, tool.toolDescription, tool.category.title].joined(separator: " ").lowercased()
                guard haystack.contains(keyword) else { return nil }
                return Self.item(for: tool)
            }
        }
    }

    private static func item(for tool: ToolDescriptor) -> SearchResultItem {
        SearchResultItem(id: "tool-\(tool.identifier)",
                         title: tool.name,
                         subtitle: "工具箱 · \(tool.category.title)",
                         icon: tool.systemImage) {
            ToolboxUIState.shared.open(tool.identifier)
        }
    }
}

// MARK: 本地文件检索（macOS 版 Everything）

/// Everything（Windows）的 macOS 对应物就是系统自带的 Spotlight 索引：
/// `mdfind` 毫秒级返回全盘文件名匹配（无需装任何第三方软件）。
enum FileSearchSource {

    /// v50 文件类型筛选（对应 mdfind 的 ContentTypeTree 谓词）
    enum Kind: String, CaseIterable, Identifiable {
        case all, document, image, media, archive, folder
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .document: return "文稿"
            case .image: return "图片"
            case .media: return "影音"
            case .archive: return "压缩"
            case .folder: return "文件夹"
            }
        }
        /// 追加到 mdfind 查询的类型谓词（nil = 不过滤）
        var predicate: String? {
            switch self {
            case .all: return nil
            case .document: return "(kMDItemContentTypeTree == \"public.content\"cd || kMDItemContentTypeTree == \"public.document\"cd)"
            case .image: return "kMDItemContentTypeTree == \"public.image\"cd"
            case .media: return "(kMDItemContentTypeTree == \"public.movie\"cd || kMDItemContentTypeTree == \"public.audio\"cd)"
            case .archive: return "(kMDItemContentTypeTree == \"public.archive\"cd || kMDItemContentTypeTree == \"public.zip-archive\"cd)"
            case .folder: return "kMDItemContentTypeTree == \"public.folder\"cd"
            }
        }
    }

    /// 全盘文件名模糊匹配（大小写/变音不敏感），返回最多 limit 条文件 URL
    static func search(_ query: String, limit: Int = 8, kind: Kind = .all) -> [URL] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var qs = "kMDItemFSName == \"*\(escaped)*\"cd"
        if let predicate = kind.predicate { qs += " && \(predicate)" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = [qs]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n")
            .prefix(limit)
            .compactMap { URL(fileURLWithPath: String($0)) }
    }
}

// MARK: - 网页搜索结果抓取（离屏 WKWebView + 引擎专用 JS 提取）

/// 一条网页搜索结果（已过滤掉搜索页自身的导航/广告等杂物）
struct WebSearchResult: Identifiable, Equatable {
    let id: UUID
    let title: String
    let url: URL
    let snippet: String

    var host: String { url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString }
}

/// 离屏抓取器：单个复用 WKWebView（nonPersistent），加载引擎搜索页后注入 JS
/// 提取结果列表。URLSession 直抓会被反爬拦（DDG 202 挑战页 / Bing·百度 302），
/// WKWebView 是真实 WebKit 栈，实测 Bing/DDG 均返回完整结果。
@MainActor
final class WebResultScraper: NSObject, WKNavigationDelegate {

    static let shared = WebResultScraper()

    private var webView: WKWebView?
    /// didFinish 续体（单飞：同一时间只处理一次加载）
    private var navContinuation: CheckedContinuation<Void, Never>?
    private var navTimedOut = false

    /// 内嵌结果列表支持的引擎（实测可稳定提取）；其余引擎直接回落浏览器打开
    static func supportsResultList(_ engine: SearchEngine) -> Bool {
        ["bing", "duckduckgo", "google"].contains(engine.id)
    }

    /// 搜索页 URL（DDG 用无 JS 的 html 端点；其余按引擎模板）
    static func searchURL(for engine: SearchEngine, query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch engine.id {
        case "duckduckgo": return URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)")
        case "google":     return URL(string: "https://www.google.com/search?q=\(encoded)&num=10&pws=0")
        default:           return SearchServiceManager.searchURL(for: engine, query: query)
        }
    }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // 抓取不留痕迹
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        wv.navigationDelegate = self
        webView = wv
        return wv
    }

    /// 抓取某引擎的结果列表（失败/为空返回 []，由 UI 显示回落提示）
    func fetchResults(engine: SearchEngine, query: String) async -> [WebSearchResult] {
        guard let url = Self.searchURL(for: engine, query: query) else { return [] }
        let wv = ensureWebView()

        // 等待 didFinish（8s 超时兜底）
        navTimedOut = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.navContinuation = cont
            wv.load(URLRequest(url: url, timeoutInterval: 15))
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.navContinuation != nil else { return }
                self.navTimedOut = true
                self.navContinuation?.resume()
                self.navContinuation = nil
            }
        }
        guard !navTimedOut else { return [] }

        // JS 渲染余量（百度/Google 动态部分；DDG/Bing 静态页开销极小）
        try? await Task.sleep(nanoseconds: 700_000_000)

        guard let json = try? await wv.evaluateJavaScript(Self.extractionScript) as? String,
              let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var results: [WebSearchResult] = []
        for row in rows {
            guard let title = row["t"] as? String, !title.isEmpty,
                  let rawURL = row["u"] as? String,
                  let resolved = Self.resolveURL(rawURL) else { continue }
            let snippet = (row["s"] as? String) ?? ""
            results.append(WebSearchResult(id: UUID(), title: title, url: resolved,
                                           snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines)))
            if results.count >= 10 { break }
        }
        return results
    }

    /// 引擎通用提取脚本（探测当前页是哪家，用对应选择器；一次注入全兼容）
    private static let extractionScript = """
    (() => {
      const out = [];
      const href = location.href;
      let q, snipSel, scope;
      if (href.includes('duckduckgo.com')) { q = '.result__a'; snipSel = '.result__snippet'; }
      else if (href.includes('baidu.com')) { q = '#content_left h3 a'; snipSel = '.c-abstract, [class*=content-right]'; }
      else if (href.includes('google.')) { q = '#search a h3, #rso a h3'; snipSel = 'div[data-sncf], .VwiC3b'; }
      else { q = 'li.b_algo h2 a'; snipSel = '.b_caption p'; }
      document.querySelectorAll(q).forEach(h => {
        const a = h.tagName === 'A' ? h : h.closest('a');
        if (!a || !a.href || a.href.startsWith('javascript')) return;
        const li = a.closest('.result, .b_algo, .c-container') || a.parentElement;
        const snip = li ? li.querySelector(snipSel) : null;
        out.push({t: (a.innerText||'').slice(0, 90), u: a.href, s: snip ? (snip.innerText||'').slice(0, 160) : (li ? (li.innerText||'').slice(0, 130) : '')});
      });
      return JSON.stringify(out.slice(0, 12));
    })()
    """

    /// 引擎跳转链接还原：DDG 的 /l/?uddg=、Bing 的 /ck/a?u=base64
    static func resolveURL(_ raw: String) -> URL? {
        if raw.contains("duckduckgo.com/l/"), let comps = URLComponents(string: raw),
           let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: target)
        }
        if raw.contains("bing.com/ck/"), let comps = URLComponents(string: raw),
           var b64 = comps.queryItems?.first(where: { $0.name == "u" })?.value {
            if b64.hasPrefix("a1") { b64 = String(b64.dropFirst(2)) }
            b64 = b64.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            if let data = Data(base64Encoded: b64),
               let s = String(data: data, encoding: .utf8),
               let url = URL(string: s) { return url }
        }
        return URL(string: raw)
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let cont = self.navContinuation else { return }
            self.navContinuation = nil
            cont.resume()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            guard let cont = self.navContinuation else { return }
            self.navContinuation = nil
            cont.resume()
        }
    }
}

// MARK: - 搜索分类（用户自选：输入关键词后点击聚焦某一类）

enum SearchCategory: String, CaseIterable, Identifiable {
    case all, web, clipboard, files, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .web: return "网页"
        case .clipboard: return "剪贴板"
        case .files: return "文件"
        case .tools: return "工具"
        }
    }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .web: return "globe"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "folder"
        case .tools: return "hammer"
        }
    }
}

// MARK: UI

public struct SearchSectionView: View {
    @Stored private var query: String = ""
    @Stored private var toolResults: [SearchResultItem] = []
    @Stored private var fileResults: [URL] = []
    @Stored private var isSearching = false
    @Stored private var generation = 0
    @Stored private var hasSearched = false
    /// 选中的分类（v50：用户自选聚焦；默认"全部"同 v47 堆叠视图）
    @Stored private var selectedCategory: SearchCategory = .all
    /// 文件类型筛选（用户自选）
    @Stored private var fileKind: FileSearchSource.Kind = .all
    /// 剪贴板条目类型筛选（用户自选）
    @Stored private var clipboardKind: ClipboardFilterKind = .all
    /// 内嵌预览用的关键词（防抖提交后的值；输入过程中不刷网页）
    @Stored private var previewQuery: String = ""
    /// 预览所选引擎（nil = 默认引擎）
    @Stored private var previewEngineID: String?
    /// v50 网页结果列表（防抖提交后由抓取器填充）
    @Stored private var webResults: [WebSearchResult] = []
    @Stored private var webFetchFailed = false
    /// v50 点击结果行后内嵌预览的文章页 URL（nil = 显示结果列表）
    @Stored private var previewArticleURL: URL?
    /// 抓取中的引擎 id（防并发显示）
    @Stored private var fetchingEngineID: String?
    /// 搜索框焦点（「打开并搜索」热键经通知程序化聚焦）
    @FocusState private var searchFieldFocused: Bool

    // 分类开关（分类头部眼睛按钮与设置页共用同一批键）
    @AppStorage(Preferences.Keys.searchCategoryWeb) private var showWeb = true
    @AppStorage(Preferences.Keys.searchCategoryClipboard) private var showClipboard = true
    @AppStorage(Preferences.Keys.searchCategoryFiles) private var showFiles = true

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField

            if !trimmedQuery.isEmpty {
                categoryChips
                categoryList
            } else {
                // 原版建议位留白（2026-10-18 实测）：搜索框底 96pt → 日历卡顶 220pt，
                // 中间 124pt 空白留给输入建议。此前我们日历紧跟搜索框（差 124pt），
                // 首页节奏与原版明显不同。留白随输入出现而收起（结果列表接管该区域）。
                Color.clear.frame(height: 112)
            }
        }
        .onChange(of: query) { _ in scheduleSearch() }
        // v50：文件类型筛选变化 → 重跑文件检索（仅关键词非空时）
        .onChange(of: fileKind) { _ in
            guard !trimmedQuery.isEmpty else { return }
            let kind = fileKind
            let text = trimmedQuery
            Task {
                let files: [URL] = await Task.detached(priority: .utility) {
                    FileSearchSource.search(text, kind: kind)
                }.value
                fileResults = files
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .frsetFocusPanelSearch)) { _ in
            // 面板可能刚被 show()，稍等一拍让 TextField 挂到窗口后再聚焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                searchFieldFocused = true
            }
        }
    }

    // MARK: 搜索框

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索或输入 / 使用工具", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFieldFocused)
                // 原版行为：回车 = 用搜索栏当前引擎打开网页搜索（引擎卡片上的 ↵ 标记）
                .onSubmit {
                    if let first = SearchServiceManager.shared.activeBarEngines.first {
                        performWebSearch(first)
                    }
                }
            if !query.isEmpty {
                Button {
                    clearInput()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBackground))
    }

    // MARK: 分类 chips（v50：用户自选聚焦类别）

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SearchCategory.allCases) { category in
                    // "全部"永远可选；单类仅在启用（或就是当前选中）时可选
                    let enabled = category == .all
                        || (category == .web && showWeb)
                        || (category == .clipboard && showClipboard)
                        || (category == .files && showFiles)
                        || category == .tools
                    Button {
                        selectedCategory = category
                        // 切回网页类时若列表为空且未抓取过，重新触发防抖抓取
                        if category == .web, webResults.isEmpty, !previewQuery.isEmpty {
                            fetchingEngineID = previewEngine?.id
                            Task { await fetchWebResults() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.icon).font(.system(size: 9.5, weight: .semibold))
                            Text(category.title).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(selectedCategory == category
                                           ? Color.accentColor.opacity(0.16)
                                           : Theme.cardBackground)
                        )
                        .foregroundStyle(selectedCategory == category ? Color.accentColor : Color.secondary)
                        .opacity(enabled ? 1 : 0.35)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }
            }
            .padding(.leading, 2)
        }
    }

    // MARK: 分类列表

    private var categoryList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if isSearching && toolResults.isEmpty && fileResults.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("搜索中…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
                }

                switch selectedCategory {
                case .all:
                    // 全部视图：三类同显（沿用 v47 堆叠 + 眼睛开关）
                    if showWeb { webCategory; if showClipboard || showFiles || !toolResults.isEmpty { categoryDivider } }
                    if showClipboard { clipboardCategory; if showFiles || !toolResults.isEmpty { categoryDivider } }
                    if showFiles { filesCategory; if !toolResults.isEmpty { categoryDivider } }
                    if !toolResults.isEmpty { toolCategory }
                case .web:
                    webCategory
                case .clipboard:
                    clipboardCategory
                case .files:
                    filesCategory
                case .tools:
                    if toolResults.isEmpty {
                        Text("没有匹配的工具（输入 / 查看全部）")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                            .padding(.vertical, 8)
                    } else {
                        toolCategory
                    }
                }

                if nothingFound {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("没有找到与「\(trimmedQuery)」相关的内容")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("网页 / 剪贴板 / 文件分类可在分类行右侧的眼睛按钮或设置中调整显隐。")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                    }
                    .padding(.leading, 4)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private var nothingFound: Bool {
        hasSearched && !isSearching && selectedCategory != .web
            && (toolResults.isEmpty && fileResults.isEmpty && clipboardMatches.isEmpty)
    }

    private var categoryDivider: some View {
        Divider().padding(.vertical, 7)
    }

    /// 分类标题行：图标 + 名 + 计数 + 快速隐藏（眼睛）
    private func categoryHeader(_ title: String, icon: String,
                                isShown: Binding<Bool>, count: Int? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 13)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                isShown.wrappedValue.toggle()
            } label: {
                Image(systemName: isShown.wrappedValue ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(isShown.wrappedValue ? Color.secondary : Color.primary.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help(isShown.wrappedValue ? "隐藏该分类（设置 → 搜索 里也可开关）" : "该分类已隐藏，点击显示")
        }
        .padding(.vertical, 3)
    }

    // MARK: 分类① 网页（结果列表 + 单条内嵌预览）

    private var previewEngine: SearchEngine? {
        guard let id = previewEngineID else {
            return SearchServiceManager.shared.activeBarEngines.first
        }
        return SearchServiceManager.shared.activeBarEngines.first(where: { $0.id == id })
    }

    private var webCategory: some View {
        VStack(alignment: .leading, spacing: 5) {
            if selectedCategory == .all {
                categoryHeader("网页搜索", icon: "globe", isShown: $showWeb)
            }
            engineActionsRow
            webResultArea
        }
    }

    /// 引擎动作行：搜索型引擎 = 切换内嵌结果列表；动作型引擎 = 浏览器直接打开
    private var engineActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SearchServiceManager.shared.activeBarEngines) { engine in
                    Button {
                        if WebResultScraper.supportsResultList(engine) {
                            previewEngineID = engine.id
                            previewArticleURL = nil
                            fetchingEngineID = engine.id
                            Task { await fetchWebResults() }
                        } else {
                            performWebSearch(engine)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: engine.systemImage)
                                .font(.system(size: 10))
                            Text(WebResultScraper.supportsResultList(engine)
                                 ? engine.name
                                 : "\(engine.name) ↗")
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.smallRadius)
                                .fill(previewEngineID == engine.id
                                      ? Color.accentColor.opacity(0.14)
                                      : Theme.cardBackground)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(WebResultScraper.supportsResultList(engine)
                          ? "内嵌预览 \(engine.name) 搜索结果"
                          : "在浏览器中用 \(engine.name) 搜索（该引擎不支持内嵌结果列表）")
                }
            }
            .padding(.leading, 2)
        }
    }

    /// v50 网页区主体：结果列表 ↔ 单条文章预览
    @ViewBuilder private var webResultArea: some View {
        let engine = previewEngine
        let supports = engine.map { WebResultScraper.supportsResultList($0) } ?? false

        if let articleURL = previewArticleURL {
            // 单条结果的内嵌预览（文章页在小窗中可读性远好于搜索页）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        previewArticleURL = nil
                    } label: {
                        Label("结果列表", systemImage: "chevron.left")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("返回搜索结果列表")
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.open(articleURL)
                    } label: {
                        Label("浏览器打开", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("在默认浏览器中打开该页面")
                }
                WebPreviewRepresentable(url: articleURL)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08)))
            }
            .padding(.top, 2)
        } else if !supports {
            // 引擎不支持内嵌结果（Google/百度安全验证墙、ChatGPT/Claude 等动作型引擎）
            VStack(alignment: .leading, spacing: 4) {
                Text("「\(engine?.name ?? "该引擎")」不支持内嵌结果列表")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    if let engine { performWebSearch(engine) }
                } label: {
                    Label("在浏览器中搜索", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
            .padding(.leading, 4)
            .padding(.vertical, 4)
        } else if fetchingEngineID != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("正在获取 \(engine?.name ?? "") 搜索结果…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .padding(.vertical, 10)
        } else if webFetchFailed || (webResults.isEmpty && !previewQuery.isEmpty) {
            VStack(alignment: .leading, spacing: 4) {
                Text("未能获取「\(engine?.name ?? "")」结果（可能被安全验证拦截）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    if let engine { performWebSearch(engine) }
                } label: {
                    Label("在浏览器中搜索", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
            .padding(.leading, 4)
            .padding(.vertical, 4)
        } else if !webResults.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("搜索结果 · \(engine?.name ?? "")")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        if let engine { performWebSearch(engine) }
                    } label: {
                        Label("浏览器打开", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("在默认浏览器打开该搜索结果")
                }
                ForEach(webResults) { result in
                    Button {
                        previewArticleURL = result.url
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                            if !result.snippet.isEmpty {
                                Text(result.snippet)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(result.host)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("点击内嵌预览该页面（⌘点击 = 浏览器打开）")
                    .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                        NSWorkspace.shared.open(result.url)
                    })
                }
            }
            .padding(.top, 2)
        }
    }

    // MARK: 分类② 剪贴板历史

    /// v50 剪贴板条目类型筛选
    enum ClipboardFilterKind: String, CaseIterable, Identifiable {
        case all, text, link, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "全部"
            case .text: return "文本"
            case .link: return "链接"
            case .image: return "图片"
            }
        }
        func matches(_ type: ClipboardItemType) -> Bool {
            switch self {
            case .all: return true
            case .text: return type == .text || type == .richtext || type == .file
            case .link: return type == .url
            case .image: return type == .image
            }
        }
    }

    private var filteredClipboardMatches: [ClipboardItem] {
        let keyword = trimmedQuery.lowercased()
        guard !keyword.isEmpty else { return [] }
        return ClipboardManager.shared.items.filter { item in
            guard clipboardKind.matches(item.type) else { return false }
            let haystack = [item.title, item.subtitle, item.content]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return haystack.contains(keyword)
        }
    }

    private var clipboardMatches: [ClipboardItem] { filteredClipboardMatches }

    /// 二级筛选 chips（文件类型 / 剪贴板类型共用样式）
    private func filterChips<Kind: Identifiable & Equatable>(
        _ kinds: [Kind], selection: Binding<Kind>, title: @escaping (Kind) -> String) -> some View {
        HStack(spacing: 3) {
            ForEach(kinds) { kind in
                Button {
                    selection.wrappedValue = kind
                } label: {
                    Text(title(kind))
                        .font(.system(size: 10, weight: selection.wrappedValue == kind ? .semibold : .regular))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(selection.wrappedValue == kind
                                                   ? Color.accentColor.opacity(0.15)
                                                   : Theme.cardBackground))
                        .foregroundStyle(selection.wrappedValue == kind ? Color.accentColor : Color.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var clipboardCategory: some View {
        let matches = Array(filteredClipboardMatches.prefix(6))
        return VStack(alignment: .leading, spacing: 3) {
            if selectedCategory == .all {
                categoryHeader("剪贴板历史", icon: "doc.on.clipboard",
                               isShown: $showClipboard, count: filteredClipboardMatches.count)
            } else {
                filterChips(ClipboardFilterKind.allCases, selection: $clipboardKind) { $0.title }
            }
            if matches.isEmpty {
                Text("没有匹配的剪贴板条目")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .padding(.bottom, 2)
            } else {
                ForEach(matches) { item in
                    Button {
                        ClipboardManager.shared.copy(item)
                        Toast.show("已复制剪贴板条目", icon: "checkmark.circle.fill")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: clipboardIcon(item.type))
                                .font(.system(size: 11))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title ?? item.content ?? "(空)")
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(item.timestamp.formatted(.relative(presentation: .named)))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("点击复制该条目")
                }
            }
        }
    }

    private func clipboardIcon(_ type: ClipboardItemType) -> String {
        switch type {
        case .text: return "doc.plaintext"
        case .richtext: return "doc.richtext"
        case .image: return "photo"
        case .file: return "doc"
        case .url: return "link"
        }
    }

    // MARK: 分类③ 本地文件

    private var filesCategory: some View {
        VStack(alignment: .leading, spacing: 3) {
            if selectedCategory == .all {
                categoryHeader("本地文件", icon: "folder",
                               isShown: $showFiles, count: fileResults.isEmpty ? nil : fileResults.count)
            } else {
                filterChips(FileSearchSource.Kind.allCases, selection: $fileKind) { $0.title }
            }
            if fileResults.isEmpty {
                Text(hasSearched ? "没有匹配的文件（Spotlight 索引范围）" : "输入文件名搜索全盘文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .padding(.bottom, 2)
            } else {
                ForEach(fileResults, id: \.absoluteString) { url in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .font(.system(size: 11))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("在 Finder 中显示")
                }
            }
        }
    }

    // MARK: 分类④ 工具（"/" 模式与关键词匹配）

    @ViewBuilder private var toolCategory: some View {
        VStack(alignment: .leading, spacing: 3) {
            categoryHeader("工具", icon: "hammer", isShown: .constant(true), count: toolResults.count)
            ForEach(toolResults) { item in
                Button {
                    item.action()
                    if SearchServiceManager.shared.clearSearchInputAfterWebAction {
                        clearInput()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12))
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            if let subtitle = item.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 动作

    /// 去除首尾空白后的关键词（分类显隐、剪贴板匹配、预览 URL 构造共用）
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Web 打开引擎搜索 URL；行为开关 clearSearchInputAfterWebAction 决定是否清空输入框
    private func performWebSearch(_ engine: SearchEngine) {
        let text = trimmedQuery
        guard !text.isEmpty, let url = SearchServiceManager.searchURL(for: engine, query: text) else { return }
        NSWorkspace.shared.open(url)
        if SearchServiceManager.shared.clearSearchInputAfterWebAction {
            clearInput()
        }
    }

    /// 清空输入与结果（打开链接动作后同样按开关生效）
    private func clearInput() {
        query = ""
        toolResults = []
        fileResults = []
        webResults = []
        webFetchFailed = false
        hasSearched = false
        previewQuery = ""
        previewEngineID = nil
        previewArticleURL = nil
        fetchingEngineID = nil
    }

    /// v50 抓取当前引擎的结果列表（后台任务；generation 防串台）
    private func fetchWebResults() {
        guard let engine = previewEngine, !previewQuery.isEmpty else { return }
        let engineID = engine.id
        let text = previewQuery
        let current = generation
        Task {
            let results = await WebResultScraper.shared.fetchResults(engine: engine, query: text)
            guard current == generation else { return }
            webResults = results
            webFetchFailed = results.isEmpty
            fetchingEngineID = nil
        }
    }

    /// 简单防抖（250ms），避免每敲一个字都触发全部检索源
    private func scheduleSearch() {
        generation += 1
        let current = generation
        let text = query
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toolResults = []; fileResults = []; webResults = []
            hasSearched = false; isSearching = false
            previewQuery = ""; previewArticleURL = nil; fetchingEngineID = nil
            return
        }
        isSearching = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard current == generation else { return }
            let items = await SearchHookRegistry.search(text)
            let kind = fileKind
            let files: [URL] = (showFiles || selectedCategory == .files)
                ? await Task.detached(priority: .utility) { FileSearchSource.search(trimmed, kind: kind) }.value
                : []
            guard current == generation else { return }
            await MainActor.run {
                toolResults = items
                fileResults = files
                previewQuery = trimmed          // 预览随防抖提交的词更新（不逐键刷网页）
                hasSearched = true
                isSearching = false
            }
            // v50：防抖提交后立即抓取当前引擎的结果列表（仅搜索型引擎）
            if let engine = previewEngine, WebResultScraper.supportsResultList(engine) {
                fetchingEngineID = engine.id
                fetchWebResults()
            }
        }
    }
}

// MARK: - WKWebView 内嵌预览（集成 WebKit 引擎）

private struct WebPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 预览是临时查看，不留 cookie/缓存/历史
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {
        webView.stopLoading()
    }
}
