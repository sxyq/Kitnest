import Foundation
import Combine

// MARK: - 扫码直连 + 免扫码重连（Android 11+ 无线调试）
//
// 用户 2026-10-29：「最重要的是扫码直连，而不是基于某个局域网再 adb 连」
// 用户 2026-10-29 追加：「按照 AndroMeld 的方式一步一步做，手机端看能否通过扫码完成」
//
// ── 手机端为什么可以「零安装 + 只扫码」────────────────────────────
// 逆向确认（Project/temp/AndroMeld/逆向-01-连接与扫码真相.md）：
//   AndroMeld 手机端靠 `IAdbManager.enablePairingByQrCode(S, P)` 自己给自己开配对服务，
//   S/P 是它自己随机生成的，所以它**不需要二维码**，它的交互是「12 位连接码 + 6 位配对码」。
//   我们反过来：S/P 由 Mac 生成并放进二维码，手机用**系统相机**扫，
//   系统识别 `WIFI:T:ADB;` 前缀后自动跳到「无线调试」并调 enablePairingByQrCode(S, P)，
//   手机 adbd 随即广播 `_adb-tls-pairing._tcp` —— 这一步完全由 Android 系统完成，
//   手机端**不需要装任何 App**。这就是我们能保住「零安装」的原因。
//
// ── 但「每次都要扫码」是可以消掉的 ────────────────────────────────
// AndroMeld 的体验优势其实是「配对一次永久免确认」（TLS 1.3 双向证书）。
// 我们拿不到同等级凭据，但 ADB 的 RSA 授权本身也是持久的，变的只是端口。
// 所以按成本从低到高试三级（见 AdbCastMemory 注释）：
//   ① 已在线（adb devices 里有无线设备）→ 0 交互
//   ② 上次的 serial / 同 IP 的 5555       → 0 交互
//   ③ 都失败 → 才显示二维码让用户扫
//
// 配对链路（与 Android Studio「Pair device with QR code」完全一致）：
//   1. 本机生成一次性 S/P，编成 `WIFI:T:ADB;S:<S>;P:<P>;;`
//   2. 手机系统相机扫 → 系统调 enablePairingByQrCode(S, P) → adbd 广播 `_adb-tls-pairing._tcp`
//   3. 本机 `adb mdns services` **等到**该实例出现 → `adb pair ip:port P`（不能抢跑，见 v159 注释）
//   4. 手机广播 `_adb-tls-connect._tcp` → `adb connect ip:port`
//   5. `adb devices` 出现设备 → 拉起 scrcpy
//
// 参考实现（均 MIT，机制相同、只是壳不同，我们照机制用 Swift 重写，不引依赖）：
//   · wadb          github.com/LinDevHard/wadb      （Go，CLI 打印二维码）
//   · adbqr         github.com/kristjan/adbqr       （bash + qrencode）
//   · adb-auto-pair github.com/etng/adb-auto-pair   （Go）
//
// 已知限制（不是我们能修的）：手机与 Mac 必须在同一网段且**未开 AP 隔离**
// （酒店/公司 Wi-Fi 常见），因为配对依赖 mDNS 双向发现；此时退回 USB 或手机热点。
public final class AdbQrPairing: ObservableObject {

    public enum Phase: Equatable {
        case idle
        /// v164：先找 mDNS 里已授权的连接服务（0 交互，不急着出二维码）
        case discovering
        /// v159：正在尝试「上次的设备」，命中就不需要扫码
        case reconnecting(String)
        /// 等手机扫码
        case waiting
        /// 已发现手机的配对服务
        case found(String)
        case pairing
        /// 已配对，正在 connect
        case connecting
        /// v159：已连接，正在起 scrcpy（对应 AndroMeld ctrl 的 ready→live 之间）
        case launching(String)
        case connected(String)
        case failed(String)
        case expired

        public var text: String {
            switch self {
            case .idle:                 return "准备中…"
            case .discovering:          return "正在查找已授权设备…"
            case .reconnecting(let d):  return "正在连接上次的设备 \(d)…"
            case .waiting:              return "等待手机扫码…"
            case .found(let host):      return "发现手机 \(host)，开始配对…"
            case .pairing:              return "配对中…"
            case .connecting:           return "已配对，正在连接…"
            case .launching:            return "已连接，正在建立画面…"
            case .connected(let s):     return "已连接 \(s)，正在投屏"
            case .failed(let why):      return "失败：\(why)"
            case .expired:              return "超时未扫码"
            }
        }

        public var isTerminal: Bool {
            switch self {
            case .connected, .failed, .expired: return true
            default: return false
            }
        }

        /// 是否需要显示二维码（重连阶段先不显示，避免用户以为必须扫）
        public var showsQR: Bool {
            switch self {
            case .reconnecting, .idle, .discovering: return false
            default: return true
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    /// 连接成功回调（参数为 adb serial，如 192.168.1.5:37651）
    public var onConnected: ((String) -> Void)?
    /// 扫码口径：是否已经尝试过重连（UI 用来决定文案）
    @Published public private(set) var didTryReconnect = false

    @Published public private(set) var serviceName: String
    @Published public private(set) var code: String

    /// 二维码内容（手机系统相机识别为「无线调试配对」）
    public var qrText: String { "WIFI:T:ADB;S:\(serviceName);P:\(code);;" }

    private var timer: Timer?
    private var startedAt = Date()
    private var pairedHost: String?
    private var connectAttempts = 0
    private var pairAttempts = 0
    private let timeout: TimeInterval = 120
    /// v159：重连阶段不占用 120s 主超时
    private var reconnectDeadline = Date()
    /// v159：会话代数。每次 start / restart / skipReconnect 递增，
    /// 过期回调（比如 6s 降级后才返回的 adb connect）一律作废——
    /// 否则会出现「已经显示二维码，两秒后突然跳到已连接」这种诡异行为。
    private var generation = 0
    /// v159：重连降级定时器。
    /// 原来靠 1.2s 轮询 timer 判断 `Date() > reconnectDeadline`，
    /// 实机验证发现 tick 在 reconnecting 阶段**没有按时触发**（等了 50s 仍停在转圈），
    /// 改成一次性 DispatchWorkItem：到点必执行、可取消、不依赖 RunLoop 轮询节奏。
    private var reconnectFallback: DispatchWorkItem?

    public init() {
        // Android Studio 用 `studio-` 前缀 + 随机串；我们沿用前缀，
        // 避免个别 ROM 的相机处理器只认这个前缀（AOSP 代码里就是判 T:ADB，
        // 但前缀保持一致零成本）。
        serviceName = "studio-frset-" + Self.randomToken(6)
        // v164：配对码改成 **6 位数字**。系统「使用配对码配对设备」给的就是 6 位数字，
        // 主流实现（Super_ADB / adbqr）也按 6 位随机数生成；此前用 8 位字母数字，
        // 部分 ROM 的扫码解析会直接判为非法二维码（表现为「扫了没反应」）。
        code = Self.randomDigits(6)
    }

    /// 换一套凭证（配对码是一次性的，重试必须重新生成，否则手机会拒）
    private func regenerate() {
        serviceName = "studio-frset-" + Self.randomToken(6)
        code = Self.randomDigits(6)
    }

    deinit { timer?.invalidate() }

    // MARK: 生命周期

    public func start() {
        guard timer == nil else { return }
        startedAt = Date()
        pairedHost = nil
        connectAttempts = 0
        pairAttempts = 0
        didTryReconnect = false
        generation += 1

        // v159：先试「免扫码重连」，命中就直接结束；失败再进扫码态。
        // 这一步是 AndroMeld「第二次零交互」在我们这套 ADB 方案里的等价物。
        if let last = AdbCastMemory.shared.lastDevice, !AdbCastMemory.shared.isEmpty {
            didTryReconnect = true
            phase = .reconnecting(last.displayName)
            reconnectDeadline = Date().addingTimeInterval(6)
            Log.info("Transfer", "扫码直连：先尝试免扫码重连 \(last.serial)")
            scheduleReconnectFallback()
        } else {
            // v164：没有历史记录也先找 mDNS 里现成的连接服务——
            // 只要这台手机以前授权过（USB 授权或配对过），无线调试一开就能直连，
            // 完全不需要再扫一次码。找不到才出二维码。
            phase = .discovering
            Log.info("Transfer", "扫码直连：先查找 mDNS 里的已授权设备")
            let gen = generation
            tryDiscoveredConnections(gen: gen) { [weak self] hit in
                guard let self, gen == self.generation, !hit, self.phase == .discovering else { return }
                self.phase = .waiting
                Log.info("Transfer", "扫码直连：未发现可用设备，等待扫码 service=\(self.serviceName)")
                self.tick()
            }
        }

        let t = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if didTryReconnect {
            attemptReconnect()
        } else {
            tick()
        }
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        reconnectFallback?.cancel()
        reconnectFallback = nil
        if !phase.isTerminal { phase = .idle }
    }

    public func restart() {
        cancel()
        regenerate()
        start()
    }

    /// 用户主动选「换一台设备扫码」：跳过重连直接进扫码态
    public func skipReconnect() {
        guard timer != nil else { return }
        generation += 1          // 作废所有在途的重连回调
        reconnectFallback?.cancel()
        reconnectFallback = nil
        phase = .waiting
        Log.info("Transfer", "扫码直连：用户选择扫码新设备 service=\(serviceName)")
        tick()
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
        case .discovering:
            // 一次性发现任务在跑，不在这里轮询（避免拿到过期配对码）
            break
        case .connecting:
            pollConnectService()
        case .reconnecting:
            // 双保险：一次性任务 + 轮询判断，谁先到谁降级。
            // （实测出现过「一次性任务没执行」的诡异情况，两个都留着）
            if Date() > reconnectDeadline {
                Log.info("Transfer", "扫码直连：轮询判定重连超时，转为扫码")
                generation += 1
                phase = .waiting
                tick()
            }
        default:
            pollPairingService()
        }
    }

    // MARK: v159 · 免扫码重连（对应 AndroMeld 的 mTLS 长期凭据）

    /// 6 秒内没连上就降级到扫码。用一次性任务而不是轮询判断——
    /// 轮询版本实测在 reconnecting 阶段不会按时触发（原因未完全定位，
    /// 但与 RunLoop 在面板/弹层上的调度有关），一次性任务不依赖它。
    private func scheduleReconnectFallback() {
        reconnectFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .reconnecting = self.phase else {
                Log.debug("Transfer", "重连降级任务：phase=\(self.phase) 已变，跳过")
                return
            }
            Log.info("Transfer", "扫码直连：6 秒未连上，转为扫码")
            self.generation += 1        // 作废还在路上的 adb connect 回调
            self.phase = .waiting
            self.tick()
        }
        reconnectFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// 三级回退：已在线 → 记忆 serial → 同 IP 的 5555
    private func attemptReconnect() {
        // ① 已经在线（用户可能刚在别处连过，或上次会话还活着）
        let gen = generation
        ScreenCastEngine.connectedDevices { [weak self] list in
            guard let self, gen == self.generation else { return }
            // 优先无线（含 ":"），其次 USB —— 插着数据线时也应该直接投，不要逼用户扫码
            let pick = list?.first(where: {
                $0.state == "device" && $0.serial.contains(":")
            }) ?? list?.first(where: { $0.state == "device" })
            if let online = pick {
                Log.info("Transfer", "扫码直连：设备已在线 \(online.serial)，跳过扫码")
                self.succeed(serial: online.serial)
                return
            }
            // ①.5 v164：mDNS 里现成的「连接服务」直接试。
            // 无线调试的端口每次开关都会变，记忆里的 serial 很快过期（本例记的是
            // 10.255.255.1:37651，早已不可达）；而 mDNS 广播里的 target 永远是当前端口。
            // 已配对/已授权的设备因此可以完全跳过扫码。
            self.tryDiscoveredConnections(gen: gen) { hit in
                guard !hit else { return }
                // ② 记忆里的 serial 逐个试
                self.tryCandidates(index: 0)
            }
        }
    }

    /// 用 mDNS 发现的 `_adb-tls-connect` 服务直接连（不配对、不出二维码）
    private func tryDiscoveredConnections(gen: Int, attempt: Int = 0,
                                          completion: @escaping (Bool) -> Void) {
        ADBWirelessEngine.discoverServices { [weak self] list in
            guard let self, gen == self.generation else { return }
            let targets = (list ?? []).filter { !$0.needsPairing }.map { $0.target }
            guard !targets.isEmpty else {
                // adb 的 mDNS 列表偶发返回空（实测：刚 adb disconnect 后有一次空列表），
                // 空结果不等于没有设备 —— 重试两次再放弃。
                if attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.tryDiscoveredConnections(gen: gen, attempt: attempt + 1,
                                                       completion: completion)
                    }
                } else {
                    completion(false)
                }
                return
            }
            Log.info("Transfer", "扫码直连：mDNS 发现 \(targets.count) 个连接服务，尝试直连")
            self.tryDiscoveredTargets(targets, index: 0, gen: gen, completion: completion)
        }
    }

    private func tryDiscoveredTargets(_ targets: [String], index: Int, gen: Int,
                                      completion: @escaping (Bool) -> Void) {
        guard index < targets.count else { completion(false); return }
        guard let addr = Self.split(targets[index]) else {
            tryDiscoveredTargets(targets, index: index + 1, gen: gen, completion: completion)
            return
        }
        ADBWirelessEngine.connect(host: addr.host, port: addr.port, timeout: 3) { [weak self] out in
            guard let self, gen == self.generation else { return }
            guard out.lowercased().contains("connected") else {
                self.tryDiscoveredTargets(targets, index: index + 1, gen: gen, completion: completion)
                return
            }
            // adb connect 成功 ≠ 设备可用（可能 unauthorized/offline），再确认一次
            ScreenCastEngine.connectedDevices { [weak self] list in
                guard let self, gen == self.generation else { return }
                if list?.contains(where: { $0.serial == targets[index] && $0.state == "device" }) == true {
                    Log.info("Transfer", "扫码直连：mDNS 直连成功 \(targets[index])")
                    self.succeed(serial: targets[index])
                    completion(true)
                } else {
                    self.tryDiscoveredTargets(targets, index: index + 1, gen: gen, completion: completion)
                }
            }
        }
    }

    private func tryCandidates(index: Int) {
        let gen = generation
        let candidates = AdbCastMemory.shared.candidates()
        guard index < candidates.count else {
            // ③ 全失败 → 扫码
            Log.info("Transfer", "扫码直连：\(candidates.count) 个历史设备均未连上，转为扫码")
            phase = .waiting
            tick()
            return
        }
        let dev = candidates[index]
        Log.info("Transfer", "扫码直连：尝试 \(dev.serial)")
        ADBWirelessEngine.connect(host: dev.host, port: dev.port, timeout: 3) { [weak self] out in
            guard let self, gen == self.generation else { return }
            let lower = out.lowercased()
            let ok = lower.contains("connected to") && !lower.contains("failed")
            if ok {
                // adb connect 成功不代表设备可用（可能 offline/unauthorized），再确认一次
                ScreenCastEngine.connectedDevices { [weak self] list in
                    guard let self, gen == self.generation else { return }
                    let usable = list?.contains { $0.serial == dev.serial && $0.state == "device" } ?? false
                    if usable {
                        Log.info("Transfer", "扫码直连：重连成功 \(dev.serial)")
                        self.succeed(serial: dev.serial, name: dev.displayName)
                    } else {
                        self.tryCandidates(index: index + 1)
                    }
                }
            } else if !dev.isStickyPort {
                // 端口变了 → 同 IP 的 5555 再试一次（老式 tcpip，端口固定）
                Log.info("Transfer", "扫码直连：\(dev.serial) 失败，回退 5555")
                ADBWirelessEngine.connect(host: dev.host, port: "5555", timeout: 3) { [weak self] out2 in
                    guard let self, gen == self.generation else { return }
                    if out2.lowercased().contains("connected to") {
                        self.succeed(serial: "\(dev.host):5555", name: dev.displayName)
                    } else {
                        self.tryCandidates(index: index + 1)
                    }
                }
            } else {
                self.tryCandidates(index: index + 1)
            }
        }
    }

    private func succeed(serial: String, name: String? = nil) {
        AdbCastMemory.shared.remember(serial: serial, name: name)   // 记住是安全的（设备确实通了）
        // 先停在 .launching（= 对应 AndroMeld ctrl 通道的 ready→live 之间），
        // 0.8s 后再转 .connected；这段时间留给 scrcpy 起窗口，
        // 避免「显示已连接」之后黑屏两秒不知道发生了什么。
        timer?.invalidate()
        timer = nil
        phase = .launching(serial)
        onConnected?(serial)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.phase == .launching(serial) else { return }
            self.phase = .connected(serial)
        }
    }

    // MARK: 扫码配对

    /// 等配对服务出现（手机扫完码才会广播）
    ///
    /// v159：这里**必须等**，不能抢跑。手机扫完码到 adbd 真的开始广播
    /// `_adb-tls-pairing._tcp` 之间有 0.3–2s 的窗口（系统要起 adbd 的 TLS server）。
    /// 抢跑 `adb pair` 会得到 "Failed to pair" 或 "cannot connect"，表现为
    /// 「扫了没反应，再扫一次就好」——这是之前最主要的偶发失败来源。
    private func pollPairingService() {
        let gen = generation
        ADBWirelessEngine.discoverServices { [weak self] list in
            guard let self, gen == self.generation, let list else { return }
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
        let gen = generation
        ADBWirelessEngine.pair(host: host, port: port, code: code) { [weak self] out in
            guard let self, gen == self.generation else { return }
            let lower = out.lowercased()
            if lower.contains("successfully paired") || lower.contains("already paired") {
                Log.info("Transfer", "扫码直连：配对成功 \(host)")
                self.phase = .connecting
                self.connectAttempts = 0
            } else {
                Log.warn("Transfer", "扫码直连：配对失败 \(out)")
                // 一次失败不算致命（手机可能还在起服务），继续等下一轮；超过 3 次才报错
                self.pairAttempts += 1
                if self.pairAttempts >= 3 {
                    self.finish(.failed(out.isEmpty ? "adb pair 无输出" : out))
                } else {
                    self.phase = .waiting
                }
            }
        }
    }

    /// 配对完成后，手机广播 `_adb-tls-connect._tcp`，连它即可
    private func pollConnectService() {
        let gen = generation
        ADBWirelessEngine.discoverServices { [weak self] list in
            guard let self, gen == self.generation, let list else { return }
            let candidates = list.filter { !$0.needsPairing }
            // 优先同 IP 的那条（同一台手机），否则取第一条
            let hit = candidates.first(where: { $0.target.hasPrefix((self.pairedHost ?? "") + ":") })
                ?? candidates.first
            guard let hit, let addr = Self.split(hit.target) else { return }
            ADBWirelessEngine.connect(host: addr.host, port: addr.port, timeout: 8) { [weak self] out in
                guard let self, gen == self.generation else { return }
                let ok = out.lowercased().contains("connected")
                if ok {
                    let serial = "\(addr.host):\(addr.port)"
                    Log.info("Transfer", "扫码直连：已连接 \(serial)")
                    self.succeed(serial: serial)
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

    /// 6 位数字配对码（与系统「使用配对码配对设备」同形）
    private static func randomDigits(_ n: Int) -> String {
        String((0..<n).compactMap { _ in "0123456789".randomElement() })
    }
}
