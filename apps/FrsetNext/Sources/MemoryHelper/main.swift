import Darwin
import Foundation

// ============================================================================
// FrsetNext 内存维护 helper（root LaunchDaemon）
//
// 为什么需要 root：
//   · `kern.memorypressure_manual_trigger` 只有 root 可写（普通进程 EPERM）；
//   · `/usr/sbin/purge` 只有 root 可执行。
// 安全模型（参考 WonderBox，MIT）：
//   · 只接受固定命令白名单（version / optimize-memory），不接受调用方传 shell；
//   · Unix socket 权限 root:<安装用户组> 0660，且校验对端 UID；
//   · 安装时把授权 UID 写入 /Library/PrivilegedHelperTools/*.client.json（root:wheel 0600）。
// ============================================================================

private let protocolVersion = "1"
private let defaultSocketPath = "/var/run/com.sxyq.frsetnext.memory.sock"
private let clientAuthorizationPath = "/Library/PrivilegedHelperTools/com.sxyq.frsetnext.memoryhelper.client.json"

private struct ClientAuthorization: Codable {
    let uid: uid_t
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func runTool(_ path: String, _ arguments: [String] = []) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// 与 `memory_pressure -S` 同一个内核入口（仅 root）：
/// value = request << 16 | level；request 6 = 通知所有已注册进程 + 丢弃全部 purgeable 内存。
/// level 取自 <sys/event.h> 的 NOTE_MEMORYSTATUS_PRESSURE_*（normal 1 / warning 2 / critical 4）。
private enum SimulatedMemoryPressure {
    private static let sysctlName = "kern.memorypressure_manual_trigger"
    private static let notifyAllAndPurge: Int32 = 6
    static let normal: Int32 = 0x1
    static let critical: Int32 = 0x4
    /// 给各 app 读取压力事件并回收缓存的时间；结束后必须复位，否则内核真实压力处理会被禁用。
    static let holdSeconds: UInt32 = 3

    static func set(_ level: Int32) -> Bool {
        var value = (notifyAllAndPurge << 16) | level
        return sysctlbyname(sysctlName, nil, nil, &value, MemoryLayout<Int32>.size) == 0
    }
}

/// 与 macOS 自身受压时的回收路径一致：先广播压力让各 app 释放缓存（压缩页随之释放），再丢文件缓存。
private func optimizeMemory() -> String {
    var steps: [String] = []
    if SimulatedMemoryPressure.set(SimulatedMemoryPressure.critical) {
        // defer 在 if 作用域结束时复位（3 秒后、purge 之前），与 WonderBox 行为一致
        defer { _ = SimulatedMemoryPressure.set(SimulatedMemoryPressure.normal) }
        sleep(SimulatedMemoryPressure.holdSeconds)
        steps.append("pressure")
    }
    if runTool("/usr/sbin/purge") {
        steps.append("purge")
    }
    guard !steps.isEmpty else { return "error The system memory tools are unavailable\n" }
    return "ok \(steps.joined(separator: " "))\n"
}

private func handle(_ request: String) -> String {
    let fields = request.split(separator: " ").map(String.init)
    guard let command = fields.first else { return "error Empty command\n" }
    switch command {
    case "version":
        return "ok \(protocolVersion)\n"
    case "optimize-memory":
        guard fields.count == 1 else { return "error Invalid arguments for optimize-memory\n" }
        return optimizeMemory()
    default:
        return "error Unsupported command\n"
    }
}

private func loadAuthorization() -> ClientAuthorization? {
    guard let data = FileManager.default.contents(atPath: clientAuthorizationPath),
          let authorization = try? JSONDecoder().decode(ClientAuthorization.self, from: data),
          authorization.uid != 0
    else { return nil }
    return authorization
}

private func writeAll(_ descriptor: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { buffer -> Int in
            Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written <= 0 { break }
        offset += written
    }
}

private func serve(socketPath: String) -> Never {
    guard let authorization = loadAuthorization() else {
        fail("missing or invalid client authorization", code: 77)
    }
    guard let user = getpwuid(authorization.uid) else {
        fail("authorized uid \(authorization.uid) no longer exists", code: 77)
    }
    let group = user.pointee.pw_gid

    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { fail("failed to create socket", code: 71) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= pathCapacity else { fail("socket path is too long", code: 64) }
    withUnsafeMutablePointer(to: &address.sun_path) { tuple in
        tuple.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
            for index in 0..<pathBytes.count { destination[index] = pathBytes[index] }
        }
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else { fail("failed to bind socket", code: 71) }

    _ = chown(socketPath, 0, group)
    _ = chmod(socketPath, 0o660)

    guard listen(server, 8) == 0 else { fail("failed to listen on socket", code: 71) }

    while true {
        let client = accept(server, nil, nil)
        if client < 0 { continue }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == authorization.uid else {
            close(client)
            continue
        }

        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = Darwin.read(client, &buffer, buffer.count)
        let request = received > 0
            ? String(decoding: buffer.prefix(received), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let reply = request.isEmpty ? "error Empty command\n" : handle(request)
        writeAll(client, reply)
        close(client)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--daemon" {
    serve(socketPath: arguments.count > 1 ? arguments[1] : defaultSocketPath)
}
if arguments.first == "version" {
    print("ok \(protocolVersion)")
    exit(0)
}
if arguments.first == "optimize-memory" {
    print(optimizeMemory(), terminator: "")
    exit(0)
}
fail("usage: com.sxyq.frsetnext.memoryhelper --daemon [SOCKET] | version | optimize-memory", code: 64)
