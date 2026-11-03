import AppKit
import CoreGraphics
import Foundation

// MARK: - 贴图本地化辅助

/// 贴图 UI 文案走 L10n（spec 16：键面用原作英文键，中文值由 Localizable.strings 提供；
/// 本工程 L10n 基建（specs/18）未落地前，NSLocalizedString 回退到英文键面）
private func pinL10n(_ key: String) -> String {
    NSLocalizedString(key, comment: "Frset pinned screenshot")
}

// MARK: - 缩放 HUD

/// 缩放 HUD（原作 PinnedScreenshotScaleHUD）：
/// intrinsicContentSize = 56×28（0x1002fe124）；hitTest = nil 穿透点击（0x1002fe11c）；
/// 字体 systemFont 12pt semibold（0x1002fe0ac）；黑底白字百分比文本。
final class PinnedScreenshotScaleHUD: NSView {

    /// v126（性能审计 F0426）：缓存 HUD 字体与属性字典，避免 draw 每帧重建
    private static let hudFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
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

    /// 点击穿透（0x1002fe11c）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath.continuousRoundedRect(bounds, radius: 8)
        NSColor(white: 0, alpha: 0.72).setFill()
        path.fill()
        // v126（性能审计 F0426）：复用静态缓存属性字典
        let attrs = Self.hudAttrs
        let size = (percentText as NSString).size(withAttributes: attrs)
        (percentText as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                                   y: (bounds.height - size.height) / 2),
                                       withAttributes: attrs)
    }
}

// MARK: - 小模式关闭按钮

/// 小尺寸模式下的关闭按钮（原作 PinnedScreenshotSmallCloseButton：自绘 + handleClick）
final class PinnedScreenshotSmallCloseButton: NSView {

    var handleClick: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 0.85))
        ctx.fillEllipse(in: bounds)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(1.6)
        ctx.addLines(between: [CGPoint(x: 5, y: 5), CGPoint(x: 13, y: 13)])
        ctx.move(to: CGPoint(x: 13, y: 5))
        ctx.addLine(to: CGPoint(x: 5, y: 13))
        ctx.strokePath()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { handleClick?() }

    /// 小模式下右键同样弹动作菜单（0x1002fda28）
    override func rightMouseDown(with event: NSEvent) {
        (superview as? PinnedScreenshotContentView)?.showActionsMenu(with: event)
    }
}

// MARK: - 小模式提示窗

/// 一次性提示窗（原作 PinnedScreenshotSmallModeTipWindow）：
/// 文案 "Right-click for more actions"（zh-Hans「右键查看更多操作」）；
/// 显示时写 UserDefaults 一次性标记 pinnedScreenshot.smallModeTipSeen_v2（0x1002f8db0）。
final class PinnedScreenshotSmallModeTipWindow: NSPanel {

    private var dismissTimer: Timer?

    init(near frame: NSRect, text: String) {
        let size = NSSize(width: 220, height: 40)
        // 贴图上方居中（精确几何原作未完全解出，spec 16 §6.10 ⬜）
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY + 8)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let tip = NSTextField(labelWithString: text)
        tip.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        tip.textColor = .white
        tip.alignment = .center
        tip.wantsLayer = true
        tip.layer?.backgroundColor = CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.85)
        tip.layer?.cornerRadius = 8
        tip.layer?.cornerCurve = .continuous   // v156: G2（曲率连续）圆角
        tip.frame = NSRect(origin: .zero, size: size)
        contentView = tip
    }

    func present(autoDismissAfter interval: TimeInterval = 4.0) {
        orderFront(nil)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    override func mouseDown(with event: NSEvent) { fadeOut() }

    /// 淡出并关闭（对应原作 dismiss 闭包 0x1002fc58c → 0x1002fbe28）
    private func fadeOut() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

// MARK: - 控制条宿主视图

/// 控制条宿主视图（原作 PinnedScreenshotControlsHostView：acceptsFirstMouse 返回 true）
final class PinnedScreenshotControlsHostView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
}

// MARK: - 控制条窗口

/// 控制条承载窗（原作 PinnedScreenshotControlsWindow：canBecomeKey/Main = true，0x1003024b4）。
/// 悬停贴图时显示，2.0s 单发定时器自动隐藏（0x1002fb394，fmov d0,#2.0，NSRunLoop.mainRunLoop + commonModes）；
/// 显示 = 取消旧 DispatchWorkItem + 世代计数递增 + 淡入（0x1002f83a4/0x1002f83cc）；
/// 隐藏 = NSAnimationContext 淡出 + setHidden + ignoresMouseEvents（0x1002fae6c/0x1002fb0c0）。
final class PinnedScreenshotControlsWindow: NSPanel {

    /// 控制条窗口尺寸（按钮布局按此宽度居中计算）
    static let defaultSize = NSSize(width: 320, height: 44)

    /// 自动隐藏间隔（2.0s，原作立即数）
    static let autoHideInterval: TimeInterval = 2.0

    /// 世代计数（防错序：显示路径递增，隐藏动画完成块比对，0x1002f83cc）
    private(set) var generation = 0
    private var hideTimer: Timer?
    private var pendingHide: DispatchWorkItem?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = PinnedScreenshotControlsHostView(frame: NSRect(origin: .zero, size: Self.defaultSize))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 显示（淡入 + 重置 2s 自动隐藏）
    func present(at frame: NSRect) {
        pendingHide?.cancel()
        pendingHide = nil
        generation += 1
        setFrameOrigin(frame.origin)
        ignoresMouseEvents = false
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
        scheduleAutoHide()
    }

    /// 隐藏（淡出后 setHidden + 穿透恢复）
    func dismiss(animated: Bool = true) {
        hideTimer?.invalidate()
        hideTimer = nil
        let generationAtSchedule = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == generationAtSchedule else { return }   // 世代比对防错序
            // v126（性能审计 F0436）：非动画路径跳过 NSAnimationContext，减少主线程开销
            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    self.animator().alphaValue = 0
                }, completionHandler: {
                    if self.generation == generationAtSchedule {
                        self.orderOut(nil)
                        self.ignoresMouseEvents = true
                    }
                })
            } else {
                self.alphaValue = 0
                self.orderOut(nil)
                self.ignoresMouseEvents = true
            }
        }
        pendingHide = work
        DispatchQueue.main.async(execute: work)
    }

    /// 2.0s 单发定时器，加入 RunLoop.main .commonModes（0x1002fb394）
    private func scheduleAutoHide() {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autoHideInterval, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

// MARK: - 贴图内容视图（核心交互）

/// 贴图内容视图（原作 PinnedScreenshotContentView，@objc 方法表 26 项的核心交互视图）：
/// - 悬停显示控制条 / 2s 自动隐藏（F2）
/// - 右键动作菜单：Zoom(200/150/100/50%)‖标注/提取文字/翻译/保存‖关闭（F3）
/// - 滚轮/捏合以光标为锚点缩放，HUD 56×28 居中显示（F4/F6）
/// - 四边+四角 ~10pt 手柄拖拽调尺寸，body 区拖动=移动窗口（F7）
/// - 小模式：宽<200pt 或 高<60pt；一次性提示（F8/F9）
final class PinnedScreenshotContentView: NSView {

    // MARK: 命中区（0–8 区号，0x1002f4b58）

    private enum HitZone { case body, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }

    /// 边缘手柄带宽（0x1002f4c04/0x1002f4c28，±10.0）
    static let resizeBand: CGFloat = 10.0
    /// 最小窗宽（0x1002f59ec，0x4049…=50.0）
    static let minWindowWidth: CGFloat = 50.0
    /// 小模式阈值：宽<200pt 或 高<60pt（0x1002fe584/0x1002fe598）
    static let smallModeWidthThreshold: CGFloat = 200.0
    static let smallModeHeightThreshold: CGFloat = 60.0
    /// 缩放档位（__DATA 0x100c6bf48：200,150,100,50）
    static let scalePresets: [Int] = [200, 150, 100, 50]
    /// 滚轮灵敏度：精确滚轮 3.5 / 普通滚轮 12.0（0x1002f57a0/0x1002f57a4）
    static let preciseScrollDivisor: CGFloat = 3.5
    static let regularScrollStep: CGFloat = 12.0

    // MARK: 状态

    let image: CGImage
    /// 初始（scale=1.0）基准尺寸
    private let baseSize: NSSize
    private var currentScale: CGFloat = 1.0
    var onClose: (() -> Void)?

    private var dragStartWindowFrame: NSRect?
    private var dragStartMouse: NSPoint?
    private var activeZone: HitZone?

    /// 控制条（懒建， addChildWindow 挂到贴图窗）
    private lazy var controlsWindow = PinnedScreenshotControlsWindow()
    private var controlsInstalled = false
    /// 缩放 HUD —— v83（2026-10-19 用户反馈「100% 一直飘着关不掉」）：
    /// 原实现用独立 NSPanel + addChildWindow(hudWindow)，2s 后只 orderOut；
    /// **childWindow 会在父窗每次 orderFront/成为 key 时被系统重新带出**，
    /// 于是贴图被点击/拖动后 HUD 复活并永久常驻（无新 timer 收尾）。
    /// 现改为内容视图内的子视图：随贴图绘制、随 2s 定时器隐藏，无窗口联动。
    private let scaleHUD = PinnedScreenshotScaleHUD()
    private var hudHideTimer: Timer?

    /// 小模式一次性提示调度（0x1002f8838）
    private var pendingTipWorkItem: DispatchWorkItem?
    private var isMenuPopped = false
    private var tipWindow: PinnedScreenshotSmallModeTipWindow?
    /// 小模式关闭按钮
    private let smallCloseButton = PinnedScreenshotSmallCloseButton()

    static let smallModeTipKey = "pinnedScreenshot.smallModeTipSeen_v2"   // 0x100b4c270

    // MARK: 初始化

    init(image: CGImage, frame frameRect: NSRect) {
        self.image = image
        self.baseSize = frameRect.size
        super.init(frame: frameRect)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        scaleHUD.isHidden = true
        addSubview(scaleHUD)
        smallCloseButton.isHidden = true
        smallCloseButton.handleClick = { [weak self] in self?.closeClicked() }
        addSubview(smallCloseButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { false }

    // MARK: 小模式

    /// 小模式谓词（0x1002fe4d4）：width < 200.0 || height < 60.0
    var isSmallMode: Bool {
        bounds.width < Self.smallModeWidthThreshold || bounds.height < Self.smallModeHeightThreshold
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let path = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    override func layout() {
        super.layout()
        // 小模式：控制条不可用，右上角关闭按钮可用（F8）
        let small = isSmallMode
        smallCloseButton.isHidden = !small
        if small {
            smallCloseButton.frame = NSRect(x: bounds.maxX - 22, y: bounds.maxY - 22, width: 18, height: 18)
            if controlsWindow.isVisible { controlsWindow.dismiss(animated: false) }
        }
        // 缩放 HUD 跟随贴图正中心（0x1002f961c）
        repositionHUD()
        // 一次性提示调度（0x1002f8838）
        scheduleSmallModeTipIfNeeded()
    }

    // MARK: HUD

    /// HUD 居中（内容视图子视图，56×28）
    private func repositionHUD() {
        scaleHUD.frame = NSRect(x: (bounds.width - 56) / 2,
                                y: (bounds.height - 28) / 2,
                                width: 56, height: 28)
    }

    /// 缩放时短暂显示 HUD（2.0s 后隐藏；子视图方案无窗口联动问题）
    private func showHUD() {
        repositionHUD()
        scaleHUD.update(percent: Int((currentScale * 100).rounded()))
        scaleHUD.isHidden = false
        hudHideTimer?.invalidate()
        hudHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.scaleHUD.isHidden = true
        }
    }

    // MARK: 控制条

    /// 控制条几何：贴图上方居中（按钮横排 28pt 宽 / 30pt 间距 / 起排 x≈85，0x1002f80b0）
    private func controlsFrame() -> NSRect {
        guard let window = window else { return .zero }
        let frame = window.frame
        let size = controlsWindow.frame.size
        return NSRect(x: frame.midX - size.width / 2,
                      y: frame.maxY + 6,
                      width: size.width,
                      height: size.height)
    }

    /// 显示控制条（显示路径 0x1002f8358：取消旧隐藏 + 世代计数 + 淡入）
    private func showControls() {
        guard !isSmallMode, let window = window else { return }   // 小模式控制条不可用
        if !controlsInstalled {
            window.addChildWindow(controlsWindow, ordered: .above)
            controlsWindow.level = window.level
            controlsInstalled = true
            installControlButtons()
        }
        controlsWindow.present(at: controlsFrame())
    }

    /// 控制条按钮：横排、28pt 宽、30pt 间距（0x1002f80d0 布局循环）。
    /// 原作图标资源名未探明（Int→NSImage(named:)，spec 16 §6.2 ⬜），重建用 SF Symbols。
    private func installControlButtons() {
        guard let host = controlsWindow.contentView else { return }
        let buttons: [(String, Selector)] = [
            ("pencil.tip.crop.circle", #selector(annotateClicked)),
            ("text.viewfinder", #selector(ocrClicked)),
            ("globe", #selector(translateClicked)),
            ("square.and.arrow.down", #selector(saveClicked)),
            ("xmark.circle", #selector(closeClicked)),
        ]
        // v83（2026-10-19 用户反馈「点叉号无法关闭」根因）：
        // 原布局 start=85、index×58 → 第 5 个（关闭）按钮 x=317、右缘 345，
        // **超出 320pt 窗口宽被裁掉**，用户看不到也点不到关闭钮。
        // 改为整组水平居中：5×28 + 4×30 = 260pt，起点 (320-260)/2 = 30。
        let width: CGFloat = 28, spacing: CGFloat = 30
        let totalWidth = CGFloat(buttons.count) * width + CGFloat(buttons.count - 1) * spacing
        let start = (PinnedScreenshotControlsWindow.defaultSize.width - totalWidth) / 2
        for (index, item) in buttons.enumerated() {
            let button = NSButton(frame: NSRect(x: start + CGFloat(index) * (width + spacing),
                                                y: 8, width: width, height: width))
            button.isBordered = false
            button.image = NSImage(systemSymbolName: item.0, accessibilityDescription: nil) ?? NSImage()
            button.imagePosition = .imageOnly
            button.target = self
            button.action = item.1
            host.addSubview(button)
        }
    }

    // MARK: 悬停（F2：move/drag/进入均触发显示，2s 自动隐藏）

    override func mouseEntered(with event: NSEvent) { showControls() }
    override func mouseExited(with event: NSEvent) {
        guard controlsInstalled else { return }
        // 防抖：NSEvent.mouseLocation 与控制条 frame 外扩 1pt 的包含测试（0x1002fabc4）
        let mouse = NSEvent.mouseLocation
        let inflated = controlsWindow.frame.insetBy(dx: -1, dy: -1)
        if controlsWindow.alphaValue > 0.01, inflated.contains(mouse) {
            showControls()
        } else {
            controlsWindow.dismiss()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
        showControls()
    }
    override func mouseDragged(with event: NSEvent) {
        showControls()
        handleDrag(event)
    }

    // MARK: 光标（边缘手柄光标，0x1002f50d8/0x1002f5138 + 两枚自定义对角光标）

    private static let diagonalDownCursor: NSCursor = makeCursor("⤢")
    private static let diagonalUpCursor: NSCursor = makeCursor("⤡")

    private static func makeCursor(_ glyph: String) -> NSCursor {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16)]
            let s = (glyph as NSString).size(withAttributes: attrs)
            (glyph as NSString).draw(at: NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2),
                                     withAttributes: attrs)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }

    private func updateCursor(for event: NSEvent) {
        let zone = hitZone(at: convert(event.locationInWindow, from: nil))
        switch zone {
        case .left, .right:               NSCursor.resizeLeftRight.set()
        case .top, .bottom:               NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight:      Self.diagonalDownCursor.set()
        case .topRight, .bottomLeft:      Self.diagonalUpCursor.set()
        case .body:                       NSCursor.arrow.set()
        }
    }

    // MARK: 命中区分类（0x1002f4b58：边缘带宽 10pt，返回 0–8 区号）

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

    // MARK: 拖拽：body 区移动窗口，边缘手柄调尺寸（0x1002f454c / 0x1002f4a8c）

    /// v83（2026-10-19 用户反馈「关不掉」补强）：贴图窗是 nonactivating panel——
    /// 点击贴图不会激活本 App，PinnedScreenshotManager 的**本地** keyDown 监听
    /// 收不到 Esc（本地监视器只在本 App 为活动应用时回调），用户没有任何键盘关闭路径。
    /// nonactivating 面板成为 key window 后仍可收键盘，故在内容视图直接处理：
    /// Esc / Delete / ForwardDelete 均关闭当前贴图（比 manager 的「Esc 全关」更安全）。
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 51, 117:   // Esc / Delete / Forward Delete
            closeClicked()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartWindowFrame = window?.frame
        dragStartMouse = NSEvent.mouseLocation
        activeZone = hitZone(at: convert(event.locationInWindow, from: nil))
    }

    private func handleDrag(_ event: NSEvent) {
        guard let window = window,
              let frame0 = dragStartWindowFrame,
              let mouse0 = dragStartMouse else { return }
        let mouse1 = NSEvent.mouseLocation
        let dx = mouse1.x - mouse0.x
        let dy = mouse1.y - mouse0.y
        let zone = activeZone ?? .body
        var frame = frame0

        if zone == .body {
            // body 区拖动 = 移动窗口
            frame.origin.x += dx
            frame.origin.y += dy
        } else {
            // 边缘/对角拖拽调尺寸（setFrame:display:，0x1002f4a50）
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
        }
        window.setFrame(frame, display: true)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStartWindowFrame = nil
        dragStartMouse = nil
        activeZone = nil
    }

    // MARK: 缩放核心（0x1002f55b0：非 key 先 makeKey；锚点=光标；灵敏度 3.5/12 两档）

    override func scrollWheel(with event: NSEvent) { zoomCore(with: event) }
    override func magnify(with event: NSEvent) { zoomCore(with: event, magnification: event.magnification) }

    private func zoomCore(with event: NSEvent, magnification: CGFloat? = nil) {
        guard let window = window else { return }
        // 非 key 窗时先抢 key 再缩放（0x1002f56b8）
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }

        // 灵敏度两档：精确滚轮 delta/3.5，普通滚轮固定步进 ±12（0x1002f57a0-0x1002f582c）
        var deltaPercent: CGFloat
        if let magnification = magnification {
            deltaPercent = magnification * 100
        } else if event.hasPreciseScrollingDeltas {
            deltaPercent = event.scrollingDeltaY / Self.preciseScrollDivisor
        } else {
            deltaPercent = event.scrollingDeltaY > 0 ? Self.regularScrollStep : -Self.regularScrollStep
        }
        // 滚轮向上 = 放大
        deltaPercent = -deltaPercent
        applyZoom(percentDelta: deltaPercent, anchor: NSEvent.mouseLocation)
        showHUD()
    }

    /// 以光标为锚点缩放（0x1002f5838/0x1002f5854）；最小边 50pt（0x1002f59ec）
    ///
    /// 上限说明：本实现此前按"0x1002f5a00 = 8 倍基准上限"加了自定上限，经双方案件复核（实测反汇编）：
    /// 该地址实为**下限钳制**——`0x1002f59e4 fmov d3,#1.0` / `0x1002f5a00 fcmp d2,d3` /
    /// `0x1002f5a04 fcsel d2,d3,d4,ls`，对宽/高逐分量做 min 钳制（1.0 与 50pt 两个下限），
    /// **原作无上限**。故移除自定的 8 倍上限，恢复原作无上限行为。
    private func applyZoom(percentDelta: CGFloat, anchor: NSPoint) {
        guard let window = window else { return }
        let frame = window.frame
        let aspect = max(CGFloat(image.width) / max(CGFloat(image.height), 1), 0.0001)
        var width = max(Self.minWindowWidth, frame.width * (1.0 + percentDelta / 100.0))
        var height = width / aspect
        if height < Self.minWindowWidth {
            height = Self.minWindowWidth
            width = height * aspect
        }

        // 锚点保持：光标相对旧 frame 的比例在新 frame 中不变
        let fx = (anchor.x - frame.minX) / max(frame.width, 1)
        let fy = (anchor.y - frame.minY) / max(frame.height, 1)
        let origin = NSPoint(x: anchor.x - fx * width,
                             y: anchor.y - fy * height)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        currentScale = width / max(baseSize.width, 1)
        needsDisplay = true
    }

    // MARK: 右键动作菜单（0x1002f9b6c 完整实证）

    override func rightMouseDown(with event: NSEvent) { showActionsMenu(with: event) }

    func showActionsMenu(with event: NSEvent) {
        isMenuPopped = true
        // 弹出前先隐藏控制条（0x1002f8188 + 0x1002f8358）
        controlsWindow.dismiss(animated: false)
        let menu = NSMenu(title: "More")
        // Zoom ▸ 子菜单（0x1002f998c：4 档，标题 "\(n)%"，representedObject = NSNumber(scale)）
        let zoom = NSMenu(title: pinL10n("Zoom"))
        for n in Self.scalePresets {
            let item = NSMenuItem(title: "\(n)%", action: #selector(handleScalePreset(_:)), keyEquivalent: "")
            item.representedObject = NSNumber(value: Double(n) / 100.0)
            item.target = self
            zoom.addItem(item)
        }
        let zoomItem = NSMenuItem(title: pinL10n("Zoom"), action: nil, keyEquivalent: "")
        zoomItem.submenu = zoom
        menu.addItem(zoomItem)
        menu.addItem(.separator())
        for (key, sel) in [(pinL10n("Annotate"), #selector(annotateClicked)),
                           (pinL10n("Extract Text"), #selector(ocrClicked)),
                           (pinL10n("Translate"), #selector(translateClicked)),
                           (pinL10n("Save"), #selector(saveClicked))] {
            let item = NSMenuItem(title: key, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: pinL10n("Close"), action: #selector(closeClicked), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        // 弹出前调用隐藏逻辑；菜单关闭后允许 tip 重新调度
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        isMenuPopped = false
    }

    /// 档位缩放（0x1002fa188 → 0x1002fa1d8）：scale = n/100，受屏可见域钳制
    @objc func handleScalePreset(_ sender: NSMenuItem) {
        guard let window = window,
              let number = sender.representedObject as? NSNumber else { return }
        let scale = CGFloat(number.doubleValue)
        let width = max(Self.minWindowWidth, baseSize.width * scale)
        let height = width / max(CGFloat(image.width) / max(CGFloat(image.height), 1), 0.0001)
        var frame = NSRect(x: 0, y: 0, width: width, height: height)
        // 以贴图中心为准，受屏可见域钳制（内容内矩换算 0x1002faaec）
        let old = window.frame
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(visible.minX, old.midX - width / 2), visible.maxX - width)
            frame.origin.y = min(max(visible.minY, old.midY - height / 2), visible.maxY - height)
        } else {
            frame.origin = NSPoint(x: old.midX - width / 2, y: old.midY - height / 2)
        }
        window.setFrame(frame, display: true)
        currentScale = scale
        needsDisplay = true
        showHUD()
    }

    // MARK: 动作（选择器逐一对应原作 selref 0x100c3c820-0x100c3c848）

    /// 标注：把当前贴图送入标注编辑器
    @objc func annotateClicked() {
        controlsWindow.dismiss(animated: false)
        AnnotationEditorController.shared.open(image: image)
    }

    /// 提取文字（贴图 OCR，F11）：失败态显示 "Text Recognition Failed" + exclamationmark.circle.fill
    @objc func ocrClicked() {
        controlsWindow.dismiss(animated: false)
        guard let data = ImageProcessor.pngData(image) else { return }
        Task { @MainActor in
            do {
                let text = try await OCRService.shared.recognizeText(imageData: data, quality: .thorough)
                if text.isEmpty {
                    Self.showTextResultAlert(title: pinL10n("No text recognized"), body: "", failure: false)
                } else {
                    CaptureEventBus.onTextRecognized?(text)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    Self.showTextResultAlert(title: pinL10n("Extract Text"), body: text, failure: false)
                }
            } catch {
                // 失败占位：SF Symbol exclamationmark.circle.fill（0x1002fa964/0x1002fa990）
                Self.showTextResultAlert(title: pinL10n("Text Recognition Failed"), body: "", failure: true)
            }
        }
    }

    /// 翻译：OCR 后交给 LLM 服务（无服务时回退提示）
    @objc func translateClicked() {
        controlsWindow.dismiss(animated: false)
        guard let data = ImageProcessor.pngData(image) else { return }
        Task { @MainActor in
            do {
                let text = try await OCRService.shared.recognizeText(imageData: data, quality: .thorough)
                guard !text.isEmpty else {
                    Self.showTextResultAlert(title: pinL10n("No text recognized"), body: "", failure: false)
                    return
                }
                guard let llm = ServiceLocator.llmService else {
                    Self.showTextResultAlert(title: pinL10n("Translate"), body: text, failure: false)
                    return
                }
                let translated = try await llm.complete(
                    prompt: "请把以下文本翻译为中文，只输出译文：\n\(text)",
                    system: nil, model: nil)
                Self.showTextResultAlert(title: pinL10n("Translate"), body: translated, failure: false)
            } catch {
                Self.showTextResultAlert(title: pinL10n("Text Recognition Failed"), body: "", failure: true)
            }
        }
    }

    /// 保存：落盘 + 登记最近截图（复用 ScreenshotManager 主流程）
    @objc func saveClicked() {
        controlsWindow.dismiss(animated: false)
        guard let data = ImageProcessor.pngData(image),
              let url = ScreenshotManager.shared.savePNG(data) else { return }
        ScreenshotManager.shared.registerCaptured(url: url, data: data, playSound: true, mode: "pin")   // v130②
    }

    /// 关闭（setReleasedWhenClosed(false) 面板 close，0x100302174 链）
    @objc func closeClicked() {
        window?.close()
    }

    /// 文本结果弹窗（OCR 失败态带 SF Symbol，对齐 F11）
    private static func showTextResultAlert(title: String, body: String, failure: Bool) {
        let alert = NSAlert()
        alert.alertStyle = failure ? .warning : .informational
        alert.messageText = title
        if failure {
            alert.icon = NSImage(systemSymbolName: "exclamationmark.circle.fill",
                                 accessibilityDescription: nil)
        }
        if !body.isEmpty {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
            text.string = body
            text.isEditable = false
            text.font = NSFont.systemFont(ofSize: 13)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: pinL10n("Close"))
        alert.runModal()
    }

    // MARK: 小模式一次性提示（0x1002f8838 调度器）

    /// 调度条件（0x1002f88a4-0x1002f88f4）：小模式 + 菜单未弹出 + 无 pending + tip 未看过
    private func scheduleSmallModeTipIfNeeded() {
        guard isSmallMode, !isMenuPopped, pendingTipWorkItem == nil else { return }
        let seen = UserDefaults.standard.bool(forKey: Self.smallModeTipKey)
        guard !seen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.window != nil else { return }   // 弱引用存活才显示（0x1002f8b18）
            self.presentSmallModeTip()
        }
        pendingTipWorkItem = work
        DispatchQueue.main.async(execute: work)   // 0x1002f8ab0
    }

    private func presentSmallModeTip() {
        pendingTipWorkItem = nil
        guard let window = window, tipWindow == nil else { return }
        // 显示时写一次性标记（0x1002f8db0-0x1002f8de0）
        UserDefaults.standard.set(true, forKey: Self.smallModeTipKey)
        let tip = PinnedScreenshotSmallModeTipWindow(near: window.frame,
                                                     text: pinL10n("Right-click for more actions"))
        tipWindow = tip
        tip.present()
    }
}

// MARK: - 贴图窗口

/// 贴图窗（原作 PinnedScreenshotWindow，NSPanel 子类，窗口语义 0x100300344-0x100300790 完整实证）：
/// 浮动层级 3（.floating）、无阴影、透明背景、canJoinAllSpaces | fullScreenAuxiliary、
/// becomeKey 后通知 Manager（0x100302174 → 0x10030152c）、constrainFrameRect 直通（0x1003021fc）。
final class PinnedScreenshotWindow: NSPanel {

    init(image: CGImage, origin: NSPoint) {
        let size = Self.initialSize(for: image)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // §3.5 窗口配置（0x100300344 起，逐项对齐）
        isReleasedWhenClosed = false            // 0x1009530e0
        isFloatingPanel = true                  // setFloatingPanel(true)，0x100951a60
        becomesKeyOnlyIfNeeded = false          // 0x100950820
        level = NSWindow.Level(3)               // NSFloatingWindowLevel，0x1009523c0
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]   // 0x101，0x100950ca0
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // 0x100951d40（贴图窗无投影）
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true          // 0x1009501e0
        hidesOnDeactivate = false

        let view = PinnedScreenshotContentView(image: image, frame: NSRect(origin: .zero, size: size))
        view.onClose = { [weak self] in self?.close() }
        contentView = view
        setFrame(NSRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
    }

    /// 初始尺寸：图像等比放入屏幕可见域（常量 360/420/0.58/0.74，精确公式原作未复原，spec 16 §6.7 ⬜）
    private static func initialSize(for image: CGImage) -> NSSize {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxW = min(visible.width * 0.58, 420)
        let maxH = min(visible.height * 0.74, 360)
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return NSSize(width: 60, height: 60) }
        let scale = min(1, maxW / w, maxH / h)
        return NSSize(width: max(w * scale, 60), height: max(h * scale, 60))
    }

    override var canBecomeKey: Bool { true }     // 0x100302164（canBecomeKeyWindow）
    override var canBecomeMain: Bool { true }    // 0x10030216c（canBecomeMainWindow）

    /// becomeKey → super → 通知 Manager 更新活动贴图（0x100302174/0x10030152c）
    override func becomeKey() {
        super.becomeKey()
        // v83：把键盘焦点交给内容视图，Esc/Delete 才能到达其 keyDown
        if let view = contentView { makeFirstResponder(view) }
        PinnedScreenshotManager.shared.windowDidBecomeKey(self)
    }

    /// 直通 super：允许拖出屏幕边缘自由摆放（0x1003021fc）
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        super.constrainFrameRect(frameRect, to: screen)
    }
}

// MARK: - 贴图管理器

/// 多贴图管理（原作 PinnedScreenshotManager 单例）：
/// 持有窗口数组 + 本地 NSEvent 监听器；键监听 Esc(53)/Delete(51)/ForwardDelete(117)（0x1002ffb90）。
/// ⚠️ 三键的关闭语义差分原作未逐条落地（spec 16 §6.4 ⬜），重建取：
/// Esc=关闭全部；Delete/ForwardDelete=关闭活动（key）贴图。
public final class PinnedScreenshotManager: NSObject {

    public static let shared = PinnedScreenshotManager()

    private var windows: [PinnedScreenshotWindow] = []
    private var monitor: Any?
    /// becomeKeyWindow 回写的活动贴图（弱引用）
    private weak var activeWindow: PinnedScreenshotWindow?

    private override init() {
        super.init()
        // 本地 keyDown 监听（0x1002ffc2c addLocalMonitorForEventsMatchingMask:handler:）
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53:            // Esc（0x1002fff98）
                self?.closeAll()
                return nil
            case 51, 117:       // Delete / Forward Delete（0x1002fffa8/0x1002fffbc）
                self?.closeActive()
                return event    // 不吞键：删除语义保持正常文本编辑，仅顺带关闭活动贴图
            default:
                return event
            }
        }
    }

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }   // removeMonitor: 0x10094f120
    }

    // MARK: 钉图入口

    /// 把一张图钉到屏幕（原作 pin() 流；错位平铺避免完全重叠）
    @discardableResult
    public func show(image: CGImage, at origin: NSPoint? = nil) -> Bool {
        let offset = CGFloat(windows.count % 6) * 24
        let position = origin ?? NSPoint(x: 160 + offset, y: 160 + offset)
        let window = PinnedScreenshotWindow(image: image, origin: position)
        windows.append(window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: window)
        return true
    }

    /// 把图片文件钉到屏幕上
    @discardableResult
    public func show(url: URL) -> Bool {
        guard let image = ImageProcessor.cgImage(from: url) else { return false }
        return show(image: image)
    }

    /// 关闭全部贴图
    public func closeAll() {
        for window in windows { window.close() }
        windows.removeAll()
    }

    /// 关闭当前活动贴图
    private func closeActive() {
        guard let active = activeWindow else { return }
        active.close()
    }

    // MARK: 窗口事件

    /// becomeKeyWindow 链回调（0x10030152c：验证 contentView 后更新活动贴图弱引用）
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
