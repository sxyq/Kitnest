import AppKit

// MARK: - 来源应用图标缓存（官方原版行式「缩略图右下角 app 徽章」）
//
// ClipboardItem.sourceApp 存的是 bundleIdentifier（回退 localizedName）。
// 行渲染高频调用，NSWorkspace 查询按名字缓存（含 nil 命中缓存，避免反复文件探测）。

enum ClipboardAppIconCache {

    // v126（性能审计 F0560）：缓存加锁 + 有界。
    // 行渲染高频调用且可能跨线程（异步 fetch 回填后重绘），裸字典并发读写是崩溃隐患；
    // 换 NSCache 自动回收（原字典无界，长期运行按来源应用数无限增长）。
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()
    /// 负缓存（查不到的应用）：避免每次行渲染都重复跑 5 个目录的 fileExists 探测
    private static let missCache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 256
        return c
    }()
    /// 应用目录探测列表（循环不变量外提，原在每次 miss 时重建数组）
    private static let probeDirectories = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]

    /// 应用名 / bundleId → 应用图标
    static func icon(forAppName name: String) -> NSImage? {
        let key = name as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard missCache.object(forKey: key) == nil else { return nil }
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
            for dir in probeDirectories {
                let path = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    icon = NSWorkspace.shared.icon(forFile: path)
                    break
                }
            }
        }
        if let icon { cache.setObject(icon, forKey: key) }
        else { missCache.setObject("", forKey: key) }
        return icon
    }
}
