import AppKit
import Foundation

// MARK: - 长截图采集期 HUD（v74，2026-10-19 用户反馈「框选后没有 UI」）
//
// 原实现：框选确认 → 关闭选区覆盖层 → 只剩一条 Toast；滚动采集中没有任何
// 持续可见的界面（选区边界消失、无进度、无完成/取消按钮），用户不知道
// 是否在录、录了多少。本文件补两件东西：
//   ① LongScreenshotSelectionBorderWindow：选区虚线边框（点击穿透，不挡操作）
//   ② LongScreenshotHUDController：浮在选区下方的小毛玻璃条（红点 + 已采高度
//      + 完成/取消按钮），材质与主面板/监测面板同为 .popover 玻璃。

// MARK: - 选区边框窗口

final class LongScreenshotSelectionBorderWindow: NSWindow {
    init(rect: NSRect) {
        super.init(contentRect: rect,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        ignoresMouseEvents = true          // 点击穿透：不挡用户滚动目标窗口
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = BorderView(frame: NSRect(origin: .zero, size: rect.size))
    }
}

private final class BorderView: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        path.lineWidth = 1.5
        NSColor(srgbRed: 0.95, green: 0.60, blue: 0.30, alpha: 0.95).setStroke()
        path.stroke()
        // 四角标记（让边界在复杂背景上仍可辨认）
        let corner: CGFloat = 10
        let cpath = NSBezierPath()
        let pts: [(NSPoint, NSPoint, NSPoint)] = [
            (NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY - corner), NSPoint(x: r.minX + corner, y: r.maxY)),
            (NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY - corner), NSPoint(x: r.maxX - corner, y: r.maxY)),
            (NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.minX, y: r.minY + corner), NSPoint(x: r.minX + corner, y: r.minY)),
            (NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.minY + corner), NSPoint(x: r.maxX - corner, y: r.minY)),
        ]
        for (a, b, c) in pts {
            cpath.move(to: a); cpath.line(to: b)
            cpath.move(to: a); cpath.line(to: c)
        }
        cpath.lineWidth = 3
        NSColor(srgbRed: 0.95, green: 0.60, blue: 0.30, alpha: 1).setStroke()
        cpath.stroke()
    }
}

// MARK: - 采集 HUD

final class LongScreenshotHUDController {
    private var panel: NSPanel?
    private var rowsLabel: NSTextField?
    private var statusLabel: NSTextField?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    /// 在鼠标（框选结束点）附近显示 HUD——用鼠标坐标避免覆盖层视图/窗口坐标系歧义，
    /// 并 clamp 到屏幕可视区（左下原点：优先放在鼠标下方，贴底则翻到上方）。
    func show(near point: NSPoint) {
        close()
        let size = NSSize(width: 320, height: 56)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x - size.width / 2,
                             y: point.y - size.height - 20)
        if origin.y < vf.minY + 8 {
            origin.y = min(vf.maxY - size.height - 8, point.y + 20)
        }
        origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false

        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 12
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true

        // 红点（录制中）
        let dot = NSView(frame: NSRect(x: 14, y: (size.height - 8) / 2, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        glass.addSubview(dot)

        let title = NSTextField(labelWithString: "长截图采集中")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 30, y: 30, width: 130, height: 16)
        glass.addSubview(title)

        let status = NSTextField(labelWithString: "滚动目标窗口 · Return 完成 / Esc 取消")
        status.font = .systemFont(ofSize: 9.5)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 30, y: 12, width: 190, height: 14)
        glass.addSubview(status)
        statusLabel = status

        let rows = NSTextField(labelWithString: "0 px")
        rows.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        rows.alignment = .right
        rows.frame = NSRect(x: 150, y: 26, width: 66, height: 18)
        glass.addSubview(rows)
        rowsLabel = rows

        let done = NSButton(title: "完成", target: self, action: #selector(finishTapped))
        done.bezelStyle = .inline
        done.controlSize = .small
        done.frame = NSRect(x: 226, y: 16, width: 44, height: 24)
        glass.addSubview(done)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .inline
        cancel.controlSize = .small
        cancel.frame = NSRect(x: 272, y: 16, width: 40, height: 24)
        glass.addSubview(cancel)

        p.contentView = glass
        p.orderFrontRegardless()           // 只上屏不抢焦点（否则目标窗口收不到滚动）
        panel = p
        Log.info("Capture", "长截图 HUD 已显示 origin=\(Int(origin.x)),\(Int(origin.y))")
    }

    func update(rows: Int) {
        rowsLabel?.stringValue = "\(rows) px"
    }

    func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        rowsLabel = nil
        statusLabel = nil
    }

    @objc private func finishTapped() { onFinish?() }
    @objc private func cancelTapped() { onCancel?() }
}
