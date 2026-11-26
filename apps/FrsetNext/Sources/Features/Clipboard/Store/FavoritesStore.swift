import AppKit
import Combine
import Foundation
import SwiftUI

public enum FavoriteResourceKind: String, CaseIterable {
    case clipboard, tool, command, searchResult
}

public struct FavoriteReference: Identifiable, Hashable {
    public let kind: FavoriteResourceKind
    public let resourceID: String
    public let addedAt: Double
    public var id: String { "\(kind.rawValue):\(resourceID)" }
}

/// 非剪贴板资源只保存类型与稳定 ID；剪贴板继续以 clipboard_items.is_favorite 为兼容字段，
/// 真实等级存 resource_favorites.level（0 未收藏 / 1 普通 / 2 重要 / 3 置顶），
/// 两处写入在同一事务内保持一致（level>0 ⇔ is_favorite=1）。
public final class FavoritesStore: ObservableObject {
    public static let shared = FavoritesStore()

    @Published public private(set) var keys = Set<String>()
    /// v286：收藏等级表（"kind:id" → 0...3）。keys 仍然存在（level>0 的键集），
    /// 旧调用方的 contains/布尔语义完全兼容。
    @Published public private(set) var levels = [String: Int]()
    public static let didChangeNotification = Notification.Name("Kitnest.Favorites.didChange")
    private let database = DatabaseManager.shared.clipboard
    private let queue = DispatchQueue(label: "kitnest.favorites", qos: .utility)

    private init() { refresh() }

    public func contains(_ kind: FavoriteResourceKind, id: String) -> Bool {
        keys.contains("\(kind.rawValue):\(id)")
    }

    /// 当前收藏等级（0 = 未收藏）。
    public func level(_ kind: FavoriteResourceKind, id: String) -> FavoriteLevel {
        FavoriteLevel(rawValue: levels["\(kind.rawValue):\(id)"] ?? 0) ?? .none
    }

    public func set(_ kind: FavoriteResourceKind, id: String, favorite: Bool) {
        set(kind, id: id, level: favorite ? .normal : .none)
    }

    /// v286 分级收藏主入口：0 取消（删行），1...3 写等级（INSERT OR REPLACE 保留 added_at 首次值）。
    public func set(_ kind: FavoriteResourceKind, id: String, level: FavoriteLevel) {
        queue.async {
            do {
                if level == .none {
                    try self.database.run("DELETE FROM resource_favorites WHERE resource_type=? AND resource_id=?",
                                          [.text(kind.rawValue), .text(id)])
                } else {
                    try self.database.run(
                        "INSERT INTO resource_favorites(resource_type,resource_id,added_at,level) VALUES(?,?,?,?) " +
                        "ON CONFLICT(resource_type,resource_id) DO UPDATE SET level=excluded.level",
                        [.text(kind.rawValue), .text(id), .real(Date().timeIntervalSince1970), .int(Int64(level.rawValue))])
                }
                self.publish(kind, id: id, level: level)
            } catch {
                DispatchQueue.main.async {
                    Toast.show("收藏状态未保存：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true)
                }
            }
        }
    }

    @discardableResult
    public func setClipboard(dedupeKey: String, favorite: Bool) -> Bool {
        setClipboard(dedupeKey: dedupeKey, level: favorite ? .normal : .none)
    }

    /// v286：剪贴板分级收藏（事务内同步 is_favorite 兼容字段）。
    @discardableResult
    public func setClipboard(dedupeKey: String, level: FavoriteLevel) -> Bool {
        do {
            try database.transaction { db in
                guard try db.scalarInt("SELECT COUNT(*) FROM clipboard_items WHERE dedupe_key=?", [.text(dedupeKey)]) > 0 else {
                    throw DatabaseError(message: "剪贴板条目已不存在")
                }
                try db.run("UPDATE clipboard_items SET is_favorite=? WHERE dedupe_key=?",
                           [.int(level == .none ? 0 : 1), .text(dedupeKey)])
                if level == .none {
                    try db.run("DELETE FROM resource_favorites WHERE resource_type='clipboard' AND resource_id=?",
                               [.text(dedupeKey)])
                } else {
                    try db.run(
                        "INSERT INTO resource_favorites(resource_type,resource_id,added_at,level) VALUES('clipboard',?,?,?) " +
                        "ON CONFLICT(resource_type,resource_id) DO UPDATE SET level=excluded.level",
                        [.text(dedupeKey), .real(Date().timeIntervalSince1970), .int(Int64(level.rawValue))])
                }
            }
            publish(.clipboard, id: dedupeKey, level: level)
            return true
        } catch {
            Log.error("clipboard", "收藏状态保存失败: \(error.localizedDescription)")
            return false
        }
    }

    public func clipboardRemoved(_ dedupeKey: String) {
        publish(.clipboard, id: dedupeKey, level: .none)
    }

    private func publish(_ kind: FavoriteResourceKind, id: String, level: FavoriteLevel) {
        DispatchQueue.main.async {
            let key = "\(kind.rawValue):\(id)"
            var next = self.keys
            var nextLevels = self.levels
            if level == .none {
                next.remove(key)
                nextLevels.removeValue(forKey: key)
            } else {
                next.insert(key)
                nextLevels[key] = level.rawValue
            }
            if next != self.keys { self.keys = next }
            if nextLevels != self.levels { self.levels = nextLevels }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil,
                                            userInfo: ["kind": kind.rawValue, "id": id, "level": level.rawValue])
        }
    }

    public func toggle(_ kind: FavoriteResourceKind, id: String) {
        queue.async {
            do {
                var nextLevel: FavoriteLevel = .none
                try self.database.transaction { db in
                    let current = try db.scalarInt(
                        "SELECT COALESCE(level,0) FROM resource_favorites WHERE resource_type=? AND resource_id=?",
                        [.text(kind.rawValue), .text(id)])
                    nextLevel = current > 0 ? .none : .normal
                    if nextLevel == .none {
                        try db.run("DELETE FROM resource_favorites WHERE resource_type=? AND resource_id=?",
                                   [.text(kind.rawValue), .text(id)])
                    } else {
                        try db.run("INSERT INTO resource_favorites(resource_type,resource_id,added_at,level) VALUES(?,?,?,?) " +
                                   "ON CONFLICT(resource_type,resource_id) DO UPDATE SET level=excluded.level",
                                   [.text(kind.rawValue), .text(id), .real(Date().timeIntervalSince1970), .int(Int64(nextLevel.rawValue))])
                    }
                }
                self.publish(kind, id: id, level: nextLevel)
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

    /// 批量移除失效收藏（2026-11-26 修复，low）：
    /// 原实现每发现一条失效收藏就 set() 一次，而每次 set() 都会 post 一次
    /// didChangeNotification → 收藏窗 reload → 再全量重建（含 CommandCatalog），
    /// 靠「每轮至少删掉一条」收敛。这里一次事务删完、只发一次通知。
    public func removeMissing(_ references: [FavoriteReference]) {
        guard !references.isEmpty else { return }
        queue.async {
            do {
                try self.database.transaction { db in
                    for reference in references {
                        try db.run("DELETE FROM resource_favorites WHERE resource_type=? AND resource_id=?",
                                   [.text(reference.kind.rawValue), .text(reference.resourceID)])
                    }
                }
            } catch {
                Log.error("favorites", "清理失效收藏失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    Toast.show("清理失效收藏失败：\(error.localizedDescription)",
                               icon: "exclamationmark.triangle", isWarning: true)
                }
                return
            }
            DispatchQueue.main.async {
                var next = self.keys
                var nextLevels = self.levels
                for reference in references {
                    next.remove(reference.id)
                    nextLevels.removeValue(forKey: reference.id)
                }
                if next != self.keys { self.keys = next }
                if nextLevels != self.levels { self.levels = nextLevels }
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil,
                                                userInfo: ["batchRemoved": references.count])
            }
        }
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
            let loaded: [(String, Int)] = (try? self.database.query("SELECT resource_type,resource_id,COALESCE(level,1) AS level FROM resource_favorites") { row -> (String, Int)? in
                guard let type = row.string("resource_type"), let id = row.string("resource_id") else { return nil }
                return ("\(type):\(id)", Int(row.int("level")))
            }.compactMap { $0 }) ?? []
            DispatchQueue.main.async {
                var nextLevels = [String: Int]()
                for (key, level) in loaded { nextLevels[key] = level }
                let next = Set(nextLevels.keys)
                if self.keys != next { self.keys = next }
                if self.levels != nextLevels { self.levels = nextLevels }
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
        // 2026-11-26 修复：失效收藏先收集，循环结束再一次性批量移除（不再边遍历边写库）
        var missing: [FavoriteReference] = []
        for item in items {
            let title = item.aliasTitle ?? item.title ?? item.content?.firstLineBrief ?? item.type.rawValue
            next.append(FavoriteEntry(id: "clipboard:\(item.dedupeKey)", title: title,
                                      detail: "剪贴板 · \(item.sourceApp ?? "")", symbol: "doc.on.clipboard",
                                      open: { ClipboardManager.shared.copy(item, autoPaste: false) },
                                      remove: { ClipboardManager.shared.toggleFavorite(item) }))
        }

        let commands = references.contains(where: { $0.kind == .command })
            ? CommandCatalog.build(selection: .failure(.init(message: ""))) + CommandCatalog.buildSlash()
            : []
        for reference in references {
            switch reference.kind {
            case .clipboard:
                continue
            case .tool:
                guard let tool = ToolRegistry.tool(id: reference.resourceID) else {
                    missing.append(reference); continue
                }
                next.append(FavoriteEntry(id: reference.id, title: tool.name, detail: "工具 · \(tool.category.title)",
                                          symbol: tool.systemImage, open: { ToolRunnerWindowController.shared.show(toolID: tool.identifier) },
                                          remove: { FavoritesStore.shared.set(reference.kind, id: reference.resourceID, favorite: false) }))
            case .command:
                guard let command = commands.first(where: { $0.id == reference.resourceID }) else {
                    missing.append(reference); continue
                }
                next.append(FavoriteEntry(id: reference.id, title: command.title, detail: command.subtitle,
                                          symbol: command.systemImage, open: command.handler,
                                          remove: { FavoritesStore.shared.set(reference.kind, id: reference.resourceID, favorite: false) }))
            case .searchResult:
                guard let url = URL(string: reference.resourceID) else {
                    missing.append(reference); continue
                }
                if url.isFileURL {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        missing.append(reference); continue
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
                    missing.append(reference)
                }
            }
        }
        // 2026-11-26 修复（low）：渲染派生过程里不写库——失效项先收集，函数末尾一次提交。
        // 原实现每发现一条就 removeMissing 一次，每次都触发收藏窗 reload → 本函数重跑
        //（含 CommandCatalog 全量重建），靠「每轮至少删一条」往复收敛。
        if !missing.isEmpty { FavoritesStore.shared.removeMissing(missing) }
        entries = next
    }
}
