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
    /// 已内缩、圆角化的绘制轮廓；只在布局时采样。
    let contour: [CGPoint]
    let bbox: CGRect
    /// 占本层比例（0...1），同时也是布局权重
    let ratio: Double
    /// v230：「可用空间」那块——不参与下钻/删除，画成带同心圆的底块
    var isFreeSpace: Bool = false
    var id: String { node.id }
}

enum DiskVoronoiLayout {

    /// - Parameter freeSpace: 根层的磁盘可用空间（字节），同样按实际字节分配面积。
    static func make(nodes: [DiskNode], in size: CGSize,
                     freeSpace: Int64? = nil, maxTiles: Int = 14) -> [DiskTile] {
        guard size.width > 12, size.height > 12, !nodes.isEmpty else { return [] }
        var list = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }

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
                                      isDirectory: true,
                                      size: rest,
                                      ownSize: 0,
                                      foldedCount: tail.count,
                                      children: tail)
                list = head + [merged]
            }
        }

        // 根层左上角放「可用空间」，与已索引占用按同一比例显示。
        // 它放 list 第一个——seeds 的递归二分会把第一项分到左上角。
        var freeNode: DiskNode?
        if let free = freeSpace, free > 0 {
            let n = DiskNode(path: "__free_space",
                             name: "可用空间",
                             isDirectory: false,
                             size: free,
                             ownSize: free,
                             foldedCount: 0,
                             children: [])
            freeNode = n
            list.insert(n, at: 0)
        }

        // 面积按真实字节数分配；小项通过可下钻的「其他」聚合，不放大份额。
        let weights = list.map { CGFloat($0.size) }

        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        let polys = VoronoiTreemap.layout(weights: weights,
                                          in: CGRect(origin: .zero, size: size),
                                          arcFirst: freeNode != nil)
        guard polys.count == list.count else { return [] }

        var tiles: [DiskTile] = []
        tiles.reserveCapacity(list.count)
        // 标签占比与布局权重使用同一组真实字节数。
        let sizeTotal = list.reduce(Int64(0)) { $0 + $1.size }
        for (i, n) in list.enumerated() {
            let poly = polys[i]
            guard poly.count >= 3 else { continue }
            let bbox = VoronoiTreemap.boundingBox(poly)
            let contour = VoronoiTreemap.sampledPoints(
                VoronoiTreemap.roundedPath(VoronoiTreemap.inset(poly, factor: 0.976),
                                          radius: min(bbox.width, bbox.height) * 0.30),
                spacing: 18)
            tiles.append(DiskTile(node: n,
                                  polygon: poly,
                                  contour: contour,
                                  bbox: bbox,
                                  ratio: sizeTotal > 0 ? Double(n.size) / Double(sizeTotal) : 0,
                                  isFreeSpace: n.path == "__free_space"))
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

    func tiles(for node: DiskNode, size: CGSize, freeSpace: Int64? = nil) -> [DiskTile] {
        let k = "\(node.id)|\(Int(size.width))×\(Int(size.height))|\(node.children.count)|\(node.size)"
            + "|\(freeSpace ?? 0)"
        if k == key { return tiles }
        let made = DiskVoronoiLayout.make(nodes: node.children,
                                          in: size, freeSpace: freeSpace)
        key = k
        tiles = made
        return made
    }
}

/// 命中区域 = 多边形本身（相邻块的 bbox 会重叠，不能用矩形命中）
private struct PolygonHitShape: Shape {
    var points: [CGPoint]
    let radius: CGFloat

    var animatableData: PolygonAnimatableVector {
        get { PolygonAnimatableVector(values: points.flatMap { [$0.x, $0.y] }) }
        set {
            guard newValue.values.count >= 6 else { return }
            points = stride(from: 0, to: newValue.values.count, by: 2).map {
                CGPoint(x: newValue.values[$0], y: newValue.values[$0 + 1])
            }
        }
    }

    func path(in rect: CGRect) -> Path {
        VoronoiTreemap.roundedPath(points, radius: radius)
    }
}

private struct PolygonAnimatableVector: VectorArithmetic {
    var values: [CGFloat]

    static var zero: Self { Self(values: []) }
    var magnitudeSquared: Double { values.reduce(0) { $0 + Double($1 * $1) } }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * CGFloat(rhs) }
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        if lhs.values.isEmpty { return rhs }
        if rhs.values.isEmpty { return lhs }
        return Self(values: zip(lhs.values, rhs.values).map { $0.0 + $0.1 })
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        if lhs.values.isEmpty { return Self(values: rhs.values.map { -$0 }) }
        if rhs.values.isEmpty { return lhs }
        return Self(values: zip(lhs.values, rhs.values).map { $0.0 - $0.1 })
    }
}

struct StorageMapShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let point: (CGFloat, CGFloat) -> CGPoint = {
            CGPoint(x: rect.minX + $0 * rect.width, y: rect.minY + $1 * rect.height)
        }
        path.move(to: point(0.48, 0))
        path.addLine(to: point(0.91, 0))
        path.addCurve(to: point(1, 0.09), control1: point(0.96, 0), control2: point(1, 0.04))
        path.addLine(to: point(1, 0.91))
        path.addCurve(to: point(0.91, 1), control1: point(1, 0.96), control2: point(0.96, 1))
        path.addLine(to: point(0, 1))
        // 2026-11-12：按用户橙线，从整个窗口的左下方连续弯到上方中部。
        path.addLine(to: point(0, 0.84))
        path.addCurve(to: point(0.48, 0), control1: point(0.28, 0.80), control2: point(0.52, 0.55))
        path.closeSubpath()
        return path
    }
}

struct StorageTreemap: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: DiskNode
    /// 目录块点击 → 下钻
    let onDrill: (DiskNode) -> Void
    /// 文件 / 折叠块点击 → 选中（底部详情 + 删除）
    let onSelect: (DiskNode) -> Void
    /// 点空白处 = 返回上一级（v228：用户「进去之后没有快速返回的方式」）
    var onBack: (() -> Void)? = nil
    /// 根层的磁盘可用空间（字节）。子目录不混入全盘可用空间。
    var freeSpace: Int64? = nil
    @Stored private var hoveredID: String?
    @Stored private var selectedID: String?
    @Stored private var hoverPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let tiles = DiskLayoutCache.shared.tiles(for: node, size: geo.size,
                                                     freeSpace: freeSpace)
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
                        tileView(tile, in: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(StorageMapShape())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let inside = StorageMapShape().path(in: CGRect(origin: .zero, size: geo.size))
                            .contains(location)
                        hoverPoint = inside ? location : nil
                        hoveredID = inside ? tiles.first { tile in
                            VoronoiTreemap.roundedPath(
                                VoronoiTreemap.inset(tile.polygon, factor: 0.976),
                                radius: min(tile.bbox.width, tile.bbox.height) * 0.30)
                                .contains(location)
                        }?.id : nil
                    case .ended:
                        hoveredID = nil
                        hoverPoint = nil
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86),
                           value: hoverPoint)
            }
        }
        .background(StorageMapShape().fill(Color.primary.opacity(0.03)))
        .clipShape(StorageMapShape())
    }

    private func tileView(_ t: DiskTile, in size: CGSize) -> some View {
        let tileFrame = t.bbox.insetBy(dx: -18, dy: -18)
        let hitPolygon = VoronoiTreemap.inset(t.polygon, factor: 0.976)
        let deformed = liquidPoints(t.contour, around: hoverPoint, in: size)
        let hitLocal = hitPolygon.map { CGPoint(x: $0.x - tileFrame.minX, y: $0.y - tileFrame.minY) }
        let local = deformed.map { CGPoint(x: $0.x - tileFrame.minX, y: $0.y - tileFrame.minY) }
        let radius = min(t.bbox.width, t.bbox.height) * 0.30
        // 顶部操作和导航占据 144pt；标签只排在导航下方的实际图块内。
        let labelPolygon = VoronoiTreemap.clipHalfPlane(deformed, a: 0, b: -1, c: -144)
        let center = VoronoiTreemap.centroid(labelPolygon)
        let isSelected = selectedID == t.id
        let isHovered = hoveredID == t.id
        let ink = contentColor(t.ratio)
        return Button {
            if t.isFreeSpace { onBack?(); return }
            selectedID = t.id
            if t.node.canDrill { onDrill(t.node) } else { onSelect(t.node) }
        } label: {
            // 只变形绘制层；热区保持静止，避免气泡推开指针后反复进出。
            ZStack {
                ZStack {
                    PolygonHitShape(points: local, radius: 0)
                        .fill(t.isFreeSpace ? Color.primary.opacity(0.055) : fill(t.ratio))
                    if t.isFreeSpace {
                        ForEach(1..<6, id: \.self) { i in
                            let f = 1 - CGFloat(i) * 0.14
                            PolygonHitShape(points: VoronoiTreemap.inset(local, factor: f),
                                            radius: 0)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                    }
                    if labelPolygon.count >= 3 {
                        label(t, polygon: labelPolygon, ink: t.isFreeSpace ? .primary : ink)
                            .position(x: center.x - tileFrame.minX, y: center.y - tileFrame.minY)
                    }
                }
                .frame(width: tileFrame.width, height: tileFrame.height)
                .clipShape(PolygonHitShape(points: local, radius: 0))
                .overlay {
                    PolygonHitShape(points: local, radius: 0)
                        .stroke(isSelected || isHovered ? Theme.accent : Color.primary.opacity(0.10),
                                lineWidth: isSelected || isHovered ? 2 : 0.5)
                }
                .allowsHitTesting(false)
            }
            .frame(width: tileFrame.width, height: tileFrame.height)
            .contentShape(PolygonHitShape(points: hitLocal, radius: radius))
        }
        .buttonStyle(.plain)
        .position(x: tileFrame.midX, y: tileFrame.midY)
        .accessibilityLabel("\(t.node.name)，\(StorageFormat.bytes(t.node.size))")
        .accessibilityHint(t.isFreeSpace ? "返回上一级" : t.node.canDrill ? "进入查看子项" : "显示文件详情")
        .help(t.isFreeSpace ? "磁盘可用空间 · \(StorageFormat.bytes(t.node.size))"
              : "\(t.node.name) · \(StorageFormat.bytes(t.node.size))"
                + String(format: " · 占当前图 %.1f%%", t.ratio * 100)
                + (t.node.path.contains("/__rest") ? " · 点击查看全部子项" : " · \(t.node.path)"))
    }

    private func liquidPoints(_ polygon: [CGPoint], around point: CGPoint?, in size: CGSize) -> [CGPoint] {
        guard !reduceMotion, let point else { return polygon }
        let reach = max(140, min(260, min(size.width, size.height) * 0.42))
        return polygon.map { vertex in
            let dx = vertex.x - point.x
            let dy = vertex.y - point.y
            // 同一全局压力场作用于所有轮廓，相邻边一起挤压；中心处连续归零。
            let pressure = 44 / reach * exp(-(dx * dx + dy * dy) / (reach * reach) * 1.45)
            return CGPoint(x: vertex.x + dx * pressure,
                           y: vertex.y + dy * pressure)
        }
    }

    /// 块内文字按**内切圆半径**分档（照截图：够圆够大才写字，窄条只留一个点）。
    ///
    /// 不能用 bbox 判断：斜的多边形 bbox 可能很大，但实际是一条窄缝，
    /// 文字会从块里挤出去（实测底部 .rustup / 422.8M 两块叠字）。
    @ViewBuilder
    private func label(_ t: DiskTile, polygon: [CGPoint], ink: Color) -> some View {
        let inR = inradius(polygon)
        let bounds = VoronoiTreemap.boundingBox(polygon)
        let w = bounds.width
        let h = bounds.height
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
                .font(.system(size: 11).monospacedDigit())
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
