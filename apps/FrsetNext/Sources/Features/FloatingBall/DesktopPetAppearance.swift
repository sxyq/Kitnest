import SwiftUI

// MARK: - 海豚桌面精灵外观配置

/// 海豚精灵的视觉外观：皮肤颜色、大小模式、气泡等。
/// 所有持久化键以 `desktopPet.` 为前缀，与既有 UserDefaults 域兼容。
struct DesktopPetAppearance {
    /// 大小模式
    enum SizeMode: String, CaseIterable, Identifiable {
        case small
        case medium
        case large

        var id: String { rawValue }

        var title: String {
            switch self {
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            }
        }

        /// 相对基准尺寸的缩放比例
        var scale: CGFloat {
            switch self {
            case .small: return 0.80
            case .medium: return 1.00
            case .large: return 1.18
            }
        }
    }

    // MARK: 皮肤颜色（HSB 色彩空间）
    var skinHue: Double
    var skinSaturation: Double
    var skinBrightness: Double

    /// 动态模式：静态（不跑动画时钟，零重绘开销）/ 轻量（约 3fps 呼吸漂浮）
    enum MotionMode: String, CaseIterable, Identifiable {
        case staticMode = "static"
        case light = "light"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .staticMode: return "静态"
            case .light: return "轻动"
            }
        }
    }

    // MARK: 大小
    var sizeMode: SizeMode

    // MARK: 动态模式
    var motionMode: MotionMode

    // MARK: 自定义 PNG（用户替换形象；nil = 内置矢量海豚）
    var customImagePath: String?

    // MARK: 气泡
    var showsBubble: Bool

    // MARK: 计算颜色

    /// 身体主色（默认蓝灰色系）
    var bodyColor: Color {
        Color(hue: skinHue, saturation: skinSaturation, brightness: skinBrightness)
    }

    /// 腹部浅色
    var bellyColor: Color {
        Color(hue: skinHue,
              saturation: skinSaturation * 0.35,
              brightness: min(skinBrightness + 0.22, 1.0))
    }

    /// 鳍 / 尾颜色（比身体略深）
    var finColor: Color {
        Color(hue: skinHue,
              saturation: min(skinSaturation + 0.10, 1.0),
              brightness: max(skinBrightness - 0.12, 0))
    }

    /// 嘴线颜色
    var mouthColor: Color {
        Color(hue: skinHue,
              saturation: min(skinSaturation + 0.15, 1.0),
              brightness: max(skinBrightness - 0.28, 0))
    }

    /// 眼睛颜色
    var eyeColor: Color { .primary.opacity(0.88) }

    /// 眼睛高光
    var eyeHighlightColor: Color { .white }
}

// MARK: - 持久化键与读写

enum DesktopPetSettings {
    static let enabledKey = "desktopPet.enabled"
    static let skinHueKey = "desktopPet.skinHue"
    static let skinSaturationKey = "desktopPet.skinSaturation"
    static let skinBrightnessKey = "desktopPet.skinBrightness"
    static let sizeModeKey = "desktopPet.sizeMode"
    static let showsBubbleKey = "desktopPet.showsBubble"
    static let doubleClickActionKey = "desktopPet.doubleClickAction"
    static let motionModeKey = "desktopPet.motionMode"
    static let customImagePathKey = "desktopPet.customImagePath"

    /// 桌面精灵是否启用（默认关闭）
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 读取当前外观配置（缺省值 = 蓝灰小海豚、中号、显示气泡）
    static var appearance: DesktopPetAppearance {
        let d = UserDefaults.standard
        return DesktopPetAppearance(
            skinHue: d.object(forKey: skinHueKey) as? Double ?? 0.58,
            skinSaturation: d.object(forKey: skinSaturationKey) as? Double ?? 0.30,
            skinBrightness: d.object(forKey: skinBrightnessKey) as? Double ?? 0.72,
            sizeMode: (d.string(forKey: sizeModeKey))
                .flatMap(DesktopPetAppearance.SizeMode.init(rawValue:)) ?? .medium,
            motionMode: (d.string(forKey: motionModeKey))
                .flatMap(DesktopPetAppearance.MotionMode.init(rawValue:)) ?? .light,
            customImagePath: d.string(forKey: customImagePathKey),
            showsBubble: d.object(forKey: showsBubbleKey) as? Bool ?? true
        )
    }

    /// 双击动作 ID；空串或 "expand" = 展开面板
    static var doubleClickAction: String {
        UserDefaults.standard.string(forKey: doubleClickActionKey) ?? ""
    }
}
