import AppKit
import Foundation
import SwiftUI

// MARK: - 个性化状态（v66：设置 → 常规 →「个性化」，全部即改即生效）
//
// 单例 ObservableObject：设置页 Binding 写入 → objectWillChange 广播 →
// 观察视图（PanelRootView / SettingsRootView / 剪贴板表格等）即时重算；
// AppKit 侧（PanelController 窗口尺寸 / FloatingPanel 材质）经 Notification 订阅。
// Theme 的 static var（cornerRadius / rowHeight / statsRowHeight / thumbSize /
// accent / panelMaxHeight）全部改读本类，同名访问点（全工程 ~40 处）零改动生效。

public enum PersonalizationDensity: String, CaseIterable, Identifiable {
    case compact, standard, relaxed
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .relaxed: return "宽松"
        }
    }
    /// 剪贴板表格行高
    public var statsRowHeight: CGFloat {
        switch self {
        case .compact: return 46
        case .standard: return 58
        case .relaxed: return 76
        }
    }
    /// 通用行高（预览锚点估算等）
    public var rowHeight: CGFloat {
        switch self {
        case .compact: return 46
        case .standard: return 56
        case .relaxed: return 68
        }
    }
    /// 缩略图边长
    public var thumbSize: CGFloat {
        switch self {
        case .compact: return 32
        case .standard: return 40
        case .relaxed: return 52
        }
    }
}

public enum PersonalizationOpenAnimation: String, CaseIterable, Identifiable {
    case snappy, standard, soft
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .snappy: return "跟手"
        case .standard: return "标准"
        case .soft: return "柔和"
        }
    }
    /// 面板 / 预览窗 / 监测窗开合动画时长（v197 起统一由 Core/WindowReveal 消费）。
    ///
    /// v195（GSAP 性能口径）：只动 transform + opacity；不用弹簧——弹簧实际收敛时间
    /// 约为 response 的 1.6–2 倍，窗口收尾按固定时长结束必然把动画截断。
    /// v197：动画挪到窗口内容层（整块玻璃+内容从一个锚点展开/缩回），
    /// 曲线统一为 Theme.Motion.caEaseOut / caEaseIn，这里只留时长档位。
    public var duration: TimeInterval {
        switch self {
        case .snappy: return 0.18
        case .standard: return 0.22
        case .soft: return 0.28
        }
    }
}

public enum PersonalizationMaterial: String, CaseIterable, Identifiable {
    case solid, vibrancy
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .solid: return "纯色卡片"
        case .vibrancy: return "毛玻璃"
        }
    }
}

public final class Personalization: ObservableObject {

    public static let shared = Personalization()

    /// 变更通知（AppKit 侧无 Combine 观察的组件用；window 尺寸 / 材质 / C 层分隔线）
    public static let didChangeNotification =
        Notification.Name("personalization.didChange")

    // MARK: P0

    /// 强调色（nil = 跟随系统）
    @Published public var accentColor: Color? { didSet { persist() } }
    @Published public var fontScale: CGFloat = 1.0 { didSet { persist() } }   // 0.9/1.0/1.1/1.25
    @Published public var density: PersonalizationDensity = .standard { didSet { persist() } }
    @Published public var cornerRadius: CGFloat = 10 { didSet { persist() } } // 6/10/14
    @Published public var openAnimation: PersonalizationOpenAnimation = .standard { didSet { persist() } }
    @Published public var hoverPreviewEnabled: Bool = true { didSet { persist() } }

    // MARK: P1

    @Published public var material: PersonalizationMaterial = .solid { didSet { persist() } }
    @Published public var showSourceBadge: Bool = true { didSet { persist() } }
    @Published public var thumbOverride: CGFloat? { didSet { persist() } }    // 44/56/72，nil=随密度
    @Published public var toastDuration: TimeInterval = 3 { didSet { persist() } }   // 2/3/5
    @Published public var toastFollowPanel: Bool = false { didSet { persist() } }    // true=跟随主面板；默认屏幕中线偏下
    @Published public var barDividerColorHex: String = "" { didSet { persist() } }  // 空 = 默认
    @Published public var barDividerAlpha: Double = 0.35 { didSet { persist() } }   // 0..1

    // MARK: 玻璃质感（v193）
    //
    // 用户：「设置里面添加相关的按钮去调节玻璃的一个通透质感以及相关的参数，
    // 弄成几个可以滑动的这种类似于音量条的这种。放在个性化里面」。
    //
    // 这五个参数就是 v192 那套「三层明度台阶」的可调版本：
    //   通透度   —— 玻璃面底衬的不透明度（越大越实，越小越透出桌面）
    //   磨砂     —— 霜感层强度（模拟模糊层的漫反射，越大越"起雾"）
    //   卡片亮度 —— 内容卡相对窗口底的明度台阶（层与层的距离）
    //   描边     —— 发丝边可见度（ArcZip 那种 8% 亮边）

    /// 玻璃通透度：0.55（很透）… 1.0（完全不透明）
    ///
    /// v205：默认值对齐 macOS 天气 App 的玻璃观感（系统 Liquid Glass 之上
    /// 只压一层 60% 的底衬，比旧的 93% 更透、更接近系统面板）。
    @Published public var glassOpacity: Double = 0.60 { didSet { persist() } }
    /// 磨砂强度：0（清透）… 1（厚霜）
    @Published public var glassBlur: Double = 0.30 { didSet { persist() } }
    /// 卡片亮度台阶：0（卡片贴平）… 1（卡片明显浮起）
    @Published public var glassCardLift: Double = 0.55 { didSet { persist() } }
    /// 描边强度：0（无发丝边）… 1（亮边明显）
    @Published public var glassStroke: Double = 0.30 { didSet { persist() } }

    /// 玻璃观感版本：v205 起默认改成「天气 App 同款」。
    /// 旧版本存过的 0.93/0.35/0.5/0.4 会覆盖新默认 → 一次性迁移到新口径。
    private static let glassLookVersionKey = "ui.glassLookVersion"
    private static let currentGlassLookVersion = 2

    // MARK: P2

    @Published public var midnightHueShift: Double = 0 { didSet { persist() } }     // -30...30
    @Published public var backgroundImagePath: String = "" { didSet { persist() } }  // 空 = 无
    @Published public var backgroundImageDim: Double = 0.35 { didSet { persist() } } // 0...0.8

    private let persistsChanges: Bool

    private init(persistsChanges: Bool = true) {
        self.persistsChanges = persistsChanges
        if persistsChanges { load() }
    }

    public func makeDraft() -> Personalization {
        let draft = Personalization(persistsChanges: false)
        draft.copyValues(from: self)
        return draft
    }

    /// 设置页明确列出本模块字段，避免旧草稿覆盖其他页刚保存的值。
    struct DraftField {
        let key: String
        let copy: (Personalization, Personalization) -> Void
        let matches: (Personalization, Personalization) -> Bool

        init<T: Equatable>(_ path: ReferenceWritableKeyPath<Personalization, T>, key: String) {
            self.key = key
            copy = { target, source in target[keyPath: path] = source[keyPath: path] }
            matches = { left, right in left[keyPath: path] == right[keyPath: path] }
        }
    }

    static func makeDefaultDraft() -> Personalization { Personalization(persistsChanges: false) }

    func applyDraft(_ draft: Personalization, fields: [DraftField]) {
        isLoading = true
        for field in fields { field.copy(self, draft) }
        isLoading = false
        flushPersist(keys: Set(fields.map(\.key)))
    }

    private func copyValues(from source: Personalization) {
        accentColor = source.accentColor
        fontScale = source.fontScale
        density = source.density
        cornerRadius = source.cornerRadius
        openAnimation = source.openAnimation
        hoverPreviewEnabled = source.hoverPreviewEnabled
        material = source.material
        showSourceBadge = source.showSourceBadge
        thumbOverride = source.thumbOverride
        toastDuration = source.toastDuration
        toastFollowPanel = source.toastFollowPanel
        barDividerColorHex = source.barDividerColorHex
        barDividerAlpha = source.barDividerAlpha
        midnightHueShift = source.midnightHueShift
        backgroundImagePath = source.backgroundImagePath
        backgroundImageDim = source.backgroundImageDim
        glassOpacity = source.glassOpacity
        glassBlur = source.glassBlur
        glassCardLift = source.glassCardLift
        glassStroke = source.glassStroke
    }

    // MARK: 持久化

    /// 加载期抑制持久化（v66 修复：load 逐属性赋值时 didSet 会用「半初始化状态」
    /// 覆盖刚读入的偏好——accentColor 先赋值 → persist 把 fontScale=1.0 写盘，
    /// 随后 fontScale 读回被污染值，用户设置永远失效）
    private var isLoading = false

    /// v84（2026-10-20 设置页卡死治理）：写盘合并到 150ms 一次。
    /// 此前每个属性 didSet 都立刻写 15 个 defaults 键并发通知——拖动滑块时
    /// 每帧一轮（15 写入 + N 个监听者重建状态栏），主线程直接被淹没。
    /// 现改为防抖：连续修改只落盘一次；退出前 flushPendingPersist() 兜底。
    private var persistWork: DispatchWorkItem?

    private func persist() {
        guard persistsChanges, !isLoading else { return }
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPersist() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 立即落盘（防抖窗口内退出时由 App 层调用，避免丢设置）
    public func flushPendingPersist() {
        persistWork?.cancel()
        persistWork = nil
        flushPersist()
    }

    private func flushPersist(keys: Set<String>? = nil) {
        Log.info("personalization", "persist: fontScale=\(fontScale) density=\(density.rawValue) corner=\(cornerRadius)")
        let d = UserDefaults.standard
        let values: [String: Any?] = [
            Preferences.Keys.uiAccentColor: accentColorHex,
            Preferences.Keys.uiFontScale: Double(fontScale),
            Preferences.Keys.uiListDensity: density.rawValue,
            Preferences.Keys.uiCornerRadius: Double(cornerRadius),
            Preferences.Keys.uiOpenAnimation: openAnimation.rawValue,
            "ui.hoverPreviewEnabled": hoverPreviewEnabled,
            Preferences.Keys.uiPanelMaterial: material.rawValue,
            Preferences.Keys.uiSourceBadge: showSourceBadge,
            Preferences.Keys.uiThumbSize: thumbOverride.map(Double.init),
            Preferences.Keys.uiToastDuration: toastDuration,
            Preferences.Keys.uiToastPosition: toastFollowPanel,
            Preferences.Keys.uiBarDividerColor: barDividerColorHex,
            Preferences.Keys.uiBarDividerAlpha: barDividerAlpha,
            Preferences.Keys.uiMidnightHue: midnightHueShift,
            Preferences.Keys.uiBackgroundImage: backgroundImagePath,
            Preferences.Keys.uiBackgroundDim: backgroundImageDim,
            Preferences.Keys.uiGlassOpacity: glassOpacity,
            Preferences.Keys.uiGlassBlur: glassBlur,
            Preferences.Keys.uiGlassCardLift: glassCardLift,
            Preferences.Keys.uiGlassStroke: glassStroke,
        ]
        for (key, value) in values where keys == nil || keys!.contains(key) {
            if let value { d.set(value, forKey: key) }
            else { d.removeObject(forKey: key) }
        }
        if keys == nil || keys!.contains(Preferences.Keys.uiGlassOpacity) {
            d.set(Self.currentGlassLookVersion, forKey: Self.glassLookVersionKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func load() {
        let d = UserDefaults.standard
        isLoading = true
        defer { isLoading = false }
        Log.info("personalization", "load: raw fontScale=\(d.double(forKey: Preferences.Keys.uiFontScale))")
        let hex = d.string(forKey: Preferences.Keys.uiAccentColor) ?? ""
        accentColor = Self.color(fromHex: hex)
        accentColorHex = hex
        fontScale = d.object(forKey: Preferences.Keys.uiFontScale) == nil
            ? 1.0 : CGFloat(d.double(forKey: Preferences.Keys.uiFontScale))
        density = PersonalizationDensity(rawValue: d.string(forKey: Preferences.Keys.uiListDensity) ?? "") ?? .standard
        cornerRadius = d.object(forKey: Preferences.Keys.uiCornerRadius) == nil
            ? 10 : CGFloat(d.double(forKey: Preferences.Keys.uiCornerRadius))
        openAnimation = PersonalizationOpenAnimation(rawValue: d.string(forKey: Preferences.Keys.uiOpenAnimation) ?? "") ?? .standard
        hoverPreviewEnabled = d.object(forKey: "ui.hoverPreviewEnabled") == nil
            ? true : d.bool(forKey: "ui.hoverPreviewEnabled")
        material = PersonalizationMaterial(rawValue: d.string(forKey: Preferences.Keys.uiPanelMaterial) ?? "") ?? .solid
        showSourceBadge = d.object(forKey: Preferences.Keys.uiSourceBadge) == nil
            ? true : d.bool(forKey: Preferences.Keys.uiSourceBadge)
        thumbOverride = d.object(forKey: Preferences.Keys.uiThumbSize) == nil
            ? nil : CGFloat(d.double(forKey: Preferences.Keys.uiThumbSize))
        toastDuration = d.object(forKey: Preferences.Keys.uiToastDuration) == nil
            ? 3 : d.double(forKey: Preferences.Keys.uiToastDuration)
        toastFollowPanel = d.object(forKey: Preferences.Keys.uiToastPosition) == nil
            ? false : d.bool(forKey: Preferences.Keys.uiToastPosition)
        barDividerColorHex = d.string(forKey: Preferences.Keys.uiBarDividerColor) ?? ""
        barDividerAlpha = d.object(forKey: Preferences.Keys.uiBarDividerAlpha) == nil
            ? 0.35 : d.double(forKey: Preferences.Keys.uiBarDividerAlpha)
        midnightHueShift = d.double(forKey: Preferences.Keys.uiMidnightHue)
        backgroundImagePath = d.string(forKey: Preferences.Keys.uiBackgroundImage) ?? ""
        backgroundImageDim = d.object(forKey: Preferences.Keys.uiBackgroundDim) == nil
            ? 0.35 : d.double(forKey: Preferences.Keys.uiBackgroundDim)
        // 玻璃四参数：没有落盘值时用出厂口径（不覆盖默认值）
        if d.object(forKey: Preferences.Keys.uiGlassOpacity) != nil {
            glassOpacity = min(1, max(0.55, d.double(forKey: Preferences.Keys.uiGlassOpacity)))
        }
        if d.object(forKey: Preferences.Keys.uiGlassBlur) != nil {
            glassBlur = min(1, max(0, d.double(forKey: Preferences.Keys.uiGlassBlur)))
        }
        if d.object(forKey: Preferences.Keys.uiGlassCardLift) != nil {
            glassCardLift = min(1, max(0, d.double(forKey: Preferences.Keys.uiGlassCardLift)))
        }
        if d.object(forKey: Preferences.Keys.uiGlassStroke) != nil {
            glassStroke = min(1, max(0, d.double(forKey: Preferences.Keys.uiGlassStroke)))
        }
        // v205：旧观感一次迁移到「天气 App 同款」默认（用户改过也先归位，之后可再调）
        if d.integer(forKey: Self.glassLookVersionKey) < Self.currentGlassLookVersion {
            glassOpacity = 0.60
            glassBlur = 0.30
            glassCardLift = 0.55
            glassStroke = 0.30
            // load 期间 didSet 不落盘，这里直接写入，避免每次启动都重新迁移
            d.set(glassOpacity, forKey: Preferences.Keys.uiGlassOpacity)
            d.set(glassBlur, forKey: Preferences.Keys.uiGlassBlur)
            d.set(glassCardLift, forKey: Preferences.Keys.uiGlassCardLift)
            d.set(glassStroke, forKey: Preferences.Keys.uiGlassStroke)
            d.set(Self.currentGlassLookVersion, forKey: Self.glassLookVersionKey)
            Log.info("personalization", "玻璃观感迁移：v2 天气 App 口径 0.60/0.30/0.55/0.30")
        }

    }

    // MARK: hex 辅助

    public var accentColorHex: String {
        get {
            guard let accentColor else { return "" }
            return Self.hex(fromColor: accentColor)
        }
        set {
            accentColor = Self.color(fromHex: newValue)
        }
    }

    public static func color(fromHex hex: String) -> Color? {
        guard hex.count == 6 || hex.count == 7 else { return nil }
        var value: UInt64 = 0
        let scanner = Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex)
        guard scanner.scanHexInt64(&value) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    public static func hex(fromColor color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        return String(format: "%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }

    /// 主题色预设（强调色档位）
    public static let accentPresets: [(name: String, hex: String)] = [
        ("蓝", "0A66FF"), ("紫", "7B5CFF"), ("青", "00A6A6"),
        ("橙", "FF8A00"), ("粉", "FF4D8F"), ("绿", "2FA84F"),
    ]

    // MARK: 生效值（Theme / 各消费点读取）

    /// 实际缩略图边长（覆盖档位优先于密度联动）
    public var effectiveThumbSize: CGFloat {
        thumbOverride ?? density.thumbSize
    }

    /// 恢复默认（重置按钮）
    public func resetAll() {
        accentColor = nil
        fontScale = 1.0
        density = .standard
        cornerRadius = 10
        openAnimation = .standard
        hoverPreviewEnabled = true
        material = .solid
        showSourceBadge = true
        thumbOverride = nil
        toastDuration = 3
        toastFollowPanel = false
        barDividerColorHex = ""
        barDividerAlpha = 0.35
        midnightHueShift = 0
        backgroundImagePath = ""
        backgroundImageDim = 0.35
        glassOpacity = 0.60
        glassBlur = 0.30
        glassCardLift = 0.55
        glassStroke = 0.30
    }
}
