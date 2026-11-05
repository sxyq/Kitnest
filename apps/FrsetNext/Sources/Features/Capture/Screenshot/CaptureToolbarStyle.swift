import SwiftUI

// MARK: - 框选动作条样式（v219）
//
// 用户：「这三种方案都要。在设置里面……把当前的这个选项放在个性化设置里面」。
//
// 三种形态共用同一份数据（CaptureActionChain.groups），差别只在排布与子项展开方式：
//   iconBar      纯图标，30pt 方块。最紧凑（约 210pt），悬停 0.3 秒浮出组内子项。
//   pillBar      图标 + 文字药丸（默认）。零学习成本，宽约 320pt。
//   primarySplit 左侧默认动作大按钮，右侧次要动作图标，竖线分隔。
//
// 偏好键用字符串直接落 UserDefaults：设置页（Settings 模块）只读这个键，
// 不引用 Capture 模块的类型，遵守跨模块纪律。
public enum CaptureToolbarStyle: String, CaseIterable, Identifiable {
    case iconBar
    case pillBar
    case primarySplit

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .iconBar:      return "图标条"
        case .pillBar:      return "药丸条"
        case .primarySplit: return "主次分离"
        }
    }

    public var caption: String {
        switch self {
        case .iconBar:      return "最紧凑"
        case .pillBar:      return "文字常显"
        case .primarySplit: return "常用放大"
        }
    }

    public static let preferenceKey = "capture.toolbar.style"

    /// 当前样式（未设置过 = 药丸条）
    public static var current: CaptureToolbarStyle {
        get {
            let raw = Preferences.shared.value(preferenceKey,
                                               default: CaptureToolbarStyle.pillBar.rawValue)
            return CaptureToolbarStyle(rawValue: raw) ?? .pillBar
        }
        set { Preferences.shared.set(preferenceKey, newValue.rawValue) }
    }
}
