import Foundation

// MARK: - 文件中转的偏好键
//
// 单独集中：面板页（TransferDockView）、设置页（TransferDockSettingsPane）、
// 局域网服务（LanTransferServer）三处都读同一批键，避免各自写字面量写歪。
// 面板入口键沿用 v40 的 `panel.transferDock`（设置 → 常规 → 功能 已有勾选项）。

public enum TransferDockPref {
    /// 主面板「文件中转」入口显隐（沿用既有键）
    public static let panelVisible = Preferences.Keys.panelTransferDock

    /// 中转**功能**总开关（v260，与入口显隐解耦）
    ///
    /// 关掉它时：中转页显示一句「文件中转已关闭」，且主面板顶部的「中转 / 投屏」
    /// 分段一起隐藏（v260 用户要求「按钮也要消失」）；设置侧栏入口保留，方便重新开启。
    /// 之前它和 panelVisible 共用同一个键，两处 UI 互相覆盖。
    public static let featureEnabled = Preferences.Keys.transferFeatureEnabled

    /// v260：旧键 → 新键一次性迁移。
    ///
    /// 老版本里「常规→功能→文件中转」和「设置→文件中转→启用文件中转」
    /// 共用 `panel.transferDock`，语义已经被 v181 改过一次，这里再拆一次。
    /// 老用户的开关状态不能因为换键而丢失。
    public static func migrateLegacyFeatureFlag() {
        let d = UserDefaults.standard
        guard d.object(forKey: featureEnabled) == nil else { return }
        let legacy = d.object(forKey: panelVisible) as? Bool ?? true
        d.set(legacy, forKey: featureEnabled)
    }

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

    // MARK: - 投屏画质（v117；用户：「画质十分差，要能在设置里手动设置」）

    /// 投屏画质档位：分辨率上限 / 码率 / 帧率，全部可在 设置 → 文件中转 调整
    public enum CastQuality {
        private static let sizeKey = "cast.maxSize"       // 0 = 原始分辨率
        private static let bitrateKey = "cast.bitrate"    // Mbps
        private static let fpsKey = "cast.fps"            // 0 = scrcpy 默认

        /// 分辨率上限（短边像素；0 = 原始）
        public static var maxSize: Int {
            get { UserDefaults.standard.object(forKey: sizeKey) as? Int ?? 1920 }
            set { UserDefaults.standard.set(newValue, forKey: sizeKey) }
        }
        /// 码率（Mbps）
        public static var bitrate: Int {
            get { UserDefaults.standard.object(forKey: bitrateKey) as? Int ?? 16 }
            set { UserDefaults.standard.set(newValue, forKey: bitrateKey) }
        }
        /// 帧率上限（0 = 默认）
        public static var fps: Int {
            get { UserDefaults.standard.object(forKey: fpsKey) as? Int ?? 60 }
            set { UserDefaults.standard.set(newValue, forKey: fpsKey) }
        }

        // v130（AndroMeld/AgentHUD）：显式剪贴板参数（AndroMeld P0-2）。
        // 开（默认）→ scrcpy 拉起显式带双向剪贴板；关 → 明确关闭（不再依赖默认值）。
        private static let clipboardKey = "cast.clipboardAutoSync"
        public static var clipboardAutoSync: Bool {
            get {
                guard let v = UserDefaults.standard.object(forKey: clipboardKey) as? Bool else { return true }
                return v
            }
            set { UserDefaults.standard.set(newValue, forKey: clipboardKey) }
        }

        /// 人类可读摘要（设置页/投屏页展示）
        public static var summary: String {
            let size = maxSize == 0 ? "原始分辨率" : "\(maxSize)p"
            let fpsText = fps == 0 ? "默认帧率" : "\(fps)fps"
            return "\(size) · \(bitrate)Mbps · \(fpsText)"
        }

        public static let sizeOptions: [(String, Int)] = [
            ("原始", 0), ("1920", 1920), ("1440", 1440), ("1280", 1280), ("1024", 1024), ("854", 854)
        ]
        public static let bitrateOptions: [Int] = [4, 8, 16, 24, 32, 50]
        public static let fpsOptions: [Int] = [30, 60, 90, 0]
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
