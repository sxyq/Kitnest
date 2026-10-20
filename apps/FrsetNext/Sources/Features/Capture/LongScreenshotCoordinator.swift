import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图采帧流（全局事件监视器三件套）

/// 事件监视器组（spec 15 §3①，选择器经 stub 0x100944920 实证）：
/// | 掩码        | 事件                    | 处理                       |
/// | 0x400000    | scrollWheel             | Δ 过滤+累积+去抖调度        |
/// | 0xe0        | mouseMoved+左右拖拽     | 光标在选区内→调度捕获       |
/// | 0x400       | keyDown                 | keyCode 0x35(Esc)→主队列取消|
/// 全局监视器**只观察不拦截**——与被动采捕模型自洽（原作不合成任何滚轮/键盘事件）。
final class LongScreenshotCaptureStream {

    /// 「首次全局滚动已到达」日志只打一次（诊断全局监视器/授权是否生效）
    private static var loggedFirstScroll = false

    private weak var session: LongScreenshotSession?
    private var scrollMonitor: Any?
    private var mouseMonitor: Any?
    private var globalKeyMonitor: Any?
    /// 本地 keyDown 补充监视器：全局监视器收不到本 App 自身窗口的事件
    /// （如 Esc 时焦点在本 App），与原作「全局 Esc 取消」语义互补。
    private var localKeyMonitor: Any?

    /// 注册三个全局监视器
    func start(session: LongScreenshotSession) {
        self.session = session
        stop()

        // ① scrollWheel（掩码 0x400000，注册点 0x100445e98）
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            // 诊断（首次）：确认全局监视器确实收到事件——macOS 的全局 scrollWheel
            // 监视需要「输入监控/辅助功能」授权，未授权时**静默失效**（回调不触发）。
            // 这行日志是「长截图滚动没反应」类问题的第一判据。
            if !Self.loggedFirstScroll {
                Self.loggedFirstScroll = true
                Log.info("Capture", "长截图：已收到全局滚动事件（全局监视器生效）")
            }
            self?.session?.onScroll(deltaY: Double(event.scrollingDeltaY),
                                    deltaX: Double(event.scrollingDeltaX),
                                    cursorInSelection: self?.cursorInSelection() ?? false)
        }

        // ② mouseMoved + 左右拖拽（掩码 0xe0，注册点 0x10045aa14）
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.session?.onMouseActivity(cursorInSelection: self?.cursorInSelection() ?? false)
        }

        // ③ keyDown（掩码 0x400，注册点 0x10045b1cc；keyCode 0x35=Esc → 主队列取消 0x10045b494）
        //    2026-10-18：全局监视器同时处理 Return（0x24）收尾——长截图的滚动目标是
        //    别的 App（浏览器/文档），此时本 App 未激活，**local monitor 收不到 Return**，
        //    用户无法完成截图（此前只能 Esc 取消）。全局监视器只观察不拦截，
        //    目标 App 的 Return 行为不受影响。
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            switch event.keyCode {
            case 0x35:   // Esc → 取消
                DispatchQueue.main.async { self?.session?.cancel() }
            case 0x24:   // Return → 完成（长截图在别的窗口滚动时的收尾路径）
                DispatchQueue.main.async { self?.session?.finish() }
            default:
                break
            }
        }
        // 补充：本 App 活动时的 Esc / Return（0x24 完成，重建扩展——原作自动收尾逻辑未探明）
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            switch event.keyCode {
            case 0x35:  // Esc
                DispatchQueue.main.async { self?.session?.cancel() }
                return nil
            case 0x24:  // Return：手动收尾（对应原作 flags/到底收尾的替代路径）
                DispatchQueue.main.async { self?.session?.finish() }
                return nil
            default:
                return event
            }
        }
    }

    /// 注销全部监视器（随会话结束）
    func stop() {
        for monitor in [scrollMonitor, mouseMonitor, globalKeyMonitor, localKeyMonitor] {
            if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        }
        scrollMonitor = nil
        mouseMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        session = nil
    }

    deinit { stop() }

    /// 光标（AppKit 全局坐标）是否在选区内（NSEvent.mouseLocation + CGRectContainsPoint）
    private func cursorInSelection() -> Bool {
        guard let session = session else { return false }
        return session.containsCursor(NSEvent.mouseLocation)
    }
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
        guard session == nil else { return }   // 已有会话进行中
        Task { @MainActor in
            // v32：权限以真实抓屏能力为准（preflight 会假阴性）
            guard await ScreenshotManager.shared.ensureScreenRecordingPermission() else { return }
            self.beginSelectionUI()
        }
    }

    @MainActor
    private func beginSelectionUI() {
        selectionOverlays.removeAll()
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let snapshot = ScreenSnapshot.cgCapture(screen: screen)
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
            window.makeKeyAndOrderFront(nil)
        }
        if selectionOverlays.isEmpty {
            Log.warn("Capture", "长截图：无法创建选区覆盖层")
        }
    }

    /// 选区确认：换算全局坐标 → 关覆盖层 → 启动会话
    private func commitSelection(rect: CGRect, window: ScreenshotOverlayWindow) {
        let screenFrame = window.frame
        // 视图内矩形 → AppKit 全局坐标（左下原点）
        let appKit = rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        // AppKit → CG 全局坐标（主屏左上原点，Y 向下；对齐 ScreenSnapshot.cgRect 的换算）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        let cg = CGRect(x: appKit.minX, y: primaryHeight - appKit.maxY,
                        width: appKit.width, height: appKit.height)
        let screen = window.screen ?? NSScreen.main
        let displayID = screen.flatMap { ScreenSnapshot.displayID(of: $0) } ?? CGMainDisplayID()

        closeSelectionOverlays()

        guard appKit.width >= 8, appKit.height >= 8 else {
            Log.warn("Capture", "长截图：选区过小，已取消")
            return
        }

        let session = LongScreenshotSession(selectionRectAppKit: appKit,
                                            selectionRectCG: cg,
                                            displayID: displayID,
                                            windowID: 0)
        session.onFinish = { [weak self] state, image in
            self?.handleSessionFinished(state: state, image: image)
        }
        // v74（用户反馈「框选后没有 UI」）：采集期 HUD + 选区边框
        session.onProgress = { [weak self] rows in
            self?.hud?.update(rows: rows)
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
        hud.show(near: NSEvent.mouseLocation)
        self.hud = hud

        Toast.show("长截图：向任意方向滚动目标窗口，Return 完成 / Esc 取消", icon: "arrow.up.and.down.text.horizontal")
        Log.info("Capture", "长截图会话已启动（选区 \(Int(appKit.width))×\(Int(appKit.height))）：二维拼接（横/竖/斜向滚动均可），Return 完成 / Esc 取消")
    }

    private func cancelSelection() {
        closeSelectionOverlays()
    }

    private func closeSelectionOverlays() {
        for window in selectionOverlays { window.orderOut(nil) }
        selectionOverlays.removeAll()
    }

    // MARK: 会话收尾

    private func handleSessionFinished(state: LongScreenshotState, image: CGImage?) {
        stream.stop()
        session = nil
        // v74：收尾时关闭采集期 HUD 与选区边框
        hud?.close()
        hud = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        switch state {
        case .finished:
            guard let image = image else {
                Log.warn("Capture", "长截图收尾：无有效画布")
                Toast.show("长截图失败：没有采到画面（请确认已滚动目标窗口）", icon: "exclamationmark.triangle")
                return
            }
            LongScreenshotPreviewController.shared.show(image: image)
            Toast.show("长截图完成", icon: "checkmark.circle.fill")
            Log.info("Capture", "长截图完成：\(image.width)×\(image.height)")
        case .cancelled:
            Log.info("Capture", "长截图已取消")
        case .failed:
            Log.error("Capture", "长截图采捕连续失败，会话终止")
            Toast.show("长截图失败：采帧连续失败（多为屏幕录制权限问题）", icon: "exclamationmark.triangle")
        default:
            break
        }
    }

    /// 是否有会话进行中（供 UI 状态提示）
    var isRunning: Bool { session?.state.isActive ?? false }
}
