import CoreGraphics
import Foundation

// MARK: - CGEventTap 上下文（C 回调无法捕获 Swift 闭包，只能通过 userInfo 传递）

/// 事件回调上下文：承载 Swift 侧的回调闭包
final class EventTapContext {
    let onCopyShortcut: () -> Void
    init(onCopyShortcut: @escaping () -> Void) { self.onCopyShortcut = onCopyShortcut }
}

/// C 函数指针形式的事件回调（@convention(c) 由 CGEventTapCallBack 隐含）
private let clipboardEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if type == .keyDown, let userInfo = userInfo {
        let context = Unmanaged<EventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
        let flags = event.flags
        // keyCode 8 = C；Cmd+C 视为一次复制动作
        if flags.contains(.maskCommand), event.getIntegerValueField(.keyboardEventKeycode) == 8 {
            context.onCopyShortcut()
        }
    }
    // listenOnly 模式：原样透传事件，不做修改
    return Unmanaged.passUnretained(event)
}

// MARK: - 全局事件监听（05 号规格 1.1：EventMonitor / EventTapContext）

/// 复制动作感知：以 `.listenOnly` 方式挂 CGEventTap，检测到 Cmd+C 即触发一次读取。
/// 说明：
/// - `listenOnly` 不拦截事件，行为等价于"通知"，对系统零副作用；
/// - 部分 macOS 版本在**未授予辅助功能权限**时 `CGEventTapCreate` 返回 nil，
///   此时 `start()` 返回 false，ClipboardManager 自动退化为纯轮询（0.5s changeCount），
///   因此本监听是**可选增强**，不参与功能必需路径；
/// - 默认关闭，由设置页 `clipboard.eventTapEnabled` 开启。
public final class EventMonitor {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retainedUserInfo: UnsafeMutableRawPointer?
    private let context: EventTapContext
    private let enabled: () -> Bool

    public init(enabled: @escaping () -> Bool, onCopyDetected: @escaping () -> Void) {
        self.enabled = enabled
        self.context = EventTapContext(onCopyShortcut: onCopyDetected)
    }

    public var isRunning: Bool { tap != nil }

    /// 挂tap；失败（权限不足）返回 false，调用方据此走轮询兜底
    @discardableResult
    public func start() -> Bool {
        guard enabled(), tap == nil else { return false }
        let userInfo = Unmanaged.passRetained(context).toOpaque()
        retainedUserInfo = userInfo
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        // 新版 SDK（macOS 26 工具链）已将 CGEventTapCreate 迁移为 CGEvent.tapCreate 静态方法
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .listenOnly,
                                             eventsOfInterest: mask,
                                             callback: clipboardEventTapCallback,
                                             userInfo: userInfo) else {
            retainedUserInfo = nil
            Unmanaged<EventTapContext>.fromOpaque(userInfo).release()
            Log.warn("clipboard", "CGEventTap 创建失败（缺少辅助功能权限？），退化为轮询捕获")
            return false
        }
        tap = created
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: created, enable: true)
        Log.info("clipboard", "EventMonitor 已启动（listenOnly）")
        return true
    }

    public func stop() {
        guard let created = tap else { return }
        CGEvent.tapEnable(tap: created, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        tap = nil
        if let pointer = retainedUserInfo {
            Unmanaged<EventTapContext>.fromOpaque(pointer).release()
            retainedUserInfo = nil
        }
    }

    deinit { stop() }
}
