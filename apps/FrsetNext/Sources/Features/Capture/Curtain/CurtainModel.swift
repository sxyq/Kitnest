import AppKit
import Foundation
import ImageIO

// MARK: - 图帘 · 模型层
//
// 「图帘」= 截图后挂在屏幕顶边那条帘线上的临时暂存区。
// 早期版本按 1Capture 的叫法称它「截图悬挂架」，v263 起统一改名为「图帘」——
// 用户原话：「窗帘形式的这种钉住的形式……换一个名字，起个更好听的名字，两到三个字」。
// 内部类型统一用 Curtain*，偏好键仍沿用历史 `shelf.*`（改键会丢老用户设置）。
//
// 对标 1Capture 的「拖放架 → 悬挂（HangingShelf）」：
// 截图完成后不直接消失，而是挂到屏幕顶边的一条帘线上临时暂存，
// 可以再拖出去、复制、保存。到期只「收起」不删内容。
//
// 与 1Capture 的差异（有意为之）：
// 1. 它的帘线有四种样式（原版 / 拐杖糖 / 圣诞彩灯 / 积雪），后两种是 CAEmitterLayer 粒子。
//    我们用纯 CoreGraphics 画同样的四种，不引入粒子层——常驻粒子层在滚动/缩放时掉帧。
// 2. 它的卡片常驻钟摆（CAKeyframeAnimation 无限循环）。我们只在「落入」时摆一次衰减摆动，
//    之后静止；悬停时轻微上浮。理由是用户明确要求「不论负载多高都不能掉帧」。

/// 帘线上的一张卡片
public struct CurtainItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// 截图落盘路径（不动原文件，拖出去就是它）
    public let fileURL: URL
    public let createdAt: Date
    /// 像素尺寸，用来算卡片长宽比
    public let pixelSize: CGSize

    public init(id: UUID = UUID(), fileURL: URL, createdAt: Date = Date(), pixelSize: CGSize) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.pixelSize = pixelSize
    }

    /// 卡片宽高：宽度按偏好，高度按原图比例。
    ///
    /// v263：卡片可放大到 420pt，高度上限不能再写死 168——按 `railScale`
    /// （帘线缩放系数）一起放大，避免大卡片被压成一条横带；
    /// `maxHeight` 再由控制器按当前屏幕可见高度兜底，防止竖屏截图顶到菜单栏。
    public func cardSize(cardWidth: CGFloat, railScale: CGFloat, maxHeight: CGFloat) -> CGSize {
        let ratio = pixelSize.width > 0 ? pixelSize.height / pixelSize.width : 0.62
        let minH = 84 * railScale
        let maxH = 168 * railScale
        let h = min(max(cardWidth * ratio, minH), maxH)
        return CGSize(width: cardWidth, height: max(min(h, maxHeight), 40))
    }
}

// MARK: - 绳子样式

/// 绳子样式。
///
/// 命名对齐 1Capture 的 `HangingShelfRopeStyle`（CLASSIC / CANDY_CANE /
/// CHRISTMAS_LIGHTS / SNOW），中文沿用它的官方措辞——用户在两边设置里
/// 看到的是同一套词。
public enum CurtainRopeStyle: String, CaseIterable, Identifiable {
    /// 原版：一根半透明白绳 + 细芯，带投影
    case classic
    /// 拐杖糖：白底 + 红色斜纹（1Capture 的 CANDY_CANE）
    case candyCane
    /// 圣诞彩灯：细绳 + 等距小灯
    case lights
    /// 积雪：绳上堆一层白
    case snow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic:   return "原版"
        case .candyCane: return "拐杖糖"
        case .lights:    return "圣诞彩灯"
        case .snow:      return "积雪"
        }
    }

    public var subtitle: String {
        switch self {
        case .classic:   return "一根半透明的帘线，任何桌面都不抢眼"
        case .candyCane: return "白线缠红条纹，最像晾衣绳"
        case .lights:    return "帘线上等距小灯，深色桌面最好看"
        case .snow:      return "帘线上积雪，冬天用"
        }
    }

    /// 旧版本存过 "twine"（麻绳），归一化到拐杖糖。
    /// 不做这一步，升级后读不出值会静默退回 classic。
    public static func normalized(_ raw: String) -> CurtainRopeStyle {
        if raw == "twine" { return .candyCane }
        return CurtainRopeStyle(rawValue: raw) ?? .classic
    }
}

// MARK: - 偏好

/// 图帘的偏好读写。
///
/// 全部走 `Preferences.shared`（UserDefaults），设置页与运行时共用一个来源。
/// 默认 **关闭**：不创建窗口、不挂任何东西，等于这个功能不存在。
public enum CurtainPref {

    /// 卡片宽度的设计基准。帘线/夹子/圆角都以它为 1.0 倍缩放。
    public static let baseCardWidth: CGFloat = 140
    /// 卡片宽度的下限 / 上限。上限从 v262 的 180 提到 420：
    /// 用户要求「按住 Command 拖动放大」，180 在 5K 屏上只够看个轮廓。
    public static let minCardWidth: CGFloat = 72
    public static let maxCardWidth: CGFloat = 420

    /// 总开关（默认 false —— 用户明确要求「不是常驻的」）
    public static var enabled: Bool {
        get { Preferences.shared.value(Preferences.Keys.curtainEnabled, default: false) }
        set {
            Preferences.shared.set(Preferences.Keys.curtainEnabled, newValue)
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

    /// 帘线样式
    public static var ropeStyle: CurtainRopeStyle {
        get {
            let raw: String = Preferences.shared.value(Preferences.Keys.curtainRopeStyle,
                                                       default: CurtainRopeStyle.classic.rawValue)
            return CurtainRopeStyle.normalized(raw)
        }
        set {
            Preferences.shared.set(Preferences.Keys.curtainRopeStyle, newValue.rawValue)
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

    /// 展示时长（秒）。0 = 永不自动收起
    public static var displayDuration: Double {
        get { Preferences.shared.value(Preferences.Keys.curtainDisplayDuration, default: 12.0) }
        set {
            Preferences.shared.set(Preferences.Keys.curtainDisplayDuration, max(0, newValue))
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

    /// 最多同时挂几张，超出从最旧的开始挤掉
    public static var maxCards: Int {
        get {
            let v: Int = Preferences.shared.value(Preferences.Keys.curtainMaxCards, default: 8)
            return min(max(v, 1), 20)
        }
        set {
            Preferences.shared.set(Preferences.Keys.curtainMaxCards, min(max(newValue, 1), 20))
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

    /// 截图完成后自动挂上去
    public static var attachOnCapture: Bool {
        get { Preferences.shared.value(Preferences.Keys.curtainAttachOnCapture, default: true) }
        set {
            Preferences.shared.set(Preferences.Keys.curtainAttachOnCapture, newValue)
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

    /// 卡片宽度（72...420，默认 140）。
    /// 1Capture 没暴露这个，我们留出来是为了 27 寸屏不显得空、13 寸屏不挤；
    /// v263 又加了两条改法：按住 ⌘ 在帘上左右拖、⌘ + 滚轮。
    public static var cardWidth: CGFloat {
        get {
            let v: Double = Preferences.shared.value(Preferences.Keys.curtainCardWidth,
                                                     default: Double(baseCardWidth))
            return CGFloat(min(max(v, Double(minCardWidth)), Double(maxCardWidth)))
        }
        set {
            let clamped = min(max(newValue, minCardWidth), maxCardWidth)
            Preferences.shared.set(Preferences.Keys.curtainCardWidth, Double(clamped))
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

    /// 帘线是否跟着卡片一起放大。
    ///
    /// 用户原话：「放大的时候，它需要不止放大图片，它那个窗帘的那个线也需要可以放大，
    /// 然后可以在系统设置里面单独设置」。所以这里给一个独立开关，默认开；
    /// 关掉之后卡片照常变大，但帘线/夹子/绳结保持 1×，适合「只想要大图、不想要粗线」的人。
    public static var railScalesWithCards: Bool {
        get { Preferences.shared.value(Preferences.Keys.curtainRailScales, default: true) }
        set {
            Preferences.shared.set(Preferences.Keys.curtainRailScales, newValue)
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

    /// 鼠标移到屏幕顶边时自动唤出图帘（v264，对齐 1Capture 的
    /// `SETTINGS_DDSHELF_HANGING_REVEAL_ON_HOVER`）。
    ///
    /// 热区放在**菜单栏下沿的 5pt 窄条**上，而不是真的顶到 0——顶边属于菜单栏，
    /// 抢了它的点击会让用户点不到状态栏图标（v261 当时就是因此没做）。
    /// 默认关：它会在屏幕最上方多一条 5pt 的「鼠标陷阱」，必须是用户主动选的。
    public static var revealOnHover: Bool {
        get { Preferences.shared.value(Preferences.Keys.curtainRevealOnHover, default: false) }
        set {
            Preferences.shared.set(Preferences.Keys.curtainRevealOnHover, newValue)
            NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil)
        }
    }

}

public extension Notification.Name {
    /// 图帘偏好变化（开关、样式、时长……）——设置页改完立即生效，不用重启
    static let curtainPreferencesChanged = Notification.Name("frset.shelf.preferencesChanged")
    /// 请求唤出 / 收起图帘（菜单栏、快捷键、深链共用）
    static let curtainToggleRequested = Notification.Name("frset.shelf.toggle")
}

// MARK: - 缩略图

/// 从原图生成卡片用的缩略图。
///
/// 为什么不直接 `NSImage(contentsOf:)`：那张图可能是 6000×4000 的 Retina 全屏截图，
/// 每挂一张就常驻几十 MB，挂八张直接把内存吃满。这里按卡片实际像素尺寸解码，
/// 并且 `kCGImageSourceShouldCacheImmediately` 关掉，让解码推迟到真正绘制时。
public enum CurtainThumbnail {

    public static func make(for url: URL, maxPixel: CGFloat = 320) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel * 2),
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 只读元数据里的像素尺寸，不解码整张图
    public static func pixelSize(of url: URL) -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
              w > 0, h > 0 else {
            return CGSize(width: 16, height: 10)
        }
        return CGSize(width: w, height: h)
    }
}
