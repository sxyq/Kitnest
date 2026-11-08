import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import ScreenCaptureKit

// MARK: - 录屏器（v264 · C 档）
//
// 一条 SCStream 直接进 AVAssetWriter，默认**不合成**（原始帧直通，最省 CPU）；
// 只有开了「摄像头画中画 / 显示按键 / 点击动画」才走 Core Image 合成路径。
//
// 几个刻意的取舍：
//   · 音频只允许「系统声音」或「麦克风」二选一：两条音轨在 mp4 里多数播放器只放第一条，
//     用户会以为没录上；二选一的行为是可解释的。
//   · 暂停 = 丢帧但 PTS 继续走：播放时表现为「画面停住」，不需要重排时间轴。
//   · 合成只画小画布（键帽条 / 点击环），不做全画布绘制——4K 全画布一帧 33MB。

public enum RecordingError: LocalizedError {
    case permissionDenied
    case noDisplay
    case writerFailed(String)
    case streamFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "没有屏幕录制权限，无法录屏"
        case .noDisplay:        return "找不到可录制的显示器"
        case .writerFailed(let m): return "写入失败：\(m)"
        case .streamFailed(let m): return "录制中断：\(m)"
        }
    }
}

// MARK: - 采集 / 写盘管线（后台队列）

final class RecordingPipeline: NSObject, SCStreamOutput, SCStreamDelegate,
                               AVCaptureVideoDataOutputSampleBufferDelegate,
                               AVCaptureAudioDataOutputSampleBufferDelegate {

    private let options: RecordingOptions
    private let outputURL: URL
    private let videoSize: CGSize
    /// 录制区域左上角（CG 全局坐标，左上原点）——点击坐标换算用
    private let regionOrigin: CGPoint
    /// 视频像素 / 屏幕点
    private let pixelScale: CGFloat

    private let queue = DispatchQueue(label: "kitnest.recording.pipeline")
    private let audioQueue = DispatchQueue(label: "kitnest.recording.audio")
    private let cameraQueue = DispatchQueue(label: "kitnest.recording.camera")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var paused = false

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    private var cameraSession: AVCaptureSession?
    private var micSession: AVCaptureSession?
    private var latestCamera: CVPixelBuffer?
    private let cameraLock = NSLock()

    private(set) var isRunning = false

    init(options: RecordingOptions, videoSize: CGSize, regionOrigin: CGPoint,
         pixelScale: CGFloat, outputURL: URL) {
        self.options = options
        self.videoSize = videoSize
        self.regionOrigin = regionOrigin
        self.pixelScale = pixelScale
        self.outputURL = outputURL
        super.init()
    }

    // MARK: 写盘

    func prepareWriter() throws {
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        let w = Int(max(2, videoSize.width.rounded()))
        let h = Int(max(2, videoSize.height.rounded()))
        let bitrate = min(24_000_000, max(4_000_000, Int(Double(w * h) * 0.12)))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecordingError.writerFailed("无法添加视频轨")
            }
            writer.add(input)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: w,
                    kCVPixelBufferHeightKey as String: h,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ])
            if options.audio != .none {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) { writer.add(aInput); audioInput = aInput }
            }
            guard writer.startWriting() else {
                throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
            }
            self.writer = writer
            self.videoInput = input
            self.adaptor = adaptor
            Log.info("Recording", "写入器就绪：\(w)×\(h) @\(options.fps)fps 码率 \(bitrate / 1000)kbps 音频=\(options.audio.rawValue)")
        } catch let error as RecordingError {
            throw error
        } catch {
            throw RecordingError.writerFailed(error.localizedDescription)
        }
    }

    func setPaused(_ value: Bool) {
        queue.async { self.paused = value }
    }

    /// 收尾：标记结束 → 等 finishWriting → 返回文件
    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.isRunning = false
                self.stopDevices()
                guard let writer = self.writer, writer.status == .writing else {
                    continuation.resume(returning: nil)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    let ok = writer.status == .completed
                    if !ok {
                        Log.error("Recording", "finishWriting 失败：\(writer.error?.localizedDescription ?? "?")")
                    }
                    continuation.resume(returning: ok ? self.outputURL : nil)
                }
            }
        }
    }

    // MARK: 设备（摄像头 / 麦克风）

    func startCamera() {
        guard options.cameraEnabled else { return }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high
        let device = options.cameraDeviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            Log.warn("Recording", "摄像头不可用，跳过画中画")
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: cameraQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        cameraSession = session
        Log.info("Recording", "摄像头画中画：\(device.localizedName)")
    }

    func startMicrophone() {
        guard options.audio == .microphone else { return }
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Log.warn("Recording", "麦克风不可用")
            return
        }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        micSession = session
    }

    private func stopDevices() {
        cameraSession?.stopRunning()
        cameraSession = nil
        micSession?.stopRunning()
        micSession = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Recording", "SCStream 中止：\(error.localizedDescription)")
        isRunning = false
    }

    // MARK: 视频

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let writer, writer.status == .writing,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        if paused { return }

        let needsComposite = options.cameraEnabled || options.showKeys || options.showClicks
        if !needsComposite {
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
            return
        }

        guard let adaptor, let pool = adaptor.pixelBufferPool,
              videoInput?.isReadyForMoreMediaData == true else { return }
        var dest: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dest)
        guard let dest else { return }

        var image = CIImage(cvPixelBuffer: imageBuffer)
        let now = CACurrentMediaTime()

        // 摄像头画中画
        if options.cameraEnabled, let cam = currentCameraBuffer() {
            let rect = RecordingCompositor.cameraRect(videoSize: videoSize,
                                                       corner: options.cameraCorner,
                                                       widthFraction: options.cameraScale)
            var ci = CIImage(cvPixelBuffer: cam)
            let sx = rect.width / max(ci.extent.width, 1)
            let sy = rect.height / max(ci.extent.height, 1)
            ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            // CIImage 左下原点：把「左上坐标」翻过来
            ci = ci.transformed(by: CGAffineTransform(translationX: rect.minX,
                                                      y: videoSize.height - rect.maxY))
            image = ci.composited(over: image)
        }

        // 点击动画
        if options.showClicks {
            for click in RecordingInputMonitor.shared.currentClicks(now: now) {
                let progress = CGFloat((now - click.time) / RecordingInputMonitor.clickTTL)
                guard let ring = RecordingCompositor.clickOverlay(progress: progress,
                                                                  isRight: click.isRight,
                                                                  pixelScale: pixelScale) else { continue }
                let side = CGFloat(ring.width)
                let cx = (click.point.x - regionOrigin.x) * pixelScale
                let cy = (click.point.y - regionOrigin.y) * pixelScale
                guard cx > -side, cy > -side, cx < videoSize.width + side, cy < videoSize.height + side else { continue }
                var ci = CIImage(cgImage: ring)
                ci = ci.transformed(by: CGAffineTransform(translationX: cx - side / 2,
                                                          y: videoSize.height - cy - side / 2))
                image = ci.composited(over: image)
            }
        }

        // 按键条
        if options.showKeys {
            let keys = RecordingInputMonitor.shared.currentKeys(now: now)
            if let strip = RecordingCompositor.keyOverlay(keys: keys, now: now, pixelScale: pixelScale) {
                let w = CGFloat(strip.width)
                var ci = CIImage(cgImage: strip)
                ci = ci.transformed(by: CGAffineTransform(translationX: (videoSize.width - w) / 2,
                                                          y: 28 * pixelScale))
                image = ci.composited(over: image)
            }
        }

        let bounds = CGRect(origin: .zero, size: videoSize)
        ciContext.render(image, to: dest, bounds: bounds, colorSpace: colorSpace)
        if !adaptor.append(dest, withPresentationTime: pts) {
            Log.warn("Recording", "合成帧 append 失败：\(writer.error?.localizedDescription ?? "?")")
        }
    }

    private func currentCameraBuffer() -> CVPixelBuffer? {
        cameraLock.lock(); defer { cameraLock.unlock() }
        return latestCamera
    }

    // MARK: 音频

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard options.audio == .system, let audioInput,
              audioInput.isReadyForMoreMediaData else { return }
        if paused { return }
        audioInput.append(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            cameraLock.lock()
            latestCamera = pixelBuffer
            cameraLock.unlock()
            return
        }
        // 麦克风
        guard options.audio == .microphone, let audioInput,
              audioInput.isReadyForMoreMediaData else { return }
        if paused { return }
        audioInput.append(sampleBuffer)
    }
}

// MARK: - 对外录制器

@MainActor
public final class ScreenRecorder: ObservableObject {

    public enum State: Equatable {
        case idle, preparing, recording, paused, finishing
        public var isActive: Bool { self != .idle }
    }

    public static let shared = ScreenRecorder()

    @Published public private(set) var state: State = .idle
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var outputURL: URL?
    @Published public private(set) var errorText: String?

    private var stream: SCStream?
    private var pipeline: RecordingPipeline?
    private var timer: Timer?
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0
    private var currentOptions = RecordingOptions()

    private init() {}

    // MARK: 开始

    /// 整屏录制（鼠标所在屏幕）
    public func startDisplayRecording() {
        Task { await start(options: .current(displayID: currentDisplayID())) }
    }

    /// 区域录制：先框选，再开始
    public func startRegionRecording() {
        RecordingRegionPicker.shared.pick { [weak self] rect in
            guard let self else { return }
            Task { await self.start(options: .current(region: rect,
                                                      displayID: self.currentDisplayID())) }
        }
    }

    public func start(options: RecordingOptions) async {
        guard state == .idle else {
            Toast.show("正在录制中", icon: "record.circle")
            return
        }
        state = .preparing
        errorText = nil
        currentOptions = options

        guard await ScreenshotManager.shared.ensureScreenRecordingPermission() else {
            state = .idle
            return
        }
        if options.audio == .microphone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                Log.warn("Recording", "麦克风未授权，本次不录音")
            }
        }
        if options.cameraEnabled {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                Log.warn("Recording", "摄像头未授权，本次不启用画中画")
            }
        }

        do {
            let setup = try await makeStream(options: options)
            let url = uniqueOutputURL()
            let pipeline = RecordingPipeline(options: options,
                                             videoSize: setup.videoSize,
                                             regionOrigin: setup.regionOrigin,
                                             pixelScale: setup.pixelScale,
                                             outputURL: url)
            try pipeline.prepareWriter()
            let stream = SCStream(filter: setup.filter, configuration: setup.config, delegate: pipeline)
            try stream.addStreamOutput(pipeline, type: .screen, sampleHandlerQueue: setup.queue)
            if options.audio == .system {
                try stream.addStreamOutput(pipeline, type: .audio, sampleHandlerQueue: setup.queue)
            }
            pipeline.startCamera()
            pipeline.startMicrophone()
            try await stream.startCapture()

            self.pipeline = pipeline
            self.stream = stream
            outputURL = url

            if options.showKeys || options.showClicks {
                _ = RecordingInputMonitor.shared.start()
                RecordingInputMonitor.shared.reset()
            }

            startedAt = Date()
            accumulated = 0
            elapsed = 0
            state = .recording
            startTimer()
            RecordingHUDController.shared.show()

            // 排障：注入样例按键/点击，验证叠加合成路径（不需要辅助功能权限）
            if ProcessInfo.processInfo.environment["FRSET_RECORD_OVERLAY_PROBE"] == "1" {
                Task { @MainActor in
                    for _ in 0..<6 {
                        RecordingInputMonitor.shared.injectProbeEvents()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
            Log.info("Recording", "开始录制 \(Int(setup.videoSize.width))×\(Int(setup.videoSize.height)) → \(url.lastPathComponent)")
        } catch {
            state = .idle
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Log.error("Recording", "启动失败：\(error.localizedDescription)")
            Toast.show(errorText ?? "录屏启动失败", icon: "exclamationmark.triangle", isWarning: true)
        }
    }

    // MARK: 暂停 / 继续 / 停止

    public func pause() {
        guard state == .recording else { return }
        pipeline?.setPaused(true)
        if let startedAt { accumulated += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        state = .paused
        stopTimer()
        RecordingHUDController.shared.refresh()
    }

    public func resume() {
        guard state == .paused else { return }
        pipeline?.setPaused(false)
        startedAt = Date()
        state = .recording
        startTimer()
        RecordingHUDController.shared.refresh()
    }

    public func togglePause() {
        if state == .recording { pause() } else if state == .paused { resume() }
    }

    /// 停止并返回文件（失败返回 nil）
    @discardableResult
    public func stop() async -> URL? {
        guard state.isActive, state != .finishing else { return nil }
        state = .finishing
        stopTimer()
        RecordingHUDController.shared.hide()
        RecordingInputMonitor.shared.stop()

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        let file = await pipeline?.finish()
        pipeline = nil
        state = .idle
        startedAt = nil

        guard let file else {
            errorText = "录制文件写入失败"
            Toast.show("录制失败：文件没有写出来", icon: "exclamationmark.triangle", isWarning: true)
            return nil
        }
        outputURL = file
        let seconds = max(1, Int(elapsed.rounded()))
        Toast.show("录制完成 · \(seconds / 60):\(String(format: "%02d", seconds % 60))", icon: "checkmark.circle.fill")
        // 录制完成 → 打开编辑器（用户可直接裁剪 / 导出）
        RecordingEditorController.shared.open(url: file)
        return file
    }

    // MARK: 计时

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = self.accumulated + Date().timeIntervalSince(started)
                RecordingHUDController.shared.refresh()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: 流配置

    private struct StreamSetup {
        let filter: SCContentFilter
        let config: SCStreamConfiguration
        let videoSize: CGSize
        let regionOrigin: CGPoint
        let pixelScale: CGFloat
        let queue: DispatchQueue
    }

    private func makeStream(options: RecordingOptions) async throws -> StreamSetup {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == options.displayID })
                ?? content.displays.first else {
            throw RecordingError.noDisplay
        }
        let excluded = content.applications.filter {
            let id = $0.bundleIdentifier
            return !id.isEmpty && options.excludedBundleIDs.contains(id)
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: excluded,
                                     exceptingWindows: [])

        let primaryH = NSScreen.screens.first?.frame.height ?? display.frame.height
        let pixelScale = CGFloat(display.width) / max(display.frame.width, 1)

        // 录制区域（AppKit 全局，左下原点）→ CG 全局（左上原点）
        let appKitRegion = options.region ?? {
            // 默认：该显示器整屏
            CGRect(x: display.frame.minX,
                   y: primaryH - display.frame.maxY,
                   width: display.frame.width,
                   height: display.frame.height)
        }()
        let regionTop = CGRect(x: appKitRegion.minX,
                               y: primaryH - appKitRegion.maxY,
                               width: appKitRegion.width,
                               height: appKitRegion.height)

        let config = SCStreamConfiguration()
        config.width = Int((regionTop.width * pixelScale).rounded())
        config.height = Int((regionTop.height * pixelScale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = false
        config.showsCursor = options.showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 6
        config.capturesAudio = options.audio == .system
        if options.audio == .system {
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        // sourceRect 用**显示器本地坐标（points）**
        let localX = regionTop.minX - display.frame.minX
        let localY = regionTop.minY - display.frame.minY
        if options.region != nil {
            config.sourceRect = CGRect(x: localX, y: localY,
                                       width: regionTop.width, height: regionTop.height)
        }
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        Log.info("Recording", "采集配置：\(config.width)×\(config.height)px 区域=\(Int(regionTop.width))×\(Int(regionTop.height))pt "
                 + "缩放=\(String(format: "%.2f", pixelScale)) 排除 App=\(excluded.count)")

        return StreamSetup(filter: filter,
                           config: config,
                           videoSize: CGSize(width: config.width, height: config.height),
                           regionOrigin: CGPoint(x: regionTop.minX, y: regionTop.minY),
                           pixelScale: pixelScale,
                           queue: DispatchQueue(label: "kitnest.recording.stream", qos: .userInitiated))
    }

    private func currentDisplayID() -> CGDirectDisplayID? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return nil }
        return ScreenSnapshot.displayID(of: screen)
    }

    private func uniqueOutputURL() -> URL {
        let dir = RecordingOptions.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = "Recording-\(fmt.string(from: Date()))"
        var url = dir.appendingPathComponent("\(base).mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(index).mp4")
            index += 1
        }
        return url
    }

    // MARK: 状态文案

    public var elapsedText: String {
        let total = Int(elapsed.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 供设置页 / 状态栏调用的统一入口
    public static func toggleRecording() {
        let recorder = ScreenRecorder.shared
        if recorder.state.isActive {
            Task { await recorder.stop() }
        } else {
            recorder.startDisplayRecording()
        }
    }
}
