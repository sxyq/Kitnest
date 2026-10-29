import AppKit
import CoreGraphics

/// 贴在 **scrcpy 外部窗口**底部的控制条（返回 / 桌面 / 多任务）。
///
/// 需求（2026-10-29 用户原话）：「我要的就是在原版的外部窗口上添加这个按钮，
/// 而不是在我们的状态栏」。
///
/// 为什么是「贴附面板」而不是改 scrcpy：
///   scrcpy 4.1 没有可开启的按钮条（`--help` 里只有快捷键 Alt+B/H/S），也不提供插件机制；
///   它是个 SDL 自绘窗口，我们无法往它的窗口里塞子视图。所以用一层 **非激活面板**
///   （`.nonactivatingPanel`，点击不抢 key）浮在它窗口底部，跟随移动/缩放；
///   点击只做一件事：`adb -s <serial> shell input keyevent <code>`。
///
/// 视觉：底部内嵌 10pt、高 40、圆角连续（G2），HUD 毛玻璃；鼠标远离时淡到 35%，
/// 靠近恢复——它盖住的是手机屏幕底部一条，不能一直抢视线。
final class ScrcpyControlBarController {

    static let shared = ScrcpyControlBarController()

    /// 三个导航键（Android keycode：4=BACK / 3=HOME / 187=APP_SWITCH）
    private static let keys: [(symbol: String, code: Int32, tip: String)] = [
        ("chevron.backward", 4, "返回（scrcpy 快捷键 ⌥B）"),
        ("house", 3, "桌面（⌥H）"),
        ("rectangle.on.rectangle", 187, "多任务（⌥S）"),
    ]

    private var panel: NSPanel?
    private var timer: Timer?
    private var serial: String?
    /// 找不到窗口的起始时刻（超过 20s 认为 scrcpy 已退出，停止跟踪）
    private var missingSince: Date?

    private init() {}

    // MARK: - 挂载 / 卸载

    /// scrcpy 启动后调用。`serial` 为空时会在后台用 `adb devices` 兜底解析。
    func attach(serial: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.serial = serial
            self.missingSince = nil
            if self.serial == nil { self.resolveSerialIfNeeded() }
            self.startTracking()
            self.tick()
            Log.info("Transfer", "投屏控制条：已挂载（serial=\(serial ?? "自动")）")
        }
    }

    /// scrcpy 退出时调用
    func detach() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.panel?.orderOut(nil)
            self.panel = nil
            self.serial = nil
            self.missingSince = nil
        }
    }

    private func resolveSerialIfNeeded() {
        ScreenCastEngine.connectedDevices { [weak self] list in
            guard let self, self.serial == nil else { return }
            // 优先无线（含 ":"）：多设备并存时 5555/随机端口那条才是投屏用的
            let pick = list?.first(where: { $0.state == "device" && $0.serial.contains(":") })
                ?? list?.first(where: { $0.state == "device" })
            self.serial = pick?.serial
        }
    }

    // MARK: - 跟踪窗口

    private func startTracking() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            autoreleasepool { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let bounds = Self.scrcpyWindowBounds() else {
            panel?.orderOut(nil)
            if missingSince == nil { missingSince = Date() }
            if let since = missingSince, Date().timeIntervalSince(since) > 20 { detach() }
            return
        }
        missingSince = nil

        let p = panel ?? makePanel()
        let target = Self.barFrame(for: bounds)
        if p.frame != target { p.setFrame(target, display: false) }
        if !p.isVisible { p.orderFrontRegardless() }

        // 鼠标靠近才完全显形：它盖住的是手机屏幕底部。
        // 静止 0.62 而不是 0.35——用户要求「能看到」，太淡等于没有。
        let near = p.frame.insetBy(dx: -24, dy: -70).contains(NSEvent.mouseLocation)
        let want: CGFloat = near ? 1.0 : 0.62
        if abs(p.alphaValue - want) > 0.01 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.Motion.dFast
                p.animator().alphaValue = want
            }
        }
    }

    /// 找到 scrcpy 的窗口（owner 名 "scrcpy"；多开时取面积最大的那个）
    private static func scrcpyWindowBounds() -> CGRect? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: CGRect?
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner.lowercased() == "scrcpy" else { continue }
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let dict = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if r.width < 120 || r.height < 160 { continue }   // 过滤掉辅助/隐藏小窗
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    /// CG 窗口坐标（左上原点）→ 贴在窗口**下沿之外**的 Cocoa 矩形。
    ///
    /// 不做「浮在画面底部」：实测会正好压住手机输入框/键盘区（截图为证），
    /// 用户要的是「首页下面的添加」——放到窗口下沿外面，什么都不遮，且仍跟着窗口走。
    private static func barFrame(for cg: CGRect) -> CGRect {
        // 主屏高度足够：scrcpy 在本机总是开在主屏；多屏时按窗口中心点反查屏幕
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let cocoaBottom = mainH - (cg.origin.y + cg.height)
        let width = min(max(160, cg.width - 24), 176)
        let height: CGFloat = 38
        // 离窗口下沿 6pt；窗口贴着屏幕底时钳到 4pt，宁可轻微压住也不掉出屏幕
        let y = max(cocoaBottom - height - 6, 4)
        return CGRect(x: cg.origin.x + (cg.width - width) / 2, y: y,
                      width: width, height: height)
    }

    // MARK: - 面板与按钮

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true          // 点击不抢 scrcpy 的键盘焦点
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = CastControlBarView(keys: Self.keys) { [weak self] code in
            self?.sendKey(code)
        }
        panel = p
        return p
    }

    private func sendKey(_ keycode: Int32) {
        guard let adb = ScreenCastEngine.findADB() else {
            Toast.show("未找到 adb", icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        let serial = self.serial
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adb)
            p.arguments = (serial.map { ["-s", $0] } ?? []) + ["shell", "input", "keyevent", "\(keycode)"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    Log.warn("Transfer", "控制条：keyevent \(keycode) 失败（status \(p.terminationStatus)）")
                }
            } catch {
                Log.warn("Transfer", "控制条：keyevent \(keycode) 启动失败 \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 控制条视图

private final class CastControlBarView: NSView {

    private let keys: [(symbol: String, code: Int32, tip: String)]
    private let onTap: (Int32) -> Void
    private var buttons: [NSButton] = []

    init(keys: [(symbol: String, code: Int32, tip: String)], onTap: @escaping (Int32) -> Void) {
        self.keys = keys
        self.onTap = onTap
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 19
        layer?.cornerCurve = .continuous          // v156：G2，不许直角混入
        layer?.masksToBounds = true
        // 深色胶囊：HUD 毛玻璃在浅色画面下会变成「白条」，白图标直接看不见（实测）。
        // 固定黑 55% + 细白边，深浅画面上都有对比度。
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        for item in keys {
            let b = NSButton(title: "", target: self, action: #selector(tapped(_:)))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tip)
            b.contentTintColor = NSColor.white.withAlphaComponent(0.95)
            b.tag = Int(item.code)
            b.toolTip = item.tip
            b.setAccessibilityLabel(item.tip)
            addSubview(b)
            buttons.append(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        let bw: CGFloat = 44, bh: CGFloat = 28, gap: CGFloat = 6
        let total = CGFloat(buttons.count) * bw + CGFloat(max(0, buttons.count - 1)) * gap
        var x = (bounds.width - total) / 2
        for b in buttons {
            b.frame = NSRect(x: x, y: (bounds.height - bh) / 2, width: bw, height: bh)
            x += bw + gap
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        onTap(Int32(sender.tag))
    }
}
