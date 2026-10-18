import Darwin
import Foundation

// ============================================================================
// 按应用归并物理内存占用（活动监视器「内存」列口径）
//
// 归并思路参考 WonderBox（MIT License）
// https://github.com/jasonwong1991/WonderBox
// Sources/WonderBox/Services/ProcessMemoryInspector.swift
// 本实现按本工程命名与模型重写，仅保留所需能力（排行/前后差值）。
// ============================================================================

public struct AppMemoryUsage: Identifiable, Sendable {
    public var id: URL { location }
    public let location: URL
    public let name: String
    /// Activity Monitor「内存」列：私有页 + 该 app 的压缩/交换页
    public let footprint: UInt64
    public let resident: UInt64
    public let processCount: Int

    public var nonResident: UInt64 { footprint - min(footprint, resident) }
}

public enum ProcessMemoryInspector {
    /// PROC_PIDPATHINFO_MAXSIZE 是宏，Swift 里用 4×MAXPATHLEN
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// 只统计真正的 .app；系统守护进程没有可归并的宿主 app，跳过
    public static func topConsumers(limit: Int = 40) -> [AppMemoryUsage] {
        var groups: [String: (footprint: UInt64, resident: UInt64, count: Int)] = [:]
        for pid in allProcessIdentifiers() {
            if Task.isCancelled { break }
            guard let usage = resourceUsage(of: pid), usage.ri_phys_footprint > 0,
                  let path = executablePath(of: pid),
                  let bundlePath = applicationBundlePath(containing: path)
            else { continue }
            groups[bundlePath, default: (0, 0, 0)].footprint += usage.ri_phys_footprint
            groups[bundlePath, default: (0, 0, 0)].resident += usage.ri_resident_size
            groups[bundlePath, default: (0, 0, 0)].count += 1
        }

        let ownPath = Bundle.main.bundleURL.standardizedFileURL.path
        return groups
            .sorted { $0.value.footprint > $1.value.footprint }
            .prefix(limit)
            .compactMap { key, value -> AppMemoryUsage? in
                guard key != ownPath else { return nil }
                let location = URL(fileURLWithPath: key)
                guard location.pathExtension == "app" else { return nil }
                let bundle = Bundle(url: location)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? location.deletingPathExtension().lastPathComponent
                return AppMemoryUsage(
                    location: location,
                    name: name,
                    footprint: value.footprint,
                    resident: value.resident,
                    processCount: value.count
                )
            }
    }

    static func resourceUsage(of pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// 取路径上最外层的 .app，嵌套 helper 自动归并到宿主应用
    static func applicationBundlePath(containing executablePath: String) -> String? {
        let components = executablePath.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    static func allProcessIdentifiers() -> [pid_t] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.size + 32)
        let bytesWritten = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &buffer,
            Int32(buffer.count * MemoryLayout<pid_t>.size)
        )
        guard bytesWritten > 0 else { return [] }
        return buffer.prefix(Int(bytesWritten) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
