import SwiftUI

/// 一级目录只控制展开；页面、搜索及旧链接共用二级归属。
enum SettingsGroup: String, CaseIterable, Identifiable, Hashable {
    case general, haptics, appearance, entryInteraction, clipboard, transfer, capture, searchAI, tools, monitor, data
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "常规"
        case .haptics: return "触觉反馈"
        case .appearance: return "主题外观"
        case .entryInteraction: return "入口与交互"
        case .clipboard: return "剪贴板"
        case .transfer: return "文件与传输"
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
        case .haptics: return "hand.tap"
        case .appearance: return "paintpalette"
        case .entryInteraction: return "rectangle.3.group"
        case .clipboard: return "doc.on.clipboard"
        case .transfer: return "arrow.left.arrow.right.square"
        case .capture: return "camera.viewfinder"
        case .searchAI: return "magnifyingglass"
        case .tools: return "hammer"
        case .monitor: return "waveform.path.ecg"
        case .data: return "info.circle"
        }
    }
    var pages: [SettingsPage] {
        switch self {
        case .general: return [.generalStart, .generalNotifications, .permissions]
        case .haptics: return [.haptics]
        case .appearance: return [.generalPersonal, .appearanceText, .generalWindows]
        case .entryInteraction: return [.generalPanel, .panelBackground, .generalMenuBar, .menuBarArrangement,
                                        .monitorWidgets, .shortcuts, .island, .islandPeeks, .islandCanvas,
                                        .islandMaterial, .floatingBall, .clipboardFloating]
        case .clipboard: return [.clipboardCapture, .clipboardHistory, .clipboardAppearance]
        case .transfer: return [.transferLocal, .transferScan, .transferCloud, .transferCast, .archive]
        case .capture: return [.capture(.capture), .ocr, .watermark, .captureActions, .capture(.pin), .capture(.curtain), .capture(.recording), .capture(.workflow)]
        case .searchAI: return [.search, .ai]
        case .tools: return [.tools, .aiText, .calendar]
        case .monitor: return [.monitorSettings]
        case .data: return [.configTransfer, .diagnostics, .about]
        }
    }
    static func group(of page: SettingsPage) -> SettingsGroup {
        allCases.first { $0.pages.contains(page.canonical) } ?? .general
    }
}

enum SettingsPage: Hashable {
    case haptics
    case generalStart, generalNotifications, permissions, generalPersonal, appearanceText, generalWindows, generalPanel, panelBackground, island, islandPeeks, islandCanvas, islandMaterial, generalMenuBar, menuBarArrangement, monitorWidgets, floatingBall, clipboardCapture, clipboardHistory, clipboardAppearance, clipboardFloating, transferLocal, transferScan, transferCloud, transferCast, archive, ocr, watermark, captureActions, search, ai, tools, aiText, calendar, shortcuts, monitorSettings, configTransfer, diagnostics, about, manual, audio, transferDisplay, statistics
    case capture(CaptureSettingsBlock), monitorModule(MonitorModuleID)
    /// 旧业务入口仍可解析，设置侧栏不展示实时正文。
    var canonical: SettingsPage {
        switch self {
        case .audio: return .tools
        case .transferDisplay: return .transferLocal
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
        case .island: return "唤出与收回"
        case .islandPeeks: return "收起态"
        case .islandCanvas: return "画布与组件"
        case .islandMaterial: return "材质与颜色"
        case .generalMenuBar: return "图标与入口"
        case .menuBarArrangement: return "排列与间距"
        case .monitorWidgets: return "部件与颜色"
        case .floatingBall: return "悬浮球"
        case .clipboardCapture: return "捕获与隐私"
        case .clipboardHistory: return "历史与备份"
        case .clipboardAppearance: return "列表外观"
        case .clipboardFloating: return "浮动窗"
        case .transferLocal: return "本地中转"
        case .transferScan: return "手机直传"
        case .transferCloud: return "云端中转"
        case .transferCast: return "投屏"
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
        case .transferDisplay: return "本地中转"
        case .statistics: return "使用统计"
        case .monitorModule(let module): return module.displayName
        }
    }
    var systemImage: String { self == .manual ? "book.closed" : SettingsGroup.group(of: self).systemImage }
    var group: SettingsGroup? { self == .manual ? nil : SettingsGroup.group(of: self) }
    var openHint: String? {
        switch canonical {
        case .haptics: return "总开关、全局强度与独立场景开关；模拟试听当前草稿，保存后应用"
        case .generalStart: return "启动与语言保存后生效；系统关联与授权单独操作"
        case .generalNotifications: return "复制、截图完成后显示；重播只作用于模拟通知"
        case .permissions: return "查看真实授权状态；系统授权为即时操作"
        case .generalPersonal: return "全局主题与强调色；色相只作用于 Midnight"
        case .appearanceText: return "共用字号与窗口圆角；模块独有样式在所属模块"
        case .generalWindows: return "共用材质与开合动效；底衬不透明度越大，底衬越不透明"
        case .generalPanel: return "页面显隐只改变展示，不关闭底层功能"
        case .panelBackground: return "背景图和遮罩只作用于主面板"
        case .island: return "设置显示屏幕、菜单栏入口、悬停停留与自动收回"
        case .islandPeeks: return "收起图标、数值、顺序及快捷操作"
        case .islandCanvas: return "预览中完成布局只更新草稿；本页保存后应用"
        case .islandMaterial: return "刘海材质、组件与指标颜色；不改变其他窗口"
        case .generalMenuBar: return "图标及入口；日历、OCR 与 AI 设置在各自模块"
        case .menuBarArrangement: return "合并、间距与分隔线；刷新间隔位于性能监测"
        case .monitorWidgets: return "页内选择部件与形态；复用正式绘制"
        case .clipboardCapture: return "复制后自动捕获；自动图片 OCR 在此设置"
        case .clipboardHistory: return "保留期和容量保存后生效；清理、标签及备份为即时操作"
        case .clipboardAppearance: return "主面板列表；密度、缩略图及来源徽章"
        case .clipboardFloating: return "独立浮动窗样式；呼出绑定统一在快捷键页"
        case .transferLocal: return "主面板中转页；自动暂存、悬停及保留期"
        case .transferScan: return "主面板中转页的手机直传；服务启停为即时操作"
        case .transferCloud: return "主面板中转页的云端传输；登录和账号操作单独呈现"
        case .transferCast: return "主面板投屏页；画质参数保存后应用"
        case .archive: return "双击打开/快速解压、悬浮预览上限、任务窗置顶与 Finder 服务"
        case .capture(.capture): return "截图目录、命名与保存行为；各截图动作独立绑定"
        case .ocr: return "共用识别语言与结果展示；预览不启动真实识别"
        case .watermark: return "文字、透明度、平铺及角度使用固定模拟画面"
        case .captureActions: return "截图后出现；预览不执行真实复制或保存"
        case .capture(.pin): return "模块默认保留单个钉图窗口的独立样式"
        case .capture(.curtain): return "截图挂到屏幕顶边；悬停与收回使用短演示"
        case .capture(.recording): return "效果使用模拟画面；开始录制为即时操作"
        case .capture(.workflow): return "保存后改变后续截图工作流"
        case .search: return "搜索分类与引擎；显示开关不停止对应功能"
        case .ai: return "服务商、地址、模型及凭证；文本动作在 AI 文本工具"
        case .tools: return "启用保存后应用；音量、设备及统计打开正式功能窗"
        case .aiText: return "默认文本动作与自定义提示词；服务配置在搜索与 AI"
        case .calendar: return "周起始日统一月历和两周视图；预览不读真实日程"
        case .shortcuts: return "组合键或现有双按模式；保存成功后才注册"
        case .monitorSettings: return "八项指标在正式监测页；此处调节采样与显示"
        case .floatingBall: return "悬浮快捷窗可独立开关；组件与位置分别保存"
        case .configTransfer: return "导入导出为即时操作；不含内容、凭证或预览状态"
        case .diagnostics: return "运行状态及诊断导出；不自动清理资料"
        case .about: return "更新源保存后应用；查找更新为即时操作"
        case .manual, .audio, .transferDisplay, .monitorModule, .statistics: return nil
        }
    }
}
