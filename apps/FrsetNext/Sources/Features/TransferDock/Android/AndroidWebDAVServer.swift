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
// v200（2026-11-04）：此前只写了「127.0.0.1」的地址，NWListener 实际监听所有接口。
// 现用 requiredLocalEndpoint 显式绑回环，令注释与行为一致（实测 lsof 127.0.0.1:port）。

public final class AndroidWebDAVServer {

    public static let shared = AndroidWebDAVServer()
    public static let defaultPort: UInt16 = 8768   // 8765/8766 实测被系统内其它进程占用

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "frset.webdav", qos: .userInitiated)
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
            let nwPort = NWEndpoint.Port(rawValue: port)!
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            let l = try NWListener(using: params)
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
        queue.sync {
            stateLock.lock(); _running = false; stateLock.unlock()
            for conn in connections.values {
                conn.stateUpdateHandler = nil
                conn.cancel()
            }
            connections.removeAll()
        }
    }

    // MARK: HTTP 会话

    private func accept(_ conn: NWConnection) {
        guard isRunning else { conn.cancel(); return }
        connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .failed, .cancelled: self.close(conn)
            default: break
            }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func close(_ conn: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
        if let spill = spills.removeValue(forKey: ObjectIdentifier(conn)) {
            try? spill.handle.closeFile()
            try? FileManager.default.removeItem(at: spill.url)
        }
        conn.stateUpdateHandler = nil
        conn.cancel()
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, isComplete, err in
            guard let self, self.connections[ObjectIdentifier(conn)] != nil else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || err != nil { self.close(conn); return }
                self.readRequest(conn, buffer: buf)
                return
            }
            let header = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            guard let bodyLen = Int(Self.headerValue(header, "content-length") ?? "0"), bodyLen >= 0 else {
                self.send(conn, status: "400 Bad Request", headers: [:], body: Data())
                return
            }
            let body = Data(buf[headerEnd.upperBound...])
            if body.count < bodyLen {
                // 继续读 body（PUT 上传）
                self.readBody(conn, header: header, body: body, need: bodyLen)
                return
            }
            self.dispatch(conn, header: header, body: Data(body.prefix(bodyLen)))
        }
    }

    /// 上传体落盘阈值（2026-11-25 函数审查 NEEDS_FIX）：超过它不再内存累积，
    /// 边收边写临时文件——PUT 本来就要临时文件再 adb push。
    static let bodySpillThreshold = 16 << 20
    /// 上传体绝对上限：防恶意/异常 Content-Length 无限占盘
    static let bodyMaxBytes = 2 << 30

    private func readBody(_ conn: NWConnection, header: String, body: Data, need: Int) {
        guard need <= Self.bodyMaxBytes else {
            send(conn, status: "413 Payload Too Large", headers: [:], body: Data())
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, isComplete, err in
            guard let self, self.connections[ObjectIdentifier(conn)] != nil else { return }
            var buf = body
            if let data { buf.append(data) }
            // 大 body：落盘续收。spills 记录每条连接的临时文件句柄。
            if need > Self.bodySpillThreshold {
                let key = ObjectIdentifier(conn)
                if self.spills[key] == nil {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()
                        + "frset-webdav-body-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                    guard let handle = try? FileHandle(forWritingTo: url) else {
                        self.send(conn, status: "500 Internal Server Error", headers: [:], body: Data())
                        return
                    }
                    self.spills[key] = (url, handle)
                }
                if let spill = self.spills[key] {
                    let start = spill.handle.offsetInFile
                    try? spill.handle.write(contentsOf: buf)
                    _ = start
                }
                let received = self.spills[ObjectIdentifier(conn)]?.handle.offsetInFile ?? UInt64(buf.count)
                if received >= need {
                    self.spills[ObjectIdentifier(conn)]?.handle.closeFile()
                    if let spill = self.spills.removeValue(forKey: ObjectIdentifier(conn)) {
                        self.dispatch(conn, header: header, body: Data(), bodyFile: spill.url)
                    } else {
                        self.close(conn)
                    }
                } else if isComplete || err != nil {
                    self.spills.removeValue(forKey: ObjectIdentifier(conn))?.handle.closeFile()
                    self.close(conn)
                } else {
                    self.readBody(conn, header: header, body: Data(), need: need)
                }
                return
            }
            if buf.count >= need {
                self.dispatch(conn, header: header, body: Data(buf.prefix(need)))
            } else if isComplete || err != nil {
                self.close(conn)
            } else {
                self.readBody(conn, header: header, body: buf, need: need)
            }
        }
    }

    /// 连接 → 大 body 临时文件（收完在 dispatch 后删除）
    private var spills: [ObjectIdentifier: (url: URL, handle: FileHandle)] = [:]

    private static func headerValue(_ headers: String, _ name: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") where line.lowercased().hasPrefix(name + ":") {
            return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func dispatch(_ conn: NWConnection, header: String, body: Data, bodyFile: URL? = nil) {
        defer { if let f = bodyFile { try? FileManager.default.removeItem(at: f) } }
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").components(separatedBy: " ")
        guard parts.count >= 2 else { close(conn); return }
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
            if let bodyFile {
                upload(conn, path: path, data: Data(), stagedFile: bodyFile)
            } else {
                upload(conn, path: path, data: body)
            }
        case "MKCOL":
            ADBExtrasEngine.run(["shell", "mkdir", "-p", "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"]) { _, status in
                let ok = status == 0
                self.send(conn, status: ok ? "201 Created" : "409 Conflict", headers: [:], body: Data())
            }
        case "DELETE":
            ADBExtrasEngine.run(["shell", "rm", "-rf", "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"]) { _, status in
                self.send(conn, status: status == 0 ? "204 No Content" : "500 Internal Server Error", headers: [:], body: Data())
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
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let encoded = p.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        return encoded.hasPrefix("/") ? encoded : "/" + encoded
    }

    private struct Entry { let name: String; let isDir: Bool; let size: Int64 }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func entryXML(href: String, isDir: Bool, size: Int64, name: String) -> String {
        """
          <D:response>
            <D:href>\(escapeXML(href))</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>\(escapeXML(name))</D:displayname>
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
        ADBExtrasEngine.run(["shell", "ls", "-l", "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"], timeout: 20) { out, _ in
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
        if headOnly {
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            ADBExtrasEngine.run(["shell", "[ -f \(quoted) ] && stat -L -c %s \(quoted)"]) { out, status in
                guard status == 0, let out,
                      let size = UInt64(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    self.send(conn, status: "404 Not Found", headers: [:], body: Data())
                    return
                }
                self.send(conn, status: "200 OK", headers: ["Content-Length": "\(size)"], body: Data())
            }
            return
        }
        // 2026-11-25（函数审查 NEEDS_FIX 落实）：旧实现 `readDataToEndOfFile` 把整个
        // 文件读进内存再一次 send——数 GB 视频内存峰值≈文件大小。改为：
        // ① 先 stat 拿大小（给 Content-Length）；② cat 输出按 256KB 分块边读边发。
        DispatchQueue.global(qos: .userInitiated).async {
            let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            ADBExtrasEngine.run(["shell", "[ -f \(quoted) ] && stat -L -c %s \(quoted)"]) { out, status in
                guard status == 0, let out,
                      let size = UInt64(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    self.send(conn, status: "404 Not Found", headers: [:], body: Data())
                    return
                }
                let task = Process()
                task.executableURL = URL(fileURLWithPath: adb)
                var catArgs: [String] = []
                if let serial = ADBExtrasEngine.resolveSerialSync(adb) { catArgs += ["-s", serial] }
                catArgs += ["exec-out", "cat", quoted]
                task.arguments = catArgs
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                do { try task.run() } catch {
                    self.send(conn, status: "500 Internal Server Error", headers: [:], body: Data())
                    return
                }
                self.streamDownload(conn, handle: pipe.fileHandleForReading, task: task, size: size)
            }
        }
    }

    /// 发响应头后按块泵送 cat 输出（后台线程阻塞读，发送完成回调驱动下一块）
    private func streamDownload(_ conn: NWConnection, handle: FileHandle, task: Process, size: UInt64) {
        var head = "HTTP/1.1 200 OK\r\nServer: Kitnest-WebDAV\r\nConnection: close\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        head += "Content-Length: \(size)\r\n\r\n"
        queue.async { [weak self] in
            guard let self, self.connections[ObjectIdentifier(conn)] != nil else {
                task.terminate(); return
            }
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                self.pumpDownload(conn, handle: handle, task: task, remaining: size)
            })
        }
    }

    private func pumpDownload(_ conn: NWConnection, handle: FileHandle, task: Process, remaining: UInt64) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard remaining > 0 else {
                try? task.waitUntilExit()
                self.queue.async { self.close(conn) }
                return
            }
            let chunk = (try? handle.read(upToCount: min(256 << 10, Int(remaining)))) ?? Data()
            if chunk.isEmpty {
                // cat 提前退出（设备断开等）：已声明的长度发不满，只能关闭连接让客户端重试
                try? task.waitUntilExit()
                self.queue.async { self.close(conn) }
                return
            }
            self.queue.async {
                guard self.connections[ObjectIdentifier(conn)] != nil else {
                    task.terminate(); return
                }
                conn.send(content: chunk, completion: .contentProcessed { _ in
                    self.pumpDownload(conn, handle: handle, task: task,
                                      remaining: remaining - UInt64(chunk.count))
                })
            }
        }
    }

    /// 上传：`data` 走旧路径（写临时文件再 push）；`stagedFile` 是大 body 已落盘的
    /// 临时文件，直接 push，省一次「内存 → 磁盘」往返（2026-11-25 函数审查 NEEDS_FIX）。
    private func upload(_ conn: NWConnection, path: String, data: Data, stagedFile: URL? = nil) {
        let tmp: String
        if let stagedFile {
            tmp = stagedFile.path
        } else {
            let fresh = NSTemporaryDirectory() + "frset-webdav-\(UUID().uuidString)"
            do {
                try data.write(to: URL(fileURLWithPath: fresh))
                tmp = fresh
            } catch {
                send(conn, status: "500 Internal Server Error", headers: [:], body: Data())
                return
            }
        }
        ADBExtrasEngine.run(["push", tmp, path], timeout: 600) { _, status in
            if stagedFile == nil { try? FileManager.default.removeItem(atPath: tmp) }
            let ok = status == 0
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
        queue.async { [out] in
            guard self.connections[ObjectIdentifier(conn)] != nil else { return }
            conn.send(content: out, completion: .contentProcessed { _ in self.close(conn) })
        }
    }
}
