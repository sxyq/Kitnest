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
    /// v268：共享边采样点（tile 局部坐标）。相邻图块的公共顶点来自同一份
    /// 量化坐标（a0a6be85 的接缝修复），压力场对它按同一函数位移，
    /// 共享边保持闭合——这是旧版液态动画缺了会裂、现在能恢复的前提。
    let contour: [CGPoint]
    /// 未形变绘制路径（pressure == 0 时的快速通道，与命中路径同源）。
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
                     parentPath: String, freeSpace: Int64? = nil, maxTiles: Int = 14,
                     contentTopRatio: CGFloat = 0,
                     geometry: StorageSurfaceGeometry = StorageSurfaceGeometry()) -> [DiskTile] {
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
                                          arcFirst: freeNode != nil,
                                          outline: StorageTileShape(geometry: geometry, top: contentTopRatio)
                                            .path(in: CGRect(x: 0, y: 0, width: 1, height: 1)))
        guard polys.count == list.count else { return [] }

        var tiles: [DiskTile] = []
        tiles.reserveCapacity(list.count)
        // 标签占比与布局权重使用同一组真实字节数。
        let sizeTotal = list.reduce(Int64(0)) { $0 + $1.size }
        for (i, n) in list.enumerated() {
            let contours = VoronoiTreemap.sampledContours(polys[i], spacing: 18)
            guard let labelPolygon = contours.max(by: {
                VoronoiTreemap.area($0) < VoronoiTreemap.area($1)
            }) else { continue }
            let bbox = VoronoiTreemap.boundingBox(contours.flatMap { $0 })
            let frame = bbox.insetBy(dx: -18, dy: -18)
            var hitPath = Path()
            for contour in contours {
                hitPath.addPath(VoronoiTreemap.roundedPath(contour, radius: 0))
            }
            let center = VoronoiTreemap.centroid(labelPolygon)
            let localContours = contours.map { loop in
                loop.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }
            }
            let drawingPath = hitPath.offsetBy(dx: -frame.minX, dy: -frame.minY)
            tiles.append(DiskTile(node: n,
                                  contour: localContours.flatMap { $0 },
                                  drawingPath: drawingPath,
                                  frame: frame,
                                  hitPath: hitPath,
                                  localHitPath: drawingPath,
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
               indexRevision: Int, contentTopRatio: CGFloat = 0,
               geometry: StorageSurfaceGeometry = StorageSurfaceGeometry()) -> [DiskTile] {
        // v286：外轮廓改由整窗画布推导，缓存键必须带上画布口径
        //（画布宽/顶带高度/图块画布左缘任一变化都要重切）。
        let k = "\(node.id)|\(size.width)×\(size.height)|\(node.children.count)|\(node.size)"
            + "|\(freeSpace ?? 0)|\(indexRevision)|\(contentTopRatio)"
            + "|\(Int(geometry.canvas.width))×\(Int(geometry.canvas.height))"
            + "|\(Int(geometry.tileFrame.minX))|\(Int(geometry.surfaceTop))|\(Int(geometry.sweepEnd))"
        if k == key { return tiles }
        var nodes = node.children
        if node.isDirectory, node.ownSize > 0 {
            nodes.append(DiskNode(path: "disk-files:" + node.path, name: "其余直接文件",
                                  isDirectory: false, size: node.ownSize, ownSize: node.ownSize,
                                  foldedCount: 0, children: [], isAggregate: true))
        }
        let made = DiskVoronoiLayout.make(nodes: nodes, in: size,
                                          parentPath: node.path, freeSpace: freeSpace,
                                          contentTopRatio: contentTopRatio,
                                          geometry: geometry)
        key = k
        tiles = made
        return made
    }
}

/// v268：恢复 a0a6be85 删掉的液态压力场（原实现见 54402adc / 3ce0d9a0）。
///
/// 与旧版的关键差别：位移作用在**共享边采样点**上——所有图块用同一个
/// 全局压力场函数（振幅 × 高斯衰减），相邻图块的公共顶点位移量完全一致，
/// 所以悬停挤压、回弹不会再把接缝撑开。
/// 只插值压力中心与强度三个标量，静态轮廓与文字不参与逐帧向量运算。
private struct LiquidTileDrawing<Label: View>: View, Animatable {
    let tiles: [DiskTile]
    var pressurePoint: CGPoint
    var pressure: CGFloat
    let reach: CGFloat
    /// 按住的块：压力增强 1.5 倍 + 2pt 描边（替代逐块缩放，避免破坏共享边）。
    let pressedID: String?
    let selectedID: String?
    let hoveredID: String?
    let label: Label

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(pressurePoint.x, pressurePoint.y), pressure) }
        set {
            pressurePoint = CGPoint(x: newValue.first.first, y: newValue.first.second)
            pressure = newValue.second
        }
    }

    var body: some View {
        Canvas { context, _ in
            let boost: CGFloat = pressedID != nil ? 1.5 : 1
            let amplitude = pressure * 44 * boost / reach
            let falloff = 1.45 / (reach * reach)
            for tile in tiles {
                let local = CGPoint(x: pressurePoint.x - tile.frame.minX,
                                    y: pressurePoint.y - tile.frame.minY)
                var ringCenter = tile.labelCenter
                let path: Path
                if pressure == 0 {
                    path = tile.drawingPath
                } else {
                    let contour = tile.contour.map { vertex -> CGPoint in
                        let dx = vertex.x - local.x, dy = vertex.y - local.y
                        let displacement = amplitude * exp(-(dx * dx + dy * dy) * falloff)
                        return CGPoint(x: vertex.x + dx * displacement, y: vertex.y + dy * displacement)
                    }
                    path = VoronoiTreemap.roundedPath(contour, radius: 0)
                    if tile.isFreeSpace { ringCenter = VoronoiTreemap.centroid(contour) }
                }
                let emphasized = selectedID == tile.id || hoveredID == tile.id
                var drawing = context
                drawing.translateBy(x: tile.frame.minX, y: tile.frame.minY)
                var content = drawing
                content.clip(to: path)
                let fill = tile.isFreeSpace
                    ? Color.primary.opacity(0.055)
                    : emphasized ? Theme.accent.opacity(0.16) : StorageTreemap.fill(tile.ratio)
                content.fill(path, with: .color(fill))
                if tile.isFreeSpace {
                    for i in 1..<6 {
                        let f = 1 - CGFloat(i) * 0.14
                        let transform = CGAffineTransform(a: f, b: 0, c: 0, d: f,
                                                          tx: ringCenter.x * (1 - f), ty: ringCenter.y * (1 - f))
                        content.stroke(path.applying(transform), with: .color(.primary.opacity(0.10)), lineWidth: 1)
                    }
                }
                if pressedID == tile.id {
                    drawing.stroke(path, with: .color(Theme.accent), lineWidth: 2)
                } else if emphasized {
                    drawing.stroke(path, with: .color(Theme.accent), lineWidth: 1.5)
                }
                if let symbol = context.resolveSymbol(id: tile.id) { content.draw(symbol, at: tile.labelCenter) }
            }
        } symbols: {
            label
        }
    }
}

/// v267：块按压样式。只把 isPressed 透传出去，外观保持 plain。
private struct TilePressStyle: ButtonStyle {
    let onPress: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed in onPress(pressed) }
    }
}

/// v286（2026-11-24 用户定案「液面沿左侧弯曲边界持续延伸到上半部」）：
/// 曲面几何的唯一口径——**画布 = 存储窗口内容整体（含顶部操作带）**。
/// 单一事实来源：背景轮廓、图块裁切、悬停命中、手势区域、Voronoi 外轮廓
/// 全部由这一份几何推导，禁止各消费方各自再画一条近似路径。
/// 坐标系约定：所有字段都是画布坐标（窗口内容，原点在标题栏安全区以下）。
struct StorageSurfaceGeometry: Equatable {
    /// 整窗内容画布尺寸。
    var canvas: CGSize = .zero
    /// 曲面顶边基线（画布 y）。顶边有机起伏，**不再是一条水平直线**。
    var surfaceTop: CGFloat = 0
    /// 顶带左缘：曲面上半部延伸到画布中线的 x（只发生在顶部操作带高度内）。
    var crestLeft: CGFloat = 0
    /// 左缘到达图块区左缘的 y（= 顶部操作带高度）；以下边界全程 ≥ 图块区左缘，
    /// 绝不咬进左侧清单卡片（v285 的清单锯齿缺陷不回归）。
    var sweepEnd: CGFloat = 0
    /// 图块画布（画布坐标）：地图列、顶部操作带以下、整列高。
    var tileFrame: CGRect = .zero
    /// 图块画布顶部的前景导航芯片行高——图块从它下方开始（芯片浮在曲面上）。
    var contentTop: CGFloat = 0
}

struct StorageMapShape: Shape {
    /// v286：由 StorageSurfaceGeometry 推导的整条异形外轮廓。
    ///
    /// v285 的教训：轮廓只活在地图列自己的矩形里、上缘是从 (r,0) 到 (1-r,0) 的
    /// 整条水平直线——这正是用户说「曲面没有延伸到上半部」的直接原因。
    /// 现在轮廓以整窗内容为画布：顶边有机起伏、左缘在顶部操作带高度内连续弯曲
    /// 过渡到顶带左缘、以下全程守住图块区左缘（清单可读性不回退）；液面手感参数
    /// （中段微鼓、底边轻弧、0.045 圆角）沿用 54402adc/v285 口径。
    var geometry: StorageSurfaceGeometry

    /// 画布坐标下的整条轮廓（唯一实现；消费方只做「裁剪 + 线性映射」）。
    static func blob(in g: StorageSurfaceGeometry) -> Path {
        let W = g.canvas.width, H = g.canvas.height
        guard W > 60, H > 60 else { return Path() }
        let x0 = g.tileFrame.minX
        let mapW = max(10, W - x0)
        let xC = min(max(g.crestLeft, x0), W - 12)
        let topY = min(max(g.surfaceTop, 2), H * 0.2)
        let sweepY = min(max(g.sweepEnd, topY + 20), H * 0.5)
        let wave = max(3, H * 0.012)
        let r = max(8, min(W, H) * 0.045)
        var path = Path()
        // 顶边：左低右高的有机波浪（液面一直漫到窗口上沿，不再水平截断）
        path.move(to: CGPoint(x: xC, y: topY + wave))
        path.addCurve(to: CGPoint(x: W * 0.55, y: topY - wave * 0.5),
                      control1: CGPoint(x: xC + (W * 0.55 - xC) * 0.45, y: topY + wave * 0.1),
                      control2: CGPoint(x: W * 0.38, y: topY - wave))
        path.addCurve(to: CGPoint(x: W - r, y: topY + wave * 0.2),
                      control1: CGPoint(x: W * 0.74, y: topY - wave),
                      control2: CGPoint(x: W - r * 2.4, y: topY - wave * 0.4))
        // 右上角
        path.addCurve(to: CGPoint(x: W, y: topY + wave * 0.2 + r),
                      control1: CGPoint(x: W, y: topY + wave * 0.2 + r * 0.45),
                      control2: CGPoint(x: W, y: topY + wave * 0.2 + r * 0.45))
        // 右边
        path.addLine(to: CGPoint(x: W, y: H - r))
        path.addCurve(to: CGPoint(x: W - r, y: H),
                      control1: CGPoint(x: W, y: H - r * 0.45),
                      control2: CGPoint(x: W - r * 0.45, y: H))
        // 底边：轻弧（液面下沿微微上提；比例换成地图列口径，形状与 v285 一致）
        path.addLine(to: CGPoint(x: x0 + mapW * 0.35, y: H))
        path.addCurve(to: CGPoint(x: x0 + mapW * 0.10, y: H - H * 0.015),
                      control1: CGPoint(x: x0 + mapW * 0.24, y: H + H * 0.005),
                      control2: CGPoint(x: x0 + mapW * 0.15, y: H))
        path.addCurve(to: CGPoint(x: x0, y: H - H * 0.08),
                      control1: CGPoint(x: x0 + mapW * 0.045, y: H - H * 0.025),
                      control2: CGPoint(x: x0, y: H - H * 0.042))
        // 左边下段：中段向右微鼓（液面手感；只向图块区内鼓，绝不咬清单）
        path.addLine(to: CGPoint(x: x0, y: H * 0.72))
        path.addCurve(to: CGPoint(x: x0 + mapW * 0.032, y: H * 0.50),
                      control1: CGPoint(x: x0, y: H * 0.62),
                      control2: CGPoint(x: x0 + mapW * 0.032, y: H * 0.58))
        path.addCurve(to: CGPoint(x: x0, y: sweepY),
                      control1: CGPoint(x: x0 + mapW * 0.032, y: max(H * 0.40, sweepY + 8)),
                      control2: CGPoint(x: x0, y: max(H * 0.34, sweepY + 4)))
        // 左边上段（sweepY → 顶带）：连续弯曲过渡到顶带左缘
        path.addCurve(to: CGPoint(x: xC + (x0 - xC) * 0.35, y: topY + (sweepY - topY) * 0.42),
                      control1: CGPoint(x: x0, y: sweepY - (sweepY - topY) * 0.30),
                      control2: CGPoint(x: xC + (x0 - xC) * 0.62, y: topY + (sweepY - topY) * 0.55))
        path.addCurve(to: CGPoint(x: xC, y: topY + wave),
                      control1: CGPoint(x: xC + (x0 - xC) * 0.10, y: topY + (sweepY - topY) * 0.16),
                      control2: CGPoint(x: xC, y: topY + (sweepY - topY) * 0.30))
        path.closeSubpath()
        return path
    }

    func path(in rect: CGRect) -> Path {
        let blob = Self.blob(in: geometry)
        let tile = geometry.tileFrame
        // 背景消费方：rect 就是画布本身，直接给整条轮廓。
        if abs(rect.width - geometry.canvas.width) < 0.5,
           abs(rect.height - geometry.canvas.height) < 0.5 {
            return blob
        }
        // 图块画布消费方：轮廓 ∩ 图块画布，再线性映射到调用方 rect
        //（rect == 画布局部矩形时是恒等映射；rect == 单位正方形时供 Voronoi 用）。
        guard tile.width > 1, tile.height > 1 else { return Path() }
        let clipped = blob.cgPath.intersection(CGPath(rect: tile, transform: nil))
        guard !clipped.isEmpty else { return Path() }
        let sx = rect.width / tile.width, sy = rect.height / tile.height
        let transform = CGAffineTransform(translationX: -tile.minX, y: -tile.minY)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: rect.minX, y: rect.minY)
        return Path(clipped).applying(transform)
    }
}

/// 深色图块实际可占用的容器：外轮廓在图块画布内、前景芯片行以下的部分。
/// 芯片行所在的曲面上沿不铺色块，但外轮廓与左侧曲线仍按 StorageMapShape 走。
struct StorageTileShape: Shape {
    var geometry: StorageSurfaceGeometry
    var top: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let outer = StorageMapShape(geometry: geometry).path(in: rect)
        let t = min(max(top, 0), 0.95)
        guard t > 0 else { return outer }
        let clip = CGRect(x: rect.minX, y: rect.minY + rect.height * t,
                          width: rect.width, height: rect.height * (1 - t))
        return Path(outer.cgPath.intersection(CGPath(rect: clip, transform: nil)))
    }
}

struct StorageTreemap: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let node: DiskNode
    let selectedID: String?
    /// 目录块点击 → 下钻
    let onDrill: (DiskNode, UnitPoint) -> Void
    /// 文件 / 折叠块点击 → 选中（底部详情 + 删除）
    let onSelect: (DiskNode) -> Void
    /// 点空白处 = 返回上一级（v228：用户「进去之后没有快速返回的方式」）
    var onBack: (() -> Void)? = nil
    /// 根层的磁盘可用空间（字节）。子目录不混入全盘可用空间。
    var freeSpace: Int64? = nil
    var indexRevision: Int = 0
    /// v274：深色图块仍从前景导航芯片行下方开始。
    /// 这个 inset（pt）就是图块画布顶边到图块区顶边的距离；0 = 铺满整个外轮廓。
    var contentTop: CGFloat = 0
    /// v286：曲面几何（画布坐标）。轮廓/裁切/命中/Voronoi 全部由它推导，
    /// 本视图自己的局部 rect == geometry.tileFrame（调用方按同一几何布frame）。
    var geometry: StorageSurfaceGeometry = StorageSurfaceGeometry()
    /// v268：悬停状态恢复为「指针 + 活跃」二元组——压力场需要鼠标位置
    /// 连续跟随，离开时把 active 弹回 0（自然回弹，允许中途反向）。
    @Stored private var hover = (point: CGPoint.zero, id: Optional<String>.none, active: false)
    /// 本工程 @State 宏不可用，按项目约定用 @Stored（StateCompat）。
    @Stored private var pressedID: String?

    /// 演示/排障：脚本化悬停。深链 `kitnest://storage?hover=1` 会发通知重放，
    /// 场景重开窗口（onAppear）时也自动跑一次；默认键关着时什么都不做。
    private func startScriptedHoverIfNeeded(tiles: [DiskTile]) {
        guard StorageHoverScript.isEnabled else { return }
        let route = tiles
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .prefix(6)
            .map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        StorageHoverScript.shared.start(route: Array(route)) { [self] point in
            let id = tiles.first {
                $0.frame.contains(point) && $0.hitPath.contains(point)
            }?.id
            hover = (point, id, true)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let tiles = DiskLayoutCache.shared.tiles(for: node, size: geo.size,
                                                     freeSpace: freeSpace, indexRevision: indexRevision,
                                                     contentTopRatio: geo.size.height > 0
                                                        ? contentTop / geo.size.height : 0,
                                                     geometry: geometry)
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
                    // 所有图块共用一块绘制层；压力场与曲线参数沿用 54402adc 原值。
                    LiquidTileDrawing(tiles: tiles, pressurePoint: hover.point,
                        // 指针跟随是「直接操作」，不是自动播放的装饰动画：
                        // 系统开了「减弱动态效果」时只把弹簧换成无过冲直跟（见下方 animation），
                        // 压力场本身仍然跟随鼠标，否则整块悬停手感会被系统开关一键抹掉。
                        pressure: hover.active ? 1 : 0,
                        reach: max(140, min(260, min(geo.size.width, geo.size.height) * 0.42)),
                        pressedID: pressedID,
                        selectedID: selectedID, hoveredID: hover.id,
                        label: ForEach(tiles) { tile in
                            if tile.labelPointCount >= 3 {
                                label(tile, ink: tile.isFreeSpace ? .primary : contentColor(tile.ratio)).tag(tile.id)
                            }
                        })
                        .allowsHitTesting(false)
                    ForEach(tiles) { tile in
                        tileView(tile, in: geo.size)
                    }
                    // 2026-11-23 实测：某些目录（如 Users）只有一个子项，整层就是一大块深灰，
                    // 看起来像「空白/坏了」。给一句可行动的提示，数据面积不变（不伪造比例）。
                    // 判据用「最大图块占画布面积」而非 ratio：ratio 是相对父级数据的，不直观。
                    if let biggest = tiles.filter({ !$0.isFreeSpace })
                        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
                       biggest.frame.width * biggest.frame.height
                        > geo.size.width * geo.size.height * 0.82 {
                        Text("这一层只有 1 个子项 · 点击继续下钻")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule(style: .continuous).fill(Theme.cardFill))
                            .overlay(Capsule(style: .continuous)
                                .strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline))
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(StorageMapShape(geometry: geometry))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        // v286：逆映射到共享画布，避免每次指针事件都求轮廓交集。
                        let hitPoint = CGPoint(x: geometry.tileFrame.minX + location.x * geometry.tileFrame.width / geo.size.width,
                                               y: geometry.tileFrame.minY + location.y * geometry.tileFrame.height / geo.size.height)
                        let inside = StorageMapShape.blob(in: geometry).contains(hitPoint)
                        // 同上：位置与活跃态始终跟随真实指针，减弱动态只影响过渡曲线。
                        let nextPoint = inside ? location : hover.point
                        let nextID = inside ? tiles.first { $0.frame.contains(location) && $0.hitPath.contains(location) }?.id : nil
                        let active = inside
                        if hover.point != nextPoint || hover.id != nextID || hover.active != active {
                            hover = (nextPoint, nextID, active)
                        }
                    case .ended:
                        if hover.id != nil || hover.active { hover = (hover.point, nil, false) }
                    }
                }
                // 排障/演示（probe.storageHover=1，默认关闭）：脚本化悬停。
                // 液态回弹真实触发需要鼠标；自动化录屏时让压力中心沿最大几块巡航，
                // 走的仍是同一条压力场与同一根弹簧（0.26/0.86），只是输入源换成定时器。
                // 只读这个 defaults 键，不改变真实鼠标交互与任何产品行为。
                .onAppear { startScriptedHoverIfNeeded(tiles: tiles) }
                .onReceive(NotificationCenter.default.publisher(for: .frsetStorageDemoHover)) { _ in
                    startScriptedHoverIfNeeded(tiles: tiles)
                }
                .onDisappear { StorageHoverScript.shared.stop() }
                // v268：压力中心与强度用 0.26/0.86 弹簧跟随——移动平滑、
                // 离开自然回弹、快速反向不跳变。
                // 减弱动态：不取消跟随，只把「回弹」换成临界阻尼的 0.12s 直跟，
                // 去掉过冲但保留连续感（否则整块液态悬停会被系统开关一键抹掉）。
                .animation(reduceMotion ? .spring(response: 0.12, dampingFraction: 1)
                                        : .spring(response: 0.26, dampingFraction: 0.86),
                           value: hover.point)
                .animation(reduceMotion ? .spring(response: 0.12, dampingFraction: 1)
                                        : .spring(response: 0.26, dampingFraction: 0.86),
                           value: hover.active)
            }
        }
        // v286：底衬与 1pt 外轮廓描边上移到窗口级的曲面背景层（StorageManagerRootView），
        // 这里只保留裁切——否则图块画布会在芯片行下沿画出一条水平接缝，
        // 与整条轮廓的连续曲线相接处出现双线。
        .clipShape(StorageMapShape(geometry: geometry))
        .onChange(of: indexRevision) { _ in hover = (.zero, nil, false); pressedID = nil }
    }

    private func tileView(_ t: DiskTile, in size: CGSize) -> some View {
        let tileFrame = t.frame
        return Button {
            if t.isFreeSpace { onBack?(); return }
            if t.node.canDrill {
                let anchor = UnitPoint(x: (tileFrame.minX + t.labelCenter.x) / size.width,
                                       y: (tileFrame.minY + t.labelCenter.y) / size.height)
                onDrill(t.node, anchor)
            } else {
                onSelect(t.node)
            }
        } label: {
            // 命中区域独立于逐帧绘制，邻块挤压不改变按钮边界。
            Color.clear
                .frame(width: tileFrame.width, height: tileFrame.height)
                .contentShape(t.localHitPath)
        }
        .buttonStyle(TilePressStyle { pressing in
            // v267：按压反馈直接取 Button 自身的 isPressed，不额外挂手势抢点击。
            if pressing { if pressedID != t.id { pressedID = t.id } }
            else if pressedID == t.id { pressedID = nil }
        })
        // v274：图块按钮不参与键盘焦点——那圈蓝色焦点环会贴在外轮廓上，
        // 和真正想要的「边切」混在一起，显得发虚。
        .focusable(false)
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
        // v266：单子项目录（如 Users 下只有 sunyiyang）那一块几乎占满整图，
        // 但内切圆可能落在细长分片上，旧规则会退化成一个小点。面积够大时优先出字。
        let roomy = w > 220 && h > 120
        if (t.isFreeSpace || inR > 44 || roomy), w > 90, h > 50 {
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
            .frame(width: t.isFreeSpace ? min(w * 0.5, 160) : min(w * 0.78, max(inR * 1.7, 180)))
        } else if inR > 24 || roomy {
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

// MARK: - 排障/演示：脚本化悬停（默认关闭）

/// 存储地图的液态回弹由真实鼠标的 `onContinuousHover` 驱动。自动化录屏/截图时
/// 不能移动用户光标，这里用定时器把压力中心沿「最大几块的中心」巡航一圈：
/// 目标仍是同一个 `hover` 状态、同一根 0.26/0.86 弹簧、同一条压力场绘制路径，
/// 所以录到的是真实形变与回弹，只是输入源不是鼠标。
///
/// 开关：`defaults write com.sxyq.frsetnext probe.storageHover -bool true`（默认关）。
private final class StorageHoverScript {

    static let shared = StorageHoverScript()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "probe.storageHover")
    }

    private var timer: Timer?
    private var started: CFTimeInterval = 0

    func start(route: [CGPoint], duration: TimeInterval = 6, onUpdate: @escaping (CGPoint) -> Void) {
        stop()
        guard route.count >= 2 else { return }
        started = CACurrentMediaTime()
        // 往返路线：A→B→C→B→A，端点处自然减速换向（线性插值，弹簧负责柔化）
        let path = route + route.dropLast().reversed()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.started
            if elapsed >= duration {
                self.stop()
                return
            }
            let u = min(0.999, elapsed / duration)
            let scaled = u * Double(path.count - 1)
            let index = min(Int(scaled), path.count - 2)
            let frac = CGFloat(scaled - Double(index))
            let a = path[index], b = path[index + 1]
            onUpdate(CGPoint(x: a.x + (b.x - a.x) * frac,
                             y: a.y + (b.y - a.y) * frac))
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.info("Storage", "probe.storageHover：脚本化悬停开始（\(route.count) 个落点 / \(Int(duration))s）")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

extension Notification.Name {
    /// 存储地图脚本化悬停重放（`kitnest://storage?hover=1`，排障/录屏用；默认不触发）
    static let frsetStorageDemoHover = Notification.Name("frsetStorageDemoHover")
}
