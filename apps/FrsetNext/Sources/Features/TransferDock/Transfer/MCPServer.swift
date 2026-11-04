import Foundation
import Network

// MARK: - 本机 MCP 服务器（v116）
//
// 让 AI 客户端（Claude/Cursor/自家 AI）直接控制手机：HTTP + JSON-RPC 2.0，
// 端点为 http://127.0.0.1:8765/mcp（Streamable HTTP 的 JSON 响应模式）。
//
// 暴露的工具（全部走 adb，零安装）：
//   adb_devices       列出设备
//   adb_shell         执行 shell 命令
//   adb_push          本地 → 手机
//   adb_pull          手机 → 本地
//   adb_install       安装 APK
//   adb_screencap     截手机屏（拉回本地，返回路径）
//   list_apps         第三方应用
//   launch_app_window 给单个 App 开独立窗口（scrcpy 虚拟屏）
//
// 安全（v200 / 2026-11-04，修工程全图 P0-1 / P0-2）：
//   ① 显式 requiredLocalEndpoint 绑定 127.0.0.1——NWListener(using:on:) 默认监听所有接口，
//      实测 lsof 为 `TCP *:port (LISTEN)`，指定后为 `TCP 127.0.0.1:port (LISTEN)`；
//   ② 每次进程启动生成访问 token，所有 JSON-RPC 请求必须携带（URL ?token= 或请求头），
//      GET /health 例外且不回显 token；
//   ③ 拒绝一切带 Origin 的请求与 OPTIONS 预检，去掉 Access-Control-Allow-Origin: *，
//      本机任意网页不再能静默调用 adb_shell；
//   ④ 服务仍默认关闭，需在投屏页手动开启；完整带 token 的地址在投屏页复制。

public final class MCPServer {

    public static let shared = MCPServer()
    public static let defaultPort: UInt16 = 8767   // 8765/8766 实测被系统内其它进程占用

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "frset.mcp", qos: .userInitiated)
    private let lock = NSLock()
    private var _running = false
    private var _port: UInt16 = MCPServer.defaultPort

    /// 进程级访问令牌：每次启动重新生成，旧客户端配置需重新复制投屏页地址
    private let accessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    /// 不含 token 的基础地址（日志用，避免令牌落到日志文件）
    public var baseEndpoint: String { "http://127.0.0.1:\(_port)/mcp" }
    /// 供投屏页展示/复制的完整地址（含 token）
    public var endpoint: String { "\(baseEndpoint)?token=\(accessToken)" }

    private init() {}

    // MARK: 生命周期

    public func start() -> Bool {
        guard !isRunning else { return true }
        // 端口顺延：8767 起试 8 个，避开系统内其它常驻服务
        for offset in 0..<8 {
            let port = Self.defaultPort + UInt16(offset)
            if bind(port: port) { return true }
        }
        Log.error("MCP", "启动失败：8767-8774 全被占用")
        return false
    }

    private func bind(port: UInt16) -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 只绑回环：requiredLocalEndpoint 已含端口，此处用 NWListener(using:) 而非 (using:on:)，
            // 两者同时指定同一端口会 EINVAL（2026-11-04 本机实测）。
            let nwPort = NWEndpoint.Port(rawValue: port)!
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            let l = try NWListener(using: params)
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: ok = true; sem.signal()
                case .failed(let e):
                    Log.error("MCP", "监听失败（\(port)）：\(e.localizedDescription)")
                    sem.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.start(queue: queue)
            _ = sem.wait(timeout: .now() + 2)
            guard ok else { l.cancel(); return false }
            listener = l
            _port = port
            lock.lock(); _running = true; lock.unlock()
            Log.info("MCP", "已启动 \(baseEndpoint)（需 token，完整地址见投屏页）")
            return true
        } catch {
            return false
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        lock.lock(); _running = false; lock.unlock()
        Log.info("MCP", "已停止")
    }

    // MARK: HTTP

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerText = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let bodyStart = headerEnd.upperBound
                let contentLength = Self.contentLength(in: headerText)
                let body = buf[bodyStart...]
                if body.count >= contentLength {
                    self.respond(conn, request: headerText, body: Data(body.prefix(contentLength)))
                    return
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private static func contentLength(in headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func send(_ conn: NWConnection, status: String, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(data.count)\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// token 可来自 URL query（投屏页复制的完整地址）或两种请求头，三者取一即可
    private static func authorized(firstLine: String, headers: [String], token: String) -> Bool {
        let target = firstLine.split(separator: " ").dropFirst(1).first.map(String.init) ?? ""
        if let q = target.firstIndex(of: "?") {
            for item in target[target.index(after: q)...].split(separator: "&") {
                if item.hasPrefix("token="), String(item.dropFirst("token=".count)) == token { return true }
            }
        }
        for line in headers {
            let lower = line.lowercased()
            if lower.hasPrefix("authorization:") {
                let v = String(line.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces)
                if v == "Bearer \(token)" { return true }
            }
            if lower.hasPrefix("x-kitnest-token:") {
                let v = String(line.dropFirst("x-kitnest-token:".count)).trimmingCharacters(in: .whitespaces)
                if v == token { return true }
            }
        }
        return false
    }

    private func respond(_ conn: NWConnection, request: String, body: Data) {
        let lines = request.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""

        // 浏览器发起的请求一律拒绝（含 CORS 预检）：绑回环只能挡外部主机，
        // 本机任意网页仍能对本机端口发请求，所以必须在服务端再挡一层。
        if firstLine.hasPrefix("OPTIONS ") || lines.contains(where: { $0.lowercased().hasPrefix("origin:") }) {
            send(conn, status: "403 Forbidden", json: ["error": "browser origin is not allowed"])
            return
        }
        // GET /health 只探活，不回显 token
        if firstLine.hasPrefix("GET ") {
            send(conn, status: "200 OK", json: ["ok": true, "server": "Kitnest MCP", "endpoint": baseEndpoint])
            return
        }
        guard Self.authorized(firstLine: firstLine, headers: lines, token: accessToken) else {
            send(conn, status: "401 Unauthorized", json: [
                "jsonrpc": "2.0",
                "error": ["code": -32001, "message": "missing or invalid token; copy the full URL from Kitnest's Cast page"]
            ])
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            send(conn, status: "400 Bad Request", json: ["jsonrpc": "2.0", "error": ["code": -32700, "message": "parse error"]])
            return
        }
        let id = obj["id"] ?? NSNull()
        let method = obj["method"] as? String ?? ""

        switch method {
        case "initialize":
            send(conn, status: "200 OK", json: [
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "kitnest-android", "version": "1.0.0"]
                ]
            ])
        case "notifications/initialized", "initialized":
            send(conn, status: "200 OK", json: ["jsonrpc": "2.0", "id": id, "result": [:]])
        case "ping":
            send(conn, status: "200 OK", json: ["jsonrpc": "2.0", "id": id, "result": [:]])
        case "tools/list":
            send(conn, status: "200 OK", json: ["jsonrpc": "2.0", "id": id,
                                                "result": ["tools": Self.toolDefinitions]])
        case "tools/call":
            let params = obj["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            Self.call(name: name, args: args) { text, isError in
                self.send(conn, status: "200 OK", json: [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["content": [["type": "text", "text": text]],
                               "isError": isError]
                ])
            }
        default:
            send(conn, status: "200 OK", json: ["jsonrpc": "2.0", "id": id,
                                                "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    // MARK: 工具定义

    private static var toolDefinitions: [[String: Any]] {
        [
            tool("adb_devices", "List connected Android devices (adb devices).", [:]),
            tool("adb_shell", "Run an adb shell command on the device.", [
                "command": ["type": "string", "description": "shell command, e.g. 'pm list packages -3'"]
            ], required: ["command"]),
            tool("adb_push", "Push a local file to the device.", [
                "local": ["type": "string"], "remote": ["type": "string"]
            ], required: ["local", "remote"]),
            tool("adb_pull", "Pull a device file to local path.", [
                "remote": ["type": "string"], "local": ["type": "string"]
            ], required: ["remote", "local"]),
            tool("adb_install", "Install an APK from local path.", [
                "path": ["type": "string"]
            ], required: ["path"]),
            tool("adb_screencap", "Take a screenshot on the device and pull it locally; returns the local path.", [:]),
            tool("list_apps", "List third-party apps installed on the device.", [:]),
            tool("launch_app_window", "Open a dedicated mirror window for one app (virtual display).", [
                "package": ["type": "string"]
            ], required: ["package"])
        ]
    }

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    // MARK: 工具执行

    private static func call(name: String, args: [String: Any],
                             completion: @escaping (String, Bool) -> Void) {
        func arg(_ k: String) -> String { args[k] as? String ?? "" }
        switch name {
        case "adb_devices":
            ADBExtrasEngine.run(["devices", "-l"]) { out in
                completion(out ?? "adb 不可用（未安装 android-platform-tools）", out == nil)
            }
        case "adb_shell":
            let cmd = arg("command")
            guard !cmd.isEmpty else { completion("缺少 command 参数", true); return }
            // shell 命令按空格拆参数（避免注入引号问题：整体交给 shell -c）
            ADBExtrasEngine.run(["shell", cmd]) { out in
                completion(out ?? "无输出", false)
            }
        case "adb_push":
            ADBExtrasEngine.run(["push", arg("local"), arg("remote")]) { out in
                let t = out ?? "无输出"
                completion(t, t.lowercased().contains("error"))
            }
        case "adb_pull":
            ADBExtrasEngine.run(["pull", arg("remote"), arg("local")], timeout: 120) { out in
                let t = out ?? "无输出"
                completion(t, t.lowercased().contains("error"))
            }
        case "adb_install":
            ADBExtrasEngine.installAPK(url: URL(fileURLWithPath: arg("path"))) { ok, out in
                completion(out, !ok)
            }
        case "adb_screencap":
            let remote = "/sdcard/Download/Kitnest/screencap.png"
            let local = NSTemporaryDirectory() + "frset-screencap-\(Int(Date().timeIntervalSince1970)).png"
            ADBExtrasEngine.run(["shell", "screencap", "-p", remote]) { _ in
                ADBExtrasEngine.run(["pull", remote, local], timeout: 60) { out in
                    completion("已保存：\(local)\n\(out ?? "")", false)
                }
            }
        case "list_apps":
            ADBExtrasEngine.thirdPartyApps { apps in
                completion(apps.map { "\($0.label)\t\($0.id)" }.joined(separator: "\n"), false)
            }
        case "launch_app_window":
            let pkg = arg("package")
            guard !pkg.isEmpty else { completion("缺少 package 参数", true); return }
            let ok = ADBExtrasEngine.startAppWindow(package: pkg)
            completion(ok ? "已为 \(pkg) 打开独立窗口" : "启动失败（需 Android 14+）", !ok)
        default:
            completion("未知工具：\(name)", true)
        }
    }
}
