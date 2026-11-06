import AppKit
import Darwin
import Foundation

// ============================================================================
// 内存维护后台服务客户端
//
// 服务形态：root LaunchDaemon（/Library/PrivilegedHelperTools + /Library/LaunchDaemons）
// 通信：/var/run/com.sxyq.frsetnext.memory.sock，只支持固定命令（version / optimize-memory）
// 授权：首次安装时弹一次系统管理员密码；之后点击即用，不再询问
// ============================================================================

public enum MemoryHelperClient {
    /// 与 Sources/MemoryHelper/main.swift 的 protocolVersion 保持一致
    public static let protocolVersion = "1"
    public static let helperLabel = "com.sxyq.frsetnext.memoryhelper"
    static let socketPath = "/var/run/com.sxyq.frsetnext.memory.sock"
    static let installedHelperPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    static let installedPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    static let clientAuthorizationPath = "/Library/PrivilegedHelperTools/\(helperLabel).client.json"

    public enum Reply: Sendable {
        case success(String)
        case failure(String)
        case unavailable
    }

    private struct ClientAuthorization: Codable {
        let uid: uid_t
    }

    public static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installedHelperPath)
            && FileManager.default.fileExists(atPath: installedPlistPath)
    }

    /// 同步探活（阻塞 ≤2s，调用方应在后台线程）
    public static func isReady() -> Bool {
        if case let .success(version) = send("version", timeoutSeconds: 2) {
            return version == protocolVersion
        }
        return false
    }

    /// 确保服务可用；未安装则走一次管理员授权安装
    @MainActor
    public static func ensureReady() async -> (ready: Bool, message: String) {
        let ready = await Task.detached(priority: .userInitiated) { isReady() }.value
        if ready { return (true, "内存服务已就绪") }
        return await install()
    }

    @MainActor
    public static func install() async -> (ready: Bool, message: String) {
        guard let helperURL, let plistURL else {
            return (false, "应用包内缺少内存服务文件（请重新构建）")
        }
        guard let authData = try? JSONEncoder().encode(ClientAuthorization(uid: getuid())) else {
            return (false, "无法生成服务授权信息")
        }
        let authBase64 = authData.base64EncodedString()
        let quote = AdministratorShell.quote
        let commands = [
            "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(quote(helperURL.path)) \(quote(installedHelperPath))",
            "/usr/bin/install -o root -g wheel -m 644 \(quote(plistURL.path)) \(quote(installedPlistPath))",
            "(/bin/echo \(quote(authBase64)) | /usr/bin/base64 -D > \(quote(clientAuthorizationPath)))",
            "/usr/sbin/chown root:wheel \(quote(clientAuthorizationPath))",
            "/bin/chmod 600 \(quote(clientAuthorizationPath))",
            "(/usr/bin/xattr -d com.apple.quarantine \(quote(installedHelperPath)) >/dev/null 2>&1 || true)",
            "(/usr/bin/xattr -d com.apple.quarantine \(quote(installedPlistPath)) >/dev/null 2>&1 || true)",
            "(/bin/launchctl bootout system \(quote(installedPlistPath)) >/dev/null 2>&1 || true)",
            "/bin/rm -f \(quote(socketPath))",
            "(/bin/launchctl enable system/\(helperLabel) >/dev/null 2>&1 || true)",
            "/bin/launchctl bootstrap system \(quote(installedPlistPath))"
        ]
        switch AdministratorShell.run(commands.joined(separator: " && ")) {
        case .success:
            // launchd 启动有延迟，轮询至多 6 秒
            for _ in 0..<30 {
                let ready = await Task.detached(priority: .userInitiated) { isReady() }.value
                if ready { return (true, "内存服务已安装并就绪") }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return (false, "服务已安装但未能启动，请查看 /var/log/\(helperLabel).log")
        case let .failure(failure):
            return (false, failure.isCancelled ? "已取消管理员授权" : failure.message)
        }
    }

    @MainActor
    public static func optimize() async -> Reply {
        await Task.detached(priority: .userInitiated) {
            send("optimize-memory", timeoutSeconds: 45)
        }.value
    }

    // MARK: - 资源定位

    private static var helperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools/\(helperLabel)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private static var plistURL: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("\(helperLabel).plist")
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Unix socket

    static func send(_ command: String, timeoutSeconds: Int = 10) -> Reply {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .unavailable }
        defer { Darwin.close(descriptor) }

        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < pathCapacity else { return .unavailable }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { tuple in
                tuple.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
                    _ = strncpy($0, source, pathCapacity - 1)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .unavailable }

        // 防止被同机其它用户伪造的 socket 冒充 root 服务
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == 0 else { return .unavailable }

        let data = Data((command + "\n").utf8)
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard written else { return .unavailable }

        var reply = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while reply.count < 65_536 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return .unavailable }
            reply.append(contentsOf: bytes.prefix(count))
            if reply.contains(10) { break }
        }
        guard reply.last == 10 else { return .unavailable }
        let response = String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if response.hasPrefix("ok ") { return .success(String(response.dropFirst(3))) }
        if response.hasPrefix("error ") { return .failure(String(response.dropFirst(6))) }
        return .failure("内存服务返回了无效响应")
    }
}

// MARK: - 管理员授权（一次安装/卸载）

enum AdministratorShell {
    struct Failure: Error, Sendable {
        let message: String
        let isCancelled: Bool
    }

    @MainActor
    static func run(_ command: String) -> Result<String, Failure> {
        let source = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "管理员授权失败"
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            return .failure(Failure(message: message, isCancelled: code == -128 || message == "User canceled."))
        }
        return .success(output?.stringValue ?? "")
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
