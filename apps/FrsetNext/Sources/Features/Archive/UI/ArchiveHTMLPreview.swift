import AppKit
import SwiftUI
import WebKit

// MARK: - 网页预览（v210）
//
// 用户：「压缩包里的 HTML 直接渲染成浏览器里的那种，不是显示源码」。
// 之前 .html 被归到「代码」用带行号的文本视图显示（截图实证：deck.html 整页是源码），
// 这里改成真正的 WKWebView：
//   · 用 7zz 把 HTML **连同同目录资源**解到临时目录，再以 file:// + 读权限加载，
//     CSS/JS/图片/子页面按相对路径自然生效；
//   · 站内相对链接继续在窗内跳转（退回上一页可用），http(s) 外链交给系统浏览器；
//   · 顶部一条极简浏览器条：后退 / 前进 / 刷新 / 在浏览器打开 + 加载进度。
//
// 不做地址栏：归档内预览不需要手输 URL，真要看网页请点「在浏览器打开」。

/// WKWebView 的控制器：持有 webView、暴露可观察的导航状态。
final class WebPreviewController: NSObject, ObservableObject {

    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var pageTitle: String = ""

    /// 允许读取的根目录（同目录资源都在它下面）
    let rootDirectory: URL
    private(set) var webView: WKWebView!
    private var observers: [NSKeyValueObservation] = []

    init(fileURL: URL, rootDirectory: URL) {
        // v211 实测白屏根因：NSTemporaryDirectory() 给的是 /var/folders/…（/var 是符号链接），
        // 而 WKWebView 导航时把 URL 规范化成 /private/var/folders/…；两边都按字面比前缀
        // 必然不匹配 → decidePolicyFor 判为「越界」→ cancel → 纯白页。
        // 统一在入口解析符号链接，后面所有比较都用真实路径。
        let realRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.rootDirectory = realRoot
        super.init()

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 归档预览是本地静态页：不持久化任何站点数据
        config.websiteDataStore = .nonPersistent()

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        // 网页按浏览器观感渲染：页面自己有底色就用自己的；没有底色的裸 HTML 用系统文本底色，
        // 不能透出窗口玻璃（实测：透明底 + 深色文字在浅色玻璃上可读性很差）。
        web.underPageBackgroundColor = .textBackgroundColor
        self.webView = web

        observers.append(web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] v, _ in
            DispatchQueue.main.async { self?.canGoBack = v.canGoBack }
        })
        observers.append(web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] v, _ in
            DispatchQueue.main.async { self?.canGoForward = v.canGoForward }
        })
        observers.append(web.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in
            DispatchQueue.main.async {
                self?.progress = v.estimatedProgress
                self?.isLoading = v.estimatedProgress < 1
            }
        })
        observers.append(web.observe(\.title, options: [.initial, .new]) { [weak self] v, _ in
            DispatchQueue.main.async { self?.pageTitle = v.title ?? "" }
        })

        load(fileURL)
    }

    func load(_ url: URL) {
        webView.loadFileURL(url.resolvingSymlinksInPath(), allowingReadAccessTo: rootDirectory)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    /// 用系统默认浏览器打开当前页（解决「我要真浏览器能力」的场景）
    func openInBrowser() {
        if let current = webView.url, current.isFileURL {
            NSWorkspace.shared.open(current)
        }
    }

    /// 该 URL 是否属于本次预览的可读范围（同目录解出来的资源）
    private func isInsideRoot(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // 必须解析符号链接：/var 与 /private/var 指向同一目录但字面不同（v211 白屏根因）
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = rootDirectory.path
        return path == root || path.hasPrefix(root + "/")
    }
}

extension WebPreviewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        switch url.scheme?.lowercased() {
        case "file":
            // 只放行本次解压目录内的文件；越界（例如指向用户文稿）一律拦
            decisionHandler(isInsideRoot(url) ? .allow : .cancel)
        case "http", "https", "mailto":
            // 外链不在预览窗里打开：交给系统浏览器，避免把归档窗变成半个浏览器
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }
}

extension WebPreviewController: WKUIDelegate {
    /// target="_blank" / window.open：留在同一个 webView 里打开（不外弹新窗）
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.isFileURL, isInsideRoot(url) {
                webView.loadFileURL(url, allowingReadAccessTo: rootDirectory)
            } else if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }
}

// MARK: - SwiftUI 包装

private struct WebViewRepresentable: NSViewRepresentable {
    let controller: WebPreviewController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 归档右栏的网页预览：一条浏览器工具条 + WKWebView。
struct ArchiveHTMLPreview: View {

    let fileURL: URL
    let rootDirectory: URL
    let entryName: String

    @StateObject private var controller: WebPreviewController

    init(fileURL: URL, rootDirectory: URL, entryName: String) {
        self.fileURL = fileURL
        self.rootDirectory = rootDirectory
        self.entryName = entryName
        _controller = StateObject(wrappedValue: WebPreviewController(fileURL: fileURL,
                                                                    rootDirectory: rootDirectory))
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            ZStack(alignment: .top) {
                WebViewRepresentable(controller: controller)
                if controller.isLoading, controller.progress < 1 {
                    ProgressView(value: controller.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("网页")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("·").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            Text(entryName)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            navButton("chevron.left", enabled: controller.canGoBack, help: "后退") { controller.goBack() }
            navButton("chevron.right", enabled: controller.canGoForward, help: "前进") { controller.goForward() }
            navButton("arrow.clockwise", enabled: true, help: "刷新") { controller.reload() }
            navButton("safari", enabled: true, help: "用默认浏览器打开") { controller.openInBrowser() }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func navButton(_ symbol: String, enabled: Bool, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(enabled ? Color.secondary : Theme.tertiaryText.opacity(0.5))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
