import AppKit
import SwiftUI

// MARK: - 框选后动作链
//
// 三入口设计（沿用）：
//   ① 「截图后默认执行」偏好（CaptureDefaultAction，设置 → 截图）；
//   ② 逐工具快捷键：动作条内的 ⌘C/⌘S/… 键位；
//   ③ 全局快捷键：specs/19 的 screenshotOCR/Pin/Copy/Translate 等直连表项。
//
// v218 重构（用户反馈三点）：
//   · 「框出来非常缓慢」——原来每次框选都新建 NSPanel + NSHostingView，
//     还要算两次 fittingSize（SwiftUI 首次布局 + 玻璃材质初始化）。
//     改为**单例面板 + 启动预热**：首次之后只更新 model 与尺寸，不再重建视图树。
//   · 「按钮非常多，需要按功能分类」——12 个平铺按钮收成 5 个入口，
//     复制 / 识别 / 长截图 / 编辑 / 更多，同类动作进右侧 chevron 的二级菜单。
//   · 「上面要有预览小窗，下半才是框；固定屏幕正中央、约 1/4 高度」——
//     面板改为「预览图 + 分隔线 + 工具条」两段式，位置固定居中，
//     顶部落在可见区 25% 高度处（不再贴着选区飘）。

/// 一条框选后动作（工具注册表条目）
public struct CaptureActionTool: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// 工具条内键位（无修饰，单字符；配合 ⌘ 使用）
    public let key: Character?
    public let handler: (CGImage, URL) -> Void

    public init(id: String, title: String, systemImage: String,
                key: Character? = nil, handler: @escaping (CGImage, URL) -> Void) {
        self.id = id; self.title = title; self.systemImage = systemImage
        self.key = key; self.handler = handler
    }
}

/// 工具分组（v218）：主条只放 5 个入口，同类动作收进二级菜单
public struct CaptureActionGroup: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// 主按钮直接执行的动作 id（nil = 只能从菜单选）
    public let primary: String?
    /// 二级菜单项（工具 id，按展示顺序）
    public let items: [String]

    public init(id: String, title: String, systemImage: String,
                primary: String?, items: [String]) {
        self.id = id; self.title = title; self.systemImage = systemImage
        self.primary = primary; self.items = items
    }
}

public enum CaptureActionChain {

    // MARK: 偏好

    /// 框选后是否显示动作工具条（关闭则直接执行默认动作）
    static let keyShowToolbar = "capture.afterSelect.showToolbar"
    public static var showToolbarAfterSelection: Bool {
        get { Preferences.shared.value(keyShowToolbar, default: true) }
        set { Preferences.shared.set(keyShowToolbar, newValue) }
    }

    // MARK: 工具注册表

    public static var tools: [CaptureActionTool] {
        [
            CaptureActionTool(id: "copy", title: "复制", systemImage: "doc.on.doc", key: "c") { image, _ in
                guard ScreenshotManager.shared.copyToPasteboard(image) else { return }
                Toast.show("截图已复制", icon: "checkmark.circle.fill")
            },
            CaptureActionTool(id: "recentCopy", title: "近期复制", systemImage: "list.bullet.clipboard") { _, _ in
                Task { @MainActor in ScreenshotManager.shared.openRecentClipboard() }
            },
            // v218（对齐 1capture / 用户：「复制、复制并 OCR 这种同一类功能」）：
            // 复制的同时把图里的文字识别出来，省掉「先复制再单独点识字」两步。
            // v224（用户：「不是直接复制到剪贴板，而是打开之前那个单独窗口，
            // 信息让用户手动选择」）：这两个动作改为「识别 → 开结果窗」，
            // 不自动写剪贴板；窗口里可框选、可点复制、可切翻译页签。
            CaptureActionTool(id: "copyOCR", title: "复制并识别", systemImage: "doc.text.viewfinder") { image, _ in
                ScreenshotManager.shared.recognizeShowing(image)
            },
            CaptureActionTool(id: "copyTranslate", title: "复制并翻译", systemImage: "character.book.closed") { image, _ in
                ScreenshotManager.shared.recognizeAndTranslate(image)
            },
            // v235：动作条之前的落盘只是暂存（App 私有目录），点「保存」才复制到下载目录
            CaptureActionTool(id: "save", title: "保存", systemImage: "square.and.arrow.down", key: "s") { _, url in
                ScreenshotManager.shared.commitToSaveDirectory(staged: url)
            },
            // v233：按 1Capture 的叫法统一成「钉住」（原来叫「贴图」）
            CaptureActionTool(id: "pin", title: "钉住", systemImage: "pin.fill", key: "p") { image, _ in
                PinnedScreenshotManager.shared.show(image: image)
                Toast.show("已钉在屏幕上", icon: "pin.fill")
            },
            // v263（用户：「钉住就变成一个图标，然后选择钉住或者是这种多形态的，
            // 一个形态一个选项」）：四个外观形态各占一个选项，选中即按该形态钉住。
            CaptureActionTool(id: "pinClassic", title: "经典", systemImage: "rectangle.portrait") { image, _ in
                Self.pin(image, preset: "classic")
            },
            CaptureActionTool(id: "pinBorderless", title: "无边框", systemImage: "rectangle.dashed") { image, _ in
                Self.pin(image, preset: "borderless")
            },
            CaptureActionTool(id: "pinCard", title: "卡片", systemImage: "rectangle.on.rectangle") { image, _ in
                Self.pin(image, preset: "card")
            },
            CaptureActionTool(id: "pinAccent", title: "强调", systemImage: "rectangle.inset.filled") { image, _ in
                Self.pin(image, preset: "accent")
            },
            // 图帘（原悬挂架）：把这张直接挂到屏幕顶边，不落到截图文件夹
            CaptureActionTool(id: "curtain", title: "挂到图帘", systemImage: "rectangle.stack.badge.plus", key: "g") { _, url in
                // 控制器是 @MainActor：动作条 handler 是同步非隔离闭包，这里显式切回主线程
                Task { @MainActor in
                    if ImageCurtainController.shared.attach(url: url, manual: true) {
                        Toast.show("已挂到图帘", icon: "rectangle.stack")
                    } else {
                        Toast.show("图帘未开启：设置 → 截图与钉图 → 图帘",
                                   icon: "exclamationmark.triangle", isWarning: true)
                    }
                }
            },
            CaptureActionTool(id: "ocr", title: "识字", systemImage: "text.viewfinder", key: "o") { image, _ in
                ScreenshotManager.shared.recognize(image)
            },
            CaptureActionTool(id: "qrCode", title: "识码", systemImage: "qrcode.viewfinder", key: "r") { image, _ in
                QRCodeRecognizer.run(image: image)
            },
            CaptureActionTool(id: "ocrTranslate", title: "翻译", systemImage: "character.book.closed", key: "f") { image, _ in
                ScreenshotManager.shared.recognizeAndTranslate(image)
            },
            CaptureActionTool(id: "screenTranslate", title: "屏幕翻译", systemImage: "character.book.closed", key: "t") { image, _ in
                let origin = ScreenshotManager.shared.lastSelectionAppKit
                ScreenTranslator.run(image: image, pinOrigin: origin.isNull ? nil : origin.origin)
            },
            CaptureActionTool(id: "annotate", title: "编辑", systemImage: "pencil.and.outline", key: "e") { image, _ in
                AnnotationEditorController.shared.open(image: image)
            },
            CaptureActionTool(id: "beautify", title: "美化", systemImage: "wand.and.stars", key: "b") { image, _ in
                BeautifyController.shared.show(image: image)
            },
            CaptureActionTool(id: "airDrop", title: "空投", systemImage: "dot.radiowaves.left.and.right", key: "d") { _, url in
                NotificationCenter.default.post(name: .frsetAirDropFiles, object: nil,
                                                userInfo: ["urls": [url]])
                Toast.show("已发起隔空投送", icon: "dot.radiowaves.left.and.right")
            },
            CaptureActionTool(id: "history", title: "历史", systemImage: "clock.arrow.circlepath", key: "h") { _, _ in
                CaptureHistoryWindowController.shared.show()
            },
            CaptureActionTool(id: "longShot", title: "长截图", systemImage: "arrow.up.and.down.text.horizontal", key: "l") { _, _ in
                if !LongScreenshotCoordinator.shared.beginFromLastSelection() {
                    LongScreenshotCoordinator.shared.beginSelection()
                }
            },
        ]
    }

    /// 主条分组（顺序即显示顺序）。每组的 primary 是点主按钮直接执行的动作，
    /// items 是右侧 chevron 展开的二级菜单。
    public static var groups: [CaptureActionGroup] {
        [
            CaptureActionGroup(id: "copyGroup", title: "复制", systemImage: "doc.on.doc",
                               primary: "copy", items: ["copyOCR", "copyTranslate", "save"]),
            CaptureActionGroup(id: "recentCopyGroup", title: "近期复制", systemImage: "list.bullet.clipboard",
                               primary: "recentCopy", items: []),
            CaptureActionGroup(id: "ocrGroup", title: "识别", systemImage: "text.viewfinder",
                               primary: "ocr", items: ["qrCode", "ocrTranslate", "screenTranslate"]),
            // v263：钉住从「更多」里提出来单独成组。点图标 = 用当前外观钉住，
            // 悬停展开四个形态 + 「挂到图帘」，一个形态一个选项。
            CaptureActionGroup(id: "pinGroup", title: "钉住", systemImage: "pin.fill",
                               primary: "pin",
                               items: ["pin", "pinClassic", "pinBorderless", "pinCard", "pinAccent", "curtain"]),
            // 长截图保持独立一组（v263 用户明确要求「长截图单独一下」）
            CaptureActionGroup(id: "longGroup", title: "长截图", systemImage: "arrow.up.and.down.text.horizontal",
                               primary: "longShot", items: []),
            CaptureActionGroup(id: "editGroup", title: "编辑", systemImage: "pencil.and.outline",
                               primary: "annotate", items: ["beautify"]),
            CaptureActionGroup(id: "moreGroup", title: "更多", systemImage: "ellipsis",
                               primary: nil, items: ["airDrop", "history"]),
        ]
    }

    /// 按指定形态钉住（动作条四个形态选项共用）
    private static func pin(_ image: CGImage, preset: String) {
        let appearance = PinAppearance.preset(preset) ?? .current
        PinnedScreenshotManager.shared.show(image: image, appearance: appearance)
        let title = appearance.presetTitle ?? "自定义"
        Toast.show("已钉住 · \(title)", icon: "pin.fill")
    }

    static func tool(id: String) -> CaptureActionTool? {
        tools.first { $0.id == id }
    }

    /// 把 CaptureDefaultAction 映射到工具 id（默认动作在工具条上以高亮环标出）
    static func toolID(for action: CaptureDefaultAction) -> String? {
        switch action {
        case .save: return "save"
        case .clipboard: return "copy"
        case .ocr: return "ocr"
        case .pin: return "pin"
        case .screenTranslate: return "screenTranslate"
        case .annotate: return "annotate"
        case .beautify: return "beautify"
        }
    }

    /// 执行某个动作（命令面板 / 工具条 / 默认动作共用）
    public static func perform(id: String, image: CGImage, url: URL) {
        guard let tool = tool(id: id) else { return }
        tool.handler(image, url)
    }

    // MARK: 呈现

    /// 选区确认后弹出动作面板（固定屏幕居中，不再贴选区）
    static func present(image: CGImage, url: URL, selectionAppKit: CGRect) {
        DispatchQueue.main.async {
            presentOnMain(image: image, url: url)
        }
    }

    @MainActor
    private static func presentOnMain(image: CGImage, url: URL) {
        guard showToolbarAfterSelection else {
            ScreenshotManager.shared.apply(ScreenshotManager.shared.defaultAction, to: image, url: url)
            return
        }
        let panel = sharedPanel ?? CaptureActionToolbarPanel()
        sharedPanel = panel
        panel.present(image: image, url: url)
    }

    /// 启动预热：提前把面板与 SwiftUI 视图树建好（不显示），
    /// 之后每次框选只是更新 model + 改尺寸，省掉首次渲染的几百毫秒。
    @MainActor
    public static func warmUp() {
        guard sharedPanel == nil else { return }
        sharedPanel = CaptureActionToolbarPanel()
        Log.info("Capture", "框选动作面板已预热")
    }

    /// 排障：`kitnest://capturebar?expand=copyGroup` 直接展开某一组的子项浮层
    public static var debugExpandGroup: String?

    @MainActor
    static var sharedPanel: CaptureActionToolbarPanel?
}

// MARK: - 动作面板（单例复用）

final class CaptureActionToolbarPanel: NSPanel {

    private let model = CaptureToolbarModel()
    private var hostingView: NSHostingView<CaptureActionToolbarView>?
    private var currentImage: CGImage?
    private var currentURL: URL?
    private var keyMonitor: Any?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        worksWhenModal = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        // NSPanel 默认「App 失活即隐藏」。框选结束那一瞬间 App 可能还没抢回前台
        // （实测深链 kitnest://capturebar 时窗口直接不出现），这里关掉，
        // 关闭时机交给点击外部 / Esc / 选中动作。
        hidesOnDeactivate = false

        model.onPick = { [weak self] id in self?.execute(toolID: id) }
        model.onDismiss = { [weak self] in self?.dismiss() }

        let view = CaptureActionToolbarView(model: model)
        let host = NSHostingView(rootView: view)
        hostingView = host
        contentView = host

        installKeyMonitors()
    }

    override var canBecomeKey: Bool { true }

    // MARK: 显示

    /// 预览面板尺寸：预览图按 340×200 内等比缩放，下面留 56pt 给工具条。
    /// 七个入口共用标准按钮，最小宽度按各样式的间距与文字布局分配。
    static func panelSize(for image: CGImage?, style: CaptureToolbarStyle) -> NSSize {
        let minWidth: CGFloat
        switch style {
        case .iconBar:      minWidth = 300
        case .pillBar:      minWidth = 450
        case .primarySplit: minWidth = 360
        }
        guard let image else { return NSSize(width: minWidth, height: 286) }
        let maxW: CGFloat = 340
        let maxH: CGFloat = 200
        let iw = max(1, CGFloat(image.width))
        let ih = max(1, CGFloat(image.height))
        let scale = min(maxW / iw, maxH / ih, 1)
        let previewW = max(120, iw * scale)
        // v263：子项改成竖排列表后需要更高的面板（钉住组 6 行 + 标题 ≈ 181pt）。
        // 预览区保底 210，任何一组的列表都不会被窗口上沿裁掉；大图仍按比例最多 200。
        let previewH = max(210, ih * scale)

        return NSSize(width: max(minWidth, previewW + 20), height: previewH + 20 + 56)
    }

    func present(image: CGImage, url: URL) {
        isDismissing = false
        currentImage = image
        currentURL = url
        model.preview = NSImage(cgImage: image,
                                size: NSSize(width: image.width, height: image.height))
        model.defaultToolID = CaptureActionChain.toolID(for: ScreenshotManager.shared.defaultAction)
        // v219：样式每次重新读偏好——设置里切换后，下一次框选就是新样式，不用重启
        model.style = CaptureToolbarStyle.current
        // 排障开关只对这一次生效，别让普通框选也带着上次的展开状态
        model.debugExpand = CaptureActionChain.debugExpandGroup
        CaptureActionChain.debugExpandGroup = nil
        model.presentToken += 1

        var size = Self.panelSize(for: image, style: model.style)
        if let screen = NSScreen.main { size.width = min(size.width, screen.visibleFrame.width - 24) }
        setContentSize(size)
        let target = placementOrigin(size: size)

        // 只做淡入，不做位移：`animator().setFrameOrigin` 在 borderless NSPanel 上
        // 实测不执行（窗口停在起点，比特目标位置低 8pt）。位置精度比 8pt 的位移感更重要。
        // 上一版用 SwiftUI 的 .opacity(isPresented) 驱动则更糟——NSHostingView
        // 首次合成停在透明态，面板上屏是一块空白。
        setFrameOrigin(target)
        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        TransientWindowCenter.shared.register(window: self, onDismiss: { [weak self] in self?.dismiss() })
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    /// 目标位置（v219 修正）：水平居中，垂直方向落在**从底部往上 1/4** 处。
    ///
    /// 上一版按「距顶部 1/4」算，面板实际飘在屏幕中上部（用户实拍指出：
    /// 「不能在屏幕的正中间，而应该是从下到上的一个 1/4 的位置」）。
    /// AppKit 的 y 轴以屏幕底部为原点，所以 minY + height*0.25 就是「从下往上 1/4」。
    private func placementOrigin(size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return frame.origin }
        let vf = screen.visibleFrame
        let x = min(max(vf.midX - size.width / 2, vf.minX + 12), vf.maxX - size.width - 12)
        let centerY = vf.minY + vf.height * 0.25
        var y = centerY - size.height / 2
        y = min(max(y, vf.minY + 12), vf.maxY - size.height - 12)
        return NSPoint(x: x, y: y)
    }

    /// 关闭：先播 130ms 淡出，再真正下屏（v219）
    private var isDismissing = false

    func dismiss(completion: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        let token = model.presentToken
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            self.animator().alphaValue = 0
        } completionHandler: {
            guard token == self.model.presentToken else { return }
            self.orderOut(nil)
            TransientWindowCenter.shared.unregister(window: self)
            self.alphaValue = 1
            self.isDismissing = false
            self.currentImage = nil
            self.currentURL = nil
            completion?()
        }
    }

    override func close() { dismiss() }

    /// Esc 兜底：panel 未成为 key 时 local monitor 收不到 keyDown
    override func cancelOperation(_ sender: Any?) { dismiss() }

    // MARK: 键盘

    private func installKeyMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            if event.keyCode == 0x35 {                       // Esc
                self.dismiss()
                return nil
            }
            let defaultID = CaptureActionChain.toolID(for: ScreenshotManager.shared.defaultAction)
            if event.keyCode == 0x24 {                       // Return → 默认动作
                self.execute(toolID: defaultID ?? "copy")
                return nil
            }
            if event.modifierFlags.contains(.command) {
                let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if let key = chars.first,
                   let tool = CaptureActionChain.tools.first(where: { $0.key == key }) {
                    self.execute(toolID: tool.id)
                    return nil
                }
            }
            return event
        }

    }

    private func execute(toolID: String) {
        guard let image = currentImage, let url = currentURL else { return }
        dismiss {
            CaptureActionChain.perform(id: toolID, image: image, url: url)
        }
    }
}

// MARK: - 视图模型

final class CaptureToolbarModel: ObservableObject {
    @Published var preview: NSImage?
    @Published var defaultToolID: String?
    /// 当前动作条样式：present 时重新读偏好，设置里改完下一次框选即生效
    @Published var style: CaptureToolbarStyle = .pillBar
    /// 每次 present 自增：视图靠它重置悬停/展开状态（单例面板，上次的状态会残留）
    @Published var presentToken = 0
    /// 排障：本次直接展开的组 id（`kitnest://capturebar?expand=copyGroup`）
    var debugExpand: String?
    var onPick: ((String) -> Void)?
    var onDismiss: (() -> Void)?
}

