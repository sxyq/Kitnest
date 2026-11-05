import AppKit
import QuartzCore

// MARK: - 窗口开合：神灯（Genie）漏斗动画
//
// 用户：「展开和收起都需要同样的」；随后：「一帧一帧闪退的、闪现的形式，
// 没有做到一帧一帧地渲染」——所以这一版把**逐帧渲染**和**逐帧播放**拆开：
//
//   ① 抓窗口快照（dlsym 的 CGWindowListCreateImage，按窗口 ID）；
//   ② 一次性把整条动画渲染成 N 张 CGImage（每张就是网格在某一进度下的样子）；
//   ③ 交给 Core Animation 用 `contents` 关键帧按刷新率播放——播放发生在渲染
//      服务器上，主线程那段时忙（SwiftUI 重排、采样器）也不会掉帧、不会跳。
//
// 为什么不能每帧在主线程现画：
//   · 第一版 Timer(1/60) + 每次重绘整屏（1710×1112@2x）：实测 24 帧 / 464ms；
//   · 换成 CADisplayLink + 只盖漏斗外接框（372×676）后，展开 24 帧、收起只有
//     12 帧——收起时主线程正被 SwiftUI 重排占着，掉一半帧，看起来就是「闪现」。
//
// 坐标：所有几何都在「覆盖窗视图」的局部坐标里，原点 = 该视图左上角，y 向下，
// 与 GenieMesh 的约定一致。

// MARK: - 单帧渲染

enum GenieFrameRenderer {

    /// 把某一进度的漏斗画进一张 CGImage。
    /// - size: 覆盖区尺寸（点）
    /// - scale: 像素倍率（按内存预算自动降，最高 2）
    static func render(progress: CGFloat,
                       snapshot: CGImage,
                       windowRect: GenieRect,
                       slotRect: GenieRect,
                       clipY: CGFloat,
                       size: CGSize,
                       scale: CGFloat,
                       showsMesh: Bool,
                       showsGuides: Bool) -> CGImage? {
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())
        guard w > 0, h > 0 else { return nil }
        guard let cg = CGContext(data: nil, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        cg.scaleBy(x: scale, y: scale)
        // Quartz 默认 y 向上，这里翻成 y 向下，后续几何全部按「屏幕坐标」写
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)

        cg.setShouldAntialias(true)
        cg.interpolationQuality = .medium

        if showsGuides {
            cg.setStrokeColor(NSColor.systemBlue.cgColor)
            cg.setLineWidth(1)
            cg.stroke(windowRect.rect)
            cg.setStrokeColor(NSColor.systemGreen.cgColor)
            cg.stroke(slotRect.rect)
        }

        let mesh = genieMesh(progress: progress, window: windowRect, icon: slotRect, edge: .top)
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

        guard mesh.rows >= 2, windowRect.width > 0 else { return cg.makeImage() }

        let pixelScale = CGFloat(snapshot.width) / windowRect.width
        let sourceWidth = CGFloat(snapshot.width)

        for row in 0..<(mesh.rows - 1) {
            var y0 = mesh.screenY(row)
            var y1 = mesh.screenY(row + 1)
            var (x0a, x0b) = mesh.screenX(row)
            var (x1a, x1b) = mesh.screenX(row + 1)
            var ly0 = mesh.localY(row) * pixelScale
            var ly1 = mesh.localY(row + 1) * pixelScale

            if y1 <= clipY + 0.01 { continue }        // 整行都在菜单栏里
            if y0 < clipY {                            // 顶部压到菜单栏：截掉一截
                let t = (clipY - y0) / max(y1 - y0, 0.0001)
                x0a += (x1a - x0a) * t
                x0b += (x1b - x0b) * t
                ly0 += (ly1 - ly0) * t
                y0 = clipY
            }

            let height = ly1 - ly0
            guard height > 0.05, abs(y1 - y0) > 0.01 else { continue }

            let top = max(0, min(CGFloat(snapshot.height - 1), ly0))
            let cropRect = CGRect(x: 0,
                                  y: top,
                                  width: sourceWidth,
                                  height: max(1, min(CGFloat(snapshot.height) - top, height)))
            guard let strip = snapshot.cropping(to: cropRect) else { continue }

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

        return cg.makeImage()
    }

    /// 把源三角形仿射贴到目标三角形（用裁剪限定范围）。
    /// 四边形是梯形 → 必须拆两个三角形，否则侧边会出现锯齿阶梯。
    private static func drawTriangle(_ cg: CGContext,
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
        cg.translateBy(x: 0, y: CGFloat(image.height))
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        cg.restoreGState()
    }
}

// MARK: - 覆盖窗

/// 只用来播漏斗的覆盖窗：**绝不允许成为 key/main**。
/// 普通 NSPanel 会抢走键盘焦点，主面板 resignKey → 0.9s 后自动收起，
/// 表现为「面板刚展开就自己关了」。
private final class GenieOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 驱动器

final class GenieWarp {

    static let shared = GenieWarp()

    private var overlay: NSPanel?
    private var targetWindow: NSWindow?
    private var completion: (() -> Void)?
    private var watchdog: Timer?
    private var running = false
    private var duration: TimeInterval = 0.5
    private var opening = true

    /// 神灯需要的时长。设置里的三档（0.18 / 0.22 / 0.28）是给缩放动画的，
    /// 漏斗在这个尺度下 0.2s 只会「闪一下」——Dock 自己是 500ms。
    /// 这里把三档映射到 0.40 / 0.46 / 0.56，既不忽略用户偏好，也保证看得清两段。
    static func duration(for configured: TimeInterval) -> TimeInterval {
        min(0.62, max(0.40, 0.40 + (configured - 0.18) * 1.6))
    }

    static var isRunning: Bool { shared.running }

    // MARK: 对外

    @discardableResult
    func playIn(window: NSWindow, slot: NSRect, duration: TimeInterval,
                completion: (() -> Void)? = nil) -> Bool {
        play(window: window, slot: slot, opening: true, duration: duration, completion: completion)
    }

    @discardableResult
    func playOut(window: NSWindow, slot: NSRect, duration: TimeInterval,
                 completion: @escaping () -> Void) -> Bool {
        play(window: window, slot: slot, opening: false, duration: duration, completion: completion)
    }

    func cancel(restoreWindow: Bool) {
        guard running else { return }
        let win = targetWindow
        stopWatchdog()
        teardownOverlay()
        if restoreWindow, let win, win.isVisible { win.alphaValue = 1 }
        targetWindow = nil
        completion = nil
        running = false
    }

    // MARK: 主流程

    private func play(window: NSWindow, slot: NSRect, opening: Bool,
                      duration: TimeInterval, completion: (() -> Void)?) -> Bool {
        // 总开关：默认开。缺省也当开。
        if UserDefaults.standard.object(forKey: "motion.genie") != nil,
           UserDefaults.standard.bool(forKey: "motion.genie") == false {
            return false
        }
        guard let screen = window.screen ?? NSScreen.main else { return false }

        var shot = Self.snapshot(of: window)
        if shot == nil {
            // 刚 orderFront 的窗口有时还没登记进窗口服务器，抓回来是 nil。
            CATransaction.flush()
            window.displayIfNeeded()
            shot = Self.snapshot(of: window)
        }
        guard let shot else {
            Log.warn("Motion", "genie：窗口快照失败（windowNumber=\(window.windowNumber)），退回缩放动画")
            return false
        }

        if running { cancel(restoreWindow: false) }

        // 展开：快照已经拿到，立刻把真窗藏掉。预渲染帧要几十毫秒，
        // 这期间如果让面板原样挂着，用户会先看到一块完整面板闪一下再开始倒。
        if opening { window.alphaValue = 0 }

        self.targetWindow = window
        self.completion = completion
        self.opening = opening
        // 排障：probe.genieDuration 可把整条动画拉长（例如 3 秒），用来逐帧核对
        let probeDuration = UserDefaults.standard.double(forKey: "probe.genieDuration")
        self.duration = probeDuration > 0 ? probeDuration : GenieWarp.duration(for: duration)
        self.running = true

        let screenFrame = screen.frame
        let wRect = Self.local(window.frame, screen: screenFrame)
        let sRect = Self.local(slot, screen: screenFrame)

        // 覆盖窗只盖「漏斗可能出现的范围」，不盖整屏（整屏每帧要清 760 万像素）
        var bbox = wRect.rect.union(sRect.rect).insetBy(dx: -6, dy: -6)
        bbox = bbox.intersection(CGRect(origin: .zero, size: screenFrame.size))
        if bbox.width < 8 || bbox.height < 8 {
            bbox = CGRect(origin: .zero, size: screenFrame.size)
        }

        let viewWindow = wRect.offsetBy(-bbox.minX, -bbox.minY)
        let viewSlot = sRect.offsetBy(-bbox.minX, -bbox.minY)
        let menuH = screen.frame.maxY - screen.visibleFrame.maxY
        let clipY = max(max(0, menuH - bbox.minY), viewSlot.maxY)

        // 快照是 2x（720 宽），而每一帧画布只有 372×1.2≈446 宽：
        // 每帧都对 720 宽的条带做一次降采样，24~28 帧累计就是一百多毫秒。
        // 先整张降到目标尺寸，之后每帧几乎 1:1 取图，预渲染直接砍掉一半。
        let targetSourceWidth = viewWindow.width * Self.pixelScale(bbox: bbox.size, frames: 1)
        let ratio = shot.width > 0 ? targetSourceWidth / CGFloat(shot.width) : 1
        let renderShot = ratio < 0.95 ? (Self.downscale(shot, ratio: ratio) ?? shot) : shot

        let showsMesh = UserDefaults.standard.bool(forKey: "probe.genieMesh")
        let showsGuides = UserDefaults.standard.bool(forKey: "probe.genieDebug")

        // ---- 预算帧数：60fps 为目标，太多吃内存 ----
        let target = max(12, min(30, Int((self.duration * 60).rounded())))
        let pixelScale = Self.pixelScale(bbox: bbox.size, frames: target)
        let t0 = CFAbsoluteTimeGetCurrent()
        var frames: [CGImage] = []
        frames.reserveCapacity(target)

        let hold = Self.heldProgress()
        if let hold {
            if let one = GenieFrameRenderer.render(
                progress: hold, snapshot: renderShot, windowRect: viewWindow, slotRect: viewSlot,
                clipY: clipY, size: bbox.size, scale: pixelScale,
                showsMesh: showsMesh, showsGuides: showsGuides) {
                frames = [one]
                Log.info("Motion", String(format: "genie 定格在 %.2f（probe.genieHold）", hold))
            }
        } else {
            for i in 0..<target {
                let t = CGFloat(i) / CGFloat(max(1, target - 1))
                let p = opening ? (1 - t) : t     // 展开 1→0，收起 0→1
                guard let img = GenieFrameRenderer.render(
                    progress: p, snapshot: renderShot, windowRect: viewWindow, slotRect: viewSlot,
                    clipY: clipY, size: bbox.size, scale: pixelScale,
                    showsMesh: showsMesh, showsGuides: showsGuides) else { continue }
                frames.append(img)
            }
        }
        let buildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard !frames.isEmpty else {
            Log.warn("Motion", "genie：帧渲染失败，退回缩放动画")
            running = false
            if opening { window.alphaValue = 1 }
            return false
        }

        let overlayFrame = NSRect(x: screenFrame.minX + bbox.minX,
                                  y: screenFrame.maxY - bbox.maxY,
                                  width: bbox.width,
                                  height: bbox.height)
        let panel = GenieOverlayPanel(contentRect: overlayFrame,
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

        let host = NSView(frame: NSRect(origin: .zero, size: bbox.size))
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        panel.contentView = host

        let frameLayer = CALayer()
        frameLayer.frame = CGRect(origin: .zero, size: bbox.size)
        frameLayer.contentsGravity = .resize
        frameLayer.contentsScale = pixelScale
        frameLayer.magnificationFilter = .linear
        frameLayer.minificationFilter = .linear
        frameLayer.isOpaque = false
        frameLayer.contents = frames[0]
        host.layer?.addSublayer(frameLayer)

        panel.orderFrontRegardless()
        overlay = panel

        // 真窗退到幕后：动画期间由覆盖窗上的帧序列代替。
        // 收起时窗口必须保持 isVisible（外部还在用它判断状态），只把 alpha 归零。
        window.alphaValue = 0

        let phases = geniePhases(progress: opening ? 1 : 0, window: viewWindow, icon: viewSlot, edge: .top)
        Log.info("Motion", String(format: "genie %@：窗 %.0f×%.0f 图标 %.0f×%.0f 行程 %.0f 弯 %.0fms 滑 %.0fms 弯完于 %.0f%%",
                                  opening ? "展开" : "收起",
                                  viewWindow.width, viewWindow.height,
                                  viewSlot.width, viewSlot.height,
                                  abs(viewWindow.maxY - viewSlot.midY),
                                  phases.bendLength, phases.slideLength, phases.settled * 100))
        Log.info("Motion", String(format: "genie 预渲染 %d 帧 %.0f×%.0f@%.1fx 耗时 %.0fms",
                                  frames.count, bbox.width, bbox.height, pixelScale, buildMs))

        // 排障：定格模式停在第一张，交给截图核对
        if hold != nil { return true }

        // ---- 交给 Core Animation 逐帧播放（渲染服务器上跑，与主线程解耦）----
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = frames
        anim.keyTimes = (0..<frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        anim.calculationMode = .discrete
        anim.duration = self.duration
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        anim.beginTime = CACurrentMediaTime()
        // 模型值先落终态，动画从第一帧放起；结束后停在终态，不会闪回第一帧
        frameLayer.contents = frames[frames.count - 1]
        frameLayer.add(anim, forKey: "genie.frames")

        // 兜底：动画结束（含被系统打断）后收尾
        let timer = Timer(timeInterval: self.duration + 0.02, repeats: false) { [weak self] _ in
            self?.finish()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        return true
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func finish() {
        guard running else { return }
        stopWatchdog()
        let win = targetWindow
        let done = completion
        let wasOpening = opening
        teardownOverlay()

        if let win, win.isVisible {
            if wasOpening {
                win.alphaValue = 1
            } else {
                // v240（用户：「收纳动画重复播放，还有闪回」）：
                // 收起时**不能**先把 alpha 拉回 1 再 orderOut——那一下窗口会完整
                // 亮回来一帧，看起来就是「吸进去了又闪出来」。直接退场，alpha 留 0，
                // 由 PanelController.show 在下次展开前重置。
                win.orderOut(nil)
            }
        }
        // 快照定格模式（probe.genieHold）不跑 finish，这里不额外处理

        targetWindow = nil
        completion = nil
        running = false
        done?()
    }

    private func teardownOverlay() {
        overlay?.orderOut(nil)
        overlay?.contentView = nil
        overlay = nil
    }

    // MARK: 工具

    /// 帧数固定后按内存预算挑像素倍率：总占用压在 64MB 以内，最高 2x
    private static func pixelScale(bbox: CGSize, frames: Int) -> CGFloat {
        let budget: Double = 64 * 1024 * 1024
        let perFrameAt1x = Double(bbox.width * bbox.height * 4)
        guard perFrameAt1x > 0 else { return 1 }
        let allowed = sqrt(budget / (perFrameAt1x * Double(max(1, frames))))
        return max(1, min(1.25, CGFloat(allowed)))
    }

    /// 整张快照等比降采样（预渲染提速用）
    private static func downscale(_ image: CGImage, ratio: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let h = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func heldProgress() -> CGFloat? {
        guard UserDefaults.standard.object(forKey: "probe.genieHold") != nil else { return nil }
        return CGFloat(UserDefaults.standard.double(forKey: "probe.genieHold"))
    }

    /// 抓窗口快照并按窗口圆角裁出透明边角。
    private static func snapshot(of window: NSWindow) -> CGImage? {
        guard window.windowNumber > 0 else { return nil }
        guard let raw = ScreenSnapshot.legacyCapture(
            rect: .null,
            option: .optionIncludingWindow,
            windowID: CGWindowID(window.windowNumber),
            imageOption: [.boundsIgnoreFraming, .bestResolution]) else { return nil }

        let w = raw.width, h = raw.height
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return raw
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let scale = window.frame.width > 0 ? CGFloat(w) / window.frame.width : 1
        let radius = Theme.Radius.window * scale
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
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
