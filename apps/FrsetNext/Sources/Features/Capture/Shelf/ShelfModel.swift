import AppKit
import Foundation
import ImageIO

// MARK: - 截图悬挂架 · 模型层
//
// 对标 1Capture 的「拖放架 → 悬挂（HangingShelf）」：
// 截图完成后不直接消失，而是挂到屏幕顶边的一条绳子上临时暂存，
// 可以再拖出去、复制、保存。到期只「收起」不删内容。
//
// 与 1Capture 的差异（有意为之）：
// 1. 它的绳子有四种样式（原版 / 拐杖糖 / 圣诞彩灯 / 积雪），后两种是 CAEmitterLayer 粒子。
//    我们用纯 CoreGraphics 画同样的四种，不引入粒子层——常驻粒子层在滚动/缩放时掉帧。
// 2. 它的卡片常驻钟摆（CAKeyframeAnimation 无限循环）。我们只在「落入」时摆一次衰减摆动，
//    之后静止；悬停时轻微上浮。理由是用户明确要求「不论负载多高都不能掉帧」。

/// 架子上的一张卡片
public struct ShelfItem: Identifiable, Equatable, Sendable {
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

    /// 卡片宽高：宽度固定，高度按原图比例，夹在 84...168 之间（避免超长截图把架子拉得很高）
    public func cardSize(cardWidth: CGFloat) -> CGSize {
        let ratio = pixelSize.width > 0 ? pixelSize.height / pixelSize.width : 0.62
        let h = min(max(cardWidth * ratio, 84), 168)
        return CGSize(width: cardWidth, height: h)
    }
}

// MARK: - 绳子样式

public enum ShelfRopeStyle: String, CaseIterable, Identifiable {
    /// 原版：一根细线
    case classic
    /// 麻绳：粗一点 + 斜纹
    case twine
    /// 彩灯：线上挂一圈小灯
    case lights
    /// 积雪：线上积一层白
    case snow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: return "原版"
        case .twine:   return "麻绳"
        case .lights:  return "彩灯"
        case .snow:    return "积雪"
        }
    }

    public var subtitle: String {
        switch self {
        case .classic: return "一根细线，最不抢眼"
        case .twine:   return "粗绳带斜纹，最像晾衣绳"
        case .lights:  return "沿线小灯，深色桌面更明显"
        case .snow:    return "线上积雪，冬天用"
        }
    }
}

// MARK: - 偏好

/// 悬挂架的偏好读写。
///
/// 全部走 `Preferences.shared`（UserDefaults），设置页与运行时共用一个来源。
/// 默认 **关闭**：不创建窗口、不挂任何东西，等于这个功能不存在。
public enum ShelfPref {

    /// 总开关（默认 false —— 用户明确要求「不是常驻的」）
    public static var enabled: Bool {
        get { Preferences.shared.value(Preferences.Keys.shelfEnabled, default: false) }
        set {
            Preferences.shared.set(Preferences.Keys.shelfEnabled, newValue)
            NotificationCenter.default.post(name: .shelfPreferencesChanged, object: nil)
        }
    }

    /// 绳子样式
    public static var ropeStyle: ShelfRopeStyle {
        get {
            let raw: String = Preferences.shared.value(Preferences.Keys.shelfRopeStyle,
                                                       default: ShelfRopeStyle.twine.rawValue)
            return ShelfRopeStyle(rawValue: raw) ?? .twine
        }
        set {
            Preferences.shared.set(Preferences.Keys.shelfRopeStyle, newValue.rawValue)
            NotificationCenter.default.post(name: .shelfPreferencesChanged, object: nil)
        }
    }

    /// 展示时长（秒）。0 = 永不自动收起
    public static var displayDuration: Double {
        get { Preferences.shared.value(Preferences.Keys.shelfDisplayDuration, default: 12.0) }
        set {
            Preferences.shared.set(Preferences.Keys.shelfDisplayDuration, max(0, newValue))
            NotificationCenter.default.post(name: .shelfPreferencesChanged, object: nil)
        }
    }

    /// 最多同时挂几张，超出从最旧的开始挤掉
    public static var maxCards: Int {
        get {
            let v: Int = Preferences.shared.value(Preferences.Keys.shelfMaxCards, default: 8)
            return min(max(v, 1), 20)
        }
        set {
            Preferences.shared.set(Preferences.Keys.shelfMaxCards, min(max(newValue, 1), 20))
            NotificationCenter.default.post(name: .shelfPreferencesChanged, object: nil)
        }
    }

    /// 截图完成后自动挂上去
    public static var attachOnCapture: Bool {
        get { Preferences.shared.value(Preferences.Keys.shelfAttachOnCapture, default: true) }
        set {
            Preferences.shared.set(Preferences.Keys.shelfAttachOnCapture, newValue)
            NotificationCenter.default.post(name: .shelfPreferencesChanged, object: nil)
        }
    }

    /// 卡片宽度（64...180，默认 140）。1Capture 没暴露这个，我们留出来是为了 27 寸屏不显得空、13 寸屏不挤。
    public static var cardWidth: CGFloat {
        get {
            let v: Double = Preferences.shared.value(Preferences.Keys.shelfCardWidth, default: 140)
            return CGFloat(min(max(v, 64), 180))
        }
        set {
            Preferences.shared.set(Preferences.Keys.shelfCardWidth, Double(min(max(newValue, 64), 180)))
            NotificationCenter.default.post(name: .shelfPreferencesChanged, object: nil)
        }
    }
}

public extension Notification.Name {
    /// 悬挂架偏好变化（开关、样式、时长……）——设置页改完立即生效，不用重启
    static let shelfPreferencesChanged = Notification.Name("frset.shelf.preferencesChanged")
    /// 请求唤出 / 收起悬挂架（菜单栏、快捷键、深链共用）
    static let shelfToggleRequested = Notification.Name("frset.shelf.toggle")
}

// MARK: - 缩略图

/// 从原图生成卡片用的缩略图。
///
/// 为什么不直接 `NSImage(contentsOf:)`：那张图可能是 6000×4000 的 Retina 全屏截图，
/// 每挂一张就常驻几十 MB，挂八张直接把内存吃满。这里按卡片实际像素尺寸解码，
/// 并且 `kCGImageSourceShouldCacheImmediately` 关掉，让解码推迟到真正绘制时。
public enum ShelfThumbnail {

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
