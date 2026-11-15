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
    /// 图块局部坐标下的圆角轮廓，布局时一次生成。
    let contour: [CGPoint]
    let drawingPath: Path
    let frame: CGRect
    let hitPath: Path
    let localHitPath: Path
    let labelCenter: CGPoint
    let labelBounds: CGRect
    let labelRadius: CGFloat
    let labelPointCount: Int
    /// 占本层比例（0...1），同时也是布局权重
    let ratio: Double
    /// v230：「可用空间」那块——不参与下钻/删除，画成带同心圆的底块
    var isFreeSpace: Bool = false
    var id: String { node.id }
}

enum DiskVoronoiLayout {

    /// - Parameter freeSpace: 根层的磁盘可用空间（字节），同样按实际字节分配面积。
    static func make(nodes: [DiskNode], in size: CGSize,
                     parentPath: String, freeSpace: Int64? = nil, maxTiles: Int = 14) -> [DiskTile] {
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
                let merged = DiskNode(path: "disk-group:" + parentPath,
                                      name: "其他 \(tail.count) 项",
                                      isDirectory: true,
                                      size: rest,
                                      ownSize: 0,
                                      foldedCount: tail.count,
                                      children: tail, isAggregate: true)
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
                             children: [], isAggregate: true)
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
            let frame = bbox.insetBy(dx: -18, dy: -18)
            let hitPath = VoronoiTreemap.roundedPath(VoronoiTreemap.inset(poly, factor: 0.976),
                                                     radius: min(bbox.width, bbox.height) * 0.30)
            let contour = VoronoiTreemap.sampledPoints(
                hitPath, spacing: 18)
            let labelPolygon = contour
            let center = VoronoiTreemap.centroid(labelPolygon)
            let localContour = contour.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }
            tiles.append(DiskTile(node: n,
                                  contour: localContour,
                                  drawingPath: VoronoiTreemap.roundedPath(localContour, radius: 0),
                                  frame: frame,
                                  hitPath: hitPath,
                                  localHitPath: hitPath.offsetBy(dx: -frame.minX, dy: -frame.minY),
                                  labelCenter: CGPoint(x: center.x - frame.minX, y: center.y - frame.minY),
                                  labelBounds: VoronoiTreemap.boundingBox(labelPolygon),
                                  labelRadius: inradius(labelPolygon, center: center),
                                  labelPointCount: labelPolygon.count,
                                  ratio: sizeTotal > 0 ? Double(n.size) / Double(sizeTotal) : 0,
                                  isFreeSpace: n.path == "__free_space"))
        }
        return tiles
    }

    /// 标签度量只随布局更新，悬停时保持文字尺寸与层级稳定。
    private static func inradius(_ poly: [CGPoint], center c: CGPoint) -> CGFloat {
        guard poly.count >= 3 else { return 0 }
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
}

/// 布局缓存：hover 改状态会重算 body，不能每次都跑 Voronoi 迭代
/// （17 个块 × 90 轮 ≈ 2–5ms，逐帧跑会明显掉帧）
private final class DiskLayoutCache {
    static let shared = DiskLayoutCache()
    private var key = ""
    private var tiles: [DiskTile] = []

    func tiles(for node: DiskNode, size: CGSize, freeSpace: Int64? = nil,
               indexRevision: Int) -> [DiskTile] {
        let k = "\(node.id)|\(size.width)×\(size.height)|\(node.children.count)|\(node.size)"
            + "|\(freeSpace ?? 0)|\(indexRevision)"
        if k == key { return tiles }
        var nodes = node.children
        if node.isDirectory, node.ownSize > 0 {
            nodes.append(DiskNode(path: "disk-files:" + node.path, name: "其余直接文件",
                                  isDirectory: false, size: node.ownSize, ownSize: node.ownSize,
                                  foldedCount: 0, children: [], isAggregate: true))
        }
        let made = DiskVoronoiLayout.make(nodes: nodes, in: size,
                                          parentPath: node.path, freeSpace: freeSpace)
        key = k
        tiles = made
        return made
    }
}

/// 一次轮廓插值供填色、同心线、文字裁切和边框共用。
private struct LiquidTileDrawing<Label: View>: View, Animatable {
    let tiles: [DiskTile]
    var pressurePoint: CGPoint
    var pressure: CGFloat
    let reach: CGFloat
    let selectedID: String?
    let hoveredID: String?
    let label: Label

    // 只插值压力场的三个数值，静态轮廓与文字不参与逐帧向量运算。
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(pressurePoint.x, pressurePoint.y), pressure) }
        set {
            pressurePoint = CGPoint(x: newValue.first.first, y: newValue.first.second)
            pressure = newValue.second
        }
    }

    var body: some View {
        Canvas { context, _ in
            let amplitude = pressure * 44 / reach
            let falloff = 1.45 / (reach * reach)
            for tile in tiles {
                let point = CGPoint(x: pressurePoint.x - tile.frame.minX, y: pressurePoint.y - tile.frame.minY)
                let contour = pressure == 0 ? tile.contour : tile.contour.map { vertex in
                    let dx = vertex.x - point.x, dy = vertex.y - point.y
                    // 相邻图块共用全局压力场，移动与离开时连续挤压、回弹。
                    let displacement = amplitude * exp(-(dx * dx + dy * dy) * falloff)
                    return CGPoint(x: vertex.x + dx * displacement, y: vertex.y + dy * displacement)
                }
                let path = pressure == 0 ? tile.drawingPath : VoronoiTreemap.roundedPath(contour, radius: 0)
                var drawing = context
                drawing.translateBy(x: tile.frame.minX, y: tile.frame.minY)
                var content = drawing
                content.clip(to: path)
                content.fill(path, with: .color(tile.isFreeSpace ? Color.primary.opacity(0.055) : StorageTreemap.fill(tile.ratio)))
                if tile.isFreeSpace {
                    let center = VoronoiTreemap.centroid(contour)
                    for i in 1..<6 {
                        let f = 1 - CGFloat(i) * 0.14
                        let transform = CGAffineTransform(a: f, b: 0, c: 0, d: f,
                                                          tx: center.x * (1 - f), ty: center.y * (1 - f))
                        content.stroke(path.applying(transform), with: .color(.primary.opacity(0.10)), lineWidth: 1)
                    }
                }
                if let symbol = context.resolveSymbol(id: tile.id) { content.draw(symbol, at: tile.labelCenter) }
                let emphasized = selectedID == tile.id || hoveredID == tile.id
                drawing.stroke(path, with: .color(emphasized ? Theme.accent : Color.primary.opacity(0.10)),
                               lineWidth: emphasized ? 2 : 0.5)
            }
        } symbols: {
            label
        }
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
    var indexRevision: Int = 0
    @Stored private var selectedID: String?
    @Stored private var hover = (point: CGPoint.zero, id: Optional<String>.none, active: false)

    var body: some View {
        GeometryReader { geo in
            let tiles = DiskLayoutCache.shared.tiles(for: node, size: geo.size,
                                                     freeSpace: freeSpace, indexRevision: indexRevision)
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
                    // 所有图块共用一块绘制层；压力场与曲线参数保持原样。
                    LiquidTileDrawing(tiles: tiles, pressurePoint: hover.point,
                        pressure: hover.active && !reduceMotion ? 1 : 0,
                        reach: max(140, min(260, min(geo.size.width, geo.size.height) * 0.42)),
                        selectedID: selectedID, hoveredID: hover.id,
                        label: ForEach(tiles) { tile in
                            if tile.labelPointCount >= 3 {
                                label(tile, ink: tile.isFreeSpace ? .primary : contentColor(tile.ratio)).tag(tile.id)
                            }
                        })
                        .allowsHitTesting(false)
                    ForEach(tiles) { tile in
                        tileView(tile)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(StorageMapShape())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let inside = StorageMapShape().path(in: CGRect(origin: .zero, size: geo.size))
                            .contains(location)
                        let nextPoint = inside && !reduceMotion ? location : hover.point
                        let nextID = inside ? tiles.first { $0.frame.contains(location) && $0.hitPath.contains(location) }?.id : nil
                        let active = inside && !reduceMotion
                        if hover.point != nextPoint || hover.id != nextID || hover.active != active {
                            hover = (nextPoint, nextID, active)
                        }
                    case .ended:
                        if hover.id != nil || hover.active { hover = (hover.point, nil, false) }
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86),
                           value: hover.point)
                .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86),
                           value: hover.active)
            }
        }
        .background(StorageMapShape().fill(Color.primary.opacity(0.03)))
        .clipShape(StorageMapShape())
        .onChange(of: indexRevision) { _ in selectedID = nil; hover = (.zero, nil, false) }
    }

    private func tileView(_ t: DiskTile) -> some View {
        let tileFrame = t.frame
        return Button {
            if t.isFreeSpace { onBack?(); return }
            selectedID = t.id
            if t.node.canDrill { onDrill(t.node) } else { onSelect(t.node) }
        } label: {
            // 命中区域独立于逐帧绘制，邻块挤压不改变按钮边界。
            Color.clear
                .frame(width: tileFrame.width, height: tileFrame.height)
                .contentShape(t.localHitPath)
        }
        .buttonStyle(.plain)
        .position(x: tileFrame.midX, y: tileFrame.midY)
        .accessibilityLabel("\(t.node.name)，\(StorageFormat.bytes(t.node.size))")
        .accessibilityHint(t.isFreeSpace ? "返回上一级" : t.node.canDrill ? "进入查看子项" : "显示文件详情")
        .help(t.isFreeSpace ? "磁盘可用空间 · \(StorageFormat.bytes(t.node.size))"
              : "\(t.node.name) · \(StorageFormat.bytes(t.node.size))"
                + String(format: " · 占当前图 %.1f%%", t.ratio * 100)
                + (t.node.isAggregate
                   ? (t.node.canDrill ? " · 点击查看全部子项" : " · 聚合占用，仅供查看")
                   : " · \(t.node.path)"))
    }

    /// 块内文字按**内切圆半径**分档（照截图：够圆够大才写字，窄条只留一个点）。
    ///
    /// 不能用 bbox 判断：斜的多边形 bbox 可能很大，但实际是一条窄缝，
    /// 文字会从块里挤出去（实测底部 .rustup / 422.8M 两块叠字）。
    @ViewBuilder
    private func label(_ t: DiskTile, ink: Color) -> some View {
        let inR = t.labelRadius
        let bounds = t.labelBounds
        let w = bounds.width
        let h = bounds.height
        if (t.isFreeSpace || inR > 44), w > 90, h > 50 {
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
            .frame(width: t.isFreeSpace ? min(w * 0.5, 160) : min(w * 0.78, inR * 1.7))
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

    /// 七档深浅：按占本层比例跳变（不看排名）。
    /// 对照截图的层次——最大的块接近黑，最小的接近底色，中间有明确分档。
    fileprivate static func fill(_ ratio: Double) -> Color {
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
