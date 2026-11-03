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
    @ObservedObject var state: SettingsUIState
    @ObservedObject private var appearance = AppearanceState.shared
    /// v71：个性化强调色作用于设置窗子树（此前只在主面板生效——用户点强调色
    /// 「无效」的主观感受主要来自设置窗自身无反馈）
    @ObservedObject private var personalization = Personalization.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // v206：fullSizeContentView 下红绿灯会压在侧边栏第一项上——顶部留 32pt 标题带
            Color.clear.frame(height: 32)
            HStack(spacing: 0) {
            SettingsSidebarView(state: state)
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
            }
        }
        // 根视图尺寸必须等于窗口 contentRect（940×620）：NSHostingView 的 fitting size
        // 会被当作窗口内容尺寸请求——设大 32 会让窗口被撑到 684（2026-10-18 实测）。
        // fullSizeContentView 下 contentView 已含标题栏区域，620 正好铺满。
        .frame(width: 940, height: 620)
        .background(backgroundColor)
        .foregroundStyle(appearance.isMidnight ? MidnightTheme.textColor : Color.primary)
        // 强调色 + Midnight 统一主题入口（个性化改色即生效）
        .frsetThemeChrome()
        // v84：侧边栏切换面包屑（卡死时日志可见「切到哪一页后卡住」）
        .onChange(of: state.selection) { newValue in
            Log.breadcrumb("Settings", "侧边栏 → \(newValue)")
        }
        .ignoresSafeArea()
    }

    private var backgroundColor: Color {
        if appearance.isMidnight { return MidnightTheme.baseBackground }
        // v204（用户：「需要覆盖所有界面」）：设置窗也铺统一玻璃底——
        // 根视图不再画不透明灰，玻璃/通透度/磨砂滑块在设置窗内同样可见。
        // 窗口背后的玻璃底由 SettingsWindowController 的 applyOfficialChrome 提供。
        return Color.clear
    }

    // MARK: - 头部（当前分类标题）

    private var currentTitle: String {
        switch state.selection {
        case .category(let category): return category.title
        case .monitorModule(let module): return module == .sensors ? "传感器" : module.displayName
        case .monitorSettings: return "监测设置"
        case .monitorWidgets: return "部件设置"
        case .manual: return "使用手册"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(currentTitle)
                .font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .frame(height: 56)
    }

    // MARK: - 内容分发

    @ViewBuilder private var content: some View {
        switch state.selection {
        case .category(let category):
            switch category {
            case .general:
                panePage { GeneralSettingsPane() }
            case .clipboard:
                panePage { ClipboardSettingsPane() }
            case .transfer:
                panePage { TransferDockSettingsPane() }
            case .searchAI:
                segmentedPage(selection: $state.searchAISub, tabs: [
                    ("搜索", AnyView(SearchSettingsPane())),
                    ("AI", AnyView(AISettingsPane()))
                ])
            case .tooling:
                segmentedPage(selection: $state.toolingSub, tabs: [
                    ("工具", AnyView(ToolSettingsPane())),
                    ("快捷键", AnyView(ShortcutSettingsPane())),
                    ("截图", AnyView(CaptureSettingsPane()))
                ])
            case .statistics:
                panePage { StatisticsSettingsPane() }
            case .about:
                AboutSettingsPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .monitorModule(let module):
            ScrollView(.vertical, showsIndicators: true) {
                StatsModulePage(module: module)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .monitorSettings:
            panePage { MonitorSettingsPane() }
        case .monitorWidgets:
            // v55：用本项目设置组件重写的部件设置页（功能覆盖 STATS，不嵌入其界面）
            MonitorWidgetsPane()
        case .manual:
            // v88：交互式树形使用手册（左树 + 右内容；图片/表格/搜索/上下一节）
            ManualPaneView()
        }
    }

    /// 单页设置：整页纵向滚动
    private func panePage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
                .padding(.horizontal, 34)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 多合一分类（搜索与 AI / 工具与快捷键）：顶部分段 + 内容滚动
    private func segmentedPage(selection: Binding<Int>,
                               tabs: [(String, AnyView)]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    let selected = selection.wrappedValue == index
                    Button {
                        withAnimation(Theme.Motion.spring) {
                            selection.wrappedValue = index
                        }
                    } label: {
                        Text(tab.0)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? MonitorColors.user : Color.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background {
                                if selected {
                                    Capsule(style: .continuous)
                                        .fill(MonitorColors.user.opacity(0.15))
                                }
                            }
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
            .frame(height: 40)

            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: true) {
                if tabs.indices.contains(selection.wrappedValue) {
                    tabs[selection.wrappedValue].1
                        .padding(.horizontal, 34)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
