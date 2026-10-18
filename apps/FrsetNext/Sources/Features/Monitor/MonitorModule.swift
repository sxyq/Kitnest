import Foundation
import SwiftUI

/// 监测模块入口：启动采样器并完成三项注册（面板区段 / 设置页签 / 状态栏项）。
public enum MonitorModule: AppModule {
    public static let identifier = "monitor"

    public static func start() {
        // 1) 启动采样（间隔/开关由 MonitorPreferences 决定，可在设置里随时改）
        MonitorSampler.shared.start()

        // 2) 主面板「监测中心」区段
        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "monitor",
            title: "监测中心",
            priority: 10,
            build: { AnyView(MonitorCenterView()) }
        ))

        // 3) 设置窗口「监测」页签
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "monitor",
            title: "监测",
            systemImage: "gauge",
            build: { AnyView(MonitorSettingsPane()) }
        ))

        // 4) 官方原版菜单栏 4 个独立监控项（网速/CPU/RAM/SSD）——**不再注册**。
        //    v42（2026-10-18 用户指示）：我们已有更好的呈现方式（STATS 合并条：
        //    多模块合并、12 种部件形态、配置与 Stats 互通），不必再摆官方那 4 个
        //    独立图标去抢菜单栏位置。MonitorStatusItems 保留在工程内，需要时可恢复。
        //    MonitorStatusItems.registerAll()

        // 5) STATS 部件引擎（菜单栏合并条：12 形态 × 7 模块，配置与 Stats 互通）。
        StatsBarEngine.start()

        Log.info("Monitor", "监测模块已启动")
    }

    /// 停止采样（总开关关闭 / App 退出前可调用）
    public static func stop() {
        MonitorSampler.shared.stop()
        StatsBarEngine.stop()
    }
}
