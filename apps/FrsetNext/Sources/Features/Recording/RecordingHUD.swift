import AppKit

// MARK: - 录制控制条（v264）
//
// 一条一直浮在屏幕顶部的小胶囊：红点 + 计时 + 暂停 + 停止。
// `sharingType = .none` 让**它自己不会出现在录出来的视频里**（NSWindow 原生能力），
// 否则每段录屏顶部都会挂着一个计时器。

@MainActor
final class RecordingHUDController {

    static let shared = RecordingHUDController()

    private var panel: NSPanel?
    private var timeLabel: NSTextField?
    private var pauseButton: NSButton?
    private var dot: NSView?

    private init() {}

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        refresh()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func refresh() {
        guard let panel, let timeLabel else { return }
        let recorder = ScreenRecorder.shared
        timeLabel.stringValue = recorder.elapsedText
        pauseButton?.image = NSImage(systemSymbolName: recorder.state == .paused ? "play.fill" : "pause.fill",
                                     accessibilityDescription: nil)
        dot?.layer?.backgroundColor = (recorder.state == .paused
                                       ? NSColor.systemOrange
                                       : NSColor.systemRed).cgColor
        // 跟着鼠标所在屏幕走
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2,
                                         y: vf.maxY - panel.frame.height - 12))
        }
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 190, height: 40)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(6)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 关键：录屏里不出现控制条
        panel.sharingType = .none

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.92).cgColor
        host.layer?.cornerRadius = 20
        host.layer?.cornerCurve = .continuous
        host.layer?.borderWidth = 0.5
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let dot = NSView(frame: NSRect(x: 16, y: 17, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        host.addSubview(dot)
        self.dot = dot

        let label = NSTextField(labelWithString: "00:00")
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 30, y: 11, width: 62, height: 18)
        host.addSubview(label)
        timeLabel = label

        let pause = iconButton("pause.fill", action: #selector(togglePause), x: 104)
        host.addSubview(pause)
        pauseButton = pause

        let stop = iconButton("stop.fill", action: #selector(stopRecording), x: 142)
        stop.contentTintColor = .systemRed
        host.addSubview(stop)

        panel.contentView = host
        return panel
    }

    private func iconButton(_ symbol: String, action: Selector, x: CGFloat) -> NSButton {
        let button = NSButton(frame: NSRect(x: x, y: 8, width: 24, height: 24))
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.contentTintColor = .white
        button.target = self
        button.action = action
        return button
    }

    @objc private func togglePause() {
        ScreenRecorder.shared.togglePause()
        refresh()
    }

    @objc private func stopRecording() {
        Task { await ScreenRecorder.shared.stop() }
    }
}

// MARK: - 区域选择（复用截图覆盖层）

@MainActor
final class RecordingRegionPicker {

    static let shared = RecordingRegionPicker()

    private var overlays: [ScreenshotOverlayWindow] = []
    private var completion: ((CGRect) -> Void)?

    private init() {}

    func pick(completion: @escaping (CGRect) -> Void) {
        Task { @MainActor in
            guard await ScreenshotManager.shared.ensureScreenRecordingPermission() else { return }
            self.overlays.forEach { $0.orderOut(nil) }
            self.overlays.removeAll()
            self.completion = completion
            let snapshots = await ScreenshotManager.acquireScreenSnapshots()
            for (screen, snapshot) in snapshots {
                let window = ScreenshotOverlayWindow(screen: screen, snapshot: snapshot)
                window.overlayView.onCommit = { [weak self, weak window] rect in
                    guard let self, let window else { return }
                    let global = rect.offsetBy(dx: window.frame.origin.x, dy: window.frame.origin.y)
                    self.finish(global)
                }
                window.overlayView.onCancel = { [weak self] in self?.finish(nil) }
                self.overlays.append(window)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func finish(_ rect: CGRect?) {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        guard let rect, rect.width > 8, rect.height > 8 else {
            completion = nil
            return
        }
        let callback = completion
        completion = nil
        callback?(rect)
    }
}
