import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 录屏输入采集（显示按键 / 点击动画的数据源）
//
// 为什么要 CGEventTap 而不是 NSEvent 本地监听：录屏时用户在**别的 App**里操作，
// 本 App 收不到任何 NSEvent。CGEventTap 的 listenOnly 模式能拿到全局键鼠事件，
// 但它属于「输入监控 / 辅助功能」权限，没授权时创建会失败——这里全部降级：
//   · tap 建不起来 → 两个功能静默关闭，只写一条日志，不影响录制；
//   · 授权状态用 AXIsProcessTrusted() 判（不弹窗、不申请，避免录屏时被打断）。

public struct RecordedKey: Sendable {
    public let text: String
    public let time: CFTimeInterval
}

public struct RecordedClick: Sendable {
    /// 全局坐标（CG 坐标系：主屏左上原点）
    public let point: CGPoint
    public let time: CFTimeInterval
    public let isRight: Bool
}

public final class RecordingInputMonitor {

    public static let shared = RecordingInputMonitor()

    private let lock = NSLock()
    private var keys: [RecordedKey] = []
    private var clicks: [RecordedClick] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var thread: Thread?
    private var running = false

    /// 事件保留时长：按键 1.6s（够看清），点击 0.65s（一圈扩散）
    static let keyTTL: CFTimeInterval = 1.6
    static let clickTTL: CFTimeInterval = 0.65

    private init() {}

    // MARK: 生命周期

    /// 开始采集（幂等）。返回是否真的可用（false = 没权限 / 建 tap 失败）
    @discardableResult
    public func start() -> Bool {
        if running { return true }
        guard AXIsProcessTrusted() else {
            Log.warn("Recording", "输入采集不可用：没有辅助功能/输入监控权限（按键与点击叠加将关闭）")
            return false
        }
        running = true
        let t = Thread { [weak self] in self?.runTap() }
        t.name = "kitnest.recording.input"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
        // 线程起来需要一点时间；tap 创建失败会在 runTap 里把 running 置 false
        Thread.sleep(forTimeInterval: 0.05)
        return running
    }

    public func stop() {
        running = false
        if let loop = tapRunLoop {
            if let source = runLoopSource { CFRunLoopRemoveSource(loop, source, .commonModes) }
            CFRunLoopStop(loop)
            tapRunLoop = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        lock.lock(); keys.removeAll(); clicks.removeAll(); lock.unlock()
    }

    /// 清空历史（开始录制时调用，避免把录制前的按键带进去）
    public func reset() {
        lock.lock(); keys.removeAll(); clicks.removeAll(); lock.unlock()
    }

    // MARK: 读取

    public func currentKeys(now: CFTimeInterval) -> [RecordedKey] {
        lock.lock(); defer { lock.unlock() }
        keys.removeAll { now - $0.time > Self.keyTTL }
        return keys
    }

    public func currentClicks(now: CFTimeInterval) -> [RecordedClick] {
        lock.lock(); defer { lock.unlock() }
        clicks.removeAll { now - $0.time > Self.clickTTL }
        return clicks
    }

    /// 鼠标当前位置（CG 全局坐标）
    public static func cursorPoint() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryH - p.y)
    }

    /// 排障注入：伪造一组按键与点击，用来验证「合成路径」本身。
    /// 不依赖辅助功能权限——没权限时 CGEventTap 起不来，但合成/写盘仍要能验收。
    public func injectProbeEvents() {
        let now = CACurrentMediaTime()
        lock.lock()
        keys = [RecordedKey(text: "⌘", time: now),
                RecordedKey(text: "⇧", time: now),
                RecordedKey(text: "K", time: now)]
        clicks = [RecordedClick(point: Self.cursorPoint(), time: now, isRight: false)]
        lock.unlock()
    }

    // MARK: tap

    private func runTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<RecordingInputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask),
                                           callback: callback,
                                           userInfo: refcon) else {
            Log.warn("Recording", "CGEventTap 创建失败（输入监控权限未授予）")
            running = false
            return
        }
        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        guard let source = runLoopSource else { running = false; return }
        tapRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        Log.info("Recording", "输入采集已启动（显示按键 / 点击动画）")
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = CACurrentMediaTime()
        switch type {
        case .keyDown:
            let text = Self.describe(event: event)
            guard !text.isEmpty else { return }
            lock.lock()
            // 按住不放会重复 keyDown：同一键 0.08s 内只记一次
            if let last = keys.last, last.text == text, now - last.time < 0.08 {
                lock.unlock()
                return
            }
            keys.append(RecordedKey(text: text, time: now))
            if keys.count > 6 { keys.removeFirst(keys.count - 6) }
            lock.unlock()
        case .leftMouseDown, .rightMouseDown:
            let p = event.location
            lock.lock()
            clicks.append(RecordedClick(point: p, time: now, isRight: type == .rightMouseDown))
            if clicks.count > 12 { clicks.removeFirst(clicks.count - 12) }
            lock.unlock()
        default:
            break
        }
    }

    /// CGEvent → 可显示的键名（⌘⇧A / Space / ↩ / → …）
    static func describe(event: CGEvent) -> String {
        let flags = event.flags
        var mods = ""
        if flags.contains(.maskControl)   { mods += "⌃" }
        if flags.contains(.maskAlternate) { mods += "⌥" }
        if flags.contains(.maskShift)     { mods += "⇧" }
        if flags.contains(.maskCommand)   { mods += "⌘" }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let special = specialKey(code) { return mods + special }
        guard let ns = NSEvent(cgEvent: event),
              let chars = ns.charactersIgnoringModifiers, !chars.isEmpty else {
            return mods
        }
        // 控制字符（⌃A 之类）不显示成乱码
        if let scalar = chars.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7F {
            return mods
        }
        return mods + chars.uppercased()
    }

    private static func specialKey(_ code: Int) -> String? {
        switch code {
        case 36:  return "↩"
        case 48:  return "⇥"
        case 49:  return "Space"
        case 51:  return "⌫"
        case 53:  return "Esc"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PgUp"
        case 121: return "PgDn"
        default:  return nil
        }
    }
}
