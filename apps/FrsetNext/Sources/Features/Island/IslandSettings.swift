import SwiftUI

/// Demo 只保留显示状态，不读写正式配置和用户内容。
enum IslandPage: String, CaseIterable, Identifiable {
    case home, clipboard, transfer, monitor, media, calendar, tools, settings
    var id: String { rawValue }
    static let tabs: [Self] = [.home, .clipboard, .transfer]
    var title: String {
        switch self {
        case .home: return "首页"
        case .clipboard: return "剪贴板"
        case .transfer: return "中转"
        case .monitor: return "系统监测"
        case .media: return "正在播放"
        case .calendar: return "日历"
        case .tools: return "快捷工具"
        case .settings: return "刘海与组件"
        }
    }
}

struct IslandConfiguration {
    var width: CGFloat = 560
    let hoverDelay = 0.10
    let collapseDelay = 0.18
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
              body: "{\n  \"project\": \"Kitnest\",\n  \"layout\": \"notch\",\n  \"preview\": \"live\",\n  \"apply\": \"onSave\"\n}")
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
