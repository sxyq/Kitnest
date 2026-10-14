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
        guard filled > 0 else { return [] }
        var result: [Double] = []
        result.reserveCapacity(filled)
        for offset in 0..<filled {
            let index = (writeIndex - filled + offset + capacity * 2) % capacity
            result.append(storage[index])
        }
        return result
    }

    public var count: Int { filled }

    public var last: Double { filled == 0 ? 0 : storage[(writeIndex - 1 + capacity) % capacity] }

    public mutating func reset() {
        storage = [Double](repeating: 0, count: capacity)
        writeIndex = 0
        filled = 0
    }
}
