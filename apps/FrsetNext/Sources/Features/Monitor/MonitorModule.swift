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

        // 4) STATS 部件引擎（菜单栏合并条：12 形态 × 7 模块，配置与 Stats 互通）。
        //    引擎启用后重建版自带的 monitor.* 双排状态项不再注册——合并条即其替代
        //    （与注入版「原生项隐藏、合并条呈现」观感一致；功耗/网络等数据改由
        //     合并条部件 + 监测面板呈现）。
        StatsBarEngine.start()

        Log.info("Monitor", "监测模块已启动")
    }

    /// 停止采样（总开关关闭 / App 退出前可调用）
    public static func stop() {
        MonitorSampler.shared.stop()
        StatsBarEngine.stop()
    }
}
