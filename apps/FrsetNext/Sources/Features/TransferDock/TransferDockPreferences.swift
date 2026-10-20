import Foundation

// MARK: - 文件中转的偏好键
//
// 单独集中：面板页（TransferDockView）、设置页（TransferDockSettingsPane）、
// 局域网服务（LanTransferServer）三处都读同一批键，避免各自写字面量写歪。
// 面板入口键沿用 v40 的 `panel.transferDock`（设置 → 常规 → 功能 已有勾选项）。

public enum TransferDockPref {
    /// 主面板「文件中转」入口显隐（沿用既有键）
    public static let panelVisible = Preferences.Keys.panelTransferDock

    /// OPPO 云端中转通道（关掉后 UI 完全不出现「云端」分区）
    public static let cloudEnabled = "transferDock.cloud.enabled"

    /// 手机扫码直传（内置 HTTP 服务）
    public static let lanEnabled = "transferDock.lan.enabled"

    /// 直传服务端口
    private static let lanPortKey = "transferDock.lan.port"
    /// 直传访问 token（URL 路径前缀，防止同网段随手扫到）
    public static let lanToken = "transferDock.lan.token"

    public static let defaultLanPort: UInt16 = 8787

    public static var lanPort: UInt16 {
        get {
            let raw = UserDefaults.standard.integer(forKey: lanPortKey)
            guard raw >= 1024, raw <= 65535 else { return defaultLanPort }
            return UInt16(raw)
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: lanPortKey) }
    }

    /// 三个开关的默认值都是「开」：不写默认值时 UserDefaults.bool 返回 false，
    /// 会导致老用户升级后功能突然消失，这里统一按「未设置 = 开」解释。
    public static func isOn(_ key: String, default fallback: Bool = true) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) as? Bool else { return fallback }
        return value
    }

    /// 云端通道当前是否可用（开关开 **且** 桥接脚本/登录态存在）
    public static var cloudActive: Bool {
        isOn(cloudEnabled) && TransferDockPath.isAvailable
    }

    /// 剪贴板文件自动暂存（复制 Word / PPT / Excel / 压缩包等 → 自动进本地中转）
    public static let autoStageClipboard = "transferDock.autoStageClipboard"

    /// 自动暂存只对这些扩展名生效（用户原话「类似 zip Word PPT 等文件」→ 文档 + 压缩包）
    public static let autoStageExtensions: Set<String> = [
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pdf",
        "pages", "numbers", "key",
        "zip", "rar", "7z", "tar", "gz", "tgz"
    ]
}
