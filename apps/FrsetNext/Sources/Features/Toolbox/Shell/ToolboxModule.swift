import Foundation
import SwiftUI

// MARK: - 模块入口（由总控 App 层调用 ToolboxModule.start()）

public enum ToolboxModule: AppModule {
    public static let identifier = "toolbox"

    public static func start() {
        // 1) 注册内置工具
        BuiltinTools.registerAll()

        // 2) 主面板区段：搜索（priority 5，最前）→ 工具（50）→ 日历（60）
        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "search", title: "搜索", priority: 5,
            build: { AnyView(SearchSectionView()) }))
        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "tools", title: "工具", priority: 50,
            build: { AnyView(ToolboxSectionView()) }))
        PanelSectionRegistry.register(PanelSectionDescriptor(
            id: "calendar", title: "日历", priority: 60,
            build: { AnyView(CalendarSectionView()) }))

        // 3) 设置页签：工具 / 快捷键
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "tools", title: "工具", systemImage: "wrench",
            build: { AnyView(ToolSettingsPane()) }))
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "shortcuts", title: "快捷键", systemImage: "keyboard",
            build: { AnyView(ShortcutSettingsPane()) }))

        // 4) 全局搜索默认数据源：工具名检索（其他模块可再注册自己的检索源）
        ToolboxSearchSource.register()

        // 5) 恢复用户此前录入的工具快捷键（全局热键）
        ToolShortcutStore.restoreAll()

        // 6) 日历授权（未授权时降级为空事件 + 提示入口）
        CalendarService.shared.requestAccessIfNeeded()

        Log.info("Toolbox", "started: \(ToolRegistry.all.count) tools")
    }
}
