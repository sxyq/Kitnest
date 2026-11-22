import AppKit
import Combine
import SwiftUI

// MARK: - 设置窗口侧边栏（v41 大侧边栏结构 / v234 分组 + 搜索）
//
// v234（用户：「设置选项需要进一步分类整理……确保用户能够快速的找到」）：
//   ① 侧边栏按「常用 / 截图 / 工具 / 性能监测」分组，不再是一条长列表；
//   ② 顶部加设置搜索：输入关键词直接列出「设置项 → 所在页」，
//      点一下跳过去（含子页签），不用记它在哪个分类里；
//   ③ 「截图」独立成一级——截图/钉图/水印/识别都在这，不再埋在「工具与快捷键」里。

// v272：`SettingsCategory` / `SettingsSidebarSelection` 已由
// `SettingsNavigation.swift` 的「一级目录 SettingsGroup + 二级页 SettingsPage」
// 取代——侧边栏、内容区、深链、搜索索引共用同一份页枚举。

/// v271（用户：「这些选项都进行拆分」，选择「拆回侧边栏独立项」）：
/// 原 CaptureHubPane 把五块（截图/钉图/图帘/录屏/工作流）串成一条长滚动；
/// 现在每块是一个侧边栏入口，标题、副标题、图标由本枚举统一提供。
enum CaptureSettingsBlock: String, CaseIterable, Identifiable, Hashable {
    case capture, pin, curtain, recording, workflow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture:   return "截图"
        case .pin:       return "钉图"
        case .curtain:   return "图帘"
        case .recording: return "录屏"
        case .workflow:  return "工作流"
        }
    }

    var subtitle: String {
        switch self {
        case .capture:   return "保存位置、截图后动作、比例、水印、文字识别"
        case .pin:       return "钉住之后的边框、圆角、投影与工具条"
        case .curtain:   return "截图后挂到屏幕顶边的帘线上，临时暂存"
        case .recording: return "整屏或区域录制，可叠加摄像头、按键与点击动画"
        case .workflow:  return "截图后自动保存、识别、上传、建 GitHub / Linear issue"
        }
    }

    var icon: String {
        switch self {
        case .capture:   return "camera.viewfinder"
        case .pin:       return "pin"
        case .curtain:   return "photo.on.rectangle.angled"
        case .recording: return "record.circle"
        case .workflow:  return "arrow.triangle.branch"
        }
    }

    /// 旧深链 / 搜索里的数字下标（0…4）兼容
    init?(legacyIndex: Int) {
        guard CaptureSettingsBlock.allCases.indices.contains(legacyIndex) else { return nil }
        self = CaptureSettingsBlock.allCases[legacyIndex]
    }
}

/// 设置搜索条目：一个「用户会怎么找」的入口，指向具体页 + 子页签
struct SettingsSearchEntry: Identifiable {
    let id = UUID()
    let title: String
    let area: String
    let keywords: String
    /// 目标二级页（v272：一个条目直接落到一页，不再有「页内第几段」）
    let selection: SettingsPage
    var field: String? = nil

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
    @EnvironmentObject private var editingSession: SettingsEditingSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { MonitorColors.user }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            searchField
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    if trimmedQuery.isEmpty {
                        navigation
                    } else {
                        searchResults
                    }
                }
                // v271：导航区不能画到常驻页脚下面。
                .clipped()
                // v272（2026-11-11，用户：「选中 general 但侧栏停在中部」）：
                // 同页深链也要定位；接收每次赋值，等导航内容更新后再滚动。
                .onChange(of: state.navigationRevision) { _ in
                    let page = state.selection
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            proxy.scrollTo(page, anchor: .center)
                        }
                    }
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
        state.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 分组导航

    private var navigation: some View {
        // 一级目录独立展开，二级页面保持当前选中内容。
        // 一级标题可点（跳到该组第一页），二级行才承载选中态。
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsGroup.allCases) { group in
                groupHeader(group)
                if state.expandedGroups.contains(group) {
                    // v282：所有目录都是三级——一级标题 → 二级小节 → 三级页面。
                    // 单页小节（如「权限」「录屏」）渲染成不可折叠的小标题 + 一页，
                    // 层级看得见，但不会为了点一页多按一次。
                    ForEach(group.sections) { section in
                        let collapsedCaption = section.pages.count == 1
                        sectionHeader(section, isCaption: collapsedCaption)
                        if collapsedCaption || state.expandedSections.contains(section.id) {
                            ForEach(section.pages, id: \.self) { page in
                                navRow(page, leading: 38).id(page)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    /// 一级目录只展开或收起，不改变右侧选中页。
    private func groupHeader(_ group: SettingsGroup) -> some View {
        let expanded = state.expandedGroups.contains(group)
        return Button {
            if expanded {
                state.expandedGroups.remove(group)
            } else {
                state.expandedGroups.insert(group)
                // v282：展开目录时把这一组的小节全部展开。以前只展开一节，
                // 点开「入口与交互」只看到四个小节名，还要再点一次才见页面。
                for section in group.sections { state.expandedSections.insert(section.id) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: group.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.primary.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "收起\(group.title)" : "展开\(group.title)")
        .accessibilityValue(expanded ? "已展开" : "已收起")
        .padding(.top, 8)
    }

    /// 二级小节：可折叠标题行，比一级目录轻、比页面行重。
    /// - Parameter isCaption: 单页小节——只做分层用的小标题，不可折叠（避免多点一次）。
    private func sectionHeader(_ section: SettingsSidebarSection, isCaption: Bool = false) -> some View {
        let expanded = isCaption || state.expandedSections.contains(section.id)
        return Button {
            guard !isCaption else { return }
            if expanded { state.expandedSections.remove(section.id) }
            else { state.expandedSections.insert(section.id) }
        } label: {
            HStack(spacing: 5) {
                if isCaption {
                    // 单页小节：用一个小圆点占位，保持与可折叠小节的视觉对齐
                    Circle()
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 3, height: 3)
                        .frame(width: 10)
                } else {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 10)
                }
                Text(section.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .frame(height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCaption ? section.title : (expanded ? "收起\(section.title)" : "展开\(section.title)"))
        .accessibilityValue(expanded ? "已展开" : "已收起")
        .padding(.top, 3)
    }

    /// 三级页轻量缩进行，保留单行选中反馈。
    private func navRow(_ page: SettingsPage, leading: CGFloat = 24) -> some View {
        let selected = state.selection == page
        return Button {
            state.detailPaneID = nil
            state.selection = page
        } label: {
            HStack(spacing: 7) {
                Text(page.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accent : Color.primary.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if editingSession.isDirty(page: page) {
                    Circle().fill(Color.orange).frame(width: 5, height: 5)
                        .accessibilityLabel("未保存")
                }
            }
            .padding(.leading, leading)
            .padding(.trailing, 8)
            .frame(height: 25)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(accent.opacity(0.15))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(page.title)
    }

    // MARK: - 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            TextField("搜索设置", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
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
                        Text(entry.selection.path)
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
        state.reveal(entry.selection, field: entry.field)
    }

    /// 设置索引：标题 = 用户嘴里的说法，keywords = 同义词/部件名。
    /// v272：每条直接指向一个二级页（`SettingsPage`），不再带「页内第几段」。
    private static let searchIndex: [SettingsSearchEntry] =
        SettingsGroup.allCases.flatMap { group in
            group.pages.map { page in
                SettingsSearchEntry(title: page.title, area: page.path,
                    keywords: page.openHint ?? "", selection: page)
            }
        } + [
            .init(title: "开机启动", area: "常规 › 启动与语言", keywords: "登录 自启", selection: .generalStart, field: "开机启动"),
            .init(title: "共享字号与圆角", area: "主题外观 › 文字与圆角", keywords: "字体 行高", selection: .appearanceText),
            .init(title: "强调色", area: "主题外观 › 主题与颜色", keywords: "accent 主题色", selection: .generalPersonal, field: "强调色"),
            .init(title: "底衬不透明度", area: "主题外观 › 窗口材质与动效", keywords: "透明 毛玻璃 磨砂 描边", selection: .generalWindows, field: "底衬不透明度"),
            .init(title: "间距与分隔线", area: "菜单栏 › 排列与间距", keywords: "状态栏 合并 spacing", selection: .menuBarArrangement),
            .init(title: "自动图片 OCR", area: "剪贴板 › 捕获与隐私", keywords: "图片识别 自动识别", selection: .clipboardCapture),
            .init(title: "忽略应用（隐私名单）", area: "剪贴板 › 捕获与隐私", keywords: "黑名单 隐私 排除", selection: .clipboardCapture, field: "忽略应用（隐私名单）"),
            .init(title: "保留天数", area: "剪贴板 › 历史与备份", keywords: "历史 到期 清理 容量", selection: .clipboardHistory, field: "保留天数"),
            .init(title: "标签管理", area: "剪贴板 › 历史与备份", keywords: "分类 tag", selection: .clipboardHistory, field: "标签管理"),
            .init(title: "浮动剪贴板快捷键", area: "快捷键 › 全部功能绑定", keywords: "悬浮 呼出 双按", selection: .shortcuts, field: "floatingClipboard"),
            .init(title: "取色快捷键", area: "快捷键 › 全部功能绑定", keywords: "colorPicker colorpicker", selection: .shortcuts, field: "colorpicker"),
            .init(title: "图帘快捷键", area: "快捷键 › 全部功能绑定", keywords: "悬挂 截图", selection: .shortcuts, field: "curtainToggle"),
            .init(title: "截图保存路径", area: "截图与录屏 › 截图与保存", keywords: "目录 文件名", selection: .capture(.capture)),
            .init(title: "文字识别语言", area: "截图与录屏 › 文字识别", keywords: "OCR 中文 英文 静默", selection: .ocr),
            .init(title: "ZIP 关联与 Finder 服务", area: "文件与传输 › 压缩与 Finder", keywords: "压缩 解压 复制路径 终端 访达", selection: .archive),
            .init(title: "日历周起始日", area: "工具 › 日历", keywords: "周日 周一 农历 日程", selection: .calendar),
            .init(title: "监测模块与独立刷新间隔", area: "性能监测 › 采样与显示", keywords: "CPU GPU 内存 网络 磁盘 温度 功耗 电池 采样", selection: .monitorSettings),
            .init(title: "使用统计与音量", area: "工具 › 工具集合", keywords: "设备 混音器 统计 音频", selection: .tools),
            .init(title: "使用手册", area: "页脚", keywords: "帮助 文档 教程", selection: .manual)
        ]

    // MARK: - 品牌区

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 20)
            Text(verbatim: "Kitnest Lite")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        // 左侧留 44：让开窗口左上角的官方圆形关闭钮（14pt 圆 + 14pt 边距）
        .padding(.leading, 44)
        .padding(.trailing, 14)
        .frame(height: 44)
    }

    // MARK: - 行

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
            // v271：截图拆成五个侧边栏项后导航变长，原来的竖排页脚（3×30）把
            // 「性能监测」整组挤到折叠线以下。这三项改成一行紧凑入口（图标 + 小字），
            // 高度从 ~120 降到 ~58，常驻可见且不抢纵向空间。
            HStack(spacing: 2) {
                footerChip("使用手册", icon: "book.closed", selection: .manual)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)

            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .frame(width: 16)
                    .foregroundStyle(Theme.tertiaryText)
                Text(verbatim: "Kitnest Lite v1.0.0")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 22)
        }
    }

    /// 页脚紧凑入口：图标在上、小字在下，宽度均分
    private func footerChip(_ title: String, icon: String,
                            selection: SettingsPage) -> some View {
        let on = state.selection == selection
        return Button {
            state.selection = selection
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Theme.accent : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
