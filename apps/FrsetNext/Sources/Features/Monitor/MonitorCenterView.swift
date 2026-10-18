import SwiftUI

// MARK: - 主面板页面状态（v60 简化）
//
// v60（2026-10-19 用户决策）：性能监测只保留独立窗口一套实现（MonitorPopoutWindow），
// 主面板里的「性能监测」页删除。主面板只剩两页：主页 / 文件中转站。
// 本文件仅保留页面状态与三段分段的状态源；原「监测中心」卡片视图
// （MonitorCenterView，v30 旧入口，注册位早已无人渲染）一并移除。
public enum PanelCenterPage {
    case home, transfer
}

public final class MonitorCenterPresenter: ObservableObject {
    /// 第三页：中转站（文件暂存与转发）
    @Published public var showsTransferDock = false

    /// 面板当前主页面（两段：主页 / 文件中转站）
    public var activePage: PanelCenterPage {
        showsTransferDock ? .transfer : .home
    }

    public func selectHome() {
        showsTransferDock = false
    }

    public func selectTransferDock() {
        showsTransferDock = true
    }

    /// 「文件中转」入口是否启用（设置 → 常规 → 功能，v41 新增开关）。
    /// 关闭时主面板顶部的第二段页签隐藏，设置窗口侧边栏也不显示该入口。
    public static var isTransferDockEnabled: Bool {
        Preferences.shared.value(Preferences.Keys.panelTransferDock, default: true)
    }

    public static let shared = MonitorCenterPresenter()

    public init() {}
}
