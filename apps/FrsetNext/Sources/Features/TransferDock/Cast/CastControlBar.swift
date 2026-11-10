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
        ("chevron.backward", 4, "返回（⌥B）"),
        ("house", 3, "桌面（⌥H）"),
        ("rectangle.on.rectangle", 187, "多任务（⌥S）"),
    ]

    private var panel: NSPanel?
    private var timer: Timer?
    private var serial: String?
    /// 上次成功找到的 scrcpy 进程 pid（用于判断它是否还活着）
    private var scrcpyPID: pid_t?

    private init() {}

    // MARK: - 挂载 / 卸载

    /// 控制条只跟随实际启动的进程及目标设备。
    func attach(serial: String?, processID: pid_t) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.serial = serial
            self.scrcpyPID = processID
            self.startTracking()
            self.tick()
            Log.info("Transfer", "投屏控制条：已挂载（serial=\(serial ?? "自动")）")
        }
    }

    /// 页面重建或 App 重启后，按运行进程的实际 --serial 恢复设备绑定。
    func attachIfScrcpyRunning() {
        if let pid = scrcpyPID, kill(pid, 0) == 0 {
            startTracking()
            tick()
            return
        }
        guard let window = Self.scrcpyWindow() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-p", "\(window.pid)", "-o", "args="]
            let pipe = Pipe()
            task.standardOutput = pipe
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let args = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            guard task.terminationStatus == 0,
                  let index = args.firstIndex(of: "--serial"), index + 1 < args.count else { return }
            let serial = String(args[index + 1])
            DispatchQueue.main.async {
                guard self.scrcpyPID == nil else { return }
                self.attach(serial: serial, processID: window.pid)
            }
        }
    }

    func isAttached(to processID: pid_t) -> Bool { scrcpyPID == processID }

    /// scrcpy 退出时调用
    func detach() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        serial = nil
        scrcpyPID = nil
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
        guard let pid = scrcpyPID, let win = Self.scrcpyWindow(processID: pid) else {
            panel?.orderOut(nil)
            // v166.1：**不能因为「这一会儿没找到窗口」就停跟踪** —— 用户切到别的 Space、
            // 或窗口被完全遮住时都会查不到；以前 20s 后 detach，切回来条就再也不出现。
            // 现在只按「scrcpy 进程是否还活着」决定收工。
            if let pid = scrcpyPID, kill(pid, 0) != 0 {
                Log.info("Transfer", "投屏控制条：投屏窗口已退出，摘除")
                detach()
            }
            return
        }
        scrcpyPID = win.pid

        // v166.1（用户反馈）：不能浮在所有窗口最上面，要和 scrcpy 窗口**同级**。
        // 做法：面板降到 .normal，并且每帧把自己插到 scrcpy 窗口的**正上方**。
        // 这样它的 z 序永远紧贴 scrcpy：别的窗口盖住 scrcpy 时，也一定会盖住它；
        // 而 scrcpy 只是失去焦点、仍可见时，它不会无故消失。
        // （不用「前台 App 判断」——那会让后台可见的 scrcpy 丢失控制条。）
        let p = panel ?? makePanel()
        let target = Self.barFrame(for: win.bounds)
        if p.frame != target { p.setFrame(target, display: false) }
        p.order(.above, relativeTo: win.number)

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

    /// 兼容两种进程名：改名后的「Kitnest 投屏」与旧版直接跑的 `scrcpy`
    private static func isCastOwner(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == ScreenCastEngine.castAppName.lowercased() || n == "scrcpy"
    }

    /// 找到指定进程的投屏窗口
    /// 返回窗口矩形、窗口号（用于同级排序）、进程 pid（用于判定前台）
    ///
    /// v166.1：**不能只用 `.optionOnScreenOnly`** —— 实测它会间歇性把 scrcpy 窗口
    /// 判成「不在屏」（同一时刻截图里明明可见），导致控制条被误收起。
    /// 改成取全量列表，再用 `kCGWindowIsOnscreen` + alpha 自己判定。
    private static func scrcpyWindow(processID: pid_t? = nil) -> (bounds: CGRect, number: Int, pid: pid_t)? {
        let opts: CGWindowListOption = [.excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: (CGRect, Int, pid_t)?
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  Self.isCastOwner(owner) else { continue }
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { continue }
            guard let dict = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if r.width < 120 || r.height < 160 { continue }   // 过滤掉辅助/隐藏小窗
            guard (w[kCGWindowIsOnscreen as String] as? Bool) ?? false else { continue }
            let num = w[kCGWindowNumber as String] as? Int ?? 0
            let pid = pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0)
            if let processID, pid != processID { continue }
            if best == nil || r.width * r.height > best!.0.width * best!.0.height {
                best = (r, num, pid)
            }
        }
        // 没有「确实在屏」的窗口（最小化/隐藏）→ 返回 nil，让控制条收起
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
        // v166.1：普通层级 + 靠 order(.above, relativeTo: scrcpy 窗口) 贴住它。
        // 用 .floating 会永远压在所有窗口上面（用户实测反馈）。
        p.level = .normal
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
