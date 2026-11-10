import AppKit
import QuartzCore

// MARK: - 图帘 · 视图与窗口
//
// 结构（自下而上）：
//   CurtainPanel（无边框、nonactivating、不抢焦点、不进截图）
//     └ CurtainCanvasView（flipped，负责排版）
//         ├ CurtainRopeView（整条绳子，纯 CoreGraphics 画，四种样式）
//         └ CurtainCardView × N（夹子 + 缩略图 + 悬停工具条 + 拖出）
//
// 之所以不用 NSCollectionView / SwiftUI List：卡片最多十几张、尺寸各异、
// 还要自己做夹子和摆动，用 NSView 直接摆位比套一层布局系统更省，也更好控帧率。

// MARK: - 尺寸常量
//
// v263：全部尺寸从「写死」改成「按 railScale 缩放」。
// 用户要求「放大的时候，它需要不止放大图片，那个窗帘的线也需要可以放大」——
// 卡片宽度是主变量，railScale = 卡片宽 / 140，帘线、夹子、绳结、间距一起变。
// 关掉「帘线跟随缩放」时 railScale 恒为 1，只有卡片变大。

enum CurtainMetrics {
    /// 帘线区域高度（也是夹子能露出来的高度）
    static let ropeHeightBase: CGFloat = 28
    /// 线端距视图顶的距离。1Capture 反汇编：`y = height - 12`
    static let ropeInsetBase: CGFloat = 12
    /// 下垂量系数。1Capture：`sag = min(width * 0.018, 28)`
    static let sagRatio: CGFloat = 0.018
    /// 下垂量上限（1× 时）
    static let sagMaxBase: CGFloat = 28
    /// 线两端留给绳结的距离
    static let ropeEndInsetBase: CGFloat = 5
    /// 卡片之间的水平间距
    static let gapBase: CGFloat = 16
    /// 左右留白
    static let paddingBase: CGFloat = 22
    /// 夹子高度
    static let clipHeightBase: CGFloat = 20
    /// 卡片圆角（按卡片宽度自适应，见 `cornerRadius(for:scale:)`）
    static let cardRadiusMin: CGFloat = 8
    static let cardRadiusMax: CGFloat = 25
    /// 窗口底部余量（给投影）
    static let bottomInsetBase: CGFloat = 12

    static func ropeHeight(_ scale: CGFloat) -> CGFloat { ropeHeightBase * scale }
    static func ropeInset(_ scale: CGFloat) -> CGFloat { ropeInsetBase * scale }
    static func sagMax(_ scale: CGFloat) -> CGFloat { sagMaxBase * scale }
    static func ropeEndInset(_ scale: CGFloat) -> CGFloat { max(ropeEndInsetBase * scale, 3) }
    static func gap(_ scale: CGFloat) -> CGFloat { gapBase * scale }
    static func padding(_ scale: CGFloat) -> CGFloat { paddingBase * scale }
    static func clipHeight(_ scale: CGFloat) -> CGFloat { clipHeightBase * scale }
    static func bottomInset(_ scale: CGFloat) -> CGFloat { bottomInsetBase * scale }

    /// 卡片圆角。
    ///
    /// 1Capture 在 `CGPathCreateWithRoundedRect(rect, 25, 25, nil)` 里写死 25pt，
    /// 并且用 `kCACornerCurveContinuous`（连续曲率，不是圆弧）。
    /// 我们的卡片宽度可调（72–420），直接照抄 25 在 72pt 宽时会把角吃掉一半，
    /// 所以按比例取：宽度 × 0.16，下限 8、上限 25，再乘缩放系数。
    static func cornerRadius(for cardWidth: CGFloat, scale: CGFloat) -> CGFloat {
        min(max(cardWidth * 0.16, cardRadiusMin * scale), cardRadiusMax * scale)
    }
}

// MARK: - 绳线几何

/// 绳子的三次贝塞尔参数，卡片要靠它算「自己挂在这一段绳上该歪多少度」。
///
/// 1Capture 的 `HangingShelfRopeView` 反汇编结果：
/// ```
/// y = height - 12
/// sag = min(width * 0.018, 28)
/// curve(to: (width, y), cp1: (width/3, y - sag), cp2: (2*width/3, y - sag))
/// ```
/// 控制点落在 1/3 与 2/3，所以 x(t) = width · t 是**精确线性**的，
/// 这让「按 x 反解 t」不需要解三次方程。
struct CurtainRopeGeometry {
    let width: CGFloat
    /// 线端 y（视图坐标，已翻转为向下为正）
    let y: CGFloat
    let sag: CGFloat
    /// 帘线缩放系数（与卡片宽度联动，见 `CurtainPref.railScale`）
    let scale: CGFloat

    init(width: CGFloat, ropeTop: CGFloat, scale: CGFloat = 1) {
        self.width = max(width, 1)
        self.y = ropeTop
        self.scale = max(scale, 0.5)
        self.sag = min(max(width, 1) * CurtainMetrics.sagRatio,
                       CurtainMetrics.sagMax(self.scale))
    }

    private func t(atX x: CGFloat) -> CGFloat {
        min(max(x / width, 0), 1)
    }

    /// 曲线上某点的 y：y(t) = y + 3·sag·t(1-t)
    func y(atX x: CGFloat) -> CGFloat {
        let t = t(atX: x)
        return y + 3 * sag * t * (1 - t)
    }

    /// 切线斜率 dy/dx = 3·sag·(1-2t) / width
    func slope(atX x: CGFloat) -> CGFloat {
        let t = t(atX: x)
        return 3 * sag * (1 - 2 * t) / width
    }

    /// 卡片应该倾斜的角度（弧度）。绳子上任意一点都朝最低处倒，
    /// 所以这条曲线上的卡片会「向着中间微微偏」——这是绳子看起来
    /// 真实的关键，全部垂直挂着会像贴在一条假线上。
    func tilt(atX x: CGFloat) -> CGFloat {
        let angle = atan(slope(atX: x))
        let limit = 4 * CGFloat.pi / 180
        return min(max(angle, -limit), limit)
    }
}

// MARK: - 卡片

/// 一张挂在帘线上的截图。
///
/// 交互：
/// - 单击 → 复制图片到剪贴板（最常用，所以给左键）
/// - 拖 → 拖出成文件（可以拖进 Finder / 聊天窗口 / 编辑器）
/// - **按住 ⌘ 左右拖 → 放大 / 缩小整条图帘**（v263，连同帘线一起缩放）
/// - 悬停 → 右上角出现关闭，底部出现「保存 / 编辑」两个小按钮
/// - 右键 → 菜单（复制 / 保存到… / 在 Finder 中显示 / 钉在屏幕上 / 移除）
final class CurtainCardView: NSView {

    let item: CurtainItem
    /// 卡片本体尺寸（不含夹子）。v263 起可变——⌘ 拖动缩放时原地更新，不重建视图。
    private(set) var cardSize: CGSize
    private(set) var railScale: CGFloat
    private let thumbnail: CGImage?
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var mouseDownPoint: NSPoint?
    private var didStartDrag = false
    /// 本次按下时是否按着 ⌘（= 缩放模式，不拖出文件）
    private var resizeMode = false
    /// 用**屏幕坐标**记上一次的 x，不能用视图坐标：
    /// 窗口会随着放大整体变宽、卡片左边缘跟着左移，同一个屏幕点换算到视图里
    /// x 会越变越大，形成「越拖越快」的正反馈（v263 实测一拖就冲到 420 上限）。
    private var lastResizeScreenX: CGFloat = 0
    /// 缩放过程中用低插值，减少大图重绘成本；结束再恢复高质量
    private(set) var isLiveResizing = false
    /// 这张卡挂在绳子上应该歪多少（弧度，正 = 顺时针）。
    /// 由 `CurtainCanvasView` 按帘线在该 x 处的斜率算出来。
    var ropeTilt: CGFloat = 0 {
        didSet { if abs(oldValue - ropeTilt) > 0.0001 { needsDisplay = true } }
    }
    /// 常驻微摆的相位（每张卡错开，避免整齐划一地一起动）
    var swayPhase: Double = 0

    private let closeButton = NSButton(frame: .zero)
    private let saveButton = NSButton(frame: .zero)
    private let pinButton = NSButton(frame: .zero)

    var onRemove: ((CurtainItem) -> Void)?
    var onSave: ((CurtainItem) -> Void)?
    var onPin: ((CurtainItem) -> Void)?
    /// ⌘ 拖动缩放：每次鼠标事件回调「相对上一次的 x 位移」
    var onResizeStep: ((CGFloat) -> Void)?
    /// 缩放结束（鼠标抬起 / 滚轮停下）
    var onResizeEnd: (() -> Void)?

    private var clipHeight: CGFloat { CurtainMetrics.clipHeight(railScale) }

    init(item: CurtainItem, cardSize: CGSize, railScale: CGFloat, thumbnail: CGImage?) {
        self.item = item
        self.cardSize = cardSize
        self.railScale = railScale
        self.thumbnail = thumbnail
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: cardSize.width,
                                 height: CurtainMetrics.clipHeight(railScale) + cardSize.height))
        wantsLayer = true
        layer?.masksToBounds = false
        // 卡片投影。参数取自 1Capture HangingShelfCard.initWithFrame 的指令：
        //   shadowOpacity 0x3E6B851F ≈ 0.23、shadowRadius 9、shadowOffset (0, -5)
        // 比我们原来那套（0.34 / 7 / (0,-3)）更淡、更散、更往下——
        // 光从上方来，卡片又挂在绳上，影子自然压在下面。
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.23
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -5)
        setupButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// 原地改尺寸：只改 frame / 按钮位置并重绘，不重建视图、不重挂动画。
    /// ⌘ 拖动时每帧都会走这里，所以这里**不能**碰缩略图解码或窗口层级。
    func update(cardSize: CGSize, railScale: CGFloat, live: Bool) {
        self.cardSize = cardSize
        self.railScale = railScale
        self.isLiveResizing = live
        setFrameSize(NSSize(width: cardSize.width, height: CurtainMetrics.clipHeight(railScale) + cardSize.height))
        layoutButtons()
        needsDisplay = true
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 整张卡（含夹子）绕**夹子**旋转：它挂在绳上是跟着绳子的切线歪的。
        // 锚点取夹子中心，不取卡片中心——只有夹子被绳子约束住，卡片是垂下来的。
        if abs(ropeTilt) > 0.0001 {
            let anchor = CGPoint(x: bounds.midX, y: clipHeight / 2)
            ctx.saveGState()
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: ropeTilt)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
        }
        defer {
            if abs(ropeTilt) > 0.0001 { ctx.restoreGState() }
        }

        let radius = CurtainMetrics.cornerRadius(for: cardSize.width, scale: railScale)
        let cardRect = NSRect(x: 0,
                              y: clipHeight,
                              width: cardSize.width,
                              height: cardSize.height)
        let path = CGPath(roundedRect: cardRect,
                          cornerWidth: radius,
                          cornerHeight: radius,
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
            // 缩放过程中用低插值：420pt 宽 × 8 张卡时，高质量重采样会吃掉主线程；
            // 松手后 `isLiveResizing=false` 再按高质量重绘一次。
            ctx.interpolationQuality = isLiveResizing ? .low : .high
            ctx.translateBy(x: 0, y: cardRect.minY + cardRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(thumbnail, in: drawRect)
            ctx.restoreGState()
        } else {
            // 缩略图还没解码出来：用 1Capture 那个「玻璃渐变」占位。
            //
            // 反汇编 HangingShelfCard.initWithFrame 里它建了一个 CAGradientLayer：
            //   colors    = [white 0.62, white 0.94, white 0.80, white 0.61]
            //   locations = [0, 0.36, 0.68, 1]
            //   startPoint (0,0.5) → endPoint (1,0.5)   ← 水平
            //   圆角 3、边框 0.5
            // 四个颜色的 alpha 都是 1，所以它只能在「没有图」的时候露出来，
            // 一旦有缩略图就会被盖住——也就是占位底色，不是叠加高光。
            // 之前我们这里是一块纯色，闪一下很明显；换成同参数的横向渐变。
            if let gradient = Self.placeholderGradient(isDark: isDark) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: cardRect.minX, y: cardRect.midY),
                                       end: CGPoint(x: cardRect.maxX, y: cardRect.midY),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        ctx.restoreGState()

        // 描边：双色（外深内浅），保证在任何桌面背景上都有边界
        ctx.addPath(path)
        ctx.setLineWidth((hovered ? 1.5 : 0.8) * railScale)
        if hovered {
            ctx.setStrokeColor(Theme.accentNS.withAlphaComponent(0.9).cgColor)
        } else {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.32))
        }
        ctx.strokePath()

        if !hovered {
            // 内侧一道极淡的白边，深色桌面上能把卡片从背景里「托」起来
            let inset = 0.6 * railScale
            let inner = CGPath(roundedRect: cardRect.insetBy(dx: inset, dy: inset),
                               cornerWidth: radius,
                               cornerHeight: radius,
                               transform: nil)
            ctx.addPath(inner)
            ctx.setLineWidth(0.6 * railScale)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
            ctx.strokePath()
        }

        drawClip(ctx, isDark: isDark)
    }

    /// 1Capture 的占位渐变（反汇编值）：四段灰度、位置 0 / 0.36 / 0.68 / 1、水平方向。
    /// 深色模式取补色，否则 0.94 的白在深色桌面上会糊成一块亮斑。
    private static func placeholderGradient(isDark: Bool) -> CGGradient? {
        let grays: [CGFloat] = [0.62, 0.94, 0.80, 0.61]
        let locations: [CGFloat] = [0, 0.36, 0.68, 1]
        let colors = grays.map { CGColor(gray: isDark ? (1 - $0) : $0, alpha: 1) }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                          colors: colors as CFArray,
                          locations: locations)
    }

    /// 夹子：一个小梯形压在帘线与卡片之间，让人相信「这张是挂在帘线上的」
    private func drawClip(_ ctx: CGContext, isDark: Bool) {
        let s = railScale
        let w: CGFloat = 12 * s
        let x = bounds.midX - w / 2
        let top: CGFloat = 4 * s
        let bottom = clipHeight + 2 * s

        let clip = CGMutablePath()
        clip.move(to: CGPoint(x: x + 1.5 * s, y: top))
        clip.addLine(to: CGPoint(x: x + w - 1.5 * s, y: top))
        clip.addLine(to: CGPoint(x: x + w, y: bottom))
        clip.addLine(to: CGPoint(x: x, y: bottom))
        clip.closeSubpath()

        ctx.saveGState()
        // 夹子投影，让它和卡片有前后关系
        ctx.setShadow(offset: CGSize(width: 0, height: 1 * s),
                      blur: 2.5 * s,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(clip)
        ctx.setFillColor(isDark
                         ? CGColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1)
                         : CGColor(red: 0.72, green: 0.72, blue: 0.75, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // 夹口的一道暗线
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.22))
        ctx.setLineWidth(1 * s)
        ctx.move(to: CGPoint(x: x + 2.5 * s, y: top + 3.5 * s))
        ctx.addLine(to: CGPoint(x: x + w - 2.5 * s, y: top + 3.5 * s))
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
        // 先停摆再位移：`transform.rotation.z` 的动画和 setAffineTransform 写的是
        // 同一个 transform，共存时 CA 会按最后写入的那份插值，肉眼看是「抖一下」。
        stopSway()
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
        startSway()
    }

    // MARK: 常驻微摆

    /// 一排卡片各自轻微摆动，幅度 ±0.7°、周期 3.4–4.3 秒。
    ///
    /// 用 `CABasicAnimation` 改 `transform`，**不重绘内容、不占主线程**：
    /// 动画跑在 render server 上，滚动/截图/CPU 满载时都不会掉帧。
    /// 这也是为什么不采用「定时器 + needsDisplay」——那条路每帧都要重画缩略图。
    ///
    /// 摆动**不含** `ropeTilt`：静态倾斜已经由 `draw` 里的 ctx 旋转完成，
    /// 这里再加一次会变成双倍倾角。
    func startSway() {
        guard let layer, !hovered, window != nil else { return }
        // 已经在摆就别重挂：设置页拖滑块会频繁 rebuild，重挂会让整排卡片「跳」一下
        if layer.animation(forKey: Self.swayKey) != nil { return }
        layer.removeAnimation(forKey: Self.swayKey)
        let amplitude = 0.7 * Double.pi / 180
        let h = bounds.height
        let swing = CABasicAnimation(keyPath: "transform")
        swing.fromValue = NSValue(caTransform3D: CurtainCanvasView.topPivot(angle: -amplitude, height: h))
        swing.toValue = NSValue(caTransform3D: CurtainCanvasView.topPivot(angle: amplitude, height: h))
        swing.duration = 3.4 + (swayPhase * 0.37).truncatingRemainder(dividingBy: 0.9)
        swing.autoreverses = true
        swing.repeatCount = .infinity
        swing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        swing.timeOffset = swayPhase
        swing.isRemovedOnCompletion = false
        layer.add(swing, forKey: Self.swayKey)
    }

    func stopSway() {
        layer?.removeAnimation(forKey: Self.swayKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 窗口收起（orderOut）时把动画撤掉：不可见的图层还在跑动画是纯浪费，
        // 而这块架子大部分时间都是收起的。
        if window == nil { stopSway() } else { startSway() }
    }

    private static let swayKey = "curtain.sway"

    // MARK: 按钮

    private func setupButtons() {
        configure(closeButton, symbol: "xmark", action: #selector(removeTapped))
        configure(saveButton, symbol: "square.and.arrow.down", action: #selector(saveTapped))
        configure(pinButton, symbol: "pin", action: #selector(pinTapped))
        layoutButtons()
        setButtonsHidden(true)
    }

    /// 按钮位置跟着卡片尺寸走（⌘ 缩放时每帧调用）
    private func layoutButtons() {
        let s = railScale
        let side = 17 * s
        let inset = 5 * s
        let left = 6 * s
        closeButton.frame = NSRect(x: cardSize.width - side - inset,
                                   y: clipHeight + inset,
                                   width: side, height: side)
        saveButton.frame = NSRect(x: left,
                                  y: clipHeight + cardSize.height - side - inset,
                                  width: side, height: side)
        pinButton.frame = NSRect(x: left + side + 4 * s,
                                 y: clipHeight + cardSize.height - side - inset,
                                 width: side, height: side)
        for button in [closeButton, saveButton, pinButton] {
            button.layer?.cornerRadius = 8.5 * s
            button.imageScaling = .scaleProportionallyDown
        }
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

    // MARK: 点击 / 拖拽 / ⌘ 缩放

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
        // ⌘ + 拖动 = 调图帘大小。这个组合不能和「拖出文件」共用：
        // 拖出是用户最常用的动作，缩放必须显式按住修饰键才进入。
        resizeMode = event.modifierFlags.contains(.command)
        lastResizeScreenX = NSEvent.mouseLocation.x
        if resizeMode {
            stopSway()
            NSCursor.resizeLeftRight.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if resizeMode {
            let x = NSEvent.mouseLocation.x
            let delta = x - lastResizeScreenX
            lastResizeScreenX = x
            if abs(delta) > 0.01 { onResizeStep?(delta) }
            return
        }
        guard let origin = mouseDownPoint, !didStartDrag else { return }
        guard hypot(p.x - origin.x, p.y - origin.y) > 4 else { return }
        didStartDrag = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            if resizeMode { NSCursor.pop(); resizeMode = false }
        }
        if resizeMode {
            onResizeEnd?()
            startSway()
            return
        }
        guard !didStartDrag else { return }
        copyToPasteboard()
    }

    /// ⌘ + 滚轮也能缩放（触控板双指 + ⌘ 比按住拖动更省力）
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.6 : 2.0)
        guard abs(delta) > 0.01 else { return }
        onResizeStep?(delta)
        onResizeEnd?()
    }

    /// 复制 = 同时给 PNG 和文件 URL，粘贴到聊天窗口是图片，粘到 Finder 是文件
    private func copyToPasteboard() {
        let data: Data
        do { data = try Data(contentsOf: item.fileURL) }
        catch {
            Toast.show("复制失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        let contents = NSPasteboardItem()
        contents.setData(data, forType: .png)
        contents.setString(item.fileURL.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.writeObjects([contents]) else {
            Toast.show("复制失败：未能写入剪贴板", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
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
        // v263：不按住 ⌘ 也能改大小——右键给两个确定性的档位
        let bigger = menu.addItem(withTitle: "放大图帘", action: #selector(zoomIn), keyEquivalent: "")
        bigger.target = self
        let smaller = menu.addItem(withTitle: "缩小图帘", action: #selector(zoomOut), keyEquivalent: "")
        smaller.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "从图帘移除", action: #selector(removeTapped), keyEquivalent: "").target = self
        return menu
    }

    @objc private func zoomIn() {
        onResizeStep?(40)
        onResizeEnd?()
    }

    @objc private func zoomOut() {
        onResizeStep?(-40)
        onResizeEnd?()
    }

    @objc private func copyFromMenu() { copyToPasteboard() }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }
}

// MARK: - 拖拽源

extension CurtainCardView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

// MARK: - 帘线

/// 整条帘线。四种样式全部用 CoreGraphics 画，不引入 CAEmitterLayer。
///
/// 几何与描边参数来自 1Capture `HangingShelfRopeView` 的反汇编：
/// - 三次贝塞尔，控制点在 1/3 与 2/3（不是二次贝塞尔的单控制点）
/// - 下垂量按**宽度**算：`min(width * 0.018, 28)`，与挂了几张无关
/// - 线端距视图顶 12pt
/// - 每道描边都带 `shadow(黑 28%, offset(0,1), blur 2)`——靠阴影勾轮廓，
///   而不是靠双色描边。双色看起来是两条平行线，不像一根线。
///
/// v263：所有数值再乘 `geometry.scale`。卡片放大时线也变粗、下垂更深，
/// 否则 420pt 的卡片挂在一根 2pt 细线上，视觉上像贴纸而不是挂件。
final class CurtainRopeView: NSView {

    var style: CurtainRopeStyle = .classic {
        didSet { needsDisplay = true }
    }
    /// 卡片中心的 x 坐标（保留给命中/调试；几何本身按宽度算，与张数无关）
    var loadPoints: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }
    /// 由画布注入，保证卡片算倾斜用的曲线和这里画的是同一条
    var geometry: CurtainRopeGeometry? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    private var currentGeometry: CurtainRopeGeometry {
        geometry ?? CurtainRopeGeometry(width: bounds.width,
                                        ropeTop: CurtainMetrics.ropeInset(1),
                                        scale: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 4 else { return }
        let g = currentGeometry
        let path = ropePath(g)
        let s = g.scale

        ctx.saveGState()
        // 主绳的投影：这是「任何桌面都看得见」的真正保障。
        // flipped 坐标里 +y 是向下，所以把阴影压到绳子下方。
        // 实测 0.28/2pt 在浅色桌面上几乎看不见（白线叠白底），
        // 加深到 0.46/2.5pt，浅底靠暗晕勾边、深底靠白线本身。
        ctx.setShadow(offset: CGSize(width: 0, height: 1 * s),
                      blur: 2.5 * s,
                      color: CGColor(gray: 0, alpha: 0.46))

        switch style {
        case .classic:
            stroke(ctx, path, width: 2.0 * s, gray: 0.72, alpha: 0.95)
            // 细芯：1Capture 用 0.45pt 的同色半透明线叠在中间，
            // 让绳子有「芯」，不是一根均匀的带子。
            // 实测单靠 0.62 白的单道线，在浅色桌面上会整条糊掉。
            clearShadow(ctx)
            stroke(ctx, path, width: 0.45 * s, gray: 0.85, alpha: 0.55)

        case .candyCane:
            stroke(ctx, path, width: 3.0 * s, gray: 0.997, alpha: 1.0)
            clearShadow(ctx)
            // 红白相间 = 白底上叠红色虚线，圆头线帽让红段变成糖果条纹
            dashed(ctx, path, width: 3.0 * s,
                   color: CGColor(red: 0.86, green: 0.03, blue: 0.16, alpha: 1),
                   pattern: [3.2 * s, 3.2 * s])

        case .lights:
            stroke(ctx, path, width: 1.4 * s, gray: 0.72, alpha: 0.95)
            clearShadow(ctx)
            drawLights(ctx, g)

        case .snow:
            stroke(ctx, path, width: 2.0 * s, gray: 0.72, alpha: 0.95)
            clearShadow(ctx)
            drawSnow(ctx, g)
        }

        drawKnots(ctx, g)
        ctx.restoreGState()
    }

    // MARK: 路径

    /// 三次贝塞尔：起点 (inset, y)，终点 (w-inset, y)，
    /// 控制点落在 1/3 与 2/3，所以 x(t) 仍是线性——
    /// `CurtainRopeGeometry` 正是靠这一点直接按 x 反解 t。
    ///
    /// 两端各留 5pt 是给绳结的：原来绳子直接顶到窗口边缘，视觉上是
    /// 「一根线被窗口切断」，而不是「一段绳子的两端」。
    private func ropePath(_ g: CurtainRopeGeometry) -> CGPath {
        let inset = CurtainMetrics.ropeEndInset(g.scale)
        let w = max(g.width - inset * 2, 1)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset, y: g.y))
        path.addCurve(to: CGPoint(x: inset + w, y: g.y),
                      control1: CGPoint(x: inset + w / 3, y: g.y + g.sag),
                      control2: CGPoint(x: inset + w * 2 / 3, y: g.y + g.sag))
        return path
    }

    /// 两端的绳结：一个实心小圆 + 一圈暗描边。
    /// 它的作用不是装饰，是把「线断了」读成「绳系住了」。
    private func drawKnots(_ ctx: CGContext, _ g: CurtainRopeGeometry) {
        let r: CGFloat = 2.8 * g.scale
        let inset = CurtainMetrics.ropeEndInset(g.scale)
        for cx in [inset, g.width - inset] {
            let rect = CGRect(x: cx - r, y: g.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(CGColor(gray: 0.78, alpha: 0.98))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.34))
            ctx.setLineWidth(0.6 * g.scale)
            ctx.strokeEllipse(in: rect)
        }
    }

    // MARK: 描边

    private func clearShadow(_ ctx: CGContext) {
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    private func stroke(_ ctx: CGContext, _ path: CGPath,
                        width: CGFloat, gray: CGFloat, alpha: CGFloat) {
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(gray: gray, alpha: alpha))
        ctx.strokePath()
    }

    private func dashed(_ ctx: CGContext, _ path: CGPath,
                        width: CGFloat, color: CGColor, pattern: [CGFloat]) {
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color)
        ctx.setLineDash(phase: 0, lengths: pattern)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: 装饰

    /// 圣诞彩灯：沿帘线每 24pt 一颗，四色循环。
    /// 外圈用低透明度圆做光晕——比真 shadow 便宜得多，也够像。
    private func drawLights(_ ctx: CGContext, _ g: CurtainRopeGeometry) {
        let palette: [CGColor] = [
            NSColor.systemYellow.cgColor,
            NSColor.systemPink.cgColor,
            NSColor.systemTeal.cgColor,
            NSColor.systemOrange.cgColor,
        ]
        for (i, point) in samplePoints(g, spacing: 24 * g.scale).enumerated() {
            let r: CGFloat = 2.1 * g.scale
            // 灯是「垂下来」的：沿帘线再往下 2pt，挂在绳下而不是压在绳上
            let c = CGPoint(x: point.x, y: point.y + 2.2 * g.scale)
            ctx.setFillColor(palette[i % palette.count].copy(alpha: 0.20) ?? palette[i % palette.count])
            ctx.fillEllipse(in: CGRect(x: c.x - r * 2.4, y: c.y - r * 2.4,
                                       width: r * 4.8, height: r * 4.8))
            ctx.setFillColor(palette[i % palette.count])
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
    }

    /// 积雪：沿绳线上沿堆一串大小不一的白色小球。
    /// 用确定性伪随机，避免每次重绘雪的形状都在跳。
    ///
    /// 球径 1.3–3.2pt、间距 6.5pt：间距比球径稍大一点才看得出是「一坨一坨的雪」，
    /// 5pt 间距配 1–2.5pt 球径会连成一条珠子，像霜不像雪。
    private func drawSnow(_ ctx: CGContext, _ g: CurtainRopeGeometry) {
        for (i, point) in samplePoints(g, spacing: 6.5 * g.scale).enumerated() {
            let n = CGFloat((i &* 2654435761) % 100) / 100
            let r = (1.3 + n * 1.9) * g.scale
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.90))
            // flipped 坐标里「上沿」是 y 更小
            ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r * 1.9,
                                       width: r * 2, height: r * 1.9))
        }
    }

    /// 沿帘线按近似等距取样（按 x 均匀取样，再用三次贝塞尔求 y）
    private func samplePoints(_ g: CurtainRopeGeometry, spacing: CGFloat) -> [CGPoint] {
        let steps = max(Int(g.width / spacing), 1)
        var result: [CGPoint] = []
        result.reserveCapacity(steps + 1)
        for i in 0...steps {
            let x = g.width * CGFloat(i) / CGFloat(steps)
            result.append(CGPoint(x: x, y: g.y(atX: x)))
        }
        return result
    }
}

// MARK: - 画布

/// 窗口的宿主视图：翻转坐标（y 向下），让画布从顶部对齐。
final class CurtainHostView: NSView {
    override var isFlipped: Bool { true }
}

/// 排版容器：绳子在上，卡片按顺序挂着，整体水平居中。
final class CurtainCanvasView: NSView {

    private let rope = CurtainRopeView()
    private var cardViews: [CurtainCardView] = []

    var onRemove: ((CurtainItem) -> Void)?
    var onSave: ((CurtainItem) -> Void)?
    var onPin: ((CurtainItem) -> Void)?
    /// ⌘ 拖动 / ⌘ 滚轮缩放（卡片把自己的事件转上来，帘线空白处也接）
    var onResizeStep: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(rope)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 重排。`size` 是宿主给画布分配的尺寸（窗口内区）。
    ///
    /// v263：卡片尺寸不再固定，`railScale`（帘线缩放）与 `maxCardHeight`
    /// （按屏幕高度兜底）一并传进来；`animate=false` 用于缩放结束后的高质量重绘，
    /// 避免每改一次宽度就重播一遍落入动画。
    func reload(items: [(CurtainItem, CGImage?)],
                cardWidth: CGFloat,
                railScale: CGFloat,
                maxCardHeight: CGFloat,
                style: CurtainRopeStyle,
                size: CGSize,
                animate: Bool = true) {
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = []
        rope.style = style
        layoutCards(items: items, cardWidth: cardWidth, railScale: railScale,
                    maxCardHeight: maxCardHeight, size: size, live: false, animate: animate)
    }

    /// ⌘ 拖动缩放：**原地改尺寸**，不重建卡片视图。
    ///
    /// 为什么必须单独一条路径：`reload` 会 remove + add 所有子视图，
    /// 每帧都做等于每帧重挂图层、重播落入动画，拖动时必然掉帧。
    /// 这里只改 frame / 重绘，卡片对象与动画都留着。
    func updateLayout(items: [(CurtainItem, CGImage?)],
                      cardWidth: CGFloat,
                      railScale: CGFloat,
                      maxCardHeight: CGFloat,
                      size: CGSize) {
        guard cardViews.count == items.count,
              zip(cardViews, items).allSatisfy({ $0.0.item.id == $0.1.0.id }) else {
            reload(items: items, cardWidth: cardWidth, railScale: railScale,
                   maxCardHeight: maxCardHeight, style: rope.style, size: size, animate: false)
            return
        }
        layoutCards(items: items, cardWidth: cardWidth, railScale: railScale,
                    maxCardHeight: maxCardHeight, size: size, live: true, animate: false)
    }

    private func layoutCards(items: [(CurtainItem, CGImage?)],
                             cardWidth: CGFloat,
                             railScale: CGFloat,
                             maxCardHeight: CGFloat,
                             size: CGSize,
                             live: Bool,
                             animate: Bool) {
        let gap = CurtainMetrics.gap(railScale)
        let padding = CurtainMetrics.padding(railScale)
        let clipH = CurtainMetrics.clipHeight(railScale)
        let sizes = items.map {
            $0.0.cardSize(cardWidth: cardWidth, railScale: railScale, maxHeight: maxCardHeight)
        }
        let totalW = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(items.count - 1, 0)) * gap
            + padding * 2
        // 内容比窗口窄时居中，宽时从左边开始（超出部分由窗口宽度裁掉，但正常不会发生）
        var x = max(padding, (size.width - totalW) / 2 + padding)
        var centers: [CGFloat] = []
        let geometry = CurtainRopeGeometry(width: size.width,
                                           ropeTop: CurtainMetrics.ropeInset(railScale),
                                           scale: railScale)
        rope.frame = NSRect(x: 0, y: 0, width: size.width,
                            height: CurtainMetrics.ropeHeight(railScale))
        rope.geometry = geometry

        for (index, entry) in items.enumerated() {
            let cardSize = sizes[index]
            let card: CurtainCardView
            let isNew = index >= cardViews.count
            if isNew {
                card = CurtainCardView(item: entry.0, cardSize: cardSize,
                                       railScale: railScale, thumbnail: entry.1)
                card.onRemove = { [weak self] in self?.onRemove?($0) }
                card.onSave = { [weak self] in self?.onSave?($0) }
                card.onPin = { [weak self] in self?.onPin?($0) }
                card.onResizeStep = { [weak self] delta in self?.onResizeStep?(delta) }
                card.onResizeEnd = { [weak self] in self?.onResizeEnd?() }
                card.swayPhase = Double(index) * 0.618
                addSubview(card)
                cardViews.append(card)
            } else {
                card = cardViews[index]
                card.update(cardSize: cardSize, railScale: railScale, live: live)
            }
            card.frame = NSRect(x: x, y: 0,
                                width: cardSize.width,
                                height: clipH + cardSize.height)
            // 卡片跟着帘线歪：挂在一根下垂的帘线上还笔直垂着，是「假」的最大来源
            card.ropeTilt = geometry.tilt(atX: card.frame.midX)
            centers.append(card.frame.midX)
            x += cardSize.width + gap
            if animate && isNew {
                animateDrop(card, index: index, geometry: geometry)
            } else if live {
                card.stopSway()
            } else {
                card.startSway()
            }
        }
        rope.loadPoints = centers
    }

    // MARK: ⌘ 缩放（空白处 / 帘线上）

    private var canvasResizeLastScreenX: CGFloat?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        canvasResizeLastScreenX = NSEvent.mouseLocation.x
        NSCursor.resizeLeftRight.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = canvasResizeLastScreenX else {
            super.mouseDragged(with: event)
            return
        }
        let x = NSEvent.mouseLocation.x
        let delta = x - last
        canvasResizeLastScreenX = x
        if abs(delta) > 0.01 { onResizeStep?(delta) }
    }

    override func mouseUp(with event: NSEvent) {
        guard canvasResizeLastScreenX != nil else {
            super.mouseUp(with: event)
            return
        }
        canvasResizeLastScreenX = nil
        NSCursor.pop()
        onResizeEnd?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.6 : 2.0)
        guard abs(delta) > 0.01 else { return }
        onResizeStep?(delta)
        onResizeEnd?()
    }

    /// 落入动画：从上方 10pt 落下 + 淡入 + 绕顶部摆一次衰减，
    /// 摆完后接上常驻微摆（`startSway`）。
    ///
    /// 为什么可以常驻：微摆只改 `transform`，**不重绘内容**，动画跑在
    /// render server 上，主线程和 GPU 的代价与「静止」几乎一样。
    /// 之前担心的掉帧来自「定时器 + needsDisplay」那条路，不是这条路。
    private func animateDrop(_ card: CurtainCardView, index: Int, geometry: CurtainRopeGeometry) {
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

        // 落地回弹：在卡片自己的倾斜角上做，摆完正好交给微摆接手
        let base = card.ropeTilt
        let offsets: [CGFloat] = [0, -0.032, 0.024, -0.015, 0.008, -0.003, 0]
        let values = offsets.map {
            NSValue(caTransform3D: CurtainCanvasView.topPivot(angle: base + $0, height: h))
        }
        let bounce = CAKeyframeAnimation(keyPath: "transform")
        bounce.values = values
        bounce.keyTimes = [0, 0.12, 0.3, 0.48, 0.66, 0.84, 1].map { NSNumber(value: $0) }
        bounce.duration = 1.5
        bounce.beginTime = CACurrentMediaTime() + 0.34 + Double(index) * 0.04
        bounce.isRemovedOnCompletion = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak card] in
            // 回弹结束后无缝接上常驻微摆；卡片已被移除时 startSway 内部会自己跳过
            card?.startSway()
        }
        layer.add(bounce, forKey: "drop.bounce")
        CATransaction.commit()
    }

    /// 把旋转中心从图层中心挪到顶部中心
    static func topPivot(angle: CGFloat, height: CGFloat) -> CATransform3D {        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, 0, -height / 2, 0)
        t = CATransform3DRotate(t, angle, 0, 0, 1)
        t = CATransform3DTranslate(t, 0, height / 2, 0)
        return t
    }
}

// MARK: - 窗口

/// 图帘窗口：贴在菜单栏下方的一条，无边框、不激活、不进截图。
final class CurtainPanel: NSPanel {

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
