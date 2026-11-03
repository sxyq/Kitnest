import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

// MARK: - 长截图连续帧流（v137）
//
// 为什么需要它：旧实现的每次 captureTick 都走 `sckCaptureSync(displayID:)`——
// 先 `SCShareableContent.excludingDesktopWindows` 枚举全部共享内容（窗口列表，
// ~50-200ms），再 `SCScreenshotManager.captureImage` 单帧截图（又 ~50-200ms）。
// 一次完整 tick ≈ 100-400ms；而滚动中帧的产生间隔只有 ~33ms：
//   · 帧严重滞后 → 拿到的是「滚动后很久」的画面 → 位移估计全错 → 画面乱窜
//   · 串行队列积压 → 连续 append 失败 → 大量内容没截进去
//   · 旧路径（CGWindowList option 0x14）还会把本 App 的 HUD/选区边框一起截进来
//     （HUD 恰好悬在选区附近且闪烁），静态覆盖物让对齐搜索直接跑偏
//
// 本实现：会话期开一条 30fps 的 SCStream（sourceRect = 选区、排除本 App 全部窗口），
// tick 只取「最新一帧」——帧龄 ≤ 33ms，且帧里永远没有 HUD/边框。

@available(macOS 14.0, *)
final class LongScreenshotFrameStream: NSObject, SCStreamOutput {

    private let lock = NSLock()
    private var latest: CGImage?
    private var latestAt: CFAbsoluteTime = 0
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.frset.long-screenshot.frames", qos: .userInitiated)
    private(set) var connected = false
    private var loggedFrameSize = false

    /// 启动帧流（后台完成；调用方不等待——tick 在帧到达前走同步回退）
    func start(displayID: CGDirectDisplayID, selectionRectCG: CGRect) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else { return }

                // 排除本 App 的全部窗口（HUD、选区边框、Toast 都不能进帧）
                let myPID = ProcessInfo.processInfo.processIdentifier
                let mine = content.applications.filter { $0.processID == myPID }
                let filter = SCContentFilter(display: display,
                                             excludingApplications: mine,
                                             exceptingWindows: [])

                let displayFrame = display.frame          // CG 全局坐标（点）
                let local = CGRect(x: selectionRectCG.minX - displayFrame.minX,
                                   y: selectionRectCG.minY - displayFrame.minY,
                                   width: selectionRectCG.width,
                                   height: selectionRectCG.height)
                // 点 → 像素比：**必须用「实际像素 / 点」**，不能用 NSScreen.backingScaleFactor。
                // 实测反例（2026-10-27 用户机器）：backingScaleFactor 报 2.0，但
                // SCDisplay 像素宽 = 点宽 = 1710（有效 1x）。按 2 倍申请输出尺寸时，
                // SCK 会把 431×505 的选区**放大成 850×999**——整幅长截图被拉伸、发虚，
                // 正是用户说的「十分怪异、有拉伸效果」。
                // ShareX 也是这个口径：scalingFactor = PhysicalScreenHeight / LogicalScreenHeight。
                let pixelRatio = display.frame.width > 0
                    ? CGFloat(display.width) / display.frame.width
                    : 1
                let scale = max(1, pixelRatio)

                let cfg = SCStreamConfiguration()
                cfg.sourceRect = local
                cfg.width = max(2, Int((local.width * scale).rounded()))
                cfg.height = max(2, Int((local.height * scale).rounded()))
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = false
                cfg.queueDepth = 5
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // 30fps
                // 尺寸与选区同比，不允许 SCK 自己再缩放（避免各向异性拉伸）
                cfg.scalesToFit = false

                let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()

                self.lock.lock()
                self.stream = s
                self.connected = true
                self.lock.unlock()
                Log.info("Capture", "长截图帧流已启动 \(cfg.width)×\(cfg.height)@30fps"
                         + "（选区 \(Int(local.width))×\(Int(local.height)) 点，倍率 \(String(format: "%.2f", scale))）")
            } catch {
                Log.warn("Capture", "长截图帧流启动失败（\(error.localizedDescription)）——回退同步抓屏")
            }
        }
    }

    func stop() {
        lock.lock()
        let s = stream
        stream = nil
        connected = false
        latest = nil
        lock.unlock()
        if let s { Task { try? await s.stopCapture() } }
    }

    /// 取最新一帧；帧龄超过 maxAge 视为无效（画面静止 / 流卡死），返回 nil
    func latestFrame(maxAge: CFAbsoluteTime = 0.5) -> CGImage? {
        lock.lock()
        let img = latest
        let at = latestAt
        lock.unlock()
        guard let img, CFAbsoluteTimeGetCurrent() - at <= maxAge else { return nil }
        return img
    }

    /// 最新帧的帧龄（秒）；从未出帧返回 .greatestFiniteMagnitude
    var latestFrameAge: CFAbsoluteTime {
        lock.lock()
        let at = latestAt
        lock.unlock()
        guard at > 0 else { return .greatestFiniteMagnitude }
        return CFAbsoluteTimeGetCurrent() - at
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var cg: CGImage?
        if VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cg) == noErr, let cg {
            if !loggedFrameSize {
                loggedFrameSize = true
                Log.info("Capture", "长截图首帧实际 \(cg.width)×\(cg.height)")
            }
            lock.lock()
            latest = cg
            latestAt = CFAbsoluteTimeGetCurrent()
            lock.unlock()
        }
    }
}
