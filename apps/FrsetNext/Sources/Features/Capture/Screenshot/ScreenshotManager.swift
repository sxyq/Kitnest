import AppKit
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import Foundation

// MARK: - 原生像素区域截图

/// 按「屏幕原生像素」截取一块区域。
///
/// v166.7（用户：「截图能否提高分辨率，跟屏幕原生像素一致」）：
/// 实测这台机器（1710×1112pt / scale 2 / 面板 2560×1664）几条通道的真实表现
/// （边缘能量越高越锐，系统截图约 12~15）：
///
/// | 通道 | 尺寸 | 锐度 |
/// |---|---|---|
/// | `screencapture -x`（整屏）| 3420×2224 | **12.38** ✅ 真 2x |
/// | `screencapture -x -R…` | 3420×2224 | 12.38 ✅ 但慢且不稳定（0.5~1.5s）|
/// | `screencapture -x **-o** -R…` | 3420×2224 | 8.34 ❌ 被降级成 1x 放大 |
/// | SCK（`captureResolution = .best`）| 3420×2224 | 7.14 ❌ 插值放大 |
/// | `CGDisplayCreateImage` | 3420×2224 | 8.31 ❌ 放大 |
/// | legacy `CGWindowListCreateImage(.bestResolution)` | 3466×2348 | 8.60 ❌ 放大 |
///
/// 结论：**只有整屏 `screencapture` 能拿到真 Retina 细节**，约 208ms。
/// 所以流程改成「整屏抓 → 内存里裁」，既避开 `-R` 的不稳定，也不要 `-o`。
/// 注意 `-o`（去窗口阴影）会让 screencapture 走另一条渲染路径、直接掉到 1x —— 别加。
enum NativeRegionCapture {

    /// 抓指定屏幕的整屏原生像素图（screencapture，同步 ~200ms，**禁止主线程调用**）
    static func captureScreen(_ screen: NSScreen) -> CGImage? {
        let idx = (NSScreen.screens.firstIndex(of: screen) ?? 0) + 1
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frset-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        if let img = run(arguments: ["-x", "-D\(idx)", tmp.path], tmp: tmp) { return img }
        // -D 索引在某些多屏布局下不匹配 → 退回不带 -D（抓主屏）
        return run(arguments: ["-x", tmp.path], tmp: tmp)
    }

    /// 按 AppKit 全局坐标（左下原点，点）截一块区域
    static func capture(appKitRect: CGRect) -> CGImage? {
        guard appKitRect.width >= 1, appKitRect.height >= 1 else { return nil }
        let screen = NSScreen.screens.first { $0.frame.intersects(appKitRect) } ?? NSScreen.main
        guard let screen, let full = captureScreen(screen) else { return nil }
        // crop 内部按 image.width / screenFrame.width 自适应缩放，
        // 所以 2x 整屏图裁出来就是 2x 区域
        return ImageProcessor.crop(full, rectInPoints: appKitRect, screenFrame: screen.frame)
    }

    private static func run(arguments: [String], tmp: URL) -> CGImage? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do { try task.run() } catch {
            Log.warn("Capture", "原生像素截图：启动 screencapture 失败 \(error.localizedDescription)")
            return nil
        }
        if done.wait(timeout: .now() + 4) == .timedOut {
            task.terminate()
            Log.warn("Capture", "原生像素截图：screencapture 超时")
            return nil
        }
        guard task.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        return img
    }
}

// MARK: - 屏幕快照来源

/// 抓屏通道：
/// - ScreenCaptureKit（macOS 14+）：原作技术栈（otool 实证已链接该框架），异步、不含光标；
/// - CGWindowListCreateImage：低版本回退，同步，覆盖层快照（放大镜）也走这条路。
enum ScreenSnapshot {

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

    /// NSScreen → CGDirectDisplayID
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
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
                if let img = try? await sckCapture(displayID: displayID) { return img }
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
        var img: CGImage?
        Task {
            img = try? await sckCapture(displayID: displayID)
            sem.signal()
        }
        sem.wait()
        return img
    }

    /// ScreenCaptureKit 抓整屏（macOS 14+）
    /// v166.7：这条通道**只作为兜底**（原生像素走 NativeRegionCapture）。
    /// 实测 SCK 在这台机器上只能拿到 1x 源，把输出尺寸写成 2 倍只会插值放大
    /// （锐度 7.14 vs 真 2x 的 12.8）——所以这里保持 1x，宁小勿糊。
    @available(macOS 14.0, *)
    static func sckCapture(displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.captureFailed
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
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

// MARK: - 截图管理器

/// 截图流程编排：权限 → 唤起覆盖层 → 选区 → 抓图 → 落盘 / 剪贴板 / OCR / 钉图。
/// 约定：所有公开方法在主线程调用（UI 触发），内部异步部分显式回到 Main Actor。
public final class ScreenshotManager: ObservableObject {
    public static let shared = ScreenshotManager()

    // MARK: 对外可观察状态

    @Published public private(set) var recent: [CapturedImage] = []
    @Published public private(set) var isCapturing = false
    @Published public var ocrText: String = ""
    @Published public var isRecognizing = false
    @Published public var statusMessage: String?
    /// 是否已获得屏幕录制权限（供 UI 显示提示条）
    @Published public private(set) var hasPermission: Bool = CGPreflightScreenCaptureAccess()
    /// 是否已完成一次「权威探测」（真实抓屏通道）
    private var permissionProbed = false
    /// 探测进行中（防重入）
    private var permissionProbing = false

    // MARK: 私有

    private var overlays: [ScreenshotOverlayWindow] = []
    // v128（内存优化）：原缩略图缓存无界，截图目录大时长期驻留只涨不落。
    // 加 countLimit=48 + totalCostLimit=20MB，写入按像素字节记账（w*h*4）。
    private let thumbCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 48
        c.totalCostLimit = 20 * 1024 * 1024
        return c
    }()
    /// 直接动作（热键直连：captureAndOCR/Pin/Copy）；toolbar = 框选后弹动作工具条
    private enum PendingFlow {
        case direct(CaptureDefaultAction)
        case toolbar
    }
    private var pendingFlow: PendingFlow = .direct(.save)
    /// 最近一次选区（AppKit 全局坐标，左下原点）——屏幕翻译钉回原位用
    private(set) var lastSelectionAppKit: CGRect = .zero
    /// v130（SnowShot 对齐）②：最近一次落盘截图的路径（OCR 文本回填历史库用）
    private var lastHistoryPath: String?
    /// v130②：本次截图的模式标签（历史库 mode 列；入口处设置）
    private var currentModeTag: String = "area"
    /// v130（SnowShot 对齐）⑤：最近一次识别到的二维码 payload（结果窗二维码页签用）
    @Published public private(set) var qrPayloads: [String] = []

    init() {
        reloadRecent()
        // v30（2026-10-18）：启动即打权限实况——TCC 授权按 code identity 校验，
        // ad-hoc 签名（cdhash）在重新构建后失效、证书签名（FrsetDev）跨构建保留。
        // 这行日志是"授权了却又提示没授权"类问题的第一判据。
        Log.info("Capture", "屏幕录制权限启动实况：\(CGPreflightScreenCaptureAccess() ? "已获得" : "未获得")（bundle=\(Bundle.main.bundleIdentifier ?? "?")）")
        // v77（2026-10-19 全盘排查）：启动不再用 SCK 探测。
        // `SCShareableContent` 属于屏幕录制 TCC 授权 API——放在 init 里会导致
        // **每次启动都请求一次权限**（用户实测「一直重复请求」）。改为只在用户
        // 真正发起截图/取色时按需探测（ensureScreenRecordingPermission）。
        // 启动只做 CGPreflight（纯查询，不弹窗）。

        // 排障：FRSET_TCC_REQUEST=1 或存在标记文件时主动发一次系统录屏请求。
        // 用途：TCC 记录被移除后，让系统按当前二进制重新建立记录（设置列表随之出现该 app）。
        // 标记文件方案用于经 LaunchServices（open/双击）启动的场景——环境变量传不进去。
        let tccMarker = "/tmp/frset_tcc_request_once"
        if ProcessInfo.processInfo.environment["FRSET_TCC_REQUEST"] == "1"
            || FileManager.default.fileExists(atPath: tccMarker) {
            try? FileManager.default.removeItem(atPath: tccMarker)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let granted = CGRequestScreenCaptureAccess()
                Log.info("Capture", "TCC 请求探针：granted=\(granted)")
            }
        }
    }

    // MARK: 偏好

    /// 默认动作（键不在 Core/Preferences.Keys 里，模块内自定义）
    private static let keyDefaultAction = "capture.defaultAction"
    /// OCR 完成后是否弹出结果窗
    private static let keyOCRResultWindow = "capture.ocrShowResultWindow"
    /// v130（SnowShot 对齐）④：延时截图秒数（3 / 5 / 10）
    private static let keyDelaySeconds = "capture.delaySeconds"

    /// v130④：延时截图秒数（设置 → 截图 → 延时截图）
    public var delaySeconds: Int {
        get { Preferences.shared.value(Self.keyDelaySeconds, default: 5) }
        set { Preferences.shared.set(Self.keyDelaySeconds, newValue) }
    }

    public var defaultAction: CaptureDefaultAction {
        get {
            let raw = Preferences.shared.value(Self.keyDefaultAction, default: CaptureDefaultAction.save.rawValue)
            return CaptureDefaultAction(rawValue: raw) ?? .save
        }
        set { Preferences.shared.set(Self.keyDefaultAction, newValue.rawValue) }
    }

    /// OCR 完成后是否自动弹出结果窗（默认开启，对齐原作「OCR 结果窗」）
    public var ocrShowResultWindow: Bool {
        get { Preferences.shared.value(Self.keyOCRResultWindow, default: true) }
        set { Preferences.shared.set(Self.keyOCRResultWindow, newValue) }
    }

    /// 保存目录：Preferences.captureSavePath；为空则用**下载目录**
    ///
    /// v228（用户：「保存是默认保存下载目录里面，然后设置里面可以去设置」）：
    /// 原来默认落到 App 私有目录（`AppDirectories.sub("screenshots")`），
    /// 用户在访达里根本找不到；改成系统下载目录，找不到再回退私有目录。
    public var saveDirectory: URL {
        let raw: String = Preferences.shared.value(Preferences.Keys.captureSavePath, default: "")
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? AppDirectories.sub("screenshots")
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// 暂存目录（App 私有）：截图一完成先落到这里，**只有用户点「保存」才复制到下载目录**。
    ///
    /// v235（用户：「点复制不需要放到下载目录，我点了保存才放」）：
    /// v228 把默认保存目录改成下载目录后，出动作条前的「先落盘」也写到了下载目录——
    /// 用户只是点复制/识别，下载目录里也会多一张图。这里把「暂存」和「用户保存」分开，
    /// 恢复到 v228 之前的行为：先私有暂存，显式保存才进下载目录。
    public var stagingDirectory: URL { AppDirectories.sub("screenshots") }

    // MARK: 权限

    /// 刷新权限状态（系统设置里授权后回来调用）
    public func refreshPermission() {
        // v77：设置页出现时只查 preflight（不弹窗）；权威探测留到用户点
        // 「前往授权」或真正截图时（probePermission 会走 SCK）。
        hasPermission = CGPreflightScreenCaptureAccess()
    }

    /// 权威权限探测：以「真实抓屏通道是否可用」为准，而不是只看 CGPreflight。
    ///
    /// 为什么（2026-10-18 用户实障，必须写清）：
    /// `CGPreflightScreenCaptureAccess()` 返回的是**TCC 记录与当前进程 code identity
    /// 的匹配结果**，在以下情形会**假阴性**（系统里明明已授权、抓屏也能成功，它却返回 false）：
    ///   · 应用刚被重新签名/替换，tccd/amfid 的校验缓存尚未刷新；
    ///   · 本工程用自签名证书 FrsetDev 签名，TCC 记录建立时的 csreq 与当前二进制
    ///     不完全一致（设置里开关仍是「开」）；
    ///   · 经 LaunchServices（双击）启动 vs 从终端直接启动，responsible process
    ///     归属不同，preflight 结果可能不同（实测：同一二进制同一时刻，终端启动
    ///     报“已获得”、双击启动报“未获得”）。
    /// 直接拿 preflight 当硬闸门 → 用户明明授权了，app 却反复弹「需要屏幕录制权限」。
    ///
    /// ScreenCaptureKit 的 `SCShareableContent` 只在系统**真正拒绝**录屏时抛错，
    /// 因此用它做权威判据：能枚举到显示器 = 权限真实可用 → UI 不再提示授权。
    @discardableResult
    public func probePermission() async -> Bool {
        if permissionProbing { return hasPermission }
        permissionProbing = true
        defer { permissionProbing = false }

        if CGPreflightScreenCaptureAccess() {
            await MainActor.run {
                self.hasPermission = true
                self.permissionProbed = true
            }
            Log.info("Capture", "权限探测：preflight=已获得")
            return true
        }

        var granted = false
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                granted = !content.displays.isEmpty
            } catch {
                granted = false
                Log.info("Capture", "权限探测：SCK 失败 \(error.localizedDescription)")
            }
        }
        await MainActor.run {
            self.hasPermission = granted
            self.permissionProbed = true
        }
        Log.info("Capture", "权限探测：preflight=未获得 SCK=\(granted ? "可用" : "不可用")")
        return granted
    }

    /// 本次启动是否已向系统发过录屏授权请求 / 已弹过说明
    private var didRequestScreenRecordingThisLaunch = false
    private var didShowPermissionAlertThisLaunch = false

    /// 检查屏幕录制权限；只有「真实抓屏也不可用」时才请求并弹说明。
    /// v77：`CGRequestScreenCaptureAccess()` 每次调用都会让系统再弹一次授权，
    /// 用户在没授权成功时反复截图 → 无限弹窗。现在**每次启动只请求一次**，
    /// 后续失败只提示去系统设置（不再重复请求）。
    @discardableResult
    public func ensureScreenRecordingPermission() async -> Bool {
        if hasPermission { return true }
        if await probePermission() { return true }
        await MainActor.run {
            if !self.didRequestScreenRecordingThisLaunch {
                self.didRequestScreenRecordingThisLaunch = true
                CGRequestScreenCaptureAccess()
            }
            if !self.didShowPermissionAlertThisLaunch {
                self.didShowPermissionAlertThisLaunch = true
                self.showPermissionAlert()
            } else {
                Toast.show("仍未获得屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制，勾选后重启应用",
                           icon: "exclamationmark.circle.fill")
            }
        }
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "截图功能需要系统授权。请打开 系统设置 → 隐私与安全性 → 屏幕录制，勾选本应用后重新启动。"
        alert.addButton(withTitle: "权限引导")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // v111：统一权限引导窗（四类权限总览；各失败点统一入口）
            PermissionGuideWindowController.shared.show()
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                // spec 13 §4：无法打开链接场景（原作 Unable to Open Link，open 返回 false 即失败）
                if !NSWorkspace.shared.open(url) {
                    Toast.show("无法打开链接", icon: "exclamationmark.circle.fill")
                }
            }
        default:
            break
        }
    }

    // MARK: 区域截图

    /// 区域截图（框选后弹动作工具条；关闭工具条开关则直接执行默认动作）
    public func captureRegion() { startRegionCapture(flow: .toolbar) }

    /// 截图后直接走 OCR（对应原作「截图并 OCR」入口）
    public func captureAndOCR() { startRegionCapture(flow: .direct(.ocr)) }

    /// 截图后直接钉图
    public func captureAndPin() { startRegionCapture(flow: .direct(.pin)) }

    /// 截图后直接复制到剪贴板（specs/19 默认热键 screenshotCopy 用；与 captureAndOCR/captureAndPin 同型）
    public func captureAndCopy() { startRegionCapture(flow: .direct(.clipboard)) }

    /// 截图后直接屏幕翻译（OCR→翻译→按坐标画回→钉回原位）
    public func captureAndScreenTranslate() { startRegionCapture(flow: .direct(.screenTranslate)) }

    private func startRegionCapture(flow: PendingFlow) {
        Task { @MainActor in
            guard await ensureScreenRecordingPermission() else { return }
            self.beginRegionCapture(flow: flow)
        }
    }

    @MainActor
    private func beginRegionCapture(flow: PendingFlow) {
        closeOverlays()
        pendingFlow = flow
        currentModeTag = "area"      // v130②：历史库模式标签
        isCapturing = true
        // v207（用户：「按快捷键截图应该立刻定格当前屏幕，不能先跳转界面/打断预览」）：
        // 这里绝对不能先 NSApp.activate —— 激活会让主面板/preview hover 窗先收起，
        // 等到真正抓帧时画面已经变了（鼠标停在预览上，预览消失）。
        // 顺序改为：先冻结抓帧（此时不改任何窗口状态）→ 再激活 App 并铺覆盖层。

        // v161（2026-10-29 修「⌘1 快捷截屏必定卡死」）：快照抓取移出主线程。
        // 根因（真机采样实锤）：macOS 27 上 legacy CGWindowListCreateImage 已被系统
        // 改造为 ScreenCaptureKit 代理（SLWindowListCreateImage →
        // SLSWindowListCreateImageProxying），内部把完成块派发回主队列后 signal
        // 信号量——主线程同步等待它 = 永久死锁（覆盖层都来不及建，整个 App 无响应）。
        // 修复：快照统一异步获取（SCK 优先），完成后再回主线程建覆盖层。
        Task { @MainActor in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let snapshots = await Self.acquireScreenSnapshots()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            Log.info("Capture", String(format: "区域截图快照冻结完成 %.0fms（抓帧前未改窗口状态）", ms))
            guard self.isCapturing else { return }   // 等待期间已被取消（如再次触发）
            // 画面已冻结，这时才激活 App 铺覆盖层；此后的窗口收起不会影响已抓到的帧
            if !snapshots.isEmpty { NSApp.activate(ignoringOtherApps: true) }
            for (screen, snapshot) in snapshots {
                let window = ScreenshotOverlayWindow(screen: screen, snapshot: snapshot)
                // v264：固定比例（设置里选中哪组就锁哪组；没选 = 自由 + ⇧ 正方形）
                if let ratio = CaptureRatioStore.selected {
                    window.overlayView.lockedRatio = CGSize(width: ratio.width, height: ratio.height)
                    window.overlayView.lockedRatioLabel = ratio.label
                }
                window.overlayView.onCommit = { [weak self, weak window] rect in
                    guard let self = self, let window = window else { return }
                    self.commitRegion(rect: rect, window: window)
                }
                window.overlayView.onCancel = { [weak self] in self?.cancelCapture() }
                self.overlays.append(window)
                // v109：先激活应用，防首击被激活吃掉（拉伸没反应要第二次）
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            if self.overlays.isEmpty {
                self.isCapturing = false
                self.statusMessage = CaptureError.captureFailed.errorDescription
                Toast.show("截图失败：没有可用屏幕", icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// v162：每屏快照异步获取（区域/窗口/长截图选区共用）——统一走自适应通道选择，
    /// 各系统版本自动选对 API（macOS 27 主线程同步调 legacy 会死锁，见 ScreenSnapshot 通道策略注释）。
    static func acquireScreenSnapshots() async -> [(screen: NSScreen, image: CGImage?)] {
        var result: [(NSScreen, CGImage?)] = []
        for screen in NSScreen.screens {
            let image = await ScreenSnapshot.captureScreenAdaptive(screen: screen)
            result.append((screen, image))
        }
        return result
    }

    private func commitRegion(rect: CGRect, window: ScreenshotOverlayWindow) {
        let screenFrame = window.frame
        let snapshot = window.overlayView.snapshot
        closeOverlays()
        isCapturing = false

        // 视图坐标 → 屏幕全局坐标
        let global = rect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        // 选区（AppKit 全局，左下原点）——屏幕翻译钉回原位用
        lastSelectionAppKit = global
        let flow = pendingFlow

        // v166.7：产物按「屏幕原生像素」重抓（screencapture，~200ms，必须后台）。
        // 覆盖层那张快照是 1x，只作为兜底——它裁出来的图在 Retina 上少一半像素。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let native = NativeRegionCapture.capture(appKitRect: global)
            let fallback: CGImage? = native == nil
                ? snapshot.flatMap { ImageProcessor.crop($0, rectInPoints: global, screenFrame: screenFrame) }
                : nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard let image = native ?? fallback else {
                    self.statusMessage = CaptureError.captureFailed.errorDescription
                    // 屏幕级反馈：失败不能只写在面板状态里（面板此刻根本没开）
                    Toast.show("截图失败，请重试", icon: "exclamationmark.triangle", isWarning: true)
                    return
                }
                if native != nil {
                    Log.info("Capture", "选区截图：\(Int(global.width))×\(Int(global.height))pt → \(image.width)×\(image.height)px（原生像素）")
                } else {
                    Log.warn("Capture", "选区截图：原生像素通道不可用，回退 1x 快照裁剪")
                }
                self.finishRegion(image, flow: flow, global: global)
            }
        }
    }

    /// 选区截图拿到图之后的收尾（原 commitRegion 的 switch 部分）
    private func finishRegion(_ cropped: CGImage, flow: PendingFlow, global: CGRect) {
        switch flow {
        case .direct(let action):
            handle(cropped, action: action)
        case .toolbar:
            // 先落盘（动作链各工具都以 URL/已保存文件为前提），再弹动作工具条
            let pixel = CGSize(width: cropped.width, height: cropped.height)
            guard let data = ImageProcessor.pngData(cropped),
                  let url = stagePNG(data, pixelSize: pixel) else {
                Toast.show("截图暂存失败，请检查磁盘空间", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            registerCaptured(url: url, data: data, playSound: true)
            autoDetectQR(in: cropped)   // v130⑤：自动检测二维码
            // v264：轻量拖拽角标（不需要图帘也能直接拖进别的 App）
            CaptureDragBadgeController.shared.show(image: cropped, url: url)
            CaptureActionChain.present(image: cropped, url: url, selectionAppKit: global)
        }
    }

    private func cancelCapture() {
        closeOverlays()
        isCapturing = false
    }

    private func closeOverlays() {
        for window in overlays { window.orderOut(nil) }
        overlays.removeAll()
    }

    // MARK: 全屏截图

    /// 全屏截图：抓鼠标所在屏幕（v162：自适应通道，按系统版本选 SCK/legacy）
    public func captureFullScreen() {
        Task { @MainActor in
            guard await ensureScreenRecordingPermission() else { return }
            guard let screen = currentScreen() else { return }
            let action = defaultAction
            self.currentModeTag = "full"   // v130②：历史库模式标签

            // v166.7：优先原生像素（screencapture，后台）；失败才回退 1x 的 SCK/legacy
            var image = await Task.detached(priority: .userInitiated) {
                NativeRegionCapture.captureScreen(screen)
            }.value
            if image == nil {
                image = await ScreenSnapshot.captureScreenAdaptive(screen: screen)
            }
            guard let image = image else {
                self.statusMessage = CaptureError.captureFailed.errorDescription
                Log.error("Capture", "全屏截图失败")
                return
            }
            self.handle(image, action: action)
        }
    }

    // MARK: 延时截图（v130 SnowShot 对齐④）

    /// 延时截图：N 秒倒计时后自动截取当前屏幕（Esc 取消；N = 设置项 delaySeconds）
    public func captureDelayed() {
        DelayedCaptureController.shared.start(seconds: delaySeconds)
    }

    private func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: 窗口截图（v113 对齐原版窗口模式）
    //
    // 证据（docs/窗口识别与传输功能-既有实现彻查.md）：
    //   · 原版 CaptureMode 含 `.window`（specs/06 反汇编还原）；
    //   · 原版二进制反射字段 windows / windowOrder / selectedWindowId /
    //     keyDownMonitor / isClosingWindow → 窗口模式自带「识别 + 选择」交互。
    //
    // 因此本实现走「覆盖层窗口选择」：悬停高亮 + 单击截取（Esc 取消），
    // 与原版交互对齐；v112 的「直接抓最前台窗口」与「区域模式悬停吸附」已移除
    // （前者偏离原版交互，后者是自研发明）。

    /// 进入窗口截图：覆盖层窗口选择（悬停识别 → 单击截取）
    public func captureWindow() {
        Task { @MainActor in
            guard await ensureScreenRecordingPermission() else { return }
            self.beginWindowCapture()
        }
    }

    @MainActor
    private func beginWindowCapture() {
        closeOverlays()
        pendingFlow = .toolbar          // 截取后与区域截图同一套动作工具条
        currentModeTag = "window"       // v130②：历史库模式标签
        isCapturing = true
        // v207：与区域截图同修——先冻结帧，再激活；否则预览窗会先收起

        // v161：与 beginRegionCapture 同修——快照异步获取，legacy 同步调用禁止主线程（macOS 27 死锁）
        Task { @MainActor in
            let snapshots = await Self.acquireScreenSnapshots()
            guard self.isCapturing else { return }
            if !snapshots.isEmpty { NSApp.activate(ignoringOtherApps: true) }
            for (screen, snapshot) in snapshots {
                let window = ScreenshotOverlayWindow(screen: screen, snapshot: snapshot, pickMode: .window)
                window.overlayView.onWindowCommit = { [weak self, weak window] rect, windowID in
                    guard let self = self, let window = window else { return }
                    self.commitWindow(rect: rect, windowID: windowID, window: window)
                }
                // v264：⌘ 多选窗口 → 一次截完，按顺序纵向拼成一张图
                window.overlayView.onWindowsCommit = { [weak self, weak window] items in
                    guard let self = self, let window = window else { return }
                    self.commitWindows(items: items, window: window)
                }
                window.overlayView.onCancel = { [weak self] in self?.cancelCapture() }
                self.overlays.append(window)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            if self.overlays.isEmpty {
                self.isCapturing = false
                Toast.show("截图失败：没有可用屏幕", icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// 提交窗口选择：优先 SCK 窗口级抓取（排除遮挡窗口），回退覆盖层快照裁剪
    private func commitWindow(rect: CGRect, windowID: CGWindowID, window: ScreenshotOverlayWindow) {
        let screenFrame = window.frame
        let snapshot = window.overlayView.snapshot
        closeOverlays()
        isCapturing = false

        let global = rect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        lastSelectionAppKit = global

        Task { @MainActor in
            var image: CGImage?
            if windowID != 0, #available(macOS 14.0, *) {
                image = try? await ScreenSnapshot.sckCapture(windowID: windowID)
            }
            if image == nil, let snapshot {
                image = ImageProcessor.crop(snapshot, rectInPoints: global, screenFrame: screenFrame)
            }
            guard let image else {
                self.statusMessage = CaptureError.captureFailed.errorDescription
                Toast.show("窗口截图失败，请重试", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            // 与区域截图同一条收尾路径（落盘 + 广播 + 动作工具条/默认动作）
            switch self.pendingFlow {
            case .direct(let action):
                self.handle(image, action: action)
            case .toolbar:
                let pixel = CGSize(width: image.width, height: image.height)
                guard let data = ImageProcessor.pngData(image),
                      let url = self.stagePNG(data, pixelSize: pixel) else {
                    Toast.show("截图暂存失败，请检查磁盘空间", icon: "exclamationmark.triangle", isWarning: true)
                    return
                }
                self.registerCaptured(url: url, data: data, playSound: true)
                self.autoDetectQR(in: image)   // v130⑤：自动检测二维码
                CaptureDragBadgeController.shared.show(image: image, url: url)
                CaptureActionChain.present(image: image, url: url, selectionAppKit: global)
            }
        }
    }

    // MARK: 窗口多选（v264）

    /// 一次截多个窗口：按勾选顺序**纵向拼成一张图**（16pt 间隔、24pt 留白）。
    ///
    /// 为什么拼成一张而不是存多个文件：多选的用途基本是「写文档 / 发群里对比」，
    /// 存成 5 个文件用户还得再拼一次；一张图直接能拖走。
    /// 需要单独文件时，单窗口截图本来就还在。
    private func commitWindows(items: [(rect: CGRect, windowID: CGWindowID)],
                               window: ScreenshotOverlayWindow) {
        let screenFrame = window.frame
        let snapshot = window.overlayView.snapshot
        closeOverlays()
        isCapturing = false
        guard !items.isEmpty else { return }

        Task { @MainActor in
            var images: [CGImage] = []
            for item in items {
                var image: CGImage?
                if item.windowID != 0, #available(macOS 14.0, *) {
                    image = try? await ScreenSnapshot.sckCapture(windowID: item.windowID)
                }
                if image == nil, let snapshot {
                    let global = item.rect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
                    image = ImageProcessor.crop(snapshot, rectInPoints: global, screenFrame: screenFrame)
                }
                if let image { images.append(image) }
            }
            guard !images.isEmpty else {
                Toast.show("窗口截图失败，请重试", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            guard let composed = Self.composeVertically(images) else {
                Toast.show("窗口图片合成失败", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            Log.info("Capture", "窗口多选：\(images.count) 个窗口 → \(composed.width)×\(composed.height)px")
            self.lastSelectionAppKit = .zero
            switch self.pendingFlow {
            case .direct(let action):
                self.handle(composed, action: action)
            case .toolbar:
                guard let data = ImageProcessor.pngData(composed),
                      let url = self.stagePNG(data, pixelSize: CGSize(width: composed.width,
                                                                      height: composed.height)) else {
                    Toast.show("截图暂存失败，请检查磁盘空间", icon: "exclamationmark.triangle", isWarning: true)
                    return
                }
                self.registerCaptured(url: url, data: data, playSound: true)
                CaptureDragBadgeController.shared.show(image: composed, url: url)
                CaptureActionChain.present(image: composed, url: url, selectionAppKit: .zero)
            }
        }
    }

    /// 纵向拼接（深/浅色背景跟随系统外观，避免白底图和暗色界面打架）
    static func composeVertically(_ images: [CGImage]) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let gap: CGFloat = 16
        let pad: CGFloat = 24
        var maxW = images.map { CGFloat($0.width) }.max() ?? 0
        var totalH = images.reduce(0) { $0 + CGFloat($1.height) }
            + gap * CGFloat(max(0, images.count - 1)) + pad * 2
        guard maxW > 0, totalH > 0 else { return nil }

        // 内存闸门：超过 120MP 等比缩（一张 6K 竖拼十张会到 300MP）
        let maxPixels: CGFloat = 120_000_000
        let scale = min(1, sqrt(maxPixels / (maxW * totalH)))
        maxW *= scale
        totalH *= scale

        let width = Int(maxW.rounded()), height = Int(totalH.rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.96, alpha: 1)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high

        var y = CGFloat(height) - pad
        for image in images {
            let w = CGFloat(image.width) * scale
            let h = CGFloat(image.height) * scale
            let x = (CGFloat(width) - w) / 2
            ctx.draw(image, in: CGRect(x: x, y: y - h, width: w, height: h))
            y -= h + gap * scale
        }
        return ctx.makeImage()
    }

    // MARK: 产出分流

    /// 统一收尾：落盘 + 事件广播 + 按动作分流
    private func handle(_ image: CGImage, action: CaptureDefaultAction) {
        guard let data = ImageProcessor.pngData(image) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            Toast.show("截图失败：图片编码失败", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        // v235：默认动作不是「保存」时只暂存，不往下载目录写文件
        let pixel = CGSize(width: image.width, height: image.height)
        guard let url = (action == .save ? savePNG(data, pixelSize: pixel)
                                        : stagePNG(data, pixelSize: pixel)) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            Toast.show("截图保存失败，请检查保存路径", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        registerCaptured(url: url, data: data, playSound: true)
        autoDetectQR(in: image)   // v130（SnowShot 对齐）⑤：截图完成后自动检测二维码
        // v264：轻量拖拽角标（只有「保存 / 复制」这两种「我要拿去用」的动作才给）
        if action == .save || action == .clipboard {
            CaptureDragBadgeController.shared.show(image: image, url: url)
        }
        apply(action, to: image, url: url)
    }

    /// 登记一张已落盘的截图：刷新最近列表 + 可选提示音 + 事件广播。
    /// 供截图主流程与标注保存复用，保证两条链路行为一致。
    /// v130（SnowShot 对齐）②：同时写入截图历史库（缩略图 + 可检索，上限 500 条）。
    public func registerCaptured(url: URL, data: Data, playSound: Bool = false, mode: String? = nil) {
        recent.insert(CapturedImage(url: url, createdAt: Date()), at: 0)
        if recent.count > 60 { recent = Array(recent.prefix(60)) }
        if playSound, Preferences.shared.value(Preferences.Keys.captureSound, default: true) { playShutterSound() }
        // v130②：历史入库（异步生成缩略图；mode 缺省用本次截图入口标签）
        CaptureHistoryStore.shared.record(url: url, mode: mode ?? currentModeTag)
        lastHistoryPath = url.path
        // 不直接调用剪贴板模块：由 App 层接线把这条回调接到剪贴板历史入库
        CaptureEventBus.onImageCaptured?(url, data)
    }

    /// 对已有截图执行某个动作（面板里点最近截图时用）
    public func apply(_ action: CaptureDefaultAction, to image: CGImage, url: URL) {
        switch action {
        case .save:
            // 屏幕级反馈（2026-10-18 用户实障「截图后没有提示」）：
            // 此前保存分支只写 statusMessage，而该字段只在主面板的截图页里渲染，
            // 用户按 ⌥S 截完图时面板是关着的 → 落盘成功却没有任何可见确认。
            // 原版对应文案 Saved Successfully（zh-Hans「已保存」）。
            Toast.show("已保存", icon: "checkmark.circle.fill")
            statusMessage = "已保存到 \(url.lastPathComponent)"
        case .clipboard:
            copyToPasteboard(image)
            Toast.show("截图已复制", icon: "checkmark.circle.fill")   // spec 13 §4：截图复制场景
            statusMessage = "已复制到剪贴板"
        case .ocr:
            recognize(image)
        case .pin:
            PinnedScreenshotManager.shared.show(image: image)
            Toast.show("已钉在屏幕上", icon: "pin.fill")
            statusMessage = "已钉在屏幕上"
        case .screenTranslate:
            // 钉回原选区位置（无选区上下文时 nil → 贴图默认错位平铺）
            ScreenTranslator.run(image: image, pinOrigin: lastSelectionAppKit.isNull ? nil : lastSelectionAppKit.origin)
        case .annotate:
            AnnotationEditorController.shared.open(image: image)
        case .beautify:
            BeautifyController.shared.show(image: image)
        }
    }

    /// 对最近截图文件执行动作
    public func apply(_ action: CaptureDefaultAction, to url: URL) {
        guard let image = ImageProcessor.cgImage(from: url) else { return }
        apply(action, to: image, url: url)
    }

    // MARK: 落盘 / 剪贴板 / 提示音

    /// 写入 PNG 到**用户保存目录**（下载目录 / 设置里的路径）
    @discardableResult
    public func savePNG(_ data: Data, pixelSize: CGSize = .zero) -> URL? {
        writePNG(data, to: saveDirectory, pixelSize: pixelSize)
    }

    /// 写入 PNG 到**私有暂存目录**（动作条各工具都拿到这个 URL，但不算用户保存）
    @discardableResult
    public func stagePNG(_ data: Data, pixelSize: CGSize = .zero) -> URL? {
        writePNG(data, to: stagingDirectory, pixelSize: pixelSize)
    }

    private func writePNG(_ data: Data, to dir: URL, pixelSize: CGSize = .zero) -> URL? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(Self.newFileName(pixelSize: pixelSize))
            try data.write(to: url)
            return url
        } catch {
            Log.error("Capture", "保存截图失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 把暂存的截图正式保存到下载目录（动作条「保存」按钮）
    ///
    /// 复制而非移动：动作条上保存之后用户还可能点「空投 / 钉住」，那些工具仍要读原 URL。
    @discardableResult
    public func commitToSaveDirectory(staged url: URL) -> URL? {
        let dir = saveDirectory
        // 已经在保存目录里（默认动作就是「保存到文件夹」的直连路径）→ 不再复制一份
        if url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            Toast.show("已保存", icon: "checkmark.circle.fill")
            return url
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(Self.newFileName())
            try FileManager.default.copyItem(at: url, to: dest)
            recent.removeAll { $0.url == url }
            recent.insert(CapturedImage(url: dest, createdAt: Date()), at: 0)
            lastHistoryPath = dest.path
            Log.info("Capture", "保存到用户目录：\(dest.path)")
            Toast.show("已保存到 \(dir.lastPathComponent)", icon: "checkmark.circle.fill")
            statusMessage = "已保存到 \(dest.lastPathComponent)"
            return dest
        } catch {
            Log.error("Capture", "保存到用户目录失败: \(error.localizedDescription)")
            Toast.show("保存失败，请检查保存路径", icon: "exclamationmark.triangle", isWarning: true)
            return nil
        }
    }

    /// v264：文件名交给模板引擎（设置 → 截图 → 文件命名）。
    /// 默认模板与旧版输出完全一致，老用户不会发现名字变了。
    private static func newFileName(pixelSize: CGSize = .zero) -> String {
        CaptureFileName.make(pixelSize: pixelSize, mode: shared.currentModeTag)
    }

    public func copyToPasteboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = ImageProcessor.pngData(image) {
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
        }
        pasteboard.writeObjects([ImageProcessor.nsImage(image)])
    }

    private func playShutterSound() {
        NSSound(named: NSSound.Name("Pop"))?.play()
    }

    // MARK: 最近截图

    /// 扫描「暂存 + 用户保存」两个目录，刷新最近截图列表
    ///
    /// v235：截图默认只进私有暂存目录，用户点保存才进下载目录；
    /// 列表要把两边都算上，否则未保存的截图在面板里看不到。
    public func reloadRecent() {
        let fm = FileManager.default
        let allowed: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
        var seen: Set<String> = []
        var items: [CapturedImage] = []
        for dir in [saveDirectory, stagingDirectory] {
            guard let urls = try? fm.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { continue }
            for url in urls {
                guard allowed.contains(url.pathExtension.lowercased()),
                      !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? Date.distantPast
                items.append(CapturedImage(url: url, createdAt: date))
            }
        }
        recent = Array(items.sorted { $0.createdAt > $1.createdAt }.prefix(60))
    }

    /// 缩略图（带内存缓存）
    public func thumbnail(for url: URL, maxSide: CGFloat = 240) -> NSImage? {
        if let cached = thumbCache.object(forKey: url as NSURL) { return cached }
        // v128（内存优化）：包 autoreleasepool——缩略图生成（CGImage 解码 + 缩放）
        // 在列表滚动时成批触发，临时对象显式 drain
        return autoreleasepool {
            guard let cg = ImageProcessor.cgImage(from: url) else { return nil }
            let image = ImageProcessor.nsImage(ImageProcessor.scaled(cg, maxSide: maxSide))
            // v128（内存优化）：按像素字节记账，配合 totalCostLimit 控制缓存驻留
            thumbCache.setObject(image, forKey: url as NSURL,
                                 cost: Int(image.size.width * image.size.height * 4))
            return image
        }
    }

    // MARK: OCR

    /// 识别一张图（结果写入 ocrText，并广播给剪贴板等模块）
    public func recognize(_ image: CGImage) {
        guard let data = ImageProcessor.pngData(image) else { return }
        recognize(imageData: data)
    }

    /// v139：动作条「翻译」——识字后直接打开结果窗的翻译页签（自动提取并翻译）
    public func recognizeAndTranslate(_ image: CGImage) {
        guard let data = ImageProcessor.pngData(image) else { return }
        recognize(imageData: data, autoTranslate: true)
    }

    // MARK: v224 「复制并识别 / 复制并翻译」——打开结果窗，由用户自己选文字复制

    /// 识别后**总是**打开结果窗（不受「识别后显示结果窗」偏好影响）
    ///
    /// 用户：「不是直接复制到剪贴板，而是应该打开之前那个单独窗口，
    /// 信息可以让用户手动选择」。所以这两个动作不再自动写剪贴板，
    /// 窗口里可以框选、可以点复制、可以切翻译页签。
    public func recognizeShowing(_ image: CGImage) {
        guard let data = ImageProcessor.pngData(image) else { return }
        recognize(imageData: data, forceWindow: true)
    }

    public func recognize(imageData: Data, autoTranslate: Bool = false, forceWindow: Bool = false) {
        isRecognizing = true
        statusMessage = nil
        Task { @MainActor in
            defer { self.isRecognizing = false }
            do {
                let text = try await OCRService.shared.recognizeText(imageData: imageData, quality: .thorough)
                self.ocrText = text
                self.statusMessage = text.isEmpty ? CaptureError.noText.errorDescription : nil
                // spec 13 §4：未读取到文字场景（0x10000d45c，空识别结果分支）
                if text.isEmpty {
                    Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
                }
                if !text.isEmpty {
                    CaptureEventBus.onTextRecognized?(text)
                    // v130（SnowShot 对齐）②：OCR 文本回填截图历史（历史窗可按文本搜索）
                    if let p = self.lastHistoryPath {
                        CaptureHistoryStore.shared.updateOCR(path: p, text: text)
                    }
                    // 弹出「原文对照 + 识别文本」结果窗（B5）
                    // v264：静默模式 —— 只弹一条 N 秒的提示，不打断连续识别；
                    // 文本同时写进剪贴板，用户可以直接粘贴。
                    if CaptureOCRNotify.isSilent, !forceWindow, !autoTranslate {
                        self.copyOCRText()
                        CaptureOCRNotify.show(text: text)
                        return
                    }
                    if forceWindow || self.ocrShowResultWindow || autoTranslate,
                       let cg = ScreenshotOCRDirectImageStore.shared.image(for: imageData) {
                        ScreenshotOCRWindowController.shared.show(sourceImage: cg, imageData: imageData,
                                                                  text: text, autoTranslate: autoTranslate)
                    }
                }
            } catch {
                Toast.show("文字识别失败", icon: "exclamationmark.circle.fill")   // spec 13 §4：OCR 失败场景
                self.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Log.error("Capture", "OCR 失败: \(error.localizedDescription)")
            }
        }
    }

    /// 复制 OCR 结果到剪贴板
    public func copyOCRText() {
        guard !ocrText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ocrText, forType: .string)
        CaptureEventBus.onTextRecognized?(ocrText)
        statusMessage = "识别结果已复制"
    }

    // MARK: 二维码自动检测（v130 SnowShot 对齐⑤）
    //
    // v130 起截图链路已接入真正的二维码识别（QRCodeRecognizer / VNDetectBarcodesRequest），
    // 之前的 TODO「二维码识别失败提示无挂点」就地闭环：识别失败 = 静默（不弹错），
    // 命中时弹结果窗二维码页签 + Toast（见 autoDetectQR）。

    /// 截图完成后自动检测二维码：命中 → 结果窗「二维码」页签展示 payload（可打开/复制）
    private func autoDetectQR(in image: CGImage) {
        QRCodeRecognizer.recognize(image) { [weak self] payloads in
            guard let self, !payloads.isEmpty else { return }
            self.qrPayloads = payloads
            Toast.show("识别到 \(payloads.count) 个二维码", icon: "qrcode.viewfinder")
            // 与 OCR 结果窗合并展示（同一面板加二维码页签）
            let data = ImageProcessor.pngData(image) ?? Data()
            ScreenshotOCRWindowController.shared.show(sourceImage: image, imageData: data,
                                                      text: "", qrPayloads: payloads, selectQR: true)
        }
    }

    // MARK: 长截图 / 钉图


    /// 拼接结果的落盘 + 列表刷新（拼接计算可在后台线程做，落盘回主线程调这里）
    @discardableResult
    public func saveStitchedResult(_ image: CGImage, overlaps: [Int]) -> URL? {
        guard let data = ImageProcessor.pngData(image) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            return nil
        }
        guard let url = savePNG(data, pixelSize: CGSize(width: image.width, height: image.height)) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            return nil
        }
        recent.insert(CapturedImage(url: url, createdAt: Date()), at: 0)
        if recent.count > 60 { recent = Array(recent.prefix(60)) }
        CaptureHistoryStore.shared.record(url: url, mode: "long")   // v130②：长截图入历史
        lastHistoryPath = url.path
        CaptureEventBus.onImageCaptured?(url, data)
        let total = overlaps.reduce(0, +)
        statusMessage = "长截图已保存（重叠 \(total) 像素）"
        return url
    }

    /// 把一张图钉到屏幕上
    public func pin(url: URL) {
        guard let image = ImageProcessor.cgImage(from: url) else { return }
        PinnedScreenshotManager.shared.show(image: image)
    }

    // MARK: 长截图（被动式滚轮采捕，spec 15）

    /// 长截图入口：选区确认后进入滚动采捕会话（面板 / CaptureMode.long 调用）
    public func captureLongScreenshot() {
        LongScreenshotCoordinator.shared.beginSelection()
    }

    // MARK: 标注编辑

    /// 进入标注编辑器（B3⑥）：对指定图片文件
    public func annotate(url: URL) {
        AnnotationEditorController.shared.open(url: url)
    }

    /// 进入标注编辑器：优先标注最近一张截图，返回是否成功打开
    @discardableResult
    public func annotateLatest() -> Bool {
        AnnotationEditorController.shared.openLatest()
    }
}
