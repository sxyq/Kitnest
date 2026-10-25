import AppKit
import Foundation

// MARK: - 归档引擎（v118；ArcZip 能力接入 / 需求文档 M2·M4）
//
// 用随包分发的 `7zz`（LGPL，见 7zip-License）做真实解压/压缩/回写，
// 不自研压缩格式。全部子进程在后台队列，主线程只收结果。
//
// 覆盖：列条目（-slt 解析）/ 解压全部或单个条目 / 读单个条目内容（实时预览）/
//      更新条目（编辑后重新打包）/ 删除条目 / 创建压缩包（强度、密码）。

public struct ArchiveEntry: Identifiable, Equatable {
    public let path: String          // 归档内完整路径（含目录）
    public let name: String          // 最后一段
    public let size: Int64
    public let packedSize: Int64
    public let modified: String
    public let method: String
    public let isDirectory: Bool
    /// 归档内的父目录（"" = 根）
    public let parent: String
    /// v124：条目是否加密（`Encrypted = +`），行内显示锁图标
    public let isEncrypted: Bool
    /// v127（ArcZip P2）：路径不安全（穿越/绝对路径/设备名段），UI 显示警告图标；
    /// 其中穿越/绝对路径类解压与写回会被拒绝或跳过（isHardUnsafeEntryPath），设备名类仅警告
    public let isUnsafe: Bool

    public init(path: String, name: String, size: Int64, packedSize: Int64,
                modified: String, method: String, isDirectory: Bool, parent: String,
                isEncrypted: Bool = false, isUnsafe: Bool = false) {
        self.path = path; self.name = name; self.size = size; self.packedSize = packedSize
        self.modified = modified; self.method = method; self.isDirectory = isDirectory
        self.parent = parent; self.isEncrypted = isEncrypted; self.isUnsafe = isUnsafe
    }

    public var id: String { path }
    public var sizeText: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    /// 压缩率（0-100，越大越省空间）
    public var ratioText: String {
        guard !isDirectory, size > 0, packedSize > 0 else { return "—" }
        let r = 100 - Int(Double(packedSize) / Double(size) * 100)
        return "\(max(0, min(100, r)))%"
    }
}

public enum ArchiveCore {

    // MARK: 7zz 定位

    /// 随包 7zz（Resources/bin/7zz）→ 工程目录 → PATH
    public static var sevenZipPath: String? {
        if let bundled = Bundle.main.url(forResource: "7zz", withExtension: nil, subdirectory: "bin")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        // 开发期兜底（未打包时直接跑源码目录）
        let dev = "/Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/Resources/bin/7zz"
        if FileManager.default.isExecutableFile(atPath: dev) { return dev }
        for p in ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz", "/opt/homebrew/bin/7z"] where
            FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// 可处理的归档扩展名（ArcZip 33 种里最常用的集合；复合后缀已归并）
    /// v123：补全到 ArcZip 原版一致的 33 种扩展名（附录 A）
    /// ZIP 系 / 7z / TAR 系 / 单文件流 / 磁盘映像 / 其他归档 / 特殊
    public static let archiveExtensions: Set<String> = [
        // ZIP 系
        "zip", "zipx",
        // 7z
        "7z",
        // RAR（只读）
        "rar", "cbr",
        // TAR 系
        "tar", "tgz", "tbz", "tbz2", "txz",
        // 单文件流
        "gz", "gzip", "bz2", "bzip2", "xz", "lzma", "lz",
        // 磁盘映像（只读）
        "dmg", "iso",
        // 其他归档（只读）
        "cab", "cpio", "arj", "lha", "lzh", "xar", "rpm", "msi", "pkg",
        "jar", "apk", "spk", "whl", "xpi",
        // 特殊
        "exe", "swf", "001", "zst"
    ]

    public static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if archiveExtensions.contains(ext) { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz")
    }

    /// 可写（新建/回写）格式——与 FR-401 一致：ZIP / 7z 可编辑，其余只读浏览
    public static func isEditable(_ url: URL) -> Bool {
        ["zip", "7z"].contains(url.pathExtension.lowercased())
    }

    // MARK: 辅助文件（v124；ArcZip「辅助文件过滤」）

    /// macOS / Windows 打包时产生的辅助文件，浏览与解压默认过滤
    /// `__MACOSX/` 资源叉、`._*` AppleDouble、`.DS_Store`、`Thumbs.db`、`desktop.ini`
    public static func isAuxiliary(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini" { return true }
        if name.hasPrefix("._") { return true }
        if path == "__MACOSX" || path.hasPrefix("__MACOSX/") || path.contains("/__MACOSX/") {
            return true
        }
        return false
    }

    /// 解压时排除辅助文件的 `-x!` 参数（includeAuxiliary = true 则全保留）
    private static func auxExcludeArgs(_ includeAuxiliary: Bool) -> [String] {
        guard !includeAuxiliary else { return [] }
        return ["-x!__MACOSX*", "-x!.DS_Store", "-x!Thumbs.db", "-x!desktop.ini", "-x!._*"]
    }

    // MARK: Windows 文件名检测 / 修正（v127（ArcZip P2）：ArcZip「检测 Windows 保留名/非法字符」）

    /// Windows 保留设备名（不区分大小写；`CON.txt` 这种带扩展名的也算）
    private static let windowsReservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// 取「第一个点之前」的基名判保留名（Windows 就是这么判的：`CON.txt` 也非法）
    private static func windowsReservedBase(_ name: String) -> String? {
        let stem = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { String($0) } ?? name
        let up = stem.uppercased()
        return windowsReservedNames.contains(up) ? up : nil
    }

    /// 文件名在 Windows 上是否有问题；有问题返回问题描述（弹窗文案用），无问题返回 nil
    /// 检查项：非法字符 `<>:"/\|?*`、控制字符 0-31、结尾空格/点、保留名 CON/PRN/AUX/NUL/COM1-9/LPT1-9
    public static func windowsUnsafeName(_ name: String) -> String? {
        if name.isEmpty { return "空文件名" }
        if name.unicodeScalars.contains(where: { $0.value < 32 }) {
            return "含控制字符（0-31）"
        }
        let illegal = "<>:\"/\\|?*"
        if let ch = name.first(where: { illegal.contains($0) }) {
            return "含非法字符「\(ch)」（Windows 不允许 <>:\"/\\|?*）"
        }
        if name.hasSuffix(" ") || name.hasSuffix(".") {
            return "结尾是空格或点（Windows 会截断）"
        }
        if let base = windowsReservedBase(name) {
            return "保留名 \(base)（Windows 上无法打开）"
        }
        return nil
    }

    /// 建议新名（只改包内名，原磁盘文件不动）：非法字符 → `_`，结尾空格/点去掉，保留名前加 `_`
    public static func sanitizeWindowsName(_ name: String) -> String {
        var out = ""
        for ch in name {
            if ch.unicodeScalars.contains(where: { $0.value < 32 })
                || "<>:\"/\\|?*".contains(ch) {
                out.append("_")
            } else {
                out.append(ch)
            }
        }
        while out.hasSuffix(" ") || out.hasSuffix(".") { out.removeLast() }
        if out.isEmpty { out = "_" }
        if windowsReservedBase(out) != nil { out = "_" + out }
        return out
    }

    /// 批量扫描（创建/添加文件前弹窗列表用）
    public static func windowsNameIssues(_ names: [String])
        -> [(name: String, reason: String, suggested: String)] {
        names.compactMap { n in
            guard let reason = windowsUnsafeName(n) else { return nil }
            return (name: n, reason: reason, suggested: sanitizeWindowsName(n))
        }
    }

    /// 改名后可能撞名（`a:b` 与 `a?b` 都变成 `a_b`）→ 加序号去重
    static func uniqueWindowsNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.map { name in
            let lower = name.lowercased()
            guard seen.contains(lower) else { seen.insert(lower); return name }
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var i = 2
            var cand = ""
            repeat {
                cand = ext.isEmpty ? "\(stem)-\(i)" : "\(stem)-\(i).\(ext)"
                i += 1
            } while seen.contains(cand.lowercased())
            seen.insert(cand.lowercased())
            return cand
        }
    }

    // MARK: 路径安全显式校验（v127（ArcZip P2）：拒绝 `../`、绝对路径、设备名等不安全路径）

    /// 硬不安全（真漏洞面——解压/写回直接拒绝或跳过）：
    ///   · 路径穿越：任一段是 `..`（`../x`、`x/..`、`..\\x`）
    ///   · 绝对路径：`/` 开头、`~` 开头、盘符 `C:\`、UNC `\\server`
    ///   · 空路径、含 `\0`
    /// v127.1（与 arch-browser 会商）：设备名段从硬拒里拆出——macOS 上 CON/NUL 是合法
    ///   文件名，mac 打包的归档常见 `dir/CON.txt`，硬拒会让预览/拖出/解压全挂且丢数据；
    ///   设备名改为「只警告不跳过」（isUnsafeEntryPath 照标，UI 已有警告图标）。
    public static func isHardUnsafeEntryPath(_ path: String) -> Bool {
        if path.isEmpty || path.contains("\0") { return true }
        // 绝对路径 / 家目录 / UNC
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("\\") { return true }
        // Windows 盘符（C: 或 C:\...）
        if path.count >= 2 {
            let a = path.startIndex, b = path.index(after: a)
            if path[a].isLetter && path[b] == ":" { return true }
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        for seg in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == ".." { return true }                                   // 路径穿越
        }
        return false
    }

    /// 归档内条目路径是否有安全隐患（含设备名段，UI 警告用）：
    ///   · 硬不安全（isHardUnsafeEntryPath）→ 解压/写回拒绝或跳过
    ///   · 设备名段（CON/NUL 等，含 `dir/CON.txt`）→ 仅标警告不拦截（macOS 合法文件名）
    /// 测试思路（不必建测试文件）：构造含 `../evil.txt`、`/etc/evil`、`C:\evil` 的 zip，
    /// `list` 应标 isUnsafe=true 且 extract 拒绝/跳过并记数；`dir/CON.txt` 只标警告、可正常解压。
    public static func isUnsafeEntryPath(_ path: String) -> Bool {
        if isHardUnsafeEntryPath(path) { return true }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        for seg in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if windowsReservedBase(String(seg)) != nil { return true }       // 设备名（仅警告）
        }
        return false
    }

    // MARK: 密码缓存（v124；ArcZip「密码缓存」——同一归档一次会话只问一次）

    public enum ArchivePasswords {
        private static var cache: [String: String] = [:]
        private static let lock = NSLock()

        public static func get(_ url: URL) -> String? {
            lock.lock(); defer { lock.unlock() }
            return cache[url.standardizedFileURL.path]
        }

        public static func set(_ password: String?, for url: URL) {
            lock.lock(); defer { lock.unlock() }
            cache[url.standardizedFileURL.path] = password
        }

        /// 判断 7zz 报错是不是「要密码」（实测文案见注释）
        /// 7z: `Cannot open encrypted archive. Wrong password?`
        public static func looksLikePasswordError(_ text: String) -> Bool {
            let t = text.lowercased()
            return t.contains("wrong password")
                || t.contains("cannot open encrypted")
                || t.contains("can not open encrypted")
                || t.contains("data error in encrypted")
                || t.contains("encrypted archive")
                || t.contains("enter password")
                || t.contains("口令")
        }
    }

    // MARK: 压缩用途预设（v124；ArcZip「压缩用途预设」5 种）

    public struct ArchivePreset: Identifiable {
        public let title: String
        public let detail: String
        /// 7zz 的 -t 参数（tar.gz 走两趟：先 tar 再 gzip）
        public let format: String
        /// 0(store) - 9(ultra)
        public let level: Int
        public var id: String { title }
    }

    public static let presets: [ArchivePreset] = [
        .init(title: "通用分享",
              detail: "ZIP · 均衡，任何系统都能直接打开",
              format: "zip", level: 5),
        .init(title: "Mac 之间传递",
              detail: "7z · 保留 macOS 元数据，压缩率更高",
              format: "7z", level: 5),
        .init(title: "Windows 用户",
              detail: "ZIP · Windows 资源管理器直接解压",
              format: "zip", level: 5),
        .init(title: "Linux 与服务器",
              detail: "tar.gz · 命令行友好，保留权限与软链",
              format: "tar.gz", level: 5),
        .init(title: "尽可能小",
              detail: "7z · 最高压缩率，体积最小、耗时更长",
              format: "7z", level: 9),
    ]

    // MARK: 基础执行

    /// 运行 7zz（后台）：返回（退出码, stdout, stderr）
    /// v127（ArcZip P2）：
    ///   · `taskID` —— 把 Process 注册进 ArchiveTaskQueue，`cancel(taskID)` 会 terminate 它（取消传播）
    ///   · `onProgress` —— 传入时自动加 `-bsp1`，从 stdout 流式解析 `NN%` 回调；
    ///     解析不到就不回调，面板走 indeterminate（不确定进度兜底）
    static func run(_ args: [String], timeout: TimeInterval = 300,
                    taskID: UUID? = nil,
                    onProgress: ((Double) -> Void)? = nil,
                    completion: @escaping (Int32, Data, String) -> Void) {
        execute(args, cwd: nil, timeout: timeout, taskID: taskID,
                onProgress: onProgress, completion: completion)
    }

    /// 带工作目录执行
    private static func runIn(_ args: [String], cwd: URL, timeout: TimeInterval = 300,
                              taskID: UUID? = nil,
                              onProgress: ((Double) -> Void)? = nil,
                              completion: @escaping (Int32, Data, String) -> Void) {
        execute(args, cwd: cwd, timeout: timeout, taskID: taskID,
                onProgress: onProgress, completion: completion)
    }

    /// run / runIn 共同实现
    private static func execute(_ args: [String], cwd: URL?, timeout: TimeInterval,
                                taskID: UUID?, onProgress: ((Double) -> Void)?,
                                completion: @escaping (Int32, Data, String) -> Void) {
        guard let bin = sevenZipPath else {
            DispatchQueue.main.async { completion(-1, Data(), "未找到 7zz") }
            return
        }
        // -bsp1：7zz 把进度百分比打到 stdout（形如 ` 45%`）；只有要进度时才加，
        // 免得污染 `l -slt` 的解析输出 / `e -so` 的二进制内容
        var fullArgs = args
        if onProgress != nil { fullArgs.append("-bsp1") }

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: bin)
            if let cwd { task.currentDirectoryURL = cwd }
            task.arguments = fullArgs
            let outPipe = Pipe(), errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            // v127：双管道各起一个读线程（读到 EOF）——比原先「先读完 stdout 再读 stderr」
            // 更稳（stderr 缓冲塞满不会互锁），且能边读边解析 -bsp1 进度
            let outBox = StreamBox(), errBox = StreamBox()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                readStream(outPipe.fileHandleForReading, into: outBox, onProgress: onProgress)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                readStream(errPipe.fileHandleForReading, into: errBox, onProgress: nil)
                group.leave()
            }

            do { try task.run() } catch {
                // 没起子进程时父侧写端仍在手里，读线程等不到 EOF——先关掉再收工
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                group.wait()
                DispatchQueue.main.async { completion(-1, Data(), error.localizedDescription) }
                return
            }
            // v127：注册进任务队列 → cancel(taskID) terminate 这个 Process（取消传播落点）
            ArchiveTaskQueue.shared.registerProcess(task, for: taskID)

            // 超时看门狗（沿用原 300s 语义）：到点还活着就 terminate
            let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            group.wait()
            task.waitUntilExit()
            watchdog.cancel()
            ArchiveTaskQueue.shared.unregisterProcess(task, for: taskID)

            let errText = String(data: errBox.data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                completion(task.terminationStatus, outBox.data, errText)
            }
        }
    }

    /// 单管道收集器（线程安全；progressState 只被自己的读线程碰）
    private final class StreamBox {
        private let lock = NSLock()
        private var buffer = Data()
        var lastPercent = -1
        func append(_ d: Data) {
            lock.lock(); buffer.append(d); lock.unlock()
        }
        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }
    }

    private static func readStream(_ handle: FileHandle, into box: StreamBox,
                                   onProgress: ((Double) -> Void)?) {
        while true {
            let chunk = handle.availableData    // 阻塞到有数据或 EOF
            if chunk.isEmpty { break }
            box.append(chunk)
            if let onProgress, let text = String(data: chunk, encoding: .utf8) {
                parseProgress(text, box: box, onProgress: onProgress)
            }
        }
    }

    private static let progressRegex = try? NSRegularExpression(pattern: #"(\d{1,3})\s*%"#)

    /// 从 7zz -bsp1 输出块里抓最后一个 ≤100 的 `NN%`；值没变就不回调（省 UI 刷新）
    private static func parseProgress(_ text: String, box: StreamBox,
                                      onProgress: (Double) -> Void) {
        guard let regex = progressRegex else { return }
        let ns = text as NSString
        var found = -1
        regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).forEach { m in
            let v = Int(ns.substring(with: m.range(at: 1))) ?? -1
            if v >= 0 && v <= 100 { found = v }
        }
        guard found >= 0, found != box.lastPercent else { return }
        box.lastPercent = found
        onProgress(Double(found) / 100.0)
    }

    /// 任务进度回调（仅当跑在队列任务里时才非 nil）
    private static func progressCallback(_ taskID: UUID?, phase: String) -> ((Double) -> Void)? {
        guard let taskID else { return nil }
        return { p in
            ArchiveTaskQueue.shared.updateProgress(taskID: taskID, p, message: phase)
        }
    }

    private static func passwordArg(_ password: String?) -> [String] {
        guard let password, !password.isEmpty else { return ["-p"] }
        return ["-p\(password)"]
    }

    // MARK: 列条目（FR-202）

    /// 列出条目。密码留空时自动用会话缓存；`includeAuxiliary = false` 时过滤
    /// `__MACOSX` / `.DS_Store` 等辅助文件（v124）。
    public static func list(url: URL, password: String? = nil,
                            includeAuxiliary: Bool = false,
                            completion: @escaping ([ArchiveEntry], String?) -> Void) {
        var args = ["l", "-slt", "-ba"]
        args += passwordArg(password ?? ArchivePasswords.get(url))
        args += [url.path]
        run(args, timeout: 60) { code, data, err in
            guard code == 0 else {
                let msg = err.isEmpty ? "无法读取归档（可能需要密码）" : err
                completion([], msg.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }
            var entries = parseListOutput(String(data: data, encoding: .utf8) ?? "")
            if !includeAuxiliary {
                entries = entries.filter { !isAuxiliary($0.path) }
            }
            completion(entries, nil)
        }
    }

    /// 解析 `7zz l -slt -ba`：空行分隔块，`Key = Value`
    static func parseListOutput(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]

        func flush() {
            guard let path = fields["Path"], !path.isEmpty else { fields = [:]; return }
            let isDir = (fields["Folder"] == "+") || path.hasSuffix("/")
            let name = isDir
                ? String(path.split(separator: "/").last ?? "")
                : (path as NSString).lastPathComponent
            var parent = ""
            if let slash = path.lastIndex(of: "/") {
                parent = String(path[..<slash])
            }
            entries.append(ArchiveEntry(
                path: path.hasSuffix("/") ? String(path.dropLast()) : path,
                name: name,
                size: Int64(fields["Size"] ?? "0") ?? 0,
                packedSize: Int64(fields["Packed Size"] ?? "0") ?? 0,
                modified: fields["Modified"] ?? "",
                method: fields["Method"] ?? "",
                isDirectory: isDir,
                parent: parent,
                isEncrypted: fields["Encrypted"] == "+",
                // v127（ArcZip P2）：不安全路径打标（UI 警告 + 解压时跳过）
                isUnsafe: isUnsafeEntryPath(path)))
            fields = [:]
        }

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            guard let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[eq.upperBound...])
            fields[key] = value
        }
        flush()
        // 目录按层级排序（父在子前），便于树形展示
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: 读取单个条目（FR-407 实时预览用，不落地）

    /// 读取条目内容到内存（文本/图片预览）；limit 限制大小（默认 8MB）
    public static func readEntry(url: URL, entry: ArchiveEntry, password: String? = nil,
                                 limit: Int = 8 * 1024 * 1024,
                                 completion: @escaping (Data?, String?) -> Void) {
        guard entry.size <= Int64(limit) else {
            completion(nil, "文件过大（\(entry.sizeText)），请解压后用默认应用打开")
            return
        }
        var args = ["e", "-so", "-y"]
        args += passwordArg(password ?? ArchivePasswords.get(url))
        args += [url.path, entry.path]
        run(args, timeout: 60) { code, data, err in
            if code == 0 { completion(data, nil) }
            else { completion(nil, err.isEmpty ? "读取失败" : err) }
        }
    }

    // MARK: 解压（FR-206）

    /// 解压全部（entry == nil）或单个条目到目标目录
    /// `includeAuxiliary = false` 时丢弃 `__MACOSX` / `.DS_Store` 等（v124）
    /// v127（ArcZip P2）：
    ///   · 走任务队列（进度面板 + 可取消），返回 taskID（@discardableResult，旧调用方不接也不破坏）
    ///   · 解压前用 `list` 显式校验条目路径，硬不安全（`../` 穿越、绝对路径、盘符、UNC）的条目
    ///     默认跳过，并在 message 里记「已跳过 N 个不安全路径」；整包硬不安全则整包拒绝。
    ///     设备名段（CON/NUL 等）只经 ArchiveEntry.isUnsafe 警告、不拦不跳（v127.1）
    @discardableResult
    public static func extract(url: URL, entry: String? = nil, to dir: URL,
                               password: String? = nil,
                               includeAuxiliary: Bool = false,
                               completion: @escaping (Bool, String) -> Void) -> UUID? {
        let title = entry.map { "解压 \($0)" } ?? "解压 \(url.lastPathComponent)"
        return ArchiveTaskQueue.shared.enqueue(kind: .extract, title: title) { taskID, done in
            // 队列记账 + 原调用方回调（一次 work 只收尾一次）
            func both(_ ok: Bool, _ msg: String) {
                // v127：取消传播的统一收尾——被 terminate 的 7zz 可能报空错，
                // 对外一律回「已取消」，别把取消显示成失败
                let cancelled = !ok && ArchiveTaskQueue.shared.isCancelled(taskID)
                done(ok, msg)
                // 保持原 API 语义：结果回主线程（run 的回调本在主线程，这里兜底早期返回路径）
                DispatchQueue.main.async { completion(ok, cancelled ? "已取消" : msg) }
            }
            let pw = password ?? ArchivePasswords.get(url)
            ArchiveTaskQueue.shared.updateProgress(taskID: taskID, -1, message: "核对路径…")
            // 校验用的 list 要看全量条目（含辅助文件），不放过任何一条路径
            list(url: url, password: pw, includeAuxiliary: true) { entries, _ in
                if ArchiveTaskQueue.shared.isCancelled(taskID) {
                    both(false, "已取消")
                    return
                }
                // 单条目解压：直接判（v127.1：设备名不拦，只拦穿越/绝对路径类）
                if let entry {
                    if isHardUnsafeEntryPath(entry) {
                        both(false, "已拦截不安全路径：\(entry)")
                        return
                    }
                    performExtract(url: url, entry: entry, to: dir, password: pw,
                                   includeAuxiliary: includeAuxiliary,
                                   restrictTo: nil, taskID: taskID, completion: both)
                    return
                }
                // 全量解压：挑出硬不安全条目（穿越/绝对路径；设备名类不跳，仅 UI 警告）
                let unsafe = entries.filter { isHardUnsafeEntryPath($0.path) }
                if !entries.isEmpty && unsafe.count == entries.count {
                    both(false, "归档内 \(entries.count) 个路径全部不安全，已拒绝解压")
                    return
                }
                // 有硬不安全条目时只解压安全的（显式列路径 = 跳过不安全项）
                var restrict: [String]? = nil
                if !unsafe.isEmpty {
                    let safe = entries.filter { !$0.isDirectory && !isHardUnsafeEntryPath($0.path) }
                        .map { $0.path }
                    // 条目太多时命令行放不下 → 退化为整包解压（仅在 message 警告）
                    restrict = safe.count <= 1500 ? safe : nil
                }
                performExtract(url: url, entry: nil, to: dir, password: pw,
                               includeAuxiliary: includeAuxiliary,
                               restrictTo: restrict, taskID: taskID) { ok, msg in
                    both(ok, ok && !unsafe.isEmpty
                         ? msg + "（已跳过 \(unsafe.count) 个不安全路径）"
                         : msg)
                }
            }
        }
    }

    /// 真正跑 7zz 解压（不入队，供队列体与临时解压共用）。
    /// `restrictTo` 非 nil 时只解压列出的条目路径（= 显式跳过不安全项）。
    private static func performExtract(url: URL, entry: String?, to dir: URL,
                                       password: String?, includeAuxiliary: Bool,
                                       restrictTo: [String]?,
                                       taskID: UUID?,
                                       completion: @escaping (Bool, String) -> Void) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let restrictTo, restrictTo.isEmpty {
            // 一条可安全解压的都没有（例如文件全在不安全目录下）
            DispatchQueue.main.async { completion(true, "没有可安全解压的条目") }
            return
        }
        var args = ["x", "-y", "-o\(dir.path)"]
        args += passwordArg(password)
        args += auxExcludeArgs(includeAuxiliary)
        args += [url.path]
        if let restrictTo {
            args += restrictTo
        } else if let entry {
            args.append(entry)
        }
        run(args, taskID: taskID, onProgress: progressCallback(taskID, phase: "解压中…")) {
            code, _, err in
            completion(code == 0, code == 0 ? "已解压到 \(dir.path)" : err)
        }
    }

    /// 解压单个条目到临时目录，返回落地文件 URL（Office 预览 / 外部打开用）
    /// v127：不入队（预览/缩略图不该进任务面板），同样做路径安全校验
    /// v127.1：只拦硬不安全（穿越/绝对路径），设备名类（CON.txt 等）放行——macOS 合法文件
    public static func extractEntryToTemp(url: URL, entry: ArchiveEntry,
                                          completion: @escaping (URL?, String) -> Void) {
        guard !isHardUnsafeEntryPath(entry.path) else {
            completion(nil, "已拦截不安全路径：\(entry.path)")
            return
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frset-archive-\(UUID().uuidString)", isDirectory: true)
        performExtract(url: url, entry: entry.path, to: dir, password: nil,
                       includeAuxiliary: false, restrictTo: nil, taskID: nil) { ok, msg in
            guard ok else { completion(nil, msg); return }
            // 7zz x 会保留目录结构；在 dir 下找同名文件
            let candidate = dir.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                completion(candidate, "")
                return
            }
            // 兜底：递归找同名
            if let found = FileManager.default.subpaths(atPath: dir.path)?
                .first(where: { ($0 as NSString).lastPathComponent == entry.name }) {
                completion(dir.appendingPathComponent(found), "")
            } else {
                completion(nil, "解压后未找到文件")
            }
        }
    }

    // MARK: 编辑回写（FR-402/404：添加 / 更新 / 删除）

    /// 用本地文件更新归档内某个路径（编辑保存 / 添加文件）
    /// - 做法：在临时目录按归档内相对路径放好文件，再 `7zz a` 回写，保证包内路径不变
    /// v127（ArcZip P2）：走任务队列（进度 + 可取消），返回 taskID
    @discardableResult
    public static func updateEntry(url: URL, entryPath: String, localFile: URL,
                                   password: String? = nil,
                                   completion: @escaping (Bool, String) -> Void) -> UUID? {
        return ArchiveTaskQueue.shared.enqueue(kind: .add,
                                               title: "写回 \(entryPath)") { taskID, done in
            func both(_ ok: Bool, _ msg: String) {
                // v127：取消传播的统一收尾——被 terminate 的 7zz 可能报空错，
                // 对外一律回「已取消」，别把取消显示成失败
                let cancelled = !ok && ArchiveTaskQueue.shared.isCancelled(taskID)
                done(ok, msg)
                // 保持原 API 语义：结果回主线程（run 的回调本在主线程，这里兜底早期返回路径）
                DispatchQueue.main.async { completion(ok, cancelled ? "已取消" : msg) }
            }
            guard !isHardUnsafeEntryPath(entryPath) else {
                both(false, "已拦截不安全路径：\(entryPath)")
                return
            }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-archive-stage-\(UUID().uuidString)", isDirectory: true)
            let dest = staging.appendingPathComponent(entryPath)
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: localFile, to: dest)
            } catch {
                both(false, "准备写入失败：\(error.localizedDescription)")
                return
            }
            if ArchiveTaskQueue.shared.isCancelled(taskID) {
                try? FileManager.default.removeItem(at: staging)
                both(false, "已取消")
                return
            }
            var args = ["a", "-y"]
            args += passwordArg(password)
            args += [url.path, entryPath]   // 相对路径 + cwd=staging → 包内路径保持不变
            runIn(args, cwd: staging, taskID: taskID,
                  onProgress: progressCallback(taskID, phase: "写回中…")) { code, _, err in
                try? FileManager.default.removeItem(at: staging)
                both(code == 0, code == 0 ? "已写回归档" : err)
            }
        }
    }

    /// 归档内重命名（`7zz rn`：直接改包内路径，不开新包、不留备份）
    /// v127（ArcZip P2）：走任务队列，返回 taskID
    @discardableResult
    public static func renameEntry(url: URL, entryPath: String, newName: String,
                                   password: String? = nil,
                                   completion: @escaping (Bool, String) -> Void) -> UUID? {
        return ArchiveTaskQueue.shared.enqueue(kind: .rename,
                                               title: "重命名为 \(newName)") { taskID, done in
            func both(_ ok: Bool, _ msg: String) {
                // v127：取消传播的统一收尾——被 terminate 的 7zz 可能报空错，
                // 对外一律回「已取消」，别把取消显示成失败
                let cancelled = !ok && ArchiveTaskQueue.shared.isCancelled(taskID)
                done(ok, msg)
                // 保持原 API 语义：结果回主线程（run 的回调本在主线程，这里兜底早期返回路径）
                DispatchQueue.main.async { completion(ok, cancelled ? "已取消" : msg) }
            }
            // v127：新名只取最后一段，先过硬安全闸（穿越/绝对路径；设备名不拦）
            guard !isHardUnsafeEntryPath(newName), !newName.contains("/") else {
                both(false, "已拦截不安全名称：\(newName)")
                return
            }
            let dir = (entryPath as NSString).deletingLastPathComponent
            let target = dir.isEmpty ? newName : dir + "/" + newName
            guard target != entryPath else {
                both(true, "名称未变")
                return
            }
            var args = ["rn"]
            args += passwordArg(password)
            args += [url.path, entryPath, target]
            run(args, taskID: taskID) { code, _, err in
                both(code == 0, code == 0 ? "已重命名为 \(newName)" : err)
            }
        }
    }

    /// 添加若干本地文件到归档根（或指定目录）
    /// v127（ArcZip P2）：走任务队列（进度 + 可取消），返回 taskID
    @discardableResult
    public static func addFiles(url: URL, files: [URL], intoDirectory: String = "",
                                password: String? = nil,
                                completion: @escaping (Bool, String) -> Void) -> UUID? {
        return ArchiveTaskQueue.shared.enqueue(kind: .add,
                                               title: "添加 \(files.count) 个文件到 \(url.lastPathComponent)") {
            taskID, done in
            func both(_ ok: Bool, _ msg: String) {
                // v127：取消传播的统一收尾——被 terminate 的 7zz 可能报空错，
                // 对外一律回「已取消」，别把取消显示成失败
                let cancelled = !ok && ArchiveTaskQueue.shared.isCancelled(taskID)
                done(ok, msg)
                // 保持原 API 语义：结果回主线程（run 的回调本在主线程，这里兜底早期返回路径）
                DispatchQueue.main.async { completion(ok, cancelled ? "已取消" : msg) }
            }
            // v127：目标目录路径过硬安全闸（穿越/绝对路径；设备名不拦）
            if !intoDirectory.isEmpty && isHardUnsafeEntryPath(intoDirectory) {
                both(false, "已拦截不安全路径：\(intoDirectory)")
                return
            }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-archive-add-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var rel: [String] = []
                for f in files {
                    var target = staging.appendingPathComponent(f.lastPathComponent)
                    if !intoDirectory.isEmpty {
                        target = staging.appendingPathComponent(intoDirectory)
                            .appendingPathComponent(f.lastPathComponent)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                    }
                    try FileManager.default.copyItem(at: f, to: target)
                    rel.append(intoDirectory.isEmpty
                               ? f.lastPathComponent
                               : intoDirectory + "/" + f.lastPathComponent)
                }
                if ArchiveTaskQueue.shared.isCancelled(taskID) {
                    try? FileManager.default.removeItem(at: staging)
                    both(false, "已取消")
                    return
                }
                var args = ["a", "-y"]
                args += passwordArg(password)
                args += [url.path] + rel
                runIn(args, cwd: staging, taskID: taskID,
                      onProgress: progressCallback(taskID, phase: "添加中…")) { code, _, err in
                    try? FileManager.default.removeItem(at: staging)
                    both(code == 0, code == 0 ? "已添加 \(files.count) 个文件" : err)
                }
            } catch {
                both(false, "准备添加失败：\(error.localizedDescription)")
            }
        }
    }

    /// 删除归档内条目
    /// v127（ArcZip P2）：走任务队列，返回 taskID
    @discardableResult
    public static func removeEntries(url: URL, entryPaths: [String], password: String? = nil,
                                     completion: @escaping (Bool, String) -> Void) -> UUID? {
        guard !entryPaths.isEmpty else {
            completion(false, "没有选中条目")
            return nil
        }
        return ArchiveTaskQueue.shared.enqueue(kind: .remove,
                                               title: "删除 \(entryPaths.count) 项") { taskID, done in
            func both(_ ok: Bool, _ msg: String) {
                // v127：取消传播的统一收尾——被 terminate 的 7zz 可能报空错，
                // 对外一律回「已取消」，别把取消显示成失败
                let cancelled = !ok && ArchiveTaskQueue.shared.isCancelled(taskID)
                done(ok, msg)
                // 保持原 API 语义：结果回主线程（run 的回调本在主线程，这里兜底早期返回路径）
                DispatchQueue.main.async { completion(ok, cancelled ? "已取消" : msg) }
            }
            var args = ["d", "-y"]
            args += passwordArg(password)
            args += [url.path] + entryPaths
            run(args, taskID: taskID) { code, _, err in
                both(code == 0, code == 0 ? "已删除 \(entryPaths.count) 项" : err)
            }
        }
    }

    /// 创建压缩包（FR-301/302；level 0-9）
    /// - volumeMB > 0 时分卷（生成 `.001/.002/…`，v124）
    /// - 格式 `tar.gz` 走两趟：先 `-ttar` 打包，再 `-tgzip` 压缩（保留权限/软链）
    /// - 密码写入会话缓存，之后浏览/解压不再询问
    /// v127（ArcZip P2）：
    ///   · 走任务队列（进度 + 可取消），返回 taskID
    ///   · `useWindowsSafeNames = true` 时把包内名换成 Windows 安全名
    ///     （原磁盘文件不动：复制到临时目录改名后再打包）
    @discardableResult
    public static func create(files: [URL], to archiveURL: URL, level: Int = 5,
                              password: String? = nil, volumeMB: Int = 0,
                              useWindowsSafeNames: Bool = false,
                              completion: @escaping (Bool, String) -> Void) -> UUID? {
        guard !files.isEmpty else {
            completion(false, "没有选中文件")
            return nil
        }
        return ArchiveTaskQueue.shared.enqueue(kind: .compress,
                                               title: "创建 \(archiveURL.lastPathComponent)") {
            taskID, done in
            func both(_ ok: Bool, _ msg: String) {
                // v127：取消传播的统一收尾——被 terminate 的 7zz 可能报空错，
                // 对外一律回「已取消」，别把取消显示成失败
                let cancelled = !ok && ArchiveTaskQueue.shared.isCancelled(taskID)
                done(ok, msg)
                // 保持原 API 语义：结果回主线程（run 的回调本在主线程，这里兜底早期返回路径）
                DispatchQueue.main.async { completion(ok, cancelled ? "已取消" : msg) }
            }
            guard let first = files.first else {
                both(false, "没有选中文件")
                return
            }
            var base = first.deletingLastPathComponent()
            var names = files.map { $0.lastPathComponent }
            var staging: URL? = nil
            let name = archiveURL.lastPathComponent.lowercased()

            // v127（ArcZip P2）：Windows 文件名修正——包内名用建议名，磁盘原名不动
            if useWindowsSafeNames {
                let sanitized = uniqueWindowsNames(names.map { sanitizeWindowsName($0) })
                if sanitized != names {
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("frset-archive-create-\(UUID().uuidString)",
                                                isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: dir,
                                                                withIntermediateDirectories: true)
                        for (f, newName) in zip(files, sanitized) {
                            try FileManager.default.copyItem(at: f,
                                                             to: dir.appendingPathComponent(newName))
                        }
                        base = dir
                        names = sanitized
                        staging = dir
                    } catch {
                        try? FileManager.default.removeItem(at: dir)
                        both(false, "准备改名失败：\(error.localizedDescription)")
                        return
                    }
                }
            }

            if ArchiveTaskQueue.shared.isCancelled(taskID) {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                both(false, "已取消")
                return
            }

            func finalize(_ code: Int32, _ err: String) {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                if code == 0 {
                    if let password, !password.isEmpty {
                        ArchivePasswords.set(password, for: archiveURL)
                    }
                    let vol = volumeMB > 0 ? "（分卷 \(volumeMB) MB）" : ""
                    both(true, "已创建 \(archiveURL.lastPathComponent)\(vol)")
                } else {
                    both(false, err)
                }
            }

            let progress = progressCallback(taskID, phase: "压缩中…")

            // tar.gz：先 tar 再 gzip（7zz 不能一趟出 tar.gz）
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
                let dir = archiveURL.deletingLastPathComponent()
                let stem = name.hasSuffix(".tar.gz")
                    ? String(archiveURL.lastPathComponent.dropLast(7))
                    : String(archiveURL.lastPathComponent.dropLast(4))
                let tarURL = dir.appendingPathComponent(stem + ".tar")
                var tarArgs = ["a", "-ttar", "-y"]
                tarArgs += passwordArg(password)
                if volumeMB > 0 { tarArgs.append("-v\(max(1, volumeMB))m") }
                tarArgs += [tarURL.path] + names
                runIn(tarArgs, cwd: base, taskID: taskID, onProgress: progress) { code, _, err in
                    guard code == 0 else {
                        finalize(code, err)
                        return
                    }
                    // 单卷直接 gzip；分卷时 7zz 已切成 .tar.001…，不再二次压缩
                    guard volumeMB == 0 else {
                        finalize(0, "")
                        return
                    }
                    if ArchiveTaskQueue.shared.isCancelled(taskID) {
                        try? FileManager.default.removeItem(at: tarURL)
                        finalize(-1, "已取消")
                        return
                    }
                    var gzArgs = ["a", "-tgzip", "-mx=\(max(0, min(9, level)))", "-y"]
                    gzArgs += passwordArg(password)
                    gzArgs += [archiveURL.path, tarURL.lastPathComponent]
                    runIn(gzArgs, cwd: dir, taskID: taskID, onProgress: progress) {
                        code2, _, err2 in
                        try? FileManager.default.removeItem(at: tarURL)
                        finalize(code2, err2)
                    }
                }
                return
            }

            let ext = archiveURL.pathExtension.isEmpty ? "zip" : archiveURL.pathExtension
            var args = ["a", "-t\(ext)", "-mx=\(max(0, min(9, level)))", "-y"]
            args += passwordArg(password)
            if volumeMB > 0 { args.append("-v\(max(1, volumeMB))m") }
            args += [archiveURL.path] + names
            runIn(args, cwd: base, taskID: taskID, onProgress: progress) { code, _, err in
                finalize(code, err)
            }
        }
    }

    /// 另存为带密码的归档（v124；ArcZip「保存为加密归档」）
    /// 全部解到临时目录再用 `-p` 重打，等价于「编辑后另存加密」。
    /// v127（ArcZip P2）：走任务队列（进度 + 可取消），返回 taskID；
    ///   内部直接走 performExtract（不再经 extract 入队——否则嵌套任务会自相排队死锁）
    @discardableResult
    public static func saveEncryptedCopy(url: URL, to dest: URL, password: String,
                                         level: Int = 5,
                                         completion: @escaping (Bool, String) -> Void) -> UUID? {
        return ArchiveTaskQueue.shared.enqueue(kind: .encrypt,
                                               title: "加密另存 \(dest.lastPathComponent)") {
            taskID, done in
            func both(_ ok: Bool, _ msg: String) {
                // v127：取消传播的统一收尾——被 terminate 的 7zz 可能报空错，
                // 对外一律回「已取消」，别把取消显示成失败
                let cancelled = !ok && ArchiveTaskQueue.shared.isCancelled(taskID)
                done(ok, msg)
                // 保持原 API 语义：结果回主线程（run 的回调本在主线程，这里兜底早期返回路径）
                DispatchQueue.main.async { completion(ok, cancelled ? "已取消" : msg) }
            }
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-enc-\(UUID().uuidString)", isDirectory: true)
            performExtract(url: url, entry: nil, to: staging, password: nil,
                           includeAuxiliary: true, restrictTo: nil, taskID: taskID) { ok, msg in
                guard ok else {
                    try? FileManager.default.removeItem(at: staging)
                    both(false, "解出内容失败：\(msg)")
                    return
                }
                let children = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
                guard !children.isEmpty else {
                    try? FileManager.default.removeItem(at: staging)
                    both(false, "归档内容为空")
                    return
                }
                if ArchiveTaskQueue.shared.isCancelled(taskID) {
                    try? FileManager.default.removeItem(at: staging)
                    both(false, "已取消")
                    return
                }
                let ext = dest.pathExtension.isEmpty ? "7z" : dest.pathExtension
                var args = ["a", "-t\(ext)", "-mx=\(max(0, min(9, level)))",
                            "-p\(password)", "-y"]
                // 7z 才支持加密文件名（-mhe=on）；ZIP 只加密内容
                if ext == "7z" { args.append("-mhe=on") }
                args += [dest.path] + children
                runIn(args, cwd: staging, taskID: taskID,
                      onProgress: progressCallback(taskID, phase: "加密打包…")) { code, _, err in
                    try? FileManager.default.removeItem(at: staging)
                    if code == 0 {
                        ArchivePasswords.set(password, for: dest)
                        both(true, "已保存加密归档 \(dest.lastPathComponent)")
                    } else {
                        both(false, err)
                    }
                }
            }
        }
    }
}
