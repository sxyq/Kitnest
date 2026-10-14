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

        // 4) 状态栏部件（CPU / 网络 / 内存 / 磁盘 / 温度 + 合并总览）
        MonitorStatusItems.registerAll()

        Log.info("Monitor", "监测模块已启动")
    }

    /// 停止采样（总开关关闭 / App 退出前可调用）
    public static func stop() {
        MonitorSampler.shared.stop()
    }
}
