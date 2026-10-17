import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import Foundation

// MARK: - 屏幕快照来源

/// 抓屏通道：
/// - ScreenCaptureKit（macOS 14+）：原作技术栈（otool 实证已链接该框架），异步、不含光标；
/// - CGWindowListCreateImage：低版本回退，同步，覆盖层快照（放大镜）也走这条路。
enum ScreenSnapshot {

    /// 同步抓屏（覆盖层快照 / 回退路径都用）
    static func cgCapture(rect: CGRect) -> CGImage? {
        CGWindowListCreateImage(rect, .optionOnScreenOnly, CGWindowID(0), [.bestResolution])
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

    /// ScreenCaptureKit 抓整屏（macOS 14+）
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

    // MARK: 私有

    private var overlays: [ScreenshotOverlayWindow] = []
    private let thumbCache = NSCache<NSURL, NSImage>()
    private var pendingAction: CaptureDefaultAction = .save

    init() { reloadRecent() }

    // MARK: 偏好

    /// 默认动作（键不在 Core/Preferences.Keys 里，模块内自定义）
    private static let keyDefaultAction = "capture.defaultAction"
    /// OCR 完成后是否弹出结果窗
    private static let keyOCRResultWindow = "capture.ocrShowResultWindow"

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

    /// 保存目录：Preferences.captureSavePath；为空则用 AppDirectories.sub("screenshots")
    public var saveDirectory: URL {
        let raw: String = Preferences.shared.value(Preferences.Keys.captureSavePath, default: "")
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppDirectories.sub("screenshots")
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    // MARK: 权限

    /// 刷新权限状态（系统设置里授权后回来调用）
    public func refreshPermission() {
        hasPermission = CGPreflightScreenCaptureAccess()
    }

    /// 检查屏幕录制权限；未授权时触发系统请求并弹中文说明
    @discardableResult
    public func ensureScreenRecordingPermission() -> Bool {
        hasPermission = CGPreflightScreenCaptureAccess()
        if hasPermission { return true }
        CGRequestScreenCaptureAccess()
        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "截图功能需要系统授权。请打开 系统设置 → 隐私与安全性 → 屏幕录制，勾选本应用后重新启动。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            // spec 13 §4：无法打开链接场景（原作 Unable to Open Link，open 返回 false 即失败）
            if !NSWorkspace.shared.open(url) {
                Toast.show("无法打开链接", icon: "exclamationmark.circle.fill")
            }
        }
    }

    // MARK: 区域截图

    /// 区域截图（按设置的默认动作收尾）
    public func captureRegion() { startRegionCapture(action: defaultAction) }

    /// 截图后直接走 OCR（对应原作「截图并 OCR」入口）
    public func captureAndOCR() { startRegionCapture(action: .ocr) }

    /// 截图后直接钉图
    public func captureAndPin() { startRegionCapture(action: .pin) }

    /// 截图后直接复制到剪贴板（specs/19 默认热键 screenshotCopy 用；与 captureAndOCR/captureAndPin 同型）
    public func captureAndCopy() { startRegionCapture(action: .clipboard) }

    private func startRegionCapture(action: CaptureDefaultAction) {
        guard ensureScreenRecordingPermission() else { return }
        closeOverlays()
        pendingAction = action
        isCapturing = true
        NSApp.activate(ignoringOtherApps: true)

        // 每个屏幕一个覆盖层；快照在覆盖层出现前先抓，避免把覆盖层自己拍进去
        for screen in NSScreen.screens {
            let snapshot = ScreenSnapshot.cgCapture(screen: screen)
            let window = ScreenshotOverlayWindow(screen: screen, snapshot: snapshot)
            window.overlayView.onCommit = { [weak self, weak window] rect in
                guard let self = self, let window = window else { return }
                self.commitRegion(rect: rect, window: window)
            }
            window.overlayView.onCancel = { [weak self] in self?.cancelCapture() }
            overlays.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        if overlays.isEmpty {
            isCapturing = false
            statusMessage = CaptureError.captureFailed.errorDescription
        }
    }

    private func commitRegion(rect: CGRect, window: ScreenshotOverlayWindow) {
        let screenFrame = window.frame
        let snapshot = window.overlayView.snapshot
        closeOverlays()
        isCapturing = false

        // 视图坐标 → 屏幕全局坐标
        let global = rect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        guard let snapshot = snapshot,
              let cropped = ImageProcessor.crop(snapshot, rectInPoints: global, screenFrame: screenFrame) else {
            statusMessage = CaptureError.captureFailed.errorDescription
            return
        }
        handle(cropped, action: pendingAction)
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

    /// 全屏截图：抓鼠标所在屏幕；优先 ScreenCaptureKit，低版本回退 CG
    public func captureFullScreen() {
        guard ensureScreenRecordingPermission() else { return }
        guard let screen = currentScreen(),
              let displayID = ScreenSnapshot.displayID(of: screen) else { return }
        let action = defaultAction

        Task { @MainActor in
            var image: CGImage?
            if #available(macOS 14.0, *) {
                image = try? await ScreenSnapshot.sckCapture(displayID: displayID)
            }
            if image == nil { image = ScreenSnapshot.cgCapture(screen: screen) }
            guard let image = image else {
                self.statusMessage = CaptureError.captureFailed.errorDescription
                Log.error("Capture", "全屏截图失败")
                return
            }
            self.handle(image, action: action)
        }
    }

    private func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    // MARK: 产出分流

    /// 统一收尾：落盘 + 事件广播 + 按动作分流
    private func handle(_ image: CGImage, action: CaptureDefaultAction) {
        guard let data = ImageProcessor.pngData(image) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            return
        }
        guard let url = savePNG(data) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            return
        }
        registerCaptured(url: url, data: data, playSound: true)
        apply(action, to: image, url: url)
    }

    /// 登记一张已落盘的截图：刷新最近列表 + 可选提示音 + 事件广播。
    /// 供截图主流程与标注保存复用，保证两条链路行为一致。
    public func registerCaptured(url: URL, data: Data, playSound: Bool = false) {
        recent.insert(CapturedImage(url: url, createdAt: Date()), at: 0)
        if recent.count > 60 { recent = Array(recent.prefix(60)) }
        if playSound, Preferences.shared.value(Preferences.Keys.captureSound, default: true) { playShutterSound() }
        // 不直接调用剪贴板模块：由 App 层接线把这条回调接到剪贴板历史入库
        CaptureEventBus.onImageCaptured?(url, data)
    }

    /// 对已有截图执行某个动作（面板里点最近截图时用）
    public func apply(_ action: CaptureDefaultAction, to image: CGImage, url: URL) {
        switch action {
        case .save:
            statusMessage = "已保存到 \(url.lastPathComponent)"
        case .clipboard:
            copyToPasteboard(image)
            Toast.show("截图已复制", icon: "checkmark.circle.fill")   // spec 13 §4：截图复制场景
            statusMessage = "已复制到剪贴板"
        case .ocr:
            recognize(image)
        case .pin:
            PinnedScreenshotManager.shared.show(image: image)
            statusMessage = "已钉在屏幕上"
        }
    }

    /// 对最近截图文件执行动作
    public func apply(_ action: CaptureDefaultAction, to url: URL) {
        guard let image = ImageProcessor.cgImage(from: url) else { return }
        apply(action, to: image, url: url)
    }

    // MARK: 落盘 / 剪贴板 / 提示音

    /// 写入 PNG 到保存目录，返回文件 URL
    @discardableResult
    public func savePNG(_ data: Data) -> URL? {
        let dir = saveDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(Self.newFileName())
            try data.write(to: url)
            return url
        } catch {
            Log.error("Capture", "保存截图失败: \(error.localizedDescription)")
            return nil
        }
    }

    private static func newFileName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let stamp = fmt.string(from: Date())
        let tail = String(format: "%03d", Int.random(in: 0...999))
        return "Screenshot-\(stamp)-\(tail).png"
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

    /// 扫描保存目录，刷新最近截图列表
    public func reloadRecent() {
        let dir = saveDirectory
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        let allowed: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
        let items: [CapturedImage] = urls.compactMap { url in
            guard allowed.contains(url.pathExtension.lowercased()) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return CapturedImage(url: url, createdAt: date)
        }
        recent = Array(items.sorted { $0.createdAt > $1.createdAt }.prefix(60))
    }

    /// 缩略图（带内存缓存）
    public func thumbnail(for url: URL, maxSide: CGFloat = 240) -> NSImage? {
        if let cached = thumbCache.object(forKey: url as NSURL) { return cached }
        guard let cg = ImageProcessor.cgImage(from: url) else { return nil }
        let image = ImageProcessor.nsImage(ImageProcessor.scaled(cg, maxSide: maxSide))
        thumbCache.setObject(image, forKey: url as NSURL)
        return image
    }

    // MARK: OCR

    /// 识别一张图（结果写入 ocrText，并广播给剪贴板等模块）
    public func recognize(_ image: CGImage) {
        guard let data = ImageProcessor.pngData(image) else { return }
        recognize(imageData: data)
    }

    public func recognize(imageData: Data) {
        isRecognizing = true
        statusMessage = nil
        Task { @MainActor in
            defer { self.isRecognizing = false }
            do {
                let text = try await OCRService.shared.recognizeText(imageData: imageData)
                self.ocrText = text
                self.statusMessage = text.isEmpty ? CaptureError.noText.errorDescription : nil
                // spec 13 §4：未读取到文字场景（0x10000d45c，空识别结果分支）
                if text.isEmpty {
                    Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
                }
                if !text.isEmpty {
                    CaptureEventBus.onTextRecognized?(text)
                    // 弹出「原文对照 + 识别文本」结果窗（B5）
                    if self.ocrShowResultWindow,
                       let cg = ScreenshotOCRDirectImageStore.shared.image(for: imageData) {
                        ScreenshotOCRWindowController.shared.show(sourceImage: cg, imageData: imageData, text: text)
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

    // MARK: 暂缓的通知条场景（spec 13 §4，等依赖能力落地后接）
    //
    // TODO(spec 13 §4)：「二维码识别失败」（0x1003c98e0 / 0x1003c99e8 / 0x100411b08，
    // 文案 Text Recognition Failed 与 QR Code Recognition Failed 两态）——
    // 重建版截图链路只有文字 OCR（recognize(imageData:)）。全工程唯一的二维码能力是
    // Panel 侧 PreviewImageLoader.detectQRCode（CIDetector，仅返回「有没有」的 Bool，
    // 供预览头尾高度分支用，无失败态、也不在本模块），故此处**没有可挂失败分支的入口**；
    // 待截图链路接入真正的二维码识别后再接
    // `Toast.show("二维码识别失败", icon: "exclamationmark.circle.fill")`。

    // MARK: 长截图 / 钉图

    /// 拼接多张带重叠的截图并保存
    @discardableResult
    public func stitchAndSave(urls: [URL]) -> URL? {
        guard urls.count >= 2 else {
            statusMessage = "请至少选择两张有重叠区域的截图"
            return nil
        }
        guard let result = Stitcher.stitch(urls: urls) else {
            statusMessage = "拼接失败：请确认图片同宽且存在重叠内容"
            return nil
        }
        return saveStitchedResult(result.image, overlaps: result.overlaps)
    }

    /// 拼接结果的落盘 + 列表刷新（拼接计算可在后台线程做，落盘回主线程调这里）
    @discardableResult
    public func saveStitchedResult(_ image: CGImage, overlaps: [Int]) -> URL? {
        guard let data = ImageProcessor.pngData(image) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            return nil
        }
        guard let url = savePNG(data) else {
            statusMessage = CaptureError.saveFailed.errorDescription
            return nil
        }
        recent.insert(CapturedImage(url: url, createdAt: Date()), at: 0)
        if recent.count > 60 { recent = Array(recent.prefix(60)) }
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
