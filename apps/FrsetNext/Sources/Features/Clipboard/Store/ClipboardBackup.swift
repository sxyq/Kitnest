import Foundation

/// 手动密码备份；数据库与附件阶段由 Manager 的既有串行队列调用。
enum ClipboardBackup {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    final class Operation {
        private let lock = NSLock()
        private var cancelled = false
        private var finished = false
        private var taskID: UUID?

        func cancel() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            cancelled = true
            let id = taskID
            lock.unlock()
            if let id { ArchiveTaskQueue.shared.cancel(taskID: id) }
        }

        fileprivate func install(_ id: UUID?) {
            lock.lock()
            taskID = id
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel, let id { ArchiveTaskQueue.shared.cancel(taskID: id) }
        }

        fileprivate func checkCancellation() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled || ArchiveTaskQueue.shared.isCancelled(taskID) { throw Failure(message: "已取消") }
        }

        /// 进入最终提交后取消不再改写操作结果。
        fileprivate func finish() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled || ArchiveTaskQueue.shared.isCancelled(taskID) { throw Failure(message: "已取消") }
            finished = true
        }
    }

    struct Link: Codable {
        let itemDedupeKey: String
        let tagID: String
        let createdAt: Date
    }

    struct Attachment: Codable {
        let path: String
        let bytes: Int64
    }

    struct MissingRecord: Codable, Identifiable {
        let dedupeKey: String
        let title: String
        let paths: [String]
        var id: String { dedupeKey }
    }

    struct Manifest: Codable {
        let version: Int
        let createdAt: Date
        var items: [ClipboardItem]
        let tags: [Tag]
        let links: [Link]
        var attachments: [Attachment]
        var skippedRecords: [MissingRecord]?
    }

    final class RestoreSession {
        fileprivate let directory: URL
        let summary: String

        fileprivate init(directory: URL, summary: String) {
            self.directory = directory
            self.summary = summary
        }

        func cleanup() {
            let directory = directory
            DispatchQueue.global(qos: .utility).async { ClipboardBackup.removeTemporaryDirectory(directory) }
        }

        deinit { cleanup() }
    }

    private struct Analysis {
        let added: Int
        let duplicates: Int
        let conflicts: [String: [String]]
        let invalidFileReferences: [String]

        func summary(_ manifest: Manifest) -> String {
            let details = manifest.items.compactMap { item -> String? in
                guard let reasons = conflicts[item.dedupeKey] else { return nil }
                return "\(item.aliasTitle ?? item.title ?? item.dedupeKey)：\(reasons.joined(separator: "、"))"
            }
            return ClipboardBackup.counts(manifest)
                + (manifest.skippedRecords.map { "\n此包已备份 \(manifest.items.count) 条，跳过 \($0.count) 条；跳过记录保留在来源设备。" } ?? "")
                + "\n新增 \(added) · 重复 \(duplicates) · 冲突 \(conflicts.count) · 失效文件引用 \(invalidFileReferences.count)"
                + (details.isEmpty ? "" : "\n冲突：\n" + details.joined(separator: "\n"))
                + (invalidFileReferences.isEmpty ? "" : "\n失效引用：\n" + invalidFileReferences.joined(separator: "\n"))
        }
    }

    private static let folders: Set<String> = ["images", "thumbnails", "texts", "rich_texts", "ocr"]
    private static let pathColumns = ["image_path", "thumbnail_path", "text_path", "rich_text_path"]
    private static let columns: [String] = {
        ClipboardRepository.columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }()

    static func reviewExport(queue: DispatchQueue,
                             completion: @escaping (Result<[MissingRecord], Error>) -> Void) -> Operation {
        let operation = Operation()
        queue.async {
            do {
                let database = DatabaseManager.shared.clipboard
                database.accessLock.lock(); defer { database.accessLock.unlock() }
                let missing = try missingRecords(readSnapshot(database), operation: operation)
                try operation.finish()
                deliver(.success(missing), completion)
            } catch { deliver(.failure(error), completion) }
        }
        return operation
    }

    static func export(to url: URL, password: String, skipping: [MissingRecord], queue: DispatchQueue,
                       completion: @escaping (Result<String, Error>) -> Void) -> Operation {
        let operation = Operation()
        queue.async {
            var directory: URL?
            do {
                guard !password.isEmpty else { throw Failure(message: "请输入备份密码") }
                try operation.checkCancellation()
                let root = try temporaryDirectory()
                directory = root
                let manifest = try prepare(in: root, database: DatabaseManager.shared.clipboard,
                                           skipping: Set(skipping.map(\.dedupeKey)), operation: operation)
                let archive = root.appendingPathComponent("backup.7z")
                let id = ArchiveCore.create(files: [root.appendingPathComponent("manifest.json"),
                                                   root.appendingPathComponent("attachments")],
                                            to: archive, level: 5, password: password, encryptFileNames: true) { ok, message in
                    queue.async {
                        do {
                            try operation.checkCancellation()
                            guard ok else { throw archiveFailure(message) }
                            // 只发布这次新生成的加密归档，绝不更新已有目标包。
                            let destinationStage = url.deletingLastPathComponent()
                                .appendingPathComponent(".kitnest-backup-\(UUID().uuidString).7z")
                            defer { removeTemporaryDirectory(destinationStage) }
                            try FileManager.default.copyItem(at: archive, to: destinationStage)
                            try operation.finish()
                            if FileManager.default.fileExists(atPath: url.path) {
                                _ = try FileManager.default.replaceItemAt(url, withItemAt: destinationStage)
                            } else {
                                try FileManager.default.moveItem(at: destinationStage, to: url)
                            }
                            let cleanupWarning = removeTemporaryDirectory(root)
                            let result = manifest.skippedRecords.map { "已备份 \(manifest.items.count) 条，跳过 \($0.count) 条；缺失记录保留在本机。" }
                                ?? ("已加密备份：" + counts(manifest))
                            deliver(.success(result
                                             + (cleanupWarning.map { "\n" + $0 } ?? "")), completion)
                        } catch {
                            deliver(.failure(cleanupFailure(error, directory: root)), completion)
                        }
                    }
                }
                operation.install(id)
            } catch {
                deliver(.failure(cleanupFailure(error, directory: directory)), completion)
            }
        }
        return operation
    }

    static func prepareRestore(from url: URL, password: String, queue: DispatchQueue,
                               completion: @escaping (Result<RestoreSession, Error>) -> Void) -> Operation {
        let operation = Operation()
        queue.async {
            var directory: URL?
            do {
                guard !password.isEmpty else { throw Failure(message: "请输入备份密码") }
                try operation.checkCancellation()
                let handle = try FileHandle(forReadingFrom: url)
                let signature = try handle.read(upToCount: 6)
                try handle.close()
                guard signature == Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) else {
                    throw Failure(message: "备份格式错误：需要 Kitnest 的 7z 备份")
                }
                let root = try temporaryDirectory()
                directory = root
                let id = ArchiveTaskQueue.shared.enqueue(kind: .extract, title: "读取剪贴板备份",
                    onCancel: {
                        queue.async {
                            deliver(.failure(cleanupFailure(Failure(message: "已取消"), directory: root)), completion)
                        }
                    }) { taskID, done in
                    func fail(_ error: Error) {
                        let failure = cleanupFailure(error, directory: root)
                        done(false, failure.localizedDescription)
                        deliver(.failure(failure), completion)
                    }
                    ArchiveCore.list(url: url, password: password, includeAuxiliary: true, taskID: taskID) { entries, error in
                        queue.async {
                            do {
                                try operation.checkCancellation()
                                if let error { throw archiveFailure(error) }
                                try validateEntries(entries)
                                ArchiveCore.performExtract(url: url, entry: nil, to: root, password: password,
                                    includeAuxiliary: true, restrictTo: nil, taskID: taskID) { ok, message in
                                    queue.async {
                                        do {
                                            try operation.checkCancellation()
                                            guard ok else { throw archiveFailure(message) }
                                            let manifest = try readManifest(in: root)
                                            let database = DatabaseManager.shared.clipboard
                                            database.accessLock.lock()
                                            let analysis: Analysis
                                            do {
                                                analysis = try analyze(manifest, in: root, local: readSnapshot(database), operation: operation)
                                                database.accessLock.unlock()
                                            } catch {
                                                database.accessLock.unlock()
                                                throw error
                                            }
                                            let summary = analysis.summary(manifest)
                                            DispatchQueue.main.async {
                                                do {
                                                    try operation.finish()
                                                    done(true, "备份已读取")
                                                    completion(.success(RestoreSession(directory: root, summary: summary)))
                                                } catch {
                                                    queue.async { fail(error) }
                                                }
                                            }
                                        } catch { fail(error) }
                                    }
                                }
                            } catch { fail(error) }
                        }
                    }
                }
                operation.install(id)
            } catch {
                deliver(.failure(cleanupFailure(error, directory: directory)), completion)
            }
        }
        return operation
    }

    static func restore(_ session: RestoreSession, replace: Bool, useBackupConflicts: Bool,
                        queue: DispatchQueue, completion: @escaping (Result<String, Error>) -> Void) -> Operation {
        let operation = Operation()
        queue.async {
            do {
                try operation.checkCancellation()
                var message = try apply(session, replace: replace, useBackupConflicts: useBackupConflicts,
                                        database: DatabaseManager.shared.clipboard, operation: operation)
                if let failure = removeTemporaryDirectory(session.directory) { message += "\n" + failure }
                deliver(.success(message), completion)
            } catch {
                deliver(.failure(cleanupFailure(error, directory: session.directory)), completion)
            }
        }
        return operation
    }

    private static func missingRecords(_ manifest: Manifest, operation: Operation) throws -> [MissingRecord] {
        try manifest.items.compactMap { item in
            try operation.checkCancellation()
            let missing = try attachmentPaths(item).filter {
                let url = try attachmentURL($0, root: ClipboardFileStore.baseURL, mustExist: false)
                return !FileManager.default.fileExists(atPath: url.path)
            }
            return missing.isEmpty ? nil : MissingRecord(dedupeKey: item.dedupeKey,
                title: item.aliasTitle ?? item.title ?? item.dedupeKey, paths: missing)
        }
    }

    private static func prepare(in root: URL, database: SQLiteDatabase, skipping: Set<String>, operation: Operation) throws -> Manifest {
        try database.transaction { database in
            var manifest = try readSnapshot(database)
            let missing = try missingRecords(manifest, operation: operation)
            let unreviewed = missing.filter { !skipping.contains($0.dedupeKey) }
            guard unreviewed.isEmpty else {
                throw Failure(message: "附件状态已变化，请重新读取缺失清单：\n" + unreviewed.flatMap(\.paths).joined(separator: "\n"))
            }
            if !missing.isEmpty {
                let skipped = Set(missing.map(\.dedupeKey))
                manifest = Manifest(version: manifest.version, createdAt: manifest.createdAt,
                    items: manifest.items.filter { !skipped.contains($0.dedupeKey) }, tags: manifest.tags,
                    links: manifest.links.filter { !skipped.contains($0.itemDedupeKey) }, attachments: [], skippedRecords: missing)
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("attachments"),
                                                    withIntermediateDirectories: true)
            var paths = Set(manifest.items.flatMap(attachmentPaths))
            for item in manifest.items {
                let path = ClipboardOCRTextStorage.relativePath(dedupeKey: item.dedupeKey)
                let source = try attachmentURL(path, root: ClipboardFileStore.baseURL, mustExist: false)
                if FileManager.default.fileExists(atPath: source.path) { paths.insert(path) }
            }
            for path in paths.sorted() {
                try operation.checkCancellation()
                let source = try attachmentURL(path, root: ClipboardFileStore.baseURL)
                let target = try attachmentURL(path, root: root.appendingPathComponent("attachments"), mustExist: false)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
                manifest.attachments.append(Attachment(path: path, bytes: try byteCount(target)))
            }
            try operation.checkCancellation()
            try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
            return manifest
        }
    }

    private static func readSnapshot(_ database: SQLiteDatabase) throws -> Manifest {
        var items = try database.query("SELECT \(ClipboardRepository.columns) FROM clipboard_items", transform: ClipboardRepository.makeItem)
        let tags = try database.query("SELECT id, name, color_hex, created_at, updated_at FROM tags") {
            Tag(id: $0.string("id")!, name: $0.string("name")!, colorHex: $0.string("color_hex")!,
                createdAt: Date(timeIntervalSince1970: $0.real("created_at")),
                updatedAt: Date(timeIntervalSince1970: $0.real("updated_at")))
        }
        let links = try database.query("""
            SELECT item_dedupe_key, tag_id, created_at FROM clipboard_item_tags
            WHERE item_dedupe_key IN (SELECT dedupe_key FROM clipboard_items)
            """) {
                Link(itemDedupeKey: $0.string("item_dedupe_key")!, tagID: $0.string("tag_id")!,
                     createdAt: Date(timeIntervalSince1970: $0.real("created_at")))
            }
        let grouped = Dictionary(grouping: links, by: \.itemDedupeKey)
        for index in items.indices { items[index].tagIDs = (grouped[items[index].dedupeKey] ?? []).map(\.tagID) }
        return Manifest(version: 1, createdAt: Date(), items: items, tags: tags, links: links, attachments: [])
    }

    private static func validateEntries(_ entries: [ArchiveEntry]) throws {
        guard entries.contains(where: { $0.path == "manifest.json" && !$0.isDirectory }),
              Set(entries.map(\.path)).count == entries.count else {
            throw Failure(message: "备份缺少 manifest.json 或存在重名条目")
        }
        for entry in entries {
            guard !entry.isLink else { throw Failure(message: "备份含软链或硬链接：\(entry.path)") }
            if entry.path == "manifest.json" {
                guard entry.isEncrypted else { throw Failure(message: "备份 manifest 未加密") }
            } else if entry.isDirectory {
                let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                guard entry.path == "attachments" || (parts.count == 2 && parts[0] == "attachments" && folders.contains(String(parts[1]))) else {
                    throw Failure(message: "备份含不支持的目录：\(entry.path)")
                }
            } else {
                guard entry.path.hasPrefix("attachments/"), entry.isEncrypted else {
                    throw Failure(message: "备份含不支持或未加密的条目：\(entry.path)")
                }
                try validatePath(String(entry.path.dropFirst("attachments/".count)))
            }
        }
    }

    private static func readManifest(in root: URL) throws -> Manifest {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.type] as? FileAttributeType == .typeRegular else {
            throw Failure(message: "manifest.json 不是普通文件")
        }
        guard try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("attachments").path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure(message: "备份附件根目录不是普通目录")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1 else { throw Failure(message: "不支持的备份版本：\(manifest.version)") }
        let keys = Set(manifest.items.map(\.dedupeKey)), tagIDs = Set(manifest.tags.map(\.id))
        guard keys.count == manifest.items.count, Set(manifest.items.map(\.id)).count == manifest.items.count,
              tagIDs.count == manifest.tags.count,
              manifest.items.allSatisfy({ !$0.id.isEmpty && !$0.dedupeKey.isEmpty && !$0.id.contains("\0") && !$0.dedupeKey.contains("\0") }),
              manifest.tags.allSatisfy({ !$0.id.isEmpty && !$0.id.contains("\0") && !$0.name.isEmpty && !$0.name.contains("\0") }),
              manifest.links.allSatisfy({ keys.contains($0.itemDedupeKey) && tagIDs.contains($0.tagID) }) else {
            throw Failure(message: "备份条目或标签关联损坏")
        }
        let linked = Dictionary(grouping: manifest.links, by: \.itemDedupeKey)
        for item in manifest.items {
            guard Set(item.tagIDs) == Set((linked[item.dedupeKey] ?? []).map(\.tagID)) else {
                throw Failure(message: "标签关联不一致：\(item.dedupeKey)")
            }
        }
        guard Set(manifest.links.map { $0.itemDedupeKey + "\0" + $0.tagID }).count == manifest.links.count else {
            throw Failure(message: "备份含重复标签关联")
        }
        let required = Set(manifest.items.flatMap(attachmentPaths))
        let possible = required.union(manifest.items.map { ClipboardOCRTextStorage.relativePath(dedupeKey: $0.dedupeKey) })
        let declared = Set(manifest.attachments.map(\.path))
        guard declared.count == manifest.attachments.count else { throw Failure(message: "备份含重名附件") }
        let missing = required.subtracting(declared)
        guard missing.isEmpty else { throw Failure(message: "备份缺少必要附件：" + missing.sorted().joined(separator: "、")) }
        guard declared.isSubset(of: possible) else {
            throw Failure(message: "备份含无归属附件：" + declared.subtracting(possible).sorted().joined(separator: "、"))
        }
        for attachment in manifest.attachments {
            let url = try attachmentURL(attachment.path, root: root.appendingPathComponent("attachments"), mustExist: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure(message: "备份包缺少附件：\(attachment.path)")
            }
            guard attachment.bytes >= 0, try byteCount(url) == attachment.bytes else {
                throw Failure(message: "备份附件长度不符：\(attachment.path)")
            }
        }
        var files = Set<String>()
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let type = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.type] as? FileAttributeType
            if type == .typeDirectory {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard path == "attachments" || (parts.count == 2 && parts[0] == "attachments" && folders.contains(String(parts[1]))) else {
                    throw Failure(message: "备份含不支持的目录：\(path)")
                }
            } else if type == .typeRegular {
                if path != "manifest.json" { files.insert(path) }
            } else {
                throw Failure(message: "备份含软链或特殊文件：\(path)")
            }
        }
        guard files == Set(declared.map { "attachments/" + $0 }) else {
            throw Failure(message: "备份附件目录与 manifest 不一致")
        }
        return manifest
    }

    private static func analyze(_ manifest: Manifest, in root: URL, local: Manifest, operation: Operation) throws -> Analysis {
        let current = Dictionary(uniqueKeysWithValues: local.items.map { ($0.dedupeKey, $0) })
        let incomingTags = Dictionary(uniqueKeysWithValues: manifest.tags.map { ($0.id, $0.name.lowercased()) })
        let localTags = Dictionary(uniqueKeysWithValues: local.tags.map { ($0.id, $0.name.lowercased()) })
        var added = 0, duplicates = 0
        var conflicts: [String: [String]] = [:]
        var invalid = Set<String>()
        for item in manifest.items {
            try operation.checkCancellation()
            if item.type == .file {
                let text = try fullText(item, root: root.appendingPathComponent("attachments"))
                for path in text.split(separator: "\n").map(String.init) where !FileManager.default.fileExists(atPath: path) {
                    invalid.insert(path)
                }
            }
            guard let previous = current[item.dedupeKey] else { added += 1; continue }
            var reasons: [String] = []
            if item.isNote != previous.isNote { reasons.append("已存状态不同") }
            if item.isFavorite != previous.isFavorite { reasons.append("收藏状态不同") }
            if item.title != previous.title || item.aliasTitle != previous.aliasTitle { reasons.append("标题不同") }
            if Set(item.tagIDs.compactMap { incomingTags[$0] }) != Set(previous.tagIDs.compactMap { localTags[$0] }) {
                reasons.append("标签不同")
            }
            if item.type != previous.type || item.content != previous.content { reasons.append("正文不同") }
            let a = [item.imagePath, item.thumbnailPath, item.textPath, item.richTextPath]
            let b = [previous.imagePath, previous.thumbnailPath, previous.textPath, previous.richTextPath]
            for (incoming, existing) in zip(a, b) {
                if (incoming == nil) != (existing == nil) { reasons.append("附件不同"); break }
                if let incoming, let existing {
                    let source = try attachmentURL(incoming, root: root.appendingPathComponent("attachments"))
                    let existingURL = try attachmentURL(existing, root: ClipboardFileStore.baseURL, mustExist: false)
                    if !FileManager.default.fileExists(atPath: existingURL.path) {
                        reasons.append("本机附件缺失：\(existing)")
                    } else if try Data(contentsOf: source) != Data(contentsOf: existingURL) {
                        reasons.append("附件不同")
                    }
                }
            }
            let ocr = ClipboardOCRTextStorage.relativePath(dedupeKey: item.dedupeKey)
            let sourceOCR = try attachmentURL(ocr, root: root.appendingPathComponent("attachments"), mustExist: false)
            let localOCR = try attachmentURL(ocr, root: ClipboardFileStore.baseURL, mustExist: false)
            let hasSource = FileManager.default.fileExists(atPath: sourceOCR.path), hasLocal = FileManager.default.fileExists(atPath: localOCR.path)
            var ocrDiffers = hasSource != hasLocal
            if hasSource && hasLocal { ocrDiffers = try Data(contentsOf: sourceOCR) != Data(contentsOf: localOCR) }
            if ocrDiffers {
                reasons.append("OCR 不同")
            }
            if reasons.isEmpty { duplicates += 1 } else { conflicts[item.dedupeKey] = reasons }
        }
        return Analysis(added: added, duplicates: duplicates, conflicts: conflicts, invalidFileReferences: invalid.sorted())
    }

    private struct InstalledFile {
        let target: URL
        let previous: URL?
    }

    private static func apply(_ session: RestoreSession, replace: Bool, useBackupConflicts: Bool,
                              database: SQLiteDatabase, operation: Operation) throws -> String {
        database.accessLock.lock(); defer { database.accessLock.unlock() }
        let manifest = try readManifest(in: session.directory)
        let local = try readSnapshot(database)
        let analysis = try analyze(manifest, in: session.directory, local: local, operation: operation)
        let current = Dictionary(uniqueKeysWithValues: local.items.map { ($0.dedupeKey, $0) })
        var selected: [ClipboardItem] = []
        var replaced = 0, keptConflicts = 0
        for item in manifest.items {
            try operation.checkCancellation()
            if current[item.dedupeKey] != nil {
                if !replace && (analysis.conflicts[item.dedupeKey] == nil || !useBackupConflicts) {
                    if analysis.conflicts[item.dedupeKey] != nil { keptConflicts += 1 }
                    continue
                }
                replaced += 1
            }
            selected.append(item)
        }
        let restoredKeys = Set(selected.map(\.dedupeKey))
        let kept = replace ? [] : local.items.filter { !restoredKeys.contains($0.dedupeKey) }
        let fm = FileManager.default
        let base = ClipboardFileStore.baseURL.resolvingSymlinksInPath()
        let stage = base.appendingPathComponent(".kitnest-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var installed: [InstalledFile] = []
        var staged: [(source: URL, target: URL)] = []
        var remapping: [String: String] = [:]
        var tags = replace ? [] : local.tags
        var importedTagIDs: [String: String] = [:]
        for tag in manifest.tags {
            if let existing = tags.first(where: { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame }) {
                importedTagIDs[tag.id] = existing.id
            } else {
                let id = replace ? local.tags.first(where: { $0.name.caseInsensitiveCompare(tag.name) == .orderedSame })?.id : nil
                let new = Tag(id: id ?? UUID().uuidString, name: tag.name, colorHex: tag.colorHex,
                              createdAt: tag.createdAt, updatedAt: tag.updatedAt)
                tags.append(new)
                importedTagIDs[tag.id] = new.id
            }
        }
        var finalItems: [ClipboardItem] = []
        do {
            let declaredAttachments = Set(manifest.attachments.map(\.path))
            let paths = Set(selected.flatMap(attachmentPaths)).union(selected.compactMap { item -> String? in
                let path = ClipboardOCRTextStorage.relativePath(dedupeKey: item.dedupeKey)
                return declaredAttachments.contains(path) ? path : nil
            })
            for path in paths.sorted() {
                try operation.checkCancellation()
                let source = try attachmentURL(path, root: session.directory.appendingPathComponent("attachments"))
                let parts = path.split(separator: "/")
                let targetPath = parts[0] == "ocr" ? path
                    : String(parts[0]) + "/" + UUID().uuidString + "." + source.pathExtension
                remapping[path] = targetPath
                let saved = stage.appendingPathComponent(UUID().uuidString)
                try fm.copyItem(at: source, to: saved)
                staged.append((saved, try attachmentURL(targetPath, root: base, mustExist: false)))
            }
            var imported: [ClipboardItem] = []
            for item in selected {
                var row = Dictionary(uniqueKeysWithValues: zip(columns, ClipboardRepository.bindings(item)))
                row["id"] = .text(current[item.dedupeKey]?.id ?? UUID().uuidString)
                for column in pathColumns {
                    if let path = row.string(column) { row[column] = .text(remapping[path]!) }
                }
                if item.type == .file {
                    row["file_categories"] = .int(Int64(ClipboardFileCategories.classify(try fullText(item, root: session.directory.appendingPathComponent("attachments")))))
                }
                var restored = ClipboardRepository.makeItem(row)
                var seenTags = Set<String>()
                restored.tagIDs = item.tagIDs.map { importedTagIDs[$0]! }
                    .filter { seenTags.insert($0).inserted }
                imported.append(restored)
            }
            finalItems = kept + imported
            try database.transaction { database in
                for file in staged {
                    try operation.checkCancellation()
                    try fm.createDirectory(at: file.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    var previous: URL?
                    if fm.fileExists(atPath: file.target.path) {
                        let saved = stage.appendingPathComponent(UUID().uuidString)
                        try fm.moveItem(at: file.target, to: saved)
                        previous = saved
                    }
                    installed.append(InstalledFile(target: file.target, previous: previous))
                    try fm.moveItem(at: file.source, to: file.target)
                }
                if replace {
                    try database.run("DELETE FROM clipboard_item_tags")
                    try database.run("DELETE FROM clipboard_items")
                    try database.run("DELETE FROM resource_favorites WHERE resource_type='clipboard'")
                    try database.run("DELETE FROM tags")
                }
                let existingTags = Set(local.tags.map(\.id))
                for tag in tags where replace || !existingTags.contains(tag.id) {
                    try operation.checkCancellation()
                    try database.run("INSERT INTO tags(id,name,color_hex,created_at,updated_at) VALUES(?,?,?,?,?)",
                                     [.text(tag.id), .text(tag.name), .text(tag.colorHex),
                                      .real(tag.createdAt.timeIntervalSince1970), .real(tag.updatedAt.timeIntervalSince1970)])
                }
                let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
                let updates = columns.filter { $0 != "dedupe_key" }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
                for item in replace ? finalItems : imported {
                    try operation.checkCancellation()
                    try database.run("INSERT INTO clipboard_items(\(ClipboardRepository.columns)) VALUES(\(placeholders)) ON CONFLICT(dedupe_key) DO UPDATE SET \(updates)",
                                     ClipboardRepository.bindings(item))
                    if item.isFavorite {
                        try database.run("INSERT OR IGNORE INTO resource_favorites(resource_type,resource_id,added_at) VALUES('clipboard',?,?)",
                                         [.text(item.dedupeKey), .real(item.timestamp.timeIntervalSince1970)])
                    } else {
                        try database.run("DELETE FROM resource_favorites WHERE resource_type='clipboard' AND resource_id=?",
                                         [.text(item.dedupeKey)])
                    }
                    try database.run("DELETE FROM clipboard_item_tags WHERE item_dedupe_key=?", [.text(item.dedupeKey)])
                    for tagID in item.tagIDs {
                        let time = manifest.links.first { $0.itemDedupeKey == item.dedupeKey && importedTagIDs[$0.tagID] == tagID }!.createdAt
                        try database.run("INSERT INTO clipboard_item_tags(item_dedupe_key,tag_id,created_at) VALUES(?,?,?)",
                                         [.text(item.dedupeKey), .text(tagID), .real(time.timeIntervalSince1970)])
                    }
                }
                try operation.finish()
            }
        } catch {
            var rollbackFailures: [String] = []
            for file in installed.reversed() {
                do {
                    if fm.fileExists(atPath: file.target.path) { try fm.removeItem(at: file.target) }
                    if let previous = file.previous { try fm.moveItem(at: previous, to: file.target) }
                } catch { rollbackFailures.append("\(file.target.path)：\(error.localizedDescription)") }
            }
            if !rollbackFailures.isEmpty {
                throw Failure(message: error.localizedDescription + "\n附件恢复失败：" + rollbackFailures.joined(separator: "\n") + "\n原附件暂存在：\(stage.path)")
            }
            throw cleanupFailure(error, directory: stage)
        }
        // 数据库已提交；以下失败只能报告，绝不能进入附件回滚。
        var retainedPaths = Set(finalItems.flatMap(attachmentPaths))
        for item in finalItems {
            let path = ClipboardOCRTextStorage.relativePath(dedupeKey: item.dedupeKey)
            if !restoredKeys.contains(item.dedupeKey) || remapping[path] != nil { retainedPaths.insert(path) }
        }
        var oldPaths = Set(local.items.flatMap(attachmentPaths))
        oldPaths.formUnion(local.items.map { ClipboardOCRTextStorage.relativePath(dedupeKey: $0.dedupeKey) })
        var reclaimed: Int64 = 0
        var failures: [String] = []
        for path in oldPaths.subtracting(retainedPaths) {
            do {
                let url = try attachmentURL(path, root: base, mustExist: false)
                if fm.fileExists(atPath: url.path) {
                    let bytes = try byteCount(url)
                    try fm.removeItem(at: url)
                    reclaimed += bytes
                }
            } catch { failures.append("\(path)：\(error.localizedDescription)") }
        }
        for file in installed {
            guard let previous = file.previous else { continue }
            do {
                let bytes = try byteCount(previous)
                try fm.removeItem(at: previous)
                reclaimed += bytes
            } catch { failures.append("\(previous.path)：\(error.localizedDescription)") }
        }
        if let failure = removeTemporaryDirectory(stage) { failures.append(failure) }
        return "恢复已提交：新增 \(analysis.added) · 重复 \(analysis.duplicates) · 冲突 \(analysis.conflicts.count) · 使用备份 \(replaced) · 保留本机冲突 \(keptConflicts) · 失效引用 \(analysis.invalidFileReferences.count) · 失败 \(failures.count) · 回收 \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file))"
            + (failures.isEmpty ? "" : "\n附件回收失败：\n" + failures.joined(separator: "\n"))
    }

    private static func attachmentPaths(_ item: ClipboardItem) -> [String] {
        [item.imagePath, item.thumbnailPath, item.textPath, item.richTextPath].compactMap { $0 }
    }

    private static func fullText(_ item: ClipboardItem, root: URL) throws -> String {
        if let path = item.textPath { return try String(contentsOf: attachmentURL(path, root: root), encoding: .utf8) }
        return item.content ?? ""
    }

    private static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, folders.contains(String(parts[0])), !parts[1].isEmpty,
              parts[1] != ".", parts[1] != "..", !path.contains("\\"),
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw Failure(message: "不允许的私有附件路径：\(path)")
        }
    }

    private static func attachmentURL(_ path: String, root: URL, mustExist: Bool = true) throws -> URL {
        try validatePath(path)
        let parts = path.split(separator: "/")
        var url = root.resolvingSymlinksInPath()
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            do {
                let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == (index == parts.count - 1 ? .typeRegular : .typeDirectory) else {
                    throw Failure(message: "附件路径含软链或不是普通文件：\(path)")
                }
            } catch let error as NSError where !mustExist && error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                continue
            }
        }
        return url
    }

    private static func byteCount(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as! NSNumber).int64Value
    }

    private static func counts(_ manifest: Manifest) -> String {
        "条目 \(manifest.items.count) · 已存 \(manifest.items.filter(\.isNote).count) · 附件 \(manifest.attachments.count)"
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kitnest-clipboard-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    @discardableResult
    private static func removeTemporaryDirectory(_ url: URL) -> String? {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return nil
        } catch {
            let message = "临时明文清理失败 \(url.path)：\(error.localizedDescription)"
            Log.warn("clipboard", message)
            return message
        }
    }

    private static func cleanupFailure(_ error: Error, directory: URL?) -> Failure {
        let cleanup = directory.flatMap(removeTemporaryDirectory)
        return Failure(message: error.localizedDescription + (cleanup.map { "\n" + $0 } ?? ""))
    }

    private static func archiveFailure(_ message: String) -> Failure {
        Failure(message: ArchiveCore.ArchivePasswords.looksLikePasswordError(message)
                ? "密码错误或加密备份损坏：\(message)" : (message.isEmpty ? "7zz 操作失败" : message))
    }

    private static func deliver<T>(_ result: Result<T, Error>, _ completion: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }
}
