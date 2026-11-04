import AppKit
import Foundation

// MARK: - 外置卷观察（v217）
//
// 用户：「当外部插入 U 盘或者是其他的盘符的时候，它能够自动把那里加载出来，
// 就像当前我接入了外部的一个盘」。
//
// 之前磁盘页只有一条链路：IOKit 的启动卷容量。外置盘插进来完全不显示。
// 这里监听 NSWorkspace 的挂载/卸载/改名通知，枚举所有挂载卷，
// 只保留「可移动 / 可推出 / 网络」这几类——内置启动卷仍由原来的容量构成负责。
//
// 不轮询：系统通知足够（插拔都会发），零常驻开销。

struct DiskVolume: Identifiable, Hashable {
    let path: String
    let name: String
    let total: Int64
    let free: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isReadOnly: Bool
    let isLocal: Bool

    var id: String { path }
    var used: Int64 { max(0, total - free) }

    /// 类型标签（网络盘 / U 盘 / 外置 / 一般卷）
    ///
    /// 注意：外置 SSD（如 Lexar 这类 USB/NVMe 盒）`removable` 与 `ejectable`
    /// 都返回 false，只有 `isInternal == false`。v217 实测：不看这个字段
    /// 会把 954 GB 的外置盘标成「卷」。
    var kindText: String {
        if !isLocal { return "网络" }
        if isRemovable { return "可移动" }
        if !isInternal || isEjectable { return "外置" }
        return "卷"
    }

    var symbolName: String {
        if !isLocal { return "network" }
        if isRemovable { return "sdcard" }
        return "externaldrive"
    }
}

final class DiskVolumeStore: ObservableObject {

    static let shared = DiskVolumeStore()

    /// 只含外置/可移动/网络卷，按名称排序
    @Published private(set) var volumes: [DiskVolume] = []

    private var tokens: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            tokens.append(token)
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsReadOnlyKey, .volumeIsLocalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []

        var found: [DiskVolume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isInternal = values.volumeIsInternal ?? true
            let removable = values.volumeIsRemovable ?? false
            let ejectable = values.volumeIsEjectable ?? false
            let local = values.volumeIsLocal ?? true

            // 内置启动卷交给原来的 IOKit 容量构成，这里跳过
            if isInternal && !removable && !ejectable && local { continue }
            guard let capacity = values.volumeTotalCapacity, capacity > 0 else { continue }

            found.append(DiskVolume(
                path: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                total: Int64(capacity),
                free: Int64(values.volumeAvailableCapacity ?? 0),
                isInternal: isInternal,
                isRemovable: removable,
                isEjectable: ejectable,
                isReadOnly: values.volumeIsReadOnly ?? false,
                isLocal: local))
        }

        let sorted = found.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if sorted != volumes { volumes = sorted }
    }
}
