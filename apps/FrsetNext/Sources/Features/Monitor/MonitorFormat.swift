import Foundation

/// 监测模块使用的格式化工具（字节/速率/百分比）
public enum MonitorFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 字节数 → 易读字符串（按 1024 进制）
    public static func bytes(_ value: UInt64) -> String {
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(size)) B" }
        return String(format: size >= 100 ? "%.0f %@" : "%.1f %@", size, units[unit])
    }

    /// 速率（bytes/s）
    public static func rate(_ value: UInt64) -> String {
        bytes(value) + "/s"
    }

    /// 菜单栏速率：沿用字节单位与精度，省去单位前的空格。
    public static func compactRate(_ value: UInt64) -> String {
        rate(value).replacingOccurrences(of: " ", with: "")
    }

    /// 带方向的速率（↑ 上传 / ↓ 下载）
    public static func directionalRate(upload: UInt64, download: UInt64) -> String {
        "↑\(rate(upload)) ↓\(rate(download))"
    }

    /// 0..1 → 百分比整数（如 62%）
    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }

    /// 百分比（保留一位小数，用于压力/负载）
    public static func percentFine(_ value: Double) -> String {
        guard value.isFinite else { return "0.0%" }
        return String(format: "%.1f%%", min(1, max(0, value)) * 100)
    }

    /// 温度
    public static func temperature(_ value: Double) -> String {
        String(format: "%.0f°", value)
    }

    /// 负载
    public static func load(_ value: Double) -> String {
        String(format: "%.2f", value.isFinite ? value : 0)
    }

    /// 磁盘读写合并显示（状态栏用，紧凑）
    public static func diskRate(read: UInt64, write: UInt64) -> String {
        "R\(rate(read)) W\(rate(write))"
    }

    /// 整机功耗（W，保留一位小数；≥100W 取整）
    public static func power(_ watts: Double) -> String {
        guard watts.isFinite, watts >= 0 else { return "—" }
        return String(format: watts >= 100 ? "%.0fW" : "%.1fW", watts)
    }
}
