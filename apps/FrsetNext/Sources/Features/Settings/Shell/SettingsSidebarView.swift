import AppKit
import SwiftUI

// MARK: - 设置窗口侧边栏（v41 大侧边栏结构 / v234 分组 + 搜索）
//
// v234（用户：「设置选项需要进一步分类整理……确保用户能够快速的找到」）：
//   ① 侧边栏按「常用 / 截图 / 工具 / 性能监测」分组，不再是一条长列表；
//   ② 顶部加设置搜索：输入关键词直接列出「设置项 → 所在页」，
//      点一下跳过去（含子页签），不用记它在哪个分类里；
//   ③ 「截图」独立成一级——截图/钉图/水印/识别都在这，不再埋在「工具与快捷键」里。

/// 设置项归类
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case clipboard
    /// 文件中转（面板入口 / 手机扫码直传 / OPPO 云端通道 / 本地暂存）
    case transfer
    /// v234：截图与钉图（原来埋在「工具与快捷键 → 截图」里）
    case capture
    case searchAI
    case tooling
    case statistics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .clipboard: return "剪贴板"
        case .transfer: return "文件中转"
        case .capture: return "截图与钉图"
        case .searchAI: return "搜索与 AI"
        case .tooling: return "工具与快捷键"
        case .statistics: return "数据"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .clipboard: return "doc.on.clipboard"
        case .transfer: return "arrow.left.arrow.right.square"
        case .capture: return "camera.viewfinder"
        case .searchAI: return "magnifyingglass"
        case .tooling: return "hammer"
        case .statistics: return "chart.bar.xaxis"
        case .about: return "info.circle"
        }
    }
}

/// 侧边栏选中项
enum SettingsSidebarSelection: Hashable {
    case category(SettingsCategory)
    case monitorModule(MonitorModuleID)
    case monitorSettings
    /// v54：内嵌 STATS 部件设置（形态/颜色/间距/每模块选项，功能对齐 Stats）
    case monitorWidgets
    /// v88：使用手册（交互式树形手册，2026-10-20 用户需求）
    case manual
}

/// 设置搜索条目：一个「用户会怎么找」的入口，指向具体页 + 子页签
struct SettingsSearchEntry: Identifiable {
    let id = UUID()
    let title: String
    let area: String
    let keywords: String
    /// 目标位置（分类 / 性能模块 / 监测设置 / 部件设置）
    let selection: SettingsSidebarSelection
    /// 页内分段（-1 = 不分段）
    var subTab: Int = -1

    /// 只匹配标题与关键词：区域名（"截图与钉图"）会把整组条目都带出来，
    /// 实测搜"钉图"命中 12 条、真正的钉图设置只有 5 条。
    func matches(_ needle: String) -> Bool {
        let n = needle.lowercased()
        return title.lowercased().contains(n) || keywords.lowercased().contains(n)
    }
}

/// 侧边栏视图（宽 186，整窗高）
struct SettingsSidebarView: View {
    @ObservedObject var state: SettingsUIState
    @Environment(\.colorScheme) private var colorScheme
    /// 初值读 probe.settingsSearch：无键盘模拟权限时靠它验收搜索结果
    @Stored private var query: String = UserDefaults.standard.string(forKey: "probe.settingsSearch") ?? ""

    /// 性能监测二级目录顺序（与性能页标签行一致；功耗不单列）
    private static let monitorModules: [MonitorModuleID] = [
        .cpu, .memory, .gpu, .disk, .network, .sensors, .battery
    ]

    private var accent: Color { MonitorColors.user }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            searchField
            ScrollView(.vertical, showsIndicators: false) {
                if trimmedQuery.isEmpty {
                    navigation
                } else {
                    searchResults
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(width: Theme.settingsSidebarWidth)
        .background(
            Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035))
        )
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 分组导航

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 1) {
            groupTitle("常用")
            navRow(.general)
            navRow(.clipboard)
            navRow(.transfer)

            groupTitle("截图").padding(.top, 12)
            navRow(.capture)

            groupTitle("工具").padding(.top, 12)
            navRow(.searchAI)
            navRow(.tooling)

            groupTitle("性能监测").padding(.top, 12)
            ForEach(Self.monitorModules, id: \.self) { module in
                navRow(title: module == .sensors ? "传感器" : module.displayName,
                       icon: module.systemImage,
                       selected: state.selection == .monitorModule(module)) {
                    state.selection = .monitorModule(module)
                }
            }
            navRow(title: "监测设置",
                   icon: "slider.horizontal.3",
                   selected: state.selection == .monitorSettings) {
                state.selection = .monitorSettings
            }
            navRow(title: "部件设置",
                   icon: "menubar.rectangle",
                   selected: state.selection == .monitorWidgets) {
                state.selection = .monitorWidgets
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func navRow(_ category: SettingsCategory) -> some View {
        navRow(title: category.title,
               icon: category.systemImage,
               selected: state.selection == .category(category)) {
            state.selection = .category(category)
        }
    }

    // MARK: - 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            TextField("搜索设置", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var searchResults: some View {
        let needle = trimmedQuery
        let hits = Self.searchIndex.filter { $0.matches(needle) }
        return VStack(alignment: .leading, spacing: 1) {
            Text(hits.isEmpty ? "没有匹配的设置" : "找到 \(hits.count) 项")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ForEach(hits) { entry in
                Button {
                    navigate(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .lineLimit(1)
                        Text(entry.area)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func navigate(_ entry: SettingsSearchEntry) {
        state.selection = entry.selection
        if case .category(let category) = entry.selection, entry.subTab >= 0 {
            switch category {
            case .searchAI: state.searchAISub = entry.subTab
            case .tooling:  state.toolingSub = entry.subTab
            case .capture:
                // v262：截图那三块不再分页签，`captureSub` 变成「滚到哪一块」。
                // 它是指令不是状态——重复搜同一个词时值没变，onChange 不会触发，
                // 页面就不会滚过去。所以值相同时先归零再设回去。
                let target = entry.subTab
                if state.captureSub == target {
                    state.captureSub = -1
                    DispatchQueue.main.async { state.captureSub = target }
                } else {
                    state.captureSub = target
                }
            default: break
            }
        }
        query = ""
    }

    /// 设置索引：标题 = 用户嘴里的说法，keywords = 同义词/部件名
    private static let searchIndex: [SettingsSearchEntry] = [
        // 常规
        .init(title: "开机启动", area: "常规", keywords: "登录 自启 启动项", selection: .category(.general)),
        .init(title: "外观（浅色 / 深色 / Midnight）", area: "常规", keywords: "主题 配色 暗色 深色模式 午夜", selection: .category(.general)),
        .init(title: "语言", area: "常规", keywords: "中文 英文 language", selection: .category(.general)),
        .init(title: "菜单栏图标", area: "常规", keywords: "状态栏 图标 logo 风扇 日期", selection: .category(.general)),
        .init(title: "标签管理", area: "常规", keywords: "标签 tag 分类", selection: .category(.general)),
        .init(title: "忽略应用（隐私名单）", area: "常规", keywords: "隐私 排除 黑名单", selection: .category(.general)),
        .init(title: "个性化（圆角 / 密度 / 字体）", area: "常规", keywords: "字号 行高 缩略图 强调色", selection: .category(.general)),
        // 剪贴板
        .init(title: "剪贴板历史", area: "剪贴板", keywords: "条数 保留 清理 上限", selection: .category(.clipboard)),
        .init(title: "自动粘贴", area: "剪贴板", keywords: "回车 粘贴 自动", selection: .category(.clipboard)),
        // 文件中转
        .init(title: "文件中转", area: "文件中转", keywords: "暂存 传输 扫码 手机", selection: .category(.transfer)),
        // 截图与钉图
        .init(title: "截图保存路径", area: "截图", keywords: "下载 目录 文件夹 保存位置", selection: .category(.capture), subTab: 0),
        .init(title: "截图后动作", area: "截图", keywords: "复制 保存 贴图 默认动作", selection: .category(.capture), subTab: 0),
        .init(title: "延时截图", area: "截图", keywords: "倒计时 3 秒 5 秒 10 秒", selection: .category(.capture), subTab: 0),
        .init(title: "提示音", area: "截图", keywords: "声音 快门 音效", selection: .category(.capture), subTab: 0),
        .init(title: "水印", area: "截图", keywords: "文字 平铺 倾斜 透明度", selection: .category(.capture), subTab: 0),
        .init(title: "文字识别语言", area: "截图", keywords: "OCR 识别 语言 自动检测", selection: .category(.capture), subTab: 0),
        .init(title: "截图权限（屏幕录制）", area: "截图", keywords: "权限 授权 录屏 辅助功能", selection: .category(.capture), subTab: 0),
        .init(title: "钉图外观（描边 / 圆角 / 阴影）", area: "钉图", keywords: "钉住 贴图 悬浮 边框 投影 预设", selection: .category(.capture), subTab: 1),
        .init(title: "钉图不透明度", area: "钉图", keywords: "透明 alpha 半透明", selection: .category(.capture), subTab: 1),
        .init(title: "钉图自动吸附", area: "钉图", keywords: "对齐 边缘 磁吸 magnet", selection: .category(.capture), subTab: 1),
        .init(title: "钉图控制条自动收起", area: "钉图", keywords: "工具条 悬停 收起 隐藏", selection: .category(.capture), subTab: 1),
        .init(title: "钉图快捷键", area: "钉图", keywords: "标注 拷贝 关闭 Esc A C M", selection: .category(.capture), subTab: 1),
        // 工具
        .init(title: "搜索", area: "搜索", keywords: "全局搜索 命令 面板", selection: .category(.searchAI), subTab: 0),
        .init(title: "AI 服务", area: "AI", keywords: "模型 key 接口 翻译", selection: .category(.searchAI), subTab: 1),
        .init(title: "工具开关", area: "工具", keywords: "归档 解压 二维码 取色", selection: .category(.tooling), subTab: 0),
        .init(title: "快捷键", area: "快捷键", keywords: "热键 组合键 冲突", selection: .category(.tooling), subTab: 1),
        // 监测
        .init(title: "性能监测", area: "性能监测", keywords: "CPU 内存 GPU 磁盘 网络 传感器 电池", selection: .monitorModule(.cpu)),
        .init(title: "监测设置", area: "性能监测", keywords: "刷新 频率 采样", selection: .monitorSettings),
        .init(title: "部件设置", area: "性能监测", keywords: "状态栏 部件 形态 颜色", selection: .monitorWidgets),
        // 数据 / 关于
        .init(title: "使用统计", area: "数据", keywords: "统计 事件 报表", selection: .category(.statistics)),
        .init(title: "版本与更新", area: "关于", keywords: "版本 更新 检查", selection: .category(.about)),
    ]

    // MARK: - 品牌区

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 20)
            Text(verbatim: "Kitnest")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        // 左侧留 44：让开窗口左上角的官方圆形关闭钮（14pt 圆 + 14pt 边距）
        .padding(.leading, 44)
        .padding(.trailing, 14)
        .frame(height: 50)
    }

    // MARK: - 行

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 9)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func navRow(title: String, icon: String, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? accent : Color.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accent : Color.primary.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(accent.opacity(0.15))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    /// 页脚常驻入口（数据 / 关于 / 使用手册）
    private func footerRow(_ title: String, icon: String,
                           selection: SettingsSidebarSelection) -> some View {
        Button {
            state.selection = selection
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(state.selection == selection ? Theme.accent : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
            // v234：数据 / 关于 / 使用手册 常驻页脚——列表里 7 个性能模块已经要滚动，
            // 这三项再放列表末尾就彻底找不到了
            footerRow("数据", icon: "chart.bar.xaxis", selection: .category(.statistics))
            footerRow("关于", icon: "info.circle", selection: .category(.about))
            footerRow("使用手册", icon: "book.closed", selection: .manual)
            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(Theme.tertiaryText)
                Text(verbatim: "Kitnest v1.0.0")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
    }
}
