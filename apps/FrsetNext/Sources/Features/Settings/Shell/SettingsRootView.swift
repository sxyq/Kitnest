import SwiftUI

// MARK: - 设置窗口根视图（v41：左侧大侧边栏 + 内容区）
//
// 用户 2026-10-18 指定：
//   ① 状态栏点开的主面板**保持官方原样**；改的是设置界面；
//   ② 设置界面加一个大左侧侧边栏——第一项「主页」= 完整设置
//      （10 个设置页归类成 6 个二级标签），第二项「性能监测」= 模块二级目录；
//   ③ 配色以性能监测页为准（MonitorColors.user 作选中色 + 玻璃卡片感）。
//
// 布局纪律（2026-10-16 实证，勿改）：根视图必须固定 .frame(...)。SwiftUI App
// lifecycle 下 NSHostingView 会把根视图 fitting size 折成窗口尺寸请求；高度自由的
// 根视图会令窗口被反复请求撑到内容自然高，触发无限 Update Constraints 循环 →
// NSGenericException。各页内部滚动由 ScrollView 承担。

struct SettingsRootView: View {

    /// 与 SettingsWindowController 保持一致的窗口高度（默认 620，排障时可拉高）
    static let probeHeight: CGFloat = {
        let value: Double = Preferences.shared.value("probe.settingsHeight", default: 720.0)
        return min(max(CGFloat(value), 720), 1040)
    }()
    @ObservedObject var state: SettingsUIState
    @ObservedObject private var appearance = AppearanceState.shared
    /// v71：个性化强调色作用于设置窗子树（此前只在主面板生效——用户点强调色
    /// 「无效」的主观感受主要来自设置窗自身无反馈）
    @ObservedObject private var personalization = Personalization.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // v208：交还 macOS 原生标题栏（原生材质 + 红绿灯 + 分隔线，唯一实现）；
            // 这里只留 32pt 净空，避免内容压到红绿灯
            Color.clear.frame(height: 32)
            HStack(spacing: 0) {
            // v260（左侧导航被挤压截断）：侧边栏原来**没有宽度约束**，宽度全靠内容撑。
            // 「工具与快捷键 → 快捷键」那页内容比较宽，SwiftUI 就把可压缩的侧边栏
            // 压扁（用户截图：左侧只剩半截字）。这里钉死宽度，并让内容区可压缩。
            SettingsSidebarView(state: state)
                .frame(width: Theme.settingsSidebarWidth)
                // v260：.frame(width:) 只是「提议尺寸」，兄弟视图更刚性时 SwiftUI
                // 仍会压扁侧栏（截图里只剩半截字）。钉成不可压缩才是真约束。
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 0.5)
            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(minWidth: 0)
            // v260：横向溢出裁在内容区内，不再回压兄弟视图
            .clipped()
            }
        }
        // 根视图尺寸必须等于窗口 contentRect（940×720）：NSHostingView 的 fitting size
        // 会被当作窗口内容尺寸请求——设大 32 会让窗口被撑到 684（2026-10-18 实测）。
        // fullSizeContentView 下 contentView 已含标题栏区域，620 正好铺满。
        // v263：排障探针 `probe.settingsHeight` 与 SettingsWindowController 用同一个值，
        // 拉高窗口时根视图同步变高，否则 SwiftUI 的固定 620 会把窗口又拽回去。
        .frame(width: 940, height: Self.probeHeight)
        .foregroundStyle(appearance.isMidnight ? MidnightTheme.textColor : Color.primary)
        // 强调色 + Midnight 统一主题入口（个性化改色即生效）
        .frsetThemeChrome()
        // v84：侧边栏切换面包屑（卡死时日志可见「切到哪一页后卡住」）
        .onChange(of: state.selection) { newValue in
            Log.breadcrumb("Settings", "侧边栏 → \(newValue)")
        }
        .ignoresSafeArea()
    }

    // MARK: - 头部（当前分类标题）

    private var currentTitle: String { state.selection.title }

    private var header: some View {
        // v273：标题下方统一挂一行「打开方式」。用户改完设置却不知道按哪个键把功能
        // 叫出来，是这次反馈的核心；提示来自 `SettingsPage.openHint`，每个二级页必答，
        // 所以不会再漏页。没有入口的页（关于 / 使用手册）返回 nil，自动不占位。
        VStack(alignment: .leading, spacing: 3) {
            Text(currentTitle)
                .font(.system(size: 16, weight: .semibold))
            if let hint = state.selection.openHint {
                HStack(spacing: 5) {
                    Image(systemName: "command")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(hint)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(Theme.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 34)
        .frame(height: 66)
    }

    // MARK: - 内容分发（v272：一个二级页 = 一个 View）

    @ViewBuilder private var content: some View {
        switch state.selection {
        // 常规（5 个二级页）
        case .generalStart:
            panePage { GeneralSettingsPane(section: .startup) }
        case .generalPanel:
            panePage { GeneralSettingsPane(section: .mainPanel) }
        case .generalWindows:
            panePage { GeneralSettingsPane(section: .floating) }
        case .generalPersonal:
            panePage { GeneralSettingsPane(section: .personalization) }
        case .generalMenuBar:
            panePage { GeneralSettingsPane(section: .menuBar) }
        case .generalNotifications:
            panePage { GeneralSettingsPane(section: .notifications) }
        case .captureActions:
            panePage { GeneralSettingsPane(section: .captureToolbar) }

        case .audio:
            AudioMixerPane()

        // 剪贴板（3）
        case .clipboardHistory:
            panePage { ClipboardSettingsPane(section: .history) }
        case .clipboardCapture:
            panePage { ClipboardSettingsPane(section: .capture) }
        case .clipboardFloating:
            panePage { ClipboardSettingsPane(section: .floating) }
        case .clipboardAppearance:
            panePage { ClipboardSettingsPane(section: .appearance) }

        // 文件中转（5）
        case .transferDisplay:
            panePage { TransferDockSettingsPane(section: .display) }
        case .transferCast:
            panePage { TransferDockSettingsPane(section: .cast) }
        case .transferScan:
            panePage { TransferDockSettingsPane(section: .scan) }
        case .transferCloud:
            panePage { TransferDockSettingsPane(section: .cloud) }
        case .transferLocal:
            panePage { TransferDockSettingsPane(section: .local) }

        // 截图（5，v271 已拆）
        case .capture(let block):
            CaptureBlockPage(block: block)

        // 工具（2）
        case .tools:
            panePage { ToolSettingsPane() }
        case .shortcuts:
            panePage { ShortcutSettingsPane() }

        // 搜索与 AI（2）
        case .search:
            panePage { SearchSettingsPane() }
        case .ai:
            panePage { AISettingsPane() }

        // 性能监测（9）
        case .monitorModule(let module):
            ScrollView(.vertical, showsIndicators: true) {
                StatsModulePage(module: module)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { MonitorSampler.shared.setSettingsActive(true) }
            .onDisappear { MonitorSampler.shared.setSettingsActive(false) }
        case .monitorSettings:
            panePage { MonitorSettingsPane() }
        case .monitorWidgets:
            MonitorWidgetsPane()

        // 页脚常驻
        case .statistics:
            panePage { StatisticsSettingsPane() }
        case .about:
            AboutSettingsPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .manual:
            ManualPaneView()
        }
    }

    private func panePage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
                .padding(.horizontal, 34)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
