import AppKit

// MARK: - 双击快捷键兼容性提示（复刻原版 Double-tap shortcut compatibility warning 卡片）
//
// 原版实机截图（2026-10-18）：白底圆角卡片、顶部 App 图标、正文两行半、底部蓝色「知道了」按钮，
// 浮在设置窗口之上。原文案取自原版 zh-Hans Localizable.strings 同名键。

private final class DoubleTapTipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DoubleTapTipWindowController {
    static let shared = DoubleTapTipWindowController()

    private var panel: NSPanel?

    private static let message = "当前未开启辅助功能权限。双击快捷键仍可尝试使用；如遇兼容性问题，请在系统设置中开启辅助功能权限，以获得更稳定的体验。"

    func show() {
        if let panel {
            position(panel)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let size = NSSize(width: 340, height: 214)
        let panel = DoubleTapTipPanel(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered,
                                      defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let card = NSView(frame: NSRect(origin: .zero, size: size))
        card.wantsLayer = true
        // v205：统一玻璃底（无边框窗，显式 12pt 圆角）
        card.layer?.backgroundColor = NSColor.clear.cgColor
        card.layer?.cornerRadius = Theme.Radius.window
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.separatorColor.cgColor

        let iconSide: CGFloat = 52
        let icon = NSImageView(frame: NSRect(x: (size.width - iconSide) / 2,
                                            y: size.height - iconSide - 20,
                                            width: iconSide, height: iconSide))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        card.addSubview(icon)

        let label = NSTextField(wrappingLabelWithString: Self.message)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.isSelectable = false
        label.frame = NSRect(x: 26, y: 56, width: size.width - 52, height: 74)
        card.addSubview(label)

        let button = NSButton(title: "知道了", target: self, action: #selector(dismiss))
        button.bezelStyle = .rounded
        button.bezelColor = .controlAccentColor
        button.keyEquivalent = "\r"
        button.frame = NSRect(x: 26, y: 16, width: size.width - 52, height: 30)
        card.addSubview(button)

        panel.contentView = card
        // v205：统一玻璃底（无边框窗，显式 12pt 圆角）
        panel.installUnifiedGlassBackground(cornerRadius: Theme.Radius.window)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        Log.info("DoubleTap", "已显示双击快捷键兼容性提示")
    }

    @objc private func dismiss() {
        panel?.orderOut(nil)
    }

    /// 居中于当前设置窗口（无窗口时居中主屏）
    private func position(_ panel: NSPanel) {
        let target = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame
        guard let target, target.width > 0 else { panel.center(); return }
        let size = panel.frame.size
        let origin = NSPoint(x: target.midX - size.width / 2,
                             y: target.midY - size.height / 2)
        panel.setFrameOrigin(origin)
    }
}
