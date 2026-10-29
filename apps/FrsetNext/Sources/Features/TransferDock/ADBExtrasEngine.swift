import AppKit
import Foundation

// MARK: - ADB 扩展引擎（v116，用户「全都做一下」批次）
//
// 覆盖：① 一键无线（USB 一次 → adb tcpip 5555 → connect，免每次配对码）
//      ② 打开手机无线调试页  ③ 通知同步（dumpsys 轮询，零安装）
//      ④ 存储视图  ⑤ APK 安装  ⑥ 第三方应用列表  ⑦ Meld：虚拟屏 + 单应用窗口
//
// 纪律：所有 adb 调用一律后台队列（v105 卡死教训），完成回调回主线程。

public enum ADBExtrasEngine {

    // MARK: 数据模型

    public struct PhoneNotification: Identifiable, Equatable {
        public let id: String
        public let pkg: String
        public let app: String
        public let title: String
        public let text: String
        public let time: String
    }

    public struct StorageItem: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let sizeText: String
    }

    public struct AppItem: Identifiable, Equatable {
        public let id: String        // package
        public let label: String     // 包名最后一段（无 aapt，取可读名）
    }

    // MARK: 基础执行

    /// 当前目标设备序列号（v117：USB + 无线同时在线时 adb 会报「more than one device」，
    /// 所有命令必须显式 -s；这里缓存最近一次解析结果，5 秒后过期重查）
    private static let serialLock = NSLock()
    private static var _activeSerial: String?
    private static var _serialStamp: TimeInterval = 0

    static var activeSerial: String? {
        serialLock.lock(); defer { serialLock.unlock() }
        if Date().timeIntervalSince1970 - _serialStamp < 5 { return _activeSerial }
        return nil
    }

    static func setActiveSerial(_ s: String?) {
        serialLock.lock()
        _activeSerial = s
        _serialStamp = Date().timeIntervalSince1970
        serialLock.unlock()
    }

    /// 同步解析目标设备（后台队列里调用）：优先 USB，其次第一条 device
    private static func resolveSerialSync(_ adb: String) -> String? {
        if let cached = activeSerial { return cached }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = ["devices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var first: String?
        for line in out.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2, parts[1].hasPrefix("device") else { continue }
            let serial = parts[0]
            // v122（用户：「尽量不用线，优先无线」）：无线设备 serial 形如 192.168.1.5:5555
            if serial.contains(":") { setActiveSerial(serial); return serial }   // 无线优先
            if first == nil { first = serial }
        }
        setActiveSerial(first)
        return first
    }

    /// 不需要 pin 设备的子命令
    private static func needsSerialPin(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        let global: Set<String> = ["devices", "connect", "disconnect", "pair", "tcpip",
                                   "mdns", "start-server", "kill-server", "version",
                                   "usb", "reconnect", "forward", "reverse"]
        return !global.contains(first)
    }

    /// 运行 adb（后台；自动 -s 目标设备；返回合并输出）
    static func run(_ args: [String], timeout: TimeInterval = 25,
                    completion: @escaping (String?) -> Void) {
        guard let adb = ScreenCastEngine.findADB() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var fullArgs = args
            if needsSerialPin(args), !args.contains("-s") {
                if let serial = resolveSerialSync(adb) {
                    fullArgs = ["-s", serial] + args
                }
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            task.arguments = fullArgs
            let out = Pipe(); let err = Pipe()
            task.standardOutput = out; task.standardError = err
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let deadline = DispatchTime.now() + timeout
            while task.isRunning && DispatchTime.now() < deadline {
                usleep(60_000)
            }
            if task.isRunning { task.terminate() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            var text = String(data: data, encoding: .utf8) ?? ""
            let e = String(data: errData, encoding: .utf8) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = e }
            DispatchQueue.main.async { completion(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    // MARK: ① 一键无线

    /// USB 已连接时执行 `adb tcpip 5555`，再取设备 IP 并 `adb connect ip:5555`。
    /// 之后同一 Wi-Fi 下无需再开无线调试、无需配对码（与原版 scrcpy 工作流一致）。
    public static func enableWireless(completion: @escaping (Bool, String) -> Void) {
        deviceIP { ip in
            guard let ip else {
                completion(false, "取不到设备 IP（手机需先连同一 Wi-Fi）")
                return
            }
            run(["tcpip", "5555"]) { out1 in
                // tcpip 生效需要 1-2 秒，稍等再连
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    run(["connect", "\(ip):5555"]) { out2 in
                        let log = [out1 ?? "", out2 ?? ""].joined(separator: " · ")
                        let ok = (out2 ?? "").lowercased().contains("connected")
                        completion(ok, ok ? "已启用无线：\(ip):5555" : log)
                    }
                }
            }
        }
    }

    /// 设备 Wi-Fi IP（wlan0 优先）
    static func deviceIP(completion: @escaping (String?) -> Void) {
        run(["shell", "ip", "-f", "inet", "addr", "show", "wlan0"]) { out in
            if let ip = Self.firstIPv4(in: out) { completion(ip); return }
            run(["shell", "ip", "-f", "inet", "addr", "show"]) { out2 in
                completion(Self.firstIPv4(in: out2))
            }
        }
    }

    private static func firstIPv4(in text: String?) -> String? {
        guard let text else { return nil }
        let pattern = "inet (\\d+\\.\\d+\\.\\d+\\.\\d+)/"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let ip = ns.substring(with: m.range(at: 1))
        // 排除回环 / 虚拟网卡常见段
        if ip.hasPrefix("127.") || ip.hasPrefix("0.") { return nil }
        return ip
    }

    // MARK: ② 打开手机无线调试页

    public static func openWirelessDebugging(completion: ((String) -> Void)? = nil) {
        // 各厂商 Activity 名不同，按常见顺序尝试
        let candidates = [
            "com.android.settings/.development.WirelessDebuggingActivity",
            "com.android.settings/.Settings\\$WirelessDebuggingActivity",
            "com.android.settings/.SubSettings",
        ]
        func attempt(_ i: Int) {
            guard i < candidates.count else {
                completion?("未找到无线调试页，请手动打开「开发者选项 → 无线调试」")
                return
            }
            run(["shell", "am", "start", "-n", candidates[i]]) { out in
                if (out ?? "").lowercased().contains("error") {
                    attempt(i + 1)
                } else {
                    completion?("已在手机上打开无线调试页")
                }
            }
        }
        attempt(0)
    }

    // MARK: ③ 通知同步

    /// `dumpsys notification --noredact` → 解析 NotificationRecord 块
    public static func notifications(completion: @escaping ([PhoneNotification]) -> Void) {
        run(["shell", "dumpsys", "notification", "--noredact"], timeout: 20) { out in
            completion(parseNotifications(out ?? ""))
        }
    }

    static func parseNotifications(_ text: String) -> [PhoneNotification] {
        var result: [PhoneNotification] = []
        var currentPkg: String?
        var currentTitle = ""
        var currentText = ""
        var currentWhen = ""
        var seq = 0

        func flush() {
            guard let pkg = currentPkg, !(currentTitle.isEmpty && currentText.isEmpty) else {
                currentTitle = ""; currentText = ""; currentWhen = ""
                return
            }
            seq += 1
            result.append(PhoneNotification(id: "\(pkg)-\(seq)",
                                            pkg: pkg,
                                            app: shortAppName(pkg),
                                            title: currentTitle,
                                            text: currentText,
                                            time: shortTime(currentWhen)))
            currentTitle = ""; currentText = ""; currentWhen = ""; currentPkg = nil
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("NotificationRecord(") {
                flush()
                if let r = trimmed.range(of: "pkg=") {
                    let rest = trimmed[r.upperBound...]
                    currentPkg = String(rest.prefix { !$0.isWhitespace })
                }
                continue
            }
            if trimmed.hasPrefix("android.title=") {
                currentTitle = extractValue(trimmed, key: "android.title=")
            } else if trimmed.hasPrefix("android.text=") {
                currentText = extractValue(trimmed, key: "android.text=")
            } else if trimmed.hasPrefix("android.bigText=") {
                let big = extractValue(trimmed, key: "android.bigText=")
                if currentText.isEmpty { currentText = big }
            } else if trimmed.hasPrefix("when=") {
                currentWhen = String(trimmed.dropFirst(5).split(separator: "/").first ?? "")
            }
        }
        flush()
        // 去掉系统噪声、空标题，最多 30 条
        let noisy: Set<String> = ["android", "com.android.systemui", "com.milink.service",
                                  "com.android.settings", "com.xiaomi.mi_connect_service"]
        return Array(result.filter { !noisy.contains($0.pkg) && !$0.title.isEmpty }.prefix(30))
    }

    private static func extractValue(_ line: String, key: String) -> String {
        // 形如：android.title=String (微信) / CharSequence (xxx) / SpannableString (xxx)
        guard let keyRange = line.range(of: key) else { return "" }
        var v = String(line[keyRange.upperBound...])
        if let open = v.firstIndex(of: "("), let close = v.lastIndex(of: ")"), open < close {
            v = String(v[v.index(after: open)..<close])
        }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shortAppName(_ pkg: String) -> String {
        // 跳过 com/org/net/cn/android/app/mobile/client 这类无信息量段：
        // com.zhihu.android → zhihu；com.smzdm.client.android → smzdm
        let generic: Set<String> = ["com", "org", "net", "cn", "io", "app", "apps",
                                    "android", "mobile", "client", "activity",
                                    "service", "main", "phone", "pad", "hd"]
        let parts = pkg.split(separator: ".").map(String.init)
        let meaningful = parts.filter { !generic.contains($0.lowercased()) }
        if let best = meaningful.last { return best }
        return parts.last ?? pkg
    }

    private static func shortTime(_ raw: String) -> String {
        guard let ms = Double(raw), ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: ④ 存储视图

    /// 返回（总览文本, 顶层目录占用 Top N）
    public static func storage(completion: @escaping (String, [StorageItem]) -> Void) {
        run(["shell", "df", "-h", "/sdcard"], timeout: 15) { dfOut in
            let summary = dfOut?
                .components(separatedBy: .newlines)
                .last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            run(["shell", "du", "-sh", "/sdcard/*/", "2>/dev/null"], timeout: 40) { duOut in
                var items: [StorageItem] = []
                for line in (duOut ?? "").components(separatedBy: .newlines) {
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let name = (parts[1] as NSString).lastPathComponent
                    guard !name.isEmpty, !name.hasPrefix(".") else { continue }
                    items.append(StorageItem(id: parts[1], name: name, sizeText: parts[0]))
                }
                // du -h 的 K/M/G 字符串排序不可靠——按数字+单位粗排
                items.sort { byteValue($0.sizeText) > byteValue($1.sizeText) }
                completion(summary, Array(items.prefix(8)))
            }
        }
    }

    private static func byteValue(_ text: String) -> Double {
        let t = text.uppercased().trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return 0 }
        var numPart = t
        let mult: Double
        switch last {
        case "K": mult = 1_000; numPart = String(t.dropLast())
        case "M": mult = 1_000_000; numPart = String(t.dropLast())
        case "G": mult = 1_000_000_000; numPart = String(t.dropLast())
        case "T": mult = 1_000_000_000_000; numPart = String(t.dropLast())
        default:  mult = 1
        }
        return (Double(numPart) ?? 0) * mult
    }

    // MARK: ⑤ APK 安装

    public static func installAPK(url: URL, completion: @escaping (Bool, String) -> Void) {
        run(["install", "-r", "-d", url.path], timeout: 180) { out in
            let text = out ?? "安装无输出"
            let ok = text.contains("Success")
            completion(ok, text)
        }
    }

    // MARK: ⑥ 第三方应用

    public static func thirdPartyApps(completion: @escaping ([AppItem]) -> Void) {
        run(["shell", "pm", "list", "packages", "-3"], timeout: 20) { out in
            let apps = (out ?? "").components(separatedBy: .newlines).compactMap { line -> AppItem? in
                guard line.hasPrefix("package:") else { return nil }
                let pkg = String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces)
                guard !pkg.isEmpty else { return nil }
                return AppItem(id: pkg, label: shortAppName(pkg))
            }
            completion(apps.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
        }
    }

    // MARK: ⑧ 导航键（v117；全面屏/手势机没有实体返回键，投屏时需要）

    public enum NavKey: Int {
        case back = 4          // KEYCODE_BACK
        case home = 3          // KEYCODE_HOME
        case recents = 187     // KEYCODE_APP_SWITCH
        case power = 26        // KEYCODE_POWER
        case volumeUp = 24
        case volumeDown = 25
    }

    /// 发送系统按键（走 adb input keyevent，不依赖 scrcpy 窗口焦点）
    public static func sendKey(_ key: NavKey, completion: ((Bool) -> Void)? = nil) {
        run(["shell", "input", "keyevent", "\(key.rawValue)"]) { out in
            completion?(!(out ?? "").lowercased().contains("error"))
        }
    }

    /// 展开手机通知栏（全面屏手势机没有下拉区域在投屏窗里时用）
    public static func expandNotifications(completion: ((Bool) -> Void)? = nil) {
        run(["shell", "cmd", "statusbar", "expand-notifications"]) { out in
            completion?(!(out ?? "").lowercased().contains("error"))
        }
    }

    // MARK: ⑦ Meld：虚拟屏 + 单应用窗口

    /// scrcpy 4.x `--new-display`（Android 14+）：给单个 App 开一块虚拟屏，
    /// 对应 AndroMeld 的 Meld Mode「每个 App 独立 Mac 窗口」。
    /// - Parameter title: 窗口标题（传真实应用名；不传则用包名）
    @discardableResult
    public static func startAppWindow(package: String, title: String? = nil,
                                      width: Int = 1280, height: Int = 800) -> Bool {
        guard ScreenCastEngine.findScrcpy() != nil else {
            Toast.show("未找到投屏组件", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        // v166.3：与镜像同样用「我们自己的名字」启动，避免菜单栏出现第三方名称
        let launcher = ScreenCastEngine.brandedLauncher()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launcher.exe)
        var args: [String] = []
        if let serial = ADBExtrasEngine.activeSerial { args += ["--serial", serial] }
        args += ["--new-display=\(width)x\(height)/160",
                    "--start-app=\(package)",
                    "--window-title=\(title ?? shortAppName(package))",
                    "--stay-awake", "--no-power-on"]
        // v130（AndroMeld/AgentHUD）：显式剪贴板参数（AndroMeld P0-2），与镜像同一开关
        args += ScreenCastEngine.clipboardArguments()
        // v117：与镜像共用画质设置（分辨率上限交给 scrcpy，虚拟屏尺寸按设备能力）
        args += ["--video-bit-rate", "\(TransferDockPref.CastQuality.bitrate)M"]
        if TransferDockPref.CastQuality.fps > 0 {
            args += ["--max-fps", "\(TransferDockPref.CastQuality.fps)"]
        }
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let adb = ScreenCastEngine.findADB() {
            env["ADB"] = adb
            env["PATH"] = (adb as NSString).deletingLastPathComponent + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        if let server = launcher.server { env["SCRCPY_SERVER_PATH"] = server }
        task.environment = env
        do {
            try task.run()
            Log.info("Transfer", "应用窗口启动：\(package)（\(title ?? "-")）")
            Toast.show("已为 \(title ?? shortAppName(package)) 打开独立窗口",
                       icon: "macwindow.on.rectangle")
            return true
        } catch {
            Toast.show("启动失败：\(error.localizedDescription)",
                       icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
    }
}
