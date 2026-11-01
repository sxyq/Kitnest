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
            // v166.8（用户：「这个弹窗没有方式去关闭」）：
            // 原来浅色静态取 white 0.78，压在官方灰底 #DDDFDF（≈0.867）上几乎看不出边界，
            // 用户会以为窗口根本没有关闭入口。静态提到 0.62，hover 再压到 0.46，
            // 保证「静置时能看见、悬停时更明确」。
            if dark { return NSColor(white: self.isHovering ? 0.62 : 0.42, alpha: 1) }
            return NSColor(white: self.isHovering ? 0.46 : 0.62, alpha: 1)
        }
        base.setFill()
        circle.fill()

        // v179：× 常驻显示（不再只在 hover 时出现）。
        // 审计时发现：静置状态下这个按钮就是一颗纯灰圆点，用户根本认不出是关闭键，
        // 多个窗口的截图里都像「界面上的脏点」。改成淡 ×（0.55）+ 悬停加深（0.95）。
        let cross = NSBezierPath()
        cross.lineWidth = 1.1
        let inset: CGFloat = 4.2
        cross.move(to: NSPoint(x: inset, y: inset))
        cross.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
        cross.move(to: NSPoint(x: bounds.width - inset, y: inset))
        cross.line(to: NSPoint(x: inset, y: bounds.height - inset))
        (NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let alpha: CGFloat = self.isHovering ? 0.95 : 0.55
            return dark ? NSColor(white: 0.92, alpha: alpha) : NSColor(white: 0.25, alpha: alpha)
        }).setStroke()
        cross.stroke()
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
    ///
    /// v166.9（用户：「这个弹窗没有方式去关闭」）——两处修正：
    /// 1. **位置**：原来挂到 `contentView` 顶部，坐标系差了整个标题栏高度（28pt），
    ///    按钮实际落在内容区左上角（压在「原文」标签上），看起来像没有关闭钮。
    ///    现在优先贴到系统关闭钮的原位（父视图 = 标题栏容器），坐标天然对齐。
    /// 2. **随 contentView 替换存活**：标题栏不属于 contentView，
    ///    所以「先 applyOfficialChrome 再换 contentView」也不会把按钮弄丢。
    ///    这也顺带修好了美化面板 / 长截图预览 / 截图历史 / 剪贴板大文本预览
    ///    这几个同类窗口的关闭钮。
    func attachOfficialRoundCloseButton() {
        // v166.9：用 alpha=0 + isEnabled=false 代替 isHidden。
        // isHidden 会让 AppKit 把标题左移到 x≈12，正好压上自绘圆钮；
        // 保留不可见的占位后，标题回到原生位置（x≈80），圆钮与标题互不干扰。
        for button in [standardWindowButton(.closeButton),
                       standardWindowButton(.miniaturizeButton),
                       standardWindowButton(.zoomButton)] {
            button?.alphaValue = 0
            button?.isEnabled = false
        }

        let size: CGFloat = 12
        let stdHost = standardWindowButton(.closeButton)?.superview
        guard let host = stdHost ?? contentView else { return }

        // host 可能是标题栏容器（非 flipped）或内容视图；两种都算一遍
        func place(_ btn: RoundCloseButton) {
            if let std = standardWindowButton(.closeButton),
               std.superview === host, std.frame.width > 0 {
                let f = std.frame
                // x 固定 10 + 12pt 直径：隐藏三钮后 AppKit 把标题左移到 x≈27，
                // 这个尺寸刚好留出 5pt 间隙，不再压住标题首字
                btn.frame = NSRect(x: 10, y: f.midY - size / 2,
                                   width: size, height: size)
            } else {
                let y = host.isFlipped ? 14 : host.bounds.height - size - 14
                btn.frame = NSRect(x: 14, y: y, width: size, height: size)
            }
        }

        if let existing = objc_getAssociatedObject(self, &roundCloseButtonKey) as? RoundCloseButton {
            if existing.superview !== host {
                existing.removeFromSuperview()
                host.addSubview(existing)
            }
            place(existing)
            // 窗口尚未完成布局时 frame 还是 0 —— 排两次兜底
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                place(existing)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                place(existing)
            }
            return
        }

        let btn = RoundCloseButton(frame: .zero)
        btn.target = self
        btn.action = #selector(NSWindow.performClose(_:))
        host.addSubview(btn)
        place(btn)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            place(btn)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            place(btn)
        }
        objc_setAssociatedObject(self, &roundCloseButtonKey, btn, .OBJC_ASSOCIATION_RETAIN)
    }
}
