import AppKit
import CoreGraphics
import Foundation

// MARK: - 钉图外观（v233，对齐 1Capture 的 DecorateModel）
//
// 1Capture 的 `SnipPinWindowController.DecorateModel` 暴露了这几项：
//   BORDER_COLOR / BORDER_WIDTH / TOGGLE_ROUNDED_CORNERS / TOGGLE_WINDOW_SHADOW /
//   WINDOW_AUTO_MAGNET
// 这里落成全局偏好：新钉的图立刻生效，已钉的图在「更多」菜单里改。

public enum PinStyle {

    // 键名统一带 .window.：早期版本遗留过 pin.opacity / pin.border.width
    // （opacity 存的是 0.8，直接复用会让新钉图莫名其妙半透明）
    public static let keyBorderWidth = "pin.window.border.width"
    public static let keyBorderColor = "pin.window.border.color"
    public static let keyCorner      = "pin.window.corner.radius"
    public static let keyShadow      = "pin.window.shadow"
    public static let keyMagnet      = "pin.window.auto.magnet"
    public static let keyOpacity     = "pin.window.opacity"
    public static let keyAutoHide    = "pin.window.chrome.autohide"

    /// 描边宽度（0 = 无描边）。1.5 是「能在任何底图上看出边界」的最小值。
    public static var borderWidth: Double {
        get { Preferences.shared.value(keyBorderWidth, default: 1.5) }
        set { Preferences.shared.set(keyBorderWidth, max(0, min(6, newValue))) }
    }

    /// 描边颜色：auto / white / black / accent
    public static var borderColorToken: String {
        get { Preferences.shared.value(keyBorderColor, default: "auto") }
        set { Preferences.shared.set(keyBorderColor, newValue) }
    }

    /// 窗口圆角（0–24）
    public static var cornerRadius: Double {
        get { Preferences.shared.value(keyCorner, default: 10) }
        set { Preferences.shared.set(keyCorner, max(0, min(24, newValue))) }
    }

    /// 窗口投影（macOS 会按内容 alpha 自动裁剪出形状）
    public static var shadow: Bool {
        get { Preferences.shared.value(keyShadow, default: true) }
        set { Preferences.shared.set(keyShadow, newValue) }
    }

    /// 拖动时吸附到屏幕边缘与其它钉图
    public static var magnet: Bool {
        get { Preferences.shared.value(keyMagnet, default: true) }
        set { Preferences.shared.set(keyMagnet, newValue) }
    }

    /// 图片不透明度
    public static var opacity: Double {
        get { Preferences.shared.value(keyOpacity, default: 1.0) }
        set { Preferences.shared.set(keyOpacity, max(0.15, min(1, newValue))) }
    }

    /// 控制条静止多久后自动收起（秒）；0 = 不自动收起（移开鼠标仍会收起）
    public static var chromeAutoHide: Double {
        get { Preferences.shared.value(keyAutoHide, default: 2.5) }
        set { Preferences.shared.set(keyAutoHide, max(0, min(10, newValue))) }
    }

    /// auto：按图像四周平均亮度反色。浅色截图配深描边、深色截图配白描边，
    /// 这样不管钉的是白底文档还是暗色 IDE，边界都看得见。
    public static func sampledBorderColor(for image: CGImage?) -> NSColor {
        guard let image else { return NSColor(white: 1, alpha: 0.8) }
        let w = 32, h = 32
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return NSColor(white: 1, alpha: 0.8)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0, count = 0
        for y in 0..<h {
            for x in 0..<w {
                // 只取四周 3px 环：边框要和「边缘」区分开，不是和整图平均色
                guard x < 3 || x >= w - 3 || y < 3 || y >= h - 3 else { continue }
                let i = (y * w + x) * 4
                let r = Double(data[i]) / 255
                let g = Double(data[i + 1]) / 255
                let b = Double(data[i + 2]) / 255
                total += 0.2126 * r + 0.7152 * g + 0.0722 * b
                count += 1
            }
        }
        let lum = count > 0 ? total / Double(count) : 0.5
        return lum > 0.55 ? NSColor(white: 0.08, alpha: 0.45) : NSColor(white: 1, alpha: 0.82)
    }
}

// MARK: - 单张钉图的外观快照（v263）

/// 一张钉图自己的外观参数。
///
/// 为什么不是直接读 `PinStyle`：截图动作条里现在有「钉住 · 经典 / 无边框 / 卡片 / 强调」
/// 四个形态选项（用户原话：「一个形态一个选项」）。如果选完直接改全局偏好，
/// 用户下次随手钉一张就会莫名其妙变成上次选的形态；这里把参数**随窗口**带一份，
/// 只影响这一张。菜单里再改外观时同时写回全局，保持「新钉图沿用上次设置」的老行为。
public struct PinAppearance: Equatable {
    public var borderWidth: Double
    public var borderColorToken: String
    public var cornerRadius: Double
    public var shadow: Bool
    public var magnet: Bool
    public var opacity: Double
    public var chromeAutoHide: Double

    public init(borderWidth: Double, borderColorToken: String, cornerRadius: Double,
                shadow: Bool, magnet: Bool, opacity: Double, chromeAutoHide: Double) {
        self.borderWidth = borderWidth
        self.borderColorToken = borderColorToken
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.magnet = magnet
        self.opacity = opacity
        self.chromeAutoHide = chromeAutoHide
    }

    /// 当前全局设置（普通「钉住」用这个）
    public static var current: PinAppearance {
        PinAppearance(borderWidth: PinStyle.borderWidth,
                      borderColorToken: PinStyle.borderColorToken,
                      cornerRadius: PinStyle.cornerRadius,
                      shadow: PinStyle.shadow,
                      magnet: PinStyle.magnet,
                      opacity: PinStyle.opacity,
                      chromeAutoHide: PinStyle.chromeAutoHide)
    }

    /// 动作条里的四个形态。数值与设置页「外观预设」一致，两处不会各说各话。
    public static func preset(_ id: String) -> PinAppearance? {
        var p = current
        switch id {
        case "classic":
            p.borderWidth = 1.5; p.borderColorToken = "auto"; p.cornerRadius = 10; p.shadow = true
        case "borderless":
            p.borderWidth = 0; p.borderColorToken = "auto"; p.cornerRadius = 0; p.shadow = false
        case "card":
            p.borderWidth = 2; p.borderColorToken = "white"; p.cornerRadius = 16; p.shadow = true
        case "accent":
            p.borderWidth = 2; p.borderColorToken = "accent"; p.cornerRadius = 12; p.shadow = true
        default:
            return nil
        }
        return p
    }

    public var presetTitle: String? {
        for (id, title) in [("classic", "经典"), ("borderless", "无边框"),
                            ("card", "卡片"), ("accent", "强调")] {
            if let p = PinAppearance.preset(id), p.borderWidth == borderWidth,
               p.borderColorToken == borderColorToken,
               abs(p.cornerRadius - cornerRadius) < 0.01, p.shadow == shadow {
                return title
            }
        }
        return nil
    }
}

// MARK: - 工具条（图片内底边居中）
//
// 对照 1Capture 的 `SnipPinToolbarWC` 与资源清单：
//   sc_pin_drag_16x20 · sc_pin_annotate_20 · sc_pin_copy_20 · sc_pin_more_20 · sc_pin_close_20
// 截图里实际显示的是：拖拽柄 + 标注 + 拷贝 + 更多 + 「100%」。
// 关闭按钮是 `SnipPinWindowController.CloseButton`（独立类型），放在图片左上角。

/// 2×3 点阵拖拽柄（对应 sc_pin_drag_16x20）
final class PinDragGripView: NSView {
    var onDown: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func mouseDown(with event: NSEvent) { onDown?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.35, alpha: 0.95).setFill()
        let cols = 2, rows = 3
        let r: CGFloat = 1.7
        let dx: CGFloat = 6.0, dy: CGFloat = 5.5
        let totalW = CGFloat(cols - 1) * dx + r * 2
        let totalH = CGFloat(rows - 1) * dy + r * 2
        let x0 = (bounds.width - totalW) / 2 + r
        let y0 = (bounds.height - totalH) / 2 + r
        for c in 0..<cols {
            for row in 0..<rows {
                let rect = NSRect(x: x0 + CGFloat(c) * dx - r,
                                  y: y0 + CGFloat(row) * dy - r,
                                  width: r * 2, height: r * 2)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }
}

/// 带悬停底色的图标按钮
final class PinIconButton: NSButton {
    private var hovering = false
    private var hoverTracking: NSTrackingArea?
    /// 悬停进出（用于弹出统一气泡）
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        onHoverChange?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor(white: 0, alpha: 0.075).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                         xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 钉图控制条：胶囊底 + 拖拽柄 + 三个动作 + 缩放百分比
final class PinToolbarView: NSView {

    enum Metrics {
        static let height: CGFloat = 38
        static let hPad: CGFloat = 9
        static let gripWidth: CGFloat = 18
        static let gapAfterGrip: CGFloat = 4
        static let button: CGFloat = 32
        static let gapBeforeZoom: CGFloat = 4
        static let zoomWidth: CGFloat = 44
    }

    /// 182pt：9 + 18 + 4 + 32×3 + 4 + 44 + 9
    static var barWidth: CGFloat {
        Metrics.hPad * 2 + Metrics.gripWidth + Metrics.gapAfterGrip
            + Metrics.button * 3 + Metrics.gapBeforeZoom + Metrics.zoomWidth
    }

    var onAnnotate: (() -> Void)?
    var onCopy: (() -> Void)?
    var onMore: (() -> Void)?
    var onResetZoom: (() -> Void)?
    var onGripDown: ((NSEvent) -> Void)?
    var onGripDrag: ((NSEvent) -> Void)?
    /// 鼠标进入/离开整条控制条（用来钉住自动隐藏计时器）
    var onHoverChange: ((Bool) -> Void)?
    /// 悬停某个按钮时上抛气泡内容与锚点（本视图坐标）；离开时 model 为 nil
    var onBubble: ((PinBubbleModel?, NSRect) -> Void)?

    private let grip = PinDragGripView()
    private var iconButtons: [PinIconButton] = []
    private let zoomButton = PinTextButton()
    private var hoverTracking: NSTrackingArea?
    /// 缩放百分比（气泡里要读）
    private var currentPercent = 100

    /// 「更多」按钮在本视图里的位置（列表以它为锚点）
    var moreAnchor: NSRect {
        iconButtons.count > 2 ? iconButtons[2].frame : bounds
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.26
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        grip.onDown = { [weak self] event in self?.onGripDown?(event) }
        grip.onDrag = { [weak self] event in self?.onGripDrag?(event) }
        grip.onHoverChange = { [weak self] inside in
            guard let self else { return }
            self.onBubble?(inside ? PinBubbleModel(title: "拖动", shortcut: "拖动",
                                                   usage: "按住这里把钉图挪走，靠近边缘会自动吸附") : nil,
                            self.grip.frame)
        }
        addSubview(grip)

        typealias Item = (symbol: String, title: String, shortcut: String, usage: String, sel: Selector)
        let items: [Item] = [
            // 1Capture 的 sc_pin_annotate 是一支画波浪线的笔，scribble 最接近
            ("scribble", "标注", "A", "在这张图上画标注，会打开编辑器", #selector(annotateTapped)),
            ("doc.on.doc", "拷贝", "C", "把这张图复制到剪贴板", #selector(copyTapped)),
            ("ellipsis", "更多", "M", "缩放、旋转、边框、隐藏全部", #selector(moreTapped)),
        ]
        for item in items {
            let button = PinIconButton()
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            button.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?
                .withSymbolConfiguration(config)
            button.contentTintColor = NSColor(white: 0.16, alpha: 0.92)
            button.target = self
            button.action = item.sel
            // 系统 tooltip 延迟 1.5s，会和自绘气泡打架——留空，说明交给气泡
            button.toolTip = ""
            button.setAccessibilityLabel(item.title)
            button.onHoverChange = { [weak self, weak button] inside in
                guard let self, let button else { return }
                if inside {
                    self.onBubble?(PinBubbleModel(title: item.title,
                                                  shortcut: item.shortcut,
                                                  usage: item.usage),
                                   button.frame)
                } else {
                    self.onBubble?(nil, .zero)
                }
            }
            addSubview(button)
            iconButtons.append(button)
        }

        zoomButton.isBordered = false
        zoomButton.bezelStyle = .regularSquare
        zoomButton.alignment = .center
        zoomButton.target = self
        zoomButton.action = #selector(zoomTapped)
        zoomButton.toolTip = ""
        zoomButton.onHoverChange = { [weak self] inside in
            guard let self else { return }
            let model = PinBubbleModel(title: "缩放",
                                       shortcut: "0",
                                       usage: "当前 \(self.currentPercent)%，点击回到原始大小")
            self.onBubble?(inside ? model : nil, self.zoomButton.frame)
        }
        zoomButton.attributedTitle = Self.zoomTitle(100)
        addSubview(zoomButton)
    }

    private static func zoomTitle(_ percent: Int) -> NSAttributedString {
        NSAttributedString(string: "\(percent)%",
                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                        .foregroundColor: NSColor(white: 0.28, alpha: 1)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.barWidth, height: Metrics.height) }
    override var fittingSize: NSSize { NSSize(width: Self.barWidth, height: Metrics.height) }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = Metrics.hPad
        grip.frame = NSRect(x: x, y: (h - 20) / 2, width: Metrics.gripWidth, height: 20)
        x += Metrics.gripWidth + Metrics.gapAfterGrip
        for button in iconButtons {
            button.frame = NSRect(x: x, y: (h - Metrics.button) / 2,
                                  width: Metrics.button, height: Metrics.button)
            x += Metrics.button
        }
        x += Metrics.gapBeforeZoom
        zoomButton.frame = NSRect(x: x, y: (h - 22) / 2,
                                  width: Metrics.zoomWidth, height: 22)
        layer?.cornerRadius = h / 2
        layer?.cornerCurve = .continuous
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r - 0.5, yRadius: r - 0.5)
        // 浅色胶囊：深色截图上靠底色分辨，浅色截图上靠 1px 暗描边 + 投影分辨
        NSColor(white: 1.0, alpha: 0.92).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.10).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    func updateZoom(percent: Int) {
        currentPercent = percent
        zoomButton.attributedTitle = Self.zoomTitle(percent)
    }

    /// 排障：按名字取某个控件的「气泡内容 + 位置（本视图坐标）」
    func probeBubble(_ name: String) -> (PinBubbleModel, NSRect)? {
        switch name {
        case "grip":
            return (PinBubbleModel(title: "拖动", shortcut: "拖动",
                                   usage: "按住这里把钉图挪走，靠近边缘会自动吸附"), grip.frame)
        case "annotate":
            return (PinBubbleModel(title: "标注", shortcut: "A",
                                   usage: "在这张图上画标注，会打开编辑器"), iconButtons[0].frame)
        case "copy":
            return (PinBubbleModel(title: "拷贝", shortcut: "C",
                                   usage: "把这张图复制到剪贴板"), iconButtons[1].frame)
        case "more":
            return (PinBubbleModel(title: "更多", shortcut: "M",
                                   usage: "缩放、旋转、边框、隐藏全部"), iconButtons[2].frame)
        case "zoom":
            return (PinBubbleModel(title: "缩放", shortcut: "0",
                                   usage: "当前 \(currentPercent)%，点击回到原始大小"), zoomButton.frame)
        default:
            return nil
        }
    }

    @objc private func annotateTapped() { onAnnotate?() }
    @objc private func copyTapped() { onCopy?() }
    @objc private func moreTapped() { onMore?() }
    @objc private func zoomTapped() { onResetZoom?() }
}

/// 文字按钮（缩放百分比），带悬停回调
final class PinTextButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        onHoverChange?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor(white: 0, alpha: 0.075).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                         xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 左上角关闭按钮（对应 SnipPinWindowController.CloseButton）
final class PinCloseButton: NSView {
    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var hovering = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = ""
        setAccessibilityLabel("关闭")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = hoverTracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        onHoverChange?(false)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let rect = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let circle = NSBezierPath(ovalIn: rect)
        let fill = hovering ? NSColor.systemRed.withAlphaComponent(0.94)
                            : NSColor(white: 0.06, alpha: 0.62)
        fill.setFill()
        circle.fill()
        // 浅色发丝环：深色截图上全靠这圈把按钮从背景里拎出来；
        // 浅色截图上则是深底本身在起作用，两种底都看得见。
        NSColor(white: 1, alpha: hovering ? 0 : 0.38).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        NSColor(white: 1, alpha: 0.95).setStroke()
        let c = rect.insetBy(dx: d * 0.31, dy: d * 0.31)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: c.minX, y: c.minY))
        cross.line(to: NSPoint(x: c.maxX, y: c.maxY))
        cross.move(to: NSPoint(x: c.maxX, y: c.minY))
        cross.line(to: NSPoint(x: c.minX, y: c.maxY))
        cross.lineWidth = 1.7
        cross.lineCapStyle = .round
        cross.stroke()
    }
}

// MARK: - 缩放 HUD

/// 缩放 HUD：56×28 居中黑底白字，只在缩放瞬间出现（工具条隐藏时也能看到数值）
final class PinnedScreenshotScaleHUD: NSView {

    private static let hudFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let hudAttrs: [NSAttributedString.Key: Any] = [
        .font: hudFont,
        .foregroundColor: NSColor.white,
    ]

    private var percentText: String = "100%"

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 28))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func update(percent: Int) {
        percentText = "\(percent)%"
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 56, height: 28) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(white: 0, alpha: 0.72).setFill()
        path.fill()
        let attrs = Self.hudAttrs
        let size = (percentText as NSString).size(withAttributes: attrs)
        (percentText as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                   y: (bounds.height - size.height) / 2),
                                       withAttributes: attrs)
    }
}

// MARK: - 钉图内容视图

/// 钉图交互视图：
/// - 悬停显示「底边居中控制条 + 左上关闭」，静止 2.4s 淡出
/// - 主体拖动移动窗口（可吸附屏幕边缘 / 其它钉图），八向手柄调尺寸
/// - 滚轮 / 捏合以光标为锚点缩放，双击复位 100%
/// - 右键「更多」：缩放 / 不透明度 / 旋转与翻转 / 圆角 / 阴影 / 边框 / 隐藏全部
final class PinnedScreenshotContentView: NSView {

    private enum HitZone { case body, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }

    static let resizeBand: CGFloat = 10.0
    static let minWindowWidth: CGFloat = 50.0
    static let smallModeWidthThreshold: CGFloat = 200.0
    static let smallModeHeightThreshold: CGFloat = 60.0
    static let scalePresets: [Int] = [200, 150, 100, 50]
    static let opacityPresets: [Int] = [100, 90, 80, 70, 50, 30]
    static let preciseScrollDivisor: CGFloat = 3.5
    static let regularScrollStep: CGFloat = 12.0

    let image: CGImage
    /// 未旋转时的 100% 基准尺寸
    private let baseSize: NSSize
    private var currentScale: CGFloat = 1.0

    /// 旋转 90° 的次数（0–3）与翻转标记
    private var rotationQuarter = 0
    private var flipH = false
    private var flipV = false

    /// auto 描边的取样结果（按图缓存一次）
    private let autoBorderColor: NSColor
    /// 这一张钉图自己的外观（v263，见 PinAppearance）
    var pinAppearance: PinAppearance

    var onClose: (() -> Void)?

    private var dragStartWindowFrame: NSRect?
    private var dragStartMouse: NSPoint?
    private var activeZone: HitZone?

    // MARK: 控件

    private let toolbar = PinToolbarView()
    private let closeButton = PinCloseButton()
    private let scaleHUD = PinnedScreenshotScaleHUD()
    /// 统一气泡 + 自绘列表（和标注竖栏同一套观感）
    private let bubblePanel = PinBubblePanel()
    private let menuPanel = PinMenuPanel()
    private var hudHideTimer: Timer?
    private var chromeHideTimer: Timer?
    private var chromeVisible = false
    private var toolbarHovered = false

    init(image: CGImage, frame frameRect: NSRect, appearance: PinAppearance = .current) {
        self.image = image
        self.baseSize = frameRect.size
        self.pinAppearance = appearance
        self.autoBorderColor = PinStyle.sampledBorderColor(for: image)
        super.init(frame: frameRect)

        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)

        toolbar.alphaValue = 0
        toolbar.isHidden = true
        toolbar.onAnnotate = { [weak self] in self?.annotateClicked() }
        toolbar.onCopy = { [weak self] in self?.copyClicked() }
        toolbar.onMore = { [weak self] in self?.showMoreMenuFromToolbar() }
        toolbar.onResetZoom = { [weak self] in self?.setScale(1.0) }
        toolbar.onGripDown = { [weak self] event in self?.beginWindowDrag(event) }
        toolbar.onGripDrag = { [weak self] event in self?.continueWindowDrag(event) }
        toolbar.onHoverChange = { [weak self] inside in self?.toolbarHovered = inside }
        // 按钮的 frame 是工具条内部坐标，先换算到内容视图再交给气泡定位
        toolbar.onBubble = { [weak self] model, rect in
            guard let self else { return }
            self.showBubble(model, from: self.toolbar.convert(rect, to: self))
        }
        addSubview(toolbar)

        closeButton.alphaValue = 0
        closeButton.isHidden = true
        closeButton.onClick = { [weak self] in self?.closeClicked() }
        closeButton.onHoverChange = { [weak self] inside in
            guard let self else { return }
            let model = PinBubbleModel(title: "关闭", shortcut: "Esc",
                                       usage: "把这张钉图从屏幕上移除")
            self.showBubble(inside ? model : nil, from: self.closeButton.frame)
        }
        addSubview(closeButton)

        scaleHUD.isHidden = true
        addSubview(scaleHUD)

        menuPanel.onPick = { [weak self] id in self?.handleMenuPick(id) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isSmallMode: Bool {
        bounds.width < Self.smallModeWidthThreshold || bounds.height < Self.smallModeHeightThreshold
    }

    /// 当前朝向下的 100% 尺寸
    private var displayedBaseSize: NSSize {
        rotationQuarter % 2 == 1
            ? NSSize(width: baseSize.height, height: baseSize.width)
            : baseSize
    }

    private var displayedAspect: CGFloat {
        let s = displayedBaseSize
        return max(s.width / max(s.height, 1), 0.0001)
    }

    // MARK: 绘制

    private var borderColor: NSColor {
        switch pinAppearance.borderColorToken {
        case "white":  return NSColor(white: 1, alpha: 0.86)
        case "black":  return NSColor(white: 0, alpha: 0.55)
        case "accent": return NSColor.controlAccentColor.withAlphaComponent(0.95)
        default:       return autoBorderColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let radius = CGFloat(pinAppearance.cornerRadius)
        let borderWidth = CGFloat(pinAppearance.borderWidth)
        let outer = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 1. 图像（裁进圆角；按旋转/翻转绘制）
        ctx.saveGState()
        ctx.addPath(outer)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        if rotationQuarter != 0 { ctx.rotate(by: CGFloat(rotationQuarter) * .pi / 2) }
        if flipH || flipV { ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1) }
        let swapped = rotationQuarter % 2 == 1
        let drawW = swapped ? bounds.height : bounds.width
        let drawH = swapped ? bounds.width : bounds.height
        ctx.setAlpha(CGFloat(pinAppearance.opacity))
        ctx.draw(image, in: CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH))
        ctx.setAlpha(1)
        ctx.restoreGState()

        // 2. 描边（内缩半个线宽，否则外半边会被窗口边界裁掉）
        if borderWidth > 0 {
            let inset = borderWidth / 2
            let rect = bounds.insetBy(dx: inset, dy: inset)
            let inner = CGPath(roundedRect: rect,
                               cornerWidth: max(0, radius - inset),
                               cornerHeight: max(0, radius - inset),
                               transform: nil)
            ctx.addPath(inner)
            ctx.setLineWidth(borderWidth)
            ctx.setStrokeColor(borderColor.cgColor)
            ctx.strokePath()
        }
    }

    override func layout() {
        super.layout()
        layoutChrome()
        repositionHUD()
        if isSmallMode {
            closeButton.alphaValue = 1
            closeButton.isHidden = false
        }
    }

    // MARK: 控制条几何

    private func layoutChrome() {
        if isSmallMode {
            toolbar.isHidden = true
            closeButton.isHidden = false
            closeButton.frame = NSRect(x: bounds.width - 10 - 22,
                                       y: bounds.height - 10 - 22,
                                       width: 22, height: 22)
            return
        }
        let size = NSSize(width: PinToolbarView.barWidth, height: PinToolbarView.Metrics.height)
        toolbar.frame = NSRect(x: (bounds.width - size.width) / 2, y: 10,
                               width: size.width, height: size.height)
        closeButton.frame = NSRect(x: 10, y: bounds.height - 10 - 22, width: 22, height: 22)
    }

    // MARK: 控制条显隐

    private func showChrome() {
        guard !isSmallMode else { return }
        if !chromeVisible {
            chromeVisible = true
            layoutChrome()
            toolbar.isHidden = false
            closeButton.isHidden = false
            toolbar.alphaValue = 0
            closeButton.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toolbar.animator().alphaValue = 1
                closeButton.animator().alphaValue = 1
            }
        }
        scheduleChromeHide()
    }

    private func hideChrome() {
        guard chromeVisible else { return }
        chromeVisible = false
        bubblePanel.hide()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            toolbar.animator().alphaValue = 0
            closeButton.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.chromeVisible else { return }
            self.toolbar.isHidden = true
            self.closeButton.isHidden = true
        })
    }

    /// 静止 N 秒后隐藏；鼠标停在控制条上时续命。N = 0 表示不自动收起。
    private func scheduleChromeHide() {
        chromeHideTimer?.invalidate()
        let interval = pinAppearance.chromeAutoHide
        guard interval > 0 else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.toolbarHovered { self.scheduleChromeHide(); return }
            let p = self.convert(NSEvent.mouseLocation, from: nil)
            if self.toolbar.frame.contains(p) || self.closeButton.frame.contains(p) {
                self.scheduleChromeHide()
                return
            }
            self.hideChrome()
        }
        chromeHideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: HUD

    private func repositionHUD() {
        scaleHUD.frame = NSRect(x: (bounds.width - 56) / 2,
                                y: (bounds.height - 28) / 2,
                                width: 56, height: 28)
    }

    private func showHUD() {
        repositionHUD()
        scaleHUD.update(percent: Int((currentScale * 100).rounded()))
        scaleHUD.isHidden = false
        hudHideTimer?.invalidate()
        hudHideTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.scaleHUD.isHidden = true
        }
    }

    // MARK: 光标

    private static let diagonalDownCursor: NSCursor = makeCursor("⤢")
    private static let diagonalUpCursor: NSCursor = makeCursor("⤡")

    private static func makeCursor(_ glyph: String) -> NSCursor {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16)]
            let s = (glyph as NSString).size(withAttributes: attrs)
            (glyph as NSString).draw(at: NSPoint(x: (rect.width - s.width) / 2,
                                                 y: (rect.height - s.height) / 2),
                                     withAttributes: attrs)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }

    private func updateCursor(for event: NSEvent) {
        switch hitZone(at: convert(event.locationInWindow, from: nil)) {
        case .left, .right:               NSCursor.resizeLeftRight.set()
        case .top, .bottom:               NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight:      Self.diagonalDownCursor.set()
        case .topRight, .bottomLeft:      Self.diagonalUpCursor.set()
        case .body:                       NSCursor.arrow.set()
        }
    }

    private func hitZone(at point: NSPoint) -> HitZone {
        let band = Self.resizeBand
        let nearLeft = point.x <= band, nearRight = point.x >= bounds.width - band
        let nearBottom = point.y <= band, nearTop = point.y >= bounds.height - band
        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, _, true):    return .topLeft
        case (_, true, _, true):    return .topRight
        case (true, _, true, _):    return .bottomLeft
        case (_, true, true, _):    return .bottomRight
        case (true, _, _, _):       return .left
        case (_, true, _, _):       return .right
        case (_, _, true, _):       return .bottom
        case (_, _, _, true):       return .top
        default:                    return .body
        }
    }

    // MARK: 键盘

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 气泡里标了快捷键，这里必须真的能用，否则徽章就是骗人的
        switch event.keyCode {
        case 53, 51, 117:   // Esc / Delete / Forward Delete
            closeClicked()
            return
        default:
            break
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch chars {
        case "a":
            annotateClicked()
        case "c":
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)   // ⌘C 交给系统常规拷贝
            } else {
                copyClicked()
            }
        case "m":
            showMoreMenuFromToolbar()
        case "0":
            setScale(1.0)
        case "=", "+":
            applyZoom(percentDelta: 12, anchor: NSEvent.mouseLocation)
            showHUD()
        case "-", "_":
            applyZoom(percentDelta: -12, anchor: NSEvent.mouseLocation)
            showHUD()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: 悬停

    override func mouseEntered(with event: NSEvent) { showChrome() }
    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
        showChrome()
    }
    override func mouseExited(with event: NSEvent) {
        let p = convert(NSEvent.mouseLocation, from: nil)
        // 移到控制条上不算离开
        if toolbar.frame.contains(p) || closeButton.frame.contains(p) { return }
        bubblePanel.hide()
        hideChrome()
    }

    // MARK: 拖动 / 调尺寸

    override func mouseDown(with event: NSEvent) {
        guard !isSmallMode else { return }
        if event.clickCount == 2 {
            setScale(1.0)
            return
        }
        beginWindowDrag(event)
        activeZone = hitZone(at: convert(event.locationInWindow, from: nil))
        if activeZone != .body { NSCursor.closedHand.set() }
    }

    private func beginWindowDrag(_ event: NSEvent) {
        dragStartWindowFrame = window?.frame
        dragStartMouse = NSEvent.mouseLocation
        showChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        showChrome()
        continueWindowDrag(event)
    }

    private func continueWindowDrag(_ event: NSEvent) {
        guard let window,
              let frame0 = dragStartWindowFrame,
              let mouse0 = dragStartMouse else { return }
        let mouse1 = NSEvent.mouseLocation
        let dx = mouse1.x - mouse0.x
        let dy = mouse1.y - mouse0.y
        let zone = activeZone ?? .body
        var frame = frame0

        if zone == .body {
            frame.origin.x += dx
            frame.origin.y += dy
            if pinAppearance.magnet {
                frame.origin = magnetSnapped(origin: frame.origin,
                                             size: frame.size,
                                             window: window)
            }
        } else {
            if zone == .left || zone == .topLeft || zone == .bottomLeft {
                frame.origin.x += dx
                frame.size.width -= dx
            }
            if zone == .right || zone == .topRight || zone == .bottomRight {
                frame.size.width += dx
            }
            if zone == .top || zone == .topLeft || zone == .topRight {
                frame.size.height += dy
            }
            if zone == .bottom || zone == .bottomLeft || zone == .bottomRight {
                frame.origin.y += dy
                frame.size.height -= dy
            }
            if frame.width < Self.minWindowWidth {
                let diff = Self.minWindowWidth - frame.width
                if frame.origin.x != frame0.origin.x { frame.origin.x -= diff }
                frame.size.width = Self.minWindowWidth
            }
            if frame.height < Self.minWindowWidth {
                let diff = Self.minWindowWidth - frame.height
                if frame.origin.y != frame0.origin.y { frame.origin.y -= diff }
                frame.size.height = Self.minWindowWidth
            }
            currentScale = frame.width / max(displayedBaseSize.width, 1)
            toolbar.updateZoom(percent: Int((currentScale * 100).rounded()))
        }
        window.setFrame(frame, display: true)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStartWindowFrame = nil
        dragStartMouse = nil
        activeZone = nil
        scheduleChromeHide()
    }

    /// 吸附：屏幕四边 + 其它钉图的四边与中线对齐（阈值 8pt）
    private func magnetSnapped(origin: NSPoint, size: NSSize, window: NSWindow) -> NSPoint {
        let threshold: CGFloat = 8
        var x = origin.x, y = origin.y
        if let screen = window.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            if abs(x - v.minX) < threshold { x = v.minX }
            if abs((x + size.width) - v.maxX) < threshold { x = v.maxX - size.width }
            if abs(y - v.minY) < threshold { y = v.minY }
            if abs((y + size.height) - v.maxY) < threshold { y = v.maxY - size.height }
        }
        for other in PinnedScreenshotManager.shared.otherFrames(excluding: window) {
            if abs(x - other.minX) < threshold { x = other.minX }
            if abs((x + size.width) - other.maxX) < threshold { x = other.maxX - size.width }
            if abs(y - other.minY) < threshold { y = other.minY }
            if abs((y + size.height) - other.maxY) < threshold { y = other.maxY - size.height }
            if abs((y + size.height) - other.minY) < threshold { y = other.minY - size.height }
            if abs(y - other.maxY) < threshold { y = other.maxY }
        }
        return NSPoint(x: x, y: y)
    }

    // MARK: 缩放

    override func scrollWheel(with event: NSEvent) { zoomCore(with: event) }
    override func magnify(with event: NSEvent) { zoomCore(with: event, magnification: event.magnification) }

    private func zoomCore(with event: NSEvent, magnification: CGFloat? = nil) {
        guard let window else { return }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }

        var deltaPercent: CGFloat
        if let magnification {
            deltaPercent = magnification * 100
        } else if event.hasPreciseScrollingDeltas {
            deltaPercent = event.scrollingDeltaY / Self.preciseScrollDivisor
        } else {
            deltaPercent = event.scrollingDeltaY > 0 ? Self.regularScrollStep : -Self.regularScrollStep
        }
        deltaPercent = -deltaPercent
        applyZoom(percentDelta: deltaPercent, anchor: NSEvent.mouseLocation)
        showHUD()
        showChrome()
    }

    private func applyZoom(percentDelta: CGFloat, anchor: NSPoint) {
        guard let window else { return }
        let frame = window.frame
        let aspect = displayedAspect
        var width = max(Self.minWindowWidth, frame.width * (1.0 + percentDelta / 100.0))
        var height = width / aspect
        if height < Self.minWindowWidth {
            height = Self.minWindowWidth
            width = height * aspect
        }
        let fx = (anchor.x - frame.minX) / max(frame.width, 1)
        let fy = (anchor.y - frame.minY) / max(frame.height, 1)
        let origin = NSPoint(x: anchor.x - fx * width, y: anchor.y - fy * height)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        currentScale = width / max(displayedBaseSize.width, 1)
        toolbar.updateZoom(percent: Int((currentScale * 100).rounded()))
        needsDisplay = true
    }

    /// 按比例缩放（保持中心，受屏幕可见域钳制）
    private func setScale(_ scale: CGFloat) {
        guard let window else { return }
        let clamped = max(0.05, scale)
        let aspect = displayedAspect
        var width = max(Self.minWindowWidth, displayedBaseSize.width * clamped)
        var height = width / aspect
        if height < Self.minWindowWidth {
            height = Self.minWindowWidth
            width = height * aspect
        }
        let old = window.frame
        var frame = NSRect(x: old.midX - width / 2, y: old.midY - height / 2, width: width, height: height)
        if let screen = window.screen ?? NSScreen.main {
            let v = screen.visibleFrame
            frame.origin.x = min(max(v.minX, frame.origin.x), v.maxX - width)
            frame.origin.y = min(max(v.minY, frame.origin.y), v.maxY - height)
        }
        window.setFrame(frame, display: true)
        currentScale = width / max(displayedBaseSize.width, 1)
        toolbar.updateZoom(percent: Int((currentScale * 100).rounded()))
        needsDisplay = true
        showHUD()
    }

    // MARK: 旋转 / 翻转

    private func rotate(by direction: Int) {
        guard let window else { return }
        let old = window.frame
        rotationQuarter = (rotationQuarter + direction + 4) % 4
        // 90° / 270° 时宽高互换，窗口跟着换，否则图会被压扁
        if direction % 2 != 0 {
            let size = NSSize(width: old.height, height: old.width)
            let frame = NSRect(x: old.midX - size.width / 2,
                               y: old.midY - size.height / 2,
                               width: size.width, height: size.height)
            window.setFrame(frame, display: true)
            currentScale = size.width / max(displayedBaseSize.width, 1)
            toolbar.updateZoom(percent: Int((currentScale * 100).rounded()))
        }
        needsDisplay = true
    }

    // MARK: 气泡 / 弹出列表（统一组件见 PinChrome.swift）

    /// 弹出某个控件的气泡（rect 为本视图坐标）
    private func showBubble(_ model: PinBubbleModel?, from rectInView: NSRect) {
        guard let model, let window else {
            bubblePanel.hide()
            return
        }
        let onScreen = window.convertToScreen(convert(rectInView, to: nil))
        bubblePanel.show(model, above: onScreen)
        Log.debug("Pin", "气泡锚点 \(Int(onScreen.midX)),\(Int(onScreen.maxY)) → 面板 \(Int(bubblePanel.frame.minX)),\(Int(bubblePanel.frame.minY))")
    }

    private func anchorInScreen(_ rectInView: NSRect) -> NSRect {
        guard let window else { return rectInView }
        return window.convertToScreen(convert(rectInView, to: nil))
    }

    private func showMoreMenuFromToolbar() {
        bubblePanel.hide()
        menuPanel.ownerWindow = window
        menuPanel.present(entries: menuEntries(),
                          above: anchorInScreen(toolbar.moreAnchor))
    }

    override func rightMouseDown(with event: NSEvent) {
        bubblePanel.hide()
        let p = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        menuPanel.ownerWindow = window
        menuPanel.present(entries: menuEntries(),
                          above: NSRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2))
    }

    private func menuEntries() -> [PinMenuEntry] {
        let percent = Int((currentScale * 100).rounded())
        let zoom = PinMenuEntry.submenu(
            id: "zoom", title: "缩放", symbol: "arrow.up.left.and.arrow.down.right",
            detail: "\(percent)%",
            children: Self.scalePresets.map {
                PinMenuEntry.choice(id: "zoom.\($0)", title: "\($0)%",
                                    symbol: "", selected: percent == $0)
            } + [.action(id: "zoom.original", title: "切换原始大小", symbol: "1.square", detail: nil)])

        let alphaPercent = Int((pinAppearance.opacity * 100).rounded())
        let alpha = PinMenuEntry.submenu(
            id: "alpha", title: "不透明度", symbol: "circle.lefthalf.filled",
            detail: "\(alphaPercent)%",
            children: Self.opacityPresets.map {
                PinMenuEntry.choice(id: "alpha.\($0)", title: "\($0)%",
                                    symbol: "", selected: alphaPercent == $0)
            })

        let orientation = PinMenuEntry.submenu(
            id: "orientation", title: "旋转与翻转", symbol: "rotate.right", detail: nil,
            children: [
                .action(id: "rotate.left", title: "向左旋转", symbol: "rotate.left", detail: nil),
                .action(id: "rotate.right", title: "向右旋转", symbol: "rotate.right", detail: nil),
                .toggle(id: "flip.h", title: "水平翻转", symbol: "arrow.left.and.right", on: flipH),
                .toggle(id: "flip.v", title: "垂直翻转", symbol: "arrow.up.and.down", on: flipV),
                .action(id: "orientation.reset", title: "重置朝向", symbol: "arrow.counterclockwise", detail: nil),
            ])

        let borderDetail = pinAppearance.borderWidth == 0
            ? "无" : String(format: "%.1f pt", pinAppearance.borderWidth)
        let border = PinMenuEntry.submenu(
            id: "border", title: "边框", symbol: "square.dashed", detail: borderDetail,
            children: [0.0, 1.0, 1.5, 2.0, 3.0, 5.0].map {
                PinMenuEntry.choice(id: "border.\($0)",
                                    title: $0 == 0 ? "无" : String(format: "%.1f pt", $0),
                                    symbol: "",
                                    selected: abs(pinAppearance.borderWidth - $0) < 0.01)
            } + [
                .choice(id: "bordercolor.auto", title: "自动（按底色反色）", symbol: "",
                        selected: pinAppearance.borderColorToken == "auto"),
                .choice(id: "bordercolor.white", title: "白色", symbol: "",
                        selected: pinAppearance.borderColorToken == "white"),
                .choice(id: "bordercolor.black", title: "黑色", symbol: "",
                        selected: pinAppearance.borderColorToken == "black"),
                .choice(id: "bordercolor.accent", title: "强调色", symbol: "",
                        selected: pinAppearance.borderColorToken == "accent"),
            ])

        return [
            zoom,
            alpha,
            orientation,
            .toggle(id: "corner", title: "窗口圆角", symbol: "rectangle.roundedtop",
                    on: pinAppearance.cornerRadius > 0),
            .toggle(id: "shadow", title: "窗口阴影", symbol: "square.stack.3d.down.right",
                    on: pinAppearance.shadow),
            .toggle(id: "magnet", title: "自动吸附", symbol: "square.grid.2x2",
                    on: pinAppearance.magnet),
            border,
            .action(id: "hideall",
                    title: PinnedScreenshotManager.shared.hasHidden ? "显示全部" : "隐藏全部",
                    symbol: "eye.slash", detail: nil),
            .action(id: "close", title: "关闭", symbol: "xmark", detail: nil),
        ]
    }

    private func handleMenuPick(_ id: String) {
        switch id {
        case "zoom.original":
            setScale(1.0)
        case "rotate.left":
            rotate(by: -1)
        case "rotate.right":
            rotate(by: 1)
        case "flip.h":
            flipH.toggle()
            needsDisplay = true
        case "flip.v":
            flipV.toggle()
            needsDisplay = true
        case "orientation.reset":
            resetOrientation()
        case "corner":
            pinAppearance.cornerRadius = pinAppearance.cornerRadius > 0 ? 0 : 10
            PinStyle.cornerRadius = pinAppearance.cornerRadius
            needsDisplay = true
        case "shadow":
            pinAppearance.shadow.toggle()
            PinStyle.shadow = pinAppearance.shadow
            window?.hasShadow = pinAppearance.shadow
        case "magnet":
            pinAppearance.magnet.toggle()
            PinStyle.magnet = pinAppearance.magnet
        case "hideall":
            if PinnedScreenshotManager.shared.hasHidden {
                PinnedScreenshotManager.shared.showAll()
            } else {
                PinnedScreenshotManager.shared.hideAll()
            }
        case "close":
            closeClicked()
        default:
            if id.hasPrefix("zoom."), let n = Int(id.dropFirst(5)) {
                setScale(CGFloat(n) / 100)
            } else if id.hasPrefix("alpha."), let n = Int(id.dropFirst(6)) {
                pinAppearance.opacity = Double(n) / 100
                PinStyle.opacity = pinAppearance.opacity
                needsDisplay = true
            } else if id.hasPrefix("border."), let d = Double(id.dropFirst(7)) {
                pinAppearance.borderWidth = d
                PinStyle.borderWidth = d
                needsDisplay = true
            } else if id.hasPrefix("bordercolor.") {
                pinAppearance.borderColorToken = String(id.dropFirst("bordercolor.".count))
                PinStyle.borderColorToken = pinAppearance.borderColorToken
                needsDisplay = true
            }
        }
    }

    /// 朝向复位：把窗口换回未旋转的宽高（保持当前缩放与中心）
    private func resetOrientation() {
        guard rotationQuarter != 0 || flipH || flipV else { return }
        rotationQuarter = 0
        flipH = false
        flipV = false
        if let window {
            let old = window.frame
            let width = displayedBaseSize.width * currentScale
            let height = width / displayedAspect
            let frame = NSRect(x: old.midX - width / 2, y: old.midY - height / 2,
                               width: width, height: height)
            window.setFrame(frame, display: true)
        }
        needsDisplay = true
    }
    // MARK: 排障

    /// 排障入口：无鼠标模拟权限时直接展示某个气泡 / 列表，验收位置与样式
    func probe(_ name: String) {
        if name == "menu" {
            showMoreMenuFromToolbar()
            return
        }
        showChrome()
        if name == "close" {
            let model = PinBubbleModel(title: "关闭", shortcut: "Esc",
                                       usage: "把这张钉图从屏幕上移除")
            showBubble(model, from: closeButton.frame)
            return
        }
        guard let (model, rect) = toolbar.probeBubble(name) else { return }
        showBubble(model, from: toolbar.convert(rect, to: self))
    }

    // MARK: 动作

    /// 带旋转/翻转的成图（复制 / 保存 / 送编辑都用它，不然钉的是转过的、拷出去还是原图）
    func flattenedImage() -> CGImage {
        guard rotationQuarter != 0 || flipH || flipV else { return image }
        let swapped = rotationQuarter % 2 == 1
        let w = swapped ? image.height : image.width
        let h = swapped ? image.width : image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: CGFloat(rotationQuarter) * .pi / 2)
        ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2,
                                   y: -CGFloat(image.height) / 2,
                                   width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
        return ctx.makeImage() ?? image
    }

    @objc func annotateClicked() {
        hideChrome()
        AnnotationEditorController.shared.open(image: flattenedImage())
    }

    @objc func copyClicked() {
        hideChrome()
        let flat = flattenedImage()
        guard ScreenshotManager.shared.copyToPasteboard(flat) else { return }
        Toast.show("已拷贝钉图", icon: "doc.on.doc.fill")
    }

    @objc func closeClicked() {
        bubblePanel.hide()
        menuPanel.dismiss()
        window?.close()
    }
}

// MARK: - 钉图窗口

/// 钉图窗：浮动层级 3、无标题栏、随内容 alpha 生成投影
final class PinnedScreenshotWindow: NSPanel {

    init(image: CGImage, origin: NSPoint, appearance: PinAppearance = .current) {
        let size = Self.initialSize(for: image)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = NSWindow.Level(3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = appearance.shadow
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false

        let view = PinnedScreenshotContentView(image: image,
                                               frame: NSRect(origin: .zero, size: size),
                                               appearance: appearance)
        view.onClose = { [weak self] in self?.close() }
        contentView = view
        // v233：初始位置可能被调用方给到屏幕外（实测 y=160 时窗底落到屏幕下方，
        // 工具条整条看不见）。这里统一夹进可见区域，保证钉上去第一眼就完整可见。
        var frame = NSRect(origin: origin, size: size)
        if let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            frame.origin.x = min(max(v.minX + 12, frame.origin.x), v.maxX - size.width - 12)
            frame.origin.y = min(max(v.minY + 12, frame.origin.y), v.maxY - size.height - 12)
        }
        setFrame(frame, display: true)
        makeKeyAndOrderFront(nil)
    }

    /// 初始尺寸：等比放进屏幕可见域，最大 420×360，最小 60
    private static func initialSize(for image: CGImage) -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxW = min(visible.width * 0.58, 420)
        let maxH = min(visible.height * 0.74, 360)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return NSSize(width: 60, height: 60) }
        let scale = min(1, maxW / w, maxH / h)
        return NSSize(width: max(w * scale, 60), height: max(h * scale, 60))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        if let view = contentView { makeFirstResponder(view) }
        PinnedScreenshotManager.shared.windowDidBecomeKey(self)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        super.constrainFrameRect(frameRect, to: screen)
    }
}

// MARK: - 钉图管理器

/// 多钉图管理：持有窗口数组 + Esc/Delete 键监听 + 全部隐藏/恢复
public final class PinnedScreenshotManager: NSObject {

    public static let shared = PinnedScreenshotManager()

    private var windows: [PinnedScreenshotWindow] = []
    private var monitor: Any?
    private weak var activeWindow: PinnedScreenshotWindow?
    private(set) var hasHidden = false
    /// 最近一次钉的图（供「上次钉图」用）
    public private(set) var lastImage: CGImage?

    private override init() {
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:            // Esc
                // v274：旧版是 App 级监视器，任何窗口按 Esc 都 closeAll() 并吞掉事件：
                // 在标注编辑器 / OCR 结果窗按 Esc，钉图被无提示全删，编辑器反而关不掉。
                // 现在只在「当前 key window 就是一张钉图」时处理，且只关当前这一张。
                guard let key = NSApp.keyWindow,
                      self?.windows.contains(where: { $0 === key }) == true else {
                    return event
                }
                self?.closeActive()
                return nil
            case 51, 117:       // Delete / Forward Delete
                guard let key = NSApp.keyWindow,
                      self?.windows.contains(where: { $0 === key }) == true else {
                    return event
                }
                self?.closeActive()
                return nil
            default:
                return event
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: 钉图入口

    /// 把一张图钉到屏幕（错位平铺避免完全重叠）
    ///
    /// - Parameter appearance: 这一张的外观形态；默认沿用全局设置。
    ///   动作条里的「钉住 · 经典/无边框/卡片/强调」就是靠它做到「一个形态一个选项」。
    @discardableResult
    public func show(image: CGImage, at origin: NSPoint? = nil,
                     appearance: PinAppearance = .current) -> Bool {
        let offset = CGFloat(windows.count % 6) * 24
        let position = origin ?? NSPoint(x: 160 + offset, y: 160 + offset)
        let window = PinnedScreenshotWindow(image: image, origin: position, appearance: appearance)
        windows.append(window)
        lastImage = image
        hasHidden = false
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: window)
        return true
    }

    @discardableResult
    // MARK: 批量

    public func closeAll() {
        for window in windows { window.close() }
        windows.removeAll()
        hasHidden = false
    }

    public func hideAll() {
        for window in windows { window.orderOut(nil) }
        hasHidden = true
    }

    public func showAll() {
        for window in windows { window.orderFront(nil) }
        hasHidden = false
    }

    /// v264：重新钉住上一张（「全部隐藏」之后一键找回；不用回历史里翻）
    @discardableResult
    public func repinLast() -> Bool {
        guard let image = lastImage else { return false }
        return show(image: image)
    }

    /// 吸附用：其它钉图的 frame
    func otherFrames(excluding window: NSWindow) -> [NSRect] {
        windows.filter { $0 !== window }.map(\.frame)
    }

    /// 排障：对最后一张钉图展示指定气泡 / 列表（annotate / copy / more / zoom / close / grip / menu）
    public func probeLast(_ name: String) {
        guard let window = windows.last,
              let view = window.contentView as? PinnedScreenshotContentView else { return }
        view.probe(name)
    }

    private func closeActive() {
        guard let active = activeWindow else { return }
        active.close()
    }

    // MARK: 窗口事件

    func windowDidBecomeKey(_ window: PinnedScreenshotWindow) {
        guard window.contentView is PinnedScreenshotContentView else { return }
        activeWindow = window
    }

    @objc private func windowDidClose(_ note: Notification) {
        guard let window = note.object as? PinnedScreenshotWindow else { return }
        windows.removeAll { $0 === window }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
    }
}
