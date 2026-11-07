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
    /// 绳端距视图顶的距离。1Capture 反汇编：`y = height - 12`
    static let ropeInset: CGFloat = 12
    /// 下垂量系数。1Capture：`sag = min(width * 0.018, 28)`
    static let sagRatio: CGFloat = 0.018
    /// 下垂量上限
    static let sagMax: CGFloat = 28
    /// 绳子两端留给绳结的距离
    static let ropeEndInset: CGFloat = 5
    /// 卡片之间的水平间距
    static let gap: CGFloat = 16
    /// 左右留白
    static let padding: CGFloat = 22
    /// 夹子高度
    static let clipHeight: CGFloat = 20
    /// 卡片圆角（按卡片宽度自适应，见 `cornerRadius(for:)`）
    static let cardRadiusMin: CGFloat = 8
    static let cardRadiusMax: CGFloat = 18
    /// 窗口底部余量（给投影）
    static let bottomInset: CGFloat = 12

    /// 卡片圆角 = 宽度 × 0.09，钳到 8…18。
    /// 1Capture 反汇编里是写死的 25pt，但它的卡片比我们宽；
    /// 按宽度比例算，小卡片不会被圆角吃掉内容。
    static func cornerRadius(for cardWidth: CGFloat) -> CGFloat {
        min(max(cardWidth * 0.09, cardRadiusMin), cardRadiusMax)
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
struct ShelfRopeGeometry {
    let width: CGFloat
    /// 绳端 y（视图坐标，已翻转为向下为正）
    let y: CGFloat
    let sag: CGFloat

    init(width: CGFloat, ropeTop: CGFloat) {
        self.width = max(width, 1)
        self.y = ropeTop
        self.sag = min(max(width, 1) * ShelfMetrics.sagRatio, ShelfMetrics.sagMax)
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
    /// 这张卡挂在绳子上应该歪多少（弧度，正 = 顺时针）。
    /// 由 `ShelfCanvasView` 按绳线在该 x 处的斜率算出来。
    var ropeTilt: CGFloat = 0 {
        didSet { if abs(oldValue - ropeTilt) > 0.0001 { needsDisplay = true } }
    }
    /// 常驻微摆的相位（每张卡错开，避免整齐划一地一起动）
    var swayPhase: Double = 0

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

        // 整张卡（含夹子）绕**夹子**旋转：它挂在绳上是跟着绳子的切线歪的。
        // 锚点取夹子中心，不取卡片中心——只有夹子被绳子约束住，卡片是垂下来的。
        if abs(ropeTilt) > 0.0001 {
            let anchor = CGPoint(x: bounds.midX, y: ShelfMetrics.clipHeight / 2)
            ctx.saveGState()
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: ropeTilt)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
        }
        defer {
            if abs(ropeTilt) > 0.0001 { ctx.restoreGState() }
        }

        let radius = ShelfMetrics.cornerRadius(for: cardSize.width)
        let cardRect = NSRect(x: 0,
                              y: ShelfMetrics.clipHeight,
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
                               cornerWidth: radius,
                               cornerHeight: radius,
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
        layer.removeAnimation(forKey: Self.swayKey)
        let amplitude = 0.7 * Double.pi / 180
        let h = bounds.height
        let swing = CABasicAnimation(keyPath: "transform")
        swing.fromValue = NSValue(caTransform3D: ShelfCanvasView.topPivot(angle: -amplitude, height: h))
        swing.toValue = NSValue(caTransform3D: ShelfCanvasView.topPivot(angle: amplitude, height: h))
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

    private static let swayKey = "shelf.sway"

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
///
/// 几何与描边参数来自 1Capture `HangingShelfRopeView` 的反汇编：
/// - 三次贝塞尔，控制点在 1/3 与 2/3（不是二次贝塞尔的单控制点）
/// - 下垂量按**宽度**算：`min(width * 0.018, 28)`，与挂了几张无关
/// - 绳端距视图顶 12pt
/// - 每道描边都带 `shadow(黑 28%, offset(0,1), blur 2)`——靠阴影勾轮廓，
///   而不是靠双色描边。双色看起来是两条平行线，不像一根绳。
final class ShelfRopeView: NSView {

    var style: ShelfRopeStyle = .classic {
        didSet { needsDisplay = true }
    }
    /// 卡片中心的 x 坐标（保留给命中/调试；几何本身按宽度算，与张数无关）
    var loadPoints: [CGFloat] = [] {
        didSet { needsDisplay = true }
    }
    /// 由画布注入，保证卡片算倾斜用的曲线和这里画的是同一条
    var geometry: ShelfRopeGeometry? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    private var currentGeometry: ShelfRopeGeometry {
        geometry ?? ShelfRopeGeometry(width: bounds.width, ropeTop: ShelfMetrics.ropeInset)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 4 else { return }
        let g = currentGeometry
        let path = ropePath(g)

        ctx.saveGState()
        // 主绳的投影：这是「任何桌面都看得见」的真正保障。
        // flipped 坐标里 +y 是向下，所以把阴影压到绳子下方。
        // 实测 0.28/2pt 在浅色桌面上几乎看不见（白线叠白底），
        // 加深到 0.46/2.5pt，浅底靠暗晕勾边、深底靠白线本身。
        ctx.setShadow(offset: CGSize(width: 0, height: 1),
                      blur: 2.5,
                      color: CGColor(gray: 0, alpha: 0.46))

        switch style {
        case .classic:
            stroke(ctx, path, width: 2.0, gray: 0.72, alpha: 0.95)
            // 细芯：1Capture 用 0.45pt 的同色半透明线叠在中间，
            // 让绳子有「芯」，不是一根均匀的带子。
            // 实测单靠 0.62 白的单道线，在浅色桌面上会整条糊掉。
            clearShadow(ctx)
            stroke(ctx, path, width: 0.45, gray: 0.85, alpha: 0.55)

        case .candyCane:
            stroke(ctx, path, width: 3.0, gray: 0.997, alpha: 1.0)
            clearShadow(ctx)
            // 红白相间 = 白底上叠红色虚线，圆头线帽让红段变成糖果条纹
            dashed(ctx, path, width: 3.0,
                   color: CGColor(red: 0.86, green: 0.03, blue: 0.16, alpha: 1),
                   pattern: [3.2, 3.2])

        case .lights:
            stroke(ctx, path, width: 1.4, gray: 0.72, alpha: 0.95)
            clearShadow(ctx)
            drawLights(ctx, g)

        case .snow:
            stroke(ctx, path, width: 2.0, gray: 0.72, alpha: 0.95)
            clearShadow(ctx)
            drawSnow(ctx, g)
        }

        drawKnots(ctx, g)
        ctx.restoreGState()
    }

    // MARK: 路径

    /// 三次贝塞尔：起点 (inset, y)，终点 (w-inset, y)，
    /// 控制点落在 1/3 与 2/3，所以 x(t) 仍是线性——
    /// `ShelfRopeGeometry` 正是靠这一点直接按 x 反解 t。
    ///
    /// 两端各留 5pt 是给绳结的：原来绳子直接顶到窗口边缘，视觉上是
    /// 「一根线被窗口切断」，而不是「一段绳子的两端」。
    private func ropePath(_ g: ShelfRopeGeometry) -> CGPath {
        let inset = ShelfMetrics.ropeEndInset
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
    private func drawKnots(_ ctx: CGContext, _ g: ShelfRopeGeometry) {
        let r: CGFloat = 2.8
        for cx in [ShelfMetrics.ropeEndInset, g.width - ShelfMetrics.ropeEndInset] {
            let rect = CGRect(x: cx - r, y: g.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(CGColor(gray: 0.78, alpha: 0.98))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.34))
            ctx.setLineWidth(0.6)
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

    /// 圣诞彩灯：沿绳线每 24pt 一颗，四色循环。
    /// 外圈用低透明度圆做光晕——比真 shadow 便宜得多，也够像。
    private func drawLights(_ ctx: CGContext, _ g: ShelfRopeGeometry) {
        let palette: [CGColor] = [
            NSColor.systemYellow.cgColor,
            NSColor.systemPink.cgColor,
            NSColor.systemTeal.cgColor,
            NSColor.systemOrange.cgColor,
        ]
        for (i, point) in samplePoints(g, spacing: 24).enumerated() {
            let r: CGFloat = 2.1
            // 灯是「垂下来」的：沿绳子再往下 2pt，挂在绳下而不是压在绳上
            let c = CGPoint(x: point.x, y: point.y + 2.2)
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
    private func drawSnow(_ ctx: CGContext, _ g: ShelfRopeGeometry) {
        for (i, point) in samplePoints(g, spacing: 6.5).enumerated() {
            let n = CGFloat((i &* 2654435761) % 100) / 100
            let r = 1.3 + n * 1.9
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.90))
            // flipped 坐标里「上沿」是 y 更小
            ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r * 1.9,
                                       width: r * 2, height: r * 1.9))
        }
    }

    /// 沿绳线按近似等距取样（按 x 均匀取样，再用三次贝塞尔求 y）
    private func samplePoints(_ g: ShelfRopeGeometry, spacing: CGFloat) -> [CGPoint] {
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

        let geometry = ShelfRopeGeometry(width: size.width, ropeTop: ShelfMetrics.ropeInset)

        for (index, entry) in items.enumerated() {
            let cardSize = sizes[index]
            let card = ShelfCardView(item: entry.0, cardSize: cardSize, thumbnail: entry.1)
            card.onRemove = { [weak self] in self?.onRemove?($0) }
            card.onSave = { [weak self] in self?.onSave?($0) }
            card.onPin = { [weak self] in self?.onPin?($0) }
            card.frame = NSRect(x: x, y: 0,
                                width: cardSize.width,
                                height: ShelfMetrics.clipHeight + cardSize.height)
            // 卡片跟着绳线歪：挂在一根下垂的绳上还笔直垂着，是「假」的最大来源
            card.ropeTilt = geometry.tilt(atX: card.frame.midX)
            card.swayPhase = Double(index) * 0.618
            addSubview(card)
            cardViews.append(card)
            centers.append(card.frame.midX)
            x += cardSize.width + ShelfMetrics.gap
            animateDrop(card, index: index, geometry: geometry)
        }
        rope.loadPoints = centers
        rope.geometry = geometry
    }

    /// 落入动画：从上方 10pt 落下 + 淡入 + 绕顶部摆一次衰减，
    /// 摆完后接上常驻微摆（`startSway`）。
    ///
    /// 为什么可以常驻：微摆只改 `transform`，**不重绘内容**，动画跑在
    /// render server 上，主线程和 GPU 的代价与「静止」几乎一样。
    /// 之前担心的掉帧来自「定时器 + needsDisplay」那条路，不是这条路。
    private func animateDrop(_ card: ShelfCardView, index: Int, geometry: ShelfRopeGeometry) {
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
            NSValue(caTransform3D: ShelfCanvasView.topPivot(angle: base + $0, height: h))
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
