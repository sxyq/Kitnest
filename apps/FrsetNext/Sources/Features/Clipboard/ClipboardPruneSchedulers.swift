import Foundation

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

    private init() {}

    /// 保留天数（可运行时调小即刻生效，由下一次 tick 执行）
    public var retentionDays: Int {
        max(0, preferences.value(Preferences.Keys.clipboardRetentionDays, default: 30))
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.prune()
        }
        RunLoop.main.add(timer!, forMode: .common)
        Log.info("clipboard", "保留期清理已启动：\(retentionDays) 天")
        prune()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 单次清理：批量推进直到没有更早的条目
    public func prune() {
        let days = retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        while true {
            let batch = repository.rowsOlderThan(cutoff, limit: 200)
            if batch.isEmpty { break }
            for item in batch { repository.delete(dedupeKey: item.dedupeKey) }
            removed += batch.count
            if batch.count < 200 { break }
        }
        if removed > 0 {
            Log.info("clipboard", "保留期清理：删除 \(removed) 条（早于 \(cutoff)）")
            ClipboardManager.shared.reload()
        }
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

    private init() {}

    public var limitBytes: Int64 {
        let mb = max(0, preferences.value(Preferences.Keys.clipboardStorageLimitMB, default: 2048))
        return Int64(mb) * 1024 * 1024
    }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.prune()
        }
        RunLoop.main.add(timer!, forMode: .common)
        Log.info("clipboard", "容量清理已启动：上限 \(limitBytes / 1024 / 1024) MB")
        prune()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func prune() {
        let limit = limitBytes
        guard limit > 0 else { return }
        let target = Int64(Double(limit) * Self.hysteresis)
        var removed = 0
        while usage.totalBytes > target {
            let batch = repository.oldestRows(limit: 200)
            if batch.isEmpty { break }
            // 先删文件再删行：即便事务失败也不会留下孤儿文件
            for item in batch {
                repository.delete(dedupeKey: item.dedupeKey)
            }
            removed += batch.count
            if batch.count < 200 { break }
        }
        if removed > 0 {
            Log.info("clipboard", "容量清理：删除 \(removed) 条，当前用量 \(usage.totalBytes / 1024 / 1024) MB")
            ClipboardManager.shared.reload()
        }
    }
}
