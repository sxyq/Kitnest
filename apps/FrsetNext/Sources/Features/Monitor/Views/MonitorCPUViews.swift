import Foundation
import SwiftUI

// MARK: - CPU 页补充信息（v183）
//
// 用户反馈：「CPU 页十分的空」——原来只有两个环 + 四行数字 + 一张没有刻度的曲线，
// 旁边还常因读不到温度传感器空出半个环位。
//
// 这个文件补三块**本机真实可读**的信息（不编数据）：
//   ① 芯片规格：型号 / 核心构成 / 系统版本（sysctl）
//   ② 每核心占用：C1…Cn 的迷你柱 + 百分比（原来是一排等高蓝块，没有刻度）
//   ③ 热压力：ProcessInfo.thermalState（没有温度传感器时的替代指标）

enum CPUHardware {

    /// 芯片名（Apple Silicon / Intel 都由 sysctl 提供；读不到就退回「Apple Silicon」）
    static let brand: String = {
        sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? "Apple Silicon"
    }()

    static let physicalCores: Int = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount

    static let logicalCores: Int = max(1, sysctlInt("hw.logicalcpu") ?? physicalCores)

    /// 系统版本（只取数字段：27.0.1）
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }()

    /// 热压力：没有温度传感器时也能反映「机器是不是在硬撑」
    static var thermal: (text: String, color: Color) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return ("热压力 正常", MonitorColors.memory)
        case .fair:     return ("热压力 偏热", MonitorColors.compressed)
        case .serious:  return ("热压力 过热", MonitorColors.system)
        case .critical: return ("热压力 严重", MonitorColors.system)
        @unknown default: return ("热压力 未知", .secondary)
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

// MARK: - 每核心占用

/// 每核心占用：一行一个小柱 + 核编号 + 百分比。
/// 原来用 `MonitorBarChart` 画一排等高蓝块——没有刻度、看不出单核数值；
/// 这里每格自带百分比，柱高按 0…1 映射。
struct MonitorCoreGrid: View {

    let values: [Double]
    var columns: Int = 5
    var accent: Color = MonitorColors.user

    var body: some View {
        let count = values.count
        let columnCount = max(1, min(columns, count))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                 count: columnCount),
                  spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, raw in
                tile(index: index, raw: raw)
            }
        }
    }

    private func tile(index: Int, raw: Double) -> some View {
        let ratio = min(1, max(0, raw.isFinite ? raw : 0))
        // 单核打满时全部同色蓝块，看不出哪颗在硬扛——按负载分三档着色：
        // ≥90% 红、≥70% 橙、其余蓝（与「系统/偏热/用户」同一套语义色）
        let fill = ratio >= 0.90 ? MonitorColors.system
            : (ratio >= 0.70 ? MonitorColors.compressed : accent)
        return VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fill.opacity(0.35 + 0.65 * ratio))
                    .frame(height: max(2, 26 * ratio))
            }
            .frame(height: 26)

            Text("C\(index + 1)")
                .font(.system(size: 8))
                .foregroundStyle(Theme.tertiaryText)
            Text(String(format: "%.0f%%", ratio * 100))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(ratio >= 0.90 ? MonitorColors.system : .secondary)
        }
        .frame(maxWidth: .infinity)
        .help("核心 \(index + 1)：\(String(format: "%.0f%%", ratio * 100))")
    }
}

/// 集群胶囊（P / E，可选 M）：一行小卡，数值按占比着色
struct MonitorClusterPill: View {
    let title: String
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(MonitorFormat.percent(value))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
        )
    }
}
