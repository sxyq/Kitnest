import Darwin
import Foundation

// ============================================================================
// 内存分类统计（活动监视器口径）
//
// 独立于 MonitorSample（契约禁止扩展该结构）：优化前后对比需要 wired / cached /
// pressure 这些原始字段，而现有 MonitorSample 只有 used/total/swap。
// ============================================================================

public struct MemoryBreakdown: Sendable, Equatable {
    public var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    /// App Memory = internal_page_count - purgeable_count
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    /// Cached Files = external_page_count
    public var cached: UInt64 = 0
    public var swapUsed: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level：1 normal / 2 warning / 4 critical
    public var pressureLevel: Int32 = 1

    public var used: UInt64 { app + wired + compressed }
    public var available: UInt64 { total - min(total, used + cached) }
    public var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }
    public var pressure: MemoryPressureLevel { MemoryPressureLevel(rawValue: pressureLevel) ?? .normal }
}

public enum MemoryPressureLevel: Int32, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var title: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }
}

public enum MemoryBreakdownReader {
    public static func read() -> MemoryBreakdown {
        var result = MemoryBreakdown()
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return result }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        let internalPages = UInt64(statistics.internal_page_count)
        let purgeablePages = UInt64(statistics.purgeable_count)
        result.app = (internalPages - min(internalPages, purgeablePages)) * page
        result.wired = UInt64(statistics.wire_count) * page
        result.compressed = UInt64(statistics.compressor_page_count) * page
        result.cached = UInt64(statistics.external_page_count) * page
        result.swapUsed = readSwapUsed()
        result.pressureLevel = readPressureLevel()
        return result
    }

    static func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    static func readPressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return level
    }
}
