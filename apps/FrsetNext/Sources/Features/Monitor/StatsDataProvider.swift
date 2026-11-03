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
    /// 展开状态用的稳定键：bundle 路径（无 bundle 时用进程名）。
    /// 不能用 pid——组内排序会把「第一个 pid」换人，导致展开状态每次刷新都跳。
    public var groupKey: String { iconPath.isEmpty ? name : iconPath }
    public var pid: Int32
    public var name: String
    public var cpu: Double        // 单核百分比（100 = 单核满载）
    public var memBytes: Double   // footprint 字节
    public var diskRead: Double   // B/s
    public var diskWrite: Double  // B/s
    /// 同 App 合并后的全部 pid（单进程 = [pid]；「退出」时全杀）
    public var pids: [Int32]
    /// v86：图标来源路径——宿主的 `.app` 完整路径（无 bundle 的进程为可执行文件路径）。
    /// 由 C 层进程路径按 `.app/` 截取，不再按进程名猜图标（猜测是图标显示错误的根因）。
    public var iconPath: String
    /// v84（用户需求「进程展开查看明细」）：组内子进程明细（已按当前维度降序）。
    /// 归类行 = 某 App 的全部 Helper/Renderer 合并；children 保留每个子进程的原始名与用量，
    /// 供 UI 展开查看「到底哪个渲染进程占得多」。单进程组为空数组。
    public var children: [StatsProcItem]

    public init(pid: Int32, name: String, cpu: Double, memBytes: Double, diskRead: Double, diskWrite: Double,
                pids: [Int32]? = nil, iconPath: String = "", children: [StatsProcItem] = []) {
        self.pid = pid; self.name = name
        self.cpu = cpu; self.memBytes = memBytes
        self.diskRead = diskRead; self.diskWrite = diskWrite
        self.pids = pids ?? [pid]
        self.iconPath = iconPath
        self.children = children
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

    /// 性能探针开关（FRSET_PERF_PROBE=1）：仅性能测试时打开
    static let perfProbe = ProcessInfo.processInfo.environment["FRSET_PERF_PROBE"] != nil

    private let lock = NSLock()
    private var storage = StatsSnapshot()

    // v129（内存）：connHistory 双缓冲（见 refresh 内注释；仅采样队列单线程访问）
    private var connScratchA: [Int] = []
    private var connScratchB: [Int] = []
    private var connScratchIndex = 0

    // 节流时间戳（systemUptime）
    private var lastProcAt: TimeInterval = -10
    private var lastScanAt: TimeInterval = -10
    private var lastSlowAt: TimeInterval = -10

    // 节流窗口（秒）
    // 2026-10-20 性能实测：SMC 全量扫描单次 ~103ms（占 refresh 的 82%），
    // 而传感器/风扇只被监测面板消费——面板不可见时没必要 3s 扫一次。
    // 改为按 UI 可见性分档：可见 5s / 隐藏 30s；进程排行同理（隐藏 15s）。
    // v128（CPU 优化）：slow 档同样按可见性分档（原固定 5s）——隐藏时磁盘容量/
    // 型号/SMART/网络 Top 这批中频项降到 30s（见 refresh 内 slowInterval）。

    /// 传感器静态元数据缓存（key → 官方名/类型/分组/是否参与均值）
    /// 600 个传感器每次扫描要查 4 次映射函数（2400 次 C 字符串查找），
    /// 而映射是静态表——缓存后只在首次扫描付一次成本。
    /// v129（内存）：缓存里同时存 interned key/name String——原来每轮扫描都
    /// `String(cString:)` 新建 600 个 key（4 字符小串也走 StringStorage 路径）
    /// 再连同 name 一起塞进新 items 数组，5s/30s 一轮是 non-object 小块的
    /// 稳定churn 源；intern 后同 key 共享同一 String 存储，稳态零新建。
    private struct SensorMeta {
        let key: String
        let name: String
        let type: Int32
        let group: Int32
        let isAvg: Int32
    }
    private var sensorMeta: [String: SensorMeta] = [:]

    private init() {}

    /// 当前快照（线程安全只读）
    public var current: StatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// 刷新一帧深数据。在**后台队列**调用（MonitorSampler 采样队列）。
    /// 内部按成本节流：GPU/电池/连通性每帧；磁盘中频 5s；
    /// SMC 扫描 / 进程排行按 UI 可见性分档（可见 5s/3s，隐藏 30s/15s）。
    /// SMART 由 C 层内部 30s 缓存（调用近乎免费）。
    /// v128（CPU 优化）补充：slow 档（磁盘中频项/网络 Top）同样按可见性分档
    /// （可见 5s / 隐藏 30s）；GPU / CPU 集群 / 电池全量这类 IOKit 扫描可见时每帧、
    /// 隐藏时并入 slow 档；磁盘型号/连接/文件系统是静态信息只取一次；
    /// 后台 ICMP/nettop 采样线程随可见性暂停（frset_conn_set_active /
    /// frset_net_top_set_active）。
    /// - Parameter uiActive: 监测面板/设置页是否可见（决定重活频率）
    public func refresh(uiActive: Bool = true) {
        let procInterval: TimeInterval = uiActive ? 3 : 15
        let scanInterval: TimeInterval = uiActive ? 5 : 30
        // v128：slow 档可见 5s / 隐藏 30s（原固定 5s，隐藏时白采）
        let slowInterval: TimeInterval = uiActive ? 5 : 30
        let now = ProcessInfo.processInfo.systemUptime
        // v128：slow 档是否到期（在 slow 块改写 lastSlowAt 之前先算好，
        // 供 GPU/集群/电池这些重活共享同一节拍）
        let slowDue = now - lastSlowAt >= slowInterval
        // v128：重活（IOKit 扫描类）——可见时每帧保实时；隐藏时与 slow 档同频
        let heavyDue = uiActive || slowDue
        // v128（CPU 优化）：后台采样线程可见性开关。conn（1 包/秒 ICMP）与
        // nettop（每 5s popen 子进程实测 ~1s）只被面板消费，隐藏即暂停。
        //
        // v191（用户：「应该就一直放在那，只是它会变化它显示的那个 App」）：
        // nettop 默认改常驻——不打开面板也在累计 10 分钟窗口，打开即有数据。
        // 代价是每 5s 一个 nettop 子进程；设置 → 监测 → 网络 可关掉。
        frset_conn_set_active(uiActive ? 1 : 0)
        frset_net_top_set_active((uiActive || MonitorPreferences.networkKeepAlive) ? 1 : 0)
        // 性能探针（FRSET_PERF_PROBE=1）：分段计时，定位阻塞段；生产零日志
        let probe = Self.perfProbe
        var tPrev = DispatchTime.now().uptimeNanoseconds
        func mark(_ label: String) {
            guard probe else { return }
            let t = DispatchTime.now().uptimeNanoseconds
            Log.info("Perf", String(format: "refresh.%@ %.2fms", label, Double(t - tPrev) / 1_000_000))
            tPrev = t
        }
        lock.lock()
        var snap = storage
        lock.unlock()

        // ---- GPU（IOAccelerator，轻）----
        // 先清零：C 层只在对应键存在时写值，未命中会保留下未初始化的垃圾
        // （M 系列偶发缺 "Tiler Utilization %"）。0 = 无占用，-1 才是无数据。
        // v128：IOAccelerator 属性读取是 IOKit 注册表扫描，隐藏时并入 slow 档。
        if heavyDue {
            let gpuPtr = UnsafeMutablePointer<Double>.allocate(capacity: 3)
            defer { gpuPtr.deallocate() }
            gpuPtr.initialize(repeating: 0, count: 3)
            if frset_gpu_usage(gpuPtr, gpuPtr + 1, gpuPtr + 2) == 0 {
                snap.gpuUsage = gpuPtr[0]
                snap.gpuRenderer = gpuPtr[1]
                snap.gpuTiler = gpuPtr[2]
            }
        }
        let nameBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { nameBuf.deallocate() }
        if snap.gpuModel.isEmpty, frset_gpu_model(nameBuf, 128) == 0 {
            // 型号是静态信息，只取一次；此前每帧 String(cString:) 重建
            snap.gpuModel = String(cString: nameBuf)
        }

        mark("gpu")

        // ---- CPU 集群拓扑（sysctl perflevel；Intel 返回非 0）----
        // v128：含 host_processor_info 自采（系统调用），隐藏时并入 slow 档
        if heavyDue {
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
        }

        mark("cpuCluster")

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

        mark("mem")

        // ---- 电池（IORegistry，每帧；字段含 v27 适配器段）----
        // v128：AppleSmartBattery 属性字典读取（~30 键 + 2 次 SMC 单键）属 IOKit
        // 扫描，隐藏时并入 slow 档（g_snap 的 1s 电池采样不受影响，状态栏照常）
        if heavyDue {
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
        }

        mark("battery")

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
            // v129（内存）：connHistory 双缓冲复用——原来每帧 map 出新 [Int]（90×8B
            // + 数组头），refresh 每 0.5~1.5s 一帧是稳定小块churn；交替**原地**回填
            // 另一份 scratch（上一份此时已被 storage 释放、refcount=1）零分配。
            connScratchIndex ^= 1
            if connScratchIndex == 0 {
                connScratchA.removeAll(keepingCapacity: true)
                withUnsafePointer(to: conn) { base in
                    connScratchA.reserveCapacity(historyCount)
                    for i in 0..<historyCount {
                        connScratchA.append(Int(FSStatsConnHistoryAt(base, Int32(i))))
                    }
                }
                snap.connHistory = connScratchA
            } else {
                connScratchB.removeAll(keepingCapacity: true)
                withUnsafePointer(to: conn) { base in
                    connScratchB.reserveCapacity(historyCount)
                    for i in 0..<historyCount {
                        connScratchB.append(Int(FSStatsConnHistoryAt(base, Int32(i))))
                    }
                }
                snap.connHistory = connScratchB
            }
        }

        mark("conn")

        // ---- 磁盘中频项（可见 5s / 隐藏 30s）：容量/型号/连接/文件系统/SMART/网络 Top ----
        // v128：型号/连接/文件系统是静态信息，只在首次取到后缓存（原先每 5s
        // 两次 IOKit 注册表上溯 + 一次 statfs，纯浪费）；本地 IP/主接口一并挪入
        // 本档（原先每帧 getifaddrs + SCDynamicStore，显示层不需要这么勤）。
        if slowDue {
            lastSlowAt = now
            let capPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
            defer { capPtr.deallocate() }
            frset_disk_capacity(capPtr, capPtr + 1)
            snap.diskTotalBytes = capPtr[0]
            snap.diskFreeBytes = capPtr[1]

            let diskBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
            defer { diskBuf.deallocate() }
            if snap.diskModel.isEmpty, frset_disk_model(diskBuf, 128) == 0 {
                snap.diskModel = String(cString: diskBuf)
            }
            if snap.diskInterconnect.isEmpty, frset_disk_interconnect(diskBuf, 128) == 0 {
                snap.diskInterconnect = String(cString: diskBuf)
            }
            if snap.diskFileSystem.isEmpty, let fs = FSStatsRootFileSystem() {
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
            // 10 分钟窗口累计（用户需求：分流按「过去 10 分钟」而不是最近 5 秒）
            NetworkFlowTracker.shared.ingestApps(snap.procNet)

            // v128：本地 IP / 主接口（原每帧 getifaddrs + SCDynamicStore）
            let ipBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
            defer { ipBuf.deallocate() }
            frset_net_ip(ipBuf, 64)
            snap.netLocalIP = String(cString: ipBuf)
            snap.netInterface = StatsDataProvider.primaryInterfaceName()
        }

        mark("slow")

        // ---- SMC 全量扫描（可见 5s / 隐藏 30s）----
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
                // 静态映射走缓存：首次扫描建表，后续零 C 调用
                let meta: SensorMeta
                if let cached = sensorMeta[key] {
                    meta = cached
                } else {
                    var groupOut: Int32 = 0
                    let official = key.withCString { frset_sensor_name($0, &groupOut) }
                    // v129：未收录键回落「中文类别（键名）」——纯英文简写（TPDA/PHPB 等
                    // Apple Silicon 键不在官方名表）对用户不可读，扫描层 category 最可靠
                    // v132：供电轨三件套族优先（V×I=P 已实测精确吻合，见 railFamilyName）
                    let fallbackName: String
                    if let rail = Self.railFamilyName(key: key) {
                        fallbackName = rail
                    } else {
                        fallbackName = Self.genericSensorName(key: key, category: Int(raw.category))
                    }
                    meta = SensorMeta(
                        key: key,
                        name: official != nil ? String(cString: official!)
                                              : fallbackName,
                        type: key.withCString { frset_sensor_type($0) },
                        group: key.withCString { frset_sensor_group($0) },
                        isAvg: key.withCString { frset_sensor_average($0) }
                    )
                    sensorMeta[key] = meta
                }
                // category 必须用**扫描层的字母分类**（categorize：0温1扇2压3流4功5能），
                // 与 StatsSensorItem 文档和 UI 各分节过滤一致；名表 type 是另一套枚举
                // （0温1压2流3功4能5扇），直接搬过来会把电压/电流/功率/能耗全部错位、
                // 未收录键（如 BDAT，type=-1）更无类可归——2026-10-20 用户实证
                // 「传感器获取到的数据不对（BDAT 显示 5388°）」。
                // v129（内存）：key/name 用 meta 里的 interned 实例（同 key 跨扫描共享存储）
                items.append(StatsSensorItem(key: meta.key, name: meta.name, category: Int(raw.category),
                                             group: Int(meta.group), value: raw.value))
                // 计算项口径：group∈{CPU(1),GPU(2)} 且 type=温度(0) 且官方 average 标记
                if meta.type == 0 && meta.isAvg == 1 {
                    if meta.group == 1 { cpuTemps.append(raw.value) }
                    if meta.group == 2 { gpuTemps.append(raw.value) }
                }
            }
            snap.sensors = items
            snap.calcAverageCPU = cpuTemps.isEmpty ? nil : cpuTemps.reduce(0, +) / Double(cpuTemps.count)
            snap.calcHottestCPU = cpuTemps.max()
            snap.calcAverageGPU = gpuTemps.isEmpty ? nil : gpuTemps.reduce(0, +) / Double(gpuTemps.count)
            snap.calcHottestGPU = gpuTemps.max()
            // GPU 温度：TV*/TG* 最大值
            // v129（内存）：filter+map 双中间数组 → 单循环求 max（600 项扫描每5s/30s 一轮）
            var gpuTempMax = 0.0
            for item in items where item.category == 0
                && (item.key.hasPrefix("TV") || item.key.hasPrefix("TG")) {
                if item.value > gpuTempMax { gpuTempMax = item.value }
            }
            snap.gpuTemperature = gpuTempMax
            // 多风扇：FNum + F{i}ID/F{i}Ac + 官方百分比
            snap.fans = StatsDataProvider.readFans()
        }

        mark("smc")

        // ---- 进程排行 CPU/内存/磁盘（可见 3s / 隐藏 15s）----
        if now - lastProcAt >= procInterval {
            lastProcAt = now
            snap.procCPU = StatsDataProvider.readProcList(kind: 0, max: 8)
            snap.procMem = StatsDataProvider.readProcList(kind: 1, max: 8)
            snap.procDisk = StatsDataProvider.readProcList(kind: 2, max: 8)
        }

        mark("proc")

        snap.updatedAt = Date()
        lock.lock()
        storage = snap
        lock.unlock()
    }

    // MARK: - 内部辅助

    /// 读一类进程排行（kind：0=CPU 1=内存 2=磁盘 3=网络）。
    /// v71：读入后按 App 聚合——「一个 App 的多个进程/Helper/Renderer 合并显示」，
    /// 聚合项保留全部 pid（退出时一并结束），主指标相加后重排截 max。
    /// v84（用户需求「展开看明细」）：聚合时同步收集 children（每个子进程的原始名与用量），
    /// 并把 C 层取样上限放宽到 64——否则带多个 Helper 的 App（Chrome/Edge）会被截断，
    /// 展开后看不到真正的「大头」子进程。UI 侧只展示前 N 组。
    /// v86（用户反馈「图标没有正确展现 / 归类不准」）：改成**按可执行路径的 .app bundle 归类**，
    /// 与注入版 frset_proc_grouped 同一口径——不再按进程名猜 App。
    ///   · 归类键 = `/Applications/X.app`（Chrome 的 N 个 Helper/Renderer 自动归一行）
    ///   · 图标路径 = 同一个 bundle 路径 → NSWorkspace 直接取宿主 App 图标（不再靠名字匹配表）
    ///   · 无 .app 的守护进程/CLI = 按可执行路径独立成行，图标取该可执行文件图标
    /// 采样上限 640：C 层本来就要遍历全部 pid（瓶颈在 proc_pid_rusage），
    /// 抬高输出上限不增加扫描成本，却能保证「聚合后的排名」完整（大 App 不再被 64 截断）。
    ///
    /// v191：`private` → 模块内可见。网络常驻统计（NetworkFlowTracker 的后台节拍）
    /// 需要在不打开监测页时也读 nettop 缓存；procBuffer 本身有锁，两个调用方串行安全。
    static func readProcList(kind: Int, max: Int) -> [StatsProcItem] {
        // v129（内存）：sampleMax 640→512——C 层 FRSET_PROC_CAP=512（v128 起），
        // 640 的输出缓冲纯浪费：每次调用 640×612B≈392KB → 313KB，且每周期
        // 3 kind + 1 net 共 4 次调用（峰值 152MB 的 churn 源之一）。
        // 输出缓冲改静态复用：313KB 每周期 4 次 malloc/free 是 malloc zone
        // 碎片化的主要推手（footprint 里表现为 non-object 小块+脏页滞留）；
        // 本函数只被 StatsDataProvider.refresh 调用（MonitorSampler 采样队列单线程），
        // 但保留锁防御性串行化。buffer 只在函数内使用，无跨调用状态。
        let sampleMax = 512   // 恒等于 procBuffer 容量（C 层 FRSET_PROC_CAP=512 也截断在此）
        procBufferLock.lock()
        defer { procBufferLock.unlock() }
        let ptr = procBuffer
        // kind 3 = 网络：走 nettop 后台差分（frset_net_top，字段 disk_r/disk_w = 下载/上传）
        let n = (kind == 3) ? frset_net_top(ptr, Int32(sampleMax))
                            : frset_proc_top(Int32(kind), ptr, Int32(sampleMax))
        // v129（内存）：轻量子进程记录——只存 ptr 下标 + 数值，**不**建 name String /
        // StatsProcItem / 单元素 pids 数组。原实现给全部 ~640 个原始进程都建
        // StatsProcItem（含 pids:[pid] 小数组 + children 数组），随后 items.prefix(max)
        // 只留 8 组、其余当场丢弃——是 malloc 直方图 32B/48B 峰值（11.5万+6万个
        // 小块）与 non-object 驻留的主要churn 源。现在只有进入 top-`max` 的组才实体化。
        struct ChildRec {
            var idx: Int          // 进 ptr 下标（本函数返回前一直有效）
            var pid: Int32
            var cpu: Double, mem: Double, r: Double, w: Double
        }
        // 网络 kind（3）的 down/up 复用 diskRead/diskWrite 字段，随聚合相加
        struct Acc {
            var displayName = ""
            var iconPath = ""
            var cpu = 0.0, mem = 0.0, r = 0.0, w = 0.0
            var kids: [ChildRec] = []
        }
        var groups: [String: Acc] = [:]
        for i in 0..<Int(n) {
            var item = ptr[i]
            let path = String(cString: FSStatsProcPath(&item))
            let bundle = appBundlePath(path)
            // v129（内存）：name String 延迟创建——分组键只在 path 为空时才用 name
            //（守护进程/内核态，少数），displayName 只在**建组首项**时取一次。
            // 原实现每原始进程都建 name String（每次调用 ~640 个小字符串 × 4 调用/周期，
            // 全部当场丢弃），是 non-object 小块（16~48B 峰值）的稳定churn 源。
            let key: String
            if let bundle {
                key = bundle
            } else if path.isEmpty {
                key = String(cString: FSStatsProcName(&item))
            } else {
                key = path
            }
            var acc = groups[key] ?? Acc()
            if acc.displayName.isEmpty {
                acc.displayName = bundle.map { appDisplayName(bundle: $0) }
                    ?? String(cString: FSStatsProcName(&item))
                acc.iconPath = bundle ?? path
            }
            acc.cpu += item.cpu; acc.mem += item.mem
            acc.r += item.disk_r; acc.w += item.disk_w
            acc.kids.append(ChildRec(idx: i, pid: item.pid,
                                     cpu: item.cpu, mem: item.mem, r: item.disk_r, w: item.disk_w))
            groups[key] = acc
        }
        // 组内子进程按当前维度降序（同样分桶，避免展开后行序抖动）
        func sortChildren(_ list: inout [StatsProcItem]) {
            func key(_ item: StatsProcItem) -> Double {
                switch kind {
                case 1: return (item.memBytes / (16 * 1024 * 1024)).rounded()
                case 2, 3: return (Swift.max(item.diskRead, item.diskWrite) / 65536).rounded()
                default: return (item.cpu * 2).rounded()
                }
            }
            list.sort { a, b in
                let ka = key(a), kb = key(b)
                if ka != kb { return ka > kb }
                // v126（性能审计 F0938）：localizedStandardCompare（Foundation 重量级，
                // 数字感知比较）→ < 字典序。此处仅是同桶内兜底排序，字典序足够。
                return a.name < b.name
            }
        }
        // v129（内存）：先按组聚合值排序全部组（保持名次稳定语义），再**只对前 max 组**
        // 实体化 StatsProcItem（children/pids 此时才建）。
        func rank(_ acc: Acc) -> Double {
            switch kind {
            case 1: return (acc.mem / (8 * 1024 * 1024)).rounded()
            case 2, 3: return (Swift.max(acc.r, acc.w) / 32768).rounded()
            default: return (acc.cpu * 10).rounded()
            }
        }
        // v86：排序 = 分桶指标 + **沿用上一轮名次**兜底。
        //   直接按原始值排：1.5s 刷新时 0.1% / 1MB 级噪声会让行序反复跳动（点不中想展开的行）；
        //   纯分桶再按名称：0% 与 1% 会在桶边界交错，看起来像没排序。
        //   现在同桶内保持上一轮相对次序，只有指标实质变化才换位（既稳定又不会明显乱序）。
        orderLock.lock()
        let previous = lastOrders[kind] ?? [:]
        orderLock.unlock()
        var ordered = groups.map { (key: $0.key, acc: $0.value) }
        ordered.sort { a, b in
            let ra = rank(a.acc), rb = rank(b.acc)
            if ra != rb { return ra > rb }
            let ia = previous[a.key] ?? Int.max
            let ib = previous[b.key] ?? Int.max
            if ia != ib { return ia < ib }
            // v126（性能审计 F0938）：同上，localizedStandardCompare → < 字典序
            return a.acc.displayName < b.acc.displayName
        }
        var snapshot: [String: Int] = [:]
        for (index, entry) in ordered.enumerated() { snapshot[entry.key] = index }
        orderLock.lock()
        lastOrders[kind] = snapshot
        orderLock.unlock()
        var result: [StatsProcItem] = []
        result.reserveCapacity(Swift.min(max, ordered.count))
        for entry in ordered.prefix(max) {
            let acc = entry.acc
            var kids: [StatsProcItem] = acc.kids.map { rec in
                var raw = ptr[rec.idx]
                return StatsProcItem(pid: rec.pid,
                                     name: String(cString: FSStatsProcName(&raw)),
                                     cpu: rec.cpu, memBytes: rec.mem,
                                     diskRead: rec.r, diskWrite: rec.w,
                                     iconPath: acc.iconPath)
            }
            sortChildren(&kids)
            result.append(StatsProcItem(pid: acc.kids.first?.pid ?? 0, name: acc.displayName,
                                        cpu: acc.cpu, memBytes: acc.mem,
                                        diskRead: acc.r, diskWrite: acc.w,
                                        pids: acc.kids.map(\.pid),
                                        iconPath: acc.iconPath,
                                        children: kids.count > 1 ? kids : []))
        }
        return result
    }

    /// 上一轮组序（按 kind 分开存：CPU/内存/磁盘/网络 各自独立，互不冲掉对方次序）
    private static var lastOrders: [Int: [String: Int]] = [:]
    private static let orderLock = NSLock()

    // v129（内存）：frset_proc_t 输出缓冲静态复用（512×612B≈313KB，见 readProcList）
    private static let procBuffer = UnsafeMutablePointer<frset_proc_t>.allocate(capacity: 512)
    private static let procBufferLock = NSLock()

    /// 可执行路径 → 宿主 `.app` 路径（与 C 层 frset_bundle_of 同规则：截到第一个 ".app" 为止）。
    /// 例：`/Applications/Google Chrome.app/Contents/Frameworks/…/Helper` → `/Applications/Google Chrome.app`
    static func appBundlePath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let end = path.index(range.lowerBound, offsetBy: 4)   // 含 ".app"
        return String(path[..<end])
    }

    /// bundle 显示名：CFBundleDisplayName / CFBundleName 优先，回落 `.app` 文件名。
    /// （有些 app 文件名是英文而显示名是中文，或反之；与 Finder/Dock 显示一致）
    private static let displayNameCacheLock = NSLock()
    private static var displayNameCache: [String: String] = [:]
    static func appDisplayName(bundle path: String) -> String {
        displayNameCacheLock.lock()
        if let hit = displayNameCache[path] { displayNameCacheLock.unlock(); return hit }
        displayNameCacheLock.unlock()
        var name = (path as NSString).lastPathComponent
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") {
            if let display = info["CFBundleDisplayName"] as? String, !display.isEmpty {
                name = display
            } else if let bundleName = info["CFBundleName"] as? String, !bundleName.isEmpty,
                      bundleName.count <= 24 {
                name = bundleName
            }
        }
        displayNameCacheLock.lock()
        displayNameCache[path] = name
        displayNameCacheLock.unlock()
        return name
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

    // MARK: 传感器中文名（v129：未收录键不再裸露英文简写）

    /// 扫描类别 → 中文（与 frset_smc_scan 的 categorize 口径一致）
    private static let sensorCategoryCN = ["温度", "风扇", "电压", "电流", "功率", "能耗"]

    /// 未收录键的回落名：中文类别（原始键名），如「功率传感器（PHPB）」
    private static func genericSensorName(key: String, category: Int) -> String {
        let cn = sensorCategoryCN[min(max(category, 0), sensorCategoryCN.count - 1)]
        return "\(cn)传感器（\(key)）"
    }

    // MARK: v132：供电轨三件套族（V/I/P 同后缀；V×I=P 已实测精确吻合）
    //
    // 本机 M5 实测：VP0b 1.016V × IP0b 4.876A = 4.954W = PP0b（精确）、
    // VP2b×IP2b=PP2b、VMVC×IMVC=PMVC、VD0R↔PDTR/ID0R（19.7V 适配器）全部吻合。
    // 特征：4 字符键、首字母 V/I/P、末字母 b/l（b/l 为同一轨的两组测量点）。
    // 具体哪条轨对应 CPU/GPU/内存核心 Apple 未文档化，保持键名透明。

    private static func railFamilyName(key: String) -> String? {
        guard key.count == 4,
              let first = key.first, "VIP".contains(first),
              let last = key.last, "bl".contains(last) else { return nil }
        switch first {
        case "V": return "供电轨电压（\(key)）"
        case "I": return "供电轨电流（\(key)）"
        default:  return "供电轨功率（\(key)）"
        }
    }

    /// 供设置页传感器选择器使用：官方名表命中用官方中文名，
    /// 其次供电轨三件套族（V×I=P 实测验证），最后按 SMC 首字母族推断
    public static func sensorDisplayName(_ key: String) -> String {
        var groupOut: Int32 = 0
        let official: String? = key.withCString { cKey in
            guard let ptr = frset_sensor_name(cKey, &groupOut) else { return nil }
            return String(cString: ptr)
        }
        if let official, !official.isEmpty { return official }
        if let rail = railFamilyName(key: key) { return rail }
        let family: String
        switch key.first {
        case "T": family = "温度传感器"
        case "I": family = "电流传感器"
        case "V": family = "电压传感器"
        case "P": family = "功耗传感器"
        default:  family = "传感器"
        }
        return "\(family)（\(key)）"
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
