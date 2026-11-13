import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件夹 / 归档共用内嵌浏览

struct FileContainerPreview: View {
    let path: String
    @StateObject private var browser: FileContainerPreviewBrowser

    init(path: String) {
        self.path = path
        _browser = StateObject(wrappedValue: FileContainerPreviewBrowser(path: path))
    }

    private var showsPreview: Bool { browser.preview != nil || browser.previewLoading }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: browser.goUp) { Image(systemName: "arrow.up") }
                    .help("返回父目录（⌘↑）")
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(browser.atRoot || browser.loading)
                Button("根目录", action: browser.goRoot)
                    .disabled(browser.atRoot || browser.loading)
                Button("进入") { browser.openSelectedDirectory() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(browser.selectedEntry?.isDirectory != true || browser.loading)
                pathButton(browser.currentPath)
                Spacer(minLength: 0)
                Text("\(browser.entries.count) 项").foregroundStyle(.secondary)
            }
            .controlSize(.small)
            HStack(spacing: 0) {
                List(selection: Binding(get: { browser.selection }, set: browser.select)) {
                    ForEach(browser.entries) { entry in
                        HStack(spacing: 8) {
                            Image(nsImage: ArchiveFileIcon.icon(for: entry))
                                .resizable().scaledToFit().frame(width: 22, height: 22)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(entry.sizeText).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(entry.path)
                        .help(entry.path)
                        .onTapGesture {
                            if entry.isDirectory { browser.enter(entry) }
                            else { browser.select(entry.path) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(width: showsPreview ? 220 : nil)
                .overlay {
                    if browser.loading { ProgressView("读取目录…") }
                    else if browser.entries.isEmpty { Text("目录为空").foregroundStyle(.secondary) }
                }
                .onMoveCommand { direction in
                    if direction == .right { browser.openSelectedDirectory() }
                    if direction == .left { browser.goUp() }
                }
                if showsPreview {
                    Divider()
                    Group {
                        if browser.previewLoading {
                            ProgressView("读取文件…")
                        } else if let model = browser.preview {
                            PreviewPopoverContentView(model: model, usesWindowChrome: false)
                                .id(model.sessionID)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 8)
                }
            }
            .frame(minHeight: 300, maxHeight: .infinity)
            if let error = browser.errorText {
                Text(error).foregroundStyle(.orange)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .onAppear { browser.load(path) }
        .onChange(of: path) { browser.load($0) }
        .onDisappear(perform: browser.close)
    }

    private func pathButton(_ value: String) -> some View {
        Button {
            if let error = ClipboardManager.shared.copyText(value, successMessage: "已复制路径") {
                browser.errorText = error
            }
        } label: {
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("复制路径：\(value)")
    }
}

private final class FileContainerPreviewBrowser: ObservableObject {
    @Published var entries: [ArchiveEntry] = []
    @Published var selection: String?
    @Published var loading = true
    @Published var previewLoading = false
    @Published var preview: PreviewPopoverContentModel?
    @Published var errorText: String?
    @Published private var root: URL
    @Published private var directory = ""
    private var isArchive = false
    private var allEntries: [ArchiveEntry] = []
    private var history: [String] = []
    private var active = false
    private var listingGeneration = 0
    private var previewGeneration = 0
    private var work: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var temporaryFile: URL?
    private var listingArchive = false
    private var pendingArchive: Revision?
    private var extracting = false
    private var pendingExtraction: (URL, ArchiveEntry, Int)?
    private static let queue = DispatchQueue(label: "Kitnest.container-preview", qos: .userInitiated)

    private struct Revision: Equatable {
        let url: URL
        let modified: Date?
        let size: Int?
    }
    // 只保存最近四个归档的条目元数据，不保存解压文件。
    private static var recent: [(Revision, [ArchiveEntry])] = []

    init(path: String) { root = URL(fileURLWithPath: path) }

    var selectedEntry: ArchiveEntry? { entries.first { $0.path == selection } }
    var atRoot: Bool { history.isEmpty }
    var currentPath: String {
        isArchive ? root.path + (directory.isEmpty ? "" : "/" + directory)
                  : (directory.isEmpty ? root.path : directory)
    }
    var selectedPath: String {
        guard let entry = selectedEntry else { return currentPath }
        return isArchive ? root.path + "/" + entry.path : (preview?.fileURL?.path ?? entry.path)
    }

    func load(_ path: String) {
        close()
        active = true
        loading = true
        entries = []
        allEntries = []
        history = []
        directory = ""
        errorText = nil
        root = URL(fileURLWithPath: path)
        let generation = listingGeneration
        let item = DispatchWorkItem {
            do {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
                }
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let revision = Revision(url: url, modified: values.contentModificationDate, size: values.fileSize)
                let folder = isDirectory.boolValue
                DispatchQueue.main.async {
                    guard self.active, generation == self.listingGeneration else { return }
                    self.root = url
                    self.isArchive = !folder
                    if folder { self.readDirectory() }
                    else { self.readArchive(revision) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.active, generation == self.listingGeneration else { return }
                    self.loading = false
                    self.errorText = "无法读取 \(path)：\(error.localizedDescription)"
                }
            }
        }
        work = item
        Self.queue.async(execute: item)
    }

    private func readArchive(_ revision: Revision) {
        if let index = Self.recent.firstIndex(where: { $0.0 == revision }) {
            let hit = Self.recent.remove(at: index)
            Self.recent.append(hit)
            allEntries = hit.1
            readDirectory()
            return
        }
        if listingArchive { pendingArchive = revision; return }
        listingArchive = true
        let generation = listingGeneration
        ArchiveCore.list(url: revision.url, includeAuxiliary: true) { list, error in
            self.listingArchive = false
            if error == nil {
                Self.recent.removeAll { $0.0.url == revision.url }
                Self.recent.append((revision, list))
                if Self.recent.count > 4 { Self.recent.removeFirst() }
            }
            if self.active, generation == self.listingGeneration {
                if let error {
                    self.loading = false
                    self.errorText = "无法读取归档 \(revision.url.path)：\(error)"
                } else {
                    self.allEntries = list
                    self.readDirectory()
                }
            }
            if let next = self.pendingArchive {
                self.pendingArchive = nil
                self.readArchive(next)
            }
        }
    }

    private func readDirectory() {
        listingGeneration += 1
        let generation = listingGeneration
        work?.cancel()
        clearPreview()
        entries = []
        loading = true
        let archive = isArchive, source = allEntries, layer = directory
        let path = currentPath
        let item = DispatchWorkItem {
            do {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let list: [ArchiveEntry]
                if archive {
                    let prefix = layer.isEmpty ? "" : layer + "/"
                    var rows: [String: ArchiveEntry] = [:]
                    for entry in source where entry.path.hasPrefix(prefix) {
                        let remainder = entry.path.dropFirst(prefix.count)
                        guard let name = remainder.split(separator: "/").first else { continue }
                        let child = prefix + String(name)
                        if remainder.contains("/") {
                            if rows[child] == nil {
                                rows[child] = ArchiveEntry(path: child, name: String(name), size: 0,
                                    packedSize: 0, modified: "", method: "", isDirectory: true, parent: layer)
                            }
                        } else { rows[entry.path] = entry }
                    }
                    list = Array(rows.values)
                } else {
                    list = try FileManager.default.contentsOfDirectory(at: url,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).map { child in
                        var folder: ObjCBool = false
                        FileManager.default.fileExists(atPath: child.path, isDirectory: &folder)
                        let values = try child.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        return ArchiveEntry(path: child.path, name: child.lastPathComponent,
                            size: Int64(values.fileSize ?? 0), packedSize: 0,
                            modified: values.contentModificationDate?.description ?? "", method: "",
                            isDirectory: folder.boolValue && !DocumentInlinePreview.supportedExtensions.contains(child.pathExtension.lowercased()),
                            parent: url.path)
                    }
                }
                let sorted = list.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                DispatchQueue.main.async {
                    guard self.active, generation == self.listingGeneration else { return }
                    if !archive, !layer.isEmpty { self.directory = url.path }
                    self.entries = sorted
                    self.loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.active, generation == self.listingGeneration else { return }
                    self.loading = false
                    self.errorText = "无法读取目录 \(path)：\(error.localizedDescription)"
                }
            }
        }
        work = item
        Self.queue.async(execute: item)
    }

    func enter(_ entry: ArchiveEntry) {
        guard entry.isDirectory else { return }
        history.append(directory)
        directory = entry.path
        readDirectory()
    }

    func openSelectedDirectory() {
        if let entry = selectedEntry, entry.isDirectory { enter(entry) }
    }

    func goUp() {
        guard let parent = history.popLast() else { return }
        directory = parent
        readDirectory()
    }

    func goRoot() {
        history = []
        directory = ""
        readDirectory()
    }

    func select(_ path: String?) {
        guard selection != path else { return }
        clearPreview()
        selection = path
        guard let entry = selectedEntry, !entry.isDirectory else { return }
        previewLoading = true
        let generation = previewGeneration
        if isArchive {
            if extracting { pendingExtraction = (root, entry, generation) }
            else { extract(root, entry, generation) }
        } else { render(URL(fileURLWithPath: entry.path), generation) }
    }

    private func extract(_ archive: URL, _ entry: ArchiveEntry, _ generation: Int) {
        extracting = true
        ArchiveCore.extractEntryToTemp(url: archive, entry: entry) { file, message in
            self.extracting = false
            if self.active, generation == self.previewGeneration {
                if let file {
                    self.temporaryFile = file
                    self.render(file, generation)
                } else {
                    self.previewLoading = false
                    self.errorText = "无法解压 \(archive.path)/\(entry.path)：\(message)"
                }
            } else if let file { self.removeTemporaryFile(file) }
            if let next = self.pendingExtraction {
                self.pendingExtraction = nil
                self.extract(next.0, next.1, next.2)
            }
        }
    }

    private func render(_ url: URL, _ generation: Int) {
        let displayPath = isArchive ? selectedPath : nil
        let item = DispatchWorkItem {
            let file = url.resolvingSymlinksInPath()
            let id = "container:" + file.path
            let item = ClipboardItem(id: id, type: .file, content: file.path,
                                     title: file.lastPathComponent, dedupeKey: id)
            let model = PreviewPopoverContentModel(item: item, source: .mainPreview,
                sessionID: UUID(), inlineText: "", displayPath: displayPath)
            DispatchQueue.main.async {
                guard self.active, generation == self.previewGeneration else { return }
                if FilePreviewBuilder.imageExtensions.contains(file.pathExtension.lowercased()),
                   model.fileImage == nil {
                    self.errorText = "无法读取图片：\(file.path)"
                } else { self.preview = model }
                self.previewLoading = false
            }
        }
        previewWork = item
        Self.queue.async(execute: item)
    }

    private func clearPreview() {
        previewGeneration += 1
        previewWork?.cancel()
        pendingExtraction = nil
        preview = nil
        previewLoading = false
        selection = nil
        errorText = nil
        if let file = temporaryFile {
            temporaryFile = nil
            removeTemporaryFile(file)
        }
    }

    private func removeTemporaryFile(_ file: URL) {
        var unit = file.deletingLastPathComponent()
        // ArchiveCore 的解压目录是 temporaryDirectory 的直接子目录，内部同名前缀目录不算。
        let base = FileManager.default.temporaryDirectory.path
        while unit.deletingLastPathComponent().path != base { unit.deleteLastPathComponent() }
        do { try FileManager.default.removeItem(at: unit) }
        catch { errorText = "无法删除临时解压目录 \(unit.path)：\(error.localizedDescription)" }
    }

    func close() {
        active = false
        listingGeneration += 1
        work?.cancel()
        pendingArchive = nil
        clearPreview()
    }
}

// MARK: - 单个条目（图标 + 名字 + 大小）

struct ArchiveEntryTile: View {
    let entry: ArchiveEntry
    /// 所属归档路径（用来解出条目内容做缩略图）；空则只显示类型图标
    var archivePath: String = ""
    // v127（ArcZip P1）：尺寸可调——悬停气泡默认 46，归档浏览窗图标视图 64
    var size: CGFloat = 46

    @Stored private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            // v123：能出内容的（图片/PDF/Office/文本/视频）显示真实缩略图，
            // 其余仍用类型图标——等价于 ArcZip 的分级解码，只是放在悬停气泡里
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.micro, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
            } else {
                Image(nsImage: ArchiveFileIcon.icon(for: entry))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.78, height: size * 0.78)
            }
            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Text(entry.sizeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .help(entry.path)
        .onAppear(perform: loadThumbnail)
        // v127 接线（arch-engine P2-3）：不安全路径角标（../ 穿越 / 绝对路径 / 设备名）
        .overlay(alignment: .topTrailing) {
            if entry.isUnsafe {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(2)
                    .help("路径不安全（../ 穿越 / 绝对路径 / 设备名）。穿越与绝对路径解压时拦截跳过，设备名仅警告（v127.1）")
            }
        }
    }

    private func loadThumbnail() {
        guard thumb == nil, !archivePath.isEmpty,
              ArchiveEntryThumbnail.canRender(entry.name) else { return }
        ArchiveEntryThumbnail.load(archive: URL(fileURLWithPath: archivePath),
                                   entry: entry, size: size) { image in
            // v128（内存优化）：包 autoreleasepool——缩略图批量生成循环（LazyVStack
            // 每行 onAppear 触发）的回调在主线程成批执行，临时桥接对象显式 drain
            autoreleasepool {
                if let image { thumb = image }
            }
        }
    }
}

// MARK: - 归档条目的系统类型图标（不依赖文件落盘，带缓存）

enum ArchiveFileIcon {

    // v128（内存优化）：原无界 [String: NSImage] 字典按扩展名无限增长（同款问题
    // NSCache 治理）；换 NSCache<NSString, NSImage> + countLimit=256——扩展名种类
    // 有限，256 足够且自动响应内存压力。NSCache 线程安全，原 NSLock 一并去掉。
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let genericIcon = NSWorkspace.shared.icon(for: .data)

    /// 按扩展名取系统为该类型注册的图标（和 Finder 里一致）
    static func icon(for entry: ArchiveEntry) -> NSImage {
        if entry.isDirectory { return folderIcon }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return genericIcon }

        let key = ext as NSString
        if let hit = cache.object(forKey: key) { return hit }

        let image: NSImage
        if let ut = UTType(filenameExtension: ext) {
            image = NSWorkspace.shared.icon(for: ut)
        } else {
            image = genericIcon
        }

        cache.setObject(image, forKey: key)
        return image
    }
}
