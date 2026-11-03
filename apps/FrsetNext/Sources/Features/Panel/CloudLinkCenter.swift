import AppKit
import SwiftUI

// MARK: - 网盘解析中心（下载配置 + 诊断）
//
// 用户复制网盘链接后：状态栏下方弹出小提示 → 点开这个窗口。
// 窗口负责三件事：
//   1. 把「这条链接能不能解析」讲清楚（识别 / 脚本 / 页面可达性 / 下载目录 / UA）；
//   2. 给出可修改的下载配置（解析脚本、保存目录、超时、UA、自动更新）；
//   3. 列出 8 家网盘的支持情况，当前链接命中哪家一眼可见。

// MARK: 配置

enum CloudLinkSettings {
    private static let scriptKey = "cloudlink.scriptPath"
    private static let dirKey = "cloudlink.downloadDirectory"
    private static let timeoutKey = "cloudlink.timeout"
    private static let autoUpdateKey = "cloudlink.autoUpdate"
    private static let uaKey = "cloudlink.uaOverride"

    static var scriptPath: String {
        get { UserDefaults.standard.string(forKey: scriptKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: scriptKey) }
    }

    static var downloadDirectory: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: dirKey), !saved.isEmpty { return saved }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        }
        set { UserDefaults.standard.set(newValue, forKey: dirKey) }
    }

    static var timeout: Double {
        get {
            let value = UserDefaults.standard.double(forKey: timeoutKey)
            return value > 0 ? value : 20
        }
        set { UserDefaults.standard.set(newValue, forKey: timeoutKey) }
    }

    static var autoUpdate: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoUpdateKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoUpdateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    static var uaOverride: String {
        get { UserDefaults.standard.string(forKey: uaKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: uaKey) }
    }

    // MARK: 下载引擎与并发（LinkSwift config 的对应项）

    enum Engine: String, CaseIterable {
        case builtin, aria2, copy

        var title: String {
            switch self {
            case .builtin: return "内置下载"
            case .aria2: return "aria2 RPC"
            case .copy: return "复制直链"
            }
        }
    }

    enum ConflictPolicy: String, CaseIterable {
        case rename, overwrite, skip

        var title: String {
            switch self {
            case .rename: return "自动重命名"
            case .overwrite: return "覆盖"
            case .skip: return "跳过"
            }
        }
    }

    private static let engineKey = "cloudlink.engine"
    private static let maxConcurrentKey = "cloudlink.maxConcurrent"
    private static let connectionsKey = "cloudlink.connectionsPerFile"
    private static let chunkKey = "cloudlink.chunkSizeMB"
    private static let retryKey = "cloudlink.retryCount"
    private static let resumeKey = "cloudlink.resume"
    private static let conflictKey = "cloudlink.conflictPolicy"
    private static let revealKey = "cloudlink.revealAfterDownload"
    private static let aria2EndpointKey = "cloudlink.aria2.endpoint"
    private static let aria2TokenKey = "cloudlink.aria2.token"
    private static let scriptURLKey = "cloudlink.scriptUpdateURL"

    static var engine: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .builtin }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    /// 同时下载的文件数（1–6）
    static var maxConcurrent: Int {
        get { max(1, min(6, UserDefaults.standard.object(forKey: maxConcurrentKey) as? Int ?? 2)) }
        set { UserDefaults.standard.set(max(1, min(6, newValue)), forKey: maxConcurrentKey) }
    }

    /// 单文件并发连接数（aria2 的 split / max-connection-per-server）
    static var connectionsPerFile: Int {
        get { max(1, min(16, UserDefaults.standard.object(forKey: connectionsKey) as? Int ?? 8)) }
        set { UserDefaults.standard.set(max(1, min(16, newValue)), forKey: connectionsKey) }
    }

    /// 分片大小 MB（aria2 的 min-split-size）
    static var chunkSizeMB: Int {
        get { UserDefaults.standard.object(forKey: chunkKey) as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: chunkKey) }
    }

    static var retryCount: Int {
        get { max(0, min(10, UserDefaults.standard.object(forKey: retryKey) as? Int ?? 3)) }
        set { UserDefaults.standard.set(max(0, min(10, newValue)), forKey: retryKey) }
    }

    static var resumeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: resumeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: resumeKey) }
    }

    static var conflictPolicy: ConflictPolicy {
        get { ConflictPolicy(rawValue: UserDefaults.standard.string(forKey: conflictKey) ?? "") ?? .rename }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: conflictKey) }
    }

    static var revealAfterDownload: Bool {
        get { UserDefaults.standard.object(forKey: revealKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: revealKey) }
    }

    static var aria2Endpoint: String {
        get {
            let value = UserDefaults.standard.string(forKey: aria2EndpointKey) ?? ""
            return value.isEmpty ? "http://127.0.0.1:6800/jsonrpc" : value
        }
        set { UserDefaults.standard.set(newValue, forKey: aria2EndpointKey) }
    }

    static var aria2Token: String {
        get { UserDefaults.standard.string(forKey: aria2TokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: aria2TokenKey) }
    }

    /// LinkSwift 脚本在线更新源（.user.js 原始地址）
    static var scriptUpdateURL: String {
        get {
            let value = UserDefaults.standard.string(forKey: scriptURLKey) ?? ""
            return value.isEmpty
                ? "https://raw.githubusercontent.com/hmjz100/LinkSwift/main/LinkSwift.user.js"
                : value
        }
        set { UserDefaults.standard.set(newValue, forKey: scriptURLKey) }
    }

    /// 各家网盘下载时要求/建议的 UA（LinkSwift config.ua 的实测结论）
    static func defaultUA(for provider: CloudDriveProvider) -> String {
        switch provider {
        case .baidu:
            return "pan.baidu.com"
        case .quark:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/3.20.0 Chrome/120.0.0.0 Safari/537.36"
        default:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }
    }
}

// MARK: - 诊断

struct CloudLinkCheck: Identifiable {
    enum State {
        case pending, running, ok, warn, failed
    }

    let id = UUID()
    let title: String
    var state: State = .pending
    var detail: String = ""
}

final class CloudLinkTester: ObservableObject {
    @Published private(set) var checks: [CloudLinkCheck] = []
    @Published private(set) var isRunning = false
    @Published private(set) var summary: String = ""

    private var task: URLSessionDataTask?

    func run(link: CloudDriveLink) {
        task?.cancel()
        isRunning = true
        summary = ""
        checks = [
            CloudLinkCheck(title: "链接识别"),
            CloudLinkCheck(title: "解析脚本"),
            CloudLinkCheck(title: "分享页可达性"),
            CloudLinkCheck(title: "下载目录"),
            CloudLinkCheck(title: "下载 UA")
        ]
        mark(0, .running, "识别中…")

        // ① 识别：本地规则，同步
        if link.isSharePage {
            mark(0, .ok, "\(link.provider.displayName) · 分享页 · \(link.host)")
        } else {
            mark(0, .warn, "\(link.provider.displayName) · 非分享页（个人主页/文件页需要登录态，解析可能失败）")
        }

        // ② 解析脚本
        let script = CloudLinkSettings.scriptPath
        if script.isEmpty {
            mark(1, .warn, "未配置 LinkSwift 脚本；将使用内置网页解析（成功率较低）")
        } else if !FileManager.default.fileExists(atPath: script) {
            mark(1, .failed, "脚本不存在：\(script)")
        } else if let version = Self.scriptVersion(at: script) {
            mark(1, .ok, "已配置 · \(version)")
        } else {
            mark(1, .ok, "已配置 · \(URL(fileURLWithPath: script).lastPathComponent)")
        }

        // ③ 分享页可达性（不携带登录 cookie，只判断网络与状态码）
        probe(url: link.url, provider: link.provider)

        // ④ 下载目录
        let dir = CloudLinkSettings.downloadDirectory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
            if FileManager.default.isWritableFile(atPath: dir) {
                mark(3, .ok, dir)
            } else {
                mark(3, .failed, "目录不可写：\(dir)")
            }
        } else {
            mark(3, .failed, "目录不存在：\(dir)")
        }

        // ⑤ UA
        let custom = CloudLinkSettings.uaOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if custom.isEmpty {
            mark(4, .ok, "使用 \(link.provider.displayName) 默认 UA")
        } else {
            mark(4, .ok, "自定义 UA（\(custom.count) 字符）")
        }
    }

    private func probe(url: URL, provider: CloudDriveProvider) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = CloudLinkSettings.timeout
        // 探针用浏览器 UA：下载 UA（如百度 `pan.baidu.com`）不是合法 UA，页面会返回异常内容
        let customUA = CloudLinkSettings.uaOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue(customUA.isEmpty
                         ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                         : customUA,
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        mark(2, .running, "请求 \(url.host ?? "")…")

        let session = URLSession(configuration: .ephemeral)
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                if let error {
                    let ns = error as NSError
                    if ns.code == NSURLErrorCannotDecodeRawData || ns.code == NSURLErrorCannotParseResponse {
                        self.mark(2, .warn, "页面可达，但内容无法解码（可能需要登录/被风控拦截）")
                        self.summary = "需要登录态；实际解析请在网页解析器中完成"
                    } else {
                        self.mark(2, .failed, "请求失败：\(error.localizedDescription)")
                        self.summary = "网络不可达或被拦截"
                    }
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.mark(2, .warn, "非 HTTP 响应")
                    self.summary = "无法判断页面状态"
                    return
                }
                let title = data.flatMap { Self.htmlTitle($0) }
                let titleText = title.map { " · \($0)" } ?? ""
                if (200...399).contains(http.statusCode) {
                    self.mark(2, .ok, "HTTP \(http.statusCode)\(titleText)")
                    self.summary = "页面可达；实际取直链需要登录态与脚本"
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    self.mark(2, .warn, "HTTP \(http.statusCode) · 需要登录或触发风控")
                    self.summary = "需要先在解析窗口登录该网盘"
                } else {
                    self.mark(2, .warn, "HTTP \(http.statusCode)\(titleText)")
                    self.summary = "页面状态异常，可能需要验证码"
                }
            }
        }
        task?.resume()
    }

    private func mark(_ index: Int, _ state: CloudLinkCheck.State, _ detail: String) {
        guard checks.indices.contains(index) else { return }
        checks[index].state = state
        checks[index].detail = detail
    }

    static func scriptVersion(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4096)
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var name = "LinkSwift"
        var version = ""
        for line in text.split(separator: "\n").prefix(40) {
            if line.contains("@name") {
                name = line.components(separatedBy: "@name").last?
                    .trimmingCharacters(in: .whitespaces) ?? name
            }
            if line.contains("@version") {
                version = line.components(separatedBy: "@version").last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
            }
        }
        return version.isEmpty ? name : "\(name) \(version)"
    }

    static func htmlTitle(_ data: Data) -> String? {
        guard let text = String(data: data.prefix(8192), encoding: .utf8),
              let start = text.range(of: "<title>", options: .caseInsensitive),
              let end = text.range(of: "</title>", options: .caseInsensitive),
              start.upperBound < end.lowerBound else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 窗口内容

struct CloudLinkCenterView: View {
    let link: CloudDriveLink
    @ObservedObject private var tester = CloudLinkTester()
    @Stored private var scriptPath = CloudLinkSettings.scriptPath
    @Stored private var downloadDir = CloudLinkSettings.downloadDirectory
    @Stored private var timeout = CloudLinkSettings.timeout
    @Stored private var autoUpdate = CloudLinkSettings.autoUpdate
    @Stored private var uaOverride = CloudLinkSettings.uaOverride
    @Stored private var engineRaw = CloudLinkSettings.engine.rawValue
    @Stored private var maxConcurrent = CloudLinkSettings.maxConcurrent
    @Stored private var connections = CloudLinkSettings.connectionsPerFile
    @Stored private var chunkMB = CloudLinkSettings.chunkSizeMB
    @Stored private var retryCount = CloudLinkSettings.retryCount
    @Stored private var resumeEnabled = CloudLinkSettings.resumeEnabled
    @Stored private var conflictRaw = CloudLinkSettings.conflictPolicy.rawValue
    @Stored private var revealAfter = CloudLinkSettings.revealAfterDownload
    @Stored private var aria2Endpoint = CloudLinkSettings.aria2Endpoint
    @Stored private var aria2Token = CloudLinkSettings.aria2Token
    @Stored private var scriptUpdateURL = CloudLinkSettings.scriptUpdateURL

    private var tint: Color { Color(nsColor: link.provider.tint) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    checkSection
                    configSection
                    providersSection
                }
                .padding(16)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 560, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { tester.run(link: link) }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.16)).frame(width: 34, height: 34)
                Image(systemName: link.provider.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(link.provider.displayName) · 链接解析")
                    .font(.system(size: 14, weight: .semibold))
                Text(link.url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("打开链接") { NSWorkspace.shared.open(link.url) }
                .controlSize(.small)
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
                Toast.show("链接已复制", icon: "checkmark.circle.fill")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    // MARK: 检测

    private var checkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("解析检测")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if tester.isRunning { ProgressView().controlSize(.small) }
                Button("重新检测") { tester.run(link: link) }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
            }
            VStack(spacing: 0) {
                ForEach(tester.checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        stateIcon(check.state)
                            .frame(width: 14)
                        Text(check.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 92, alignment: .leading)
                        Text(check.detail.isEmpty ? "—" : check.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    if check.id != tester.checks.last?.id { Divider().opacity(0.4) }
                }
            }
            .glassCard(radius: 8)

            if !tester.summary.isEmpty {
                Text(tester.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("说明：解析依赖网盘页面登录态，检测只验证链接与脚本配置；实际取直链在「开始解析」后由网页解析器完成。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func stateIcon(_ state: CloudLinkCheck.State) -> some View {
        Group {
            switch state {
            case .pending: Image(systemName: "circle.dotted").foregroundStyle(Theme.tertiaryText)
            case .running: Image(systemName: "clock").foregroundStyle(.secondary)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .font(.system(size: 11))
    }

    // MARK: 配置

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("下载配置")
                .font(.system(size: 12, weight: .semibold))

            // 下载方式
            configRow(title: "下载方式", hint: "内置 / aria2 / 只复制直链") {
                Picker("", selection: Binding(
                    get: { engineRaw },
                    set: { engineRaw = $0; CloudLinkSettings.engine = CloudLinkSettings.Engine(rawValue: $0) ?? .builtin })) {
                    ForEach(CloudLinkSettings.Engine.allCases, id: \.rawValue) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }

            // 并发
            configRow(title: "同时下载", hint: "并发文件数，1–6") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(maxConcurrent) },
                        set: { maxConcurrent = Int($0); CloudLinkSettings.maxConcurrent = Int($0) }),
                           in: 1...6, step: 1)
                        .frame(width: 180)
                    Text("\(maxConcurrent) 个").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            configRow(title: "单文件连接数", hint: "aria2 的 split / max-connection-per-server") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(connections) },
                        set: { connections = Int($0); CloudLinkSettings.connectionsPerFile = Int($0) }),
                           in: 1...16, step: 1)
                        .frame(width: 180)
                        .disabled(engineRaw != CloudLinkSettings.Engine.aria2.rawValue)
                    Text("\(connections)").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            configRow(title: "分片大小", hint: "aria2 的 min-split-size") {
                Picker("", selection: Binding(
                    get: { chunkMB },
                    set: { chunkMB = $0; CloudLinkSettings.chunkSizeMB = $0 })) {
                    Text("1 MB").tag(1)
                    Text("4 MB").tag(4)
                    Text("10 MB").tag(10)
                    Text("32 MB").tag(32)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .disabled(engineRaw != CloudLinkSettings.Engine.aria2.rawValue)
            }

            configRow(title: "失败重试", hint: "0–10 次，指数退避") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(retryCount) },
                        set: { retryCount = Int($0); CloudLinkSettings.retryCount = Int($0) }),
                           in: 0...10, step: 1)
                        .frame(width: 180)
                    Text("\(retryCount) 次").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("断点续传（aria2 continue）", isOn: Binding(
                get: { resumeEnabled },
                set: { resumeEnabled = $0; CloudLinkSettings.resumeEnabled = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(engineRaw != CloudLinkSettings.Engine.aria2.rawValue)

            if engineRaw == CloudLinkSettings.Engine.aria2.rawValue {
                configRow(title: "aria2 RPC", hint: "JSON-RPC 地址（默认 6800）") {
                    TextField("http://127.0.0.1:6800/jsonrpc", text: Binding(
                        get: { aria2Endpoint },
                        set: { aria2Endpoint = $0; CloudLinkSettings.aria2Endpoint = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
                configRow(title: "RPC 密钥", hint: "--rpc-secret，可留空") {
                    SecureField("token", text: Binding(
                        get: { aria2Token },
                        set: { aria2Token = $0; CloudLinkSettings.aria2Token = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            configRow(title: "同名文件", hint: "下载落盘时的冲突策略") {
                Picker("", selection: Binding(
                    get: { conflictRaw },
                    set: { conflictRaw = $0; CloudLinkSettings.conflictPolicy = CloudLinkSettings.ConflictPolicy(rawValue: $0) ?? .rename })) {
                    ForEach(CloudLinkSettings.ConflictPolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.title).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            Toggle("完成后在 Finder 中显示", isOn: Binding(
                get: { revealAfter },
                set: { revealAfter = $0; CloudLinkSettings.revealAfterDownload = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))

            Divider().opacity(0.5)

            Text("脚本与保存")
                .font(.system(size: 12, weight: .semibold))

            configRow(title: "解析脚本", hint: "LinkSwift .user.js") {
                HStack(spacing: 6) {
                    Text(scriptPath.isEmpty ? "未配置" : (scriptPath as NSString).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(scriptPath.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择…") { pickScript() }.controlSize(.mini)
                    Button("获取…") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/hmjz100/LinkSwift")!)
                    }
                    .controlSize(.mini)
                    .help("在浏览器打开 LinkSwift 项目，下载 .user.js 后点「选择…」")
                    if !scriptPath.isEmpty {
                        Button("清除") { scriptPath = ""; CloudLinkSettings.scriptPath = "" }
                            .controlSize(.mini)
                    }
                }
            }

            configRow(title: "更新源", hint: "自动更新时拉取的 .user.js 地址") {
                TextField("https://raw.githubusercontent.com/…/LinkSwift.user.js", text: Binding(
                    get: { scriptUpdateURL },
                    set: { scriptUpdateURL = $0; CloudLinkSettings.scriptUpdateURL = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            Toggle("脚本自动更新（启动时对比 @version）", isOn: Binding(
                get: { autoUpdate },
                set: { autoUpdate = $0; CloudLinkSettings.autoUpdate = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))

            configRow(title: "保存目录", hint: "下载完成落盘位置") {
                HStack(spacing: 6) {
                    Text(downloadDir)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择…") { pickDownloadDir() }.controlSize(.mini)
                    Button("打开") { NSWorkspace.shared.open(URL(fileURLWithPath: downloadDir)) }
                        .controlSize(.mini)
                }
            }

            configRow(title: "超时", hint: "秒") {
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { timeout },
                        set: { timeout = $0; CloudLinkSettings.timeout = $0 }), in: 5...120, step: 5)
                        .frame(width: 180)
                    Text("\(Int(timeout))s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            configRow(title: "下载 UA", hint: link.provider.displayName) {
                TextField("留空使用网盘默认 UA", text: Binding(
                    get: { uaOverride },
                    set: { uaOverride = $0; CloudLinkSettings.uaOverride = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func configRow<Content: View>(title: String, hint: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            content()
        }
    }

    // MARK: 支持列表

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("支持的网盘")
                .font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(CloudDriveProvider.allCases, id: \.rawValue) { provider in
                    let active = provider == link.provider
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: provider.tint))
                            .frame(width: 7, height: 7)
                        Text(provider.displayName)
                            .font(.system(size: 11, weight: active ? .semibold : .regular))
                        Spacer(minLength: 2)
                        if active {
                            Text("当前")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(nsColor: provider.tint))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            .fill(active ? Color(nsColor: provider.tint).opacity(0.10)
                                  : Theme.cardFill)
                    )
                }
            }
            Text("域名规则来自 LinkSwift v1.1.3 的 @match（AGPL-3.0）。解析失败时请先在网页解析器里登录对应网盘。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Text(link.isSharePage ? "分享页" : "非分享页")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("开始解析下载") {
                CloudLinkActions.resolve(link)
            }
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    // MARK: 选择器

    private func pickScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // .user.js / .js / .txt 都允许（LinkSwift 是单文件 UserScript）
        panel.allowedContentTypes = [.sourceCode, .text]
        panel.allowsOtherFileTypes = true
        panel.prompt = "使用"
        if panel.runModal() == .OK, let url = panel.url {
            scriptPath = url.path
            CloudLinkSettings.scriptPath = url.path
            tester.run(link: link)
        }
    }

    private func pickDownloadDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            downloadDir = url.path
            CloudLinkSettings.downloadDirectory = url.path
        }
    }
}

// MARK: - 窗口控制器

final class CloudLinkCenterController {
    static let shared = CloudLinkCenterController()

    private var window: NSWindow?

    func show(link: CloudDriveLink) {
        window?.close()
        let hosting = NSHostingView(rootView: CloudLinkCenterView(link: link))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 660),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "网盘解析 · \(link.provider.displayName)"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // v198：从触发点（链接提示窗/面板）展开整块解析中心
        WindowReveal.playInFromMouse(on: window)
        self.window = window
        Log.info("CloudLink", "解析中心已打开：\(link.provider.rawValue) \(link.url.absoluteString)")
    }
}
