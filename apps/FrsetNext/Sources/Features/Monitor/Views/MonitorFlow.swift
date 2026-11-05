import AppKit
import SwiftUI

// MARK: - 监测页可视化基元（v181）
//
// 用户需求（2026-11-02）：「按『数据是否已经有 × 用户是否真的想知道』排序，
// 把这几个可视化做出来」——网络「带宽去哪了」、功耗流向图、温度分区热区条、
// 内存构成堆叠条、磁盘容量构成。
//
// 本文件只放**可复用的基元**，具体接线在各页（MonitorDetailView）：
//   · MonitorFlowCard —— 同款流向图（电池页已用同一套：来源 → 流带 → 分支）
//   · MonitorZoneHeatStrip —— 分区热区条（CPU/GPU/电池/SSD，按阈值着色）
//   · MonitorThermalZones —— 把 200+ 颗传感器按名字/分组折成 4 个区
//   · MonitorDiskSpace —— 磁盘「可清除」容量（系统按需回收的那部分）

// MARK: - 流向图（通用）

/// 流向图节点：一个来源 / 一个分支。
/// `value` 只决定流带粗细（瓦、字节/秒…都行），`valueText` 决定显示文本——
/// 这样同一张图既能画「瓦特」也能画「带宽」，不必复制一套布局。
struct MonitorFlowNode: Identifiable {
    let id: String
    let title: String
    let value: Double
    let valueText: String
    let systemImage: String
    let color: Color
    /// false = 没拿到读数（显示「—」，绝不补 0）
    let available: Bool
    /// 数值字号：带宽这类「↓1.2M / ↑80K」的长文本用 compact
    var compactValue: Bool = false
    /// 真实 App 图标（网络分流用；为空时退回 systemImage 的 SF Symbol）
    var iconImage: NSImage? = nil
    /// 悬停提示：例如「10 分钟 12.4 MB · 当前 ↓1.2 MB/s」
    var detail: String? = nil
    /// 当前是否有实际流量（网络分流用：亮一个小圆点，让「正在跑」的 App 一眼可见）
    var isActive: Bool = false
}

/// 通用流向图卡片：左侧来源 │ 中间流带（宽度按比例）│ 右侧分支。
/// 与电池页那张是**同一套几何**（FlowRibbon），只是底板可选：
/// `.glass` = 标准玻璃卡片；`.gridded` = 电池页那张带坐标网格的纹理卡。
struct MonitorFlowCard: View {

    enum Plate { case glass, gridded }

    let input: MonitorFlowNode
    let branches: [MonitorFlowNode]
    var height: CGFloat = 116
    var plate: Plate = .glass

    private let tileSpacing: CGFloat = 4
    private let maxBand: CGFloat = 34

    private var maxValue: Double {
        max(0.001, max(input.value, branches.reduce(0) { $0 + $1.value }))
    }

    private func thickness(_ value: Double) -> CGFloat {
        // 0 W 的分支也要留一条发丝带：否则「充入电池 0 W」的格子旁边什么都没有，
        // 看起来像图没画完。视觉上它是「很细 = 没有流量」，语义仍然准确。
        guard value > 0 else { return 1.5 }
        return max(2, CGFloat(value / maxValue) * maxBand)
    }

    /// 每个分支格的最小高度：图标/数值 + 名字，少一行就压字
    private static let minTileHeight: CGFloat = 34

    /// v183（用户：「分流图文本有超出」）：高度原来固定 116，4 个分支时每格只有
    /// 24.5pt，而一格内容是图标 10 + 数值 10.5 + 名字 9.5 + 行距 ≈ 33pt —— 必然溢出。
    /// 现在按分支数反推高度，只增不减。
    private var resolvedHeight: CGFloat {
        let n = CGFloat(max(1, branches.count))
        return max(height, n * Self.minTileHeight + CGFloat(max(0, branches.count - 1)) * tileSpacing)
    }

    private var tileHeight: CGFloat {
        let n = max(1, branches.count)
        return (resolvedHeight - CGFloat(n - 1) * tileSpacing) / CGFloat(n)
    }

    var body: some View {
        HStack(spacing: 0) {
            // v183：分支多时卡片会变高（5 个 = 224pt），左侧来源格若跟着拉满，
            // 就是一大片空盒子。固定上限 136 并垂直居中，视觉重心才稳。
            inputTile
                .frame(width: 88, height: min(resolvedHeight, 136))
                .frame(maxHeight: .infinity, alignment: .center)
            ribbonArea.frame(maxWidth: .infinity)
            VStack(spacing: tileSpacing) {
                ForEach(branches) { node in
                    branchTile(node)
                }
            }
            .frame(width: 134)
        }
        .frame(height: resolvedHeight)
        .padding(8)
        .background { plateBackground }
        // 数值变化时流带平滑过渡：数据每 5 秒换一档，硬切会让整张图「跳」一下
        .animation(Theme.Motion.page, value: branches.map(\.value))
    }

    @ViewBuilder private var plateBackground: some View {
        switch plate {
        case .glass:
            Color.clear.glassCard(radius: 10)
        case .gridded:
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [Color.primary.opacity(0.055),
                                                  Color.primary.opacity(0.015)],
                                         startPoint: .top, endPoint: .bottom))
                GeometryReader { geo in
                    Path { p in
                        for i in 1...3 {
                            let y = geo.size.height * CGFloat(i) / 4
                            p.move(to: CGPoint(x: 10, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width - 10, y: y))
                        }
                    }
                    .stroke(Color.primary.opacity(0.045), lineWidth: 0.5)
                }
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
        }
    }

    private var inputTile: some View {
        VStack(spacing: 2) {
            nodeIcon(input, size: 12, fallbackFont: 11)
                .padding(.bottom, 2)
            Text(input.available ? input.valueText : "—")
                .font(.system(size: input.compactValue ? 12.5 : 15, weight: .semibold)
                    .monospacedDigit())
                .foregroundStyle(input.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(input.title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(radius: Theme.Radius.control)
        .padding(.trailing, 6)
    }

    /// 节点图标：有真实 App 图标就用它（网络分流），否则用 SF Symbol（功耗/电池等）
    @ViewBuilder
    private func nodeIcon(_ node: MonitorFlowNode, size: CGFloat, fallbackFont: CGFloat) -> some View {
        if let image = node.iconImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: node.systemImage)
                .font(.system(size: fallbackFont))
                .foregroundStyle(node.color)
        }
    }

    private func branchTile(_ node: MonitorFlowNode) -> some View {
        // v183：图标与数值同一行（原来三行竖排，格子一矮就压字）；
        // 名字单独一行、中间省略，长 App 名不会把数值顶出去。
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                nodeIcon(node, size: 14, fallbackFont: 9.5)
                Text(node.available ? node.valueText : "—")
                    .font(.system(size: node.compactValue ? 10.5 : 13, weight: .semibold)
                        .monospacedDigit())
                    .foregroundStyle(node.value < 0.05 ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if node.isActive {
                    Circle()
                        .fill(node.color)
                        .frame(width: 4, height: 4)
                        .help("当前正在传输")
                }
            }
            Text(node.title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // v183：从「一块 10% 平涂」改成「渐变 + 同色发丝边」——
            // 四五个格子堆在一起时，平涂会糊成一片，分不清边界。
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(LinearGradient(colors: [node.color.opacity(0.16),
                                              node.color.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(node.color.opacity(0.22), lineWidth: 0.5)
        )
        .help(node.detail ?? node.title)
    }

    /// 中间的流带：宽度按数值比例（几何与电池页完全一致）
    private var ribbonArea: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let gap: CGFloat = 2
            let widths = branches.map { thickness($0.value) }
            let total = widths.reduce(0, +) + gap * CGFloat(max(0, branches.count - 1))

            let bands: [(node: MonitorFlowNode, start: CGFloat, end: CGFloat, width: CGFloat)] = {
                var out: [(MonitorFlowNode, CGFloat, CGFloat, CGFloat)] = []
                var cursor = h / 2 - total / 2
                for (index, node) in branches.enumerated() {
                    let w = widths[index]
                    let endCenter = CGFloat(index) * (tileHeight + tileSpacing) + tileHeight / 2
                    out.append((node, cursor + w / 2, endCenter, w))
                    cursor += w + gap
                }
                return out
            }()

            ZStack {
                ForEach(bands.indices, id: \.self) { i in
                    let band = bands[i]
                    let bend: CGFloat = branches.count == 1 ? 6 : (i == 0 ? -4 : 4)
                    let shape = FlowRibbon(startCenter: band.start,
                                           endCenter: band.end,
                                           startThickness: band.width,
                                           endThickness: max(2, band.width * 0.88),
                                           bend: bend)
                    shape
                        .fill(LinearGradient(colors: [band.node.color.opacity(0.72),
                                                      band.node.color.opacity(0.42)],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay(shape.stroke(band.node.color.opacity(0.22), lineWidth: 0.5))
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - 温度分区热区条

/// 一个热区（CPU / GPU / 电池 / SSD）
struct MonitorThermalZone: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// 该区最热的一颗（区温按「最热」口径，避免平均值把热点抹平）
    let celsius: Double
    let sensorCount: Int
    let hottestName: String
}

enum MonitorThermalZones {

    /// 传感器按名字/分组折成 4 个区。命中不了任何区的传感器不显示——
    /// 宁缺勿假，不要为了凑四行编数据。
    static func build(from sensors: [StatsSensorItem],
                      fallback: (cpu: Double?, thermal: [Double]) = (nil, [])) -> [MonitorThermalZone] {
        let temps = sensors.filter { $0.category == 0 && $0.value > 0 && $0.value < 130 }

        func match(_ item: StatsSensorItem, keywords: [String], groups: [Int]) -> Bool {
            if groups.contains(item.group) { return true }
            let n = item.name.lowercased()
            return keywords.contains { n.contains($0) }
        }

        let specs: [(id: String, title: String, icon: String, groups: [Int], keys: [String])] = [
            ("cpu", "CPU", "cpu", [1], ["cpu", "core", "p-core", "e-core", "soc"]),
            ("gpu", "GPU", "cube.transparent", [2], ["gpu", "gfx"]),
            ("battery", "电池", "battery.50percent", [], ["battery", "电池", "gas gauge"]),
            ("ssd", "SSD", "internaldrive", [], ["ssd", "nand", "nvme", "flash", "闪存"]),
        ]

        var zones: [MonitorThermalZone] = []
        for spec in specs {
            let hits = temps.filter { match($0, keywords: spec.keys, groups: spec.groups) }
            guard let hottest = hits.max(by: { $0.value < $1.value }) else { continue }
            zones.append(MonitorThermalZone(id: spec.id, title: spec.title, systemImage: spec.icon,
                                            celsius: hottest.value, sensorCount: hits.count,
                                            hottestName: hits.count > 1 ? hottest.name : ""))
        }
        return zones
    }

    /// 阈值配色：<60 正常 / 60–80 偏热 / ≥80 过热
    static func color(for celsius: Double) -> Color {
        if celsius >= 80 { return Color(red: 0.90, green: 0.25, blue: 0.28) }
        if celsius >= 60 { return Color(red: 0.95, green: 0.62, blue: 0.18) }
        return MonitorColors.memory
    }

}

/// 分区热区条：一行一个区（名称 + 0–110°C 标尺条 + 温度），温度按阈值变色。
struct MonitorZoneHeatStrip: View {

    let zones: [MonitorThermalZone]
    /// 标尺上限（°C）
    var scaleMax: Double = 110

    var body: some View {
        VStack(spacing: 7) {
            ForEach(zones) { zone in
                row(zone)
            }
            legend
        }
    }

    private func row(_ zone: MonitorThermalZone) -> some View {
        let color = MonitorThermalZones.color(for: zone.celsius)
        let ratio = min(1, max(0.01, zone.celsius / scaleMax))
        return HStack(spacing: 8) {
            Image(systemName: zone.systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 13)
            Text(zone.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color)
                        .frame(width: max(3, geo.size.width * CGFloat(ratio)))
                }
            }
            .frame(height: 7)
            Text(MonitorFormat.temperature(zone.celsius))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 48, alignment: .trailing)
        }
        .help(zone.sensorCount > 1
              ? "\(zone.title)：\(zone.sensorCount) 颗传感器，取最热\(zone.hottestName.isEmpty ? "" : "（\(zone.hottestName)）")"
              : zone.title)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            dot("正常 <60°", color: MonitorColors.memory)
            dot("偏热 60–80°", color: Color(red: 0.95, green: 0.62, blue: 0.18))
            dot("过热 ≥80°", color: Color(red: 0.90, green: 0.25, blue: 0.28))
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.tertiaryText)
    }

    private func dot(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title)
        }
    }
}

// MARK: - 磁盘容量：可清除

enum MonitorDiskSpace {

    /// 「可清除」= 系统为重要用途可临时腾出的容量 − 当前空闲。
    /// （快照、缓存、废纸篓这类系统按需回收的空间；读不到就是 0，不猜。）
    static func purgeableBytes(freeBytes: UInt64,
                               volume: URL = URL(fileURLWithPath: "/")) -> UInt64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage,
              important > 0 else { return 0 }
        let importantBytes = UInt64(important)
        guard importantBytes > freeBytes else { return 0 }
        return importantBytes - freeBytes
    }
}
