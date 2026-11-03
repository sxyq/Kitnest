import Foundation

/// 迷你折线/柱状使用的环形缓冲（保留最近 capacity 个点）
public struct MonitorHistoryBuffer {
    private var storage: [Double]
    private var writeIndex: Int = 0
    private var filled: Int = 0
    public let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
        self.storage = [Double](repeating: 0, count: max(1, capacity))
    }

    public mutating func append(_ value: Double) {
        storage[writeIndex] = value.isFinite ? value : 0
        writeIndex = (writeIndex + 1) % capacity
        filled = min(capacity, filled + 1)
    }

    /// 按时间顺序返回（旧 → 新）
    public func values() -> [Double] {
        var result: [Double] = []
        values(into: &result)
        return result
    }

    /// v129（内存）：写入调用方缓冲（容量复用）——values() 每 tick 为 7 个缓冲各建
    /// 一个新 [Double]（60×8B+头 ≈ 512B × 7/tick），是 32B/48B 小块直方图峰值的
    /// 稳定churn 源；调用方持双缓冲轮换时，旧快照释放后即回到原地写、零分配。
    public func values(into buffer: inout [Double]) {
        buffer.removeAll(keepingCapacity: true)
        guard filled > 0 else { return }
        buffer.reserveCapacity(filled)
        for offset in 0..<filled {
            let index = (writeIndex - filled + offset + capacity * 2) % capacity
            buffer.append(storage[index])
        }
    }

    public var count: Int { filled }

    public var last: Double { filled == 0 ? 0 : storage[(writeIndex - 1 + capacity) % capacity] }

    public mutating func reset() {
        storage = [Double](repeating: 0, count: capacity)
        writeIndex = 0
        filled = 0
    }
}
