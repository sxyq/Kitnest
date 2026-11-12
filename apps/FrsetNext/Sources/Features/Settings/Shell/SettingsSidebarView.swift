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
                .onReceive(state.$selection.combineLatest(state.$query)) { page, query in
                    guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.18)) {
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
        // v272：一级目录（SettingsGroup）+ 常驻展开的二级页（SettingsPage）。
        // 一级标题可点（跳到该组第一页），二级行才承载选中态。
        VStack(alignment: .leading, spacing: 1) {
            ForEach(SettingsGroup.allCases) { group in
                groupHeader(group)
                ForEach(group.pages, id: \.self) { page in
                    navRow(page)
                        .id(page)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    /// 一级目录行：图标 + 名称，点一下跳到该组第一页
    private func groupHeader(_ group: SettingsGroup) -> some View {
        let on = SettingsGroup.group(of: state.selection) == group
        return Button {
            if let first = group.pages.first { state.selection = first }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: group.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? accent : Color.primary.opacity(0.72))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(group.title)（点标题跳到「\(group.pages.first?.title ?? "")」）")
        .padding(.top, 8)
    }

    /// 二级页行：缩进 + 小图标，选中态用强调色胶囊
    private func navRow(_ page: SettingsPage) -> some View {
        let selected = state.selection == page
        return Button {
            state.selection = page
        } label: {
            HStack(spacing: 7) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? accent : Color.secondary.opacity(0.9))
                Text(page.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accent : Color.primary.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
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
        // v272：每条搜索直接落到一个二级页
        state.selection = entry.selection
        state.query = ""
    }

    /// 设置索引：标题 = 用户嘴里的说法，keywords = 同义词/部件名。
    /// v272：每条直接指向一个二级页（`SettingsPage`），不再带「页内第几段」。
    private static let searchIndex: [SettingsSearchEntry] = [
        // 常规 · 启动与外观
        .init(title: "开机启动", area: "常规 › 启动与外观", keywords: "登录 自启 启动项", selection: .generalStart),
        .init(title: "ZIP 默认打开方式", area: "常规 › 启动与语言", keywords: "ZIP 压缩 解压 默认应用 关联 访达 服务", selection: .generalStart),
        .init(title: "外观（浅色 / 深色 / Midnight）", area: "常规 › 主题外观", keywords: "主题 配色 暗色 深色模式 午夜", selection: .generalPersonal),
        .init(title: "语言", area: "常规 › 启动与外观", keywords: "中文 英文 language", selection: .generalStart),
        // 常规 · 主面板
        .init(title: "主面板（字号 / 圆角 / 宽度 / 背景图）", area: "常规 › 主面板", keywords: "字号 行高 圆角 宽度 面板页面 顺序 打开动画 背景图", selection: .generalPanel),
        .init(title: "外观预览（主面板）", area: "常规 › 主面板", keywords: "预览 实时 缩略窗 所见即所得", selection: .generalPanel),
        // 常规 · 独立窗口与浮层
        .init(title: "窗口材质（玻璃 / 通透度 / 磨砂）", area: "常规 › 窗口材质", keywords: "玻璃 通透度 磨砂 描边 卡片亮度 材质 浮层", selection: .generalWindows),
        .init(title: "通知提示（时长 / 位置）", area: "常规 › 通知提示", keywords: "通知条 Toast 时长 位置 跟随主面板", selection: .generalNotifications),
        .init(title: "列表外观（密度 / 缩略图 / 徽章）", area: "剪贴板 › 列表外观", keywords: "密度 缩略图 来源徽章 预览", selection: .clipboardAppearance),
        .init(title: "截图动作条外观", area: "截图 › 动作条外观", keywords: "动作条 图标条 药丸条 主次分离 排布", selection: .captureActions),
        // 常规 · 个性化
        .init(title: "主题外观（强调色 / Midnight）", area: "常规 › 主题外观", keywords: "强调色 主题色 恢复默认", selection: .generalPersonal),
        // 常规 · 菜单栏
        .init(title: "菜单栏图标", area: "常规 › 菜单栏", keywords: "状态栏 图标 logo 风扇 日期 小猫", selection: .generalMenuBar),
        .init(title: "菜单栏功能开关", area: "常规 › 菜单栏", keywords: "系统监控 日历 截图检索 文件中转", selection: .generalMenuBar),
        .init(title: "AI 服务商", area: "常规 › 菜单栏", keywords: "provider key 模型", selection: .generalMenuBar),
        .init(title: "菜单栏部件", area: "常规 › 菜单栏", keywords: "合并条 状态栏部件", selection: .generalMenuBar),
        // 音频
        .init(title: "音频混音器", area: "音频 › 音频混音器", keywords: "系统音量 静音 输出设备 有声 App 声音 audio mixer", selection: .audio),
        // 剪贴板
        .init(title: "剪贴板历史", area: "剪贴板 › 历史", keywords: "条数 保留 清理 上限 占用", selection: .clipboardHistory),
        .init(title: "标签管理", area: "剪贴板 › 历史", keywords: "标签 tag 分类", selection: .clipboardHistory),
        .init(title: "自动粘贴", area: "剪贴板 › 捕获", keywords: "回车 粘贴 自动 辅助功能", selection: .clipboardCapture),
        .init(title: "忽略应用（隐私名单）", area: "剪贴板 › 捕获", keywords: "隐私 排除 黑名单", selection: .clipboardCapture),
        .init(title: "浮动窗", area: "剪贴板 › 浮动窗", keywords: "悬浮 剪贴板 呼出 快捷键 位置", selection: .clipboardFloating),
        // 文件中转
        .init(title: "文件中转入口", area: "文件中转 › 显示", keywords: "中转 面板 显示 暂存", selection: .transferDisplay),
        .init(title: "投屏画质", area: "文件中转 › 投屏画质", keywords: "投屏 airplay 清晰度 码率", selection: .transferCast),
        .init(title: "手机扫码直传", area: "文件中转 › 手机扫码直传", keywords: "二维码 扫码 手机 局域网 端口", selection: .transferScan),
        .init(title: "云端中转（OPPO）", area: "文件中转 › 云端中转", keywords: "云端 云盘 上传 OPPO", selection: .transferCloud),
        .init(title: "本地暂存", area: "文件中转 › 本地暂存", keywords: "暂存 目录 本地 清理", selection: .transferLocal),
        // 截图
        .init(title: "截图保存路径", area: "截图 › 截图", keywords: "下载 目录 文件夹 保存位置", selection: .capture(.capture)),
        .init(title: "截图后动作", area: "截图 › 截图", keywords: "复制 保存 贴图 默认动作", selection: .capture(.capture)),
        .init(title: "延时截图", area: "截图 › 截图", keywords: "倒计时 3 秒 5 秒 10 秒", selection: .capture(.capture)),
        .init(title: "提示音", area: "截图 › 截图", keywords: "声音 快门 音效", selection: .capture(.capture)),
        .init(title: "水印", area: "截图 › 截图", keywords: "文字 平铺 倾斜 透明度", selection: .capture(.capture)),
        .init(title: "文字识别语言", area: "截图 › 截图", keywords: "OCR 识别 语言 自动检测", selection: .capture(.capture)),
        .init(title: "截图权限（屏幕录制）", area: "截图 › 截图", keywords: "权限 授权 录屏 辅助功能", selection: .capture(.capture)),
        .init(title: "固定比例", area: "截图 › 截图", keywords: "16:9 4:3 方形 竖版 比例锁 自定义", selection: .capture(.capture)),
        .init(title: "文件命名模板", area: "截图 › 截图", keywords: "文件名 时间戳 序号 随机 占位符", selection: .capture(.capture)),
        .init(title: "静默识别", area: "截图 › 截图", keywords: "OCR 不弹窗 通知 时长", selection: .capture(.capture)),
        .init(title: "仅文本马赛克", area: "截图 › 截图", keywords: "标注 打码 文本 隐私", selection: .capture(.capture)),
        .init(title: "钉图外观（描边 / 圆角 / 阴影）", area: "截图 › 钉图", keywords: "钉住 贴图 悬浮 边框 投影 预设", selection: .capture(.pin)),
        .init(title: "钉图不透明度", area: "截图 › 钉图", keywords: "透明 alpha 半透明", selection: .capture(.pin)),
        .init(title: "钉图自动吸附", area: "截图 › 钉图", keywords: "对齐 边缘 磁吸 magnet", selection: .capture(.pin)),
        .init(title: "钉图控制条自动收起", area: "截图 › 钉图", keywords: "工具条 悬停 收起 隐藏", selection: .capture(.pin)),
        .init(title: "钉图快捷键", area: "截图 › 钉图", keywords: "标注 拷贝 关闭 Esc A C M", selection: .capture(.pin)),
        .init(title: "图帘", area: "截图 › 图帘", keywords: "悬挂架 帘线 悬停 唤出 快捷键 缩放", selection: .capture(.curtain)),
        .init(title: "录屏", area: "截图 › 录屏", keywords: "录制 摄像头 画中画 按键 点击 忽略 App", selection: .capture(.recording)),
        .init(title: "录屏保存位置", area: "截图 › 录屏", keywords: "mp4 视频 目录", selection: .capture(.recording)),
        .init(title: "工作流", area: "截图 › 工作流", keywords: "自动化 GitHub Linear 图床 上传 issue", selection: .capture(.workflow)),
        // 工具
        .init(title: "工具开关", area: "工具 › 工具", keywords: "归档 解压 二维码 取色", selection: .tools),
        .init(title: "快捷键", area: "工具 › 快捷键", keywords: "热键 组合键 冲突", selection: .shortcuts),
        // 搜索与 AI
        .init(title: "搜索", area: "搜索与 AI › 搜索", keywords: "全局搜索 命令 面板", selection: .search),
        .init(title: "AI 服务", area: "搜索与 AI › AI", keywords: "模型 key 接口 翻译", selection: .ai),
        // 性能监测
    ] + [MonitorModuleID.cpu, .memory, .gpu, .disk, .network, .sensors, .power, .battery].map { module in
        let page = SettingsPage.monitorModule(module)
        return SettingsSearchEntry(title: page.title, area: "性能监测 › \(page.title)",
                                   keywords: "性能监测", selection: page)
    } + [
        .init(title: "监测设置", area: "性能监测 › 监测设置", keywords: "刷新 频率 采样", selection: .monitorSettings),
        .init(title: "部件设置", area: "性能监测 › 部件设置", keywords: "状态栏 部件 形态 颜色", selection: .monitorWidgets),
        // 数据 / 关于
        .init(title: "使用统计", area: "数据", keywords: "统计 事件 报表", selection: .statistics),
        .init(title: "版本与更新", area: "关于", keywords: "版本 更新 检查", selection: .about),
        .init(title: "使用手册", area: "使用手册", keywords: "帮助 文档 教程", selection: .manual),
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
                footerChip("数据", icon: "chart.bar.xaxis", selection: .statistics)
                footerChip("关于", icon: "info.circle", selection: .about)
                footerChip("使用手册", icon: "book.closed", selection: .manual)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)

            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .frame(width: 16)
                    .foregroundStyle(Theme.tertiaryText)
                Text(verbatim: "Kitnest v1.0.0")
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
