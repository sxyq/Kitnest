import AppKit
import Foundation

// MARK: - 诊断包导出（设置 → 关于 → 导出）
//
// 2026-10-20 用户需求：在「关于」页提供导出，内容包含
//   ① 功能使用记录（复用统计窄表 usage_daily_metrics 的全量导出接口）
//   ② 性能开销记录（从运行日志抽取慢事件/卡顿/重绘告警）
//   ③ 运行日志（LogArchive 按天文件，保留窗口内的全部）
// ④ 系统环境快照（macOS 版本 / App 版本 / 内存占用）
// 打成一个 zip 交给用户（NSSavePanel 选位置），不上传、不联网。

public enum DiagnosticsExporter {

    /// 弹出保存面板并生成诊断包（主线程调用）
    public static func export() {
        let panel = NSSavePanel()
        panel.title = "导出使用记录"
        panel.nameFieldStringValue = "FrsetNext-诊断-\(stamp()).zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // v128（流畅度）：打包整体移出主线程——原实现同步跑 writeBundle（统计全量查询
        // + 日志目录拷贝 + 性能行逐文件扫描 + ditto 压缩 waitUntilExit），导出期间
        // 整窗冻结数秒。面板关闭后后台打包，完成后回主线程提示/回显。
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try writeBundle(to: dest)
                Log.info("Settings", "诊断包已导出：\(dest.path)")
                DispatchQueue.main.async {
                    Toast.show("已导出使用记录", icon: "doc.zipper")
                    AnalyticsEvent.settingsExportSuccess.recordNow()
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                Log.warn("Settings", "诊断包导出失败：\(error.localizedDescription)")
                DispatchQueue.main.async {
                    Toast.show("导出失败：\(error.localizedDescription)",
                               icon: "exclamationmark.triangle.fill", isWarning: true)
                }
            }
        }
    }

    // MARK: 打包

    private static func writeBundle(to dest: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("frset-diag-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // ③ 日志：整目录拷贝（logs/*.log）
        let logsDir = LogArchive.shared.directory
        if let files = try? fm.contentsOfDirectory(at: logsDir,
                                                  includingPropertiesForKeys: nil) {
            let out = staging.appendingPathComponent("logs", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "log" {
                try? fm.copyItem(at: file, to: out.appendingPathComponent(file.lastPathComponent))
            }
        }

        // ① 功能使用记录（day,event,count 全量）
        var usage = "day,event,count\n"
        for (day, event, count) in usageRows() {
            usage += "\(day),\(event),\(count)\n"
        }
        try usage.write(to: staging.appendingPathComponent("usage.csv"),
                        atomically: true, encoding: .utf8)

        // ② 性能开销记录：从日志抽「慢/卡顿/重绘」告警行
        var perf = "time,level,tag,message\n"
        for line in performanceLines() {
            perf += line + "\n"
        }
        try perf.write(to: staging.appendingPathComponent("performance.csv"),
                       atomically: true, encoding: .utf8)

        // ④ 系统环境快照
        try systemSnapshot().write(to: staging.appendingPathComponent("system.txt"),
                                   atomically: true, encoding: .utf8)

        // 压成 zip（系统 ditto 保结构，不引第三方）
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent",
                         staging.path, dest.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            throw NSError(domain: "FrsetNext.Diagnostics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "打包失败（ditto \(zip.terminationStatus)）"])
        }
    }

    // MARK: ① 使用统计

    private static func usageRows() -> [(String, String, Int)] {
        // 复用统计窄表的全量导出（Q8：设置导出携带统计数据的同一接口）
        StatisticsManager.shared.exportAll()
    }

    // MARK: ② 性能行抽取

    /// 日志里的性能相关行（卡顿/慢操作/重绘告警），CSV 转义后返回
    private static func performanceLines() -> [String] {
        let keywords = ["WARN", "卡顿", "hang", "stall", "重绘", "耗时", "slow", "热"]
        var out: [String] = []
        let fm = FileManager.default
        let logsDir = LogArchive.shared.directory
        guard let files = try? fm.contentsOfDirectory(at: logsDir,
                                                     includingPropertiesForKeys: [.contentModificationDateKey])
        else { return out }
        for file in files where file.pathExtension == "log" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw)
                guard keywords.contains(where: { line.contains($0) }) else { continue }
                out.append(csvLine(line))
            }
        }
        return out
    }

    /// 整行按「time,level,tag,message」尽力拆分；拆不动就整体进 message 列
    private static func csvLine(_ line: String) -> String {
        // 形如 [19:17:35.710][INFO][Ports] scan n=58
        var time = "", level = "", tag = "", message = line
        let pattern = "^\\[([0-9:.]+)\\]\\[([A-Z]+)\\]\\[([^\\]]+)\\]\\s?(.*)$"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            func part(_ i: Int) -> String {
                let r = match.range(at: i)
                guard r.location != NSNotFound, let swift = Range(r, in: line) else { return "" }
                return String(line[swift])
            }
            time = part(1); level = part(2); tag = part(3); message = part(4)
        }
        return [time, level, tag, message].map(csvEscape).joined(separator: ",")
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    // MARK: ④ 系统快照

    private static func systemSnapshot() -> String {
        var lines: [String] = []
        let sys = ProcessInfo.processInfo
        lines.append("app_version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        lines.append("bundle_id=\(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("macos=\(sys.operatingSystemVersionString)")
        lines.append("hardware_mem=\(ByteCountFormatter.string(fromByteCount: Int64(sys.physicalMemory), countStyle: .file))")
        lines.append("uptime=\(Int(sys.systemUptime))s")
        lines.append("generated_at=\(ISO8601DateFormatter().string(from: Date()))")
        // 当前进程内存占用（footprint）
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        if result == 0 {
            lines.append("mem_footprint=\(ByteCountFormatter.string(fromByteCount: Int64(usage.ri_phys_footprint), countStyle: .file))")
            lines.append("cpu_time=\(Double(usage.ri_user_time + usage.ri_system_time) / 1e9)s")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }
}

private extension AnalyticsEvent {
    /// 埋点 +1 的便捷入口（无 day 参数 = 今天）
    func recordNow() {
        StatisticsManager.shared.record(eventName)
    }
}
