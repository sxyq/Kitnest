import AppKit
import SwiftUI

private struct SettingsPreviewViewportKey: EnvironmentKey {
    static let defaultValue = CGRect.zero
}

extension EnvironmentValues {
    var settingsPreviewViewport: CGRect {
        get { self[SettingsPreviewViewportKey.self] }
        set { self[SettingsPreviewViewportKey.self] = newValue }
    }
}

// MARK: - 设置窗口根视图（v41：左侧大侧边栏 + 内容区）
//
// 用户 2026-10-18 指定：
//   ① 状态栏点开的主面板**保持官方原样**；改的是设置界面；
//   ② 设置界面加一个大左侧侧边栏——第一项「主页」= 完整设置
//      （10 个设置页归类成 6 个二级标签），第二项「性能监测」= 模块二级目录；
//   ③ 配色以性能监测页为准（MonitorColors.user 作选中色 + 玻璃卡片感）。
//
// 窗口容器拥有尺寸；根视图填满宿主并由各页 ScrollView 承担纵向溢出。

struct SettingsRootView: View {

    @ObservedObject var state: SettingsUIState
    @ObservedObject private var editingSession: SettingsEditingSession
    @ObservedObject private var appearance = AppearanceState.shared
    /// v71：个性化强调色作用于设置窗子树（此前只在主面板生效——用户点强调色
    /// 「无效」的主观感受主要来自设置窗自身无反馈）
    @ObservedObject private var personalization = Personalization.shared
    @Environment(\.colorScheme) private var colorScheme
    @Stored private var previewViewport = CGRect.zero

    init(state: SettingsUIState) {
        self.state = state
        self.editingSession = state.editingSession
    }

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
                .fill(Theme.separator)
                .frame(width: 0.5)
            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 0.5)
                if state.isVisible {
                    content.id(editingSession.generation)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(minWidth: 0)
            .coordinateSpace(name: "settingsPreviewViewport")
            // v260：横向溢出裁在内容区内，不再回压兄弟视图
            .clipped()
            .background(GeometryReader { proxy in
                let bounds = proxy.frame(in: .named("settingsPreviewViewport"))
                let contentViewport = CGRect(x: bounds.minX, y: bounds.minY + 66,
                                              width: bounds.width, height: max(0, bounds.height - 66))
                Color.clear
                    .onAppear { previewViewport = contentViewport }
                    .onChange(of: proxy.size) { _ in previewViewport = contentViewport }
            })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(appearance.isMidnight ? MidnightTheme.textColor : Color.primary)
        // 强调色 + Midnight 统一主题入口（个性化改色即生效）
        .frsetThemeChrome()
        .environmentObject(editingSession)
        .environment(\.settingsPreviewViewport, previewViewport)
        .environment(\.settingsTargetField, state.detailPaneID)
        // v84：侧边栏切换面包屑（卡死时日志可见「切到哪一页后卡住」）
        .onChange(of: state.selection) { newValue in
            Log.breadcrumb("Settings", "侧边栏 → \(newValue)")
        }
        .ignoresSafeArea()
    }

    // MARK: - 头部（当前分类标题）

    private var currentTitle: String { state.selection.title }

    private var header: some View {
        // v275（用户：「窗口上面的那个小字全部删掉」）：页头只留当前页标题。
        // 分组名在侧栏已经高亮，功能说明放界面里就是噪音；未保存状态改用一个小圆点，
        // 和侧栏保持同一套标记（页脚仍写明保存状态）。
        HStack(spacing: 7) {
            Text(currentTitle)
                .font(.system(size: 16, weight: .semibold))
            if editingSession.isDirty(page: state.selection) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("未保存")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 34)
        .frame(height: 52)
    }

    // MARK: - 内容分发（v272：一个二级页 = 一个 View）

    @ViewBuilder private var content: some View {
        switch state.selection {
        case .haptics:
            panePage { HapticSettingsPane() }
        // 常规（5 个二级页）
        case .generalStart:
            panePage { GeneralSettingsPane(section: .startup) }
        case .generalPanel:
            panePage { GeneralSettingsPane(section: .mainPanel) }
        case .generalWindows:
            panePage { GeneralSettingsPane(section: .floating) }
        case .appearanceText:
            panePage { GeneralSettingsPane(section: .appearanceText) }
        case .panelBackground:
            panePage { GeneralSettingsPane(section: .background) }
        case .permissions:
            panePage { GeneralSettingsPane(section: .permissions) }
        case .island:
            panePage { IslandSettingsPane(part: .activation) }
        case .islandPeeks:
            panePage { IslandSettingsPane(part: .peeks) }
        case .islandCanvas:
            panePage { IslandSettingsPane(part: .canvas) }
        case .islandMaterial:
            panePage { IslandSettingsPane(part: .appearance) }
        case .generalPersonal:
            panePage { GeneralSettingsPane(section: .personalization) }
        case .generalMenuBar:
            panePage { GeneralSettingsPane(section: .menuBar) }
        case .floatingBall:
            panePage { FloatingBallSettingsPane() }
        case .menuBarArrangement:
            panePage { GeneralSettingsPane(section: .menuBarArrangement) }
        case .generalNotifications:
            panePage { GeneralSettingsPane(section: .notifications) }
        case .captureActions:
            panePage { GeneralSettingsPane(section: .captureToolbar) }

        case .audio:
            panePage { ToolSettingsPane(part: .collection) }

        // 剪贴板（3）
        case .clipboardHistory:
            panePage { ClipboardSettingsPane(section: .history) }
        case .clipboardCapture:
            panePage { ClipboardSettingsPane(section: .capture) }
        case .clipboardFloating:
            panePage { ClipboardSettingsPane(section: .floating) }
        case .clipboardAppearance:
            panePage { ClipboardSettingsPane(section: .appearance) }

        // 压缩与 Finder（原来挂在文件与传输下，Lite 版并入工具）
        case .archive:
            // v273（ArcZip 1.2.5 设置结构对齐）：打开与解压 / 悬浮预览 / 进度窗口 / 系统关联
            panePage {
                VStack(alignment: .leading, spacing: 20) {
                    SettingsSection("打开与解压") {
                        SettingsGroupBox { ArchiveOpenBehaviorOptions() }
                    }
                    SettingsSection("悬浮预览") {
                        SettingsGroupBox { ArchiveHoverPreviewOptions() }
                    }
                    SettingsSection("进度窗口") {
                        SettingsGroupBox { ArchiveProgressWindowOptions() }
                    }
                    SettingsSection("系统关联与 Finder 服务") {
                        SettingsGroupBox { ArchiveDefaultApplicationOption() }
                    }
                }
            }

        // 截图（5，v271 已拆）
        case .capture(let block):
            panePage { CaptureBlockPage(block: block) }
        case .ocr:
            panePage { CaptureSettingsPane(section: .ocr) }
        case .watermark:
            panePage { CaptureSettingsPane(section: .watermark) }

        // 工具（2）
        case .tools:
            panePage { ToolSettingsPane(part: .collection) }
        case .aiText:
            panePage { ToolSettingsPane(part: .aiText) }
        case .calendar:
            panePage { ToolSettingsPane(part: .calendar) }
        case .shortcuts:
            panePage { ShortcutSettingsPane(targetID: state.detailPaneID) }

        // 搜索与 AI（2）
        case .search:
            panePage { SearchSettingsPane() }
        case .ai:
            panePage { AISettingsPane() }

        // 性能监测（9）
        case .monitorModule:
            panePage { MonitorSettingsPane() }
        case .monitorSettings:
            panePage { MonitorSettingsPane() }
        case .monitorWidgets:
            panePage { MonitorWidgetsPane() }

        // 页脚常驻
        case .statistics:
            panePage { diagnostics }
        case .configTransfer:
            panePage { StatisticsSettingsPane() }
        case .diagnostics:
            panePage { diagnostics }
        case .about:
            panePage { AboutSettingsPane() }
        case .manual:
            ManualPaneView()
        }
    }

    private func panePage<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                content()
                    .padding(.horizontal, 34)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SettingsScrollPosition(state: state, page: state.selection))
            }
            .onAppear {
                if let field = state.detailPaneID {
                    DispatchQueue.main.async { proxy.scrollTo(field, anchor: .top) }
                }
            }
            .onChange(of: state.navigationRevision) { _ in
                if let field = state.detailPaneID {
                    DispatchQueue.main.async { proxy.scrollTo(field, anchor: .top) }
                }
            }
        }
    }

    private var diagnostics: some View {
        SettingsSection("运行诊断") {
            SettingsGroupBox {
                SettingsRow(title: "诊断资料", subtitle: "导出运行日志与使用记录；不改变当前设置") {
                    Button("导出诊断…") { DiagnosticsExporter.export() }
                }
                SettingsRow(title: "日志目录") {
                    Button("在 Finder 中查看") {
                        NSWorkspace.shared.open(LogArchive.shared.directory)
                    }
                }
            }
        }
    }

}
