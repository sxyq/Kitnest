import Foundation
import SwiftUI
import QuartzCore
import CommonCrypto

// MARK: - 日志（贴近原作：Sentry 已断，本地统一出口）

public enum Log {
    public enum Level: String { case debug, info, warn, error }
    public static var isVerbose = false

    /// 日志落盘（v84，2026-10-20 用户需求「3 天日志 + 卡死诊断」）：
    /// 统一交给 LogArchive——按天分文件（logs/YYYY-MM-DD.log）、保留 3 天自动清理、
    /// 单文件 4MB 上限、主线程卡死看门狗与 60s 状态快照都在那里实现。
    /// 本枚举的 API 签名保持不变，全工程调用点零改动。
    public static func write(_ level: Level, _ tag: String, _ message: String) {
        guard level != .debug || isVerbose else { return }
        let line = "[\(level.rawValue.uppercased())][\(tag)] \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
        LogArchive.shared.append(level: level.rawValue.uppercased(), tag: tag, message: message)
    }
    public static func debug(_ tag: String, _ m: String) { write(.debug, tag, m) }
    public static func info(_ tag: String, _ m: String) { write(.info, tag, m) }
    public static func warn(_ tag: String, _ m: String) { write(.warn, tag, m) }
    public static func error(_ tag: String, _ m: String) { write(.error, tag, m) }

    /// 操作面包屑（卡死看门狗在 HANG 日志里附最近 5 条，定位「卡死前最后一步」）
    public static func breadcrumb(_ tag: String, _ message: String) {
        LogArchive.shared.pushBreadcrumb("\(tag): \(message)")
    }
}

// MARK: - 模块注册（各功能模块自行实现 AppModule，由 App 层统一 start）

public protocol AppModule {
    static var identifier: String { get }
    static func start()
}

public enum ModuleRegistry {
    private static var lock = NSLock()
    private static var list: [any AppModule.Type] = []
    public static func register(_ m: any AppModule.Type) {
        lock.lock(); defer { lock.unlock() }
        guard !list.contains(where: { $0.identifier == m.identifier }) else { return }
        list.append(m)
        Log.info("Module", "registered: \(m.identifier)")
    }
    public static func startAll() {
        lock.lock(); let snapshot = list; lock.unlock()
        for m in snapshot {
            Log.info("Module", "start: \(m.identifier)")
            m.start()
        }
    }
}

// MARK: - 服务定位器（跨模块解耦：模块 A 只依赖协议，实现由模块 B 注入）

public protocol LLMServiceProtocol: AnyObject {
    /// 一次性补全
    func complete(prompt: String, system: String?, model: String?) async throws -> String
    /// 流式补全
    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error>
}

public protocol OCRServiceProtocol: AnyObject {
    /// 返回识别出的整段文本
    func recognizeText(imageData: Data) async throws -> String
    /// 返回带坐标的片段（用于取词/翻译定位）
    func recognizeObservations(imageData: Data) async throws -> [OCRTextObservation]
}

public struct OCRTextObservation: Sendable {
    public let text: String
    public let boundingBox: CGRect   // 归一化坐标（左下原点）
    public init(text: String, boundingBox: CGRect) {
        self.text = text; self.boundingBox = boundingBox
    }
}

public enum ServiceLocator {
    /// internal（供 Core/Registry.swift 的 extension 复用同一把锁）
    static let lock = NSLock()
    private static var llm: LLMServiceProtocol?
    private static var ocr: OCRServiceProtocol?

    public static var llmService: LLMServiceProtocol? {
        get { lock.lock(); defer { lock.unlock() }; return llm }
        set { lock.lock(); defer { lock.unlock() }; llm = newValue }
    }
    public static var ocrService: OCRServiceProtocol? {
        get { lock.lock(); defer { lock.unlock() }; return ocr }
        set { lock.lock(); defer { lock.unlock() }; ocr = newValue }
    }
}

// MARK: - 主题（视觉对齐 Frset：毛玻璃 + 圆角 + SF 字体）
//
// v66：布局尺寸与强调色全部动态化——读 Personalization（设置 → 常规 →「个性化」），
// 即改即生效；引用点（全工程 ~40 处）同名访问零改动。

public enum Theme {
    /// 面板圆角（个性化：6 / 10 / 14）
    public static var cornerRadius: CGFloat { Personalization.shared.cornerRadius }
    public static let smallRadius: CGFloat = 6
    /// 主面板宽度（官方原版 400pt；v41 起大侧边栏只用于设置窗口，面板版式不动）
    public static var panelWidth: CGFloat { 400 * Personalization.shared.fontScale }
    /// 设置窗口侧边栏宽度（v41：设置窗改左侧大侧边栏 + 内容区）
    public static let settingsSidebarWidth: CGFloat = 186
    /// 面板最大高度（随字号缩放联动：内容 scaleEffect 后视觉高度 = 700 × scale）
    public static var panelMaxHeight: CGFloat { 700 * Personalization.shared.fontScale }
    /// 通用行高（个性化密度联动）
    public static var rowHeight: CGFloat { Personalization.shared.density.rowHeight }
    /// 原版主页剪贴板行高（缩略图 50 + 上下 8pt 留白；行距由 intercellSpacing 8 提供）
    public static var statsRowHeight: CGFloat { Personalization.shared.density.statsRowHeight }
    /// 缩略图边长（密度联动 / 覆盖档位优先）
    public static var thumbSize: CGFloat { Personalization.shared.effectiveThumbSize }

    // MARK: 设计令牌（v153）
    //
    // 审计基线（apple-ui-designer + taste-skill）：
    //   · 345 个按钮/Menu 里只有 35% 有 help、3% 有 accessibilityLabel；
    //   · 297 处字号 <11pt（HIG 文本下限 11pt）；
    //   · 132 处 .tertiary 小字，实测 #808080 on #F2F2F4 ≈ 3.2:1，不达 AA 4.5:1；
    //   · 圆角出现 2/4/5/6/7/8/10/12/14 九种，无规则。
    // 这里先立规矩，后续新代码只许用这些令牌。
    public enum TextSize {
        /// 辅助信息下限（脚注、单位、"近 3 秒"这类）；正文一律 ≥ 11
        public static let micro: CGFloat = 10
        public static let caption: CGFloat = 11       // 最小可用正文字号（HIG 下限）
        public static let small: CGFloat = 12
        public static let body: CGFloat = 13
        public static let title: CGFloat = 15
        /// 指标数值（大号等宽数字）
        public static let metric: CGFloat = 17
    }

    /// 圆角只有五档，**不许再写字面量**（v179 统一）：
    ///   window 12 / card 10 / control 8 / chip 6 / micro 4
    /// 审计前全工程有 1/1.5/2/3/4/5/6/7/8/9/10/11/12/14/16/19/24 共 17 种取值，
    /// 其中 6 与 7、8 与 10 混用最严重（7 有 24 处、6 有 33 处，视觉上差 1pt 却
    /// 让相邻卡片对不齐）。胶囊一律用 `Capsule()`，不写数值。
    public enum Radius {
        /// 窗口 / 悬浮面板
        public static let window: CGFloat = 12
        /// 内容卡片（设置分组、统计卡、流向图卡）
        public static let card: CGFloat = 10
        /// 控件（按钮底、输入框、缩略图容器）
        public static let control: CGFloat = 8
        /// 小标签 / 徽标底
        public static let chip: CGFloat = 6
        /// 进度条端点、极小色块
        public static let micro: CGFloat = 4
        /// 旧名兼容（历史代码还在用 container）
        public static let container: CGFloat = window
    }

    /// 描边只有两档：发丝线 0.5pt（卡片/窗口边）与 1pt（选中态强调）
    public enum Stroke {
        public static let hairline: CGFloat = 0.5
        public static let emphasis: CGFloat = 1
    }

    /// 发丝线颜色：跟随明暗的 10% 前景色（浅色=黑 10%，深色=白 10%）
    public static let hairlineColor = Color.primary.opacity(0.10)
    /// 卡片底：比窗口底亮一档的极淡填充（深色下自动反相）
    public static let cardFill = Color.primary.opacity(0.045)

    /// 间距只有 4 的倍数档（外加 6/10 两个半档）
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 8
        public static let lg: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 20
    }
    /// 列表行 hover 底色（v156）：中性、极淡——强调色只留给「选中」，不用于悬停。
    /// 之前用 accent 0.10 整行铺满，等于一条蓝砖（用户：「蓝色框会直接填满」）。
    /// 用 primary 而不是 white：浅色下是「黑 5.5%」，深色下是「白 5.5%」，一套值两套主题。
    public static var rowHoverFill: Color { Color.primary.opacity(0.055) }

    /// 三级文字：主 / 次 / 弱。弱文字用 0.55 alpha（白底 ≈4.8:1，达 AA），
    /// 不再用 .tertiary（系统 tertiaryLabel 在白底只有 ~2.6:1）。
    public static let tertiaryText = Color.primary.opacity(0.55)

    // MARK: 动效令牌（v155，2026-10-28）
    //
    // 审计结果：全 App 的动画曲线散成 9 种时长 × 6 类曲线，spring 有 14 组不同写法；
    // 而且**唯一一个持续旋转**的动画（菜单栏风扇，RotatingLayerView）根本没设
    // timingFunction，走的是 CA 默认曲线（≈CSS ease，0.25/0.1/0.25/1）——
    // 每转一圈都「加速→减速」，接缝处速度从 0 直接跳回最大，看起来就是转一下顿一下。
    //
    // 统一规则（曲线只从这里取，不许再写字面量）：
    //   · 连续循环（旋转 / 扫描 / 进度）→ **只能线性**。给循环套缓动等于每圈重新起步，
    //     位置连续但速度不连续（连 G1 都不过），再漂亮的曲线也不如匀速。
    //   · 单次交互（悬停 / 按压 / 展开 / 淡入）→ 统一 ease-out，三档时长。
    //   · 有物理感的收放（卡片、面板）→ 统一弹簧，四档。
    public enum Motion {
        // 单次交互
        public static let tap: Animation = .easeOut(duration: 0.12)
        public static let fast: Animation = .easeOut(duration: 0.16)
        public static let page: Animation = .easeOut(duration: 0.22)
        public static let slow: Animation = .easeOut(duration: 0.45)

        // 弹簧四档（跟手 / 标准 / 柔和 / 回弹）
        public static let springSnappy: Animation = .spring(response: 0.22, dampingFraction: 0.85)
        public static let spring: Animation = .spring(response: 0.28, dampingFraction: 0.86)
        public static let springSoft: Animation = .spring(response: 0.34, dampingFraction: 0.86)
        public static let springBouncy: Animation = .spring(response: 0.24, dampingFraction: 0.62)

        // 连续循环
        public static let loop: Animation = .linear(duration: 0.9)
        public static let progress: Animation = .linear(duration: 0.2)

        // AppKit / CoreAnimation 侧（时长单列，避免与 SwiftUI 混用）
        public static let dTap: TimeInterval = 0.12
        public static let dFast: TimeInterval = 0.16
        public static let dPage: TimeInterval = 0.22
        public static let caLinear = CAMediaTimingFunction(name: .linear)
        public static let caEaseOut = CAMediaTimingFunction(controlPoints: 0.22, 0, 0, 1)
        public static let caEaseIn = CAMediaTimingFunction(name: .easeIn)
        public static let caEaseInEaseOut = CAMediaTimingFunction(name: .easeInEaseOut)
        /// 入场「略冲过」曲线（监测独立窗）
        public static let caBackOut = CAMediaTimingFunction(controlPoints: 0.22, 1.05, 0.36, 1)
    }

    public static let secondaryText = Color.secondary
    public static let cardBackground = Color(NSColor.controlBackgroundColor).opacity(0.6)
    public static let separator = Color(NSColor.separatorColor).opacity(0.5)

    /// 强调色（个性化自定义优先，nil 跟随系统）
    public static var accent: Color { Personalization.shared.accentColor ?? Color.accentColor }

    /// 强调色的 AppKit 形态（画布/图层描边等 NSColor 消费点，与 Theme.accent 同源）
    public static var accentNS: NSColor { NSColor(accent) }

    public static func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - 通用扩展

public extension Date {
    /// 相对时间文案（"刚刚" / "3分钟前" / 昨天具体时间）
    var relativeText: String {
        // v101 性能审计：DateFormatter 每次新建（0.5-2ms）→ 静态复用（两枚）
        let fmt = Self.relativeFormatter(today: Calendar.current.isDateInToday(self))
        fmt.dateFormat = Calendar.current.isDateInToday(self) ? "今天 HH:mm" : "M月d日 HH:mm"
        return fmt.string(from: self)
    }

    private static let fmtToday: DateFormatter = { let f = DateFormatter(); return f }()
    private static let fmtOther: DateFormatter = { let f = DateFormatter(); return f }()

    private static func relativeFormatter(today: Bool) -> DateFormatter { today ? fmtToday : fmtOther }
}

public extension String {
    /// SHA-256 十六进制摘要（小写）。
    ///
    /// 实现说明：此处曾为手写纯 Swift SHA-256（注释写"避免 CommonCrypto 链接问题"），
    /// 但消息调度字被 `& 0xffffffff` 掩成 32 位等缺陷，使长输入在剪贴板指纹路径
    /// （约 32KB）崩溃——实测崩溃报告 FrsetNext-2026-10-15-111300.ips：
    /// poll → ingest → read → fingerprint → String.sha256（自适应轮询每秒一次，故为间歇性崩溃）。
    /// 现统一走 CommonCrypto CC_SHA256（与 Features/AI/AICredentialJournal 同一实现），
    /// 已用标准向量（空串 / "abc" / 1MB 数据）对照 `shasum -a 256` 验证。
    var sha256: String { Data(utf8).sha256Hex }

    var truncatedForDisplay: String {
        var s = replacingOccurrences(of: "\n", with: " ")
        if s.count > 120 { s = String(s.prefix(120)) + "…" }
        return s
    }
}

public extension Data {
    /// SHA-256 十六进制摘要（小写）；空输入合法（e3b0c442…）。
    /// 逐字节摘要，供剪贴板指纹等热路径使用（CommonCrypto，单次调用 O(n) 无堆分配风暴）。
    var sha256Hex: String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 文件与目录

public enum AppDirectories {
    public static var base: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEBUG
        let dir = root.appendingPathComponent("FrsetNext-Dev", isDirectory: true)
        #else
        let dir = root.appendingPathComponent("FrsetNext", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    public static func sub(_ name: String) -> URL {
        let d = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
