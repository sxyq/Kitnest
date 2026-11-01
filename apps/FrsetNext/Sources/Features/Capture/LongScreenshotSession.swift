import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图会话状态

/// 会话状态机（spec 15 §3③）：IDLE → RUNNING → CAPTURING → PROCESSING → FINISHED / CANCELLED。
/// 对齐原作状态枚举：0=正常处理、4=捕获失败；2=对齐放弃、3=完成分支（未探明部分按语义命名）。
enum LongScreenshotState: Equatable {
    case idle               // 未启动
    case running            // 监听中，等待滚动
    case capturing          // 正在采帧
    case processing         // 正在拼接
    case finished           // 正常收尾（产物有效）
    case cancelled          // Esc 取消
    case failed             // 捕获失败（原作状态 4）

    var isActive: Bool { self == .running || self == .capturing || self == .processing }
}

// MARK: - 采集状态（HUD 文案用）

enum LongScreenshotCaptureStatus {
    /// 正在追加新内容
    case collecting
    /// 一段时间没有新内容（可能已到底）
    case idle
    /// 画面变化过快 / 对齐失败（提示放慢滚动）
    case unstable
    /// 已经因为滚动过快跳过了一段（持续提示，不是一闪而过）
    case lost
}

// MARK: - 长截图会话

/// 长截图会话（v150：改「定时采样」驱动）
///
/// 旧实现由全局 `scrollWheel` 事件 + 55ms 去抖驱动：滚动一快就漏帧、光标移出选区
/// 就静默停采、事件到达时画面仍在动（抓到的帧滞后）。ScrollSnap（macOS 开源，
/// MIT）的做法是**完全不监听滚轮**——用 0.25s 定时器主动取帧。本实现照此：
///   · 每 250ms 取一次连续帧流的最新帧（帧龄 ≤33ms）；
///   · 滚轮事件只累积「位移提示」，用于估算对齐搜索窗，不再决定是否采帧；
///   · 去掉「光标必须在选区内」的限制（手一抖就不采是旧版最隐蔽的坑）；
///   · 收尾前强制补采一帧，避免「点了完成但最后一小段没进去」。
final class LongScreenshotSession {

    // MARK: 几何与目标（+0x10/+0x18 选区、捕获目标）

    /// 选区（AppKit 全局坐标，左下原点）
    let selectionRectAppKit: CGRect
    /// 选区（CG 全局坐标，左上原点）
    let selectionRectCG: CGRect
    let displayID: CGDirectDisplayID
    let windowID: CGWindowID

    // MARK: 队列与锁（+0x50 队列、+0x58 NSLock）

    let queue = DispatchQueue(label: "com.frset.long-screenshot", qos: .userInitiated)
    private let lock = NSLock()

    // MARK: 采样参数

    /// 采样间隔（秒）——**按帧高自适应**。
    /// 固定 250ms 在快速滑动时会「一帧跨过整个画面」，没有重叠可对齐（必然丢帧）。
    /// v151：目标改成「单次位移 ≤ 帧高的 45%（按 4000px/s 的快速滑动估）」，
    /// 因为对齐的可靠上限是 75% 帧高（留 25% 重叠），留一倍余量才不会踩线。
    /// 443px 高的选区 ≈ 63ms（16fps）；1200px ≈ 135ms。区间 [60ms, 200ms]。
    static func samplingInterval(frameHeight: Int) -> TimeInterval {
        guard frameHeight > 0 else { return 0.12 }
        let target = 0.45 * Double(frameHeight) / 4000.0
        return min(0.20, max(0.06, target))
    }
    /// 「没有新内容」判定：超过该时长没有追加成功 → HUD 提示可能已到底
    static let idleThreshold: TimeInterval = 1.2
    /// 帧流最新帧的最大可用帧龄：超过就当「这一 tick 没有新画面」。
    /// v150 用 0.5s 太宽——用户在滚动开始时，tick 会拿到滚动前的旧帧，
    /// 下一次 tick（≈100ms 后）真实位移已经很远，超出搜索窗 → 整段丢失。
    static let maxFrameAge: TimeInterval = 0.15

    // MARK: 会话字段

    private let stitcher = LongScreenshotStitcher()
    /// 自上次 tick 以来的滚动累积量（像素，仅作搜索窗提示）
    private var pendingDelta: Double = 0
    /// 自上次**成功追加**以来的累计滚动量（用于判断「是否真的跳了一屏」）
    private var scrollSinceAppend: Double = 0
    /// 已锁定的「滚动区」列区间（像素）——框选里混进静止后台时只截这块
    private var cropRange: Range<Int>?
    /// 上一次运动检测结果（连续两次一致才锁定）
    private var pendingCrop: Range<Int>?
    /// 上一帧**未裁剪**的画面（运动检测用）
    private var lastRawFrame: CGImage?
    private var pendingDeltaX: Double = 0
    /// 采样定时器（串行队列上触发）
    private var sampleTimer: DispatchSourceTimer?
    /// 最近一次成功追加的时间（captureTick 内更新）
    private var lastContentAt: CFAbsoluteTime = 0
    /// 停止标志（tick 内检查）
    private var isStopped = false
    /// 取消标志：取消后连「收尾补采」也不做
    private var isCancelled = false
    /// 捕获失败连续次数（连续 3 次判失败）
    private var captureFailures = 0
    /// 上一次同步抓屏兜底的时间（限流：帧流停摆时最多 3 次/秒）
    private var lastSyncFallbackAt: CFAbsoluteTime = 0

    /// 内容缩放 = imgW / max(选区宽, 1)（诊断用）
    private(set) var contentScale: Double = 1.0
    /// 捕获分辨率钳制 [1, 3]
    var captureScaleClamp: ClosedRange<Double> = 1.0...3.0

    /// 会话启动时建立的连续帧流（30fps、排除本 App 窗口）
    private var frameStream: AnyObject?   // LongScreenshotFrameStream（macOS 14+，弱类型存以兼容旧系统编译）
    private var frameStreamStarted = false

    /// 采集矩形（v139）：选区向内收 3pt——长截图自己的选区边框（1.5pt 描边 +
    /// 3pt 角标）画在选区边界上，SCK 的 excludingApplications 对 .statusBar 层级
    /// 的覆盖窗不生效，边框会被逐帧截入（用户实测：结果图每帧顶边一条橙线、
    /// 左右各一条竖线）。内收 3pt 后画框完全落在采集区之外。
    var captureRectCG: CGRect {
        let r = selectionRectCG
        guard r.width > 20, r.height > 20 else { return r }
        return r.insetBy(dx: 3, dy: 3)
    }

    /// 当前状态
    private(set) var state: LongScreenshotState = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    // MARK: 回调

    var onStateChange: ((LongScreenshotState) -> Void)?
    /// 会话收尾（主线程回调；finished → 产物；cancelled / failed → nil 或已采内容）
    var onFinish: ((LongScreenshotState, CGImage?) -> Void)?
    /// 采集进度（主线程回调）：已拼接高度（像素）+ 当前状态（HUD 文案）
    var onProgress: ((Int, LongScreenshotCaptureStatus) -> Void)?
    /// v176：追加新内容后吐一次当前画布（实时预览卡用）
    var onPreview: ((CGImage) -> Void)?

    // MARK: 初始化

    init(selectionRectAppKit: CGRect, selectionRectCG: CGRect,
         displayID: CGDirectDisplayID, windowID: CGWindowID = 0) {
        self.selectionRectAppKit = selectionRectAppKit
        self.selectionRectCG = selectionRectCG
        self.displayID = displayID
        self.windowID = windowID
    }

    deinit {
        sampleTimer?.setEventHandler {}
        sampleTimer?.cancel()
    }

    // MARK: 生命周期

    /// 启动会话：开连续帧流 → 等首帧 → 采首帧 → 启动 250ms 采样
    func start() {
        guard state == .idle else { return }
        state = .running
        var streamStarted = false
        if #available(macOS 14.0, *), !frameStreamStarted {
            frameStreamStarted = true
            let fs = LongScreenshotFrameStream()
            fs.start(displayID: displayID, selectionRectCG: captureRectCG)
            frameStream = fs
            streamStarted = true
        }
        // 首帧作为画布底图。等帧流连上再采（≤600ms）——同步路径的首帧尺寸
        // 可能与流不一致，混用会让后续对齐算出 dx=1，整幅图横向错 1px。
        queue.async { [weak self] in
            guard let self else { return }
            if streamStarted, #available(macOS 14.0, *) {
                // 等到第一张**帧流**画面再开始。不能拿同步抓屏当首帧：
                // 两条管线的裁切取整差 1-2px，混用会让之后每一帧都差那 1-2px，
                // 实测表现为「开头几帧永远对不上」。
                var waited = 0
                while waited < 1200 {
                    if let fs = self.frameStream as? LongScreenshotFrameStream,
                       fs.latestFrame(maxAge: 0.2) != nil { break }
                    if self.frameStream == nil { break }        // 已收尾/取消
                    usleep(50_000)
                    waited += 50
                }
            }
            self.captureTick(force: true)
            self.startSampling(frameHeight: self.stitcher.canvasHeight)
        }
    }

    /// 启动定时采样（在 session 串行队列上）
    private func startSampling(frameHeight: Int) {
        guard sampleTimer == nil, !isStopped else { return }
        let interval = Self.samplingInterval(frameHeight: frameHeight)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval,
                       repeating: interval,
                       leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in
            self?.captureTick(force: false)
        }
        timer.resume()
        sampleTimer = timer
        Log.info("Capture", "长截图采样已启动：每 \(Int(interval * 1000))ms 取一帧"
                 + "（帧高 \(frameHeight)px，自适应）")
    }

    private func stopSampling() {
        if let timer = sampleTimer {
            timer.setEventHandler {}
            timer.cancel()
            sampleTimer = nil
        }
    }

    /// Esc 取消
    func cancel() {
        guard state.isActive else { return }
        isStopped = true
        isCancelled = true
        stopSampling()
        stopFrameStream()
        state = .cancelled
        DispatchQueue.main.async { [weak self] in self?.onFinish?(.cancelled, nil) }
    }

    /// 正常收尾：**先补采一帧**（用户可能刚滚完就点完成），再出图
    func finish() {
        guard state.isActive else { return }
        isStopped = true
        stopSampling()
        queue.async { [weak self] in
            guard let self else { return }
            if self.stitcher.canvasHeight > 0 {
                self.captureTick(force: true)
            }
            self.stopFrameStream()
            let image = self.stitcher.canvas
            self.state = .finished
            Log.info("Capture", "长截图收尾：画布 \(self.stitcher.canvasWidth)×\(self.stitcher.canvasHeight)，追加 \(self.stitcher.appendedRows) 行"
                     + (self.stitcher.didDropContent ? "，⚠️ 有一段因滚动过快未能对齐" : ""))
            DispatchQueue.main.async { self.onFinish?(.finished, image) }
        }
    }

    private func stopFrameStream() {
        if #available(macOS 14.0, *), let fs = frameStream as? LongScreenshotFrameStream {
            fs.stop()
        }
        frameStream = nil
    }

    // MARK: 事件入口（全局监视器只观察不拦截）

    /// 滚轮事件：只累积位移提示（供对齐搜索估算窗口），不再决定是否采帧。
    /// v150：去掉「光标必须在选区内」——采样由定时器驱动，光标在哪都能采。
    func onScroll(deltaY: Double, deltaX: Double) {
        guard state.isActive, !isStopped else { return }
        guard abs(deltaY) > LongScreenshotStitcher.scrollEpsilon
                || abs(deltaX) > LongScreenshotStitcher.scrollEpsilon else { return }
        lock.lock()
        pendingDelta += deltaY
        pendingDeltaX += deltaX
        lock.unlock()
    }

    /// 诊断日志节流（同一原因 2s 内只记一条；跨会话也能看到，不刷屏）
    private static var logPacedAt: [String: CFAbsoluteTime] = [:]
    static func logOnce(_ tag: String, _ message: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = logPacedAt[tag], now - last < 2.0 { return }
        logPacedAt[tag] = now
        Log.info("Capture", message)
    }

    // MARK: 采样 tick（串行队列上执行）

    private func captureTick(force: Bool) {
        lock.lock()
        let stopped = isStopped
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { return }
        if stopped && !force { return }

        state = .capturing

        // 先看看有没有**新鲜**的帧流画面。静止画面时 SCK 不出帧，帧会变旧；
        // 此时用旧帧去对齐没有意义（位移必然算成 0），直接跳过本 tick 最省事。
        var frame: CGImage?
        var streamStale = false
        if #available(macOS 14.0, *), let fs = frameStream as? LongScreenshotFrameStream {
            if let img = fs.latestFrame(maxAge: Self.maxFrameAge) {
                frame = img
            } else if fs.connected {
                streamStale = true
            }
        }

        // 帧流停摆但用户确实在滚（有事件提示）→ 用同步抓屏兜底，别让画面凭空丢失
        if streamStale {
            lock.lock()
            let scrollHint = abs(pendingDelta) + abs(pendingDeltaX)
            lock.unlock()
            let now = CFAbsoluteTimeGetCurrent()
            if force || (scrollHint > 8 && now - lastSyncFallbackAt > 0.3) {
                frame = captureFrameSync()
                if frame != nil { lastSyncFallbackAt = now }
            }
        } else if frame == nil {
            frame = captureFrameSync()
        }

        guard let frame else {
            if streamStale {
                // 不是失败：只是这一 tick 没有新画面（画面静止）
                Self.logOnce("staleFrame", "长截图：帧流暂无新帧（画面静止），本 tick 跳过")
                if !isStopped { state = .running }
                return
            }
            captureFailures += 1
            Log.warn("Capture", "长截图采帧失败（第 \(captureFailures) 次）——若连续 3 次将终止")
            if captureFailures >= 3 {
                isStopped = true
                stopSampling()
                state = .failed
                DispatchQueue.main.async { [weak self] in
                    self?.onFinish?(.failed, self?.stitcher.canvas)
                }
            } else {
                state = .running
            }
            return
        }
        captureFailures = 0

        lock.lock()
        let delta = pendingDelta
        let deltaX = pendingDeltaX
        pendingDelta = 0
        pendingDeltaX = 0
        lock.unlock()

        state = .processing
        scrollSinceAppend += delta

        // 框选里混进静止后台时（后台窗口/侧边栏/桌面），整幅对齐会被静止部分带偏。
        // 先找出「正在滚动」的列区间并锁定，之后所有帧只截这块。
        updateMotionCrop(with: frame)
        let target = cropRange.flatMap { r -> CGImage? in
            // 同步兜底路径的画面宽度可能与帧流差 1-2px，越界就退回整幅（不裁）
            let x0 = max(0, min(r.lowerBound, frame.width - 1))
            let x1 = min(r.upperBound, frame.width)
            guard x1 - x0 >= 32 else { return nil }
            return frame.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: frame.height))
        } ?? frame
        let outcome = stitcher.append(frame: target, hintDY: delta, scrollSinceAppend: scrollSinceAppend)

        switch outcome {
        case .appended(let rows):
            lastContentAt = CFAbsoluteTimeGetCurrent()
            scrollSinceAppend = 0
            Log.info("Capture", "长截图追加 \(rows) 行：画布 \(stitcher.canvasWidth)×\(stitcher.canvasHeight)"
                     + "（本帧 \(target.width)×\(target.height)，位移 d(\(stitcher.lastOffset.dx),\(stitcher.lastOffset.dy))，"
                     + "滚动提示 δ=(\(Int(deltaX)),\(Int(delta)))，\(LongScreenshotStitcher.lastNote)）")
        case .unchanged(let reason):
            Log.debug("Capture", "长截图本帧未追加：\(reason)（δ=(\(Int(deltaX)),\(Int(delta)))）")
        case .failed(let reason):
            // 静止/纯色区域会连续失败，用 debug + 节流，避免刷满日志
            Self.logOnce("alignFail", "长截图本帧对齐失败：\(reason)")
        }

        // HUD 进度（主线程）
        let height = stitcher.canvasHeight
        let status: LongScreenshotCaptureStatus
        switch outcome {
        case .appended:
            status = .collecting
        case .unchanged:
            status = (CFAbsoluteTimeGetCurrent() - lastContentAt > Self.idleThreshold) ? .idle : .collecting
        case .failed(let why):
            // 向上滚动时确实会「对齐失败」（真位移超出搜索窗），这不是错误：
            // 用户回看内容很常见，不要弹「滚动过快」。其余失败才提示放慢。
            if delta < -8 {
                status = .collecting
            } else if abs(delta) > 40,
                      why.contains("对齐") || why.contains("横向") || why.contains("宽度") {
                status = .unstable     // 确实在快速滚动却没对上，才提示放慢
            } else {
                status = .collecting
            }
        }
        let finalStatus: LongScreenshotCaptureStatus = stitcher.didDropContent ? .lost : status
        DispatchQueue.main.async { [weak self] in self?.onProgress?(height, finalStatus) }

        // v176：只有真的追加了内容才更新预览卡（unchanged/failed 不必重画）
        if case .appended = outcome, let canvas = stitcher.canvas {
            DispatchQueue.main.async { [weak self] in self?.onPreview?(canvas) }
        }

        if !isStopped { state = .running }
    }

    // MARK: 运动区检测（静止后台 → 只截滚动区）

    private func updateMotionCrop(with frame: CGImage) {
        defer { lastRawFrame = frame }
        guard cropRange == nil, let prev = lastRawFrame, prev.width == frame.width else { return }
        guard let r = LongScreenshotMotionCrop.movingColumns(previous: prev, current: frame) else {
            pendingCrop = nil
            return
        }
        if let p = pendingCrop, LongScreenshotMotionCrop.similar(p, r),
           stitcher.recrop(xRange: r) {
            cropRange = r
            Log.info("Capture", "长截图：检测到静止背景，只保留滚动区 x=\(r.lowerBound)..<\(r.upperBound)"
                     + "（宽 \(r.count)px，原宽 \(frame.width)px）")
        } else {
            pendingCrop = r
        }
    }

    // MARK: 捕获原语

    /// 采捕一帧：优先取连续帧流的最新帧（帧龄 ≤maxFrameAge）；流未就绪/过期时回退同步抓屏
    func captureFrame() -> CGImage? {
        if #available(macOS 14.0, *), let fs = frameStream as? LongScreenshotFrameStream,
           let img = fs.latestFrame(maxAge: Self.maxFrameAge) {
            let rect = captureRectCG
            contentScale = max(0.01, Double(img.width) / max(rect.width, 1))
            if contentScale > captureScaleClamp.upperBound { contentScale = captureScaleClamp.upperBound }
            if contentScale < captureScaleClamp.lowerBound { contentScale = captureScaleClamp.lowerBound }
            return img
        }
        return captureFrameSync()
    }

    /// 同步抓屏回退路径（帧流启动失败/卡死时的兜底）
    /// v162：通道次序按系统自适应——legacy 被运行时证实已废（macOS 26/27 返回 nil）时直接走 SCK；
    /// ≤15 的系统 legacy 仍可用（实测），保持低成本优先。首次 nil 会记账（legacyCaptureProbed）。
    private func captureFrameSync() -> CGImage? {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var img: CGImage?
        if #available(macOS 14.0, *), ScreenSnapshot.isLegacyKnownDead {
            img = ScreenSnapshot.sckCaptureSync(displayID: displayID)
        }
        if img == nil {
            img = ScreenSnapshot.legacyCaptureProbed(
                    rect: bounds,
                    option: CGWindowListOption(rawValue: 0x14),
                    windowID: windowID,
                    imageOption: CGWindowImageOption(rawValue: 8))
        }
        if img == nil, #available(macOS 14.0, *) {
            img = ScreenSnapshot.sckCaptureSync(displayID: displayID)
        }
        guard let img else { return nil }
        let rect = captureRectCG
        let sx = CGFloat(img.width) / max(CGFloat(bounds.width), 1)
        let sy = CGFloat(img.height) / max(CGFloat(bounds.height), 1)
        var r = CGRect(x: (rect.minX - bounds.minX) * sx,
                       y: (rect.minY - bounds.minY) * sy,
                       width: rect.width * sx,
                       height: rect.height * sy)
        r = r.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        r = r.integral
        guard !r.isNull, !r.isEmpty, r.width >= 1, r.height >= 1 else { return nil }

        let content = Double(img.width) / max(Double(rect.width), 1)
        contentScale = max(max(0.01, content), 0.01)
        if contentScale > captureScaleClamp.upperBound { contentScale = captureScaleClamp.upperBound }
        if contentScale < captureScaleClamp.lowerBound { contentScale = captureScaleClamp.lowerBound }

        return img.cropping(to: r)
    }

    // MARK: 查询

    /// 当前累积画布
    var canvas: CGImage? { stitcher.canvas }

    /// 采集中是否有内容因滚动过快被跳过（收尾提示用）
    var droppedContent: Bool { stitcher.didDropContent }
}
