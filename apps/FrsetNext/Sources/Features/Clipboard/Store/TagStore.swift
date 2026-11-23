import Foundation

// MARK: - 标签仓储（tags + clipboard_item_tags，05 号规格 B6）

/// 标签总管：CRUD + 分配 + 内存索引。
/// 说明：`tags.name` 上有 `UNIQUE COLLATE NOCASE`，重名插入会抛约束错误，
/// 这里捕获后返回同名既有标签（等价于 NSUniqueConstraint 的幂等 upsert 行为）。
public final class TagStore: ObservableObject {

    public static let shared = TagStore()
    public static let didChangeNotification = Notification.Name("FrsetNext.Clipboard.tagsDidChange")
    public static let manageRequestedNotification = Notification.Name("FrsetNext.Clipboard.manageTagsRequested")

    @Published public private(set) var tags: [Tag] = []
    /// v286：标签分组（名称/颜色/排序）。删组只解绑，不删记录。
    @Published public private(set) var groups: [TagGroup] = []

    private let db: SQLiteDatabase = DatabaseManager.shared.clipboard
    /// dedupeKey -> tagID 列表（内存索引，避免每行一次 SQL）
    private var mapping: [String: [String]] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: 加载

    public func refresh(notifying: Bool = false) {
        db.accessLock.lock(); defer { db.accessLock.unlock() }
        do {
            // v286：分组先行（标签按组排序展示），旧库无 group_id 列时已由迁移补上。
            let groupRows = try db.query("SELECT id, name, color_hex, sort_order, created_at, updated_at FROM tag_groups ORDER BY sort_order, created_at")
            let loadedGroups = groupRows.map { row -> TagGroup in
                TagGroup(id: row.string("id") ?? UUID().uuidString,
                         name: row.string("name") ?? "",
                         colorHex: row.string("color_hex") ?? "#8E8E93",
                         sortOrder: Int(row.int("sort_order")),
                         createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                         updatedAt: Date(timeIntervalSince1970: row.real("updated_at")))
            }
            let rows = try db.query("SELECT id, name, color_hex, created_at, updated_at, group_id, sort_order FROM tags")
            var loadedTags = rows.map { row -> Tag in
                Tag(id: row.string("id") ?? UUID().uuidString,
                    name: row.string("name") ?? "",
                    colorHex: row.string("color_hex") ?? "#8E8E93",
                    createdAt: Date(timeIntervalSince1970: row.real("created_at")),
                    updatedAt: Date(timeIntervalSince1970: row.real("updated_at")),
                    groupID: row.string("group_id"),
                    sortOrder: Int(row.int("sort_order")))
            }
            // 组内按 sort_order，无组的排最后按更新时间（展示口径，原始 tags 数组顺序即 UI 顺序）
            let groupRank = Dictionary(uniqueKeysWithValues: loadedGroups.enumerated().map { ($1.id, $0) })
            loadedTags.sort {
                let l = $0.groupID.map { groupRank[$0] ?? Int.max } ?? Int.max
                let r = $1.groupID.map { groupRank[$0] ?? Int.max } ?? Int.max
                if l != r { return l < r }
                if $0.groupID != nil, $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.updatedAt > $1.updatedAt
            }
            let linkRows = try db.query(#"SELECT item_dedupe_key, tag_id FROM clipboard_item_tags"#)
            var loadedMapping: [String: [String]] = [:]
            for row in linkRows {
                guard let key = row.string("item_dedupe_key"), let tagID = row.string("tag_id") else { continue }
                loadedMapping[key, default: []].append(tagID)
            }
            lock.lock()
            self.mapping = loadedMapping
            lock.unlock()
            let publish = { [weak self] in
                guard let self else { return }
                self.groups = loadedGroups
                self.tags = loadedTags
                if notifying { self.postChange(["mappingReplaced": true]) }
            }
            if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
        } catch {
            Log.error("clipboard", "标签加载失败: \(error)")
        }
    }

    /// 给查询出来的条目填充 tagIDs（批量，无 N+1）
    public func attachTags(to items: inout [ClipboardItem]) {
        guard !items.isEmpty else { return }
        // v126（性能审计 F0769）：去掉整表快照复制。
        // 原实现 `let snapshot = mapping` 在每次 fetch（首页 200 条）都把整个
        // [dedupeKey: [tagID]] 字典做一次值语义拷贝；改为持锁就地查表，
        // 拷贝量从 O(mapping 全表) 降为 0（锁内只做 items.count 次字典查找）。
        lock.lock()
        for index in items.indices {
            items[index].tagIDs = mapping[items[index].dedupeKey] ?? []
        }
        lock.unlock()
    }

    // MARK: 写

    @discardableResult
    public func create(name: String, colorHex: String = "#8E8E93") -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let tag = Tag(name: trimmed, colorHex: colorHex, createdAt: now, updatedAt: now)
        do {
            try db.run("INSERT INTO tags(id, name, color_hex, created_at, updated_at) VALUES (?,?,?,?,?)",
                       [.text(tag.id), .text(tag.name), .text(tag.colorHex),
                        .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            publishTags { $0.append(tag) }
            return tag
        } catch {
            // 重名（NOCASE）→ 返回既有标签
            Log.info("clipboard", "标签重名，复用既有: \(trimmed)")
            return tags.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        }
    }

    @discardableResult
    public func rename(id: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !tags.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }
        let updatedAt = Date()
        do {
            try db.run("UPDATE tags SET name = ?, updated_at = ? WHERE id = ?",
                       [.text(trimmed), .real(updatedAt.timeIntervalSince1970), .text(id)])
            publishTags { tags in
                guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
                tags[index].name = trimmed
                tags[index].updatedAt = updatedAt
                tags.sort { $0.updatedAt > $1.updatedAt }
            }
            return true
        } catch {
            Log.error("clipboard", "标签重命名失败: \(error)")
            return false
        }
    }


    public func delete(id: String) {
        do {
            try db.run("DELETE FROM tags WHERE id = ?", [.text(id)])
            lock.lock()
            let affectedKeys = mapping.compactMap { key, values in values.contains(id) ? key : nil }
            for key in affectedKeys {
                mapping[key]?.removeAll { $0 == id }
                if mapping[key]?.isEmpty == true { mapping.removeValue(forKey: key) }
            }
            lock.unlock()
            publishTags(["keys": affectedKeys, "tagID": id, "removed": true]) { tags in
                tags.removeAll { $0.id == id }
            }
        } catch {
            Log.error("clipboard", "标签删除失败: \(error)")
        }
    }

    // MARK: 分配

    public func assign(tagID: String, toDedupeKey key: String) {
        lock.lock()
        let alreadyAssigned = (mapping[key] ?? []).contains(tagID)
        lock.unlock()
        guard !alreadyAssigned else { return }
        do {
            try db.run("INSERT OR IGNORE INTO clipboard_item_tags(item_dedupe_key, tag_id, created_at) VALUES (?,?,?)",
                       [.text(key), .text(tagID), .real(Date().timeIntervalSince1970)])
            // v126（性能审计 F0769）：增量维护内存索引，免去全表 refresh。
            // 原实现每次分配/取消都 reload tags 全表 + clipboard_item_tags 全表（主线程 UI 动作触发），
            // 而 assign/unassign 只改一条关联行、tags 列表根本没变——直接就地更新 mapping 即可。
            lock.lock()
            var list = mapping[key] ?? []
            if !list.contains(tagID) { list.append(tagID) }
            mapping[key] = list
            lock.unlock()
            postChange(["keys": [key], "tagID": tagID, "assigned": true])
        } catch {
            // 失败时不做增量（保持 mapping 与库一致），下次 refresh 兜底
            Log.warn("clipboard", "标签分配失败: \(error)")
        }
    }

    public func unassign(tagID: String, fromDedupeKey key: String) {
        lock.lock()
        let isAssigned = (mapping[key] ?? []).contains(tagID)
        lock.unlock()
        guard isAssigned else { return }
        do {
            try db.run("DELETE FROM clipboard_item_tags WHERE item_dedupe_key = ? AND tag_id = ?", [.text(key), .text(tagID)])
            // v126（性能审计 F0769）：同 assign，增量摘除代替全表 refresh
            lock.lock()
            if var list = mapping[key] {
                list.removeAll { $0 == tagID }
                if list.isEmpty { mapping.removeValue(forKey: key) } else { mapping[key] = list }
            }
            lock.unlock()
            postChange(["keys": [key], "tagID": tagID, "assigned": false])
        } catch {
            Log.warn("clipboard", "标签取消失败: \(error)")
        }
    }

    /// 成功删除条目后同步移除内存标签关联。
    func removeMapping(for key: String) {
        lock.lock()
        mapping.removeValue(forKey: key)
        lock.unlock()
    }

    /// 菜单勾选用：已分配则取消，否则分配
    public func toggle(tagID: String, dedupeKey: String) {
        lock.lock()
        let already = (mapping[dedupeKey] ?? []).contains(tagID)
        lock.unlock()
        if already { unassign(tagID: tagID, fromDedupeKey: dedupeKey) }
        else { assign(tagID: tagID, toDedupeKey: dedupeKey) }
    }

    public func tagIDs(forDedupeKey key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return mapping[key] ?? []
    }

    // MARK: 分组（v286 剪贴板三栏）

    @discardableResult
    public func createGroup(name: String, colorHex: String = "#8E8E93") -> TagGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = TagGroup(name: trimmed, colorHex: colorHex,
                             sortOrder: (groups.map(\.sortOrder).max() ?? -1) + 1)
        do {
            try db.run("INSERT INTO tag_groups(id,name,color_hex,sort_order,created_at,updated_at) VALUES(?,?,?,?,?,?)",
                       [.text(group.id), .text(group.name), .text(group.colorHex), .int(Int64(group.sortOrder)),
                        .real(group.createdAt.timeIntervalSince1970), .real(group.updatedAt.timeIntervalSince1970)])
            publishTags(["groupsChanged": true]) { _ in }
            refresh()
            return group
        } catch {
            Log.error("clipboard", "分组创建失败: \(error)")
            return nil
        }
    }

    public func renameGroup(id: String, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try db.run("UPDATE tag_groups SET name=?, updated_at=? WHERE id=?",
                       [.text(trimmed), .real(Date().timeIntervalSince1970), .text(id)])
            publishTags(["groupsChanged": true]) { _ in }
            refresh()
            return true
        } catch {
            Log.error("clipboard", "分组重命名失败: \(error)")
            return false
        }
    }

    public func setGroupColor(id: String, colorHex: String) {
        do {
            try db.run("UPDATE tag_groups SET color_hex=?, updated_at=? WHERE id=?",
                       [.text(colorHex), .real(Date().timeIntervalSince1970), .text(id)])
            publishTags(["groupsChanged": true]) { _ in }
            refresh()
        } catch {
            Log.error("clipboard", "分组颜色保存失败: \(error)")
        }
    }

    /// 删组：只把成员标签解绑（group_id → NULL），剪贴板记录与标签本身全部保留。
    public func deleteGroup(id: String) {
        do {
            try db.transaction { db in
                try db.run("UPDATE tags SET group_id=NULL, sort_order=0, updated_at=? WHERE group_id=?",
                           [.real(Date().timeIntervalSince1970), .text(id)])
                try db.run("DELETE FROM tag_groups WHERE id=?", [.text(id)])
            }
            publishTags(["groupsChanged": true, "groupRemoved": id]) { _ in }
            refresh()
        } catch {
            Log.error("clipboard", "分组删除失败: \(error)")
        }
    }

    /// 移动标签到分组（nil = 移出分组）。不动标签名与关联记录。
    public func setGroup(tagID: String, groupID: String?) {
        do {
            try db.run("UPDATE tags SET group_id=?, updated_at=? WHERE id=?",
                       [groupID.map { SQLiteValue.text($0) } ?? .null,
                        .real(Date().timeIntervalSince1970), .text(tagID)])
            publishTags(["tagsChanged": true, "tagID": tagID]) { tags in
                guard let index = tags.firstIndex(where: { $0.id == tagID }) else { return }
                tags[index].groupID = groupID
            }
        } catch {
            Log.error("clipboard", "标签分组移动失败: \(error)")
        }
    }

    /// 组内/全局标签排序（按给定 id 顺序重写 sort_order）。
    public func reorderTags(_ orderedTagIDs: [String]) {
        do {
            try db.transaction { db in
                for (index, tagID) in orderedTagIDs.enumerated() {
                    try db.run("UPDATE tags SET sort_order=? WHERE id=?", [.int(Int64(index)), .text(tagID)])
                }
            }
            publishTags(["tagsChanged": true]) { tags in
                let rank = Dictionary(uniqueKeysWithValues: orderedTagIDs.enumerated().map { ($1, $0) })
                for index in tags.indices where rank[tags[index].id] != nil {
                    tags[index].sortOrder = rank[tags[index].id]!
                }
            }
        } catch {
            Log.error("clipboard", "标签排序失败: \(error)")
        }
    }

    /// 分组排序（按给定 id 顺序重写 sort_order）。
    public func reorderGroups(_ orderedGroupIDs: [String]) {
        do {
            try db.transaction { db in
                for (index, groupID) in orderedGroupIDs.enumerated() {
                    try db.run("UPDATE tag_groups SET sort_order=? WHERE id=?", [.int(Int64(index)), .text(groupID)])
                }
            }
            publishTags(["groupsChanged": true]) { _ in }
            refresh()
        } catch {
            Log.error("clipboard", "分组排序失败: \(error)")
        }
    }

    private func publishTags(_ info: [String: Any] = ["tagsChanged": true],
                             _ update: @escaping (inout [Tag]) -> Void) {
        let apply = { [weak self] in
            guard let self else { return }
            update(&self.tags)
            self.postChange(info)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func postChange(_ userInfo: [String: Any]) {
        let post = { NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: userInfo) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

}
