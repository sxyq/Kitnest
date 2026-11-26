import AppKit
import SwiftUI

enum IslandPage: String, Codable, CaseIterable, Identifiable {
    case home, clipboard, search, custom, monitor, media, calendar, tools, capture, recording, ocr, transfer, cast, ai, statistics, archive, downloads
    var id: String { rawValue }
    static let tabs: [Self] = [.home, .clipboard, .search, .custom]
    var title: String {
        switch self {
        case .home: return "常用"
        case .clipboard: return "剪贴板"
        case .search: return "搜索"
        case .custom: return "我的空间"
        case .monitor: return "监测"
        case .media: return "媒体"
        case .calendar: return "日历"
        case .tools: return "全部功能"
        case .capture: return "截图与标注"
        case .recording: return "录屏"
        case .ocr: return "识别与翻译"
        case .transfer: return "中转站与传输"
        case .cast: return "手机投屏"
        case .ai: return "AI 对话"
        case .statistics: return "使用统计"
        case .archive: return "压缩与解压"
        case .downloads: return "网盘与下载"
        }
    }
}

enum IslandOpeningPageMode: String, Codable, CaseIterable, Identifiable {
    case fixed, remember
    var id: String { rawValue }
    var title: String { self == .fixed ? "固定指定页" : "记忆上次页面" }
}

enum IslandHotspot: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var title: String { self == .left ? "顶部左侧" : self == .right ? "顶部右侧" : "顶部中央" }
}

enum IslandPeekPlacement: String, Codable, CaseIterable, Identifiable {
    case both, left, right, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "左右两侧"
        case .left: return "仅左侧"
        case .right: return "仅右侧"
        case .hidden: return "隐藏常态数据"
        }
    }
}

enum IslandEntryVisibility: String, Codable, CaseIterable, Identifiable {
    case hidden, event, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hidden: return "仅热区唤出"
        case .event: return "悬停时显示"
        case .always: return "常驻显示"
        }
    }
}

enum IslandEntryTrigger: String, Codable, CaseIterable, Identifiable {
    case hoverAndClick, clickOnly
    var id: String { rawValue }
    var title: String { self == .hoverAndClick ? "悬停或点击" : "仅点击" }
}

enum IslandSearchCategory: String, Codable, CaseIterable, Identifiable {
    case all, web, clipboard, files, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .web: return "网页"
        case .clipboard: return "剪贴板"
        case .files: return "文件"
        case .tools: return "工具"
        }
    }
}

enum IslandMaterial: String, Codable, CaseIterable, Identifiable {
    case liquidGlass, frosted, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .liquidGlass: return "原生液态玻璃"
        case .frosted: return "毛玻璃"
        case .solid: return "纯色"
        }
    }
}

enum IslandDisplayScope: String, Codable, CaseIterable, Identifiable {
    case auto, all, main, selected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "自动 · 刘海屏优先"
        case .all: return "全部屏幕"
        case .main: return "仅主屏"
        case .selected: return "指定屏幕"
        }
    }
}

struct IslandConfiguration: Codable, Equatable {
    static let key = "island.configuration"
    var enabled = true
    var displayScope: IslandDisplayScope = .auto
    var selectedDisplayIDs = Set<String>()
    var width: CGFloat = 780
    var height: CGFloat = 480
    var gridColumns: Int? = nil
    var gridRows: Int? = nil
    var columns: Int { gridColumns ?? 4 }
    var rows: Int { gridRows ?? 2 }
    var customGridColumns: Int? = nil
    var customGridRows: Int? = nil
    var customColumns: Int { customGridColumns ?? columns }
    var customRows: Int { customGridRows ?? rows }
    var minimumWidth: CGFloat { CGFloat(columns) * 144 + CGFloat(columns - 1) * 8 + IslandLayout.horizontalInset * 2 }
    var minimumHeight: CGFloat { CGFloat(rows) * 112 + CGFloat(rows - 1) * 8 + 176 }
    var hoverEnabled = true
    var hoverDelay = 0.18
    var collapseDelay = 0.30
    var usesGlass = true
    var material: IslandMaterial? = nil
    var effectiveMaterial: IslandMaterial { material ?? (usesGlass ? .liquidGlass : .solid) }
    var opacity = 0.32
    var glowEnabled = true
    var visiblePeeks = Set<IslandPeek>()
    var peeksShowValues = true
    var peeksQuickActions = true
    var peekOrder = IslandPeek.allCases
    var widgetOrder = [IslandWidget.capture, .clipboard, .search, .monitor]
        + IslandWidget.allCases.filter { ![.capture, .clipboard, .search, .monitor].contains($0) }
    var hiddenWidgets = Set(IslandWidget.allCases).subtracting([.capture, .clipboard, .search, .monitor])
    var widgetSizes: [String: IslandWidgetSize] = [:]
    var widgetPositions: [String: IslandWidgetPosition]? = nil
    var widgetColors: [String: String] = [:]
    var metricOrder = IslandMetric.allCases
    var metricColors: [String: String] = [:]
    var pageOrder = IslandPage.tabs
    var hiddenPages = Set<IslandPage>()
    var openingPageMode: IslandOpeningPageMode = .fixed
    var fixedPage: IslandPage = .home
    var lastPageByDisplay: [String: IslandPage] = [:]
    var customPageName = "我的空间"
    var customWidgetOrder: [IslandWidget] = []
    var customWidgetSizes: [String: IslandWidgetSize] = [:]
    var customWidgetPositions: [String: IslandWidgetPosition] = [:]
    var commonWidgetLimit = 3
    var clipboardRecentLimit = 4
    var clipboardFavoritesOnly = false
    var searchCategory: IslandSearchCategory = .all
    var hotspots: [String: IslandHotspot] = [:]
    var peekPlacements: [String: IslandPeekPlacement] = [:]
    var hotspotWidths: [String: Int] = [:]
    var entryVisibilities: [String: IslandEntryVisibility] = [:]
    var entryTriggers: [String: IslandEntryTrigger] = [:]
    /// v266：上次使用的屏幕。多屏时重启后回到同一块屏，而不是固定取第一块。
    var lastActiveDisplayID: String? = nil

    var visiblePages: [IslandPage] {
        let ordered = pageOrder.filter { IslandPage.tabs.contains($0) }
            + IslandPage.tabs.filter { !pageOrder.contains($0) }
        let visible = ordered.filter { !hiddenPages.contains($0) }
        return visible.isEmpty ? [.home] : visible
    }
    func pageTitle(_ page: IslandPage) -> String { page == .custom ? customPageName : page.title }

    private enum CodingKeys: String, CodingKey {
        case enabled, displayScope, selectedDisplayIDs, width, height, gridColumns, gridRows
        case customGridColumns, customGridRows
        case hoverEnabled, hoverDelay, collapseDelay, usesGlass, material, opacity, glowEnabled
        case visiblePeeks, peeksShowValues, peeksQuickActions, peekOrder, widgetOrder, hiddenWidgets
        case widgetSizes, widgetPositions, widgetColors, metricOrder, metricColors
        case pageOrder, hiddenPages, openingPageMode, fixedPage, lastPageByDisplay, customPageName
        case customWidgetOrder, customWidgetSizes, customWidgetPositions, commonWidgetLimit
        case clipboardRecentLimit, clipboardFavoritesOnly, searchCategory, hotspots, peekPlacements
        case hotspotWidths, entryVisibilities, entryTriggers, lastActiveDisplayID
    }

    init() {}

    // 旧配置逐字段保留；新增屏幕选项缺失时只采用该字段的默认值。
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        displayScope = try values.decodeIfPresent(IslandDisplayScope.self, forKey: .displayScope) ?? displayScope
        selectedDisplayIDs = try values.decodeIfPresent(Set<String>.self, forKey: .selectedDisplayIDs) ?? selectedDisplayIDs
        width = try values.decodeIfPresent(CGFloat.self, forKey: .width) ?? width
        height = try values.decodeIfPresent(CGFloat.self, forKey: .height) ?? height
        gridColumns = try values.decodeIfPresent(Int.self, forKey: .gridColumns)
        gridRows = try values.decodeIfPresent(Int.self, forKey: .gridRows)
        customGridColumns = try values.decodeIfPresent(Int.self, forKey: .customGridColumns)
        customGridRows = try values.decodeIfPresent(Int.self, forKey: .customGridRows)
        hoverEnabled = try values.decodeIfPresent(Bool.self, forKey: .hoverEnabled) ?? hoverEnabled
        hoverDelay = try values.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? hoverDelay
        collapseDelay = try values.decodeIfPresent(Double.self, forKey: .collapseDelay) ?? collapseDelay
        usesGlass = try values.decodeIfPresent(Bool.self, forKey: .usesGlass) ?? usesGlass
        material = try values.decodeIfPresent(IslandMaterial.self, forKey: .material)
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        glowEnabled = try values.decodeIfPresent(Bool.self, forKey: .glowEnabled) ?? glowEnabled
        visiblePeeks = try values.decodeIfPresent(Set<IslandPeek>.self, forKey: .visiblePeeks) ?? visiblePeeks
        peeksShowValues = try values.decodeIfPresent(Bool.self, forKey: .peeksShowValues) ?? peeksShowValues
        peeksQuickActions = try values.decodeIfPresent(Bool.self, forKey: .peeksQuickActions) ?? peeksQuickActions
        peekOrder = try values.decodeIfPresent([IslandPeek].self, forKey: .peekOrder) ?? peekOrder
        widgetOrder = try values.decodeIfPresent([IslandWidget].self, forKey: .widgetOrder) ?? widgetOrder
        hiddenWidgets = try values.decodeIfPresent(Set<IslandWidget>.self, forKey: .hiddenWidgets) ?? hiddenWidgets
        widgetSizes = try values.decodeIfPresent([String: IslandWidgetSize].self, forKey: .widgetSizes) ?? widgetSizes
        widgetPositions = try values.decodeIfPresent([String: IslandWidgetPosition].self, forKey: .widgetPositions)
        widgetColors = try values.decodeIfPresent([String: String].self, forKey: .widgetColors) ?? widgetColors
        metricOrder = try values.decodeIfPresent([IslandMetric].self, forKey: .metricOrder) ?? metricOrder
        metricColors = try values.decodeIfPresent([String: String].self, forKey: .metricColors) ?? metricColors
        pageOrder = try values.decodeIfPresent([IslandPage].self, forKey: .pageOrder) ?? pageOrder
        hiddenPages = try values.decodeIfPresent(Set<IslandPage>.self, forKey: .hiddenPages) ?? hiddenPages
        openingPageMode = try values.decodeIfPresent(IslandOpeningPageMode.self, forKey: .openingPageMode) ?? openingPageMode
        fixedPage = try values.decodeIfPresent(IslandPage.self, forKey: .fixedPage) ?? fixedPage
        lastPageByDisplay = try values.decodeIfPresent([String: IslandPage].self, forKey: .lastPageByDisplay) ?? lastPageByDisplay
        customPageName = try values.decodeIfPresent(String.self, forKey: .customPageName) ?? customPageName
        customWidgetOrder = try values.decodeIfPresent([IslandWidget].self, forKey: .customWidgetOrder) ?? customWidgetOrder
        customWidgetSizes = try values.decodeIfPresent([String: IslandWidgetSize].self, forKey: .customWidgetSizes) ?? customWidgetSizes
        customWidgetPositions = try values.decodeIfPresent([String: IslandWidgetPosition].self, forKey: .customWidgetPositions) ?? customWidgetPositions
        commonWidgetLimit = try values.decodeIfPresent(Int.self, forKey: .commonWidgetLimit)
            ?? min(4, max(1, widgetOrder.filter { !hiddenWidgets.contains($0) }.count))
        clipboardRecentLimit = try values.decodeIfPresent(Int.self, forKey: .clipboardRecentLimit) ?? clipboardRecentLimit
        clipboardFavoritesOnly = try values.decodeIfPresent(Bool.self, forKey: .clipboardFavoritesOnly) ?? clipboardFavoritesOnly
        searchCategory = try values.decodeIfPresent(IslandSearchCategory.self, forKey: .searchCategory) ?? searchCategory
        hotspots = try values.decodeIfPresent([String: IslandHotspot].self, forKey: .hotspots) ?? hotspots
        peekPlacements = try values.decodeIfPresent([String: IslandPeekPlacement].self, forKey: .peekPlacements) ?? peekPlacements
        hotspotWidths = try values.decodeIfPresent([String: Int].self, forKey: .hotspotWidths) ?? hotspotWidths
        entryVisibilities = try values.decodeIfPresent([String: IslandEntryVisibility].self, forKey: .entryVisibilities) ?? entryVisibilities
        entryTriggers = try values.decodeIfPresent([String: IslandEntryTrigger].self, forKey: .entryTriggers) ?? entryTriggers
        lastActiveDisplayID = try values.decodeIfPresent(String.self, forKey: .lastActiveDisplayID)
    }

    /// 返回保存的行 × 列档位；画布适配只影响 size(for:) 的显示结果。
    func requestedSize(for widget: IslandWidget) -> IslandWidgetSize {
        widgetSizes[widget.rawValue] ?? (widget == .monitor || widget == .clipboard ? .wide : .small)
    }
    func size(for widget: IslandWidget) -> IslandWidgetSize {
        let size = requestedSize(for: widget)
        if rows == 1 && size.rows == 2 { return size.columns == 1 ? .small : .wide }
        return size.columns > columns ? .wide : size
    }
    func color(for widget: IslandWidget) -> Color {
        widgetColors[widget.rawValue].flatMap(Personalization.color(fromHex:)) ?? widget.color
    }
    func color(for metric: IslandMetric) -> Color {
        metricColors[metric.rawValue].flatMap(Personalization.color(fromHex:)) ?? metric.color
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key) else { return Self() }
        do {
            var value = try JSONDecoder().decode(Self.self, from: data)
            value.widgetOrder += IslandWidget.allCases.filter { !value.widgetOrder.contains($0) }
            value.customWidgetOrder = value.customWidgetOrder.filter { IslandWidget.allCases.contains($0) }
            value.pageOrder = IslandPage.tabs.filter { value.pageOrder.contains($0) }
                + IslandPage.tabs.filter { !value.pageOrder.contains($0) }
            if value.hiddenPages.count >= IslandPage.tabs.count { value.hiddenPages.remove(.home) }
            if !value.visiblePages.contains(value.fixedPage) { value.fixedPage = value.visiblePages[0] }
            return value
        }
        catch { Log.warn("Island", "配置读取失败：\(error.localizedDescription)"); return Self() }
    }
    func persist() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}

struct IslandWidgetPosition: Codable, Equatable {
    var page: Int
    var column: Int
    var row: Int
}

enum IslandWidgetSize: String, CaseIterable, Codable, Identifiable {
    case small = "1×1", wide = "1×2", tall = "2×1", strip = "1×4", square = "2×2"
    var id: String { rawValue }
    var columns: Int { self == .small || self == .tall ? 1 : self == .strip ? 4 : 2 }
    var rows: Int { self == .square || self == .tall ? 2 : 1 }
}

enum IslandPeek: String, CaseIterable, Codable, Identifiable {
    case clipboard, media, calendar, monitor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: return "最近复制"
        case .media: return "播放状态"
        case .calendar: return "日期"
        case .monitor: return "功耗"
        }
    }
    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .monitor: return "bolt"
        }
    }
    var quickActionTitle: String {
        switch self {
        case .clipboard: return "复制最近一条"
        case .media: return "播放／暂停"
        case .calendar: return "复制今天日期"
        case .monitor: return "打开功耗监测"
        }
    }
    var page: IslandPage {
        switch self {
        case .clipboard: return .clipboard
        case .media: return .media
        case .calendar: return .calendar
        case .monitor: return .monitor
        }
    }
}

enum IslandWidget: String, CaseIterable, Codable, Identifiable {
    case monitor, media, calendar, clipboard, tools, volume, search, capture, recording, ocr, transfer, cast, ai, statistics, archive, downloads
    var id: String { rawValue }
    var page: IslandPage {
        // 2026-11-26 修复：原 `IslandPage(rawValue: rawValue)!` 依赖两枚举一一对应，
        // 新增 widget 而没有同名 page 会运行时崩溃。改为解析失败回退首页。
        if self == .volume { return .media }
        return IslandPage(rawValue: rawValue) ?? .home
    }
    var title: String {
        switch self {
        case .media: return "正在播放"
        case .monitor: return "性能监测"
        case .clipboard: return "剪贴板与中转"
        case .calendar: return "日程与待办"
        case .tools: return "快捷工具"
        case .volume: return "系统音量"
        case .search: return "全局搜索"
        case .capture: return "截图与标注"
        case .recording: return "录屏"
        case .ocr: return "识别与翻译"
        case .transfer: return "中转站与传输"
        case .cast: return "手机投屏"
        case .ai: return "AI 对话"
        case .statistics: return "使用统计"
        case .archive: return "压缩与解压"
        case .downloads: return "网盘与下载"
        }
    }
    var icon: String {
        switch self {
        case .media: return "music.note"
        case .monitor: return "waveform.path.ecg"
        case .clipboard: return "doc.on.clipboard"
        case .calendar: return "calendar"
        case .tools: return "square.grid.2x2"
        case .volume: return "speaker.wave.2"
        case .search: return "magnifyingglass"
        case .capture: return "viewfinder"
        case .recording: return "record.circle"
        case .ocr: return "text.viewfinder"
        case .transfer: return "arrow.up.arrow.down"
        case .cast: return "iphone.and.arrow.forward"
        case .ai: return "bubble.left.and.bubble.right"
        case .statistics: return "chart.bar"
        case .archive: return "archivebox"
        case .downloads: return "arrow.down.circle"
        }
    }
    var color: Color {
        switch self {
        case .monitor: return MonitorColors.user
        case .media: return MonitorColors.wired
        case .calendar: return MonitorColors.temperature
        case .clipboard: return MonitorColors.download
        case .tools: return MonitorColors.memory
        case .volume: return MonitorColors.battery
        case .search: return MonitorColors.download
        case .capture: return MonitorColors.user
        case .recording: return MonitorColors.temperature
        case .ocr: return MonitorColors.memory
        case .transfer: return MonitorColors.download
        case .cast: return MonitorColors.wired
        case .ai: return MonitorColors.wired
        case .statistics: return MonitorColors.memory
        case .archive: return MonitorColors.temperature
        case .downloads: return MonitorColors.download
        }
    }
}

enum IslandMetric: String, CaseIterable, Codable, Identifiable {
    case cpu, gpu, memory, network, power, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .power: return "整机功耗"
        case .battery: return "电池"
        }
    }
    var unit: String {
        switch self {
        case .cpu, .gpu, .battery: return "%"
        case .memory: return "GB"
        case .network: return "KB/s"
        case .power: return "W"
        }
    }
    var upperBound: Double {
        switch self {
        case .cpu, .gpu, .battery: return 100
        case .memory: return 16
        case .network: return 60
        case .power: return 14
        }
    }
    var color: Color {
        switch self {
        case .cpu: return MonitorColors.user
        case .gpu: return MonitorColors.wired
        case .memory: return MonitorColors.memory
        case .network: return MonitorColors.download
        case .power: return MonitorColors.temperature
        case .battery: return MonitorColors.battery
        }
    }
    var values: [Double] {
        switch self {
        case .cpu: return [8, 10, 9, 12, 18, 15, 11, 9, 8, 10, 16, 22, 17, 12, 11, 14, 19, 16, 11, 8, 9, 14, 16, 12]
        case .gpu: return [2, 3, 3, 5, 8, 6, 4, 2, 3, 4, 5, 10, 14, 11, 7, 5, 4, 3, 6, 12, 15, 10, 7, 8]
        case .memory: return [6.0, 6.0, 6.1, 6.1, 6.2, 6.3, 6.3, 6.2, 6.2, 6.3, 6.4, 6.4, 6.5, 6.6, 6.6, 6.5, 6.4, 6.4, 6.3, 6.3, 6.4, 6.5, 6.4, 6.4]
        case .network: return [3, 8, 28, 40, 15, 6, 2, 4, 16, 52, 42, 14, 5, 2, 6, 18, 36, 24, 10, 4, 8, 25, 32, 18]
        case .power: return [6.4, 6.7, 7.2, 8.4, 9.5, 8.8, 7.5, 6.8, 6.5, 7.2, 8.6, 10.2, 11.3, 9.6, 8.2, 7.8, 8.5, 9.4, 10.1, 9.2, 8.1, 8.4, 9.2, 8.6]
        case .battery: return [85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 85, 84, 84, 84, 84, 84, 84, 84, 84, 84]
        }
    }
    func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(unit == "%" || unit == "KB/s" ? 0 : 1))) + " " + unit
    }
}

extension Array where Element: Equatable {
    mutating func islandMove(_ item: Element, to destination: Int) {
        let index = firstIndex(of: item)!
        remove(at: index)
        insert(item, at: destination)
    }
}

enum IslandLayout {
    static let inset: CGFloat = Theme.Space.lg
    static let corner: CGFloat = 28
    static let horizontalInset = inset + corner * 0.45
    static let collapsedRadius: CGFloat = Theme.Radius.chip
    static let cardRadius: CGFloat = corner - inset
    static let controlRadius: CGFloat = Theme.Radius.control
    // 2026-11-23：IslandLayout.tint（黑 0.32）已删——它是「黑幕与 tint 双铺」时代
    // 的残留常量，零引用；现展开态深色程度只由 IslandMaterialView.tint(shellOpacity) 一层负责。
    static let cardFill = Color.white.opacity(0.035)
    static let cardStroke = Color.white.opacity(0.08)
}

struct IslandSample: Identifiable {
    let id: Int
    let title: String
    let icon: String
    let detail: String
    let body: String
    var children: [String] = []
    static let clipboard: [Self] = [
        .init(id: 0, title: "周五交付清单", icon: "text.alignleft", detail: "文本 · 备忘录 · 刚刚",
              body: "周五交付清单\n\n1. 完成首页和剪贴板的交互\n2. 统一预览窗口与动效\n3. 核对保存、取消与恢复默认\n4. 更新用户手册"),
        .init(id: 1, title: "Apple 设计资源", icon: "link", detail: "链接 · Safari · 2 分钟前",
              body: "https://developer.apple.com/design/\n\nApple 平台设计资源与界面指南。"),
        .init(id: 2, title: "项目笔记.json", icon: "curlybraces", detail: "代码 · 编辑器 · 5 分钟前",
              body: "{\n  \"project\": \"Kitnest\",\n  \"layout\": \"notch\",\n  \"preview\": \"live\",\n  \"apply\": \"onSave\"\n}"),
        .init(id: 3, title: "交互说明", icon: "text.alignleft", detail: "长文本 · 编辑器 · 8 分钟前",
              body: "刘海是一个轻量入口。展开后，首页展示近期内容与常用组件；剪贴板和中转采用列表与详情两栏。\n\n同一窗口从顶部中心展开，切换页面时调整外形，正文保持可读。\n\n悬停不会打断正在使用的应用。主动选择页面后，可以用键盘继续操作。\n\n关闭后，刘海恢复原来的尺寸；下次打开保留当前记录与滚动位置。\n\n此处为固定演示内容，所有操作只作用于当前界面。\n\n长文本在详情区域独立滚动，列表和顶部导航保持原位。"),
        .init(id: 4, title: "首页说明.png", icon: "photo", detail: "图片 · 截图 · 10 分钟前", body: "首页交互说明"),
        .init(id: 5, title: "设计资料", icon: "folder", detail: "文件夹 · Finder · 12 分钟前", body: "Documents/设计资料",
              children: ["首页设计.fig", "交互说明.md", "图标素材/"])
    ]
    static let files: [Self] = [
        .init(id: 0, title: "设计资料", icon: "folder", detail: "文件夹 · 3 项", body: "~/Documents/设计资料",
              children: ["首页设计.fig", "交互说明.md", "图标素材/"]),
        .init(id: 1, title: "设计说明.md", icon: "doc.text", detail: "文档 · 12 KB",
              body: "刘海承载快捷操作和近期内容。\n\n文字、链接和代码放在剪贴板。\n文件、文件夹放在中转。"),
        .init(id: 2, title: "长截图.png", icon: "photo", detail: "图片 · 364 KB", body: "首页交互说明"),
        .init(id: 3, title: "项目素材.zip", icon: "archivebox", detail: "压缩包 · 1.2 MB", body: "~/Downloads/项目素材.zip",
              children: ["封面.png", "图标素材/", "README.md"])
    ]
}
