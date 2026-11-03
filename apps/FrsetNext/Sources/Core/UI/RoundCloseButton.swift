import AppKit
import ObjectiveC

// MARK: - 官方圆形关闭钮（2026-10-18）
//
// 官方原版内容型窗口左上角是一个灰色圆形关闭钮（无系统红绿灯三钮）。
// 重建版此前沿用系统红绿灯（key 时红/黄/绿），与官方观感不一致。
// 这里自绘 13pt 圆钮：静态灰圆 + 发丝描边 + 常驻 ×（v181 起不再像「脏点」）；点击 performClose。
// 由 `NSWindow.applyOfficialChrome()` 自动挂载（隐藏系统三钮）。

private var roundCloseButtonKey: UInt8 = 0
private var roundCloseResizeObserverKey: UInt8 = 0

final class RoundCloseButton: NSButton {

    /// 视觉直径（画出来的圆）
    static let visualSize: CGFloat = 13
    /// 命中直径（v182：13pt 的圆太小，差 2px 就点到标题栏开始拖窗口，
    /// 用户读作「关不掉」。视觉仍是 13pt，热区放大到 24pt）
    static let hitSize: CGFloat = 24
    /// 视觉圆相对命中框的内缩
    static var hitPadding: CGFloat { (hitSize - visualSize) / 2 }

    private var isHovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
        toolTip = "关闭"
    }

    /// 应用在后台时，第一次点击也要直接生效。
    /// 默认 NSButton 返回 false → 首击只激活 App、把点击吞掉，用户会以为按钮坏了。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 视觉圆的矩形（居中）
    private var circleRect: NSRect {
        let d = Self.visualSize
        return NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2,
                      width: d, height: d)
    }

    required init?(coder: NSCoder) { fatalError("RoundCloseButton 不支持 NSCoder") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
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

        // v181（用户：「监测窗左侧仍有一处灰色圆点」）：来源就是这颗自绘关闭钮——
        // 灰圆 + 0.55 的淡 × 在 12pt 尺寸下读不出「这是个按钮」，看着像界面上的脏点。
        // 现在补一道发丝描边 + 把 × 画实（粗细/透明度都提上来），
        // 静置时是一颗「看得出是关闭键」的小圆钮，hover 再压深。
        (NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? NSColor(white: 0, alpha: 0.35) : NSColor(white: 0, alpha: 0.16)
        }).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let cross = NSBezierPath()
        cross.lineWidth = 1.35
        let r = circleRect
        let inset: CGFloat = r.width * 0.30
        cross.move(to: NSPoint(x: r.minX + inset, y: r.minY + inset))
        cross.line(to: NSPoint(x: r.maxX - inset, y: r.maxY - inset))
        cross.move(to: NSPoint(x: r.maxX - inset, y: r.minY + inset))
        cross.line(to: NSPoint(x: r.minX + inset, y: r.maxY - inset))
        cross.lineCapStyle = .round
        (NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let alpha: CGFloat = self.isHovering ? 1.0 : 0.8
            return dark ? NSColor(white: 0.96, alpha: alpha) : NSColor(white: 0.16, alpha: alpha)
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
    /// 自绘圆钮的关闭动作：不依赖标准关闭钮状态（见 attach 里的注释）。
    /// 先问 delegate，保留 `windowShouldClose` 的否决权（例如「还有任务在跑」的确认框），
    /// 放行后再直接关闭。
    @objc public func frsetRoundCloseTapped(_ sender: Any?) {
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        close()
    }

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
            // v182（用户：「关不掉」）：**不要** isEnabled = false。
            // 标准关闭钮一旦被禁用，`performClose(_:)` 会静默变成空操作 ——
            // ⌘W、菜单「关闭」、Esc 兜底全部失效，自绘圆钮就成了唯一出口。
            // 只置 alpha = 0 就能隐藏，还保留 performClose 的语义；
            // 圆钮叠在它上面（后添加 → 命中优先），正常点击仍走自绘按钮。
        }

        let size = RoundCloseButton.visualSize
        let hit = RoundCloseButton.hitSize
        let pad = RoundCloseButton.hitPadding
        let stdHost = standardWindowButton(.closeButton)?.superview
        guard let host = stdHost ?? contentView else { return }

        // host 可能是标题栏容器（非 flipped）或内容视图；两种都算一遍
        func place(_ btn: RoundCloseButton) {
            if let std = standardWindowButton(.closeButton),
               std.superview === host, std.frame.width > 0 {
                let f = std.frame
                // 视觉圆左边缘固定 x = 7（系统关闭钮原位）；命中框向左扩 5.5pt，
                // 视觉位置不变，但点起来不用「瞄准」。
                btn.frame = NSRect(x: 7 - pad, y: f.midY - hit / 2,
                                   width: hit, height: hit)
            } else {
                // 无标题栏窗口（监测独立窗这类）：贴内容左上角，内缩 16pt。
                // v181（真身就是那颗「左侧灰点」）：监测独立窗是**内容驱动高度**，会自己长高；
                // 而这里原来只在挂载时算一次 y → 窗口一变高，圆钮就卡在画面中间乱飘。
                // 现在给它「距顶固定」的弹性边距（non-flipped 用 minYMargin、flipped 用 maxYMargin），
                // 窗口缩放时 AppKit 自己把它按在标题上；下面再加 didResize 观察做兜底。
                btn.autoresizingMask = host.isFlipped ? [.maxYMargin] : [.minYMargin]
                let y = host.isFlipped ? 16 - pad : host.bounds.height - size - 16 - pad
                btn.frame = NSRect(x: 16 - pad, y: y, width: hit, height: hit)
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
        // v181（用户：「长截图的框 关闭按钮无效」）：原来接的是 `performClose(_:)`。
        // 标准关闭钮被本函数禁用（isEnabled = false）后，performClose 会**什么都不做**
        // ——实测：禁用后调 performClose，window.isVisible 仍为 true。
        // 于是所有用自绘圆钮的窗口，关闭键其实一直是死的。
        // 改为走自定义 action：保留 delegate 的 windowShouldClose 否决权，然后直接 close()。
        btn.action = #selector(NSWindow.frsetRoundCloseTapped(_:))
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
        observeResizeForRoundClose(button: btn, host: host, size: size)
    }

    /// 窗口尺寸变化 → 重新贴边（监测独立窗、长截图预览都会动画改高）。
    /// autorezingMask 在「整块换 contentView」后可能失效，这里用通知兜一层。
    private func observeResizeForRoundClose(button: RoundCloseButton,
                                            host: NSView,
                                            size: CGFloat) {
        guard objc_getAssociatedObject(self, &roundCloseResizeObserverKey) == nil else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self, weak button, weak host] _ in
            guard let self, let button, let host, button.superview === host else { return }
            let pad = RoundCloseButton.hitPadding
            if host.isFlipped {
                button.frame.origin.y = 16 - pad
            } else {
                button.frame.origin.y = host.bounds.height - size - 16 - pad
            }
        }
        objc_setAssociatedObject(self, &roundCloseResizeObserverKey, token,
                                 .OBJC_ASSOCIATION_RETAIN)
    }
}
