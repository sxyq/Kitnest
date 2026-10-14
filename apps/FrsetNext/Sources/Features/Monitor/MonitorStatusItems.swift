import Foundation
import SwiftUI

// MARK: - 状态栏部件注册（08 号状态栏模块消费）

/// 状态栏文案前缀：表示该项当前应被隐藏（总开关关闭 / 模块关闭 / 合并模式）。
/// 状态栏模块在渲染时可用 `MonitorStatusItems.isHidden(id:title:)` 过滤，
/// 或直接调用 `MonitorPreferences.visibleStatusItemIDs()` 取允许显示的 id 集合。
public enum MonitorStatusItems {
    public static let hiddenMarker = "⟨monitor:hidden⟩"

    /// 该项当前是否应隐藏（关闭的模块、合并模式下的分项、无数据的温度项都会返回 true）
    public static func isHidden(id: String) -> Bool {
        !MonitorPreferences.visibleStatusItemIDs().contains(id)
    }

    /// CPU：迷你折线用文本近似（百分比 + 趋势箭头）
    public static func cpuTitle() -> String {
        guard !MonitorPreferences.combinedMode else { return hiddenMarker }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.cpu) else { return hiddenMarker }
        let sample = MonitorSampler.shared.sample
        let trend = trendSymbol(MonitorSampler.shared.history.cpu)
        return "\(MonitorFormat.percent(sample.cpuUsage))\(trend)"
    }

    /// 内存：百分比
    public static func memoryTitle() -> String {
        guard !MonitorPreferences.combinedMode else { return hiddenMarker }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.memory) else { return hiddenMarker }
        let sample = MonitorSampler.shared.sample
        return MonitorFormat.percent(sample.memoryPressure)
    }

    /// 网络：↑上传 ↓下载
    public static func networkTitle() -> String {
        guard !MonitorPreferences.combinedMode else { return hiddenMarker }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.network) else { return hiddenMarker }
        let sample = MonitorSampler.shared.sample
        return "↑\(MonitorFormat.rate(sample.netUpload)) ↓\(MonitorFormat.rate(sample.netDownload))"
    }

    /// 磁盘：R 读 W 写
    public static func diskTitle() -> String {
        guard !MonitorPreferences.combinedMode else { return hiddenMarker }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.disk) else { return hiddenMarker }
        let sample = MonitorSampler.shared.sample
        return MonitorFormat.diskRate(read: sample.diskRead, write: sample.diskWrite)
    }

    /// 温度：最高温度（关闭温度采集或读不到时隐藏）
    public static func sensorsTitle() -> String {
        guard !MonitorPreferences.combinedMode else { return hiddenMarker }
        guard MonitorPreferences.isEnabled,
              MonitorPreferences.showTemperatures,
              MonitorPreferences.isModuleEnabled(.sensors) else { return hiddenMarker }
        guard let value = MonitorSampler.shared.sample.temperatures.values.max() else { return hiddenMarker }
        return MonitorFormat.temperature(value)
    }

    /// 合并模式总览项：CPU 占用 + 图标
    public static func combinedTitle() -> String {
        guard MonitorPreferences.isEnabled else { return hiddenMarker }
        guard MonitorPreferences.combinedMode else { return hiddenMarker }
        return "⁘ \(MonitorFormat.percent(MonitorSampler.shared.sample.cpuUsage))"
    }

    /// 趋势近似：比较最近两点
    private static func trendSymbol(_ values: [Double]) -> String {
        guard values.count >= 2 else { return "" }
        let delta = values[values.count - 1] - values[values.count - 2]
        if delta > 0.03 { return "↑" }
        if delta < -0.03 { return "↓" }
        return "→"
    }

    // MARK: - 注册

    /// 注册全部监测状态栏项（CPU / 内存 / 网络 / 磁盘 / 温度 / 合并总览）
    public static func registerAll() {
        register(id: "monitor.cpu", priority: 10, title: cpuTitle) {
            AnyView(MonitorDetailView(module: .cpu))
        }
        register(id: "monitor.network", priority: 11, title: networkTitle) {
            AnyView(MonitorDetailView(module: .network))
        }
        register(id: "monitor.memory", priority: 12, title: memoryTitle) {
            AnyView(MonitorDetailView(module: .memory))
        }
        register(id: "monitor.disk", priority: 13, title: diskTitle) {
            AnyView(MonitorDetailView(module: .disk))
        }
        register(id: "monitor.sensors", priority: 14, title: sensorsTitle) {
            AnyView(MonitorDetailView(module: .sensors))
        }
        register(id: "monitor.combined", priority: 15, title: combinedTitle) {
            AnyView(MonitorDetailView(module: .cpu))
        }
    }

    private static func register(id: String,
                                 priority: Int,
                                 title: @escaping () -> String,
                                 popover: @escaping () -> AnyView) {
        StatusItemRegistry.register(StatusItemDescriptor(
            id: id,
            priority: priority,
            title: title,
            onTap: nil,
            popover: popover
        ))
    }
}
