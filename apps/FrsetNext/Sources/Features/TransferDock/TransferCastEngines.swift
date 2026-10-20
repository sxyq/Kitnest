import AppKit
import Combine

// MARK: - 传输与投屏 引擎层（v103 重构，2026-10-21）
//
// 需求：中转站彻底重构——旧 OPPO 云端桥接 / 局域网扫码直传全部下线；
//   传输走「原生互传」路线（omdrop-owl 的思路：对端零安装——macOS 上即
//   系统级隔空投送 NSSharingService，iPhone 零安装收发）；
//   投屏走「AndroMeld 同实现方式」（商业闭源不可接，其底座=scrcpy 式
//   ADB 镜像——我们按同路线自研，Android 侧同样零安装，ADB 授权即用）。
// 方案与调研结论见 docs/传输与投屏-重构方案.md。

// MARK: ① 隔空投送发送（NSSharingService 系统面板，对端 iPhone 零安装）

public enum AirDropSendEngine {

    /// 系统空投服务是否可用（老系统/被 MDM 禁用时为 false）
    public static var isAvailable: Bool {
        NSSharingService(named: .sendViaAirDrop) != nil
    }

    /// 调起系统「隔空投送」面板发送文件（在给定视图锚点弹出）
    /// - Returns: 是否成功发起（服务不可用/无文件时 false 并提示）
    @discardableResult
    public static func send(urls: [URL], relativeTo view: NSView? = nil) -> Bool {
        guard !urls.isEmpty else {
            Toast.show("没有可发送的文件", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            Toast.show("本机隔空投送不可用（检查系统设置）", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        service.perform(withItems: urls)
        Log.info("Transfer", "隔空投送发起：\(urls.count) 个文件")
        return true
    }
}

// MARK: ② 隔空投送接收（系统落盘 ~/Downloads → 自动入库本地暂存）

/// macOS 系统收空投默认落 ~/Downloads。监听新增完整文件 → 回调入库。
public final class AirDropReceiveWatcher {
    public static let shared = AirDropReceiveWatcher()

    /// 收到新文件（主线程回调）
    public var onFileReceived: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.frset.airdrop.receive")
    private var seen: Set<String> = []
    private var started = false

    private var downloadsDir: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    public func start() {
        guard !started else { return }
        started = true
        let dir = downloadsDir
        // 基线：已存在的文件不触发
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.warn("Transfer", "Downloads 目录监听打开失败")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        Log.info("Transfer", "空投接收监听已启动（~/Downloads）")
    }

    public func stop() {
        source?.cancel()
        source = nil
        started = false
    }

    /// 扫描新落盘的完整文件（跳过 .download 等未完成文件）
    private func scan() {
        let dir = downloadsDir
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where !seen.contains(name) {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  !isDir.boolValue,
                  !name.hasSuffix(".download"),
                  !name.hasPrefix(".") else { continue }
            seen.insert(name)
            // 稳定性小等待（拷贝刚完成的文件偶尔仍在收尾）
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                Log.info("Transfer", "空投接收：\(name)")
                DispatchQueue.main.async { self?.onFileReceived?(url) }
            }
        }
    }
}

// MARK: ③ 投屏（scrcpy 引擎——AndroMeld 同实现路线：ADB + 视频流镜像）

public enum ScreenCastEngine {

    /// scrcpy 可执行文件探测（PATH / Homebrew / 手动放置）
    public static func findScrcpy() -> String? {
        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
            "/usr/bin/scrcpy",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // PATH 查找
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "scrcpy"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }

    /// adb 可执行文件探测
    public static func findADB() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// 已连接设备列表（serial\tstate 每行；未装 adb 返回 nil）
    public static func connectedDevices() -> [(serial: String, state: String)]? {
        guard let adb = findADB() else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adb)
        task.arguments = ["devices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        var result: [(String, String)] = []
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 {
                result.append((String(parts[0]), String(parts[1])))
            }
        }
        return result
    }

    /// 启动投屏镜像（scrcpy 独立进程；等 ADB 连真机后实测调参）
    /// - Parameter serial: 指定设备（多设备时必填）
    @discardableResult
    public static func startMirror(serial: String? = nil,
                                   maxSize: Int = 1280,
                                   bitRateMbps: Int = 8) -> Bool {
        guard let scrcpy = findScrcpy() else {
            Toast.show("未找到 scrcpy（brew install scrcpy 后重试）",
                       icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: scrcpy)
        var args = ["--max-size", "\(maxSize)", "--video-bit-rate", "\(bitRateMbps)M",
                    "--stay-awake", "--no-power-on"]
        if let serial { args += ["--serial", serial] }
        task.arguments = args
        do {
            try task.run()
            Log.info("Transfer", "投屏启动：scrcpy \(args.joined(separator: " "))")
            Toast.show("投屏已启动（镜像窗）", icon: "display")
            return true
        } catch {
            Toast.show("投屏启动失败：\(error.localizedDescription)",
                       icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
    }
}
