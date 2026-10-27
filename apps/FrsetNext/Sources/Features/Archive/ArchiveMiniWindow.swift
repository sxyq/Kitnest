import AppKit
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - ArcZip Mini 独立小窗（v127（ArcZip P3）：P3-1）
//
// 从深链 `frsetnext://archive?path=xxx&action=mini` 打开时用 Mini 小窗浏览压缩包，
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

/// v127（ArcZip P3）：Mini 窗专用简化 tile（图标 + 名称 + 大小，支持拖出）。
/// 与 ArchiveEntryTile 思路一致但独立实现——避免与浏览窗缩略图链路耦合。
struct MiniEntryTile: View {
    let archiveURL: URL
    let entry: ArchiveEntry
    var onOpen: (ArchiveEntry) -> Void

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: MiniFileIcon.icon(for: entry))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(entry.sizeText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(entry.path)
        // v127（ArcZip P3）：拖出即解压（MiniEntryDragPayload 按需解到临时目录）
        .draggable(MiniEntryDragPayload(archiveURL: archiveURL, entry: entry))
        .onTapGesture(count: 2) { onOpen(entry) }
    }
}

// MARK: - Mini 窗模型

final class ArchiveMiniModel: ObservableObject {
    let url: URL
    @Published var entries: [ArchiveEntry] = []
    @Published var listError: String?
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
        ArchiveCore.list(url: url) { [weak self] entries, err in
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

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 320, minHeight: 380)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(model.entries.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
            // v127（ArcZip P3）：置顶图钉按钮（状态与 window.level 同步）
            Button {
                model.isPinned.toggle()
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(model.isPinned ? Theme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "取消置顶" : "置顶（悬浮在其他窗口之上）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
        } else if model.entries.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.entries.filter { !$0.isDirectory } + model.entries.filter { $0.isDirectory },
                            id: \.id) { entry in
                        MiniEntryTile(archiveURL: model.url, entry: entry) { model.openEntry($0) }
                    }
                }
                .padding(8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button("完整界面") { model.openFullBrowser() }
                .help("切换到完整归档浏览窗口")
            Button("解压到…") { model.extractAll() }
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
        let controller = ArchiveMiniWindowController(url: url)
        open[key] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let model: ArchiveMiniModel

    init(url: URL) {
        self.model = ArchiveMiniModel(url: url)
        let hosting = NSHostingController(rootView: ArchiveMiniView(model: model))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Mini · \(url.lastPathComponent)"
        // v127（ArcZip P3）：约 360×420 的浏览专用小窗
        win.setContentSize(NSSize(width: 360, height: 420))
        win.minSize = NSSize(width: 320, height: 380)
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
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
