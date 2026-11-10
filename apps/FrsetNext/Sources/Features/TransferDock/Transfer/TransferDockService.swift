import Foundation
import AppKit

// MARK: - 中转站服务（Web 通道）
//
// 协议实现在 OPPO 中转站工程的 Python 侧（已实包验证：签名 / STS 分片 / 懒续期）。
// Swift 只做三件事：调 `frset_bridge.py` 拿单行 JSON、维护 UI 状态、写回登录态。
// 这样不会在 Swift 里复制一份加密与上传实现，登录态也只有一份（credentials/cookies.json）。

struct TransferDockFile: Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
    let createdAt: Double
    let type: String

    // v126（性能审计 F1530）：字节格式化器复用——sizeText 是列表每行都要求值的计算属性，
    // `ByteCountFormatter.string(fromByteCount:countStyle:)` 类方法内部每次都新建 formatter。
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var sizeText: String {
        Self.byteFormatter.string(fromByteCount: size)
    }

    // v126（性能审计 F1530）：DateFormatter 复用——dateText 是列表每行都要求值的计算属性，
    // 原实现每次 new 一个 DateFormatter。提为 static 缓存。
    private static let dateTextFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var dateText: String {
        guard createdAt > 0 else { return "—" }
        // 服务端下发的是毫秒时间戳
        let seconds = createdAt > 1_000_000_000_000 ? createdAt / 1000 : createdAt
        let date = Date(timeIntervalSince1970: seconds)
        return Self.dateTextFormatter.string(from: date)
    }
}

/// 桥接脚本的位置（用户可在设置里改；默认指向工程目录）
enum TransferDockPath {
    private static let defaultsKey = "transferDock.rootPath"

    static var root: URL {
        get {
            if let saved = UserDefaults.standard.string(forKey: defaultsKey), !saved.isEmpty {
                return URL(fileURLWithPath: saved)
            }
            return URL(fileURLWithPath: "/Users/sunyiyang/Desktop/Project/temp/OPPO 中转站")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: defaultsKey) }
    }

    static var webRoot: URL { root.appendingPathComponent("网页") }
    static var bridgeScript: URL { webRoot.appendingPathComponent("scripts/frset_bridge.py") }
    static var cookieFile: URL { root.appendingPathComponent("credentials/cookies.json") }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: bridgeScript.path)
            || FileManager.default.fileExists(atPath: cookieFile.path)
    }
}

final class TransferDockService: ObservableObject {

    static let shared = TransferDockService()

    @Published private(set) var loggedIn = false
    @Published private(set) var leftSpace: Int64 = 0
    @Published private(set) var totalSpace: Int64 = 0
    @Published private(set) var files: [TransferDockFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isUploading = false
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSyncedAt: Date?

    private let queue = DispatchQueue(label: "frset.transferdock.bridge", qos: .userInitiated)
    private var keepAliveTimer: Timer?
    /// 云端「实时同步」定时器：30s 拉一次列表（OPPO 中转像云盘一样会变，UI 要跟着变）
    private var liveSyncTimer: Timer?

    private init() {}

    /// 实时同步开关（面板打开中转页时启动；重复调用幂等）
    func startLiveSync() {
        guard liveSyncTimer == nil else { return }
        // v128（流畅度）：回调体进 autoreleasepool——桥接返回的 JSON 字典/字符串
        // 不再等 runloop 排空；周期 30s 与启停时机（中转页 onAppear/onDisappear）不变。
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.loggedIn, !self.isLoading, !self.isUploading else { return }
            autoreleasepool { self.refresh(clearError: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveSyncTimer = timer
    }

    func stopLiveSync() {
        liveSyncTimer?.invalidate()
        liveSyncTimer = nil
    }

    /// 会话保活（docs/08：会话 30 分钟滑动，5 分钟一刷即可常驻在线）。
    /// 首次登录成功后启动；只在已登录时打桥，且 Python 侧另有 60s 节流兜底。
    func startKeepAlive() {
        guard keepAliveTimer == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keepAliveTimer == nil else { return }
            self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                guard let self, self.loggedIn else { return }
                // v128（流畅度）：回调体进 autoreleasepool（Python 桥接的 JSON 临时对象
                // 随回调排空）；300s 低频周期保持不变。
                self.queue.async {
                    autoreleasepool { _ = Self.runBridge(["keepalive"]) }
                }
            }
        }
    }

    var spaceText: String {
        guard totalSpace > 0 else { return "" }
        let used = max(0, totalSpace - leftSpace)
        return "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalSpace, countStyle: .file))"
    }

    var spaceRatio: Double {
        guard totalSpace > 0 else { return 0 }
        return min(1, max(0, Double(totalSpace - leftSpace) / Double(totalSpace)))
    }

    // MARK: 刷新（登录态 + 空间 + 列表一次拿）

    func refresh(clearError: Bool = true) {
        guard TransferDockPath.isAvailable else {
            errorMessage = "未找到中转站工程：\n\(TransferDockPath.root.path)"
            return
        }
        isLoading = true
        if clearError { errorMessage = nil }
        queue.async { [weak self] in
            guard let self else { return }
            // v128（流畅度）：桥接 JSON 解析块进 autoreleasepool——status/list 两次
            // Python 桥接返回的字典树不再等队列线程 runloop 排空（30s 轮询 × 200 条
            // 列表的临时对象是小堆堆积源）。
            autoreleasepool {
                let status = Self.runBridge(["status"])
                guard let statusData = status["data"] as? [String: Any] else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.errorMessage = (status["error"] as? String) ?? "无法读取登录态"
                    }
                    return
                }
                let logged = statusData["loggedIn"] as? Bool ?? false
                DispatchQueue.main.async {
                    self.loggedIn = logged
                    self.leftSpace = (statusData["leftSpace"] as? NSNumber)?.int64Value ?? 0
                    self.totalSpace = (statusData["totalSpace"] as? NSNumber)?.int64Value ?? 0
                }
                guard logged else {
                    let reason = (statusData["reason"] as? String) ?? "登录态已失效"
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.files = []
                        self.errorMessage = reason
                    }
                    return
                }
                let listing = Self.runBridge(["list", "1", "200"])
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.lastSyncedAt = Date()
                    guard let data = listing["data"] as? [String: Any],
                          let rawFiles = data["files"] as? [[String: Any]] else {
                        self.errorMessage = (listing["error"] as? String) ?? "列表拉取失败"
                        return
                    }
                    self.files = rawFiles.compactMap { item in
                        guard let id = item["id"] as? String else { return nil }
                        return TransferDockFile(
                            id: id,
                            name: (item["name"] as? String) ?? "未命名",
                            size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                            createdAt: (item["createdAt"] as? NSNumber)?.doubleValue ?? 0,
                            type: (item["type"] as? String) ?? "")
                    }
                }
            }
        }
    }

    // MARK: 上传

    func upload(url: URL) {
        isUploading = true
        statusMessage = "正在上传 \(url.lastPathComponent)…"
        errorMessage = nil
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.runBridge(["upload", url.path])
            DispatchQueue.main.async {
                self.isUploading = false
                if result["ok"] as? Bool == true,
                   let data = result["data"] as? [String: Any] {
                    let seconds = (data["seconds"] as? NSNumber)?.doubleValue ?? 0
                    self.statusMessage = "已上传 \(url.lastPathComponent)（\(String(format: "%.1f", seconds))s）"
                } else {
                    self.statusMessage = ""
                    self.errorMessage = (result["error"] as? String) ?? "上传失败"
                }
                self.refresh(clearError: false)
            }
        }
    }

    /// 批量上传（本地暂存勾选后「加入云端」）：逐个走桥接，最后统一刷新一次列表
    func uploadBatch(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isUploading = true
        statusMessage = "正在上传 \(urls.count) 个文件…"
        errorMessage = nil
        queue.async { [weak self] in
            guard let self else { return }
            var ok = 0
            var failed: [String] = []
            for url in urls {
                let result = Self.runBridge(["upload", url.path])
                if result["ok"] as? Bool == true {
                    ok += 1
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
            DispatchQueue.main.async {
                self.isUploading = false
                if failed.isEmpty {
                    self.statusMessage = "已上传 \(ok) 个文件"
                    self.errorMessage = nil
                } else {
                    self.statusMessage = ok > 0 ? "已上传 \(ok) 个，失败 \(failed.count) 个" : ""
                    self.errorMessage = "上传失败：" + failed.joined(separator: "、")
                }
                self.refresh(clearError: false)
            }
        }
    }

    // MARK: 下载

    func download(_ file: TransferDockFile) {
        statusMessage = "正在下载 \(file.name)…"
        errorMessage = nil
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.runBridge(["download", file.id])
            DispatchQueue.main.async {
                if result["ok"] as? Bool == true,
                   let data = result["data"] as? [String: Any],
                   let path = data["path"] as? String {
                    self.statusMessage = "已下载到 \(path)"
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } else {
                    self.statusMessage = ""
                    self.errorMessage = (result["error"] as? String) ?? "下载失败"
                }
            }
        }
    }

    // MARK: 删除

    func delete(_ file: TransferDockFile) {
        statusMessage = "正在删除 \(file.name)…"
        errorMessage = nil
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.runBridge(["delete", file.id])
            DispatchQueue.main.async {
                if result["ok"] as? Bool == true {
                    self.statusMessage = "已删除 \(file.name)"
                } else {
                    self.statusMessage = ""
                    self.errorMessage = (result["error"] as? String) ?? "删除失败"
                }
                self.refresh(clearError: false)
            }
        }
    }

    // MARK: 登录态写回（WKWebView 抓到的 cookie → credentials/cookies.json）

    /// 把浏览器 cookie 写成中转站工程认识的格式（数组，含 domain/expires/httpOnly/name/path/secure/value）
    /// - Parameter completion: v255 起必传的逻辑：登录页要等**服务端回验通过**才关窗。
    ///   `ok == false` 时 `reason` 是服务端原话（例如 1003 用户信息获取失败）。
    func saveCookies(_ cookies: [HTTPCookie], completion: ((Bool, String?) -> Void)? = nil) {
        let keepDomains = ["heytap.com", "oppo.com"]
        let relevant = cookies.filter { cookie in
            keepDomains.contains { cookie.domain.hasSuffix($0) }
        }
        guard !relevant.isEmpty else {
            errorMessage = "登录页没有产生有效 cookie，请确认已登录成功"
            completion?(false, "登录页没有产生有效 cookie")
            return
        }
        let payload: [[String: Any]] = relevant.map { cookie in
            [
                "domain": cookie.domain,
                "expires": cookie.expiresDate?.timeIntervalSince1970 ?? 0,
                "httpOnly": cookie.isHTTPOnly,
                "name": cookie.name,
                "path": cookie.path,
                "secure": cookie.isSecure,
                "value": cookie.value
            ]
        }
        do {
            try FileManager.default.createDirectory(at: TransferDockPath.cookieFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys])
            // v249（用户：「登录之后没有成功显示」）：写之前把上一份 cookie 存成证据，便于回溯
            Self.archiveCookieEvidence()
            try data.write(to: TransferDockPath.cookieFile, options: .atomic)
            Log.info("TransferDock", "登录态落盘 \(relevant.count) 条: "
                     + relevant.map { "\($0.domain)/\($0.name)" }.sorted().joined(separator: ", "))
            // v249：不能只看 cookie 条数就宣布登录成功——必须让桥回验一次。
            // 原来这里直接 loggedIn = true，服务端其实回 1003，界面显示已登录但列表永远空。
            statusMessage = "登录态已保存，正在校验…"
            errorMessage = nil
            Self.verifySession { [weak self] ok, reason in
                guard let self else { return }
                Log.info("TransferDock", "回验结果 ok=\(ok) reason=\(reason ?? "-")")
                DispatchQueue.main.async {
                    if ok {
                        self.loggedIn = true
                        self.statusMessage = "登录态有效，已开始续约"
                        self.errorMessage = nil
                        self.startKeepAlive()
                    } else {
                        self.loggedIn = false
                        self.statusMessage = ""
                        self.errorMessage = reason ?? "会话无效，请重新登录"
                    }
                    completion?(ok, reason)
                }
            }
        } catch {
            errorMessage = "写入登录态失败：\(error.localizedDescription)"
            completion?(false, "写入登录态失败：\(error.localizedDescription)")
        }
    }

    // MARK: 登录态校验与留证

    /// v249：让桥回验登录态。写 cookie 成功 ≠ 会话有效（服务端可能回 1003）。
    private static func verifySession(_ done: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = runBridge(["status"])
            let data = result["data"] as? [String: Any]
            let ok = (data?["loggedIn"] as? Bool) ?? false
            let reason = (data?["reason"] as? String) ?? (result["error"] as? String)
            done(ok, reason)
        }
    }

    /// v249（用户：「本地的浏览器 Cookie 需要保存证据」）：每次覆盖前把上一份存进
    /// credentials/evidence/cookies-时间戳.json，最多留 20 份，便于事后回溯是哪一份失效。
    private static func archiveCookieEvidence() {
        let fm = FileManager.default
        let src = TransferDockPath.cookieFile
        guard fm.fileExists(atPath: src.path) else { return }
        let dir = src.deletingLastPathComponent().appendingPathComponent("evidence", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let dst = dir.appendingPathComponent("cookies-\(fmt.string(from: Date())).json")
        try? fm.copyItem(at: src, to: dst)
        // 只留最近 20 份
        let olds = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("cookies-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for old in olds.dropFirst(20) { try? fm.removeItem(at: old) }
    }

    // MARK: 调桥接脚本

    /// 在后台队列同步执行 `python3 frset_bridge.py <args>`，解析首行 JSON
    private static func runBridge(_ args: [String]) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [TransferDockPath.bridgeScript.path] + args
        process.currentDirectoryURL = TransferDockPath.webRoot

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return ["ok": false, "error": "无法启动桥接脚本：\(error.localizedDescription)"]
        }

        // 先把两个管道读空再等退出（readDataToEndOfFile 阻塞到 EOF，零轮询开销；
        // 顺序很重要：先读后 wait，否则子进程可能因管道写满而卡死）。
        // 超时保护用「兜底杀手」：10 分钟后还在跑就 terminate，EOF 自然到达。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) {
            if process.isRunning {
                process.terminate()
            }
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        // 桥接只保证「最后一行」是 JSON（前面的懒续期日志走 stderr）
        for line in stdout.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        let hint = stderr.isEmpty ? stdout : stderr
        return ["ok": false, "error": hint.isEmpty ? "桥接脚本没有返回结果" : String(hint.suffix(400))]
    }
}
