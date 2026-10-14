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

        public init() {}
    }

    public static let historyCapacity = 60

    private let reader = MonitorReader()
    private let samplingQueue = DispatchQueue(label: "com.frset.monitor.sampler", qos: .utility)
    private let lock = NSLock()

    private var buffers = Buffers()
    private var pendingWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private struct Buffers {
        var cpu = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var memory = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var netDownload = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var netUpload = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var diskRead = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
        var diskWrite = MonitorHistoryBuffer(capacity: MonitorSampler.historyCapacity)
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
        let interval = MonitorPreferences.refreshInterval
        reader.temperatureEnabled = MonitorPreferences.showTemperatures

        if !enabled {
            stop()
            return
        }
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
        var snapshot = History()
        snapshot.cpu = buffers.cpu.values()
        snapshot.memory = buffers.memory.values()
        snapshot.netDownload = buffers.netDownload.values()
        snapshot.netUpload = buffers.netUpload.values()
        snapshot.diskRead = buffers.diskRead.values()
        snapshot.diskWrite = buffers.diskWrite.values()
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
