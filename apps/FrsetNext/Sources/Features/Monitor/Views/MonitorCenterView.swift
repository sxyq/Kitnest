import SwiftUI

// MARK: - 主面板页面状态
//
// 主面板顶部两页切换：主页 │ 性能监测。性能页内容复用 MonitorDetailView
//（与独立窗同一套组件，不多一套实现）；模块选中态由本 presenter 持有。
public enum PanelCenterPage: String, CaseIterable {
    case home, performance
}

public final class MonitorCenterPresenter: ObservableObject {
    /// 面板当前主页面（主页 / 性能监测）
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
