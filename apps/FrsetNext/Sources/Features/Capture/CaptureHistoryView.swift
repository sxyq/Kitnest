import SwiftUI
import AppKit

// v130（SnowShot 对齐）②：截图历史视图
//
// 缩略图网格 + 搜索（OCR 文本 / 日期 / 模式）+ 模式过滤；
// 双击「继续标注」（恢复未完成标注到编辑器）/ 复制 / 在 Finder 中显示 / 删除。
// 入口：截图动作工具条「历史」按钮、面板截图区「历史」、深链 frsetnext://capture?action=history。

// MARK: - 视图模型

final class CaptureHistoryVM: ObservableObject {
    @Published var items: [CaptureHistoryItem] = []
    @Published var query: String = ""
    @Published var modeFilter: String = "all"

    /// 模式过滤选项（值 = CaptureMode.rawValue 或 "all"）
    static let modeOptions: [(value: String, title: String)] = [
        ("all", "全部模式"),
        ("area", "区域截图"),
        ("full", "全屏截图"),
        ("window", "窗口截图"),
        ("ocr", "截图识字"),
        ("pin", "屏幕钉图"),
        ("long", "长截图"),
        ("delayed", "延时截图"),
    ]

    init() {
        reload()
        NotificationCenter.default.addObserver(
            forName: CaptureHistoryStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    func reload() {
        items = CaptureHistoryStore.shared.items(query: query, mode: modeFilter)
    }

    /// v130.2：点外部收起时重置搜索/过滤，下次打开是干净状态
    func clearOnDismiss() {
        query = ""
        modeFilter = "all"
        items = []
    }

    func delete(_ item: CaptureHistoryItem) {
        CaptureHistoryStore.shared.delete(id: item.id)
        items.removeAll { $0.id == item.id }
    }

    /// 继续标注：打开标注编辑器并恢复未完成标注
    func continueAnnotate(_ item: CaptureHistoryItem) {
        AnnotationEditorController.shared.open(url: item.url, annotationState: item.annotationState)
    }

    func copy(_ item: CaptureHistoryItem) {
        guard let image = ImageProcessor.cgImage(from: item.url) else {
            Toast.show("无法读取图片", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        ScreenshotManager.shared.copyToPasteboard(image)
        Toast.show("截图已复制", icon: "checkmark.circle.fill")
    }

    func revealInFinder(_ item: CaptureHistoryItem) {
        if FileManager.default.fileExists(atPath: item.path) {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else {
            Toast.show("文件已不存在", icon: "exclamationmark.triangle", isWarning: true)
        }
    }
}

// MARK: - 历史视图

struct CaptureHistoryView: View {
    @ObservedObject private var vm: CaptureHistoryVM
    /// 缩略图缓存（path → NSImage）
    // v130：@State 宏在本工程不可用（SwiftUIMacros 缺失），用 @Stored 兼容层
    @Stored private var thumbCache: [String: NSImage] = [:]

    init(vm: CaptureHistoryVM = CaptureHistoryVM()) {
        _vm = ObservedObject(wrappedValue: vm)
    }

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if vm.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(vm.items) { item in
                            cell(item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { vm.reload() }
    }

    // MARK: 过滤条

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索 OCR 文本 / 日期（2026-10-26）/ 文件名", text: $vm.query)
                .textFieldStyle(.plain)
                .onSubmit { vm.reload() }
            if !vm.query.isEmpty {
                Button {
                    vm.query = ""
                    vm.reload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Picker("", selection: $vm.modeFilter) {
                ForEach(CaptureHistoryVM.modeOptions, id: \.value) { opt in
                    Text(opt.title).tag(opt.value)
                }
            }
            .frame(width: 118)
            .onChange(of: vm.modeFilter) { _ in vm.reload() }
            Button {
                vm.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("暂无截图历史")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("截图后自动记录（上限 \(CaptureHistoryStore.maxEntries) 条）")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 单元格

    private func cell(_ item: CaptureHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let img = thumbnail(item) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Theme.cardBackground)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 88)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.smallRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius)
                    .stroke(Theme.separator, lineWidth: 0.5)
            )

            Text(item.url.lastPathComponent)
                .font(.system(size: 9))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(modeTitle(item.mode))
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.14))
                    .clipShape(Capsule())
                Text("\(item.width)×\(item.height)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(item.createdAt.relativeText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if !item.ocrText.isEmpty {
                Text(item.ocrText.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 双击 = 继续标注（含未完成标注恢复）
            vm.continueAnnotate(item)
        }
        .contextMenu {
            Button("继续标注") { vm.continueAnnotate(item) }
            Button("复制到剪贴板") { vm.copy(item) }
            Button("在访达中显示") { vm.revealInFinder(item) }
            Divider()
            Button("删除", role: .destructive) { vm.delete(item) }
        }
    }

    private func thumbnail(_ item: CaptureHistoryItem) -> NSImage? {
        if let cached = thumbCache[item.id] { return cached }
        guard let url = item.thumbnailURL ?? (FileManager.default.fileExists(atPath: item.path) ? item.url : nil),
              let img = NSImage(contentsOf: url) else { return nil }
        DispatchQueue.main.async { thumbCache[item.id] = img }
        return img
    }

    private func modeTitle(_ raw: String) -> String {
        CaptureMode(rawValue: raw)?.title ?? (raw.isEmpty ? "截图" : raw)
    }
}

// MARK: - 历史窗口

final class CaptureHistoryWindowController: NSObject, NSWindowDelegate {
    public static let shared = CaptureHistoryWindowController()
    private var window: NSWindow?
    private let vm = CaptureHistoryVM()
    // v130.2：点外部收起——历史窗是工具条/⌘H 弹出的瞬态窗，点其他地方应自动消失。
    //  双监听：global（点其他 App）+ local（点本 App 其他地方）；只留其一会漏一半场景。
    private var outsideGlobal: Any?
    private var outsideLocal: Any?

    private override init() { super.init() }

    /// 打开历史窗（深链 / 工具条 / 面板共用入口）
    public func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            vm.reload()
            installOutsideMonitors()
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "截图历史"
        win.applyOfficialChrome()
        win.minSize = NSSize(width: 480, height: 300)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = NSHostingView(rootView: CaptureHistoryView(vm: vm))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        installOutsideMonitors()
    }

    /// v130.2：点窗口外部即关闭（global + local 双监听；Esc 也关）
    private func installOutsideMonitors() {
        removeOutsideMonitors()
        // ① 点其他 App：global（无需本 App 焦点，但需辅助功能授权；未授权时静默失效）
        outsideGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        // ② 点本 App 其他区域：local（过滤掉点在本窗内的）
        outsideLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] ev in
            guard let self, let win = self.window else { return ev }
            // Esc 关闭
            if ev.type == .keyDown, ev.keyCode == 53 { self.dismiss(); return nil }
            // 鼠标：点在窗外才关
            if ev.type == .leftMouseDown || ev.type == .rightMouseDown {
                if !win.frame.contains(NSEvent.mouseLocation) {
                    self.dismiss()
                    return ev
                }
            }
            return ev
        }
    }

    private func removeOutsideMonitors() {
        if let g = outsideGlobal { NSEvent.removeMonitor(g) }
        if let l = outsideLocal { NSEvent.removeMonitor(l) }
        outsideGlobal = nil
        outsideLocal = nil
    }

    /// 收起（等价关闭；保留下次 show() 重建语义）
    public func dismiss() {
        removeOutsideMonitors()
        window?.orderOut(nil)
        window = nil
        vm.clearOnDismiss()
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            removeOutsideMonitors()
            window = nil
        }
    }
}

// MARK: - 深链入口（v130②）

/// frsetnext://capture?action=history 由 App 层分流到这里（App/ 一行接线，见交付说明）。
public enum CaptureDeepLink {
    /// 处理 frsetnext://capture?...；返回是否已消费
    @discardableResult
    public static func handle(url: URL) -> Bool {
        guard url.scheme == "frsetnext", url.host == "capture" else { return false }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let action = comps?.queryItems?.first(where: { $0.name == "action" })?.value ?? "history"
        switch action {
        case "history":
            CaptureHistoryWindowController.shared.show()
        case "delayed":
            // 排障/测试入口：frsetnext://capture?action=delayed&seconds=3
            let raw = comps?.queryItems?.first(where: { $0.name == "seconds" })?.value
            let s = raw.flatMap(Int.init) ?? ScreenshotManager.shared.delaySeconds
            DelayedCaptureController.shared.start(seconds: s)
        case "region":
            ScreenshotManager.shared.captureRegion()
        default:
            CaptureHistoryWindowController.shared.show()
        }
        return true
    }
}
