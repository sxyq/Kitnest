import SwiftUI
import AppKit
import Combine

// MARK: - 全局搜索区段（id "search", priority 5，排在主面板最前）
//
// 设计：本模块只提供 UI 与检索框架，真正的检索源由其他模块/总控通过 SearchHookRegistry 注入
// （避免直接引用剪贴板等模块的具體类型）。模块内置"工具名检索"作为默认数据源。

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
            let keyword = query.lowercased()
            return ToolRegistry.enabledTools.compactMap { tool in
                let haystack = [tool.name, tool.identifier, tool.category.title].joined(separator: " ").lowercased()
                guard haystack.contains(keyword) else { return nil }
                return SearchResultItem(id: "tool-\(tool.identifier)",
                                        title: tool.name,
                                        subtitle: "工具箱 · \(tool.category.title)",
                                        icon: tool.systemImage) {
                    ToolboxUIState.shared.open(tool.identifier)
                }
            }
        }
    }
}

// MARK: UI

public struct SearchSectionView: View {
    @Stored private var query: String = ""
    @Stored private var results: [SearchResultItem] = []
    @Stored private var isSearching = false
    @Stored private var generation = 0
    @Stored private var hasSearched = false
    /// 搜索框焦点（「打开并搜索」热键经通知程序化聚焦）
    @FocusState private var searchFieldFocused: Bool

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索工具、剪贴板、AI…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFieldFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardBackground))

            // 引擎搜索动作行：输入非空时提供「用 Google 搜索」等动作项（specs/18 ①）
            if !trimmedQuery.isEmpty {
                engineActionsRow
            }

            if isSearching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("搜索中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            } else if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(results) { item in
                            Button {
                                item.action()
                                // 打开链接后按行为开关清空输入框（specs/18 F4）
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
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else if hasSearched && !query.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("没有找到与「\(query)」相关的内容")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("当前已接入的检索源：工具名。其他检索源（剪贴板 / AI 会话等）由对应模块注入后即刻生效。")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                }
                .padding(.leading, 4)
            }
        }
        .onChange(of: query) { _ in scheduleSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .frsetFocusPanelSearch)) { _ in
            // 面板可能刚被 show()，稍等一拍让 TextField 挂到窗口后再聚焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                searchFieldFocused = true
            }
        }
    }

    // MARK: - 引擎搜索动作（specs/18 ①：内置引擎 Web 打开 + 清空输入框开关）

    /// 去除首尾空白后的关键词（引擎动作行显隐与构造共用）
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 引擎动作行：搜索栏激活集内的引擎逐个给出「用 X 搜索」按钮
    private var engineActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(SearchServiceManager.shared.activeBarEngines) { engine in
                    Button {
                        performWebSearch(engine)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: engine.systemImage)
                                .font(.system(size: 10))
                            Text("用 \(engine.name) 搜索")
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Theme.smallRadius).fill(Theme.cardBackground))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 2)
        }
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
        results = []
        hasSearched = false
    }

    /// 简单防抖（250ms），避免每敲一个字都触发全部检索源
    private func scheduleSearch() {
        generation += 1
        let current = generation
        let text = query
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []; hasSearched = false; isSearching = false
            return
        }
        isSearching = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard current == generation else { return }
            let items = await SearchHookRegistry.search(text)
            guard current == generation else { return }
            await MainActor.run {
                results = items
                hasSearched = true
                isSearching = false
            }
        }
    }
}
