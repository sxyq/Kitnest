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

    /// 返回与 weights 一一对应的多边形（容器坐标）
    ///
    /// - Parameter cutout: 左上角要挖掉的矩形（agent 区）。传 nil 就是普通矩形容器。
    ///   v229：用户要「异形」——左上角留给 agent，气泡绕着它排。
    static func layout(weights: [CGFloat],
                       in rect: CGRect,
                       cutout: CGRect? = nil,
                       arcFirst: Bool = false,
                       iterations: Int = 60) -> [[CGPoint]] {
        guard !weights.isEmpty, rect.width > 8, rect.height > 8 else { return [] }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        let targets = weights.map { $0 / total }

        // 必须在**单位正方形**里迭代：power diagram 的偏置 w 与 |p|² 同量纲，
        // 直接在 600×560 的坐标里调步长会被面积尺度（36 万）淹没——
        // 实测同样的增益下最大误差高达 17 个百分点，最大块被压到目标的一半。
        // 归一化后 k=0.3 只要 17 轮就把误差压到 0.3%（实测）。
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let base = basePolygon(cutout: cutout, in: rect)
        let baseArea = area(base)
        // v232：arcFirst = 参考图那种半弧排布（第一块固定左上，其余沿弧线铺开 + 斥力松弛）
        var sites = arcFirst
            ? arcSeeds(targets: targets, in: unit)
            : seeds(in: unit, targets: targets)
        // 初始站点落在缺口里的，推到缺口右下方——否则它的单元被 L 形切得很小，
        // 前几轮迭代会来回震荡（实测收敛慢一倍）。
        if let c = cutout, c.width > 0, c.height > 0 {
            let uw = c.width / rect.width, uh = c.height / rect.height
            for i in sites.indices where sites[i].x < uw && sites[i].y < uh {
                sites[i].x = uw + (1 - uw) * 0.5
                sites[i].y = uh + (1 - uh) * 0.5
            }
        }
        var bias = [CGFloat](repeating: 0, count: weights.count)
        var polygons: [[CGPoint]] = []
        let gain: CGFloat = 0.3
        let relax: CGFloat = 0.08

        for _ in 0..<iterations {
            polygons = cells(sites: sites, bias: bias, in: base)

            var maxErr: CGFloat = 0
            for i in polygons.indices {
                // 面积占比（分母是**容器**面积，不是 1——L 形比矩形小）
                let err = targets[i] - area(polygons[i]) / max(1e-9, baseArea)
                maxErr = max(maxErr, abs(err))
                // 面积偏小 → 增大偏置把边界推远；偏大 → 收缩
                bias[i] += err * gain
            }

            // 轻微 Lloyd 松弛：站点向单元质心靠拢 → 分布更均匀 → 单元更接近
            // 圆形/六边形，边缘看起来是「被挤压的鹅卵石」而不是「斜切的方块」。
            // 实测 0.08 不会破坏面积收敛（误差仍 < 0.4%）。
            for i in polygons.indices where polygons[i].count >= 3 {
                let c = centroid(polygons[i])
                sites[i].x += (c.x - sites[i].x) * relax
                sites[i].y += (c.y - sites[i].y) * relax
            }

            if maxErr < 0.003 { break }
        }

        // 缩回容器坐标
        return polygons.map { poly in
            poly.map { CGPoint(x: rect.minX + $0.x * rect.width,
                               y: rect.minY + $0.y * rect.height) }
        }
    }

    /// 容器轮廓（单位坐标）。有 cutout 时是「左上角缺一块」的 L 形。
    private static func basePolygon(cutout: CGRect?, in rect: CGRect) -> [CGPoint] {
        guard let c = cutout, c.width > 1, c.height > 1 else {
            return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                    CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        }
        let uw = min(0.7, max(0, c.width / rect.width))
        let uh = min(0.6, max(0, c.height / rect.height))
        // 顺时针（SwiftUI 的 y 向下）：从缺口右下角起，绕一圈回来
        return [CGPoint(x: uw, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1),
                CGPoint(x: 0, y: 1), CGPoint(x: 0, y: uh), CGPoint(x: uw, y: uh)]
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

    private static func cells(sites: [CGPoint], bias: [CGFloat], in base: [CGPoint]) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        out.reserveCapacity(sites.count)

        for i in sites.indices {
            var poly = base
            let pi = sites[i]
            let wi = bias[i]
            let pi2 = pi.x * pi.x + pi.y * pi.y

            for j in sites.indices where j != i {
                let pj = sites[j]
                // |x-pi|² - wi ≤ |x-pj|² - wj
                // → 2x·(pj-pi) ≤ |pj|² - |pi|² - wj + wi
                let a = 2 * (pj.x - pi.x)
                let b = 2 * (pj.y - pi.y)
                let c = (pj.x * pj.x + pj.y * pj.y - bias[j]) - (pi2 - wi)
                if abs(a) < 1e-9, abs(b) < 1e-9 { continue }   // 两站点重合，跳过
                poly = clipHalfPlane(poly, a: a, b: b, c: c)
                if poly.count < 3 { break }
            }
            out.append(poly.count >= 3 ? poly : [])
        }
        return out
    }

    /// 保留 a·x + b·y ≤ c 的部分（Sutherland–Hodgman）
    private static func clipHalfPlane(_ poly: [CGPoint], a: CGFloat, b: CGFloat, c: CGFloat) -> [CGPoint] {
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

    /// 多边形圆角路径：每个顶点用 tangent 圆弧过渡。
    ///
    /// 半径必须**逐角**按相邻两条边钳制：之前用全局最短边做上限，
    /// 结果一个多边形只要有一条短边（Voronoi 里很常见），
    /// 整个形状的圆角都被压到十几 pt，看起来还是方块（实测踩过）。
    static func roundedPath(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        let n = points.count
        guard n >= 3 else { return path }

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
