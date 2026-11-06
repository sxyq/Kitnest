import AppKit
import SwiftUI
import WebKit

// MARK: - 中转站登录（内嵌官方登录页，账号密码照常在网页里输）
//
// 为什么不自己拼登录请求：官方登录是「RSA + AES-CBC 三段式 + HMAC 签名 + PKCE」，
// 且 check/login 的明文 payload 字段尚未实包验证。内嵌官方页面等于复用官方前端，
// 用户输账号密码后前端自己完成加密；我们只做一件事——登录成功时把 cookie 落盘，
// 让 Python 侧（frset_bridge.py）继续用同一份登录态。
//
// v255（用户：「登录完成了，它这边没有回传读取到 Cookie」）：
//   原来靠猜两个 cookie 名（OCLOUD_ACCESS_TOKEN / HASLOGIN）判断登录成功——
//   磁盘上 cookies.json 里实际只有 otrack_jssdk_store_116600 这类埋点 cookie，
//   这两个名字根本不存在，所以条件从未满足，onCookiesDetected 从未被调用。
//   现在不再猜名字：
//     · 进过授权页（id.heytap.com / login / auth / sso / 带 code=）后回到业务页 → 触发
//     · cookie 里出现 TOKEN / SESSION / SSO / TICKET / LOGIN / UID 类名字 → 触发
//     · 用户点「重新检测」→ 强制触发
//   触发后落盘 + 让桥真打一次 space_info 回验，**回验成功才关窗**。
//   回验失败不终止：用户可以继续在页面里登录，或点重新检测。

struct TransferDockLoginView: View {
    var onCancel: () -> Void
    var onLoggedIn: () -> Void

    @Stored private var detail = "正在打开登录页…"
    /// waiting / verifying / failed / ok
    @Stored private var phase = "waiting"
    @Stored private var forceTick = 0
    @Stored private var attempts = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("登录文件中转账号")
                    .font(.system(size: 13, weight: .semibold))

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(phase == "failed" ? Color.red : (phase == "ok" ? Color.green : Color.secondary))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.leading, 6)

                Spacer(minLength: 8)

                if phase == "verifying" {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                }
                Button("重新检测") {
                    phase = "waiting"
                    forceTick += 1
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(phase == "verifying" || phase == "ok")

                Button("取消", action: onCancel)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()

            TransferDockWebView(
                forceTick: forceTick,
                onCandidate: { cookies in
                    guard phase != "verifying", phase != "ok" else { return }
                    phase = "verifying"
                    detail = "拿到 \(cookies.count) 条 cookie，正在向服务端确认会话…"
                    TransferDockService.shared.saveCookies(cookies) { ok, reason in
                        if ok {
                            phase = "ok"
                            detail = "登录有效，正在进入中转站…"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onLoggedIn() }
                        } else {
                            phase = "failed"
                            attempts += 1
                            detail = (reason ?? "会话无效") + "（第 \(attempts) 次）"
                        }
                    }
                },
                onProgress: { text in
                    // 回验中/成功后不覆盖状态文字，避免把结果冲掉
                    if phase == "waiting" { detail = text }
                })
        }
        .frame(width: 560, height: 700)
    }
}

/// WKWebView 包装：加载官方中转站页面，登录完成后把 cookie 交回
private struct TransferDockWebView: NSViewRepresentable {
    var forceTick: Int
    var onCandidate: ([HTTPCookie]) -> Void
    var onProgress: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // v253（用户：「点了登录无法进行」）：OPPO 登录是 window.open 弹层，
        // WKWebView 没有 WKUIDelegate 时会把弹层直接丢掉——点登录毫无反应。
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // v255 诊断：官网登录态到底存 cookie 还是 localStorage，用探针一次问清。
        // 只回传键名与长度，不回传任何值（避免 token 进日志）。
        // 注意：必须挂在 configuration 上、且在创建 WKWebView 之前——创建后再 add 对已建视图无效。
        configuration.userContentController.add(context.coordinator, name: "frsetProbe")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 直接用桌面 UA，避免被引导去下载 App
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        if let url = URL(string: "https://cloud.heytap.com/owork/mapp/transfer-dock") {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.startPolling(webView: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.applyForceTick(forceTick)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCandidate: onCandidate, onProgress: onProgress)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

        // MARK: 页面探针（诊断登录态存哪：cookie 还是 localStorage）

        private var lastProbeSignature = ""

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "frsetProbe", let body = message.body as? [String: Any] else { return }
            let path = body["path"] as? String ?? ""
            let cookieLen = body["cookieLen"] as? Int ?? 0
            let keys = (body["keys"] as? [String]) ?? []
            let sig = "\(path)|\(cookieLen)|\(keys.joined(separator: ","))"
            guard sig != lastProbeSignature else { return }
            lastProbeSignature = sig
            Log.info("TransferDock", "页面探针 path=\(path) document.cookie=\(cookieLen)字节 "
                     + "localStorage=\(keys.prefix(24).joined(separator: ","))")
        }

        /// 每次页面落地都重新注入：跨页导航会把上一页的 setInterval 清掉
        private func installProbe(_ webView: WKWebView) {
            let js = """
            (function(){
              if (window.__frsetProbe) { return; }
              window.__frsetProbe = setInterval(function(){
                try {
                  var ks = [];
                  for (var i = 0; i < localStorage.length; i++) { ks.push(String(localStorage.key(i))); }
                  window.webkit.messageHandlers.frsetProbe.postMessage({
                    keys: ks, path: location.pathname, cookieLen: document.cookie.length
                  });
                } catch (e) {}
              }, 2500);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func detach() {
            stopPolling()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "frsetProbe")
            webView?.evaluateJavaScript("if (window.__frsetProbe) { clearInterval(window.__frsetProbe); }",
                                        completionHandler: nil)
        }

        /// 弹层登录：target=_blank / window.open 一律在同一个 webView 里就地打开
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private let onCandidate: ([HTTPCookie]) -> Void
        private let onProgress: (String) -> Void
        private var timer: Timer?
        private var finished = false
        private weak var webView: WKWebView?

        /// 是否进过授权页（id.heytap.com / login / auth / sso / 带 code=）
        private var sawAuthPage = false
        /// 上一次尝试抓取的 cookie 名字集合签名（去重）
        private var lastSignature = ""
        private var lastAttemptAt = Date.distantPast
        private var lastForceTick = 0

        init(onCandidate: @escaping ([HTTPCookie]) -> Void,
             onProgress: @escaping (String) -> Void) {
            self.onCandidate = onCandidate
            self.onProgress = onProgress
        }

        func startPolling(webView: WKWebView) {
            self.webView = webView
            onProgress("在页面里输入账号密码，登录成功后会自动回来")
            // v255 诊断：打开登录页先把 store 里已有的 cookie 名单打出来（只打名字，不打值）。
            // 这样从日志就能判断「登录前有哪些、登录后多了哪些」，不用再靠猜。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.dumpCookieNames("打开登录页")
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                autoreleasepool { self?.check(force: false) }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }

        private func dumpCookieNames(_ reason: String) {
            guard let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let list = cookies.map { "\($0.domain)/\($0.name)" }.sorted()
                Log.info("TransferDock", "cookie dump [\(reason)] 共 \(cookies.count) 条: \(list.joined(separator: ", "))")
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        /// 用户点「重新检测」
        func applyForceTick(_ tick: Int) {
            guard tick != lastForceTick else { return }
            lastForceTick = tick
            check(force: true)
        }

        // MARK: 抓取判定

        private func check(force: Bool) {
            guard !finished, let webView else { return }
            let url = webView.url
            let host = url?.host?.lowercased() ?? ""
            let path = url?.path.lowercased() ?? ""
            let query = url?.query?.lowercased() ?? ""

            // 记录「进过授权页」这一事实
            if host.contains("id.heytap.com") || path.contains("login") || path.contains("auth")
                || path.contains("sso") || query.contains("code=") {
                sawAuthPage = true
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let relevant = cookies.filter { c in
                    let d = c.domain.lowercased()
                    return d.hasSuffix("heytap.com") || d.hasSuffix("oppo.com")
                }
                guard !relevant.isEmpty else { return }

                let names = Set(relevant.map { $0.name.uppercased() })
                // 会话类 cookie：名字里含 TOKEN / SESSION / SSO / TICKET / LOGIN / UID
                let looksLoggedIn = names.contains { n in
                    ["TOKEN", "SESSION", "SSO", "TICKET", "LOGIN", "UID"].contains { n.contains($0) }
                }
                // 从授权页回到业务页
                let backToBiz = self.sawAuthPage && host.contains("cloud.heytap.com")
                    && !path.contains("login") && !path.contains("auth")

                guard force || looksLoggedIn || backToBiz else { return }

                let sig = relevant.map { "\($0.domain)|\($0.name)" }.sorted().joined(separator: ",")
                if !force, sig == self.lastSignature,
                   Date().timeIntervalSince(self.lastAttemptAt) < 3 {
                    return
                }
                self.lastSignature = sig
                self.lastAttemptAt = Date()

                Log.info("TransferDock", "候选 cookie \(relevant.count) 条 [\(sig)] 触发=\(force ? "手动" : (looksLoggedIn ? "会话类" : "回业务页"))")
                self.onCandidate(relevant)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onProgress("页面已加载，请登录")
            installProbe(webView)
            // 跳转落地那一刻立刻查一次：登录成功后回跳往往就是这一步
            check(force: false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onProgress("加载失败：\(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onProgress("加载失败：\(error.localizedDescription)")
        }
    }
}
