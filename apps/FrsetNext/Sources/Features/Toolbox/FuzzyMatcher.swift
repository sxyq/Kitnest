import Foundation

// MARK: - FuzzyMatcher（FSearch 式模糊匹配引擎）
//
// 对标 GitHub 开源项目 FSearch（cboxdoerfer/fsearch，Windows「Everything」的
// 开源跨平台复刻）的核心搜索体验：
//   · 模糊匹配：query 与候选串按「子序列」匹配——字符按顺序出现即可命中，
//     不要求连续（"dcf" 也能命中 DocumentConverter.swift）；
//   · 即时精排：fzf 风格评分——连续匹配奖励、词边界奖励（分隔符/驼峰边界
//     后的首字符）、gap 惩罚（命中点越分散分越低）、靠前奖励。
// 返回命中字符的下标区间，供搜索结果行做「匹配高亮」（重点突出）。
//
// 与 FSearch 的实现差异（macOS 环境所致）：FSearch 启动时对全盘建内存索引后
// 即时过滤；我们借用系统 Spotlight（mdfind，毫秒级）做模糊预过滤，本地再精排，
// 效果等价且无需常驻后台索引进程。

public struct FuzzyMatch: Equatable {
    /// 综合得分（越大越相关，用于结果排序）
    public let score: Int
    /// 命中字符在目标串中的下标（升序，用于高亮）
    public let indices: [Int]

    public init(score: Int, indices: [Int]) {
        self.score = score
        self.indices = indices
    }
}

public enum FuzzyMatcher {

    /// 词边界字符（其后首字符视为词首，给予边界奖励）
    private static let boundaryCharacters: Set<Character> = [
        "/", ".", "_", "-", " ", "@", "#", "(", ")", "[", "]", "{", "}",
    ]

    /// 模糊匹配入口（大小写不敏感）。nil = 不匹配。
    public static func match(_ pattern: String, in target: String) -> FuzzyMatch? {
        let query = Array(pattern.lowercased())
        let lowered = Array(target.lowercased())
        guard !query.isEmpty, lowered.count >= query.count else { return nil }

        // 病态长查询（>32 字符）退化为精确子串直查，避免逐字回溯开销
        if query.count > 32 {
            guard let range = lowered.firstRange(of: query) else { return nil }
            return FuzzyMatch(score: 160 + query.count * 16, indices: Array(range))
        }

        // ① 贪心可行性：为 query 每个字符找「最早出现」位置
        var indices: [Int] = []
        indices.reserveCapacity(query.count)
        var cursor = 0
        for character in query {
            guard cursor < lowered.count,
                  let hit = lowered[cursor...].firstIndex(of: character) else { return nil }
            indices.append(hit)
            cursor = hit + 1
        }

        // ② 收紧：从最后一个命中点向前逐个「尽量前移」（不得越过前一个点的下界），
        //    得到整体最靠前、最紧凑的匹配——高亮更准确，评分也更高
        var upper = lowered.count
        for j in stride(from: query.count - 1, through: 0, by: -1) {
            let lowerBound = (j > 0 ? indices[j - 1] + 1 : 0)
            if lowerBound < upper,
               let better = lowered[lowerBound..<upper].firstIndex(of: query[j]) {
                indices[j] = better
            }
            upper = indices[j]
        }

        return FuzzyMatch(score: rate(indices: indices, original: Array(target)),
                          indices: indices)
    }

    /// 是否模糊命中（不关心得分与位置）
    ///
    /// v172（性能审阅）：原来直接 `match(...) != nil` —— 为了回答一个是非题，
    /// 会建 indices 数组、做收紧回溯、再转一次 `Array(target)` 算评分。
    /// 搜索面板每敲一个字对 200–800 条各调一次，这些全是白做。
    /// 这里走**纯子序列判定**：单趟扫描，零额外数组分配。
    public static func isMatch(_ pattern: String, in target: String) -> Bool {
        let query = pattern.lowercased()
        guard !query.isEmpty else { return false }
        var rest = query.makeIterator()
        guard var want = rest.next() else { return false }
        for ch in target.lowercased() where ch == want {
            guard let next = rest.next() else { return true }
            want = next
        }
        return false
    }

    // MARK: 评分（fzf 风格简化版，全整型）

    private static func rate(indices: [Int], original: [Character]) -> Int {
        var total = 16 * indices.count
        var streak = 0
        for (j, i) in indices.enumerated() {
            // 连续匹配奖励：连续段越长加成越多
            if j > 0, indices[j - 1] == i - 1 { streak += 1 } else { streak = 0 }
            total += streak * 8
            // 词边界奖励：串首 / 分隔符后 / 驼峰边界（如 "fS" 的 S）
            if i == 0 {
                total += 14
            } else {
                let previous = original[i - 1]
                if boundaryCharacters.contains(previous) {
                    total += 14
                } else if previous.isLowercase, original[i].isUppercase {
                    total += 10
                }
            }
            // 靠前奖励：命中越早越好（线性衰减，16 字符后归零）
            total += max(0, 8 - i / 2)
            // gap 惩罚：与前一命中点之间跨度越大越扣（单段上限 8）
            if j > 0 {
                let gap = i - indices[j - 1] - 1
                total -= min(gap, 8)
            }
        }
        return total
    }
}
