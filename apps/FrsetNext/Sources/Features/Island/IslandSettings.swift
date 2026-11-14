import AppKit
import SwiftUI

/// 页面内容为固定演示；快捷复制单独读取系统剪贴板快照。
enum IslandPage: String, CaseIterable, Identifiable {
    case home, clipboard, transfer, monitor, media, calendar, tools, settings
    var id: String { rawValue }
    static let tabs: [Self] = [.home, .clipboard, .transfer, .monitor]
    var title: String {
        switch self {
        case .home: return "总览"
        case .clipboard: return "剪贴板"
        case .transfer: return "中转"
        case .monitor: return "监测"
        case .media: return "媒体"
        case .calendar: return "日历"
        case .tools: return "工具"
        case .settings: return "刘海与组件"
        }
    }
}

struct IslandConfiguration {
    var width: CGFloat = 780
    var height: CGFloat = 440
    let hoverDelay = 0.10
    let collapseDelay = 0.18
}

enum IslandPeek: String, CaseIterable, Identifiable {
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
    var page: IslandPage {
        switch self {
        case .clipboard: return .clipboard
        case .media: return .media
        case .calendar: return .calendar
        case .monitor: return .monitor
        }
    }
}

enum IslandWidget: String, CaseIterable, Identifiable {
    case media, monitor, clipboard, transfer, calendar, tools
    var id: String { rawValue }
    var page: IslandPage { IslandPage(rawValue: rawValue)! }
    var title: String {
        switch self {
        case .media: return "正在播放"
        case .monitor: return "性能监测"
        case .clipboard: return "近期复制"
        case .transfer: return "文件中转"
        case .calendar: return "日程与待办"
        case .tools: return "快捷工具"
        }
    }
    var icon: String {
        switch self {
        case .media: return "music.note"
        case .monitor: return "waveform.path.ecg"
        case .clipboard: return "doc.on.clipboard"
        case .transfer: return "tray"
        case .calendar: return "calendar"
        case .tools: return "square.grid.2x2"
        }
    }
}

enum IslandMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, network, power, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .network: return "网络下载"
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
    static let inset: CGFloat = 14
    static let corner: CGFloat = 38
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
    static let tint = NSColor.black.withAlphaComponent(0.32)
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
