import SwiftUI
import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers

// MARK: - 全局搜索区段（id "search", priority 5，排在主面板最前）
//
// v60（2026-10-19 用户需求三连）：
//   ① 文件搜索引擎升级为「FSearch 式」（对标 GitHub 开源项目 cboxdoerfer/fsearch）：
//      mdfind 模糊通配预过滤（字符间插 *，"dcf" → *d*c*f*）+ FuzzyMatcher 本地
//      精排——子序列模糊匹配（不要求连续），乱序输入也能命中；速度保持毫秒级。
//   ② 布局动态化：空查询时不再保留 112pt 原版建议位留白（搜索框下直接接日历）；
//      输入后结果区按内容实际高度**动态向下展开**（PreferenceKey 测量 + 弹簧动画，
//      上限 360pt 保日历卡可见），清空即收回。
//   ③ 结果视觉层级重做：统一行版式（图标容器 + 主标题 + 次级信息），命中字符
//      accent 高亮加粗；文件行用真实文件图标 + 路径次级行；评分第一项带「最佳」
//      徽标——重点突出、层级清晰，不再是「全都一个样」。
//   ④ 工具/剪贴板/网页标题同步接入模糊匹配与命中高亮。
//
// v50（2026-10-18 用户需求三连）：
//   ① 网页预览不再直接加载必应/谷歌整页（大页面只能看到局部区域）——改为
//      「搜索结果列表」：离屏 WKWebView 抓取搜索页 + JS 提取结果（标题/链接/摘要），
//      过滤掉原网页的导航/广告等杂物；点击某条结果才在预览 WebView 里打开该页面。
//      实测：Bing ✓ 10 条、DuckDuckGo ✓ 10 条；Google/百度有安全验证墙（Google 动态
//      渲染 DOM、百度出"安全验证"页）→ 显示提示 + 一键浏览器打开。
//   ② 本地文件检索接入 Spotlight `mdfind`（毫秒级全盘文件名搜索，实测 0.15s）。
//      本轮（v60）升级为 FSearch 式模糊引擎，见 ①。
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
    /// 标题上的模糊命中（FuzzyMatcher 返回的下标区间，用于 accent 高亮；nil = 无高亮）
    public let match: FuzzyMatch?
    public let action: () -> Void

    public init(id: String = UUID().uuidString,
                title: String,
                subtitle: String? = nil,
                icon: String = "magnifyingglass",
                match: FuzzyMatch? = nil,
                action: @escaping () -> Void) {
        self.id = id; self.title = title; self.subtitle = subtitle
        self.icon = icon; self.match = match; self.action = action
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

// MARK: 内置默认数据源：工具名检索（v60 接入 FuzzyMatcher 模糊匹配）

public enum ToolboxSearchSource {
    public static func register() {
        SearchHookRegistry.register { await search($0) }
    }

    static func search(_ query: String) async -> [SearchResultItem] {
        // 工具文字按当前语言读取；搜索源由并发任务组调用，L10n 缓存只在主线程访问。
        if query.hasPrefix("/") {
            let token = String(query.dropFirst())
            return await MainActor.run {
                SlashCommandCatalog.match(token).map { cmd in
                    SearchResultItem(id: "slash-\(cmd.id)", title: cmd.title,
                                     subtitle: cmd.subtitle, icon: cmd.systemImage,
                                     match: nil, action: cmd.run)
                }
            }
        }
        let tools = await MainActor.run {
            ToolRegistry.enabledTools.map {
                ($0.identifier, $0.keyword, $0.name, $0.toolDescription, $0.category.title, $0.systemImage)
            }
        }
        return tools.compactMap { id, keyword, name, description, category, icon in
            let nameMatch = FuzzyMatcher.match(query, in: name)
            let haystack = [name, id, keyword, description, category].joined(separator: " ")
            guard nameMatch != nil || FuzzyMatcher.isMatch(query, in: haystack) else { return nil }
            return SearchResultItem(id: "tool-\(id)", title: name,
                                    subtitle: "工具箱 · \(category)", icon: icon,
                                    match: nameMatch) {
                ToolboxUIState.shared.open(id)
            }
        }
    }

}

// MARK: 本地文件检索（v60：FSearch 式模糊引擎）
//
// 对标 GitHub 开源项目 FSearch（cboxdoerfer/fsearch）的「预过滤 + 精排」两段式：
//   ① 预过滤：mdfind 查询把 query 字符间插通配符（"dcf" → *d*c*f*），一次拿到
//      「子序列超集」候选——Spotlight 索引毫秒级返回，乱序输入也能命中；
//   ② 精排：FuzzyMatcher 对候选逐一评分（文件名命中优先于路径命中），
//      得分降序取 top N，同时给出命中区间供 UI 高亮。
// 与 FSearch 的差异：它启动时自建内存索引；我们复用系统 Spotlight 索引，
// 无需常驻后台进程，速度同为毫秒级。

/// 一条文件搜索结果（含模糊命中信息）
struct FuzzyFileResult: Identifiable {
    let url: URL
    /// 综合得分（文件名命中的 2 倍权重 + 路径命中）
    let score: Int
    /// 文件名上的命中（用于标题高亮）
    let nameMatch: FuzzyMatch?
    /// 父目录上的命中（文件名未命中时兜底，用于路径高亮）
    let pathMatch: FuzzyMatch?

    var id: String { url.absoluteString }
}

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

        func includes(_ url: URL) -> Bool {
            if self == .all { return true }
            guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey]) else { return false }
            if self == .folder { return values.isDirectory == true }
            guard let type = values.contentType else { return false }
            switch self {
            case .document: return type.conforms(to: .content)
            case .image: return type.conforms(to: .image)
            case .media: return type.conforms(to: .movie) || type.conforms(to: .audio)
            case .archive: return type.conforms(to: .archive) || type.conforms(to: .zip)
            case .all, .folder: return true
            }
        }
    }

    /// 送入精排的候选上限（200 条足够覆盖 top 8 的精排精度）
    static let candidateLimit = 200
    /// 单字符查询时 mdfind 命中海量文件：输出读到 512KB 即够 200 条候选，随即终止
    private static let readCapBytes = 512 * 1024

    /// 系统/metadata 垃圾文件，不参与结果（「workbuddy skill」会带出 `.DS_Store`）
    private static let junkNames: Set<String> = [
        ".DS_Store", ".localized", ".gitkeep", ".keep", "Icon\r",
    ]

    static func pathURL(for query: String) -> URL? {
        guard query.hasPrefix("/") || query.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (query as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// FSearch 式模糊搜索（子序列模糊匹配 + 评分排序 + 命中区间）
    static func search(_ query: String, limit: Int = 8, kind: Kind = .all) -> [FuzzyFileResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 2026-11-13：目录末尾 / 不参与匹配；真实路径保留内部空格，关键词去除全部空白。
        let pathURL = Self.pathURL(for: trimmed)
        let key = pathURL?.path ?? trimmed.split(whereSeparator: { $0.isWhitespace }).joined()

        var candidates = runMdfind(fuzzySpotlightPattern(key), kind: kind)
        var seen = Set(candidates.map { $0.standardizedFileURL.path })
        if let pathURL, FileManager.default.fileExists(atPath: pathURL.path), kind.includes(pathURL),
           seen.insert(pathURL.path).inserted {
            candidates.append(pathURL)
        }

        // v264（用户：「搜索的文件也不是全盘」）：
        // mdfind 走的是 Spotlight 库，而 Spotlight **不索引** ~/Library、隐藏目录
        // （.workbuddy / .cursor / .npm…）、.app 包内部、/usr/local。
        // 这几处恰好是开发者文件最密集的地方，所以补一层自建的全盘文件名索引。
        // 索引是 mmap 的，查询只是顺序扫一遍字节池，几十毫秒。
        let extra = FileNameIndex.shared.search(key, limit: candidateLimit, kind: kind)
        for p in extra {
            let url = URL(fileURLWithPath: p)
            if seen.insert(url.standardizedFileURL.path).inserted { candidates.append(url) }
        }

        guard !candidates.isEmpty else { return [] }

        var scored: [FuzzyFileResult] = []
        scored.reserveCapacity(candidates.count)
        for url in candidates {
            if Self.junkNames.contains(url.lastPathComponent) { continue }
            let nameMatch = FuzzyMatcher.match(key, in: url.lastPathComponent)
            // 文件名未命中时对**完整路径**兜底：搜「workbuddy skill」要能命中
            // `~/.workbuddy/skills` 这个目录本身——它的文件名是 skills、
            // 父目录是 .workbuddy，任取一半都凑不齐两个词，只有整条路径凑得齐。
            let pathMatch = (nameMatch == nil)
                ? FuzzyMatcher.match(key, in: url.path)
                : nil
            guard nameMatch != nil || pathMatch != nil else { continue }
            let combined = (nameMatch?.score ?? 0) * 2 + (pathMatch?.score ?? 0)
            scored.append(FuzzyFileResult(url: url, score: combined,
                                          nameMatch: nameMatch, pathMatch: pathMatch))
        }

        // 排序：得分降序 → 同分目录层级浅者优先 → 字母序（稳定可预期）
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let depthA = a.url.pathComponents.count
            let depthB = b.url.pathComponents.count
            if depthA != depthB { return depthA < depthB }
            return a.url.path < b.url.path
        }
        return Array(scored.prefix(limit))
    }

    /// FSearch 式模糊预过滤模式：query 字符间插 Spotlight 通配符
    /// （"dcf" → *d*c*f* = 子序列匹配；单字符/空查询原样返回）
    static func fuzzySpotlightPattern(_ query: String) -> String {
        let chars = Array(query)
        guard chars.count > 1 else { return query }
        return chars.map(String.init).joined(separator: "*")
    }

    /// 执行 mdfind（通配查询 + 类型谓词），输出读满 readCapBytes 或 EOF 即止，
    /// 返回最多 candidateLimit 条文件 URL
    private static func runMdfind(_ pattern: String, kind: Kind) -> [URL] {
        let escaped = pattern
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

        // 容量封顶读取：避免单字符查询命中十万级结果时全量搬运
        let handle = pipe.fileHandleForReading
        var data = Data()
        while data.count < readCapBytes {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n")
            .prefix(candidateLimit)
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
    /// 分类识别色（v63 分级展示：组头图标块/徽标同色，一眼分清结果类别）
    var tint: Color {
        switch self {
        case .all: return .accentColor
        case .web: return .indigo
        case .clipboard: return .teal
        case .files: return .blue
        case .tools: return .purple
        }
    }
}

// MARK: UI

public struct SearchSectionView: View {
    @Environment(\.settingsPreviewPersonalization) private var previewPersonalization
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.settingsPreviewClipboardQuery) private var settingsPreviewClipboardQuery
    @Environment(\.settingsPreviewClipboardSelection) private var settingsPreviewClipboardSelection
    private var theme: ThemeAppearance {
        ThemeAppearance(personalization: previewPersonalization ?? .shared,
                        isMidnight: previewIsMidnight ?? AppearanceState.shared.isMidnight)
    }
    @Stored private var localQuery: String = ""
    private let draftQuery: Binding<String>?
    private var query: String {
        get { draftQuery?.wrappedValue ?? localQuery }
        nonmutating set {
            if let draftQuery { draftQuery.wrappedValue = newValue }
            else { localQuery = newValue }
        }
    }

    /// 命令模式：输入以 `/` 开头（v172）
    private var isSlashMode: Bool {
        query.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }
    private var isLocalPathQuery: Bool { !isSettingsPreview && FileSearchSource.pathURL(for: trimmedQuery) != nil }
    private var showsWebResults: Bool { showWeb && !isLocalPathQuery }
    @Stored private var toolResults: [SearchResultItem] = []
    @Stored private var fileResults: [FuzzyFileResult] = []
    @Stored private var isSearching = false
    @Stored private var generation = 0
    @Stored private var toolLanguageGeneration = 0
    @Stored private var webGeneration = 0
    @Stored private var hasSearched = false
    /// v60 结果列表内容实测高度（PreferenceKey 测量 → 动态展开动画）
    @Stored private var listContentHeight: CGFloat = 0
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
    /// 首选引擎无结果时用了哪个兜底引擎（标题处提示，nil = 没兜底）
    @Stored private var webFallbackName: String?
    /// v50 点击结果行后内嵌预览的文章页 URL（nil = 显示结果列表）
    @Stored private var previewArticleURL: URL?
    /// 抓取中的引擎 id（防并发显示）
    @Stored private var fetchingEngineID: String?
    /// 搜索框焦点（「打开并搜索」热键经通知程序化聚焦）
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.settingsPreviewClipboardItems) private var settingsPreviewClipboardItems
    /// v264：自建的全盘文件名索引状态（补 Spotlight 盲区，见 FileNameIndex.swift）
    @Stored private var fileIndexState: FileNameIndex.State = .absent
    private var fileIndex: FileNameIndex { FileNameIndex.shared }
    @ObservedObject private var service: SearchServiceManager
    @ObservedObject private var clipboard = ClipboardManager.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @Stored private var previewShowWeb = true
    @Stored private var previewShowClipboard = true
    @Stored private var previewShowFiles = true
    @Stored private var previewSelectedResultID: String?
    @Stored private var previewFeedback: String?
    private let draftWeb: Binding<Bool>?
    private let draftClipboard: Binding<Bool>?
    private let draftFiles: Binding<Bool>?
    private let initialCategory: SearchCategory?

    // 分类开关（分类头部眼睛按钮与设置页共用同一批键）
    @AppStorage(Preferences.Keys.searchCategoryWeb) private var savedShowWeb = true
    @AppStorage(Preferences.Keys.searchCategoryClipboard) private var savedShowClipboard = true
    @AppStorage(Preferences.Keys.searchCategoryFiles) private var savedShowFiles = true

    private var webVisibility: Binding<Bool> { isSettingsPreview ? draftWeb ?? $previewShowWeb : $savedShowWeb }
    private var clipboardVisibility: Binding<Bool> { isSettingsPreview ? draftClipboard ?? $previewShowClipboard : $savedShowClipboard }
    private var filesVisibility: Binding<Bool> { isSettingsPreview ? draftFiles ?? $previewShowFiles : $savedShowFiles }
    private var showWeb: Bool { webVisibility.wrappedValue }
    private var showClipboard: Bool { clipboardVisibility.wrappedValue }
    private var showFiles: Bool { filesVisibility.wrappedValue }

    public init() {
        service = .shared
        draftQuery = nil
        draftWeb = nil; draftClipboard = nil; draftFiles = nil
        initialCategory = nil
    }

    init(islandCategory: IslandSearchCategory) {
        service = .shared
        draftQuery = nil
        draftWeb = nil; draftClipboard = nil; draftFiles = nil
        initialCategory = SearchCategory(rawValue: islandCategory.rawValue)
    }

    init(draft: SearchDisplayDraft, query: Binding<String>) {
        service = draft.service
        draftQuery = query
        draftWeb = Binding(get: { draft.showWeb }, set: { draft.showWeb = $0 })
        draftClipboard = Binding(get: { draft.showClipboard }, set: { draft.showClipboard = $0 })
        draftFiles = Binding(get: { draft.showFiles }, set: { draft.showFiles = $0 })
        initialCategory = nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if isSettingsPreview { previewStatus }

            if initialCategory != nil, trimmedQuery.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("搜索整个 Kitnest", systemImage: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                    Text("输入关键词搜索已启用的来源；输入 / 浏览可用命令。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button {
                        query = "/"
                        searchFieldFocused = true
                    } label: {
                        Label("浏览快捷命令", systemImage: "command")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(IslandButtonStyle())
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: Theme.Radius.control)
            }

            // v60：空查询不再保留 112pt 原版建议位留白（用户反馈留白过多）——
            // 搜索框下直接接日历卡（homePage 已有 12pt 常规间隔）；
            // 输入后结果区按内容高度动态向下展开，清空即收回。
            if !trimmedQuery.isEmpty {
                if !isSettingsPreview || !isSlashMode { categoryChips }
                if isSettingsPreview && showWeb && !isSlashMode { engineActionsRow }
                if isSettingsPreview, !isSlashMode, showsWebResults, let engine = previewEngine,
                   let url = SearchServiceManager.searchURL(for: engine, query: trimmedQuery) {
                    Text("\(engine.name) · \(url.absoluteString)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                resultList
                if isSettingsPreview, let detail = previewSelectionDetail {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(detail.title).font(.system(size: 12, weight: .medium))
                        Text(detail.body).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).glassCard(radius: Theme.Radius.control)
                }
            }
        }
        .onChange(of: query) { _ in
            if isSettingsPreview { previewFeedback = nil }
            toolLanguageGeneration += 1
            scheduleSearch()
        }
        // v50：文件类型筛选变化 → 重跑文件检索（仅关键词非空时）
        .onChange(of: fileKind) { _ in
            scheduleSearch()
        }
        .onChange(of: showWeb) { _ in updatePreviewCategories() }
        .onChange(of: showClipboard) { _ in updatePreviewCategories() }
        .onChange(of: showFiles) { _ in updatePreviewCategories() }
        .onChange(of: service.activeBarItems) { _ in
            if isSettingsPreview, let id = previewEngineID, !service.activeBarItems.contains(id) { previewEngineID = nil }
        }
        .onChange(of: settingsPreviewClipboardQuery) { value in
            if isSettingsPreview && draftQuery == nil { query = value }
        }
        .onReceive(NotificationCenter.default.publisher(for: .frsetFocusPanelSearch)) { _ in
            if isSettingsPreview { return }
            // 面板可能刚被 show()，稍等一拍让 TextField 挂到窗口后再聚焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                searchFieldFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LanguageManager.languageDidChange)) { _ in
            guard !isSettingsPreview, !trimmedQuery.isEmpty else { return }
            toolLanguageGeneration += 1
            let current = toolLanguageGeneration
            let text = trimmedQuery
            Task { @MainActor in
                let results = await ToolboxSearchSource.search(text)
                guard toolLanguageGeneration == current else { return }
                toolResults = results
            }
        }
        .onReceive(FileNameIndex.shared.$state) { value in
            if !isSettingsPreview { fileIndexState = value }
        }
        .onChange(of: fileIndexState) { value in
            // 索引第一次建完 → 自动重跑当前查询。
            // 否则用户搜「image html deck」时索引还在建、只看到"没有匹配的文件"就走了，
            // 下次再搜才有结果——他只会觉得"这功能坏了"。
            if case .ready = value,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleSearch()
            }
        }
        .onAppear {
            if let initialCategory { selectedCategory = initialCategory }
            if isSettingsPreview {
                if draftQuery == nil { query = settingsPreviewClipboardQuery }
                scheduleSearch()
                return
            }
            // v264：面板一出现就把已有索引 mmap 进来（毫秒级），这样状态行能直接
            // 显示「全盘索引 124 万项」而不是每次都问用户要不要建。
            // 只读缓存，不会在这里触发建索引。
            fileIndex.preloadIfCached()
            // 排障探针：FRSET_SEARCH_PROBE=<关键词>（或 defaults write … probe.searchQuery）
            // 启动 3s 后自动填入并触发搜索。
            // 用 UserDefaults 兜底是因为 `open --env` 在本机没把变量传给 App（实测）；
            // 自动化截图验证只能靠这个入口——非激活面板收不到合成键盘事件。
            let probeEnv = ProcessInfo.processInfo.environment["FRSET_SEARCH_PROBE"]
            let probeDefault = UserDefaults.standard.string(forKey: "probe.searchQuery")
            if let probe = probeEnv ?? probeDefault, !probe.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    query = probe
                }
            }
            // 排障探针：probe.openTool=<工具id> 启动 3.5s 后自动打开工具——
            // 与点击工具行同一条 ToolboxUIState.open 链路（验证工具窗弹出）
            if let toolID = UserDefaults.standard.string(forKey: "probe.openTool"),
               !toolID.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    Log.info("Toolbox", "探针：自动打开工具 \(toolID)")
                    ToolboxUIState.shared.open(toolID)
                }
            }
            // 排障探针：probe.slashQuery=1 → 3.5s 后把首页输入框设成 "/"，
            // 5s 时把命令列表打出来（面板窗在别的 Space，截图抓不到，只能靠日志核对）
            // 排障探针：probe.slashRun=uuid → 填 `/uuid` 后执行第一条（验证命令→工具链路）
            // 排障探针：probe.webQuery=swift → 3.5s 后填入查询，8.5s 时把网页结果打进日志
            if let wq = UserDefaults.standard.string(forKey: "probe.webQuery"), !wq.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    query = wq
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        Log.info("Toolbox", "探针：网页结果 \(webResults.count) 条，引擎=\(previewEngine?.id ?? "-")，兜底=\(webFallbackName ?? "-")，失败=\(webFetchFailed)")
                        // v181：主操作改成「点击即开浏览器」后，探针不再自动打开内嵌预览
                        //（否则面板一出现就被预览占满，看不到结果列表本身）。
                    }
                }
            }
            if let token = UserDefaults.standard.string(forKey: "probe.slashRun"), !token.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    query = "/" + token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        Log.info("Toolbox", "探针：执行命令 /\(token)，命中 \(toolResults.count) 条")
                        toolResults.first?.action()
                    }
                }
            }
            if UserDefaults.standard.bool(forKey: "probe.slashQuery") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    query = "/"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let titles = toolResults.prefix(20).map(\.title).joined(separator: " ")
                        Log.info("Toolbox", "探针：斜杠命令 \(toolResults.count) 条 → \(titles)")
                    }
                }
            }
        }
        .onDisappear {
            generation += 1
        }
    }

    // MARK: 搜索框

    private var previewStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(trimmedQuery.isEmpty ? "选择场景或输入关键词" :
                     "网页 \(showWeb ? String(webResults.count) : "已隐藏") · 文件 \(showFiles ? String(fileResults.count) : "已隐藏") · 剪贴板 \(showClipboard ? String(clipboardMatches.count) : "已隐藏") · 工具 \(toolResults.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button(isSlashMode ? "演示执行" : "演示搜索") {
                    if let engine = previewEngine ?? service.activeBarEngines.first { performWebSearch(engine) }
                }
                .buttonStyle(.bordered).controlSize(.mini)
                .disabled(trimmedQuery.isEmpty || (isSlashMode ? toolResults.isEmpty : !showWeb))
            }
            if let previewFeedback {
                Text(previewFeedback).font(.system(size: 11)).foregroundStyle(theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewSelectionDetail: (title: String, body: String)? {
        if showFiles, let file = fileResults.first(where: { $0.id == previewSelectedResultID }) {
            return (file.url.lastPathComponent, file.url.path)
        }
        if showClipboard, let item = clipboardMatches.first(where: { $0.item.id == previewSelectedResultID })?.item {
            return (item.displayTitle, item.content ?? item.subtitle ?? "图片示例")
        }
        if showsWebResults, let item = webResults.first(where: { $0.id.uuidString == previewSelectedResultID }) {
            return (item.title, item.snippet + "\n" + item.url.absoluteString)
        }
        if let tool = toolResults.first(where: { $0.id == previewSelectedResultID }) { return (tool.title, tool.subtitle ?? "") }
        return nil
    }

    private func previewAction(_ action: String) {
        let clears = service.clearSearchInputAfterWebAction
        previewFeedback = "演示：\(action) · \(clears ? "输入已清空" : "输入保留")"
        if clears { clearInput() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索或输入 / 使用工具", text: draftQuery ?? $localQuery)

            // v59：⌘K 面板内聚焦搜索（与 ⌥F 全局快捷键同一条通知链路）
            .background {
                Button {
                    if isSettingsPreview { searchFieldFocused = true }
                    else { NotificationCenter.default.post(name: .frsetFocusPanelSearch, object: nil) }
                } label: {
                    Color.clear.frame(width: 0, height: 0)
                }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
            }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFieldFocused)
                // 原版行为：回车 = 用搜索栏当前引擎打开网页搜索（引擎卡片上的 ↵ 标记）
                .onSubmit {
                    if let first = (isSettingsPreview ? previewEngine : nil) ?? service.activeBarEngines.first {
                        performWebSearch(first)
                    }
                }
            // v172（用户：「添加一个按钮，点击之后就自动输入斜杠，展示这一系列命令」）
            // 就在首页这个输入框里：点一下补 `/` 列出全部命令，再点一下退回普通搜索。
            Button {
                query = isSlashMode ? "" : "/"
                searchFieldFocused = true
            } label: {
                Text("/")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSlashMode ? theme.accent : Color.secondary)
                    .frame(width: 20, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                            .fill(isSlashMode ? theme.accent.opacity(0.18)
                                              : Color.primary.opacity(0.06))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("命令模式：列出全部工具命令（/uuid、/time、/apollo…）")
            .accessibilityLabel("斜杠命令")

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
        .glassCard(radius: 8, fill: isSettingsPreview && reduceTransparency ? Color(nsColor: .controlBackgroundColor) : nil)
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
                        if !isSettingsPreview, category == .web, webResults.isEmpty, !previewQuery.isEmpty {
                            fetchingEngineID = previewEngine?.id
                            Task { await fetchWebResults() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.icon).font(.system(size: 11, weight: .semibold))
                            Text(category.title).font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            Capsule().fill(selectedCategory == category
                                           ? theme.accent.opacity(0.16)
                                           : theme.cardFill)
                        )
                        .foregroundStyle(selectedCategory == category ? theme.accent : Color.secondary)
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

    // MARK: 结果列表（v60：按内容实际高度动态向下展开）

    /// 内容高度测量键（VStack 在 ScrollView 内保持理想高度，测量值即内容实际高度）
    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// 展开上限：主面板固定 700pt，搜索结果区最多 420pt（分级展示条数更多，
    /// 超出在区内滚动；日历卡仍露出大半）
    private var resultListMaxHeight: CGFloat { isSettingsPreview ? 240 : 420 }

    private var resultList: some View {
        ScrollView(.vertical, showsIndicators: isSettingsPreview) {
            listContent
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: geo.size.height)
                    }
                )
        }
        .frame(height: min(max(listContentHeight, 1), resultListMaxHeight))
        .animation(reduceMotion ? nil : Theme.Motion.spring, value: listContentHeight)
        .onPreferenceChange(ContentHeightKey.self) { listContentHeight = $0 }
    }

    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSearching && toolResults.isEmpty && fileResults.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("搜索中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
                .padding(.vertical, 8)
            }

            switch isSettingsPreview && isSlashMode ? SearchCategory.tools : selectedCategory {
            case .all:
                // 全部视图（v63 分级/分类展示）：按匹配优先级排列——本地文件（模糊
                // 引擎主场景）→ 工具 → 剪贴板 → 网页；每类更多条 + 类型色分级组头
                //（点组头进入该分类完整列表）。上限内滚动浏览。
                if showFiles { filesCategory(maxRows: isSettingsPreview ? 2 : 6, compact: true); if !toolResults.isEmpty || showClipboard || showsWebResults { categoryDivider } }
                if !toolResults.isEmpty { toolCategory(maxRows: 4, compact: true); if showClipboard || showsWebResults { categoryDivider } }
                if showClipboard { clipboardCategory(maxRows: 3, compact: true); if showsWebResults { categoryDivider } }
                if showsWebResults { webCategory(maxRows: 3, compact: true) }
            case .web:
                if isLocalPathQuery {
                    Text("文件路径仅在本机搜索").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    webCategory(maxRows: 10, compact: false)
                }
            case .clipboard:
                clipboardCategory(maxRows: 8, compact: false)
            case .files:
                filesCategory(maxRows: 8, compact: false)
            case .tools:
                if toolResults.isEmpty {
                    Text("没有匹配的工具（输入 / 查看全部）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 4)
                        .padding(.vertical, 8)
                } else {
                    toolCategory(maxRows: 8, compact: false)
                }
            }

            if nothingFound {
                VStack(alignment: .leading, spacing: 2) {
                    Text("没有找到与「\(trimmedQuery)」相关的内容")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("网页 / 剪贴板 / 文件分类可在分类行右侧的眼睛按钮或设置中调整显隐。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                }
                .padding(.leading, 4)
                .padding(.vertical, 8)
            }
        }
    }

    private var nothingFound: Bool {
        hasSearched && !isSearching && selectedCategory != .web
            && (toolResults.isEmpty && fileResults.isEmpty && clipboardMatches.isEmpty)
    }

    private var categoryDivider: some View {
        Divider().padding(.vertical, 7)
    }

    /// 分类标题行：图标 + 名 + 计数 + 快速隐藏（眼睛）
    /// v63 分级展示·一级（分类组头）：类型色图标块 + 标题 + 计数徽标 +
    /// 「查看全部 ›」（点击整行进入该分类的完整结果列表）+ 右侧眼睛显隐开关。
    private func categoryHeader(_ category: SearchCategory,
                                isShown: Binding<Bool>? = nil,
                                count: Int? = nil) -> some View {
        Button {
            if category != .all { selectedCategory = category }
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(category.tint.opacity(0.14))
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: category.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(category.tint)
                    )
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                if category != .all {
                    Text("查看全部")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                }
                Spacer(minLength: 0)
                if let isShown {
                    Button {
                        isShown.wrappedValue.toggle()
                    } label: {
                        Image(systemName: isShown.wrappedValue ? "eye" : "eye.slash")
                            .font(.system(size: 11))
                            .foregroundStyle(isShown.wrappedValue ? Color.secondary : Color.primary.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help(isShown.wrappedValue ? "隐藏该分类（设置 → 搜索 里也可开关）" : "该分类已隐藏，点击显示")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(category == .all ? "" : "点击查看「\(category.title)」分类的全部结果")
        .padding(.vertical, 3)
    }

    // MARK: 分类① 网页（结果列表 + 单条内嵌预览）

    private var previewEngine: SearchEngine? {
        guard let id = previewEngineID else {
            return service.activeBarEngines.first
        }
        let selected = service.activeBarEngines.first(where: { $0.id == id })
        return isSettingsPreview ? selected ?? service.activeBarEngines.first : selected
    }

    private func webCategory(maxRows: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if selectedCategory == .all {
                categoryHeader(.web, isShown: webVisibility)
            }
            if !compact && !isSettingsPreview {
                engineActionsRow
            }
            webResultArea(maxRows: maxRows, compact: compact)
        }
    }

    /// 引擎动作行：搜索型引擎 = 切换内嵌结果列表；动作型引擎 = 浏览器直接打开
    private var engineActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(service.activeBarEngines) { engine in
                    Button {
                        if engine.supportsResultList {
                            previewEngineID = engine.id
                            previewArticleURL = nil
                            if isSettingsPreview { previewFeedback = "已切换到 \(engine.name)，其他分类和所选内容保持原样" }
                            else {
                                fetchingEngineID = engine.id
                                Task { await fetchWebResults() }
                            }
                        } else {
                            performWebSearch(engine)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: engine.systemImage)
                                .font(.system(size: 11))
                            Text(engine.supportsResultList
                                 ? engine.name
                                 : "\(engine.name) ↗")
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                                .fill((isSettingsPreview ? previewEngine?.id : previewEngineID) == engine.id
                                      ? theme.accent.opacity(0.14)
                                      : theme.cardFill)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isSettingsPreview ? "固定示例：切换结果引擎，↗ 演示搜索后清空输入" : engine.supportsResultList
                          ? "内嵌预览 \(engine.name) 搜索结果"
                          : "在浏览器中用 \(engine.name) 搜索（该引擎不支持内嵌结果列表）")
                }
            }
            .padding(.leading, 2)
        }
    }

    /// v50 网页区主体：结果列表 ↔ 单条文章预览
    /// v60：条数限流；compact = 全部视图单行（标题 + 右侧域名），重点突出
    @ViewBuilder private func webResultArea(maxRows: Int, compact: Bool) -> some View {
        let engine = previewEngine
        let supports = engine?.supportsResultList ?? false

        if !isSettingsPreview, let articleURL = previewArticleURL {
            // 单条结果的内嵌预览（文章页在小窗中可读性远好于搜索页）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        previewArticleURL = nil
                    } label: {
                        Label("结果列表", systemImage: "chevron.left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("返回搜索结果列表")
                    Spacer(minLength: 0)
                    Button {
                        NSWorkspace.shared.open(articleURL)
                    } label: {
                        Label("浏览器打开", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("在默认浏览器中打开该页面")
                }
                WebPreviewRepresentable(url: articleURL)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
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
                    Label(isSettingsPreview ? "演示搜索" : "在浏览器中搜索", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
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
                Text(isSettingsPreview ? "没有匹配的固定网页示例" : "未能获取「\(engine?.name ?? "")」结果（可能被安全验证拦截）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    if let engine { performWebSearch(engine) }
                } label: {
                    Label(isSettingsPreview ? "演示搜索" : "在浏览器中搜索", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
            .padding(.leading, 4)
            .padding(.vertical, 4)
        } else if !webResults.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(webFallbackName.map { "搜索结果 · \(engine?.name ?? "") → \($0)" }
                         ?? "搜索结果 · \(engine?.name ?? "")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        if let engine { performWebSearch(engine) }
                    } label: {
                        Label(isSettingsPreview ? "演示搜索" : "浏览器打开", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isSettingsPreview ? "演示搜索后清空输入开关" : "在默认浏览器打开该搜索结果")
                }
                ForEach(webResults.prefix(maxRows)) { result in
                    HStack(spacing: 4) {
                    Button {
                        if isSettingsPreview {
                            previewSelectedResultID = result.id.uuidString
                            if NSEvent.modifierFlags.contains(.option) { previewFeedback = "内嵌网页预览：" + result.title }
                            else { previewAction("打开网页：" + result.title) }
                            return
                        }
                        // v181（用户：「只要点击，就是直接默认浏览器打开」）：
                        // 主操作从「内嵌预览」改成「开浏览器」——点行内任何位置都走这里。
                        // 内嵌预览退到 ⌥ 点击（功能保留，不再挡在主动作前面）。
                        if NSEvent.modifierFlags.contains(.option) {
                            previewArticleURL = result.url
                        } else {
                            Log.info("Search", "openResult host=\(result.url.host ?? "-")")
                            NSWorkspace.shared.open(result.url)
                            if service.clearSearchInputAfterWebAction { clearInput() }
                        }
                    } label: {
                        if compact {
                            // 全部视图：单行——标题（命中高亮）+ 右侧域名
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .frame(width: 14)
                                highlighted(result.title,
                                            match: FuzzyMatcher.match(previewQuery, in: result.title),
                                            size: 12)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                Spacer(minLength: 8)
                                // v181：标题有 layoutPriority(1)，长标题会把域名挤到只剩 1–2 个字符
                                //（截图实测「(」「...」）。给域名一个最小宽度，让标题先截断。
                                Text(result.host)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(minWidth: 72, alignment: .trailing)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color.clear))
                            .contentShape(Rectangle())
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                // 标题对关键词做模糊命中高亮（accent + 加粗），重点突出
                                highlighted(result.title,
                                            match: FuzzyMatcher.match(previewQuery, in: result.title),
                                            size: 12, weight: .medium, color: .accentColor)
                                    .lineLimit(1)
                                if !result.snippet.isEmpty {
                                    Text(result.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(result.host)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color.clear))
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .background(previewSelectionFill(result.id.uuidString))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(isSettingsPreview ? "选择固定网页示例" : "点击在默认浏览器打开（⌥ 点击：在此处预览）")
                    .accessibilityLabel(isSettingsPreview ? "选择示例：\(result.title)" : "在默认浏览器打开：\(result.title)")
                    if !isSettingsPreview {
                        let url = result.url.absoluteString
                        Button { favorites.toggle(.searchResult, id: url) } label: {
                            Image(systemName: favorites.contains(.searchResult, id: url) ? "star.fill" : "star")
                                .font(.system(size: 11))
                                .foregroundStyle(favorites.contains(.searchResult, id: url) ? Theme.accent : Color.secondary)
                                .frame(width: 22, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help(favorites.contains(.searchResult, id: url) ? "取消收藏网页" : "收藏网页")
                        .accessibilityLabel(favorites.contains(.searchResult, id: url) ? "取消收藏网页" : "收藏网页")
                    }
                    }
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

    /// 正文参与匹配的上限（v128：超长条目（整篇文档/日志）每键都要全量 lowercased +
    /// 贪心扫描，是输入卡顿的大头；搜索列表本就只展示标题/副标题，截到前 4096 字符
    /// 对常规条目零差异，超长条目只损失尾部命中）。
    private static let matchContentLimit = 4096

    private var filteredClipboardMatches: [(item: ClipboardItem, match: FuzzyMatch?)] {
        let keyword = trimmedQuery
        guard !keyword.isEmpty else { return [] }
        if isSettingsPreview {
            return settingsPreviewClipboardItems.compactMap { item in
                guard clipboardKind.matches(item.type),
                      FuzzyMatcher.isMatch(keyword, in: [item.displayTitle, item.subtitle, item.content].compactMap { $0 }.joined(separator: " ")) else { return nil }
                return (item, FuzzyMatcher.match(keyword, in: item.displayTitle))
            }
        }
        let limit = Self.matchContentLimit
        return clipboard.items.compactMap { item in
            guard clipboardKind.matches(item.type) else { return nil }
            let content = item.content.map { $0.count > limit ? String($0.prefix(limit)) : $0 }
            let haystack = [item.displayTitle, item.title, item.subtitle, content]
                .compactMap { $0 }.joined(separator: " ")
            guard FuzzyMatcher.isMatch(keyword, in: haystack) else { return nil }
            let titleMatch = FuzzyMatcher.match(keyword, in: item.displayTitle)
            return (item, titleMatch)
        }
    }

    private var clipboardMatches: [(item: ClipboardItem, match: FuzzyMatch?)] { filteredClipboardMatches }

    /// 二级筛选 chips（文件类型 / 剪贴板类型共用样式）
    private func filterChips<Kind: Identifiable & Equatable>(
        _ kinds: [Kind], selection: Binding<Kind>, title: @escaping (Kind) -> String) -> some View {
        HStack(spacing: 3) {
            ForEach(kinds) { kind in
                Button {
                    selection.wrappedValue = kind
                } label: {
                    Text(title(kind))
                        .font(.system(size: 11, weight: selection.wrappedValue == kind ? .semibold : .regular))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(selection.wrappedValue == kind
                                                   ? theme.accent.opacity(0.15)
                                                   : theme.cardFill))
                        .foregroundStyle(selection.wrappedValue == kind ? theme.accent : Color.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func clipboardCategory(maxRows: Int, compact: Bool) -> some View {
        // v126（性能审计 F1423）：filteredClipboardMatches 是全量模糊过滤（对每个剪贴板
        // 条目做 FuzzyMatcher），原实现对 count / rows 各求值一次 = 每次渲染两遍全量过滤，
        // 且行内用 matches.first(where:) 反查 match 是 O(n²)。改为一次求值 + 枚举直取。
        let all = filteredClipboardMatches
        let matches = Array(all.prefix(maxRows))
        return VStack(alignment: .leading, spacing: 3) {
            if selectedCategory == .all {
                categoryHeader(.clipboard, isShown: clipboardVisibility,
                               count: all.isEmpty ? nil : all.count)
            } else {
                filterChips(ClipboardFilterKind.allCases, selection: $clipboardKind) { $0.title }
            }
            if matches.isEmpty {
                Text("没有匹配的剪贴板条目")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.leading, 4)
                    .padding(.bottom, 2)
            } else {
                ForEach(matches.indices, id: \.self) { idx in
                    let item = matches[idx].item
                    let match = matches[idx].match
                    Button {
                        if isSettingsPreview {
                            previewSelectedResultID = item.id
                            settingsPreviewClipboardSelection?.wrappedValue = item.id
                            previewFeedback = "复制示例：\(item.displayTitle) · 输入保留"
                            return
                        }
                        ClipboardManager.shared.copy(item)
                        Toast.show("已复制剪贴板条目", icon: "checkmark.circle.fill")
                    } label: {
                        if compact {
                            // 全部视图：单行——标题（命中高亮）+ 右侧时间
                            HStack(spacing: 8) {
                                Image(systemName: clipboardIcon(item.type))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .frame(width: 14)
                                highlighted(item.displayTitle,
                                            match: match, size: 12)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                Spacer(minLength: 8)
                                Text(item.timestamp.formatted(.relative(presentation: .named)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color.clear))
                            .contentShape(Rectangle())
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: clipboardIcon(item.type))
                                    .font(.system(size: 11))
                                    .frame(width: 18)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    // 标题命中字符 accent 高亮
                                    highlighted(item.displayTitle,
                                                match: match, size: 12)
                                        .lineLimit(1)
                                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(item.timestamp.formatted(.relative(presentation: .named)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color.clear))
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .background(previewSelectionFill(item.id))
                    .help(isSettingsPreview ? "选择固定剪贴板示例" : "点击复制该条目")
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

    // MARK: 分类③ 本地文件（v60：真实文件图标 + 命中高亮 + 层级排版）

    /// 文件图标缓存（NSWorkspace 真实图标，FSearch/Everything 同款风格）
    // v128（内存）：NSCache 原本无上限——每次搜索结果路径都不同，长会话下图标可无限堆积。
    // 上限 256 项 + 按像素面积计 cost（18×18 图约 1.3KB，256 项约 0.3MB 量级，压力可忽略）。
    private static let fileIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    private static func fileIcon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = fileIconCache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        // v128（内存）：按像素面积计 cost，配合 totalCostLimit 语义更准（现主要靠 countLimit 兜底）
        let cost = Int(icon.size.width * icon.size.height * 4)
        fileIconCache.setObject(icon, forKey: key, cost: cost)
        return icon
    }

    private func resultFileIcon(for url: URL) -> Image {
        if !isSettingsPreview { return Image(nsImage: Self.fileIcon(for: url)) }
        let kind = Self.previewFiles.first { $0.name == url.lastPathComponent }?.kind
        let icon = kind == .folder ? "folder" : kind == .image ? "photo" : kind == .media ? "play.rectangle" : kind == .archive ? "archivebox" : "doc.text"
        return Image(systemName: icon)
    }

    /// 「最佳匹配」徽标（该组评分第一名）
    private var bestBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
            Text("最佳")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(theme.accent)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.accent.opacity(0.12)))
    }

    private var isIndexBuilding: Bool {
        if case .building = fileIndexState { return true }
        return false
    }

    /// 索引状态行（v264）。
    ///
    /// 用户搜不到 `~/.workbuddy/skills/image-html-deck`，根因是 Spotlight 压根没索引那片，
    /// 但界面上只写「没有匹配的文件」看不出是"没有"还是"没搜"。这里把索引状态摊开：
    /// 建到哪一步、覆盖哪些目录、什么时候建的、要不要重建。
    @ViewBuilder
    private var fileIndexStatus: some View {
        if isSettingsPreview {
            Text("固定文件示例 · 不查询本机索引")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        } else {
        HStack(spacing: 6) {
            switch fileIndexState {
            case .absent:
                Text("Spotlight 不索引 ~/Library、隐藏目录（.workbuddy / .cursor…）与 .app 内部")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                Button("建立全盘索引") { fileIndex.ensureReady() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.accent)
            case .building(let scanned):
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text("正在建立全盘索引 · 已收录 \(scanned.formatted()) 项（首次约 1 分钟，之后秒出）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
            case .ready(let count, let at):
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
                Text("全盘索引 \(count.formatted()) 项 · \(Self.ago(at)) · 含隐藏目录 / ~/Library / .app 内部")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                Button("重建") { fileIndex.rebuild() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
            case .failed(let msg):
                Text("全盘索引不可用：\(msg)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                Button("重试") { fileIndex.rebuild() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.leading, 4)
        }
    }

    private static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "刚刚建立" }
        if s < 3600 { return "\(s / 60) 分钟前建立" }
        if s < 86_400 { return "\(s / 3600) 小时前建立" }
        return "\(s / 86_400) 天前建立"
    }

    private func filesCategory(maxRows: Int, compact: Bool) -> some View {
        let rows = Array(fileResults.prefix(maxRows))
        return VStack(alignment: .leading, spacing: 3) {
            if selectedCategory == .all {
                categoryHeader(.files, isShown: filesVisibility,
                               count: fileResults.isEmpty ? nil : fileResults.count)
            } else {
                filterChips(FileSearchSource.Kind.allCases, selection: $fileKind) { $0.title }
            }
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasSearched
                         ? (isIndexBuilding ? "正在建立全盘索引，先看上面几组结果…" : "没有匹配的文件")
                         : "输入文件名搜索全盘文件（支持乱序模糊匹配）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.leading, 4)
                    fileIndexStatus
                }
                .padding(.bottom, 2)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, result in
                    HStack(spacing: 4) {
                        Button {
                            if isSettingsPreview {
                                previewSelectedResultID = result.id
                                previewFeedback = "定位示例：" + result.url.lastPathComponent
                                return
                            }
                            NSWorkspace.shared.activateFileViewerSelecting([result.url])
                        } label: {
                            if compact {
                            // 全部视图：单行——文件名（命中高亮）+ 右侧父目录名
                            HStack(spacing: 8) {
                                resultFileIcon(for: result.url)
                                    .interpolation(.high)
                                    .frame(width: 16, height: 16)
                                highlighted(result.url.lastPathComponent,
                                            match: result.nameMatch, size: 12)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                                if index == 0 { bestBadge }
                                Spacer(minLength: 8)
                                Text(result.url.deletingLastPathComponent().lastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color.clear))
                            .contentShape(Rectangle())
                        } else {
                            HStack(spacing: 8) {
                                // 真实文件图标（26pt 容器统一节奏）
                                resultFileIcon(for: result.url)
                                    .interpolation(.high)
                                    .frame(width: 26, height: 26)
                                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                        .fill(Color.primary.opacity(0.045)))
                                VStack(alignment: .leading, spacing: 1) {
                                    // 主层级：文件名 + 命中高亮
                                    highlighted(result.url.lastPathComponent,
                                                match: result.nameMatch,
                                                size: 12, weight: .medium)
                                        .lineLimit(1)
                                    // 次层级：父目录路径（灰字，中段截断）
                                    highlighted(result.url.deletingLastPathComponent().path,
                                                match: result.pathMatch,
                                                size: 11, color: .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                // 评分第一名带「最佳」徽标（重点突出）
                                if index == 0 {
                                    bestBadge
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Color.clear))
                            .contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .background(previewSelectionFill(result.id))
                        .help(isSettingsPreview ? "选择固定文件示例" : "在 Finder 中显示")
                        if !isSettingsPreview {
                            let url = result.url.absoluteString
                            Button { favorites.toggle(.searchResult, id: url) } label: {
                                Image(systemName: favorites.contains(.searchResult, id: url) ? "star.fill" : "star")
                                    .font(.system(size: 11))
                                    .foregroundStyle(favorites.contains(.searchResult, id: url) ? Theme.accent : Color.secondary)
                                    .frame(width: 22, height: 24)
                            }
                            .buttonStyle(.plain)
                            .help(favorites.contains(.searchResult, id: url) ? "取消收藏文件" : "收藏文件")
                            .accessibilityLabel(favorites.contains(.searchResult, id: url) ? "取消收藏文件" : "收藏文件")
                        }
                    }
                }
            }
        }
    }

    // MARK: 分类④ 工具（"/" 模式与关键词模糊匹配）

    @ViewBuilder private func toolCategory(maxRows: Int, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            categoryHeader(.tools, count: toolResults.isEmpty ? nil : toolResults.count)
            ForEach(toolResults.prefix(maxRows)) { item in
                Button {
                    if isSettingsPreview {
                        previewSelectedResultID = item.id
                        previewAction("执行工具：" + item.title)
                        return
                    }
                    item.action()
                    if service.clearSearchInputAfterWebAction {
                        clearInput()
                    }
                } label: {
                    if compact {
                        // 全部视图：单行——工具名（命中高亮）+ 右侧分类
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(width: 14)
                            highlighted(item.title, match: item.match, size: 12)
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: 8)
                            Text(item.subtitle ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .font(.system(size: 12))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                // 工具名命中高亮
                                highlighted(item.title, match: item.match, size: 12)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.system(size: 11))
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
                }
                .buttonStyle(.plain)
                .background(previewSelectionFill(item.id))
            }
        }
    }

    // MARK: 匹配高亮文本（v60）

    /// 命中字符 accent + 加粗、其余常规——搜索结果的「重点突出」由它完成。
    /// match = nil（未命中/无区间）时退化为纯文本。
    private func highlighted(_ text: String, match: FuzzyMatch?, size: CGFloat,
                             weight: Font.Weight = .regular,
                             color: Color = .primary) -> Text {
        let font = Font.system(size: size, weight: weight)
        guard let match, !match.indices.isEmpty, !text.isEmpty else {
            return Text(text).font(font).foregroundColor(color)
        }
        let hits = Set(match.indices)
        var segments: [(str: String, hit: Bool)] = []
        for (index, character) in text.enumerated() {
            let isHit = hits.contains(index)
            if let last = segments.last, last.hit == isHit {
                segments[segments.count - 1].str.append(character)
            } else {
                segments.append((String(character), isHit))
            }
        }
        var output = Text("")
        for segment in segments {
            let piece = Text(segment.str)
                .font(segment.hit ? font.weight(.semibold) : font)
                .foregroundColor(segment.hit ? theme.accent : color)
            output = output + piece
        }
        return output
    }

    // MARK: - 动作

    private static let previewTools: [SearchResultItem] = [
        SearchResultItem(id: "preview-tinyimg", title: "设计图压缩", subtitle: "/tinyimg · 图片工具", icon: "photo", action: {}),
        SearchResultItem(id: "preview-uuid", title: "UUID 生成", subtitle: "/uuid · 开发工具", icon: "number", action: {}),
        SearchResultItem(id: "preview-time", title: "时间转换", subtitle: "/time · 开发工具", icon: "clock", action: {}),
    ]
    private static let previewFiles: [(name: String, kind: FileSearchSource.Kind)] = [
        ("设计说明.pdf", .document), ("设计封面.png", .image),
        ("设计演示.mov", .media), ("设计素材.zip", .archive), ("设计项目", .folder),
    ]
    private static let previewWebItems: [WebSearchResult] = [
        WebSearchResult(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Apple 设计资源",
                        url: URL(string: "https://developer.apple.com/design/")!, snippet: "固定示例：界面设计与交互指南。"),
        WebSearchResult(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "SwiftUI 界面设计",
                        url: URL(string: "https://developer.apple.com/swiftui/")!, snippet: "固定示例：布局、状态和原生组件。"),
    ]

    private func updatePreviewCategories() {
        if (selectedCategory == .web && !showWeb)
            || (selectedCategory == .clipboard && !showClipboard)
            || (selectedCategory == .files && !showFiles) { selectedCategory = .all }
        if !isSettingsPreview { scheduleSearch() }
    }

    private func filterPreviewItems(_ text: String) {
        let toolQuery = isSlashMode ? String(text.dropFirst()) : text
        toolResults = Self.previewTools.compactMap { item in
            let match = FuzzyMatcher.match(toolQuery, in: item.title)
            guard toolQuery.isEmpty || match != nil
                || FuzzyMatcher.isMatch(toolQuery, in: item.subtitle ?? "") else { return nil }
            return SearchResultItem(id: item.id, title: item.title, subtitle: item.subtitle,
                                    icon: item.icon, match: match, action: item.action)
        }
        fileResults = isSlashMode ? [] : Self.previewFiles.compactMap { sample in
            guard fileKind == .all || fileKind == sample.kind,
                  let match = FuzzyMatcher.match(text, in: sample.name) else { return nil }
            return FuzzyFileResult(url: URL(fileURLWithPath: "/示例资料/\(sample.name)"),
                                   score: match.score, nameMatch: match, pathMatch: nil)
        }
        webResults = isSlashMode ? [] : Self.previewWebItems.filter {
            FuzzyMatcher.isMatch(text, in: $0.title + " " + $0.snippet)
        }
        previewQuery = text
        hasSearched = true
        isSearching = false
        fetchingEngineID = nil
        webFetchFailed = false
        webFallbackName = nil
    }

    private func previewSelectionFill(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
            .fill(isSettingsPreview && previewSelectedResultID == id ? theme.accent.opacity(0.12) : Color.clear)
    }

    /// 去除首尾空白后的关键词（分类显隐、剪贴板匹配、预览 URL 构造共用）
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Web 打开引擎搜索 URL；行为开关 clearSearchInputAfterWebAction 决定是否清空输入框
    private func performWebSearch(_ engine: SearchEngine) {
        if isSettingsPreview {
            if isSlashMode {
                if let tool = toolResults.first {
                    previewSelectedResultID = tool.id
                    previewAction("执行工具：" + tool.title)
                }
            } else if showWeb {
                previewEngineID = engine.id
                previewAction("使用 \(engine.name) 搜索「\(trimmedQuery)」")
            }
            return
        }
        let text = trimmedQuery
        guard !text.isEmpty, let url = SearchServiceManager.searchURL(for: engine, query: text) else { return }
        Log.info("Search", "performWebSearch engine=\(engine.name)")
        // v84：搜索结果打开埋点（面板内所有「搜索」动作的统一出口）
        StatisticsManager.shared.record(.searchExecute)
        StatisticsManager.shared.record(.webSearchOpen)
        if NSWorkspace.shared.open(url) {
            HapticService.shared.perform(.searchCompleted)
        }
        if service.clearSearchInputAfterWebAction {
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
        previewSelectedResultID = nil
    }

    /// v50 抓取当前引擎的结果列表（后台任务；generation 防串台）
    private func fetchWebResults() {
        if isSettingsPreview { scheduleSearch(); return }
        guard !isLocalPathQuery, let engine = previewEngine, !previewQuery.isEmpty else { return }
        let engineID = engine.id
        let text = previewQuery
        let current = generation
        webGeneration += 1
        let webRequest = webGeneration
        Task {
            var results = await WebResultScraper.shared.fetchResults(engine: engine, query: text)
            var fallbackName: String?

            // v174：首选引擎空手而归时兜底。
            // Google 经常返回同意页/安全验证，WKWebView 里 JS 抓不到条目，
            // 用户看到的就是「没有搜索结果」。DuckDuckGo 的 html 端点无 JS、稳定。
            if results.isEmpty, engineID != "duckduckgo",
               let ddg = service.allEngines.first(where: { $0.id == "duckduckgo" }) {
                let backup = await WebResultScraper.shared.fetchResults(engine: ddg, query: text)
                if !backup.isEmpty {
                    results = backup
                    fallbackName = ddg.name
                }
            }

            guard !Task.isCancelled, current == generation, webRequest == webGeneration,
                  engineID == previewEngine?.id else { return }
            webResults = results
            webFetchFailed = results.isEmpty
            webFallbackName = fallbackName
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
            webFallbackName = nil
            return
        }
        if isSettingsPreview {
            filterPreviewItems(trimmed)
            return
        }
        isSearching = true
        let languageVersion = toolLanguageGeneration
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, current == generation else { return }
            let items = await SearchHookRegistry.search(text)
            let kind = fileKind
            let wantsFiles = showFiles || selectedCategory == .files
            // 第一次搜文件时才把索引准备好（有缓存就 mmap，没有就后台建）；
            // 平时不搜文件的话这里一次都不会执行，零常驻。
            if wantsFiles { FileNameIndex.shared.ensureReady() }
            let files: [FuzzyFileResult] = wantsFiles
                ? await Task.detached(priority: .utility) { FileSearchSource.search(trimmed, kind: kind) }.value
                : []
            guard !Task.isCancelled, current == generation else { return }
            await MainActor.run {
                guard !Task.isCancelled, current == generation else { return }
                if languageVersion == toolLanguageGeneration { toolResults = items }
                fileResults = files
                previewQuery = trimmed          // 预览随防抖提交的词更新（不逐键刷网页）
                hasSearched = true
                isSearching = false
                if isLocalPathQuery { webResults = []; fetchingEngineID = nil }
                // 网页启用时等该查询的网页结果收尾，其余查询在全部本地来源汇总后反馈。
                if showsWebResults, let engine = previewEngine, engine.supportsResultList {
                    fetchingEngineID = engine.id
                    fetchWebResults()
                }
            }
        }
    }
}

// MARK: - WKWebView 内嵌预览（集成 WebKit 引擎）

private struct WebPreviewRepresentable: NSViewRepresentable {
    let url: URL

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Log.info("Search", "内嵌预览加载完成 host=\(webView.url?.host ?? "-")")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let failure = error as NSError
            Log.warn("Search", "内嵌预览加载失败：\(failure.domain) \(failure.code)")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let failure = error as NSError
            Log.warn("Search", "内嵌预览无法连接：\(failure.domain) \(failure.code)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 预览是临时查看，不留 cookie/缓存/历史
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
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
