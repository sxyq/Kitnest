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
                ScreenshotManager.shared.copyToPasteboard(image)
                Toast.show("截图已复制", icon: "checkmark.circle.fill")
            },
            // v218（对齐 1capture / 用户：「复制、复制并 OCR 这种同一类功能」）：
            // 复制的同时把图里的文字识别出来，省掉「先复制再单独点识字」两步。
            CaptureActionTool(id: "copyOCR", title: "复制并识别", systemImage: "doc.text.viewfinder") { image, _ in
                ScreenshotManager.shared.copyToPasteboard(image)
                ScreenshotManager.shared.recognize(image)
            },
            CaptureActionTool(id: "save", title: "保存", systemImage: "square.and.arrow.down", key: "s") { _, url in
                Toast.show("已保存", icon: "checkmark.circle.fill")
                _ = url
            },
            CaptureActionTool(id: "pin", title: "贴图", systemImage: "pin.fill", key: "p") { image, _ in
                PinnedScreenshotManager.shared.show(image: image)
                Toast.show("已钉在屏幕上", icon: "pin.fill")
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
                               primary: "copy", items: ["copyOCR", "save"]),
            CaptureActionGroup(id: "ocrGroup", title: "识别", systemImage: "text.viewfinder",
                               primary: "ocr", items: ["qrCode", "ocrTranslate", "screenTranslate"]),
            CaptureActionGroup(id: "longGroup", title: "长截图", systemImage: "arrow.up.and.down.text.horizontal",
                               primary: "longShot", items: []),
            CaptureActionGroup(id: "editGroup", title: "编辑", systemImage: "pencil.and.outline",
                               primary: "annotate", items: ["beautify"]),
            CaptureActionGroup(id: "moreGroup", title: "更多", systemImage: "ellipsis",
                               primary: nil, items: ["pin", "airDrop", "history"]),
        ]
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
    private var outsideLocalMonitor: Any?
    private var outsideGlobalMonitor: Any?

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

    /// 预览面板尺寸：预览图按 340×200 内等比缩放，下面留 56pt 给工具条
    static func panelSize(for image: CGImage) -> NSSize {
        let maxW: CGFloat = 340
        let maxH: CGFloat = 200
        let iw = max(1, CGFloat(image.width))
        let ih = max(1, CGFloat(image.height))
        let scale = min(maxW / iw, maxH / ih, 1)
        let previewW = max(120, iw * scale)
        let previewH = max(48, ih * scale)
        return NSSize(width: max(320, previewW + 20), height: previewH + 20 + 56)
    }

    func present(image: CGImage, url: URL) {
        currentImage = image
        currentURL = url
        model.preview = NSImage(cgImage: image,
                                size: NSSize(width: image.width, height: image.height))
        model.defaultToolID = CaptureActionChain.toolID(for: ScreenshotManager.shared.defaultAction)

        let size = Self.panelSize(for: image)
        setContentSize(size)
        placeCentered(size: size)
        makeKeyAndOrderFront(nil)
    }

    /// 固定位置：水平居中，面板顶边落在可见区顶部往下 1/4 处
    private func placeCentered(size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let x = vf.midX - size.width / 2
        let top = vf.maxY - vf.height * 0.25
        var y = top - size.height
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func dismiss() {
        orderOut(nil)
        currentImage = nil
        currentURL = nil
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

        // 点面板外部即关闭（本 App 内 local，其他 App global；global 需辅助功能授权）
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window !== self else { return event }
            self.dismiss()
            return event
        }
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func execute(toolID: String) {
        guard let image = currentImage, let url = currentURL else { return }
        dismiss()
        CaptureActionChain.perform(id: toolID, image: image, url: url)
    }
}

// MARK: - 视图模型

final class CaptureToolbarModel: ObservableObject {
    @Published var preview: NSImage?
    @Published var defaultToolID: String?
    var onPick: ((String) -> Void)?
    var onDismiss: (() -> Void)?
}

// MARK: - 面板内容（预览 + 分组工具条）

struct CaptureActionToolbarView: View {

    @ObservedObject var model: CaptureToolbarModel

    var body: some View {
        VStack(spacing: 0) {
            if let image = model.preview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 340, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .padding(10)
                    // v218（1capture 对齐）：预览图可直接拖到其他 App / AI 工具
                    .onDrag { NSItemProvider(object: image) }
                    .help("拖到其他 App 可直接使用这张图")
            }

            Divider().opacity(0.4)

            HStack(spacing: 2) {
                ForEach(CaptureActionChain.groups) { group in
                    groupControl(group)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 56)
        }
        .background(GlassSurface(cornerRadius: Theme.Radius.window))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    /// 主按钮 +（有子项时）右侧 chevron 菜单
    @ViewBuilder
    private func groupControl(_ group: CaptureActionGroup) -> some View {
        let isDefault = group.primary == model.defaultToolID
            || group.items.contains(model.defaultToolID ?? "")

        HStack(spacing: 0) {
            Button {
                if let primary = group.primary {
                    model.onPick?(primary)
                } else if let first = group.items.first {
                    model.onPick?(first)
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: group.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(height: 15)
                    Text(group.title)
                        .font(.system(size: 10.5))
                }
                .frame(width: group.items.isEmpty ? 62 : 46, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 面板一 show 系统会把键盘焦点落到第一个按钮，画出一圈蓝框
            .focusable(false)
            .help(group.primary.flatMap { id in CaptureActionChain.tool(id: id)?.title } ?? group.title)

            if !group.items.isEmpty {
                Menu {
                    ForEach(group.items, id: \.self) { id in
                        if let tool = CaptureActionChain.tool(id: id) {
                            Button {
                                model.onPick?(id)
                            } label: {
                                Label(tool.title, systemImage: tool.systemImage)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 38)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .focusable(false)
                .fixedSize()
            }
        }
        // 默认动作只标一条底部短线（回车会执行它）。
        // 之前用「淡底 + 描边」，视觉上跟系统焦点环太像，用户会以为是蓝框。
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isDefault ? Theme.accent.opacity(0.07) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            if isDefault {
                Capsule(style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 16, height: 2)
                    .padding(.bottom, 3)
            }
        }
    }
}
