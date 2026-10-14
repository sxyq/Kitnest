import Foundation
import AppKit

// MARK: - 辅助窗口群管理
//
// 登记当前已打开的辅助窗口（钉图 / 编辑窗 / 浮动窗 / 预览窗 …），
// 支持按类型或一键全部关闭。内部使用弱引用集合，窗口释放后自动清理，不持有、不泄漏。

public enum AuxiliaryWindowKind: String, CaseIterable, Sendable, Identifiable {
    case pinned      // 钉图（截图标注后钉在屏幕上）
    case editor      // 编辑窗（长截图编辑器等）
    case floating    // 浮动窗（浮动剪贴板等）
    case preview     // 预览窗（图片 / 代码预览）
    case other       // 其他

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pinned:   return "钉图"
        case .editor:   return "编辑窗"
        case .floating: return "浮动窗"
        case .preview:  return "预览窗"
        case .other:    return "其他"
        }
    }
}

public struct AuxiliaryWindowInfo: Identifiable {
    public let id: String             // 窗口对象地址字符串（稳定标识）
    public let kind: AuxiliaryWindowKind
    public let title: String
    public weak var window: NSWindow?
}

public enum WindowManager {
    /// 弱引用条目：窗口被关闭释放后自动失效
    private final class Entry {
        weak var window: NSWindow?
        let kind: AuxiliaryWindowKind
        let title: String
        init(window: NSWindow, kind: AuxiliaryWindowKind, title: String) {
            self.window = window; self.kind = kind; self.title = title
        }
    }

    private static let lock = NSLock()
    private static var entries: [Entry] = []

    /// 登记一个辅助窗口
    public static func register(_ window: NSWindow,
                                kind: AuxiliaryWindowKind,
                                title: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        // 同一窗口重复登记时先移除旧条目
        entries.removeAll { $0.window === window }
        entries.append(Entry(window: window, kind: kind, title: title ?? window.title))
        Log.info("WindowManager", "register: \(kind.rawValue) - \(title ?? window.title)")
    }

    public static func unregister(_ window: NSWindow) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.window === window || $0.window == nil }
    }

    /// 当前所有存活的辅助窗口
    public static var allWindows: [AuxiliaryWindowInfo] {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        return entries.compactMap { entry in
            guard let window = entry.window else { return nil }
            return AuxiliaryWindowInfo(id: String(describing: ObjectIdentifier(window)),
                                       kind: entry.kind,
                                       title: entry.title,
                                       window: window)
        }
    }

    public static func windows(of kind: AuxiliaryWindowKind) -> [AuxiliaryWindowInfo] {
        allWindows.filter { $0.kind == kind }
    }

    /// 关闭指定类型的全部窗口（nil 表示全部）
    public static func closeAll(kind: AuxiliaryWindowKind? = nil) {
        let targets = allWindows.filter { kind == nil || $0.kind == kind }
        for info in targets {
            guard let window = info.window else { continue }
            DispatchQueue.main.async {
                window.close()
            }
        }
        lock.lock()
        if let kind {
            entries.removeAll { $0.kind == kind }
        } else {
            entries.removeAll()
        }
        lock.unlock()
        Log.info("WindowManager", "closeAll: \(kind?.rawValue ?? "all"), count=\(targets.count)")
    }

    /// 把某类窗口提到最前（如唤起浮动剪贴板）
    public static func bringToFront(kind: AuxiliaryWindowKind) {
        for info in windows(of: kind) {
            DispatchQueue.main.async {
                info.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// 数量统计（设置页 / 调试展示用）
    public static func count(of kind: AuxiliaryWindowKind) -> Int { windows(of: kind).count }

    /// 清理已释放的窗口条目
    private static func pruneLocked() {
        entries.removeAll { $0.window == nil }
    }
}
