import AppKit
import CryptoKit

// MARK: - 更新检查（v112；对标报告第二批「自动更新」缺口）
//
// 设计：**零第三方依赖**（Sparkle 2 需要 SPM/包依赖，与 build.sh 无包管理器的
// 构建方式不合；而 Kitnest 尚未定分发渠道）。做成「可配置 feed + 手动检查」：
//   · feed 默认空 = 功能关闭（无渠道时零开销、零打扰）；
//   · feed 指向 GitHub API `releases/latest`（或任何返回
//     {"tag_name": "...", "html_url": "..."} 的 JSON 端点）；
//   · 设置里填 feed 后，状态栏菜单「检查更新…」即可用；启动静默检查一次
//     （间隔 ≥24h，不打扰）。
// 版本比较：语义化三段数字比较（v 前缀剥离，1.2.10 > 1.2.9）。
// 用户点「忽略此版本」后记入偏好，同版本不再提示。

public final class AppUpdateChecker {

    public static let shared = AppUpdateChecker()

    private init() {}

    // MARK: - 偏好键

    private enum Keys {
        static let feedURL = "update.feedURL"
        static let ignoredVersion = "update.ignoredVersion"
        static let lastCheckAt = "update.lastCheckAt"
    }

    /// 更新 feed（GitHub releases/latest 等；空 = 关闭）
    public var feedURL: String {
        get { Preferences.shared.value(Keys.feedURL, default: "") }
        set { Preferences.shared.set(Keys.feedURL, newValue) }
    }

    /// 当前版本（Info.plist CFBundleShortVersionString）
    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - 检查

    /// 手动检查（状态栏菜单/设置入口）：无论有无更新都给反馈
    public func checkNowManual() {
        check(manual: true)
    }

    /// 启动静默检查：feed 为空跳过；距上次检查 <24h 跳过；有更新才提示
    public func checkOnLaunch() {
        guard !feedURL.isEmpty else { return }
        let last = Preferences.shared.value(Keys.lastCheckAt, default: 0.0)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check(manual: false)
    }

    private func check(manual: Bool) {
        let feed = feedURL
        guard let url = URL(string: feed) else {
            if manual { Toast.show("未配置更新源（设置 → 关于 中填写）", icon: "arrow.triangle.2.circlepath") }
            return
        }
        if manual { Toast.show("正在检查更新…", icon: "arrow.triangle.2.circlepath") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                Preferences.shared.set(Keys.lastCheckAt, Date().timeIntervalSince1970)
                guard let self else { return }
                if let error {
                    if manual {
                        Toast.show("检查更新失败：\(error.localizedDescription)",
                                   icon: "exclamationmark.triangle", isWarning: true)
                    }
                    return
                }
                guard let data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String else {
                    if manual { Toast.show("更新源返回格式不符（需要 tag_name 字段）",
                                           icon: "exclamationmark.triangle", isWarning: true) }
                    return
                }
                let latest = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
                let pageURL = (obj["html_url"] as? String) ?? feed
                let notes = (obj["body"] as? String) ?? ""
                // v116：整包更新支持（zip 资产 + 可选 sha256）
                let zipURL = (obj["zip_url"] as? String)
                    ?? (obj["download_url"] as? String)
                    ?? ((obj["assets"] as? [[String: Any]])?.first?["browser_download_url"] as? String)
                let sha = (obj["sha256"] as? String) ?? ""

                switch Self.compare(latest, self.currentVersion) {
                case .orderedDescending:
                    // 用户忽略过的版本不再提示（手动检查除外——手动=明确想看）
                    let ignored = Preferences.shared.value(Keys.ignoredVersion, default: "")
                    if !manual && ignored == latest { return }
                    self.presentUpdate(latest: latest, pageURL: pageURL, notes: notes,
                                       zipURL: zipURL, sha256: sha, manual: manual)
                default:
                    if manual {
                        Toast.show("已是最新版本（v\(self.currentVersion)）", icon: "checkmark.seal.fill")
                    }
                }
            }
        }.resume()
    }

    // MARK: - 提示

    private func presentUpdate(latest: String, pageURL: String, notes: String,
                               zipURL: String?, sha256: String, manual: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 v\(latest)"
        let canAutoInstall = !(zipURL ?? "").isEmpty
        alert.informativeText = (notes.isEmpty ? "" : String(notes.prefix(400)) + "\n\n")
            + "当前版本 v\(currentVersion)。"
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
            Preferences.shared.set(Keys.ignoredVersion, latest)
        default:
            break
        }
    }

    // MARK: - 整包更新（v116：下载 → 校验 → 解压 → 替换 /Applications → 重启）
    //
    // 用户要求「整个 APP 覆盖更新，不是只更新一部分功能」。流程：
    //   ① 下载 zip 到临时目录（feed 里给 zip_url/download_url/assets[0]）
    //   ② sha256 校验（可选；feed 里给 sha256）
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

    // MARK: - 版本比较

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
