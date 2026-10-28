import AppKit
import Combine

// MARK: - 传输与投屏 引擎层（v103 重构，2026-10-21）
//
// 需求：中转站彻底重构——旧 OPPO 云端桥接 / 局域网扫码直传全部下线；
//   传输走「原生互传」路线（omdrop-owl 的思路：对端零安装——macOS 上即
//   系统级隔空投送 NSSharingService，iPhone 零安装收发）；
//   投屏走「AndroMeld 同实现方式」（商业闭源不可接，其底座=scrcpy 式
//   ADB 镜像——我们按同路线自研，Android 侧同样零安装，ADB 授权即用）。
// 方案与调研结论见 docs/传输与投屏-重构方案.md。

// MARK: ① 隔空投送发送（NSSharingService 系统面板，对端 iPhone 零安装）

/// 跨模块空投请求（v112；对标报告第一批 P1「空投联动」）：
/// 剪贴板历史条目 / 截图动作链等非 Transfer 模块通过此通知请求空投，
/// 由 App 层接线到 AirDropSendEngine（模块间不互相引用具体类型，CONTRACT §1.3）。
/// userInfo: `urls` = [URL]（必须已存在磁盘上）
public extension Notification.Name {
    static let frsetAirDropFiles = Notification.Name("frset.airDropFiles")
}

public enum AirDropSendEngine {

    /// 系统空投服务是否可用（老系统/被 MDM 禁用时为 false）
    public static var isAvailable: Bool { cachedService != nil }

    // MARK: v120 修复「点了没显示 + 卡顿」
    //
    // 两个真根因（用户实测：「隔空投送的 UI 没有显示，点击还十分卡顿」）：
    //  ① 面板是 FloatingPanel（styleMask 含 .nonactivatingPanel）——**点击不会激活本 app**。
    //     而 NSSharingService.perform(withItems:) 在 app 未激活时不会显示系统分享面板，
    //     于是表现为"点了没反应"。
    //  ② NSSharingService(named:.sendViaAirDrop) 首次实例化要同步初始化 AWDL/网络栈，
    //     实测阻塞主线程 1~3s → 点下去先卡住，之后面板才"突然"冒出来。
    //
    // 处置：实例缓存 5 分钟（warmUp 在页面出现时预热）+ 先激活 app 再异步 perform。

    private static var _service: NSSharingService?
    private static var _stamp: TimeInterval = 0
    private static let lock = NSLock()

    private static var cachedService: NSSharingService? {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if let s = _service, now - _stamp < 300 { return s }
        let s = NSSharingService(named: .sendViaAirDrop)
        _service = s
        _stamp = now
        return s
    }

    /// 预热：把首次实例化的 1~3s 挪到用户点击之前（页面 onAppear 调一次即可）
    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = cachedService
            Log.info("Transfer", "隔空投送已预热")
        }
    }

    /// 调起系统「隔空投送」面板发送文件
    /// - Returns: 是否成功发起（服务不可用/无文件时 false 并提示）
    @discardableResult
    public static func send(urls: [URL], relativeTo view: NSView? = nil) -> Bool {
        guard !urls.isEmpty else {
            Toast.show("没有可发送的文件", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        guard let service = cachedService else {
            Toast.show("本机隔空投送不可用（检查系统设置）", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        // ① 先把本 app 激活（nonactivating 面板不会自己激活），否则系统面板不出现。
        //    面板 hidesOnDeactivate=false 且 canBecomeKey=true，激活后仍是 key，不会自己收起。
        NSApp.activate(ignoringOtherApps: true)
        // ② 异步 perform：让按钮的按压态先画出来，避免"点下去像卡死"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            service.perform(withItems: urls)
            Log.info("Transfer", "隔空投送发起：\(urls.count) 个文件")
        }
        return true
    }
}

// MARK: ② 隔空投送接收（系统落盘 ~/Downloads → 自动入库本地暂存）

/// macOS 系统收空投默认落 ~/Downloads。监听新增完整文件 → 回调入库。
public final class AirDropReceiveWatcher {
    public static let shared = AirDropReceiveWatcher()

    /// 收到新文件（主线程回调）
    public var onFileReceived: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.frset.airdrop.receive")
    private var seen: Set<String> = []
    private var started = false

    private var downloadsDir: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    public func start() {
        guard !started else { return }
        started = true
        // v105（2026-10-21 卡死根因，sample 栈实锤）：此处在**主线程**做
        // contentsOfDirectory + open(dir)——~/Downloads 枚举被文件系统/同步盘
        // 挂起时主线程整体冻结（实测 236s 完整卡死）。全部移后台队列执行。
        queue.async { [weak self] in
            guard let self else { return }
            let dir = self.downloadsDir
            self.seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else {
                Log.warn("Transfer", "Downloads 目录监听打开失败")
                return
            }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend], queue: self.queue)
            src.setEventHandler { [weak self] in self?.scan() }
            src.setCancelHandler { close(fd) }
            src.resume()
            self.source = src
            Log.info("Transfer", "空投接收监听已启动（~/Downloads）")
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        started = false
    }

    /// 扫描新落盘的完整文件（跳过 .download 等未完成文件）
    private func scan() {
        let dir = downloadsDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where !seen.contains(name) {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue,
                  !name.hasSuffix(".download"),
                  !name.hasPrefix(".") else { continue }
            seen.insert(name)
            // 稳定性小等待（拷贝刚完成的文件偶尔仍在收尾）
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                Log.info("Transfer", "空投接收：\(name)")
                DispatchQueue.main.async { self?.onFileReceived?(url) }
            }
        }
    }
}

// MARK: ③ 投屏（scrcpy 引擎——AndroMeld 同实现路线：ADB + 视频流镜像）

public enum ScreenCastEngine {

    /// scrcpy 可执行文件探测（PATH / Homebrew / 手动放置）
    public static func findScrcpy() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/scrcpy",   // v115：实测本机装在这里
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
            "/usr/bin/scrcpy",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // PATH 查找
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "scrcpy"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// adb 可执行文件探测
    public static func findADB() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/adb",   // v115：实测本机 adb 装在这里（应用 PATH 看不到）
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// 已连接设备列表（后台执行——adb 挂起不得卡主线程，v105 卡死教训）
    public static func connectedDevices(completion: @escaping ([(serial: String, state: String)]?) -> Void) {
        guard let adb = findADB() else { completion(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            task.arguments = ["devices"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            var result: [(String, String)] = []
            for line in out.split(separator: "\n").dropFirst() {
                let parts = line.split(separator: "\t")
                if parts.count >= 2 {
                    result.append((String(parts[0]), String(parts[1])))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 启动投屏镜像（scrcpy 独立进程；等 ADB 连真机后实测调参）
    /// - Parameter serial: 指定设备（多设备时必填）
    @discardableResult
    public static func startMirror(serial: String? = nil,
                                   maxSize: Int? = nil,
                                   bitRateMbps: Int? = nil) -> Bool {
        guard let scrcpy = findScrcpy() else {
            Toast.show("未找到 scrcpy（brew install scrcpy 后重试）",
                       icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: scrcpy)
        // v117：画质走「设置 → 文件中转 → 投屏画质」（默认 1920p / 16Mbps / 60fps）
        var args: [String] = ["--stay-awake", "--no-power-on"]
        // v130（AndroMeld/AgentHUD）：显式剪贴板参数（AndroMeld P0-2），不再依赖默认值
        args += clipboardArguments()
        let size = maxSize ?? TransferDockPref.CastQuality.maxSize
        if size > 0 { args += ["--max-size", "\(size)"] }
        args += ["--video-bit-rate", "\(bitRateMbps ?? TransferDockPref.CastQuality.bitrate)M"]
        let fps = TransferDockPref.CastQuality.fps
        if fps > 0 { args += ["--max-fps", "\(fps)"] }
        if let serial { args += ["--serial", serial] }
        task.arguments = args
        do {
            try task.run()
            Log.info("Transfer", "投屏启动：scrcpy \(args.joined(separator: " "))")
            Toast.show(TransferDockPref.CastQuality.clipboardAutoSync
                       ? "投屏已启动（镜像窗 · 双向剪贴板：已开启）"
                       : "投屏已启动（双向剪贴板：已关闭）", icon: "display")
            return true
        } catch {
            Toast.show("投屏启动失败：\(error.localizedDescription)",
                       icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
    }

    // MARK: v130（AndroMeld/AgentHUD）：显式剪贴板参数（AndroMeld P0-2）
    //
    // 开关：TransferDockPref.CastQuality.clipboardAutoSync（默认开），
    // UI 明示「双向剪贴板：已开启」；关掉就不传同步参数。
    // scrcpy 版本差异（本机 4.1 实测）：
    //   · 4.x：只有 `--no-clipboard-autosync`，默认即双向同步 → 开=不传（即默认开），
    //     关=传 --no-clipboard-autosync。**4.1 不认识 --clipboard-autosync**（实测退出码 1）。
    //   · 2.x/3.x：有 `--clipboard-autosync` / `--no-clipboard-autosync` 一对。
    // 所以按 scrcpy --help 探测支持集，开时能显式传就显式传（保证「显式」语义），
    // 不支持显式开参数的版本回落「不传 = 默认开启」。
    public static func clipboardArguments() -> [String] {
        guard TransferDockPref.CastQuality.clipboardAutoSync else {
            return ["--no-clipboard-autosync"]     // 两代版本都支持显式关
        }
        return clipboardExplicitOnSupported() ? ["--clipboard-autosync"] : []
    }

    /// scrcpy 是否支持显式 `--clipboard-autosync`（探测结果缓存 10 分钟）
    /// 注：`--no-clipboard-autosync` 不含子串 `--clipboard-autosync`（中间隔着 "no"），
    /// 直接 contains 判正参数即可。
    private static var clipProbeStamp: Date = .distantPast
    private static var clipProbeSupportsOn = false
    private static func clipboardExplicitOnSupported() -> Bool {
        if Date().timeIntervalSince(clipProbeStamp) < 600 { return clipProbeSupportsOn }
        guard let scrcpy = findScrcpy() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: scrcpy)
        task.arguments = ["--help"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let help = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        clipProbeSupportsOn = help.contains("--clipboard-autosync")
        clipProbeStamp = Date()
        return clipProbeSupportsOn
    }
}

// MARK: ④ 无线配对（v112；对标报告第一批 P0——AndroMeld「随叫随到」的主路径）
//
// Android 11+ 无线调试流程：开发者选项 → 无线调试 → 「使用配对码配对设备」
// 得到 ip:port + 6 位配对码 → `adb pair ip:port code`（一次性）→
// 之后 `adb connect ip:port` 随连随用（无线调试页显示的端口是 connect 端口，
// 与 pair 端口不同）。局域网发现用 `adb mdns services`（adb 自带 mDNS，
// 比自写 NWBrowser 少一层解析，且能同时发现 pairing/connecting 两类服务）。

public enum ADBWirelessEngine {

    /// 一条 mDNS 发现结果
    public struct DiscoveredService: Identifiable {
        public let id: String          // name+target 组合
        public let name: String        // 服务名（adb-xxx-yyy 或设备名）
        public let target: String      // ip:port
        public let needsPairing: Bool  // _adb-tls-pairing = 需要配对码
    }

    /// `adb mdns services` 解析（后台执行）
    public static func discoverServices(completion: @escaping ([DiscoveredService]?) -> Void) {
        runADB(["mdns", "services"]) { out in
            guard let out, !out.isEmpty else { completion(nil); return }
            var result: [DiscoveredService] = []
            var seen = Set<String>()
            for line in out.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                // 形如：adb-XXXX-YYYY._adb-tls-connect._tcp  192.168.1.5:37xxx
                let parts = l.split(separator: "\t").map { String($0) }
                guard parts.count >= 2 else { continue }
                let service = parts[0]
                let target = parts[1]
                guard target.contains(":") else { continue }
                let needsPairing = service.contains("_adb-tls-pairing")
                let name = service
                    .replacingOccurrences(of: "._adb-tls-connect._tcp", with: "")
                    .replacingOccurrences(of: "._adb-tls-pairing._tcp", with: "")
                let id = service + "@" + target
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                result.append(DiscoveredService(id: id, name: name, target: target, needsPairing: needsPairing))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// `adb pair ip:port code`（后台执行；输出如 "Successfully paired to ..."）
    public static func pair(host: String, port: String, code: String,
                            completion: @escaping (String) -> Void) {
        runADB(["pair", "\(host):\(port)", code]) { out in
            DispatchQueue.main.async { completion(out ?? "adb 不可用") }
        }
    }

    /// `adb connect ip:port`（后台执行；输出如 "connected to ..." / "already connected"）
    public static func connect(host: String, port: String,
                               completion: @escaping (String) -> Void) {
        runADB(["connect", "\(host):\(port)"]) { out in
            DispatchQueue.main.async { completion(out ?? "adb 不可用") }
        }
    }

    /// adb 子进程统一封装（全后台；v105 教训：adb 挂起不得碰主线程）
    private static func runADB(_ args: [String], completion: @escaping (String?) -> Void) {
        guard let adb = ScreenCastEngine.findADB() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            // v117：多设备（USB + 无线）同时在线时必须指定目标
            // mdns / pair / connect / devices / tcpip 是 adb 的**全局命令**，
            // 加 -s 会被当成「对某台设备执行」而直接失败（多设备时必踩）。
            let global: Set<String> = ["devices", "connect", "disconnect", "pair",
                                       "mdns", "tcpip", "start-server", "kill-server", "version"]
            var full = args
            if let serial = ADBExtrasEngine.activeSerial,
               let first = args.first, !global.contains(first), !args.contains("-s") {
                full = ["-s", serial] + args
            }
            task.arguments = full
            let out = Pipe(); let err = Pipe()
            task.standardOutput = out
            task.standardError = err
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            task.waitUntilExit()
            var text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = e }
            DispatchQueue.main.async { completion(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}

// MARK: ⑤ ADB 文件桥（v112；对标报告第一批 P1——暂存区 ↔ 手机，扫码直传的 Android 侧替代）

public enum ADBFileBridge {

    /// 推送文件到手机（默认 /sdcard/Download/FrsetNext/）
    /// - completion: (成功数, 输出文本)
    public static func push(urls: [URL],
                            remoteDir: String = "/sdcard/Download/FrsetNext",
                            completion: @escaping (Int, String) -> Void) {
        guard !urls.isEmpty else {
            DispatchQueue.main.async { completion(0, "没有要推送的文件") }
            return
        }
        runADB(["shell", "mkdir", "-p", remoteDir]) { _ in
            runADBPush(urls: urls, remoteDir: remoteDir, index: 0, sent: 0, log: "") { sent, log in
                completion(sent, log)
            }
        }
    }

    // MARK: 带进度的推送（v122；用户：「数据也要显示」）

    /// 传输进度快照（整个批次，不是单文件）
    public struct PushProgress {
        public var currentFile: String = ""
        public var fileIndex: Int = 0
        public var fileCount: Int = 0
        public var bytesDone: Int64 = 0
        public var bytesTotal: Int64 = 0
        public var bytesPerSecond: Double = 0

        public init() {}

        public var fraction: Double {
            bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
        }
        public var speedText: String {
            guard bytesPerSecond > 1024 else { return "" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        }
        public var etaText: String {
            guard bytesPerSecond > 1024, bytesTotal > bytesDone else { return "" }
            let secs = Double(bytesTotal - bytesDone) / bytesPerSecond
            if secs < 60 { return String(format: "%.0fs", secs) }
            return String(format: "%.0fm%.0fs", floor(secs / 60), secs.truncatingRemainder(dividingBy: 60))
        }
        public var doneText: String {
            ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)
                + " / " + ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
        }
    }

    final class PushTracker {
        var fileCount = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var start = Date()
        var log = ""
    }

    /// 带进度推送：`adb push -p` 会在 stderr 打 `[ 42%] /path`，逐块解析换算成整体进度与速率
    public static func push(urls: [URL],
                            remoteDir: String = "/sdcard/Download/FrsetNext",
                            progress: @escaping (PushProgress) -> Void,
                            completion: @escaping (Int, String) -> Void) {
        guard !urls.isEmpty else {
            DispatchQueue.main.async { completion(0, "没有要推送的文件") }
            return
        }
        let fm = FileManager.default
        let sizes: [Int64] = urls.map {
            ((try? fm.attributesOfItem(atPath: $0.path))?[.size] as? Int64) ?? 0
        }
        let tracker = PushTracker()
        tracker.fileCount = urls.count
        tracker.bytesTotal = sizes.reduce(0, +)
        tracker.start = Date()

        runADB(["shell", "mkdir", "-p", remoteDir]) { _ in
            pushOne(urls: urls, sizes: sizes, remoteDir: remoteDir, index: 0,
                    sent: 0, tracker: tracker, progress: progress, completion: completion)
        }
    }

    private static func pushOne(urls: [URL], sizes: [Int64], remoteDir: String,
                                index: Int, sent: Int,
                                tracker: PushTracker,
                                progress: @escaping (PushProgress) -> Void,
                                completion: @escaping (Int, String) -> Void) {
        guard index < urls.count else {
            DispatchQueue.main.async { completion(sent, tracker.log) }
            return
        }
        let url = urls[index]
        let size = sizes[index]
        let baseDone = tracker.bytesDone
        guard let adb = ScreenCastEngine.findADB() else {
            DispatchQueue.main.async { completion(sent, "未找到 adb") }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            let serial = ADBExtrasEngine.activeSerial
            var args: [String] = []
            if let serial, !serial.isEmpty { args += ["-s", serial] }
            args += ["push", url.path, remoteDir + "/"]
            task.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            // v122 实测结论：adb 在管道（非 tty）里**不输出百分比**，
            // 只会在结束时给一行「1 file pushed ... 38.2 MB/s」。
            // 所以进度改用「轮询手机端文件大小」：每 0.7s 跑一次 stat -c %s。
            let remotePath = remoteDir + "/" + url.lastPathComponent
            do {
                try task.run()
            } catch {
                DispatchQueue.main.async {
                    completion(sent, "adb 启动失败：\(error.localizedDescription)")
                }
                return
            }

            while task.isRunning {
                usleep(700_000)
                guard task.isRunning else { break }
                guard let size = remoteFileSize(adb: adb, serial: serial, path: remotePath),
                      size > 0 else { continue }
                var p = PushProgress()
                p.currentFile = url.lastPathComponent
                p.fileIndex = index
                p.fileCount = tracker.fileCount
                p.bytesDone = min(tracker.bytesTotal, baseDone + size)
                p.bytesTotal = tracker.bytesTotal
                let elapsed = max(0.1, Date().timeIntervalSince(tracker.start))
                p.bytesPerSecond = Double(p.bytesDone) / elapsed
                DispatchQueue.main.async { progress(p) }
            }

            task.waitUntilExit()
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            let outText = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            let combined = (outText + errText).trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = task.terminationStatus == 0 && !combined.lowercased().contains("adb: error")
            tracker.bytesDone = baseDone + (ok ? size : 0)
            tracker.log += "\(url.lastPathComponent)：\(ok ? "✓ " + speedHint(combined) : "✗ " + String(combined.prefix(80)))\n"

            pushOne(urls: urls, sizes: sizes, remoteDir: remoteDir, index: index + 1,
                    sent: sent + (ok ? 1 : 0), tracker: tracker,
                    progress: progress, completion: completion)
        }
    }

    /// 手机端文件当前大小（进度轮询用）
    private static func remoteFileSize(adb: String, serial: String?, path: String) -> Int64? {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: adb)
        var a: [String] = []
        if let serial, !serial.isEmpty { a += ["-s", serial] }
        a += ["shell", "stat", "-c", "%s", path]
        t.arguments = a
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        guard (try? t.run()) != nil else { return nil }
        t.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Int64(out)
    }

    /// 从 adb 汇总行里抽速率（「… 38.2 MB/s (125829120 bytes in 3.140s)」）
    private static func speedHint(_ text: String) -> String {
        guard let r = text.range(of: #"[\d.]+ ?[KMG]B/s"#, options: .regularExpression) else { return "" }
        return String(text[r])
    }

    /// 从 adb 的进度块里取百分比（形如 `[ 42%]` 或 `42%`）
    static func parsePercent(_ text: String) -> Double? {
        guard let r = text.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let num = text[r].dropLast()
        guard let v = Double(num) else { return nil }
        return min(1, max(0, v / 100))
    }

    /// 逐个推送（adb push 一次多源在个别 ROM 上行为不一，逐个最稳、还能精确报数）
    private static func runADBPush(urls: [URL], remoteDir: String, index: Int,
                                   sent: Int, log: String,
                                   completion: @escaping (Int, String) -> Void) {
        guard index < urls.count else {
            DispatchQueue.main.async { completion(sent, log) }
            return
        }
        let url = urls[index]
        runADB(["push", url.path, remoteDir + "/"]) { out in
            // 成功输出形如 "1 file pushed, 0 skipped."；失败含 "adb: error"
            let text = out ?? ""
            let ok = !text.isEmpty && !text.lowercased().contains("error")
            var log = log
            log += "\(url.lastPathComponent)：\(ok ? "✓" : "✗ \(text)")\n"
            runADBPush(urls: urls, remoteDir: remoteDir, index: index + 1,
                       sent: sent + (ok ? 1 : 0), log: log, completion: completion)
        }
    }

    /// 拉取手机目录下全部文件到本地暂存目录（先清空暂存目录，避免重复堆积）
    /// - completion: (成功数, 输出文本)
    public static func pull(remoteDir: String = "/sdcard/Download/FrsetNext",
                            into stagingDir: URL,
                            completion: @escaping (Int, String) -> Void) -> Void {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        runADB(["pull", remoteDir + "/.", stagingDir.path]) { out in
            guard let out else {
                DispatchQueue.main.async { completion(0, "adb 不可用") }
                return
            }
            // 输出形如 "N files pulled, 0 skipped."
            let count = Int(out.split(separator: " ").first ?? "") ?? (out.contains("pulled") ? 1 : 0)
            DispatchQueue.main.async { completion(count, out) }
        }
    }

    /// 暂存目录（与 LocalTransferStore 的本地暂存同源——拉取文件直接入暂存索引）
    public static var stagingDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrsetNext", isDirectory: true)
            .appendingPathComponent("TransferStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func runADB(_ args: [String], completion: @escaping (String?) -> Void) {
        guard let adb = ScreenCastEngine.findADB() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            // v117：多设备（USB + 无线）同时在线时必须指定目标
            var full = args
            if let serial = ADBExtrasEngine.activeSerial, !args.contains("-s") {
                full = ["-s", serial] + args
            }
            task.arguments = full
            let out = Pipe(); let err = Pipe()
            task.standardOutput = out
            task.standardError = err
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            task.waitUntilExit()
            var text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = e }
            DispatchQueue.main.async { completion(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}
