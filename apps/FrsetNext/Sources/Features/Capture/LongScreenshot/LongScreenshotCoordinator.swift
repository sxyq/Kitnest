import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图采帧流（全局事件监视器）

/// v150 改造（对齐 ScrollSnap）：
///   · **采帧不再由事件驱动**——会话内部 250ms 定时采样；
///   · 滚轮事件只累积「位移提示」，供对齐搜索估算窗口；
///   · 删除 mouseMoved 监视器（旧逻辑「光标必须在选区内才采帧」，手一抖就静默停采）；
///   · **删除全局 Return**——旧实现会在目标 App 里也触发一次 Return（可能提交表单）；
///     完成改为点 HUD 的「完成」按钮（本 App 聚焦时仍支持 Return）。
final class LongScreenshotCaptureStream {

    /// 「首次全局滚动已到达」日志只打一次（诊断全局监视器/授权是否生效）
    private static var loggedFirstScroll = false

    private weak var session: LongScreenshotSession?
    private var scrollMonitor: Any?
    private var globalKeyMonitor: Any?
    /// 本地 keyDown 补充监视器：全局监视器收不到本 App 自身窗口的事件
    private var localKeyMonitor: Any?

    /// 注册监视器
    func start(session: LongScreenshotSession) {
        // v137 BUGFIX：先清旧监视器，再挂新会话（stop() 会把 session 置 nil）
        stop()
        self.session = session

        // ① scrollWheel：仅累积位移提示
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            if !Self.loggedFirstScroll {
                Self.loggedFirstScroll = true
                Log.info("Capture", "长截图：已收到全局滚动事件（全局监视器生效）")
            }
            // scrollingDeltaY > 0 = 向上滚（内容下移）→ 取负，换成「画布向下追加」的符号
            self?.session?.onScroll(deltaY: -Double(event.scrollingDeltaY),
                                    deltaX: -Double(event.scrollingDeltaX))
        }

        // ② 全局 keyDown：只处理 Esc（观察不拦截，目标 App 行为不受影响）
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 0x35 else { return }
            DispatchQueue.main.async { self?.session?.cancel() }
        }
        // ③ 本 App 聚焦时：Esc 取消 / Return 完成（Return 不再全局监听）
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            switch event.keyCode {
            case 0x35:
                DispatchQueue.main.async { self?.session?.cancel() }
                return nil
            case 0x24:
                DispatchQueue.main.async { self?.session?.finish() }
                return nil
            default:
                return event
            }
        }
    }

    /// 注销全部监视器（随会话结束）
    func stop() {
        for monitor in [scrollMonitor, globalKeyMonitor, localKeyMonitor] {
            if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        }
        scrollMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        session = nil
    }

    deinit { stop() }
}

// MARK: - 长截图编排器

/// 长截图编排（原作 LongScreenshotCoordinator，0x10045a1bc 会话启动调用链）：
/// 1) 入口（标注工具条 / CaptureMode.long）→ 选区覆盖层；
/// 2) 选区确认 → 建 Session + 注册监视器；
/// 3) 收尾（finished）→ 预览/编辑器；cancelled / failed → 日志。
final class LongScreenshotCoordinator: NSObject {

    static let shared = LongScreenshotCoordinator()

    private var session: LongScreenshotSession?
    /// v74：采集期 HUD（进度 + 完成/取消）与选区边框
    private var hud: LongScreenshotHUDController?
    /// v176：采集中选区旁的实时预览卡
    private var livePreview: LongScreenshotLivePreviewPanel?
    private var borderWindow: LongScreenshotSelectionBorderWindow?
    private let stream = LongScreenshotCaptureStream()
    /// 选区阶段的覆盖层（复用截图选区交互）
    private var selectionOverlays: [ScreenshotOverlayWindow] = []

    private override init() { super.init() }

    // MARK: 入口一：标注编辑器工具条「长截图」按钮

    /// 有标注时先弹确认框（spec 15 F1，文案键 0x100b4e3b0/0x100b4e3e0/0x100b4e430）
    /// - Returns: true = 继续启动（已确认或无标注）
    static func confirmClearAnnotations(hasAnnotations: Bool) -> Bool {
        guard hasAnnotations else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear annotations and start long screenshot?"
        alert.informativeText = "Existing annotations will be removed."
        alert.addButton(withTitle: "Clear Annotations")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: 入口二：面板 / CaptureMode.long

    /// 进入选区阶段（复用截图覆盖层：每屏一层，框选后启动会话）
    func beginSelection() {
        // v108（用户：「点击之后没有提示开始运行」）：进入框选即给提示
        Toast.show("长截图：请框选要捕获的区域（Esc 取消）",
                   icon: "crop")
        guard session == nil else {
            Log.warn("Capture", "长截图：已有会话进行中，忽略本次框选请求")
            return
        }
        Task { @MainActor in
            // v32：权限以真实抓屏能力为准（preflight 会假阴性）
            // v139：这里**不再因权限判定失败而直接 return**——用户实测「点了没反应」：
            // 权限在启动时已确认获得（日志「屏幕录制权限启动实况：已获得」），但
            // 这一步的探测有时会长时间不返回/返回假阴性，覆盖层就永远不出现。
            // 让覆盖层先出来，真抓不到帧时由会话自己报错。
            let ok = await ScreenshotManager.shared.ensureScreenRecordingPermission()
            Log.info("Capture", "长截图：进入选区阶段（权限检查=\(ok)）")
            self.beginSelectionUI()
        }
    }

    @MainActor
    private func beginSelectionUI() {
        // v139 BUGFIX：原来只 removeAll() 不动窗口——旧覆盖层仍留在最上层，
        // 任何一次鼠标松开/右键都会命中旧层触发 onCancel，把**新建的**覆盖层
        // 一起关掉（实测：创建后 0.2-1s 就被「关闭选区覆盖层（1 屏）」）。
        closeSelectionOverlays()
        NSApp.activate(ignoringOtherApps: true)
        // v161：快照异步获取——macOS 27 上主线程同步调 legacy 抓屏会死锁（与 ⌘1 卡死同根因）
        Task { @MainActor in
            let snapshots = await ScreenshotManager.acquireScreenSnapshots()
            for (screen, snapshot) in snapshots {
                let window = ScreenshotOverlayWindow(screen: screen, snapshot: snapshot)
                window.overlayView.onCommit = { [weak self, weak window] rect in
                    guard let self = self, let window = window else { return }
                    self.commitSelection(rect: rect, window: window)
                }
                window.overlayView.onCancel = { [weak self] in
                    self?.cancelSelection()
                }
                selectionOverlays.append(window)
                // v109：先激活应用——否则首个点击被系统用于激活、拖拽无反应（要第二次）
                NSApp.activate(ignoringOtherApps: true)
                // v139：makeKeyAndOrderFront 在后台（非活跃）状态下会被系统忽略——
                // 用户实测「点长截图没反应」：日志说覆盖层已创建，屏幕上却没有。
                // 改用 orderFrontRegardless（无条件上屏）+ 再尝试设为 key。
                window.orderFrontRegardless()
                window.makeKey()
                Log.info("Capture", "长截图：覆盖层 window frame=\(Int(window.frame.width))×\(Int(window.frame.height)) visible=\(window.isVisible) level=\(window.level.rawValue) appActive=\(NSApp.isActive)")
            }
            if selectionOverlays.isEmpty {
                Log.warn("Capture", "长截图：无法创建选区覆盖层")
            } else {
                Log.info("Capture", "长截图：选区覆盖层已显示（\(selectionOverlays.count) 屏）")
            }
        }
    }

    /// 选区确认：换算全局坐标 → 关覆盖层 → 启动会话
    private func commitSelection(rect: CGRect, window: ScreenshotOverlayWindow) {
        let screenFrame = window.frame
        // 视图内矩形 → AppKit 全局坐标（左下原点）
        let appKit = rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        let screen = window.screen ?? NSScreen.main
        let displayID = screen.flatMap { ScreenSnapshot.displayID(of: $0) } ?? CGMainDisplayID()

        closeSelectionOverlays()

        guard appKit.width >= 8, appKit.height >= 8 else {
            Log.warn("Capture", "长截图：选区过小，已取消")
            return
        }
        startSession(appKit: appKit, displayID: displayID)
    }

    /// v137：复用「上一次正常截图的选区」直接进入长截图（动作工具条「长截图」入口）。
    /// 用户需求：普通截图后那条长条动作栏里，加一个用当前框选区域直接上下滚动长截图的按钮。
    @discardableResult
    func beginFromLastSelection() -> Bool {
        let appKit = ScreenshotManager.shared.lastSelectionAppKit
        guard !appKit.isNull, appKit.width >= 8, appKit.height >= 8 else { return false }
        guard session == nil else { return true }   // 已有会话
        let screen = NSScreen.screens.first { $0.frame.intersects(appKit) } ?? NSScreen.main
        let displayID = screen.flatMap { ScreenSnapshot.displayID(of: $0) } ?? CGMainDisplayID()
        Task { @MainActor in
            guard await ScreenshotManager.shared.ensureScreenRecordingPermission() else { return }
            self.startSession(appKit: appKit, displayID: displayID)
        }
        return true
    }

    /// 建会话 + 监视器 + HUD/边框（选区入口与"复用上次选区"共用）
    private func startSession(appKit: CGRect, displayID: CGDirectDisplayID) {
        // AppKit 全局（左下原点）→ CG 全局（主屏左上原点）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? appKit.height
        let cg = CGRect(x: appKit.minX, y: primaryHeight - appKit.maxY,
                        width: appKit.width, height: appKit.height)

        let session = LongScreenshotSession(selectionRectAppKit: appKit,
                                            selectionRectCG: cg,
                                            displayID: displayID,
                                            windowID: 0)
        session.onFinish = { [weak self, weak session] state, image in
            self?.handleSessionFinished(state: state, image: image,
                                        dropped: session?.droppedContent ?? false)
        }
        // v150：进度 = 画布真实高度 + 是否「没有新内容」（HUD 据此换状态文案）
        session.onProgress = { [weak self] height, status in
            self?.hud?.update(height: height, status: status)
        }
        // v176（用户：「长截图需要预览，像原版一样」）：每追加一段就刷新预览卡
        let preview = LongScreenshotLivePreviewPanel()
        livePreview = preview
        session.onPreview = { [weak preview] image in
            preview?.update(image: image, near: appKit)
        }
        self.session = session
        stream.start(session: session)
        session.start()

        let border = LongScreenshotSelectionBorderWindow(rect: appKit)
        border.orderFrontRegardless()
        borderWindow = border

        let hud = LongScreenshotHUDController()
        hud.onFinish = { [weak session] in session?.finish() }
        hud.onCancel = { [weak session] in session?.cancel() }
        // HUD 避开选区（滚轮向上框选时 HUD 会翻到鼠标上方 → 压进选区 → 每帧截入 HUD）
        hud.show(near: NSEvent.mouseLocation, avoiding: appKit)
        self.hud = hud

        // 不再弹全屏 Toast：它就落在选区中央（用户实测被截进图里），而且 HUD 已经
        // 写着「滚动目标窗口即可，结束后点完成」，同一条信息说两遍只会挡内容。
        Log.info("Capture", "长截图会话已启动（选区 \(Int(appKit.width))×\(Int(appKit.height))）：自适应定时采样（约 \(Int(LongScreenshotSession.samplingInterval(frameHeight: Int(appKit.height)) * 1000))ms），无需光标留在框内；点 HUD「完成」或按 Esc")
    }

    private func cancelSelection() {
        closeSelectionOverlays()
    }

    private func closeSelectionOverlays() {
        let n = selectionOverlays.count
        for window in selectionOverlays { window.orderOut(nil) }
        selectionOverlays.removeAll()
        if n > 0 { Log.warn("Capture", "长截图：关闭选区覆盖层（\(n) 屏）") }
    }

    // MARK: 会话收尾

    private func handleSessionFinished(state: LongScreenshotState, image: CGImage?, dropped: Bool = false) {
        stream.stop()
        session = nil
        // v74：收尾时关闭采集期 HUD 与选区边框
        hud?.close()
        hud = nil
        livePreview?.orderOut(nil)
        livePreview?.close()
        livePreview = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        switch state {
        case .finished:
            guard let image = image else {
                Log.warn("Capture", "长截图收尾：无有效画布")
                Toast.show("长截图失败：没有采到画面（请确认已滚动目标窗口）", icon: "exclamationmark.triangle")
                return
            }
            // v137（用户反馈「点击完成没有正确复制到剪贴板」）：收尾即复制——
            // 与普通截图"完成即可粘贴"的心智一致；编辑器里仍可再复制/保存
            let copied = ScreenshotManager.shared.copyToPasteboard(image)
            LongScreenshotPreviewController.shared.show(image: image)
            if copied {
                if dropped {
                    Toast.show("长截图完成（有一段因滚动过快跳过），已复制到剪贴板", icon: "checkmark.circle.fill")
                } else {
                    Toast.show("长截图完成，已复制到剪贴板", icon: "checkmark.circle.fill")
                }
            }
            Log.info("Capture", "长截图完成：\(image.width)×\(image.height)，\(copied ? "已复制到剪贴板" : "复制失败")\(dropped ? "（有跳过段）" : "")")
        case .cancelled:
            Log.info("Capture", "长截图已取消")
        case .failed:
            Log.error("Capture", "长截图采捕连续失败，会话终止")
            Toast.show("长截图失败：采帧连续失败（多为屏幕录制权限问题）", icon: "exclamationmark.triangle")
        default:
            break
        }
    }

    // MARK: 排障入口（不经过框选，便于无人值守验证 HUD/预览）

    /// 用屏幕中央的固定矩形直接起一次会话（不碰鼠标；配合 finish/cancel 深链使用）
    func beginDemoSession() {
        guard session == nil else { return }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: vf.midX - 300, y: vf.midY - 250, width: 600, height: 500)
        let displayID = NSScreen.main.flatMap { ScreenSnapshot.displayID(of: $0) } ?? CGMainDisplayID()
        startSession(appKit: rect, displayID: displayID)
        Log.info("Capture", "长截图演示会话已启动（排障用，固定选区 600×500）")
    }

    /// 结束当前会话并出图（排障用）
    func finishCurrentSession() {
        session?.finish()
    }

    /// 取消当前会话（排障用）
    func cancelCurrentSession() {
        session?.cancel()
    }

    // MARK: 排障：采集期实时预览卡（v181 复查）

    /// 不用滚鼠标也能验收预览卡：走**真实建会话路径**（startSession 同时建 HUD / 选区边框 / 预览卡），
    /// 之后按真实「追加一段」的节奏把合成画布喂给预览卡，最后自动收尾，验证卡片随之关闭。
    ///
    /// 入口：`kitnest://longshotcard?anchor=right|left|wide`，结果写 /tmp/livecard.txt
    func runLiveCardCheck(anchor: String, growTo: Int = 5200) {
        guard session == nil else {
            Log.warn("Capture", "预览卡自检：已有会话在跑，先结束它")
            return
        }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 600
        let height: CGFloat = 480
        var rect = NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height)
        switch anchor {
        case "right":   // 贴着右边缘 → 右边放不下，必须翻到左侧
            rect.origin.x = vf.maxX - width - 24
        case "wide":    // 几乎占满屏宽 → 左右都放不下，必须移到选区上下方或收起
            rect = NSRect(x: vf.minX + 12, y: vf.midY - height / 2,
                          width: vf.width - 24, height: height)
        default: break  // 屏幕中间 → 正常放右侧
        }
        let displayID = NSScreen.main.flatMap { ScreenSnapshot.displayID(of: $0) } ?? CGMainDisplayID()
        startSession(appKit: rect, displayID: displayID)

        let src = Self.makeLiveCardSource(width: Int(rect.width), height: growTo)
        var report = ["selection = \(Int(rect.width))×\(Int(rect.height)) @ (\(Int(rect.minX)),\(Int(rect.minY))) anchor=\(anchor)"]

        var step = 1
        func feed() {
            guard let panel = self.livePreview, let src else { return }
            let order = [0.28, 0.45, 0.62, 0.80, 1.0]
            if step > order.count {
                // 全部喂完 → 1.6s 后走真实的取消收尾，验证「采集中止时卡片自动关掉」
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    self.cancelCurrentSession()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let still = self.livePreview != nil
                        report.append("after cancel: livePreview=\(still ? "仍在（异常）" : "已释放 ✓")")
                        try? report.joined(separator: "\n").write(toFile: "/tmp/livecard.txt",
                                                                 atomically: true, encoding: .utf8)
                        Log.info("Capture", "预览卡自检完成：\(report.suffix(3).joined(separator: " | "))")
                    }
                }
                return
            }
            let h = max(240, Int(CGFloat(growTo) * order[step - 1]))
            if let img = src.cropping(to: CGRect(x: 0, y: 0, width: src.width, height: h)) {
                panel.update(image: img, near: rect)
                let f = panel.frame
                let overlap = f.intersects(rect)
                report.append("step\(step) 画布 \(img.width)×\(img.height) → card \(Int(f.width))×\(Int(f.height))"
                              + " @ (\(Int(f.minX)),\(Int(f.minY)))"
                              + " 右侧差 \(Int(f.minX - rect.maxX))"
                              + " 重叠=\(overlap && panel.isVisible ? "是（异常）" : "否 ✓")"
                              + " 可见=\(panel.isVisible) 穿透=\(panel.ignoresMouseEvents)"
                              + " sharing=\(panel.sharingType == .none ? "none ✓" : "\(panel.sharingType.rawValue)（会被截进去）")")
            }
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: feed)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            feed()
        }
        _ = width
        Log.info("Capture", "预览卡自检开始（anchor=\(anchor)，选区 \(Int(rect.width))×\(Int(rect.height))）")
    }

    /// 合成一张「像网页」的长图（顶部有标题条，正文是分段色块 + 行号），用于预览卡验收
    private static func makeLiveCardSource(width: Int, height: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.90, alpha: 1).setFill()
        NSRect(x: 0, y: height - 44, width: width, height: 44).fill()
        var y = 64
        var i = 1
        while y < height - 40 {
            NSColor.white.setFill()
            NSRect(x: 18, y: height - y - 56, width: width - 36, height: 56).fill()
            let text = String(format: "%04d  长截图采集期预览 · 追加到这一行", i)
            (text as NSString).draw(at: NSPoint(x: 34, y: height - y - 34),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                 .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1)])
            y += 72
            i += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// 是否有会话进行中（供 UI 状态提示）
    var isRunning: Bool { session?.state.isActive ?? false }
}
