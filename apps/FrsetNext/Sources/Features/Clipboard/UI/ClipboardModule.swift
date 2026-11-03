import Foundation
import SwiftUI

// MARK: - 剪贴板模块入口（契约 §2：AppModule）

public enum ClipboardModule: AppModule {

    public static let identifier = "clipboard"

    public static func start() {
        // 双击修饰键呼出（原版 AppKitDoubleTapMonitor 族，重建版缺失功能 §3-3）：
        // 0.4s 内两次按下 ⌘ → 悬浮剪贴板在鼠标位置弹出/收起。global 覆盖其他 App 前台，
        // local 覆盖本 App 前台；监听器常驻，判定窗口仅 0.4s，常驻开销可忽略。
        DoubleTapCommandMonitor.start()
        // ① 启动捕获与双清理调度
        ClipboardManager.shared.start()
        ClipboardHistoryRetentionPruneScheduler.shared.start()
        ClipboardStoragePruneScheduler.shared.start()

        // ② 恢复浮动窗的上次可见状态
        FloatingClipboardWindowController.shared.restoreVisibilityIfNeeded()

        // ③ 主面板区段
        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "clipboard", title: "剪贴板", priority: 20,
            build: { AnyView(ClipboardSectionView()) }))

        // ④ 设置页签
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "clipboard", title: "剪贴板", systemImage: "clipboard",
            build: { AnyView(ClipboardSettingsPane()) }))

        ModuleRegistry.register(self)
        Log.info("clipboard", "模块已启动")
    }
}


// MARK: - 双击修饰键呼出（§3-3）

/// 0.4s 内两次按下 ⌘ → 悬浮剪贴板在鼠标位置弹出/收起。
/// 只在「按下沿」计数（松开沿不算），避免一次按放被判成两次。
enum DoubleTapCommandMonitor {
    private static var lastDownAt: Date?
    private static var wasDown = false
    private static var installed = false

    static func start() {
        guard !installed else { return }
        installed = true
        let handler: (NSEvent) -> Void = { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmdDown = flags.contains(.command)
            defer { wasDown = cmdDown }
            guard cmdDown, !wasDown else { return }      // 只认按下沿
            let now = Date()
            if let last = lastDownAt, now.timeIntervalSince(last) < 0.4 {
                lastDownAt = nil
                DispatchQueue.main.async {
                    FloatingClipboardWindowController.shared.showNearMouse()
                }
            } else {
                lastDownAt = now
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }
}
