import AppKit
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import Foundation

// MARK: - 屏幕快照来源

/// 一轮截图的时间预算（2026-11-24 v293）。
///
/// 旧实现每条通道各自写死 4s：原生 BMP 4s（超时）→ PNG 再 4s → SCK 再 4s，
/// 极端情况下一次截图会在关键路径上串行等 12s，用户只看到「按了没反应」。
/// 现在整轮共用一个 deadline，各通道只拿「剩余时间」，绝不叠加。
struct CaptureBudget: Sendable {
    /// 单调时钟 deadline（uptimeNanoseconds）
    let deadline: UInt64
    /// 冻结阶段预算：双屏空闲实测 <500ms，高负载留足余量。
    /// 取值依据见 docs/40-修改记录 本轮截图专项；不是「越短越好」，
    /// 太短会把高负载下本来正常的画面误判成失败。
    static let freezeSeconds: Double = 2.4
    /// 单通道上限：不能因为整轮还有预算就让某一条通道独占。
    static let channelSeconds: Double = 4.0

    static func seconds(_ seconds: Double) -> CaptureBudget {
        CaptureBudget(deadline: DispatchTime.now().uptimeNanoseconds
                      + UInt64(max(0.1, seconds) * 1_000_000_000))
    }

    /// 剩余秒数（可为负）
    var remaining: Double {
        (Double(deadline) - Double(DispatchTime.now().uptimeNanoseconds)) / 1_000_000_000
    }

    var expired: Bool { remaining <= 0 }
}


/// 抓屏通道：
/// - ScreenCaptureKit（macOS 14+）：原作技术栈（otool 实证已链接该框架），异步、不含光标；
/// - CGWindowListCreateImage：低版本回退，同步，覆盖层快照（放大镜）也走这条路。
enum ScreenSnapshot {

    private final class SynchronousImageResult: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?

        func store(_ image: CGImage?) {
            lock.lock()
            self.image = image
            lock.unlock()
        }

        func load() -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return image
        }
    }

    // MARK: 旧 API 兼容层（2026-10-18 修复「长截屏不可用 / 区域截图黑屏」）
    //
    // `CGWindowListCreateImage` 在 macOS 15.0 被系统 obsoleted（SDK 标注，
    // 运行时直接返回 nil）——长截图采帧（LongScreenshotSession.captureFrame）
    // 与区域截图/长截图选区快照全依赖它，导致：
    //   · 长截图：采帧连续失败 → state=.failed → "长截图采捕连续失败，会话终止"
    //   · 区域截图：覆盖层底图 nil → 确认后 "截图失败"
    // 系统兼容实现仍在（dlsym 实测 macOS 15 返回有效图，2x Retina），
    // 与引擎侧 frset_barwidgets.m 用 dlsym 取 CGDisplayCreateImageForRect 同款手法。
    private typealias LegacyCreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let legacyCreateImage: LegacyCreateImageFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: LegacyCreateImageFn.self)
    }()

    /// 旧 API 的动态入口（保留原始 option 值；系统未移除时与原生调用等价）
    static func legacyCapture(rect: CGRect,
                              option: CGWindowListOption,
                              windowID: CGWindowID = 0,
                              imageOption: CGWindowImageOption = [.bestResolution]) -> CGImage? {
        guard let fn = legacyCreateImage else { return nil }
        return fn(rect, option.rawValue, UInt32(windowID), imageOption.rawValue)?.takeRetainedValue()
    }

    /// 同步抓屏（覆盖层快照 / 回退路径都用）
    static func cgCapture(rect: CGRect) -> CGImage? {
        legacyCapture(rect: rect, option: .optionOnScreenOnly, imageOption: [.bestResolution])
    }

    /// NSScreen.frame（左下原点、Y 向上）→ CG 全局显示坐标（主屏左上角为原点、Y 向下）。
    /// 单屏或横向排列时结果与 frame 一致；垂直堆叠的多屏必须转换，否则抓屏区域会错位。
    static func cgRect(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX,
                      y: primaryHeight - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    /// 抓取整块屏幕（含多屏坐标转换）
    static func cgCapture(screen: NSScreen) -> CGImage? {
        cgCapture(rect: cgRect(for: screen))
    }

    /// 一次 32×32 缩略采样同时给出「尺寸/透明度可用」与「是否纯色」。
    ///
    /// 2026-11-23：旧实现为同一张 7.6MP 整屏图各画一次 16×16（透明度）和 32×32（纯色），
    /// 两次全图缩放都在截图关键路径上。现在合并成一次，并把插值固定 `.none`
    /// （默认高质量缩放会把整张 3420×2224 重新采样一遍，满载时是几十毫秒）。
    /// 判定阈值按采样点数等比换算：244/256 → 976/1024。
    struct ImageProbe {
        let usable: Bool
        let monochrome: SIMD3<Int>?
    }

    static func probe(_ image: CGImage, size: CGSize, opaque: Bool = true) -> ImageProbe {
        guard size.width > 0, size.height > 0,
              CGFloat(image.width) >= size.width, CGFloat(image.height) >= size.height,
              abs(CGFloat(image.width) / CGFloat(image.height) - size.width / size.height) <= 0.02 else {
            return ImageProbe(usable: false, monochrome: nil)
        }
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                      bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return ImageProbe(usable: true, monochrome: nil) }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let pixels = data.bindMemory(to: UInt8.self, capacity: 32 * 32 * 4)
        var opaqueCount = 0
        var anyAlpha = false
        var minimum = [255, 255, 255]
        var maximum = [0, 0, 0]
        for index in 0..<1024 {
            let offset = index * 4
            let alpha = Int(pixels[offset + 3])
            if alpha >= 240 { opaqueCount += 1 }
            if alpha > 0 { anyAlpha = true }
            for channel in 0..<3 {
                let value = Int(pixels[offset + channel])
                minimum[channel] = min(minimum[channel], value)
                maximum[channel] = max(maximum[channel], value)
            }
        }
        let usable = opaque ? opaqueCount >= 976 : anyAlpha
        var monochrome: SIMD3<Int>?
        if (0..<3).allSatisfy({ maximum[$0] - minimum[$0] <= 1 }) {
            monochrome = SIMD3((minimum[0] + maximum[0]) / 2,
                               (minimum[1] + maximum[1]) / 2,
                               (minimum[2] + maximum[2]) / 2)
        }
        return ImageProbe(usable: usable, monochrome: monochrome)
    }

    static func isUsableImage(_ image: CGImage, size: CGSize, opaque: Bool = true) -> Bool {
        probe(image, size: size, opaque: opaque).usable
    }

    static func windowImageMatchesFrozen(_ image: CGImage, frozen: CGImage,
                                         windowRect: CGRect, clickPoint: CGPoint,
                                         screenFrame: CGRect) -> Bool {
        guard image.width > 0, image.height > 0, frozen.width > 0, frozen.height > 0,
              windowRect.width > 0, windowRect.height > 0,
              screenFrame.width > 0, screenFrame.height > 0 else { return false }
        let visibleRect = windowRect.intersection(screenFrame)
        guard visibleRect.contains(clickPoint) else { return false }
        let clickX = min(max(Int((clickPoint.x - windowRect.minX) / windowRect.width
                                 * CGFloat(image.width)), 0), image.width - 1)
        let clickY = min(max(Int((windowRect.maxY - clickPoint.y) / windowRect.height
                                 * CGFloat(image.height)), 0), image.height - 1)
        let frozenClickX = min(max(Int((clickPoint.x - screenFrame.minX) / screenFrame.width
                                       * CGFloat(frozen.width)), 0), frozen.width - 1)
        let frozenClickY = min(max(Int((screenFrame.maxY - clickPoint.y) / screenFrame.height
                                       * CGFloat(frozen.height)), 0), frozen.height - 1)
        guard let clicked = pixelColor(image, x: clickX, y: clickY),
              let frozenClicked = pixelColor(frozen, x: frozenClickX, y: frozenClickY),
              sameColor(clicked, frozenClicked) else { return false }
        for fy in [0.25, 0.5, 0.75] {
            for fx in [0.25, 0.5, 0.75] {
                let screenX = visibleRect.minX + visibleRect.width * fx
                let screenY = visibleRect.maxY - visibleRect.height * fy
                let imageX = min(max(Int((screenX - windowRect.minX) / windowRect.width
                                         * CGFloat(image.width)), 0), image.width - 1)
                let imageY = min(max(Int((windowRect.maxY - screenY) / windowRect.height
                                         * CGFloat(image.height)), 0), image.height - 1)
                let frozenX = min(max(Int((screenX - screenFrame.minX) / screenFrame.width
                                          * CGFloat(frozen.width)), 0), frozen.width - 1)
                let frozenY = min(max(Int((screenFrame.maxY - screenY) / screenFrame.height
                                          * CGFloat(frozen.height)), 0), frozen.height - 1)
                guard let candidate = pixelColor(image, x: imageX, y: imageY),
                      let reference = pixelColor(frozen, x: frozenX, y: frozenY),
                      sameColor(candidate, reference) else { return false }
            }
        }
        return true
    }

    /// 截图代次（2026-11-23）：连按快捷键时，上一轮的 screencapture 必须能被叫停。
    /// 旧实现只挡「旧图不铺覆盖层」，进程仍在跑，和新的抢 WindowServer —— 越按越慢。
    private final class CaptureEpochCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }

        func isCurrent(_ candidate: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return value == candidate
        }
    }

    private static let epochCounter = CaptureEpochCounter()

    static func beginEpoch() -> Int { epochCounter.next() }
    static func isCurrentEpoch(_ epoch: Int) -> Bool { epochCounter.isCurrent(epoch) }

    /// 通知卡排除信息（由调用方在关键路径外查一次，避免每屏一次主线程往返）
    enum ToastExclusion {
        case unknown
        case none
        case visible(CGRect)
    }

    private static func sameColor(_ lhs: SIMD3<Int>, _ rhs: SIMD3<Int>) -> Bool {
        abs(lhs.x - rhs.x) <= 3 && abs(lhs.y - rhs.y) <= 3 && abs(lhs.z - rhs.z) <= 3
    }

    private static func averageDifference(_ lhs: CGImage, _ rhs: CGImage,
                                          screenFrame: CGRect, excluding rect: CGRect? = nil) -> Double? {
        guard let a = ImageProcessor.rgbaBuffer(lhs, targetWidth: 32),
              let b = ImageProcessor.rgbaBuffer(rhs, targetWidth: 32),
              a.width == b.width, a.height == b.height,
              screenFrame.width > 0, screenFrame.height > 0 else { return nil }
        var total = 0
        var samples = 0
        for index in 0..<(a.width * a.height) {
            let column = index % a.width
            let row = index / a.width
            let point = CGPoint(x: screenFrame.minX + (CGFloat(column) + 0.5) / CGFloat(a.width) * screenFrame.width,
                                y: screenFrame.maxY - (CGFloat(row) + 0.5) / CGFloat(a.height) * screenFrame.height)
            if let rect, rect.contains(point) { continue }
            for channel in 0..<3 {
                let offset = index * 4 + channel
                total += abs(Int(a.pixels[offset]) - Int(b.pixels[offset]))
            }
            samples += 1
        }
        return samples > 0 ? Double(total) / Double(samples * 3) : nil
    }

    private static func pixelColor(_ image: CGImage, x: Int, y: Int) -> SIMD3<Int>? {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        return bytes.withUnsafeMutableBytes { buffer -> SIMD3<Int>? in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let channels = buffer.bindMemory(to: UInt8.self)
            return SIMD3(Int(channels[0]), Int(channels[1]), Int(channels[2]))
        }
    }

    /// 在激活应用前交叉核对原生与 SCK 冻结帧；Retina 原生图仅在画面对照通过时使用。
    ///
    /// 2026-11-23：加两件事——① 代次取消（旧轮次的 screencapture 直接终止）；
    /// ② 单通道阶段计时（通道 / displayID / 毫秒 / 像素），用来定位真实瓶颈，
    /// 日志只记这些元数据，不记任何画面内容。
    static func captureScreenForScreenshot(_ screen: NSScreen,
                                           epoch: Int? = nil,
                                           toast: ToastExclusion = .unknown,
                                           budget: CaptureBudget? = nil) async -> CGImage? {
        let started = DispatchTime.now().uptimeNanoseconds
        let screenFrame = screen.frame
        let displayID = displayID(of: screen)
        let toastFrame: CGRect?
        switch toast {
        case .unknown:
            toastFrame = await MainActor.run { MenuBarToastManager.shared.captureExcludedWindowFrame }
        case .none:
            toastFrame = nil
        case .visible(let rect):
            toastFrame = rect
        }
        let toastVisible = toastFrame != nil
        let shouldCancel: () -> Bool = {
            if let epoch, !isCurrentEpoch(epoch) { return true }
            if let budget, budget.expired { return true }
            return false
        }
        var probeMs: Double = 0   // v292 B1：32×32 校验累计耗时（native + SCK 两段）
        func finish(_ image: CGImage?, _ channel: String) -> CGImage? {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            Log.info("Capture", String(format: "%@ D%@ %.0fms %@ · 校验 %.1fms", channel,
                                       displayID.map { String($0) } ?? "?",
                                       ms,
                                       image.map { "\($0.width)×\($0.height)px" } ?? "无可用图像",
                                       probeMs))
            return image
        }
        if shouldCancel() { return nil }
        let nativeDisplayIndex = displayID.flatMap(screencaptureDisplayIndex(for:))
        let native: CGImage?
        if let nativeDisplayIndex {
            let channel = NativeRegionCapture.ChannelLimit(
                seconds: min(CaptureBudget.channelSeconds, budget?.remaining ?? CaptureBudget.channelSeconds))
            native = await Task.detached(priority: .userInitiated) {
                NativeRegionCapture.captureScreenOnDisplay(index: nativeDisplayIndex,
                                                           isCancelled: shouldCancel,
                                                           limit: channel)
            }.value
        } else {
            native = nil
        }
        let nativeProbeStart = DispatchTime.now().uptimeNanoseconds
        let nativeProbe = native.map { probe($0, size: screenFrame.size) }
        probeMs += Double(DispatchTime.now().uptimeNanoseconds - nativeProbeStart) / 1_000_000
        let usableNative = nativeProbe?.usable == true ? native : nil
        let nativeColor = nativeProbe?.monochrome
        if !toastVisible, let usableNative, nativeColor == nil {
            return finish(usableNative, "冻结帧 screencapture")
        }
        if shouldCancel() { return nil }
        let sck: CGImage?
        if toastVisible {
            if #available(macOS 14.0, *), let displayID {
                sck = await Task.detached(priority: .userInitiated) {
                    sckCaptureSync(displayID: displayID)
                }.value
            } else {
                sck = nil
            }
        } else {
            sck = await captureScreenAdaptive(screen: screen)
        }
        let sckProbeStart = DispatchTime.now().uptimeNanoseconds
        let sckProbe = sck.map { probe($0, size: screenFrame.size) }
        probeMs += Double(DispatchTime.now().uptimeNanoseconds - sckProbeStart) / 1_000_000
        let usableSCK = sckProbe?.usable == true ? sck : nil
        if let usableSCK, let usableNative {
            if toastVisible {
                if let difference = averageDifference(usableSCK, usableNative,
                                                      screenFrame: screenFrame, excluding: toastFrame),
                   difference > 18 {
                    Log.error("Capture", "排除通知卡区域后两路整屏图仍不一致，取消截图")
                    return finish(nil, "冻结帧对照失败")
                }
                return finish(usableSCK, "冻结帧 SCK（通知卡排除）")
            }
            let sckColor = sckProbe?.monochrome
            if let sckColor, let nativeColor, !sameColor(sckColor, nativeColor) {
                Log.error("Capture", "两路整屏图均为纯色且颜色不一致，取消截图")
                return finish(nil, "冻结帧对照失败")
            }
            if sckColor != nil, nativeColor == nil {
                return finish(usableNative, "冻结帧 screencapture")
            }
            if nativeColor != nil, sckColor == nil {
                return finish(usableSCK, "冻结帧 SCK")
            }
            let difference = averageDifference(usableSCK, usableNative, screenFrame: screenFrame)
            if let difference, difference > 18 {
                Log.error("Capture", "SCK 与原生整屏图画面对照差异过大，取消截图")
                return finish(nil, "冻结帧对照失败")
            }
            if difference != nil {
                return finish(usableNative, "冻结帧对照一致")
            }
            Log.warn("Capture", "画面对照缓存不可用，保留先冻结的 SCK 画面")
            return finish(usableSCK, "冻结帧 SCK")
        }
        if let usableSCK {
            Log.warn("Capture", "原生抓屏失败或图像异常，使用 SCK 冻结帧 \(usableSCK.width)×\(usableSCK.height)px")
            return finish(usableSCK, "冻结帧 SCK（回退）")
        }
        if let usableNative {
            Log.warn("Capture", "SCK 抓屏失败或图像异常，使用同屏原生冻结帧 \(usableNative.width)×\(usableNative.height)px")
            return finish(usableNative, "冻结帧 screencapture（回退）")
        }
        Log.error("Capture", "SCK 与原生整屏抓取均无可用图像，取消截图")
        return finish(nil, "冻结帧失败")
    }

    /// NSScreen → CGDirectDisplayID
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    static func screencaptureDisplayIndex(for displayID: CGDirectDisplayID) -> Int? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard displayIDs.withUnsafeMutableBufferPointer({
            CGGetOnlineDisplayList(count, $0.baseAddress, &count)
        }) == .success else { return nil }
        let ordered = [CGMainDisplayID()] + displayIDs.prefix(Int(count)).filter { $0 != CGMainDisplayID() }
        guard let index = ordered.firstIndex(of: displayID) else { return nil }
        return index + 1
    }

    // MARK: v162 抓屏通道自适应（按系统版本选 API，杜绝「新版系统上主线程同步调 legacy」类死锁）
    //
    // 事实矩阵（真机采样/档案证据）：
    //   · macOS 27：legacy 主线程同步 = 死锁（SLSWindowListCreateImageProxying 主队列回环）；
    //               legacy 后台线程 = 返回 nil（系统已废）；SCK 异步 = 唯一可用通道
    //   · macOS 15：legacy dlsym 实测仍返回有效图（SDK 已标 obsoleted）
    //   · macOS <14：无 ScreenCaptureKit，legacy 是唯一通道（同步直连 WindowServer，无代理死锁）
    // 策略：14+ 一律 SCK 异步优先（全版本可用且不含光标），legacy 只做后台兜底；
    //      <14 legacy 后台调用（统一后台纪律，防未来版本再把 legacy 代理化后重演死锁）。
    // 覆盖开关：环境变量 FRSET_CAPTURE_CHANNEL=sck|legacy 可强制指定（排障用）。
    enum CaptureChannel: String {
        case sckAsync = "SCK异步"
        case legacyBackground = "legacy后台"
    }

    /// 当前系统应使用的首选通道
    static var preferredChannel: CaptureChannel {
        switch ProcessInfo.processInfo.environment["FRSET_CAPTURE_CHANNEL"]?.lowercased() {
        case "sck": return .sckAsync
        case "legacy": return .legacyBackground
        default: break
        }
        if #available(macOS 14.0, *) { return .sckAsync }
        return .legacyBackground
    }

    private static var channelLogged = false

    /// 自适应抓屏总入口（异步，主线程安全）：截图族所有 UI 快照统一走这里
    static func captureScreenAdaptive(screen: NSScreen) async -> CGImage? {
        let channel = preferredChannel
        if !channelLogged {
            channelLogged = true
            let v = ProcessInfo.processInfo.operatingSystemVersion
            Log.info("Capture", "抓屏通道自适应：macOS \(v.majorVersion).\(v.minorVersion) → \(channel.rawValue)"
                + (channel == .sckAsync ? "（legacy 仅后台兜底）" : "（无 SCK，legacy 后台直抓）"))
        }
        switch channel {
        case .sckAsync:
            if #available(macOS 14.0, *), let displayID = displayID(of: screen) {
                if let image = await Task.detached(priority: .userInitiated, operation: {
                    sckCaptureSync(displayID: displayID)
                }).value { return image }
                Log.warn("Capture", "SCK 整屏抓取失败或超时，回退同屏 legacy 通道")
            }
            return await Task.detached(priority: .userInitiated) { cgCapture(screen: screen) }.value
        case .legacyBackground:
            return await Task.detached(priority: .userInitiated) { cgCapture(screen: screen) }.value
        }
    }

    /// v162：legacy 通道运行时存活探针（逐帧采捕等高频路径用）。nil=未探测；
    /// false=该系统上已失效（返回 nil，如 macOS 26/27）；true=可用（如 ≤15）。
    private static var legacyAlive: Bool?

    /// 带存活记账的 legacy 抓屏：首次 nil 记「该系统 legacy 已废」，此后调用方可直接换通道
    static func legacyCaptureProbed(rect: CGRect,
                                    option: CGWindowListOption,
                                    windowID: CGWindowID = 0,
                                    imageOption: CGWindowImageOption = [.bestResolution]) -> CGImage? {
        let img = legacyCapture(rect: rect, option: option, windowID: windowID, imageOption: imageOption)
        if img != nil {
            legacyAlive = true
        } else if legacyAlive == nil {
            legacyAlive = false
        }
        return img
    }

    /// legacy 是否已被运行时证实失效（false = 未探测或仍可用）
    static var isLegacyKnownDead: Bool { legacyAlive == false }

    /// 同步版 ScreenCaptureKit 抓整屏（v108：长截图采帧用）。
    /// legacy dlsym 路径在 macOS 15+ 被移除后返回 nil（实测 macOS 27 采帧
    /// 连续失败 → 无有效画布）；此封装在**后台队列**信号量等待异步 SCK，
    /// 禁止主线程调用。
    @available(macOS 14.0, *)
    static func sckCaptureSync(displayID: CGDirectDisplayID) -> CGImage? {
        let sem = DispatchSemaphore(value: 0)
        let result = SynchronousImageResult()
        let task = Task.detached(priority: .userInitiated) {
            result.store(try? await sckCapture(displayID: displayID))
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 4) == .success else {
            task.cancel()
            Log.warn("Capture", "ScreenCaptureKit 整屏抓取超时")
            return nil
        }
        return result.load()
    }

    @available(macOS 14.0, *)
    static func sckCaptureWindowSync(windowID: CGWindowID) -> CGImage? {
        let sem = DispatchSemaphore(value: 0)
        let result = SynchronousImageResult()
        let task = Task.detached(priority: .userInitiated) {
            result.store(try? await sckCapture(windowID: windowID))
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 4) == .success else {
            task.cancel()
            Log.warn("Capture", "ScreenCaptureKit 窗口抓取超时")
            return nil
        }
        return result.load()
    }

    /// ScreenCaptureKit 抓整屏（macOS 14+）
    /// v166.7：这条通道**只作为兜底**（原生像素走 NativeRegionCapture）。
    /// 实测 SCK 在这台机器上只能拿到 1x 源，把输出尺寸写成 2 倍只会插值放大
    /// （锐度 7.14 vs 真 2x 的 12.8）——所以这里保持 1x，宁小勿糊。
    @available(macOS 14.0, *)
    static func sckCapture(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.captureFailed
        }
        let toastID = await MainActor.run { MenuBarToastManager.shared.captureExcludedWindowID }
        let excluded = content.windows.filter { $0.windowID == toastID }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        if #available(macOS 26.0, *), toastID != nil {
            let config = SCScreenshotConfiguration()
            config.showsCursor = false
            config.displayIntent = .local
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            guard let image = output.sdrImage else { throw CaptureError.captureFailed }
            return image
        }
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// ScreenCaptureKit 窗口级抓取（v112 窗口截图用；desktopIndependentWindow
    /// 只含该窗口本身、自动排除遮挡在其上的其他窗口——区域裁剪做不到这点）
    @available(macOS 14.0, *)
    static func sckCapture(windowID: CGWindowID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.captureFailed
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // 同上：window.frame 是点，乘 scale 只是放大，保持 1:1
        config.width = max(1, Int(window.frame.width))
        config.height = max(1, Int(window.frame.height))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
