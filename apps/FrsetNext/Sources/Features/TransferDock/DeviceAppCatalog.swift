import AppKit
import Foundation

/// 手机上已安装应用的目录：**真实图标 + 真实名称 + 使用频率**。
///
/// 为什么要「设备端渲染」：
///   国产 App（微信/淘宝/小红书…）的 APK 资源名被混淆，`unzip -l` 里根本没有
///   `ic_launcher`；靠解析 AndroidManifest/resources.arsc 也拿不到稳定结果。
///   唯一可靠的办法是让 **PackageManager 自己渲染**：随包的 `Resources/bin/icons.dex`
///   用 `app_process` 在手机上跑（shell uid，无需安装 APK、无需 root），
///   把 `getApplicationIcon` 画成 192×192 PNG，再 `adb pull` 回来缓存。
///
/// 性能：只在**首次**为每个包拉一次图标（缓存到磁盘），一次调用可批量 60 个包。
final class DeviceAppCatalog {

    static let shared = DeviceAppCatalog()

    struct App: Identifiable, Equatable {
        let id: String          // package
        let label: String       // 真实名称（微信 / 小红书…）
        let iconPath: String?   // 本地 PNG 路径
        var icon: NSImage? { iconPath.flatMap { NSImage(contentsOfFile: $0) } }
    }

    private let cacheDir: URL
    private let labelsURL: URL
    private let queue = DispatchQueue(label: "frset.cast.appcatalog", qos: .utility)
    private let lock = NSLock()
    private var labels: [String: String] = [:]
    private var inFlight = false
    private var waiting: [([App]) -> Void] = []

    private init() {
        cacheDir = AppDirectories.sub("cast-apps")
        labelsURL = cacheDir.appendingPathComponent("labels.json")
        if let data = try? Data(contentsOf: labelsURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            labels = dict
        }
    }

    // MARK: - 读取

    /// 读取第三方应用（带图标与真实名）；结果按「使用频率 + 最近使用」排序
    func load(serial: String?, completion: @escaping ([App]) -> Void) {
        lock.lock()
        waiting.append(completion)
        if inFlight { lock.unlock(); return }
        inFlight = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let packages = self.listPackages(serial: serial)
            self.fetchMissingIcons(packages: packages, serial: serial)
            let apps = packages.map { pkg -> App in
                let icon = self.cacheDir.appendingPathComponent("\(pkg).png").path
                let hasIcon = FileManager.default.fileExists(atPath: icon)
                return App(id: pkg,
                           label: self.labels[pkg] ?? Self.shortName(pkg),
                           iconPath: hasIcon ? icon : nil)
            }
            let sorted = apps.sorted { a, b in
                let sa = CastAppUsage.score(a.id), sb = CastAppUsage.score(b.id)
                if sa != sb { return sa > sb }
                return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
            }
            DispatchQueue.main.async {
                self.lock.lock()
                let callbacks = self.waiting
                self.waiting.removeAll()
                self.inFlight = false
                self.lock.unlock()
                callbacks.forEach { $0(sorted) }
            }
        }
    }

    // MARK: - 设备交互

    private func listPackages(serial: String?) -> [String] {
        guard let adb = ScreenCastEngine.findADB() else { return [] }
        let out = Self.runADB(adb, serial: serial, args: ["shell", "pm", "list", "packages", "-3"])
        return out.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            let pkg = String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return pkg.isEmpty ? nil : pkg
        }
    }

    /// 只为「还没有图标」的包跑助手，批量 60 个一次
    private func fetchMissingIcons(packages: [String], serial: String?) {
        guard let adb = ScreenCastEngine.findADB() else { return }
        let missing = packages.filter {
            !FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("\($0).png").path)
        }
        guard !missing.isEmpty else { return }
        guard let dex = Self.bundledDex() else {
            Log.warn("Cast", "图标助手缺失（Resources/bin/icons.dex）")
            return
        }
        let remoteDex = "/data/local/tmp/frset-icons.dex"
        let remoteOut = "/data/local/tmp/frset-appicons"
        // 推送（大小不同才推）
        let localSize = (try? FileManager.default.attributesOfItem(atPath: dex.path)[.size] as? Int) ?? 0
        let remoteSize = Int(Self.runADB(adb, serial: serial,
                                         args: ["shell", "stat", "-c", "%s", remoteDex])
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        if localSize != remoteSize {
            _ = Self.runADB(adb, serial: serial, args: ["push", dex.path, remoteDex])
        }

        for batch in stride(from: 0, to: missing.count, by: 60).map({ Array(missing[$0..<min($0 + 60, missing.count)]) }) {
            let cmd = "rm -rf \(remoteOut); CLASSPATH=\(remoteDex) app_process /system/bin IconDump \(remoteOut) \(batch.joined(separator: " "))"
            let out = Self.runADB(adb, serial: serial, args: ["shell", cmd], timeout: 40)
            // 解析 "pkg\tlabel"
            for line in out.components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2, packages.contains(parts[0]) else { continue }
                labels[parts[0]] = parts[1]
            }
            // 拉回这批图标
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("frset-appicons-\(UUID().uuidString)")
            _ = Self.runADB(adb, serial: serial, args: ["pull", remoteOut, tmp.path], timeout: 60)
            if let files = try? FileManager.default.contentsOfDirectory(at: tmp,
                                                                       includingPropertiesForKeys: nil) {
                for f in files where f.pathExtension.lowercased() == "png" {
                    try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(f.lastPathComponent))
                    try? FileManager.default.moveItem(at: f,
                                                      to: cacheDir.appendingPathComponent(f.lastPathComponent))
                }
            }
            try? FileManager.default.removeItem(at: tmp)
            saveLabels()
        }
    }

    private func saveLabels() {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        try? data.write(to: labelsURL, options: .atomic)
    }

    // MARK: - 工具

    private static func bundledDex() -> URL? {
        if let u = Bundle.main.url(forResource: "icons", withExtension: "dex", subdirectory: "bin"),
           FileManager.default.fileExists(atPath: u.path) { return u }
        return nil
    }

    @discardableResult
    private static func runADB(_ adb: String, serial: String?, args: [String],
                               timeout: TimeInterval = 20) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = (serial.map { ["-s", $0] } ?? []) + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 包名兜底可读名：com.tencent.mm → Mm
    private static func shortName(_ pkg: String) -> String {
        pkg.split(separator: ".").last.map(String.init)?.capitalized ?? pkg
    }
}

// MARK: - 使用频率（简单推荐：次数 + 最近使用衰减）

enum CastAppUsage {

    private static let key = "cast.appUsage"          // [pkg: ["n": 次数, "t": 时间戳]]

    static func record(_ package: String) {
        var dict = Preferences.shared.value(key, default: [String: [String: Double]]())
        var item = dict[package] ?? ["n": 0, "t": 0]
        item["n"] = (item["n"] ?? 0) + 1
        item["t"] = Date().timeIntervalSince1970
        dict[package] = item
        Preferences.shared.set(key, dict)
    }

    /// 分数 = 次数 × 时间衰减（半衰期 14 天）；没记录过 = 0
    static func score(_ package: String) -> Double {
        let dict = Preferences.shared.value(key, default: [String: [String: Double]]())
        guard let item = dict[package] else { return 0 }
        let n = item["n"] ?? 0
        let t = item["t"] ?? 0
        guard n > 0, t > 0 else { return 0 }
        let days = max(0, (Date().timeIntervalSince1970 - t) / 86_400)
        return n * pow(0.5, days / 14.0)
    }
}
