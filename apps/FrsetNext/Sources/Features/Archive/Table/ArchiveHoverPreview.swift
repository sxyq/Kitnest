import AppKit

// MARK: - 归档表格「悬停 1 秒」预览
//
// 为什么不能把条目路径直接交给 FileHoverPreview：条目在压缩包**里面**，
// QuickLook / DocumentInlinePreview / FilePreviewBuilder 都只认磁盘文件。
// 所以先按需解到临时目录（复用 ArchiveCore.extractEntryToTemp），再交给同一个弹窗。
//
// 缓存：最近 8 个条目（key 带归档 mtime，包一改就失效），避免来回悬停反复拉 7zz。
// 清理：淘汰时删掉整个临时目录；浏览窗关闭时 cleanup() 全清。

final class ArchiveHoverPreview {

    static let shared = ArchiveHoverPreview()

    /// 用户要的「悬浮 1 秒」——短于这个值，扫列表时会一直闪窗
    static let delay: TimeInterval = 1.0
    /// 超过 96MB 的条目不预解：解压成本远大于预览收益
    static let sizeCap: Int64 = 96 * 1024 * 1024
    private static let cacheLimit = 8

    private struct Item {
        let key: String
        let file: URL      // 解出来的文件
        let dir: URL       // 这次解压的临时目录（删除单位）
    }

    private var pending: DispatchWorkItem?
    private var generation = 0
    private var cache: [Item] = []

    // MARK: 对外

    func schedule(archive: URL, entry: ArchiveEntry) {
        generation += 1
        let gen = generation
        pending?.cancel()
        pending = nil
        // 换行了：先把上一条的预览收掉，再等 1 秒
        FileHoverPreviewController.shared.scheduleHide()

        guard !entry.isDirectory else { return }
        guard entry.size > 0, entry.size <= Self.sizeCap else { return }
        // 只解「有内容可看」的类型；未知二进制解出来也只有图标，白花一次 7zz
        guard ArchiveEntryThumbnail.canRender(entry.name) else { return }

        let key = Self.key(archive: archive, entry: entry)
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            // 按住鼠标（拖动 / 多选）时不弹
            guard NSEvent.pressedMouseButtons == 0 else { return }
            if let hit = self.cached(key) {
                FileHoverPreviewController.shared.showNow(url: hit)
                return
            }
            ArchiveCore.extractEntryToTemp(url: archive, entry: entry) { [weak self] tmp, _ in
                guard let self else { return }
                guard gen == self.generation else {
                    // 期间已经换行 / 鼠标离开：这次解出来的直接扔掉
                    if let tmp { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
                    return
                }
                guard let tmp else { return }
                self.store(key: key, file: tmp)
                DispatchQueue.main.async {
                    FileHoverPreviewController.shared.showNow(url: tmp)
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// 鼠标离开行 / 换行 / 滚动：撤销尚未弹出的预览，并收起已弹出的
    func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
        FileHoverPreviewController.shared.scheduleHide()
    }

    /// 归档窗关闭：把所有临时解压目录删掉
    func cleanup() {
        cancel()
        for item in cache { try? FileManager.default.removeItem(at: item.dir) }
        cache.removeAll()
    }

    // MARK: 缓存

    private static func key(archive: URL, entry: ArchiveEntry) -> String {
        var stamp = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: archive.path),
           let date = attrs[.modificationDate] as? Date {
            stamp = Int(date.timeIntervalSince1970)
        }
        return "\(archive.path)|\(entry.path)|\(entry.size)|\(stamp)"
    }

    private func cached(_ key: String) -> URL? {
        guard let index = cache.firstIndex(where: { $0.key == key }) else { return nil }
        guard FileManager.default.fileExists(atPath: cache[index].file.path) else {
            // 临时文件被系统清了：当作未命中
            let stale = cache.remove(at: index)
            try? FileManager.default.removeItem(at: stale.dir)
            return nil
        }
        let item = cache.remove(at: index)
        cache.append(item)          // LRU：命中挪到队尾
        return item.file
    }

    private func store(key: String, file: URL) {
        // extractEntryToTemp 每次建一个 frset-archive-<UUID> 目录；
        // 文件在包里可能有子目录，删除单位要回到这一层，否则删不干净
        var unit = file.deletingLastPathComponent()
        while !unit.lastPathComponent.hasPrefix("frset-archive-") {
            let parent = unit.deletingLastPathComponent()
            if parent.path == unit.path { break }
            unit = parent
        }
        cache.append(Item(key: key, file: file, dir: unit))
        if cache.count > Self.cacheLimit {
            let evicted = cache.removeFirst()
            try? FileManager.default.removeItem(at: evicted.dir)
        }
    }
}
