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

    /// 单行标题供菜单使用，菜单栏复用同一组双排数据。
    public static func cpuTitle() -> String {
        title(from: cpuTwoLine())
    }

    public static func memoryTitle() -> String {
        title(from: memoryTwoLine())
    }

    public static func networkTitle() -> String {
        title(from: networkTwoLine())
    }

    /// CPU：标签 / 百分比与趋势。
    public static func cpuTwoLine() -> (String, String)? {
        guard !MonitorPreferences.combinedMode else { return nil }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.cpu) else { return nil }
        let sample = MonitorSampler.shared.sample
        let trend = trendSymbol(MonitorSampler.shared.history.cpu)
        return ("CPU", "\(MonitorFormat.percent(sample.cpuUsage))\(trend)")
    }

    /// 内存：标签 / 百分比。
    public static func memoryTwoLine() -> (String, String)? {
        guard !MonitorPreferences.combinedMode else { return nil }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.memory) else { return nil }
        return ("RAM", MonitorFormat.percent(MonitorSampler.shared.sample.memoryPressure))
    }

    /// 网络（双层：上行 / 下行）——2026-10-16 用户诉求：双层省横向空间
    public static func networkTwoLine() -> (String, String)? {
        guard !MonitorPreferences.combinedMode else { return nil }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.network) else { return nil }
        let sample = MonitorSampler.shared.sample
        return ("↑\(MonitorFormat.compactRate(sample.netUpload))", "↓\(MonitorFormat.compactRate(sample.netDownload))")
    }

    public static func powerTitle() -> String {
        title(from: powerTwoLine())
    }

    /// 整机功耗：输入 / 输出标签与瓦数，接电保留 ⚡。
    public static func powerTwoLine() -> (String, String)? {
        guard !MonitorPreferences.combinedMode else { return nil }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.power) else { return nil }
        let sample = MonitorSampler.shared.sample
        guard let watts = sample.powerWatts else { return nil }
        let symbol = sample.powerIsInput ? "⚡" : ""
        return (sample.powerIsInput ? "输入" : "功耗", "\(symbol)\(MonitorFormat.power(watts))")
    }

    /// 功耗文案（输入/输出语义，详情与设置行用）
    public static func powerDetailText() -> String {
        let sample = MonitorSampler.shared.sample
        guard let watts = sample.powerWatts else { return "无数据" }
        let value = MonitorFormat.power(watts)
        if sample.powerIsInput {
            return sample.isCharging ? "输入 \(value)（充电中）" : "输入 \(value)"
        }
        return "输出 \(value)"
    }

    /// 磁盘：R 读 W 写
    public static func diskTitle() -> String {
        title(from: diskTwoLine())
    }

    /// 磁盘（双层：读取 / 写入）——与网络同款双层，省横向空间
    public static func diskTwoLine() -> (String, String)? {
        guard !MonitorPreferences.combinedMode else { return nil }
        guard MonitorPreferences.isEnabled, MonitorPreferences.isModuleEnabled(.disk) else { return nil }
        let sample = MonitorSampler.shared.sample
        return ("R\(MonitorFormat.compactRate(sample.diskRead))", "W\(MonitorFormat.compactRate(sample.diskWrite))")
    }

    /// 温度：最高温度（关闭温度采集或读不到时隐藏）
    public static func sensorsTitle() -> String {
        title(from: sensorsTwoLine())
    }

    public static func sensorsTwoLine() -> (String, String)? {
        guard !MonitorPreferences.combinedMode else { return nil }
        guard MonitorPreferences.isEnabled,
              MonitorPreferences.showTemperatures,
              MonitorPreferences.isModuleEnabled(.sensors) else { return nil }
        guard let value = MonitorSampler.shared.sample.temperatures.values.max() else { return nil }
        return ("温度", MonitorFormat.temperature(value))
    }

    /// 合并模式总览项：CPU / RAM 两排。
    public static func combinedTitle() -> String {
        title(from: combinedTwoLine())
    }

    public static func combinedTwoLine() -> (String, String)? {
        guard MonitorPreferences.isEnabled, MonitorPreferences.combinedMode else { return nil }
        let cpuEnabled = MonitorPreferences.isModuleEnabled(.cpu)
        let memoryEnabled = MonitorPreferences.isModuleEnabled(.memory)
        guard cpuEnabled || memoryEnabled else { return nil }
        let sample = MonitorSampler.shared.sample
        return (cpuEnabled ? "CPU\(MonitorFormat.percent(sample.cpuUsage))" : "",
                memoryEnabled ? "RAM\(MonitorFormat.percent(sample.memoryPressure))" : "")
    }

    private static func title(from pair: (String, String)?) -> String {
        guard let pair else { return hiddenMarker }
        return [pair.0, pair.1].filter { !$0.isEmpty }.joined(separator: " ")
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

    /// 注册全部监测状态栏项，统一使用现有双排渲染链。
    public static func registerAll() {
        register(id: "monitor.power", priority: 9, title: powerTitle,
                 twoLineTitle: powerTwoLine) {
            AnyView(MonitorDetailView(module: .power))
        }
        register(id: "monitor.cpu", priority: 10, title: cpuTitle,
                 twoLineTitle: cpuTwoLine) {
            AnyView(MonitorDetailView(module: .cpu))
        }
        register(id: "monitor.network", priority: 11, title: networkTitle,
                 twoLineTitle: networkTwoLine) {
            AnyView(MonitorDetailView(module: .network))
        }
        register(id: "monitor.memory", priority: 12, title: memoryTitle,
                 twoLineTitle: memoryTwoLine) {
            AnyView(MonitorDetailView(module: .memory))
        }
        register(id: "monitor.disk", priority: 13, title: diskTitle,
                 twoLineTitle: diskTwoLine) {
            AnyView(MonitorDetailView(module: .disk))
        }
        register(id: "monitor.sensors", priority: 14, title: sensorsTitle,
                 twoLineTitle: sensorsTwoLine) {
            AnyView(MonitorDetailView(module: .sensors))
        }
        register(id: "monitor.combined", priority: 15, title: combinedTitle,
                 twoLineTitle: combinedTwoLine) {
            AnyView(MonitorDetailView(module: .cpu))
        }
    }

    private static func register(id: String,
                                 priority: Int,
                                 title: @escaping () -> String,
                                 twoLineTitle: (() -> (String, String)?)? = nil,
                                 popover: @escaping () -> AnyView) {
        StatusItemRegistry.register(StatusItemDescriptor(
            id: id,
            priority: priority,
            title: title,
            twoLineTitle: twoLineTitle,
            onTap: nil,
            popover: popover
        ))
    }
}
