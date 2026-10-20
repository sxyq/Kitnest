import AppKit
import Combine
import Foundation

// MARK: - 本地文件中转（硬链接暂存）
//
// 设计目标（2026-10-20 用户需求）：
//   · 把常用文件拖进中转站，随取随用，不复制一份新的数据；
//   · 同一卷上优先用**硬链接**（link(2)）：磁盘只占一份，原地修改两边同步；
//   · 跨卷（外置盘/U 盘）无法硬链 → 自动降级为拷贝，并在 UI 上标注「副本」，不假装是硬链；
//   · 目录无法硬链 → 用符号链接（同样不复制数据），标注「链接目录」；
//   · 拖出去 = 把暂存路径交给 Finder（拖到别处默认复制该文件，内容与原件同源）。
//
// 暂存位置：Application Support/FrsetNext/transfer-local/<uuid>/<原文件名>
// 索引：transfer-local/index.json（只存元数据，不存内容）

/// 暂存目录的纯静态路径：任何地方都可安全读取，**不触发单例初始化**。
/// 之前 `stagedURL` 走 `LocalTransferStore.shared.stagingRoot`，而单例 init 里
/// `pruneMissing()` 又会读 `stagedURL` → dispatch_once 重入 → SIGTRAP（面板一开就崩）。
public enum LocalTransferPaths {
    public static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FrsetNext/transfer-local", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}

public struct LocalTransferItem: Identifiable, Codable, Equatable {
    public enum Mode: String, Codable {
        case hardlink
        case symlink
        case copy
        /// 局域网直传（手机扫码上传）——数据是真实的独立文件，不是链接
        case upload

        public var label: String {
            switch self {
            case .hardlink: return "链接"
            case .symlink: return "目录链接"
            case .copy: return "副本"
            case .upload: return "手机上传"
            }
        }

        public var symbol: String {
            switch self {
            case .hardlink: return "link"
            case .symlink: return "folder.badge.questionmark"
            case .copy: return "doc.on.doc"
            case .upload: return "iphone.and.arrow.forward"
            }
        }
    }

    public let id: String
    public let name: String
    /// 相对 transfer-local 的路径（<uuid>/<name>）
    public let relativePath: String
    public let originalPath: String
    public let size: Int64
    public let addedAt: Double
    public let mode: Mode

    public var stagedURL: URL { LocalTransferPaths.root.appendingPathComponent(relativePath) }

    public var sizeText: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "—"
    }

    public var addedText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: addedAt))
    }
}

public final class LocalTransferStore: ObservableObject {

    public static let shared = LocalTransferStore()

    @Published public private(set) var items: [LocalTransferItem] = []
    @Published public private(set) var lastMessage: String = ""
    @Published public private(set) var lastError: String?

    /// 暂存根目录
    public let stagingRoot: URL

    private let indexURL: URL
    private let queue = DispatchQueue(label: "frset.transfer.local", qos: .userInitiated)

    private init() {
        stagingRoot = LocalTransferPaths.root
        indexURL = LocalTransferPaths.root.appendingPathComponent("index.json")
        load()
        pruneMissing()
    }

    // MARK: 索引

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LocalTransferItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.sorted { $0.addedAt > $1.addedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 暂存文件被用户从 Finder 删掉后，索引里不再保留幽灵条目
    private func pruneMissing() {
        let alive = items.filter { FileManager.default.fileExists(atPath: $0.stagedURL.path) }
        if alive.count != items.count {
            items = alive
            persist()
        }
    }

    // MARK: 加入

    /// 把一批文件/目录加入本地中转；返回成功条数。
    @discardableResult
    public func add(urls: [URL]) -> Int {
        var added: [LocalTransferItem] = []
        var failures: [String] = []
        let fm = FileManager.default

        for url in urls {
            let normalized = url.standardizedFileURL
            guard fm.fileExists(atPath: normalized.path) else {
                failures.append("\(url.lastPathComponent)：文件不存在")
                continue
            }

            let id = UUID().uuidString
            let dir = stagingRoot.appendingPathComponent(id, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(normalized.lastPathComponent)
                let mode = try stage(from: normalized, to: dest)
                let size = Self.sizeOf(normalized)
                let item = LocalTransferItem(id: id,
                                             name: normalized.lastPathComponent,
                                             relativePath: "\(id)/\(normalized.lastPathComponent)",
                                             originalPath: normalized.path,
                                             size: size,
                                             addedAt: Date().timeIntervalSince1970,
                                             mode: mode)
                added.append(item)
            } catch {
                try? fm.removeItem(at: dir)
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        if !added.isEmpty {
            items.insert(contentsOf: added.reversed(), at: 0)
            persist()
            lastMessage = added.count == 1
                ? "已暂存 \(added[0].name)（\(added[0].mode.label)）"
                : "已暂存 \(added.count) 个文件"
            lastError = nil
            NotificationCenter.default.post(name: .localTransferDidChange, object: nil)
        }
        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }
        return added.count
    }

    /// 剪贴板自动暂存（2026-10-20 用户需求）：复制「zip / Word / PPT / Excel 等」文件时
    /// 自动进本地中转（硬链接暂存版——不复制数据）。只对文档/压缩包类扩展名生效，
    /// 且同一原路径已在列表里就跳过（避免同一次复制反复入库）。
    /// 需要在主线程调用（改 @Published）。
    @discardableResult
    public func autoStage(urls: [URL]) -> Int {
        let allowed = TransferDockPref.autoStageExtensions
        var candidates: [URL] = []
        for url in urls {
            let normalized = url.standardizedFileURL
            guard allowed.contains(normalized.pathExtension.lowercased()) else { continue }
            // 已暂存过同一原文件 → 不重复
            if items.contains(where: { $0.originalPath == normalized.path }) { continue }
            candidates.append(normalized)
        }
        guard !candidates.isEmpty else { return 0 }
        let count = add(urls: candidates)
        if count > 0 {
            Log.info("TransferDock", "剪贴板文件自动暂存 \(count) 个")
        }
        return count
    }

    /// 手机扫码上传进来的文件：数据已经落在临时目录，直接**移入**暂存（不是链接、不留副本）。
    /// 需要在主线程调用（改 @Published + 发通知）。
    @discardableResult
    public func addUploads(_ entries: [(name: String, tempURL: URL)], source: String = "手机") -> Int {
        var added: [LocalTransferItem] = []
        let fm = FileManager.default

        for entry in entries {
            let id = UUID().uuidString
            let dir = stagingRoot.appendingPathComponent(id, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(entry.name)
                do {
                    try fm.moveItem(at: entry.tempURL, to: dest)
                } catch {
                    // 临时目录与 Application Support 不同卷时 move 会失败 → 拷贝后删源
                    try fm.copyItem(at: entry.tempURL, to: dest)
                    try? fm.removeItem(at: entry.tempURL)
                }
                let size = Self.sizeOf(dest)
                added.append(LocalTransferItem(id: id,
                                               name: entry.name,
                                               relativePath: "\(id)/\(entry.name)",
                                               originalPath: entry.tempURL.path,
                                               size: size,
                                               addedAt: Date().timeIntervalSince1970,
                                               mode: .upload))
            } catch {
                try? fm.removeItem(at: dir)
                lastError = "\(entry.name)：\(error.localizedDescription)"
            }
        }

        guard !added.isEmpty else { return 0 }
        items.insert(contentsOf: added.reversed(), at: 0)
        persist()
        lastMessage = added.count == 1
            ? "\(source)上传了 \(added[0].name)"
            : "\(source)上传了 \(added.count) 个文件"
        NotificationCenter.default.post(name: .localTransferDidChange, object: nil)
        return added.count
    }

    /// 建链：硬链接优先；目录走符号链接；跨卷/不支持时降级拷贝。
    private func stage(from source: URL, to dest: URL) throws -> LocalTransferItem.Mode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)

        if isDir.boolValue {
            // 目录不能硬链；符号链接保持「不复制数据」的语义
            try fm.createSymbolicLink(at: dest, withDestinationURL: source)
            return .symlink
        }

        do {
            try fm.linkItem(at: source, to: dest)
            return .hardlink
        } catch {
            // EXDEV（跨卷）/ 文件系统不支持硬链 → 拷贝
            do {
                try fm.copyItem(at: source, to: dest)
                return .copy
            } catch {
                throw error
            }
        }
    }

    private static func sizeOf(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
              values.isDirectory != true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }

    // MARK: 移除/打开

    public func remove(_ item: LocalTransferItem) {
        // 只删暂存目录里的链接/副本，绝不动原文件
        let dir = stagingRoot.appendingPathComponent(item.id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        items.removeAll { $0.id == item.id }
        persist()
        lastMessage = "已移出 \(item.name)"
        NotificationCenter.default.post(name: .localTransferDidChange, object: nil)
    }

    public func clearAll() {
        for item in items {
            try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(item.id, isDirectory: true))
        }
        items.removeAll()
        persist()
        lastMessage = "已清空本地中转（原文件未受影响）"
        NotificationCenter.default.post(name: .localTransferDidChange, object: nil)
    }

    public func reveal(_ item: LocalTransferItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.stagedURL])
    }

    public func open(_ item: LocalTransferItem) {
        NSWorkspace.shared.open(item.stagedURL)
    }

    public func openStagingFolder() {
        NSWorkspace.shared.open(stagingRoot)
    }
}

public extension Notification.Name {
    static let localTransferDidChange = Notification.Name("frset.localTransfer.didChange")
}
