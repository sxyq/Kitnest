import Foundation

// MARK: - 主面板顶部页面开关（v177）
//
// 用户需求：「设置里可以自定义顶部的中转 / 首页 / 监测 / 投屏这些按钮的展现与显示，
// 并且动态加载；如果全关闭了，就不占内存」。
//
// 这里只负责「哪些页面启用」这一份事实。真正的懒加载在 `PanelRootView`：
// 内容用 if/else 分支，未选中的分支不会被创建；关掉的页面更不会被创建，
// 因此 `TransferDockView` / `CastView` 这类重型视图连 init 都不会跑。
//
// 与旧开关 `panel.transferDock` 的关系：
// - 旧开关是「是否启用文件中转这个功能」（还会影响别的模块），语义更重；
// - 新开关只决定「顶部要不要出现这个分段」。
// 两者是**与**关系：功能没启用时，分段即使勾了也不出现。

public enum PanelSegments {

    public static let homeKey = "panel.segment.home"
    public static let monitorKey = "panel.segment.monitor"
    public static let transferKey = "panel.segment.transfer"
    public static let castKey = "panel.segment.cast"

    public static func key(for page: PanelCenterPage) -> String {
        switch page {
        case .home:        return homeKey
        case .performance: return monitorKey
        case .transfer:    return transferKey
        case .cast:        return castKey
        }
    }

    public static func title(_ page: PanelCenterPage) -> String {
        switch page {
        case .home:        return "主页"
        case .performance: return "监测"
        case .transfer:    return "中转"
        case .cast:        return "投屏"
        }
    }

    public static func isEnabled(_ page: PanelCenterPage) -> Bool {
        Preferences.shared.value(key(for: page), default: true)
    }

    public static func setEnabled(_ page: PanelCenterPage, _ on: Bool) {
        Preferences.shared.set(key(for: page), on)
    }

    /// 按声明顺序返回启用项（中转/投屏还受旧的总开关约束）
    public static func enabledPages() -> [PanelCenterPage] {
        let transferFeature = Preferences.shared.value(Preferences.Keys.panelTransferDock, default: true)
        var pages: [PanelCenterPage] = []
        if isEnabled(.home) { pages.append(.home) }
        if isEnabled(.performance) { pages.append(.performance) }
        if transferFeature, isEnabled(.transfer) { pages.append(.transfer) }
        if transferFeature, isEnabled(.cast) { pages.append(.cast) }
        return pages
    }
}
