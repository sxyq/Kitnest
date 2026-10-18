import AppKit
import ObjectiveC

// MARK: - 官方圆形关闭钮（2026-10-18）
//
// 官方原版内容型窗口左上角是一个灰色圆形关闭钮（无系统红绿灯三钮）。
// 重建版此前沿用系统红绿灯（key 时红/黄/绿），与官方观感不一致。
// 这里自绘 14pt 圆钮：静态灰圆，hover 显示 ×；点击 performClose。
// 由 `NSWindow.applyOfficialChrome()` 自动挂载（隐藏系统三钮）。

private var roundCloseButtonKey: UInt8 = 0

final class RoundCloseButton: NSButton {

    private var isHovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("RoundCloseButton 不支持 NSCoder") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        let base: NSColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if dark { return NSColor(white: self.isHovering ? 0.55 : 0.36, alpha: 1) }
            return NSColor(white: self.isHovering ? 0.58 : 0.78, alpha: 1)
        }
        base.setFill()
        circle.fill()

        if isHovering {
            let cross = NSBezierPath()
            cross.lineWidth = 1.1
            let inset: CGFloat = 4.2
            cross.move(to: NSPoint(x: inset, y: inset))
            cross.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
            cross.move(to: NSPoint(x: bounds.width - inset, y: inset))
            cross.line(to: NSPoint(x: inset, y: bounds.height - inset))
            (NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.28, alpha: 1)
            }).setStroke()
            cross.stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; needsDisplay = true }
}

extension NSWindow {
    /// 挂载官方圆形关闭钮（幂等；隐藏系统红绿灯）。
    /// 支持内容视图被替换后重挂（设置/统计窗的 NSHostingView 延后一个 runloop 装载）。
    /// 注意：NSHostingView 是 flipped（y=0 在顶部），普通 NSView 不 flipped——
    /// 需按 isFlipped 换算纵坐标（2026-10-18 实测：一律按未翻转算会挂到左下角）。
    func attachOfficialRoundCloseButton() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        guard let host = contentView else { return }

        // 按 bounds 手算（不用 Auto Layout：实测 NSHostingView 不参与子视图约束求解，
        // 设 translatesAutoresizingMaskIntoConstraints=false 后按钮 frame 恒为 0 → 不可见）。
        // 关键：挂载瞬间 host.bounds 还没布局（实测高度 128），必须等布局完成再摆一次。
        func place(_ btn: RoundCloseButton, in host: NSView) {
            let size: CGFloat = 14
            let y = host.isFlipped ? 14 : host.bounds.height - size - 14
            btn.frame = NSRect(x: 14, y: y, width: size, height: size)
        }

        if let existing = objc_getAssociatedObject(self, &roundCloseButtonKey) as? RoundCloseButton {
            if existing.superview !== host {
                existing.removeFromSuperview()
                host.addSubview(existing)
                place(existing, in: host)
                DispatchQueue.main.async { place(existing, in: host) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { place(existing, in: host) }
            }
            return
        }

        let btn = RoundCloseButton(frame: .zero)
        btn.autoresizingMask = [.minYMargin]      // 窗口改高时贴顶
        btn.target = self
        btn.action = #selector(NSWindow.performClose(_:))
        host.addSubview(btn)
        place(btn, in: host)
        DispatchQueue.main.async { place(btn, in: host) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { place(btn, in: host) }
        objc_setAssociatedObject(self, &roundCloseButtonKey, btn, .OBJC_ASSOCIATION_RETAIN)
    }
}
