import AppKit
import CoreGraphics

// MARK: - 截图态按键监视器

/// 截图进行中监听 Esc / Delete / 右键：任一触发即放弃本次截图。
/// 用本地监视器而不是窗口 keyDown，是因为覆盖层是 borderless 窗口，
/// 在部分场景下（输入法、其它 App 抢焦点）不一定能拿到 keyDown。
final class DeleteKeyMonitor {
    private var monitor: Any?
    private let handler: (NSEvent) -> Bool

    /// - Parameter handler: 返回 true 表示事件已被消费（不再向下传递）
    init(handler: @escaping (NSEvent) -> Bool) {
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            return self.handler(event) ? nil : event
        }
    }

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    }
}

// MARK: - 放大镜

/// 像素级放大镜：把屏幕快照的一小块按整数倍放大显示（关闭插值，保留硬边像素）
final class ScreenshotMagnifierView: NSView {
    var snapshot: CGImage?
    /// 采样点（快照像素坐标，左上原点）
    var samplePoint: CGPoint = .zero
    /// 放大倍数
    var zoom: CGFloat = 8

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext, let image = snapshot, zoom > 0 else { return }

        ctx.interpolationQuality = .none
        // 源区域：以采样点为中心的一块正方形（单位：快照像素）
        let side = bounds.width / zoom
        let src = CGRect(x: samplePoint.x - side / 2,
                         y: samplePoint.y - side / 2,
                         width: side, height: side)
        let clamped = src.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !clamped.isNull, !clamped.isEmpty, let piece = image.cropping(to: clamped) {
            // 把裁剪出来的区域映射回放大区域的正确位置（边缘越界时留白）
            let dest = CGRect(x: (clamped.minX - src.minX) / side * bounds.width,
                              y: (clamped.minY - src.minY) / side * bounds.height,
                              width: clamped.width / side * bounds.width,
                              height: clamped.height / side * bounds.height)
            ctx.draw(piece, in: dest)
        }

        // 中心十字（对准当前采样的那个像素）
        let cx = bounds.midX, cy = bounds.midY
        ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx - 6, y: cy)); ctx.addLine(to: CGPoint(x: cx + 6, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - 6)); ctx.addLine(to: CGPoint(x: cx, y: cy + 6))
        ctx.strokePath()
    }
}

/// 放大镜外框：圆角 + 白边 + 阴影，负责跟随光标定位
final class ScreenshotMagnifierContainerView: NSView {
    let magnifierView = ScreenshotMagnifierView()
    private let inset: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous   // v156: G2
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(magnifierView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        magnifierView.frame = bounds.insetBy(dx: inset, dy: inset)
    }

    /// 把放大镜放到光标附近（贴边时自动翻到另一侧），并更新采样内容
    func follow(pointInView point: NSPoint, viewSize: NSSize, snapshot: CGImage?) {
        magnifierView.snapshot = snapshot
        if let snapshot = snapshot {
            let sx = CGFloat(snapshot.width) / max(viewSize.width, 1)
            let sy = CGFloat(snapshot.height) / max(viewSize.height, 1)
            // 视图坐标（左下原点）→ 快照像素坐标（左上原点）
            magnifierView.samplePoint = CGPoint(x: point.x * sx, y: (viewSize.height - point.y) * sy)
        }

        let size = frame.size
        var origin = NSPoint(x: point.x + 18, y: point.y + 18)
        if origin.x + size.width > viewSize.width { origin.x = point.x - 18 - size.width }
        if origin.y + size.height > viewSize.height { origin.y = point.y - 18 - size.height }
        origin.x = max(0, min(origin.x, viewSize.width - size.width))
        origin.y = max(0, min(origin.y, viewSize.height - size.height))
        frame = NSRect(origin: origin, size: size)
        magnifierView.needsDisplay = true
    }
}

// MARK: - 默认拾取方式

/// 截图时默认用哪种拾取方式。
///
/// v266（用户：「鼠标在窗口里面，它会自动去识别，也可以去手动改成手动这种拉」）：
/// 原来默认 .region，自动识别窗口只能靠覆盖层里隐藏的 W 键或 ⇧⌥W 到达，
/// 等于没做。现在默认改成 .window，并在覆盖层顶部放一个可见的分段控件，
/// 用户随时能切回手动框选；切换结果写回偏好，下次沿用。
enum CapturePickModeStore {
    static var mode: ScreenshotOverlayView.OverlayPickMode {
        get {
            let raw: String = Preferences.shared.value(
                Preferences.Keys.captureDefaultPickMode, default: "window")
            return raw == "region" ? .region : .window
        }
        set {
            Preferences.shared.set(Preferences.Keys.captureDefaultPickMode,
                                   newValue == .window ? "window" : "region")
        }
    }
}

// MARK: - 覆盖层视图

/// 全屏覆盖层：拖拽选区 + 尺寸标签 + 十字准星 + 放大镜
final class ScreenshotOverlayView: NSView {
    /// v126（性能审计 F0553）：缓存标签字体与属性字典，避免 drawSizeLabel 每帧重建
    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.white
    ]

    /// 选区确认回调，参数是视图内矩形（左下原点，点坐标）
    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// 该屏幕的快照（用于放大镜与最终裁剪，可为 nil → 放大镜隐藏）
    var snapshot: CGImage?

    // MARK: 覆盖层两种拾取模式（v113 对齐原版）
    //
    // 原版 Frset 的 CaptureMode 含 `.window`（规格 06 反汇编还原：
    // `capture(_ mode:) // .area/.window/.full/.ocr/.pin/.long`），窗口模式自带
    // 窗口识别与选择（二进制反射字段：windows / windowOrder / selectedWindowId /
    // keyDownMonitor / isClosingWindow）。
    //
    // 窗口模式：悬停高亮窗口、单击截取。
    // v130（SnowShot 对齐）①：区域模式**重新引入元素吸附**（对标 Snow Shot
    // 「框选自动识别元素边界并吸附高亮」）——与 v112 的区别：
    //   · 只吸附、不劫持框选：拖拽仍是自由矩形，吸附仅在光标贴近元素边缘（8pt）时对齐；
    //   · 单击（无拖拽）且命中元素 → 直接截取该元素；
    //   · 按住 ⌥ 临时关闭吸附（精确手动框选）；
    //   · 无辅助功能权限时 ElementSnapEngine 全部返回 nil，自动退化纯手动（不报错）。

    enum OverlayPickMode: Equatable {
        case region   // 区域截图：拖拽框选
        case window   // 窗口截图：悬停识别 + 单击截取
    }

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private let magnifier = ScreenshotMagnifierContainerView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
    private var keyMonitor: DeleteKeyMonitor?

    /// 拾取模式。didSet 只同步可见控件；清状态统一走 setPickMode(_:)。
    var pickMode: OverlayPickMode = .region {
        didSet { syncModeControl(); needsDisplay = true }
    }
    /// 用户切换拾取方式时回调（更新历史模式标签 + 记住偏好）
    var onModeChange: ((OverlayPickMode) -> Void)?

    /// 覆盖层顶部可见的模式开关：把「自动识别窗口」摆进主流程，不再只靠隐藏的 W 键。
    private lazy var modeControl: NSSegmentedControl = {
        let c = NSSegmentedControl(frame: .zero)
        c.segmentCount = 2
        c.setLabel("窗口自动识别", forSegment: 0)
        c.setLabel("手动框选", forSegment: 1)
        c.segmentStyle = .rounded
        c.trackingMode = .selectOne
        c.target = self
        c.action = #selector(modeControlChanged(_:))
        c.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return c
    }()

    /// 开关底下垫一层不透明底：覆盖层只压暗 35%，背后的浏览器地址栏文字会透上来
    private lazy var modeBackdrop: NSView = {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94).cgColor
        v.layer?.cornerRadius = 10
        return v
    }()

    /// v266：按下后一旦拖动超过死区，本次操作就临时变成「手动拉框」。
    /// 窗口自动识别只负责「悬停 + 单击」；拖拽永远能拉出自定义矩形，不必先切模式。
    private var draggingRegion = false

    /// 窗口模式单击提交（rect=视图坐标，windowID=CG 窗口号）
    var onWindowCommit: ((CGRect, CGWindowID) -> Void)?
    /// 窗口模式多选提交（v264：⌘ 点选多个窗口 → 回车一次截完）
    var onWindowsCommit: (([(rect: CGRect, windowID: CGWindowID)]) -> Void)?

    /// 固定比例（v264）：nil = 自由框选。单位是「宽:高」的原始比例值。
    var lockedRatio: CGSize?
    /// 比例标签（尺寸气泡里显示，如 "16:9"）
    var lockedRatioLabel: String?

    /// 窗口模式已勾选的窗口（⌘ 单击切换）
    private var multiSelected: [WindowHit] = []
    /// ⌘ 点选后紧跟的那次 mouseUp 不要当成交付
    private var suppressWindowCommit = false

    private struct WindowHit {
        let globalRect: CGRect   // cocoa 全局坐标（左下原点）
        let windowID: CGWindowID
        let label: String
    }

    private var windowHits: [WindowHit] = []
    private var highlightedWindow: WindowHit?
    /// v116：AX 元素级吸附（比窗口更细，落在控件/文本块上；v130 起由 ElementSnapEngine 提供）
    private var highlightedElement: (rect: CGRect, label: String)?
    private var lastAXQuery: TimeInterval = 0
    /// 鼠标按下瞬间的高亮窗口（mouseUp 判定「单击截窗口」用）
    private var highlightedAtMouseDown: WindowHit?

    /// v130（SnowShot 对齐）①：区域模式的元素吸附命中（视图坐标）
    private var snapHighlight: (rect: CGRect, label: String)?

    /// 枚举可吸附窗口（本进程排除——覆盖层/工具条自身不能选到自己）
    private static func snapshotWindowHits() -> [WindowHit] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = Int(NSRunningApplication.current.processIdentifier)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var hits: [WindowHit] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                  wd >= 80, ht >= 60 else { continue }
            // CG 全局（主屏左上原点）→ cocoa 全局（主屏左下原点）
            let rect = CGRect(x: x, y: primaryHeight - y - ht, width: wd, height: ht)
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let name = w[kCGWindowName as String] as? String ?? ""
            let label = name.isEmpty ? owner : (owner.isEmpty ? name : "\(owner) · \(name)")
            hits.append(WindowHit(globalRect: rect, windowID: wid, label: label))
        }
        return hits
    }

    /// 全局 rect → 本视图坐标（视图铺满窗口内容区）
    private func viewRect(of global: CGRect) -> CGRect {
        window?.convertFromScreen(global) ?? global
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        magnifier.isHidden = true
        addSubview(magnifier)
        addSubview(modeBackdrop)
        addSubview(modeControl)
        syncModeControl()
        windowHits = Self.snapshotWindowHits()
        keyMonitor = DeleteKeyMonitor { [weak self] event in
            guard let self = self else { return false }
            if event.type == .rightMouseDown { self.onCancel?(); return true }
            // 53 = Esc，51 = Delete
            if event.keyCode == 53 || event.keyCode == 51 { self.onCancel?(); return true }
            // v231（用户：「没有直接选择整个窗口截图的功能，只有框选」）：
            // 框选界面上按 W 直接切到窗口模式——鼠标悬停哪个窗口就高亮哪个，
            // 单击即完成；再按 W（或 R）切回框选。⇧⌥W 的独立快捷键仍然保留。
            // W 只在「裸按」时切模式：⇧⌥W 是打开窗口截图的全局热键，
            // 它同样会产生 W 的 keyDown，若一并消费就会把刚打开的窗口识别切回框选。
            if event.keyCode == 0x0D,
               event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                self.setPickMode(self.pickMode == .region ? .window : .region)
                return true
            }
            // v264：窗口模式多选 —— 回车一次截完（Delete 仍由上面的通用分支取消整次截图）
            if self.pickMode == .window {
                if event.keyCode == 0x24 {          // Return
                    self.commitMultiWindows()
                    return true
                }
            }
            return false
        }
    }

    /// 统一的模式切换入口：W 键、顶部开关都走这里，保证状态与控件同步。
    func setPickMode(_ mode: OverlayPickMode, notify: Bool = true) {
        guard pickMode != mode else { return }
        pickMode = mode
        startPoint = nil
        currentPoint = nil
        draggingRegion = false
        highlightedWindow = nil
        highlightedElement = nil
        highlightedAtMouseDown = nil
        multiSelected.removeAll()
        suppressWindowCommit = false
        magnifier.isHidden = true
        needsDisplay = true
        if notify { onModeChange?(mode) }
    }

    @objc private func modeControlChanged(_ sender: NSSegmentedControl) {
        setPickMode(sender.selectedSegment == 0 ? .window : .region)
    }

    private func syncModeControl() {
        modeControl.selectedSegment = (pickMode == .window) ? 0 : 1
    }

    /// 开关固定在屏幕顶部居中，但必须避开刘海：带摄像头凹槽的 MacBook 顶部中央
    /// 约 37pt 被遮挡，加上菜单栏，贴着上沿放开关会看不见也点不到（v266 实机反馈）。
    /// 下移到距顶 64pt，提示胶囊再往下排一行。draw 每帧调用；frame 不变时无副作用。
    private func positionModeControl() {
        let w: CGFloat = 252, h: CGFloat = 30
        let r = NSRect(x: (bounds.width - w) / 2,
                       y: bounds.height - h - 64,
                       width: w, height: h)
        modeBackdrop.frame = r.insetBy(dx: -4, dy: -4)
        modeControl.frame = r
    }

    /// 窗口模式多选提交（回车 / 单击已选窗口）
    private func commitMultiWindows() {
        guard !multiSelected.isEmpty else { return }
        let items = multiSelected.map { (rect: viewRect(of: $0.globalRect), windowID: $0.windowID) }
        multiSelected.removeAll()
        onWindowsCommit?(items)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var acceptsFirstResponder: Bool { true }

    /// 当前选区（拖拽过程中实时计算）
    private var selectionRect: CGRect? {
        guard let a = startPoint, let b = currentPoint else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pickMode == .window {
            // v264：⌘ 单击 = 勾选/取消勾选一个窗口（多选），不立即截
            if event.modifierFlags.contains(.command), let hit = highlightedWindow {
                toggleMultiSelection(hit)
                suppressWindowCommit = true
                return
            }
            highlightedAtMouseDown = highlightedWindow
        }
        // v266：两种模式都记起点。窗口识别只吃「单击」；按下后一拖就临时进入
        // 手动框选，用户不用先切开关也能拉出自定义矩形。
        startPoint = p
        currentPoint = p
        draggingRegion = false
        if pickMode == .region { magnifier.isHidden = snapshot == nil }
        needsDisplay = true
    }

    /// ⌘ 点选：同一窗口再次点击即取消
    private func toggleMultiSelection(_ hit: WindowHit) {
        if let index = multiSelected.firstIndex(where: { $0.windowID == hit.windowID }) {
            multiSelected.remove(at: index)
        } else {
            multiSelected.append(hit)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !draggingRegion {
            // 4pt 死区：手抖不算拉框，单击仍然截整窗
            guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
            draggingRegion = true
            highlightedAtMouseDown = nil
            highlightedWindow = nil
            highlightedElement = nil
            multiSelected.removeAll()
            magnifier.isHidden = snapshot == nil
        }
        currentPoint = p
        // 吸附只在「手动框选」模式下生效：窗口识别模式下用户要的是自由自定义框，
        // 一吸附到窗口边界就又变回整窗了。
        if pickMode == .region {
            refreshSnap(at: p)
            currentPoint = snappedPoint(p)
        }
        // v264：固定比例 / ⇧ 正方形（比例优先）
        if let s = startPoint, let q = currentPoint {
            currentPoint = constrained(q, from: s, event: event)
        }
        needsDisplay = true
        if let q = currentPoint {
            magnifier.follow(pointInView: q, viewSize: bounds.size, snapshot: snapshot)
        }
    }

    /// 固定比例（v264）：设置里选了比例就锁死；否则按住 ⇧ 出正方形
    private func constrained(_ point: NSPoint, from start: NSPoint, event: NSEvent) -> NSPoint {
        if let ratio = lockedRatio, ratio.height > 0 {
            return CaptureRatioStore.constrain(from: start, to: point,
                                               ratio: ratio.width / ratio.height,
                                               bounds: bounds)
        }
        if event.modifierFlags.contains(.shift) {
            return CaptureRatioStore.square(from: start, to: point)
        }
        return point
    }

    override func mouseMoved(with event: NSEvent) {
        guard !draggingRegion else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        if pickMode == .window {
            // 窗口模式：悬停识别（缓存的 rects，零 CG 调用）
            let p = currentPoint ?? .zero
            highlightedWindow = windowHits.first { viewRect(of: $0.globalRect).contains(p) }
            // v116：AX 元素探测（节流 90ms；只对本进程外的窗口生效）
            let now = Date().timeIntervalSince1970
            if now - lastAXQuery > 0.09 {
                lastAXQuery = now
                highlightedElement = elementHit(atViewPoint: p)
            }
            needsDisplay = true
            return
        }
        // 区域模式：十字准线 + 放大镜 + v130① 元素吸附
        guard startPoint == nil else { return }
        if let p = currentPoint {
            refreshSnap(at: p)
            magnifier.isHidden = snapshot == nil
            magnifier.follow(pointInView: p, viewSize: bounds.size, snapshot: snapshot)
        }
        needsDisplay = true
    }

    /// v130①：⌥ 按下/松开即刷新（吸附加锁态要立即反馈，不等鼠标移动）
    override func flagsChanged(with event: NSEvent) {
        // 拖拽中的 ⇧ 正方形 / ⌥ 关吸附要立刻反馈，窗口模式临时拉框时同样适用
        if pickMode == .region || draggingRegion { needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        currentPoint = p
        if let start = startPoint, let q = currentPoint {
            currentPoint = constrained(q, from: start, event: event)
        }
        magnifier.isHidden = true
        let didDrag = draggingRegion
        let suppress = suppressWindowCommit
        defer {
            startPoint = nil
            currentPoint = nil
            draggingRegion = false
            highlightedAtMouseDown = nil
            suppressWindowCommit = false
            needsDisplay = true
        }

        // v266：拉出来的自定义框优先，与当前选中的模式无关。
        if didDrag {
            guard let rect = selectionRect, rect.width >= 4, rect.height >= 4 else {
                onCancel?()
                return
            }
            onCommit?(rect)
            return
        }

        if pickMode == .window {
            if suppress { return }
            // 已勾选多个窗口：这一次单击 = 确认（回车同义）
            if !multiSelected.isEmpty { commitMultiWindows(); return }
            // 单击（几乎无位移）且有高亮 → 提交该窗口；优先更细的 AX 元素
            if let el = highlightedElement, let hit = highlightedAtMouseDown,
               el.rect.width < viewRect(of: hit.globalRect).width - 8 {
                onWindowCommit?(el.rect, 0)
                return
            }
            if let hit = highlightedAtMouseDown {
                onWindowCommit?(viewRect(of: hit.globalRect), hit.windowID)
            }
            return
        }

        // v130①：单击（无拖拽位移）且命中吸附元素 → 直接截取该元素
        if let rect = selectionRect, rect.width < 4, rect.height < 4, let snap = snapHighlight {
            onCommit?(snap.rect)
            return
        }
        guard let rect = selectionRect else {
            onCancel?()
            return
        }
        // 太小的选区视为误点，直接放弃
        guard rect.width >= 4, rect.height >= 4 else {
            onCancel?()
            return
        }
        onCommit?(rect)
    }

    // MARK: v130（SnowShot 对齐）① 元素吸附

    /// 按住 ⌥ = 临时关闭吸附（精确手动框选）
    private var snapActive: Bool {
        pickMode == .region && !NSEvent.modifierFlags.contains(.option)
    }

    /// 节流查询光标下的可吸附元素（AX 调用；90ms 与窗口模式同阈值）
    private func refreshSnap(at viewPoint: NSPoint) {
        guard snapActive else {
            snapHighlight = nil
            return
        }
        let now = Date().timeIntervalSince1970
        guard now - lastAXQuery > 0.09 else { return }
        lastAXQuery = now
        snapHighlight = elementHit(atViewPoint: viewPoint)
    }

    /// 拖拽点吸附：贴近吸附矩形边缘（8pt 内）时对齐该边缘
    private func snappedPoint(_ p: NSPoint) -> NSPoint {
        guard snapActive, let snap = snapHighlight else { return p }
        let threshold: CGFloat = 8
        var out = p
        if abs(out.x - snap.rect.minX) < threshold { out.x = snap.rect.minX }
        else if abs(out.x - snap.rect.maxX) < threshold { out.x = snap.rect.maxX }
        if abs(out.y - snap.rect.minY) < threshold { out.y = snap.rect.minY }
        else if abs(out.y - snap.rect.maxY) < threshold { out.y = snap.rect.maxY }
        return out
    }

    /// 视图点 → 元素命中（返回视图坐标矩形；无权限/无命中时 nil）
    private func elementHit(atViewPoint point: NSPoint) -> (rect: CGRect, label: String)? {
        // 视图坐标 → cocoa 全局（覆盖层铺满所在屏幕窗口）
        let global = window?.convertToScreen(NSRect(origin: point, size: .zero)).origin ?? point
        guard let hit = ElementSnapEngine.snap(atCocoaGlobal: global) else { return nil }
        return (viewRect(of: hit.rect), hit.label)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        positionModeControl()
        let dim = NSColor(calibratedWhite: 0, alpha: 0.35)

        // 只有真正拖起来（draggingRegion）才画选区；窗口识别模式下按下未拖动时
        // selectionRect 是 0×0，不能把它当成框，否则会盖掉窗口高亮。
        if draggingRegion, let rect = selectionRect, rect.width >= 1, rect.height >= 1 {
            // v109（2026-10-21 用户：「第一次拉伸十分卡顿、没反应要第二次」）：
            // 全屏 evenOdd 路径填充在每次拖拽重绘都遍历 7.6M 像素——
            // 照录屏覆盖层 v62 方案改「选区外 4 个矩形」压暗，成本降到边框级。
            let r = rect.intersection(bounds)
            dim.setFill()
            NSRect(x: bounds.minX, y: bounds.minY,
                   width: bounds.width, height: max(0, r.minY - bounds.minY)).fill()
            NSRect(x: bounds.minX, y: r.maxY,
                   width: bounds.width, height: max(0, bounds.maxY - r.maxY)).fill()
            NSRect(x: bounds.minX, y: r.minY,
                   width: max(0, r.minX - bounds.minX), height: r.height).fill()
            NSRect(x: r.maxX, y: r.minY,
                   width: max(0, bounds.maxX - r.maxX), height: r.height).fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1
            border.stroke()

            drawHandles(rect)
            drawSizeLabel(rect)
        } else {
            dim.setFill()
            bounds.fill()
            if pickMode == .window {
                // v264：已勾选的多选窗口先画（带序号），悬停高亮叠在上面
                for (index, hit) in multiSelected.enumerated() {
                    drawWindowSelection(hit, index: index)
                }
                if let hit = highlightedWindow {
                    drawWindowHighlight(hit)
                }
                if let el = highlightedElement {
                    drawElementHighlight(el)
                }
                // v266：有高亮时也保留操作提示。否则用户只看到窗口被框住，
                // 不知道「单击截整窗、直接拖拽还能拉自定义框」这两条路都在。
                if !multiSelected.isEmpty {
                    drawWindowMultiHint()
                } else {
                    drawWindowModeHint()
                }
                return
            }
        }

        // 区域模式也要把「可以切到窗口自动识别」摆在眼前，否则用户只能手动拉框，
        // 永远发现不了不用拖拽的那一档（v231 的 W 键就是这么被埋没的）。
        if startPoint == nil {
            drawHint("拖拽框选 · 点上方「窗口自动识别」可免拖拽截整窗 · W 切换 · Esc 取消")
        }
        if let p = currentPoint { drawCrosshair(p) }
        // v130（SnowShot 对齐）①：元素吸附高亮（橙色描边 + 半透明填充，⌥ 按住不显示）
        if pickMode == .region, snapActive, let snap = snapHighlight {
            drawSnapHighlight(snap)
        }
    }

    // MARK: AX 元素命中（v116；v130 起查询逻辑收敛到 ElementSnapEngine）

    /// 元素吸附高亮（v130 SnowShot 对齐）：橙色实线描边 + 半透明橙填充
    private func drawSnapHighlight(_ el: (rect: CGRect, label: String)) {
        let r = el.rect.intersection(bounds)
        guard r.width > 2, r.height > 2 else { return }
        NSColor.systemOrange.withAlphaComponent(0.14).setFill()
        r.fill()
        let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        path.lineWidth = 1.5
        NSColor.systemOrange.setStroke()
        path.stroke()
        guard !el.label.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (el.label as NSString).size(withAttributes: attrs)
        var box = NSRect(x: r.minX, y: r.maxY + 3, width: size.width + 8, height: 15)
        if box.maxY > bounds.maxY { box.origin.y = r.minY - 18 }
        box.origin.x = max(0, min(box.origin.x, bounds.maxX - box.width))
        NSColor.systemOrange.withAlphaComponent(0.92).setFill()
        NSBezierPath.continuousRoundedRect(box, radius: 3).fill()
        (el.label as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 3), withAttributes: attrs)
    }

    /// 元素高亮：细虚线 + 小标签（比窗口高亮更亮）
    private func drawElementHighlight(_ el: (rect: CGRect, label: String)) {
        let r = el.rect.intersection(bounds)
        guard r.width > 2, r.height > 2 else { return }
        let path = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemYellow.setStroke()
        path.stroke()
        path.setLineDash(nil, count: 0, phase: 0)
        NSColor.systemYellow.withAlphaComponent(0.08).setFill()
        r.fill()
        guard !el.label.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let size = (el.label as NSString).size(withAttributes: attrs)
        let box = NSRect(x: r.minX, y: max(r.minY - 16, 0), width: size.width + 8, height: 15)
        NSColor.systemYellow.withAlphaComponent(0.9).setFill()
        NSBezierPath.continuousRoundedRect(box, radius: 3).fill()
        (el.label as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 3), withAttributes: attrs)
    }

    /// 窗口模式空态提示（覆盖层顶部居中）
    private func drawWindowModeHint() {
        drawHint("鼠标进窗自动高亮 · 单击截整窗 / 直接拖拽拉自定义框 · ⌘ 多选 · 点上方切手动 · Esc 取消")
    }

    /// 多选进行中的提示（v264）
    private func drawWindowMultiHint() {
        drawHint("已选 \(multiSelected.count) 个窗口 · 回车截取 · ⌘ 点击增删 · Esc 取消")
    }

    /// 顶部居中胶囊提示（两种文案共用一套排版）
    private func drawHint(_ string: String) {
        let text = string as NSString
        // v126（性能审计 F0553）：复用静态缓存属性字典
        let attrs = Self.labelAttrs
        let size = text.size(withAttributes: attrs)
        // 开关在距顶 64…94pt（避开刘海），胶囊排在它下方 8pt
        let box = NSRect(x: (bounds.width - size.width - 24) / 2,
                         y: bounds.height - 128,
                         width: size.width + 24, height: 26)
        NSColor(calibratedWhite: 0.1, alpha: 0.78).setFill()
        NSBezierPath.continuousRoundedRect(box, radius: 13).fill()
        text.draw(at: NSPoint(x: box.minX + 12, y: box.minY + 7), withAttributes: attrs)
    }

    /// 已勾选窗口的高亮 + 序号（v264）
    private func drawWindowSelection(_ hit: WindowHit, index: Int) {
        let rect = viewRect(of: hit.globalRect).intersection(bounds)
        guard rect.width > 1, rect.height > 1 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        rect.fill()
        let stroke = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        stroke.lineWidth = 2.5
        NSColor.controlAccentColor.setStroke()
        stroke.stroke()

        let badge = NSRect(x: rect.minX + 6, y: rect.maxY - 26, width: 20, height: 20)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let label = "\(index + 1)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
                   withAttributes: attrs)
    }

    /// 窗口吸附高亮：半透明提亮 + 强调色描边 + 窗口标签
    private func drawWindowHighlight(_ hit: WindowHit) {
        let rect = viewRect(of: hit.globalRect).intersection(bounds)
        guard rect.width > 1, rect.height > 1 else { return }
        NSColor.white.withAlphaComponent(0.10).setFill()
        rect.fill()
        let stroke = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        stroke.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        stroke.stroke()

        // 标签：窗口名，贴高亮框左上角（越界翻到框内）
        if !hit.label.isEmpty {
            let text = hit.label as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attrs)
            let boxW = size.width + 12
            let boxH: CGFloat = 20
            var x = rect.minX
            var y = rect.maxY + 4
            if y + boxH > bounds.maxY { y = rect.maxY - boxH - 4 }
            x = max(0, min(x, bounds.maxX - boxW))
            let box = NSRect(x: x, y: y, width: boxW, height: boxH)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath.continuousRoundedRect(box, radius: 4).fill()
            text.draw(at: NSPoint(x: x + 6, y: y + 3), withAttributes: attrs)
        }
    }

    /// 四角小方块把手
    private func drawHandles(_ rect: CGRect) {
        let s: CGFloat = 5
        NSColor.white.setFill()
        for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.minY),
                       (rect.minX, rect.maxY), (rect.maxX, rect.maxY)] {
            NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s).fill()
        }
    }

    /// 尺寸标签（v130 SnowShot 对齐③：像素单位、贴选区**右下角**，实时刷新）
    /// 显示 W × H（设备像素 = 点 × backingScale），越界时自动翻到上方/左侧
    private func drawSizeLabel(_ rect: CGRect) {
        // v130③：像素单位——Retina 下 1pt = 2px，与 Snow Shot 尺寸气泡一致
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let w = Int((rect.width * scale).rounded())
        let h = Int((rect.height * scale).rounded())
        // v264：锁定比例 / 按住 ⇧ 时把比例也写进气泡，用户一眼知道现在锁的是什么
        var title = "\(w) × \(h)"
        if let label = lockedRatioLabel {
            title += " · \(label)"
        } else if NSEvent.modifierFlags.contains(.shift) {
            title += " · 1:1"
        }
        let text = title as NSString
        // v126（性能审计 F0553）：复用静态缓存属性字典
        let attrs = Self.labelAttrs
        let size = text.size(withAttributes: attrs)
        let boxW = size.width + 12
        let boxH: CGFloat = 20

        // 右下角：先贴框右下方，越界翻到框内右上/左侧
        var x = rect.maxX - boxW
        var y = rect.minY - boxH - 6
        if y < 0 { y = rect.minY + 6 }
        x = max(0, min(x, bounds.maxX - boxW))
        y = max(0, min(y, bounds.maxY - boxH))

        let box = NSRect(x: x, y: y, width: boxW, height: boxH)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        NSBezierPath.continuousRoundedRect(box, radius: 4).fill()
        text.draw(at: NSPoint(x: x + 6, y: y + 3), withAttributes: attrs)
    }

    /// 十字准星（v130 SnowShot 对齐③：贯穿全屏 1px 实线，双色描边随背景反相——
    /// 深底上白线可见、浅底上黑影压边，任何背景都读得出）
    private func drawCrosshair(_ point: NSPoint) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: point.y))
        path.line(to: NSPoint(x: bounds.maxX, y: point.y))
        path.move(to: NSPoint(x: point.x, y: bounds.minY))
        path.line(to: NSPoint(x: point.x, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.stroke()
        NSColor.white.withAlphaComponent(0.75).setStroke()
        path.stroke()
    }
}

// MARK: - 覆盖层窗口

/// 每个屏幕一个覆盖层窗口：无边框、置顶（screenSaver 级）、透明背景
final class ScreenshotOverlayWindow: NSWindow {
    let overlayView: ScreenshotOverlayView

    init(screen: NSScreen, snapshot: CGImage?, pickMode: ScreenshotOverlayView.OverlayPickMode = .region) {
        self.overlayView = ScreenshotOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        self.overlayView.pickMode = pickMode
        super.init(contentRect: screen.frame,
                   styleMask: .borderless,
                   backing: .buffered,
                   defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = overlayView
        overlayView.snapshot = snapshot
    }

    /// borderless 窗口默认不接受键盘，这里放开以便响应 Esc
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
