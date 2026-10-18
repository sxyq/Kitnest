import AppKit

// MARK: - 来源应用图标缓存（官方原版行式「缩略图右下角 app 徽章」）
//
// ClipboardItem.sourceApp 存的是 bundleIdentifier（回退 localizedName）。
// 行渲染高频调用，NSWorkspace 查询按名字缓存（含 nil 命中缓存，避免反复文件探测）。

enum ClipboardAppIconCache {

    private static var cache: [String: NSImage?] = [:]

    /// 应用名 / bundleId → 应用图标
    static func icon(forAppName name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        var icon: NSImage?

        // 1) bundleIdentifier 直查（sourceApp 主存形式）
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        // 2) 运行中的应用按显示名匹配
        if icon == nil {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName == name || $0.bundleIdentifier == name
            }) {
                icon = app.icon
            }
        }
        // 3) 常见应用目录按 "名字.app" 探测（限制目录，不做全盘遍历）
        if icon == nil {
            for dir in ["/Applications", "/Applications/Utilities",
                        "/System/Applications", "/System/Applications/Utilities",
                        NSHomeDirectory() + "/Applications"] {
                let path = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    icon = NSWorkspace.shared.icon(forFile: path)
                    break
                }
            }
        }
        cache[name] = icon
        return icon
    }
}
