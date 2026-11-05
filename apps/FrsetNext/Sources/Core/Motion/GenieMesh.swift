import CoreGraphics
import Foundation

// MARK: - Dock 的神灯（Genie）网格
//
// 来源：Dock（macOS 27.0.1）里算这张网格的两个函数，由 raphaelsalaja 从二进制
// 反汇编还原后逐行移植（the-genie-effect）。这里按同一套公式重写为 Swift，
// 不引入原项目的任何代码。
//
// 形状要点：
//   · 窗口每一行的宽度都不同 → 单一 transform 做不到，必须是一张网格；
//   · 每个顶点 4 个数：窗口上的归一化位置（local x/y）+ 屏幕位置（x/y）；
//   · 桌面图标（slot）比自己小得多时，侧边会先「弯」成漏斗，再整体「滑」进去。
//
// 时序要点（这才是它与其它复刻的差别）：
//   · 两段各有时长，都由 log 距离决定：trunc(ln(d/2+1)) * 50 毫秒；
//   · 用 acos 解出「窗口前沿刚好抵达图标」的时刻，要求侧边此刻正好弯完；
//   · 弯早了就把弯拉长，弯晚了就让滑动等一等。

/// 参与计算的矩形（坐标系：**屏幕左上角为原点、y 向下**，与 Dock 一致）
struct GenieRect {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0

    var maxX: CGFloat { x + width }
    var maxY: CGFloat { y + height }
    var midX: CGFloat { x + width / 2 }
    var midY: CGFloat { y + height / 2 }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func offsetBy(_ dx: CGFloat, _ dy: CGFloat) -> GenieRect {
        GenieRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}

/// 图标在窗口的哪一侧（面板挂在菜单栏下方 → .top）
enum GenieEdge {
    case top, bottom, left, right
}

/// 网格结果：columns × rows 个顶点，每顶点 4 个 CGFloat（local x, local y, screen x, screen y）
struct GenieMesh {
    var columns: Int
    var rows: Int
    var points: [CGFloat]

    /// 第 row 行在窗口局部坐标里的 y（0…窗口高）
    func localY(_ row: Int) -> CGFloat { points[row * 8 + 1] }
    /// 第 row 行的屏幕 y
    func screenY(_ row: Int) -> CGFloat { points[row * 8 + 3] }
    /// 第 row 行左/右顶点的屏幕 x
    func screenX(_ row: Int) -> (CGFloat, CGFloat) { (points[row * 8 + 2], points[row * 8 + 6]) }
}

/// 两段动画的进度与时长（bendLength/slideLength 单位毫秒，仅用于诊断）
struct GeniePhases {
    var bent: CGFloat        // 侧边弯开的进度 0…1
    var poured: CGFloat      // 滑进图标的进度 0…1
    var gap: CGFloat         // 窗口与图标之间的空档
    var settled: CGFloat     // 侧边刚好弯完时的整体进度（0…1）
    var bendLength: CGFloat  // 弯时长 ms
    var slideLength: CGFloat // 滑时长 ms
}

private let genieCapacity = 1200
private let genieTolerance: CGFloat = 0.6
private let genieMaxCalls = 64

private func genieEase(_ cosine: CGFloat) -> CGFloat { cosine * -0.5 + 0.5 }

private struct GenieAxis {
    var far: CGFloat
    var length: CGFloat
    var near: CGFloat
    var iconFar: CGFloat
    var left: CGFloat
    var right: CGFloat
    var overlap: CGFloat
    var travel: CGFloat
}

private func genieAxis(window: GenieRect, icon: GenieRect, edge: GenieEdge) -> GenieAxis {
    switch edge {
    case .bottom:
        let gap = icon.y - window.maxY
        let overlap: CGFloat = gap > 0 ? 0 : gap
        return GenieAxis(far: window.y,
                         length: window.height,
                         near: icon.y,
                         iconFar: icon.maxY,
                         left: icon.x - window.x,
                         right: icon.maxX - window.maxX,
                         overlap: overlap,
                         travel: overlap >= 0 ? icon.y - window.y : window.height)
    case .top:
        let near = icon.maxY
        let far = window.maxY
        let gap = near - window.y
        let overlap: CGFloat = gap < 0 ? 0 : gap
        return GenieAxis(far: far,
                         length: -window.height,
                         near: near,
                         iconFar: icon.y,
                         left: icon.x - window.x,
                         right: icon.maxX - window.maxX,
                         overlap: overlap,
                         travel: overlap <= 0 ? near - far : -window.height)
    case .right:
        let gap = icon.x - window.maxX
        let overlap: CGFloat = gap > 0 ? 0 : gap
        return GenieAxis(far: window.x,
                         length: window.width,
                         near: icon.x,
                         iconFar: icon.maxX,
                         left: icon.y - window.y,
                         right: icon.maxY - window.maxY,
                         overlap: overlap,
                         travel: overlap >= 0 ? icon.x - window.x : window.width)
    case .left:
        let near = icon.maxX
        let far = window.maxX
        let gap = near - window.x
        let overlap: CGFloat = gap < 0 ? 0 : gap
        return GenieAxis(far: far,
                         length: -window.width,
                         near: near,
                         iconFar: icon.x,
                         left: icon.y - window.y,
                         right: icon.maxY - window.maxY,
                         overlap: overlap,
                         travel: overlap <= 0 ? near - far : -window.width)
    }
}

private func genieTiming(_ p: CGFloat, _ a: GenieAxis) -> GeniePhases {
    let sides = (abs(a.left) + abs(a.right)) * 0.125
    let squeeze = abs(a.overlap + a.overlap)
    let bend = abs(max(squeeze, sides)) * 0.5 + 1
    let bendLength = (log(bend)).rounded(.towardZero) * 50

    let distance = abs(a.travel)
    let slideLength = (log(distance * 0.5 + 1)).rounded(.towardZero) * 50

    let gap = abs(a.travel - a.length)
    let ratio = distance > 0 ? gap / distance : 0
    let reach = slideLength * (acos(min(max(ratio * -2 + 1, -1), 1)) / .pi)

    let narrow = max(bendLength, reach)
    let lead = bendLength > reach ? bendLength - reach : 0
    let along = (slideLength + lead) * p

    let narrowAt = min(along, narrow)
    let narrowed = max(0, narrowAt) / max(narrow, 0.0001)

    let slid = along - lead
    let slideAt = min(slid, slideLength)
    let slidden = max(0, slideAt) / max(slideLength, 0.0001)

    return GeniePhases(bent: genieEase(cos(narrowed * .pi)),
                       poured: genieEase(cos(slidden * .pi)),
                       gap: gap,
                       settled: narrow / max(slideLength + lead, 0.0001),
                       bendLength: bendLength,
                       slideLength: slideLength)
}

/// 递归细分漏斗的侧边：直到每一段与直线的误差 < 0.6pt。
/// 写入的是 (位置, 左偏移, 右偏移) 三元组。
private func genieSubdivide(_ buffer: inout [CGFloat],
                            _ offset: Int,
                            _ a: CGFloat,
                            _ b: CGFloat,
                            _ start: CGFloat,
                            _ left: CGFloat,
                            _ right: CGFloat,
                            _ span: CGFloat,
                            _ calls: inout Int) -> Int {
    guard abs(span) > 0.0001 else { return 0 }
    let atB = genieEase(cos((b - start) * .pi / span))
    calls += 1
    if calls > genieMaxCalls { return 0 }

    let rightB = right * atB
    let leftB = left * atB
    var written = 0
    var from = a
    var at = offset

    while true {
        let length = abs(b - from)
        if length < 8 { return written }
        let mid = (b + from) * 0.5
        let atFrom = cos((from - start) * .pi / span)
        let atMid = genieEase(cos((mid - start) * .pi / span))
        let leftMid = left * atMid
        let rightMid = right * atMid

        if length < 128 {
            let eased = genieEase(atFrom)
            let leftFrom = left * eased
            let leftChord = abs((leftB + leftFrom) * 0.5 - leftMid)
            if leftChord < genieTolerance {
                let rightFrom = right * eased
                let rightChord = abs((rightB + rightFrom) * 0.5 - rightMid)
                if rightChord < genieTolerance { return written }
            }
        }

        let count = genieSubdivide(&buffer, at, from, mid, start, left, right, span, &calls)
        let index = count + at
        if index > genieCapacity - 1 { return written }
        buffer[index] = mid
        buffer[index + 1] = leftMid
        buffer[index + 2] = rightMid
        if index > genieCapacity - 4 { return written }
        at = index + 3
        written += count + 3
        calls += 1
        from = mid
        if calls >= genieMaxCalls + 1 { return written }
    }
}

private func genieBuild(_ buffer: [CGFloat],
                        count: Int,
                        window: GenieRect,
                        edge: GenieEdge) -> GenieMesh {
    let vertical = (edge == .bottom || edge == .top)
    let reversed = (edge == .top || edge == .left)
    let firstAt = reversed ? count - 1 : 0
    let lastAt = reversed ? 0 : count - 1
    let origin = buffer[firstAt * 3]
    let extent = vertical ? window.height : window.width
    let denominator = buffer[lastAt * 3] - origin
    let scale = abs(denominator) > 0.0001 ? extent / denominator : 1
    let across = vertical ? window.width : window.height
    let base = vertical ? window.x : window.y

    var points = [CGFloat](repeating: 0, count: count * 8)
    for n in 0..<count {
        let i = reversed ? count - 1 - n : n
        let position = buffer[i * 3]
        let local = (position - origin) * scale
        let near = base + buffer[i * 3 + 1]
        let far = base + across + buffer[i * 3 + 2]
        if vertical {
            points[n * 8 + 0] = 0
            points[n * 8 + 1] = local
            points[n * 8 + 2] = near
            points[n * 8 + 3] = position
            points[n * 8 + 4] = across
            points[n * 8 + 5] = local
            points[n * 8 + 6] = far
            points[n * 8 + 7] = position
        } else {
            // 水平方向（Dock 在左右两侧）本工程暂不使用，保持结构完整
            points[n * 8 + 0] = local
            points[n * 8 + 1] = 0
            points[n * 8 + 2] = position
            points[n * 8 + 3] = near
            points[n * 8 + 4] = local
            points[n * 8 + 5] = across
            points[n * 8 + 6] = position
            points[n * 8 + 7] = far
        }
    }
    return vertical
        ? GenieMesh(columns: 2, rows: count, points: points)
        : GenieMesh(columns: count, rows: 2, points: points)
}

/// progress：0 = 完整窗口，1 = 完全收进图标
func genieMesh(progress: CGFloat,
               window: GenieRect,
               icon: GenieRect,
               edge: GenieEdge = .top) -> GenieMesh {
    let a = genieAxis(window: window, icon: icon, edge: edge)
    let t = genieTiming(min(max(progress, 0), 1), a)

    let left = a.left * t.bent
    let right = a.right * t.bent
    let moved = a.travel * t.poured
    let span = (a.travel).rounded(.towardZero)
    let start = a.far + a.overlap * t.bent
    let top = start + moved
    let bottom = a.length + top
    let toward = (edge == .bottom || edge == .right)
    let clamped: CGFloat
    if toward {
        clamped = bottom <= a.near ? bottom : a.near
    } else {
        clamped = bottom >= a.near ? bottom : a.near
    }
    let neck = t.poured <= 0 ? bottom : clamped

    var buffer = [CGFloat](repeating: 0, count: genieCapacity)

    guard abs(span) > 0.0001 else {
        // 退化（窗口与图标同高）：直接给两行，避免除零
        return genieBuild([top, 0, 0, top, left, right], count: 2, window: window, edge: edge)
    }

    let first = genieEase(cos((top - start) * .pi / span))
    buffer[0] = top
    buffer[1] = left * first
    buffer[2] = right * first

    var calls = 0
    let count = genieSubdivide(&buffer, 3, top, neck, start, left, right, span, &calls)

    let atNeck = genieEase(cos((neck - start) * .pi / span))
    buffer[count + 3] = neck
    buffer[count + 4] = left * atNeck
    buffer[count + 5] = right * atNeck
    var floats = count + 6

    if abs(moved) > t.gap {
        var tail = bottom
        if toward {
            if tail > a.iconFar { tail = a.iconFar }
        } else if tail < a.iconFar {
            tail = a.iconFar
        }
        buffer[floats] = tail
        buffer[floats + 1] = left
        buffer[floats + 2] = right
        floats += 3
    }

    return genieBuild(buffer, count: max(1, floats / 3), window: window, edge: edge)
}

/// 只算时序，不生成网格（诊断 / 设置页预览用）
func geniePhases(progress: CGFloat,
                 window: GenieRect,
                 icon: GenieRect,
                 edge: GenieEdge = .top) -> GeniePhases {
    genieTiming(min(max(progress, 0), 1), genieAxis(window: window, icon: icon, edge: edge))
}
