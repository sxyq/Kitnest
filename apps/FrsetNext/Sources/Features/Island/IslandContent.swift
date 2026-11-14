import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandRootView: View {
    @ObservedObject var controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Stored private var selectedRecord: String? = nil
    @Stored private var selectedMetric = IslandMetric.cpu
    @Stored private var selectedTool: String? = nil
    @Stored private var selectedDate = Date.now
    @Stored private var records: [IslandRecentRow] = []
    @Stored private var homeMonitorVisible = false

    private var preview: Bool { controller.previewOnly || isSettingsPreview }
    private var monitoringVisible: Bool {
        controller.expanded && (controller.page == .monitor || (controller.page == .home && homeMonitorVisible))
    }

    var body: some View {
        IslandSurface(controller: controller, height: controller.effectiveHeight) {
            if controller.expanded || preview {
                pageContent(controller.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: controller.effectiveWidth, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.page)
        .onAppear {
            if controller.expanded || preview { reloadRecords() }
            updateMonitoring()
        }
        .onChange(of: controller.expanded) { expanded in
            if expanded { reloadRecords() }
            updateMonitoring()
        }
        .onChange(of: controller.page) { _ in reloadRecords(); updateMonitoring() }
        .onChange(of: homeMonitorVisible) { _ in updateMonitoring() }
        .onChange(of: preview) { _ in reloadRecords(); updateMonitoring() }
        .onDisappear { if !preview { MonitorSampler.shared.setIslandActive(false) } }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardManager.itemsDidChangeNotification)) { _ in
            if !preview && controller.expanded { reloadRecords() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localTransferDidChange)) { _ in
            if !preview && controller.expanded { reloadRecords() }
        }
    }

    private func updateMonitoring() {
        if !preview { MonitorSampler.shared.setIslandActive(monitoringVisible) }
    }

    @ViewBuilder private func pageContent(_ page: IslandPage) -> some View {
        switch page {
        case .home: home
        case .clipboard: recordsPage
        case .monitor: IslandMonitorPage(controller: controller, selectedMetric: $selectedMetric, previewOnly: preview)
        case .media: IslandMediaContent(controller: controller, previewOnly: preview)
        case .calendar: IslandCalendarContent(controller: controller, selectedDate: $selectedDate, previewOnly: preview)
        case .tools: toolsPage
        }
    }

    private var home: some View {
        IslandWidgetGrid(controller: controller) { (item: IslandWidget, size: IslandWidgetSize) in
            widget(item, size: size) { widgetContent(item, size: size) }
        }
    }

    @ViewBuilder private func widgetContent(_ item: IslandWidget, size: IslandWidgetSize) -> some View {
        switch item {
        case .monitor:
            IslandMonitorChart(metric: selectedMetric, compact: true, previewOnly: preview,
                               tint: controller.configuration.color(for: item))
                .onAppear { homeMonitorVisible = true }
                .onDisappear { homeMonitorVisible = false }
        case .clipboard:
            if records.isEmpty {
                Text("暂无近期内容").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if size.columns == 4 {
                HStack(spacing: 10) {
                    ForEach(Array(records.prefix(4))) { record in compactRecord(record) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(records.prefix(size.rows == 2 ? 3 : 1))) { record in
                        compactRecord(record)
                    }
                    if size.rows == 2 {
                        Button {
                            if let record = records.first { copy(record) }
                        } label: { Label("复制最近内容", systemImage: "doc.on.doc") }
                            .font(.system(size: 11)).buttonStyle(IslandButtonStyle())
                    }
                }
            }
        case .media:
            IslandMediaContent(controller: controller, previewOnly: preview, size: size)
        case .volume:
            IslandVolumeContent(controller: controller, previewOnly: preview, size: size)
        case .calendar:
            IslandCalendarContent(controller: controller, selectedDate: $selectedDate, previewOnly: preview, size: size)
        case .tools:
            let tools = preview ? [] : ToolRegistry.enabledTools
            if preview {
                Button { controller.page = .tools } label: { Label("快捷工具", systemImage: "square.grid.2x2") }
                    .font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            } else if tools.isEmpty {
                Text("暂无已启用工具").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4),
                                        count: size.columns == 4 ? 4 : size.columns), spacing: 4) {
                    ForEach(Array(tools.prefix(size.columns * size.rows))) { tool in
                        Button { selectedTool = tool.id; controller.page = .tools } label: {
                            Label(tool.name, systemImage: tool.systemImage).font(.system(size: 11)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(IslandButtonStyle())
                    }
                }
            }
        }
    }

    private func widget<Content: View>(_ item: IslandWidget, size: IslandWidgetSize,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: size.rows == 2 ? 6 : 3) {
            Button { controller.page = item.page } label: {
                Label(item.title, systemImage: item.icon).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(controller.configuration.color(for: item))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(IslandButtonStyle()).accessibilityLabel("打开" + item.title)
                .padding(.trailing, 24)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(size.rows == 2 ? 10 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tint(controller.configuration.color(for: item))
            .islandGlow(enabled: controller.glowEnabled && controller.expanded && controller.page == .home)
            .glassCard(radius: IslandLayout.cardRadius, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
    }

    private func compactRecord(_ record: IslandRecentRow) -> some View {
        HStack(spacing: 4) {
            Button { select(record, openPage: true) } label: {
                Label(record.title, systemImage: record.icon).font(.system(size: 11)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        if !preview, let url = record.url {
                            IslandFileDragSource(urls: [url], controller: controller) { select(record, openPage: true) }
                        }
                    }
            }.buttonStyle(IslandButtonStyle()).accessibilityLabel(record.title)
            if record.id == selectedRecord {
                Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordsPage: some View {
        VStack(spacing: 8) {
            HStack {
                Text("剪贴板与中转").fontWeight(.medium)
                Spacer()
                Text(preview ? "设置预览" : "\(records.count) 项近期内容 · 可拖入文件")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 11))
            GeometryReader { geometry in
                HStack(spacing: 12) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(records) { record in
                                    Button { select(record) } label: {
                                        record.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selectedRecord == record.id ? Theme.accent(for: nil).opacity(0.14) : .clear,
                                                        in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
                                            .overlay {
                                                if !preview, let url = record.url {
                                                    IslandFileDragSource(urls: [url], controller: controller) { select(record) }
                                                }
                                            }
                                    }.buttonStyle(IslandButtonStyle())
                                        .accessibilityAddTraits(selectedRecord == record.id ? .isSelected : [])
                                        .id(record.id)
                                }
                            }
                        }
                        .onMoveCommand { direction in
                            guard let index = records.firstIndex(where: { $0.id == selectedRecord }),
                                  direction == .up || direction == .down else { return }
                            let next = min(max(index + (direction == .up ? -1 : 1), 0), records.count - 1)
                            select(records[next])
                            proxy.scrollTo(records[next].id, anchor: .center)
                        }
                    }.frame(width: geometry.size.width * 0.38)
                    Color.white.opacity(0.1).frame(width: Theme.Stroke.hairline)
                    if let record = records.first(where: { $0.id == selectedRecord }) {
                        IslandRecordDetail(record: record, controller: controller, previewOnly: preview) { copy(record) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(records.isEmpty ? "暂无内容，可拖入文件或文件夹" : "选择记录查看完整内容")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            if preview { controller.feedback = "预览接收 \(files.count) 个文件"; return true }
            controller.beginInteraction()
            LocalTransferStore.shared.add(urls: files) { count in
                controller.endInteraction()
                controller.feedback = LocalTransferStore.shared.lastError ?? "已暂存 \(count) 个文件"
                reloadRecords()
            }
            return true
        }
    }

    private func select(_ record: IslandRecentRow, openPage: Bool = false) {
        selectedRecord = record.id
        if openPage { controller.page = .clipboard }
    }

    /// 独立近期查询，不改主剪贴板的搜索词、过滤条件或分页。
    private func reloadRecords() {
        if !preview && (!controller.expanded || (controller.page != .home && controller.page != .clipboard)) { return }
        if preview {
            var samples = IslandSample.clipboard
            samples.append(contentsOf: IslandSample.files.filter { file in
                !samples.contains { $0.title == file.title && $0.icon == file.icon }
            })
            records = samples.enumerated().map { index, sample in
                IslandRecentRow(id: "sample:\(index)", title: sample.title, icon: sample.icon,
                                date: Date(timeIntervalSince1970: 0), sample: sample)
            }
        } else {
            let clipboard = ClipboardRepository.shared.fetch(ClipboardQuery())
            let transfers = LocalTransferStore.shared.items
            var joined: [String: IslandRecentRow] = [:]
            var aliases: [String: String] = [:]
            for transfer in transfers {
                let original = URL(fileURLWithPath: transfer.originalPath).standardizedFileURL.path
                let staged = transfer.stagedURL.standardizedFileURL.path
                let key = "file:" + original
                aliases[original] = key
                aliases[staged] = key
                if joined[key] == nil {
                    joined[key] = IslandRecentRow(id: key, title: transfer.name, icon: fileIcon(transfer.stagedURL),
                        date: Date(timeIntervalSince1970: transfer.addedAt), transfer: transfer, url: transfer.stagedURL)
                }
            }
            for item in clipboard {
                if item.type == .file {
                    for path in (item.content ?? "").split(separator: "\n") {
                        let url = URL(fileURLWithPath: String(path)).standardizedFileURL
                        let key = aliases[url.path] ?? "file:" + url.path
                        if var row = joined[key] {
                            if row.clipboard == nil { row.clipboard = item }
                            row.date = max(row.date, item.timestamp)
                            joined[key] = row
                        } else {
                            joined[key] = IslandRecentRow(id: key, title: url.lastPathComponent, icon: fileIcon(url),
                                                          date: item.timestamp, clipboard: item, url: url)
                        }
                    }
                } else {
                    let icon: String
                    switch item.type {
                    case .image: icon = "photo"
                    case .url: icon = "link"
                    case .text, .richtext:
                        let kind = PreviewPopoverContentModel.classifyRawText(item.content ?? "")
                        icon = kind == .code || kind == .json ? "curlybraces" : "text.alignleft"
                    case .file: icon = "doc"
                    }
                    let url = item.type == .image ? item.imagePath.map(ClipboardFileStore.url(forRelativePath:)) : nil
                    joined["clipboard:" + item.id] = IslandRecentRow(id: "clipboard:" + item.id, title: item.displayTitle,
                        icon: icon, date: item.timestamp, clipboard: item, url: url)
                }
            }
            records = joined.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        }
        if !records.contains(where: { $0.id == selectedRecord }) { selectedRecord = records.first?.id }
    }

    private func fileIcon(_ url: URL) -> String {
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        if directory.boolValue { return "folder" }
        return FilePreviewBuilder.imageExtensions.contains(url.pathExtension.lowercased()) ? "photo" : "doc"
    }

    @discardableResult private func copy(_ record: IslandRecentRow) -> String? {
        if preview { controller.feedback = "复制效果预览"; return nil }
        let error: String?
        if record.clipboard?.type == .image, let item = record.clipboard {
            error = ClipboardManager.shared.copy(item, autoPaste: false)
        } else if let url = record.url {
            error = ClipboardManager.shared.copyFiles([url], successMessage: "已复制 " + record.title)
        } else if let item = record.clipboard {
            var failure: String?
            _ = ClipboardManager.shared.fullText(for: item) { failure = $0 }
            if let failure { controller.feedback = failure; return failure }
            error = ClipboardManager.shared.copy(item, autoPaste: false)
        } else { return "记录没有可复制的内容" }
        controller.feedback = error ?? "已复制 " + record.title
        return error
    }

    private var toolsPage: some View {
        let tools = preview ? [] : ToolRegistry.enabledTools
        return HStack(spacing: 10) {
            ScrollView {
                VStack(spacing: 6) {
                    if preview {
                        Button("快捷工具") { controller.feedback = "工具选择预览" }.buttonStyle(IslandButtonStyle())
                    }
                    ForEach(tools) { tool in
                        Button { selectedTool = tool.id } label: {
                            Label(tool.name, systemImage: tool.systemImage).font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                .background(selectedTool == tool.id ? Theme.accent(for: nil).opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius))
                        }.buttonStyle(IslandButtonStyle())
                    }
                }
            }.frame(width: 180)
            VStack(alignment: .leading, spacing: 12) {
                if preview {
                    Label("快捷工具", systemImage: "square.grid.2x2").font(.system(size: 16))
                    Text("设置预览，不执行工具").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("预览操作") { controller.feedback = "工具操作预览" }.buttonStyle(IslandButtonStyle())
                } else if let tool = tools.first(where: { $0.id == selectedTool }) ?? tools.first {
                    Label(tool.name, systemImage: tool.systemImage).font(.system(size: 16, weight: .medium))
                    ScrollView { Text(tool.toolDescription).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("打开工具") {
                        controller.collapse()
                        ToolboxUIState.shared.open(tool.id)
                    }.buttonStyle(IslandButtonStyle())
                } else {
                    Text("暂无已启用工具").foregroundStyle(.secondary)
                }
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .glassCard(radius: IslandLayout.cardRadius, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
        }
    }
}

/// 刘海列表行只携带两个正式来源的引用，不修改、迁移或删除源记录。
private struct IslandRecentRow: View, Identifiable {
    let id: String
    let title: String
    let icon: String
    var date: Date
    var clipboard: ClipboardItem? = nil
    var transfer: LocalTransferItem? = nil
    var url: URL? = nil
    var sample: IslandSample? = nil

    var detail: String {
        if let sample { return sample.detail }
        let source = clipboard != nil && transfer != nil ? "剪贴板 · 中转" : transfer != nil ? "中转" : "剪贴板"
        let type = icon == "folder" ? "文件夹" : icon == "photo" ? "图片" : icon == "link" ? "链接" : icon == "curlybraces" ? "代码" : url != nil ? "文件" : "文字"
        return [type, source, transfer?.sizeText, clipboard?.sourceApp,
                date.formatted(.dateTime.month().day().hour().minute())].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12)).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct IslandRecordDetail: View {
    let record: IslandRecentRow
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var copy: () -> String?
    @Stored private var text = ""
    @Stored private var image: NSImage? = nil
    @Stored private var children: [URL] = []
    @Stored private var error: String? = nil
    @Stored private var loadedRecord: String? = nil
    @Stored private var attributedText = NSAttributedString(string: "")
    @Stored private var copyFailure: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.detail).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Text(record.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                Spacer(minLength: 4)
                Button { copyFailure = copy() } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.system(size: 11))
                        .padding(.horizontal, 6).frame(height: 24)
                }
                    .buttonStyle(IslandButtonStyle()).accessibilityLabel("复制所选内容")
            }
            if !previewOnly, let url = record.url {
                Label("拖出到 Finder 或其他 App", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11)).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(IslandLayout.cardFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { IslandFileDragSource(urls: [url], controller: controller) {} }
                    .accessibilityLabel("拖出 " + record.title)
            }
            if loadedRecord == record.id, let error = copyFailure ?? error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
            }
            if loadedRecord != record.id {
                ProgressView("正在读取").font(.system(size: 11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !previewOnly, error == nil, let url = record.url, DocumentInlinePreview.supportedExtensions.contains(url.pathExtension.lowercased()) {
                DocumentInlinePreview(url: url)
            } else if image == nil && children.isEmpty && record.icon != "photo" {
                PreviewTextViewRepresentable(attributedText: attributedText, monospaced: record.icon == "curlybraces",
                                             sourceText: text)
                    .environment(\.isSettingsPreview, previewOnly)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else if previewOnly && record.icon == "photo" {
                            Image(systemName: "photo").font(.system(size: 50)).padding(30)
                        }
                        ForEach(children, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc")
                                .font(.system(size: 12)).padding(.vertical, 2)
                                .overlay {
                                    if !previewOnly { IslandFileDragSource(urls: [url], controller: controller) {} }
                                }
                        }
                        Text(text).font(record.icon == "curlybraces" ? .system(size: 12, design: .monospaced) : .system(size: 12))
                            .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: record.id + (record.url?.path ?? "") + (record.clipboard?.dedupeKey ?? "")) { await load() }
    }

    private func load() async {
        let id = record.id
        let item = record.clipboard
        let url = record.url
        copyFailure = nil
        if previewOnly {
            text = record.sample?.body ?? ""
            if let sample = record.sample, !sample.children.isEmpty {
                text += "\n\n" + sample.children.joined(separator: "\n")
            }
            image = nil; children = []; error = nil
            setAttributedText()
            loadedRecord = id
            return
        }
        let result = await Task.detached(priority: .userInitiated) { () -> (String, [URL], URL?, String?) in
            if let item, item.type != .file && item.type != .image {
                var failure: String?
                let fullText = ClipboardManager.shared.fullText(for: item) { failure = $0 }
                return (failure == nil ? fullText : item.content ?? "", [], nil, failure)
            }
            guard let url else { return ("", [], nil, "记录没有可读取的文件路径") }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                let ext = url.pathExtension.lowercased()
                if values.isDirectory == true && !DocumentInlinePreview.supportedExtensions.contains(ext) {
                    let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    return (url.path, children, nil, nil)
                }
                if FilePreviewBuilder.imageExtensions.contains(ext) { return (url.path, [], url, nil) }
                if FilePreviewBuilder.textExtensions.contains(ext) && !DocumentInlinePreview.supportedExtensions.contains(ext) {
                    return (try FilePreviewBuilder.readText(url: url), [], nil, nil)
                }
                return (url.path, [], nil, nil)
            } catch { return (url.path, [], nil, "无法读取 \(url.path)：\(error.localizedDescription)") }
        }.value
        guard !Task.isCancelled else { return }
        var loadedImage: NSImage?
        var failure = result.3
        if let imageURL = result.2 {
            loadedImage = await withCheckedContinuation { continuation in
                PreviewImageLoader.shared.loadImage(at: imageURL, needsFullRebuild: true) {
                    continuation.resume(returning: $0)
                }
            }
            if loadedImage == nil { failure = "无法读取图片：" + imageURL.path }
        }
        guard !Task.isCancelled else { return }
        text = result.0; children = result.1; image = loadedImage; error = failure
        setAttributedText()
        loadedRecord = id
    }

    private func setAttributedText() {
        let font = record.icon == "curlybraces" ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                                              : NSFont.systemFont(ofSize: 12)
        attributedText = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}

/// NSURL 原生拖动会话不触碰系统剪贴板，也不创建文件副本。
private struct IslandFileDragSource: NSViewRepresentable {
    let urls: [URL]
    let controller: IslandController
    var select: () -> Void

    func makeNSView(context: Context) -> IslandFileDragView { IslandFileDragView() }
    func updateNSView(_ view: IslandFileDragView, context: Context) {
        view.urls = urls; view.controller = controller; view.select = select
    }
}

private final class IslandFileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    weak var controller: IslandController?
    var select: (() -> Void)?
    private var mouseStart: NSPoint? = nil
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        mouseStart = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseStart,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 else { return }
        for url in urls where !FileManager.default.isReadableFile(atPath: url.path) {
            controller?.feedback = "无法拖出文件：" + url.path
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        dragging = true
        controller?.beginInteraction()
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging, mouseStart != nil { select?() }
        mouseStart = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; mouseStart = nil
        controller?.endInteraction()
        controller?.feedback = operation.isEmpty ? "拖出已取消" : "拖出已结束"
    }
}

private struct IslandMediaContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil

    var body: some View {
        Group {
            if previewOnly {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.tracks[controller.track].0).font(.system(size: size == nil ? 18 : 11)).lineLimit(1)
                    if size == nil || size?.rows == 2 {
                        Text(controller.tracks[controller.track].1).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if size == nil || size?.rows == 2 || size?.columns == 4 {
                        HStack(spacing: 8) {
                            Button { controller.changeTrack(-1) } label: { Image(systemName: "backward.end.fill") }
                            Button { controller.playing.toggle() } label: { Image(systemName: controller.playing ? "pause.fill" : "play.fill") }
                            Button { controller.changeTrack(1) } label: { Image(systemName: "forward.end.fill") }
                        }.buttonStyle(IslandButtonStyle()).font(.system(size: 11))
                    }
                    if size == nil {
                        Slider(value: $controller.seek, in: 0...240).accessibilityLabel("预览播放进度")
                        IslandVolumeContent(controller: controller, previewOnly: true)
                    }
                }
            } else {
                IslandLiveMediaContent(controller: controller, size: size)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IslandLiveMediaContent: View {
    @ObservedObject var controller: IslandController
    var size: IslandWidgetSize?
    @ObservedObject private var audio = AudioMixerController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if size?.columns == 4 {
                HStack {
                    apps
                    unavailableControls
                }
            } else {
                apps
                if size == nil || size?.rows == 2 { unavailableControls }
            }
            if size == nil {
                Text("现有服务提供有声应用；曲目、进度与播放控制不可用。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button("刷新有声应用") { audio.refreshPlayingApps() }.buttonStyle(IslandButtonStyle())
                IslandVolumeContent(controller: controller, previewOnly: false)
            }
        }.onAppear { audio.refreshPlayingApps() }
    }

    private var apps: some View {
        Group {
            if audio.playingApps.isEmpty {
                Label("暂无有声应用", systemImage: "speaker.slash").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(Array(audio.playingApps.prefix(size == nil ? audio.playingApps.count : size?.rows == 2 ? 2 : 1))) { app in
                    HStack(spacing: 6) {
                        if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(app.name).font(.system(size: 11)).lineLimit(1)
                    }
                }
            }
        }
    }

    private var unavailableControls: some View {
        HStack(spacing: 10) {
            ForEach(["backward.end.fill", "play.fill", "forward.end.fill"], id: \.self) { icon in
                Button {} label: { Image(systemName: icon).font(.system(size: 11)) }
                    .buttonStyle(IslandButtonStyle()).disabled(true)
                    .help("现有媒体服务没有播放控制").accessibilityLabel("播放控制不可用")
            }
            Text("不可用").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct IslandVolumeContent: View {
    @ObservedObject var controller: IslandController
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil

    var body: some View {
        Group {
            if previewOnly {
                HStack(spacing: 4) {
                    Slider(value: $controller.volume, in: 0...100).controlSize(.mini).accessibilityLabel("预览音量")
                    Text("\(Int(controller.volume))%").font(.system(size: 10)).monospacedDigit()
                }
            } else {
                IslandLiveVolumeContent(size: size)
            }
        }
    }
}

private struct IslandLiveVolumeContent: View {
    var size: IslandWidgetSize?
    @ObservedObject private var audio = AudioMixerController.shared
    @Stored private var volume = 0.0
    @Stored private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Slider(value: Binding(get: { volume }, set: { value in
                    audio.setSystemVolume(Float(value))
                    volume = audio.getSystemVolume()
                    feedback = abs(volume - value) < 0.02 ? "" : "输出设备不支持设置音量"
                }), in: 0...1).controlSize(.mini).accessibilityLabel("系统输出音量")
                Text("\(Int(volume * 100))%").font(.system(size: 10)).monospacedDigit()
            }
            if !feedback.isEmpty { Text(feedback).font(.system(size: 10)).foregroundStyle(.red) }
            if size == nil || size?.rows == 2 {
                Text(audio.devices.first(where: { $0.isDefault })?.name ?? "系统默认输出")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Button("刷新音量") { volume = audio.getSystemVolume() }.buttonStyle(IslandButtonStyle())
                    .font(.system(size: 11))
            }
        }.onAppear { volume = audio.getSystemVolume() }
    }
}

private struct IslandCalendarContent: View {
    @ObservedObject var controller: IslandController
    @Binding var selectedDate: Date
    let previewOnly: Bool
    var size: IslandWidgetSize? = nil

    var body: some View {
        Group {
            if previewOnly {
                VStack(alignment: .leading, spacing: 6) {
                    Text("2026 年 11 月 14 日").font(.system(size: size == nil ? 18 : 11)).lineLimit(1)
                    if size == nil || size?.rows == 2 {
                        previewEvent(0, title: "14:00 项目同步")
                        previewEvent(1, title: "16:30 设计评审")
                    }
                    if size == nil {
                        Button("复制日期") { controller.feedback = "日期复制预览" }.buttonStyle(IslandButtonStyle())
                    }
                }
            } else {
                IslandLiveCalendarContent(controller: controller, selectedDate: $selectedDate, size: size)
            }
        }
    }

    private func previewEvent(_ index: Int, title: String) -> some View {
        Button {
            if controller.completedEvents.contains(index) { controller.completedEvents.remove(index) }
            else { controller.completedEvents.insert(index) }
        } label: {
            Label(title, systemImage: controller.completedEvents.contains(index) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
        }.buttonStyle(IslandButtonStyle())
    }
}

private struct IslandLiveCalendarContent: View {
    @ObservedObject var controller: IslandController
    @Binding var selectedDate: Date
    var size: IslandWidgetSize?
    @ObservedObject private var calendar = CalendarService.shared
    @Stored private var days: [CalendarDay] = []
    @Stored private var events: [CalendarEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if size == nil {
                HStack {
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    Text(CalendarService.monthTitle(selectedDate)).font(.system(size: 14, weight: .medium))
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    Spacer()
                    Button("今天") { selectedDate = Date.now; reload() }
                }.buttonStyle(IslandButtonStyle())
                HStack(alignment: .top, spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                        ForEach(days) { day in
                            Button { selectedDate = day.date; reloadEvents() } label: {
                                Text(day.date.formatted(.dateTime.day())).font(.system(size: 11))
                                    .frame(maxWidth: .infinity).frame(height: 22)
                                    .background(Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
                                                ? Theme.accent(for: nil).opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(IslandButtonStyle())
                        }
                    }.frame(maxWidth: .infinity)
                    ScrollView { eventList }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Button("复制所选日期") {
                    let value = selectedDate.formatted(.iso8601.year().month().day().dateSeparator(.dash))
                    controller.feedback = ClipboardManager.shared.copyText(value, successMessage: "已复制日期 " + value) ?? "已复制日期 " + value
                }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
            } else if size?.columns == 4 {
                HStack(spacing: 12) {
                    Text(Date.now.formatted(.dateTime.month().day())).font(.system(size: 11))
                    eventList
                }
            } else {
                Text(Date.now.formatted(.dateTime.month().day())).font(.system(size: 11))
                if size?.rows == 2 { eventList }
            }
        }
        .onAppear { reload() }
        .onChange(of: calendar.isAuthorized) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in reload() }
    }

    private var eventList: some View {
        Group {
            if let hint = calendar.authorizationHint {
                Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
            } else if events.isEmpty {
                Text(calendar.isAuthorized ? "暂无日程" : "日历尚未授权").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if size?.columns == 4 {
                HStack(spacing: 12) {
                    ForEach(Array(events.prefix(3))) { event in eventRow(event) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(events.prefix(size == nil ? events.count : 2))) { event in eventRow(event) }
                }
            }
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title).font(.system(size: 11)).lineLimit(size == nil ? nil : 1)
            Text(event.isAllDay ? "全天" : event.startDate.formatted(.dateTime.hour().minute()))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func moveMonth(_ step: Int) {
        if let date = Calendar.current.date(byAdding: .month, value: step, to: selectedDate) { selectedDate = date; reload() }
    }

    private func reload() {
        if size == nil { days = calendar.monthDays(for: selectedDate) }
        reloadEvents()
    }

    private func reloadEvents() {
        let start = Calendar.current.startOfDay(for: size == nil ? selectedDate : Date.now)
        if let end = Calendar.current.date(byAdding: .day, value: 1, to: start) {
            events = calendar.events(from: start, to: end)
        }
    }
}

