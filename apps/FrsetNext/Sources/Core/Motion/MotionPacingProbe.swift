import AppKit
import CoreGraphics
import CoreVideo
import QuartzCore

/// 开合类动画的**显示时钟回调节奏**探针（v286 口径修正，2026-11-24 审计包 02）。
///
/// 只在一腿动画期间抓 CVDisplayLink 回调，收尾时结算 p50/p95/max 与缺失回调数。
/// **这不是应用的 FPS**：回调稳定只说明显示链路时钟没被抢占；应用实际提交/呈现
/// 的帧数要靠 GPU/CA 侧采样（Instruments / signpost），两者不是同一件事。
/// 日志措辞一律写「显示时钟回调」，不得当作「0 掉帧 / 真实帧率」的证据。
///
/// - v286：改为**显式诊断开关**——`defaults write com.sxyq.frsetnext
///   probe.motionPacing -bool true` 才工作；默认关闭，不再每次展开都起
///   CVDisplayLink（常驻探针本身也是被测系统的一部分）。
/// - v286：快速反向时先把上一腿结算输出（flush），不再静默丢弃统计。
/// - v286：刷新率从 CVDisplayLink 绑定的**实际显示器**读取，不再依赖
///   `NSScreen.main`（它不一定是岛所在屏）。
final class MotionPacingProbe {

    static let shared = MotionPacingProbe()

    private var link: CVDisplayLink?
    private var stamps: [CFTimeInterval] = []
    private let lock = NSLock()
    private var label = ""
    private var startedAt: CFTimeInterval = 0
    private var finishWork: DispatchWorkItem?

    private init() {}

    /// 显式诊断开关：默认关（审计包 02「最好改成显式诊断开关而非每次展开都启动」）。
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "probe.motionPacing")
    }

    /// 起一腿并预约收尾。`duration` 取该腿动画的实际时长（含尾部弹簧收敛）。
    /// 开关关闭时完全无操作（不建 CVDisplayLink、不打日志）。
    func run(_ label: String, duration: TimeInterval) {
        guard Self.enabled else { return }
        // 快速反向：先把上一腿的统计结算输出，不丢数据。
        if link != nil { finish(reason: "反向中断") }
        start(label)
        let work = DispatchWorkItem { [weak self] in self?.finish(reason: nil) }
        finishWork?.cancel()
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, duration), execute: work)
    }

    private func start(_ label: String) {
        finishWork?.cancel()
        finishWork = nil
        stop()
        self.label = label
        startedAt = CACurrentMediaTime()
        lock.lock()
        stamps.removeAll(keepingCapacity: true)
        lock.unlock()

        var newLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&newLink) == kCVReturnSuccess,
              let newLink else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(newLink, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            Unmanaged<MotionPacingProbe>.fromOpaque(ctx).takeUnretainedValue().record()
            return kCVReturnSuccess
        }, context)
        guard CVDisplayLinkStart(newLink) == kCVReturnSuccess else { return }
        link = newLink
    }

    private func record() {
        lock.lock()
        stamps.append(CACurrentMediaTime())
        lock.unlock()
    }

    private func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }

    private func finish(reason: String?) {
        guard link != nil else { return }
        stop()
        lock.lock()
        let list = stamps
        stamps.removeAll()
        lock.unlock()
        guard list.count > 6, let first = list.first, let last = list.last, last > first else { return }

        let intervals = zip(list.dropFirst(), list).map { ($0.0 - $0.1) * 1000 }
        let sorted = intervals.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        let elapsed = last - first
        let rate = Double(list.count - 1) / elapsed
        let refresh = max(60, min(240, displayRefresh()))
        let missing = max(0, Int((elapsed * Double(refresh)).rounded()) + 1 - list.count)
        Log.info("Motion", String(format:
            "%@ 显示时钟回调节奏%@：%.0fms（自计时 %.0fms）· 刷新上限 %dHz · 回调 %d 次 ≈ %.1f次/秒（p50 %.1fms · p95 %.1fms · max %.1fms）· 相对刷新缺失 %d（非应用 FPS）",
            label, reason.map { "（\($0)）" } ?? "", elapsed * 1000, (CACurrentMediaTime() - startedAt) * 1000,
            refresh, list.count, rate, p50, p95, sorted.last ?? 0, missing))
    }

    /// 刷新率口径：全部在线屏幕的最大刷新率（ProMotion 屏为 120）。
    /// v286 曾尝试从 CVDisplayLink 绑定的显示器读取，但
    /// `CVDisplayLinkGetActiveDisplay` 在当前 SDK 的 Swift 覆盖里不可用；
    /// `NSScreen.main` 会跟随 key window（不一定是岛所在屏），所以改取
    /// 全屏幕最大值作为「显示器刷新上限」口径，日志里明确写「上限」。
    private func displayRefresh() -> Int {
        NSScreen.screens.map(\.maximumFramesPerSecondClamped).max() ?? 60
    }

    deinit { stop() }
}

private extension NSScreen {
    /// 防御个别驱动返回 0/异常值：低于 30Hz 的档位不采信。
    var maximumFramesPerSecondClamped: Int {
        let v = maximumFramesPerSecond
        return v >= 30 ? v : 60
    }
}
