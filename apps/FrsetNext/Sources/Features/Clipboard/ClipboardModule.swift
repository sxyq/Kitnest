import Foundation
import SwiftUI

// MARK: - 剪贴板模块入口（契约 §2：AppModule）

public enum ClipboardModule: AppModule {

    public static let identifier = "clipboard"

    public static func start() {
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
