import AppKit
import SwiftUI

// MARK: - 框选后动作链（eSearch 对齐，2026-10-19 用户需求）
//
// 三入口设计：
//   ① 「截图后默认执行」偏好（CaptureDefaultAction，设置 → 截图）——
//      直达入口（全局热键 captureAndOCR/Pin/Copy）与工具条回车键共用；
//   ② 逐工具快捷键：动作工具条内的 ⌘C/⌘S/… 键位（工具条为 key 窗口时生效）；
//   ③ 全局快捷键：specs/19 既有的 screenshotOCR/Pin/Copy/Translate 等直连表项。
//
// 工具条本身是「tools 注册表」的渲染：新增动作只需在 CaptureActionChain.tools
// 加一项（标题/图标/键位/handler），工具条、默认动作、命令面板全部自动获得。

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

public enum CaptureActionChain {

    // MARK: 偏好

    /// 框选后是否显示动作工具条（关闭则直接执行默认动作）
    static let keyShowToolbar = "capture.afterSelect.showToolbar"
    public static var showToolbarAfterSelection: Bool {
        get { Preferences.shared.value(keyShowToolbar, default: true) }
        set { Preferences.shared.set(keyShowToolbar, newValue) }
    }

    // MARK: 工具注册表（顺序即工具条顺序）

    public static var tools: [CaptureActionTool] {
        [
            CaptureActionTool(id: "copy", title: "复制", systemImage: "doc.on.doc", key: "c") { image, _ in
                ScreenshotManager.shared.copyToPasteboard(image)
                Toast.show("截图已复制", icon: "checkmark.circle.fill")
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
            // v117：识码（原版截图动作含 qrCode，见 QRCodeRecognizer 头注）
            CaptureActionTool(id: "qrCode", title: "识码", systemImage: "qrcode.viewfinder", key: "r") { image, _ in
                QRCodeRecognizer.run(image: image)
            },
            // v139（用户需求）：识码旁边加「翻译」——自动提取文字并翻译，
            // 结果开在识别结果窗的「翻译」页签里（与「屏幕翻译」钉图是两条路：
            // 这条要的是**可复制可编辑的译文文本**）
            CaptureActionTool(id: "ocrTranslate", title: "翻译", systemImage: "character.book.closed", key: "f") { image, _ in
                ScreenshotManager.shared.recognizeAndTranslate(image)
            },
            CaptureActionTool(id: "screenTranslate", title: "屏幕翻译", systemImage: "character.book.closed", key: "t") { image, _ in
                // 钉回原选区位置（工具条流程必有 lastSelectionAppKit）
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
                // v112 空投联动（对标报告第一批 P1）：截图落盘文件 → 系统空投面板。
                // 跨模块经通知走 App 层接线（见 AirDropSendEngine 头注）。
                NotificationCenter.default.post(name: .frsetAirDropFiles, object: nil,
                                                userInfo: ["urls": [url]])
                Toast.show("已发起隔空投送", icon: "dot.radiowaves.left.and.right")
            },
            // v130（SnowShot 对齐）②：历史——截图结果工具条直达截图历史窗
            CaptureActionTool(id: "history", title: "历史", systemImage: "clock.arrow.circlepath", key: "h") { _, _ in
                CaptureHistoryWindowController.shared.show()
            },
            // v137（用户需求）：复用当前框选区域直接进入上下滚动长截图——
            // 与"再按一次长截图快捷键重选一遍"相比少一次框选
            CaptureActionTool(id: "longShot", title: "长截图", systemImage: "arrow.up.and.down.text.horizontal", key: "l") { _, _ in
                if !LongScreenshotCoordinator.shared.beginFromLastSelection() {
                    // 无上次选区（理论不发生——工具条必然跟着一次框选）→ 走正常框选入口
                    LongScreenshotCoordinator.shared.beginSelection()
                }
            },
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

    // MARK: 工具条呈现

    /// 选区确认后弹出动作工具条（非隔离入口，内部跳主线程；贴选区下方，放不下贴上方）
    static func present(image: CGImage, url: URL, selectionAppKit: CGRect) {
        DispatchQueue.main.async {
            presentOnMain(image: image, url: url, selectionAppKit: selectionAppKit)
        }
    }

    @MainActor
    private static func presentOnMain(image: CGImage, url: URL, selectionAppKit: CGRect) {
        guard showToolbarAfterSelection else {
            // 关闭工具条：直接执行默认动作
            ScreenshotManager.shared.apply(ScreenshotManager.shared.defaultAction, to: image, url: url)
            return
        }
        toolbar?.close()
        let panel = CaptureActionToolbarPanel(image: image, url: url,
                                              selectionAppKit: selectionAppKit)
        panel.onClose = { [weak panel] in
            if toolbar === panel { toolbar = nil }
        }
        toolbar = panel
        panel.place(near: selectionAppKit)
        panel.makeKeyAndOrderFront(nil)
    }


    @MainActor
    static var toolbar: CaptureActionToolbarPanel?
}

// MARK: - 动作工具条窗口

/// 框选后动作工具条（非激活浮条；borderless + 可 key 以接收键位）
final class CaptureActionToolbarPanel: NSPanel {

    private let image: CGImage
    private let url: URL
    private var keyMonitor: Any?
    private var outsideLocalMonitor: Any?
    private var outsideGlobalMonitor: Any?
    /// 关闭回调（清理 CaptureActionChain.toolbar 强引用）
    var onClose: (() -> Void)?

    init(image: CGImage, url: URL, selectionAppKit: CGRect) {
        self.image = image
        self.url = url
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 48),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        worksWhenModal = true

        let defaultID = CaptureActionChain.toolID(for: ScreenshotManager.shared.defaultAction)
        let view = CaptureActionToolbarView(tools: CaptureActionChain.tools,
                                            defaultToolID: defaultID) { [weak self] toolID in
            self?.execute(toolID: toolID)
        }
        let host = NSHostingView(rootView: view)
        let width = host.fittingSize.width
        let height = host.fittingSize.height
        setContentSize(NSSize(width: max(200, width), height: height))
        contentView = host

        // 逐工具键位 + Return（默认动作）+ Esc（取消）
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            if event.keyCode == 0x35 {                       // Esc
                self.close()
                return nil
            }
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

        // v83（2026-10-19 用户反馈「截图后不选择，工具条一直飘着关不掉」）：
        // 工具条此前只有 Esc/Return/点工具三种退出路径，用户不知道时无法关闭。
        // 补「点击工具条外部即关闭」：本 App 内点击走 local，其他 App 点击走 global
        // （global 需辅助功能授权，未授权时静默失效，local 仍覆盖本 App 场景）。
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window !== self else { return event }
            self.close()
            return event
        }
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    override var canBecomeKey: Bool { true }

    /// Esc 兜底：nonactivating 面板未成为 key 时 local monitor 收不到 keyDown，
    /// 但一旦用户点过工具条（面板成为 key），responder chain 的 cancelOperation 必然可达。
    override func cancelOperation(_ sender: Any?) { close() }

    /// 工具条位置：优先选区下方 10pt（AppKit 全局，左下原点），放不下贴上方；可见区内钳制
    func place(near selectionAppKit: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(selectionAppKit) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = frame.size
        var x = selectionAppKit.midX - size.width / 2
        var y = selectionAppKit.minY - size.height - 10
        if y < vf.minY + 4 { y = selectionAppKit.maxY + 10 }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func execute(toolID: String) {
        close()
        CaptureActionChain.perform(id: toolID, image: image, url: url)
    }

    override func close() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        if let monitor = outsideLocalMonitor { NSEvent.removeMonitor(monitor) }
        outsideLocalMonitor = nil
        if let monitor = outsideGlobalMonitor { NSEvent.removeMonitor(monitor) }
        outsideGlobalMonitor = nil
        onClose?()
        super.close()
    }
}

// MARK: - 工具条视图（SwiftUI）

private struct CaptureActionToolbarView: View {

    let tools: [CaptureActionTool]
    let defaultToolID: String?
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tools) { tool in
                Button {
                    onPick(tool.id)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(height: 15)
                        Text(tool.title)
                            .font(.system(size: 11))
                    }
                    .frame(width: 46, height: 38)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(tool.id == defaultToolID ? Theme.accent.opacity(0.16) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tool.id == defaultToolID ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.title + (tool.key.map { "（⌘\($0.uppercased())）" } ?? ""))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: OfficialChrome.windowBackground).opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
