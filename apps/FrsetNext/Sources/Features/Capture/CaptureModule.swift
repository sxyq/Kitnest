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
                guard let nsImage = note.object as? NSImage,
                      let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                AnnotationEditorController.shared.open(image: cg)
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
