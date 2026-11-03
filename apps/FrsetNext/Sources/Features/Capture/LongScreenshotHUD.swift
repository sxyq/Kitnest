import AppKit
import Foundation
import QuartzCore

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
        // v139（用户实测：结果图每帧顶边一条橙线、左右两条竖线）：边框窗必须
        // 不进屏幕捕获——SCK 的 excludingApplications 对 .statusBar 层级的覆盖窗
        // 不生效（实证：帧流帧里一直有边框）。sharingType = .none 是系统级开关，
        // 任何捕获 API 都取不到该窗。
        sharingType = UserDefaults.standard.bool(forKey: "probe.cardCapture") ? .readOnly : .none
        contentView = BorderView(frame: NSRect(origin: .zero, size: rect.size))
    }
}

private final class BorderView: NSView {
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath.continuousRoundedRect(r, radius: 2)
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
    /// v139：`avoiding` = 选区（AppKit 坐标）。HUD 一旦压在选区内，每一帧都会把
    /// HUD 截进去（滚轮向上框选时 HUD 会翻到鼠标上方 → 正好落进选区）。落点与
    /// 选区相交时改放到选区外侧。
    func show(near point: NSPoint, avoiding selection: NSRect? = nil) {
        close()
        let size = NSSize(width: 340, height: 58)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x - size.width / 2,
                             y: point.y - size.height - 20)
        if origin.y < vf.minY + 8 {
            origin.y = min(vf.maxY - size.height - 8, point.y + 20)
        }
        origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
        // 避开选区——优先放选区下方，其次上方，最后退回原落点
        if let sel = selection {
            let guardSel = sel.insetBy(dx: -8, dy: -8)
            func fits(_ o: NSPoint) -> Bool {
                let r = NSRect(origin: o, size: size)
                return r.minY >= vf.minY + 8 && r.maxY <= vf.maxY - 8 && !r.intersects(guardSel)
            }
            if NSRect(origin: origin, size: size).intersects(guardSel) {
                let below = NSPoint(x: origin.x, y: sel.minY - size.height - 14)
                let above = NSPoint(x: origin.x, y: sel.maxY + 14)
                if fits(below) {
                    origin = below
                } else if fits(above) {
                    origin = above
                } else {
                    origin.y = min(vf.maxY - size.height - 8, sel.maxY + 14)
                }
            }
        }
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
        // HUD 不进捕获（它在选区附近，SCK 的 app 级排除对高 level 窗无效）
        p.sharingType = UserDefaults.standard.bool(forKey: "probe.cardCapture") ? .readOnly : .none

        // v181（UI 一致性检查 R2）：不再自拼 NSVisualEffectView。
        // 走 LiquidGlass 工厂 → macOS 26+ 拿到真 NSGlassEffectView，
        // 旧系统无回归；「个性化 → 背景材质：纯色 / 降低透明度」也一并生效。
        let glass = LiquidGlass.makeView(frame: NSRect(origin: .zero, size: size),
                                         cornerRadius: Theme.Radius.window,
                                         material: .popover)

        // 红点（录制中）——呼吸脉冲
        let dot = NSView(frame: NSRect(x: 14, y: (size.height - 8) / 2, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.layer?.cornerCurve = .continuous   // v156: G2（曲率连续）圆角
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = Theme.Motion.caEaseInEaseOut
        dot.layer?.add(pulse, forKey: "recording.pulse")
        glass.addSubview(dot)

        let title = NSTextField(labelWithString: "长截图采集中")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 30, y: 31, width: 150, height: 16)
        glass.addSubview(title)

        // v150：提示改成「怎么做 + 怎么结束」，不再是 "Return 完成"（全局 Return 已移除）
        let status = NSTextField(labelWithString: "慢一点滚（每屏约 2 秒），结束后点「完成」")
        status.font = .systemFont(ofSize: 9.5)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 30, y: 12, width: 215, height: 14)
        glass.addSubview(status)
        statusLabel = status

        // 真实画布高度（像素）——不是旧版的「行当量」
        let rows = NSTextField(labelWithString: "0 px")
        rows.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        rows.alignment = .right
        rows.frame = NSRect(x: 170, y: 27, width: 78, height: 18)
        glass.addSubview(rows)
        rowsLabel = rows

        let done = NSButton(title: "完成", target: self, action: #selector(finishTapped))
        done.bezelStyle = .inline
        done.controlSize = .small
        done.frame = NSRect(x: 252, y: 15, width: 44, height: 24)
        glass.addSubview(done)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .inline
        cancel.controlSize = .small
        cancel.frame = NSRect(x: 298, y: 15, width: 38, height: 24)
        glass.addSubview(cancel)

        p.contentView = glass
        p.orderFrontRegardless()           // 只上屏不抢焦点（否则目标窗口收不到滚动）
        panel = p
        Log.info("Capture", "长截图 HUD 已显示 origin=\(Int(origin.x)),\(Int(origin.y))")
    }

    /// 更新进度：画布真实像素高度 + 采集状态
    func update(height: Int, status: LongScreenshotCaptureStatus) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let text = formatter.string(from: NSNumber(value: height)) ?? "\(height)"
        rowsLabel?.stringValue = "\(text) px"
        switch status {
        case .collecting:
            statusLabel?.stringValue = "正在采集 · 慢点滚更稳"
            statusLabel?.textColor = .secondaryLabelColor
        case .idle:
            statusLabel?.stringValue = "没有新内容（可能已到底）· 点「完成」结束"
            statusLabel?.textColor = .secondaryLabelColor
        case .unstable:
            // 明确「怎么放慢」：给出可执行的速度参考，而不是只说「放慢一点」
            statusLabel?.stringValue = "滚太快没接上 · 每屏约 2 秒"
            statusLabel?.textColor = .systemOrange
        case .lost:
            statusLabel?.stringValue = "有段落没接上 · 后面慢一点"
            statusLabel?.textColor = .systemOrange
        }
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
