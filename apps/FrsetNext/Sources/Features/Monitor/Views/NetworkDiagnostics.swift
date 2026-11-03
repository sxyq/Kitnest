import CFNetwork
import Foundation
import Network

// MARK: - 网络诊断（IP / 归属 / 代理 / 延迟 / DNS）
//
// 能力对照「鹅的IP」插件（ZToolsCenter/ZTools-plugins · plugins/e-de-ip）：
//   内网：本机网卡 IPv4，可切换
//   公网：国内接口拿 IPv4 + 区县归属（myip.ipip.net 一步返回中文归属）
//   代理：**读本地真实状态**（v45）——系统代理设置 + 常见代理端口监听 + 进程名，
//        不再只靠"公网归属非中国"推断（那只在开着代理时才准，且认不出 Clash）
//   延迟：并发 HEAD 各站点 favicon，取 TTFB（与插件同口径）
//   DNS：bash.ws 泄漏检测，拿真实出口解析器（不是系统里填的那个）
//
// 全部匿名公开接口，无需 key（插件里的高德/腾讯 key 是可选的精度增强，这里不接）。

struct NetInterfaceInfo: Identifiable, Equatable {
    let name: String          // en0
    let address: String       // 192.168.1.5
    let isPrimary: Bool
    var id: String { name }
}

struct SiteLatency: Identifiable, Equatable {
    let name: String
    let host: String
    var milliseconds: Int?
    var id: String { name }
}

final class NetworkDiagnostics: ObservableObject {

    static let shared = NetworkDiagnostics()

    @Published private(set) var interfaces: [NetInterfaceInfo] = []
    @Published private(set) var selectedInterface: String = ""
    @Published private(set) var publicIP: String?
    @Published private(set) var publicLocation: String?
    @Published private(set) var overseasIP: String?
    @Published private(set) var overseasLocation: String?
    @Published private(set) var isProxyLikely = false
    /// 本地代理客户端名（"Clash" / "Clash Verge" / "Surge" / "系统代理" / nil=没检测到）
    @Published private(set) var proxyLabel: String?
    /// 代理地址（"127.0.0.1:7890"）
    @Published private(set) var proxyAddress: String?
    /// 补充说明（"系统代理" / "TUN 模式（未设系统代理）"）
    @Published private(set) var proxyNote: String?
    @Published private(set) var latencies: [SiteLatency] = NetworkDiagnostics.defaultSites
    @Published private(set) var dnsServers: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?

    private let session: URLSession
    private let queue = DispatchQueue(label: "frset.netdiag", qos: .utility)
    private var inFlight = false

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 诊断请求不跟随系统代理会让「国外出口」失真，这里保持默认（跟随系统代理）
        session = URLSession(configuration: config)
    }

    static let defaultSites: [SiteLatency] = [
        .init(name: "百度", host: "https://www.baidu.com/favicon.ico", milliseconds: nil),
        .init(name: "网易云", host: "https://music.163.com/favicon.ico", milliseconds: nil),
        .init(name: "阿里云", host: "https://www.aliyun.com/favicon.ico", milliseconds: nil),
        .init(name: "腾讯云", host: "https://cloud.tencent.com/favicon.ico", milliseconds: nil),
        .init(name: "GitHub", host: "https://github.com/favicon.ico", milliseconds: nil),
        .init(name: "Google", host: "https://www.google.com/generate_204", milliseconds: nil),
        .init(name: "ChatGPT", host: "https://chatgpt.com/favicon.ico", milliseconds: nil),
        .init(name: "Cursor", host: "https://cursor.com/favicon.ico", milliseconds: nil)
    ]

    var selectedAddress: String {
        interfaces.first(where: { $0.name == selectedInterface })?.address
            ?? interfaces.first?.address ?? "—"
    }

    func selectInterface(_ name: String) {
        selectedInterface = name
    }

    // MARK: 刷新

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        isLoading = true
        queue.async { [weak self] in
            guard let self else { return }
            self.reloadInterfaces()
            self.probeProxy()
            self.probePublicIP { ip, location in
                DispatchQueue.main.async {
                    self.publicIP = ip
                    self.publicLocation = location
                    // 代理判断：出口 IP 与本地网段不同且归属非中国 → 视为走了代理/TUN
                    self.isProxyLikely = Self.looksProxied(location: location)
                    self.overseasIP = self.isProxyLikely ? ip : nil
                    self.overseasLocation = self.isProxyLikely ? location : nil
                }
            }
            self.probeLatencies()
            self.probeDNS()
            DispatchQueue.main.async {
                self.isLoading = false
                self.inFlight = false
                self.lastRefresh = Date()
            }
        }
    }

    private static func looksProxied(location: String?) -> Bool {
        guard let location, !location.isEmpty else { return false }
        // 归属里出现「中国」且不含港澳台 → 视为直连；否则按代理出口处理
        if location.contains("中国") { return false }
        return true
    }

    // MARK: 本地代理（Clash / mihomo / Surge / sing-box …）
    //
    // 用户 2026-10-18 反馈"公网以及代理没有读取到本地 Clash 的情况"：
    // 旧逻辑只按"公网归属是否含中国"推断代理，认不出客户端、也读不到端口。
    // 这里改读三处**真实状态**：
    //   ① 系统代理设置（CFNetworkCopySystemProxySettings，HTTP/SOCKS）
    //   ② 常见代理端口的本地监听（7890/7891/1087/6152/8889/1080/8080）
    //   ③ 进程表里的客户端名（clash / mihomo / verge / surge / sing-box / v2ray）
    private func probeProxy() {
        let system = Self.systemProxyInfo()
        let listeningPort = Self.detectListeningProxyPort()
        // 客户端名：优先看进程；沙箱/权限拿不到 ps 时按端口约定推断
        // （7890/7891/7897 = Clash 系，6152 = Surge，8889 = ClashX，1080 = SOCKS）
        let client = Self.detectProxyProcess()
            ?? Self.clientName(forPort: system?.port)
            ?? Self.clientName(forPort: listeningPort)
        let systemAddress = system?.address

        DispatchQueue.main.async {
            switch (client, systemAddress, listeningPort) {
            case let (client?, system?, _):
                self.proxyLabel = client
                self.proxyAddress = system
                self.proxyNote = "系统代理"
            case let (client?, nil, port?):
                self.proxyLabel = client
                self.proxyAddress = "127.0.0.1:\(port)"
                self.proxyNote = "TUN 模式（未设系统代理）"
            case let (client?, nil, nil):
                self.proxyLabel = client
                self.proxyAddress = nil
                self.proxyNote = "客户端在运行，未发现本地监听端口"
            case let (nil, system?, _):
                self.proxyLabel = "系统代理"
                self.proxyAddress = system
                self.proxyNote = nil
            case let (nil, nil, port?):
                self.proxyLabel = "本地代理"
                self.proxyAddress = "127.0.0.1:\(port)"
                self.proxyNote = "TUN 模式"
            default:
                self.proxyLabel = nil
                self.proxyAddress = nil
                self.proxyNote = nil
            }
        }
    }

    /// 系统代理（HTTP 优先，其次 SOCKS）——Clash 开「系统代理」时这里会有值
    private static func systemProxyInfo() -> (address: String, port: Int)? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        if let enabled = settings["HTTPEnable"] as? Int, enabled == 1,
           let host = settings["HTTPProxy"] as? String, let port = settings["HTTPPort"] as? Int {
            return ("\(host):\(port)", port)
        }
        if let enabled = settings["SOCKSEnable"] as? Int, enabled == 1,
           let host = settings["SOCKSProxy"] as? String, let port = settings["SOCKSPort"] as? Int {
            return ("\(host):\(port)", port)
        }
        return nil
    }

    /// 按端口约定推断客户端（ps 不可用时的兜底）
    private static func clientName(forPort port: Int?) -> String? {
        guard let port else { return nil }
        switch port {
        case 7890, 7891, 7897: return "Clash"
        case 8889:             return "ClashX"
        case 6152:             return "Surge"
        case 1080:             return "SOCKS 代理"
        default:               return nil
        }
    }

    /// 进程表里找代理客户端（GUI 与后台核心都能命中）
    private static func detectProxyProcess() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for raw in output.split(separator: "\n") {
            let name = (raw.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent.lowercased()
            guard !name.isEmpty else { continue }
            if name.contains("clash-verge") || name.contains("verge-mihomo") || name.contains("clash verge") {
                return "Clash Verge"
            }
            if name.contains("clash") || name.contains("mihomo") { return "Clash" }
            if name.contains("surge") { return "Surge" }
            if name.contains("sing-box") { return "sing-box" }
            if name.contains("v2ray") { return "V2Ray" }
            if name.contains("shadowsocks") { return "Shadowsocks" }
        }
        return nil
    }

    /// 常见代理客户端的本地混合 / HTTP 端口
    /// （Clash 7890、Clash Verge 7897、Surge 6152、V2Ray 1080、ClashX 8889 …）
    private static let candidateProxyPorts = [7890, 7891, 7897, 1087, 6152, 8889, 1080, 8080]

    private static func detectListeningProxyPort() -> Int? {
        candidateProxyPorts.first { isLocalPortOpen($0) }
    }

    /// 127.0.0.1 端口是否在监听（非阻塞 connect + poll 80ms，不阻塞主线程太久）
    private static func isLocalPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        return poll(&descriptor, 1, 80) > 0
    }

    // MARK: 内网网卡

    private func reloadInterfaces() {
        var result: [NetInterfaceInfo] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return }
        defer { freeifaddrs(pointer) }

        let primaryName = Self.primaryInterfaceName()
        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            result.append(NetInterfaceInfo(name: name, address: ip, isPrimary: name == primaryName))
        }
        result.sort { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.name < rhs.name
        }
        DispatchQueue.main.async {
            self.interfaces = result
            if self.selectedInterface.isEmpty || !result.contains(where: { $0.name == self.selectedInterface }) {
                self.selectedInterface = result.first(where: { $0.isPrimary })?.name
                    ?? result.first?.name ?? ""
            }
        }
    }

    /// 默认路由所在网卡（en0 / en1 …）
    private static func primaryInterfaceName() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") where line.contains("interface:") {
            return line.replacingOccurrences(of: "interface:", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return "en0"
    }

    // MARK: 公网

    /// myip.ipip.net 一步返回「当前 IP：1.2.3.4  来自于：中国 北京 北京  联通」
    private func probePublicIP(completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "https://myip.ipip.net") else {
            completion(nil, nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else {
                self.probePublicIPFallback(completion: completion)
                return
            }
            let ip = Self.extractIP(from: text)
            let location = Self.extractLocation(from: text)
            if let ip {
                completion(ip, location)
            } else {
                self.probePublicIPFallback(completion: completion)
            }
        }.resume()
    }

    /// 备用：ip.3322.net 只回 IP，再走 ipwho.is 反查归属
    private func probePublicIPFallback(completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "https://ip.3322.net/") else {
            completion(nil, nil)
            return
        }
        session.dataTask(with: url) { data, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8),
                  let ip = Self.extractIP(from: text) else {
                completion(nil, nil)
                return
            }
            guard let geoURL = URL(string: "https://ipwho.is/\(ip)?lang=zh-CN") else {
                completion(ip, nil)
                return
            }
            self.session.dataTask(with: geoURL) { geoData, _, _ in
                guard let geoData,
                      let object = try? JSONSerialization.jsonObject(with: geoData) as? [String: Any],
                      (object["success"] as? Bool) ?? true else {
                    completion(ip, nil)
                    return
                }
                let country = (object["country"] as? String) ?? ""
                let region = (object["region"] as? String) ?? ""
                let city = (object["city"] as? String) ?? ""
                let parts = [country, region, city].filter { !$0.isEmpty }
                completion(ip, parts.isEmpty ? nil : parts.joined(separator: " "))
            }.resume()
        }.resume()
    }

    // v126（性能审计 F0924）：正则编译缓存——NSRegularExpression(pattern:) 代价高（编译+JIT），
    // 模式固定不变，static 缓存后仅首次编译一次。
    private static let ipRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})"#)

    private static func extractIP(from text: String) -> String? {
        guard let regex = ipRegex,
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else {
            return nil
        }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private static func extractLocation(from text: String) -> String? {
        // 「来自于：中国 北京 北京  联通」
        guard let range = text.range(of: "来自于：") ?? text.range(of: "来自：") else { return nil }
        var tail = String(text[range.upperBound...])
        tail = tail.replacingOccurrences(of: "\n", with: " ")
        tail = tail.replacingOccurrences(of: "  ", with: " ")
        return tail.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 延迟（并发 HEAD，取 TTFB）

    private func probeLatencies() {
        let sites = Self.defaultSites
        let group = DispatchGroup()
        var results = sites
        let lock = NSLock()
        for (index, site) in sites.enumerated() {
            guard let url = URL(string: site.host) else { continue }
            group.enter()
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            let started = CFAbsoluteTimeGetCurrent()
            session.dataTask(with: request) { _, response, error in
                defer { group.leave() }
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode < 500 else { return }
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                lock.lock()
                results[index].milliseconds = ms
                lock.unlock()
            }.resume()
        }
        group.wait()
        DispatchQueue.main.async { self.latencies = results }
    }

    // MARK: DNS 出口（bash.ws 泄漏检测，两步）

    private func probeDNS() {
        guard let idURL = URL(string: "https://bash.ws/id") else { return }
        session.dataTask(with: idURL) { data, _, _ in
            guard let data, let id = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                  let testURL = URL(string: "https://bash.ws/dnsleak/test/\(id)?json") else { return }
            self.session.dataTask(with: testURL) { testData, _, _ in
                guard let testData,
                      let rows = try? JSONSerialization.jsonObject(with: testData) as? [[String: Any]] else { return }
                var servers: [String] = []
                for row in rows {
                    // type=dns 的行是解析器；ip 字段给地址，country/asn 给归属
                    guard (row["type"] as? String) == "dns",
                          let ip = row["ip"] as? String, !ip.isEmpty else { continue }
                    let country = (row["country_name"] as? String) ?? ""
                    let asn = (row["asn"] as? String) ?? ""
                    let label = [ip, country, asn].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !servers.contains(label) { servers.append(label) }
                }
                DispatchQueue.main.async { self.dnsServers = Array(servers.prefix(4)) }
            }.resume()
        }.resume()
    }
}
