import AppKit
import Combine
import Foundation
import SwiftUI

public enum FavoriteResourceKind: String, CaseIterable {
    case clipboard, transferFile, tool, command, searchResult
}

public struct FavoriteReference: Identifiable, Hashable {
    public let kind: FavoriteResourceKind
    public let resourceID: String
    public let addedAt: Double
    public var id: String { "\(kind.rawValue):\(resourceID)" }
}

/// 非剪贴板资源只保存类型与稳定 ID；剪贴板继续以 clipboard_items.is_favorite 为唯一数据源。
public final class FavoritesStore: ObservableObject {
    public static let shared = FavoritesStore()

    @Published public private(set) var keys = Set<String>()
    public static let didChangeNotification = Notification.Name("Kitnest.Favorites.didChange")
    private let database = DatabaseManager.shared.clipboard
    private let queue = DispatchQueue(label: "kitnest.favorites", qos: .utility)

    private init() { refresh() }

    public func contains(_ kind: FavoriteResourceKind, id: String) -> Bool {
        keys.contains("\(kind.rawValue):\(id)")
    }

    public func set(_ kind: FavoriteResourceKind, id: String, favorite: Bool) {
        queue.async {
            do {
                if favorite {
                    try self.database.run("INSERT OR IGNORE INTO resource_favorites(resource_type,resource_id,added_at) VALUES(?,?,?)",
                                          [.text(kind.rawValue), .text(id), .real(Date().timeIntervalSince1970)])
                } else {
                    try self.database.run("DELETE FROM resource_favorites WHERE resource_type=? AND resource_id=?",
                                          [.text(kind.rawValue), .text(id)])
                }
                self.publish(kind, id: id, favorite: favorite)
            } catch {
                DispatchQueue.main.async {
                    Toast.show("收藏状态未保存：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true)
                }
            }
        }
    }

    @discardableResult
    public func setClipboard(dedupeKey: String, favorite: Bool) -> Bool {
        do {
            try database.transaction { db in
                guard try db.scalarInt("SELECT COUNT(*) FROM clipboard_items WHERE dedupe_key=?", [.text(dedupeKey)]) > 0 else {
                    throw DatabaseError(message: "剪贴板条目已不存在")
                }
                try db.run("UPDATE clipboard_items SET is_favorite=? WHERE dedupe_key=?",
                           [.int(favorite ? 1 : 0), .text(dedupeKey)])
                if favorite {
                    try db.run("INSERT OR IGNORE INTO resource_favorites(resource_type,resource_id,added_at) VALUES('clipboard',?,?)",
                               [.text(dedupeKey), .real(Date().timeIntervalSince1970)])
                } else {
                    try db.run("DELETE FROM resource_favorites WHERE resource_type='clipboard' AND resource_id=?",
                               [.text(dedupeKey)])
                }
            }
            publish(.clipboard, id: dedupeKey, favorite: favorite)
            return true
        } catch {
            Log.error("clipboard", "收藏状态保存失败: \(error.localizedDescription)")
            return false
        }
    }

    public func clipboardRemoved(_ dedupeKey: String) {
        publish(.clipboard, id: dedupeKey, favorite: false)
    }

    private func publish(_ kind: FavoriteResourceKind, id: String, favorite: Bool) {
        DispatchQueue.main.async {
            var next = self.keys
            let key = "\(kind.rawValue):\(id)"
            if favorite { next.insert(key) } else { next.remove(key) }
            if next != self.keys { self.keys = next }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    public func toggle(_ kind: FavoriteResourceKind, id: String) {
        queue.async {
            do {
                var nextFavorite = false
                try self.database.transaction { db in
                    nextFavorite = try db.scalarInt(
                        "SELECT COUNT(*) FROM resource_favorites WHERE resource_type=? AND resource_id=?",
                        [.text(kind.rawValue), .text(id)]) == 0
                    if nextFavorite {
                        try db.run("INSERT OR IGNORE INTO resource_favorites(resource_type,resource_id,added_at) VALUES(?,?,?)",
                                   [.text(kind.rawValue), .text(id), .real(Date().timeIntervalSince1970)])
                    } else {
                        try db.run("DELETE FROM resource_favorites WHERE resource_type=? AND resource_id=?",
                                   [.text(kind.rawValue), .text(id)])
                    }
                }
                self.publish(kind, id: id, favorite: nextFavorite)
            } catch {
                DispatchQueue.main.async {
                    Toast.show("收藏状态未保存：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true)
                }
            }
        }
    }

    public func removeMissing(_ reference: FavoriteReference) {
        set(reference.kind, id: reference.resourceID, favorite: false)
    }

    private func referencesOnQueue() -> [FavoriteReference] {
        (try? database.query("SELECT resource_type,resource_id,added_at FROM resource_favorites ORDER BY added_at DESC") { row in
            guard let raw = row.string("resource_type"),
                  let kind = FavoriteResourceKind(rawValue: raw),
                  let id = row.string("resource_id") else { return nil as FavoriteReference? }
            return FavoriteReference(kind: kind, resourceID: id, addedAt: row.real("added_at"))
        }.compactMap { $0 }) ?? []
    }

    public func loadContents(completion: @escaping ([ClipboardItem], [FavoriteReference]) -> Void) {
        queue.async {
            let items = ClipboardRepository.shared.fetch(ClipboardQuery(favoriteOnly: true, limit: 1000))
            let references = self.referencesOnQueue()
            DispatchQueue.main.async { completion(items, references) }
        }
    }

    public func refresh() {
        queue.async {
            let loaded: [String] = (try? self.database.query("SELECT resource_type,resource_id FROM resource_favorites") { row -> String? in
                guard let type = row.string("resource_type"), let id = row.string("resource_id") else { return nil as String? }
                return "\(type):\(id)"
            }.compactMap { $0 }) ?? []
            DispatchQueue.main.async {
                let next = Set<String>(loaded)
                if self.keys != next { self.keys = next }
            }
        }
    }
}

private struct FavoriteEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let open: () -> Void
    let remove: () -> Void
}

public final class FavoritesWindowController {
    public static let shared = FavoritesWindowController()
    private var window: NSWindow?

    private init() {}

    public func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = "收藏"
        panel.isReleasedWhenClosed = false
        panel.applyOfficialChrome()
        panel.contentView = NSHostingView(rootView: FavoritesView())
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct FavoritesView: View {
    @Stored private var entries: [FavoriteEntry] = []
    @Stored private var searchText = ""
    @Stored private var reloadGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索收藏", text: $searchText)
                .textFieldStyle(.roundedBorder).padding(10)
            if visibleEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(entries.isEmpty ? "暂无收藏" : "没有匹配项").font(.headline)
                    Text("剪贴板、文件、工具、命令和网页可从各自入口加入收藏。")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleEntries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.symbol).foregroundStyle(Theme.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            if !entry.detail.isEmpty { Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        Button(action: entry.open) { Image(systemName: "arrow.up.right") }
                            .buttonStyle(.plain).help("打开或执行")
                        Button(action: entry.remove) { Image(systemName: "star.slash") }
                            .buttonStyle(.plain).help("取消收藏")
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: FavoritesStore.didChangeNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: ClipboardManager.itemsDidChangeNotification)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .localTransferDidChange)) { _ in reload() }
    }

    private var visibleEntries: [FavoriteEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }

    @MainActor private func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        FavoritesStore.shared.loadContents { items, references in
            guard generation == reloadGeneration else { return }
            rebuildEntries(items: items, references: references)
        }
    }

    @MainActor private func rebuildEntries(items: [ClipboardItem], references: [FavoriteReference]) {
        var next: [FavoriteEntry] = []
        for item in items {
            let title = item.aliasTitle ?? item.title ?? item.content?.firstLineBrief ?? item.type.rawValue
            next.append(FavoriteEntry(id: "clipboard:\(item.dedupeKey)", title: title,
                                      detail: "剪贴板 · \(item.sourceApp ?? "")", symbol: "doc.on.clipboard",
                                      open: { ClipboardManager.shared.copy(item, autoPaste: false) },
                                      remove: { ClipboardManager.shared.toggleFavorite(item) }))
        }

        let selection: AppBootstrap.SelectionResult = .failure(.init(message: ""))
        let commands = CommandCatalog.build(selection: selection) + CommandCatalog.buildSlash()
        for reference in references {
            switch reference.kind {
            case .clipboard:
                continue
            case .transferFile:
                guard let file = LocalTransferStore.shared.items.first(where: { $0.id == reference.resourceID }) else {
                    FavoritesStore.shared.removeMissing(reference); continue
                }
                next.append(FavoriteEntry(id: reference.id, title: file.name, detail: "文件中转 · \(file.sizeText)",
                                          symbol: "doc", open: { LocalTransferStore.shared.open(file) },
                                          remove: { FavoritesStore.shared.set(reference.kind, id: reference.resourceID, favorite: false) }))
            case .tool:
                guard let tool = ToolRegistry.tool(id: reference.resourceID) else {
                    FavoritesStore.shared.removeMissing(reference); continue
                }
                next.append(FavoriteEntry(id: reference.id, title: tool.name, detail: "工具 · \(tool.category.title)",
                                          symbol: tool.systemImage, open: { ToolRunnerWindowController.shared.show(toolID: tool.identifier) },
                                          remove: { FavoritesStore.shared.set(reference.kind, id: reference.resourceID, favorite: false) }))
            case .command:
                guard let command = commands.first(where: { $0.id == reference.resourceID }) else {
                    FavoritesStore.shared.removeMissing(reference); continue
                }
                next.append(FavoriteEntry(id: reference.id, title: command.title, detail: command.subtitle,
                                          symbol: command.systemImage, open: command.handler,
                                          remove: { FavoritesStore.shared.set(reference.kind, id: reference.resourceID, favorite: false) }))
            case .searchResult:
                guard let url = URL(string: reference.resourceID) else {
                    FavoritesStore.shared.removeMissing(reference); continue
                }
                if url.isFileURL {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        FavoritesStore.shared.removeMissing(reference); continue
                    }
                    next.append(FavoriteEntry(id: reference.id, title: url.lastPathComponent,
                                              detail: url.deletingLastPathComponent().path, symbol: "doc",
                                              open: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                                              remove: { FavoritesStore.shared.set(reference.kind, id: reference.resourceID, favorite: false) }))
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    next.append(FavoriteEntry(id: reference.id, title: url.host ?? url.absoluteString,
                                              detail: url.path, symbol: "safari", open: { NSWorkspace.shared.open(url) },
                                              remove: { FavoritesStore.shared.set(reference.kind, id: reference.resourceID, favorite: false) }))
                } else {
                    FavoritesStore.shared.removeMissing(reference)
                }
            }
        }
        entries = next
    }
}
