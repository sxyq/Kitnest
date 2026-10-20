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

// MARK: - 长截图会话

/// 长截图会话（原作 0x2d8 字节会话对象的重建映射，spec 15 §3③）：
/// - 串行队列 `com.frset.long-screenshot`（QoS userInitiated，@0x10045a754）
/// - NSLock 保护滚动累积 δ（+0xd0）与去抖令牌 pendingAutoScrollWorkItem（+0xa0）
/// - 捕获原语：CGWindowListCreateImage(option 0x14, imageOption 8) + 交集裁剪（@0x10045ae30）
/// - 被动式模型：绝不合成滚轮/键盘事件，只观察用户滚动
final class LongScreenshotSession {

    // MARK: 几何与目标（+0x10/+0x18 选区、捕获目标）

    /// 选区（AppKit 全局坐标，左下原点）——供光标包含检查
    let selectionRectAppKit: CGRect
    /// 选区（CG 全局坐标，左上原点）——供捕获裁剪
    let selectionRectCG: CGRect
    let displayID: CGDirectDisplayID
    let windowID: CGWindowID

    // MARK: 队列与锁（+0x50 队列、+0x58 NSLock）

    let queue = DispatchQueue(label: "com.frset.long-screenshot", qos: .userInitiated)
    private let lock = NSLock()

    // MARK: 会话字段

    private let stitcher = LongScreenshotStitcher()
    /// 滚动累积 δ（+0xd0）；v68 增加横向分量（二维对齐）
    private var pendingDelta: Double = 0
    private var pendingDeltaX: Double = 0
    /// 去抖去重令牌（+0xa0，同一时刻仅一个 pending）
    private var pendingWorkItem: DispatchWorkItem?
    /// 「暂停采帧」布尔（+0x128，真 → 不调度）
    private var isSuspended = false
    /// 暂停标志（+0x129，tick 内检查）
    private var isPaused = false
    /// 停止标志（+0x12a，tick 内检查）
    private var isStopped = false
    /// 捕获失败连续次数（原作失败 → 状态 4；这里允许单次抖动，连续 3 次判失败）
    private var captureFailures = 0

    /// 内容缩放 = imgW / max(选区宽, 1)，下限 0.01（+0x88，@0x10045a3d4）
    private(set) var contentScale: Double = 1.0
    /// 捕获分辨率钳制 [1, 3]（+0x70，@0x10045a994）
    var captureScaleClamp: ClosedRange<Double> = 1.0...3.0

    /// 当前状态
    private(set) var state: LongScreenshotState = .idle {
        didSet {
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    // MARK: 回调（+0x40 状态变更回调）

    var onStateChange: ((LongScreenshotState) -> Void)?
    /// 会话收尾（finished → 产物；cancelled / failed → nil）
    var onFinish: ((LongScreenshotState, CGImage?) -> Void)?
    /// 采集进度（已追加行数，主线程回调）——采集期 HUD 实时高度（v74）
    var onProgress: ((Int) -> Void)?

    // MARK: 初始化

    init(selectionRectAppKit: CGRect, selectionRectCG: CGRect,
         displayID: CGDirectDisplayID, windowID: CGWindowID = 0) {
        self.selectionRectAppKit = selectionRectAppKit
        self.selectionRectCG = selectionRectCG
        self.displayID = displayID
        self.windowID = windowID
    }

    // MARK: 生命周期

    /// 启动会话（原作 start 0x10045a1bc）：置 RUNNING 并采首帧作为画布底图
    func start() {
        guard state == .idle else { return }
        state = .running
        // 首帧：立即采捕一次作为画布起点（对齐原作「确认选区后先有一帧」）
        queue.async { [weak self] in
            self?.captureTick()
        }
    }

    /// Esc 取消（主队列调用，对齐原作 keyDown → 主队列取消 0x10045b494）
    func cancel() {
        guard state.isActive else { return }
        isStopped = true
        state = .cancelled
        onFinish?(.cancelled, nil)
    }

    /// 正常收尾：产物送预览/编辑器
    func finish() {
        guard state.isActive else { return }
        isStopped = true
        let image = stitcher.canvas
        state = .finished
        onFinish?(.finished, image)
    }

    // MARK: 事件入口（由 LongScreenshotCaptureStream 转发，全局监视器只观察不拦截）

    /// 滚轮事件：Δ 过滤 ε=0.08 → 光标须在选区内 → 累积 δ → 55ms 去抖调度（0x100446158）
    func onScroll(deltaY: Double, deltaX: Double, cursorInSelection: Bool) {
        guard state.isActive, !isSuspended else { return }
        // 三轴 ε 过滤（0x1004395ec，0.08）
        guard abs(deltaY) > LongScreenshotStitcher.scrollEpsilon
                || abs(deltaX) > LongScreenshotStitcher.scrollEpsilon else { return }
        // 光标须在选区内（CGRectContainsPoint，0x10044621c）
        guard cursorInSelection else { return }

        lock.lock()
        pendingDelta += deltaY
        pendingDeltaX += deltaX
        scheduleDebouncedCaptureLocked()
        lock.unlock()
    }

    /// 鼠标移动/拖拽：光标在选区内 → 调度捕获（0x1004461c0 区段）
    func onMouseActivity(cursorInSelection: Bool) {
        guard state.isActive, !isSuspended else { return }
        guard cursorInSelection else { return }
        lock.lock()
        scheduleDebouncedCaptureLocked()
        lock.unlock()
    }

    /// 去抖调度（锁内调用）：55ms 后派发 tick；同一时刻仅一个 pending（0x10044665c-0x100446764）
    private func scheduleDebouncedCaptureLocked() {
        guard pendingWorkItem == nil else { return }   // 去重
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.pendingWorkItem = nil
            self.lock.unlock()
            // tick 本体再经主线程检查后进捕获队列（0x100447f04 调用链）
            self.queue.async { self.captureTick() }
        }
        pendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: item)   // 0.055s @0x100446794
    }

    // MARK: 捕获 tick（串行队列上执行，0x100447f04）

    private func captureTick() {
        // flags 检查（+0x129/+0x12a，0x100447f48-0x100447f6c）
        lock.lock()
        if isPaused || isStopped {
            lock.unlock()
            return
        }
        lock.unlock()

        state = .capturing
        guard let frame = captureFrame() else {
            captureFailures += 1
            Log.warn("Capture", "长截图采帧失败（第 \(captureFailures) 次）——若连续 3 次将终止")
            if captureFailures >= 3 {
                isStopped = true
                state = .failed
                onFinish?(.failed, stitcher.canvas)
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
        // v68 二维拼接：位移提示按内容缩放换算为像素（仅作搜索窗参考，方向由图像对齐决定）
        let appended = stitcher.append(frame: frame,
                                       hintDX: deltaX * contentScale,
                                       hintDY: delta * contentScale,
                                       scale: contentScale)
        if appended {
            // v74：采集进度回调（主线程）——采集期 HUD 实时显示已追加行数
            let rowsNow = stitcher.appendedRows
            DispatchQueue.main.async { [weak self] in self?.onProgress?(rowsNow) }
            Log.info("Capture", "长截图追加成功：画布累计 \(stitcher.appendedRows) 行当量（本帧 \(frame.width)×\(frame.height)，位移 d(\(stitcher.lastOffset.dx),\(stitcher.lastOffset.dy))）")
        } else {
            Log.debug("Capture", "长截图本帧未追加（恒等帧/新内容不足/对齐失败，δ=(\(Int(deltaX)),\(Int(delta)))）")
        }
        if !isStopped { state = .running }
    }

    // MARK: 捕获原语（0x10045ae30，与 ScreenshotManager 直屏路径共用 CGWindowListCreateImage 家族）

    /// 采捕一帧：整屏抓取 → 换算 scale → 选区 ∩ 图像尺寸 → 裁剪
    func captureFrame() -> CGImage? {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // option = 0x14（onScreenAboveWindow | excludeDesktopElements）、imageOption = 8
        // （原作立即数，枚举名按 CG 常量表推断，spec 15 §7.7 标注⬜）
        // 2026-10-18：改走 ScreenSnapshot 的 dlsym 兼容层——CGWindowListCreateImage
        // 在 macOS 15 被 obsoleted（直接调用返回 nil，长截图因此连续采帧失败终止）。
        // v108（2026-10-21 用户：「滑动后没有正确记录形成长截图」）：
        // legacy CGWindowListCreateImage 在 macOS 15+ 已被移除（macOS 27 实测
        // dlsym 路径返回 nil → 采帧连续失败 → 无有效画布）。回退 ScreenCaptureKit。
        var img = ScreenSnapshot.legacyCapture(
                rect: bounds,
                option: CGWindowListOption(rawValue: 0x14),
                windowID: windowID,
                imageOption: CGWindowImageOption(rawValue: 8))
        if img == nil, #available(macOS 14.0, *) {
            img = ScreenSnapshot.sckCaptureSync(displayID: displayID)
        }
        guard let img else { return nil }
        let rect = selectionRectCG
        let reqWidth = max(rect.width, 1)
        // scale = imgWidth / reqWidth（@0x10045ae8c 起）
        let sx = CGFloat(img.width) / reqWidth
        let sy = CGFloat(img.height) / max(CGFloat(bounds.height), 1)
        // 选区（CG 全局，左上原点）→ 图像内坐标（同为左上原点，无需翻转 Y）
        var r = CGRect(x: (rect.minX - bounds.minX) * sx,
                       y: (rect.minY - bounds.minY) * sy,
                       width: rect.width * sx,
                       height: rect.height * sy)
        r = r.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        r = r.integral
        guard !r.isNull, !r.isEmpty, r.width >= 1, r.height >= 1 else { return nil }

        // 内容缩放（+0x88）与捕获分辨率钳制（+0x70，[1,3]）
        let content = Double(img.width) / max(Double(rect.width), 1)
        contentScale = max(max(0.01, content), 0.01)
        if contentScale > captureScaleClamp.upperBound { contentScale = captureScaleClamp.upperBound }
        if contentScale < captureScaleClamp.lowerBound { contentScale = captureScaleClamp.lowerBound }

        return img.cropping(to: r)
    }

    // MARK: 查询

    /// 当前累积画布
    var canvas: CGImage? { stitcher.canvas }

    /// 光标是否在选区内（AppKit 全局坐标）
    func containsCursor(_ appKitPoint: NSPoint) -> Bool {
        selectionRectAppKit.contains(appKitPoint)
    }
}
