import AppKit
import SwiftUI

// MARK: - G2（曲率连续）圆角
//
// v156（用户 2026-10-28：「圆角的曲线使用 G2，需要全部统一」）
//
// 三种渲染路径，目标是同一个形状（Apple 的 continuous corner）：
//   · SwiftUI   → `RoundedRectangle(cornerRadius:style:)` 必须带 `style: .continuous`
//                 （漏了就是 .circular：圆弧相切，接缝处曲率从 0 突变到 1/r，只有 G1）
//   · CALayer   → `layer.cornerCurve = .continuous`
//   · AppKit 手绘 → 本文件
//
// 手绘这层**不自己造曲线**：直接取 SwiftUI `RoundedRectangle(.continuous)` 的几何路径。
// 三条渲染路径共用同一份系统实现，形状逐像素一致；也避免超椭圆近似在大半径下出现
// 「方肩」——那是另一种观感，不是 Apple 的连续圆角。
public extension NSBezierPath {

    /// G2 曲率连续圆角矩形（与 SwiftUI `RoundedRectangle(style: .continuous)` 同源）
    static func continuousRoundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        guard r > 0.01, rect.width > 0, rect.height > 0 else {
            return NSBezierPath(rect: rect)
        }
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
            .path(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        // 部署目标 macOS 13：`NSBezierPath(cgPath:)` 要 14+，这里手工搬运元素。
        // 圆角矩形只含 move / line / curve / close 四类，无需处理 quad 之外的特殊情形
        // （quad 仍按标准公式升阶成 cubic，避免将来系统实现换算法时丢段）。
        let path = NSBezierPath()
        shape.cgPath.applyWithBlock { element in
            let e = element.pointee
            let p = e.points
            switch e.type {
            case .moveToPoint:
                path.move(to: p[0])
            case .addLineToPoint:
                path.line(to: p[0])
            case .addQuadCurveToPoint:
                let from = path.currentPoint
                let c = p[0], to = p[1]
                path.curve(to: to,
                           controlPoint1: CGPoint(x: from.x + (c.x - from.x) * 2 / 3,
                                                  y: from.y + (c.y - from.y) * 2 / 3),
                           controlPoint2: CGPoint(x: to.x + (c.x - to.x) * 2 / 3,
                                                  y: to.y + (c.y - to.y) * 2 / 3))
            case .addCurveToPoint:
                path.curve(to: p[2], controlPoint1: p[0], controlPoint2: p[1])
            case .closeSubpath:
                path.close()
            @unknown default:
                break
            }
        }
        return path
    }
}
