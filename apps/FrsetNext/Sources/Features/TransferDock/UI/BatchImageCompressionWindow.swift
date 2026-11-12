import AppKit
import SwiftUI

struct BatchImageCompressionRow: Identifiable {
    let id = UUID().uuidString
    let source: URL
    let original: NSImage?
    var originalBytes: Int
    var result: ImageCompressor.Result?
    var status = "待处理"
}

/// 只编排现有 ImageCompressor，成果仍保存在 toolbox 与本地中转。
@MainActor
final class BatchImageCompressionWindowController: NSWindowController, ObservableObject, NSWindowDelegate {
    static let shared = BatchImageCompressionWindowController()
    @Published var rows: [BatchImageCompressionRow] = []
    @Published var selectedID: String?
    @Published var dimension = "原始尺寸"
    @Published var format = "自动"
    @Published var quality = 0.7
    @Published var showOriginal = true
    @Published private(set) var isRunning = false
    @Published private(set) var isStaging = false
    @Published private(set) var finished = false
    @Published private(set) var processingID: String?
    @Published private(set) var cancelRequested = false
    @Published private(set) var copied = false
    @Published var error = ""
    private(set) var omitted = 0
    private var keyMonitor: Any?
    var resultURLs: [URL] { rows.compactMap { $0.result?.fileURL } }
    var completed: Int { rows.filter { $0.result != nil || $0.status.hasPrefix("失败") }.count }
    var failureCount: Int { rows.filter { $0.status.hasPrefix("失败") }.count }
    var selectedRow: BatchImageCompressionRow? { rows.first { $0.id == selectedID } }
    var showsJPEGQuality: Bool { format == "JPEG" || (format == "自动" && rows.contains { $0.source.pathExtension.lowercased() != "png" }) }

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "批量压缩图片"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 600, height: 440)
        super.init(window: panel)
        panel.delegate = self
        panel.applyOfficialChrome()
        let host = NSHostingView(rootView: BatchImageCompressionView(controller: self).frsetThemeChrome())
        host.sizingOptions = []
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        panel.setOfficialContent(host)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.keyCode == 53 || (event.keyCode == 13 && event.modifierFlags.contains(.command)) {
                self.cancelOrClose(); return nil
            }
            if event.keyCode == 36, !self.isRunning, !self.isStaging {
                if self.finished {
                    if !self.resultURLs.isEmpty { self.copyResults() }
                } else if !self.rows.isEmpty { self.startCompression() }
                return nil
            }
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError("使用代码创建图片压缩窗口") }

    func show(urls: [URL], omitted: Int) {
        guard let window else { return }
        if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        self.omitted = omitted
        rows = urls.map { url in
            BatchImageCompressionRow(source: url, original: NSImage(contentsOf: url),
                originalBytes: ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
        }
        selectedID = rows.first?.id
        dimension = "原始尺寸"; format = "自动"; quality = 0.7
        showOriginal = true; finished = false; cancelRequested = false; copied = false; error = ""
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame.insetBy(dx: 16, dy: 16)
        let size = NSSize(width: min(720, visible.width), height: min(540, visible.height))
        window.minSize = NSSize(width: min(600, visible.width), height: min(440, visible.height))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; window.animator().alphaValue = 1 }
    }

    func startCompression() {
        let maxDimension = CGFloat(Int(dimension) ?? 0)
        let selectedFormat = format
        let selectedQuality = quality
        isRunning = true; cancelRequested = false; error = ""
        Task {
            for index in rows.indices {
                if cancelRequested { break }
                let url = rows[index].source
                processingID = rows[index].id
                rows[index].status = "处理中"
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        let info = try ImageCompressor.inputInfo(path: url.path)
                        let asPNG = selectedFormat == "PNG" || (selectedFormat == "自动" && (info.isPNG || info.hasAlpha))
                        return try ImageCompressor.compress(path: url.path, maxDimension: maxDimension,
                                                            quality: selectedQuality, asPNG: asPNG)
                    }.value
                    rows[index].result = result
                    rows[index].originalBytes = result.originalBytes
                    rows[index].status = "完成 · \(result.fileURL?.pathExtension.uppercased() ?? "")"
                } catch {
                    rows[index].status = "失败：\(error.localizedDescription)"
                }
            }
            for index in rows.indices where rows[index].status == "待处理" { rows[index].status = "未处理" }
            processingID = nil; isRunning = false; finished = true
            if !resultURLs.isEmpty {
                isStaging = true
                LocalTransferStore.shared.add(urls: resultURLs) { [weak self] _ in
                    self?.isStaging = false
                    self?.error = LocalTransferStore.shared.lastError ?? ""
                }
            }
        }
    }

    func copyResults() {
        if let reason = ClipboardManager.shared.copyFiles(resultURLs, successMessage: "已复制 \(resultURLs.count) 个结果文件") { error = reason }
        else {
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.copied = false }
        }
    }
    func viewInTransferDock() {
        window?.orderOut(nil)
        MonitorCenterPresenter.shared.selectTransferDock()
        PanelController.shared.show()
    }
    func cancelOrClose() {
        if isRunning { cancelRequested = true }
        else { close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isRunning { cancelRequested = true; return false }
        return true
    }
}

private struct BatchImageCompressionView: View {
    @ObservedObject var controller: BatchImageCompressionWindowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("批量压缩图片").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(controller.rows.count) 张图片").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if controller.omitted > 0 {
                Text("其余 \(controller.omitted) 个非图片文件未参与，原文件保持不变。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                List(selection: $controller.selectedID) {
                    ForEach(controller.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.source.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            HStack {
                                Text(ImageCompressor.byteText(row.originalBytes))
                                if let result = row.result {
                                    Text("→ \(ImageCompressor.byteText(result.compressedBytes))")
                                }
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                if controller.processingID == row.id { ProgressView().controlSize(.small) }
                                else { Image(systemName: row.result != nil ? "checkmark.circle" : row.status.hasPrefix("失败") ? "exclamationmark.triangle" : "circle") }
                                Text(row.status).lineLimit(2)
                            }.font(.system(size: 11))
                            if let result = row.result {
                                Text(result.savedPercent >= 0 ? "减少 \(Int(result.savedPercent * 100))%" : "增大 \(Int(-result.savedPercent * 100))%")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4).tag(row.id)
                    }
                }.frame(minWidth: 280)
                VStack {
                    Picker("图片预览", selection: $controller.showOriginal) {
                        Text("原图").tag(true); Text("结果").tag(false)
                    }.pickerStyle(.segmented)
                    if let row = controller.selectedRow, let image = controller.showOriginal ? row.original : row.result?.image {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { Text("选择图片查看预览").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(minWidth: 220)
            }.frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Picker("最长边", selection: $controller.dimension) {
                    ForEach(["原始尺寸", "1024", "1600", "2048"], id: \.self) { Text($0).tag($0) }
                }
                Picker("格式", selection: $controller.format) {
                    ForEach(["自动", "JPEG", "PNG"], id: \.self) { Text($0).tag($0) }
                }
                if controller.showsJPEGQuality {
                    Text("JPEG \(Int(controller.quality * 100))%").font(.system(size: 11))
                    Slider(value: $controller.quality, in: 0.05...1, step: 0.05).frame(width: 90)
                }
            }.disabled(controller.isRunning || controller.isStaging || controller.finished)
            Text("自动：PNG 和透明图片保持 PNG；HEIC 输出 JPEG。原图与原始尺寸默认保留。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !controller.error.isEmpty { Text(controller.error).font(.system(size: 12)).foregroundStyle(.red) }
            if controller.cancelRequested { Text("当前文件完成后停止后续处理").font(.system(size: 12)) }
            HStack(spacing: 8) {
                if controller.isRunning { Text("已完成 \(controller.completed)／\(controller.rows.count)") }
                else if controller.finished {
                    Text("成功 \(controller.resultURLs.count) · 失败 \(controller.failureCount) · 未处理 \(controller.rows.count - controller.completed)")
                }
                if controller.isStaging { ProgressView().controlSize(.small); Text("加入中转…") }
                Spacer()
                Button(controller.isRunning ? "取消后续处理" : "取消") { controller.cancelOrClose() }
                if controller.finished {
                    Button("在中转站查看") { controller.viewInTransferDock() }.disabled(controller.isStaging)
                    Button(controller.copied ? "✓ 已复制 \(controller.resultURLs.count) 个文件" : "复制 \(controller.resultURLs.count) 个结果文件") { controller.copyResults() }
                        .frame(width: 156)
                        .disabled(controller.resultURLs.isEmpty).keyboardShortcut(.return, modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("开始压缩") { controller.startCompression() }.disabled(controller.isRunning || controller.rows.isEmpty)
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
            }.font(.system(size: 12))
        }
        .padding(16).padding(.top, OfficialChrome.titlebarInset)
        .animation(.easeOut(duration: reduceMotion ? 0.08 : 0.12), value: controller.completed)
    }
}
