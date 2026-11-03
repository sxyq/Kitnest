import AppKit

// v130（SnowShot 对齐）①：智能窗口/元素识别吸附
//
// Snow Shot 框选时自动识别元素边界并吸附高亮。本文件是吸附引擎：
//   · AXUIElementCopyElementAtPosition 命中点下元素 → 递归子元素取 kAXFrameAttribute，
//     优先最深的可命中元素，取不到帧时回退窗口级（kAXWindowAttribute）；
//   · 返回**cocoa 全局坐标**（主屏左下原点）的吸附矩形，与覆盖层视图坐标同系；
//   · 需要「辅助功能」权限（AXIsProcessTrusted）；无权限时全部查询返回 nil，
//     覆盖层自动退化为纯手动框选（不弹错、不打扰）。
//
// 坐标系注意：AX/UI 屏幕坐标是**左上原点**（与 CG 全局一致），
// AppKit 全局是左下原点。本引擎统一输出 cocoa 全局坐标，转换点只在本文件内。

/// 一次元素吸附命中
struct ElementSnapHit {
    /// cocoa 全局矩形（主屏左下原点，点坐标）
    let rect: CGRect
    /// 元素标签（角色 · 标题），可为空
    let label: String
    /// 命中深度（越大越深；窗口级为 0）
    let depth: Int
}

enum ElementSnapEngine {

    /// 最小可吸附尺寸（点）：比这更小的控件吸附体验差，回退到更大容器
    private static let minSize = CGSize(width: 24, height: 12)
    /// 子元素递归上限（防 AX 树过深导致卡顿）
    private static let maxDepth = 12

    /// 辅助功能权限（无权限时所有查询返回 nil，调用方静默回退手动框选）
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 查询点下的可吸附元素（cocoa 全局点 → cocoa 全局矩形）。
    /// 主线程调用；调用方负责节流（建议 ≥90ms）。
    static func snap(atCocoaGlobal point: NSPoint) -> ElementSnapHit? {
        guard isTrusted else { return nil }
        // cocoa 全局（左下原点）→ AX 全局（左上原点）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              let root = hit else { return nil }

        // ① 优先最深可命中元素：沿子树下探（子元素帧包含该点、尺寸达标者优先）
        if let deep = deepestElement(in: root, atAXPoint: axPoint, depth: 0),
           let frame = frame(of: deep),
           frame.width >= minSize.width, frame.height >= minSize.height {
            return ElementSnapHit(rect: toCocoa(frame, primaryHeight: primaryHeight),
                                  label: label(of: deep), depth: depth(of: deep))
        }
        // ② 命中元素自身帧
        if let frame = frame(of: root),
           frame.width >= minSize.width, frame.height >= minSize.height {
            return ElementSnapHit(rect: toCocoa(frame, primaryHeight: primaryHeight),
                                  label: label(of: root), depth: depth(of: root))
        }
        // ③ 回退窗口级
        if let windowEl = copyElement(root, kAXWindowAttribute) {
            if let frame = frame(of: windowEl) {
                return ElementSnapHit(rect: toCocoa(frame, primaryHeight: primaryHeight),
                                      label: label(of: windowEl), depth: 0)
            }
        }
        // ④ 最后回退：沿父链找第一个有帧的祖先
        var parent = copyElement(root, kAXParentAttribute)
        var hops = 0
        while let cur = parent, hops < maxDepth {
            if let frame = frame(of: cur),
               frame.width >= minSize.width, frame.height >= minSize.height {
                return ElementSnapHit(rect: toCocoa(frame, primaryHeight: primaryHeight),
                                      label: label(of: cur), depth: 0)
            }
            parent = copyElement(cur, kAXParentAttribute)
            hops += 1
        }
        return nil
    }

    // MARK: - AX 遍历

    /// 在子树里找包含 AX 点的最深元素（帧有效且尺寸达标）
    private static func deepestElement(in element: AXUIElement, atAXPoint point: CGPoint,
                                       depth d: Int) -> AXUIElement? {
        guard d < maxDepth else { return nil }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            guard let frame = frame(of: child),
                  frame.width >= minSize.width, frame.height >= minSize.height,
                  frame.contains(point) else { continue }
            if let deeper = deepestElement(in: child, atAXPoint: point, depth: d + 1) {
                return deeper
            }
            return child
        }
        return nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success ? v : nil
    }

    /// v130 修：AXUIElement 属性（kAXParentAttribute 等）返回 CFTypeRef，
    /// 直接当 AXUIElement 用会编译不过（CFTypeRef aka AnyObject 不可转换）。
    /// 加类型化变体，运行时校验 CFTypeID 后强转。
    private static func copyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copyAttribute(element, attr),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (v as! AXUIElement)
    }

    /// kAXFrameAttribute（矩形，AX 左上原点全局坐标）。
    /// 注：用原始字符串 "AXFrame"——该常量未进 Swift 导入面（v116 既有代码同款写法）
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let ref = copyAttribute(element, "AXFrame") else { return nil }
        var frame = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &frame), !frame.isEmpty else { return nil }
        return frame
    }

    /// 深度（0=窗口级）：沿父链计数，仅用于提示，不参与命中优先级
    private static func depth(of element: AXUIElement) -> Int {
        var d = 0
        var parent = copyElement(element, kAXParentAttribute)
        while let cur = parent, d < maxDepth {
            d += 1
            if (copyAttribute(cur, kAXRoleAttribute) as? String) == kAXWindowRole { break }
            parent = copyElement(cur, kAXParentAttribute)
        }
        return d
    }

    private static func label(of element: AXUIElement) -> String {
        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
        let title = (copyAttribute(element, kAXTitleAttribute) as? String)
            ?? (copyAttribute(element, kAXDescriptionAttribute) as? String)
            ?? (copyAttribute(element, kAXValueAttribute) as? String) ?? ""
        let friendly = role.replacingOccurrences(of: "AX", with: "")
        return title.isEmpty ? friendly : "\(friendly) · \(title.prefix(24))"
    }

    /// AX 全局矩形（左上原点）→ cocoa 全局矩形（左下原点）
    private static func toCocoa(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY,
               width: rect.width, height: rect.height)
    }
}
