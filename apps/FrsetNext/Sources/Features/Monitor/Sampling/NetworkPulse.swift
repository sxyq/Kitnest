import Foundation

// MARK: - 网络吞吐实时脉冲（v183）
//
// 为什么要单独一个采样器：
//   `MonitorSampler` 的节奏是「用户设置的刷新间隔」（默认 2s），而 C 引擎
//   （frset_stats_tick.m）的网络速率本来就 **1s 更新一次**（0.5s tick 隔拍采）。
//   2s 才抽一个点 → 曲线是一节一节的台阶，用户读作「根本不在实时更新」。
//
// 成本：每次只读 `g_snap` 的两个 double（无系统调用、无锁、无分配），
// 1Hz × 60 个点 = 60 秒窗口。只有网络页可见时才启动，离开即停。

public final class NetworkPulse: ObservableObject {

    public static let shared = NetworkPulse()

    /// 窗口点数（1s/点 → 60 秒）
    public static let capacity = 60

    /// 一次采样的完整快照。
    /// v183：原来 down/up/tick 各自 @Published——1 秒内要发 3 次 objectWillChange，
    /// 网络页（曲线 + 流向图 + 明细）就被重建 3 遍。合并成一个快照后每拍只发 1 次。
    public struct Snapshot: Equatable {
        public var down: [Double] = []
        public var up: [Double] = []
    }

    @Published public private(set) var snapshot = Snapshot()

    /// 下载历史（byte/s），末尾 = 最新
    public var down: [Double] { snapshot.down }
    /// 上传历史（byte/s），末尾 = 最新
    public var up: [Double] { snapshot.up }

    private var timer: Timer?
    /// 消费者计数：主面板性能页与状态栏独立窗可能同时显示同一页
    private var consumers = 0

    public var currentDown: Double { down.last ?? 0 }
    public var currentUp: Double { up.last ?? 0 }

    /// 网络页出现（可重入）
    public func activate() {
        consumers += 1
        guard timer == nil else { return }
        // 打开瞬间先读一帧：否则刚打开会空白 1 秒
        sample()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 网络页消失
    public func deactivate() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard MonitorPreferences.isEnabled else { return }
        let gsnap = g_snap
        guard gsnap.valid != 0 else { return }
        var next = snapshot
        append(&next.down, gsnap.netDownBps)
        append(&next.up, gsnap.netUpBps)
        snapshot = next          // 一次赋值 = 一次发布
        // 10 分钟窗口的整机累计：分流卡「其他 N 个」= 整机 - 已列出的 App
        NetworkFlowTracker.shared.ingestNIC(down: next.down.last ?? 0,
                                            up: next.up.last ?? 0)
    }

    private func append(_ array: inout [Double], _ raw: Double) {
        // 网卡计数器在休眠唤醒/驱动重启/接口集合变化时会给出非法值：
        // 负数、NaN，或 uint64 下溢产生的 ~2^64（实测 UI 上显示成「16384 PB/s」，
        // 整张图的量程当场被毁）。C 层已修下溢，这里再做一道兜底：
        // 超过 10 GB/s 的读数按异常丢弃——本机没有任何一块网卡能到这个量级。
        let value: Double
        if raw.isFinite, raw > 0, raw < 10_000_000_000 {
            value = raw
        } else {
            value = 0
        }
        if array.isEmpty {
            // 首帧补齐 60 个槽位：否则曲线只是贴在右边缘的一小段，
            // 看起来像「没在更新」。补零后是完整的 60 秒基线 + 右侧实时增长。
            array = Array(repeating: 0, count: Self.capacity - 1)
            array.append(value)
        } else {
            array.append(value)
            if array.count > Self.capacity {
                array.removeFirst(array.count - Self.capacity)
            }
        }
    }
}
