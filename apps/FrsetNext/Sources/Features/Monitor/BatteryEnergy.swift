import Foundation
import SwiftUI

// MARK: - CPU 能耗影响（v178）
//
// 版式来源：Status Trio 1.8 电池面板的「CPU 能耗影响」。
//
// 口径说明（**别和 CPU% 混用**）：
//   · CPU% 是「占用时间」占比；
//   · 这里是「消耗的电能」——proc_pid_rusage(RUSAGE_INFO_V6) 的 ri_energy_nj
//     两帧差分 → 瓦。两者排序结果通常不同（一个长时间 5% 的进程可能比瞬时
//     100% 的进程更耗电），所以界面标注是 mW 而不是百分比。
//
// 采样策略：
//   · 只在电池页可见时运行（onAppear/onDisappear）——页面切走就停，零后台开销；
//   · 首次调用只建基线，1.5s 后出第一份结果，之后 5s 一轮；
//   · 旧内核不支持该计数器时整体返回 -1，UI 回退到「CPU 活跃度」口径，
//     两种量纲绝不出现在同一张表里。

/// 一行「CPU 能耗影响」
public struct StatsEnergyItem: Identifiable, Sendable {
    /// 归类键：`.app` 路径或可执行路径（同一 App 的多个 Helper 合并成一行）
    public var id: String { bundle }
    public let bundle: String
    public let name: String
    public let iconPath: String
    /// 区间平均功率（瓦）
    public let watts: Double
    /// 组内代表进程：iconPath 取不到时用 NSRunningApplication 兜底取图标
    public let pid: Int32

    public init(bundle: String, name: String, iconPath: String, watts: Double, pid: Int32) {
        self.bundle = bundle
        self.name = name
        self.iconPath = iconPath
        self.watts = watts
        self.pid = pid
    }
}

@MainActor
public final class BatteryEnergySampler: ObservableObject {

    public static let shared = BatteryEnergySampler()

    public enum Phase: Equatable {
        /// 还没开始采样
        case idle
        /// 已建基线，等下一帧
        case sampling
        case ready
        /// 内核不支持 ri_energy_nj → 调用方应回退 CPU 活跃度口径
        case unavailable
    }

    @Published public private(set) var items: [StatsEnergyItem] = []
    @Published public private(set) var phase: Phase = .idle
    /// 最近一次区间的秒数（标注「近 N 秒」用）
    @Published public private(set) var window: Double = 0

    private var timer: Timer?
    private var kickoff: DispatchWorkItem?
    private var inflight = false
    private var loggedSample = false
    private let buffer = UnsafeMutablePointer<frset_energy_pid_t>.allocate(capacity: 512)
    private let bufferLock = NSLock()

    private init() {}

    // MARK: 生命周期

    public func start() {
        guard timer == nil else { return }
        if phase == .idle { phase = .sampling }

        tick()   // 建基线
        // 1.5s 后再采一次：否则用户要盯着「采样中…」等满 5 秒才看到第一份
        let kick = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        kickoff = kick
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: kick)

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        kickoff?.cancel()
        kickoff = nil
    }

    // MARK: 采样

    private func tick() {
        guard !inflight else { return }
        inflight = true
        bufferLock.lock()
        let ptr = buffer
        bufferLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var elapsed: Double = 0
            let n = frset_proc_energy_pids(ptr, 512, &elapsed)

            var grouped: [String: (name: String, icon: String, watts: Double, pid: Int32)] = [:]
            var unavailable = false
            if n < 0 {
                unavailable = true
            } else if n > 0 {
                for i in 0..<Int(n) {
                    var row = ptr[i]
                    guard row.watts > 0 else { continue }
                    let path = String(cString: FSEnergyPath(&row))
                    let rawName = String(cString: FSEnergyName(&row))
                    let bundle = StatsDataProvider.appBundlePath(path)
                    let key = bundle ?? (path.isEmpty ? rawName : path)
                    guard !key.isEmpty else { continue }
                    let display = bundle.map { StatsDataProvider.appDisplayName(bundle: $0) } ?? rawName
                    var acc = grouped[key] ?? (display, bundle ?? path, 0, row.pid)
                    acc.watts += row.watts
                    if acc.name.isEmpty { acc.name = display }
                    grouped[key] = acc
                }
            }

            let rows = grouped
                .map { StatsEnergyItem(bundle: $0.key,
                                       name: $0.value.name,
                                       iconPath: $0.value.icon,
                                       watts: $0.value.watts,
                                       pid: $0.value.pid) }
                .filter { $0.watts > 0 }
                .sorted { $0.watts > $1.watts }

            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight = false
                if unavailable {
                    self.phase = .unavailable
                    self.items = []
                    return
                }
                if !rows.isEmpty {
                    self.items = Array(rows.prefix(6))
                    self.phase = .ready
                    self.window = elapsed
                    if !self.loggedSample {
                        self.loggedSample = true
                        let head = rows.prefix(3).map {
                            "\($0.name)[pid=\($0.pid)] icon=\($0.iconPath.isEmpty ? "空" : $0.iconPath) "
                            + BatteryEnergySampler.wattsText($0.watts)
                        }.joined(separator: " | ")
                        Log.info("Battery", "能耗样本：" + head)
                    }
                } else if self.items.isEmpty {
                    self.phase = .sampling
                }
            }
        }
    }

    // MARK: 显示格式

    /// 功耗文案：< 1 W 用 mW（与原版一致），否则用 W
    public static func wattsText(_ watts: Double) -> String {
        if watts < 0.9999 {
            return String(format: "%.1f mW", max(0, watts) * 1000)
        }
        return String(format: "%.2f W", watts)
    }
}
