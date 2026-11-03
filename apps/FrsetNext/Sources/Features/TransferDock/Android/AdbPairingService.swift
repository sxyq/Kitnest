import AppKit
import Combine
import Foundation

// MARK: - 无线配对服务（v130（AndroMeld/AgentHUD）：AndroMeld P0-1）
//
// 对标 AndroMeld P0 的「无线配对流程」：adb pair（配对码）→ adb connect（会话）→
// 设备列表管理（断开）。与既有 ADBWirelessEngine 的差异：
//   ① pair/connect/disconnect/mdns 是 **host 级命令**，绝不带 `-s <serial>` 前缀
//      （ADBWirelessEngine.runADB 会按 activeSerial 注入 -s，设备在线时反而可能失败）；
//   ② 显式状态机（配对中/已连接/失败原因）供 UI 呈现；
//   ③ disconnect 补齐（原引擎只有 connect）。
// 流程说明（Android 11+ 无线调试）：
//   手机「开发者选项 → 无线调试」开启 → 「使用配对码配对设备」得 ip:配对端口 + 6 位码
//   → adb pair ip:配对端口 码 → 无线调试页显示的 ip:连接端口 → adb connect。
//   两个端口不同（配对端口一次性，连接端口长期），mDNS 同时广播
//   _adb-tls-pair._tcp（配对）与 _adb-tls-connect._tcp（连接）两类服务。

public final class AdbPairingService: ObservableObject {

    public static let shared = AdbPairingService()

    /// 一条 mDNS 发现结果（含服务类型标注）
    public struct DiscoveredDevice: Identifiable, Equatable {
        public let id: String                 // name@target
        public let name: String               // 设备广播名
        public let target: String             // ip:port
        /// 服务类型：_adb-tls-pair._tcp（需配对码）/ _adb-tls-connect._tcp（可直连）
        public let serviceType: String
        public let needsPairing: Bool

        public var typeLabel: String { needsPairing ? "配对" : "连接" }
    }

    /// 配对/连接过程状态
    public enum Phase: Equatable {
        case idle
        case scanning
        case pairing(target: String)
        case connecting(target: String)
        case done(String)      // 成功/失败摘要（失败原因来自 adb 输出）
        case failed(String)

        public var isBusy: Bool {
            switch self {
            case .scanning, .pairing, .connecting: return true
            default: return false
            }
        }
    }

    @Published public private(set) var discovered: [DiscoveredDevice] = []
    /// 已连接的无线设备（adb devices 里 serial 形如 ip:port 的）
    @Published public private(set) var wirelessConnected: [String] = []
    @Published public private(set) var phase: Phase = .idle
    /// 状态提示行（配对中/已连接/失败原因）
    @Published public private(set) var statusText = ""

    private init() {}

    // MARK: - 扫描（adb mdns services）

    /// 扫描局域网无线调试服务（后台执行）
    public func scan() {
        phase = .scanning
        statusText = "正在扫描无线调试服务…"
        runADB(["mdns", "services"]) { [weak self] out in
            guard let self else { return }
            guard let out, !out.isEmpty else {
                self.phase = .failed("扫描失败（adb 不可用）")
                self.statusText = "扫描失败：adb 不可用"
                return
            }
            var result: [DiscoveredDevice] = []
            var seen = Set<String>()
            for line in out.split(separator: "\n") {
                // 形如：adb-XXXX-YYYY._adb-tls-connect._tcp\t192.168.1.5:37xxx
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .split(separator: "\t").map(String.init)
                guard parts.count >= 2, parts[1].contains(":") else { continue }
                let service = parts[0]
                let target = parts[1]
                let isPair = service.contains("_adb-tls-pair")   // pair / pairing 两种写法都认
                let type = isPair ? "_adb-tls-pair._tcp" : "_adb-tls-connect._tcp"
                let name = service
                    .replacingOccurrences(of: "._adb-tls-connect._tcp", with: "")
                    .replacingOccurrences(of: "._adb-tls-pairing._tcp", with: "")
                    .replacingOccurrences(of: "._adb-tls-pair._tcp", with: "")
                let id = name + "@" + target
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                result.append(DiscoveredDevice(id: id, name: name, target: target,
                                               serviceType: type, needsPairing: isPair))
            }
            self.discovered = result
            self.phase = result.isEmpty ? .idle : .done("发现 \(result.count) 个服务")
            self.statusText = result.isEmpty
                ? "未发现无线调试服务（手机需开启「开发者选项 → 无线调试」，且与本机同一 Wi-Fi）"
                : "发现 \(result.count) 个服务"
            self.refreshConnected()
        }
    }

    // MARK: - 配对 / 连接 / 断开

    /// adb pair <host:port> <code>（手机「使用配对码配对设备」弹窗里的 ip:端口 + 6 位码）
    public func pair(target: String, code: String) {
        let parts = target.split(separator: ":").map(String.init)
        guard parts.count == 2, !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .failed("参数不完整")
            statusText = "地址格式应为 IP:端口，且需要 6 位配对码"
            return
        }
        phase = .pairing(target: target)
        statusText = "正在配对 \(target)…"
        runADB(["pair", target, code.trimmingCharacters(in: .whitespaces)]) { [weak self] out in
            guard let self else { return }
            let text = out ?? ""
            if text.lowercased().contains("success") {
                self.phase = .done("配对成功")
                self.statusText = "配对成功 ✓ 请用「连接」建立会话（无线调试页的连接端口）"
                Toast.show("配对成功：\(target)", icon: "checkmark.seal.fill")
            } else {
                self.phase = .failed(text)
                self.statusText = "配对失败：\(text)"
                Toast.show("配对失败：\(String(text.prefix(60)))",
                           icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }

    /// adb connect <host:port>（无线调试页显示的「IP 地址和端口」）
    public func connect(target: String) {
        let parts = target.split(separator: ":").map(String.init)
        guard parts.count == 2 else {
            phase = .failed("地址格式应为 IP:端口")
            statusText = "地址格式应为 IP:端口"
            return
        }
        phase = .connecting(target: target)
        statusText = "正在连接 \(target)…"
        runADB(["connect", target]) { [weak self] out in
            guard let self else { return }
            let text = out ?? ""
            let ok = text.lowercased().contains("connected to")
                || text.lowercased().contains("already connected")
            if ok {
                self.phase = .done("已连接")
                self.statusText = "已连接 \(target)"
                Toast.show("已连接 \(target)", icon: "link")
            } else {
                self.phase = .failed(text)
                self.statusText = "连接失败：\(text)"
                Toast.show("连接失败：\(String(text.prefix(60)))",
                           icon: "exclamationmark.triangle", isWarning: true)
            }
            self.refreshConnected()
        }
    }

    /// adb disconnect <host:port>
    public func disconnect(target: String) {
        statusText = "正在断开 \(target)…"
        runADB(["disconnect", target]) { [weak self] out in
            guard let self else { return }
            self.statusText = "已断开 \(target)"
            Toast.show("已断开 \(target)", icon: "wifi.slash")
            self.refreshConnected()
        }
    }

    /// 刷新已连接的无线设备（adb devices 里 serial 含 ":" 的）
    public func refreshConnected() {
        runADB(["devices"]) { [weak self] out in
            guard let self else { return }
            var list: [String] = []
            for line in (out ?? "").split(separator: "\n").dropFirst() {
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count >= 2, parts[1] == "device", parts[0].contains(":") else { continue }
                list.append(parts[0])
            }
            self.wirelessConnected = list
        }
    }

    // MARK: - adb 执行（host 级命令：**不注入 -s**，与 ADBWirelessEngine 的差异点）

    private func runADB(_ args: [String], completion: @escaping (String?) -> Void) {
        guard let adb = ScreenCastEngine.findADB() else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            task.arguments = args
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
            DispatchQueue.main.async {
                completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
