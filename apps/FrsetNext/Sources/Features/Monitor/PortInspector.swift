import AppKit
import Foundation
import Combine

// MARK: - 端口占用检测（网络监测页）
//
// 实现选型（2026-10-20）：
//   · libproc 逐进程枚举 socket —— macOS 27 对**其他进程**的 PROC_PIDFDSOCKETINFO
//     全部返回失败（实测 122/122 拒绝），无法拿到端口与进程归属，不可用；
//   · sysctl net.inet.tcp.pcblist —— 只有端口没有进程名，且结构体随系统版本漂移；
//   · lsof -F（机器可读字段）—— 单次约 30ms，能同时给出协议/地址/端口/进程名/PID，
//     且无需 root 即可看到同用户与多数系统进程。故选它，并做三重约束：
//       1) 只在网络页可见时扫描（页面 onAppear/onDisappear 控制）；
//       2) 可见时 10s 轮询 / 最小间隔 3s（手动刷新可强制），应用非前台时跳过；
//       3) 后台队列执行，主线程只接收解析后的快照。
//
// 解析口径：
//   · TCP 只要 LISTEN（-sTCP:LISTEN 已在命令层过滤，解析层再校验 TST）；
//   · UDP 跳过未绑定（`*:*`）与已连接（`a:b->c:d`）的 socket；
//   · 同 (proto, port, pid) 的 IPv4/IPv6 两条记录合并为一条，地址聚合展示。

/// 一条端口绑定（同进程同协议的 v4/v6 已合并）
struct PortBinding: Identifiable, Equatable {
    let proto: String          // "TCP" / "UDP"
    let port: Int
    /// 同一端口可能被同名进程的多个实例绑定（如 adb 的 helper），合并展示
    let pids: [Int32]
    let process: String
    /// 绑定地址集合：`*`=全部接口，`127.0.0.1` / `[::1]`=仅本机
    let addresses: [String]

    var id: String { "\(proto)-\(port)-\(process)" }

    /// 是否对局域网/外部开放（绑定到全部接口）
    var isExposed: Bool { addresses.contains("*") }

    /// 展示用地址：全部接口 / 具体地址（多个用 · 分隔）
    var addressLabel: String {
        if isExposed { return "全部接口" }
        let cleaned = addresses.map { $0 == "[::1]" ? "::1" : $0 }
        return cleaned.joined(separator: " · ")
    }

    /// 复制用主机：对外暴露时给回环地址（避免把 `*` 复制出去）
    var copyHost: String {
        if isExposed { return "127.0.0.1" }
        let first = addresses.first ?? "127.0.0.1"
        return first == "*" ? "127.0.0.1" : first.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
    }
}

/// 端口占用检查器（单例）：后台跑 lsof -F，主线程发布快照
final class PortInspector: ObservableObject {
    static let shared = PortInspector()

    @Published private(set) var bindings: [PortBinding] = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var isScanning = false
    /// 扫描失败且有旧数据时保留旧数据，仅记录原因供排障
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.frset.monitor.ports", qos: .utility)
    private var timer: Timer?
    private var isRunning = false
    private var lastScanUptime: TimeInterval = -1000

    /// 自动刷新间隔（页面可见时）
    private static let refreshInterval: TimeInterval = 10
    /// 最小扫描间隔（手动连点/页面反复切换时的兜底）
    private static let minInterval: TimeInterval = 3

    private static let lsofPath: String = {
        for p in ["/usr/sbin/lsof", "/usr/bin/lsof"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return "/usr/sbin/lsof"
    }()

    private init() {}

    // MARK: 生命周期

    /// 网络页出现：立即扫一次并开始 10s 轮询
    func start() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.start() }; return }
        guard !isRunning else { return }
        isRunning = true
        scan(force: true)
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.scan(force: false)
        }
        t.tolerance = 1.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 网络页消失：停止轮询（保留最后一次快照，切回时立即复用再刷新）
    func stop() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.stop() }; return }
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    // MARK: 扫描

    func scan(force: Bool = false) {
        // 应用不在前台时窗口已收起，没必要继续起子进程（手动刷新不受限）
        if !force, !NSApp.isActive { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastScanUptime < Self.minInterval { return }
        lastScanUptime = now
        guard !isScanning else { return }
        isScanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.runLsof()
            DispatchQueue.main.async {
                self.isScanning = false
                switch result {
                case .success(let list):
                    self.bindings = list
                    self.lastScan = Date()
                    self.lastError = nil
                    Log.info("Ports", "scan n=\(list.count) exposed=\(list.filter(\.isExposed).count)")
                case .failure(let err):
                    // 保留旧数据，避免「偶发失败把卡片清空」
                    self.lastError = err
                    Log.info("Ports", "scan 失败：\(err)")
                }
            }
        }
    }

    // MARK: lsof 执行与解析

    private enum ScanResult {
        case success([PortBinding])
        case failure(String)
    }

    private static func runLsof() -> ScanResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: lsofPath)
        p.arguments = ["-nP", "-FpcnPT", "-iTCP", "-sTCP:LISTEN", "-iUDP"]
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return .failure("无法执行 lsof：\(error.localizedDescription)")
        }
        // 看门狗：lsof 正常 <100ms，超过 3s 视为卡死
        let deadline = DispatchTime.now() + .seconds(3)
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: deadline) == .timedOut {
            p.terminate()
            return .failure("lsof 超时")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure("lsof 输出不可解码")
        }
        // lsof 无匹配时退出码 1；只要有内容就按解析结果走
        if text.isEmpty, p.terminationStatus != 0 {
            return .success([])
        }
        return .success(parse(text))
    }

    /// 解析 `-FpcnPT` 字段流：
    ///   p<pid> / c<command> 起进程块；f<fd> 起文件块；P<proto> / n<name> / TST=LISTEN
    static func parse(_ text: String) -> [PortBinding] {
        var pid: Int32 = 0
        var process = ""
        var proto = ""
        var name = ""
        var isListen = false
        var merged: [String: (proto: String, port: Int, pids: Set<Int32>, process: String, addrs: Set<String>)] = [:]

        func flush() {
            defer { proto = ""; name = ""; isListen = false }
            guard !name.isEmpty, !proto.isEmpty else { return }
            // 已连接 socket（含 `->`）不计入端口占用
            guard !name.contains("->") else { return }
            if proto == "TCP", !isListen { return }
            // 取最后一段冒号后的端口；`*:*` / 端口 0 视为未绑定
            guard let colon = name.lastIndex(of: ":") else { return }
            let portText = String(name[name.index(after: colon)...])
            guard let port = Int(portText), port > 0 else { return }
            var addr = String(name[..<colon])
            if addr.isEmpty { addr = "*" }
            if addr == "0.0.0.0" || addr == "::" { addr = "*" }
            // 合并口径：协议 + 端口 + 进程名（同名多实例合并，pid 保留在集合里）
            let key = "\(proto)-\(port)-\(process)"
            if var item = merged[key] {
                item.addrs.insert(addr)
                item.pids.insert(pid)
                merged[key] = item
            } else {
                merged[key] = (proto, port, [pid], process, [addr])
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p":
                flush()
                pid = Int32(value) ?? 0
                process = ""
            case "c":
                process = value
            case "f":
                flush()
            case "P":
                proto = value
            case "n":
                name = value
            case "T":
                if value == "ST=LISTEN" { isListen = true }
            default:
                break
            }
        }
        flush()

        return merged.values
            .map { item in
                PortBinding(proto: item.proto, port: item.port,
                            pids: item.pids.sorted(),
                            process: item.process.isEmpty ? "pid \(item.pids.first ?? 0)" : item.process,
                            addresses: item.addrs.sorted())
            }
            .sorted { a, b in
                if a.isExposed != b.isExposed { return a.isExposed }   // 对外暴露优先
                if a.proto != b.proto { return a.proto == "TCP" }      // TCP 在前
                if a.port != b.port { return a.port < b.port }
                return a.process.localizedCompare(b.process) == .orderedAscending
            }
    }
}
