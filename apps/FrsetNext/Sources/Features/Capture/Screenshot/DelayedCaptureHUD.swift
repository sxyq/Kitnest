import AppKit

// v130（SnowShot 对齐）④：延时截图
//
// Snow Shot 支持 N 秒后截图。实现：
//   · 倒计时 HUD：屏幕中央大数字 N→…→1，可 Esc / 右键取消；
//   · 倒计时结束后自动截取鼠标所在全屏（captureFullScreen 同链路）；
//   · 延时秒数由设置项 capture.delaySeconds 控制（3 / 5 / 10）。

/// 延时截图倒计时控制（单实例；同一时刻至多一个倒计时）
final class DelayedCaptureController {
    static let shared = DelayedCaptureController()

    private var hud: DelayedCountdownWindow?
    private var timer: Timer?
    private var keyMonitor: DeleteKeyMonitor?
    private var remaining = 0

    private init() {}

    /// 开始延时截图（秒数到 0 后截全屏；Esc / 右键取消）
    func start(seconds: Int) {
        cancel()   // 已有倒计时先收掉
        let total = max(1, seconds)
        remaining = total
        NSApp.activate(ignoringOtherApps: true)
        let window = DelayedCountdownWindow(screen: currentScreen())
        window.showValue(total)
        window.makeKeyAndOrderFront(nil)
        hud = window
        // Esc（53）/ Delete（51）/ 右键取消
        keyMonitor = DeleteKeyMonitor { [weak self] event in
            guard let self else { return false }
            if event.type == .rightMouseDown || event.keyCode == 53 || event.keyCode == 51 {
                self.cancel(withToast: true)
                return true
            }
            return false
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            if self.remaining <= 0 {
                self.finish()
            } else {
                self.hud?.showValue(self.remaining)
            }
        }
    }

    /// 取消倒计时
    func cancel(withToast: Bool = false) {
        timer?.invalidate()
        timer = nil
        keyMonitor = nil
        hud?.orderOut(nil)
        hud = nil
        if withToast {
            Toast.show("已取消延时截图", icon: "xmark.circle")
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        keyMonitor = nil
        hud?.orderOut(nil)
        hud = nil
        ScreenshotManager.shared.captureFullScreen()
    }

    private func currentScreen() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first!
    }
}

// MARK: - 倒计时 HUD 窗口

/// 屏幕中央大数字倒计时（borderless 置顶；点击/Esc 由控制器接管）
final class DelayedCountdownWindow: NSWindow {
    private let label = NSTextField(labelWithString: "")

    init(screen: NSScreen) {
        // 小窗居中即可（「屏幕中央大数字」），不铺满全屏避免遮挡操作
        let size = NSSize(width: 160, height: 160)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 24
        container.layer?.cornerCurve = .continuous   // v156: G2（曲率连续）圆角
        // v205：全界面统一玻璃（此处是深色玻璃罩，保留白色大数字的可读性）
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.48).cgColor

        label.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 88, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.autoresizingMask = [.width, .height]

        let hint = NSTextField(labelWithString: "Esc 取消")
        hint.frame = NSRect(x: 0, y: 14, width: size.width, height: 16)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        hint.alignment = .center
        hint.autoresizingMask = [.width, .maxYMargin]

        container.addSubview(label)
        container.addSubview(hint)
        contentView = container
        // v205：倒计时 HUD 也铺统一玻璃底（无边框窗，显式 24pt 圆角）
        installUnifiedGlassBackground(cornerRadius: 24)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func showValue(_ value: Int) {
        label.stringValue = "\(value)"
    }
}
