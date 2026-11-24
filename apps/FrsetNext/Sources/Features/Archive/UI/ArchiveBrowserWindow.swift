import AppKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - 归档浏览窗口（v118；ArcZip M2 浏览 + M4 归档内编辑/重新打包）
//
// 左列条目、右侧预览；文本类可直接改并「写回归档」（7zz a），
// Office/PDF/图片走解压到临时目录后 QuickLook/PDFKit 渲染（FR-408：二进制不做框内编辑）。
//
// v127（ArcZip P0/P1）：
//   P0-1 拖出到 Finder（NSFilePromiseProvider，落点才解压；多选拖出）
//   P0-2 撤销/重做栈（ArchiveUndoStack + ArchiveChange，⌘Z / ⇧⌘Z）
//   P0-3 草稿态关闭提示（windowShouldClose + 三按钮）
//   P1-1 列表 ↔ 图标视图（缩略图磁贴，可点选/右键/拖出）
//   P1-2 多选（Set<String>；批量删除/解压，选中计数）
//   P1-3 目录树导航（面包屑 + 双击进目录 + 返回 ⌘[）

// MARK: 模型

public final class ArchiveBrowserModel: ObservableObject {

    public enum PreviewKind {
        case none, text(String), image(NSImage), pdf(PDFDocument), office(URL), unsupported(String)
        /// v210：网页按浏览器渲染（解压后的落地文件 + 同目录资源根）
        case html(URL, root: URL)
    }

    @Published public private(set) var entries: [ArchiveEntry] = []
    @Published public private(set) var loading = false
    @Published public var errorText: String?
    /// v127（ArcZip P1）：多选（List/表格/图标网格统一用 Set）
    @Published public var selection: Set<String> = []
    @Published public private(set) var previewKind: PreviewKind = .none
    @Published public private(set) var previewLoading = false
    @Published public private(set) var saving = false
    private var previewGeneration = 0
    /// v127：当前预览/编辑中的条目（多选时也明确在编辑哪一个）
    @Published public private(set) var previewEntry: ArchiveEntry?
    @Published public var draftText: String = ""
    @Published public var dirty = false
    @Published public var searchText: String = ""
    /// v127：是否显示 `__MACOSX` / `.DS_Store` 等辅助文件（默认隐藏）
    @Published public var showAuxiliary = false {
        didSet { if showAuxiliary != oldValue { invalidateChildIndex() } }
    }
    /// v127（ArcZip P1）：当前层级（"" = 根）
    @Published public var currentPath: String = ""
    /// 2026-11-23（ArcZip 1.2.5 对齐）：三档视图（图标 / 列表 / 分栏），跨窗口记住
    @Published var viewMode: ArchiveViewMode = ArchiveViewMode(
        rawValue: UserDefaults.standard.string(forKey: "archive.workspace.viewMode") ?? ""
    ) ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "archive.workspace.viewMode") }
    }
    /// 前进/后退历史（ArcZip 的 ‹ › 不是「上一层」，而是访问历史）
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    public var canGoBack: Bool { !backStack.isEmpty || !currentPath.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public let url: URL
    public var editable: Bool { ArchiveCore.isEditable(url) }
    /// v127（ArcZip P0）：撤销/重做栈
    public let undoStack: ArchiveUndoStack
    /// ⇧ 连选锚点（图标视图手动多选用；表格由 NSTableView 自己管）
    public var selectionAnchor: String?

    /// v256（ArcZip `archive.save.source_changed` 同款保护）：
    /// 打开/上次成功写入时记录的源压缩包指纹（mtime + 字节数）。
    /// 每次写回归档前比对——外部程序改过就停下来问，不再用 `7zz a -y` 静默覆盖别人的改动。
    private var sourceStamp: String?

    static func stamp(of url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (a[.size] as? NSNumber)?.int64Value ?? 0
        return "\(Int(m))-\(s)"
    }

    /// 写操作前的一致性校验。返回 true = 可以继续写。
    /// 源包被外部改过时三选：仍然保存 / 重新载入（丢弃当前修改）/ 取消。
    func confirmOverwriteIfSourceChanged() -> Bool {
        guard let recorded = sourceStamp, let now = Self.stamp(of: url), recorded != now else {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "「\(url.lastPathComponent)」已被其他程序修改"
        alert.informativeText = "继续保存会覆盖磁盘上的最新内容。可以重新载入（丢弃当前未保存的修改），或者仍然保存。"
        alert.addButton(withTitle: "仍然保存")
        alert.addButton(withTitle: "重新载入")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Log.warn("Archive", "源包被外部修改，用户选择仍然保存：\(url.lastPathComponent)")
            return true
        case .alertSecondButtonReturn:
            Log.info("Archive", "源包被外部修改，用户选择重新载入：\(url.lastPathComponent)")
            dirty = false
            clearPreview()
            refreshSourceStamp()
            reload()
            return false
        default:
            return false
        }
    }

    /// 写入成功后刷新指纹基线，避免下一次保存被自己刚写的内容判成「外部修改」
    func refreshSourceStamp() {
        sourceStamp = Self.stamp(of: url)
    }

    public init(url: URL) {
        self.url = url
        self.sourceStamp = Self.stamp(of: url)
        self.undoStack = ArchiveUndoStack(url: url)
        self.undoStack.onApplied = { [weak self] in
            guard let self else { return }
            self.refreshSourceStamp()
            self.reload()
            // 编辑类撤销后预览内容要跟着回退
            if !self.dirty, let entry = self.previewEntry {
                self.clearPreview()
                self.loadPreview(for: entry)
            }
        }
    }

    // MARK: 层级 / 过滤

    /// 当前层级的直接子项（+ 为「无显式目录条目」的中间目录合成虚拟文件夹）；
    /// 搜索时跳过层级过滤，全量匹配
    public var visibleEntries: [ArchiveEntry] {
        if !searchText.isEmpty {
            let list = showAuxiliary ? entries : entries.filter { !ArchiveCore.isAuxiliary($0.path) }
            return list.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
        rebuildChildIndexIfNeeded()
        return childIndex[currentPath] ?? []
    }

    /// v288（2026-11-24 审计包 04）：parent → 直接子项索引（含隐式中间目录）。
    ///
    /// 旧 `children(in:of:)` 每调用一次就全表扫三遍——`filter { parent == dir }`、
    /// 重建显式目录 `Set`、再全表探测隐式目录；分栏视图 `columnTrail` 对**每一列**
    /// 都各扫一遍 = O(深度 × 3N)。万条档案 × 10 列 ≈ 30 万次比较，而且这是
    /// SwiftUI body 求值路径上的纯计算，每次状态变化都重来。
    /// 现在只在 entries / showAuxiliary 变化时构建一次（O(N + 路径段数)），
    /// 列内 O(1) 查表；语义逐条对齐旧实现：
    ///   · 显式子项按 parent 分组（等价于 filter parent == dir）；
    ///   · 隐式目录 = 文件路径逐级前缀里「该层第一个目录段」，且路径不在显式
    ///     目录集合中才合成（旧 known 集合是全表显式目录，路径全局唯一，等价）；
    ///   · 目录在前、名称 localizedStandardCompare 排序；
    ///   · 辅助文件过滤先行（aux 文件被滤掉时它撑起的隐式目录同样消失）；
    ///   · 搜索分支不经过索引（全量匹配，不变）。
    private var childIndex: [String: [ArchiveEntry]] = [:]
    /// 索引版本：entries 重载与 showAuxiliary 切换时递增，命中即重建。
    private var childIndexGeneration = 0

    private func rebuildChildIndexIfNeeded() {
        guard childIndexGeneration != 0 else { return }
        // generation 在失效点已递增；这里用「已构建版本号」做幂等
        if builtChildIndexGeneration == childIndexGeneration { return }
        builtChildIndexGeneration = childIndexGeneration

        let list = showAuxiliary ? entries : entries.filter { !ArchiveCore.isAuxiliary($0.path) }
        var map: [String: [ArchiveEntry]] = [:]
        var knownDirs = Set<String>()
        for e in list {
            map[e.parent, default: []].append(e)
            if e.isDirectory { knownDirs.insert(e.path) }
        }
        // 隐式中间目录：每个**文件**路径的每一级前缀目录，都向其父层注册一个合成项
        for e in list where !e.isDirectory {
            let segments = e.path.split(separator: "/")
            guard segments.count > 1 else { continue }
            var acc = ""
            for seg in segments.dropLast() {
                let parent = acc
                let dirPath = acc.isEmpty ? String(seg) : acc + "/" + seg
                if !knownDirs.contains(dirPath) {
                    knownDirs.insert(dirPath)
                    map[parent, default: []].append(
                        ArchiveEntry(path: dirPath, name: String(seg), size: 0, packedSize: 0,
                                     modified: "", method: "", isDirectory: true, parent: parent))
                }
                acc = dirPath
            }
        }
        for key in map.keys {
            map[key]!.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        childIndex = map
    }

    /// 与 generation 配对的「已构建」标记（0 = 从未构建）。
    private var builtChildIndexGeneration = 0

    /// 索引失效：entries 重载与辅助文件开关两处（generation 递增，查表前惰性重建）。
    private func invalidateChildIndex() {
        childIndexGeneration += 1
    }

    /// v127（ArcZip P1）：面包屑（根 / docs / images），每段可点
    public var breadcrumbs: [(name: String, path: String)] {
        var result: [(name: String, path: String)] = [("根", "")]
        if !currentPath.isEmpty {
            var acc = ""
            for comp in currentPath.split(separator: "/") {
                acc = acc.isEmpty ? String(comp) : acc + "/" + comp
                result.append((name: String(comp), path: acc))
            }
        }
        return result
    }

    /// 分栏视图：从根到当前层级的每一列（每列 = 该目录的直接子项）
    public struct ColumnTrailItem {
        public let path: String
        public let entries: [ArchiveEntry]
    }

    public var columnTrail: [ColumnTrailItem] {
        rebuildChildIndexIfNeeded()
        var paths: [String] = [""]
        if !currentPath.isEmpty {
            var acc = ""
            for comp in currentPath.split(separator: "/") {
                acc = acc.isEmpty ? String(comp) : acc + "/" + comp
                paths.append(acc)
            }
        }
        return paths.map { ColumnTrailItem(path: $0, entries: childIndex[$0] ?? []) }
    }

    /// 切层级：默认记进历史（ArcZip 的 ‹ › 走访问历史，不是简单上一层）
    public func navigateTo(_ path: String, recordHistory: Bool = true) {
        guard path != currentPath else { return }
        if recordHistory {
            backStack.append(currentPath)
            forwardStack.removeAll()
        }
        applyPath(path)
    }

    private func applyPath(_ path: String) {
        currentPath = path
        searchText = ""                 // 搜索是全量的，跳转层级时清掉
        selection = []
        selectionAnchor = nil
        clearPreview()
    }

    /// v127（ArcZip P1）：双击目录 → 进入
    public func enter(_ entry: ArchiveEntry) {
        guard entry.isDirectory else { return }
        navigateTo(entry.path)
    }

    /// 上一层（↑ 按钮 / ⌘↑）
    public func goUp() {
        guard !currentPath.isEmpty else { return }
        navigateTo((currentPath as NSString).deletingLastPathComponent)
    }

    /// 返回（⌘[）：优先走历史，历史上没有才退回上一层
    public func goBack() {
        if let previous = backStack.popLast() {
            forwardStack.append(currentPath)
            applyPath(previous)
            return
        }
        guard !currentPath.isEmpty else { return }
        applyPath((currentPath as NSString).deletingLastPathComponent)
    }

    /// 前进（⌘]）
    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        applyPath(next)
    }

    /// 双击条目：目录进层级；文件选中并预览
    public func activate(_ entry: ArchiveEntry) {
        if entry.isDirectory {
            enter(entry)
            return
        }
        if !selection.contains(entry.path) {
            selection = [entry.path]
            selectionAnchor = entry.path
        }
        loadPreview(for: entry)
    }

    // MARK: 选中

    public var selectedEntries: [ArchiveEntry] {
        visibleEntries.filter { selection.contains($0.path) }
    }

    /// v127（ArcZip P1）：图标视图点选（⌘ 切换 / ⇧ 连选 / 普通点选）
    public func clickSelect(_ entry: ArchiveEntry) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(entry.path) {
                selection.remove(entry.path)
            } else {
                selection.insert(entry.path)
            }
            selectionAnchor = entry.path
        } else if flags.contains(.shift), let anchor = selectionAnchor,
                  let from = visibleEntries.firstIndex(where: { $0.path == anchor }),
                  let to = visibleEntries.firstIndex(where: { $0.path == entry.path }) {
            let list = visibleEntries
            let lo = min(from, to), hi = max(from, to)
            selection = Set(list[lo...hi].map { $0.path })
        } else {
            selection = [entry.path]
            selectionAnchor = entry.path
        }
    }

    /// 右键：不在选中集里才单选它（多选时保留，菜单作用于整组）
    public func contextualSelect(_ entry: ArchiveEntry) {
        if !selection.contains(entry.path) {
            selection = [entry.path]
            selectionAnchor = entry.path
        }
    }

    // MARK: 载入

    public func reload() {
        loading = true
        errorText = nil
        // 全量载入（含辅助文件），由 visibleEntries 决定显隐——这样开关能即时生效
        ArchiveCore.list(url: url, includeAuxiliary: true) { [weak self] list, err in
            guard let self else { return }
            self.loading = false
            self.entries = list
            self.invalidateChildIndex()   // v288：目录索引随重载失效（惰性重建）
            if let err {
                // v124：像是缺密码就弹输入框，输对自动重载
                if ArchiveCore.ArchivePasswords.looksLikePasswordError(err) {
                    self.promptPassword()
                } else {
                    self.errorText = err
                }
            }
            // v127：多选——只保留仍存在的选中项（合成目录仍有子项即保留）
            self.selection = self.selection.filter { sel in
                if list.contains(where: { $0.path == sel }) { return true }
                let prefix = sel + "/"
                return list.contains { $0.path.hasPrefix(prefix) }
            }
            if let preview = self.previewEntry,
               !list.contains(where: { $0.path == preview.path }) {
                self.clearPreview()
            }
        }
    }

    public func clearPreview() {
        guard !dirty else { return }
        previewGeneration += 1
        previewKind = .none
        previewEntry = nil
        previewLoading = false
        draftText = ""
        dirty = false
    }

    /// 密码输入（NSSecureTextField + 明文切换，ArcZip「密码输入对话框」）
    public func promptPassword() {
        let alert = NSAlert()
        alert.messageText = "「\(url.lastPathComponent)」已加密"
        alert.informativeText = "请输入密码以查看归档内容。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = "密码"
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pw = field.stringValue
        guard !pw.isEmpty else { return }
        ArchiveCore.ArchivePasswords.set(pw, for: url)
        reload()
    }

    // MARK: 预览

    public func loadPreview(for entry: ArchiveEntry) {
        // 保留尚未写回的编辑；重复选择同一条目不重新读取并清空草稿。
        guard !dirty, previewEntry?.path != entry.path else { return }
        previewGeneration += 1
        let generation = previewGeneration
        previewLoading = true
        previewKind = .none
        previewEntry = entry
        draftText = ""
        dirty = false
        let ext = (entry.name as NSString).pathExtension.lowercased()

        if entry.isDirectory {
            previewLoading = false
            previewKind = .unsupported("文件夹")
            return
        }
        // v210（用户：「HTML 直接渲染成浏览器里的那种」）：网页不再当代码文本看。
        // 必须**排在文本分支之前**——html 也在 FilePreviewBuilder.textExtensions 里，
        // 落在后面就永远走「带行号的源码」（v210 实测：首版顺序错了，页面仍是源码）。
        // 连同同目录资源一起解到临时目录，交给 WKWebView（CSS/JS/图片/子页面都能生效）。
        if ["html", "htm", "xhtml", "svg"].contains(ext) {
            ArchiveCore.extractWebPreviewToTemp(url: url, entry: entry) { [weak self] fileURL, err in
                guard let self, self.previewGeneration == generation else {
                    if let fileURL { try? FileManager.default.removeItem(at: ArchiveCore.extractionDirectory(containing: fileURL)) }
                    return
                }
                self.previewLoading = false
                guard let fileURL else {
                    self.previewKind = .unsupported(err.isEmpty ? "网页解压失败" : err)
                    return
                }
                let root = fileURL.deletingLastPathComponent()
                self.rememberPreviewTemp(fileURL)
                self.previewKind = .html(fileURL, root: root)
            }
            return
        }
        // 文本类：直接读内容（可编辑）
        if FilePreviewBuilder.textExtensions.contains(ext) || ext.isEmpty {
            ArchiveCore.readEntry(url: url, entry: entry) { [weak self] data, err in
                guard let self, self.previewGeneration == generation else { return }
                self.previewLoading = false
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    self.previewKind = .unsupported(err ?? "无法以文本方式读取")
                    return
                }
                self.previewKind = .text(text)
                self.draftText = text
            }
            return
        }
        // 图片：内存解码
        //
        // v129（用户反馈「预览的照片不太对」）：原先走 readEntry 默认 8 MB 上限，
        // 手机/单反原图直接被判「文件过大」；即便放行也是整张解码（50MP 吃掉数百 MB）。
        // 现在放宽到 128 MB，并交给 ImageIO 降采样到长边 2600px —— Retina 够清晰，
        // 内存只占十几 MB，竖拍照片按 EXIF 转正。
        if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff"].contains(ext) {
            ArchiveCore.readEntry(url: url, entry: entry,
                                  limit: 128 * 1024 * 1024) { [weak self] data, err in
                guard let self, self.previewGeneration == generation else { return }
                self.previewLoading = false
                if let data, let img = ArchiveEntryThumbnail.downsample(data: data, maxPixel: 2600)
                                        ?? NSImage(data: data) {
                    self.previewKind = .image(img)
                } else {
                    self.previewKind = .unsupported(err ?? "图片解码失败")
                }
            }
            return
        }
        // 其余（PDF / Office / 任意）：解压到临时目录再渲染
        ArchiveCore.extractEntryToTemp(url: url, entry: entry) { [weak self] tempURL, err in
            guard let self, self.previewGeneration == generation else {
                if let tempURL { try? FileManager.default.removeItem(at: ArchiveCore.extractionDirectory(containing: tempURL)) }
                return
            }
            guard let tempURL else {
                self.previewLoading = false
                self.previewKind = .unsupported(err)
                return
            }
            self.rememberPreviewTemp(tempURL)
            if ext == "pdf", let doc = PDFDocument(url: tempURL) {
                self.previewLoading = false
                self.previewKind = .pdf(doc)
                return
            }
            // Office：v256 改用 QLPreviewView（preview 通道）渲染正文——
            // 原来走 QLThumbnailGenerator 只拿到首屏缩略图/图标，用户看到的是「一张封面」，
            // 和面板 v167 修掉的是同一个坑（缩略图通道对 docx/pptx/xlsx 只给图标，
            // 预览通道才有真实排版，且可翻页）。临时文件保留，供「用默认应用打开」。
            self.previewLoading = false
            self.previewKind = .office(tempURL)
        }
    }

    // 网页、PDF 与 Office 共用窗口持有的临时目录，保留到预览窗口关闭。
    private var previewTemps: [URL] = []

    private func rememberPreviewTemp(_ dir: URL) {
        let top = ArchiveCore.extractionDirectory(containing: dir)
        if !previewTemps.contains(top) { previewTemps.append(top) }
    }

    /// 窗口关闭时释放预览，再删除这次窗口持有的解压目录。
    public func cleanupPreviewTemps() {
        previewGeneration += 1
        previewKind = .none
        for dir in previewTemps {
            try? FileManager.default.removeItem(at: dir)
            Log.info("Archive", "清理预览临时目录 \(dir.lastPathComponent)")
        }
        previewTemps.removeAll()
    }

    // MARK: 编辑 / 回写

    /// 保存当前文本条目回归档
    /// v123（用户明确要求）：**直接覆盖原压缩包，不再生成 .bak 副本**。
    /// `7zz a -y` 本身就是打开原包原地更新，路径不变、不产生新文件。
    /// v127（ArcZip P0）：保存前的旧文本进撤销栈（undo=写回旧文本）。
    public func saveDraft(completion: ((Bool) -> Void)? = nil) {
        guard !saving else { completion?(false); return }
        guard confirmOverwriteIfSourceChanged() else { completion?(false); return }
        guard let entry = previewEntry, case .text(let oldText) = previewKind else {
            completion?(false)
            return
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("frset-edit-\(UUID().uuidString)-\(entry.name)")
        do {
            try draftText.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            errorText = "写入临时文件失败：\(error.localizedDescription)"
            completion?(false)
            return
        }
        let newText = draftText
        let generation = previewGeneration
        saving = true
        ArchiveCore.updateEntry(url: url, entryPath: entry.path, localFile: tmp) { [weak self] ok, msg in
            try? FileManager.default.removeItem(at: tmp)
            guard let self else { return }
            self.saving = false
            if ok {
                // v127（ArcZip P0）：可撤销；同时把预览基线挪到新文本（连续两次保存的
                // 旧文本才不会记错）
                if newText != oldText {
                    self.undoStack.push(.editText(path: entry.path, oldText: oldText, newText: newText))
                }
                if self.previewGeneration == generation {
                    self.previewKind = .text(newText)
                    self.dirty = self.draftText != newText
                }
                self.refreshSourceStamp()
                Toast.show("已写回归档", icon: "archivebox")
                self.reload()
                completion?(true)
            } else {
                self.errorText = msg
                completion?(false)
            }
        }
    }

    /// 添加文件（v127：进当前层级；选中单个文件夹时进该文件夹）
    /// v127 接线（arch-engine P2-2）：添加前扫 Windows 文件名问题 → 对话框三选一
    public func addFiles(_ files: [URL]) {
        guard !files.isEmpty else { return }
        guard confirmOverwriteIfSourceChanged() else { return }
        let issues = ArchiveCore.windowsNameIssues(files.map { $0.lastPathComponent })
        guard !issues.isEmpty else {
            performAddFiles(files)
            return
        }
        let alert = NSAlert()
        alert.messageText = "有 \(issues.count) 个文件名在 Windows 上不安全"
        var lines: [String] = []
        for issue in issues.prefix(8) {
            lines.append("\(issue.name) —— \(issue.reason)")
            lines.append("建议改为：\(issue.suggested)")
        }
        if issues.count > 8 { lines.append("…等 \(issues.count) 项") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "用建议名继续")
        alert.addButton(withTitle: "保持原名")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let renamed = withSuggestedNames(files)
            performAddFiles(renamed.files, temporaryDirectories: renamed.directories)
        case .alertSecondButtonReturn:
            performAddFiles(files)
        default:
            return
        }
    }

    /// 用建议名继续：问题文件复制到临时目录换名（原磁盘文件不动）；全量名单去重防撞名
    ///（`a:b` 与 `a?b` 都会变成 `a_b`，撞名加序号——用 arch-engine 的 uniqueWindowsNames）
    private func withSuggestedNames(_ files: [URL]) -> (files: [URL], directories: [URL]) {
        var suggestions: [String: String] = [:]
        for issue in ArchiveCore.windowsNameIssues(files.map { $0.lastPathComponent }) {
            suggestions[issue.name] = issue.suggested
        }
        let finalNames = ArchiveCore.uniqueWindowsNames(
            files.map { suggestions[$0.lastPathComponent] ?? $0.lastPathComponent })
        var out: [URL] = []
        var directories: [URL] = []
        for (i, f) in files.enumerated() {
            let newName = finalNames[i]
            guard newName != f.lastPathComponent else {
                out.append(f)
                continue
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-addname-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(newName)
            do {
                try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: f, to: tmp)
                out.append(tmp)
                directories.append(tmp.deletingLastPathComponent())
            } catch {
                try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                out.append(f)       // 换名失败 → 保持原名
            }
        }
        return (out, directories)
    }

    private func performAddFiles(_ files: [URL], temporaryDirectories: [URL] = []) {
        let dir: String
        if let entry = selectedEntries.first, entry.isDirectory {
            dir = entry.path
        } else {
            dir = currentPath
        }
        ArchiveCore.addFiles(url: url, files: files, intoDirectory: dir) { [weak self] ok, msg in
            defer {
                for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
            }
            guard let self else { return }
            if ok {
                // v127（ArcZip P0）：新增内容备份 → 可撤销（undo=removeEntries）
                self.captureAddeds(files, into: dir) { snaps in
                    if !snaps.isEmpty {
                        self.undoStack.push(.add(items: snaps))
                    }
                }
                self.refreshSourceStamp()
                Toast.show(msg, icon: "plus.circle")
                self.reload()
            } else {
                self.errorText = msg
            }
        }
    }

    /// 工具栏/右键「添加文件」入口
    public func pickAndAddFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    /// v127（ArcZip P1）：删除所有选中项（removeEntries 对目录路径是子树级删除，实测）
    public func deleteSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        guard confirmOverwriteIfSourceChanged() else { return }
        // v127（ArcZip P0）：删除前先备份内容 → 可撤销（undo=按原路径写回）
        captureSnapshots(of: targets) { [weak self] snaps in
            guard let self else { return }
            ArchiveCore.removeEntries(url: self.url, entryPaths: targets.map { $0.path }) { ok, msg in
                if ok {
                    if !snaps.isEmpty {
                        self.undoStack.push(.delete(items: snaps,
                                                    roots: targets.map { $0.path }))
                    }
                    Toast.show(targets.count == 1
                               ? "已删除 \(targets[0].name)"
                               : "已删除 \(targets.count) 项", icon: "trash")
                    self.selection = []
                    self.selectionAnchor = nil
                    if let preview = self.previewEntry, targets.contains(where: {
                        preview.path == $0.path || ($0.isDirectory && preview.path.hasPrefix($0.path + "/"))
                    }) { self.dirty = false }
                    self.clearPreview()
                    self.refreshSourceStamp()
                    self.reload()
                } else {
                    self.errorText = msg
                }
            }
        }
    }

    /// 重命名选中条目（v123；7zz rn 原地改包内路径）
    /// v127（ArcZip P1）：多选时只重命名第一个（ArcZip 也是单个重命名）
    public func renameSelected() {
        guard let entry = selectedEntries.first else { return }
        guard confirmOverwriteIfSourceChanged() else { return }
        let alert = NSAlert()
        alert.messageText = "重命名归档内条目"
        alert.informativeText = entry.path
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.stringValue = entry.name
        field.selectText(nil)
        alert.accessoryView = field
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != entry.name else { return }
        let oldPath = entry.path
        ArchiveCore.renameEntry(url: url, entryPath: oldPath, newName: newName) { [weak self] ok, msg in
            guard let self else { return }
            if ok {
                // v127（ArcZip P0）：记旧/新路径 → 可撤销（rn 对目录也是子树级改名，实测）
                let dir = (oldPath as NSString).deletingLastPathComponent
                let newPath = dir.isEmpty ? newName : dir + "/" + newName
                self.undoStack.push(.rename(from: oldPath, to: newPath))
                self.refreshSourceStamp()
                Toast.show(msg, icon: "pencil")
                self.reload()
            } else {
                self.errorText = msg
            }
        }
    }

    // MARK: 解压冲突（v256，ArcZip `dialog.extraction_conflict` 同款）

    enum ExtractConflictDecision { case overwrite, skipExisting, cancel }

    /// 解压前扫目标目录的**顶层**同名项。返回用户的决定。
    /// 顶层才算冲突：条目 `a/b.txt` 落到 `dir/a/b.txt`，只可能撞到 `dir/a`。
    private func decideExtractConflicts(_ paths: [String], in dir: URL) -> ExtractConflictDecision {
        var files: [String] = []
        var folders: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard let top = path.split(separator: "/").first.map(String.init), !top.isEmpty else { continue }
            guard seen.insert(top).inserted else { continue }
            var isDir: ObjCBool = false
            let full = dir.appendingPathComponent(top).path
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders.append(top) } else { files.append(top) }
        }
        guard !files.isEmpty || !folders.isEmpty else { return .overwrite }

        var lines: [String] = []
        if !files.isEmpty {
            lines.append("同名文件 \(files.count) 个：" + files.prefix(5).joined(separator: "、")
                         + (files.count > 5 ? " 等" : ""))
        }
        if !folders.isEmpty {
            lines.append("同名文件夹 \(folders.count) 个（会合并）："
                         + folders.prefix(5).joined(separator: "、")
                         + (folders.count > 5 ? " 等" : ""))
        }

        let alert = NSAlert()
        alert.messageText = files.isEmpty ? "目标位置已有同名文件夹" : "目标位置已有同名文件"
        NSApp.activate(ignoringOtherApps: true)
        if files.isEmpty {
            // 只有文件夹：7zz 的合并是默认行为，给「合并 / 取消」即可（-aos 对目录不生效）
            lines.append("继续会把这些文件夹合并到现有目录，同路径文件仍会被覆盖。")
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "合并")
            alert.addButton(withTitle: "取消")
            return alert.runModal() == .alertFirstButtonReturn ? .overwrite : .cancel
        }
        lines.append("「跳过已存在」会保留目标里已有的同名文件，只解出缺失的部分；「覆盖」会替换它们。")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "跳过已存在")
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Log.info("Archive", "解压冲突：用户选择跳过已存在（\(files.count) 个同名文件）")
            return .skipExisting
        case .alertSecondButtonReturn:
            Log.warn("Archive", "解压冲突：用户选择覆盖（\(files.count) 个同名文件）")
            return .overwrite
        default:
            return .cancel
        }
    }

    /// 解压全部（含辅助文件过滤按 ArchiveCore 默认）
    public func extractAll() {
        guard let dir = pickExtractDirectory() else { return }
        let decision = decideExtractConflicts(entries.map { $0.path }, in: dir)
        guard decision != .cancel else { return }
        ArchiveCore.extract(url: url, entry: nil, to: dir,
                            skipExisting: decision == .skipExisting) { ok, msg in
            Toast.show(ok ? "已解压" : "解压失败：\(msg)",
                       icon: ok ? "archivebox" : "exclamationmark.triangle", isWarning: !ok)
        }
    }

    /// v127（ArcZip P1）：解压所有选中项（逐个解到同一目录；目录路径子树级提取，实测）
    public func extractSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        guard let dir = pickExtractDirectory() else { return }
        let decision = decideExtractConflicts(targets.map { $0.path }, in: dir)
        guard decision != .cancel else { return }
        extractSequential(targets, 0, to: dir, failures: [],
                          skipExisting: decision == .skipExisting)
    }

    private func extractSequential(_ targets: [ArchiveEntry], _ index: Int,
                                   to dir: URL, failures: [String], skipExisting: Bool) {
        guard index < targets.count else {
            if failures.isEmpty {
                Toast.show(targets.count == 1 ? "已解压" : "已解压 \(targets.count) 项", icon: "archivebox")
            } else {
                Toast.show("解压完成（\(failures.count) 项失败）：\(failures.first ?? "")",
                           icon: "exclamationmark.triangle", isWarning: true)
            }
            return
        }
        ArchiveCore.extract(url: url, entry: targets[index].path, to: dir,
                            skipExisting: skipExisting) { ok, msg in
            if !ok, msg == "已取消" {
                Toast.show("已取消解压", icon: "archivebox")
                return
            }
            var fails = failures
            if !ok { fails.append(msg) }
            self.extractSequential(targets, index + 1, to: dir, failures: fails,
                                   skipExisting: skipExisting)
        }
    }

    private func pickExtractDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// 用默认应用打开条目（Office 等）
    public func openExternally(_ entry: ArchiveEntry) {
        ArchiveCore.extractEntryToTemp(url: url, entry: entry) { tempURL, err in
            guard let tempURL else {
                Toast.show(err, icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            if !NSWorkspace.shared.open(tempURL) {
                try? FileManager.default.removeItem(at: ArchiveCore.extractionDirectory(containing: tempURL))
                Toast.show("无法打开 \(entry.name)", icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// 另存为加密归档（v124；ArcZip「保存为加密归档」）
    public func saveEncryptedCopy() {
        let alert = NSAlert()
        alert.messageText = "另存为加密归档"
        alert.informativeText = "整个归档会重新打包为带密码的新文件（原包不变）。"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        stack.orientation = .vertical
        stack.spacing = 6
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        let base = (url.deletingPathExtension().lastPathComponent)
        nameField.stringValue = base + "-加密.7z"
        let pwField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        pwField.placeholderString = "密码"
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(pwField)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pw = pwField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pw.isEmpty else {
            errorText = "密码不能为空"
            return
        }
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent(nameField.stringValue.trimmingCharacters(in: .whitespaces))
        ArchiveCore.saveEncryptedCopy(url: url, to: dest, password: pw) { ok, msg in
            Toast.show(ok ? msg : "另存失败：\(msg)",
                       icon: ok ? "lock.fill" : "exclamationmark.triangle", isWarning: !ok)
        }
    }

    // MARK: 撤销快照（v127（ArcZip P0）：修改前捕获可逆信息）

    /// 删除前备份内容：目录展开为其中每个文件；>48MB 的文件跳过（该项不可撤销）
    private func captureSnapshots(of targets: [ArchiveEntry],
                                  completion: @escaping ([ArchiveChange.Snapshot]) -> Void) {
        var files: [ArchiveEntry] = []
        for t in targets {
            if t.isDirectory {
                let prefix = t.path + "/"
                files.append(contentsOf: entries.filter { !$0.isDirectory && $0.path.hasPrefix(prefix) })
            } else {
                files.append(t)
            }
        }
        let cap = Int64(48 * 1024 * 1024)
        var seen = Set<String>()
        let unique = files.filter { $0.size <= cap && seen.insert($0.path).inserted }
        var snaps: [ArchiveChange.Snapshot] = []
        func next(_ index: Int) {
            guard index < unique.count else {
                completion(snaps)
                return
            }
            let e = unique[index]
            ArchiveCore.extractEntryToTemp(url: url, entry: e) { tmp, _ in
                if let tmp {
                    snaps.append(.init(path: e.path, tempURL: tmp))
                }
                next(index + 1)
            }
        }
        next(0)
    }

    /// 添加后备份新增内容（复制源文件到临时目录，路径 = 包内相对路径）
    private func captureAddeds(_ files: [URL], into dir: String,
                               completion: @escaping ([ArchiveChange.Snapshot]) -> Void) {
        var snaps: [ArchiveChange.Snapshot] = []
        for f in files {
            let rel = dir.isEmpty ? f.lastPathComponent : dir + "/" + f.lastPathComponent
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-addsnap-\(UUID().uuidString)", isDirectory: true)
            let tmp = directory.appendingPathComponent(f.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: f, to: tmp)
                snaps.append(.init(path: rel, tempURL: tmp))
            } catch {
                // 备份失败 → 该项不可撤销，跳过
                try? FileManager.default.removeItem(at: directory)
            }
        }
        completion(snaps)
    }
}

// MARK: 窗口

public final class ArchiveBrowserWindowController: NSWindowController, NSWindowDelegate {

    private static var open: [String: ArchiveBrowserWindowController] = [:]

    public static func show(url: URL, selectFirst: Bool = false, selectPath: String? = nil) {
        let key = url.standardizedFileURL.path
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let selectPath { existing.selectEntry(path: selectPath) }
            else if selectFirst { existing.selectFirstEntry() }
            return
        }
        let controller = ArchiveBrowserWindowController(url: url)
        open[key] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let selectPath { controller.selectEntry(path: selectPath) }
        else if selectFirst { controller.selectFirstEntry() }
    }

    /// 排障用（v181）：按路径/文件名选中某一条并加载预览。
    /// 本机合成点击在系统权限弹窗挡住列表时点不中，靠深链把要核对的那一条稳定选中。
    func selectEntry(path: String, attempt: Int = 0) {
        let delay: TimeInterval = attempt == 0 ? 1.2 : 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let entry = self.model.visibleEntries.first(where: {
                $0.path == path || $0.name == path
            }) {
                self.model.selection = [entry.path]
                self.model.loadPreview(for: entry)
                Log.info("Archive", "排障：已选中 \(entry.path)")
                return
            }
            if attempt < 6 { self.selectEntry(path: path, attempt: attempt + 1) }
            else { Log.warn("Archive", "排障：找不到条目 \(path)") }
        }
    }

    /// 排障用（v171）：选中第一条并加载预览。
    /// 本机合成鼠标事件点不中 SwiftUI 列表行，靠它把「选中态」稳定复现出来截图核对。
    /// 列表是异步从 7zz 读出来的，首次 0.6s 往往还没好，所以做重试。
    func selectFirstEntry(attempt: Int = 0) {
        let delay: TimeInterval = attempt == 0 ? 1.2 : 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let first = self.model.visibleEntries.first(where: { !$0.isDirectory })
                ?? self.model.visibleEntries.first {
                self.model.selection = [first.path]
                self.model.loadPreview(for: first)
                Log.info("Archive", "排障：已选中首项 \(first.path)")
                return
            }
            if attempt < 6 { self.selectFirstEntry(attempt: attempt + 1) }
            else { Log.warn("Archive", "排障：列表始终为空，放弃选中") }
        }
    }

    private let model: ArchiveBrowserModel

    init(url: URL) {
        self.model = ArchiveBrowserModel(url: url)
        let hosting = NSHostingController(rootView: ArchiveBrowserView(model: model))
        // 窗口尺寸由我们显式指定，禁止宿主视图反推窗口约束。
        // 不设的话 NSHostingController 会在首次 layout 时改窗口的约束，
        // 与 display cycle 撞上就是 _postWindowNeedsUpdateConstraints 异常（冷启动偶发崩溃）。
        hosting.sizingOptions = []
        let win = NSWindow(contentViewController: hosting)
        win.title = "归档 · \(url.lastPathComponent)"
        // 2026-11-23：按 ArcZip 1.2.5 的窗口比例（截图 1180×760 量级）给默认尺寸；
        // 内容顶到最上沿，标题行与右侧圆钮组同排（截图对齐）。
        win.setContentSize(NSSize(width: 1040, height: 660))
        win.minSize = NSSize(width: 780, height: 520)
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.isMovableByWindowBackground = true
        // v210（用户：「红绿灯被下面那行交互遮住了」）：改用全工程唯一外观入口。
        // 原因：这里原来手写 4 行（isOpaque/backgroundColor/titlebarAppearsTransparent/
        // installUnifiedGlassBackground），漏了 `titleVisibility = .hidden` ——
        // 标题栏透明后 macOS 27 会把窗口标题画到最左侧，正好压在红黄绿三钮下面
        // （截图实证：「归档 · deck…」与三钮重叠）。归档名在窗内工具栏已有，
        // 系统标题纯属重复，直接隐藏；红绿灯回归原生三钮、可正常点击。
        win.titleVisibility = .hidden
        win.applyOfficialChrome()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        model.reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// v127（ArcZip P0）：草稿未保存关窗 → 「是否保存对 ×× 的修改？」
    /// 保存 → 写回归档后再关（updateEntry 异步）；不保存 → 直接关；取消 → 不关。
    /// 关窗清理仍只在 windowWillClose（Self.open 一处，不重复移除）。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.dirty else { return true }
        let name = model.previewEntry?.name ?? model.url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "是否保存对「\(name)」的修改？"
        alert.informativeText = "「保存」把改动写回归档后关闭；「不保存」丢弃本次修改。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.saveDraft { [weak self] ok in
                if ok, self?.model.dirty == false { self?.window?.close() }
            }
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    public func windowWillClose(_ notification: Notification) {
        model.cleanupPreviewTemps()
        Self.open.removeValue(forKey: model.url.standardizedFileURL.path)
        ArchiveHoverPreview.shared.windowClosed(archive: model.url, lastWindow: Self.open.isEmpty)
    }

    // v127（ArcZip P0）：菜单路径的 undo:/redo:（Edit 菜单发到本控制器时走撤销栈）
    @objc public func undo(_ sender: Any?) { model.undoStack.undo() }
    @objc public func redo(_ sender: Any?) { model.undoStack.redo() }
}

// MARK: 视图

struct ArchiveBrowserView: View {
    @Environment(\.colorScheme) private var colorScheme

    @ObservedObject var model: ArchiveBrowserModel
    /// v180：任务按钮角标（运行中 + 等待），让「有任务在跑」在窗口里可见
    @ObservedObject private var taskQueue = ArchiveTaskQueue.shared
    @Stored private var columnWidth: CGFloat = 340
    /// 展开大预览（检查器画布点开；文本编辑仍走这里）
    @Stored private var expandPreview = false

    var body: some View {
        VStack(spacing: 0) {
            // 2026-11-23（ArcZip 1.2.5 对齐）：标题行与右侧控件同排；下方路径胶囊；
            // 内容区右侧是检查器（详情 + 预览画布）；底部一条操作条。
            ArchiveTitleBar(
                title: model.url.lastPathComponent,
                dirty: model.dirty,
                searchText: $model.searchText,
                mode: $model.viewMode,
                onSave: { model.saveDraft() },
                onDelete: { model.deleteSelected() },
                canDelete: !model.selection.isEmpty && model.editable,
                canSave: model.editable && model.dirty
            )
            ArchivePathBar(
                crumbs: model.breadcrumbs,
                currentPath: model.currentPath,
                canGoBack: model.canGoBack,
                canGoForward: model.canGoForward,
                onBack: { model.goBack() },
                onForward: { model.goForward() },
                onUp: { model.goUp() },
                onSelect: { model.navigateTo($0) }
            )
            Divider()
            HStack(spacing: 0) {
                browserPane
                    .frame(minWidth: 420, maxWidth: .infinity)
                Divider()
                ArchiveInspectorPanel(content: ArchiveInspectorContent(model: model)) {
                    if let entry = model.previewEntry { model.openExternally(entry) }
                } onExpandPreview: {
                    expandPreview = true
                }
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 780, minHeight: 520)
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.windowSurface)
        .sheet(isPresented: $expandPreview) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(model.previewEntry?.name ?? "预览")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("完成") { expandPreview = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                Divider()
                previewPane
            }
            .frame(width: 780, height: 560)
        }
        .onChange(of: model.selection) { sel in
            // v127：单选才载预览；多选/清空走摘要
            if sel.count == 1, let path = sel.first,
               let entry = model.visibleEntries.first(where: { $0.path == path }) {
                model.loadPreview(for: entry)
            } else {
                model.clearPreview()
            }
        }
    }

    // MARK: 派生状态（底部操作条 / 检查器共用）

    private var undoTitle: String {
        model.undoStack.canUndo ? "撤销 \(model.undoStack.undoLabel)" : "撤销"
    }

    private var redoTitle: String {
        model.undoStack.canRedo ? "重做 \(model.undoStack.redoLabel)" : "重做"
    }

    /// 文本类条目在可编辑归档里才允许「保存草稿」
    private var editableSelection: Bool {
        guard let entry = model.previewEntry else { return false }
        if entry.isDirectory { return false }
        if case .text = model.previewKind { return model.editable }
        return false
    }

    // MARK: 底部操作条（ArcZip Mini 同款：左侧状态，右侧胶囊按钮）

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(statusSummary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.dirty {
                Button {
                    model.saveDraft()
                } label: {
                    Text("保存")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }

            ArchiveCircleButton(symbol: "arrow.uturn.backward", size: 26, help: undoTitle) {
                model.undoStack.undo()
            }
            .disabled(!model.undoStack.canUndo)
            .opacity(model.undoStack.canUndo ? 1 : 0.4)

            ArchiveCircleButton(symbol: "arrow.uturn.forward", size: 26, help: redoTitle) {
                model.undoStack.redo()
            }
            .disabled(!model.undoStack.canRedo)
            .opacity(model.undoStack.canRedo ? 1 : 0.4)

            Menu {
                Button("全部解压…") { model.extractAll() }
                Button("解压所选项目…") { model.extractSelected() }
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("添加文件…") { model.pickAndAddFiles() }
                Button("删除所选项目") { model.deleteSelected() }
                    .disabled(model.selection.isEmpty || !model.editable)
                Toggle("显示辅助文件", isOn: $model.showAuxiliary)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.cardFill))
                    .overlay { Circle().strokeBorder(Theme.hairlineColor, lineWidth: 1) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)

            Button {
                if model.selection.isEmpty { model.extractAll() } else { model.extractSelected() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").font(.system(size: 10))
                    Text(model.selection.isEmpty ? "全部解压" : "解压所选")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help(model.selection.isEmpty ? "解压全部项目" : "解压所选项目")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.bar)
    }

    private var statusSummary: String {
        var text = "共 \(model.entries.count) 项"
        if !model.selection.isEmpty { text += " · 已选 \(model.selection.count) 项" }
        if !model.editable { text += " · 只读" }
        if model.loading { text += " · 正在读取…" }
        return text
    }

    // MARK: 左栏（列表 / 图标 / 分栏）

    @ViewBuilder private var browserPane: some View {
        VStack(spacing: 0) {
            if model.loading {
                Spacer(); ProgressView(); Spacer()
            } else if model.visibleEntries.isEmpty {
                emptyState
            } else {
                switch model.viewMode {
                case .list:
                    entryHeader
                    Divider()
                    ArchiveEntryTableRepresentable(model: model)
                case .icons:
                    iconGrid
                case .columns:
                    columnBrowser
                }
            }
        }
    }

    private var entryHeader: some View {
        HStack(spacing: 6) {
            Text("名称")
                .padding(.leading, 32)          // 让开 16pt 图标 + 间距，与行内文字对齐
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("大小").frame(width: 76, alignment: .trailing)
            Text("修改日期").frame(width: 132, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    private var emptyState: some View {
        Group {
            if model.searchText.isEmpty && model.currentPath.isEmpty {
                ArchiveEmptyDropCard { model.pickAndAddFiles() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: model.searchText.isEmpty ? "folder" : "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(model.searchText.isEmpty ? "此文件夹为空" : "无匹配条目")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !model.currentPath.isEmpty && model.searchText.isEmpty {
                        Button("返回上一层") { model.goUp() }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: 分栏视图（ArcZip 第三档：按层级横向排列）

    private var columnBrowser: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(model.columnTrail.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(column.entries) { entry in
                                    Button {
                                        if entry.isDirectory {
                                            model.navigateTo(entry.path, recordHistory: true)
                                        } else {
                                            model.selection = [entry.path]
                                            model.loadPreview(for: entry)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: ArchiveFormat.symbol(entry.name,
                                                                                   isDirectory: entry.isDirectory))
                                                .font(.system(size: 12))
                                                .foregroundStyle(entry.isDirectory ? Theme.accent : .secondary)
                                                .frame(width: 16)
                                            Text(entry.name)
                                                .font(.system(size: 12))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 0)
                                            if entry.isDirectory {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 8, weight: .semibold))
                                                    .foregroundStyle(Theme.tertiaryText)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(height: 26)
                                        .background(model.selection.contains(entry.path)
                                                    ? Theme.State.selected(isDark: colorScheme == .dark)
                                                    : Color.clear)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(width: 220)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Theme.hairlineColor).frame(width: 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // v127（ArcZip P1）：图标视图（LazyVGrid + 缩略图磁贴；点选/右键/双击/拖出在 AppKit 层）
    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 10)],
                spacing: 12
            ) {
                ForEach(model.visibleEntries) { entry in
                    ArchiveEntryTile(entry: entry, archivePath: model.url.path, size: 64)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(model.selection.contains(entry.path)
                                      ? Theme.State.selected(isDark: colorScheme == .dark)
                                      : Color.clear)
                        )
                        .overlay {
                            ArchiveTileInteraction(model: model, entry: entry)
                        }
                        // v258：图标视图也要「悬停 1 秒预览」——列表走 NSTableView 的
                        // NSTrackingArea，图标走 SwiftUI onHover，两条入口共用同一个
                        // ArchiveHoverPreview（1.0s 延迟 / LRU 缓存 / 关窗清理都在那边）。
                        .onHover { hovering in
                            if hovering {
                                ArchiveHoverPreview.shared.schedule(archive: model.url, entry: entry)
                            } else {
                                ArchiveHoverPreview.shared.cancel()
                            }
                        }
                        .help(entry.path)
                }
            }
            .padding(10)
        }
    }

    // MARK: 预览

    @ViewBuilder private var previewPane: some View {
        if model.previewLoading {
            VStack { ProgressView("正在读取…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch model.previewKind {
            case .none:
                VStack(spacing: 8) {
                    Image(systemName: model.selection.count > 1
                          ? "checkmark.circle" : "doc.text.magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.tertiaryText)
                    // v127：多选摘要
                    Text(model.selection.count > 1
                         ? "已选 \(model.selection.count) 项"
                         : "选一个条目预览")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("文本类可直接修改并「保存到归档」；Office/PDF 走 QuickLook 预览")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let text):
                // v181：文本预览与剪贴板预览同口径（Markdown 排版 / JSON 检视器 / 代码行号 / 纯文本）；
                // 可编辑的归档额外提供「预览 ↔ 编辑」开关，编辑态沿用原来的纯文本编辑器。
                ArchiveTextPreview(
                    entryName: model.previewEntry?.name ?? "",
                    editable: model.editable,
                    draft: $model.draftText,
                    dirty: model.dirty,
                    restoreKey: model.url.standardizedFileURL.absoluteString + "#" + (model.previewEntry?.path ?? ""),
                    onEdit: { new in model.dirty = (new != text) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .image(let img):
                VStack(spacing: 8) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(12)
                    Text(model.previewEntry?.sizeText ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .pdf(let doc):
                PDFViewRepresentable(document: doc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .html(let fileURL, let root):
                // v210：网页用真浏览器内核渲染（相对资源已随同目录解出）
                ArchiveHTMLPreview(fileURL: fileURL, rootDirectory: root,
                                   entryName: model.previewEntry?.name ?? "网页")
                    .id(fileURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .office(let tempURL):
                // v256：QLPreviewView 的 preview 通道——docx/pptx/xlsx/pages/key 可翻页看正文，
                // 与面板内联文档预览（DocumentInlinePreview）共用同一实现。
                VStack(spacing: 0) {
                    DocumentInlinePreview(url: tempURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 8) {
                        Text("Office 不做框内编辑（与原版一致）· 可翻页查看全文")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                        Spacer(minLength: 6)
                        Button("用默认应用打开") {
                            if let entry = model.previewEntry { model.openExternally(entry) }
                        }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(.bar)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unsupported(let msg):
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash").font(.system(size: 24)).foregroundStyle(Theme.tertiaryText)
                    Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let entry = model.previewEntry, !entry.isDirectory {
                        Button("解压并用默认应用打开") { model.openExternally(entry) }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }
}

// MARK: - AppKit 表格包一层

struct ArchiveEntryTableRepresentable: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel

    func makeNSView(context: Context) -> ArchiveEntryTableHost {
        let host = ArchiveEntryTableHost()
        host.model = model
        return host
    }

    func updateNSView(_ nsView: ArchiveEntryTableHost, context: Context) {
        nsView.model = model
        nsView.menuActions.model = model
        nsView.syncFromModel()
    }
}

/// PDFKit 包装
private struct PDFViewRepresentable: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = document
        return v
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document { nsView.document = document }
    }
}

// MARK: - 条目详情条（v170）

/// 归档窗口右栏底部的检查器：选中条目后显示「这是什么」。
///
/// 对应 ArcZip 用例 UC-06（检查器）。原实现只有内容预览，没有元信息，
/// 用户看到内容却不知道大小/压缩率/压缩方法/时间。
/// 默认展开，收起后只留一行标题——不干扰预览。
struct ArchiveInspectorBar: View {

    let entry: ArchiveEntry

    @Stored private var expanded = true

    private var ratioText: String? {
        guard entry.size > 0, entry.packedSize > 0 else { return nil }
        let pct = Int((Double(entry.packedSize) / Double(entry.size)) * 100)
        return "\(pct)%"
    }

    private func sizeText(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    private func row(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: mono ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("详情")
                        .font(.system(size: 11, weight: .medium))
                    if entry.isEncrypted {
                        Image(systemName: "lock.fill").font(.system(size: 9))
                    }
                    if entry.isUnsafe {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("展开 / 收起条目详情")

            if expanded {
                VStack(spacing: 3) {
                    row("名称", entry.name)
                    if !entry.parent.isEmpty {
                        row("位置", entry.parent, mono: true)
                    }
                    row("原始大小", sizeText(entry.size))
                    if !entry.isDirectory, entry.packedSize > 0 {
                        let suffix = ratioText.map { "（\($0)）" } ?? ""
                        row("压缩后", sizeText(entry.packedSize) + suffix)
                    }
                    if !entry.method.isEmpty {
                        row("方法", entry.method, mono: true)
                    }
                    if !entry.modified.isEmpty {
                        row("修改时间", entry.modified)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(Theme.cardFill)
    }
}

// MARK: - 检查器内容映射（模型 → 视图数据）
//
// 检查器视图只吃值类型，窗口负责把 model 拍平成 ArchiveInspectorContent：
// 这样画布可以脱离窗口渲染（离线核对样式），也避免视图直接读模型状态。

extension ArchiveInspectorContent {
    init(model: ArchiveBrowserModel) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        if model.selection.count > 1 {
            let total = model.selectedEntries.reduce(Int64(0)) { $0 + $1.size }
            self = ArchiveInspectorContent(
                kind: .multi,
                headerTitle: "多选详情",
                name: "已选 \(model.selection.count) 项",
                subtitle: "合计 \(formatter.string(fromByteCount: total))",
                rows: [("项目", "\(model.selection.count)")],
                preview: .symbol("square.stack.3d.up"),
                canOpenExternally: false
            )
            return
        }

        if let entry = model.previewEntry, model.selection.count == 1 {
            var rows: [(String, String)] = [("大小", formatter.string(fromByteCount: entry.size))]
            if entry.packedSize > 0 {
                rows.append(("压缩后", formatter.string(fromByteCount: entry.packedSize)))
                if entry.size > 0 {
                    let pct = Int((Double(entry.packedSize) / Double(entry.size)) * 100)
                    rows.append(("压缩率", "\(pct)%"))
                }
            }
            if !entry.modified.isEmpty { rows.append(("修改日期", entry.modified)) }
            if entry.isEncrypted { rows.append(("加密", "是")) }

            let preview: ArchiveInspectorContent.Preview
            switch model.previewKind {
            case .none:
                preview = .symbol(ArchiveFormat.symbol(entry.name, isDirectory: entry.isDirectory))
            case .text(let text):
                preview = .text(text)
            case .image(let image):
                preview = .image(image)
            case .pdf(let doc):
                preview = .pdf(doc)
            case .html:
                preview = .placeholder("safari")
            case .office:
                preview = .placeholder("doc.richtext")
            case .unsupported:
                preview = .unsupported
            }

            self = ArchiveInspectorContent(
                kind: .entry,
                headerTitle: entry.isDirectory ? "文件夹详情" : "文件详情",
                name: entry.name,
                subtitle: entry.isDirectory ? "文件夹" : ArchiveFormat.fileType(entry.name),
                rows: rows,
                preview: preview,
                canOpenExternally: !entry.isDirectory
            )
            return
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: model.url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified: String = {
            guard let date = attrs?[.modificationDate] as? Date else { return "—" }
            let f = DateFormatter()
            f.dateFormat = "yyyy/M/d HH:mm"
            return f.string(from: date)
        }()
        let encrypted = model.entries.contains { $0.isEncrypted }

        self = ArchiveInspectorContent(
            kind: .archive,
            headerTitle: "压缩包详情",
            name: model.url.lastPathComponent,
            subtitle: ArchiveFormat.describe(model.url),
            rows: [
                ("大小", formatter.string(fromByteCount: size)),
                ("项目", "\(model.entries.count)"),
                ("加密", encrypted ? "是" : "否"),
                ("修改日期", modified),
            ],
            preview: .none,
            canOpenExternally: false
        )
    }
}
