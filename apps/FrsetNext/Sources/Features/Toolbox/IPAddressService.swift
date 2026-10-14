import Foundation
import Darwin

// MARK: - IP 地址查询
// 公网 IP：调用 https://api.ipify.org?format=json（免 Key、免注册的公共服务），带超时；
// 失败时降级为"本机内网 IP + 中文错误提示"（不写死任何 Key，方便后续换服务商）。

public enum IPAddressService {
    /// 公网 IP 服务端点（可替换为任意返回 JSON {"ip": "..."} 的服务）
    static let endpoint = URL(string: "https://api.ipify.org?format=json")!
    /// 备用端点（纯文本返回 IP）
    static let fallbackEndpoint = URL(string: "https://api.ipify.org")!

    public struct Report {
        public var publicIP: String?
        public var localIP: String?
        public var errorMessage: String?
    }

    /// 查询错误（中文描述，直接面向 UI）
    public struct IPQueryError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: 本机内网 IP（getifaddrs，优先 IPv4）

    public static func localIPAddress(preferIPv4: Bool = true) -> String? {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0 else { return nil }
        defer { freeifaddrs(addrList) }

        var ipv6: String?
        var ptr = addrList
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let isUp = (flags & Int32(IFF_UP)) != 0
            let isLoopback = (flags & Int32(IFF_LOOPBACK)) != 0
            if isUp && !isLoopback, let sa = p.pointee.ifa_addr {
                let family = sa.pointee.sa_family
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(max(Int(sa.pointee.sa_len), Int(MemoryLayout<sockaddr>.size)))
                if getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: host)
                    if family == UInt8(AF_INET) && preferIPv4 { return text }
                    if family == UInt8(AF_INET6) && ipv6 == nil { ipv6 = text }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return ipv6  // 未找到 IPv4 时退而返回 IPv6
    }

    // MARK: 公网 IP（异步，带超时与中文错误）

    public static func queryPublicIP(timeout: TimeInterval = 6) async -> Result<String, IPQueryError> {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(IPQueryError(message: "公网 IP 查询失败：服务端返回状态码 \(http.statusCode)"))
            }
            // 兼容 JSON 与纯文本两种响应
            if let object = try? JSONSerialization.jsonObject(with: data),
               let dict = object as? [String: Any],
               let ip = dict["ip"] as? String, !ip.isEmpty {
                return .success(ip)
            }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count < 64 {
                return .success(text)
            }
            return .failure(IPQueryError(message: "公网 IP 查询失败：返回内容无法解析"))
        } catch {
            return .failure(IPQueryError(message: chineseNetworkError(error)))
        }
    }

    /// 完整报告：公网 + 内网（公网失败时仍返回内网与错误说明）
    public static func query(timeout: TimeInterval = 6, includeLocal: Bool = true) async -> Report {
        var report = Report()
        let local = includeLocal ? localIPAddress() : nil
        report.localIP = local
        switch await queryPublicIP(timeout: timeout) {
        case .success(let ip):      report.publicIP = ip
        case .failure(let error):   report.errorMessage = error.message
        }
        return report
    }

    /// 拼装展示文本
    public static func displayText(_ report: Report) -> String {
        var lines: [String] = []
        if let ip = report.publicIP {
            lines.append("公网 IP：\(ip)")
        } else if let msg = report.errorMessage {
            lines.append("公网 IP：查询失败")
            lines.append("原因：\(msg)")
        }
        if let local = report.localIP {
            lines.append("内网 IP：\(local)")
        } else {
            lines.append("内网 IP：未找到可用网卡地址")
        }
        if report.publicIP == nil {
            lines.append("提示：以上为降级结果，请检查网络后重试。")
        }
        return lines.joined(separator: "\n")
    }

    /// 系统网络错误 → 中文提示
    static func chineseNetworkError(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorTimedOut:            return "请求超时（已等待 \(Int(6)) 秒），请检查网络后重试"
        case NSURLErrorNotConnectedToInternet: return "当前无网络连接，无法查询公网 IP"
        case NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:     return "域名解析失败，请检查网络或 DNS 设置"
        case NSURLErrorNetworkConnectionLost: return "网络连接中断，请稍后重试"
        default:                            return "网络请求失败：\(ns.localizedDescription)"
        }
    }
}
