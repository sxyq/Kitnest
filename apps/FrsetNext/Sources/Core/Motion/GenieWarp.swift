import AppKit
import QuartzCore

// MARK: - 窗口开合：神灯（Genie）漏斗动画
//
// 用户：「展开和收起都需要同样的」——所以面板的开与合都走同一套 Dock 网格。
//
// 为什么要有独立的全屏覆盖窗：
//   · 漏斗会把窗口画到它自己的 frame **之外**（收进菜单栏图标那 22pt 的方格里），
//     窗口自带的图层树裁不掉这个范围，也没有公开 API 能让窗口按网格变形；
//   · 所以流程是：抓一张窗口快照 → 把真窗隐藏 → 在覆盖窗上按网格逐行重绘快照
//     → 动画结束再把真窗放回来。Apple 自己也是这么做的（warp 的是窗口图像）。
//
// 坐标：覆盖窗里的视图是 flipped，局部坐标 = 屏幕左上角原点、y 向下，
// 与 GenieMesh 的约定一致，省掉来回翻转。

final class GenieWarpView: NSView {

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// 面板快照（已按窗口圆角裁好，四周透明）
    var snapshot: CGImage?
    /// 窗口在视图坐标里的最终位置
    var windowRect: GenieRect = GenieRect()
    /// 图标（插槽）在视图坐标里的位置
    var slotRect: GenieRect = GenieRect()
    /// 0 = 完整窗口，1 = 完全收进图标
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    var showsMesh = false
    /// 菜单栏下沿（视图坐标）。漏斗进到这一线以上就被裁掉——
    /// 真机上窗口是钻进菜单栏背后的，不裁的话面板内容会盖住菜单栏图标。
    var menuBarBottom: CGFloat = 0

    private let roundedMask = true

    private static var drawLogged = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext, let image = snapshot else {
            if Self.drawLogged < 2 {
                Self.drawLogged += 1
                Log.warn("Motion", "genie draw：进不来（context 或快照为空）")
            }
            return
        }
        cg.setShouldAntialias(true)
        cg.interpolationQuality = .high

        let mesh = genieMesh(progress: progress, window: windowRect, icon: slotRect, edge: .top)
        if Self.drawLogged < 3 {
            Self.drawLogged += 1
            Log.info("Motion", "genie draw：p=\(String(format: "%.2f", progress)) 图 \(image.width)x\(image.height) 行 \(mesh.rows) 窗(\(Int(windowRect.x)),\(Int(windowRect.y)),\(Int(windowRect.width)),\(Int(windowRect.height))) 图标(\(Int(slotRect.x)),\(Int(slotRect.y)))")
        }
        if UserDefaults.standard.bool(forKey: "probe.genieDebug") {
            cg.setFillColor(NSColor.systemRed.withAlphaComponent(0.12).cgColor)
            cg.fill(bounds)
            cg.setStrokeColor(NSColor.systemBlue.cgColor)
            cg.setLineWidth(2)
            cg.stroke(CGRect(x: windowRect.x, y: windowRect.y, width: windowRect.width, height: windowRect.height))
            cg.setStrokeColor(NSColor.systemGreen.cgColor)
            cg.stroke(CGRect(x: slotRect.x, y: slotRect.y, width: slotRect.width, height: slotRect.height))
        }
        guard mesh.rows >= 2 else { return }

        // 菜单栏以下才可见：漏斗进到菜单栏里就消失了（真机上窗口是钻进菜单栏背后的）。
        // 这里**按行裁**而不是给整个 context 设 clip——实测 CGContext.clip(to:) 在这个
        // flipped 视图里会把整块画面裁没（这里不赌它的坐标解释，直接算）。
        let clipY = max(menuBarBottom, slotRect.maxY)
        Self.clipLoggedOnce(clipY, bounds)

        // 快照像素 / 点 的比例（Retina 抓回来是 2x）
        let pixelScale = windowRect.width > 0 ? CGFloat(image.width) / windowRect.width : 1
        let sourceWidth = CGFloat(image.width)

        for row in 0..<(mesh.rows - 1) {
            var y0 = mesh.screenY(row)
            var y1 = mesh.screenY(row + 1)
            var (x0a, x0b) = mesh.screenX(row)
            var (x1a, x1b) = mesh.screenX(row + 1)
            var ly0 = mesh.localY(row) * pixelScale
            var ly1 = mesh.localY(row + 1) * pixelScale

            if y1 <= clipY + 0.01 { continue }          // 整行都在菜单栏里
            if y0 < clipY {                              // 顶部压到菜单栏：截掉一截
                let t = (clipY - y0) / max(y1 - y0, 0.0001)
                x0a += (x1a - x0a) * t
                x0b += (x1b - x0b) * t
                ly0 += (ly1 - ly0) * t
                y0 = clipY
            }

            let height = ly1 - ly0
            guard height > 0.05, abs(y1 - y0) > 0.01 else { continue }

            let top = max(0, min(CGFloat(image.height - 1), ly0))
            let cropRect = CGRect(x: 0,
                                  y: top,
                                  width: sourceWidth,
                                  height: max(1, min(CGFloat(image.height) - top, height)))
            guard let strip = image.cropping(to: cropRect) else { continue }

            // 左上 / 右上 / 左下 / 右下
            let a = CGPoint(x: x0a, y: y0)
            let b = CGPoint(x: x0b, y: y0)
            let c = CGPoint(x: x1a, y: y1)
            let d = CGPoint(x: x1b, y: y1)

            let srcW = CGFloat(strip.width)
            let srcH = CGFloat(strip.height)

            drawTriangle(cg, strip,
                         src: (CGPoint(x: 0, y: 0), CGPoint(x: srcW, y: 0), CGPoint(x: 0, y: srcH)),
                         dst: (a, b, c))
            drawTriangle(cg, strip,
                         src: (CGPoint(x: srcW, y: 0), CGPoint(x: srcW, y: srcH), CGPoint(x: 0, y: srcH)),
                         dst: (b, d, c))
        }

        if showsMesh {
            cg.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.55).cgColor)
            cg.setLineWidth(0.6)
            for row in 0..<mesh.rows {
                let (xa, xb) = mesh.screenX(row)
                let y = mesh.screenY(row)
                cg.move(to: CGPoint(x: xa, y: y))
                cg.addLine(to: CGPoint(x: xb, y: y))
            }
            cg.strokePath()
        }
    }

    /// 把源三角形仿射贴到目标三角形（用裁剪限定范围）。
    /// 四边形是梯形 → 必须拆两个三角形，否则侧边会出现锯齿阶梯（网页原型踩过）。
    private static var clipLogged = false
    private static func clipLoggedOnce(_ clipY: CGFloat, _ bounds: CGRect) {
        guard !clipLogged else { return }
        clipLogged = true
        Log.info("Motion", "genie 裁切线 y=\(Int(clipY)) 画布 \(Int(bounds.width))x\(Int(bounds.height))")
    }

    private func drawTriangle(_ cg: CGContext,
                              _ image: CGImage,
                              src: (CGPoint, CGPoint, CGPoint),
                              dst: (CGPoint, CGPoint, CGPoint)) {
        let (s0, s1, s2) = src
        let (d0, d1, d2) = dst

        // 稍微外扩，避免相邻三角形之间出现 1px 白缝
        let cx = (d0.x + d1.x + d2.x) / 3
        let cy = (d0.y + d1.y + d2.y) / 3
        func push(_ p: CGPoint) -> CGPoint {
            let dx = p.x - cx, dy = p.y - cy
            let len = max(0.001, sqrt(dx * dx + dy * dy))
            let grow: CGFloat = 0.45
            return CGPoint(x: p.x + dx / len * grow, y: p.y + dy / len * grow)
        }
        let e0 = push(d0), e1 = push(d1), e2 = push(d2)

        let du1 = s1.x - s0.x, dv1 = s1.y - s0.y
        let du2 = s2.x - s0.x, dv2 = s2.y - s0.y
        let dx1 = e1.x - e0.x, dy1 = e1.y - e0.y
        let dx2 = e2.x - e0.x, dy2 = e2.y - e0.y
        let det = du1 * dv2 - du2 * dv1
        guard abs(det) > 0.000001 else { return }

        let a = (dx1 * dv2 - dx2 * dv1) / det
        let c = (du1 * dx2 - du2 * dx1) / det
        let b = (dy1 * dv2 - dy2 * dv1) / det
        let d = (du1 * dy2 - du2 * dy1) / det
        let tx = e0.x - a * s0.x - c * s0.y
        let ty = e0.y - b * s0.x - d * s0.y

        cg.saveGState()
        cg.beginPath()
        cg.move(to: e0)
        cg.addLine(to: e1)
        cg.addLine(to: e2)
        cg.closePath()
        cg.clip()

        cg.concatenate(CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty))
        // 视图是 flipped，而 Quartz 画图按 y 向上：这里补一次翻转，
        // 让源图的「第 0 行」正好落在裁剪区的上边。
        cg.translateBy(x: 0, y: CGFloat(image.height))
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        cg.restoreGState()
    }
}

// MARK: - 覆盖窗

/// 只用来画漏斗的覆盖窗：**绝不允许成为 key/main**。
/// 实测：用普通 NSPanel 时它会抢走键盘焦点，主面板 resignKey → 0.9s 后自动收起，
/// 表现为「面板刚展开就自己关了」。
private final class GenieOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 驱动器

final class GenieWarp {

    /// 神灯需要的时长。设置里的三档（0.18 / 0.22 / 0.28）是给缩放动画的，
    /// 漏斗在这个尺度下 0.2s 只会「闪一下」——Dock 自己是 500ms。
    /// 这里把三档映射到 0.40 / 0.46 / 0.56，既不忽略用户偏好，也保证看得清两段。
    static func duration(for configured: TimeInterval) -> TimeInterval {
        min(0.62, max(0.40, 0.40 + (configured - 0.18) * 1.6))
    }


    static let shared = GenieWarp()

    private var overlay: NSPanel?
    private var view: GenieWarpView?
    private var timer: Timer?
    private var targetWindow: NSWindow?
    private var completion: (() -> Void)?
    private var startedAt: CFTimeInterval = 0
    private var duration: TimeInterval = 0.5
    private var opening = true
    private var running = false

    /// 排障：把动画停在某一帧（0…1），用于确定性截图核对
    private var holdProgress: CGFloat? {
        guard UserDefaults.standard.object(forKey: "probe.genieHold") != nil else { return nil }
        return CGFloat(UserDefaults.standard.double(forKey: "probe.genieHold"))
    }

    static var isRunning: Bool { shared.running }

    // MARK: 对外

    /// 展开：窗口此刻已显示，抓完快照立刻隐藏，再由覆盖窗「倒」出来。
    /// 返回 false 表示没抓到快照（调用方退回缩放动画）。
    @discardableResult
    func playIn(window: NSWindow, slot: NSRect, duration: TimeInterval,
                completion: (() -> Void)? = nil) -> Bool {
        play(window: window, slot: slot, opening: true, duration: duration, completion: completion)
    }

    /// 收起：窗口仍在屏上，抓快照后隐藏，再「吸」回图标。
    @discardableResult
    func playOut(window: NSWindow, slot: NSRect, duration: TimeInterval,
                 completion: @escaping () -> Void) -> Bool {
        play(window: window, slot: slot, opening: false, duration: duration, completion: completion)
    }

    /// 中途取消（例如收起还没跑完又被重新打开）
    func cancel(restoreWindow: Bool) {
        guard running else { return }
        let win = targetWindow
        stopTimer()
        teardownOverlay()
        if restoreWindow, let win, win.isVisible {
            win.alphaValue = 1
        }
        targetWindow = nil
        completion = nil
        running = false
    }

    // MARK: 主流程

    private func play(window: NSWindow, slot: NSRect, opening: Bool,
                      duration: TimeInterval, completion: (() -> Void)?) -> Bool {
        // 总开关：默认开。默认值由 registerDefaults 写入，这里缺省也当开。
        if UserDefaults.standard.object(forKey: "motion.genie") != nil,
           UserDefaults.standard.bool(forKey: "motion.genie") == false {
            return false
        }
        guard let screen = window.screen ?? NSScreen.main else { return false }
        var shot = Self.snapshot(of: window)
        if shot == nil {
            // 刚 makeKeyAndOrderFront 的窗口有时还没登记进窗口服务器，抓回来是 nil。
            // flush 一次事务再抓（同一轮 runloop 内，用户看不到中间态）。
            CATransaction.flush()
            window.displayIfNeeded()
            shot = Self.snapshot(of: window)
        }
        guard let shot else {
            Log.warn("Motion", "genie：窗口快照失败（windowNumber=\(window.windowNumber)），退回缩放动画")
            return false
        }
        Log.info("Motion", "genie 快照 \(shot.width)x\(shot.height) windowNumber=\(window.windowNumber)")

        // 上一次还没跑完：直接收尾，避免两层覆盖窗叠着
        if running { cancel(restoreWindow: false) }

        self.targetWindow = window
        self.completion = completion
        self.opening = opening
        self.duration = GenieWarp.duration(for: duration)
        self.startedAt = CACurrentMediaTime()
        self.running = true

        let screenFrame = screen.frame
        let viewFrame = NSRect(origin: .zero, size: screenFrame.size)

        let v = GenieWarpView(frame: viewFrame)
        v.wantsLayer = true
        v.snapshot = shot
        v.windowRect = Self.local(window.frame, screen: screenFrame)
        v.slotRect = Self.local(slot, screen: screenFrame)
        v.showsMesh = UserDefaults.standard.bool(forKey: "probe.genieMesh")
        v.menuBarBottom = screen.frame.maxY - screen.visibleFrame.maxY

        let panel = GenieOverlayPanel(contentRect: screenFrame,
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered,
                                      defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.contentView = v
        panel.orderFrontRegardless()

        overlay = panel
        view = v

        // 真窗退到幕后：动画期间由覆盖窗上的快照代替。
        // 收起时窗口必须保持 isVisible（外部还在用它判断状态），只把 alpha 归零。
        window.alphaValue = 0

        let phases = geniePhases(progress: opening ? 1 : 0,
                                 window: v.windowRect, icon: v.slotRect, edge: .top)
        Log.info("Motion", String(format: "genie %@：窗 %.0f×%.0f 图标 %.0f×%.0f 行程 %.0f 弯 %.0fms 滑 %.0fms 弯完于 %.0f%%",
                                  opening ? "展开" : "收起",
                                  v.windowRect.width, v.windowRect.height,
                                  v.slotRect.width, v.slotRect.height,
                                  abs(v.windowRect.maxY - v.slotRect.midY),
                                  phases.bendLength, phases.slideLength, phases.settled * 100))

        if let hold = holdProgress {
            // 排障：定格在指定进度，方便截图核对形状
            v.progress = hold
            Log.info("Motion", String(format: "genie 定格在 %.2f（probe.genieHold）", hold))
            return true
        }

        v.progress = opening ? 1 : 0
        startTimer()
        return true
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common：面板首帧布局、菜单跟踪期间也不停表，否则动画会「卡一下再跳」
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard running, let view else { return }
        let elapsed = CACurrentMediaTime() - startedAt
        let t = min(1, max(0, elapsed / duration))
        // 进度是**线性**的（Dock 实测：495ms 内 RMS 误差 0.21%），缓动全在网格内部
        view.progress = opening ? CGFloat(1 - t) : CGFloat(t)

        if t >= 1 { finish() }
    }

    private func finish() {
        guard running else { return }
        stopTimer()
        let win = targetWindow
        let done = completion
        let wasOpening = opening
        teardownOverlay()

        if let win, win.isVisible {
            win.alphaValue = 1
            if !wasOpening {
                win.orderOut(nil)
            }
        }

        targetWindow = nil
        completion = nil
        running = false
        done?()
    }

    private func teardownOverlay() {
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay = nil
        view = nil
    }

    // MARK: 工具

    /// 抓窗口快照并按窗口圆角裁出透明边角。
    /// 直接抓回来的图是矩形（圆角外是桌面），拿去变形会在四角留一块「方角」贴片。
    private static func snapshot(of window: NSWindow) -> CGImage? {
        guard window.windowNumber > 0 else { return nil }
        guard let raw = ScreenSnapshot.legacyCapture(
            rect: .null,
            option: .optionIncludingWindow,
            windowID: CGWindowID(window.windowNumber),
            imageOption: [.boundsIgnoreFraming, .bestResolution]) else { return nil }

        let w = raw.width, h = raw.height
        guard w > 0, h > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return raw
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let scale = window.frame.width > 0 ? CGFloat(w) / window.frame.width : 1
        let radius = Theme.Radius.window * scale
        let path = CGPath(roundedRect: rect,
                          cornerWidth: radius, cornerHeight: radius,
                          transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(raw, in: rect)
        return ctx.makeImage() ?? raw
    }

    /// AppKit 屏幕坐标（y 向上）→ 覆盖窗视图坐标（y 向下）
    private static func local(_ rect: NSRect, screen: NSRect) -> GenieRect {
        GenieRect(x: rect.minX - screen.minX,
                  y: screen.maxY - rect.maxY,
                  width: rect.width,
                  height: rect.height)
    }
}
