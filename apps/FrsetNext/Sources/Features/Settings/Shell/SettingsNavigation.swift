import SwiftUI

/// 三级结构里的二级分组：一级目录（如「入口与交互」）下面的可折叠小节。
/// 只有页面多的目录才分小节；页面少的目录保持「一级 → 二级页」两层。
struct SettingsSidebarSection: Identifiable, Hashable {
    let id: String
    let title: String
    let pages: [SettingsPage]
}

/// 侧栏三级：一级目录 → 二级小节 → 三级页面；选中、搜索与旧链接仍以页面为单位。
enum SettingsGroup: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, entryInteraction, clipboard, capture, searchAI, tools, monitor, data
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "常规"
        case .appearance: return "主题外观"
        case .entryInteraction: return "入口与交互"
        case .clipboard: return "剪贴板"
        case .capture: return "截图与录屏"
        case .searchAI: return "搜索与 AI"
        case .tools: return "工具"
        case .monitor: return "性能监测"
        case .data: return "数据与帮助"
        }
    }
    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .entryInteraction: return "rectangle.3.group"
        case .clipboard: return "doc.on.clipboard"
        case .capture: return "camera.viewfinder"
        case .searchAI: return "magnifyingglass"
        case .tools: return "hammer"
        case .monitor: return "waveform.path.ecg"
        case .data: return "info.circle"
        }
    }
    var pages: [SettingsPage] {
        switch self {
        // v282：触觉反馈原是一级目录，但只有一页——一级目录只有一页时，
        // 侧栏会出现「点开目录 → 只有一个子项」的空壳层级。并进常规的独立小节，
        // 层级深度不变，少一次废点击。
        case .general: return [.generalStart, .generalNotifications, .permissions, .haptics]
        case .appearance: return [.generalPersonal, .appearanceText, .generalWindows]
        case .entryInteraction: return [.generalPanel, .panelBackground, .generalMenuBar, .menuBarArrangement,
                                        .shortcuts, .floatingBall, .clipboardFloating]
        case .clipboard: return [.clipboardCapture, .clipboardHistory, .clipboardAppearance]
        case .capture: return [.capture(.capture), .ocr, .watermark, .captureActions, .capture(.pin), .capture(.curtain), .capture(.recording), .capture(.workflow)]
        case .searchAI: return [.search, .ai]
        case .tools: return [.tools, .aiText, .calendar, .archive]
        case .monitor: return [.monitorSettings, .monitorWidgets]
        case .data: return [.configTransfer, .diagnostics, .about]
        }
    }
    /// 二级小节：**每个**一级目录都拆——不再有「裸页面」目录，
    /// 侧栏到处都是「一级标题 → 二级标题 → 三级页面」的同一套读法。
    var sections: [SettingsSidebarSection] {
        switch self {
        case .general:
            return [
                .init(id: "general.startup", title: "启动与通知",
                      pages: [.generalStart, .generalNotifications]),
                .init(id: "general.permissions", title: "权限",
                      pages: [.permissions]),
                .init(id: "general.haptics", title: "触觉反馈",
                      pages: [.haptics]),
            ]
        case .appearance:
            return [
                .init(id: "appearance.theme", title: "主题与文字",
                      pages: [.generalPersonal, .appearanceText]),
                .init(id: "appearance.window", title: "窗口与动效",
                      pages: [.generalWindows]),
            ]
        case .entryInteraction:
            return [
                .init(id: "entryInteraction.panel", title: "主面板",
                      pages: [.generalPanel, .panelBackground]),
                .init(id: "entryInteraction.menuBar", title: "菜单栏与快捷键",
                      pages: [.generalMenuBar, .menuBarArrangement, .shortcuts]),
                .init(id: "entryInteraction.floating", title: "悬浮窗",
                      pages: [.floatingBall, .clipboardFloating]),
            ]
        case .clipboard:
            return [
                .init(id: "clipboard.capture", title: "捕获与隐私",
                      pages: [.clipboardCapture]),
                .init(id: "clipboard.history", title: "历史与外观",
                      pages: [.clipboardHistory, .clipboardAppearance]),
            ]
        case .capture:
            return [
                .init(id: "capture.shot", title: "截图",
                      pages: [.capture(.capture), .ocr, .watermark, .captureActions]),
                .init(id: "capture.pin", title: "钉图与图帘",
                      pages: [.capture(.pin), .capture(.curtain)]),
                .init(id: "capture.record", title: "录屏",
                      pages: [.capture(.recording)]),
                .init(id: "capture.workflow", title: "截图工作流",
                      pages: [.capture(.workflow)]),
            ]
        case .searchAI:
            return [
                .init(id: "searchAI.search", title: "搜索",
                      pages: [.search]),
                .init(id: "searchAI.ai", title: "AI 服务",
                      pages: [.ai]),
            ]
        case .tools:
            return [
                .init(id: "tools.collection", title: "工具集合",
                      pages: [.tools, .aiText]),
                .init(id: "tools.calendar", title: "日历",
                      pages: [.calendar]),
            ]
        case .monitor:
            return [
                .init(id: "monitor.window", title: "监测窗口",
                      pages: [.monitorSettings]),
                .init(id: "monitor.menuBar", title: "菜单栏部件",
                      pages: [.monitorWidgets]),
            ]
        case .data:
            return [
                .init(id: "data.config", title: "配置与诊断",
                      pages: [.configTransfer, .diagnostics]),
                .init(id: "data.about", title: "关于与更新",
                      pages: [.about]),
            ]
        }
    }

    func section(containing page: SettingsPage) -> SettingsSidebarSection? {
        sections.first { $0.pages.contains(page.canonical) }
    }

    static func group(of page: SettingsPage) -> SettingsGroup {
        allCases.first { $0.pages.contains(page.canonical) } ?? .general
    }
}

enum SettingsPage: Hashable {
    case haptics
    case generalStart, generalNotifications, permissions, generalPersonal, appearanceText, generalWindows, generalPanel, panelBackground, generalMenuBar, menuBarArrangement, monitorWidgets, floatingBall, clipboardCapture, clipboardHistory, clipboardAppearance, clipboardFloating, archive, ocr, watermark, captureActions, search, ai, tools, aiText, calendar, shortcuts, monitorSettings, configTransfer, diagnostics, about, manual, audio, statistics
    case capture(CaptureSettingsBlock), monitorModule(MonitorModuleID)
    /// 旧业务入口仍可解析，设置侧栏不展示实时正文。
    var canonical: SettingsPage {
        switch self {
        case .audio: return .tools
        case .monitorModule: return .monitorSettings
        case .statistics: return .diagnostics
        default: return self
        }
    }
    var title: String {
        switch self {
        case .haptics: return "触觉反馈"
        case .generalStart: return "启动与语言"
        case .generalNotifications: return "通知提示"
        case .permissions: return "权限"
        case .generalPersonal: return "主题与颜色"
        case .appearanceText: return "文字与圆角"
        case .generalWindows: return "窗口材质与动效"
        case .generalPanel: return "布局与页面"
        case .panelBackground: return "背景图片"
        case .generalMenuBar: return "图标与入口"
        case .menuBarArrangement: return "排列与间距"
        case .monitorWidgets: return "部件与颜色"
        case .floatingBall: return "悬浮球"
        case .clipboardCapture: return "捕获与隐私"
        case .clipboardHistory: return "历史与备份"
        case .clipboardAppearance: return "列表外观"
        case .clipboardFloating: return "浮动窗"
        case .archive: return "压缩与 Finder"
        case .capture(.capture): return "截图与保存"
        case .ocr: return "文字识别"
        case .watermark: return "水印效果"
        case .captureActions: return "动作条"
        case .capture(.pin): return "钉图"
        case .capture(.curtain): return "图帘"
        case .capture(.recording): return "录屏"
        case .capture(.workflow): return "截图工作流"
        case .search: return "搜索与引擎"
        case .ai: return "AI 服务"
        case .tools: return "工具集合"
        case .aiText: return "AI 文本工具"
        case .calendar: return "日历"
        case .shortcuts: return "全部功能绑定"
        case .monitorSettings: return "采样与显示"
        case .configTransfer: return "配置导出与导入"
        case .diagnostics: return "诊断"
        case .about: return "关于与更新"
        case .manual: return "使用手册"
        case .audio: return "音频混音器"
        case .statistics: return "使用统计"
        case .monitorModule(let module): return module.displayName
        }
    }
    var systemImage: String { self == .manual ? "book.closed" : SettingsGroup.group(of: self).systemImage }
    var group: SettingsGroup? { self == .manual ? nil : SettingsGroup.group(of: self) }
    /// 所属二级小节（只对拆过小节的目录有值）。
    var section: SettingsSidebarSection? { group?.section(containing: self) }
    /// 侧栏展开状态用的键：一级目录 + 二级小节。
    var sectionID: String? { section?.id }
    /// 面包屑/搜索展示用：一级 › 二级 › 三级。
    var path: String {
        var parts: [String] = []
        if let group { parts.append(group.title) }
        if let section { parts.append(section.title) }
        parts.append(title)
        return parts.joined(separator: " › ")
    }
    var openHint: String? {
        switch canonical {
        case .haptics: return "全局强度与分场景开关"
        case .generalStart: return "开机启动与界面语言"
        case .generalNotifications: return "复制、截图完成后的提示"
        case .permissions: return "改完立即生效"
        case .generalPersonal: return "主题与强调色"
        case .appearanceText: return "全局字号与窗口圆角"
        case .generalWindows: return "窗口材质与开合动效"
        case .generalPanel: return "主面板显示哪些页面"
        case .panelBackground: return "主面板背景图与遮罩"
        case .generalMenuBar: return "菜单栏图标与入口"
        case .menuBarArrangement: return "图标合并、间距与分隔线"
        case .monitorWidgets: return "菜单栏部件的形态、颜色与排列"
        case .clipboardCapture: return "复制后自动收录，含图片 OCR"
        case .clipboardHistory: return "保留时长与容量上限"
        case .clipboardAppearance: return "列表密度、缩略图与来源徽章"
        case .clipboardFloating: return "浮动窗样式，呼出键在快捷键页"
        case .archive: return "ZIP 打开方式、悬浮预览与 Finder 服务"
        case .capture(.capture): return "保存位置与命名"
        case .ocr: return "识别语言与结果展示"
        case .watermark: return "文字、透明度、平铺与角度"
        case .captureActions: return "截图后动作条的按钮"
        case .capture(.pin): return "钉图窗口的默认样式"
        case .capture(.curtain): return "图帘的悬停与收回"
        case .capture(.recording): return "录屏画面与声音"
        case .capture(.workflow): return "截图后自动执行的动作"
        case .search: return "搜索范围与引擎"
        case .ai: return "服务商、模型与凭证"
        case .tools: return "启用状态与设备"
        case .aiText: return "默认动作与提示词"
        case .calendar: return "周起始日与日程显示"
        case .shortcuts: return "全局快捷键绑定"
        case .monitorSettings: return "采样频率与显示项"
        case .floatingBall: return "悬浮窗开关、组件与位置"
        case .configTransfer: return "导入导出配置"
        case .diagnostics: return "运行状态与诊断导出"
        case .about: return "更新源与检查更新"
        case .manual, .audio, .monitorModule, .statistics: return nil
        }
    }
}
