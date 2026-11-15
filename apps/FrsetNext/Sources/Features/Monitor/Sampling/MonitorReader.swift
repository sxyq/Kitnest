import Foundation
import IOKit
import IOKit.ps
import Darwin

/// 一次采样中不进入公共 MonitorSample 的补充字段（Models 由总控维护，此处用旁路容器承载）。
public struct MonitorReadResult {
    public var sample: MonitorSample
    public var compressedMemory: UInt64

    public init(sample: MonitorSample, compressedMemory: UInt64) {
        self.sample = sample
        self.compressedMemory = compressedMemory
    }
}

/// MonitorSample 之外的扩展指标容器：由 MonitorSampler 每次采样后写入，视图只读。
///
/// 这样避免修改 Models/MonitorSample（契约禁止），同时保证详情面板能显示峰值/累计等数据。
public enum MonitorExtra {
    private static let lock = NSLock()
    private static var storage = Snapshot()

    public struct Snapshot {
        /// 网络累计收发字节（自启动以来）
        public var netTotalIn: UInt64 = 0
        public var netTotalOut: UInt64 = 0
        /// 网络速率峰值（bytes/s）
        public var netPeakDownload: UInt64 = 0
        public var netPeakUpload: UInt64 = 0
        /// 磁盘速率峰值（bytes/s）
        public var diskPeakRead: UInt64 = 0
        public var diskPeakWrite: UInt64 = 0
        /// 压缩内存字节
        public var compressedMemory: UInt64 = 0
        /// 平均负载（1/5/15 分钟）
        public var loadAverages: [Double] = [0, 0, 0]
        /// 最后一次采样的时间戳
        public var updatedAt: Date = Date()
    }

    public static var current: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    static func update(_ mutate: (inout Snapshot) -> Void) {
        lock.lock()
        mutate(&storage)
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        storage = Snapshot()
        lock.unlock()
    }
}

/// MonitorSample 的只读便捷属性（数据来自 MonitorExtra 旁路容器）
public extension MonitorSample {
    /// 压缩内存字节数
    var compressedMemory: UInt64 { MonitorExtra.current.compressedMemory }
    /// 1 分钟平均负载
    var loadAverage1m: Double { MonitorExtra.current.loadAverages.first ?? 0 }
    /// 5 分钟平均负载
    var loadAverage5m: Double { MonitorExtra.current.loadAverages.count > 1 ? MonitorExtra.current.loadAverages[1] : 0 }
    /// 15 分钟平均负载
    var loadAverage15m: Double { MonitorExtra.current.loadAverages.count > 2 ? MonitorExtra.current.loadAverages[2] : 0 }
    /// 本次采样之后的累计下载字节
    var netTotalDownload: UInt64 { MonitorExtra.current.netTotalIn }
    /// 本次采样之后的累计上传字节
    var netTotalUpload: UInt64 { MonitorExtra.current.netTotalOut }
}

/// 使用系统 API 直接读取性能指标；单个指标失败不影响其他指标。
///
/// - CPU：`host_processor_info` 差分（system/user/idle/nice + 每核）
/// - 内存：`host_statistics64`（used/compressed/swap/压力）
/// - 网络：`getifaddrs` 计数器差分算 bytes/s
/// - 磁盘：IOKit `IOBlockStorageDriver` 统计差分（读不到降级为 0）
/// - 温度：复用 StatsDataProvider 已扫描的 SMC 快照
/// - 电池：IOKit `IOPSCopyPowerSourcesInfo`
public final class MonitorReader {
    /// CPU tick 快照（用于差分）
    private struct CPUTicks {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0
    }

    private struct MemoryReading {
        var used: UInt64 = 0
        var total: UInt64 = ProcessInfo.processInfo.physicalMemory
        var pressure: Double = 0
        var compressed: UInt64 = 0
        var swapUsed: UInt64 = 0
    }

    private struct IOCounters {
        var read: UInt64 = 0
        var written: UInt64 = 0
        var timestamp: TimeInterval = 0
    }


    private var previousCPUTicks: [CPUTicks]?
    private var previousNetwork: IOCounters?
    private var previousDisk: IOCounters?

    /// 是否读取温度（关闭时完全跳过 SMC，零开销）
    public var temperatureEnabled: Bool = true

    public init() {}

    // MARK: - 对外入口
    // v126（性能审计 F0857）：删除 readSample() 薄包装（`readResult().sample`），
    // 全仓零调用方（MonitorSampler 直接走 readResult(needFull:)），属真死代码。

    /// 采集一帧，并附带 MonitorSample 之外的补充字段。
    /// - Parameter needFull: **v125 性能优化（审计 F0858/F0860/F0861/F0864/F0866）**——
    ///   `sampleOnce` 路径里 CPU / 内存已用 / 网络 / 磁盘 / 电池 5 组结果随后会被
    ///   C 引擎 0.5s 快照 `g_snap` 整体覆盖（见 MonitorSampler.sampleOnce），
    ///   属冗余计算（实测 0.7ms/tick）。`needFull = false` 时**跳过这 5 路采集**，
    ///   只留 g_snap 不提供的字段：温度 / 功耗 / 内存压力 / 交换 / 压缩内存。
    ///   `needFull = true`（默认）保持原全量行为，供 g_snap 无效时兜底。
    public func readResult(needFull: Bool = true) -> MonitorReadResult {
        var sample = MonitorSample()

        // —— 以下 5 组会被 g_snap 覆盖：仅 needFull 时才采 ——
        var memory = MemoryReading()
        if needFull {
            let cpu = readCPU()
            sample.cpuUsage = cpu.usage
            sample.systemCPU = cpu.system
            sample.userCPU = cpu.user
            sample.idleCPU = cpu.idle
            sample.perCore = cpu.perCore

            memory = readMemory()
            sample.memoryUsed = memory.used
            sample.memoryTotal = memory.total
            sample.memoryPressure = memory.pressure
            sample.swapUsed = memory.swapUsed

            let network = readNetworkRate()
            sample.netUpload = network.upload
            sample.netDownload = network.download

            let disk = readDiskRate()
            sample.diskRead = disk.read
            sample.diskWrite = disk.written

            sample.batteryLevel = readBatteryLevel()
        } else {
            // 只取 g_snap 不覆盖的内存侧字段（压力/交换/压缩）
            memory = readMemory()
            sample.memoryPressure = memory.pressure
            sample.swapUsed = memory.swapUsed
        }

        // —— 以下 g_snap 不提供，恒采 ——
        sample.temperatures = temperatureEnabled ? readTemperatures() : [:]
        readPower(into: &sample)

        return MonitorReadResult(sample: sample, compressedMemory: memory.compressed)
    }

    /// 平均负载（1/5/15 分钟）
    func loadAverages() -> [Double] {
        readLoadAverages()
    }

    // MARK: - CPU

    private func readCPU() -> (usage: Double, system: Double, user: Double, idle: Double, perCore: [Double]) {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        )
        guard status == KERN_SUCCESS, let info = cpuInfo, cpuCount > 0 else {
            return (0, 0, 0, 1, [])
        }
        defer {
            let byteCount = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), byteCount)
        }

        var current: [CPUTicks] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let offset = core * Int(CPU_STATE_MAX)
            current.append(CPUTicks(
                user: UInt64(max(0, info[offset + Int(CPU_STATE_USER)])),
                system: UInt64(max(0, info[offset + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(max(0, info[offset + Int(CPU_STATE_IDLE)])),
                nice: UInt64(max(0, info[offset + Int(CPU_STATE_NICE)]))
            ))
        }

        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks, previous.count == current.count else {
            return (0, 0, 0, 1, Array(repeating: 0, count: current.count))
        }

        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for (now, old) in zip(current, previous) {
            let user = delta(now.user, old.user) + delta(now.nice, old.nice)
            let system = delta(now.system, old.system)
            let idle = delta(now.idle, old.idle)
            let total = user + system + idle
            totalUser += user
            totalSystem += system
            totalIdle += idle
            perCore.append(total > 0 ? clamp(Double(user + system) / Double(total)) : 0)
        }

        let total = totalUser + totalSystem + totalIdle
        guard total > 0 else { return (0, 0, 0, 1, perCore) }
        let user = clamp(Double(totalUser) / Double(total))
        let system = clamp(Double(totalSystem) / Double(total))
        let idle = clamp(Double(totalIdle) / Double(total))
        return (clamp(user + system), system, user, idle, perCore)
    }

    // MARK: - 内存 / Swap / 负载

    private func readMemory() -> MemoryReading {
        var result = MemoryReading()
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return result }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { buffer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, buffer, &count)
            }
        }
        guard status == KERN_SUCCESS else { return result }

        let page = UInt64(pageSize)
        let active = UInt64(statistics.active_count) * page
        let inactive = UInt64(statistics.inactive_count) * page
        let wired = UInt64(statistics.wire_count) * page
        let compressed = UInt64(statistics.compressor_page_count) * page
        let purgeable = UInt64(statistics.purgeable_count) * page
        let rawUsed = active + inactive + wired + compressed
        result.used = min(result.total, rawUsed > purgeable ? rawUsed - purgeable : rawUsed)
        result.compressed = compressed
        result.pressure = result.total > 0 ? clamp(Double(result.used) / Double(result.total)) : 0
        result.swapUsed = MemoryBreakdownReader.readSwapUsed()
        return result
    }

    private func readLoadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = values.withUnsafeMutableBufferPointer { buffer in
            getloadavg(buffer.baseAddress, Int32(buffer.count))
        }
        guard count >= 0 else { return [0, 0, 0] }
        return values.map { $0.isFinite ? $0 : 0 }
    }

    // MARK: - 网络（getifaddrs 差分）

    private func readNetworkCounters() -> IOCounters {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let head = firstAddress else {
            return IOCounters()
        }
        defer { freeifaddrs(head) }

        var incoming: UInt64 = 0
        var outgoing: UInt64 = 0
        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let pointer = cursor {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, let data = entry.ifa_data {
                let name = String(cString: entry.ifa_name)
                if seen.insert(name).inserted {
                    let counters = data.assumingMemoryBound(to: if_data.self).pointee
                    incoming &+= UInt64(counters.ifi_ibytes)
                    outgoing &+= UInt64(counters.ifi_obytes)
                }
            }
            cursor = entry.ifa_next
        }
        return IOCounters(
            read: incoming,
            written: outgoing,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }


    private func readNetworkRate() -> (upload: UInt64, download: UInt64) {
        let current = readNetworkCounters()
        let now = current.timestamp
        defer { previousNetwork = current }
        guard let previous = previousNetwork else { return (0, 0) }
        let elapsed = max(0.001, now - previous.timestamp)
        return (
            rate(delta(current.written, previous.written), elapsed: elapsed),
            rate(delta(current.read, previous.read), elapsed: elapsed)
        )
    }

    // MARK: - 磁盘（IOKit 统计差分，读不到降级为 0）

    private func readDiskRate() -> (read: UInt64, written: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return (0, 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWritten: UInt64 = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["Statistics"] as? [String: Any] else { continue }
            totalRead &+= uint64Value(statistics["Bytes (Read)"])
            totalWritten &+= uint64Value(statistics["Bytes (Write)"])
        }

        let current = IOCounters(
            read: totalRead,
            written: totalWritten,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        defer { previousDisk = current }
        guard let previous = previousDisk else { return (0, 0) }
        let elapsed = max(0.001, current.timestamp - previous.timestamp)
        return (
            rate(delta(totalRead, previous.read), elapsed: elapsed),
            rate(delta(totalWritten, previous.written), elapsed: elapsed)
        )
    }

    // MARK: - 温度（共用既有 SMC 全量扫描快照）

    private func readTemperatures() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: StatsDataProvider.shared.current.sensors
            .filter { $0.category == 0 }.map { ($0.key, $0.value) })
    }

    // MARK: - 电池

    private func readBatteryLevel() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey as String] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }
            return clamp(current.doubleValue / maximum.doubleValue)
        }
        return nil
    }

    // MARK: - 功率（与菜单栏共用每秒缓存）

    /// 整机始终是 PSTR 系统负载；输入功率独立显示，CPU/GPU 为区间能量差分。
    private func readPower(into sample: inout MonitorSample) {
        var power = frset_power_t()
        frset_power_sample(&power)
        let watts = { (value: Double) -> Double? in value.isFinite && value >= 0 ? value : nil }
        sample.powerWatts = watts(power.system_w)
        sample.inputPowerWatts = watts(power.input_w)
        sample.cpuPowerWatts = watts(power.cpu_w)
        sample.gpuPowerWatts = watts(power.gpu_w)
        sample.anePowerWatts = watts(power.ane_w)
        sample.ramPowerWatts = watts(power.ram_w)
        sample.dcsPowerWatts = watts(power.dcs_w)
        sample.chipPowerWatts = watts(power.chip_w)
        sample.powerIsInput = false
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        sample.externalPower = (prop("ExternalConnected") as? Bool) ?? false
        sample.isCharging = (prop("IsCharging") as? Bool) ?? false
    }

    // MARK: - 工具

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func rate(_ bytes: UInt64, elapsed: TimeInterval) -> UInt64 {
        guard elapsed > 0, elapsed.isFinite else { return 0 }
        let value = Double(bytes) / elapsed
        guard value.isFinite, value >= 0 else { return 0 }
        return UInt64(min(Double(UInt64.max), value))
    }

    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private func uint64Value(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber { return number.uint64Value }
        if let number = value as? UInt64 { return number }
        return 0
    }

}
