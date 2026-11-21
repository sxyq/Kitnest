import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

struct IslandRootView: View {
    @ObservedObject var controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Stored private var transferToolsVisible = false
    @Stored private var recordsRevision = 0
    @Stored private var recordsNeedReload = true
    @Stored private var recordDragging = false
    @FocusState private var recordListFocused: Bool
    @Stored private var fileDialogOpen = false
    @Stored private var records: [IslandRecentRow] = []
    @Stored private var homeMonitorVisible = false
    @Stored private var isManagingTags = false

    private var preview: Bool { controller.previewOnly || isSettingsPreview }
    private var selectedRecord: String? { controller.selectedRecord }
    private var recentRecordsVisible: Bool {
        let pageShowsRecords = controller.page == .home || controller.page == .custom || controller.page == .clipboard
            || (controller.page == .transfer && !transferToolsVisible)
        return pageShowsRecords && (preview || controller.expanded)
    }
    private var monitoringVisible: Bool {
        controller.contentVisible && (controller.page == .monitor
            || ((controller.page == .home || controller.page == .custom) && homeMonitorVisible))
    }
    private var pageRecords: [IslandRecentRow] {
        guard controller.page == .clipboard else { return records }
        return Array(records.filter { record in
            (!controller.showingClipboardFavoritesOnly || record.clipboard?.isFavorite == true)
                && (controller.clipboardTagID.map { record.clipboard?.tagIDs.contains($0) == true } ?? true)
        }
            .prefix(max(1, controller.configuration.clipboardRecentLimit)))
    }

    var body: some View {
        IslandSurface(controller: controller, height: controller.effectiveHeight) {
            if controller.contentVisible || fileDialogOpen {
                pageContent(controller.page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .islandGlowClip()
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.page)
        .onAppear {
            updateMonitoring()
        }
        .onChange(of: controller.expanded) { _ in
            reloadRecords()
            updateMonitoring()
        }
        .onChange(of: controller.showingContent) { visible in
            updateMonitoring()
            if !visible { controller.releaseRecordScroll() }
        }
        .onChange(of: controller.page) { _ in controller.releaseRecordScroll(); reloadRecords(dataChanged: true); updateMonitoring() }
        .onChange(of: [controller.configuration.clipboardRecentLimit,
                       controller.showingClipboardFavoritesOnly ? 1 : 0]) { _ in reloadRecords(dataChanged: true) }
        .onChange(of: controller.clipboardTagID) { _ in reloadRecords(dataChanged: true) }
        .onChange(of: transferToolsVisible) { _ in
            controller.releaseRecordScroll()
            reloadRecords()
            if let panel = controller.panel, MainPanelPreviewPopoverCoordinator.shared.hasPreview(from: panel) {
                MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .programmatic)
            }
        }
        .onChange(of: homeMonitorVisible) { _ in updateMonitoring() }
        .onChange(of: preview) { _ in reloadRecords(dataChanged: true); updateMonitoring() }
        .onDisappear {
            controller.releaseRecordScroll()
            if !preview { MonitorSampler.shared.setIslandActive(false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardManager.itemsDidChangeNotification)) { _ in
            if !preview { reloadRecords(dataChanged: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: TagStore.didChangeNotification)) { note in
            if !preview { applyTagChange(note) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .localTransferDidChange)) { _ in
            if !preview { reloadRecords(dataChanged: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: TagStore.manageRequestedNotification)) { note in
            if !preview, note.object as? String == "island" { isManagingTags = true }
        }
        .sheet(isPresented: $isManagingTags) { TagManagementSheet() }
        .task(id: recordsRevision) { await loadRecords() }
    }

    private func updateMonitoring() {
        if !preview { MonitorSampler.shared.setIslandActive(monitoringVisible) }
    }

    private func applyTagChange(_ note: Notification) {
        guard let info = note.userInfo else { reloadRecords(dataChanged: true); return }
        if info["mappingReplaced"] as? Bool == true { reloadRecords(dataChanged: true); return }
        let tagID = info["tagID"] as? String
        if info["removed"] as? Bool == true, controller.clipboardTagID == tagID {
            controller.clipboardTagID = nil
        }
        let keys = Set(info["keys"] as? [String] ?? [])
        guard !keys.isEmpty else { return }
        if controller.page == .clipboard, controller.clipboardTagID == tagID {
            reloadRecords(dataChanged: true)
            return
        }
        records = records.map { row in
            guard var item = row.clipboard, keys.contains(item.dedupeKey) else { return row }
            item.tagIDs = TagStore.shared.tagIDs(forDedupeKey: item.dedupeKey)
            var updated = row
            updated.clipboard = item
            return updated
        }
    }

    @ViewBuilder private func pageContent(_ page: IslandPage) -> some View {
        switch page {
        case .home: home
        case .clipboard: recordsPage
        case .custom: custom
        case .transfer:
            VStack(spacing: 8) {
                Picker("中转站与传输", selection: $transferToolsVisible) {
                    Text("中转站").tag(false)
                    Text("文件传输").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                if transferToolsVisible {
                    IslandFeatureContent(page: .transfer, controller: controller, previewOnly: preview)
                } else { recordsPage }
            }
        case .monitor: IslandMonitorFullContent(controller: controller, previewOnly: preview)
        case .media: IslandMediaContent(controller: controller, previewOnly: preview)
        case .calendar: IslandCalendarContent(controller: controller, selectedDate: $controller.selectedDate, previewOnly: preview)
        case .tools:
            IslandToolboxContent(controller: controller, previewOnly: preview, selectedTool: $controller.selectedTool,
                                 onFileDialog: { fileDialogOpen = $0 })
        case .search, .capture, .recording, .ocr, .cast, .ai, .statistics, .archive, .downloads:
            IslandFeatureContent(page: page, controller: controller, previewOnly: preview, size: nil)
        }
    }

    private var home: some View {
        IslandWidgetGrid(controller: controller) { (item: IslandWidget, size: IslandWidgetSize) in
            widget(item, size: size) { widgetContent(item, size: size) }
        }
        .overlay {
            if controller.page == .custom && controller.configuration.customWidgetOrder.isEmpty {
                VStack(spacing: 8) {
                    Text("我的空间还没有组件")
                    Button("在设置中添加组件") {
                        if preview { controller.beginLayoutEditing() }
                        else { controller.performOutside { ServiceLocator.settings?.open(pane: "island.canvas") } }
                    }.buttonStyle(IslandButtonStyle())
                }
            } else if controller.page == .home && controller.configuration.hiddenWidgets.count == IslandWidget.allCases.count {
                VStack(spacing: 8) {
                    Text("首页组件已全部隐藏").font(.system(size: 13))
                    Button("查看全部功能") { controller.page = .tools }.buttonStyle(IslandButtonStyle())
                }
            }
        }
    }

    private var custom: some View { home }

    @ViewBuilder private func widgetContent(_ item: IslandWidget, size: IslandWidgetSize) -> some View {
        switch item {
        case .monitor:
            IslandMonitorChart(metric: controller.selectedMetric, previewOnly: preview,
                               tint: controller.configuration.color(for: item), size: size, controller: controller)
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
            IslandCalendarContent(controller: controller, selectedDate: $controller.selectedDate, previewOnly: preview, size: size)
        case .tools:
            IslandToolboxShortcuts(controller: controller, previewOnly: preview, size: size, selectedTool: $controller.selectedTool)
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
            .glassCard(radius: IslandLayout.cardRadius, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
            .dropDestination(for: URL.self) { urls, _ in item == .clipboard && receiveFiles(urls) }
    }

    private func compactRecord(_ record: IslandRecentRow) -> some View {
        HStack(spacing: 4) {
            Button { select(record, openPage: true) } label: {
                Label(record.title, systemImage: record.icon).font(.system(size: 11)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        IslandFileDragSource(urls: preview ? [] : record.url.map { [$0] } ?? [], controller: controller,
                            onDraggingChanged: draggingChanged, onCopy: { copy(record) },
                            onDoubleClick: { select(record); copy(record) }, defersSelection: true) {
                                select(record, openPage: true)
                            }
                    }
            }.buttonStyle(IslandButtonStyle(showsFocus: false)).accessibilityLabel(record.title).help("单击预览 · 双击复制")
                .accessibilityAddTraits(record.id == selectedRecord ? .isSelected : [])
                .contextMenu {
                    if let item = record.clipboard {
                        ClipboardRowMenuContent(item: item, managementSource: "island",
                            onPreview: { select(record) },
                            onPaste: { ClipboardManager.shared.copy(item, autoPaste: true) })
                    }
                }
            if let item = record.clipboard, !preview {
                Button { ClipboardManager.shared.toggleFavorite(item) } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? Theme.accent : Color.secondary)
                }.buttonStyle(.plain).help(item.isFavorite ? "取消收藏" : "收藏")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordsPage: some View {
        let visibleRecords = pageRecords
        return VStack(spacing: 8) {
            HStack {
                Text(controller.page == .transfer ? "中转站" : "剪贴板与中转").fontWeight(.medium)
                Spacer()
                Text(preview ? "设置预览" : "\(visibleRecords.count) 项近期内容 · 可拖入文件")
                    .foregroundStyle(.secondary)
            }.font(.system(size: 11))
            if controller.page != .transfer {
                HStack(spacing: 8) {
                    recordEntrances
                    if controller.page == .clipboard {
                        Button {
                            controller.showingClipboardFavoritesOnly.toggle()
                        } label: {
                            Label(controller.showingClipboardFavoritesOnly ? "收藏中" : "全部",
                                  systemImage: controller.showingClipboardFavoritesOnly ? "star.fill" : "star")
                        }.buttonStyle(IslandButtonStyle())
                        Picker("按标签筛选", selection: $controller.clipboardTagID) {
                            Text("全部标签").tag(String?.none)
                            ForEach(TagStore.shared.tags) { tag in Text(tag.name).tag(Optional(tag.id)) }
                        }.labelsHidden().frame(maxWidth: 135)
                        Button("管理标签") { NotificationCenter.default.post(name: TagStore.manageRequestedNotification, object: "island") }
                            .buttonStyle(IslandButtonStyle())
                    }
                }
            }
            HStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleRecords) { record in
                            HStack(spacing: 6) {
                            Button { select(record) } label: {
                                record.frame(maxWidth: .infinity, alignment: .leading)
                                    .background {
                                        RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous)
                                            .fill(record.id == selectedRecord
                                                  ? Theme.accent(for: nil).opacity(0.12) : Color.clear)
                                    }
                                    .overlay {
                                        IslandFileDragSource(urls: preview ? [] : record.url.map { [$0] } ?? [], controller: controller,
                                            onDraggingChanged: draggingChanged,
                                            onMove: { moveSelection($0, proxy: proxy) }, onCopy: copySelectedRecord,
                                            onDoubleClick: { select(record); copy(record) },
                                            tracksScroll: record.id == visibleRecords.first?.id) { select(record) }
                                    }
                            }.buttonStyle(IslandButtonStyle(showsFocus: false))
                                .help("点击或空格在右侧预览 · 双击复制 · 文件可拖出")
                                .accessibilityAddTraits(selectedRecord == record.id ? .isSelected : [])
                                .contextMenu {
                                    if let item = record.clipboard {
                                        ClipboardRowMenuContent(item: item, managementSource: "island",
                                            onPreview: { select(record) },
                                            onPaste: { ClipboardManager.shared.copy(item, autoPaste: true) })
                                    }
                                }
                            }
                                .id(record.id)
                        }
                    }
                }
                .islandGlowClip()
                .focusable()
                .focused($recordListFocused)
                .modifier(IslandRecordFocusAppearance())
                .onMoveCommand { direction in
                    if direction == .up || direction == .down {
                        moveSelection(direction == .up ? -1 : 1, proxy: proxy)
                    }
                }
                .onCommand(#selector(NSText.copy(_:))) {
                    copySelectedRecord()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let record = visibleRecords.first(where: { $0.id == selectedRecord }) {
                Group {
                    if preview { sampleDetail(record) }
                    else {
                        IslandRecordPreview(item: record.previewItem, sessionID: controller.previewSessionID)
                            .id(record.previewKey)
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .glassCard(radius: IslandLayout.cardRadius, fill: IslandLayout.cardFill, stroke: IslandLayout.cardStroke)
            }
            }
            if visibleRecords.isEmpty {
                Text(controller.showingClipboardFavoritesOnly && controller.page == .clipboard
                     ? "暂无收藏" : "暂无内容，可拖入文件或文件夹")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        return true
    }

    private func sampleDetail(_ record: IslandRecentRow) -> some View {
        let sample = record.sample!
        let kind: PreviewPopoverContentModel.Kind = sample.icon == "photo" ? .image
            : sample.children.isEmpty ? PreviewPopoverContentModel.classifyRawText(sample.body) : .file
        let paths = sample.children.map { "/演示/\(sample.title)/\($0)" }.joined(separator: "\n")
        let item = ClipboardItem(id: record.id, type: sample.children.isEmpty ? record.previewItem.type : .file,
                                 content: sample.children.isEmpty ? sample.body : paths,
                                 title: sample.title, timestamp: record.date, dedupeKey: record.id)
        let model = PreviewPopoverContentModel(item: item, source: .mainPreview, sessionID: controller.previewSessionID,
            inlineText: sample.body, kindOverride: kind, loadFileContents: false)
        return VStack(spacing: 4) {
            HStack {
                Text(sample.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button("复制") { copy(record) }.buttonStyle(IslandButtonStyle())
            }.padding(8)
            PreviewPopoverContentView(model: model, usesWindowChrome: false)
                .id(record.id)
        }
    }

    private func select(_ record: IslandRecentRow, openPage: Bool = false) {
        controller.selectedRecord = record.id
        if openPage { controller.selectPage(.clipboard) }
        recordListFocused = true
    }

    private func moveSelection(_ step: Int, proxy: ScrollViewProxy) {
        let records = pageRecords
        guard !records.isEmpty else { return }
        let index = records.firstIndex(where: { $0.id == selectedRecord }) ?? (step > 0 ? -1 : records.count)
        let next = min(max(index + step, 0), records.count - 1)
        select(records[next])
        proxy.scrollTo(records[next].id, anchor: .center)
    }

    private func copySelectedRecord() {
        let records = pageRecords
        let coordinator = MainPanelPreviewPopoverCoordinator.shared
        let active = controller.panel.flatMap { coordinator.hasPreview(from: $0) ? coordinator.activeItemID : nil }
        if let record = records.first(where: { $0.previewItem.id == active })
            ?? records.first(where: { $0.id == selectedRecord }) { copy(record) }
    }

    private var recordEntrances: some View {
        HStack(spacing: 8) {
            Button("完整历史") {
                if preview { controller.feedback = "历史入口预览"; return }
                controller.performOutside { FloatingClipboardWindowController.shared.show() }
            }
            Button("中转站与传输") { controller.page = .transfer }
        }.font(.system(size: 11)).buttonStyle(IslandButtonStyle())
    }

    private func draggingChanged(_ dragging: Bool) {
        recordDragging = dragging
        if !dragging { reloadRecords() }
    }

    /// 独立近期查询，不改主剪贴板的搜索词、过滤条件或分页。
    private func reloadRecords(dataChanged: Bool = false) {
        if dataChanged { recordsNeedReload = true }
        guard recordsNeedReload, !recordDragging, recentRecordsVisible else { return }
        recordsRevision += 1
    }

    @MainActor private func loadRecords() async {
        let revision = recordsRevision
        guard recordsNeedReload, !recordDragging, recentRecordsVisible else { return }
        let updatedRecords: [IslandRecentRow]
        if preview {
            var samples = IslandSample.clipboard
            samples.append(contentsOf: IslandSample.files.filter { file in
                !samples.contains { $0.title == file.title && $0.icon == file.icon }
            })
            updatedRecords = samples.enumerated().map { index, sample in
                IslandRecentRow(id: "sample:\(index)", title: sample.title, icon: sample.icon,
                                date: SettingsPreviewSamples.date.addingTimeInterval(Double(index) * -120), sample: sample)
            }
        } else {
            let hasClipboardFilter = controller.page == .clipboard
                && (controller.showingClipboardFavoritesOnly || controller.clipboardTagID != nil)
            let transfers = hasClipboardFilter ? [] : LocalTransferStore.shared.items
            let query = ClipboardQuery(filter: controller.page == .clipboard && controller.showingClipboardFavoritesOnly
                ? .favorite : .all, search: "", tagID: controller.page == .clipboard ? controller.clipboardTagID : nil,
                limit: controller.page == .clipboard ? max(1, controller.configuration.clipboardRecentLimit) : ClipboardRepository.defaultPageSize)
            let work = Task.detached(priority: .userInitiated) { () -> [IslandRecentRow] in
                if Task.isCancelled { return [] }
                let clipboard = ClipboardRepository.shared.fetch(query)
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
            updatedRecords = joined
        }
        guard !Task.isCancelled, recordsRevision == revision, !recordDragging else { return }
        records = updatedRecords
        recordsNeedReload = false
        let visibleRecords = pageRecords
        if !visibleRecords.contains(where: { $0.id == selectedRecord }) {
            controller.selectedRecord = visibleRecords.first?.id
        }
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

private struct IslandRecordPreview: View {
    let item: ClipboardItem
    let sessionID: UUID
    @Stored private var model: PreviewPopoverContentModel?

    var body: some View {
        ZStack {
            if let model { PreviewPopoverContentView(model: model, usesWindowChrome: false, showsTOC: false) }
            else { ProgressView().controlSize(.small) }
        }
        .task {
            let loaded = await Task.detached(priority: .userInitiated) { [item, sessionID] in
                PreviewPopoverContentModel(item: item, source: .mainPreview, sessionID: sessionID,
                    inlineText: PreviewPopoverDataBridge.shared.fullText(for: item), fullTextLoaded: true)
            }.value
            guard !Task.isCancelled else { return }
            model = loaded
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

    var previewKey: String {
        [id, url?.path, clipboard?.id, clipboard?.dedupeKey, transfer?.id, title].compactMap { $0 }.joined(separator: "|")
    }

    var previewItem: ClipboardItem {
        if let url, clipboard?.type != .image {
            return ClipboardItem(id: id, type: .file, content: url.path, title: title,
                                 subtitle: transfer?.originalPath, timestamp: date,
                                 sourceApp: transfer != nil ? "中转站" : clipboard?.sourceApp,
                                 dedupeKey: previewKey, fileCategories: clipboard?.fileCategories ?? 0)
        }
        let type: ClipboardItemType = icon == "photo" ? .image : icon == "link" ? .url
            : icon == "folder" || icon == "archivebox" || icon == "doc.text" ? .file : .text
        return clipboard ?? ClipboardItem(id: id, type: type, content: type == .file ? title : sample?.body,
                                          title: title, subtitle: sample?.detail, timestamp: date, dedupeKey: id,
                                          fileCategories: 0)
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


    var body: some View {
        ClipboardRow(item: previewItem, isHighlighted: false, onCopy: {}, onEdit: {}, onSummarize: {})
    }
}

/// 只取消记录列表的系统焦点装饰，保留方向键与复制命令。
private struct IslandRecordFocusAppearance: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// 记录单击、双击与文件拖出共用原生事件；拖动会话不触碰系统剪贴板。
private struct IslandFileDragSource: NSViewRepresentable {
    let urls: [URL]
    let controller: IslandController
    var onDraggingChanged: (Bool) -> Void
    var onMove: ((Int) -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var defersSelection = false
    var tracksScroll = false
    var select: () -> Void

    func makeNSView(context: Context) -> IslandFileDragView {
        let view = IslandFileDragView()
        view.focusRingType = .none
        return view
    }
    func updateNSView(_ view: IslandFileDragView, context: Context) {
        view.urls = urls; view.controller = controller; view.select = select
        view.onDraggingChanged = onDraggingChanged
        view.onMove = onMove; view.onCopy = onCopy
        view.onDoubleClick = onDoubleClick; view.defersSelection = defersSelection
        view.tracksScroll = tracksScroll
        if controller.editingLayout { view.cancelSelection() }
    }
}

final class IslandFileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    weak var controller: IslandController?
    var select: (() -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?
    var onMove: ((Int) -> Void)?
    var onCopy: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var defersSelection = false
    var tracksScroll = false
    private var selectionWork: DispatchWorkItem?
    private var mouseStart: NSPoint? = nil
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if tracksScroll, window != nil {
            DispatchQueue.main.async { [weak self] in
                if let self, let scrollView = self.enclosingScrollView { self.controller?.bindRecordScroll(scrollView) }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        controller?.editingLayout == true ? nil : super.hitTest(point)
    }

    func cancelSelection() {
        selectionWork?.cancel(); selectionWork = nil
        mouseStart = nil
    }

    override func mouseDown(with event: NSEvent) {
        selectionWork?.cancel(); selectionWork = nil
        mouseStart = event.locationInWindow
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.editingLayout == true { super.keyDown(with: event); return }
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
        guard !urls.isEmpty, !dragging, let start = mouseStart,
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
        if !dragging, mouseStart != nil {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
            } else if defersSelection {
                // 首页单击会换页；等待系统双击间隔，避免第一击提前移走目标。
                let work = DispatchWorkItem { [weak self] in self?.select?() }
                selectionWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            } else { select?() }
        }
        mouseStart = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { selectionWork?.cancel(); selectionWork = nil }
        super.viewWillMove(toWindow: newWindow)
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
    @AppStorage(Preferences.Keys.calendarFirstWeekday) private var firstWeekday = 1
    @Stored private var sampleDays: [CalendarDay] = []

    private var previewCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = firstWeekday
        calendar.timeZone = .current
        return calendar
    }

    private var previewEvents: [CalendarEvent] {
        let calendar = previewCalendar
        let base = calendar.startOfDay(for: SettingsPreviewSamples.date)
        func event(_ id: String, _ title: String, _ offset: Int, _ hour: Int, _ minute: Int) -> CalendarEvent {
            let day = calendar.date(byAdding: .day, value: offset, to: base)!
            let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            return CalendarEvent(id: id, title: title, startDate: start)
        }
        return [
            event("island-preview-sync", "项目同步", 0, 14, 0),
            event("island-preview-review", "设计评审", 0, 16, 30),
            event("island-preview-plan", "交付计划", 3, 10, 0),
            event("island-preview-review-two", "需求梳理", 8, 15, 0)
        ]
    }

    private var previewDays: [CalendarDay] {
        let calendar = previewCalendar
        let components = calendar.dateComponents([.year, .month], from: selectedDate)
        guard let firstOfMonth = calendar.date(from: components) else { return [] }
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let offset = (weekday - firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -offset, to: firstOfMonth) else { return [] }
        let eventsByDay = Dictionary(grouping: previewEvents) { calendar.startOfDay(for: $0.startDate) }
        return (0..<42).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else { return nil }
            let dayStart = calendar.startOfDay(for: date)
            let weekday = calendar.component(.weekday, from: date)
            return CalendarDay(date: date,
                              isToday: calendar.isDate(date, inSameDayAs: SettingsPreviewSamples.date),
                              isWeekend: weekday == 1 || weekday == 7,
                              events: eventsByDay[dayStart] ?? [])
        }
    }

    var body: some View {
        Group {
            if previewOnly {
                let days = sampleDays
                IslandLiveCalendarContent.calendarLayout(
                    controller: controller, selectedDate: selectedDate, size: size,
                    firstWeekday: firstWeekday, calendar: previewCalendar, days: days,
                    events: days.first(where: { previewCalendar.isDate($0.date, inSameDayAs: selectedDate) })?.events ?? [],
                    isAuthorized: true, authorizationHint: nil,
                    onSelectDate: { selectedDate = $0 },
                    onMoveDay: { movePreviewDate(.day, by: $0) },
                    onMoveMonth: { movePreviewDate(.month, by: $0) },
                    onToday: { selectedDate = SettingsPreviewSamples.date },
                    onCopyDate: copySelectedDate
                )
            } else {
                IslandLiveCalendarContent(controller: controller, selectedDate: $selectedDate,
                                          size: size, firstWeekday: firstWeekday,
                                          onCopyDate: copySelectedDate)
            }
        }
        .onAppear { if previewOnly { sampleDays = previewDays } }
        .onChange(of: firstWeekday) { _ in if previewOnly { sampleDays = previewDays } }
        .onChange(of: selectedDate) { date in
            if previewOnly, let anchor = sampleDays.dropFirst(14).first,
               !previewCalendar.isDate(anchor.date, equalTo: date, toGranularity: .month) {
                sampleDays = previewDays
            }
        }
    }

    private func movePreviewDate(_ component: Calendar.Component, by value: Int) {
        if let date = previewCalendar.date(byAdding: component, value: value, to: selectedDate) {
            selectedDate = date
        }
    }

    private func copySelectedDate() {
        let value = selectedDate.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        if previewOnly {
            controller.feedback = "日期复制预览"
        } else {
            controller.feedback = ClipboardManager.shared.copyText(value, successMessage: "已复制日期 " + value)
                ?? "已复制日期 " + value
        }
    }
}

private struct IslandLiveCalendarContent: View {
    @ObservedObject var controller: IslandController
    @Binding var selectedDate: Date
    var size: IslandWidgetSize?
    let firstWeekday: Int
    let onCopyDate: () -> Void
    @ObservedObject private var calendar = CalendarService.shared
    @Stored private var days: [CalendarDay] = []
    @Stored private var events: [CalendarEvent] = []

    private var usesMonthGrid: Bool { size == nil || size == .square }

    var body: some View {
        Self.calendarLayout(
            controller: controller, selectedDate: selectedDate, size: size,
            firstWeekday: firstWeekday, calendar: CalendarService.calendar(firstWeekday: firstWeekday),
            days: days, events: events,
            isAuthorized: calendar.isAuthorized, authorizationHint: calendar.authorizationHint,
            onSelectDate: selectDate,
            onMoveDay: { moveDate(.day, by: $0) },
            onMoveMonth: { moveDate(.month, by: $0) },
            onToday: { selectedDate = Date.now; reload() },
            onCopyDate: onCopyDate
        )
        .onAppear { reload() }
        .onChange(of: size) { _ in reload() }
        .onChange(of: firstWeekday) { _ in reload() }
        .onChange(of: calendar.isAuthorized) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in reload() }
    }

    fileprivate static func calendarLayout(
        controller: IslandController, selectedDate: Date, size: IslandWidgetSize?,
        firstWeekday: Int, calendar: Calendar, days: [CalendarDay], events: [CalendarEvent],
        isAuthorized: Bool, authorizationHint: String?,
        onSelectDate: @escaping (Date) -> Void,
        onMoveDay: @escaping (Int) -> Void,
        onMoveMonth: @escaping (Int) -> Void,
        onToday: @escaping () -> Void,
        onCopyDate: @escaping () -> Void
    ) -> some View {
        let accent = controller.configuration.color(for: .calendar)
        return Group {
            if size == nil {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button { onMoveMonth(-1) } label: { Image(systemName: "chevron.left") }
                        Text(monthTitle(selectedDate)).font(.system(size: 14, weight: .medium))
                        Button { onMoveMonth(1) } label: { Image(systemName: "chevron.right") }
                        Spacer()
                        Button("今天", action: onToday)
                    }.buttonStyle(IslandButtonStyle())
                    HStack(alignment: .top, spacing: 12) {
                        monthGrid(days: days, selectedDate: selectedDate, calendar: calendar,
                                  firstWeekday: firstWeekday, accent: accent, compact: false,
                                  onSelectDate: onSelectDate)
                            .frame(maxWidth: .infinity)
                        ScrollView {
                            eventRows(events, isAuthorized: isAuthorized,
                                      authorizationHint: authorizationHint, limit: nil, compact: false)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    HStack {
                        Text(fullDate(selectedDate)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("复制所选日期", action: onCopyDate)
                            .font(.system(size: 11)).buttonStyle(IslandButtonStyle())
                    }
                }
            } else if size == .small {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monthDay(selectedDate)).font(.system(size: 17, weight: .semibold))
                        Text(weekdayTitle(selectedDate)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    HStack(spacing: 2) {
                        Button { onMoveDay(-1) } label: { Image(systemName: "chevron.left") }
                            .help("前一天")
                        Button(action: onCopyDate) { Image(systemName: "doc.on.doc") }
                            .help("复制日期")
                        Button { onMoveDay(1) } label: { Image(systemName: "chevron.right") }
                            .help("后一天")
                    }.buttonStyle(IslandButtonStyle())
                }
            } else if size == .wide {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monthDay(selectedDate)).font(.system(size: 14, weight: .medium))
                        Text(weekdayTitle(selectedDate)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.vertical, 10)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("日程摘要").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        eventRows(events, isAuthorized: isAuthorized,
                                  authorizationHint: authorizationHint, limit: 2, compact: true)
                    }
                    Spacer(minLength: 0)
                }
            } else if size == .tall {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(fullDate(selectedDate)).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Button(action: onCopyDate) { Image(systemName: "doc.on.doc") }
                            .help("复制日期")
                    }.buttonStyle(IslandButtonStyle())
                    eventRows(events, isAuthorized: isAuthorized,
                              authorizationHint: authorizationHint, limit: 4, compact: true)
                    Spacer(minLength: 0)
                }
            } else if size == .strip {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monthDay(selectedDate)).font(.system(size: 13, weight: .medium))
                        Text(weekdayTitle(selectedDate)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.vertical, 8)
                    if events.isEmpty {
                        eventRows(events, isAuthorized: isAuthorized,
                                  authorizationHint: authorizationHint, limit: 0, compact: true)
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Array(events.prefix(3))) { event in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.title).font(.system(size: 11)).lineLimit(1)
                                    Text(eventTime(event)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Button { onMoveMonth(-1) } label: { Image(systemName: "chevron.left") }
                        Text(monthTitle(selectedDate)).font(.system(size: 11, weight: .medium))
                        Button { onMoveMonth(1) } label: { Image(systemName: "chevron.right") }
                        Spacer(minLength: 0)
                        Button(action: onCopyDate) { Image(systemName: "doc.on.doc") }
                            .help("复制日期")
                    }.buttonStyle(IslandButtonStyle())
                    monthGrid(days: days, selectedDate: selectedDate, calendar: calendar,
                              firstWeekday: firstWeekday, accent: accent, compact: true,
                              onSelectDate: onSelectDate)
                    HStack(spacing: 6) {
                        Text(fullDate(selectedDate)).font(.system(size: 9)).foregroundStyle(.secondary)
                        if let event = events.first {
                            Text(event.title).font(.system(size: 9)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private static func monthGrid(
        days: [CalendarDay], selectedDate: Date, calendar: Calendar,
        firstWeekday: Int, accent: Color, compact: Bool,
        onSelectDate: @escaping (Date) -> Void
    ) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 1 : 3), count: 7),
                  spacing: compact ? 1 : 3) {
            ForEach(0..<7, id: \.self) { index in
                let weekday = (index + firstWeekday - 1) % 7
                Text(["日", "一", "二", "三", "四", "五", "六"][weekday])
                    .font(.system(size: compact ? 8 : 10, weight: .medium))
                    .foregroundStyle(weekday == 0 || weekday == 6 ? .secondary : .primary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(days) { day in
                let inMonth = calendar.isDate(day.date, equalTo: selectedDate, toGranularity: .month)
                let selected = calendar.isDate(day.date, inSameDayAs: selectedDate)
                Button { onSelectDate(day.date) } label: {
                    VStack(spacing: compact ? 0 : 2) {
                        Text(day.date.formatted(.dateTime.day()))
                            .font(.system(size: compact ? 9 : 11, weight: day.isToday ? .bold : .regular))
                        if compact {
                            Circle().fill(day.events.isEmpty ? Color.clear : accent)
                                .frame(width: 3, height: 3)
                        } else {
                            Text(day.holidayText ?? day.lunarText ?? "")
                                .font(.system(size: 9)).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(day.isWeekend || !inMonth ? .secondary : .primary)
                    .frame(maxWidth: .infinity).frame(height: compact ? 18 : 31)
                    .background(selected ? accent.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous))
                }.buttonStyle(IslandButtonStyle())
            }
        }
    }

    private static func eventRows(
        _ events: [CalendarEvent], isAuthorized: Bool, authorizationHint: String?,
        limit: Int?, compact: Bool
    ) -> some View {
        Group {
            if let authorizationHint {
                Text(authorizationHint).font(.system(size: 10)).foregroundStyle(.secondary)
            } else if events.isEmpty {
                Text(isAuthorized ? "暂无日程" : "日历尚未授权")
                    .font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                    ForEach(Array(events.prefix(limit ?? events.count))) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(eventTime(event)).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(event.title).font(.system(size: compact ? 10 : 11))
                                .lineLimit(compact ? 1 : nil)
                        }
                    }
                }
            }
        }
    }

    private static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().locale(Locale(identifier: "zh_CN")))
    }

    private static func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }

    private static func weekdayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    private static func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
    }

    private static func eventTime(_ event: CalendarEvent) -> String {
        event.isAllDay ? "全天" : event.startDate.formatted(.dateTime.hour().minute())
    }

    private func selectDate(_ date: Date) {
        let monthChanged = !Calendar.current.isDate(date, equalTo: selectedDate, toGranularity: .month)
        selectedDate = date
        if monthChanged { reload() } else { reloadEvents() }
    }

    private func moveDate(_ component: Calendar.Component, by value: Int) {
        if let date = Calendar.current.date(byAdding: component, value: value, to: selectedDate) {
            selectedDate = date
            reload()
        }
    }

    private func reload() {
        if usesMonthGrid { days = calendar.monthDays(for: selectedDate, firstWeekday: firstWeekday) }
        reloadEvents()
    }

    private func reloadEvents() {
        if usesMonthGrid, let day = days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }) {
            events = day.events
            return
        }
        let start = Calendar.current.startOfDay(for: selectedDate)
        if let end = Calendar.current.date(byAdding: .day, value: 1, to: start) {
            events = calendar.events(from: start, to: end)
        }
    }
}

