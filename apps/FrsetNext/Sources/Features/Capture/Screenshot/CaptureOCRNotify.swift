import AppKit
import SwiftUI

// MARK: - 静默识别（v264 · 1Capture 的 OCR 通知模式）
//
// 原来的行为：识别完必弹一个结果窗，连续识别十张就叠十个窗。
// 1Capture 的做法是「只弹通知、不弹窗」，通知时长可配。
// 这里落成一个**不抢焦点**的小面板：一行原文预览 + 「已复制」，
// N 秒后自己淡出。要细看/翻译仍然可以点面板打开完整结果窗。

public enum CaptureOCRNotify {

    static let keySilent = "capture.ocr.silent"
    static let keySeconds = "capture.ocr.notifySeconds"

    /// 静默识别：只提示、不弹结果窗（默认关，保持既有习惯）
    public static var isSilent: Bool {
        get { Preferences.shared.value(keySilent, default: false) }
        set { Preferences.shared.set(keySilent, newValue) }
    }

    /// 提示停留秒数（2–12）
    public static var seconds: Int {
        get { Preferences.shared.value(keySeconds, default: 4) }
        set { Preferences.shared.set(keySeconds, max(2, min(12, newValue))) }
    }

    /// 展示一条静默提示（文本已复制到剪贴板）
    @MainActor
    public static func show(text: String) {
        OCRNotePanel.shared.show(text: text, seconds: seconds)
    }
}

// MARK: - 提示面板

@MainActor
final class OCRNotePanel: NSPanel {

    static let shared = OCRNotePanel()

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 54),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(5)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.9).cgColor
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous

        icon.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        icon.contentTintColor = .white
        icon.frame = NSRect(x: 14, y: 18, width: 18, height: 18)
        host.addSubview(icon)

        label.textColor = .white
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 40, y: 18, width: 264, height: 18)
        host.addSubview(label)

        let sub = NSTextField(labelWithString: "已复制到剪贴板")
        sub.textColor = NSColor(calibratedWhite: 1, alpha: 0.55)
        sub.font = .systemFont(ofSize: 10)
        sub.frame = NSRect(x: 40, y: 8, width: 264, height: 12)
        host.addSubview(sub)

        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(text: String, seconds: Int) {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        label.stringValue = flat.isEmpty ? "（没有识别到文字）" : flat

        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = NSSize(width: 320, height: 54)
        setContentSize(size)
        setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 16))

        hideTask?.cancel()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(2, seconds)) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            animator().alphaValue = 0
        } completionHandler: {
            self.orderOut(nil)
            self.alphaValue = 1
        }
    }
}
