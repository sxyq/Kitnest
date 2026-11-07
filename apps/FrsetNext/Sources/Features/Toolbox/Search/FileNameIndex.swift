import Combine
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
//   2) 查询时 mmap 映射这个池，用 Boyer-Moore-Horspool 扫大小写不敏感匹配，
//      命中点向前后回溯到 \0 取完整路径；
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

    @Published private(set) var state: State = .absent {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// 给非 SwiftUI 调用方（例如日志、探针）用
    var onStateChange: ((State) -> Void)?

    // MARK: mmap 视图

    private var map: UnsafeMutableRawPointer?
    private var mapLength = 0
    private var poolOffset = 0
    private var poolLength = 0
    private var entryCount = 0
    private var builtAt: Date?
    /// 只读指针，搜索时零拷贝
    private var pool: UnsafePointer<UInt8>? {
        guard let map else { return nil }
        return UnsafePointer(map.advanced(by: poolOffset).assumingMemoryBound(to: UInt8.self))
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

    /// 在索引里找匹配路径。返回**最多 limit 条**，顺序即 DFS 顺序（浅层在前）。
    ///
    /// - Parameter query: 原始输入，内部做 ASCII 小写归一化
    func search(_ query: String, limit: Int = 120) -> [String] {
        let terms = Self.terms(of: query)
        guard !terms.isEmpty else { return [] }
        // 建索引/替换映射时 `map` 会被 munmap，搜索必须和它互斥
        // （否则可能读到已经释放的页 → EXC_BAD_ACCESS）。
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let pool, poolLength > 0 else { return [] }

        // 多词查询先按「用连字符拼起来」找（目录名习惯这么写），
        // 找不到再退回单词模式，最后统一用 AND 过滤兜底：
        // 「workbuddy skill」→ 路径必须同时含 workbuddy 和 skill。
        var needles = Self.needles(for: terms)
        if needles.isEmpty { needles = [Array(terms[0].utf8)] }
        let termBytes = terms.map { Array($0.utf8) }

        // 候选分两档，短路径优先计数：
        //
        // 池是 DFS 顺序，前面堆着 `.cc-switch` / `.gemini` / `.trae-cn` / `.lmstudio`
        // 这些目录下几千条 `skills/research-router/records/…` 长路径。
        // `~/.workbuddy/skills` 在**全部**合格项里排第 17947 位，但在**短路径**
        // （≤120 字符）里只排第 1417 位——按长度分档才能把它捞进候选（v264 实测）。
        let collectTarget = max(limit * 8, 2500)
        var short: [String] = []      // ≤120 字符，优先
        var long: [String] = []       // 超长路径，兜底
        short.reserveCapacity(collectTarget)
        long.reserveCapacity(500)
        var seen = Set<String>()

        for needle in needles {
            var start = 0
            // 时间预算 180ms：单字/超短 query 会命中几十万次，不能无限扫下去；
            // 但也不能按「命中点数」截断——`workbuddy skill` 用 skill 去扫时，
            // 前几千个命中全在 .gemini/.trae-cn 下，数到 1500 就停会一条都拿不到。
            // 按时间截断既保证有界，又保证能扫遍整池（本机扫完约 75ms）。
            let deadline = CFAbsoluteTimeGetCurrent() + 0.18
            var examined = 0
            while short.count < collectTarget,
                  let hit = Self.bmh(pool, poolLength, needle, from: start) {
                var s = hit
                while s > 0 && pool[s - 1] != 0 { s -= 1 }
                var e = hit + needle.count
                while e < poolLength && pool[e] != 0 { e += 1 }
                start = e + 1
                examined += 1
                if examined % 500 == 0, CFAbsoluteTimeGetCurrent() > deadline { break }

                let path = String(decoding: UnsafeBufferPointer(start: pool + s, count: e - s),
                                  as: UTF8.self)
                guard !path.isEmpty, !seen.contains(path) else { continue }
                // AND 过滤走字节级区域匹配，不要 `String.lowercased()`：
                // `workbuddy skill` 会命中几万个 `skill` 路径，每条都造一个 String
                // 光这一项就要多花 100ms+（v264 实测 356ms → 优化后 ~200ms）。
                if terms.count > 1 {
                    var all = true
                    for t in termBytes where !Self.regionContains(pool, s, e, t) {
                        all = false
                        break
                    }
                    if !all { continue }
                }
                seen.insert(path)
                if path.utf8.count <= 120 {
                    short.append(path)
                } else if long.count < 500 {
                    long.append(path)
                }
            }
            if short.count >= collectTarget { break }
        }
        var out = short
        out.append(contentsOf: long)
        out.sort { a, b in
            let da = Self.depth(a), db = Self.depth(b)
            if da != db { return da < db }
            return a.count < b.count
        }
        return Array(out.prefix(limit))
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
    // 只存一份原样路径。大小写不敏感靠搜索时的 ASCII 折叠表实现——
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
        poolOffset = Self.headerSize
        poolLength = len
        entryCount = count
        builtAt = Date(timeIntervalSince1970: stamp)
        stateLock.unlock()

        state = .ready(count: count, builtAt: builtAt ?? Date())
        return true
    }

    private func unmap() {
        stateLock.lock()
        if let map { munmap(map, mapLength) }
        map = nil
        mapLength = 0
        poolLength = 0
        entryCount = 0
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
            var pool: [UInt8] = []
            pool.reserveCapacity(200 * 1024 * 1024)
            var count = 0
            var lastReport = 0
            let cap = 900 * 1024 * 1024   // 硬上限，防止意外把 / 扫进来撑爆磁盘

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
            guard !pool.isEmpty else {
                DispatchQueue.main.async {
                    self.building = false
                    self.state = .failed("没有可索引的目录")
                }
                return
            }

            // 落盘
            var out = [UInt8]()
            out.reserveCapacity(pool.count + Self.headerSize)
            out.append(contentsOf: Self.magic)
            Self.appendU32(&out, 1)
            Self.appendU32(&out, UInt32(clamping: count))
            Self.appendU32(&out, UInt32(clamping: pool.count))
            Self.appendF64(&out, Date().timeIntervalSince1970)
            out.append(contentsOf: pool)

            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Date()
            do {
                try Data(out).write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    self.building = false
                    self.state = .failed("写入索引失败：\(error.localizedDescription)")
                }
                return
            }
            Log.info("FileIndex", "全盘索引完成：\(count) 条 · "
                     + "\(ByteCountFormatter.string(fromByteCount: Int64(out.count), countStyle: .file)) · "
                     + "\(String(format: "%.1f", Date().timeIntervalSince(stamp)))s")

            DispatchQueue.main.async {
                self.building = false
                // 立刻 mmap 回来（写文件用的是局部数组，池已释放）
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
    private static var skipPrefixes: [String] {
        let h = NSHomeDirectory()
        return [h + "/Library/Metadata/CoreSpotlight",
                h + "/Library/Caches/com.apple.Spotlight",
                h + "/Library/Application Support/FrsetNext/file-index"]
    }

    /// 递归收集路径（DFS，先自己再子目录）。
    private static func walk(_ path: String, pool: inout [UInt8], count: inout Int,
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
        asciiLower(query)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 把查询词展开成候选写法（按「最可能先命中」排序）。
    ///
    /// 多词时先试连字符拼接（`image html deck` → `image-html-deck`，目录名几乎都这么写）；
    /// 拼不上再退回**最后一个词**——用户是从左往右敲的，最后一个词最具体：
    /// `workbuddy skill` 用 `skill` 去扫，命中密度远高于用 `workbuddy`
    /// （后者在池里有 16 万个 `.workbuddy` 前缀命中，扫半天都是同一个目录）。
    private static func needles(for terms: [String]) -> [[UInt8]] {
        guard !terms.isEmpty else { return [] }
        if terms.count == 1 {
            return terms[0].count >= 2 ? [Array(terms[0].utf8)] : []
        }
        var out: [[UInt8]] = [Array(terms.joined(separator: "-").utf8)]
        let tail = terms[terms.count - 1]
        let pivot = tail.count >= 3 ? tail : (terms.max(by: { $0.count < $1.count }) ?? tail)
        if pivot.count >= 2, Array(pivot.utf8) != out[0] {
            out.append(Array(pivot.utf8))
        }
        return out
    }

    /// ASCII 小写（不动非 ASCII 字节）。
    /// 必须自己写：`String.lowercased()` 对某些 Unicode 字符会改变字节长度，
    /// 而我们依赖「折叠前后字节数一致」来保证池内偏移稳定。
    private static func asciiLower(_ s: String) -> String {
        var bytes = Array(s.utf8)
        for i in bytes.indices where bytes[i] >= 65 && bytes[i] <= 90 {
            bytes[i] &+= 32
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 256 项折叠表：A-Z → a-z，其余原样
    private static let fold: [UInt8] = {
        var t = [UInt8](0...255)
        for i in 65...90 { t[i] = UInt8(i + 32) }
        return t
    }()

    /// 在池的 `[start, end)` 区间里找 needle（大小写不敏感）。
    /// 区间只有几十到几百字节，朴素扫描比再建一张 skip 表更快。
    private static func regionContains(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int,
                                       _ needle: [UInt8]) -> Bool {
        let m = needle.count
        guard m > 0, end - start >= m else { return false }
        let last = m - 1
        let lastByte = fold[Int(needle[last])]
        var i = start + last
        while i < end {
            if fold[Int(p[i])] == lastByte {
                var j = 0
                var ok = true
                while j < last {
                    if fold[Int(p[i - last + j])] != fold[Int(needle[j])] {
                        ok = false
                        break
                    }
                    j += 1
                }
                if ok { return true }
            }
            i += 1
        }
        return false
    }

    /// 大小写不敏感的 Boyer-Moore-Horspool。
    /// 170MB 池、10 字节 query，实测几十毫秒；朴素逐字节比较要 1 秒以上。
    private static func bmh(_ hay: UnsafePointer<UInt8>, _ hayLen: Int,
                            _ needle: [UInt8], from: Int) -> Int? {
        let m = needle.count
        guard m > 0, hayLen >= m, from >= 0 else { return nil }
        var skip = [Int](repeating: m, count: 256)
        if m > 1 {
            for i in 0..<(m - 1) {
                skip[Int(fold[Int(needle[i])])] = m - 1 - i
            }
        }
        let lastByte = fold[Int(needle[m - 1])]
        var i = from + m - 1
        while i < hayLen {
            let c = fold[Int(hay[i])]
            if c == lastByte {
                var j = 0
                var matched = true
                while j < m - 1 {
                    if fold[Int(hay[i - m + 1 + j])] != fold[Int(needle[j])] {
                        matched = false
                        break
                    }
                    j += 1
                }
                if matched { return i - m + 1 }
            }
            i += skip[Int(c)]
        }
        return nil
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
