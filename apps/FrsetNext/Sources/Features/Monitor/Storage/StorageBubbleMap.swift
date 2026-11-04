import AppKit
import SwiftUI

// MARK: - 存储管理 · 气泡地图（v211）
//
// 参考截图（Kanso）的「设计形式 + 交互」：右侧一大片按占用面积排布的圆形气泡，
// 点气泡 = 进入该目录继续下钻，hover 放大，选中描边；左侧清单负责勾选清理。
// 本文件只换我们的配色（中性灰阶 + Theme.accent），不改布局逻辑与交互方式：
//   · 背景同心圆角线 = 枯山水涟漪，但用强调色极淡描边，不引入第二套色板；
//   · 气泡填充按体积在 primary 灰阶上递进，选中才用 Theme.accent。

struct DiskBubble: Identifiable {
    let node: DiskNode
    let center: CGPoint
    let radius: CGFloat
    /// 相对最大项的体量（0...1），用于配色深浅
    let weight: Double
    var id: String { node.id }
}

enum DiskBubbleLayout {
    /// 确定性圆堆布局：黄金角螺旋 + 碰撞检测，失败则缩小半径重试。
    /// 纯计算、无随机源，窗口尺寸变化不会让气泡乱跳。
    static func make(nodes: [DiskNode], in size: CGSize) -> [DiskBubble] {
        guard size.width > 40, size.height > 40 else { return [] }
        let maxSize = max(Int64(1), nodes.map { $0.size }.max() ?? 1)
        let maxRadius = min(size.width, size.height) * 0.25
        let spread = min(size.width, size.height) * 0.44
        var placed: [DiskBubble] = []

        for (i, n) in nodes.enumerated() {
            let t = sqrt(Double(max(Int64(1), n.size)) / Double(maxSize))
            var radius = max(16, min(maxRadius, CGFloat(t) * maxRadius))
            var center: CGPoint?
            var attempts = 0
            while center == nil, attempts < 3 {
                for step in 0..<160 {
                    let angle = Double(i * 47 + step * 11) * 2.39996323
                    let radial = sqrt(Double(step + 1) / 160.0) * Double(spread)
                    let x = size.width / 2 + cos(angle) * radial
                    let y = size.height / 2 + sin(angle) * radial
                    if x - radius < 6 || x + radius > size.width - 6
                        || y - radius < 6 || y + radius > size.height - 6 { continue }
                    if placed.contains(where: { p in
                        hypot(p.center.x - x, p.center.y - y) < p.radius + radius + 3
                    }) { continue }
                    center = CGPoint(x: x, y: y)
                    break
                }
                if center == nil { radius *= 0.78; attempts += 1 }
            }
            guard let c = center else { continue }
            placed.append(DiskBubble(node: n, center: c, radius: radius, weight: t))
        }
        return placed
    }
}

struct StorageBubbleMap: View {
    let node: DiskNode
    /// 目录气泡点击 → 下钻
    let onDrill: (DiskNode) -> Void
    /// 文件/叶子气泡点击 → 选中（右侧底部详情 + 删除）
    let onSelect: (DiskNode) -> Void

    @Stored private var hoveredID: String?
    @Stored private var selectedID: String?

    var body: some View {
        GeometryReader { geo in
            let bubbles = DiskBubbleLayout.make(nodes: Array(node.children.prefix(28)),
                                                in: geo.size)
            ZStack {
                // 涟漪底纹：设计形式照截图，颜色换成强调色的极淡描边
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Theme.accent.opacity(0.06), lineWidth: 1)
                        .padding(CGFloat(i) * 24)
                }

                ForEach(bubbles) { b in
                    let isSelected = selectedID == b.id
                    ZStack {
                        Circle()
                            .fill(bubbleFill(b, selected: isSelected))
                        Circle()
                            .stroke(isSelected ? Theme.accent : Color.white.opacity(0.55),
                                    lineWidth: isSelected ? 2 : 0.8)
                        if b.radius >= 26 {
                            VStack(spacing: 2) {
                                Text(b.node.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 6)
                                Text(StorageFormat.shortBytes(b.node.size))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.82))
                            }
                            .frame(width: b.radius * 1.8)
                        }
                    }
                    .frame(width: b.radius * 2, height: b.radius * 2)
                    .position(b.center)
                    .scaleEffect(hoveredID == b.id ? 1.05 : 1)
                    .shadow(color: .black.opacity(hoveredID == b.id ? 0.16 : 0.06),
                            radius: hoveredID == b.id ? 8 : 3, y: 2)
                    .onHover { hoveredID = $0 ? b.id : nil }
                    .onTapGesture {
                        selectedID = b.id
                        if b.node.canDrill { onDrill(b.node) } else { onSelect(b.node) }
                    }
                    .help("\(b.node.name) · \(StorageFormat.bytes(b.node.size)) · \(b.node.path)")
                    .animation(Theme.Motion.fast, value: hoveredID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }

    private func bubbleFill(_ b: DiskBubble, selected: Bool) -> Color {
        if selected { return Theme.accent }
        // 大项更深、小项更浅，全部落在我们的中性灰阶上
        return Color.primary.opacity(0.22 + 0.52 * b.weight)
    }
}
