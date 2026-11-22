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
