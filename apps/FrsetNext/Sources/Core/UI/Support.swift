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
    /// internal（供 Core/Runtime/Registry.swift 的 extension 复用同一把锁）
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

public extension Font {
    /// 个性化「界面字号」的全局缩放入口（v260）。
    ///
    /// 背景：字号档位此前**只**改窗口高度，文字一个都没变——
    /// v73 的注释里写着「字号缩放档位只影响字号（待接入全局字体缩放）」，
    /// 那一半至今没接，所以「界面字号」这一排设置看起来完全无效。
    ///
    /// SwiftUI 没有全局改 `.system(size:)` 的机制（macOS 上 dynamicType
    /// 对固定字号无效），所以只能提供一个统一入口把硬编码字号换成它。
    static func scaledSystem(size: CGFloat,
                             weight: Font.Weight? = nil,
                             design: Font.Design? = nil,
                             scale: CGFloat = Personalization.shared.fontScale) -> Font {
        .system(size: size * scale, weight: weight, design: design)
    }
}

public struct ThemeAppearance {
    public let personalization: Personalization
    public let isMidnight: Bool
    public init(personalization: Personalization, isMidnight: Bool) {
        self.personalization = personalization
        self.isMidnight = isMidnight
    }
    public var accent: Color { personalization.accentColor ?? .accentColor }
    public var cornerRadius: CGFloat { personalization.cornerRadius }
    public var fontScale: CGFloat { personalization.fontScale }
    public var thumbSize: CGFloat { personalization.effectiveThumbSize }
    public var statsRowHeight: CGFloat {
        thumbSize + personalization.density.statsRowHeight - personalization.density.thumbSize
    }
    public var windowSurface: Color { Theme.windowSurface(for: personalization, midnight: isMidnight) }
    /// 阅读面不透明底（预览栏 / 长文区：切断玻璃透射，保证正文对比度）
    public var readingBase: Color { Theme.readingBase(for: personalization, midnight: isMidnight) }
    /// 侧栏磨砂底衬（分类导航栏：比 contentBase 实、比 floatingGlass 透）
    public var sidebarFill: Color { Theme.sidebarFill(for: personalization, midnight: isMidnight) }
    /// 侧栏磨砂霜感（跟随「磨砂」滑块，强度是窗口级的一半）
    public var sidebarFrost: Color { Theme.sidebarFrost(for: personalization) }
    public var glassFrost: Color { Theme.glassFrost(for: personalization) }
    /// 结构面单层着色（底衬 + 霜感预合成）
    public var glassTint: Color { Theme.glassTint(for: personalization, midnight: isMidnight) }
    public var cardFill: Color { Theme.cardFill(for: personalization, midnight: isMidnight) }
    public var cardStroke: Color { Theme.cardStroke(for: personalization) }
    public var insetFill: Color { Theme.insetFill(for: personalization) }
}

extension Theme {
    /// 面板圆角（个性化：6 / 10 / 14）
    public static var cornerRadius: CGFloat { Personalization.shared.cornerRadius }
    public static let smallRadius: CGFloat = 6
    /// 主面板宽度（官方原版 400pt；v41 起大侧边栏只用于设置窗口，面板版式不动）
    ///
    /// v260：原来这里是 `400 * fontScale`——和「个性化 → 面板宽度」档位
    /// （360/400/440，写在 panelWidth 键里）**各算各的**，两个设置项互相覆盖。
    /// 现在以档位值为准，没设过才回退到 400。
    public static var panelWidth: CGFloat {
        let stored = Preferences.shared.value(Preferences.Keys.panelWidth, default: 400.0)
        return max(CGFloat(stored), 320)
    }
    /// 设置窗口侧边栏宽度（v41：设置窗改左侧大侧边栏 + 内容区）
    public static let settingsSidebarWidth: CGFloat = 186
    /// 面板最大高度（随字号缩放联动：内容 scaleEffect 后视觉高度 = 700 × scale）
    public static var panelMaxHeight: CGFloat { 700 * Personalization.shared.fontScale }
    /// 通用行高（个性化密度联动）
    public static var rowHeight: CGFloat { Personalization.shared.density.rowHeight }
    /// 剪贴板行高随实际缩略图调整，保留各密度的留白，避免大图挤入相邻行。
    public static var statsRowHeight: CGFloat {
        ThemeAppearance(personalization: .shared, isMidnight: AppearanceState.shared.isMidnight).statsRowHeight
    }
    /// 缩略图边长（密度联动 / 覆盖档位优先）
    public static var thumbSize: CGFloat { Personalization.shared.effectiveThumbSize }

    // 无服务依赖的排版与动效令牌见 ThemeTokens.swift。

    /// 发丝线颜色：跟随明暗的 10% 前景色（浅色=黑 10%，深色=白 10%）
    public static let hairlineColor = Color.primary.opacity(0.10)

    // MARK: 表面分层（v192，对标 ArcZip 的三层明度）
    //
    // 旧口径 `cardFill = primary 4.5%` 的问题（2026-11-03 截图对比 ArcZip）：
    // 窗口底、区块、卡片全都叠在同一个明度带上，层与层只差 4.5% 明度，
    // 在壁纸上看起来就是"一整片灰"——既不玻璃也不清晰，正文对比度还被拖低。
    //
    // ArcZip 的层次（浅色 #F2F2F4 窗口 / #FFFFFF 卡片 / #EDEDEF 内嵌；
    // 暗色 #1C1C1E / #2C2C2E / #242426）靠的是**明确 8-12% 的明度台阶 + 发丝边**，
    // 不是更大的模糊。这里照同一套口径定义四种表面，全局只许用它们。
    //
    // 全部写成 NSColor 动态色：同一份代码自动跟随浅色/深色，不用到处判 colorScheme。

    /// v193：表面令牌全部改为**跟随个性化参数**的计算属性。
    ///
    /// 之前四个表面是写死的常量，用户只能接受既定观感；现在
    /// 「设置 → 个性化 → 玻璃质感」的四个滑块直接改这里的取值：
    ///   通透度 → windowSurface 的 alpha
    ///   磨砂   → glassFrost（霜感层）
    ///   卡片亮度 → cardFill 的 alpha（层与层的明度台阶）
    ///   描边   → cardStroke 的 alpha
    ///
    /// 读取路径：ThemeChromeModifier 观察 Personalization.shared，
    /// 滑块一动 → objectWillChange → 整棵子树重算 → 新值立刻生效。
    private static func dynamicSurface(_ build: @escaping (Bool) -> (NSColor, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (base, alpha) = build(isDark)
            return base.withAlphaComponent(alpha)
        })
    }

    /// 表面令牌缓存：动态 NSColor 每次新建都要注册 appearance 观察者，
    /// 面板每秒重算时反复创建会白白堆积。参数没变就复用同一个 Color 实例。
    private static let surfaceLock = NSLock()
    private static var surfaceCache: [String: Color] = [:]

    /// 缓存键里的连续量量化到 2 位小数（2026-11-26 修复）。
    /// 滑杆值来自 Double 全精度，直接插值会让每次拖动都写入新条目且永不淘汰；
    /// 0.01 的量化对 alpha / 磨砂倍率这类参数无可感知差异。
    private static func keyValue(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private static func cachedSurface(_ key: String,
                                      _ build: @escaping (Bool) -> (NSColor, CGFloat)) -> Color {
        surfaceLock.lock()
        if let hit = surfaceCache[key] {
            surfaceLock.unlock()
            return hit
        }
        surfaceLock.unlock()
        let color = dynamicSurface(build)
        surfaceLock.lock()
        surfaceCache[key] = color
        surfaceLock.unlock()
        return color
    }

    /// 带自定义 alpha 的动态色缓存（预合成用：alpha 由合成公式算出，
    /// 不是「基色 + 常量 alpha」两段式，所以不能走 cachedSurface）。
    private static var glassTintCache: [String: Color] = [:]

    private static func cachedDynamicColor(_ key: String,
                                          _ build: @escaping (Bool) -> NSColor) -> Color {
        surfaceLock.lock()
        if let hit = glassTintCache[key] {
            surfaceLock.unlock()
            return hit
        }
        surfaceLock.unlock()
        let color = Color(nsColor: NSColor(name: nil) { appearance in
            build(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        })
        surfaceLock.lock()
        glassTintCache[key] = color
        surfaceLock.unlock()
        return color
    }

    /// 纯色叠合：base(alpha a1) 上面再压一层白色(alpha a2)，返回等价的单层颜色。
    /// 两个 alpha 都来自用户滑块，取值固定 → 结果可以缓存，运行期零计算。
    private static func composite(_ base: NSColor, alpha a1: CGFloat,
                                  whiteAlpha a2: CGFloat) -> NSColor {
        let total = a1 + a2 * (1 - a1)
        guard total > 0.0001 else { return base.withAlphaComponent(0) }
        let base = base.usingColorSpace(.sRGB) ?? base
        func mix(_ c: CGFloat) -> CGFloat { (c * a1 + a2 * (1 - a1)) / total }
        return NSColor(srgbRed: mix(base.redComponent),
                       green: mix(base.greenComponent),
                       blue: mix(base.blueComponent),
                       alpha: total)
    }

    /// L0 窗口底：铺在真玻璃之上的那层半透明底。
    /// Midnight 只更换基色，通透度仍由同一个参数决定。
    public static var windowSurface: Color {
        windowSurface(for: .shared, midnight: AppearanceState.shared.isMidnight)
    }
    public static func windowSurface(for p: Personalization, midnight: Bool) -> Color {
        let opacity = p.glassOpacity
        if midnight {
            return MidnightTheme.baseBackground(for: p).opacity(opacity)
        }
        return cachedSurface("window.\(keyValue(opacity))") { isDark in
            let base = isDark
                ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
                : NSColor(srgbRed: 0.957, green: 0.957, blue: 0.969, alpha: 1)
            return (base, CGFloat(opacity))
        }
    }

    /// 阅读面不透明底（2026-11-23 需求 B 五：「预览文字可读，不被玻璃透射干扰」）。
    ///
    /// 与 `windowSurface` **同基色**，但 alpha 恒为 1。预览栏 / 长文阅读区
    /// 这类要长时间盯正文的面，铺在窗口玻璃之上时必须切断玻璃透射——
    /// 否则壁纸/桌面内容会从正文底下透出来，小字号对比度直接塌掉。
    /// 只给「阅读面」用；普通卡片仍走 cardFill（半透明是层次感来源）。
    public static var readingBase: Color {
        readingBase(for: .shared, midnight: AppearanceState.shared.isMidnight)
    }
    public static func readingBase(for p: Personalization, midnight: Bool) -> Color {
        if midnight { return MidnightTheme.baseBackground(for: p) }
        return cachedSurface("reading") { isDark in
            let base = isDark
                ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
                : NSColor(srgbRed: 0.957, green: 0.957, blue: 0.969, alpha: 1)
            return (base, 1)
        }
    }

    // MARK: 侧栏磨砂（2026-11-23 需求 B 三：三栏工作台左侧分类导航栏）
    //
    // 口径：**比 contentBase 实一点、比 floatingGlass 透一点**——
    // 分类导航栏要「轻微磨砂感」，与中间卡片区有微妙区分，但不能像浮层那样抢戏。
    // 配方沿用 GlassSurface 的两层色调（底衬 + 霜感），**不另加模糊**：
    // 侧栏坐在窗口玻璃之上，采样已经由窗口那层做过，再叠一层只会掉帧。
    // 两层强度都比窗口级轻一档（底衬 ≈ insetFill 的一半，霜感 ≈ glassFrost 的一半）。

    /// 侧栏底衬：极轻的明暗微调，把侧栏和卡片区分成两块但不抢内容。
    /// 浅色压一点暗、深色提一点亮（与设置窗侧栏原实色同向、略轻）。
    public static var sidebarFill: Color {
        sidebarFill(for: .shared, midnight: AppearanceState.shared.isMidnight)
    }
    public static func sidebarFill(for p: Personalization, midnight: Bool) -> Color {
        if midnight { return MidnightTheme.baseBackground(for: p).opacity(0.30) }
        return cachedSurface("sidebar.fill") { isDark in
            let base = isDark ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)
            return (base, isDark ? 0.05 : 0.028)
        }
    }

    /// 侧栏霜感：玻璃之上的漫反射薄雾，「磨砂」观感的来源。
    /// 跟随「磨砂」滑块（`glassBlur`），强度是窗口级 `glassFrost` 的一半。
    public static var sidebarFrost: Color {
        sidebarFrost(for: .shared)
    }
    public static func sidebarFrost(for p: Personalization) -> Color {
        let blur = p.glassBlur
        return cachedSurface("sidebar.frost.\(keyValue(blur))") { isDark in
            let b = CGFloat(blur)
            return (NSColor(white: 1, alpha: 1), isDark ? 0.055 * b : 0.10 * b)
        }
    }

    /// 玻璃面单层着色 = 「通透度底衬」叠「磨砂霜感」**预合成**后的等价颜色。
    ///
    /// 2026-11-24（用户：「每个窗口只保留必要的背景采样层」「避免重复的整窗着色和磨砂层」）：
    /// 旧实现把这两层当成两个独立视图（SwiftUI 两个 fill / AppKit 两个 subview）
    /// 铺在玻璃上——同一块玻璃每帧多一次整窗 alpha 合成，20 余个窗口都这么干；
    /// 观感上还容易出现「白雾叠深灰」的双层污染。
    ///
    /// 两色都是纯色 + 常量 alpha，叠合结果可以离线算出来：
    ///   A = a1 + a2(1-a1)，C = (C1·a1 + C2·a2(1-a1)) / A
    /// 这里按该式预合成，一层 fill/一个 CALayer 就够，四个滑块依旧全部生效。
    public static var glassTint: Color {
        glassTint(for: .shared, midnight: AppearanceState.shared.isMidnight)
    }
    public static func glassTint(for p: Personalization, midnight: Bool) -> Color {
        let opacity = CGFloat(p.glassOpacity)
        let blur = CGFloat(p.glassBlur)
        if midnight {
            let base = NSColor(MidnightTheme.baseBackground(for: p)).usingColorSpace(.sRGB)
                ?? NSColor(srgbRed: 0.055, green: 0.067, blue: 0.105, alpha: 1)
            return cachedDynamicColor("glassTint.m.\(keyValue(opacity)).\(keyValue(blur))") { _ in
                composite(base, alpha: opacity, whiteAlpha: 0.11 * blur)
            }
        }
        return cachedDynamicColor("glassTint.\(keyValue(opacity)).\(keyValue(blur))") { isDark in
            let base = isDark
                ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
                : NSColor(srgbRed: 0.957, green: 0.957, blue: 0.969, alpha: 1)
            return composite(base, alpha: opacity, whiteAlpha: (isDark ? 0.11 : 0.20) * blur)
        }
    }

    /// 霜感层（磨砂强度）：真玻璃/毛玻璃之上的一层漫反射，模拟"起雾"
    ///
    /// v203（用户：「这两个改了无效」）：霜感必须压在「通透度底衬」之上
    /// （顺序见 GlassSurface）；夹在 93% 底衬之下时最大只剩 ~0.8% 可见度，滑块等于空转。
    /// 强度同时上调一档（浅色 0.12→0.20、深色 0.05→0.11），否则浅色主题下几乎看不出。
    ///
    /// 2026-11-24：结构面已改用上面的预合成 `glassTint`（单层）。
    /// 这里保留给仍需要「单独一层霜」的调用点（侧栏等），不要再叠在 glassTint 之上。
    public static var glassFrost: Color {
        glassFrost(for: .shared)
    }
    public static func glassFrost(for p: Personalization) -> Color {
        let blur = p.glassBlur
        return cachedSurface("frost.\(keyValue(blur))") { isDark in
            let b = CGFloat(blur)
            return (NSColor(white: 1, alpha: 1), isDark ? 0.11 * b : 0.20 * b)
        }
    }

    /// L2 内容卡：比窗口底**亮一档**（浅色近白 / 暗色略亮于窗口）
    public static var cardFill: Color {
        cardFill(for: .shared, midnight: AppearanceState.shared.isMidnight)
    }
    public static func cardFill(for p: Personalization, midnight: Bool) -> Color {
        if midnight { return MidnightTheme.cardBackground(for: p) }
        let liftValue = p.glassCardLift
        return cachedSurface("card.\(keyValue(liftValue))") { isDark in
            // 浅色 0.55（贴平）…0.98（近实白）；暗色 0.035…0.10 白
            let alpha = cardFillAlpha(lift: liftValue, isDark: isDark)
            return (NSColor(white: 1, alpha: 1), alpha)
        }
    }

    /// L1.5 内嵌区（代码块 / 列表槽 / 输入框）：比窗口底**暗一档**，
    /// 用来把「可以滚动的容器」和「卡片面」区分开
    public static var insetFill: Color {
        insetFill(for: .shared)
    }
    public static func insetFill(for p: Personalization) -> Color {
        let opacity = p.glassOpacity
        return cachedSurface("inset.\(keyValue(opacity))") { isDark in
            // 玻璃越通透，内嵌区压得越浅（否则底衬一透就糊了）
            let k = 0.6 + 0.4 * CGFloat(opacity)
            return (NSColor(white: 0, alpha: 1), isDark ? 0.22 * k : 0.045 * k)
        }
    }

    /// 卡片描边：浅色用 8% 黑，暗色用 9% 白（ArcZip 的发丝边就是这一档）
    public static var cardStroke: Color {
        cardStroke(for: .shared)
    }
    public static func cardStroke(for p: Personalization) -> Color {
        let strokeValue = p.glassStroke
        return cachedSurface("stroke.\(keyValue(strokeValue))") { isDark in
            let base = isDark ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)
            let alpha = cardStrokeAlpha(strength: strokeValue, isDark: isDark)
            return (base, alpha)
        }
    }

    /// 强调色（个性化自定义优先，nil 跟随系统）
    public static var accent: Color { accent(for: Personalization.shared.accentColor) }

    /// 强调色的 AppKit 形态（画布/图层描边等 NSColor 消费点，与 Theme.accent 同源）
    public static var accentNS: NSColor { NSColor(accent) }

    public static func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

public extension Theme.Radius {
    static var window: CGFloat { Personalization.shared.cornerRadius }
    static var container: CGFloat { window }
}

// MARK: - 通用扩展

public extension Date {
    /// 相对时间文案（"刚刚" / "3分钟前" / 昨天具体时间）
    var relativeText: String {
        // v101 性能审计：DateFormatter 每次新建（0.5-2ms）→ 静态复用（两枚）
        // v260（滚动掉帧）：原来复用后**每次调用还在改 dateFormat**——
        // 那个 setter 每次都会让 formatter 丢掉已解析的格式缓存并重新解析格式串，
        // 等于把 v101 省下的开销又吐回去；剪贴板列表每行每帧都要调它一次。
        // 现在格式在创建时固定，两枚 formatter 各司其职，运行期只改不改设。
        (Calendar.current.isDateInToday(self) ? Self.fmtToday : Self.fmtOther).string(from: self)
    }

    private static let fmtToday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "今天 HH:mm"; return f
    }()
    private static let fmtOther: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M月d日 HH:mm"; return f
    }()
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
    /// 数据根目录。
    ///
    /// 支持 `KITNEST_DATA_DIR` 覆盖：手册演示 GIF 不能带真实剪贴板内容（里面有
    /// VPN 订阅 token、服务器地址之类），录制时用隔离目录跑，录完删掉即可，
    /// 个人数据一条都不用动。
    public static var base: URL {
        // 优先级：环境变量 > user defaults > 默认目录。
        // user defaults 这条路是给录制用的：`open` 走 LaunchServices 启动的进程拿不到
        // 环境变量，只能用 `defaults write com.sxyq.frsetnext KitnestDataDir <dir>`
        // 让它在任何启动方式下都读演示目录。
        if let custom = ProcessInfo.processInfo.environment["KITNEST_DATA_DIR"],
           !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let custom = UserDefaults.standard.string(forKey: "KitnestDataDir"),
           !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
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
