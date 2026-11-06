import Foundation

// MARK: - 投屏设备记忆（v159）
//
// 对标 AndroMeld 的「配对一次，之后零交互」。
//
// 逆向结论（见 Project/temp/AndroMeld/逆向-01）：
//   AndroMeld 用 TLS 1.3 双向证书（`DeviceAgentMain:670` 的 setNeedClientAuth）
//   把「授权」变成长期凭据，所以第二次连接不需要任何用户操作。
//
// 我们走 ADB，拿不到同等级的长期凭据，但 ADB 的 RSA 授权本身也是持久的
// （`~/.android/adbkey` ↔ 手机 `adb_keys`）。真正每次都变的是**无线调试端口**：
//   · Android 11+ 无线调试：端口每次开关都随机 → 必须重新发现
//   · `adb tcpip 5555`：端口固定 → 重启手机前一直有效
//
// 所以策略是「按成本从低到高试」：
//   1. 上次成功的 serial（ip:port）—— 端口没变就直接连上，0 交互
//   2. 同 IP 的 5555（老式 tcpip）—— 端口变了但开过 tcpip 就能连
//   3. 都失败 → 才让用户扫码
//
// 这一步能把「第二次连接」从 3 次点击降到 0 次，是我们在不装手机 App 的前提下
// 最接近 AndroMeld 体验的做法。
public struct AdbCastDevice: Codable, Identifiable, Equatable {

    public var id: String { serial }

    /// adb serial，形如 `192.168.1.5:37651`
    public let serial: String
    public let host: String
    public let port: String
    /// 展示名（型号/别名，取不到时用 host）
    public var name: String
    public var lastSeen: Date
    /// 累计成功连接次数（≥2 的会排在前面，避免一次性设备抢占）
    public var successCount: Int

    public var displayName: String {
        name.isEmpty || name == host ? host : name
    }

    /// 是否是固定端口（tcpip 5555），重连成功率更高
    public var isStickyPort: Bool { port == "5555" }
}

public final class AdbCastMemory {

    public static let shared = AdbCastMemory()

    private let key = "frset.cast.devices.v1"
    private let lock = NSLock()
    private var cache: [AdbCastDevice]?

    private init() {}

    // MARK: 读

    public var devices: [AdbCastDevice] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        let list = Self.load(key: key)
        cache = list
        return list
    }

    /// 重连候选：按「固定端口优先 → 最近使用」排序，最多 3 个
    public func candidates() -> [AdbCastDevice] {
        devices
            .filter { !$0.host.isEmpty }
            .sorted { a, b in
                if a.isStickyPort != b.isStickyPort { return a.isStickyPort }
                return a.lastSeen > b.lastSeen
            }
            .prefix(3)
            .map { $0 }
    }

    public var lastDevice: AdbCastDevice? {
        devices.max(by: { $0.lastSeen < $1.lastSeen })
    }

    public var isEmpty: Bool { devices.isEmpty }

    // MARK: 写

    /// 连接成功后记住（同 host 的旧记录会被替换，避免端口变化堆积）
    public func remember(serial: String, name: String? = nil) {
        guard let addr = Self.split(serial) else { return }
        lock.lock()
        var list = cache ?? Self.load(key: key)
        let existing = list.first { $0.host == addr.host }
        let merged = AdbCastDevice(
            serial: serial,
            host: addr.host,
            port: addr.port,
            name: name ?? existing?.name ?? addr.host,
            lastSeen: Date(),
            successCount: (existing?.successCount ?? 0) + 1
        )
        list.removeAll { $0.host == addr.host }
        list.append(merged)
        // 只留最近 8 台，防止无限增长
        if list.count > 8 {
            list = Array(list.sorted { $0.lastSeen > $1.lastSeen }.prefix(8))
        }
        cache = list
        lock.unlock()
        Self.save(list, key: key)
    }

    // MARK: 工具

    static func split(_ serial: String) -> (host: String, port: String)? {
        let parts = serial.split(separator: ":")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    private static func load(key: String) -> [AdbCastDevice] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([AdbCastDevice].self, from: data) else {
            return []
        }
        return list
    }

    private static func save(_ list: [AdbCastDevice], key: String) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
