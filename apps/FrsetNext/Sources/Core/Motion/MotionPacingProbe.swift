import AppKit
import CoreVideo
import QuartzCore

/// 开合类动画的**帧节奏**探针（与 `GenieWarp` 的「播放节奏」同口径）。
///
/// 只在一腿动画期间抓显示链路回调，收尾时结算 p50/p95/max 与缺失回调数，
/// 用来回答「高负载下帧间隔有没有恶化」——而不是「主线程每帧画了多久」。
/// 口径边界：
/// - 回调稳定在刷新率 = 合成链路没被抢占；主线程的同步段再长，只影响开播前那一下。
/// - 默认开，但只在展开/收起那一腿存在（`run(label:duration:)` 到点自动 `finish`），
///   不常驻轮询，不给测量本身制造持续开销。
final class MotionPacingProbe {

    static let shared = MotionPacingProbe()

    private var link: CVDisplayLink?
    private var stamps: [CFTimeInterval] = []
    private let lock = NSLock()
    private var label = ""
    private var startedAt: CFTimeInterval = 0
    private var finishWork: DispatchWorkItem?

    private init() {}

    /// 起一腿并预约收尾。`duration` 取该腿动画的实际时长（含尾部弹簧收敛）。
    func run(_ label: String, duration: TimeInterval) {
        start(label)
        let work = DispatchWorkItem { [weak self] in self?.finish() }
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

    private func finish() {
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
        let fps = Double(list.count - 1) / elapsed
        let refresh = max(60, min(120, displayRefresh()))
        let missing = max(0, Int((elapsed * Double(refresh)).rounded()) + 1 - list.count)
        Log.info("Motion", String(format:
            "%@ 帧节奏：%.0fms（自计时 %.0fms）· 刷新 %dHz · 回调 %d 次 ≈ %.1ffps（p50 %.1fms · p95 %.1fms · max %.1fms）· 缺失 %d",
            label, elapsed * 1000, (CACurrentMediaTime() - startedAt) * 1000,
            refresh, list.count, fps, p50, p95, sorted.last ?? 0, missing))
    }

    private func displayRefresh() -> Int {
        NSScreen.main?.maximumFramesPerSecond ?? 60
    }

    deinit { stop() }
}
