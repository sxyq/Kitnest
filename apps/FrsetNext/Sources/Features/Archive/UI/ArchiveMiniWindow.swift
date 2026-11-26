import AppKit
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - ArcZip Mini 独立小窗（v127（ArcZip P3）：P3-1）
//
// 从深链 `kitnest://archive?path=xxx&action=mini` 打开时用 Mini 小窗浏览压缩包，
// 不打断主窗口。能力：条目网格浏览、置顶图钉、拖出即解压、一键切换完整界面。
//
// v127（ArcZip P3）：入口现状说明——FinderSync 扩展 / QuickLook 扩展在本构建系统下
// 不可行（build.sh 直接 swiftc 编译 Sources/**，无 app extension target 与 provisioning），
// 因此「从 Finder 双击/QuickLook 唤起 Mini」只能由宿主侧深链或后续插件调用
// `ArchiveMiniWindowController.show(url:)` 完成；本文件提供完整的窗口能力本体。
//
// 依赖约定：只读调用 ArchiveCore（列条目/解压）与 ArchiveBrowserWindowController.show
// （切换完整界面）；不修改 Archive 模块任何既有文件。

// MARK: - 拖出载荷（拖到 Finder 自动解压该条目）

/// v127（ArcZip P3）：Mini 条目的拖出载荷——拖动开始后按需解压到临时目录，
/// Finder 拿到的是解出的真实文件（「拖动解压」语义）。
struct MiniEntryDragPayload: Transferable {
    let archiveURL: URL
    let entry: ArchiveEntry

    static var transferRepresentation: some TransferRepresentation {
        // 导出内容类型用 .data（通用文件）；目标按 SentTransferredFile 的真实扩展名落地。
        // 若后续要更精确的类型提示，可改为按 entry 扩展名动态构造（需要包装 struct）。
        FileRepresentation(exportedContentType: .data) { payload in
            let tempURL: URL = try await withCheckedThrowingContinuation { cont in
                ArchiveCore.extractEntryToTemp(url: payload.archiveURL, entry: payload.entry) { url, err in
                    if let url {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(throwing: NSError(domain: "FrsetNext.ArchiveMini", code: 1,
                                                      userInfo: [NSLocalizedDescriptionKey: err]))
                    }
                }
            }
            // 2026-11-26 修复（二轮 low）：系统落地的是拷贝，源临时目录原本没人清理——
            // 每拖出一次就泄漏一个 frset-archive-<UUID> 目录。Transferable 没有「传输完成」
            // 回调，故交付后延迟一段时间（60s，足够系统完成拷贝）整目录删除。
            let extractionDir = ArchiveCore.extractionDirectory(containing: tempURL)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
                try? FileManager.default.removeItem(at: extractionDir)
            }
            return SentTransferredFile(tempURL)
        }
    }
}

// MARK: - 简化版条目 tile（v127（ArcZip P3）：自带图标映射，不依赖浏览窗/缩略图模块）

private enum MiniFileIcon {
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)
    private static let genericIcon = NSWorkspace.shared.icon(for: .data)

    static func icon(for entry: ArchiveEntry) -> NSImage {
        if entry.isDirectory { return folderIcon }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let ut = UTType(filenameExtension: ext) else { return genericIcon }
        return NSWorkspace.shared.icon(for: ut)
    }
}

/// Mini 行（ArcZip 1.2.5 截图：图标 16 + 名称 12 + 右对齐大小 11，行高 28）
struct MiniEntryRow: View {
    let archiveURL: URL
    let entry: ArchiveEntry
    var onOpen: (ArchiveEntry) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Stored private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: MiniFileIcon.icon(for: entry))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(entry.sizeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(hovering ? Theme.insetFill : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen(entry) }
        .draggable(MiniEntryDragPayload(archiveURL: archiveURL, entry: entry))
        .help(entry.path)
    }
}

// MARK: - Mini 窗模型

final class ArchiveMiniModel: ObservableObject {
    let url: URL
    @Published var entries: [ArchiveEntry] = []
    @Published var listError: String?
    @Published var loading = true
    /// v127（ArcZip P3）：置顶图钉状态； didSet 直接作用到窗口层级
    @Published var isPinned = false {
        didSet {
            window?.level = isPinned ? .floating : .normal
        }
    }
    weak var window: NSWindow?

    init(url: URL) {
        self.url = url
    }

    var title: String { url.lastPathComponent }

    func reload() {
        loading = true
        ArchiveCore.list(url: url) { [weak self] entries, err in
            self?.loading = false
            self?.entries = entries
            self?.listError = err
        }
    }

    /// v127（ArcZip P3）：双击条目 → 解压到临时目录后用默认应用打开
    func openEntry(_ entry: ArchiveEntry) {
        guard !entry.isDirectory else { return }
        ArchiveCore.extractEntryToTemp(url: url, entry: entry) { tempURL, err in
            if let tempURL {
                NSWorkspace.shared.open(tempURL)
            } else {
                Toast.show(err, icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// v127（ArcZip P3）：「解压到…」——选目录后整包解压
    func extractAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "解压到这里"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        ArchiveCore.extract(url: url, to: dir) { ok, msg in
            Toast.show(ok ? "已解压到 \(dir.lastPathComponent)" : "解压失败：\(msg)",
                       icon: ok ? "archivebox" : "exclamationmark.triangle",
                       isWarning: !ok)
        }
    }

    /// v127（ArcZip P3）：「完整界面」——切到浏览窗并收起 Mini（与完整界面切换）
    func openFullBrowser() {
        ArchiveBrowserWindowController.show(url: url)
        window?.close()
    }
}

// MARK: - Mini 窗内容

struct ArchiveMiniView: View {
    @ObservedObject var model: ArchiveMiniModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 400, minHeight: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ArchiveGlyph(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(ArchiveFormat.describe(model.url)) · \(model.entries.count) 个项目")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Button {
                model.isPinned.toggle()
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(model.isPinned ? Theme.accent : .secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.insetFill))
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "取消置顶" : "置顶窗口")

            HStack(spacing: 6) {
                ArchiveGlyph(size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Kitnest").font(.system(size: 10, weight: .semibold))
                    Text("Mini").font(.system(size: 9)).foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
    }

    @ViewBuilder
    private var content: some View {
        if let err = model.listError {
            VStack(spacing: 6) {
                Image(systemName: "lock.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else if model.loading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            Text("压缩包中没有项目")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedEntries, id: \.id) { entry in
                        MiniEntryRow(archiveURL: model.url, entry: entry) { model.openEntry($0) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var sortedEntries: [ArchiveEntry] {
        model.entries.filter { $0.isDirectory } + model.entries.filter { !$0.isDirectory }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ArchiveCircleButton(symbol: "arrow.up.left.and.arrow.down.right", help: "进入主工作区") {
                model.openFullBrowser()
            }
            ArchiveCircleButton(symbol: "arrow.down.to.line", help: "全部解压…") {
                model.extractAll()
            }
            Spacer(minLength: 8)
            Button {
                model.extractAll()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").font(.system(size: 10))
                    Text("解压").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help("全部解压到…")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.bar)
    }
}

// MARK: - Mini 窗口控制器

public final class ArchiveMiniWindowController: NSWindowController, NSWindowDelegate {

    // v127（ArcZip P3）：单例去重——同一压缩包同时只开一个 Mini 窗（与浏览窗同策略）
    private static var open: [String: ArchiveMiniWindowController] = [:]

    public static func show(url: URL) {
        let key = url.standardizedFileURL.path
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // v290（ArcZip mini.switch.*）：切 Mini 前的主工作区保护
        guard guardForMiniSwitch(url) else { return }
        openUnprotected(url)
    }

    /// v290：实际开窗（保护通过 / 保存完成后走这里）
    private static func openUnprotected(_ url: URL) {
        let key = url.standardizedFileURL.path
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ArchiveMiniWindowController(url: url)
        open[key] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// v290（ArcZip mini.switch.busy/save.*）：切 Mini 前检查同压缩包的主工作区——
    /// 仍有进行中任务（busy 文案）或未保存修改（保存并切换 / 放弃更改并切换 / 取消）。
    /// Mini 仅用于浏览，编辑语义必须留在主工作区。返回 false = 已拦截，不开 Mini。
    private static func guardForMiniSwitch(_ url: URL) -> Bool {
        let archiveURL = url.standardizedFileURL
        // 忙：该压缩包仍有进行中的任务（解压/压缩/回写都在任务队列记账）
        // 2026-11-26 修复（二轮 low）：原来是 task.title.contains(包名) 的裸子串匹配——
        // a.zip 会命中 aa.zip（误拦），而「写回 <包内路径>」「重命名为 x」这类标题根本不含
        // 包名（漏拦，正在写这个包时仍放行切 Mini）。现在优先用结构化字段（outputURL）
        // 判归属，标题只在「完整文件名按边界出现」时才算命中。
        if ArchiveTaskQueue.shared.tasks.contains(where: { !$0.isFinished && taskBelongs($0, to: archiveURL) }) {
            let alert = NSAlert()
            alert.messageText = "切换到 Mini"
            alert.informativeText = "此压缩包的 Mini 窗口仍有任务或待处理的操作，请完成后再切换。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return false
        }
        // 脏：主工作区有未保存修改
        guard let main = ArchiveBrowserWindowController.mainWorkspace(for: archiveURL),
              main.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "切换到 Mini 前，是否保存对“\(archiveURL.lastPathComponent)”的更改？"
        alert.informativeText = "Mini 仅用于浏览。保存更改或放弃更改后即可切换。"
        alert.addButton(withTitle: "保存并切换")
        alert.addButton(withTitle: "放弃更改并切换")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // 保存完成后切（失败时主窗已有错误提示，Mini 不强开）
            main.saveForMiniSwitch { _ in openUnprotected(url) }
            return false
        case .alertSecondButtonReturn:
            main.discardForMiniSwitch()
            return true
        default:
            return false
        }
    }

    /// 任务是否属于该压缩包（2026-11-26 新增，替换 title.contains 的启发式）
    ///
    /// ① 结构化：任务产物路径就是该压缩包（压缩/新建类任务会把 output 记成包路径）；
    /// ② 兜底：标题里以「完整文件名」为单位出现（按文件名边界切分，`a.zip` 不再命中 `aa.zip`）。
    /// 局限（诚实标注）：ArchiveTask 目前不记录所属压缩包，「写回 <包内路径>」「重命名为 x」
    /// 这类标题既无包名也无 outputURL，仍然判不出来——要彻底消除需由 ArchiveCore 入队时
    /// 带上 archiveURL，属本任务文件范围外的改动。
    private static func taskBelongs(_ task: ArchiveTaskQueue.ArchiveTask, to archiveURL: URL) -> Bool {
        if let output = task.outputURL?.standardizedFileURL, output.path == archiveURL.path {
            return true
        }
        return titleContains(task.title, filename: archiveURL.lastPathComponent)
    }

    private static func titleContains(_ title: String, filename: String) -> Bool {
        guard !filename.isEmpty else { return false }
        var searchStart = title.startIndex
        while searchStart < title.endIndex,
              let range = title.range(of: filename, range: searchStart..<title.endIndex) {
            let beforeOK = range.lowerBound == title.startIndex
                || !isFilenameCharacter(title[title.index(before: range.lowerBound)])
            let afterOK = range.upperBound == title.endIndex
                || !isFilenameCharacter(title[range.upperBound])
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isFilenameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "." || c == "-" || c == "_"
    }

    private let model: ArchiveMiniModel

    init(url: URL) {
        self.model = ArchiveMiniModel(url: url)
        let hosting = NSHostingController(rootView: ArchiveMiniView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Mini · \(url.lastPathComponent)"
        // 2026-11-23（ArcZip 1.2.5 截图）：Mini 约 520×430，列表式浏览
        win.setContentSize(NSSize(width: 520, height: 430))
        win.minSize = NSSize(width: 400, height: 340)
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.applyOfficialChrome()   // v179：与其它文档窗统一（灰底 + 透明标题栏 + 圆钮）
        super.init(window: win)
        win.delegate = self
        model.window = win
        model.reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    public func windowWillClose(_ notification: Notification) {
        Self.open.removeValue(forKey: model.url.standardizedFileURL.path)
    }
}
