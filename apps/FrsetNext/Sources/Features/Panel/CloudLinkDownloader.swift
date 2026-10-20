import AppKit
import WebKit

// MARK: - 网盘「解析下载」（LinkSwift 思路的最小可用实现）
//
// 现状（2026-10-20 之前）：`CloudLinkActions.resolve` 只是打开网页 + Toast「解析器接入中」，
// 并没有真正的下载能力——用户点「解析下载」拿不到文件。
//
// 本实现分三档，按成功率递进：
//   1) 直链：URL 路径就是文件（.zip/.mp4/…）且不是分享页 → 直接 URLSession 下载
//   2) 分享页：隐藏 WKWebView 打开，注入 JS 抓页面里的文件直链候选（含 JSON 内嵌 URL），
//      把 WKWebView 的 cookie 同步进 URLSession 后下载第一个可用的
//   3) 解析失败（百度/夸克等需要登录、验证码、客户端协议）：明确提示并打开页面，绝不假装成功
//
// 下载落盘到 ~/Downloads，完成后通知（Toast）+ 记录到「最近下载」列表（供后续下载中心使用）。

final class CloudLinkDownloader: NSObject, ObservableObject {

    static let shared = CloudLinkDownloader()

    enum Status: Equatable {
        case resolving          // 正在解析页面
        case queued             // 排队中（受并发上限约束）
        case downloading
        case finished
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let sourceURL: URL
        var progress: Double = 0
        var status: Status = .resolving
        var localURL: URL?
    }

    @Published private(set) var items: [Item] = []

    private var resolver: LinkPageResolver?

    /// 可直接下载的扩展名（用于「直链」判定与页面抓取过滤）
    private static let fileExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "iso",
        "mp4", "mkv", "mov", "avi", "mp3", "flac", "wav",
        "pdf", "epub", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "png", "jpg", "jpeg", "gif", "webp", "apk", "exe", "txt", "md", "json"
    ]

    private var downloadsDirectory: URL {
        let url = URL(fileURLWithPath: CloudLinkSettings.downloadDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 入口

    func start(link: CloudDriveLink) {
        let direct = Self.isDirectFileURL(link.url) && !link.isSharePage
        Log.info("CloudLink", "解析下载：provider=\(link.provider.rawValue) direct=\(direct) engine=\(CloudLinkSettings.engine.rawValue) url=\(link.url.absoluteString)")

        if CloudLinkSettings.engine == .copy, direct {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            Toast.show("直链已复制", icon: "doc.on.doc")
            return
        }

        if direct {
            enqueueDownload(url: link.url, preferredName: nil, provider: link.provider)
            return
        }

        Toast.show("正在解析\(link.provider.displayName)页面…", icon: "arrow.down.circle")
        let resolver = LinkPageResolver()
        self.resolver = resolver
        resolver.resolve(pageURL: link.url) { [weak self] result in
            guard let self else { return }
            self.resolver = nil
            switch result {
            case .success(let fileURL):
                Toast.show("已解析到直链，开始下载", icon: "checkmark.circle.fill")
                self.enqueueDownload(url: fileURL, preferredName: nil, provider: link.provider)
            case .failure(let reason):
                Log.info("CloudLink", "解析失败：\(reason)")
                Toast.show(reason, icon: "exclamationmark.triangle", isWarning: true)
                NSWorkspace.shared.open(link.url)
            }
        }
    }

    /// 直链下载入口（也用于自检/测试）
    func startDirectDownload(url: URL) {
        enqueueDownload(url: url, preferredName: nil,
                        provider: CloudDriveLinkDetector.provider(forHost: url.host ?? ""))
    }

    private static func isDirectFileURL(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - 队列（并发上限 / 重试）

    private struct Job {
        let id: UUID
        let url: URL
        let name: String
        let provider: CloudDriveProvider?
        var attempt: Int = 0
    }

    private var pending: [Job] = []
    private var active = 0

    private func enqueueDownload(url: URL, preferredName: String?, provider: CloudDriveProvider?) {
        let name = preferredName ?? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
        var item = Item(name: name, sourceURL: url)
        item.status = .queued
        items.insert(item, at: 0)
        let id = item.id
        pending.append(Job(id: id, url: url, name: name, provider: provider))
        Log.info("CloudLink", "入队：\(name)（等待 \(pending.count)，并发上限 \(CloudLinkSettings.maxConcurrent)）")
        pump()
    }

    private func pump() {
        while active < CloudLinkSettings.maxConcurrent, !pending.isEmpty {
            let job = pending.removeFirst()
            active += 1
            run(job)
        }
    }

    private func release() {
        active = max(0, active - 1)
        pump()
    }

    private func run(_ job: Job) {
        switch CloudLinkSettings.engine {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.url.absoluteString, forType: .string)
            Toast.show("直链已复制", icon: "doc.on.doc")
            finish(id: job.id, note: "已复制直链")
            release()
        case .aria2:
            sendToAria2(job)
        case .builtin:
            download(job)
        }
    }

    private func download(_ job: Job) {
        setStatus(job.id, .downloading)
        var request = URLRequest(url: job.url)
        request.timeoutInterval = CloudLinkSettings.timeout
        let custom = CloudLinkSettings.uaOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = job.provider ?? CloudDriveLinkDetector.provider(forHost: job.url.host ?? "")
        let ua = custom.isEmpty
            ? (provider.map(CloudLinkSettings.defaultUA(for:)) ?? "")
            : custom
        if !ua.isEmpty { request.setValue(ua, forHTTPHeaderField: "User-Agent") }

        let task = URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self else { return }
            if let error {
                self.handleFailure(job, reason: error.localizedDescription)
                return
            }
            guard let tempURL else {
                self.handleFailure(job, reason: "服务器没有返回文件内容")
                return
            }
            let suggested = response?.suggestedFilename
            let filename = Self.sanitize(suggested ?? job.name)
            do {
                switch try self.destination(for: filename) {
                case .skipped:
                    try? FileManager.default.removeItem(at: tempURL)
                    self.finish(id: job.id, note: "同名文件已存在，按设置跳过")
                case .file(let dest):
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    self.finish(id: job.id, localURL: dest)
                }
            } catch {
                self.handleFailure(job, reason: error.localizedDescription)
            }
        }
        task.resume()
    }

    /// aria2 JSON-RPC 直投：并发/分片/续传/UA 都按配置下发
    private func sendToAria2(_ job: Job) {
        setStatus(job.id, .downloading)
        guard let endpoint = URL(string: CloudLinkSettings.aria2Endpoint) else {
            finish(id: job.id, error: "aria2 地址无效")
            release()
            return
        }
        let custom = CloudLinkSettings.uaOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = job.provider ?? CloudDriveLinkDetector.provider(forHost: job.url.host ?? "")
        let ua = custom.isEmpty
            ? (provider.map(CloudLinkSettings.defaultUA(for:)) ?? "")
            : custom

        var options: [String: Any] = [
            "dir": CloudLinkSettings.downloadDirectory,
            "split": "\(CloudLinkSettings.connectionsPerFile)",
            "max-connection-per-server": "\(CloudLinkSettings.connectionsPerFile)",
            "min-split-size": "\(CloudLinkSettings.chunkSizeMB)M",
            "continue": CloudLinkSettings.resumeEnabled ? "true" : "false",
            "auto-file-renaming": CloudLinkSettings.conflictPolicy == .rename ? "true" : "false",
            "allow-overwrite": CloudLinkSettings.conflictPolicy == .overwrite ? "true" : "false",
            "out": job.name
        ]
        if !ua.isEmpty { options["user-agent"] = ua }

        var params: [Any] = []
        if !CloudLinkSettings.aria2Token.isEmpty {
            params.append("token:\(CloudLinkSettings.aria2Token)")
        }
        params.append([job.url.absoluteString])
        params.append(options)
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": job.id.uuidString,
            "method": "aria2.addUri",
            "params": params
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                self.handleFailure(job, reason: "aria2 连接失败：\(error.localizedDescription)")
                return
            }
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = object["error"] as? [String: Any] {
                self.handleFailure(job, reason: "aria2：\(err["message"] as? String ?? "未知错误")")
                return
            }
            self.finish(id: job.id, note: "已交给 aria2（\(CloudLinkSettings.connectionsPerFile) 连接）")
            self.release()
        }.resume()
    }

    private func handleFailure(_ job: Job, reason: String) {
        if job.attempt < CloudLinkSettings.retryCount {
            var next = job
            next.attempt += 1
            Log.info("CloudLink", "下载失败（\(reason)），第 \(next.attempt)/\(CloudLinkSettings.retryCount) 次重试")
            release()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                self.pending.insert(next, at: 0)
                self.pump()
            }
        } else {
            finish(id: job.id, error: reason)
            release()
        }
    }

    private enum Destination {
        case file(URL)
        case skipped
    }

    private func destination(for filename: String) throws -> Destination {
        let dir = downloadsDirectory
        let dest = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: dest.path) else { return .file(dest) }
        switch CloudLinkSettings.conflictPolicy {
        case .overwrite:
            try FileManager.default.removeItem(at: dest)
            return .file(dest)
        case .skip:
            return .skipped
        case .rename:
            let base = dest.deletingPathExtension().lastPathComponent
            let ext = dest.pathExtension
            var index = 2
            while true {
                let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
                let url = dir.appendingPathComponent(candidate)
                if !FileManager.default.fileExists(atPath: url.path) { return .file(url) }
                index += 1
            }
        }
    }

    private func setStatus(_ id: UUID, _ status: Status) {
        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[index].status = status
        }
    }

    private func finish(id: UUID, localURL: URL? = nil, error: String? = nil, note: String? = nil) {
        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            if let error {
                self.items[index].status = .failed(error)
                Toast.show("下载失败：\(error)", icon: "exclamationmark.triangle", isWarning: true)
            } else if let localURL {
                self.items[index].status = .finished
                self.items[index].localURL = localURL
                self.items[index].progress = 1
                Toast.show("已下载：\(localURL.lastPathComponent)", icon: "checkmark.circle.fill")
                Log.info("CloudLink", "下载完成：\(localURL.path)")
                if CloudLinkSettings.revealAfterDownload {
                    NSWorkspace.shared.activateFileViewerSelecting([localURL])
                }
            } else {
                self.items[index].status = .finished
                self.items[index].progress = 1
                Toast.show(note ?? "完成", icon: "checkmark.circle.fill")
                Log.info("CloudLink", note ?? "完成")
            }
        }
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "download" : trimmed
        return fallback.replacingOccurrences(of: "/", with: "_")
    }
}

// MARK: - 分享页直链解析（隐藏 WKWebView + JS）

/// 打开分享页，等待渲染后抓取页面里的文件直链候选。
/// 只做「页面上真实存在的直链」提取——不伪造、不绕过登录/验证码。
final class LinkPageResolver: NSObject, WKNavigationDelegate {

    enum Result {
        case success(URL)
        case failure(String)
    }

    private var webView: WKWebView?
    private var completion: ((Result) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    func resolve(pageURL: URL, completion: @escaping (Result) -> Void) {
        self.completion = completion
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 复用登录态（与浏览器同源 cookie 不共享，但同 app 内多次解析可复用）
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        self.webView = webView
        webView.load(URLRequest(url: pageURL))

        // 解析超时：12s（分享页动态渲染慢，但不应无限等）
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure("解析超时：该页面可能需要登录或验证码"))
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 首屏渲染后再等 1.2s，给 SPA 初始化/接口回填留时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.extractLinks(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure("页面加载失败：\(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure("页面加载失败：\(error.localizedDescription)"))
    }

    private func extractLinks(from webView: WKWebView) {
        let script = """
        (() => {
          const exts = /\\.(zip|rar|7z|tar|gz|dmg|pkg|iso|mp4|mkv|mov|avi|mp3|flac|wav|pdf|epub|docx?|xlsx?|pptx?|png|jpe?g|gif|webp|apk|exe|txt|md|json)(\\?|$|#)/i;
          const found = new Set();
          document.querySelectorAll('a[href]').forEach(a => {
            try {
              const u = new URL(a.href, location.href);
              if (/^https?:/.test(u.href) && exts.test(u.pathname)) found.add(u.href);
            } catch (e) {}
          });
          const html = document.documentElement.innerHTML;
          const re = /https?:\\/\\/[^"'\\\\\\s<>]+?\\.(?:zip|rar|7z|tar|gz|dmg|pkg|iso|mp4|mkv|mov|avi|mp3|flac|wav|pdf|epub|docx?|xlsx?|pptx?|png|jpe?g|gif|webp|apk|exe|txt|md|json)(?:\\?[^"'\\\\\\s<>]*)?/gi;
          (html.match(re) || []).forEach(u => found.add(u.replace(/&amp;/g, '&')));
          return Array.from(found).slice(0, 12);
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            if let error {
                self.finish(.failure("解析脚本失败：\(error.localizedDescription)"))
                return
            }
            let candidates = (value as? [String]) ?? []
            guard let first = candidates.first, let url = URL(string: first) else {
                self.finish(.failure("未找到直链：该网盘可能要求登录/客户端下载"))
                return
            }
            self.finish(.success(url), syncCookiesFrom: webView)
        }
    }

    /// 把 WKWebView 的 cookie 同步给 URLSession（很多直链校验登录态）
    private func syncCookiesFrom(_ webView: WKWebView) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where cookie.domain.hasSuffix(".baidu.com")
                || cookie.domain.hasSuffix(".aliyundrive.com")
                || cookie.domain.hasSuffix(".alipan.com")
                || cookie.domain.hasSuffix(".quark.cn")
                || cookie.domain.hasSuffix(".123pan.com")
                || cookie.domain.hasSuffix(".123684.com")
                || cookie.domain.hasSuffix(".xunlei.com") {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    private func finish(_ result: Result, syncCookiesFrom webView: WKWebView? = nil) {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let webView { syncCookiesFrom(webView) }
        let callback = completion
        completion = nil
        self.webView?.stopLoading()
        self.webView?.navigationDelegate = nil
        self.webView = nil
        callback?(result)
    }
}
