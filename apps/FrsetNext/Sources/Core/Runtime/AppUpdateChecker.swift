import AppKit
import CryptoKit
import UserNotifications

// MARK: - 在线更新（v201 / 2026-11-04）
//
// 分发通道：124 公网边缘的 `calorieai.sxyq27.online/kitnest/`（复用 CalorieAI 官网与
// 更新服务的域名、证书和限流配置，无需新 DNS）。自签 FrsetDev 且无 aps-environment，
// **没有 APNs 远程推送能力**，因此「推送」= 客户端启动 + 每 6h 轮询清单 + 本地通知/状态栏提示。
//
// 版本口径（重要）：对外显示版本 `CFBundleShortVersionString` 固定 1.0.0（AGENTS 铁律），
// 所以**不能用语义化版本比较**，一律用 `CFBundleVersion` 内部 build 号（当前 1，每次发版 +1）。
// 忽略版本、已通知版本、WhatsNew 已读版本都按 build 记账，避免 1.0.0 永不变化导致反复提示。
//
// feed 格式（docs/00-总览/工程全图.md §5.7）：
//   build / versionName / minBuild / force / zipUrl / size / sha256 /
//   releaseNotes / whatsNew{added,improved,fixed} / pageUrl / publishedAt
// 兼容旧的 GitHub 风格 `tag_name` / `html_url` / `body` / `zip_url`。
// 整包替换逻辑沿用 v116（下载 → sha256 → 解压 → 备份 → 覆盖 → 重启）。

public final class AppUpdateChecker {

    public static let shared = AppUpdateChecker()

    /// 官方更新清单；用户仍可在 设置 → 关于 覆盖（清空即回到默认）
    public static let defaultFeedURL = "https://calorieai.sxyq27.online/kitnest/stable/latest.json"

    /// 清单更新后广播（WhatsNew 与状态栏用）
    public static let feedDidUpdateNotification = Notification.Name("frset.update.feedDidUpdate")

    private init() {}

    // MARK: - 偏好键

    private enum Keys {
        static let feedURL = "update.feedURL"            // 用户覆盖；空 = 用默认源
        static let ignoredBuild = "update.ignoredBuild"
        static let lastCheckAt = "update.lastCheckAt"
        static let cachedFeed = "update.cachedFeedJSON"  // 供 WhatsNew 离线读取
        static let availableBuild = "update.availableBuild"
        static let notifiedBuild = "update.notifiedBuild"
    }

    public var feedURL: String {
        get {
            let override = Preferences.shared.value(Keys.feedURL, default: "")
            return override.isEmpty ? Self.defaultFeedURL : override
        }
        set { Preferences.shared.set(Keys.feedURL, newValue == Self.defaultFeedURL ? "" : newValue) }
    }

    /// 对外显示版本（固定 1.0.0，仅用于展示）
    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 内部构建号：更新比较的唯一基准
    public var currentBuild: Int {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return Int(raw) ?? 1
    }

    public var availableBuild: Int { Preferences.shared.value(Keys.availableBuild, default: 0) }
    public var hasUpdate: Bool { availableBuild > currentBuild }

    /// 最近一次拉到的发布清单（WhatsNew 从中取 releaseNotes / 分组条目）
    public var cachedFeed: [String: Any]? {
        let raw = Preferences.shared.value(Keys.cachedFeed, default: "")
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private var pollTimer: Timer?

    // MARK: - 检查

    /// 手动检查（状态栏菜单 / 设置入口）：无论有无更新都给反馈
    public func checkNowManual() { check(manual: true) }

    /// 启动检查 + 常驻轮询（6h）。启动必查一次，清单只有几百字节。
    public func checkOnLaunch() {
        startPolling()
        check(manual: false)
    }

    private func startPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer?.invalidate()
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                self?.check(manual: false)
            }
        }
    }

    private func check(manual: Bool) {
        let feed = feedURL
        guard let url = URL(string: feed) else {
            if manual { Toast.show("更新源地址无效（设置 → 关于）", icon: "arrow.triangle.2.circlepath") }
            return
        }
        if manual { Toast.show("正在检查更新…", icon: "arrow.triangle.2.circlepath") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                Preferences.shared.set(Keys.lastCheckAt, Date().timeIntervalSince1970)
                if let error {
                    if manual {
                        Toast.show("检查更新失败：\(error.localizedDescription)",
                                   icon: "exclamationmark.triangle", isWarning: true)
                    }
                    return
                }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    if manual { Toast.show("更新源返回格式不符（需要 build 字段）",
                                           icon: "exclamationmark.triangle", isWarning: true) }
                    return
                }

                let latestBuild = Self.parseBuild(obj, currentBuild: self.currentBuild)
                Log.info("Update", "清单已拉取：远端 build=\(latestBuild) / 当前 build=\(self.currentBuild) / 源 \(feed)")
                // 先落缓存再广播：WhatsNew 与状态栏总能读到最新说明（含离线）
                Preferences.shared.set(Keys.cachedFeed, String(data: data, encoding: .utf8) ?? "")
                Preferences.shared.set(Keys.availableBuild, latestBuild)
                NotificationCenter.default.post(name: Self.feedDidUpdateNotification, object: nil)

                let notes = (obj["releaseNotes"] as? String) ?? (obj["body"] as? String) ?? ""
                let pageURL = (obj["pageUrl"] as? String) ?? (obj["html_url"] as? String) ?? feed
                let zipURL = (obj["zipUrl"] as? String)
                    ?? (obj["zip_url"] as? String)
                    ?? (obj["download_url"] as? String)
                    ?? ((obj["assets"] as? [[String: Any]])?.first?["browser_download_url"] as? String)
                let sha = (obj["sha256"] as? String) ?? ""

                if latestBuild > self.currentBuild {
                    let ignored = Preferences.shared.value(Keys.ignoredBuild, default: 0)
                    let alreadyNotified = Preferences.shared.value(Keys.notifiedBuild, default: 0) == latestBuild
                    // 轮询不反复打扰：同一 build 只主动提示一次；手动检查永远可看
                    guard manual || (ignored != latestBuild && !alreadyNotified) else { return }
                    Preferences.shared.set(Keys.notifiedBuild, latestBuild)
                    self.notifyUpdate(build: latestBuild, notes: notes)
                    self.presentUpdate(build: latestBuild,
                                       versionName: (obj["versionName"] as? String) ?? self.currentVersion,
                                       pageURL: pageURL, notes: notes,
                                       zipURL: zipURL, sha256: sha, manual: manual)
                } else if manual {
                    Toast.show("已是最新版本（v\(self.currentVersion) · build \(self.currentBuild)）",
                               icon: "checkmark.seal.fill")
                }
            }
        }.resume()
    }

    /// build 字段优先；兼容旧的 tag_name（有新 tag 视为 current+1）
    private static func parseBuild(_ obj: [String: Any], currentBuild: Int) -> Int {
        if let n = obj["build"] as? Int { return n }
        if let s = obj["build"] as? String, let n = Int(s) { return n }
        if let tag = obj["tag_name"] as? String {
            let t = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
            return compare(t, Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0") == .orderedDescending
                ? currentBuild + 1 : currentBuild
        }
        return currentBuild
    }

    // MARK: - 通知

    /// 本地通知优先；未授权 / 菜单栏环境不弹横幅时降级为 Toast + 状态栏红点
    private func notifyUpdate(build: Int, notes: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    let content = UNMutableNotificationContent()
                    content.title = "Kitnest 有新版本（build \(build)）"
                    content.body = notes.isEmpty ? "打开状态栏菜单查看更新内容" : String(notes.prefix(120))
                    content.sound = .default
                    let request = UNNotificationRequest(identifier: "kitnest-update-\(build)",
                                                        content: content, trigger: nil)
                    center.add(request, withCompletionHandler: nil)
                } else {
                    Toast.show("发现新版本 build \(build) · 点状态栏「检查更新」查看",
                               icon: "arrow.down.circle")
                }
            }
        }
    }

    // MARK: - 提示

    private func presentUpdate(build: Int, versionName: String, pageURL: String, notes: String,
                               zipURL: String?, sha256: String, manual: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 v\(versionName)（build \(build)）"
        let canAutoInstall = !(zipURL ?? "").isEmpty
        alert.informativeText = (notes.isEmpty ? "" : String(notes.prefix(400)) + "\n\n")
            + "当前 v\(currentVersion) · build \(currentBuild)。"
            + (canAutoInstall ? "\n点「立即更新」将下载整包并替换本应用（自动保留上一版备份）。" : "")
        var buttons: [String] = []
        if canAutoInstall { buttons.append("立即更新") }
        buttons.append("前往下载")
        buttons.append("忽略此版本")
        buttons.append("下次再说")
        buttons.forEach { alert.addButton(withTitle: $0) }
        let resp = alert.runModal()
        let idx = resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let chosen = (idx >= 0 && idx < buttons.count) ? buttons[idx] : "下次再说"
        switch chosen {
        case "立即更新":
            if let zipURL, let url = URL(string: zipURL) {
                installUpdate(zipURL: url, expectedSHA256: sha256.isEmpty ? nil : sha256)
            }
        case "前往下载":
            if let url = URL(string: pageURL) { NSWorkspace.shared.open(url) }
        case "忽略此版本":
            Preferences.shared.set(Keys.ignoredBuild, build)
        default:
            break
        }
    }

    // MARK: - 整包更新（v116：下载 → 校验 → 解压 → 替换 /Applications → 重启）
    //
    // 用户要求「整个 APP 覆盖更新，不是只更新一部分功能」。流程：
    //   ① 下载 zip 到临时目录（feed 里给 zipUrl）
    //   ② sha256 校验
    //   ③ ditto 解压，找到 .app
    //   ④ 写一个替换脚本（备份旧版 → 覆盖 → 去隔离属性 → 重开），脱离进程执行
    //   ⑤ 本应用退出，脚本接管
    // 风险控制：旧版本一定先备份成 /Applications/Kitnest.app.bak，失败可手动回滚。

    public func installUpdate(zipURL: URL, expectedSHA256: String?) {
        Toast.show("开始下载更新…", icon: "arrow.down.circle")
        URLSession.shared.downloadTask(with: zipURL) { tmp, _, error in
            guard let tmp else {
                DispatchQueue.main.async {
                    Toast.show("下载失败：\(error?.localizedDescription ?? "未知错误")",
                               icon: "exclamationmark.triangle", isWarning: true)
                }
                return
            }
            do {
                let data = try Data(contentsOf: tmp)
                if let expectedSHA256 {
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest.lowercased() == expectedSHA256.lowercased() else {
                        DispatchQueue.main.async {
                            Toast.show("校验失败：sha256 不匹配，已中止更新",
                                       icon: "exclamationmark.shield", isWarning: true)
                        }
                        return
                    }
                }
                let work = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("frset-update-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try data.write(to: zip)

                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.appendingPathComponent("payload").path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0 else {
                    DispatchQueue.main.async { Toast.show("解压失败，已中止", icon: "exclamationmark.triangle", isWarning: true) }
                    return
                }
                // 找到 .app
                let payload = work.appendingPathComponent("payload")
                let appName = (try? FileManager.default.contentsOfDirectory(atPath: payload.path))?
                    .first { $0.hasSuffix(".app") }
                guard let appName else {
                    DispatchQueue.main.async { Toast.show("更新包里没有 .app", icon: "exclamationmark.triangle", isWarning: true) }
                    return
                }
                let newApp = payload.appendingPathComponent(appName)

                // 替换脚本：等本进程退出 → 备份 → 覆盖 → 去隔离 → 重开
                let script = """
                #!/bin/sh
                sleep 2
                BACKUP="/Applications/\(appName).bak"
                rm -rf "$BACKUP"
                if [ -d "/Applications/\(appName)" ]; then
                  mv "/Applications/\(appName)" "$BACKUP" || exit 1
                fi
                /usr/bin/ditto "\(newApp.path)" "/Applications/\(appName)" || {
                  rm -rf "/Applications/\(appName)"
                  mv "$BACKUP" "/Applications/\(appName)"
                  exit 1
                }
                /usr/bin/xattr -dr com.apple.quarantine "/Applications/\(appName)" 2>/dev/null
                open "/Applications/\(appName)"
                """
                let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("frset-swap.sh")
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: scriptURL.path)
                let runner = Process()
                runner.executableURL = URL(fileURLWithPath: "/bin/sh")
                runner.arguments = [scriptURL.path]
                try runner.run()
                DispatchQueue.main.async {
                    Toast.show("更新就绪，正在重启完成替换…", icon: "arrow.triangle.2.circlepath")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    Toast.show("更新失败：\(error.localizedDescription)",
                               icon: "exclamationmark.triangle", isWarning: true)
                }
            }
        }.resume()
    }

    // MARK: - 版本比较（旧 tag_name 兼容路径仍用）

    /// 语义化比较：逐段数字比（缺失段按 0）；非数字段视为相等跳过
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }
}
