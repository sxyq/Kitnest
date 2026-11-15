import SwiftUI

// MARK: - 主面板页面状态
//
// v71（2026-10-19 用户需求）：主面板顶部**恢复三页切换**（主页 │ 性能监测 │ 文件中转）。
// 性能页内容直接复用 MonitorDetailView（与独立窗同一套面板组件，不多一套实现）；
// 模块选中态由本 presenter 持有（主面板与独立窗各自独立记忆）。
//
// v114（2026-10-25 用户需求）：投屏从「文件中转」拆成独立第四页——
// 顶部四段：主页 │ 性能监测 │ 文件中转 │ 投屏（左右切换）。
public enum PanelCenterPage: String, CaseIterable {
    case home, performance
}

public final class MonitorCenterPresenter: ObservableObject {
    /// 面板当前主页面（四段：主页 / 性能监测 / 文件中转 / 投屏）
    @Published public var page: PanelCenterPage = .home
    /// 性能页当前模块（**主面板与状态栏独立窗共用这一份**；改这里两边同时切换）
    @Published public var monitorSelection = MonitorDetailSelection(.cpu)

    /// 兼容旧读取方（activePage）
    public var activePage: PanelCenterPage { page }

    public func selectHome() {
        page = .home
    }

    public func selectPerformance(module: MonitorModuleID? = nil) {
        if let module { monitorSelection.module = module }
        page = .performance
        // v84：性能监测页打开埋点（面板段切换 / URL 深链 / 状态栏部件点击共用）
        StatisticsManager.shared.record(.monitorPanelOpen)
        // v107（2026-10-21 用户：「活动监测也要计入使用统计」）：原版键
        // activityMonitorClick 从未落点——监测中心即「活动监测」功能入口，补记
        StatisticsManager.shared.record(.activityMonitorClick)
    }

    public static let shared = MonitorCenterPresenter()

    public init() {}
}
