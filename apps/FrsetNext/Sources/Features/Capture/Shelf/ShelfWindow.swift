import AppKit
import QuartzCore

// MARK: - 截图悬挂架 · 视图与窗口
//
// 结构（自下而上）：
//   ShelfPanel（无边框、nonactivating、不抢焦点、不进截图）
//     └ ShelfCanvasView（flipped，负责排版）
//         ├ ShelfRopeView（整条绳子，纯 CoreGraphics 画，四种样式）
//         └ ShelfCardView × N（夹子 + 缩略图 + 悬停工具条 + 拖出）
//
// 之所以不用 NSCollectionView / SwiftUI List：卡片最多十几张、尺寸各异、
// 还要自己做夹子和摆动，用 NSView 直接摆位比套一层布局系统更省，也更好控帧率。

// MARK: - 尺寸常量

enum ShelfMetrics {
    /// 绳子区域高度（也是夹子能露出来的高度）
    static let ropeHeight: CGFloat = 28
    /// 卡片之间的水平间距
    static let gap: CGFloat = 16
    /// 左右留白
    static let padding: CGFloat = 22
    /// 夹子高度
    static let clipHeight: CGFloat = 20
    /// 卡片圆角
    static let cardRadius: CGFloat = 7
    /// 窗口底部余量（给投影）
    static let bottomInset: CGFloat = 12
}

// MARK: - 卡片

/// 一张挂在绳上的截图。
///
/// 交互：
/// - 单击 → 复制图片到剪贴板（最常用，所以给左键）
/// - 拖 → 拖出成文件（可以拖进 Finder / 聊天窗口 / 编辑器）
/// - 悬停 → 右上角出现关闭，底部出现「保存 / 编辑」两个小按钮
/// - 右键 → 菜单（复制 / 保存到… / 在 Finder 中显示 / 钉在屏幕上 / 移除）
final class ShelfCardView: NSView {

    let item: ShelfItem
    /// 卡片本体尺寸（不含夹子）
    let cardSize: CGSize
    private let thumbnail: CGImage?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false

    private let closeButton = NSButton(frame: .zero)
    private let saveButton = NSButton(frame: .zero)
    private let pinButton = NSButton(frame: .zero)

    var onRemove: ((ShelfItem) -> Void)?
    var onSave: ((ShelfItem) -> Void)?
    var onPin: ((ShelfItem) -> Void)?

    init(item: ShelfItem, cardSize: CGSize, thumbnail: CGImage?) {
        self.item = item
        self.cardSize = cardSize
        self.thumbnail = thumbnail
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: cardSize.width,
                                 height: ShelfMetrics.clipHeight + cardSize.height))
        wantsLayer = true
        layer?.masksToBounds = false
        // 卡片投影：让卡片从桌面上「浮」起来。数量最多十几张，用 layer 自带阴影够用
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.34
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        setupButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cardRect = NSRect(x: 0,
                              y: ShelfMetrics.clipHeight,
                              width: cardSize.width,
                              height: cardSize.height)
        let path = CGPath(roundedRect: cardRect,
                          cornerWidth: ShelfMetrics.cardRadius,
                          cornerHeight: ShelfMetrics.cardRadius,
                          transform: nil)

        // 卡片底：深色模式用近黑，浅色用白；不用动态色，避免窗口失焦时整体变灰
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(isDark
                         ? CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1)
                         : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(cardRect)

        if let thumbnail {
            // 图片按 aspectFill 填满卡片，多余裁掉。
            // **必须手动再翻一次**：本视图 isFlipped = true，AppKit 已把 CTM 翻成 y 向下，
            // 直接 ctx.draw(cgImage) 出来的图是上下颠倒的（实测：标题条跑到卡片下方）。
            // NSImage.draw 同样不做 flipped 补偿，所以这里绕卡片中线翻回来。
            let imgW = CGFloat(thumbnail.width), imgH = CGFloat(thumbnail.height)
            let scale = max(cardRect.width / max(imgW, 1), cardRect.height / max(imgH, 1))
            let drawW = imgW * scale, drawH = imgH * scale
            let drawRect = NSRect(x: cardRect.midX - drawW / 2,
                                  y: cardRect.midY - drawH / 2,
                                  width: drawW, height: drawH)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: cardRect.minY + cardRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(thumbnail, in: drawRect)
            ctx.restoreGState()
        } else {
            // 还没解码出来：先给一个占位，避免空白闪一下
            ctx.setFillColor(CGColor(gray: isDark ? 0.22 : 0.94, alpha: 1))
            ctx.fill(cardRect)
        }
        ctx.restoreGState()

        // 描边：双色（外深内浅），保证在任何桌面背景上都有边界
        ctx.addPath(path)
        ctx.setLineWidth(hovered ? 1.5 : 0.8)
        if hovered {
            ctx.setStrokeColor(Theme.accentNS.withAlphaComponent(0.9).cgColor)
        } else {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.32))
        }
        ctx.strokePath()

        if !hovered {
            // 内侧一道极淡的白边，深色桌面上能把卡片从背景里「托」起来
            let inner = CGPath(roundedRect: cardRect.insetBy(dx: 0.6, dy: 0.6),
                               cornerWidth: ShelfMetrics.cardRadius,
                               cornerHeight: ShelfMetrics.cardRadius,
                               transform: nil)
            ctx.addPath(inner)
            ctx.setLineWidth(0.6)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
            ctx.strokePath()
        }

        drawClip(ctx, isDark: isDark)
    }

    /// 夹子：一个小梯形压在绳子与卡片之间，让人相信「这张是挂在绳上的」
    private func drawClip(_ ctx: CGContext, isDark: Bool) {
        let w: CGFloat = 12
        let x = bounds.midX - w / 2
        let top: CGFloat = 4
        let bottom = ShelfMetrics.clipHeight + 2

        let clip = CGMutablePath()
        clip.move(to: CGPoint(x: x + 1.5, y: top))
        clip.addLine(to: CGPoint(x: x + w - 1.5, y: top))
        clip.addLine(to: CGPoint(x: x + w, y: bottom))
        clip.addLine(to: CGPoint(x: x, y: bottom))
        clip.closeSubpath()

        ctx.saveGState()
        // 夹子投影，让它和卡片有前后关系
        ctx.setShadow(offset: CGSize(width: 0, height: 1),
                      blur: 2.5,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(clip)
        ctx.setFillColor(isDark
                         ? CGColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1)
                         : CGColor(red: 0.72, green: 0.72, blue: 0.75, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // 夹口的一道暗线
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.22))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x + 2.5, y: top + 3.5))
        ctx.addLine(to: CGPoint(x: x + w - 2.5, y: top + 3.5))
        ctx.strokePath()
    }

    // MARK: 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !hovered else { return }
        hovered = true
        setButtonsHidden(false)
        needsDisplay = true
        layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -2))
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered else { return }
        hovered = false
        setButtonsHidden(true)
        needsDisplay = true
        layer?.setAffineTransform(.identity)
    }

    // MARK: 按钮

    private func setupButtons() {
        configure(closeButton, symbol: "xmark", action: #selector(removeTapped))
        configure(saveButton, symbol: "square.and.arrow.down", action: #selector(saveTapped))
        configure(pinButton, symbol: "pin", action: #selector(pinTapped))

        closeButton.frame = NSRect(x: cardSize.width - 22, y: ShelfMetrics.clipHeight + 5,
                                   width: 17, height: 17)
        saveButton.frame = NSRect(x: 6, y: ShelfMetrics.clipHeight + cardSize.height - 23,
                                  width: 17, height: 17)
        pinButton.frame = NSRect(x: 27, y: ShelfMetrics.clipHeight + cardSize.height - 23,
                                 width: 17, height: 17)

        setButtonsHidden(true)
    }

    private func configure(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = 8.5
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func setButtonsHidden(_ hidden: Bool) {
        for b in [closeButton, saveButton, pinButton] { b.isHidden = hidden }
    }

    @objc private func removeTapped() { onRemove?(item) }
    @objc private func saveTapped()   { onSave?(item) }
    @objc private func pinTapped()    { onPin?(item) }

    // MARK: 点击 / 拖拽

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, !didStartDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - origin.x, p.y - origin.y) > 4 else { return }
        didStartDrag = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !didStartDrag else { return }
        copyToPasteboard()
    }

    /// 复制 = 同时给 PNG 和文件 URL，粘贴到聊天窗口是图片，粘到 Finder 是文件
    private func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = try? Data(contentsOf: item.fileURL) {
            pb.setData(data, forType: .png)
        }
        pb.writeObjects([item.fileURL as NSURL])
        Toast.show("已拷贝到剪贴板", icon: "doc.on.doc")
    }

    private func beginDrag(with event: NSEvent) {
        let dragItem = NSDraggingItem(pasteboardWriter: item.fileURL as NSURL)
        dragItem.setDraggingFrame(NSRect(x: 0, y: 0, width: cardSize.width, height: cardSize.height),
                                  contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        if let thumbnail {
            return NSImage(cgImage: thumbnail,
                           size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
        return NSImage(size: cardSize)
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制图片", action: #selector(copyFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "保存到…", action: #selector(saveTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "在 Finder 中显示", action: #selector(revealInFinder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "钉在屏幕上", action: #selector(pinTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "从架上移除", action: #selector(removeTapped), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyFromMenu() { copyToPasteboard() }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }
}

// MARK: - 拖拽源

extension ShelfCardView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - 绳子

/// 整条绳子。四种样式全部用 CoreGraphics 画，不引入 CAEmitterLayer。
final class ShelfRopeView: NSView {

    var style: ShelfRopeStyle = .twine {
        didSet { needsDisplay = true }
    }
    /// 卡片中心的 x 坐标：绳子在这些点上被「压」下去一点点
    var loadPoints: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 4 else { return }

        // 下垂量：挂得越多越弯，但不是线性（视觉上 10pt 就到顶了）
        let sag = min(3 + CGFloat(loadPoints.count) * 1.2, 10)
        let y = bounds.midY - 5
        let p0 = CGPoint(x: 2, y: y)
        let p1 = CGPoint(x: bounds.width - 2, y: y)
        let ctrl = CGPoint(x: bounds.midX, y: y + sag * 2)

        let path = CGMutablePath()
        path.move(to: p0)
        path.addQuadCurve(to: p1, control: ctrl)

        switch style {
        case .classic:
            strokeRope(ctx, path, width: 1.2)

        case .twine:
            strokeRope(ctx, path, width: 2.2)
            // 一圈短斜纹，远看就是麻绳的绞股
            ctx.addPath(path)
            ctx.setLineWidth(2.2)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.28))
            ctx.setLineDash(phase: 0, lengths: [1.4, 2.0])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

        case .lights:
            strokeRope(ctx, path, width: 1.3)
            // 沿线每 22pt 一颗灯，颜色循环
            let palette: [CGColor] = [
                NSColor.systemYellow.cgColor,
                NSColor.systemPink.cgColor,
                NSColor.systemTeal.cgColor,
                NSColor.systemOrange.cgColor,
            ]
            for (i, point) in samplePoints(on: (p0, ctrl, p1), spacing: 22).enumerated() {
                let r: CGFloat = 2.2
                // 外圈用低透明度做「光晕」，比真阴影便宜得多
                ctx.setFillColor(palette[i % palette.count].copy(alpha: 0.20) ?? palette[i % palette.count])
                ctx.fillEllipse(in: CGRect(x: point.x - r * 2.3, y: point.y - r * 2.3,
                                           width: r * 4.6, height: r * 4.6))
                ctx.setFillColor(palette[i % palette.count])
                ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
            }

        case .snow:
            strokeRope(ctx, path, width: 1.8)
            // 积雪：沿线上方堆一串大小不一的白色小球（确定性伪随机，避免每次重绘都在跳）
            for (i, point) in samplePoints(on: (p0, ctrl, p1), spacing: 5).enumerated() {
                let n = CGFloat((i &* 2654435761) % 100) / 100
                let r = 1.0 + n * 1.5
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.88))
                ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r * 1.8,
                                           width: r * 2, height: r * 1.9))
            }
        }
    }

    /// 双色描边：先画一道深色底线，再叠一道浅色高光。
    ///
    /// 单一颜色一定会失败——架子浮在**桌面**上，而 App 的外观（浅色/深色）和桌面
    /// 明暗没有关系。实测浅色模式下画黑绳、桌面恰好也是深色，绳子直接消失。
    /// 一深一浅叠着画，任何背景上都至少有一条能看见。
    private func strokeRope(_ ctx: CGContext, _ path: CGPath, width: CGFloat) {
        ctx.addPath(path)
        ctx.setLineWidth(width + 1.5)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.34))
        ctx.setLineCap(.round)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.66))
        ctx.strokePath()
    }

    /// 在二次贝塞尔上按近似等距取样
    private func samplePoints(on curve: (CGPoint, CGPoint, CGPoint),
                              spacing: CGFloat) -> [CGPoint] {
        let (p0, c, p1) = curve
        let steps = max(Int(bounds.width / spacing), 1)
        var result: [CGPoint] = []
        result.reserveCapacity(steps)
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mt = 1 - t
            let x = mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x
            let y = mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }
}

// MARK: - 画布

/// 窗口的宿主视图：翻转坐标（y 向下），让画布从顶部对齐。
final class ShelfHostView: NSView {
    override var isFlipped: Bool { true }
}

/// 排版容器：绳子在上，卡片按顺序挂着，整体水平居中。
final class ShelfCanvasView: NSView {

    private let rope = ShelfRopeView()
    private var cardViews: [ShelfCardView] = []

    var onRemove: ((ShelfItem) -> Void)?
    var onSave: ((ShelfItem) -> Void)?
    var onPin: ((ShelfItem) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(rope)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 重排。`size` 是宿主给画布分配的尺寸（窗口内区）。
    func reload(items: [(ShelfItem, CGImage?)],
                cardWidth: CGFloat,
                style: ShelfRopeStyle,
                size: CGSize) {
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = []

        rope.style = style
        rope.frame = NSRect(x: 0, y: 0, width: size.width, height: ShelfMetrics.ropeHeight)

        let sizes = items.map { $0.0.cardSize(cardWidth: cardWidth) }
        let totalW = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(items.count - 1, 0)) * ShelfMetrics.gap
            + ShelfMetrics.padding * 2
        // 内容比窗口窄时居中，宽时从左边开始（超出部分由窗口宽度裁掉，但正常不会发生）
        var x = max(ShelfMetrics.padding, (size.width - totalW) / 2 + ShelfMetrics.padding)
        var centers: [CGFloat] = []

        for (index, entry) in items.enumerated() {
            let cardSize = sizes[index]
            let card = ShelfCardView(item: entry.0, cardSize: cardSize, thumbnail: entry.1)
            card.onRemove = { [weak self] in self?.onRemove?($0) }
            card.onSave = { [weak self] in self?.onSave?($0) }
            card.onPin = { [weak self] in self?.onPin?($0) }
            card.frame = NSRect(x: x, y: 0,
                                width: cardSize.width,
                                height: ShelfMetrics.clipHeight + cardSize.height)
            addSubview(card)
            cardViews.append(card)
            centers.append(card.frame.midX)
            x += cardSize.width + ShelfMetrics.gap
            animateDrop(card, index: index)
        }
        rope.loadPoints = centers
    }

    /// 落入动画：从上方 10pt 落下 + 淡入 + 绕顶部摆一次衰减。
    ///
    /// 1Capture 的卡片是常驻无限钟摆；我们只摆这一次（约 1.5 秒）。
    /// 理由：常驻动画意味着窗口每次合成都要重算图层树，一直占着 GPU，
    /// 而这张架子大部分时间是静止的——一次性摆动已经足够让人觉得「挂上去了」。
    private func animateDrop(_ card: NSView, index: Int) {
        guard let layer = card.layer else { return }
        let h = card.bounds.height

        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = -10
        move.toValue = 0
        move.duration = 0.34
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        move.beginTime = CACurrentMediaTime() + Double(index) * 0.04

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.beginTime = move.beginTime

        layer.add(move, forKey: "drop")
        layer.add(fade, forKey: "fade")
        layer.opacity = 1

        // 绕顶部中心衰减摆动
        let angles: [CGFloat] = [0, -0.032, 0.024, -0.015, 0.008, -0.003, 0]
        let values = angles.map { NSValue(caTransform3D: ShelfCanvasView.topPivot(angle: $0, height: h)) }
        let sway = CAKeyframeAnimation(keyPath: "transform")
        sway.values = values
        sway.keyTimes = [0, 0.12, 0.3, 0.48, 0.66, 0.84, 1].map { NSNumber(value: $0) }
        sway.duration = 1.5
        sway.beginTime = CACurrentMediaTime() + 0.34 + Double(index) * 0.04
        sway.isRemovedOnCompletion = true
        layer.add(sway, forKey: "sway")
    }

    /// 把旋转中心从图层中心挪到顶部中心
    static func topPivot(angle: CGFloat, height: CGFloat) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, 0, -height / 2, 0)
        t = CATransform3DRotate(t, angle, 0, 0, 1)
        t = CATransform3DTranslate(t, 0, height / 2, 0)
        return t
    }
}

// MARK: - 窗口

/// 悬挂架窗口：贴在菜单栏下方的一条，无边框、不激活、不进截图。
final class ShelfPanel: NSPanel {

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // 卡片各自带投影，窗口层再加一层会糊成一片
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        // 临时暂存的东西不该出现在自己的截图里
        sharingType = .none
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
