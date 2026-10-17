import Foundation
import SystemConfiguration   // SCDynamicStore：主接口 BSD 名

// MARK: - STATS 深数据提供者（监测面板消费）
//
// 数据来源：FrsetStatsBar ObjC/C 模块的采集层（frset_stats_data.h，经桥接头直调）。
// 与菜单栏引擎（合并条）各自采样——引擎服务 g_snap/部件，本提供者服务 SwiftUI 面板详情行。
//
// 接入方式：MonitorSampler.sampleOnce() 在后台采样队列调用 refresh()（内部按成本节流），
// 视图经 `StatsDataProvider.shared.current` 只读快照（与 MonitorExtra 同款旁路模式，
// 不碰契约禁止修改的 MonitorSample）。SwiftUI 重绘由 sampler 的 tick 驱动。

// MARK: - 值类型

/// 进程排行项（CPU/内存/磁盘/网络 Top）
public struct StatsProcItem: Identifiable, Sendable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var cpu: Double        // 单核百分比（100 = 单核满载）
    public var memBytes: Double   // footprint 字节
    public var diskRead: Double   // B/s
    public var diskWrite: Double  // B/s

    public init(pid: Int32, name: String, cpu: Double, memBytes: Double, diskRead: Double, diskWrite: Double) {
        self.pid = pid; self.name = name
        self.cpu = cpu; self.memBytes = memBytes
        self.diskRead = diskRead; self.diskWrite = diskWrite
    }
}

/// 传感器项（含官方名表解析）
public struct StatsSensorItem: Sendable {
    public var key: String
    public var name: String       // 官方可读名（未收录回落 key）
    public var category: Int      // 0=温度 1=风扇 2=电压 3=电流 4=功率 5=能耗
    public var group: Int         // 0=sensor 1=CPU 2=GPU 3=system
    public var value: Double
}

/// 风扇项（多风扇：名称 + 转速 + 官方百分比）
public struct StatsFanItem: Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var name: String
    public var rpm: Double
    public var percent: Double    // 官方口径 (v-Mn)/(Mx-Mn)，0..1
}

/// NVMe SMART（disk0，C 层 30s 缓存）
public struct StatsSMART: Sendable {
    public var available: Bool
    public var temperatureC: Int
    public var life: Int              // 100 - percent_used
    public var powerCycles: Int
    public var powerOnHours: Int
    public var criticalWarning: Int   // 位掩码
    public var availableSpare: Int    // %
    public var totalRead: UInt64      // 字节
    public var totalWritten: UInt64
}

/// 电池全量（含 v27 电源适配器段）
public struct StatsBattery: Sendable {
    public var present: Bool
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var cycleCount: Int
    public var designCapacity: Int    // mAh
    public var maxCapacity: Int       // mAh
    public var currentCapacity: Int   // mAh
    public var temperature: Double    // °C
    public var voltageMv: Double
    public var amperageMa: Double     // 正=充电/输入
    // 电源适配器段（官方 Modules/Battery/readers.swift 同口径）
    public var adapterPowerW: Double      // SMC PDTR
    public var batteryPowerW: Double      // SMC PPBR（ARM）
    public var adapterVoltageV: Double    // IORegistry AdapterDetails
    public var adapterWatts: Double       // IOPSCopyExternalPowerAdapterDetails 标称
    public var chargingCurrentMa: Double  // IORegistry ChargerData
    public var chargingVoltageV: Double
}

/// 网络连通性（ICMP → 1.1.1.1，C 层后台线程 1 包/秒）
public enum StatsConnStatus: Int, Sendable {
    case unknown = -1
    case offline = 0
    case online = 1
}

/// 一帧深数据快照（线程安全容器内传递）
public struct StatsSnapshot: Sendable {
    // GPU
    public var gpuUsage: Double = -1        // -1=无数据
    public var gpuRenderer: Double = -1
    public var gpuTiler: Double = -1
    public var gpuModel: String = ""
    public var gpuTemperature: Double = 0   // TV*/TG* 最大值，0=无
    // CPU 集群（Apple Silicon；Intel 为 -1）
    public var cpuSuperCores: Int = -1
    public var cpuEffCores: Int = -1
    public var cpuMedCores: Int = -1
    public var clusterSuperUsage: Double = 0
    public var clusterEffUsage: Double = 0
    public var clusterMedUsage: Double = 0
    // 磁盘
    public var diskTotalBytes: UInt64 = 0
    public var diskFreeBytes: UInt64 = 0
    public var diskFileSystem: String = ""
    public var diskModel: String = ""
    public var diskInterconnect: String = ""
    public var smart: StatsSMART?
    // 内存构成（原版 Memory 卡：App/联动/压缩/可用 四段与压力等级）
    public var memTotal: UInt64 = 0
    public var memUsed: UInt64 = 0
    public var memWired: UInt64 = 0
    public var memCompressed: UInt64 = 0
    public var memSwapUsed: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level：1=正常 2=警告 4=严重 0=未知
    public var memPressureLevel: Int32 = 0
    // 网络
    public var connStatus: StatsConnStatus = .unknown
    public var connLatencyMs: Double = 0
    public var connJitterMs: Double = 0
    public var connAvgLatencyMs: Double = 0
    public var connAvgJitterMs: Double = 0
    /// 连通性历史（30×3=90 格，最新在末尾；1=通 0=不通 -1=未探测）
    public var connHistory: [Int] = []
    public var netInterface: String = ""
    public var netLocalIP: String = ""
    // 进程排行
    public var procCPU: [StatsProcItem] = []
    public var procMem: [StatsProcItem] = []
    public var procDisk: [StatsProcItem] = []
    public var procNet: [StatsProcItem] = []
    // 传感器（全量扫描，含官方名/类型/分组）
    public var sensors: [StatsSensorItem] = []
    public var fans: [StatsFanItem] = []
    // 传感器计算项（官方 initCalculatedSensors 口径：group∈{CPU,GPU} 且 type=温度 且 average 标记）
    public var calcAverageCPU: Double?
    public var calcHottestCPU: Double?
    public var calcAverageGPU: Double?
    public var calcHottestGPU: Double?
    // 电池
    public var battery: StatsBattery?
    public var batteryRemainSec: Double = -1   // -1=计算中 -2=接电源/无限
    // 心跳
    public var updatedAt: Date = Date()

    public init() {}
}

// MARK: - 提供者

public final class StatsDataProvider {
    public static let shared = StatsDataProvider()

    private let lock = NSLock()
    private var storage = StatsSnapshot()

    // 节流时间戳（systemUptime）
    private var lastProcAt: TimeInterval = -10
    private var lastScanAt: TimeInterval = -10
    private var lastSlowAt: TimeInterval = -10

    // 节流窗口（秒）
    private let procInterval: TimeInterval = 3     // 进程排行（单次 ~1s，最重）
    private let scanInterval: TimeInterval = 3     // SMC 全量扫描（IOKit）
    private let slowInterval: TimeInterval = 5     // 磁盘中频项

    private init() {}

    /// 当前快照（线程安全只读）
    public var current: StatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// 刷新一帧深数据。在**后台队列**调用（MonitorSampler 采样队列）。
    /// 内部按成本节流：GPU/电池/连通性每帧；SMC 扫描与进程 3s；磁盘中频 5s；
    /// SMART 由 C 层内部 30s 缓存（调用近乎免费）。
    public func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        var snap = storage
        lock.unlock()

        // ---- GPU（IOAccelerator，轻）----
        let gpuPtr = UnsafeMutablePointer<Double>.allocate(capacity: 3)
        defer { gpuPtr.deallocate() }
        if frset_gpu_usage(gpuPtr, gpuPtr + 1, gpuPtr + 2) == 0 {
            snap.gpuUsage = gpuPtr[0]
            snap.gpuRenderer = gpuPtr[1]
            snap.gpuTiler = gpuPtr[2]
        }
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { nameBuf.deallocate() }
        if frset_gpu_model(nameBuf, 128) == 0 {
            snap.gpuModel = String(cString: nameBuf)
        }

        // ---- CPU 集群拓扑（sysctl perflevel；Intel 返回非 0）----
        let clusterPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 3)
        defer { clusterPtr.deallocate() }
        if frset_cpu_clusters(clusterPtr, clusterPtr + 1, clusterPtr + 2) == 0 {
            snap.cpuSuperCores = Int(clusterPtr[0])
            snap.cpuEffCores = Int(clusterPtr[1])
            snap.cpuMedCores = Int(clusterPtr[2])
            // 集群占用（per_core 按集群顺序排列；需本层自采 CPU——C 层差分内部维护）
            let cpuPtr = UnsafeMutablePointer<frset_cpu_t>.allocate(capacity: 1)
            defer { cpuPtr.deallocate() }
            frset_cpu_sample(cpuPtr)
            let usagePtr = UnsafeMutablePointer<Double>.allocate(capacity: 3)
            defer { usagePtr.deallocate() }
            frset_cpu_cluster_usage(cpuPtr, clusterPtr[0], clusterPtr[1], clusterPtr[2],
                                    usagePtr, usagePtr + 1, usagePtr + 2)
            snap.clusterSuperUsage = usagePtr[0]
            snap.clusterEffUsage = usagePtr[1]
            snap.clusterMedUsage = usagePtr[2]
        }

        // ---- 内存构成（host_statistics64，轻；与 STATS 引擎同口径）----
        let memPtr = UnsafeMutablePointer<frset_mem_t>.allocate(capacity: 1)
        defer { memPtr.deallocate() }
        frset_mem_sample(memPtr)
        let mem = memPtr.pointee
        snap.memTotal = mem.total
        snap.memUsed = mem.used
        snap.memWired = mem.wired
        snap.memCompressed = mem.compressed
        snap.memSwapUsed = mem.swap_used
        snap.memPressureLevel = frset_mem_pressure()

        // ---- 电池（IORegistry，每帧；字段含 v27 适配器段）----
        let battPtr = UnsafeMutablePointer<frset_battery_t>.allocate(capacity: 1)
        defer { battPtr.deallocate() }
        frset_battery_sample(battPtr)
        let batt = battPtr.pointee
        snap.battery = StatsBattery(
            present: batt.present != 0,
            percent: Int(batt.percent),
            isCharging: batt.is_charging != 0,
            externalConnected: batt.external_connected != 0,
            fullyCharged: batt.fully_charged != 0,
            cycleCount: Int(batt.cycle_count),
            designCapacity: Int(batt.design_capacity),
            maxCapacity: Int(batt.max_capacity),
            currentCapacity: Int(batt.current_capacity),
            temperature: batt.temperature,
            voltageMv: batt.voltage_mv,
            amperageMa: batt.amperage_ma,
            adapterPowerW: batt.adapter_power_w,
            batteryPowerW: batt.battery_power_w,
            adapterVoltageV: batt.adapter_voltage_v,
            adapterWatts: batt.adapter_watts,
            chargingCurrentMa: batt.charging_current_ma,
            chargingVoltageV: batt.charging_voltage_v
        )
        snap.batteryRemainSec = frset_battery_remaining_sec()

        // ---- 网络连通性（C 层后台线程；本调用非阻塞读缓存）----
        let connPtr = UnsafeMutablePointer<frset_conn_t>.allocate(capacity: 1)
        defer { connPtr.deallocate() }
        frset_conn_sample(connPtr)
        let conn = connPtr.pointee
        snap.connStatus = StatsConnStatus(rawValue: Int(conn.status)) ?? .unknown
        snap.connLatencyMs = conn.latency_ms
        snap.connJitterMs = conn.jitter_ms
        snap.connAvgLatencyMs = conn.avg_latency_ms
        snap.connAvgJitterMs = conn.avg_jitter_ms
        let historyCount = Int(conn.history_count)
        if historyCount > 0 {
            withUnsafePointer(to: conn) { base in
                snap.connHistory = (0..<historyCount).map { Int(FSStatsConnHistoryAt(base, Int32($0))) }
            }
        }
        let ipBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        defer { ipBuf.deallocate() }
        frset_net_ip(ipBuf, 64)
        snap.netLocalIP = String(cString: ipBuf)
        snap.netInterface = StatsDataProvider.primaryInterfaceName()

        // ---- 磁盘中频项（5s）：容量/型号/连接/文件系统/SMART/网络 Top ----
        if now - lastSlowAt >= slowInterval {
            lastSlowAt = now
            let capPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
            defer { capPtr.deallocate() }
            frset_disk_capacity(capPtr, capPtr + 1)
            snap.diskTotalBytes = capPtr[0]
            snap.diskFreeBytes = capPtr[1]

            let diskBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
            defer { diskBuf.deallocate() }
            if frset_disk_model(diskBuf, 128) == 0 { snap.diskModel = String(cString: diskBuf) }
            if frset_disk_interconnect(diskBuf, 128) == 0 { snap.diskInterconnect = String(cString: diskBuf) }
            if let fs = FSStatsRootFileSystem() {
                snap.diskFileSystem = String(cString: fs).uppercased()
            }

            // SMART（C 层 30s 缓存）
            let smartPtr = UnsafeMutablePointer<frset_smart_t>.allocate(capacity: 1)
            defer { smartPtr.deallocate() }
            if frset_disk_smart(smartPtr) == 0 {
                let s = smartPtr.pointee
                snap.smart = StatsSMART(
                    available: s.available != 0,
                    temperatureC: Int(s.temperature_c),
                    life: Int(s.life),
                    powerCycles: Int(s.power_cycles),
                    powerOnHours: Int(s.power_on_hours),
                    criticalWarning: Int(s.critical_warning),
                    availableSpare: Int(s.available_spare),
                    totalRead: s.total_read,
                    totalWritten: s.total_written
                )
            }

            // 网络 Top 进程（nettop 差分；C 层后台 5s 一轮，此处读缓存）
            snap.procNet = StatsDataProvider.readProcList(kind: 3, max: 8)
        }

        // ---- SMC 全量扫描（3s）----
        if now - lastScanAt >= scanInterval {
            lastScanAt = now
            let sensorPtr = UnsafeMutablePointer<frset_sensor_t>.allocate(capacity: 600)
            defer { sensorPtr.deallocate() }
            let n = frset_smc_scan(sensorPtr, 600)
            var items: [StatsSensorItem] = []
            items.reserveCapacity(Int(n))
            var cpuTemps: [Double] = []
            var gpuTemps: [Double] = []
            for i in 0..<Int(n) {
                var raw = sensorPtr[i]
                let key = String(cString: FSStatsSensorKey(&raw))
                var groupOut: Int32 = 0
                let official = key.withCString { frset_sensor_name($0, &groupOut) }
                let name = official != nil ? String(cString: official!) : key
                let type = key.withCString { frset_sensor_type($0) }
                let group = key.withCString { frset_sensor_group($0) }
                let isAvg = key.withCString { frset_sensor_average($0) }
                items.append(StatsSensorItem(key: key, name: name, category: Int(type), group: Int(group), value: raw.value))
                // 计算项口径：group∈{CPU(1),GPU(2)} 且 type=温度(0) 且官方 average 标记
                if type == 0 && isAvg == 1 {
                    if group == 1 { cpuTemps.append(raw.value) }
                    if group == 2 { gpuTemps.append(raw.value) }
                }
            }
            snap.sensors = items
            snap.calcAverageCPU = cpuTemps.isEmpty ? nil : cpuTemps.reduce(0, +) / Double(cpuTemps.count)
            snap.calcHottestCPU = cpuTemps.max()
            snap.calcAverageGPU = gpuTemps.isEmpty ? nil : gpuTemps.reduce(0, +) / Double(gpuTemps.count)
            snap.calcHottestGPU = gpuTemps.max()
            // GPU 温度：TV*/TG* 最大值
            snap.gpuTemperature = items
                .filter { $0.category == 0 && ($0.key.hasPrefix("TV") || $0.key.hasPrefix("TG")) }
                .map(\.value).max() ?? 0
            // 多风扇：FNum + F{i}ID/F{i}Ac + 官方百分比
            snap.fans = StatsDataProvider.readFans()
        }

        // ---- 进程排行 CPU/内存/磁盘（3s，单次 ~1s）----
        if now - lastProcAt >= procInterval {
            lastProcAt = now
            snap.procCPU = StatsDataProvider.readProcList(kind: 0, max: 8)
            snap.procMem = StatsDataProvider.readProcList(kind: 1, max: 8)
            snap.procDisk = StatsDataProvider.readProcList(kind: 2, max: 8)
        }

        snap.updatedAt = Date()
        lock.lock()
        storage = snap
        lock.unlock()
    }

    // MARK: - 内部辅助

    /// 读一类进程排行（kind：0=CPU 1=内存 2=磁盘 3=网络）
    private static func readProcList(kind: Int, max: Int) -> [StatsProcItem] {
        let ptr = UnsafeMutablePointer<frset_proc_t>.allocate(capacity: max)
        defer { ptr.deallocate() }
        let n = frset_proc_top(Int32(kind), ptr, Int32(max))
        var items: [StatsProcItem] = []
        for i in 0..<Int(n) {
            var raw = ptr[i]
            items.append(StatsProcItem(
                pid: raw.pid,
                name: String(cString: FSStatsProcName(&raw)),
                cpu: raw.cpu,
                memBytes: raw.mem,
                diskRead: raw.disk_r,
                diskWrite: raw.disk_w
            ))
        }
        return items
    }

    /// 多风扇：数量（FNum）+ 名称（F{i}ID）+ 转速（F{i}Ac）+ 官方百分比 (v-Mn)/(Mx-Mn)
    private static func readFans() -> [StatsFanItem] {
        let fanCount = Int(frset_fan_count())
        guard fanCount > 0 else { return [] }
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 32)
        defer { nameBuf.deallocate() }
        var fans: [StatsFanItem] = []
        for i in 0..<fanCount {
            let idx = String(i)
            var name = "风扇 \(idx)"
            let idOK = "F\(idx)ID".withCString { frset_smc_read_string($0, nameBuf, 32) }
            if idOK == 0 {
                let read = String(cString: nameBuf)
                if !read.isEmpty { name = read }
            }
            let rpm = "F\(idx)Ac".withCString { frset_smc_read_key($0) }
            let min = "F\(idx)Mn".withCString { frset_smc_read_key($0) }
            let max = "F\(idx)Mx".withCString { frset_smc_read_key($0) }
            var percent = 0.0
            if !min.isNaN && !max.isNaN && max > min && !rpm.isNaN {
                percent = Swift.min(1, Swift.max(0, (rpm - min) / (max - min)))
            }
            fans.append(StatsFanItem(index: i, name: name, rpm: rpm.isNaN ? 0 : rpm, percent: percent))
        }
        return fans
    }

    /// 主网络接口 BSD 名（SCDynamicStore，官方 Net 模块同源）
    private static func primaryInterfaceName() -> String {
        guard let store = SCDynamicStoreCreate(nil, "FrsetNext" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = value["PrimaryInterface"] as? String else { return "" }
        return name
    }
}

// MARK: - 展示格式化（面板深数据行）

public enum StatsFormat {
    /// 三位小数电压（官方 %.3f V）
    public static func voltage(_ mv: Double) -> String {
        String(format: "%.3f V", mv / 1000)
    }

    /// 两位小数电流（官方 %.2f A）
    public static func amperage(_ ma: Double) -> String {
        String(format: "%.2f A", ma / 1000)
    }

    /// 两位小数功率（官方 %.2f W）
    public static func watts(_ w: Double) -> String {
        String(format: "%.2f W", w)
    }

    /// 能耗（官方 %.2f Wh）
    public static func wattHours(_ wh: Double) -> String {
        String(format: "%.2f Wh", wh)
    }

    /// 风扇转速
    public static func rpm(_ v: Double) -> String {
        "\(Int(v.rounded())) RPM"
    }

    /// 延迟/抖动（官方 %.2f ms）
    public static func ms(_ v: Double) -> String {
        String(format: "%.2f ms", v)
    }

    /// 容量 mAh
    public static func capacity(_ mah: Int) -> String {
        "\(mah) mAh"
    }

    /// 剩余时间（秒 → h m）
    public static func remaining(_ sec: Double) -> String {
        guard sec > 0 else { return "—" }
        let h = Int(sec) / 3600
        let m = (Int(sec) % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分钟"
    }
}
