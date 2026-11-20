import AppKit
import Darwin
import Foundation
import SwiftUI

// MARK: - 存储管理 · 磁盘索引（v211）
//
// 用户需求原话：
//   「添加一个按钮，可以打开这种截图的面板……点击按钮之后，就可以点开，进入这个存储管理界面，
//     可以对文件进行删除，同时它扫描的是一个全盘，包括点开头的这些目录，然后是其他目录。
//     这种索引需要注意性能，可以在点开的时候才进行加载，并且加载之后它的状态就存储在里面，
//     或者有其他更好的方式去做性能开销，平常不用它就可以不用加载。」
//
// 性能纪律（重要）：
//   1) **零常驻**：本文件里的任何类型都不在 AppBootstrap / 模块 start() 里被引用，
//      只有用户点「打开存储管理」才创建窗口 → 才读缓存 / 才扫描。平时 App 完全不加载。
//   2) 扫描走 POSIX opendir/readdir/lstat（不建 NSURL、不查 resourceValues），
//      后台专用队列、可取消；隐藏目录（点开头）一律纳入，符号链接不跟随以免死循环。
//   3) 每层只保留最大的 30 个子项，其余聚合成「其余 N 项」——索引大小有上界；
//      深度上限 5、节点上限 12 万，避免全盘扫描把内存吃满。
//   4) 结果 JSON 落盘到 Application Support/FrsetNext/disk-index/，重开窗口直接读缓存，
//      只有点「重新扫描」才重扫。删除后同时更新内存树与缓存文件。
//   5) 删除一律走「移到废纸篓」，不做永久删除。

// MARK: 模型

struct DiskNode: Codable, Identifiable, Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
    /// 目录 = 子树合计；文件 = 自身大小
    var size: Int64
    /// 目录中未单独展示的直接文件字节；文件为自身大小
    var ownSize: Int64
    /// 目录里没被单独保留的子项数量
    var foldedCount: Int
    var children: [DiskNode]
    /// 合成项目仅用于展示，不对应可操作的文件路径。
    var isAggregate: Bool = false
    /// 折叠目录保留的互斥分类与路径字节；旧缓存缺少此项时不推测分类。
    var foldedCategorySummary: [DiskDataCategory]? = nil

    init(path: String, name: String, isDirectory: Bool, size: Int64, ownSize: Int64,
         foldedCount: Int, children: [DiskNode], isAggregate: Bool = false,
         foldedCategorySummary: [DiskDataCategory]? = nil) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.ownSize = ownSize
        self.foldedCount = foldedCount
        self.children = children
        self.isAggregate = isAggregate
        self.foldedCategorySummary = foldedCategorySummary
    }

    private enum CodingKeys: String, CodingKey {
        case path, name, isDirectory, size, ownSize, foldedCount, children, isAggregate, foldedCategorySummary
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        name = try values.decode(String.self, forKey: .name)
        isDirectory = try values.decode(Bool.self, forKey: .isDirectory)
        size = try values.decode(Int64.self, forKey: .size)
        ownSize = try values.decode(Int64.self, forKey: .ownSize)
        foldedCount = try values.decode(Int.self, forKey: .foldedCount)
        children = try values.decode([DiskNode].self, forKey: .children)
        isAggregate = try values.decodeIfPresent(Bool.self, forKey: .isAggregate) ?? false
        foldedCategorySummary = try values.decodeIfPresent([DiskDataCategory].self, forKey: .foldedCategorySummary)
    }

    var id: String { path }

    /// 是否可继续下钻
    var canDrill: Bool { isDirectory && !children.isEmpty }
}

struct DiskIndexSnapshot: Codable {
    var scope: String
    var rootPath: String
    var scannedAt: TimeInterval
    var totalBytes: Int64
    var nodeCount: Int
    var skippedCount: Int
    var root: DiskNode
    /// 是否因节点上限提前收尾（v211 新增；Optional 以兼容旧缓存 JSON）
    var truncated: Bool? = nil
    /// 索引结构版本（v264 新增）。
    ///
    /// v264 把深度上限从 6 放到 64、大小口径改成 st_blocks —— 旧缓存（无此字段）
    /// 的节点数只有真实量的 1/16、总量只有 1/4，继续拿来展示等于骗人。
    /// 显式版本不符仍作废；无版本旧缓存保留目录树，分类小计缺失时提示重新扫描。
    var schema: Int? = nil
    /// 随索引生成的互斥分类汇总，窗口交互只读取结果。
    var dataCategories: [DiskDataCategory] = []
    var excludedPaths: [String] = []
    var categorySummaryIssue: String? = nil

    init(scope: String,
         rootPath: String,
         scannedAt: TimeInterval,
         totalBytes: Int64,
         nodeCount: Int,
         skippedCount: Int,
         root: DiskNode,
         truncated: Bool? = nil,
         schema: Int? = nil,
         dataCategories: [DiskDataCategory] = [],
         excludedPaths: [String] = [],
         categorySummaryIssue: String? = nil) {
        self.scope = scope
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.totalBytes = totalBytes
        self.nodeCount = nodeCount
        self.skippedCount = skippedCount
        self.root = root
        self.truncated = truncated
        self.schema = schema
        self.dataCategories = dataCategories
        self.excludedPaths = excludedPaths
        self.categorySummaryIssue = categorySummaryIssue
    }

    private enum CodingKeys: String, CodingKey {
        case scope, rootPath, scannedAt, totalBytes, nodeCount, skippedCount
        case root, truncated, schema, dataCategories, excludedPaths, categorySummaryIssue
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decode(String.self, forKey: .scope)
        rootPath = try values.decode(String.self, forKey: .rootPath)
        scannedAt = try values.decode(TimeInterval.self, forKey: .scannedAt)
        totalBytes = try values.decode(Int64.self, forKey: .totalBytes)
        nodeCount = try values.decode(Int.self, forKey: .nodeCount)
        skippedCount = try values.decode(Int.self, forKey: .skippedCount)
        root = try values.decode(DiskNode.self, forKey: .root)
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated)
        schema = try values.decodeIfPresent(Int.self, forKey: .schema)
        dataCategories = try values.decodeIfPresent([DiskDataCategory].self, forKey: .dataCategories) ?? []
        excludedPaths = try values.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
        categorySummaryIssue = try values.decodeIfPresent(String.self, forKey: .categorySummaryIssue)
    }

    mutating func recomputeDataCategories() {
        switch DiskDataCategory.summarize(root) {
        case .success(let categories):
            dataCategories = categories
            categorySummaryIssue = nil
        case .failure(let issue):
            dataCategories = []
            categorySummaryIssue = issue.message
        }
    }
}

enum DiskDataKind: String, Codable, CaseIterable, Identifiable {
    case caches, applicationSupport, logs, development, other
    var id: String { "disk-category:" + rawValue }
    var title: String {
        switch self {
        case .caches: return "缓存"
        case .applicationSupport: return "应用支持"
        case .logs: return "日志"
        case .development: return "开发资料"
        case .other: return "其他已索引内容"
        }
    }

    static func match(_ node: DiskNode) -> Self? {
        match(path: node.path, name: node.name)
    }

    static func match(path: String, name: String) -> Self? {
        switch name {
        case "Caches", "cache", "caches", ".cache", ".npm", ".pnpm-store", ".yarn",
             ".uv", "__pycache__", ".pytest_cache", "go-build": return .caches
        case "Logs", "logs": return .logs
        case ".cargo", ".rustup", ".gradle", ".m2", ".swiftpm", "node_modules",
             "Pods", "DerivedData": return .development
        default: break
        }
        let parent = (path as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent == "Library" {
            if ["Application Support", "Containers", "Group Containers"].contains(name) {
                return .applicationSupport
            }
            if name == "Developer" { return .development }
        }
        if path == "/private/var/log" || path == "/var/log" { return .logs }
        if path == "/Applications/Xcode.app" { return .development }
        return nil
    }
}

struct DiskDataPath: Codable, Hashable, Identifiable {
    let path: String
    let bytes: Int64
    var id: String { path }
}

struct DiskDataCategory: Codable, Hashable, Identifiable {
    let kind: DiskDataKind
    let bytes: Int64
    let directories: [String]
    var pathBytes: [DiskDataPath]? = nil
    var id: String { kind.id }

    enum SummaryFailure: Error {
        case foldedDetailsMissing
        case totalMismatch

        var message: String {
            switch self {
            case .foldedDetailsMissing:
                return "此缓存的折叠目录只保存总字节与项目数，缺少内部类别小计及逐路径字节；无法还原精确分类，请重新扫描。"
            case .totalMismatch:
                return "分类路径字节合计与索引目录总量不一致，无法显示精确分类，请重新扫描。"
            }
        }
    }

    struct Accumulator {
        private struct Key: Hashable {
            let kind: DiskDataKind
            let path: String
        }

        private var sizes: [Key: Int64] = [:]

        init() {}

        mutating func add(kind: DiskDataKind, path: String, bytes: Int64) {
            guard bytes > 0 else { return }
            sizes[Key(kind: kind, path: path), default: 0] += bytes
        }

        mutating func merge(_ other: Accumulator) {
            for (key, bytes) in other.sizes {
                sizes[key, default: 0] += bytes
            }
        }

        mutating func merge(_ categories: [DiskDataCategory]) -> Bool {
            for category in categories {
                guard let paths = category.pathBytes,
                      paths.reduce(Int64(0), { $0 + $1.bytes }) == category.bytes else {
                    return false
                }
                for item in paths {
                    add(kind: category.kind, path: item.path, bytes: item.bytes)
                }
            }
            return true
        }

        var totalBytes: Int64 { sizes.values.reduce(Int64(0), +) }

        func categories() -> [DiskDataCategory] {
            DiskDataKind.allCases.map { kind in
                var paths: [DiskDataPath] = []
                for (key, bytes) in sizes where key.kind == kind {
                    paths.append(DiskDataPath(path: key.path, bytes: bytes))
                }
                paths.sort {
                    if $0.bytes == $1.bytes { return $0.path < $1.path }
                    return $0.bytes > $1.bytes
                }
                return DiskDataCategory(
                    kind: kind,
                    bytes: paths.reduce(Int64(0), { $0 + $1.bytes }),
                    directories: DiskIndexStore.independentPaths(paths.map(\.path)),
                    pathBytes: paths
                )
            }
        }
    }

    var node: DiskNode {
        DiskNode(path: id, name: kind.title, isDirectory: false, size: bytes,
                 ownSize: bytes, foldedCount: 0, children: [], isAggregate: true)
    }

    static func summarize(_ root: DiskNode) -> Result<[Self], SummaryFailure> {
        var summary = Accumulator()
        func visit(_ node: DiskNode, kind: DiskDataKind, origin: String) -> SummaryFailure? {
            if node.isDirectory && node.foldedCount > 0 && !node.children.contains(where: { $0.isAggregate }) {
                return .foldedDetailsMissing
            }
            if node.isAggregate {
                guard let folded = node.foldedCategorySummary,
                      summary.merge(folded) else {
                    return .foldedDetailsMissing
                }
                return nil
            }
            let matched = node.isDirectory && !node.isAggregate ? DiskDataKind.match(node) : nil
            let kind = matched ?? kind
            let origin = matched == nil ? origin : node.path
            // 父目录只贡献未展示的直接文件；子节点各贡献一次。
            let bytes = node.isDirectory ? node.ownSize : node.size
            summary.add(kind: kind, path: origin, bytes: bytes)
            for child in node.children {
                if let issue = visit(child, kind: kind, origin: origin) { return issue }
            }
            return nil
        }
        if let issue = visit(root, kind: .other, origin: root.path) {
            return .failure(issue)
        }
        guard summary.totalBytes == root.size else { return .failure(.totalMismatch) }
        return .success(summary.categories())
    }
}

struct CleanupRecord: Codable, Identifiable {
    var id: String = UUID().uuidString
    var at: TimeInterval
    var paths: [String]
    var bytes: Int64
    var succeeded: Bool
}

enum DiskScanScope: String, CaseIterable, Identifiable {
    case home
    case fullDisk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "个人目录（含隐藏目录）"
        case .fullDisk: return "整块启动卷"
        }
    }

    var rootPath: String {
        switch self {
        case .home: return NSHomeDirectory()
        case .fullDisk: return "/"
        }
    }

    /// 有没有「完全磁盘访问权限」。
    ///
    /// 判据是能否读**系统级** TCC 数据库。这里踩过两个坑（v264 实测）：
    /// 1. 用户级 `~/Library/Application Support/com.apple.TCC/TCC.db` 对未授权进程
    ///    返回的是 ENOENT 而不是 EACCES（TCC 直接把它藏起来），拿它判断会永远为 false；
    /// 2. 直接 opendir 相册/邮件目录会弹系统授权框，把扫描流程卡死。
    /// 系统级那个库只有 FDA 能打开，且**拒绝时不弹窗**，是唯一干净的探针。
    static var hasFullDiskAccess: Bool {
        let db = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(db, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    /// TCC 保护目录：没有完全磁盘访问权限时，opendir 这些路径会同步弹
    /// 「允许访问…？」系统授权框，模态弹窗会卡住 App 主线程、连带把后台扫描与
    /// 进度刷新一起堵死（v211 实测）。无权限时整体跳过并计入「不可读路径」。
    private static var tccProtected: [String] {
        let h = NSHomeDirectory()
        return [h + "/Music", h + "/Movies", h + "/Pictures",
                h + "/Library/Music", h + "/Library/Mail", h + "/Library/Messages",
                h + "/Library/Safari", h + "/Library/Cookies", h + "/Library/Calendars",
                h + "/Library/Keychains", h + "/Library/Application Support/AddressBook",
                h + "/Library/Application Support/CallHistoryDB",
                h + "/Library/Application Support/com.apple.TCC",
                h + "/Library/Containers", h + "/Library/Group Containers"]
    }

    /// 无论如何都跳过：伪文件系统、外接卷挂载点、系统管理的临时与索引区。
    private static let alwaysSkip: [String] = [
        "/dev", "/proc", "/sys", "/Network", "/Volumes",
        // APFS firmlink：/System/Volumes/Data 就是 /Users /Applications 的另一张脸，
        // 扫它等于把整块数据算两遍。注意只跳 /System/Volumes，不跳 /System 本身——
        // 系统只读卷那 13GB 是真实占用，不跳才对得上 df（v264 修正）。
        "/System/Volumes",
        // 内核交换与睡眠镜像：系统自己管，出现在清理列表里只会误删
        "/private/var/vm",
        // 每个用户的临时目录：几十万小文件，扫它半小时、清它出事
        "/private/var/folders",
        "/cores", "/.Spotlight-V100", "/.fseventsd",
        "/.DocumentRevisions-V100", "/.TemporaryItems", "/.Trashes",
    ]

    /// home 下额外跳过的：Spotlight 自建的索引库（常有几十 GB，且不是用户文件）
    private static var homeAlwaysSkip: [String] {
        let h = NSHomeDirectory()
        return [h + "/Library/Metadata/CoreSpotlight"]
    }

    /// 跳过的路径前缀。有完全磁盘访问权限时不再跳 TCC 目录——
    /// 那是用户真实的邮件/照片/信息/沙盒缓存，跳过就是「索引不全」。
    var excludedPrefixes: [String] {
        let fda = Self.hasFullDiskAccess
        switch self {
        case .home:
            return Self.homeAlwaysSkip + (fda ? [] : Self.tccProtected)
        case .fullDisk:
            return Self.alwaysSkip + (fda ? [] : Self.tccProtected)
        }
    }
}

// MARK: - 扫描器

final class DiskIndexScanner {

    /// v264（用户：「索引不完整，没有索引到全盘」）：
    /// 原来 maxDepth = 6，实测 `/Applications` 只算出 8.2GB（真实 22GB）、
    /// `~` 只算出 34GB（真实 174GB）、全盘 51.8GB（真实 235GB）——**漏了 78%**。
    /// 根因就是深度：Xcode.app/Contents/Developer/Platforms/… 在 7 层以下，
    /// `~/Library/Application Support/<App>/Caches` 也常在第 7 层。
    ///
    /// 深度本身不影响正确性（大小是后序遍历累加出来的），只影响内存；
    /// 真正的闸门是节点上限。所以这里放到 64（等于不限制），靠 maxNodes 兜底。
    static let maxDepth = 64
    /// 节点上限只兜内存，不是「扫描精度」。
    /// 实测本机 `~` 单独就有 205 万个条目，原上限 30 万把全盘切成了 1/13。
    /// 400 万覆盖整块启动卷；折叠后实际节点 ~40 万，内存峰值 ~150MB，
    /// 且只存在于「存储管理窗口打开 + 手动点扫描」的这几十秒里。
    static let maxNodes = 4_000_000
    /// 索引结构版本：深度/大小口径变化时递增；无版本旧缓存保留目录索引。
    static let schemaVersion = 6
    /// 每层保留的最大子项。24 太少了：`~` 下有 30+ 个目录，
    /// `.workbuddy` 这种中等大小的会被折进「其余 N 项」，再也点不进去。
    static let childrenPerDirectory = 60
    static let minimumFileBytes: Int64 = 100_000_000

    private let lock = NSLock()
    private var _cancelled = false
    private var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }

    func cancel() { cancelled = true }

    /// 后台队列执行并完成；progress 在主线程回调（nodeCount, 当前路径）。
    func scan(scope: DiskScanScope,
              queue: DispatchQueue,
              progress: @escaping (Int, String) -> Void,
              completion: @escaping (DiskIndexSnapshot?) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            let startedAt = CFAbsoluteTimeGetCurrent()
            var counter = 0
            var skipped = 0
            let excluded = scope.excludedPrefixes   // 一次算好，递归里不重复拼路径数组
            let result = self.walk(scope.rootPath,
                                   depth: 0,
                                   inheritedKind: .other,
                                   inheritedOrigin: scope.rootPath,
                                   excluded: excluded,
                                   counter: &counter,
                                   skipped: &skipped,
                                   progress: progress)
            guard !self.cancelled, let result else {
                completion(nil)
                return
            }
            let root = result.node
            Log.info("DiskIndex", String(format: "扫描完成：%d 条目 · 跳过 %d 处 · %.1f GB · %.1f 秒",
                                         counter, skipped,
                                         Double(root.size) / 1_073_741_824,
                                         CFAbsoluteTimeGetCurrent() - startedAt))
            var snapshot = DiskIndexSnapshot(scope: scope.rawValue,
                                             rootPath: scope.rootPath,
                                             scannedAt: Date().timeIntervalSince1970,
                                             totalBytes: root.size,
                                             nodeCount: counter,
                                             skippedCount: skipped,
                                             root: root,
                                             truncated: counter >= Self.maxNodes,
                                             schema: Self.schemaVersion)
            snapshot.recomputeDataCategories()
            snapshot.excludedPaths = excluded
            completion(snapshot)
        }
    }

    /// 文件在磁盘上的**物理**占用（字节）。
    ///
    /// 不能用 `st_size`：APFS 对系统文件做透明压缩，`/System` 的逻辑大小 30GB、
    /// 实际只占 13GB，用 st_size 会让「已索引」虚高、与 df 对不上（v264 实测）。
    /// `st_blocks`（512 字节块）才是 df/du 的口径。稀疏文件也靠它算对。
    private static func physicalSize(_ st: stat) -> Int64 {
        Int64(st.st_blocks) * 512
    }

    /// 子目录名称用于递归；文件只保留本层最大的有限候选。
    private struct DirEntry {
        let name: String
    }

    private struct FileEntry {
        let name: String
        let size: Int64
    }

    private func retainFile(_ name: String, size: Int64, in files: inout [FileEntry]) {
        if size < Self.minimumFileBytes { return }
        if files.count == Self.childrenPerDirectory, size <= files.last!.size { return }
        let index = files.firstIndex { $0.size < size } ?? files.count
        files.insert(FileEntry(name: name, size: size), at: index)
        if files.count > Self.childrenPerDirectory { files.removeLast() }
    }

    /// 递归建树。返回 nil 表示被取消或不可读。
    ///
    /// v264 性能要点：用 `readdir` 返回的 `d_type` 判断是不是目录，
    /// **目录不再 lstat**（APFS 上 d_type 可靠），少掉约 20% 的 syscall；
    /// 只有普通文件才取 `st_size`。实测 `find ~` 205 万条目 35 秒，
    /// 这套走法与之同量级。
    private func walk(_ path: String, depth: Int,
                      inheritedKind: DiskDataKind, inheritedOrigin: String,
                      excluded: [String],
                      counter: inout Int, skipped: inout Int,
                      progress: @escaping (Int, String) -> Void)
        -> (node: DiskNode, summary: DiskDataCategory.Accumulator)? {
        if cancelled { return nil }
        if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            skipped += 1
            return nil
        }
        guard let dir = opendir(path) else { skipped += 1; return nil }
        defer { closedir(dir) }

        let name = (path as NSString).lastPathComponent.isEmpty
            ? "/" : (path as NSString).lastPathComponent
        let matched = DiskDataKind.match(path: path, name: name)
        let kind = matched ?? inheritedKind
        let origin = matched == nil ? inheritedOrigin : path

        var subdirs: [DirEntry] = []
        var fileBytes: Int64 = 0
        var files: [FileEntry] = []
        var st = stat()
        let ifmt: mode_t = 0o170000
        let ifdir: mode_t = 0o040000
        let iflnk: mode_t = 0o120000
        let dtDir = UInt8(DT_DIR)
        let dtReg = UInt8(DT_REG)
        let dtLnk = UInt8(DT_LNK)

        while let ent = readdir(dir) {
            if cancelled { break }
            var nameBuf = ent.pointee.d_name
            let name = withUnsafeBytes(of: &nameBuf) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            let full = path == "/" ? "/" + name : path + "/" + name
            let dtype = ent.pointee.d_type

            if dtype == dtDir {
                subdirs.append(DirEntry(name: name))
            } else if dtype == dtReg {
                guard lstat(full, &st) == 0 else { skipped += 1; continue }
                let bytes = Self.physicalSize(st)
                fileBytes += bytes
                retainFile(name, size: bytes, in: &files)
            } else if dtype == dtLnk {
                // 符号链接不跟随（避免 /usr → /System/Volumes/Data 之类的环）
                skipped += 1
                continue
            } else {
                // DT_UNKNOWN（网络卷 / 部分文件系统）：退回 lstat 判断
                guard lstat(full, &st) == 0 else { skipped += 1; continue }
                let mode = st.st_mode & ifmt
                if mode == iflnk { skipped += 1; continue }
                if mode == ifdir {
                    subdirs.append(DirEntry(name: name))
                } else {
                    let bytes = Self.physicalSize(st)
                    fileBytes += bytes
                    retainFile(name, size: bytes, in: &files)
                }
            }

            counter += 1
            // 全盘 248 万条目：每 2000 条回一次主线程 = 1240 次 SwiftUI 重绘，
            // 实测会把面板刷成幻灯片。1 万条一次（约 250ms）足够看清进度。
            if counter % 10_000 == 0 {
                let c = counter
                DispatchQueue.main.async { progress(c, full) }
            }
            if counter >= Self.maxNodes { break }
        }

        var children: [(node: DiskNode, summary: DiskDataCategory.Accumulator)] = files.map {
            (node: DiskNode(path: path == "/" ? "/" + $0.name : path + "/" + $0.name,
                            name: $0.name, isDirectory: false, size: $0.size,
                            ownSize: $0.size, foldedCount: 0, children: []),
             summary: DiskDataCategory.Accumulator())
        }
        var ownSize = fileBytes - files.reduce(Int64(0)) { $0 + $1.size }
        var folded = 0
        var foldedBytes: Int64 = 0
        var foldedSummary = DiskDataCategory.Accumulator()
        var summary = DiskDataCategory.Accumulator()
        summary.add(kind: kind, path: origin, bytes: fileBytes)
        if depth < Self.maxDepth {
            for e in subdirs {
                if counter >= Self.maxNodes { break }
                if let child = walk(path == "/" ? "/" + e.name : path + "/" + e.name,
                                    depth: depth + 1,
                                    inheritedKind: kind,
                                    inheritedOrigin: origin,
                                    excluded: excluded,
                                    counter: &counter, skipped: &skipped,
                                    progress: progress) {
                    summary.merge(child.summary)
                    let index = children.firstIndex { $0.node.size < child.node.size } ?? children.count
                    children.insert((node: child.node, summary: child.summary), at: index)
                    if children.count > Self.childrenPerDirectory {
                        let removed = children.removeLast()
                        if removed.node.isDirectory {
                            folded += 1
                            foldedBytes += removed.node.size
                            foldedSummary.merge(removed.summary)
                        } else {
                            ownSize += removed.node.size
                        }
                    }
                }
            }
        }
        // 文件与目录共用 60 项；被折叠的目录计入合成子节点，直接文件留在 ownSize。
        if folded > 0 {
            children.append((
                node: DiskNode(path: "disk-folded:" + path,
                               name: "其余 \(folded) 项",
                               isDirectory: false,
                               size: foldedBytes,
                               ownSize: foldedBytes,
                               foldedCount: folded,
                               children: [], isAggregate: true,
                               foldedCategorySummary: foldedSummary.categories()),
                summary: DiskDataCategory.Accumulator()
            ))
        }
        let visibleChildren = children.map(\.node).sorted { $0.size > $1.size }
        let total = ownSize + visibleChildren.reduce(Int64(0)) { $0 + $1.size }
        let node = DiskNode(path: path, name: name, isDirectory: true,
                            size: total, ownSize: ownSize, foldedCount: folded,
                            children: visibleChildren)
        return (node: node, summary: summary)
    }
}

// MARK: - 索引仓库（缓存 / 状态 / 删除）

/// 可清理候选：按常见缓存目录名 + 大文件启发式挑出来，供左侧清单勾选。
struct CleanupCandidate: Identifiable, Hashable {
    let node: DiskNode
    let reason: String
    let safe: Bool
    var id: String { node.path }
}

final class DiskIndexStore: ObservableObject {

    static let shared = DiskIndexStore()

    @Published private(set) var snapshot: DiskIndexSnapshot? {
        didSet { invalidateCandidates(); indexRevision += 1 }
    }
    @Published private(set) var indexRevision = 0
    @Published private(set) var isScanning = false
    @Published private(set) var progressText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var records: [CleanupRecord] = []
    /// v211（用户：「它同时扫描的是一个全盘，包括点开头的这些目录，然后还有就是其他目录」）：
    /// 默认就是整块启动卷；个人目录留在设置里做「只想清理自己文件」的快速选项。
    @Published var scope: DiskScanScope = .fullDisk {
        didSet {
            if scope != oldValue {
                cancelScan()
                snapshot = nil
                reloadFromCache()
            }
        }
    }

    private let queue = DispatchQueue(label: "com.frsetnext.diskindex", qos: .utility)
    private var scanner: DiskIndexScanner?
    private var loaded = false

    private var cacheDir: URL { AppDirectories.sub("disk-index") }
    private func cacheURL(for scope: DiskScanScope) -> URL {
        cacheDir.appendingPathComponent("index-\(scope.rawValue).json")
    }
    private var recordsURL: URL { cacheDir.appendingPathComponent("cleanup-records.json") }

    private init() {}

    /// 窗口打开时调用：**只读缓存**（后台解码），不触发扫描。
    /// v211 实测：打开即自动扫会立刻触发 TCC 授权弹窗，模态框把主线程和进度一起堵死。
    /// 因此索引必须由用户点「建立索引 / 重新扫描」显式触发；无缓存时界面给按钮。
    /// 这样"平常不用它"就真的零负载、零权限打扰。
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = recordsURL
        queue.async { [weak self] in
            let data = try? Data(contentsOf: url)
            let records = data.flatMap { try? JSONDecoder().decode([CleanupRecord].self, from: $0) } ?? []
            DispatchQueue.main.async { self?.records = records }
        }
        reloadFromCache(autoScanIfMissing: false)
    }

    func reloadFromCache(autoScanIfMissing: Bool = false) {
        let requestedScope = scope
        let revision = indexRevision
        let url = cacheURL(for: requestedScope)
        queue.async { [weak self] in
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            let snap = data.flatMap { Self.decodeSnapshot($0) }
            DispatchQueue.main.async {
                guard let self, self.scope == requestedScope,
                      self.indexRevision == revision, !self.isScanning else { return }
                self.snapshot = snap
                if snap == nil, autoScanIfMissing { self.rescan() }
            }
        }
    }

    /// v264：缓存格式换成**二进制 plist**。
    ///
    /// 深度放开后节点从 15 万涨到 40 万，同样的树用 JSON 要 80MB、解码 2~3 秒；
    /// 二进制 plist 小一半、解码快 3 倍。旧缓存是 JSON，先试 plist 再回落 JSON，
    /// 升级后第一次打开仍能读出来（只是慢一次）。
    private static func decodeSnapshot(_ data: Data, recomputeCategories: Bool = true) -> DiskIndexSnapshot? {
        struct Header: Decodable { let schema: Int? }
        let schema = (try? PropertyListDecoder().decode(Header.self, from: data))?.schema
            ?? (try? JSONDecoder().decode(Header.self, from: data))?.schema
        // 先读版本，过期的大树不再生成上百万个 Swift 节点。
        guard schema == nil || schema == DiskIndexScanner.schemaVersion else {
            Log.info("DiskIndex", "旧版索引缓存（schema=\(schema.map(String.init) ?? "无")），已作废，请重新扫描")
            return nil
        }
        var snap: DiskIndexSnapshot
        if let s = try? PropertyListDecoder().decode(DiskIndexSnapshot.self, from: data) {
            snap = s
        } else if let s = try? JSONDecoder().decode(DiskIndexSnapshot.self, from: data) {
            snap = s
        } else {
            return nil
        }
        if recomputeCategories { snap.recomputeDataCategories() }
        return snap
    }

    /// 重新扫描（可取消）
    func rescan() {
        guard !isScanning else { return }
        let s = DiskIndexScanner()
        scanner = s
        isScanning = true
        lastError = nil
        progressText = "正在索引…"
        let currentScope = scope
        let url = cacheURL(for: currentScope)
        s.scan(scope: currentScope, queue: queue,
               progress: { [weak self, s] count, path in
                   guard let self, self.scanner === s else { return }
                   self.progressText = "已索引 \(count) 项 · \(path)"
               },
               completion: { [weak self, s] snap in
                   if let snap, DispatchQueue.main.sync(execute: { self?.scanner === s }) {
                       do { try Self.persist(snap: snap, to: url) }
                       catch { Log.warn("DiskIndex", "索引缓存写入失败：\(error.localizedDescription)") }
                   }
                   DispatchQueue.main.async { [weak self, s] in
                       guard let self, self.scanner === s else { return }
                       self.isScanning = false
                       self.scanner = nil
                       self.progressText = ""
                       guard let snap else {
                           self.lastError = "扫描已取消或无法读取"
                           return
                       }
                       self.snapshot = snap
                   }
               })
    }

    func cancelScan() {
        scanner?.cancel()
        scanner = nil
        isScanning = false
        progressText = ""
    }

    private static func persist(snap: DiskIndexSnapshot, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(snap).write(to: url, options: .atomic)
    }

    private func persistRecords() {
        let recs = records
        let url = recordsURL
        queue.async {
            if let data = try? JSONEncoder().encode(recs) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func clearCache() {
        cancelScan()
        snapshot = nil
        let urls = DiskScanScope.allCases.map { cacheURL(for: $0) }
        queue.async { for u in urls { try? FileManager.default.removeItem(at: u) } }
    }

    // MARK: 清理候选

    /// 「可清理」只认真正的缓存/可再生目录。
    ///
    /// v213 实测收紧：原来名单里有 `Downloads`、`tmp`、`.rustup`、`.cargo`、`Xcode`、
    /// `Pods` 等——第一个是用户数据（误删不可恢复），第二个是系统临时目录
    /// （清空会打断正在运行的构建/进程，实测把构建中间产物整个搬走过一次），
    /// 后几个是工具链（删了要重装几分钟）。这些都不该出现在「推荐清理」里，
    /// 用户真要删可以在右侧堆块里点它自己做决定。
    private static let cacheNames: Set<String> = [
        "Caches", "cache", "caches", ".cache", "node_modules", "DerivedData",
        ".npm", "npm", ".pnpm-store", "pnpm", ".yarn", ".uv", "uv",
        "__pycache__", ".pytest_cache", "go-build",
        "Electron", "Crashpad",
        "logs", "Logs", ".Trash", "Trash",
    ]

    /// 兜底黑名单：任何叫 cache/tmp 的目录只要落在这几个路径上，一律不建议清理
    private static let protectedCandidatePaths: Set<String> = [
        "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
    ]

    /// 候选清单缓存：SwiftUI 每次 hover/勾选都会重算 body，
    /// 不能每帧都遍历索引树（最多 12 万节点）。只在索引变化时重算一次。
    private var candidateCache: [CleanupCandidate] = []
    private var candidateCacheStamp: TimeInterval = -1

    private func invalidateCandidates() {
        candidateCache = []
        candidateCacheStamp = -1
    }

    /// 从索引树里挑出可清理项（只取目录节点，按大小降序）
    func candidates() -> [CleanupCandidate] {
        guard let snap = snapshot else { return [] }
        if candidateCacheStamp == snap.scannedAt {
            return candidateCache
        }
        let root = snap.root
        var out: [CleanupCandidate] = []
        func visit(_ n: DiskNode, depth: Int) {
            // 黑名单路径一律跳过（/tmp 清空会打断运行中的进程，实测踩过一次）
            if Self.protectedCandidatePaths.contains(n.path) { return }
            // 安装版实见 App 内的 node_modules 被推荐删除；它们是应用资源，不能按缓存归类。
            if n.name.hasSuffix(".app") { return }
            if n.isDirectory, Self.cacheNames.contains(n.name), n.size > 20 * 1024 * 1024 {
                let safe = ["Caches", "cache", "caches", ".cache", "DerivedData",
                            ".npm", "npm", ".pnpm-store", "pnpm", ".yarn", ".uv", "uv",
                            "__pycache__", ".pytest_cache", "go-build"].contains(n.name)
                out.append(CleanupCandidate(node: n,
                                            reason: safe ? "常见缓存，可安全清理" : "请确认内容后再清理",
                                            safe: safe))
                return   // 命中后不再往里找，避免父子重复
            }
            // 候选遍历深度 12：再深的 cache（…/Caches/xxx/yyy）清掉也没多少，
            // 而全量遍历 40 万节点会让每次打开面板多花几十毫秒。
            guard depth < 12 else { return }
            for c in n.children where c.isDirectory { visit(c, depth: depth + 1) }
        }
        visit(root, depth: 0)
        let result = out.sorted { $0.node.size > $1.node.size }
        candidateCache = result
        candidateCacheStamp = snap.scannedAt
        return result
    }

    // MARK: 删除（移到废纸篓）

    /// 返回成功移入废纸篓的路径数；同时更新内存树与缓存。
    func trash(paths: [String], completion: @escaping (Int, Int64) -> Void) {
        let unique = Self.independentPaths(paths)
        let root = snapshot?.root
        let caches = DiskScanScope.allCases.map { ($0, cacheURL(for: $0)) }
        queue.async { [weak self] in
            guard let self else { return }
            var moved = Set<String>()
            var errors: [String] = []
            for p in unique {
                guard let node = Self.findNode(root, path: p), !node.isAggregate else {
                    errors.append("\(p)：不是可操作的索引路径")
                    continue
                }
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: p),
                                                      resultingItemURL: &resulting)
                    moved.insert(p)
                } catch {
                    errors.append("\(p)：\(error.localizedDescription)")
                }
            }
            let bytes = moved.reduce(Int64(0)) { sum, p in
                sum + (Self.findNode(root, path: p)?.size ?? 0)
            }
            let state = DispatchQueue.main.sync { (snapshot: self.snapshot, revision: self.indexRevision) }
            let update = state.snapshot.map { Self.removing(moved, from: $0) }
            if !moved.isEmpty {
                for (scope, url) in caches {
                    do {
                        let mutation: (changed: Bool, snapshot: DiskIndexSnapshot?)
                        if let update, state.snapshot?.scope == scope.rawValue {
                            mutation = update
                        } else {
                            guard FileManager.default.fileExists(atPath: url.path) else { continue }
                            let data = try Data(contentsOf: url, options: .mappedIfSafe)
                            guard let snapshot = Self.decodeSnapshot(data, recomputeCategories: false) else { continue }
                            mutation = Self.removing(moved, from: snapshot)
                        }
                        guard mutation.changed else { continue }
                        if let cached = mutation.snapshot {
                            try Self.persist(snap: cached, to: url)
                        } else if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                    } catch {
                        errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
                if let update, update.changed, self.indexRevision == state.revision {
                    self.snapshot = update.snapshot
                }
                let record = CleanupRecord(at: Date().timeIntervalSince1970,
                                           paths: unique, bytes: bytes,
                                           succeeded: moved.count == unique.count)
                self.records.insert(record, at: 0)
                self.records = Array(self.records.prefix(50))
                self.persistRecords()
                completion(moved.count, bytes)
            }
        }
    }

    private static func removing(_ paths: Set<String>, from snapshot: DiskIndexSnapshot)
        -> (changed: Bool, snapshot: DiskIndexSnapshot?) {
        let root = snapshot.rootPath
        let affected = Set(paths.filter {
            root == "/" || $0 == root || $0.hasPrefix(root + "/")
                || root.hasPrefix($0 == "/" ? "/" : $0 + "/")
        })
        guard !affected.isEmpty else { return (false, snapshot) }
        guard !affected.contains(where: { root == $0 || root.hasPrefix($0 == "/" ? "/" : $0 + "/") }),
              affected.allSatisfy({ findNode(snapshot.root, path: $0) != nil }) else {
            return (true, nil)
        }
        var updated = snapshot
        updated.root = pruned(updated.root, removing: affected)
        updated.totalBytes = updated.root.size
        updated.recomputeDataCategories()
        return (true, updated)
    }

    static func findNode(_ node: DiskNode?, path: String) -> DiskNode? {
        guard let node else { return nil }
        if node.path == path { return node }
        let directoryPath = path.hasPrefix("disk-folded:") ? String(path.dropFirst("disk-folded:".count)) : path
        for c in node.children where c.path == path || c.path == directoryPath
            || directoryPath.hasPrefix(c.path == "/" ? "/" : c.path + "/") {
            if let hit = findNode(c, path: path) { return hit }
        }
        return nil
    }

    /// 保留最上层所选路径，父目录已经包含的子项不再单独计数或移动。
    static func independentPaths(_ paths: [String]) -> [String] {
        let selected = Set(paths)
        return selected.sorted().filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while !parent.isEmpty, parent != path {
                if selected.contains(parent) { return false }
                if parent == "/" { break }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    /// 从树里删掉指定路径并重算父节点大小
    static func pruned(_ node: DiskNode, removing paths: Set<String>) -> DiskNode {
        var n = node
        let kept = n.children
            .filter { !paths.contains($0.path) }
            .map { pruned($0, removing: paths) }
        n.children = kept.sorted { $0.size > $1.size }
        n.size = n.ownSize + kept.reduce(Int64(0)) { $0 + $1.size }
        return n
    }
}

// MARK: 格式化

enum StorageFormat {
    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, v), countStyle: .file)
    }
    static func shortBytes(_ v: Int64) -> String {
        let d = Double(max(0, v))
        // 与 Finder、bytes() 的十进制文件单位一致，避免同一项出现 7.6 G / 8.2 GB。
        if d >= 1_000_000_000 { return String(format: "%.1f GB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.1f MB", d / 1_000_000) }
        return String(format: "%.0f KB", d / 1_000)
    }
    static func date(_ t: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
