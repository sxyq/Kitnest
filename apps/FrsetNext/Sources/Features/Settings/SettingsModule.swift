import Foundation
import SwiftUI

// MARK: - 设置模块入口
//
// 页签归属（总装裁决 2026-10-15）：
// - 「快捷键」页签（id "shortcuts"）**由 Toolbox 模块注册**——消费 ShortcutRegistry 的真实注册数据，
//   并展示注册失败/冲突原因（对应 07 号规格「录入控件/冲突提示」）。本模块不再自带简化版注册表。
// - 快捷键注册表（ShortcutRegistry / ShortcutManager）唯一实现在 Toolbox/ShortcutManager.swift。

public enum SettingsModule: AppModule {
    public static let identifier = "settings"

    public static func start() {
        // 1) 注册自带的基础页签（其他模块的页签由各自 start() 注册）
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "general", title: "通用", systemImage: "gearshape",
            build: { AnyView(GeneralSettingsPane()) }))
        // 搜索页签（specs/18：补齐原作 5 页签缺失项，排序数组已含 "search"）
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "search", title: "搜索", systemImage: "magnifyingglass",
            build: { AnyView(SearchSettingsPane()) }))
        // 数据页签（spec 17 S12：设置导出/导入携带统计数据 + Q6/Q7 统计口径出口）
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "statistics", title: "数据", systemImage: "chart.bar.doc.horizontal",
            build: { AnyView(StatisticsSettingsPane()) }))
        SettingsPaneRegistry.register(SettingsPaneDescriptor(
            id: "about", title: "关于", systemImage: "info.circle",
            build: { AnyView(AboutSettingsPane()) }))

        // 2) 注入共享能力：其他模块通过 ServiceLocator.settings 唤起设置窗口
        ServiceLocator.settings = SettingsWindowController.shared

        // 3) 外观/语言基建生效（specs/18：appearance 键 + language 键）
        AppearanceManager.shared.applyCurrent()

        Log.info("Settings", "设置模块已启动（4 个基础页签已注册；快捷键/工具页签由 Toolbox 注册）")
    }
}
