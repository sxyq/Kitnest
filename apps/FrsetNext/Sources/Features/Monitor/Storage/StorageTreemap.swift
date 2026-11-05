import AppKit
import SwiftUI

// MARK: - 存储管理 · 挤压堆块（v214）
//
// 用户对照 Kanso 截图：「颜色、色块、实现、占比，UI 表现完全对不上」，
// 「你需要彻底明白他是在做怎样的一个色块挤压」。
//
// v213 那版是矩形 squarified treemap —— 只能切出直角，块与块是横竖切线，
// 所以看起来像「表格」不像「挤压」。Kanso 那种是 **权重 Voronoi 剖分**：
// 分界线是站点间的垂直平分线，块是不规则多边形，紧贴在一起像被压扁的石头。
// 布局算法见 StorageVoronoi.swift。
//
// 视觉规则对齐截图：
//   · 面积严格等于体积占比；块间留 2% 内缩做缝；
//   · 圆角随块尺寸走（小块收小，避免圆角吃掉形状）；
//   · 深浅按「占本层比例」七档跳变，大块接近黑、小块接近底；
//   · 块内按可用面积三档降级：名称+大小 → 只大小 → 一个点。

struct DiskTile: Identifiable {
    let node: DiskNode
    /// 容器坐标下的多边形
    let polygon: [CGPoint]
    let bbox: CGRect
    /// 占本层比例（0...1），同时也是布局权重
    let ratio: Double
    var id: String { node.id }
}

enum DiskVoronoiLayout {

    static func make(nodes: [DiskNode], in size: CGSize,
                     cutout: CGRect? = nil, maxTiles: Int = 14) -> [DiskTile] {
        guard size.width > 12, size.height > 12, !nodes.isEmpty else { return [] }
        var list = nodes.sorted { $0.size > $1.size }

        // 块太多时尾部小块会被挤成细条（实测 20 块时最后 8 块宽不足 30pt，
        // 连大小都放不下，视觉上像一堆碎片）。保留前 maxTiles-1 个，
        // 其余合并成一个「其他 N 项」块——这也是截图里的做法。
        if list.count > maxTiles {
            let head = Array(list.prefix(maxTiles - 1))
            let tail = Array(list.dropFirst(maxTiles - 1))
            let rest = tail.reduce(Int64(0)) { $0 + $1.size }
            if rest > 0 {
                let merged = DiskNode(path: (head.last?.path ?? "") + "/__rest",
                                      name: "其他 \(tail.count) 项",
                                      isDirectory: false,
                                      size: rest,
                                      ownSize: rest,
                                      foldedCount: tail.count,
                                      children: [])
                list = head + [merged]
            }
        }

        // v229（用户：「占用这部分要显示得多一点」）：
        // 直接用字节数当权重时，极端比例会把小块挤成 1pt 宽的缝
        // （实测 9.2G 对 539M，后者只剩一条线，点都点不到）。
        // 开 0.68 次方压缩比例——数值标签仍然显示真实大小，只是面积不再严格线性。
        let weights = list.map { CGFloat(pow(Double(max(1, $0.size)), 0.68)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        let polys = VoronoiTreemap.layout(weights: weights,
                                          in: CGRect(origin: .zero, size: size),
                                          cutout: cutout)
        guard polys.count == list.count else { return [] }

        var tiles: [DiskTile] = []
        tiles.reserveCapacity(list.count)
        // 展示用的占比必须是**真实字节占比**，不能拿压缩后的权重算——
        // 否则颜色深浅和「占本层 %」都会失真。
        let sizeTotal = list.reduce(Int64(0)) { $0 + $1.size }
        for (i, n) in list.enumerated() {
            let poly = polys[i]
            guard poly.count >= 3 else { continue }
            tiles.append(DiskTile(node: n,
                                  polygon: poly,
                                  bbox: VoronoiTreemap.boundingBox(poly),
                                  ratio: sizeTotal > 0 ? Double(n.size) / Double(sizeTotal) : 0))
        }
        return tiles
    }
}

/// 布局缓存：hover 改状态会重算 body，不能每次都跑 Voronoi 迭代
/// （17 个块 × 90 轮 ≈ 2–5ms，逐帧跑会明显掉帧）
private final class DiskLayoutCache {
    static let shared = DiskLayoutCache()
    private var key = ""
    private var tiles: [DiskTile] = []

    func tiles(for node: DiskNode, size: CGSize, cutout: CGRect? = nil) -> [DiskTile] {
        let k = "\(node.id)|\(Int(size.width))×\(Int(size.height))|\(node.children.count)|\(node.size)"
            + "|\(Int(cutout?.width ?? 0))×\(Int(cutout?.height ?? 0))"
        if k == key { return tiles }
        let made = DiskVoronoiLayout.make(nodes: Array(node.children.prefix(28)),
                                          in: size, cutout: cutout)
        key = k
        tiles = made
        return made
    }
}

/// 命中区域 = 多边形本身（相邻块的 bbox 会重叠，不能用矩形命中）
private struct PolygonHitShape: Shape {
    let points: [CGPoint]
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        VoronoiTreemap.roundedPath(points, radius: radius)
    }
}

struct StorageTreemap: View {

    let node: DiskNode
    /// 目录块点击 → 下钻
    let onDrill: (DiskNode) -> Void
    /// 文件 / 折叠块点击 → 选中（底部详情 + 删除）
    let onSelect: (DiskNode) -> Void
    /// 点空白处 = 返回上一级（v228：用户「进去之后没有快速返回的方式」）
    var onBack: (() -> Void)? = nil
    /// 左上角 agent 区尺寸；非 nil 时容器挖掉这一块（v229 异形布局）
    var agentZone: CGSize? = nil
    var onAgent: (() -> Void)? = nil

    @Stored private var hoveredID: String?
    @Stored private var selectedID: String?

    var body: some View {
        GeometryReader { geo in
            let cutout = agentZone.map { CGRect(origin: .zero, size: $0) }
            let tiles = DiskLayoutCache.shared.tiles(for: node, size: geo.size, cutout: cutout)
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
                    // 块与块之间的空白：点一下回上一级（气泡本身在上层，优先命中）
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onBack?() }
                    ForEach(tiles) { tile in
                        tileView(tile)
                    }
                    // 左上角缺口里放 agent 入口：虚线框表示「这是功能区，不是数据块」
                    if let cutout, let onAgent {
                        agentCard(size: cutout.size, action: onAgent)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func agentCard(size: CGSize, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 15, weight: .medium))
                Text("让 Agent 清理")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("生成分析提示词")
                    .font(.system(size: 9.5))
                    .opacity(0.7)
            }
            .foregroundStyle(Theme.accent)
            .frame(width: max(40, size.width - 10), height: max(40, size.height - 10))
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.accent.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.30),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padding(5)
        .help("让 Agent 分析这个目录里有什么、哪些能清")
    }

    private func tileView(_ t: DiskTile) -> some View {
        let insetted = VoronoiTreemap.inset(t.polygon, factor: 0.976)
        // 转到 bbox 局部坐标：Path 在 SwiftUI 里以自身 frame 原点绘制
        let local = insetted.map { CGPoint(x: $0.x - t.bbox.minX, y: $0.y - t.bbox.minY) }
        // 圆角按短边的 30% 取，**不设固定上限**：
        // 之前上限 26pt 对 380pt 宽的大块只有 7%，看起来仍是「斜切方块」；
        // 按比例后大块会被磨成超椭圆，接近截图里那种「被压扁的鹅卵石」。
        let radius = min(t.bbox.width, t.bbox.height) * 0.30
        let isSelected = selectedID == t.id
        let isHovered = hoveredID == t.id
        // v229：鼠标停在某个块上时，它整体上浮 2.5pt、放大并有回弹，
        // 周围的块同时被压小、压淡——「挤在一起的气泡」的观感。
        let anyHovered = hoveredID != nil
        let pull: CGSize = isHovered ? CGSize(width: 0, height: -2.5) : .zero
        let ink = contentColor(t.ratio)

        return ZStack {
            PolygonHitShape(points: local, radius: radius)
                .fill(fill(t.ratio))
            PolygonHitShape(points: local, radius: radius)
                .stroke(isSelected ? Theme.accent : Color.white.opacity(isHovered ? 0.5 : 0.18),
                        lineWidth: isSelected ? 2 : (isHovered ? 1.2 : 0.5))
            label(t, ink: ink)
        }
        .frame(width: max(2, t.bbox.width), height: max(2, t.bbox.height))
        // 文字/描边都在多边形内裁切，斜块上不会糊到邻块
        .clipShape(PolygonHitShape(points: local, radius: radius))
        .position(x: t.bbox.midX, y: t.bbox.midY)
        .offset(pull)
        .shadow(color: .black.opacity(isHovered ? 0.24 : 0.03),
                radius: isHovered ? 16 : 2,
                y: isHovered ? 6 : 1)
        .scaleEffect(isHovered ? 1.06 : (anyHovered ? 0.972 : 1))
        .opacity(anyHovered && !isHovered ? 0.92 : 1)
        .zIndex(isHovered ? 10 : 0)
        .contentShape(PolygonHitShape(points: local, radius: radius))
        .onHover { hoveredID = $0 ? t.id : nil }
        .onTapGesture {
            selectedID = t.id
            if t.node.canDrill { onDrill(t.node) } else { onSelect(t.node) }
        }
        .help("\(t.node.name) · \(StorageFormat.bytes(t.node.size))"
              + String(format: " · 占本层 %.1f%%", t.ratio * 100)
              + " · \(t.node.path)")
        // 弹簧回弹：damping 0.55 会多抖一下，「被按下去又弹回来」的质感
        .animation(.spring(response: 0.34, dampingFraction: 0.55), value: hoveredID)
    }

    /// 块内文字按**内切圆半径**分档（照截图：够圆够大才写字，窄条只留一个点）。
    ///
    /// 不能用 bbox 判断：斜的多边形 bbox 可能很大，但实际是一条窄缝，
    /// 文字会从块里挤出去（实测底部 .rustup / 422.8M 两块叠字）。
    @ViewBuilder
    private func label(_ t: DiskTile, ink: Color) -> some View {
        let inR = inradius(t.polygon)
        let w = t.bbox.width
        let h = t.bbox.height
        if inR > 44, w > 90, h > 50 {
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
            .frame(width: min(w * 0.78, inR * 1.7))
        } else if inR > 24 {
            Text(StorageFormat.shortBytes(t.node.size))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(ink.opacity(0.9))
                .lineLimit(1)
                .frame(width: min(w * 0.72, inR * 1.6))
        } else {
            Circle()
                .fill(ink.opacity(0.4))
                .frame(width: 3, height: 3)
        }
    }

    /// 质心到各边的最小距离 ≈ 内切圆半径
    private func inradius(_ poly: [CGPoint]) -> CGFloat {
        guard poly.count >= 3 else { return 0 }
        let c = VoronoiTreemap.centroid(poly)
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 0.001 else { continue }
            let dist = abs(dy * (c.x - a.x) - dx * (c.y - a.y)) / len
            best = min(best, dist)
        }
        return best == .greatestFiniteMagnitude ? 0 : best
    }

    /// 七档深浅：按占本层比例跳变（不看排名）。
    /// 对照截图的层次——最大的块接近黑，最小的接近底色，中间有明确分档。
    private func fill(_ ratio: Double) -> Color {
        switch ratio {
        case 0.35...:       return Color.primary.opacity(0.74)
        case 0.18..<0.35:   return Color.primary.opacity(0.62)
        case 0.09..<0.18:   return Color.primary.opacity(0.50)
        case 0.04..<0.09:   return Color.primary.opacity(0.36)
        case 0.015..<0.04:  return Color.primary.opacity(0.24)
        case 0.005..<0.015: return Color.primary.opacity(0.14)
        default:            return Color.primary.opacity(0.07)
        }
    }

    /// 深块反白（windowBackgroundColor 在浅色主题是白、暗色主题是深灰），浅块用 primary
    private func contentColor(_ ratio: Double) -> Color {
        ratio >= 0.09 ? Color(nsColor: .windowBackgroundColor) : Color.primary
    }
}
