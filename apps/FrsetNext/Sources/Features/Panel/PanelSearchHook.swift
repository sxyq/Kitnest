import Foundation
import Combine

/// 面板顶部搜索框钩子。
/// 本期只做 UI + 本地剪贴板文本过滤（直接查 Storage 层 clipboard.sqlite，
/// 不引用 Clipboard 模块类型）；后续检索可由其他模块经注册表接管。
public final class PanelSearchHook: ObservableObject {
    public static let shared = PanelSearchHook()

    /// 搜索框当前文本（面板 SwiftUI 根视图双向绑定）
    @Published public var query: String = ""
    /// 最近一次过滤结果（随 query 变化由视图触发刷新，避免视图内持有 @Stored）
    @Published public var results: [SearchResult] = []

    public struct SearchResult: Identifiable {
        public let id = UUID()
        public let title: String
        public let snippet: String
        public let timestamp: Date
    }

    private init() {}

    /// 以当前 query 过滤本地剪贴板文本条目并更新 results
    public func performSearch() {
        results = search(query)
    }

    /// 过滤本地剪贴板文本条目（LIKE 匹配 title/content）
    public func search(_ raw: String) -> [SearchResult] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // 转义 LIKE 通配符，避免用户输入 %/_ 引发全表匹配异常
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let like = "%\(escaped)%"
        let sql = """
        SELECT IFNULL(title,'') AS t, IFNULL(content,'') AS c, timestamp AS ts
        FROM clipboard_items
        WHERE type = 'text'
          AND (content LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')
        ORDER BY timestamp DESC
        LIMIT 30;
        """
        do {
            let rows = try DatabaseManager.shared.clipboard.query(sql, [.text(like), .text(like)])
            return rows.map { r in
                let content = r.string("c") ?? ""
                let title = r.string("t") ?? ""
                return SearchResult(
                    title: title.isEmpty ? content.truncatedForDisplay : title,
                    snippet: content.truncatedForDisplay,
                    timestamp: Date(timeIntervalSince1970: r.real("ts")))
            }
        } catch {
            Log.warn("Panel", "剪贴板搜索失败: \(error)")
            return []
        }
    }
}
