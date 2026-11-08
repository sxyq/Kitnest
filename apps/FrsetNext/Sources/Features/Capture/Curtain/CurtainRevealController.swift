import AppKit
import QuartzCore

// MARK: - 图帘 · 顶边悬停唤出（v264，对齐 1Capture 的 HangingShelfRevealController）
//
// 1Capture 的设置文案：`鼠标悬停屏幕顶边时显示：离开后自动收起，保留暂存内容。`
// 我们之前没做，原因写在 v261 的提交里：屏幕顶边是菜单栏，热区放上去会抢菜单栏点击。
//
// 这一版把热区放在**菜单栏下沿（visibleFrame.maxY）往下的 5pt 窄条**：
//   · visibleFrame 已经扣掉菜单栏，所以这 5pt 一定在菜单栏下方；
//   · 条高 5pt，只占「贴着菜单栏划过去」的那一瞬，正常点击菜单栏不受影响；
//   · 只有「图帘总开关 + 悬停唤出」同时开着才创建窗口，关掉立刻销毁。
//
// 收起判定不靠 mouseExited（移进帘子会先触发一次 exited），
// 改成 0.2s 轮询「鼠标是否还在热区或帘子窗口里」，离开 0.8s 后才收。

@MainActor
public final class CurtainRevealController {

    public static let shared = CurtainRevealController()

    /// 热区高度（pt）
    static let stripHeight: CGFloat = 5
    /// 离开后多久收起（秒）
    static let hideDelay: Double = 0.8

    private var strips: [NSWindow] = []
    private var pollTask: Task<Void, Never>?
    private var hideDeadline: Date?
    private var installed = false
    /// 上次安装时的屏幕几何签名（同样的屏幕不重复建窗口，避免启动时装两遍）
    private var installedSignature = ""

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .curtainPreferencesChanged, object: nil)
        // 屏幕布局变化（插拔显示器）后热区要重建
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        sync()
    }

    // MARK: 安装 / 卸载

    /// 按当前偏好安装或拆除热区（偏好变化、屏幕变化、启动时都走它）
    public func sync() {
        let wanted = CurtainPref.enabled && CurtainPref.revealOnHover
        if wanted { install() } else { uninstall() }
    }

    private func install() {
        let signature = NSScreen.screens
            .map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" }
            .joined(separator: "|")
        if installed, signature == installedSignature, !strips.isEmpty { return }
        // 幂等：先拆再建（屏幕数量/分辨率可能变了）
        teardownWindows()
        for screen in NSScreen.screens {
            let vf = screen.visibleFrame
            let frame = NSRect(x: vf.minX,
                               y: vf.maxY - Self.stripHeight,
                               width: vf.width,
                               height: Self.stripHeight)
            let panel = RevealStripPanel(contentRect: frame)
            let view = RevealStripView(frame: NSRect(origin: .zero, size: frame.size))
            view.onEnter = { [weak self] in self?.pointerEntered() }
            panel.contentView = view
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            strips.append(panel)
        }
        installed = true
        installedSignature = signature
        Log.info("Curtain", "顶边悬停唤出：已安装 \(strips.count) 条热区（高 \(Int(Self.stripHeight))pt）")
    }

    private func uninstall() {
        guard installed || !strips.isEmpty else { return }
        teardownWindows()
        stopPolling()
        installed = false
        installedSignature = ""
        Log.info("Curtain", "顶边悬停唤出：已拆除")
    }

    private func teardownWindows() {
        for panel in strips { panel.orderOut(nil) }
        strips.removeAll()
    }

    // MARK: 鼠标进入 / 离开

    private func pointerEntered() {
        guard CurtainPref.enabled, CurtainPref.revealOnHover else { return }
        hideDeadline = nil
        ImageCurtainController.shared.show()
        startPolling()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        hideDeadline = nil
    }

    /// 0.2s 一次：鼠标还在热区或帘子里 → 取消收起；离开超过 0.8s → 收起
    private func tick() {
        guard ImageCurtainController.shared.isShowing else {
            stopPolling()
            return
        }
        let point = NSEvent.mouseLocation
        let inStrip = strips.contains { $0.frame.insetBy(dx: 0, dy: -2).contains(point) }
        let inCurtain = ImageCurtainController.shared.panelFrame.insetBy(dx: -4, dy: -4).contains(point)
        if inStrip || inCurtain {
            hideDeadline = nil
            return
        }
        if let deadline = hideDeadline {
            if Date() >= deadline { hideDeadline = nil; ImageCurtainController.shared.hide() }
        } else {
            hideDeadline = Date().addingTimeInterval(Self.hideDelay)
        }
    }

    // MARK: 通知

    @objc private func preferencesChanged() { sync() }
    @objc private func screensChanged() { sync() }
}

// MARK: - 热区窗口

/// 5pt 高的透明条：不激活、不抢焦点、只收 mouseEntered
private final class RevealStripPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // 菜单栏之下、普通窗口之上即可，不需要 screenSaver 级
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RevealStripView: NSView {
    var onEnter: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    /// 透明视图也要吃掉点击判定之外的事件（否则窗口不会被创建）
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}
