import AppKit
import SwiftUI

// MARK: - 存储管理 · 堆块图（v212）
//
// 用户原话：「你认真查看一下它的一个设计是怎样的一个堆块，怎样的一个界面，
// 我们那个界面完全和它不一样。」
//
// 对照 Kanso 截图：右栏不是稀疏圆形气泡，而是**紧密铺满的圆角堆块**——
//   · 面积 = 体积占比（squarified treemap），块与块之间只有 2pt 缝；
//   · 大块深、小块浅，四档跳变形成层次，不用第二套色板；
//   · 块内按可用面积分三档降级：名称+大小 → 只大小 → 一个点；
//   · 点块下钻，顶部「返回」+ 面包屑 + Esc 回上级。
//
// 为什么弃用气泡：24 个圆之间必然留缝，近一半面积浪费在空隙里，
// 「谁更大」还得靠直径估算；堆块用面积直接表达占比，是磁盘占用的标准图形。

struct DiskTile: Identifiable {
    let node: DiskNode
    let rect: CGRect
    /// 排名（0 = 最大），决定配色档位
    let rank: Int
    var id: String { node.id }
}

enum DiskTreemapLayout {

    /// squarified treemap（Bruls / Huizing / van Wijk）
    /// 输入按体积降序，逐行铺排并让每行尽量接近正方形；输出与输入一一对应。
    static func make(nodes: [DiskNode], in size: CGSize) -> [DiskTile] {
        guard size.width > 12, size.height > 12, !nodes.isEmpty else { return [] }
        let sorted = nodes.sorted { $0.size > $1.size }
        let values = sorted.map { CGFloat(max(1, $0.size)) }
        var rects: [CGRect] = []
        var remaining = CGRect(origin: .zero, size: size)
        var index = 0

        while index < values.count, remaining.width > 1, remaining.height > 1 {
            let restSum = values[index...].reduce(0, +)
            guard restSum > 0 else { break }
            let unit = (remaining.width * remaining.height) / restSum   // 每字节占的面积
            let shortSide = min(remaining.width, remaining.height)

            var row: [CGFloat] = []
            var rowSum: CGFloat = 0
            var best = CGFloat.greatestFiniteMagnitude
            var cursor = index
            while cursor < values.count {
                let v = values[cursor]
                let candidateSum = rowSum + v
                let ratio = worstRatio(row + [v], sum: candidateSum, unit: unit, shortSide: shortSide)
                if row.isEmpty || ratio <= best {
                    row.append(v)
                    rowSum = candidateSum
                    best = ratio
                    cursor += 1
                } else {
                    break
                }
            }
            guard rowSum > 0 else { break }

            // 沿短边切出一行，再在行内按体积切条
            if remaining.width <= remaining.height {
                let rowHeight = rowSum * unit / remaining.width
                var x = remaining.minX
                for v in row {
                    let w = (v * unit) / max(rowHeight, 0.0001)
                    rects.append(CGRect(x: x, y: remaining.minY, width: w, height: rowHeight))
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + rowHeight,
                                   width: remaining.width, height: remaining.height - rowHeight)
            } else {
                let rowWidth = rowSum * unit / remaining.height
                var y = remaining.minY
                for v in row {
                    let h = (v * unit) / max(rowWidth, 0.0001)
                    rects.append(CGRect(x: remaining.minX, y: y, width: rowWidth, height: h))
                    y += h
                }
                remaining = CGRect(x: remaining.minX + rowWidth, y: remaining.minY,
                                   width: remaining.width - rowWidth, height: remaining.height)
            }
            index += row.count
        }

        return zip(sorted, rects).enumerated().map { pair in
            DiskTile(node: pair.element.0, rect: pair.element.1, rank: pair.offset)
        }
    }

    /// 行长宽比，越接近 1 越方正：max(rMax/L², L²/rMin)
    private static func worstRatio(_ row: [CGFloat], sum: CGFloat,
                                   unit: CGFloat, shortSide: CGFloat) -> CGFloat {
        guard sum > 0, shortSide > 1, unit > 0 else { return .greatestFiniteMagnitude }
        let rowLength = (sum * unit) / shortSide
        guard rowLength > 0.0001 else { return .greatestFiniteMagnitude }
        let maxArea = (row.max() ?? 1) * unit
        let minArea = max((row.min() ?? 1) * unit, 0.0001)
        return max(maxArea / (rowLength * rowLength),
                   (rowLength * rowLength) / minArea)
    }
}

struct StorageTreemap: View {

    let node: DiskNode
    /// 目录块点击 → 下钻
    let onDrill: (DiskNode) -> Void
    /// 文件 / 折叠块点击 → 选中（底部详情 + 删除）
    let onSelect: (DiskNode) -> Void

    @Stored private var hoveredID: String?
    @Stored private var selectedID: String?

    var body: some View {
        GeometryReader { geo in
            let tiles = DiskTreemapLayout.make(nodes: Array(node.children.prefix(28)), in: geo.size)
            let total = node.children.reduce(Int64(0)) { $0 + $1.size }
            if tiles.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(node.children.isEmpty ? "这一层没有可拆分的子项" : "面积太小，切不出块")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(tiles) { tile in
                        tileView(tile, total: total)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func tileView(_ t: DiskTile, total: Int64) -> some View {
        let gap: CGFloat = 2
        let w = max(2, t.rect.width - gap)
        let h = max(2, t.rect.height - gap)
        // 圆角随块尺寸走：大块 14，小块收到 4，避免小块被圆角吃掉
        let radius = min(14, max(4, min(w, h) * 0.14))
        let isSelected = selectedID == t.id
        let isHovered = hoveredID == t.id
        let ratio = total > 0 ? Double(t.node.size) / Double(total) : 0
        let ink = contentColor(ratio)

        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill(ratio))
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Color.white.opacity(0.22),
                              lineWidth: isSelected ? 2 : 0.5)
            label(t, width: w, height: h, ink: ink)
        }
        .frame(width: w, height: h)
        .position(x: t.rect.midX, y: t.rect.midY)
        .shadow(color: .black.opacity(isHovered ? 0.16 : 0.04),
                radius: isHovered ? 6 : 2, y: 1)
        .scaleEffect(isHovered ? 1.01 : 1)
        .onHover { hoveredID = $0 ? t.id : nil }
        .onTapGesture {
            selectedID = t.id
            if t.node.canDrill { onDrill(t.node) } else { onSelect(t.node) }
        }
        .help("\(t.node.name) · \(StorageFormat.bytes(t.node.size))"
              + String(format: " · 占本层 %.1f%%", ratio * 100)
              + " · \(t.node.path)")
        .animation(Theme.Motion.fast, value: hoveredID)
    }

    /// 块内文字按可用面积三档降级（照 Kanso：大块名称+大小，中块只大小，小块一个点）
    @ViewBuilder
    private func label(_ t: DiskTile, width: CGFloat, height: CGFloat, ink: Color) -> some View {
        if width > 96, height > 52 {
            VStack(spacing: 2) {
                Text(t.node.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(StorageFormat.shortBytes(t.node.size))
                    .font(.system(size: 11).monospacedDigit())
                    .opacity(0.78)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
        } else if width > 52, height > 26 {
            Text(StorageFormat.shortBytes(t.node.size))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(ink.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 4)
        } else {
            Circle()
                .fill(ink.opacity(0.45))
                .frame(width: 3, height: 3)
        }
    }

    /// 深浅按「占本层比例」分五档（不看排名）：这样同级块少时也有层次，
    /// 大块深、小块浅，全部落在 primary 灰阶上，不引入第二套色板。
    private func fill(_ ratio: Double) -> Color {
        switch ratio {
        case 0.5...:      return Color.primary.opacity(0.72)
        case 0.15..<0.5:  return Color.primary.opacity(0.58)
        case 0.05..<0.15: return Color.primary.opacity(0.34)
        case 0.012..<0.05: return Color.primary.opacity(0.19)
        default:          return Color.primary.opacity(0.09)
        }
    }

    /// 深块反白（windowBackgroundColor 在浅色主题是白、暗色主题是深灰），浅块用 primary
    private func contentColor(_ ratio: Double) -> Color {
        ratio >= 0.15 ? Color(nsColor: .windowBackgroundColor) : Color.primary
    }
}
