import CoreGraphics
import Foundation
import SwiftUI

// MARK: - 权重 Voronoi 剖分（v214）
//
// 用户对照 Kanso 截图指出：「颜色、色块、实现、占比，UI 表现完全对不上」，
// 「你需要彻底明白他是在做怎样的一个色块挤压」。
//
// 那屏的形状本质是 **weighted Voronoi treemap（power diagram）**：
//   · 每个块对应一个「站点」，块与块的分界线是两个站点的**垂直平分线**（不是横竖切线）；
//   · 因此块是不规则多边形，像被压扁的石头互相挤压、共享整条边；
//   · 每个块的面积严格等于它的体积权重（迭代调偏置直到收敛）。
//
// 矩形 treemap 只能切出直角，永远做不出这种「挤压感」。
//
// 参考算法：Nocaj & Brandes, "Computing Voronoi Treemaps" (2006)；
// d3-voronoi-treemap 的迭代偏置做法。纯计算、无随机源，尺寸不变时结果稳定。

enum VoronoiTreemap {

    /// 返回与 weights 一一对应的异形裁切区域（容器坐标）
    ///
    static func layout(weights: [CGFloat],
                       in rect: CGRect,
                       arcFirst: Bool = false,
                       iterations: Int = 60,
                       outline override: Path? = nil) -> [Path] {
        guard !weights.isEmpty, rect.width > 8, rect.height > 8 else { return [] }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        let targets = weights.map { $0 / total }

        // 必须在**单位正方形**里迭代：power diagram 的偏置 w 与 |p|² 同量纲，
        // 直接在 600×560 的坐标里调步长会被面积尺度（36 万）淹没——
        // 实测同样的增益下最大误差高达 17 个百分点，最大块被压到目标的一半。
        // 归一化后 k=0.3 只要 17 轮就把误差压到 0.3%（实测）。
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        // v286：调用方（StorageTreemap）总是显式传几何推导的轮廓；
        // 这里只做兜底——圆角矩形，绝不再用旧的列内矩形轮廓。
        let fallback = Path(roundedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                            cornerRadius: 0.045)
        let outline = override ?? fallback
        let outlineBounds = outline.boundingRect
        guard outlineBounds.width > 0.001, outlineBounds.height > 0.001,
              !outlineBounds.isNull, !outlineBounds.isInfinite else { return [] }
        let base = sampledPoints(outline, spacing: 0.035)
        guard !base.isEmpty else { return [] }
        let triangles = triangulate(base)
        let baseArea = area(base)
        // v232：arcFirst = 参考图那种半弧排布（第一块固定左上，其余沿弧线铺开 + 斥力松弛）
        var sites = arcFirst
            ? arcSeeds(targets: targets, in: unit)
            : seeds(in: unit, targets: targets)
        // 矩形二分的种子可能落在弧边外，沿容器中心方向收进实际轮廓。
        let center = centroid(base)
        for i in sites.indices {
            var halvings = 0
            while !outline.contains(sites[i]), halvings < 24 {
                sites[i].x = (sites[i].x + center.x) * 0.5
                sites[i].y = (sites[i].y + center.y) * 0.5
                halvings += 1
            }
            guard outline.contains(sites[i]) else { return [] }
        }
        var bias = [CGFloat](repeating: 0, count: weights.count)
        var polygons: [[[CGPoint]]] = []
        let gain: CGFloat = 0.3
        let relax: CGFloat = 0.08

        for _ in 0..<iterations {
            polygons = cells(sites: sites, bias: bias, in: triangles)

            var maxErr: CGFloat = 0
            for i in polygons.indices {
                // 面积占比使用实际异形容器面积。
                let err = targets[i] - area(polygons[i]) / max(1e-9, baseArea)
                maxErr = max(maxErr, abs(err))
                // 面积偏小 → 增大偏置把边界推远；偏大 → 收缩
                bias[i] += err * gain
            }

            // 轻微 Lloyd 松弛：站点向单元质心靠拢 → 分布更均匀 → 单元更接近
            // 圆形/六边形，边缘看起来是「被挤压的鹅卵石」而不是「斜切的方块」。
            // 实测 0.08 不会破坏面积收敛（误差仍 < 0.4%）。
            for i in polygons.indices where !polygons[i].isEmpty {
                let c = centroid(polygons[i])
                sites[i].x += (c.x - sites[i].x) * relax
                sites[i].y += (c.y - sites[i].y) * relax
            }

            if maxErr < 0.003 { break }
        }

        let transform = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height,
                                          tx: rect.minX, ty: rect.minY)
        return polygons.map { pieces in
            let center = centroid(pieces)
            var path = Path()
            for contour in mergedContours(pieces) {
                let inset = contour.map {
                    CGPoint(x: center.x + ($0.x - center.x) * 0.976,
                            y: center.y + ($0.y - center.y) * 0.976)
                }
                path.addPath(polygonPath(inset))
            }
            return path.applying(transform)
        }
    }

    /// 半弧布点（v232，参考图）：第一块（可用空间）固定在左上，
    /// 其余按「大块靠内、小块靠外」沿一条半弧铺开，再做几轮斥力松弛。
    ///
    /// 为什么要松弛：单纯按角度均分会把相邻站点挤在半径接近的位置上，
    /// Voronoi 收敛后会出现「一条细缝夹在两个大块之间」；斥力把站点推开后，
    /// 每块都能拿到接近自身权重的面积。
    private static func arcSeeds(targets: [CGFloat], in rect: CGRect) -> [CGPoint] {
        var pts = [CGPoint](repeating: CGPoint(x: 0.5, y: 0.5), count: targets.count)
        guard targets.count > 1 else { return pts }
        _ = rect

        // ① 第一个（可用空间）放左上
        pts[0] = CGPoint(x: 0.26, y: 0.24)

        let rest = Array(targets.indices.dropFirst())
        let cx: CGFloat = 0.55, cy: CGFloat = 0.50
        let a0 = -58.0 * CGFloat.pi / 180     // 右上
        let a1 = 196.0 * CGFloat.pi / 180     // 左下（绕过左侧）
        let n = rest.count

        for (k, i) in rest.enumerated() {
            let t = n > 1 ? CGFloat(k) / CGFloat(n - 1) : 0.5
            let angle = a0 + (a1 - a0) * t
            // 内圈 0.30 → 外圈 0.46：大块在内，小块在外
            let radius = 0.30 + 0.16 * t
            pts[i] = CGPoint(x: cx + cos(angle) * radius,
                             y: cy + sin(angle) * radius)
        }

        // ② 斥力松弛：站点之间保持最小间距（约等于 sqrt(该块目标面积)）
        let minGap = rest.map { i -> CGFloat in
            max(0.045, sqrt(max(0.0004, targets[i])) * 0.85)
        }
        for _ in 0..<40 {
            var moved = false
            for a in 0..<rest.count {
                for b in (a + 1)..<rest.count {
                    let i = rest[a], j = rest[b]
                    var dx = pts[j].x - pts[i].x
                    var dy = pts[j].y - pts[i].y
                    var d = sqrt(dx * dx + dy * dy)
                    if d < 1e-6 { dx = 0.01; dy = 0.01; d = 0.0141 }
                    let need = (minGap[a] + minGap[b]) * 0.5
                    guard d < need else { continue }
                    let push = (need - d) * 0.5
                    dx /= d; dy /= d
                    pts[i].x -= dx * push; pts[i].y -= dy * push
                    pts[j].x += dx * push; pts[j].y += dy * push
                    moved = true
                }
            }
            for i in rest {
                pts[i].x = min(0.97, max(0.03, pts[i].x))
                pts[i].y = min(0.97, max(0.03, pts[i].y))
            }
            if !moved { break }
        }
        return pts
    }

    // MARK: 初始站点

    /// 按权重递归二分容器，取每块中心做初始站点。
    /// 比随机撒点收敛快一个数量级（随机布局往往要 300+ 次迭代）。
    private static func seeds(in rect: CGRect, targets: [CGFloat]) -> [CGPoint] {        var points = [CGPoint](repeating: .zero, count: targets.count)
        func split(_ idx: [Int], _ r: CGRect) {
            guard !idx.isEmpty else { return }
            if idx.count == 1 {
                points[idx[0]] = CGPoint(x: r.midX, y: r.midY)
                return
            }
            let sum = idx.reduce(CGFloat(0)) { $0 + targets[$1] }
            var acc: CGFloat = 0
            var cut = 1
            for k in 0..<(idx.count - 1) {
                acc += targets[idx[k]]
                if acc >= sum / 2 { cut = k + 1; break }
            }
            if cut >= idx.count { cut = idx.count - 1 }
            if cut <= 0 { cut = 1 }
            let left = Array(idx[0..<cut])
            let right = Array(idx[cut...])
            let leftSum = left.reduce(CGFloat(0)) { $0 + targets[$1] }
            let ratio = leftSum / sum
            if r.width >= r.height {
                let w = r.width * ratio
                split(left, CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
                split(right, CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
            } else {
                let h = r.height * ratio
                split(left, CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
                split(right, CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
            }
        }
        split(Array(targets.indices), rect)
        return points
    }

    // MARK: Voronoi 单元（半平面裁剪）

    private static func cells(sites: [CGPoint], bias: [CGFloat], in triangles: [[CGPoint]]) -> [[[CGPoint]]] {
        var out: [[[CGPoint]]] = []
        out.reserveCapacity(sites.count)

        for i in sites.indices {
            var pieces: [[CGPoint]] = []
            for triangle in triangles {
                var poly = triangle
                let pi = sites[i]
                let wi = bias[i]
                let pi2 = pi.x * pi.x + pi.y * pi.y

                for j in sites.indices where j != i {
                    let pj = sites[j]
                    let a = 2 * (pj.x - pi.x)
                    let b = 2 * (pj.y - pi.y)
                    let c = (pj.x * pj.x + pj.y * pj.y - bias[j]) - (pi2 - wi)
                    if abs(a) < 1e-9, abs(b) < 1e-9 { continue }
                    poly = clipHalfPlane(poly, a: a, b: b, c: c)
                    if poly.count < 3 { break }
                }
                if poly.count >= 3, area(poly) > 1e-10 { pieces.append(poly) }
            }
            out.append(pieces)
        }
        return out
    }

    private static func triangulate(_ polygonIn: [CGPoint]) -> [[CGPoint]] {
        // v274：轮廓现在带一段近垂直的直边，采样会生成一串**共线点**；
        // 耳切在纯共线环上找不到凸耳会返回空 → 图块整块消失。
        // 先剔除共线点再做耳切（面积不变，三角化更稳）。
        var polygon = polygonIn
        if polygon.count > 3 {
            var cleaned: [CGPoint] = []
            cleaned.reserveCapacity(polygon.count)
            for i in polygon.indices {
                let a = polygon[(i + polygon.count - 1) % polygon.count]
                let b = polygon[i]
                let c = polygon[(i + 1) % polygon.count]
                if abs(cross(a, b, c)) > 1e-9 { cleaned.append(b) }
            }
            if cleaned.count >= 3 { polygon = cleaned }
        }
        let orientation: CGFloat = signedArea(polygon) >= 0 ? 1 : -1
        var indices = Array(polygon.indices)
        var triangles: [[CGPoint]] = []
        while indices.count > 3 {
            var clipped = false
            for position in indices.indices {
                let previous = indices[(position + indices.count - 1) % indices.count]
                let current = indices[position]
                let next = indices[(position + 1) % indices.count]
                let a = polygon[previous], b = polygon[current], c = polygon[next]
                guard cross(a, b, c) * orientation > 1e-9 else { continue }
                let containsVertex = indices.contains { index in
                    guard index != previous, index != current, index != next else { return false }
                    let point = polygon[index]
                    return cross(a, b, point) * orientation > 1e-9
                        && cross(b, c, point) * orientation > 1e-9
                        && cross(c, a, point) * orientation > 1e-9
                }
                guard !containsVertex else { continue }
                triangles.append([a, b, c])
                indices.remove(at: position)
                clipped = true
                break
            }
            guard clipped else { return [] }
        }
        if indices.count == 3 { triangles.append(indices.map { polygon[$0] }) }
        return triangles
    }

    private static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        return polygon.indices.reduce(CGFloat.zero) { sum, i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return sum + a.x * b.y - b.x * a.y
        } / 2
    }

    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func polygonPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private struct PointKey: Hashable, Comparable {
        let x: Int64
        let y: Int64

        init(_ point: CGPoint) {
            // 相邻三角形独立裁切会产生极小的浮点误差；按微小坐标误差合并共享边。
            x = Int64((point.x * 1_000_000).rounded())
            y = Int64((point.y * 1_000_000).rounded())
        }

        var point: CGPoint { CGPoint(x: CGFloat(x) / 1_000_000, y: CGFloat(y) / 1_000_000) }
        static func < (lhs: PointKey, rhs: PointKey) -> Bool {
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
    }

    private struct EdgeKey: Hashable {
        let first: PointKey
        let second: PointKey
    }

    private static func mergedContours(_ polygons: [[CGPoint]]) -> [[CGPoint]] {
        var order: [EdgeKey] = []
        var counts: [EdgeKey: Int] = [:]
        for polygon in polygons {
            for index in polygon.indices {
                let start = PointKey(polygon[index])
                let end = PointKey(polygon[(index + 1) % polygon.count])
                guard start != end else { continue }
                let forward = start < end
                let edge = forward ? EdgeKey(first: start, second: end) : EdgeKey(first: end, second: start)
                if counts[edge] == nil { order.append(edge) }
                counts[edge, default: 0] += forward ? 1 : -1
            }
        }

        var edges: [(start: PointKey, end: PointKey)] = []
        var outgoing: [PointKey: [Int]] = [:]
        for edge in order {
            guard let count = counts[edge], count != 0 else { continue }
            let segment = count > 0
                ? (start: edge.first, end: edge.second)
                : (start: edge.second, end: edge.first)
            outgoing[segment.start, default: []].append(edges.count)
            edges.append(segment)
        }

        var used = Set<Int>()
        var contours: [[CGPoint]] = []
        for firstIndex in edges.indices where !used.contains(firstIndex) {
            let first = edges[firstIndex]
            var previous = first.start
            var current = first.end
            var contour = [previous.point]
            used.insert(firstIndex)

            while current != first.start {
                contour.append(current.point)
                let candidates = (outgoing[current] ?? []).filter { !used.contains($0) }
                guard let next = candidates.min(by: {
                    clockwiseTurn(from: previous, through: current, to: edges[$0].end)
                        < clockwiseTurn(from: previous, through: current, to: edges[$1].end)
                }) else { break }
                used.insert(next)
                previous = current
                current = edges[next].end
            }
            if current == first.start, contour.count >= 3 { contours.append(contour) }
        }
        return contours
    }

    private static func clockwiseTurn(from start: PointKey, through pivot: PointKey, to end: PointKey) -> CGFloat {
        let reverse = atan2(CGFloat(start.y - pivot.y), CGFloat(start.x - pivot.x))
        let outgoing = atan2(CGFloat(end.y - pivot.y), CGFloat(end.x - pivot.x))
        let turn = (reverse - outgoing).truncatingRemainder(dividingBy: 2 * .pi)
        return turn < 0 ? turn + 2 * .pi : turn
    }

    private static func area(_ pieces: [[CGPoint]]) -> CGFloat {
        pieces.reduce(CGFloat.zero) { $0 + area($1) }
    }

    private static func centroid(_ pieces: [[CGPoint]]) -> CGPoint {
        let total = area(pieces)
        guard total > 1e-9 else { return .zero }
        return pieces.reduce(CGPoint.zero) { result, contour in
            let weight = area(contour) / total
            let center = centroid(contour)
            return CGPoint(x: result.x + center.x * weight, y: result.y + center.y * weight)
        }
    }

    /// 保留 a·x + b·y ≤ c 的部分（Sutherland–Hodgman）
    static func clipHalfPlane(_ poly: [CGPoint], a: CGFloat, b: CGFloat, c: CGFloat) -> [CGPoint] {
        guard poly.count >= 3 else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(poly.count + 2)
        for k in 0..<poly.count {
            let cur = poly[k]
            let nxt = poly[(k + 1) % poly.count]
            let dc = a * cur.x + b * cur.y - c
            let dn = a * nxt.x + b * nxt.y - c
            if dc <= 0 { out.append(cur) }
            if (dc < 0 && dn > 0) || (dc > 0 && dn < 0) {
                let t = dc / (dc - dn)
                out.append(CGPoint(x: cur.x + (nxt.x - cur.x) * t,
                                   y: cur.y + (nxt.y - cur.y) * t))
            }
        }
        return out
    }

    // MARK: 几何工具

    static func area(_ p: [CGPoint]) -> CGFloat {
        guard p.count >= 3 else { return 0 }
        var s: CGFloat = 0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    static func centroid(_ p: [CGPoint]) -> CGPoint {
        guard p.count >= 3 else { return p.first ?? .zero }
        var cx: CGFloat = 0, cy: CGFloat = 0, a: CGFloat = 0
        for i in 0..<p.count {
            let p0 = p[i], p1 = p[(i + 1) % p.count]
            let cross = p0.x * p1.y - p1.x * p0.y
            a += cross
            cx += (p0.x + p1.x) * cross
            cy += (p0.y + p1.y) * cross
        }
        guard abs(a) > 1e-9 else { return p[0] }
        return CGPoint(x: cx / (3 * a), y: cy / (3 * a))
    }

    /// 按质心等比内缩（块与块之间留缝）
    static func inset(_ p: [CGPoint], factor: CGFloat) -> [CGPoint] {
        let c = centroid(p)
        return p.map { CGPoint(x: c.x + ($0.x - c.x) * factor,
                               y: c.y + ($0.y - c.y) * factor) }
    }

    static func boundingBox(_ p: [CGPoint]) -> CGRect {
        guard let first = p.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for q in p.dropFirst() {
            minX = min(minX, q.x); maxX = max(maxX, q.x)
            minY = min(minY, q.y); maxY = max(maxY, q.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 采样静态路径；布局轮廓与液态绘制共用，动画期间不再生成采样点。
    static func sampledPoints(_ path: Path, spacing: CGFloat) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var first = CGPoint.zero
        path.forEach { element in
            let start = current
            let end: CGPoint
            let c1: CGPoint
            let c2: CGPoint
            switch element {
            case .move(to: let point):
                current = point
                first = point
                return
            case .line(to: let point):
                end = point
                c1 = CGPoint(x: start.x + (end.x - start.x) / 3,
                             y: start.y + (end.y - start.y) / 3)
                c2 = CGPoint(x: start.x + (end.x - start.x) * 2 / 3,
                             y: start.y + (end.y - start.y) * 2 / 3)
            case .quadCurve(to: let point, control: let control):
                end = point
                c1 = CGPoint(x: start.x + (control.x - start.x) * 2 / 3,
                             y: start.y + (control.y - start.y) * 2 / 3)
                c2 = CGPoint(x: end.x + (control.x - end.x) * 2 / 3,
                             y: end.y + (control.y - end.y) * 2 / 3)
            case .curve(to: let point, control1: let control1, control2: let control2):
                end = point
                c1 = control1
                c2 = control2
            case .closeSubpath:
                end = first
                c1 = CGPoint(x: start.x + (end.x - start.x) / 3,
                             y: start.y + (end.y - start.y) / 3)
                c2 = CGPoint(x: start.x + (end.x - start.x) * 2 / 3,
                             y: start.y + (end.y - start.y) * 2 / 3)
            }
            let length = hypot(c1.x - start.x, c1.y - start.y)
                + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(end.x - c2.x, end.y - c2.y)
            let steps = Int(ceil(length / spacing))
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                points.append(CGPoint(x: u * u * u * start.x + 3 * u * u * t * c1.x
                                      + 3 * u * t * t * c2.x + t * t * t * end.x,
                                      y: u * u * u * start.y + 3 * u * u * t * c1.y
                                      + 3 * u * t * t * c2.y + t * t * t * end.y))
            }
            current = end
        }
        return points
    }

    static func sampledContours(_ path: Path, spacing: CGFloat) -> [[CGPoint]] {
        var contours: [[CGPoint]] = []
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var first = CGPoint.zero

        func finish() {
            if points.count >= 3 { contours.append(points) }
            points = []
        }
        func appendSegment(to end: CGPoint, control1 c1: CGPoint, control2 c2: CGPoint) {
            let start = current
            let length = hypot(c1.x - start.x, c1.y - start.y)
                + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(end.x - c2.x, end.y - c2.y)
            let steps = Int(ceil(length / spacing))
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                points.append(CGPoint(x: u * u * u * start.x + 3 * u * u * t * c1.x
                                      + 3 * u * t * t * c2.x + t * t * t * end.x,
                                      y: u * u * u * start.y + 3 * u * u * t * c1.y
                                      + 3 * u * t * t * c2.y + t * t * t * end.y))
            }
            current = end
        }

        path.forEach { element in
            switch element {
            case .move(to: let point):
                finish()
                current = point
                first = point
                points = [point]
            case .line(to: let point):
                appendSegment(to: point,
                              control1: CGPoint(x: current.x + (point.x - current.x) / 3,
                                                y: current.y + (point.y - current.y) / 3),
                              control2: CGPoint(x: current.x + (point.x - current.x) * 2 / 3,
                                                y: current.y + (point.y - current.y) * 2 / 3))
            case .quadCurve(to: let point, control: let control):
                appendSegment(to: point,
                              control1: CGPoint(x: current.x + (control.x - current.x) * 2 / 3,
                                                y: current.y + (control.y - current.y) * 2 / 3),
                              control2: CGPoint(x: point.x + (control.x - point.x) * 2 / 3,
                                                y: point.y + (control.y - point.y) * 2 / 3))
            case .curve(to: let point, control1: let control1, control2: let control2):
                appendSegment(to: point, control1: control1, control2: control2)
            case .closeSubpath:
                let start = current
                appendSegment(to: first,
                              control1: CGPoint(x: start.x + (first.x - start.x) / 3,
                                                y: start.y + (first.y - start.y) / 3),
                              control2: CGPoint(x: start.x + (first.x - start.x) * 2 / 3,
                                                y: start.y + (first.y - start.y) * 2 / 3))
                finish()
                current = first
            }
        }
        finish()
        return contours
    }

    /// 多边形圆角路径：每个顶点用 tangent 圆弧过渡。
    ///
    /// 半径必须**逐角**按相邻两条边钳制：之前用全局最短边做上限，
    /// 结果一个多边形只要有一条短边（Voronoi 里很常见），
    /// 整个形状的圆角都被压到十几 pt，看起来还是方块（实测踩过）。
    static func roundedPath(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        let n = points.count
        guard n >= 3 else { return path }

        if radius == 0 {
            // 采样后的圆角轮廓用连续三次曲线连接，保留水珠弯边。
            path.move(to: points[0])
            for i in 0..<n {
                let p0 = points[(i + n - 1) % n], p1 = points[i]
                let p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
                path.addCurve(to: p2,
                              control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                                                y: p1.y + (p2.y - p0.y) / 6),
                              control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                                                y: p2.y - (p3.y - p1.y) / 6))
            }
            path.closeSubpath()
            return path
        }

        let first = points[0], second = points[1]
        path.move(to: CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2))

        for i in 1...n {
            let corner = points[i % n]
            let next = points[(i + 1) % n]
            let prev = points[(i - 1 + n) % n]
            let lenPrev = hypot(corner.x - prev.x, corner.y - prev.y)
            let lenNext = hypot(next.x - corner.x, next.y - corner.y)
            let localLimit = min(lenPrev, lenNext) / 2 * 0.9
            let r = max(1, min(radius, localLimit))
            path.addArc(tangent1End: corner, tangent2End: next, radius: r)
        }
        path.closeSubpath()
        return path
    }
}
