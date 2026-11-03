import Foundation
import SwiftUI

// MARK: - 剪贴板模块入口（契约 §2：AppModule）

public enum ClipboardModule: AppModule {

    public static let identifier = "clipboard"

    public static func start() {
        // v200（用户：悬浮剪贴板快捷键要能自行自定义）：
        // 删掉这里硬编码的「双击 ⌘」监听——它与「设置 → 工具与快捷键 → 快捷键」里
        // `floatingClipboard` 的可配置项（组合键 / 2× 双击修饰键）重复且无法改。
        // 现在唯一入口 = AppBootstrap 默认热键表 + DoubleTapShortcutCenter。
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
