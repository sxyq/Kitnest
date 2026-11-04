import Foundation

// MARK: - 监测状态项文案（v210 大幅精简）
//
// 原先这里还有整套 `registerAll()` / 双层标题 / 隐藏标记——是 Swift 动态状态项的注册方。
// 该管线在 v128 被停用（菜单栏监测只允许 STATS 合并条一套），v210 整族删除。
// 现在只保留一个仍在用的纯文本格式化入口：监测详情/设置行里的功耗文案。

public enum MonitorStatusText {

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
}
