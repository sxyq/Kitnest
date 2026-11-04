import Foundation
import Network

// MARK: - 安卓存储 WebDAV（v116）
//
// 把 /sdcard 以 WebDAV 暴露在 127.0.0.1:8766，Finder「前往 → 连接服务器」
// 填 http://127.0.0.1:8766 即可像网络盘一样浏览/下载/上传安卓文件
// （Finder 原生支持 WebDAV，不需要 Finder 扩展，也不需要 macOS 13+ 的限制）。
//
// 支持：OPTIONS / PROPFIND(Depth 0|1) / GET / HEAD / PUT / MKCOL / DELETE
// 数据面全部经 adb（exec-out cat 下载、push 上传），零安装。

public final class AndroidWebDAVServer {

    public static let shared = AndroidWebDAVServer()
    public static let defaultPort: UInt16 = 8768   // 8765/8766 实测被系统内其它进程占用

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "frset.webdav", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()
    private var _running = false
    private var _port: UInt16 = AndroidWebDAVServer.defaultPort

    public var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _running }
    public var baseURL: String { "http://127.0.0.1:\(_port)/" }

    private init() {}

    public func start() -> Bool {
        guard !isRunning else { return true }
        for offset in 0..<8 {
            let port = Self.defaultPort + UInt16(offset)
            if bind(port: port) { return true }
        }
        return false
    }

    private func bind(port: UInt16) -> Bool {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: ok = true; sem.signal()
                case .failed(let e):
                    Log.error("WebDAV", "监听失败（\(port)）：\(e.localizedDescription)")
                    sem.signal()
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: queue)
            _ = sem.wait(timeout: .now() + 2)
            guard ok else { l.cancel(); return false }
            listener = l
            _port = port
            stateLock.lock(); _running = true; stateLock.unlock()
            Log.info("WebDAV", "已启动 \(baseURL)")
            return true
        } catch {
            return false
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        stateLock.lock(); _running = false; stateLock.unlock()
    }

    // MARK: HTTP 会话

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || err != nil { conn.cancel(); return }
                self.readRequest(conn, buffer: buf)
                return
            }
            let header = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let bodyLen = Self.headerValue(header, "content-length").flatMap(Int.init) ?? 0
            var body = Data(buf[headerEnd.upperBound...])
            if body.count < bodyLen {
                // 继续读 body（PUT 上传）
                self.readBody(conn, header: header, body: body, need: bodyLen)
                return
            }
            self.dispatch(conn, header: header, body: Data(body.prefix(bodyLen)))
        }
    }

    private func readBody(_ conn: NWConnection, header: String, body: Data, need: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            var buf = body
            if let data { buf.append(data) }
            if buf.count >= need {
                self.dispatch(conn, header: header, body: Data(buf.prefix(need)))
            } else if isComplete || err != nil {
                conn.cancel()
            } else {
                self.readBody(conn, header: header, body: buf, need: need)
            }
        }
    }

    private static func headerValue(_ headers: String, _ name: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") where line.lowercased().hasPrefix(name + ":") {
            return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func dispatch(_ conn: NWConnection, header: String, body: Data) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = parts[0].uppercased()
        let rawPath = parts[1]
        let path = Self.remotePath(from: rawPath)
        let depth = Self.headerValue(header, "depth") ?? "1"

        switch method {
        case "OPTIONS":
            send(conn, status: "200 OK", headers: [
                "DAV": "1,2", "MS-Author-Via": "DAV",
                "Allow": "OPTIONS,PROPFIND,GET,HEAD,PUT,MKCOL,DELETE"
            ], body: Data())
        case "PROPFIND":
            propfind(conn, path: path, depth: depth)
        case "GET", "HEAD":
            download(conn, path: path, headOnly: method == "HEAD")
        case "PUT":
            upload(conn, path: path, data: body)
        case "MKCOL":
            ADBExtrasEngine.run(["shell", "mkdir", "-p", path]) { out in
                let ok = !(out ?? "").lowercased().contains("error")
                self.send(conn, status: ok ? "201 Created" : "409 Conflict", headers: [:], body: Data())
            }
        case "DELETE":
            ADBExtrasEngine.run(["shell", "rm", "-rf", path]) { _ in
                self.send(conn, status: "204 No Content", headers: [:], body: Data())
            }
        default:
            send(conn, status: "405 Method Not Allowed", headers: [:], body: Data())
        }
    }

    /// URL 路径 → 安卓绝对路径（/sdcard + 解码路径）
    static func remotePath(from urlPath: String) -> String {
        var p = urlPath.components(separatedBy: "?").first ?? urlPath
        p = p.removingPercentEncoding ?? p
        if !p.hasPrefix("/") { p = "/" + p }
        // 兼容两种写法：/Download 与 /sdcard/Download（后者去掉前缀，避免拼成 /sdcard/sdcard）
        if p == "/sdcard" { p = "/" }
        else if p.hasPrefix("/sdcard/") { p = String(p.dropFirst("/sdcard".count)) }
        // 防目录穿越
        let parts = p.split(separator: "/").filter { $0 != ".." && !$0.isEmpty }
        let clean = parts.joined(separator: "/")
        return clean.isEmpty ? "/sdcard" : "/sdcard/" + clean
    }

    // MARK: PROPFIND

    private func propfind(_ conn: NWConnection, path: String, depth: String) {
        listRemote(path) { entries in
            var xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">

            """
            // 自身
            let isDir = entries == nil ? false : true
            xml += Self.entryXML(href: Self.href(fromRemote: path),
                                 isDir: isDir, size: 0, name: (path as NSString).lastPathComponent)
            if depth != "0", let entries {
                for e in entries {
                    xml += Self.entryXML(href: Self.href(fromRemote: path + "/" + e.name),
                                         isDir: e.isDir, size: e.size, name: e.name)
                }
            }
            xml += "</D:multistatus>"
            self.send(conn, status: "207 Multi-Status", headers: ["Content-Type": "application/xml; charset=utf-8"],
                      body: Data(xml.utf8))
        }
    }

    static func href(fromRemote remote: String) -> String {
        var p = remote
        if p.hasPrefix("/sdcard") { p = String(p.dropFirst("/sdcard".count)) }
        if p.isEmpty { p = "/" }
        let encoded = p.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return encoded.hasPrefix("/") ? encoded : "/" + encoded
    }

    private struct Entry { let name: String; let isDir: Bool; let size: Int64 }

    private static func entryXML(href: String, isDir: Bool, size: Int64, name: String) -> String {
        """
          <D:response>
            <D:href>\(href)</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>\(name)</D:displayname>
                <D:resourcetype>\(isDir ? "<D:collection/>" : "")</D:resourcetype>
                <D:getcontentlength>\(size)</D:getcontentlength>
                <D:getcontenttype>\(isDir ? "httpd/unix-directory" : "application/octet-stream")</D:getcontenttype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>

        """
    }

    private func listRemote(_ path: String, completion: @escaping ([Entry]?) -> Void) {
        ADBExtrasEngine.run(["shell", "ls", "-l", "'" + path + "'"], timeout: 20) { out in
            guard let out, !out.lowercased().contains("no such file") else { completion(nil); return }
            var list: [Entry] = []
            for line in out.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !t.hasPrefix("total") else { continue }
                let f = t.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
                guard f.count >= 8 else { continue }
                let isDir = f[0].hasPrefix("d")
                let size = Int64(f[4]) ?? 0
                var name = String(f[7])
                if name == "." || name == ".." { continue }
                // 软链接形如 "name -> target"
                if let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
                list.append(Entry(name: name, isDir: isDir, size: size))
            }
            completion(list)
        }
    }

    // MARK: 下载 / 上传

    private func download(_ conn: NWConnection, path: String, headOnly: Bool) {
        guard let adb = ScreenCastEngine.findADB() else { send(conn, status: "503 Service Unavailable", headers: [:], body: Data()); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: adb)
            var catArgs: [String] = []
            if let serial = ADBExtrasEngine.activeSerial { catArgs += ["-s", serial] }
            catArgs += ["exec-out", "cat", path]
            task.arguments = catArgs
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch {
                self.send(conn, status: "500 Internal Server Error", headers: [:], body: Data())
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if data.isEmpty {
                self.send(conn, status: "404 Not Found", headers: [:], body: Data())
                return
            }
            if headOnly {
                self.send(conn, status: "200 OK", headers: ["Content-Length": "\(data.count)"], body: Data())
                return
            }
            self.send(conn, status: "200 OK", headers: [
                "Content-Length": "\(data.count)", "Content-Type": "application/octet-stream"
            ], body: data)
        }
    }

    private func upload(_ conn: NWConnection, path: String, data: Data) {
        let tmp = NSTemporaryDirectory() + "frset-webdav-\(UUID().uuidString)"
        try? data.write(to: URL(fileURLWithPath: tmp))
        ADBExtrasEngine.run(["push", tmp, path], timeout: 120) { out in
            try? FileManager.default.removeItem(atPath: tmp)
            let ok = !(out ?? "").lowercased().contains("error")
            self.send(conn, status: ok ? "201 Created" : "500 Internal Server Error", headers: [:], body: Data())
        }
    }

    // MARK: 响应

    private func send(_ conn: NWConnection, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Server: Kitnest-WebDAV\r\n"
        head += "Connection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if headers["Content-Length"] == nil { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
