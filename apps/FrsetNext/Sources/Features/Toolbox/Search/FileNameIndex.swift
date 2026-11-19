import Combine
import Darwin
import Foundation

// MARK: - 全盘文件名索引（v264）
//
// 用户原话：「首页点开的那个上面搜索栏，它的搜索的文件也不是全盘，就比如我搜索
// WorkBuddy 里面的当前这个 skill，Image HTML Deck 这个 skill 它就搜不到它的文件夹」
//
// 实测确认（2026-11-08）：
//   mdfind "kMDItemFSName == '*image-html-deck*'cd"        → 空
//   mdfind -onlyin ~/.workbuddy "kMDItemFSName == '*image*'cd" → 空
//   而 ~/.workbuddy/skills/image-html-deck 确实存在。
// **Spotlight 根本没索引这一片**，不是查询写错了。macOS 的 Spotlight 默认不索引：
//   · 以「.」开头的隐藏目录（~/.workbuddy、~/.cursor、~/.npm、~/.cargo…）
//   · ~/Library（`mdfind -onlyin ~/Library` 同样返回空）
//   · .app / .framework 包内部（Spotlight 把整个 bundle 当一个文件）
//   · /usr/local、/opt
// 这几处恰好是开发者文件最密集的地方，于是「搜不到」成了常态。
//
// 做法（对标 locate(1)，但不依赖 root、不改系统设置）：
//   1) 后台遍历上述盲区，把所有路径按 DFS 顺序写进**一个平坦字节池**（\0 分隔）；
//   2) 查询时 mmap 映射这个池，直接按字节匹配 NUL 分隔路径的子序列，
//      只解码命中项，按正式搜索的模糊得分取候选；
//   3) 落盘缓存，只在首次（或用户点「重建索引」）生成。
//
// 为什么 mmap 而不是内存数组：本机盲区约 180 万条、路径平均 95 字节 ≈ 170MB。
// 常驻堆内存会实打实挤占用户 App；mmap 的页由系统按需回收，冷页直接丢掉，
// 查询时顺序扫一遍（内存带宽量级）也就几十毫秒。
//
// 为什么不索引整盘：Spotlight 对可见目录已经覆盖得很好（mdfind 实测 0.15s），
// 重复索引 350 万条只会让磁盘和内存翻倍。盲区这 180 万条才是「搜不到」的全部来源。

final class FileNameIndex: ObservableObject {

    static let shared = FileNameIndex()

    enum State: Equatable {
        /// 还没建过（或缓存被清掉了）
        case absent
        /// 正在建；scanned = 已写入的条目数
        case building(scanned: Int)
        /// 就绪；count = 条目数，builtAt = 建立时间
        case ready(count: Int, builtAt: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .absent

    // MARK: mmap 视图

    private var map: UnsafeMutableRawPointer?
    private var mapLength = 0
    private var poolLength = 0
    /// 只读指针，搜索时零拷贝
    private var pool: UnsafePointer<UInt8>? {
        guard let map else { return nil }
        return UnsafePointer(map.advanced(by: Self.headerSize).assumingMemoryBound(to: UInt8.self))
    }

    private let buildQueue = DispatchQueue(label: "com.frsetnext.fileindex", qos: .utility)
    private let stateLock = NSLock()
    private var building = false

    private init() {}

    // MARK: - 路径

    private var cacheDir: URL { AppDirectories.sub("file-index") }
    private var cacheURL: URL { cacheDir.appendingPathComponent("names-v1.idx") }

    // MARK: - 对外

    /// 首次搜索时调用：有缓存就 mmap 进来，没有就后台建。
    /// **不会**在 App 启动、面板打开时自动跑——只有用户真的在搜文件时才付出代价。
    func ensureReady() {
        switch state {
        case .ready, .building: return
        case .absent, .failed: break
        }
        if loadFromDisk() { return }
        build()
    }

    /// 面板出现时调用：**只加载已有缓存**，没有就保持「未建立」状态。
    /// 真正建索引要等用户输入了文件查询（`ensureReady`），
    /// 否则每次打开面板都可能在后台跑一分钟。
    func preloadIfCached() {
        guard case .absent = state else { return }
        _ = loadFromDisk()
    }

    /// 用户点「重建索引」
    func rebuild() {
        guard !building else { return }
        unmap()
        try? FileManager.default.removeItem(at: cacheURL)
        build()
    }

    /// 索引文件占用（给设置页显示）
    var diskBytes: Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    /// 扫完整池，先筛类型，再按正式搜索的模糊得分返回最多 limit 条。
    func search(_ query: String, limit: Int = 120, kind: FileSearchSource.Kind = .all) -> [String] {
        let key = Self.terms(of: query).joined()
        guard !key.isEmpty else { return [] }
        let needle = Array(key.utf8)
        let literal = key.count > 32
        // 建索引/替换映射时 `map` 会被 munmap，搜索必须和它互斥
        // （否则可能读到已经释放的页 → EXC_BAD_ACCESS）。
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let pool, poolLength > 0 else { return [] }

        let paths = UnsafeRawPointer(pool).assumingMemoryBound(to: CChar.self)
        var offset = 0
        var candidates: [(path: String, score: Int, depth: Int)] = []
        let before = { (a: (path: String, score: Int, depth: Int),
                        b: (path: String, score: Int, depth: Int)) in
            if a.score != b.score { return a.score > b.score }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path < b.path
        }
        key.withCString { literalKey in
            while offset < poolLength {
                let bytes = paths.advanced(by: offset)
                let end = offset + strlen(bytes)
                var matched = 0
                if literal {
                    matched = strcasestr(bytes, literalKey) == nil ? 0 : needle.count
                } else {
                    // 2026-11-13：逐路径正则实测 20.2s；字节预过滤只解码命中项。
                    for cursor in offset..<end {
                        let byte = pool[cursor]
                        let folded = byte >= 65 && byte <= 90 ? byte + 32 : byte
                        if folded == needle[matched] { matched += 1 }
                        if matched == needle.count { break }
                    }
                }
                offset = end + 1
                guard matched == needle.count else { continue }
                let path = String(cString: bytes)
                let url = URL(fileURLWithPath: path)
                guard kind.includes(url) else { continue }
                let nameMatch = FuzzyMatcher.match(key, in: url.lastPathComponent)
                let pathMatch = nameMatch == nil ? FuzzyMatcher.match(key, in: path) : nil
                guard nameMatch != nil || pathMatch != nil else { continue }
                let candidate = (path: path, score: (nameMatch?.score ?? 0) * 2 + (pathMatch?.score ?? 0),
                                 depth: Self.depth(path))
                if candidates.count == limit, let last = candidates.last, !before(candidate, last) { continue }
                let index = candidates.firstIndex { before(candidate, $0) } ?? candidates.endIndex
                candidates.insert(candidate, at: index)
                if candidates.count > limit { candidates.removeLast() }
            }
        }
        return candidates.map(\.path)
    }

    /// 路径深度（`/` 的个数）
    private static func depth(_ path: String) -> Int {
        var n = 0
        for u in path.utf8 where u == 47 { n += 1 }
        return n
    }

    // MARK: - 磁盘格式
    //
    //   [0..4)   magic "KNFI"
    //   [4..8)   version UInt32 = 1
    //   [8..12)  count UInt32
    //   [12..16) poolLength UInt32
    //   [16..24) builtAt Double（timeIntervalSince1970）
    //   [24..)   pool：每条第 \0 结尾的 UTF-8 绝对路径
    //
    // 只存一份原样路径。大小写不敏感靠搜索时的 ASCII 折叠实现——
    // 再存一份小写副本会让 170MB 变 340MB，不值得。

    private static let headerSize = 24
    private static let magic: [UInt8] = [0x4B, 0x4E, 0x46, 0x49]   // "KNFI"

    private func loadFromDisk() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: cacheURL) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: Self.headerSize),
              head.count == Self.headerSize else { return false }
        let bytes = [UInt8](head)
        guard Array(bytes[0..<4]) == Self.magic else { return false }
        let count = Int(Self.u32(bytes, 8))
        let len = Int(Self.u32(bytes, 12))
        let stamp = Self.f64(bytes, 16)
        guard count > 0, len > 0 else { return false }

        let path = cacheURL.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        let total = Self.headerSize + len
        let ptr = mmap(nil, total, PROT_READ, MAP_PRIVATE, fd, 0)
        close(fd)
        guard let ptr, ptr != MAP_FAILED else { return false }

        stateLock.lock()
        if let old = map { munmap(old, mapLength) }
        map = ptr
        mapLength = total
        poolLength = len
        stateLock.unlock()

        state = .ready(count: count, builtAt: Date(timeIntervalSince1970: stamp))
        return true
    }

    private func unmap() {
        stateLock.lock()
        if let map { munmap(map, mapLength) }
        map = nil
        mapLength = 0
        poolLength = 0
        stateLock.unlock()
    }

    // MARK: - 建索引

    private func build() {
        guard !building else { return }
        building = true
        state = .building(scanned: 0)
        let url = cacheURL
        let dir = cacheDir

        buildQueue.async { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            var pool = Data(count: Self.headerSize)
            pool.reserveCapacity(200 * 1024 * 1024)
            var count = 0
            var lastReport = 0
            let cap = 900 * 1024 * 1024 + Self.headerSize

            let roots = Self.roots()
            for root in roots {
                Self.walk(root, pool: &pool, count: &count, cap: cap) { scanned in
                    // 每 2 万条回一次主线程：太密会把 SwiftUI 刷成幻灯片
                    guard scanned - lastReport >= 20_000 else { return }
                    lastReport = scanned
                    DispatchQueue.main.async { self.state = .building(scanned: scanned) }
                }
                if pool.count >= cap { break }
            }
            guard count > 0 else {
                DispatchQueue.main.async {
                    self.building = false
                    self.state = .failed("没有可索引的目录")
                }
                return
            }

            // 原池预留头部，扫描后直接写盘，避免再复制整个路径池。
            var header = Self.magic
            Self.appendU32(&header, 1)
            Self.appendU32(&header, UInt32(clamping: count))
            Self.appendU32(&header, UInt32(clamping: pool.count - Self.headerSize))
            Self.appendF64(&header, Date().timeIntervalSince1970)
            pool.replaceSubrange(0..<Self.headerSize, with: header)

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try pool.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.building = false
                    self.state = .failed("写入索引失败：\(error.localizedDescription)")
                }
                return
            }
            Log.info("FileIndex", "全盘索引完成：\(count) 条 · "
                     + "\(ByteCountFormatter.string(fromByteCount: Int64(pool.count), countStyle: .file)) · "
                     + "\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s")

            DispatchQueue.main.async {
                self.building = false
                // 立刻 mmap 回来，扫描与写盘使用的局部 Data 随后台任务结束释放。
                if !self.loadFromDisk() {
                    self.state = .failed("索引写入后无法映射")
                }
            }
        }
    }

    /// 要扫的根。
    ///
    /// 只放 Spotlight 明确不覆盖的：`~` 下所有点开头目录、`~/Library`、
    /// `/Applications`（含 .app 内部）、`/opt`、`/usr/local`。
    /// 本机实测：隐藏目录 80 万条 + ~/Library 约 100 万 + Applications 8 万。
    private static func roots() -> [String] {
        let home = NSHomeDirectory()
        var out: [String] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for n in names.sorted() where n.hasPrefix(".") && n != "." && n != ".." {
                let p = home + "/" + n
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    out.append(p)
                }
            }
        }
        for extra in [home + "/Library", "/Applications", "/opt", "/usr/local"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: extra, isDirectory: &isDir), isDir.boolValue {
                out.append(extra)
            }
        }
        return out
    }

    /// 索引里一律不进的路径：Spotlight 自己的索引库（几 GB 二进制，没有搜索价值）
    /// 与我们的索引文件自身（否则重建时会把旧索引也扫进去）。
    private static let skipPrefixes: [String] = {
        let h = NSHomeDirectory()
        return [h + "/Library/Metadata/CoreSpotlight",
                h + "/Library/Caches/com.apple.Spotlight",
                h + "/Library/Application Support/FrsetNext/file-index"]
    }()

    /// 递归收集路径（DFS，先自己再子目录）。
    private static func walk(_ path: String, pool: inout Data, count: inout Int,
                             cap: Int, onProgress: (Int) -> Void) {
        guard pool.count < cap else { return }
        // 路径太长（>4000）多半是异常命名，跳过以免污染池
        guard path.utf8.count < 4000 else { return }
        if skipPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return }

        pool.append(contentsOf: path.utf8)
        pool.append(0)
        count += 1
        onProgress(count)

        guard let dir = opendir(path) else { return }
        defer { closedir(dir) }

        var subdirs: [String] = []
        while let ent = readdir(dir) {
            var nameBuf = ent.pointee.d_name
            let name = withUnsafeBytes(of: &nameBuf) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            let full = path + "/" + name
            if ent.pointee.d_type == UInt8(DT_DIR) {
                // 目录本身留给递归那一层写，避免同一条写两遍
                subdirs.append(full)
            } else {
                guard full.utf8.count < 4000 else { continue }
                pool.append(contentsOf: full.utf8)
                pool.append(0)
                count += 1
                if count % 20_000 == 0 { onProgress(count) }
            }
            if pool.count >= cap { break }
        }
        for d in subdirs {
            walk(d, pool: &pool, count: &count, cap: cap, onProgress: onProgress)
            if pool.count >= cap { return }
        }
    }

    // MARK: - 搜索原语

    /// 查询分词（小写、去空白）
    private static func terms(of query: String) -> [String] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("/") || key.hasPrefix("~/") { return [key] }
        return key.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - 小工具

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func f64(_ b: [UInt8], _ o: Int) -> Double {
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(b[o + i]) << (8 * UInt64(i)) }
        return Double(bitPattern: bits)
    }

    private static func appendU32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }

    private static func appendF64(_ out: inout [UInt8], _ v: Double) {
        var bits = v.bitPattern
        for _ in 0..<8 {
            out.append(UInt8(bits & 0xFF))
            bits >>= 8
        }
    }
}
