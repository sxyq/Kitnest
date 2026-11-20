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
        storage[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
        filled = min(capacity, filled + 1)
    }

    /// 按时间顺序写入调用方的复用缓冲；满环先复制较早的一段，再接较新的一段。
    public func values(into buffer: inout [Double]) {
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(filled)
        if filled == capacity {
            buffer.append(contentsOf: storage[writeIndex...])
        }
        buffer.append(contentsOf: storage[..<writeIndex])
    }

    public var count: Int { filled }

    public var last: Double { filled == 0 ? 0 : storage[(writeIndex - 1 + capacity) % capacity] }

}
