import SwiftUI

// MARK: - 截图模块入口

/// 截图与 OCR 模块：
/// 1) 注入 OCRService 到 ServiceLocator（供搜索 / AI / 剪贴板等模块复用）；
/// 2) 注册主面板区段与设置页签；
/// 3) 预热截图目录与最近截图列表。
public enum CaptureModule: AppModule {
    public static let identifier = "capture"

    public static func start() {
        // 剪贴板预览里点「标注」→ 用截图标注编辑器改这张图（跨模块走通知，不互相引用）
        NotificationCenter.default.addObserver(
            forName: Notification.Name("frset.clipboard.editImage"),
            object: nil, queue: .main) { note in
                Log.info("Capture", "标注：收到 editImage 通知 \(type(of: note.object))")
                guard let nsImage = note.object as? NSImage,
                      let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    Log.warn("Capture", "标注：通知里的图片无法转 CGImage")
                    return
                }
                AnnotationEditorController.shared.open(image: cg)
                Log.info("Capture", "标注：编辑器已请求打开")
            }
        // 共享能力：其它模块只依赖 OCRServiceProtocol
        ServiceLocator.ocrService = OCRService.shared

        // 预热：扫描保存目录，建立最近截图列表
        ScreenshotManager.shared.reloadRecent()

        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "capture",
            title: "截图",
            priority: 30,
            build: { AnyView(CaptureSectionView()) }))

        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "capture",
            title: "截图",
            systemImage: "camera",
            build: { AnyView(CaptureSettingsPane()) }))

        Log.info("Capture", "截图模块已启动")

        // 排障探针（FRSET_CAPTURE_PROBE=1）：启动 3s 后实测抓屏——
        // CGPreflight 返回 true ≠ 实际能抓图（TCC 校验 requirement 失败时会返回黑图）。
        // 同时用 ScreenCaptureKit 抓一张对照，两张图尺寸+平均亮度打印，判断：
        //   · dlsym 旧 API 抓图是否黑（长截图/区域截图不可用的第一判据）
        //   · SCK 抓图是否正常（权限是否真正生效）
        if ProcessInfo.processInfo.environment["FRSET_CAPTURE_PROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                runCaptureProbe()
            }
        }
    }

    // MARK: 抓屏诊断探针（排障专用，不影响正常使用）

    static func runCaptureProbe() {
        guard let screen = NSScreen.main else { return }
        let cgRect = ScreenSnapshot.cgRect(for: screen)

        // ① dlsym 旧 API（长截图/区域截图快照走这条）
        if let img = ScreenSnapshot.cgCapture(rect: cgRect) {
            let brightness = Self.averageBrightness(img)
            Log.info("Capture", "探针[dlsym] 抓图 OK \(img.width)x\(img.height) 平均亮度=\(String(format: "%.1f", brightness))"
                + (brightness < 3 ? " ⚠️疑似全黑（无实际抓屏权限或 API 失效）" : ""))
            if let data = ImageProcessor.pngData(img) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/frset_probe_dlsym.png"))
            }
        } else {
            Log.error("Capture", "探针[dlsym] 抓图失败（nil）——长截图/区域截图不可用")
        }

        // ② ScreenCaptureKit（全屏截图主路径）
        if #available(macOS 14.0, *), let displayID = ScreenSnapshot.displayID(of: screen) {
            Task {
                do {
                    let img = try await ScreenSnapshot.sckCapture(displayID: displayID)
                    let brightness = Self.averageBrightness(img)
                    Log.info("Capture", "探针[SCK] 抓图 OK \(img.width)x\(img.height) 平均亮度=\(String(format: "%.1f", brightness))")
                    if let data = ImageProcessor.pngData(img) {
                        try? data.write(to: URL(fileURLWithPath: "/tmp/frset_probe_sck.png"))
                    }
                } catch {
                    Log.error("Capture", "探针[SCK] 抓图失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 抽样平均亮度（0-255）：全黑图 ≈ 0，可直接判"抓到的是黑屏"
    static func averageBrightness(_ image: CGImage) -> Double {
        let w = 64, h = 64
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            sum += 0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])
        }
        return sum / Double(w * h)
    }

    /// 快捷入口（供状态栏菜单 / 全局快捷键接线调用）
    public static func capture(_ mode: CaptureMode) {
        switch mode {
        case .area:     ScreenshotManager.shared.captureRegion()
        case .full:     ScreenshotManager.shared.captureFullScreen()
        case .ocr:      ScreenshotManager.shared.captureAndOCR()
        case .pin:      ScreenshotManager.shared.captureAndPin()
        case .long:     ScreenshotManager.shared.captureLongScreenshot()   // 选区→滚动采捕会话
        case .annotate: ScreenshotManager.shared.annotateLatest()
        case .color:    Eyedropper.shared.start()
        }
    }

    // MARK: 面板截图功能菜单的动作（对齐原版：截图 / 截图并复制 / 截图并贴图 /
    // 截图提取文字 / 长截图 / 截图翻译 / 划词翻译——见 specs/20 与
    // docs/逆向版新需求对照-v74-v124.md R7）

    /// 截图并复制（区域截图 + 直接进剪贴板）
    public static func captureCopy() {
        ScreenshotManager.shared.captureAndCopy()
    }

    /// 截图翻译：截取区域 → OCR → 交 App 层翻译会话（通知跨模块派发）
    public static func captureTranslate() {
        NotificationCenter.default.post(name: .frsetScreenshotTranslate, object: nil)
    }

    /// 划词翻译：读取选中文本 → 翻译（通知跨模块派发）
    public static func translateSelection() {
        NotificationCenter.default.post(name: .frsetTranslateSelection, object: nil)
    }
}
