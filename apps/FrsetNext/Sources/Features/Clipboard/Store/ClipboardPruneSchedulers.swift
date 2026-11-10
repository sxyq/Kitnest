import Foundation

// MARK: - 清理结果（v115：设置页「立即清理」需要反馈——此前删 0 条时零提示，
// 用户误以为按钮失效；实则按策略本就无可删，见接手清单 v115 诊断）

public struct ClipboardPruneResult {
    public let removed: Int
    public let reclaimedBytes: Int64

    public static let none = ClipboardPruneResult(removed: 0, reclaimedBytes: 0)
}

// MARK: - 时间保留期清理（05 号规格 B5 双调度之一）

/// 按保留天数清理：删除 timestamp 早于 (now - retentionDays) 的条目，**同步回收落盘文件**。
/// 默认 30 天（原作付费/免费分档已取消，取满档行为）。
public final class ClipboardHistoryRetentionPruneScheduler {

    public static let shared = ClipboardHistoryRetentionPruneScheduler()

    /// 触发间隔：每小时一次
    private static let interval: TimeInterval = 3600

    private var timer: Timer?
    private let repository = ClipboardRepository.shared
    private let preferences = Preferences.shared
    /// v210（修工程全图 P1-9）：清理是批量 SQL 删除 + 落盘文件回收，原先由 RunLoop.main 上的
    /// Timer 直接驱动 → 上千条时主线程冻结。改为专用串行队列，UI 只收结果。
    private let queue = DispatchQueue(label: "com.frsetnext.clipboard.prune.retention", qos: .utility)

    private init() {}

    /// 保留天数（可运行时调小即刻生效，由下一次 tick 执行）
    public var retentionDays: Int {
        max(0, preferences.value(Preferences.Keys.clipboardRetentionDays, default: 30))
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.pruneAsync()
        }
        RunLoop.main.add(timer!, forMode: .common)
        Log.info("clipboard", "保留期清理已启动：\(retentionDays) 天")
        pruneAsync()
    }

    /// 后台执行一次清理（主线程调用安全），结果回主线程
    public func pruneAsync(completion: ((ClipboardPruneResult) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.prune()
            guard let completion else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 单次清理：批量推进直到没有更早的条目。
    /// **必须在 prune 队列上调用**（或至少不在主线程）；对外请用 `pruneAsync`。
    @discardableResult
    public func prune() -> ClipboardPruneResult {
        let days = retentionDays
        guard days > 0 else { return .none }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        var reclaimed: Int64 = 0
        // v210（修 P1-9 后半）：批数兜底。delete 静默失败（库降级成内存库/句柄失效）时
        // rowsOlderThan 会一直返回同一批，`while true` 就变成死循环；每轮最多 200 批（4 万条）。
        var batches = 0
        while batches < 200 {
            batches += 1
            let batch = repository.rowsOlderThan(cutoff, limit: 200)
            if batch.isEmpty { break }
            for item in batch {
                reclaimed += Int64(item.storageBytes)
                repository.delete(dedupeKey: item.dedupeKey)
            }
            removed += batch.count
            if batch.count < 200 { break }
        }
        if batches >= 200 {
            Log.warn("clipboard", "保留期清理达到单轮上限（\(removed) 条），余量留待下一轮")
        }
        if removed > 0 {
            Log.info("clipboard", "保留期清理：删除 \(removed) 条（早于 \(cutoff)）")
            ClipboardManager.shared.reload()
        }
        return ClipboardPruneResult(removed: removed, reclaimedBytes: reclaimed)
    }
}

// MARK: - 容量上限清理（05 号规格 B5 双调度之二）

/// 按容量上限清理：用量超限时从**最旧**条目开始删，直到回落到 90% 水位（避免反复触发）。
/// 默认上限 2048 MB（Preferences.Keys.clipboardStorageLimitMB）。
public final class ClipboardStoragePruneScheduler {

    public static let shared = ClipboardStoragePruneScheduler()

    /// 触发间隔：每 10 分钟一次（配额回收不必太频繁）
    private static let interval: TimeInterval = 600
    /// 回落到上限的比例（滞回水位，防止抖动）
    private static let hysteresis: Double = 0.9

    private var timer: Timer?
    private let repository = ClipboardRepository.shared
    private let usage = ClipboardStorageUsageProvider.shared
    private let preferences = Preferences.shared
    /// v210（修工程全图 P1-9）：同上，容量清理也移出主线程——
    /// `usage.exceeds` 每轮都做 SQL SUM + 目录树遍历，比保留期清理更重。
    private let queue = DispatchQueue(label: "com.frsetnext.clipboard.prune.storage", qos: .utility)

    private init() {}

    public var limitBytes: Int64 {
        let mb = max(0, preferences.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048))
        return Int64(mb) * 1024 * 1024
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.pruneAsync()
        }
        RunLoop.main.add(timer!, forMode: .common)
        Log.info("clipboard", "容量清理已启动：上限 \(limitBytes / 1024 / 1024) MB")
        pruneAsync()
    }

    /// 后台执行一次清理（主线程调用安全），结果回主线程
    public func pruneAsync(completion: ((ClipboardPruneResult) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.prune()
            guard let completion else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 单次清理：从最旧开始删，直到回落到 90% 水位。
    /// **必须在 prune 队列上调用**；对外请用 `pruneAsync`。
    @discardableResult
    public func prune() -> ClipboardPruneResult {
        let limit = limitBytes
        guard limit > 0, usage.exceeds(limit) else { return .none }
        let target = Int64(Double(limit) * Self.hysteresis)
        var removed = 0
        var reclaimed: Int64 = 0
        // v126（性能审计 F0657）：循环条件改判据短路（exceeds）。
        // 原 `usage.totalBytes > target` 每批都做 1 次 SQL 全表 SUM + 5 次目录树遍历
        //（max(db, disk) 两侧都必须算完才能比较）；exceeds 用等价的 OR 短路——
        // 仅当数据库口径未超限时才去遍历目录，清理循环的计量开销降一个数量级。
        while usage.exceeds(target) {
            let batch = repository.oldestRows(limit: 200)
            if batch.isEmpty { break }
            // 先删文件再删行：即便事务失败也不会留下孤儿文件
            for item in batch {
                reclaimed += Int64(item.storageBytes)
                repository.delete(dedupeKey: item.dedupeKey)
            }
            removed += batch.count
            if batch.count < 200 { break }
        }
        if removed > 0 {
            Log.info("clipboard", "容量清理：删除 \(removed) 条，当前用量 \(usage.totalBytes / 1024 / 1024) MB")
            ClipboardManager.shared.reload()
        }
        return ClipboardPruneResult(removed: removed, reclaimedBytes: reclaimed)
    }
}
