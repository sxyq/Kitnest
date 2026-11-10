import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 拖出到 Finder（v127（ArcZip P0）：NSFilePromiseProvider，落点才解压）
//
// ArcZip 同款方案：拖动时只上屏「文件承诺」（名字 + UTI），真正落到 Finder 目标目录时
// 才调 7zz 解压条目——不解到中间临时目录再拷贝，大文件零双份 IO。
//
// 注意：NSFilePromiseProvider 是 `NSObject <NSPasteboardWriting>`，**不是** NSItemProvider
// 子类，SwiftUI 的 `onDrag` 塞不进去（探针实测编译不过）→ 走 AppKit 拖拽源：
//   · 列表：NSTableView 的 `pasteboardWriterForRow`（每行一个承诺，多选拖出 = N 个承诺）
//   · 图标磁贴：NSView 里 `beginDraggingSession`（N 个选中项 = N 个承诺）

/// 一条归档条目的「文件承诺」——Finder 松手时把条目解压成真实文件
final class ArchiveFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {

    let archiveURL: URL
    let entry: ArchiveEntry
    /// 解压/移动都是异步 7zz + 文件操作，丢到独立串行队列执行，不占主线程
    private let workQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.sxyq.frsetnext.archive-promise"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    init(archiveURL: URL, entry: ArchiveEntry) {
        self.archiveURL = archiveURL
        self.entry = entry
    }

    /// 承诺文件名 = 条目名（目录条目就是文件夹名）
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        entry.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        workQueue
    }

    /// Finder 松手：url 是目标文件 URL（名字已按 fileNameForType 给好）
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frset-promise-\(UUID().uuidString)", isDirectory: true)
        // 7zz x 对目录路径是子树级提取（实测）；产出在 tempDir/<entry.path>
        ArchiveCore.extract(url: archiveURL, entry: entry.path, to: tempDir) { ok, msg in
            guard ok else {
                completionHandler(NSError(domain: "FrsetArchive", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: msg]))
                return
            }
            let produced = tempDir.appendingPathComponent(self.entry.path)
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: url.path) {
                    _ = try fm.replaceItemAt(url, withItemAt: produced)
                } else {
                    try fm.moveItem(at: produced, to: url)
                }
                try? fm.removeItem(at: tempDir)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    /// 承诺 UTI：必须符合 public.data / public.folder，否则 NSFilePromiseProvider 抛异常
    static func fileType(for entry: ArchiveEntry) -> String {
        guard !entry.isDirectory else { return UTType.folder.identifier }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext), ut.conforms(to: .data) {
            return ut.identifier
        }
        return UTType.data.identifier
    }

    /// 造一个可进拖拽会话的承诺条目（delegate 挂 userInfo 强持有——provider.delegate 是 weak）
    static func makeProvider(archiveURL: URL, entry: ArchiveEntry) -> NSFilePromiseProvider {
        let delegate = ArchiveFilePromiseDelegate(archiveURL: archiveURL, entry: entry)
        let provider = NSFilePromiseProvider(fileType: fileType(for: entry), delegate: delegate)
        provider.userInfo = delegate
        return provider
    }
}

// MARK: - 归档条目右键菜单（列表 NSTableView 与图标磁贴共用）

/// NSMenu 的动作载体（target 必须是 @objc 方法的 NSObject）
final class ArchiveMenuActions: NSObject {

    weak var model: ArchiveBrowserModel?

    init(model: ArchiveBrowserModel?) {
        self.model = model
    }

    @objc func menuPreview(_ sender: Any?) {
        guard let entry = model?.selectedEntries.first else { return }
        model?.loadPreview(for: entry)
    }

    @objc func menuEnter(_ sender: Any?) {
        guard let entry = model?.selectedEntries.first, entry.isDirectory else { return }
        model?.enter(entry)
    }

    @objc func menuRename(_ sender: Any?) {
        model?.renameSelected()
    }

    @objc func menuExtract(_ sender: Any?) {
        model?.extractSelected()
    }

    @objc func menuOpenExternal(_ sender: Any?) {
        guard let entry = model?.selectedEntries.first else { return }
        model?.openExternally(entry)
    }

    @objc func menuAddHere(_ sender: Any?) {
        model?.pickAndAddFiles()
    }

    @objc func menuDelete(_ sender: Any?) {
        model?.deleteSelected()
    }

    /// 右键菜单（多选时项数语义与工具栏一致）
    func buildMenu(hasDirectory: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(make("预览", #selector(menuPreview(_:))))
        if hasDirectory {
            menu.addItem(make("进入文件夹", #selector(menuEnter(_:))))
        }
        menu.addItem(make("重命名…", #selector(menuRename(_:))))
        menu.addItem(make("解压所选…", #selector(menuExtract(_:))))
        menu.addItem(make("用默认应用打开", #selector(menuOpenExternal(_:))))
        if hasDirectory {
            menu.addItem(make("添加文件到此文件夹…", #selector(menuAddHere(_:))))
        }
        menu.addItem(.separator())
        let del = make("删除", #selector(menuDelete(_:)))
        del.tag = 1
        menu.addItem(del)
        return menu
    }

    private func make(_ title: String, _ sel: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        return item
    }
}

// MARK: - 图标磁贴交互层（v127（ArcZip P1）：点选/⌘多选/⇧连选/双击进目录/右键/拖出）

/// 盖在 ArchiveEntryTile 上的 NSView：SwiftUI 只管画，鼠标语义全在这里（AppKit 路径最稳）
final class ArchiveTileInteractionView: NSView {

    weak var model: ArchiveBrowserModel?
    var entry: ArchiveEntry?
    private var dragStart: NSPoint = .zero
    private var dragging = false
    private lazy var menuActions = ArchiveMenuActions(model: model)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragging = false
        // 双击：进目录（单击选中在 mouseUp）
        if event.clickCount == 2, let entry {
            model?.activate(entry)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragging, event.clickCount == 1, let entry else { return }
        model?.clickSelect(entry)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let model, let entry else { return }
        let dx = event.locationInWindow.x - dragStart.x
        let dy = event.locationInWindow.y - dragStart.y
        guard hypot(dx, dy) > 4 else { return }        // 阈值：区分点选与拖拽

        // 拖中选中项 → 整组拖出；拖未选中项 → 只拖它
        let targets = (model.selection.contains(entry.path) && model.selection.count > 1)
            ? model.selectedEntries
            : [entry]
        let items: [NSDraggingItem] = targets.map { e in
            let provider = ArchiveFilePromiseDelegate.makeProvider(archiveURL: model.url, entry: e)
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(bounds, contents: ArchiveFileIcon.icon(for: e))
            return item
        }
        dragging = true
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let entry else { return }
        // 右键：不在选中集里就先选中它，菜单动作作用于当前选中
        model?.contextualSelect(entry)
        menuActions.model = model
        let menu = menuActions.buildMenu(hasDirectory: entry.isDirectory)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

extension ArchiveTileInteractionView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
    }
}

/// SwiftUI 侧包一层（NSViewRepresentable）
struct ArchiveTileInteraction: NSViewRepresentable {
    @ObservedObject var model: ArchiveBrowserModel
    let entry: ArchiveEntry

    func makeNSView(context: Context) -> ArchiveTileInteractionView {
        let v = ArchiveTileInteractionView(frame: .zero)
        v.model = model
        v.entry = entry
        return v
    }

    func updateNSView(_ nsView: ArchiveTileInteractionView, context: Context) {
        nsView.model = model
        nsView.entry = entry
    }
}
