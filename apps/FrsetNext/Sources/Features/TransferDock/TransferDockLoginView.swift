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
// 登录成功判据：cookie 里出现 OCLOUD_ACCESS_TOKEN 且 HASLOGIN 为真。

struct TransferDockLoginView: View {
    var onCancel: () -> Void
    var onLoggedIn: () -> Void

    @Stored private var progressText = "正在打开登录页…"
    @Stored private var detected = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.key")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("登录中转站账号")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Text(progressText)
                    .font(.system(size: 11))
                    .foregroundStyle(detected ? .primary : .secondary)
                Button("取消", action: onCancel)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Divider()
            TransferDockWebView(
                onCookiesDetected: { cookies in
                    TransferDockService.shared.saveCookies(cookies)
                    detected = true
                    progressText = "登录成功，正在保存…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { onLoggedIn() }
                },
                onProgress: { text in progressText = text })
        }
        .frame(width: 520, height: 640)
    }
}

/// WKWebView 包装：加载官方中转站页面，登录完成后把 cookie 交回
private struct TransferDockWebView: NSViewRepresentable {
    var onCookiesDetected: ([HTTPCookie]) -> Void
    var onProgress: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // 直接用桌面 UA，避免被引导去下载 App
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        if let url = URL(string: "https://cloud.heytap.com/owork/mapp/transfer-dock") {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.startPolling(webView: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCookiesDetected: onCookiesDetected, onProgress: onProgress)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCookiesDetected: ([HTTPCookie]) -> Void
        private let onProgress: (String) -> Void
        private var timer: Timer?
        private var finished = false
        private weak var webView: WKWebView?

        init(onCookiesDetected: @escaping ([HTTPCookie]) -> Void,
             onProgress: @escaping (String) -> Void) {
            self.onCookiesDetected = onCookiesDetected
            self.onProgress = onProgress
        }

        func startPolling(webView: WKWebView) {
            self.webView = webView
            onProgress("请在页面里输入账号密码")
            // 轮询 cookie：登录成功后官方前端会写入 OCLOUD_ACCESS_TOKEN
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
            RunLoop.main.add(timer!, forMode: .common)
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        private func checkCookies() {
            guard !finished, let webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let hasToken = cookies.contains { $0.name == "OCLOUD_ACCESS_TOKEN" && !$0.value.isEmpty }
                let hasLogin = cookies.contains { $0.name == "HASLOGIN" && ($0.value == "1" || $0.value.lowercased() == "true") }
                if hasToken && hasLogin {
                    self.finished = true
                    self.stopPolling()
                    self.onCookiesDetected(cookies)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onProgress("页面已加载，请登录")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onProgress("加载失败：\(error.localizedDescription)")
        }
    }
}
