import SwiftUI

// MARK: - 主面板页面状态
//
// v71（2026-10-19 用户需求）：主面板顶部**恢复三页切换**（主页 │ 性能监测 │ 文件中转）。
// 性能页内容直接复用 MonitorDetailView（与独立窗同一套面板组件，不多一套实现）；
// 模块选中态由本 presenter 持有（主面板与独立窗各自独立记忆）。
public enum PanelCenterPage {
    case home, performance, transfer
}

public final class MonitorCenterPresenter: ObservableObject {
    /// 面板当前主页面（三段：主页 / 性能监测 / 文件中转站）
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
    }

    public func selectTransferDock() {
        page = .transfer
        // v84：文件中转页打开埋点
        StatisticsManager.shared.record(.transferDockOpen)
    }

    /// 「文件中转」入口是否启用（设置 → 常规 → 功能，v41 新增开关）。
    /// 关闭时主面板顶部的第三段页签隐藏，设置窗口侧边栏也不显示该入口。
    public static var isTransferDockEnabled: Bool {
        Preferences.shared.value(Preferences.Keys.panelTransferDock, default: true)
    }

    public static let shared = MonitorCenterPresenter()

    public init() {}
}
