import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandRootView: View {
    @ObservedObject var controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Stored private var selectedRecord: String? = nil
    @Stored private var detailRecord: String? = nil
    @Stored private var recordsRevision = 0
    @Stored private var recordDragging = false
    @FocusState private var recordListFocused: Bool
    @Stored private var selectedMetric = IslandMetric.cpu
    @Stored private var selectedTool: String? = nil
    @Stored private var fileDialogOpen = false
    @Stored private var selectedDate = Date.now
    @Stored private var records: [IslandRecentRow] = []
    @Stored private var homeMonitorVisible = false

    private var preview: Bool { controller.previewOnly || isSettingsPreview }
    private var monitoringVisible: Bool {
        controller.expanded && (controller.page == .monitor || (controller.page == .home && homeMonitorVisible))
    }

    var body: some View {
        IslandSurface(controller: controller, height: controller.effectiveHeight) {
            if controller.expanded || preview || fileDialogOpen {
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
        .onChange(of: controller.expanded) { _ in
            reloadRecords()
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
        .task(id: recordsRevision) { await loadRecords() }
    }

    private func updateMonitoring() {
        if !preview { MonitorSampler.shared.setIslandActive(monitoringVisible) }
    }

    @ViewBuilder private func pageContent(_ page: IslandPage) -> some View {
        switch page {
        case .home: home
        case .clipboard: recordsPage
        case .monitor: IslandMonitorFullContent(controller: controller, previewOnly: preview, selectedMetric: $selectedMetric)
        case .media: IslandMediaContent(controller: controller, previewOnly: preview)
        case .calendar: IslandCalendarContent(controller: controller, selectedDate: $selectedDate, previewOnly: preview)
        case .tools:
            IslandToolboxContent(controller: controller, previewOnly: preview, selectedTool: $selectedTool,
                                 onFileDialog: { fileDialogOpen = $0 })
        case .search, .capture, .recording, .ocr, .transfer, .cast, .ai, .statistics, .archive, .downloads:
            IslandFeatureContent(page: page, controller: controller, previewOnly: preview, size: nil)
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
                recordEntrances
            } else if size.columns == 4 {
                HStack(spacing: 10) {
                    ForEach(Array(records.prefix(4))) { record in compactRecord(record) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(records.prefix(size.rows == 2 ? 3 : size.columns == 2 ? 2 : 1))) { record in
                        compactRecord(record)
                    }
                    Button {
                        if let record = records.first { copy(record) }
                    } label: { Label("复制最近内容", systemImage: "doc.on.doc") }
                        .font(.system(size: 11)).buttonStyle(IslandButtonStyle())
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
        case .search, .capture, .recording, .ocr, .transfer, .cast, .ai, .statistics, .archive, .downloads:
            IslandFeatureContent(page: item.page, controller: controller, previewOnly: preview, size: size)
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
            .dropDestination(for: URL.self) { urls, _ in item == .clipboard && receiveFiles(urls) }
    }

    private func compactRecord(_ record: IslandRecentRow) -> some View {
        HStack(spacing: 4) {
            Button { select(record, openPage: true) } label: {
                Label(record.title, systemImage: record.icon).font(.system(size: 11)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        if !preview, let url = record.url {
                            IslandFileDragSource(urls: [url], controller: controller,
                                onDraggingChanged: draggingChanged, onCopy: { copy(record) }) { select(record, openPage: true) }
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
            recordEntrances
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
                                                    IslandFileDragSource(urls: [url], controller: controller,
                                                        onDraggingChanged: draggingChanged,
                                                        onMove: { moveSelection($0, proxy: proxy) },
                                                        onCopy: copySelectedRecord) { select(record) }
                                                }
                                            }
                                    }.buttonStyle(IslandButtonStyle())
                                        .accessibilityAddTraits(selectedRecord == record.id ? .isSelected : [])
                                        .onHover { inside in
                                            if inside && !recordDragging { detailRecord = record.id }
                                        }
                                        .id(record.id)
                                }
                            }
                        }
                        .focusable()
                        .focused($recordListFocused)
                        .onMoveCommand { direction in
                            if direction == .up || direction == .down {
                                moveSelection(direction == .up ? -1 : 1, proxy: proxy)
                            }
                        }
                        .onCommand(#selector(NSText.copy(_:))) {
                            copySelectedRecord()
                        }
                    }.frame(width: geometry.size.width * 0.38)
                    Color.white.opacity(0.1).frame(width: Theme.Stroke.hairline)
                    if let record = records.first(where: { $0.id == (detailRecord ?? selectedRecord) }) {
                        IslandRecordDetail(record: record, controller: controller, previewOnly: preview,
                                           dragging: recordDragging, onDraggingChanged: draggingChanged)
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
        .dropDestination(for: URL.self) { urls, _ in receiveFiles(urls) }
    }

    private func receiveFiles(_ urls: [URL]) -> Bool {
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

    private func select(_ record: IslandRecentRow, openPage: Bool = false) {
        selectedRecord = record.id
        detailRecord = record.id
        if openPage { controller.page = .clipboard }
        recordListFocused = true
    }

    private func moveSelection(_ step: Int, proxy: ScrollViewProxy) {
        guard !records.isEmpty else { return }
        let index = records.firstIndex(where: { $0.id == selectedRecord }) ?? (step > 0 ? -1 : records.count)
        let next = min(max(index + step, 0), records.count - 1)
        select(records[next])
        proxy.scrollTo(records[next].id, anchor: .center)
    }

    private func copySelectedRecord() {
        if let record = records.first(where: { $0.id == selectedRecord }) { copy(record) }
    }

    private var recordEntrances: some View {
        HStack(spacing: 8) {
            Button("完整历史") {
                if preview { controller.feedback = "历史入口预览"; return }
                controller.performOutside { FloatingClipboardWindowController.shared.show() }
            }
            Button("本地中转") { controller.page = .transfer }
        }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
    }

    private func draggingChanged(_ dragging: Bool) {
        recordDragging = dragging
        if !dragging { reloadRecords() }
    }

    /// 独立近期查询，不改主剪贴板的搜索词、过滤条件或分页。
    private func reloadRecords() {
        recordsRevision += 1
    }

    @MainActor private func loadRecords() async {
        if recordDragging { return }
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
            let transfers = LocalTransferStore.shared.items
            let work = Task.detached(priority: .userInitiated) { () -> [IslandRecentRow] in
                if Task.isCancelled { return [] }
                let clipboard = ClipboardRepository.shared.fetch(ClipboardQuery())
                var joined: [String: IslandRecentRow] = [:]
                var aliases: [String: String] = [:]
                for transfer in transfers {
                    if Task.isCancelled { return [] }
                    let original = URL(fileURLWithPath: transfer.originalPath).standardizedFileURL.path
                    let staged = transfer.stagedURL.standardizedFileURL.path
                    let key = "file:" + original
                    aliases[original] = key
                    aliases[staged] = key
                    if joined[key] == nil {
                        joined[key] = IslandRecentRow(id: key, title: transfer.name, icon: Self.fileIcon(transfer.stagedURL),
                            date: Date(timeIntervalSince1970: transfer.addedAt), transfer: transfer, url: transfer.stagedURL)
                    }
                }
                for item in clipboard {
                    if Task.isCancelled { return [] }
                    if item.type == .file {
                        for path in (item.content ?? "").split(separator: "\n") {
                            let url = URL(fileURLWithPath: String(path)).standardizedFileURL
                            let key = aliases[url.path] ?? "file:" + url.path
                            if var row = joined[key] {
                                if row.clipboard == nil { row.clipboard = item }
                                row.date = max(row.date, item.timestamp)
                                joined[key] = row
                            } else {
                                joined[key] = IslandRecentRow(id: key, title: url.lastPathComponent, icon: Self.fileIcon(url),
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
                return joined.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
            }
            let joined = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, !recordDragging else { return }
            records = joined
        }
        if !records.contains(where: { $0.id == selectedRecord }) { selectedRecord = records.first?.id }
        if !records.contains(where: { $0.id == detailRecord }) { detailRecord = selectedRecord }
    }

    nonisolated private static func fileIcon(_ url: URL) -> String {
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        if directory.boolValue { return "folder" }
        if FilePreviewBuilder.imageExtensions.contains(url.pathExtension.lowercased()) { return "photo" }
        if ArchiveCore.isArchive(url) { return "archivebox" }
        if DocumentInlinePreview.supportedExtensions.contains(url.pathExtension.lowercased()) { return "doc.richtext" }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) { return "play.rectangle" }
        return FilePreviewBuilder.textExtensions.contains(url.pathExtension.lowercased()) ? "doc.text" : "doc"
    }

    private func copy(_ record: IslandRecentRow) {
        Task { controller.feedback = await record.copy(previewOnly: preview) ?? "已复制 " + record.title }
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

    var previewKey: String {
        [id, url?.path, clipboard?.id, clipboard?.dedupeKey, transfer?.id, title].compactMap { $0 }.joined(separator: "|")
    }

    /// 文件记录已按路径拆行，不能复制原剪贴板条目里未选中的其他文件。
    @MainActor func copy(previewOnly: Bool) async -> String? {
        if previewOnly { return "复制效果预览" }
        if clipboard?.type == .image, let item = clipboard {
            return ClipboardManager.shared.copy(item, autoPaste: false)
        }
        if let url { return ClipboardManager.shared.copyFiles([url], successMessage: "已复制 " + title) }
        guard let item = clipboard else { return "记录没有可复制的内容" }
        let result = await Task.detached(priority: .userInitiated) { () -> (String, String?) in
            var failure: String?
            let text = ClipboardManager.shared.fullText(for: item) { failure = $0 }
            return (text, failure)
        }.value
        if let failure = result.1 { return failure }
        if item.type == .richtext {
            let fullItem = ClipboardItem(id: item.id, type: item.type, content: result.0,
                richTextPath: item.richTextPath, dedupeKey: item.dedupeKey)
            return ClipboardManager.shared.copy(fullItem, autoPaste: false)
        }
        return ClipboardManager.shared.copyText(result.0, successMessage: "已复制 " + title)
    }

    var detail: String {
        if let sample { return sample.detail }
        let source = clipboard != nil && transfer != nil ? "剪贴板 · 中转" : transfer != nil ? "中转" : "剪贴板"
        let type = icon == "folder" ? "文件夹" : icon == "photo" ? "图片" : icon == "link" ? "链接"
            : icon == "curlybraces" ? "代码" : icon == "archivebox" ? "压缩包"
            : icon == "doc.richtext" ? "文档" : icon == "play.rectangle" ? "媒体" : url != nil ? "文件" : "文字"
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
    let dragging: Bool
    var onDraggingChanged: (Bool) -> Void
    @Stored private var displayed: (record: IslandRecentRow, model: PreviewPopoverContentModel,
                                   richText: NSAttributedString?, failure: String?)? = nil
    @Stored private var loading = false
    @Stored private var forceCode = false
    @Stored private var copyFailure: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let displayed {
                let current = displayed.record
                Text(current.detail).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Text(current.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    if loading { ProgressView().controlSize(.mini) }
                    if current.url == nil && displayed.model.kind != .image && displayed.model.kind != .richText {
                        Button { forceCode.toggle() } label: { Image(systemName: "curlybraces") }
                            .buttonStyle(IslandButtonStyle()).help(forceCode ? "自动识别格式" : "按代码查看")
                    }
                    Button {
                        Task {
                            let failure = await current.copy(previewOnly: previewOnly)
                            if self.displayed?.record.previewKey == current.previewKey { copyFailure = failure }
                            controller.feedback = failure ?? "已复制 " + current.title
                        }
                    } label: {
                        Label("复制", systemImage: "doc.on.doc").font(.system(size: 11))
                            .padding(.horizontal, 6).frame(height: 24)
                    }.buttonStyle(IslandButtonStyle()).accessibilityLabel("复制所选内容")
                }
                if let url = current.url {
                    Button {
                        if previewOnly { controller.feedback = "复制路径预览"; return }
                        controller.feedback = ClipboardManager.shared.copyText(current.transfer?.originalPath ?? url.path,
                            successMessage: "已复制路径") ?? "已复制路径"
                    } label: {
                        Text(current.transfer?.originalPath ?? url.path).font(.system(size: 10))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(IslandButtonStyle()).help("点击复制完整路径")
                    if !previewOnly {
                        Label("拖出到 Finder 或其他 App", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11)).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(IslandLayout.cardFill, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                IslandFileDragSource(urls: [url], controller: controller,
                                                     onDraggingChanged: onDraggingChanged) {}
                            }
                            .accessibilityLabel("拖出 " + current.title)
                    }
                } else if current.icon == "link" {
                    let text = displayed.model.inlineText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: text.lowercased().hasPrefix("www.") ? "https://" + text : text) {
                        Button("打开链接") {
                            if previewOnly { controller.feedback = "打开链接预览"; return }
                            NSWorkspace.shared.open(url)
                        }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
                    }
                }
                if let error = copyFailure ?? displayed.failure {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                }
                previewContent(displayed.model, richText: displayed.richText)
                    .environment(\.isSettingsPreview, previewOnly)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在读取").font(.system(size: 11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: record.previewKey + String(previewOnly) + String(dragging)) {
            if !dragging { await load() }
        }
    }

    @ViewBuilder private func previewContent(_ model: PreviewPopoverContentModel,
                                            richText: NSAttributedString?) -> some View {
        if let richText {
            AttributedTextView(richText)
        } else if !previewOnly, let url = model.fileURL,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audiovisualContent) {
            DocumentInlinePreview(url: url).id(model.id)
        } else if !previewOnly, let url = model.fileURL, model.fileIsDirectory || ArchiveCore.isArchive(url) {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    PreviewFileView(model: model, showsQuickLook: false)
                        .id(model.id)
                        .frame(width: max(geometry.size.width, 520), height: max(geometry.size.height, 360))
                }
            }
        } else {
            PreviewPopoverContentView(model: model, forceCode: forceCode, usesWindowChrome: false)
                .id(model.id)
        }
    }

    @MainActor private func load() async {
        if displayed?.record.previewKey == record.previewKey { loading = false; return }
        loading = true
        let current = record
        let sample = previewOnly
        let work = Task.detached(priority: .userInitiated) { () throws -> (PreviewPopoverContentModel, NSAttributedString?, String?) in
            try Task.checkCancellation()
            let item: ClipboardItem
            if sample {
                let type: ClipboardItemType = current.icon == "photo" ? .image
                    : current.icon == "folder" || current.icon == "archivebox" ? .file : .text
                item = ClipboardItem(id: current.id, type: type, content: current.sample?.body,
                                     dedupeKey: current.id, fileCategories: 0)
            } else if let url = current.url, current.clipboard?.type != .image {
                item = ClipboardItem(id: current.id, type: .file, content: url.path, title: current.title,
                                     timestamp: current.date, dedupeKey: current.previewKey)
            } else {
                item = current.clipboard!
            }
            var failure: String?
            let text = sample || item.type == .file || item.type == .image ? item.content ?? ""
                : ClipboardManager.shared.fullText(for: item) { failure = $0 }
            try Task.checkCancellation()
            // 全文已就绪，不再让落盘长文视图读取第二遍。
            let richText = item.type == .richtext ? PreviewPopoverDataBridge.shared.richTextAttributed(for: item) : nil
            let kind: PreviewPopoverContentModel.Kind? = sample && item.type == .file ? .file
                : richText != nil ? .richText
                : item.type == .text || item.type == .url || item.type == .richtext
                    ? PreviewPopoverContentModel.classifyRawText(text) : nil
            let model = PreviewPopoverContentModel(item: item, source: .floatingPreview,
                sessionID: UUID(), inlineText: text, kindOverride: kind,
                displayPath: current.transfer?.originalPath, loadFileContents: !sample)
            try Task.checkCancellation()
            return (model, richText, failure)
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            if !sample, result.0.kind == .image, let path = result.0.item.imagePath {
                let url = ClipboardFileStore.url(forRelativePath: path)
                let thumbnail = result.0.item.thumbnailPath.map(ClipboardFileStore.url(forRelativePath:))
                // 正式图片视图命中同一加载器缓存，切换时不先露出空白占位。
                for full in [false, true] {
                    guard !Task.isCancelled else { return }
                    _ = await withCheckedContinuation { continuation in
                        PreviewImageLoader.shared.loadImage(at: url, thumbnailURL: thumbnail,
                            needsFullRebuild: full) { continuation.resume(returning: $0) }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            displayed = (current, result.0, result.1, result.2)
            forceCode = false; copyFailure = nil; loading = false
        } catch {
            if !Task.isCancelled { copyFailure = error.localizedDescription; loading = false }
        }
    }
}

/// NSURL 原生拖动会话不触碰系统剪贴板，也不创建文件副本。
private struct IslandFileDragSource: NSViewRepresentable {
    let urls: [URL]
    let controller: IslandController
    var onDraggingChanged: (Bool) -> Void
    var onMove: ((Int) -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var select: () -> Void

    func makeNSView(context: Context) -> IslandFileDragView { IslandFileDragView() }
    func updateNSView(_ view: IslandFileDragView, context: Context) {
        view.urls = urls; view.controller = controller; view.select = select
        view.onDraggingChanged = onDraggingChanged
        view.onMove = onMove; view.onCopy = onCopy
    }
}

private final class IslandFileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    weak var controller: IslandController?
    var select: (() -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?
    var onMove: ((Int) -> Void)?
    var onCopy: (() -> Void)?
    private var mouseStart: NSPoint? = nil
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseStart = event.locationInWindow
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let onCopy {
            onCopy(); return
        }
        if (event.keyCode == 125 || event.keyCode == 126), let onMove {
            onMove(event.keyCode == 125 ? 1 : -1); return
        }
        if event.keyCode == 36 || event.keyCode == 49 { select?(); return }
        super.keyDown(with: event)
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
        onDraggingChanged?(true)
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
        onDraggingChanged?(false)
        controller?.feedback = operation.isEmpty ? "拖出已取消" : "拖出已结束"
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
                    previewEvent(0, title: "14:00 项目同步")
                    if size == nil || size?.rows == 2 {
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
    @AppStorage(Preferences.Keys.calendarFirstWeekday) private var firstWeekday = 1
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
                        ForEach(0..<7) { index in
                            let weekday = (index + firstWeekday - 1) % 7
                            Text(["日", "一", "二", "三", "四", "五", "六"][weekday])
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(weekday == 0 || weekday == 6 ? .secondary : .primary)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(days) { day in
                            Button {
                                let monthChanged = !Calendar.current.isDate(day.date, equalTo: selectedDate, toGranularity: .month)
                                selectedDate = day.date
                                if monthChanged { reload() } else { reloadEvents() }
                            } label: {
                                VStack(spacing: 2) {
                                    Text(day.date.formatted(.dateTime.day())).font(.system(size: 11, weight: day.isToday ? .bold : .regular))
                                    Text(day.holidayText ?? day.lunarText ?? "")
                                        .font(.system(size: 9)).lineLimit(1).foregroundStyle(.secondary)
                                }
                                    .foregroundStyle(day.isWeekend || !Calendar.current.isDate(day.date, equalTo: selectedDate, toGranularity: .month) ? .secondary : .primary)
                                    .frame(maxWidth: .infinity).frame(height: 33)
                                    .background(Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
                                                ? controller.configuration.color(for: .calendar).opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
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
        .onChange(of: firstWeekday) { _ in reload() }
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
        if size == nil { days = calendar.monthDays(for: selectedDate, firstWeekday: firstWeekday) }
        reloadEvents()
    }

    private func reloadEvents() {
        if size == nil, let day = days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }) {
            events = day.events
            return
        }
        let start = Calendar.current.startOfDay(for: size == nil ? selectedDate : Date.now)
        if let end = Calendar.current.date(byAdding: .day, value: 1, to: start) {
            events = calendar.events(from: start, to: end)
        }
    }
}

