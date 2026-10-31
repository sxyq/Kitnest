import Foundation
import SwiftUI
import Combine

/// 周期性采样器：按可配置间隔读取系统指标，并在主线程发布。
///
/// - 只依赖 Foundation/Combine（IOKit 采集在 MonitorReader 内）
/// - 采样在后台队列执行，发布切回主线程
/// - 维护各指标的环形缓冲（最近 ~60 点），供迷你折线使用
public final class MonitorSampler: ObservableObject {
    public static let shared = MonitorSampler()

    /// 当前一帧采样（主线程发布）
    @Published public private(set) var sample: MonitorSample = MonitorSample()
    /// 历史缓冲快照（主线程发布，用于迷你折线）
    @Published public private(set) var history: History = History()
    /// 是否正在采样
    @Published public private(set) var isRunning: Bool = false
    /// 单调递增的采样序号（视图可用它触发重绘）
    @Published public private(set) var tick: UInt64 = 0

    /// 历史缓冲（公开只读属性，供图表组件直接取用）
    public struct History {
        public var cpu: [Double] = []
        public var memory: [Double] = []
        public var netDownload: [Double] = []
        public var netUpload: [Double] = []
        public var diskRead: [Double] = []
        public var diskWrite: [Double] = []
        public var gpu: [Double] = []

        public init() {}
    }

    public static let historyCapacity = 60

    /// 性能探针开关（FRSET_PERF_PROBE=1）：仅排障/性能测试时打开
    private static let perfProbe = ProcessInfo.processInfo.environment["FRSET_PERF_PROBE"] != nil

    private let reader = MonitorReader()
    private let samplingQueue = DispatchQueue(label: "com.frset.monitor.sampler", qos: .utility)
    private let lock = NSLock()

    private var buffers = Buffers()
    // v129（内存）：History 快照双缓冲（见 sampleOnce 内注释）
    private var scratchA = History()
    private var scratchB = History()
    private var scratchIndex = 0
    private var pendingWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    /// v57：UI 可见性门控。面板性能页 / 监测设置页可见时用用户设置的间隔刷新；
    /// 不可见时降到 ≥5s（隐藏面板每 2s 全量重绘一轮 SwiftUI 是无谓的常驻开销，
    /// 用户反馈「性能开销非常差」的主要来源之一）。菜单栏 STATS 部件走 C 引擎
    /// 自己的采样，不受这里影响。
    private var panelActive = false
    private var homePanelActive = false
    private var settingsActive = false

    public func setPanelActive(_ active: Bool) {
        guard panelActive != active else { return }
        panelActive = active
        applyPreferences()
        if active { refresh() }   // 打开瞬间立即出一帧，不等下个周期
    }

    /// 主面板可见性门控（性能页在主面板里）。
    /// 必须与独立窗的 panelActive **分开**：两者可能同时开，任一方关闭
    /// 不能把另一方的刷新节奏一起降频——这正是用户看到的
    /// 「主页性能页 5s 一帧 / 状态栏面板 1.5s 一帧，两套时间」的根源。
    public func setHomePanelActive(_ active: Bool) {
        guard homePanelActive != active else { return }
        homePanelActive = active
        applyPreferences()
        if active { refresh() }
    }

    public func setSettingsActive(_ active: Bool) {
        guard settingsActive != active else { return }
        settingsActive = active
        applyPreferences()
        if active { refresh() }
    }

    private var uiActive: Bool { panelActive || homePanelActive || settingsActive }

    private struct Buffers {
        var cpu = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var memory = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var netDownload = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var netUpload = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var diskRead = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var diskWrite = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var gpu = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
    }

    private init() {
        // 偏好变化（刷新间隔/总开关/温度开关）后立即重排采样节奏
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: MonitorPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPreferences()
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        pendingWork?.cancel()
    }

    // MARK: - 生命周期

    public func start() {
        lock.lock()
        guard pendingWork == nil else { lock.unlock(); return }
        lock.unlock()
        applyPreferences()
        samplingQueue.async { [weak self] in self?.sampleOnce() }
    }

    public func stop() {
        lock.lock()
        pendingWork?.cancel()
        pendingWork = nil
        lock.unlock()
        // v128（CPU 优化）：采样器停机（监测模块关闭）时连带暂停 C 层后台采样线程，
        // 否则 conn（1 包/秒 ICMP）与 nettop（5s 轮询）在无人消费时继续常驻。
        // 重新 start() 后由下一次 refresh(uiActive:) 恢复。
        frset_conn_set_active(0)
        frset_net_top_set_active(0)
        DispatchQueue.main.async { [weak self] in self?.isRunning = false }
    }

    /// 立即采样一帧（不等待定时器）
    public func refresh() {
        samplingQueue.async { [weak self] in self?.sampleOnce() }
    }

    // MARK: - 内部

    /// 依据偏好决定：是否运行、采样间隔、是否读温度
    private func applyPreferences() {
        let enabled = MonitorPreferences.isEnabled
        // v88：传感器模块关掉后**不再采集**温度（设置页承诺口径）；
        // 另受「采集温度」高级开关与总开关共同控制
        reader.temperatureEnabled = MonitorPreferences.showTemperatures
            && MonitorPreferences.isModuleEnabled(.sensors)

        if !enabled {
            stop()
            return
        }
        // UI 可见 → 用户设置的间隔；不可见 → 至少 5s（保持数据不至于太陈旧）
        let base = MonitorPreferences.refreshInterval
        let interval = uiActive ? base : max(base, 5.0)
        if !isRunning {
            DispatchQueue.main.async { [weak self] in self?.isRunning = true }
        }
        scheduleNext(interval: interval)
    }

    private func scheduleNext(interval: Double) {
        lock.lock()
        let existing = pendingWork
        lock.unlock()
        existing?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard MonitorPreferences.isEnabled else { return }
            self.sampleOnce()
            // v73（2026-10-19 性能审计）：原实现直接用 refreshInterval 重排，
            // 丢失了 applyPreferences 的 UI 隐藏门控——面板/设置都不可见时
            // 仍按用户间隔（默认 1s）全量采样 + 主线程发布 3 个 @Published，
            // 是「常驻开销大」的主因。此处复用同一门控：隐藏时 ≥5s。
            let base = MonitorPreferences.refreshInterval
            let interval = self.uiActive ? base : max(base, 5.0)
            self.scheduleNext(interval: interval)
        }
        lock.lock()
        pendingWork = work
        lock.unlock()
        // leeway 给系统省电空间
        samplingQueue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func sampleOnce() {
        // 性能探针（FRSET_PERF_PROBE=1）：分段计时，定位每 tick 的真实开销。
        // 生产路径只多一次静态布尔判断，无日志、无分配。
        let probe = Self.perfProbe
        let t0 = probe ? DispatchTime.now().uptimeNanoseconds : 0
        // 深数据（C 采集层：GPU/SMART/连通性/进程/传感器/适配器）——后台队列刷新，内部节流。
        // uiActive 传入可见性：面板不可见时 SMC 扫描/进程枚举大幅降频（性能实测 2026-10-20）。
        StatsDataProvider.shared.refresh(uiActive: uiActive)
        let t1 = probe ? DispatchTime.now().uptimeNanoseconds : 0

        // v125（性能审计 F0858/F0860/F0861/F0864/F0866）：先查 g_snap 有效性再决定
        // 读取深度。CPU / 内存已用 / 网络 / 磁盘 / 电池 5 组随后会被 g_snap 整体覆盖，
        // 属冗余采集（实测 0.7ms/tick）。g_snap 有效（绝大多数 tick）时跳过这 5 路，
        // 只补温度/功耗/内存压力/交换/压缩内存——省掉 host_processor_info + sysctl +
        // IOKit 磁盘 + IOKit 电池共 4 类系统调用。
        // 注：g_snap 在主线程 0.5s 更新，此处后台读取；arm64 上 8 字节标量读写原子，
        // 最坏情况是拿到相邻两 tick 的混合快照（≤0.5s），不影响观感与正确性。
        let cSnap = g_snap
        let gSnapValid = (cSnap.valid != 0)

        let result = reader.readResult(needFull: !gSnapValid)
        let t2 = probe ? DispatchTime.now().uptimeNanoseconds : 0
        if probe {
            let ms = { (a: UInt64, b: UInt64) in Double(b - a) / 1_000_000 }
            Log.info("Perf", String(format: "tick refresh=%.2fms read=%.2fms total=%.2fms gSnap=%@",
                                   ms(t0, t1), ms(t1, t2), ms(t0, t2),
                                   gSnapValid ? "valid(skip5)" : "invalid(full)"))
        }
        var sample = result.sample
        // v76（全盘统一数据源，2026-10-19）：菜单栏部件显示的数值来自 C 引擎
        // 0.5s 快照 g_snap（frset_stats_tick.m）；SwiftUI 面板此前由 MonitorReader
        // 再采一份，同一时刻两条时间线的数值会不同（用户反复反馈的「两套时间」）。
        // 核心指标直接采用同一份 g_snap：状态栏部件 / 主面板性能页 / 状态栏独立窗
        // 从此显示同一时刻的同一组数值；其余字段（温度/功耗/内存压力/交换）仍走本采样。
        if gSnapValid {
            sample.cpuUsage = cSnap.cpuUsage
            sample.systemCPU = cSnap.cpuSystem
            sample.userCPU = cSnap.cpuUser
            sample.idleCPU = cSnap.cpuIdle
            if cSnap.coreCount > 0 {
                let count = min(Int(cSnap.coreCount), 32)
                sample.perCore = withUnsafeBytes(of: cSnap.coreUsage) { raw in
                    let p = raw.bindMemory(to: Double.self)
                    return (0..<count).map { p[$0] }
                }
            }
            if cSnap.ramTotalBytes > 0 {
                sample.memoryUsed = MonitorFormat.u64(cSnap.ramUsedBytes)
                sample.memoryTotal = MonitorFormat.u64(cSnap.ramTotalBytes)
            }
            sample.diskRead = MonitorFormat.u64(cSnap.diskReadBps)
            sample.diskWrite = MonitorFormat.u64(cSnap.diskWriteBps)
            sample.netUpload = MonitorFormat.u64(cSnap.netUpBps)
            sample.netDownload = MonitorFormat.u64(cSnap.netDownBps)
            if cSnap.batteryPresent != 0 {
                sample.batteryLevel = cSnap.batteryPercent / 100.0
            }
        }
        let loadAverages = reader.loadAverages()

        lock.lock()
        buffers.cpu.append(sample.cpuUsage)
        let memoryRatio = sample.memoryTotal > 0 ? Double(sample.memoryUsed) / Double(sample.memoryTotal) : 0
        buffers.memory.append(memoryRatio)
        buffers.netDownload.append(Double(sample.netDownload))
        buffers.netUpload.append(Double(sample.netUpload))
        buffers.diskRead.append(Double(sample.diskRead))
        buffers.diskWrite.append(Double(sample.diskWrite))
        let gpuUsage = StatsDataProvider.shared.current.gpuUsage
        buffers.gpu.append(gpuUsage >= 0 ? gpuUsage : 0)
        // v129（内存）：History 快照双缓冲轮换——每 tick 7 个 values() 新数组
        //（480B×7 + History 结构拷贝）改为复用两个 scratch 的底座；
        // 交替发布后旧快照已释放（refcount 回 1），回填即原地写
        //（removeAll(keepingCapacity:)），稳态零分配，砍掉每 tick 7 个小数组
        //（32B/48B 直方图峰值源之一）。
        scratchIndex ^= 1
        let snapshot: History
        if scratchIndex == 0 {
            buffers.cpu.values(into: &scratchA.cpu)
            buffers.memory.values(into: &scratchA.memory)
            buffers.netDownload.values(into: &scratchA.netDownload)
            buffers.netUpload.values(into: &scratchA.netUpload)
            buffers.diskRead.values(into: &scratchA.diskRead)
            buffers.diskWrite.values(into: &scratchA.diskWrite)
            buffers.gpu.values(into: &scratchA.gpu)
            snapshot = scratchA
        } else {
            buffers.cpu.values(into: &scratchB.cpu)
            buffers.memory.values(into: &scratchB.memory)
            buffers.netDownload.values(into: &scratchB.netDownload)
            buffers.netUpload.values(into: &scratchB.netUpload)
            buffers.diskRead.values(into: &scratchB.diskRead)
            buffers.diskWrite.values(into: &scratchB.diskWrite)
            buffers.gpu.values(into: &scratchB.gpu)
            snapshot = scratchB
        }
        lock.unlock()

        // 补充字段写入旁路容器（峰值/累计/负载）
        // v129（内存）：两次 MonitorExtra.update 合并为一次（原来峰值段/累计段
        // 各拿一次锁、各包一个闭包，每 tick 双份）。
        let previousPeaks = MonitorExtra.current
        let netIn = MonitorFormat.u64(Double(sample.netDownload) * MonitorPreferences.refreshInterval)
        let netOut = MonitorFormat.u64(Double(sample.netUpload) * MonitorPreferences.refreshInterval)
        MonitorExtra.update { extra in
            extra.compressedMemory = result.compressedMemory
            extra.loadAverages = loadAverages
            extra.netPeakDownload = max(previousPeaks.netPeakDownload, sample.netDownload)
            extra.netPeakUpload = max(previousPeaks.netPeakUpload, sample.netUpload)
            extra.diskPeakRead = max(previousPeaks.diskPeakRead, sample.diskRead)
            extra.diskPeakWrite = max(previousPeaks.diskPeakWrite, sample.diskWrite)
            extra.updatedAt = Date()
            // 累计流量（自本进程启动起累加，重启清零）
            // v168：用回绕加法 `&+=`。netIn/netOut 已经饱和到 UInt64.max，
            // 普通 `+=` 在累加溢出时会 trap（又一个「用久了突然退出」的来源）。
            extra.netTotalIn &+= netIn
            extra.netTotalOut &+= netOut
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sample = sample
            self.history = snapshot
            self.tick &+= 1
        }
    }

    /// 清空历史与峰值（设置页「重置」用）
    public func resetHistory() {
        lock.lock()
        buffers = Buffers()
        lock.unlock()
        MonitorExtra.reset()
        DispatchQueue.main.async { [weak self] in
            self?.history = History()
        }
    }
}
