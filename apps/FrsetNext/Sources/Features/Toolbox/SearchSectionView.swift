import SwiftUI
import AppKit

// MARK: - 全局搜索区段（id "search", priority 5，排在主面板最前）
//
// 设计：本模块只提供 UI 与检索框架，真正的检索源由其他模块/总控通过 SearchHookRegistry 注入
// （避免直接引用剪贴板等模块的具體类型）。模块内置"工具名检索"作为默认数据源。

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
