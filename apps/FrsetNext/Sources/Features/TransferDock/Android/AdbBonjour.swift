import Foundation
import Darwin

/// 用系统 Bonjour（NetServiceBrowser）发现 adb 无线调试服务。
///
/// 为什么不用 `adb mdns services`（v164 实测，2026-10-29）：
///   1) 该后端在这台机器上**周期性丢失服务**——同一时刻 `dns-sd -B _adb-tls-connect._tcp`
///      一直能看到 `adb-d715a3a4-gZ1erp`，而 `adb mdns services` 的列表在 1 条 / 0 条之间来回跳
///      （日志间隔 2~14s），扫码流程因此经常「等不到手机」。
///   2) adb server 长时间运行后（本例近 3 天）该后端会彻底不再更新，重启 server 才恢复。
/// 系统 Bonjour 走的是 mDNSResponder，与 `dns-sd` 同一条路径，稳定性已实测。
///
/// 只做「发现 + 解析出 host:port」，配对/连接仍交给 `adb pair` / `adb connect`。
final class AdbBonjour: NSObject {

    struct Hit {
        let name: String        // 实例名（配对时 = 二维码里的 S）
        let host: String
        let port: String
        let pairing: Bool       // true = _adb-tls-pairing（等我方 adb pair）
    }

    private var browser: NetServiceBrowser?
    private var pending: [NetService] = []
    private var hits: [Hit] = []
    private var completion: (([Hit]) -> Void)?
    private var finished = false
    private var deadline: DispatchWorkItem?

    /// 浏览两类服务，最多等 `timeout` 秒（默认 1.0s：短于轮询间隔 1.2s，避免叠加）
    func browse(timeout: TimeInterval = 1.0, completion: @escaping ([Hit]) -> Void) {
        // 上一轮还没收尾就直接收（轮询间隔可能略短于解析耗时）——
        // 保证每次调用都一定会有回调，不会让上层的「发现阶段」干等。
        if !finished, self.completion != nil { finish() }
        self.completion = completion
        hits.removeAll()
        pending.removeAll()
        finished = false

        let b = NetServiceBrowser()
        b.delegate = self
        browser = b
        b.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "local.")
        b.searchForServices(ofType: "_adb-tls-pairing._tcp.", inDomain: "local.")

        let work = DispatchWorkItem { [weak self] in self?.finish() }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        browser?.stop()
        browser = nil
        pending.forEach { $0.stop() }
        pending.removeAll()
        let out = hits
        hits.removeAll()
        let cb = completion
        completion = nil
        cb?(out)
    }
}

extension AdbBonjour: NetServiceBrowserDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        service.delegate = self
        pending.append(service)
        service.resolve(withTimeout: 1.2)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotFind service: NetService,
                           moreComing: Bool) {
        pending.removeAll { $0 === service }
    }
}

extension AdbBonjour: NetServiceDelegate {

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { pending.removeAll { $0 === sender } }
        guard sender.port > 0 else { return }
        guard let host = Self.ipv4String(from: sender.addresses) else { return }
        let pairing = sender.type.contains("_adb-tls-pairing")
        let hit = Hit(name: sender.name, host: host,
                      port: String(sender.port), pairing: pairing)
        // 同一实例可能解析出多个地址（IPv4/IPv6），按 name+host+port 去重
        if !hits.contains(where: { $0.name == hit.name && $0.host == hit.host && $0.port == hit.port }) {
            hits.append(hit)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeAll { $0 === sender }
    }

    /// 只取 IPv4：adb 的 `pair/connect` 对 IPv6 字面量支持不稳，局域网 IPv4 足够
    private static func ipv4String(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for data in addresses {
            let host = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
                guard let base = raw.baseAddress else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var addr = raw.load(as: sockaddr_in.self)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: buf)
            }
            if let host { return host }
        }
        return nil
    }
}
