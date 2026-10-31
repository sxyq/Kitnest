import AppKit
import SwiftUI
import QuickLookThumbnailing

// MARK: - 文件悬停预览（本地暂存 / 任意文件）
//
// 2026-10-20 用户需求：本地暂存里各种格式的文件（Word / PPT / Excel / PDF / 图片…）
// 鼠标悬停就自动出预览；预览框**默认小一点**、还能**拖拽调整大小**（以及拖动位置）。
//
// 实现要点：
//   · 缩略图走 `QLThumbnailGenerator`（系统 QuickLook）：Office / PDF / 视频 / 图片都能出图，
//     不用捆绑任何第三方预览器；文本类文件直接读前若干 KB 显示原文；
//   · 面板是 `NSPanel`（.titled + .resizable + .nonactivatingPanel + 标题栏透明），
//     标准 macOS 窗口行为：拖边/角调大小、拖背景移动，尺寸按用户上次调整的记忆恢复；
//   · 悬停 0.4s 才弹（避免划过列表时满屏乱闪）；移开 0.35s 后关；鼠标移进面板内（想拖动/调整）
//     自动取消关闭——否则手还没摸到边框预览就没了。

// MARK: - 预览内容模型

public struct FilePreviewPayload {
    public var thumbnail: NSImage?
    public var text: String?
    public var kindLabel: String
    public var sizeText: String
    public var modifiedText: String
    public var isDirectory: Bool
    public var error: String?

    public var isEmpty: Bool { thumbnail == nil && text == nil }
}

public enum FilePreviewBuilder {

    /// 文本类扩展名（直接显示原文）
    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "csv", "tsv", "yml", "yaml", "log",
        "swift", "py", "js", "ts", "jsx", "tsx", "java", "kt", "go", "rs", "c", "cpp",
        "h", "hpp", "m", "mm", "sh", "zsh", "rb", "php", "html", "css", "scss", "sql", "plist"
    ]

    /// 在后台线程生成预览内容；完成回调在主线程。
    public static func build(url: URL, completion: @escaping (FilePreviewPayload) -> Void) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let size = values?.fileSize ?? 0
        let modified = values?.contentModificationDate
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var payload = FilePreviewPayload(
            thumbnail: nil,
            text: nil,
            kindLabel: kindLabel(for: url),
            sizeText: size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : "—",
            modifiedText: modified.map { formatter.string(from: $0) } ?? "—",
            isDirectory: isDir.boolValue,
            error: exists ? nil : "文件已不存在")

        guard exists else {
            DispatchQueue.main.async { completion(payload) }
            return
        }

        // 目录：用系统文件夹图标 + 条目数
        if isDir.boolValue {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 128, height: 128)
            payload.thumbnail = icon
            let count = (try? fm.contentsOfDirectory(atPath: url.path).count) ?? 0
            payload.text = "目录 · \(count) 个条目"
            DispatchQueue.main.async { completion(payload) }
            return
        }

        let ext = url.pathExtension.lowercased()

        // 文本类：读前 8 KB 显示原文（大文件不全量读）
        if textExtensions.contains(ext) {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                let slice = data.prefix(8 * 1024)
                var text = String(data: slice, encoding: .utf8)
                    ?? String(data: slice, encoding: .isoLatin1)
                    ?? ""
                if data.count > slice.count { text += "\n…（仅预览前 8 KB）" }
                payload.text = text
            }
            // 文本也顺手要一张缩略图（带行号的文档样式），拿不到就算了
            requestThumbnail(url: url) { image in
                payload.thumbnail = image
                DispatchQueue.main.async { completion(payload) }
            }
            return
        }

        // 其余（Office / PDF / 图片 / 视频 / 压缩包…）：QuickLook 缩略图
        requestThumbnail(url: url) { image in
            if let image {
                payload.thumbnail = image
            } else {
                // QuickLook 没有生成器（少见）→ 至少给系统文件图标
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 128, height: 128)
                payload.thumbnail = icon
                if payload.text == nil {
                    payload.text = "此类型没有内建预览，可双击用系统应用打开"
                }
            }
            DispatchQueue.main.async { completion(payload) }
        }
    }

    private static func requestThumbnail(url: URL, completion: @escaping (NSImage?) -> Void) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 900, height: 1200),
            scale: scale,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            completion(rep?.nsImage)
        }
    }

    /// 类型文案（按扩展名给中文标签）
    public static func kindLabel(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "doc", "docx": return "Word 文档"
        case "xls", "xlsx": return "Excel 表格"
        case "ppt", "pptx": return "PPT 演示"
        case "pdf": return "PDF 文档"
        case "pages": return "Pages 文稿"
        case "numbers": return "Numbers 表格"
        case "key": return "Keynote 演示"
        case "zip", "rar", "7z", "tar", "gz", "tgz": return "压缩包"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp": return "图片"
        case "mp4", "mov", "mkv", "avi", "m4v": return "视频"
        case "mp3", "wav", "flac", "m4a", "aac": return "音频"
        case "swift", "py", "js", "ts", "java", "kt", "go", "rs", "c", "cpp", "h", "m", "sh":
            return "代码"
        case "md", "markdown": return "Markdown"
        case "json", "xml", "plist", "yml", "yaml": return "结构化数据"
        case "csv", "tsv": return "表格数据"
        case "txt", "log": return "文本"
        case "html", "css", "scss": return "网页"
        default:
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "文件" : "\(ext) 文件"
        }
    }
}

// MARK: - 悬停预览控制器

public final class FileHoverPreviewController: NSResponder {

    public static let shared = FileHoverPreviewController()

    private var panel: NSPanel?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var currentURL: URL?
    /// 鼠标在面板内（想拖动 / 调整大小时不要把面板关掉）
    private var pointerInsidePanel = false

    private static let sizeKey = "transferDock.previewSize"
    private static let defaultSize = NSSize(width: 320, height: 240)

    // MARK: 对外接口

    /// 悬停进入一行：0.4s 后弹预览（同一文件不重复重建内容）
    public func scheduleShow(url: URL) {
        hideWork?.cancel()
        hideWork = nil
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.show(url: url)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// 悬停离开：0.35s 后关（鼠标若已移进面板内则不关）
    public func scheduleHide() {
        showWork?.cancel()
        showWork = nil
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInsidePanel else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    public func hide() {
        showWork?.cancel()
        hideWork?.cancel()
        if panel?.isVisible == true {
            Log.info("TransferDock", "悬停预览收起")
        }
        panel?.orderOut(nil)
        currentURL = nil
    }

    // MARK: 面板

    private static var savedSize: NSSize {
        get {
            let defaults = UserDefaults.standard
            let w = defaults.double(forKey: sizeKey + ".w")
            let h = defaults.double(forKey: sizeKey + ".h")
            guard w >= 200, h >= 160 else { return defaultSize }
            return NSSize(width: w, height: h)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.width, forKey: sizeKey + ".w")
            defaults.set(newValue.height, forKey: sizeKey + ".h")
        }
    }

    private func show(url: URL) {
        // 已经在显示同一个文件：只挪位置，不重建（避免闪一下）
        if let panel, panel.isVisible, currentURL == url {
            position(panel, near: NSEvent.mouseLocation)
            return
        }
        currentURL = url

        let panel = ensurePanel()
        // contentView 是占满整窗的容器，host 是它的子视图
        if let host = panel.contentView?.subviews.first as? NSHostingView<FileHoverPreviewView> {
            host.rootView = FileHoverPreviewView(url: url)
        }
        position(panel, near: NSEvent.mouseLocation)
        panel.orderFrontRegardless()
        Log.info("TransferDock", "悬停预览显示 \(url.lastPathComponent) frame=\(Int(panel.frame.width))x\(Int(panel.frame.height))")
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let size = Self.savedSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.minSize = NSSize(width: 220, height: 170)
        panel.maxSize = NSSize(width: 900, height: 900)
        for button in [panel.standardWindowButton(.closeButton),
                       panel.standardWindowButton(.miniaturizeButton),
                       panel.standardWindowButton(.zoomButton)] {
            button?.isHidden = true
        }

        let host = NSHostingView(rootView: FileHoverPreviewView(url: URL(fileURLWithPath: "/")))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        // 用容器占满整窗（含标题栏）：fullSizeContentView 下内容要垫到透明标题栏底下，
        // 否则窗口顶部会留一条空带（截图里表现为黑条）。
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        container.addSubview(host)
        panel.contentView = container
        // contentView 挂上后 AppKit 会按整窗（含标题栏）重设容器尺寸，这里同步铺满
        container.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.frame = container.bounds

        // 鼠标进面板 → 取消自动关闭（用户要拖动 / 调整大小）
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil)
        host.addTrackingArea(tracking)

        // 尺寸变化 → 记住（下次按用户调过的大小开）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main) { [weak panel] _ in
                if let panel {
                    Self.savedSize = panel.frame.size
                }
            }

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, near point: NSPoint) {
        let size = panel.frame.size
        // 用「指针所在屏」而不是 NSScreen.main（App 未激活时 main 可能是别的屏）
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 默认放在指针右下方；贴边时翻到左侧/上方
        var origin = NSPoint(x: point.x + 18, y: point.y - size.height - 18)
        if origin.x + size.width > screen.maxX - 8 {
            origin.x = point.x - size.width - 18
        }
        if origin.y < screen.minY + 8 {
            origin.y = min(point.y + 24, screen.maxY - size.height - 8)
        }
        origin.x = min(max(screen.minX + 8, origin.x), screen.maxX - size.width - 8)
        origin.y = min(max(screen.minY + 8, origin.y), screen.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }

    // MARK: 面板内鼠标跟踪

    public override func mouseEntered(with event: NSEvent) {
        pointerInsidePanel = true
        hideWork?.cancel()
        hideWork = nil
    }

    public override func mouseExited(with event: NSEvent) {
        pointerInsidePanel = false
        scheduleHide()
    }
}

// MARK: - 预览内容视图

struct FileHoverPreviewView: View {
    let url: URL
    @Stored private var payload: FilePreviewPayload?
    @Stored private var loadToken = 0

    /// v129：压缩包单独走「列包内条目」，不再要 QuickLook 缩略图
    private var isArchive: Bool { ArchiveCore.isArchive(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            footer
        }
        .background(VisualEffectBackground())
        // 标题栏是透明的（拖动条）：内容要垫到它底下，否则顶部留一条空带
        .ignoresSafeArea()
        .task(id: url.path) {
            // v129（用户反馈）：中转站悬停压缩包时，原来只拿到一张 QuickLook 缩略图
            //（多数是 zip 图标），看不到里面有什么。改为直接列条目，见 content。
            if !isArchive { reload() }
        }
    }

    private func reload() {
        loadToken += 1
        let token = loadToken
        payload = nil
        FilePreviewBuilder.build(url: url) { result in
            guard token == loadToken else { return }
            payload = result
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(payload?.kindLabel ?? "…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var content: some View {
        Group {
            if isArchive {
                // v129：包内条目网格（复用归档窗/面板同一个 ArchivePeekView），
                // 悬停即可看到里面有 Word / PPT / 图片 / 文件夹，而不是一张 zip 图标。
                ScrollView {
                    ArchivePeekView(path: url.path, maxRows: 120)
                        .padding(8)
                }
            } else if let payload {
                if let image = payload.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else if let text = payload.text {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: iconName)
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Theme.tertiaryText)
                        Text(payload.error ?? "没有可显示的预览")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(payload?.sizeText ?? "—")
            Text("·").foregroundStyle(Theme.tertiaryText)
            Text(payload?.modifiedText ?? "—")
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("打开")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var iconName: String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp", "gif", "heic": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz", "tgz": return "archivebox"
        case "doc", "docx": return "doc.text"
        case "xls", "xlsx": return "tablecells"
        case "ppt", "pptx": return "rectangle.on.rectangle"
        case "md", "txt", "json", "xml", "csv": return "doc.plaintext"
        case "swift", "py", "js", "ts", "c", "cpp", "m", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// 毛玻璃背景（与面板玻璃语言一致）
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
