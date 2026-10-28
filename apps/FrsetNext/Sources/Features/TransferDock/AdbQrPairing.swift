import Foundation
import Combine

// MARK: - 扫码直连（Android 11+ 无线调试 · QR 配对）
//
// 用户 2026-10-29：「最重要的是扫码直连，而不是基于某个局域网再 adb 连」
//
// 机制与 Android Studio 的「Pair device with QR code」完全一致，全流程零手输：
//   1. 本机生成一次性 service name + pairing code，编成二维码
//        WIFI:T:ADB;S:<serviceName>;P:<code>;;
//      （`WIFI:` 前缀是借 WPA3 的格式，S 不是 SSID 而是 mDNS 实例名，P 不是密码而是配对码）
//   2. 手机：设置 → 开发者选项 → 无线调试 → 「使用二维码配对设备」→ 扫码。
//      手机随后以 <serviceName> 为实例名广播 `_adb-tls-pairing._tcp`
//   3. 本机 `adb mdns services` 轮询发现该实例 → `adb pair ip:port <code>`
//   4. 配对成功后手机广播 `_adb-tls-connect._tcp` → `adb connect ip:port`
//   5. `adb devices` 出现设备 → 直接拉起 scrcpy 镜像
//
// 参考实现（都是 MIT，机制相同、只是壳不同，我们照机制用 Swift 重写，不引依赖）：
//   · wadb          github.com/LinDevHard/wadb      （Go，CLI 打印二维码）
//   · adbqr         github.com/kristjan/adbqr       （bash + qrencode）
//   · adb-auto-pair github.com/etng/adb-auto-pair   （Go）
//
// 已知限制（不是我们能修的）：手机与 Mac 必须在同一网段且**未开 AP 隔离**
// （酒店/公司 Wi-Fi 常见），因为配对依赖 mDNS 双向发现；此时退回 USB 或手机热点。
public final class AdbQrPairing: ObservableObject {

    public enum Phase: Equatable {
        case idle
        /// 等手机扫码
        case waiting
        /// 已发现手机的配对服务
        case found(String)
        case pairing
        /// 已配对，正在 connect
        case connecting
        case connected(String)
        case failed(String)
        case expired

        public var text: String {
            switch self {
            case .idle:            return "准备中…"
            case .waiting:         return "等待手机扫码…"
            case .found(let host): return "发现手机 \(host)，开始配对…"
            case .pairing:         return "配对中…"
            case .connecting:      return "已配对，正在连接…"
            case .connected(let s): return "已连接 \(s)，正在投屏"
            case .failed(let why): return "失败：\(why)"
            case .expired:         return "超时未扫码"
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .connected, .failed, .expired: return true
            default: return false
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    /// 连接成功回调（参数为 adb serial，如 192.168.1.5:37651）
    public var onConnected: ((String) -> Void)?

    @Published public private(set) var serviceName: String
    @Published public private(set) var code: String

    /// 二维码内容（手机相机/无线调试扫码识别）
    public var qrText: String { "WIFI:T:ADB;S:\(serviceName);P:\(code);;" }

    private var timer: Timer?
    private var startedAt = Date()
    private var pairedHost: String?
    private var connectAttempts = 0
    private let timeout: TimeInterval = 120

    public init() {
        // Android Studio 用 `studio-` 前缀 + 随机串；我们沿用前缀，
        // 避免个别 ROM 的相机处理器只认这个前缀（AOSP 代码里就是判 T:ADB，
        // 但前缀保持一致零成本）。
        serviceName = "studio-frset-" + Self.randomToken(6)
        code = Self.randomToken(8)
    }

    /// 换一套凭证（配对码是一次性的，重试必须重新生成，否则手机会拒）
    private func regenerate() {
        serviceName = "studio-frset-" + Self.randomToken(6)
        code = Self.randomToken(8)
    }

    deinit { timer?.invalidate() }

    // MARK: 生命周期

    public func start() {
        guard timer == nil else { return }
        startedAt = Date()
        pairedHost = nil
        connectAttempts = 0
        phase = .waiting
        Log.info("Transfer", "扫码直连：等待扫码 service=\(serviceName)")
        let t = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        if !phase.isTerminal { phase = .idle }
    }

    public func restart() {
        cancel()
        regenerate()
        start()
    }

    private func finish(_ newPhase: Phase) {
        timer?.invalidate()
        timer = nil
        phase = newPhase
    }

    // MARK: 轮询

    private func tick() {
        if Date().timeIntervalSince(startedAt) > timeout {
            finish(.expired)
            return
        }
        switch phase {
        case .connecting:
            pollConnectService()
        default:
            pollPairingService()
        }
    }

    /// 等配对服务出现（手机扫完码才会广播）
    private func pollPairingService() {
        ADBWirelessEngine.discoverServices { [weak self] list in
            guard let self, let list else { return }
            // 只认我们自己生成的那个实例名——同一网段可能有别人在用 Studio 配对
            guard let svc = list.first(where: { $0.needsPairing && $0.name == self.serviceName }),
                  let addr = Self.split(svc.target) else { return }
            self.pairedHost = addr.host
            self.phase = .found(addr.host)
            self.doPair(host: addr.host, port: addr.port)
        }
    }

    private func doPair(host: String, port: String) {
        guard phase != .pairing else { return }
        phase = .pairing
        ADBWirelessEngine.pair(host: host, port: port, code: code) { [weak self] out in
            guard let self else { return }
            if out.lowercased().contains("successfully paired") || out.lowercased().contains("already paired") {
                Log.info("Transfer", "扫码直连：配对成功 \(host)")
                self.phase = .connecting
                self.connectAttempts = 0
            } else {
                Log.warn("Transfer", "扫码直连：配对失败 \(out)")
                // 一次失败不算致命（手机可能还在起服务），继续等下一轮；超过 3 次才报错
                self.connectAttempts += 1
                if self.connectAttempts >= 3 {
                    self.finish(.failed(out.isEmpty ? "adb pair 无输出" : out))
                } else {
                    self.phase = .waiting
                }
            }
        }
    }

    /// 配对完成后，手机广播 `_adb-tls-connect._tcp`，连它即可
    private func pollConnectService() {
        ADBWirelessEngine.discoverServices { [weak self] list in
            guard let self, let list else { return }
            let candidates = list.filter { !$0.needsPairing }
            // 优先同 IP 的那条（同一台手机），否则取第一条
            let hit = candidates.first(where: { $0.target.hasPrefix((self.pairedHost ?? "") + ":") })
                ?? candidates.first
            guard let hit, let addr = Self.split(hit.target) else { return }
            ADBWirelessEngine.connect(host: addr.host, port: addr.port) { [weak self] out in
                guard let self else { return }
                let ok = out.lowercased().contains("connected")
                if ok {
                    let serial = "\(addr.host):\(addr.port)"
                    Log.info("Transfer", "扫码直连：已连接 \(serial)")
                    self.finish(.connected(serial))
                    self.onConnected?(serial)
                } else {
                    self.connectAttempts += 1
                    if self.connectAttempts >= 10 {
                        self.finish(.failed(out.isEmpty ? "adb connect 无输出" : out))
                    }
                }
            }
        }
    }

    // MARK: 工具

    private static func split(_ target: String) -> (host: String, port: String)? {
        let parts = target.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// 二维码里的随机串：只用字母数字，避免 `;` `:` 等分隔符破坏解析
    private static func randomToken(_ n: Int) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<n).compactMap { _ in alphabet.randomElement() })
    }
}
