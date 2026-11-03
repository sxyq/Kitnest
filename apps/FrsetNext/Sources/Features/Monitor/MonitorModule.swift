import Foundation
import SwiftUI

/// 监测模块入口：启动采样器并完成三项注册（面板区段 / 设置页签 / 状态栏项）。
public enum MonitorModule: AppModule {
    public static let identifier = "monitor"

    public static func start() {
        // 1) 启动采样（间隔/开关由 MonitorPreferences 决定，可在设置里随时改）
        MonitorSampler.shared.start()

        // 1.5) v191：网络统计常驻——不打开监测页也在累计最近 10 分钟，
        //      打开网络页立刻有数据（用户：「应该就一直放在那，只是会变化显示的 App」）
        NetworkFlowTracker.shared.startBackgroundUpdates()

        // 2) 设置窗口「监测」页签
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "monitor",
            title: "监测",
            systemImage: "gauge",
            build: { AnyView(MonitorSettingsPane()) }
        ))

        // 3) 官方原版菜单栏 4 个独立监控项（网速/CPU/RAM/SSD）——**不再注册**。
        //    v42（2026-10-18 用户指示）：我们已有更好的呈现方式（STATS 合并条：
        //    多模块合并、12 种部件形态、配置与 Stats 互通），不必再摆官方那 4 个
        //    独立图标去抢菜单栏位置。MonitorStatusItems 保留在工程内，需要时可恢复。
        //    MonitorStatusItems.registerAll()

        // 4) STATS 部件引擎（菜单栏合并条：12 形态 × 7 模块，配置与 Stats 互通）。
        //    v60：部件点击 → 监测独立窗口（主面板性能页已删，只留独立窗一套）。
        StatsBarEngine.start()

        // 排障探针（v178）：probe.batteryPage=YES → 启动 3.5s 后打开电池页。
        // 电池页在独立监测窗里，能直接截图核对版式（主面板窗在别的 Space 截不到）。
        if UserDefaults.standard.bool(forKey: "probe.batteryPage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                MonitorPopoutWindowController.shared.open(module: .battery)
            }
        }

        // 5) 监测独立窗口空闲预热（v62：冷启动首开 489ms → 预热后 ~140ms）
        MonitorPopoutWindowController.shared.scheduleWarmup()

        Log.info("Monitor", "监测模块已启动")
    }

    /// 停止采样（总开关关闭 / App 退出前可调用）
    public static func stop() {
        MonitorSampler.shared.stop()
        StatsBarEngine.stop()
    }
}
