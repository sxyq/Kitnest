import AppKit
import Combine
import Darwin
import Foundation
import Network

// MARK: - 局域网直传服务（手机扫码 → 浏览器上传 / 下载）
//
// 设计取向（2026-10-20 用户需求「扫码直接传」）：
//   手机端**零安装**是硬指标，所以不用 LocalSend 那类「两端装 App + 组播发现」的方案，
//   也不用 PairDrop/Snapdrop 那类「WebRTC + 信令」的方案，而是走 qrcp 的路子：
//   本机起一个只监听局域网的小 HTTP 服务，把地址编成二维码，手机相机一扫就在浏览器里传。
//
// 安全：
//   · 链接带一次性随机 token（默认 4 位、可重生成），路径前缀不匹配直接 403；
//   · 只绑定局域网 IPv4 入口，服务默认关闭，由「设置 → 文件中转」或中转页开关控制；
//   · 收到文件只写进「本地中转」暂存目录（硬链接语义的同一套索引），不会自动打开。
//
// 路由（全部相对页面 URL，页面地址形如 http://ip:port/s/<token>/）：
//   GET  ""            直传页（内嵌 HTML，无外链资源）
//   GET  api/list      本地中转文件列表 JSON
//   POST api/upload    multipart/form-data 上传（可多选）
//   POST api/delete?id=<id>  移出中转
//   GET  dl/<id>       下载暂存文件
//
// 为什么自建 HTTP 解析而不用 Network.framework 的 WebSocket/URLSession：
//   没有现成的服务端框架可用（不引第三方），请求形态极简（GET/POST + 定长 body），
//   手写这 200 行比引入依赖更可控，也避免 App 体积与签名复杂度。

public final class LanTransferServer: ObservableObject {

    public static let shared = LanTransferServer()

    /// 服务是否在跑
    @Published public private(set) var running = false
    /// 实际监听端口（首选端口被占用时会顺延）
    @Published public private(set) var port: UInt16 = 0
    /// 手机访问地址（含 token，末尾带 / 以便页面内相对路径解析）
    @Published public private(set) var shareURL: String?
    /// 最近一条状态（UI 显示 + 排错）
    @Published public private(set) var statusText = ""
    /// 本次运行累计收到/发出的文件数
    @Published public private(set) var receivedCount = 0
    @Published public private(set) var sentCount = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "frset.transfer.lan", qos: .userInitiated)

    private init() {
        _ = Self.tokenCache   // 首次访问时生成/读取 token
    }

    // MARK: - 生命周期

    /// 启动（幂等）：已启动直接返回
    public func start() {
        queue.async { [weak self] in self?.startLocked(preferred: TransferDockPref.lanPort) }
    }

    /// 只在「设置里开着」时才启动——面板切到中转页时调用
    public func startIfEnabled() {
        guard TransferDockPref.isOn(TransferDockPref.lanEnabled) else { return }
        guard !running, listener == nil else { return }
        start()
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            DispatchQueue.main.async {
                self.running = false
                self.shareURL = nil
                self.port = 0
                self.statusText = "已停止"
            }
            Log.info("TransferDock", "局域网直传已停止")
        }
    }

    /// 端口/开关变更后重启（设置页调用）
    public func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.startLocked(preferred: TransferDockPref.lanPort)
        }
    }

    /// 重新生成访问 token（旧二维码立即失效）
    public func rotateToken() {
        listener?.cancel()
        listener = nil
        Self.regenerateToken()
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.startLocked(preferred: TransferDockPref.lanPort)
        }
        Toast.show("已生成新二维码，旧链接失效", icon: "qrcode")
    }

    private func startLocked(preferred: UInt16) {
        guard listener == nil else { return }
        let base = max(1024, preferred)
        attemptBind(startingAt: base, remaining: 9)
    }

    private func attemptBind(startingAt candidate: UInt16, remaining: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            if remaining > 0 { attemptBind(startingAt: candidate + 1, remaining: remaining - 1) }
            return
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let ip = Self.lanIPv4() ?? "127.0.0.1"
                let url = "http://\(ip):\(candidate)/s/\(Self.tokenCache)/"
                DispatchQueue.main.async {
                    self.running = true
                    self.port = candidate
                    self.shareURL = url
                    self.statusText = "手机与本机在同一 Wi-Fi 即可扫码传输"
                    if candidate != TransferDockPref.lanPort {
                        TransferDockPref.lanPort = candidate  // 顺延后的端口写回，避免每次重新试
                    }
                }
                Log.info("TransferDock", "局域网直传已就绪 \(url)")
            case .failed(let error):
                Log.warn("TransferDock", "局域网直传端口 \(candidate) 绑定失败：\(error)")
                self.listener?.cancel()
                self.listener = nil
                if remaining > 0 {
                    self.queue.asyncAfter(deadline: .now() + 0.15) {
                        self.attemptBind(startingAt: candidate + 1, remaining: remaining - 1)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.running = false
                        self.statusText = "端口被占用，请到设置里换一个端口"
                    }
                }
            case .cancelled:
                DispatchQueue.main.async {
                    if self.listener == nil { self.running = false }
                }
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    // MARK: - token

    /// token 缓存：监听回调里在后台队列读，避免每次读 defaults
    private static var _tokenCache: String?
    static var tokenCache: String {
        if let cached = _tokenCache { return cached }
        let value = loadToken()
        _tokenCache = value
        return value
    }
    static func invalidateTokenCache() { _tokenCache = nil }

    private static func loadToken() -> String {
        let key = TransferDockPref.lanToken
        if let saved = UserDefaults.standard.string(forKey: key), saved.count >= 4 { return saved }
        let fresh = regenerateToken()
        return fresh
    }

    @discardableResult
    static func regenerateToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let value = String((0..<4).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(value, forKey: TransferDockPref.lanToken)
        _tokenCache = value
        return value
    }

    // MARK: - 网络接口

    /// 取局域网 IPv4（优先 en0 = Wi-Fi，其次任一非回环 up 接口）
    static func lanIPv4() -> String? {
        var address: String?
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return nil }
        defer { freeifaddrs(ifaddrPointer) }

        var candidates: [(name: String, ip: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard let rawAddr = pointer.pointee.ifa_addr else { continue }
            let family = rawAddr.pointee.sa_family
            guard family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(rawAddr, socklen_t(rawAddr.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: pointer.pointee.ifa_name)
            candidates.append((name, ip))
        }
        if let wifi = candidates.first(where: { $0.name == "en0" }) { address = wifi.ip }
        else { address = candidates.first?.ip }
        return address
    }

    // MARK: - 连接处理

    private final class ConnectionContext {
        let connection: NWConnection
        var headerBuffer = Data()
        var headersParsed = false
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var contentLength = 0
        var bodyFile: URL?
        var bodyHandle: FileHandle?
        var bodyReceived = 0
        var done = false

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let context = ConnectionContext(connection)
        queue.asyncAfter(deadline: .now() + 300) {
            if !context.done { connection.cancel() }
        }
        receive(context)
    }

    private func receive(_ context: ConnectionContext) {
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                context.connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.consume(context, data)
                if context.done { return }
            }
            if isComplete {
                context.connection.cancel()
                return
            }
            self.receive(context)
        }
    }

    private func consume(_ context: ConnectionContext, _ data: Data) {
        if !context.headersParsed {
            context.headerBuffer.append(data)
            guard let headerEnd = context.headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if context.headerBuffer.count > 64 * 1024 {
                    respond(context, status: 431, text: "请求头过大")
                }
                return
            }
            let headData = context.headerBuffer.subdata(in: 0..<headerEnd.lowerBound)
            parseHead(context, headData)
            let remainder = context.headerBuffer.subdata(in: headerEnd.upperBound..<context.headerBuffer.count)
            context.headerBuffer = Data()
            context.headersParsed = true

            if context.contentLength > 0 {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("frset-lan-\(UUID().uuidString).body")
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                context.bodyFile = tmp
                context.bodyHandle = try? FileHandle(forWritingTo: tmp)
            }
            if !remainder.isEmpty { writeBody(context, remainder) }
            if context.bodyReceived >= context.contentLength { finish(context) }
        } else {
            writeBody(context, data)
            if context.bodyReceived >= context.contentLength { finish(context) }
        }
    }

    private func parseHead(_ context: ConnectionContext, _ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        if parts.count >= 2 {
            context.method = String(parts[0]).uppercased()
            context.path = String(parts[1])
        }
        lines.removeFirst()
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            context.headers[key] = value
        }
        context.contentLength = Int(context.headers["content-length"] ?? "0") ?? 0
    }

    private func writeBody(_ context: ConnectionContext, _ data: Data) {
        let remaining = context.contentLength - context.bodyReceived
        guard remaining > 0 else { return }
        let slice = data.count > remaining ? Data(data.prefix(remaining)) : data
        try? context.bodyHandle?.write(contentsOf: slice)
        context.bodyReceived += slice.count
    }

    private func finish(_ context: ConnectionContext) {
        guard !context.done else { return }
        context.done = true
        try? context.bodyHandle?.close()
        context.bodyHandle = nil
        route(context)
    }

    // MARK: - 路由

    private func route(_ context: ConnectionContext) {
        let prefix = "/s/\(Self.tokenCache)"
        var sub = context.path
        var query: [String: String] = [:]

        if let mark = sub.firstIndex(of: "?") {
            let queryString = String(sub[sub.index(after: mark)...])
            sub = String(sub[..<mark])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }

        guard sub.hasPrefix(prefix) else {
            respond(context, status: 403, html: Self.errorPage("链接已失效",
                                                               detail: "请重新扫描 Frset 上的二维码。"))
            return
        }
        var rest = String(sub.dropFirst(prefix.count))
        if rest.hasPrefix("/") { rest.removeFirst() }

        switch (context.method, rest) {
        case ("GET", ""), ("GET", "index.html"):
            respond(context, status: 200, html: Self.indexHTML)
        case ("GET", "api/list"):
            respond(context, status: 200, data: Self.listPayload(),
                    contentType: "application/json; charset=utf-8")
        case ("POST", "api/upload"):
            handleUpload(context)
        case ("POST", "api/delete"):
            handleDelete(context, id: query["id"])
        case ("GET", "favicon.ico"):
            respond(context, status: 204, text: "")
        default:
            if context.method == "GET", rest.hasPrefix("dl/") {
                handleDownload(context, id: String(rest.dropFirst(3)))
            } else {
                respond(context, status: 404, text: "Not Found")
            }
        }
    }

    /// 列表 / 上传 / 下载 / 删除

    /// 索引是主线程持有的 @Published 数组：后台队列读它必须切回主线程，
    /// 否则并发读写数组可能拿到撕裂快照（偶发崩溃）。
    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private static func listPayload() -> Data {
        let items = onMain { LocalTransferStore.shared.items }
        let payload: [[String: Any]] = items.map { item in
            [
                "id": item.id,
                "name": item.name,
                "size": ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file),
                "mode": item.mode.label,
                "date": item.addedText
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("[]".utf8)
    }

    private func handleUpload(_ context: ConnectionContext) {
        defer { cleanupBody(context) }
        guard let bodyFile = context.bodyFile else {
            respond(context, status: 400, json: ["error": "没有收到请求体"])
            return
        }
        let contentType = context.headers["content-type"] ?? ""
        guard let boundary = MultipartParser.boundary(from: contentType) else {
            respond(context, status: 400, json: ["error": "上传格式不支持"])
            return
        }
        let files = MultipartParser.files(in: bodyFile, boundary: boundary)
        guard !files.isEmpty else {
            respond(context, status: 400, json: ["error": "没有选到文件"])
            return
        }

        var staged: [(name: String, tempURL: URL)] = []
        for file in files {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-lan-up-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(file.name)
            if MultipartParser.write(file, from: bodyFile, to: dest) {
                staged.append((file.name, dest))
            }
        }
        guard !staged.isEmpty else {
            respond(context, status: 500, json: ["error": "写入临时文件失败"])
            return
        }

        DispatchQueue.main.async {
            let count = LocalTransferStore.shared.addUploads(staged, source: "手机")
            self.receivedCount += count
            if count > 0 {
                Toast.show("手机上传了 \(count) 个文件", icon: "iphone.and.arrow.forward")
            }
            Log.info("TransferDock", "手机上传 \(count) 个文件")
        }
        respond(context, status: 200, json: ["count": staged.count])
    }

    private func handleDownload(_ context: ConnectionContext, id: String) {
        let item = Self.onMain { LocalTransferStore.shared.items.first(where: { $0.id == id }) }
        guard let item else {
            respond(context, status: 404, text: "文件不存在")
            return
        }
        guard let data = try? Data(contentsOf: item.stagedURL, options: .mappedIfSafe) else {
            respond(context, status: 404, text: "文件不可读")
            return
        }
        let encoded = item.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Content-Disposition: attachment; filename*=UTF-8''\(encoded)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(data)

        DispatchQueue.main.async {
            self.sentCount += 1
        }
        send(context, payload)
    }

    private func handleDelete(_ context: ConnectionContext, id: String?) {
        let target = id.flatMap { wanted in
            Self.onMain { LocalTransferStore.shared.items.first(where: { $0.id == wanted }) }
        }
        guard let item = target else {
            respond(context, status: 404, json: ["error": "条目不存在"])
            return
        }
        DispatchQueue.main.async {
            LocalTransferStore.shared.remove(item)
        }
        respond(context, status: 200, json: ["ok": true])
    }

    private func cleanupBody(_ context: ConnectionContext) {
        if let file = context.bodyFile { try? FileManager.default.removeItem(at: file) }
        context.bodyFile = nil
    }

    // MARK: - HTTP 响应

    private func respond(_ context: ConnectionContext, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(context, status: status, data: data, contentType: "application/json; charset=utf-8")
    }

    private func respond(_ context: ConnectionContext, status: Int, html: String) {
        respond(context, status: status, data: Data(html.utf8), contentType: "text/html; charset=utf-8")
    }

    private func respond(_ context: ConnectionContext, status: Int, text: String) {
        respond(context, status: status, data: Data(text.utf8), contentType: "text/plain; charset=utf-8")
    }

    private func respond(_ context: ConnectionContext, status: Int, data: Data, contentType: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Internal Server Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(data)
        send(context, payload)
    }

    private func send(_ context: ConnectionContext, _ payload: Data) {
        context.connection.send(content: payload, completion: .contentProcessed { _ in
            context.connection.cancel()
        })
    }

    // MARK: - 内嵌页面

    private static func errorPage(_ title: String, detail: String) -> String {
        """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title>
        <style>body{font:16px/1.6 -apple-system,system-ui,sans-serif;margin:0;padding:56px 24px;
        text-align:center;color:#111;background:#fafafa}h1{font-size:19px;margin:0 0 8px}
        p{color:#666;font-size:14px;margin:0}</style></head>
        <body><h1>\(title)</h1><p>\(detail)</p></body></html>
        """
    }

    /// 手机端页面：没有外链资源（无字体/CDN/图标），拖文件或点选都会走同一个上传接口
    private static let indexHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="theme-color" content="#f7f7f8">
    <title>Frset 文件直传</title>
    <style>
      :root { color-scheme: light dark; }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      body { margin:0; padding:18px 16px 40px; background:#f7f7f8; color:#111;
             font:16px/1.5 -apple-system, BlinkMacSystemFont, "PingFang SC", system-ui, sans-serif; }
      @media (prefers-color-scheme: dark) {
        body { background:#0f0f10; color:#f2f2f4; }
        .card { background:#1b1b1d !important; border-color:#2c2c2f !important; }
        .row { border-color:#2c2c2f !important; }
        .muted { color:#9a9aa0 !important; }
      }
      header { text-align:center; margin-bottom:16px; }
      h1 { font-size:19px; margin:0 0 4px; letter-spacing:.2px; }
      .muted { color:#6b6b70; font-size:12.5px; }
      .card { background:#fff; border:1px solid #e6e6e9; border-radius:14px; padding:14px; margin-bottom:14px; }
      .pick { display:block; text-align:center; padding:22px 12px; border-radius:12px;
              border:1.5px dashed #b9b9c0; cursor:pointer; transition:background .15s; }
      .pick:active, .pick.over { background:rgba(0,122,255,.08); border-color:#007aff; }
      .pick b { display:block; font-size:16px; margin-bottom:2px; }
      .pick span { font-size:12.5px; color:#6b6b70; }
      .bar { height:3px; background:rgba(0,0,0,.08); border-radius:2px; overflow:hidden; margin-top:10px; }
      .bar > i { display:block; height:100%; width:0; background:#007aff; transition:width .2s; }
      #status { font-size:12.5px; margin-top:8px; min-height:16px; color:#6b6b70; word-break:break-all; }
      h2 { font-size:13px; margin:0 0 8px; color:#6b6b70; display:flex; align-items:center; gap:8px; font-weight:600; }
      h2 button { margin-left:auto; font-size:12px; padding:4px 10px; border-radius:8px;
                  border:1px solid #d8d8dd; background:transparent; color:inherit; }
      ul { list-style:none; margin:0; padding:0; }
      li { display:flex; align-items:center; gap:10px; padding:10px 2px; border-bottom:1px solid #eee; }
      li:last-child { border-bottom:none; }
      li a { flex:1; min-width:0; text-decoration:none; color:inherit; }
      .n { display:block; font-size:14px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
      .s { display:block; font-size:11.5px; color:#8a8a90; margin-top:2px; }
      .del { border:none; background:transparent; color:#c04a4a; font-size:15px; padding:6px; }
      .empty { color:#8a8a90; font-size:13px; text-align:center; padding:18px 0; border:none; }
      footer { text-align:center; font-size:11px; color:#a0a0a6; margin-top:22px; }
    </style>
    </head>
    <body>
      <header>
        <h1>Frset 文件直传</h1>
        <div class="muted">同一 Wi-Fi · 不经过任何服务器</div>
      </header>

      <div class="card">
        <label class="pick" id="pick">
          <input type="file" id="file" multiple hidden>
          <b>选择照片 / 文件</b>
          <span>上传到这台 Mac 的文件中转</span>
        </label>
        <div class="bar"><i id="bar"></i></div>
        <div id="status"></div>
      </div>

      <div class="card">
        <h2>Mac 上的文件 <button id="refresh">刷新</button></h2>
        <ul id="list"><li class="empty">加载中…</li></ul>
      </div>

      <footer>Frset · 局域网直传</footer>

    <script>
    const $ = (s) => document.querySelector(s);
    const statusEl = $('#status'), barEl = $('#bar'), listEl = $('#list');
    // 「定向接收」模式：Mac 上勾选若干文件后点「扫码直传」，链接带 ?pick=id1,id2 —
    // 手机打开时只显示这几个文件、隐藏上传区，一目了然地接收。
    const PICK = ((location.search.match(/[?&]pick=([^&]*)/) || [,''])[1] || '')
      .split(',').filter(Boolean);
    const isPick = PICK.length > 0;

    function setStatus(text, percent) {
      statusEl.textContent = text || '';
      barEl.style.width = (percent == null ? 0 : Math.max(0, Math.min(100, percent))) + '%';
    }

    if (isPick) {
      const cards = document.querySelectorAll('.card');
      if (cards.length > 0) cards[0].style.display = 'none';   // 上传卡收起来（这页是收文件的）
      document.querySelector('header h1').textContent = '发给你的文件';
      document.querySelector('header .muted').textContent = '点文件名即可下载到手机';
    }

    async function loadList() {
      try {
        const res = await fetch('api/list', { cache: 'no-store' });
        const all = await res.json();
        const items = isPick ? all.filter(i => PICK.indexOf(i.id) >= 0) : all;
        if (!items.length) {
          listEl.innerHTML = '<li class="empty">' + (isPick ? '这些文件已不在 Mac 的中转站里' : '还没有文件') + '</li>';
          return;
        }
        listEl.innerHTML = '';
        for (const item of items) {
          const li = document.createElement('li');
          const a = document.createElement('a');
          a.href = 'dl/' + item.id;
          const name = document.createElement('span'); name.className = 'n'; name.textContent = item.name;
          const meta = document.createElement('span'); meta.className = 's';
          meta.textContent = item.size + ' · ' + item.mode + ' · ' + item.date;
          a.appendChild(name); a.appendChild(meta);
          li.appendChild(a);
          if (!isPick) {
            const del = document.createElement('button'); del.className = 'del'; del.textContent = '✕';
            del.title = '在 Mac 上移出中转';
            del.onclick = async () => {
              if (!confirm('在 Mac 上移出「' + item.name + '」？')) return;
              await fetch('api/delete?id=' + encodeURIComponent(item.id), { method: 'POST' });
              loadList();
            };
            li.appendChild(del);
          }
          listEl.appendChild(li);
        }
      } catch (e) {
        listEl.innerHTML = '<li class="empty">读取失败：' + e + '</li>';
      }
    }

    function upload(files) {
      if (!files || !files.length) return;
      const form = new FormData();
      for (const f of files) form.append('files', f, f.name);
      const xhr = new XMLHttpRequest();
      xhr.open('POST', 'api/upload');
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          const pct = Math.round((e.loaded / e.total) * 100);
          setStatus('上传中 ' + pct + '%', pct);
        }
      };
      xhr.onload = () => {
        let ok = false, count = 0;
        try { const j = JSON.parse(xhr.responseText); ok = xhr.status === 200; count = j.count || 0; }
        catch (_) { }
        setStatus(ok ? ('已上传 ' + count + ' 个文件') : '上传失败（' + xhr.status + '）', ok ? 100 : 0);
        loadList();
      };
      xhr.onerror = () => setStatus('网络中断，请确认和 Mac 在同一个 Wi-Fi', 0);
      setStatus('准备上传…', 0);
      xhr.send(form);
    }

    $('#file').addEventListener('change', (e) => { upload(e.target.files); e.target.value = ''; });
    $('#refresh').addEventListener('click', loadList);

    const pick = $('#pick');
    ['dragenter', 'dragover'].forEach((t) => pick.addEventListener(t, (e) => {
      e.preventDefault(); pick.classList.add('over');
    }));
    ['dragleave', 'drop'].forEach((t) => pick.addEventListener(t, (e) => {
      e.preventDefault(); pick.classList.remove('over');
    }));
    pick.addEventListener('drop', (e) => {
      if (e.dataTransfer && e.dataTransfer.files) upload(e.dataTransfer.files);
    });

    loadList();
    setInterval(loadList, 5000);
    </script>
    </body>
    </html>
    """
}

// MARK: - multipart/form-data 解析
//
// 只做「取文件部件」这一件事：按 boundary 切段 → 取 Content-Disposition 里的 filename
// → 记录正文在文件里的字节区间。正文不复制到内存，落盘时按区间直接 write(2)。

enum MultipartParser {

    struct Part {
        let name: String
        let offset: Int
        let length: Int
    }

    static func boundary(from contentType: String) -> String? {
        guard contentType.lowercased().hasPrefix("multipart/form-data") else { return nil }
        for segment in contentType.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func files(in fileURL: URL, boundary: String) -> [Part] {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return [] }
        return files(in: data, boundary: boundary)
    }

    static func files(in data: Data, boundary: String) -> [Part] {
        let delimiter = Data(("--" + boundary).utf8)
        let crlf2 = Data([13, 10, 13, 10])
        var parts: [Part] = []

        var previousDelimiterEnd: Int?
        var searchStart = data.startIndex
        while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            if let segmentStart = previousDelimiterEnd {
                let segmentEnd = range.lowerBound
                if segmentEnd > segmentStart {
                    // 段内结构：\r\n headers \r\n\r\n body \r\n
                    var start = segmentStart
                    if start + 2 <= segmentEnd, data[start] == 13, data[start + 1] == 10 { start += 2 }
                    if let headerEnd = data.range(of: crlf2, in: start..<segmentEnd) {
                        let headerData = data.subdata(in: start..<headerEnd.lowerBound)
                        let bodyStart = headerEnd.upperBound
                        var bodyEnd = segmentEnd
                        // 去掉分隔符前的 CRLF
                        if bodyEnd - 2 >= bodyStart, data[bodyEnd - 2] == 13, data[bodyEnd - 1] == 10 {
                            bodyEnd -= 2
                        }
                        if bodyEnd < bodyStart { bodyEnd = bodyStart }
                        if let name = filename(fromHeaderData: headerData) {
                            parts.append(Part(name: name, offset: bodyStart, length: bodyEnd - bodyStart))
                        }
                    }
                }
            }
            previousDelimiterEnd = range.upperBound
            searchStart = range.upperBound
        }
        return parts
    }

    private static func filename(fromHeaderData data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("content-disposition:") else { continue }
            // filename*=UTF-8''xxx 优先，其次 filename="xxx"
            if let starRange = line.range(of: "filename*=") {
                let raw = String(line[starRange.upperBound...])
                let value = raw.split(separator: ";").first.map(String.init) ?? raw
                if let tick = value.range(of: "''") {
                    let encoded = String(value[tick.upperBound...])
                    if let decoded = encoded.removingPercentEncoding { return sanitize(decoded) }
                }
                return sanitize(value)
            }
            if let nameRange = line.range(of: "filename=") {
                var value = String(line[nameRange.upperBound...])
                if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if value.isEmpty { continue }
                return sanitize(value)
            }
        }
        return nil
    }

    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名文件" : String(cleaned.prefix(120))
    }

    /// 把 mapped Data 的某段直接写到目标文件（不复制整段到内存）
    static func write(_ part: Part, from fileURL: URL, to destination: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return false }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else { return false }
        defer { try? handle.close() }

        var success = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { success = false; return }
            let pointer = base.advanced(by: part.offset)
            var written = 0
            while written < part.length {
                let result = Darwin.write(handle.fileDescriptor,
                                          pointer.advanced(by: written),
                                          part.length - written)
                if result <= 0 { success = false; return }
                written += result
            }
        }
        if !success { try? FileManager.default.removeItem(at: destination) }
        return success
    }
}
