import AppKit
import Combine
import Darwin
import Foundation

// ============================================================================
// 第二档：暂停闲置应用（SIGSTOP）——与第一档 purge 合并进同一个按钮
//
// 为什么要有这一档：purge 只能回收「磁盘上还有副本」的干净页，App 自己 malloc
// 出来的匿名页它碰不到。暂停进程能让这些页冷下来，系统受压时优先被压缩/换出。
//
// 四条恢复路径，缺一不可（任何一条漏掉，用户会遇到一个「点不动的 App」）：
//   ① 切回该 App（NSWorkspace.didActivateApplication）
//   ② 冻结后 30 分钟自动全部唤醒
//   ③ 我们正常退出（willTerminate → thawAll）
//   ④ 我们崩溃或被 kill -9（独立 shell watchdog 检测父进程存活 → kill -CONT）
// 另外启动时扫一遍 pidfile，处理「上次崩溃后没来得及唤醒」的残留。
//
// 判定口径（实测踩过的坑都写在这）：
//   · 只冻「有主进程」的 .app：helper 的 .app 嵌在 Contents/Frameworks/ 下，
//     冻了它用户点主 App 也恢复不了；所以主进程优先，helper 只作为附带。
//   · 主进程必须在「最近 5 分钟内没被激活过」——用户刚用过的 App 不该冻。
//   · CPU 两次采样增量为 0 才算真闲置：放音乐、下载、跑编译的会被挡掉。
//   · 常驻 ≥ 200MB：冻小的换不来多少内存，不值得承担误伤风险。
//   · 白名单（终端 / IDE / 虚拟机 / 会议 / 音视频）一律不碰。
//   · 一次最多 4 个 App。
// ============================================================================

public struct FrozenApp: Identifiable, Sendable, Equatable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    /// 冻结前的 footprint，只用于报告「共多少常驻被暂停」，不是「释放了多少」
    public let footprint: UInt64
    /// 进程启动时刻（mach absolute），用于防止 PID 复用后误唤醒别的进程
    public let startedAt: UInt64
    /// 同一个 App 下附带暂停的 helper 进程，切回该 App 时一起恢复
    public let extraPIDs: [pid_t]

    public var id: pid_t { pid }
}

@MainActor
public final class ProcessFreezer: ObservableObject {
    public static let shared = ProcessFreezer()

    /// 一次最多暂停几个 App：每多一个，误伤面就大一分
    public static let maxCount = 4
    /// 小于这个常驻量，冻了也换不来多少内存
    public static let minimumFootprint: UInt64 = 200 * 1_048_576
    /// 兜底唤醒时间
    public static let maxHoldSeconds: TimeInterval = 30 * 60
    /// 最近这段时间内被激活过的 App 不冻（用户刚用过就别动它）
    public static let activationCooldown: TimeInterval = 300
    /// 每个 App 附带暂停的 helper 上限
    public static let maxHelpers = 2

    @Published public private(set) var frozen: [FrozenApp] = []

    public var totalFootprint: UInt64 { frozen.reduce(0) { $0 + $1.footprint } }

    private var watchdogPID: pid_t?
    private var expiryTimer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?
    private var holdGeneration = 0
    /// pid → 最近一次被激活的时刻
    private var recentActivation: [pid_t: Date] = [:]

    private init() {
        startObservingActivation()
    }

    // MARK: - 冻结

    /// 暂停当前闲置的普通 App。返回被暂停的清单（可能为空）。
    public func freezeIdle(limit: Int = ProcessFreezer.maxCount) async -> [FrozenApp] {
        guard frozen.isEmpty else { return [] }   // 已经在暂停中，不叠加

        // 候选枚举必须离开主线程：proc_listpids + 逐个 proc_pidpath/proc_pid_rusage，
        // 实测在 App 刚启动时会阻塞主线程 9 秒（HANG 日志有记录）。
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let now = Date()
        let recentlyUsed = Set(recentActivation
            .filter { now.timeIntervalSince($0.value) < Self.activationCooldown }
            .map(\.key))
        let visible = ProcessFreezer.visibleWindowPIDs()
        let candidates = await Task.detached(priority: .userInitiated) {
            ProcessFreezer.collectCandidates(frontmost: frontmost,
                                             recentlyUsed: recentlyUsed,
                                             visiblePIDs: visible)
        }.value
        guard !candidates.isEmpty else {
            Log.info("内存", "没有符合条件的闲置应用")
            return []
        }

        // 两次采样间隔 0.7s，CPU 增量为 0 才算真闲置
        let first = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            cpuSeconds(candidate.pid).map { (candidate.pid, $0) }
        })
        try? await Task.sleep(nanoseconds: 700_000_000)

        var picked: [FrozenApp] = []
        for candidate in candidates where picked.count < limit {
            guard let before = first[candidate.pid], let after = cpuSeconds(candidate.pid) else { continue }
            guard after - before < 0.02 else { continue }        // 0.7 秒内用了 >20ms 就不算闲置
            guard Darwin.kill(candidate.pid, SIGSTOP) == 0 else { continue }
            picked.append(candidate)
        }
        guard !picked.isEmpty else {
            Log.info("内存", "候选 \(candidates.count) 个，但都不满足闲置条件（CPU 未归零）")
            return []
        }

        frozen = picked
        writePidFile()
        startWatchdog()
        startExpiry()
        Log.info("内存", "暂停 \(picked.count) 个闲置应用 共 \(picked.reduce(0) { $0 + $1.footprint } / 1_048_576)MB")
        return picked
    }

    // MARK: - 恢复

    public func thawAll(reason: String = "手动") {
        guard !frozen.isEmpty else { return }
        for item in frozen {
            resume(item)
        }
        Log.info("内存", "唤醒 \(frozen.count) 个应用（\(reason)）")
        frozen = []
        clearPidFile()
        stopWatchdog()
        stopExpiry()
    }

    public func thaw(pid: pid_t, reason: String = "切回") {
        guard let index = frozen.firstIndex(where: { $0.pid == pid }) else { return }
        let item = frozen[index]
        resume(item)
        frozen.remove(at: index)
        Log.info("内存", "唤醒 \(item.name)（\(reason)）")
        if frozen.isEmpty {
            clearPidFile()
            stopWatchdog()
            stopExpiry()
        } else {
            writePidFile()
        }
    }

    /// 启动时清理上次崩溃留下的冻结进程
    public func thawOrphans() {
        guard let data = try? Data(contentsOf: Self.pidFileURL),
              let saved = try? JSONDecoder().decode([SavedFreeze].self, from: data) else { return }
        var restored = 0
        for item in saved {
            let stillFrozen = pidAlive(item.pid) && startTime(item.pid) == item.startedAt
            if stillFrozen {
                Darwin.kill(item.pid, SIGCONT)
                for extra in item.extraPIDs where pidAlive(extra) {
                    Darwin.kill(extra, SIGCONT)
                }
                restored += 1
            }
        }
        try? FileManager.default.removeItem(at: Self.pidFileURL)
        if restored > 0 {
            Log.info("内存", "上次退出遗留的 \(restored) 个暂停应用已唤醒")
        }
    }

    /// 恢复一个 App 的主进程 + 附带暂停的 helper
    private func resume(_ item: FrozenApp) {
        if isSameProcess(item) {
            Darwin.kill(item.pid, SIGCONT)
        }
        for extra in item.extraPIDs where pidAlive(extra) {
            Darwin.kill(extra, SIGCONT)
        }
    }

    // MARK: - 候选筛选

    private struct ProcessInfo {
        let pid: pid_t
        let footprint: UInt64
        let startedAt: UInt64
    }

    private struct Group {
        var main: ProcessInfo?
        var helpers: [ProcessInfo] = []
    }

    /// 当前屏幕上真正有窗口的 App：它们正在被用户看着，冻结等于当面把窗口冻住。
    /// 实测 QQ / 微信 / 浏览器都靠这条躲过（它们都有可见窗口）。
    nonisolated private static func visibleWindowPIDs() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result = Set<pid_t>()
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
                result.insert(pid)
            }
        }
        return result
    }

    /// 在后台线程收集候选。
    ///
    /// 只用 proc_* 系列接口（proc_listpids / proc_pidpath / proc_pid_rusage），
    /// **不碰 NSWorkspace.runningApplications**：那个数组在后台线程取会返回空，
    /// 实测导致「一个都没冻上」。NSWorkspace 只在主线程取一次前台 pid。
    nonisolated private static func collectCandidates(
        frontmost: pid_t?, recentlyUsed: Set<pid_t>, visiblePIDs: Set<pid_t>) -> [FrozenApp] {
        var groups: [String: Group] = [:]

        for pid in ProcessMemoryInspector.allProcessIdentifiers() {
            guard pid > 0, pid != getpid(), pid != frontmost else { continue }
            guard !recentlyUsed.contains(pid) else { continue }
            guard let path = ProcessMemoryInspector.executablePath(of: pid) else { continue }
            guard let bundlePath = ProcessMemoryInspector.applicationBundlePath(containing: path) else { continue }
            guard let usage = ProcessMemoryInspector.resourceUsage(of: pid) else { continue }

            // 路径层级判定（实测踩过的坑）：
            //   主进程      /Applications/Edge.app/Contents/MacOS/Edge
            //   helper .app /Applications/Edge.app/Contents/Frameworks/…/Edge Helper (Renderer).app/Contents/MacOS/…
            //                ↑ helper 自己也是 .app bundle，路径里同样有 ".app/Contents/MacOS/"，
            //                  只用 contains 判断会把 helper 当主进程。
            //   裸工具      /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
            //                ↑ 既不是主进程也不是 helper app，直接忽略。
            let components = path.split(separator: "/")
            let appIndices = components.indices.filter { components[$0].hasSuffix(".app") }
            guard let first = appIndices.first else { continue }
            let isMain = appIndices.count == 1
                && components.indices.contains(first + 2)
                && components[first + 1] == "Contents"
                && components[first + 2] == "MacOS"
            let isHelperApp = appIndices.count > 1
            guard isMain || isHelperApp else { continue }
            // 主进程当前在屏幕上露着 = 用户正看着它，冻结等于当面把窗口冻住
            if isMain && visiblePIDs.contains(pid) { continue }

            let info = ProcessInfo(pid: pid,
                                   footprint: usage.ri_phys_footprint,
                                   startedAt: usage.ri_proc_start_abstime)
            var group = groups[bundlePath] ?? Group()
            if isMain {
                if group.main == nil || info.footprint > group.main!.footprint {
                    group.main = info
                }
            } else {
                group.helpers.append(info)
            }
            groups[bundlePath] = group
        }

        var result: [FrozenApp] = []
        var rejected = 0
        for (bundlePath, group) in groups {
            // 没有主进程的 .app（纯 helper）一律不冻：用户点不到它，也恢复不了
            guard let main = group.main else { rejected += 1; continue }
            let url = URL(fileURLWithPath: bundlePath)
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let bundleID = bundle?.bundleIdentifier
            guard !isProtected(bundleID: bundleID, name: name) else { rejected += 1; continue }
            guard main.footprint >= minimumFootprint else { rejected += 1; continue }

            let extras = group.helpers
                .sorted { $0.footprint > $1.footprint }
                .prefix(maxHelpers)
                .map(\.pid)
            result.append(FrozenApp(pid: main.pid, name: name, bundleID: bundleID,
                                    footprint: main.footprint, startedAt: main.startedAt,
                                    extraPIDs: extras))
        }
        Log.info("内存", "候选收集：分组 \(groups.count) 个 合格 \(result.count) 个 剔除 \(rejected) 个")
        return result.sorted { $0.footprint > $1.footprint }
    }

    /// 不能暂停的东西：系统壳、终端、IDE、虚拟机、会议和音视频
    nonisolated private static func isProtected(bundleID: String?, name: String?) -> Bool {
        let id = (bundleID ?? "").lowercased()
        if id == Bundle.main.bundleIdentifier?.lowercased() { return true }
        if id.hasPrefix("com.sxyq.") { return true }

        let protectedIDs: Set<String> = [
            "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
            "com.apple.controlcenter", "com.apple.notificationcenterui",
            "com.apple.windowmanager", "com.apple.loginwindow",
            "com.apple.activitymonitor", "com.apple.screensaver.engine",
            "com.apple.securityagent", "com.apple.usernotificationcenter",
            "com.apple.spotlight", "com.apple.systempreferences",
            // 宿主 App（就是用户正在用它跟我们对话的那个）：冻住它界面会直接卡死，
            // 而它是菜单栏应用、没有可见窗口，「屏幕上有窗口」那条规则拦不住。
            "com.tencent.workbuddy.mac",
        ]
        if protectedIDs.contains(id) { return true }

        // 输入法：冻住就没法打字，比少冻一个 App 严重得多
        if id.contains("inputmethod") || id.contains("keyboard") { return true }

        // 名字里带这些词的一律不碰：终端 / 编辑器 / 虚拟机 / 会议 / 音视频 / 输入法
        let keywords = [
            "terminal", "iterm", "warp", "ghostty", "alacritty", "kitty", "hyper",
            "xcode", "visual studio", "code", "cursor", "zed", "sublime", "textmate",
            "bbedit", "nova", "intellij", "pycharm", "goland", "webstorm", "phpstorm",
            "rider", "clion", "datagrip", "android studio",
            "parallels", "vmware", "virtualbox", "utm", "docker", "orbstack", "podman",
            "zoom", "teams", "tencent meeting", "腾讯会议", "feishu", "飞书",
            "dingtalk", "钉钉", "facetime", "wechat", "微信", "qq", "discord",
            "slack", "skype", "obs", "quicktime", "voice memo", "语音备忘录",
            "logic pro", "garageband", "audacity", "ableton", "music", "podcasts",
            "spotify", "网易云音乐", "qq音乐", "screen sharing", "teamviewer",
            "anydesk", "jump desktop", "activity monitor", "installer",
            "输入法", "keyboard",
        ]
        let lowered = (name ?? "").lowercased()
        return keywords.contains { lowered.contains($0) }
    }

    // MARK: - 进程状态

    private func cpuSeconds(_ pid: pid_t) -> Double? {
        guard let usage = ProcessMemoryInspector.resourceUsage(of: pid) else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = usage.ri_user_time &+ usage.ri_system_time
        return Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private func pidAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func startTime(_ pid: pid_t) -> UInt64? {
        ProcessMemoryInspector.resourceUsage(of: pid)?.ri_proc_start_abstime
    }

    private func isSameProcess(_ item: FrozenApp) -> Bool {
        pidAlive(item.pid) && startTime(item.pid) == item.startedAt
    }

    // MARK: - 定时解冻

    private func startExpiry() {
        stopExpiry()
        holdGeneration += 1
        let generation = holdGeneration
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.maxHoldSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.holdGeneration == generation else { return }
            self.thawAll(reason: "超时 30 分钟")
        }
        timer.resume()
        expiryTimer = timer
    }

    private func stopExpiry() {
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    // MARK: - 激活监听：记录最近用过 + 切回即唤醒

    private func startObservingActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recentActivation[app.processIdentifier] = Date()
                // 只留最近 10 分钟的记录，防止字典无限增长
                let cutoff = Date().addingTimeInterval(-600)
                self.recentActivation = self.recentActivation.filter { $0.value > cutoff }
                self.thaw(pid: app.processIdentifier)
            }
        }
    }

    // MARK: - 崩溃兜底 watchdog

    /// 独立 shell 每 2 秒 check 一次父进程；我们被 kill -9 也会在 2 秒内恢复所有 App。
    /// 用 posix_spawn 而不是 Process：App 里 Process.run() 失败过一次（被 try? 吞了），
    /// 这层是最后的安全网，不能有任何静默失败。
    private func startWatchdog() {
        stopWatchdog()
        let pids = frozen.flatMap { item -> [pid_t] in [item.pid] + item.extraPIDs }
            .map(String.init).joined(separator: " ")
        guard !pids.isEmpty else { return }
        let parent = getpid()
        let script = """
        while kill -0 \(parent) 2>/dev/null; do sleep 2; done
        kill -CONT \(pids) 2>/dev/null
        """
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"), strdup("-c"), strdup(script), nil,
        ]
        defer { for pointer in argv { if let pointer = pointer { free(pointer) } } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, "/bin/sh", nil, nil, &argv, environ)
        if rc == 0 {
            watchdogPID = child
            Log.info("内存", "watchdog 已启动 pid=\(child)")
        } else {
            Log.warn("内存", "watchdog 启动失败 rc=\(rc)")
        }
    }

    private func stopWatchdog() {
        if let watchdogPID {
            Darwin.kill(watchdogPID, SIGTERM)
            self.watchdogPID = nil
        }
    }

    // MARK: - pidfile

    private struct SavedFreeze: Codable {
        let pid: pid_t
        let startedAt: UInt64
        let extraPIDs: [pid_t]
    }

    private static var pidFileURL: URL {
        // 走 AppDirectories：录制演示时 KITNEST_DATA_DIR 会把它指到隔离目录，
        // 否则演示用的冻结记录会写进真实数据。
        AppDirectories.base.appendingPathComponent("frozen-pids.json")
    }

    private func writePidFile() {
        let saved = frozen.map {
            SavedFreeze(pid: $0.pid, startedAt: $0.startedAt, extraPIDs: $0.extraPIDs)
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: Self.pidFileURL)
    }

    private func clearPidFile() {
        try? FileManager.default.removeItem(at: Self.pidFileURL)
    }
}
