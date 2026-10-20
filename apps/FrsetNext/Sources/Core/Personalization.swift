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
    /// 面板内容弹簧参数（visible 进出场）
    public var spring: Animation {
        switch self {
        case .snappy: return .spring(response: 0.18, dampingFraction: 0.85)
        case .standard: return .spring(response: 0.24, dampingFraction: 0.82)
        case .soft: return .spring(response: 0.32, dampingFraction: 0.85)
        }
    }
    /// 窗口淡入时长
    public var fadeDuration: TimeInterval {
        switch self {
        case .snappy: return 0.10
        case .standard: return 0.14
        case .soft: return 0.20
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

    // MARK: P1

    @Published public var material: PersonalizationMaterial = .solid { didSet { persist() } }
    @Published public var showSourceBadge: Bool = true { didSet { persist() } }
    @Published public var thumbOverride: CGFloat? { didSet { persist() } }    // 44/56/72，nil=随密度
    @Published public var toastDuration: TimeInterval = 3 { didSet { persist() } }   // 2/3/5
    @Published public var toastFollowPanel: Bool = false { didSet { persist() } }    // true=跟随主面板；默认屏幕中线偏下
    @Published public var barDividerColorHex: String = "" { didSet { persist() } }  // 空 = 默认
    @Published public var barDividerAlpha: Double = 0.35 { didSet { persist() } }   // 0..1

    // MARK: P2

    @Published public var midnightHueShift: Double = 0 { didSet { persist() } }     // -30...30
    @Published public var backgroundImagePath: String = "" { didSet { persist() } }  // 空 = 无
    @Published public var backgroundImageDim: Double = 0.35 { didSet { persist() } } // 0...0.8

    private init() { load() }

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
        guard !isLoading else { return }
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

    private func flushPersist() {
        Log.info("personalization", "persist: fontScale=\(fontScale) density=\(density.rawValue) corner=\(cornerRadius)")
        let d = UserDefaults.standard
        d.set(accentColorHex, forKey: Preferences.Keys.uiAccentColor)
        d.set(Double(fontScale), forKey: Preferences.Keys.uiFontScale)
        d.set(density.rawValue, forKey: Preferences.Keys.uiListDensity)
        d.set(Double(cornerRadius), forKey: Preferences.Keys.uiCornerRadius)
        d.set(openAnimation.rawValue, forKey: Preferences.Keys.uiOpenAnimation)
        d.set(material.rawValue, forKey: Preferences.Keys.uiPanelMaterial)
        d.set(showSourceBadge, forKey: Preferences.Keys.uiSourceBadge)
        if let thumbOverride { d.set(Double(thumbOverride), forKey: Preferences.Keys.uiThumbSize) }
        else { d.removeObject(forKey: Preferences.Keys.uiThumbSize) }
        d.set(toastDuration, forKey: Preferences.Keys.uiToastDuration)
        d.set(toastFollowPanel, forKey: Preferences.Keys.uiToastPosition)
        d.set(barDividerColorHex, forKey: Preferences.Keys.uiBarDividerColor)
        d.set(barDividerAlpha, forKey: Preferences.Keys.uiBarDividerAlpha)
        d.set(midnightHueShift, forKey: Preferences.Keys.uiMidnightHue)
        d.set(backgroundImagePath, forKey: Preferences.Keys.uiBackgroundImage)
        d.set(backgroundImageDim, forKey: Preferences.Keys.uiBackgroundDim)
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
        let scale = d.double(forKey: Preferences.Keys.uiFontScale)
        fontScale = scale > 0 ? CGFloat(scale) : 1.0
        density = PersonalizationDensity(rawValue: d.string(forKey: Preferences.Keys.uiListDensity) ?? "") ?? .standard
        let corner = d.double(forKey: Preferences.Keys.uiCornerRadius)
        cornerRadius = corner > 0 ? CGFloat(corner) : 10
        openAnimation = PersonalizationOpenAnimation(rawValue: d.string(forKey: Preferences.Keys.uiOpenAnimation) ?? "") ?? .standard
        material = PersonalizationMaterial(rawValue: d.string(forKey: Preferences.Keys.uiPanelMaterial) ?? "") ?? .solid
        showSourceBadge = d.object(forKey: Preferences.Keys.uiSourceBadge) == nil
            ? true : d.bool(forKey: Preferences.Keys.uiSourceBadge)
        let thumb = d.double(forKey: Preferences.Keys.uiThumbSize)
        thumbOverride = thumb > 0 ? CGFloat(thumb) : nil
        let toast = d.double(forKey: Preferences.Keys.uiToastDuration)
        toastDuration = toast > 0 ? toast : 3
        toastFollowPanel = d.object(forKey: Preferences.Keys.uiToastPosition) == nil
            ? false : d.bool(forKey: Preferences.Keys.uiToastPosition)
        barDividerColorHex = d.string(forKey: Preferences.Keys.uiBarDividerColor) ?? ""
        let alpha = d.double(forKey: Preferences.Keys.uiBarDividerAlpha)
        barDividerAlpha = alpha > 0 ? alpha : 0.35
        let hue = d.double(forKey: Preferences.Keys.uiMidnightHue)
        midnightHueShift = hue != 0 ? hue : 0
        backgroundImagePath = d.string(forKey: Preferences.Keys.uiBackgroundImage) ?? ""
        let dim = d.double(forKey: Preferences.Keys.uiBackgroundDim)
        backgroundImageDim = dim > 0 ? dim : 0.35
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
    }
}
