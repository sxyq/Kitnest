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

    private let reader = MonitorReader()
    private let samplingQueue = DispatchQueue(label: "com.frset.monitor.sampler", qos: .utility)
    private let lock = NSLock()

    private var buffers = Buffers()
    private var pendingWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    /// v57：UI 可见性门控。面板性能页 / 监测设置页可见时用用户设置的间隔刷新；
    /// 不可见时降到 ≥5s（隐藏面板每 2s 全量重绘一轮 SwiftUI 是无谓的常驻开销，
    /// 用户反馈「性能开销非常差」的主要来源之一）。菜单栏 STATS 部件走 C 引擎
    /// 自己的采样，不受这里影响。
    private var panelActive = false
    private var settingsActive = false

    public func setPanelActive(_ active: Bool) {
        guard panelActive != active else { return }
        panelActive = active
        applyPreferences()
        if active { refresh() }   // 打开瞬间立即出一帧，不等下个周期
    }

    public func setSettingsActive(_ active: Bool) {
        guard settingsActive != active else { return }
        settingsActive = active
        applyPreferences()
        if active { refresh() }
    }

    private var uiActive: Bool { panelActive || settingsActive }

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
        reader.temperatureEnabled = MonitorPreferences.showTemperatures

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
            self.scheduleNext(interval: MonitorPreferences.refreshInterval)
        }
        lock.lock()
        pendingWork = work
        lock.unlock()
        // leeway 给系统省电空间
        samplingQueue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func sampleOnce() {
        // 深数据（C 采集层：GPU/SMART/连通性/进程/传感器/适配器）——后台队列刷新，内部节流
        StatsDataProvider.shared.refresh()

        let result = reader.readResult()
        let sample = result.sample
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
        var snapshot = History()
        snapshot.cpu = buffers.cpu.values()
        snapshot.memory = buffers.memory.values()
        snapshot.netDownload = buffers.netDownload.values()
        snapshot.netUpload = buffers.netUpload.values()
        snapshot.diskRead = buffers.diskRead.values()
        snapshot.diskWrite = buffers.diskWrite.values()
        snapshot.gpu = buffers.gpu.values()
        lock.unlock()

        // 补充字段写入旁路容器（峰值/累计/负载）
        let previousPeaks = MonitorExtra.current
        MonitorExtra.update { extra in
            extra.compressedMemory = result.compressedMemory
            extra.loadAverages = loadAverages
            extra.netPeakDownload = max(previousPeaks.netPeakDownload, sample.netDownload)
            extra.netPeakUpload = max(previousPeaks.netPeakUpload, sample.netUpload)
            extra.diskPeakRead = max(previousPeaks.diskPeakRead, sample.diskRead)
            extra.diskPeakWrite = max(previousPeaks.diskPeakWrite, sample.diskWrite)
            extra.updatedAt = Date()
        }
        // 累计流量（自本进程启动起累加，重启清零）
        MonitorExtra.update { extra in
            extra.netTotalIn += UInt64(max(0, Double(sample.netDownload) * MonitorPreferences.refreshInterval))
            extra.netTotalOut += UInt64(max(0, Double(sample.netUpload) * MonitorPreferences.refreshInterval))
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
