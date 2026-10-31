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
    }

    @Published public private(set) var entries: [ArchiveEntry] = []
    @Published public private(set) var loading = false
    @Published public var errorText: String?
    /// v127（ArcZip P1）：多选（List/表格/图标网格统一用 Set）
    @Published public var selection: Set<String> = []
    @Published public private(set) var previewKind: PreviewKind = .none
    @Published public private(set) var previewLoading = false
    /// v127：当前预览/编辑中的条目（多选时也明确在编辑哪一个）
    @Published public private(set) var previewEntry: ArchiveEntry?
    @Published public var draftText: String = ""
    @Published public var dirty = false
    @Published public var searchText: String = ""
    /// v124：是否显示 `__MACOSX` / `.DS_Store` 等辅助文件（默认隐藏）
    @Published public var showAuxiliary = false
    /// v127（ArcZip P1）：当前层级（"" = 根）
    @Published public var currentPath: String = ""

    public let url: URL
    public var editable: Bool { ArchiveCore.isEditable(url) }
    /// v127（ArcZip P0）：撤销/重做栈
    public let undoStack: ArchiveUndoStack
    /// ⇧ 连选锚点（图标视图手动多选用；表格由 NSTableView 自己管）
    public var selectionAnchor: String?

    public init(url: URL) {
        self.url = url
        self.undoStack = ArchiveUndoStack(url: url)
        self.undoStack.onApplied = { [weak self] in
            guard let self else { return }
            self.reload()
            // 编辑类撤销后预览内容要跟着回退
            if let entry = self.previewEntry {
                self.loadPreview(for: entry)
            }
        }
    }

    // MARK: 层级 / 过滤

    /// 当前层级的直接子项（+ 为「无显式目录条目」的中间目录合成虚拟文件夹）；
    /// 搜索时跳过层级过滤，全量匹配
    public var visibleEntries: [ArchiveEntry] {
        let list = showAuxiliary ? entries : entries.filter { !ArchiveCore.isAuxiliary($0.path) }
        guard searchText.isEmpty else {
            return list.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
        return children(in: list, of: currentPath)
    }

    /// v127（ArcZip P1）：某目录的直接子项。zip 可以没有显式目录条目（7zz -slt 只列文件
    /// 路径，实测），按深层路径补出中间文件夹，否则这些文件在层级视图里「消失」。
    private func children(in list: [ArchiveEntry], of dir: String) -> [ArchiveEntry] {
        let direct = list.filter { $0.parent == dir }
        var known = Set(list.filter { $0.isDirectory }.map { $0.path })
        var extra: [ArchiveEntry] = []
        let prefix = dir.isEmpty ? "" : dir + "/"
        for e in list where !e.isDirectory && e.path.hasPrefix(prefix) && e.path.count > prefix.count {
            let rest = e.path.dropFirst(prefix.count)
            guard let slash = rest.firstIndex(of: "/") else { continue }
            let dirName = String(rest[..<slash])
            let dirPath = dir.isEmpty ? dirName : dir + "/" + dirName
            if !known.contains(dirPath) {
                known.insert(dirPath)
                extra.append(ArchiveEntry(path: dirPath, name: dirName, size: 0, packedSize: 0,
                                          modified: "", method: "", isDirectory: true, parent: dir))
            }
        }
        return (direct + extra).sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
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

    public func navigateTo(_ path: String) {
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

    /// v127（ArcZip P1）：返回上一层（⌘[）
    public func goBack() {
        guard !currentPath.isEmpty else { return }
        navigateTo((currentPath as NSString).deletingLastPathComponent)
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
        // 文本类：直接读内容（可编辑）
        if FilePreviewBuilder.textExtensions.contains(ext) || ext.isEmpty {
            ArchiveCore.readEntry(url: url, entry: entry) { [weak self] data, err in
                guard let self else { return }
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
                guard let self else { return }
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
            guard let self else { return }
            guard let tempURL else {
                self.previewLoading = false
                self.previewKind = .unsupported(err)
                return
            }
            if ext == "pdf", let doc = PDFDocument(url: tempURL) {
                self.previewLoading = false
                self.previewKind = .pdf(doc)
                return
            }
            // Office：QL 缩略图（首页）+ 保留临时文件供「用默认应用打开」
            let req = QLThumbnailGenerator.Request(fileAt: tempURL,
                                                   size: CGSize(width: 900, height: 900),
                                                   scale: 2,
                                                   representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                DispatchQueue.main.async {
                    self.previewLoading = false
                    self.previewKind = .office(tempURL)
                    if let img = rep?.nsImage {
                        self.officeThumb = img
                    }
                }
            }
        }
    }

    @Published public var officeThumb: NSImage?

    // MARK: 编辑 / 回写

    /// 保存当前文本条目回归档
    /// v123（用户明确要求）：**直接覆盖原压缩包，不再生成 .bak 副本**。
    /// `7zz a -y` 本身就是打开原包原地更新，路径不变、不产生新文件。
    /// v127（ArcZip P0）：保存前的旧文本进撤销栈（undo=写回旧文本）。
    public func saveDraft(completion: ((Bool) -> Void)? = nil) {
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
        ArchiveCore.updateEntry(url: url, entryPath: entry.path, localFile: tmp) { [weak self] ok, msg in
            try? FileManager.default.removeItem(at: tmp)
            guard let self else { return }
            if ok {
                // v127（ArcZip P0）：可撤销；同时把预览基线挪到新文本（连续两次保存的
                // 旧文本才不会记错）
                if newText != oldText {
                    self.undoStack.push(.editText(path: entry.path, oldText: oldText, newText: newText))
                }
                self.previewKind = .text(newText)
                self.dirty = false
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
            performAddFiles(withSuggestedNames(files))
        case .alertSecondButtonReturn:
            performAddFiles(files)
        default:
            return
        }
    }

    /// 用建议名继续：问题文件复制到临时目录换名（原磁盘文件不动）；全量名单去重防撞名
    ///（`a:b` 与 `a?b` 都会变成 `a_b`，撞名加序号——用 arch-engine 的 uniqueWindowsNames）
    private func withSuggestedNames(_ files: [URL]) -> [URL] {
        var suggestions: [String: String] = [:]
        for issue in ArchiveCore.windowsNameIssues(files.map { $0.lastPathComponent }) {
            suggestions[issue.name] = issue.suggested
        }
        let finalNames = ArchiveCore.uniqueWindowsNames(
            files.map { suggestions[$0.lastPathComponent] ?? $0.lastPathComponent })
        var out: [URL] = []
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
            } catch {
                out.append(f)       // 换名失败 → 保持原名
            }
        }
        return out
    }

    private func performAddFiles(_ files: [URL]) {
        let dir: String
        if let entry = selectedEntries.first, entry.isDirectory {
            dir = entry.path
        } else {
            dir = currentPath
        }
        ArchiveCore.addFiles(url: url, files: files, intoDirectory: dir) { [weak self] ok, msg in
            guard let self else { return }
            if ok {
                // v127（ArcZip P0）：新增内容备份 → 可撤销（undo=removeEntries）
                self.captureAddeds(files, into: dir) { snaps in
                    if !snaps.isEmpty {
                        self.undoStack.push(.add(items: snaps))
                    }
                }
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
                    self.clearPreview()
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
                Toast.show(msg, icon: "pencil")
                self.reload()
            } else {
                self.errorText = msg
            }
        }
    }

    /// 解压全部（含辅助文件过滤按 ArchiveCore 默认）
    public func extractAll() {
        guard let dir = pickExtractDirectory() else { return }
        ArchiveCore.extract(url: url, entry: nil, to: dir) { ok, msg in
            Toast.show(ok ? "已解压" : "解压失败：\(msg)",
                       icon: ok ? "archivebox" : "exclamationmark.triangle", isWarning: !ok)
        }
    }

    /// v127（ArcZip P1）：解压所有选中项（逐个解到同一目录；目录路径子树级提取，实测）
    public func extractSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        guard let dir = pickExtractDirectory() else { return }
        extractSequential(targets, 0, to: dir, failures: [])
    }

    private func extractSequential(_ targets: [ArchiveEntry], _ index: Int,
                                   to dir: URL, failures: [String]) {
        guard index < targets.count else {
            if failures.isEmpty {
                Toast.show(targets.count == 1 ? "已解压" : "已解压 \(targets.count) 项", icon: "archivebox")
            } else {
                Toast.show("解压完成（\(failures.count) 项失败）：\(failures.first ?? "")",
                           icon: "exclamationmark.triangle", isWarning: true)
            }
            return
        }
        ArchiveCore.extract(url: url, entry: targets[index].path, to: dir) { ok, msg in
            var fails = failures
            if !ok { fails.append(msg) }
            self.extractSequential(targets, index + 1, to: dir, failures: fails)
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
            NSWorkspace.shared.open(tempURL)
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
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-addsnap-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(f.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: f, to: tmp)
                snaps.append(.init(path: rel, tempURL: tmp))
            } catch {
                // 备份失败 → 该项不可撤销，跳过
            }
        }
        completion(snaps)
    }
}

// MARK: 窗口

public final class ArchiveBrowserWindowController: NSWindowController, NSWindowDelegate {

    private static var open: [String: ArchiveBrowserWindowController] = [:]

    public static func show(url: URL) {
        let key = url.standardizedFileURL.path
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ArchiveBrowserWindowController(url: url)
        open[key] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let model: ArchiveBrowserModel

    init(url: URL) {
        self.model = ArchiveBrowserModel(url: url)
        let hosting = NSHostingController(rootView: ArchiveBrowserView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "归档 · \(url.lastPathComponent)"
        win.setContentSize(NSSize(width: 860, height: 560))
        win.minSize = NSSize(width: 640, height: 420)
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        model.reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// v127（ArcZip P0）：草稿未保存关窗 → 「是否保存对 ×× 的修改？」
    /// 保存 → 写回归档后再关（updateEntry 异步）；不保存 → 直接关；取消 → 不关。
    /// 关窗清理仍只在 windowWillClose（Self.open 一处，不重复移除）。
    /// v127 接线（arch-engine P2-1）：先过未完成归档任务的退出保护，再查草稿。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard ArchiveTaskQueue.shared.confirmQuitIfNeeded() else { return false }
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
                if ok { self?.window?.close() }
            }
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    public func windowWillClose(_ notification: Notification) {
        Self.open.removeValue(forKey: model.url.standardizedFileURL.path)
    }

    // v127（ArcZip P0）：菜单路径的 undo:/redo:（Edit 菜单发到本控制器时走撤销栈）
    @objc public func undo(_ sender: Any?) { model.undoStack.undo() }
    @objc public func redo(_ sender: Any?) { model.undoStack.redo() }
}

// MARK: 视图

struct ArchiveBrowserView: View {

    @ObservedObject var model: ArchiveBrowserModel
    @Stored private var columnWidth: CGFloat = 340
    /// v127（ArcZip P1）：列表 ↔ 图标视图（@AppStorage 跨窗口记住）
    @AppStorage("archiveBrowserViewMode") private var iconView = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            breadcrumbBar
            // v127（ArcZip P3-3）：Flow 智能推荐条——按压缩包内容推断此刻最合适的操作
            // （含 .app→装应用 / 字体→装字体 / 单文件→打开 / 多图→解压图片 / .dmg→挂载）
            ArchiveFlowBar(entries: model.entries, url: model.url, selected: model.selectedEntries)
            Divider()
            HSplitView {
                browserPane
                    .frame(minWidth: 260, idealWidth: columnWidth)
                previewPane
                    .frame(minWidth: 320)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
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

    // MARK: 工具栏

    private var undoTitle: String {
        model.undoStack.canUndo ? "撤销 \(model.undoStack.undoLabel)" : "撤销"
    }

    private var redoTitle: String {
        model.undoStack.canRedo ? "重做 \(model.undoStack.redoLabel)" : "重做"
    }

    private var subtitle: String {
        var text = "共 \(model.entries.count) 项\(model.editable ? " · 可编辑" : " · 只读")"
        if !model.selection.isEmpty {
            text += " · 已选 \(model.selection.count) 项"
        }
        return text
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.url.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // v127（ArcZip P1）：列表 ↔ 图标视图切换
            Picker("", selection: $iconView) {
                Image(systemName: "list.bullet").tag(false).help("列表视图")
                Image(systemName: "square.grid.2x2").tag(true).help("图标视图")
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            // v124：辅助文件显隐开关（ArcZip「显示辅助文件开关」）
            Toggle("辅助文件", isOn: $model.showAuxiliary)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("__MACOSX / .DS_Store / Thumbs.db / desktop.ini / ._* ")
            TextField("搜索条目", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            // v127（ArcZip P0）：撤销/重做（⌘Z / ⇧⌘Z），标题即「撤销 %@」
            Button(undoTitle) { model.undoStack.undo() }
                .disabled(!model.undoStack.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销上一次修改（⌘Z）")
            Button(redoTitle) { model.undoStack.redo() }
                .disabled(!model.undoStack.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("重做（⇧⌘Z）")
            Button("解压全部") { model.extractAll() }
            Button("添加文件") { model.pickAndAddFiles() }
            Button("重命名") { model.renameSelected() }
                .disabled(model.selection.isEmpty)
                .help("多选时只重命名第一个")
            Button("删除") { model.deleteSelected() }
                .disabled(model.selection.isEmpty)
                .help("删除所有选中项（可撤销）")
            Button("保存到归档") { model.saveDraft() }
                .disabled(!model.dirty || !editableSelection)
                .keyboardShortcut("s", modifiers: .command)
            if model.editable {
                Button("另存加密…") { model.saveEncryptedCopy() }
                    .help("把整个归档另存为带密码的新归档（v124）")
            }
            // v127 接线（arch-engine P2-1）：归档任务进度窗（解压/压缩队列）
            Button {
                ArchiveProgressWindowController.toggle()
            } label: {
                Image(systemName: "list.bullet.rectangle.portrait")
            }
            .help("归档任务进度（解压/压缩队列）")
            if let err = model.errorText {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(err)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var editableSelection: Bool {
        guard let entry = model.previewEntry else { return false }
        if entry.isDirectory { return false }
        if case .text = model.previewKind { return model.editable }
        return false
    }

    // MARK: 面包屑（v127（ArcZip P1）：根 / docs / images，每段可点 + 返回 ⌘[）

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(model.currentPath.isEmpty)
            .keyboardShortcut("[", modifiers: .command)
            .help("返回上一层（⌘[）")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.breadcrumbs.indices, id: \.self) { index in
                        let seg = model.breadcrumbs[index]
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        Button(seg.name) {
                            model.navigateTo(seg.path)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: seg.path == model.currentPath
                                      ? .semibold : .regular))
                        .foregroundStyle(seg.path == model.currentPath
                                         ? Theme.accent : Color.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if model.selection.count > 1 {
                Text("已选 \(model.selection.count) 项")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: 左栏（列表 / 图标）

    @ViewBuilder private var browserPane: some View {
        VStack(spacing: 0) {
            if !iconView {
                entryHeader
                Divider()
            }
            if model.loading {
                Spacer(); ProgressView(); Spacer()
            } else if model.visibleEntries.isEmpty {
                emptyState
            } else if iconView {
                iconGrid
            } else {
                // v127（ArcZip P0/P1）：AppKit 表格——原生多选/双击/多承诺拖出
                ArchiveEntryTableRepresentable(model: model)
            }
        }
    }

    private var entryHeader: some View {
        HStack(spacing: 4) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("大小").frame(width: 64, alignment: .trailing)
            Text("压缩率").frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.searchText.isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(Theme.tertiaryText)
            Text(model.searchText.isEmpty ? "此文件夹为空" : "无匹配条目")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !model.currentPath.isEmpty && model.searchText.isEmpty {
                Button("返回上一层") { model.goBack() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.selection.contains(entry.path)
                                      ? Theme.accent.opacity(0.18)
                                      : Color.clear)
                        )
                        .overlay {
                            ArchiveTileInteraction(model: model, entry: entry)
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
                VStack(spacing: 0) {
                    HStack {
                        Text("文本 · \(model.previewEntry?.name ?? "")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if model.editable {
                            Text(model.dirty ? "未保存" : "已同步")
                                .font(.system(size: 11))
                                .foregroundStyle(model.dirty ? .orange : .secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    Divider()
                    TextEditor(text: $model.draftText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(6)
                        .onChange(of: model.draftText) { new in
                            model.dirty = (new != text)
                        }
                }
            case .image(let img):
                VStack(spacing: 8) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(12)
                    Text(model.previewEntry?.sizeText ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .pdf(let doc):
                PDFViewRepresentable(document: doc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .office(let tempURL):
                VStack(spacing: 8) {
                    if let thumb = model.officeThumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(12)
                    } else {
                        ProgressView().padding()
                    }
                    HStack(spacing: 8) {
                        Text("Office 文档不做框内编辑（与原版一致）")
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                        Button("用默认应用打开") { NSWorkspace.shared.open(tempURL) }
                            .controlSize(.small)
                    }
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
