import Foundation
import Darwin

// MARK: - 分天日志归档（v84，2026-10-20 用户需求）
//
// 需求：记录最近 3 天的运行/卡死诊断日志，自动清理，控制体积。
//
// 目录：~/Library/Application Support/FrsetNext/logs/YYYY-MM-DD.log
// 保留：3 天（启动时 + 每 6 小时清理一次，按文件修改时间）
// 上限：单文件 4MB（超出后丢弃 debug，仅保留 info 及以上）
//
// 卡死诊断（解决「设置界面点两下就卡死」这类无堆栈问题）：
//   · 主线程心跳：CFRunLoopObserver 每轮 runloop 刷新时间戳；
//   · 后台看门狗 0.5s 检查一次，超过 2s 未刷新 → 记 HANG（含阻塞时长与最近操作面包屑）；
//   · 恢复时记一行 RECOVER（累计阻塞时长），据此判断是否真卡死及卡在哪个页面；
//   · 每 60s 记一条 STATUS（footprint/线程数），用于内存与存储占用评估。
//
// 面包屑：UI 关键动作（切设置页、开面板、切换模块）调 Log.breadcrumb，
// HANG 时把最近 5 条附上——卡死前最后一步一眼可见。

public final class LogArchive {

    public static let shared = LogArchive()

    /// 日志目录
    public let directory: URL
    private let fileLock = NSLock()
    private let keepDays = 3
    private let maxFileSize = 4 * 1024 * 1024
    private var currentDay = ""
    private var handle: FileHandle?

    // 卡死看门狗状态（跨线程访问走 lock）
    private let beatLock = NSLock()
    private var lastBeat = CFAbsoluteTimeGetCurrent()
    private var hangStartedAt: CFAbsoluteTime?
    private var lastHangLogAt: CFAbsoluteTime = 0
    private var breadcrumbs: [String] = []
    private var watchdog: DispatchSourceTimer?
    private var statusTimer: DispatchSourceTimer?
    private var cleanupTimer: DispatchSourceTimer?
    private var runLoopObserver: CFRunLoopObserver?
    private var started = false
    /// 启动时刻：前 10s 是预热期——bootstrap 在主线程同步跑模块启动，
    /// 期间 runloop 不 tick，若照常判定会误报「主线程阻塞 18s」（实测）。
    private var bootAt = CFAbsoluteTimeGetCurrent()
    private let warmupSeconds: CFAbsoluteTime = 10

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("FrsetNext/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanupOldLogs()
    }

    // MARK: 生命周期

    /// 启动归档（幂等）：心跳 + 看门狗 + 状态快照 + 定时清理
    public func start() {
        guard !started else { return }
        started = true
        bootAt = CFAbsoluteTimeGetCurrent()
        beatLock.lock()
        lastBeat = bootAt
        beatLock.unlock()

        // 主线程心跳：runloop 空闲/事件前后各刷一次（阻塞时自然停摆）
        let activities: CFRunLoopActivity = [.beforeWaiting, .afterWaiting, .beforeTimers]
        runLoopObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities.rawValue, true, 0
        ) { [weak self] _, _ in
            guard let self else { return }
            self.beatLock.lock()
            self.lastBeat = CFAbsoluteTimeGetCurrent()
            self.beatLock.unlock()
        }
        if let obs = runLoopObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        }

        // 看门狗（0.5s；首 3s 容忍启动期布局）
        let wd = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        wd.schedule(deadline: .now() + 3, repeating: 0.5)
        wd.setEventHandler { [weak self] in self?.checkHang() }
        wd.resume()
        watchdog = wd

        // 状态快照（60s）
        let st = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        st.schedule(deadline: .now() + 60, repeating: 60)
        st.setEventHandler { [weak self] in self?.appendStatus() }
        st.resume()
        statusTimer = st

        // 旧日志清理（6h）
        let ct = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        ct.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600)
        ct.setEventHandler { [weak self] in self?.cleanupOldLogs() }
        ct.resume()
        cleanupTimer = ct

        appendRaw(level: "INFO", tag: "LogArchive",
                  message: "日志归档启动（保留 \(keepDays) 天，单文件上限 \(maxFileSize / 1024 / 1024)MB，目录 \(directory.path)）")
    }

    public func stop() {
        watchdog?.cancel(); watchdog = nil
        statusTimer?.cancel(); statusTimer = nil
        cleanupTimer?.cancel(); cleanupTimer = nil
        if let obs = runLoopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), obs, .commonModes)
            runLoopObserver = nil
        }
        fileLock.lock()
        try? handle?.close()
        handle = nil
        fileLock.unlock()
        started = false
    }

    // MARK: 写入

    /// 追加一条日志（Log.write 的唯一落点）
    public func append(level: String, tag: String, message: String) {
        appendRaw(level: level, tag: tag, message: message)
    }

    /// 面包屑（卡死时回溯最近操作；每条同时进日志）
    public func pushBreadcrumb(_ text: String) {
        beatLock.lock()
        breadcrumbs.append(text)
        if breadcrumbs.count > 20 { breadcrumbs.removeFirst(breadcrumbs.count - 20) }
        beatLock.unlock()
        appendRaw(level: "DEBUG", tag: "Crumb", message: text)
    }

    // MARK: 卡死检测

    private func checkHang() {
        // 启动预热期：bootstrap 同步跑模块启动，runloop 不 tick 属正常，不判定阻塞
        if CFAbsoluteTimeGetCurrent() - bootAt < warmupSeconds {
            beatLock.lock()
            lastBeat = CFAbsoluteTimeGetCurrent()
            beatLock.unlock()
            return
        }

        beatLock.lock()
        let stalled = CFAbsoluteTimeGetCurrent() - lastBeat
        let crumbs = breadcrumbs.suffix(5).joined(separator: " → ")
        let startedAt = hangStartedAt
        beatLock.unlock()

        if stalled > 2.0 {
            let now = CFAbsoluteTimeGetCurrent()
            let shouldLog: Bool
            if startedAt == nil {
                beatLock.lock(); hangStartedAt = now - stalled; beatLock.unlock()
                shouldLog = true
            } else {
                // 阻塞期间每 5s 记一次，避免刷屏
                shouldLog = now - lastHangLogAt >= 5
            }
            if shouldLog {
                lastHangLogAt = now
                let mem = Self.footprintMB()
                appendRaw(level: "ERROR", tag: "HANG",
                          message: String(format: "主线程阻塞 %.1fs（footprint %.0fMB）最近操作：%@",
                                          stalled, mem, crumbs.isEmpty ? "（无）" : crumbs))
            }
        } else if let start = startedAt {
            beatLock.lock(); hangStartedAt = nil; beatLock.unlock()
            let total = CFAbsoluteTimeGetCurrent() - start
            appendRaw(level: "WARN", tag: "HANG",
                      message: String(format: "主线程已恢复（累计阻塞 %.1fs）", total))
        }
    }

    // MARK: 状态快照

    private func appendStatus() {
        let mem = Self.footprintMB()
        let threads = Self.threadCount()
        let uptime = Int(ProcessInfo.processInfo.systemUptime)
        appendRaw(level: "INFO", tag: "STATUS",
                  message: String(format: "footprint=%.0fMB threads=%d uptime=%ds", mem, threads, uptime))
    }

    /// 当前进程 footprint（MB，与活动监视器「内存」口径一致）
    public static func footprintMB() -> Double {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { ptr -> Bool in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound) == 0
            }
        }
        guard ok else { return 0 }
        return Double(info.ri_phys_footprint) / 1024.0 / 1024.0
    }

    /// 当前进程线程数
    public static func threadCount() -> Int {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let r = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        return r > 0 ? Int(info.pti_threadnum) : 0
    }


    // MARK: 文件管理

    private func appendRaw(level: String, tag: String, message: String) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: Date())
        df.dateFormat = "HH:mm:ss.SSS"
        let ts = df.string(from: Date())
        let line = "[\(ts)][\(level)][\(tag)] \(message)\n"

        fileLock.lock()
        defer { fileLock.unlock() }
        // 按天切换文件
        if day != currentDay || handle == nil {
            try? handle?.close()
            handle = nil
            currentDay = day
            let url = directory.appendingPathComponent("\(day).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
                // 新文件首行写保留策略，便于用户自查
                let header = "# FrsetNext 运行日志（保留 \(keepDays) 天，自动清理）\n"
                if let h = try? FileHandle(forWritingTo: url) {
                    h.write(Data(header.utf8))
                    try? h.close()
                }
            }
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let fh = handle else { return }
        // 单文件上限：超限后仅保留非 debug
        let size = (try? fh.seekToEnd()) ?? 0
        if size > UInt64(maxFileSize), level == "DEBUG" { return }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(line.utf8))
    }

    /// 清理超过保留期的日志文件
    public func cleanupOldLogs() {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for f in files where f.pathExtension == "log" {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if modified < cutoff {
                if (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
            }
        }
        if removed > 0 {
            appendRaw(level: "INFO", tag: "LogArchive", message: "清理 \(removed) 个超过 \(keepDays) 天的日志文件")
        }
    }

    // MARK: 卡死取证辅助（供排障时输出最近日志摘要）

    /// 返回最近 N 行日志（当前文件尾部），供设置页「导出诊断」使用
    public func tail(lines: Int = 200) -> String {
        fileLock.lock()
        defer { fileLock.unlock() }
        let url = directory.appendingPathComponent("\(currentDay).log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }
}
