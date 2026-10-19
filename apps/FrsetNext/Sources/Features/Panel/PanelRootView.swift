import AppKit
import SwiftUI

/// 主面板 SwiftUI 根视图（1:1 复刻原版 Frset 1.3.12 实测版式）：
///
/// ```
/// ┌ 工具条：[截图][取色][悬浮剪贴板]     (主页│文件中转)     [⚙] ┐ 40pt
/// ├ 主页 ────────────────────────────────────────────────┤
/// │  🔍 搜索或输入 / 使用工具                                │
/// │  ‹ 2026年10月 ›                              ⌄          │
/// │  周日 周一 周二 周三 周四 周五 周六                       │
/// │  11  12  13  14  15  16  [17]                           │
/// │  18  19  20  21  22  23  24                             │
/// │  [缩略图] 标题 …                         ↓  ↵           │
/// └──────────────────────────────────────────────────────┘
/// ```
///
/// 说明：原版主页**没有**区段标题、没有底部退出/设置栏、没有「⋯」菜单，
/// 剪贴板也不是「标题 + 过滤栏 + 表格」——就是一条条的行。这里按原版收敛。
///
/// v41（2026-10-18 用户澄清）：主面板版式**保持官方原样**（400pt、顶部三段），
/// 大侧边栏改造只作用于**设置窗口**（见 SettingsRootView）。
/// v60（2026-10-19 用户决策）：「性能监测」页删除——只保留独立窗口一套实现
/// （MonitorPopoutWindow，⌥P / ⌥M / 状态栏部件点击直达），避免两套实现打架。
/// 本面板唯一新增：顶部「文件中转」分段受「设置 → 常规 → 功能」开关控制显隐。
struct PanelRootView: View {
    @ObservedObject var presentation: PanelPresentationState
    var onDismiss: () -> Void
    var onOpenSettings: () -> Void

    /// 当前页与选中模块（nil = 主页；非 nil = 性能监测页 + 该模块）
    @ObservedObject private var monitorPresenter = MonitorCenterPresenter.shared
    /// 个性化（v66：字号缩放 / 强调色 / 打开动画 / 密度——即改即生效）
    @ObservedObject private var personalization = Personalization.shared
    /// 文件拖入高亮（拖 .json 进面板 → 打开 JSON 检视器）
    @Stored private var isDropTargeted = false
    /// 底部工具条「标签」→ 标签管理 sheet（官方原版工具条第 3 个图标）
    @Stored private var isShowingTagSheet = false
    /// 剪贴板列表当前选中项（编辑/上传按钮按选中态启用，2026-10-18）
    @Stored private var selectedClipboardItem: ClipboardItem?
    /// 「文件中转」分段显隐（设置 → 常规 → 功能）
    @AppStorage(Preferences.Keys.panelTransferDock) private var transferDockEnabled = true

    private var page: PanelCenterPage { monitorPresenter.activePage }

    // Midnight 主题覆盖（由 .frsetAppearanceTheme() 注入；非 Midnight 时全为 nil/false）
    @Environment(\.midnightBaseBackgroundOverride) private var midnightBaseBackground
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground
    @Environment(\.usesMidnightTextColor) private var usesMidnightTextColor
    @Environment(\.midnightTextColorOverride) private var midnightTextColor

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        // v66 字号缩放：内容整体乘系数，窗口宽高在 PanelController 侧同步联动
        .scaleEffect(personalization.fontScale, anchor: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 强调色注入（个性化自定义优先；覆盖子树全部 Color.accentColor）
        .tint(personalization.accentColor ?? Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 底部悬浮工具条（官方原版主页，2026-10-18 补齐）：仅主页显示
        .overlay(alignment: .bottom) {
            if page == .home {
                bottomToolbar
                    .padding(.bottom, 14)
            }
        }
        .sheet(isPresented: $isShowingTagSheet) {
            TagManagementSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardSelectionChanged)) { note in
            selectedClipboardItem = note.object as? ClipboardItem
        }
        // 弹出/收起：缩放 + 轻微上移 + 淡入（锚点贴菜单栏，像从图标「长出来」）。
        // 只动 transform/opacity，弹簧可被下一次开合打断。参数档位见「个性化」。
        .scaleEffect(presentation.visible ? 1 : 0.93, anchor: .top)
        .offset(y: presentation.visible ? 0 : -10)
        .opacity(presentation.visible ? 1 : 0)
        .animation(personalization.openAnimation.spring, value: presentation.visible)
        // 切页：关预览——主页 hover 打开的预览不能跟到中转站页
        // （与 ClipboardTableView 的 tracking 禁用双保险）
        .onChange(of: page) { newPage in
            Log.info("Panel", "切页: \(newPage)")
            RenderProbe.snapshotAll(reason: "pageChange")
            MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .programmatic)
        }
        // 文件中转开关关闭时：若正停在该页则回主页（v41）
        .onChange(of: transferDockEnabled) { enabled in
            if !enabled && page == .transfer {
                monitorPresenter.selectHome()
            }
        }
        .onExitCommand { onDismiss() }             // Esc 关闭面板
        // 拖放：把 .json 文件拖进面板任意位置 → 打开独立 JSON 检视器（大文件不挤在 popover 里）
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .overlay {
            if isDropTargeted { dropHintOverlay }
        }
        .background {
            // v66 个性化背景图（优先）；否则 Midnight 基底
            if !personalization.backgroundImagePath.isEmpty,
               let image = NSImage(contentsOfFile: personalization.backgroundImagePath) {
                GeometryReader { geo in
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                        Color(nsColor: .windowBackgroundColor)
                            .opacity(personalization.backgroundImageDim)
                    }
                }
            } else if let base = midnightBaseBackground { base }
        }
        .foregroundStyle(bodyTextColor)
        .frsetAppearanceTheme()
        // ⌥F「打开并搜索」：聚焦主面板顶部搜索框；若当前在性能页则先回主页
        // 排障探针：FRSET_PREVIEW_PROBE=1 时打开面板后自动对「最后一条文本条目」弹预览，
        // 用于无鼠标环境验证 Markdown 目录侧栏 / 图片预览渲染（不影响正常使用）。
        .onAppear {
            guard ProcessInfo.processInfo.environment["FRSET_PREVIEW_PROBE"] == "1" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard let item = ClipboardManager.shared.items.first(where: { $0.type == .text }) else {
                    Log.info("Panel", "预览探针：没有可预览的文本条目")
                    return
                }
                Log.info("Panel", "预览探针：弹出 \(item.type) 条目（\(item.fullTextCharCount ?? 0) 字符）")
                _ = MainPanelPreviewPopoverCoordinator.shared.present(
                    for: item,
                    anchorRectInWindow: CGRect(x: 24, y: 250, width: 340, height: 60))
            }
        }
        // ⌥F「打开并搜索」：先回到主页（搜索框在主页顶部），聚焦由 SearchSectionView 处理
        .onReceive(NotificationCenter.default.publisher(for: .frsetFocusPanelSearch)) { _ in
            if page != .home { monitorPresenter.selectHome() }
        }
    }

    private var bodyTextColor: Color {
        (usesMidnightTextColor ? midnightTextColor : nil) ?? .primary
    }

    private var cardBackground: Color {
        midnightCardBackground ?? Theme.cardBackground
    }

    // MARK: - 顶部工具条（40pt，原版同序：截图 / 取色 / 悬浮剪贴板 ｜ 分段 ｜ 设置）

    private var toolbar: some View {
        ZStack {
            // 左侧三个动作图标（原版：截图、取色 ⌥C、悬浮剪贴板）
            HStack(spacing: 20) {
                captureAction
                captureButton("eyedropper", title: "取色 ⌥C", mode: .color)
                Button {
                    onDismiss()
                    FloatingClipboardWindowController.shared.toggle()
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 15))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(SpringyIconButtonStyle())
                .focusable(false)
                .foregroundStyle(.secondary)
                .help("悬浮剪贴板")
                .accessibilityLabel("悬浮剪贴板")
                Spacer(minLength: 0)
                // 齿轮菜单（官方原版 1:1，2026-10-18 实测截图）：
                // 置顶窗口 ⌘P / 悬浮剪贴板 ⇧⌘V / ─ / 暂停记录剪贴板 /
                // 设置 ⌘, / 使用统计 / 功能建议 / ─ / 退出 ⌘Q
                Menu {
                    Toggle("置顶窗口", isOn: Binding(
                        get: { PanelController.shared.isPinned },
                        set: { PanelController.shared.isPinned = $0 }
                    ))
                    .keyboardShortcut("p", modifiers: .command)
                    Button("悬浮剪贴板") {
                        onDismiss()
                        FloatingClipboardWindowController.shared.toggle()
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    Divider()
                    Toggle("暂停记录剪贴板", isOn: Binding(
                        get: { ClipboardManager.shared.isRecordingPaused },
                        set: { ClipboardManager.shared.isRecordingPaused = $0 }
                    ))
                    Button("设置") { onOpenSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                    Button("使用统计") {
                        onDismiss()
                        StatisticsWindowController.shared.openStatistics()
                    }
                    Button("功能建议") {
                        if let url = URL(string: "https://github.com/frset/frset-next/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Divider()
                    Button("退出") { NSApp.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("设置")
                .accessibilityLabel("设置")
            }

            // 中间分段（原版胶囊式：选中项浅蓝底）
            pageSegments
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// 「主页 | 性能监测 | 文件中转」三段分段（自绘胶囊，对齐原版选中态）
    /// v41：文件中转由设置开关控制显隐。
    /// v71：性能监测段恢复（用户需求「顶部加回三页面的切换」）——内容复用
    /// MonitorDetailView 同一套组件（与独立窗一致，不多一套实现）。
    private var pageSegments: some View {
        HStack(spacing: 0) {
            segmentItem("主页", selected: page == .home) {
                monitorPresenter.selectHome()
            }
            segmentItem("性能监测", selected: page == .performance) {
                monitorPresenter.selectPerformance()
            }
            if transferDockEnabled {
                segmentItem("文件中转", selected: page == .transfer) {
                    monitorPresenter.selectTransferDock()
                }
            }
        }
        .padding(2)
    }

    private func segmentItem(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.16))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 截图按钮（原版注入层的「截图按钮 → 功能菜单」）：
    /// 截图 / 截图并复制 / 截图并贴图 / 截图提取文字 / 截图翻译 / 划词翻译
    /// ＋分隔线＋ 长截图 / 录屏（长截图是原版能力，录屏是注入层净新增，独立分组）。
    /// 动作直接调 CaptureModule / StatsBarEngine 公开 API，不经热键——
    /// 用户改了全局绑定也不会让菜单静默失效（注入层当年就栽在写死热键上）。
    private var captureAction: some View {
        Menu {
            Button("截图") { runCapture { CaptureModule.capture(.area) } }
            Button("截图并复制") { runCapture { CaptureModule.captureCopy() } }
            Button("截图并贴图") { runCapture { CaptureModule.capture(.pin) } }
            Button("截图提取文字") { runCapture { CaptureModule.capture(.ocr) } }
            Button("截图翻译") { runCapture { CaptureModule.captureTranslate() } }
            Button("划词翻译") { runCapture { CaptureModule.translateSelection() } }
            Divider()
            Button("长截图") { runCapture { CaptureModule.capture(.long) } }
            Button("录屏") { runCapture { StatsBarEngine.openRecorder() } }
        } label: {
            Image(systemName: "viewfinder")
                .font(.system(size: 15))
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .foregroundStyle(.secondary)
        .help("截图")
        .accessibilityLabel("截图")
    }

    /// 统一「先收面板再执行」——截图/录屏类动作需要面板让位给选区覆盖层
    private func runCapture(_ action: @escaping () -> Void) {
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: action)
    }

    // MARK: - 底部悬浮工具条（官方原版主页，2026-10-18 补齐）
    //
    // 官方实测（FrsetClean 主面板截图）：白色胶囊悬浮于列表底部居中，
    // 5 个图标 = 搜索 / 筛选（蓝色激活态）/ 标签 / 编辑 / 上传。
    // 接线上限说明：搜索=聚焦搜索框（既有通知）；筛选=ClipboardManager.filter
    // （9 种类型）；标签=标签管理 sheet（TagStore 既有能力）；
    // 编辑=需列表选中项；上传=需图床配置（未实现 → 置灰）。

    private var bottomToolbar: some View {
        HStack(spacing: 10) {
            toolbarIcon("magnifyingglass", help: "搜索") {
                NotificationCenter.default.post(name: .frsetFocusPanelSearch, object: nil)
            }
            Menu {
                ForEach(ClipboardFilterKind.allCases) { kind in
                    Button {
                        ClipboardManager.shared.filter = kind
                    } label: {
                        if ClipboardManager.shared.filter == kind {
                            Label(kind.label, systemImage: "checkmark")
                        } else {
                            Text(kind.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.circle")
                    .font(.system(size: 16))
                    .frame(width: 30, height: 30)
                    // 官方该图标为蓝色激活态（当前筛选生效）
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("筛选")
            .accessibilityLabel("筛选")
            toolbarIcon("tag", help: "标签") {
                isShowingTagSheet = true
            }
            // 编辑：有选中项时打开编辑窗（官方「编辑」按钮，2026-10-18 接通选中态）
            toolbarIcon("square.and.pencil",
                        help: selectedClipboardItem == nil ? "编辑（先选中一条）" : "编辑选中条目") {
                guard let item = selectedClipboardItem else { return }
                ClipboardItemEditWindowRecord.open(for: item)
            }
            .disabled(selectedClipboardItem == nil)
            // 上传：官方「上传」按钮（图床能力未配置 → 提示而非静默）
            toolbarIcon("arrow.up", help: "上传") {
                Toast.show("未配置图床（上传能力待接入）", icon: "exclamationmark.triangle.fill", isWarning: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func toolbarIcon(_ symbol: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func captureButton(_ symbol: String, title: String, mode: CaptureMode) -> some View {
        Button {
            onDismiss()
            CaptureModule.capture(mode)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(SpringyIconButtonStyle())
        .focusable(false)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - 内容区（各页常驻：滚动位置/动画状态互不干扰）
    // v60：性能监测页删除（只留独立窗口一套实现，⌥P / ⌥M / 状态栏部件点击直达）

    @ViewBuilder private var content: some View {
        // v71（用户：主页/性能检测同一套内容，渐入渐出动画要一样）：三页共用
        // 同一过渡语言——fade + 轻微 scale（与性能检测独立窗 popout 动画同族），
        // 不再一页一方向。
        ZStack(alignment: .top) {
            homePage
                .pageTransition(active: page == .home)

            // 第二页：性能监测（v71 恢复三页切换）——与独立窗同一套面板组件，
            // fixedWidth=nil 撑满面板宽度；玻璃底与首页同源（根背景统一）
            ScrollView(.vertical, showsIndicators: false) {
                MonitorDetailView(selection: monitorPresenter.monitorSelection,
                                  pageMode: false, fixedWidth: nil)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .pageTransition(active: page == .performance)

            // 第三页：中转站（文件暂存与转发）
            TransferDockView()
                .pageTransition(active: page == .transfer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: page)
    }

    // MARK: - 主页：搜索区段 → 日历 → 剪贴板

    private var homePage: some View {
        VStack(spacing: 0) {
            // 搜索区段由 Toolbox 模块注入（id "search"）：原版同款——
            // 输入关键词 → 搜索引擎栏（点击/回车打开网页搜索）；输入 / → 工具列表；
            // 剪贴板列表与日历**不被过滤**（对齐原版 2026-10-18 实测行为）
            searchSection
                .padding(.horizontal, 14)
                .padding(.top, 2)

            Color.clear.frame(height: 12)
            calendarCard
            clipboardSection
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 搜索区段（Toolbox 模块经 PanelSectionRegistry 注入）
    @ViewBuilder private var searchSection: some View {
        if let descriptor = PanelSectionRegistry.all.first(where: { $0.id == "search" }) {
            descriptor.build()
        }
    }

    // MARK: - 文件拖放（JSON 检视器入口）

    /// 拖入提示：整块虚线框 + 图标 + 文案（松手即开检视器）
    private var dropHintOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text("松手打开 JSON 检视器")
                    .font(.system(size: 13, weight: .medium))
                Text("支持 .json / .txt（≤ 32 MB）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            var fileURL: URL?
            if let data = item as? Data {
                fileURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                fileURL = url
            }
            guard let url = fileURL else { return }
            DispatchQueue.main.async {
                onDismiss()
                JSONInspectorWindowController.shared.open(fileURL: url)
            }
        }
        return true
    }

    /// 日历卡（由 Toolbox 模块经 PanelSectionRegistry 注入；无区段标题，原版是一张独立卡片）
    @ViewBuilder private var calendarCard: some View {
        if let descriptor = PanelSectionRegistry.all.first(where: { $0.id == "calendar" }) {
            descriptor.build()
                .padding(.horizontal, 8)
        }
    }

    /// 剪贴板列表（由 Clipboard 模块注入；原版直接是行列表，无标题/搜索/筛选）
    @ViewBuilder private var clipboardSection: some View {
        if let descriptor = PanelSectionRegistry.all.first(where: { $0.id == "clipboard" }) {
            descriptor.build()
                .padding(.horizontal, 8)
        }
    }
}

// MARK: - 三页统一过渡（v71：主页/性能检测/文件中转动画语言一致）

private extension View {
    /// 页面过渡：fade + 轻微 scale + 12pt 横移（与性能检测独立窗 popout 同族）。
    /// 三页共用同一 modifier，互切时动画完全一致（用户需求「渐入渐出动画要一样」）。
    func pageTransition(active: Bool) -> some View {
        self
            .opacity(active ? 1 : 0)
            .scaleEffect(active ? 1 : 0.97, anchor: .top)
            .offset(x: active ? 0 : 12)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}
