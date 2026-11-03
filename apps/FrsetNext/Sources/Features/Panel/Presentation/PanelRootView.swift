import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// 底部工具条「标签」→ 标签管理 sheet（官方原版工具条第 3 个图标）
    @Stored private var isShowingTagSheet = false
    /// 底部工具条的搜索框展开态（点击放大镜展开）
    @Stored private var isSearchExpanded = false
    /// 「文件中转」分段作为放置目标（文件拖到分段上即存本地中转）
    @Stored private var transferTabTargeted = false
    /// 底部搜索框焦点
    @FocusState private var bottomSearchFocused: Bool
    /// 剪贴板列表当前选中项（编辑/上传按钮按选中态启用，2026-10-18）
    @Stored private var selectedClipboardItem: ClipboardItem?
    /// 「文件中转」**功能**开关（v181：不再影响分段显隐，只影响中转页里的功能是否启用）
    @AppStorage(Preferences.Keys.panelTransferDock) private var transferFeatureEnabled = true
    // v177（用户：设置里自定义顶部页面的展现，关掉的不占内存）；v181 增加可拖拽顺序
    @AppStorage(PanelSegments.homeKey) private var segmentHome = true
    @AppStorage(PanelSegments.monitorKey) private var segmentMonitor = true
    @AppStorage(PanelSegments.transferKey) private var segmentTransfer = false
    @AppStorage(PanelSegments.castKey) private var segmentCast = false
    /// 顺序串（CSV）——单独观察它，设置里拖完顺序面板立刻重排
    @AppStorage(PanelSegments.orderKey) private var segmentOrderRaw = ""
    /// 首页网盘链接条数据源（v74：复制网盘链接 → 自动弹出 + 日历下移）
    @ObservedObject private var clipboard = ClipboardManager.shared

    private var page: PanelCenterPage { monitorPresenter.activePage }

    /// 顶部实际出现的页面（顺序 = 设置里拖拽的顺序，过滤掉关掉的）
    private var enabledPages: [PanelCenterPage] {
        PanelSegments.decode(segmentOrderRaw).filter { isSegmentOn($0) }
    }

    private func isSegmentOn(_ page: PanelCenterPage) -> Bool {
        switch page {
        case .home:        return segmentHome
        case .performance: return segmentMonitor
        case .transfer:    return segmentTransfer
        case .cast:        return segmentCast
        }
    }

    /// 当前应渲染的页面：选中页被关掉时落到第一个启用页；全关时回主页占位
    private var activePage: PanelCenterPage {
        let pages = enabledPages
        if pages.contains(page) { return page }
        return pages.first ?? .home
    }

    /// 关掉当前页后把 presenter 拉回到可用页（否则分段高亮会全灭）
    private func normalizeSegmentSelection() {
        let pages = enabledPages
        if !pages.isEmpty, !pages.contains(page) {
            monitorPresenter.page = pages[0]
        }
    }

    // Midnight 主题覆盖（由 .frsetAppearanceTheme() 注入；非 Midnight 时全为 nil/false）
    @Environment(\.midnightBaseBackgroundOverride) private var midnightBaseBackground
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground
    @Environment(\.usesMidnightTextColor) private var usesMidnightTextColor
    @Environment(\.midnightTextColorOverride) private var midnightTextColor

    var body: some View {
        VStack(spacing: 0) {
            // v73：锚点展开时顶部让出 9pt 给三角指示器（画在窗口内，避免被窗口
            // 边界裁剪——SwiftUI overlay 超出窗口 frame 的部分不会渲染）。
            if presentation.anchored {
                Color.clear.frame(height: 9)
            }
            toolbar
            content
        }
        // v66 字号缩放：窗口宽高在 PanelController 侧已按 fontScale 联动（v73 修正）。
        // v73（2026-10-19 用户反馈「比例非常怪、按钮挤一堆」）：此处**不再**对内容
        // 叠加 scaleEffect——否则窗口 400×0.9=360 与内容再缩 0.9=324 双重缩放，
        // 表现为内容只占窗口 90%（右侧空条）+ hosting 反向压窗（324pt）拉锯。
        // 纪律：缩放只发生一处（窗口尺寸），内容始终 1:1 填充窗口。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 强调色 + Midnight 统一主题入口（个性化改色即生效；覆盖子树全部 Theme.accent）
        .frsetThemeChrome()
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
        // v197（用户「从一个点扩散成一个面，从哪来回哪去」）：开合动画整体挪到
        // 窗口内容层（Core/WindowReveal）——只有窗口层的 transform 才能连玻璃一起
        // 从菜单栏图标处展开/收回；SwiftUI 侧不再叠 scale/offset/opacity，
        // 否则窗口层缩放 + 内容再缩放 = 双重动效（历史 v73 的「比例怪」同源）。

        // 切页：关预览——主页 hover 打开的预览不能跟到中转站页
        // （与 ClipboardTableView 的 tracking 禁用双保险）
        .onChange(of: page) { newPage in
            Log.info("Panel", "切页: \(newPage)")
            RenderProbe.snapshotAll(reason: "pageChange")
            MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .programmatic)
            // 切到中转页**不再**自动起直传服务（2026-10-20 用户需求）：
            // 服务按需启动——勾选文件后点「扫码直传」才拉起并生成二维码。
        }
        // v181：中转功能开关只影响中转页内部（页面会自己显示「已关闭」提示），
        // 不再把用户踢回主页，也不影响分段显隐。
        .onChange(of: transferFeatureEnabled) { _ in
            normalizeSegmentSelection()
        }
        // v177：分段开关变化 → 若当前页被关掉，切到第一个还开着的页面
        .onChange(of: segmentHome) { _ in normalizeSegmentSelection() }
        .onChange(of: segmentMonitor) { _ in normalizeSegmentSelection() }
        .onChange(of: segmentTransfer) { _ in normalizeSegmentSelection() }
        .onChange(of: segmentCast) { _ in normalizeSegmentSelection() }
        // v181：顺序变了 → 当前页还在就保持不动，只是重排（关掉当前页的老逻辑走上面）
        .onChange(of: segmentOrderRaw) { _ in normalizeSegmentSelection() }
        .onExitCommand { onDismiss() }             // Esc 关闭面板
        // v206：JSON 检视器独立窗已删除 → 面板不再接收「拖 .json 开窗」的拖放
        .background {
            // v66 个性化背景图（优先）；否则 Midnight 基底
            // v101 性能审计：背景图此前每次 body 求值都读盘解码 → 按路径缓存
            if !personalization.backgroundImagePath.isEmpty,
               let image = Self.cachedBackgroundImage(path: personalization.backgroundImagePath) {
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
            else {
                // v203（用户：「通透度/磨砂改了无效」）：主面板原本只有窗口里那层
                // NSVisualEffectView，两个滑块完全读不到。这里叠统一结构面的
                // 「通透度底衬 + 磨砂霜感」（includesBlur=false，不叠第二层模糊，
                // 毛玻璃由 FloatingPanel 提供）。
                GlassSurface(includesBlur: false)
            }
        }
        .foregroundStyle(bodyTextColor)
        // v73（2026-10-19 用户反馈）：锚点展开时面板顶部中央画三角，指向菜单栏图标
        // ——即用户描述的「一个三角形从图标这里指下来、正对位置」。与下方
        // scaleEffect(anchor:.top)「长出来」弹簧组合，整体观感为从图标下方弹出。
        // 非锚点路径（快捷键/菜单）不显示，保持右缘停腾的干净形态。
        .overlay(alignment: .top) {
            if presentation.anchored {
                // 注：不可用 windowBackgroundColor——面板本身白底，白三角=隐形。
                // 用 primary 12% 浅灰，白底上清晰、深色主题下自动反相。
                AnchorArrow()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 26, height: 10)
                    .allowsHitTesting(false)
            }
        }
        // ⌥F「打开并搜索」：聚焦主面板顶部搜索框；若当前在性能页则先回主页
        // 排障探针：FRSET_PREVIEW_PROBE=1（或 defaults 键 probe.preview=text|image）时
        // 面板显示后自动弹预览，用于无鼠标环境验证 Markdown 目录侧栏 / 图片预览 / OCR 文本行。
        // 注意挂在「面板可见」上而不是 onAppear：popover 挂在面板窗口上，面板没显示时弹了也看不见。
        .onChange(of: presentation.visible) { visible in
            guard visible else { return }
            let mode = ProcessInfo.processInfo.environment["FRSET_PREVIEW_PROBE"]
                ?? (UserDefaults.standard.string(forKey: "probe.preview"))
            guard let mode, mode != "0" else { return }
            let wantedType: ClipboardItemType = (mode == "image") ? .image : .text
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                guard let item = ClipboardManager.shared.items.first(where: { $0.type == wantedType }) else {
                    Log.info("Panel", "预览探针：没有可预览的 \(wantedType) 条目")
                    return
                }
                // 图片探针：没有缓存 OCR 文本时先塞一段样例，好让「复制文本/重新识别」行可见
                if wantedType == .image, PreviewPopoverDataBridge.shared.ocrText(for: item) == nil {
                    PreviewPopoverDataBridge.shared.saveOCRText(
                        "（探针样例）OCR 识别文本：这里展示识别结果，可一键复制。",
                        for: item)
                }
                Log.info("Panel", "预览探针：弹出 \(item.type) 条目（\(item.fullTextCharCount ?? 0) 字符）")
                _ = MainPanelPreviewPopoverCoordinator.shared.present(
                    for: item,
                    anchorRectInWindow: CGRect(x: 24, y: 250, width: 340, height: 60))
            }
        }
        // 面板直接以中转页打开时（上次停留页）也不自动起直传服务：
        // 按需启动，勾选文件后点「扫码直传」才拉起（2026-10-20 用户需求）
        .onAppear {
            if page == .transfer { Log.info("Panel", "中转页打开：直传服务保持按需启动") }
            // v177 排障：记录当前启用了哪些页面（关掉的不创建视图，日志里应看不到它们）
            let names = enabledPages.map { PanelSegments.title($0) }.joined(separator: ",")
            Log.info("Panel", "分段启用：[\(names)]，当前页=\(PanelSegments.title(activePage))")
            normalizeSegmentSelection()
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

    /// v73：面板顶部三角指示器（锚点展开时显示，尖端指向菜单栏图标）
    private struct AnchorArrow: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))   // 顶点（朝上，指向图标）
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }

    // MARK: - 顶部工具条（40pt，原版同序：截图 / 取色 / 悬浮剪贴板 ｜ 分段 ｜ 设置）

    // v84（2026-10-20 用户反馈「性能监测/文件中转的切换压在截屏/录屏/取色按钮上」）：
    // 原实现用 ZStack 把「左图标组 + 齿轮」（下层）与「居中的三段分段」（上层）叠在一起。
    // 面板宽 360~400pt 时，分段总宽 ≈204pt、两侧各只剩 ≈78~98pt，而左侧图标组
    // （3×22 + 2×20 spacing ≈ 106pt）比余量更宽 → 分段整块压在截图/取色/悬浮剪贴板
    // 图标上（用户实拍重叠）。现改为**单行顺序排布**：图标组 │ 分段（可伸缩）│ 齿轮，
    // 并收紧图标间距与分段内边距，保证 360pt（fontScale 0.9）下仍有余量。
    private var toolbar: some View {
        HStack(spacing: 8) {
            // 左侧三个动作图标（原版：截图、取色 ⌥C、悬浮剪贴板）
            HStack(spacing: 12) {
                captureAction
                captureButton("eyedropper", title: "取色 ⌥C", mode: .color)
                Button {
                    onDismiss()
                    FloatingClipboardWindowController.shared.toggle()
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 14))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(SpringyIconButtonStyle())
                .focusable(false)
                .foregroundStyle(.secondary)
                .help("悬浮剪贴板")
                .accessibilityLabel("悬浮剪贴板")
            }
            Spacer(minLength: 2)
            // 中间分段（原版胶囊式：选中项浅蓝底）。
            // 不设 fixedSize（那会阻止缩字导致溢出）：320pt（最小面板宽）下
            // 文字按 minimumScaleFactor 0.8 兜底缩放，绝不回落到与左右图标
            // 重叠的旧 ZStack 行为。
            pageSegments
                .layoutPriority(1)
            Spacer(minLength: 2)
            // 齿轮菜单（官方原版 1:1，2026-10-18 实测截图）：
            // 置顶窗口 ⌘P / 悬浮剪贴板 ⇧⌘V / ─ / 暂停记录剪贴板 /
            // 设置 ⌘, / 使用统计 / ─ / 退出 ⌘Q
            // v85（2026-10-20 用户要求）：移除「功能建议」入口
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
                // v97（2026-10-21 用户：「点击暂停统计剪贴板无效并且无提示」）：
                // Menu 内自定义 Binding 的 Toggle 在 macOS 上点击偶发不触发 set
                // （无效）且无任何反馈（无提示）。改 Button：点击必执行 + Toast
                // 明示新状态，标题随暂停/恢复切换。
                Button {
                    let paused = !ClipboardManager.shared.isRecordingPaused
                    ClipboardManager.shared.isRecordingPaused = paused
                    Toast.show(paused ? "已暂停记录剪贴板" : "已恢复剪贴板记录",
                               icon: paused ? "pause.fill" : "play.fill")
                } label: {
                    if ClipboardManager.shared.isRecordingPaused {
                        Label("恢复剪贴板记录", systemImage: "play.fill")
                    } else {
                        Label("暂停记录剪贴板", systemImage: "pause.fill")
                    }
                }
                Button("设置") { onOpenSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("使用统计") {
                    onDismiss()
                    StatisticsWindowController.shared.openStatistics()
                }
                Divider()
                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Color.secondary)   // 同截图钮：显式灰，避免落 accent
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focusable(false)
            .help("设置")
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// 「主页 | 性能监测 | 文件中转 | 投屏」四段分段（自绘胶囊，对齐原版选中态）
    /// v41：文件中转由设置开关控制显隐。
    /// v71：性能监测段恢复（用户需求「顶部加回三页面的切换」）——内容复用
    /// MonitorDetailView 同一套组件（与独立窗一致，不多一套实现）。
    /// v114（2026-10-25 用户需求）：投屏从文件中转拆出，新增第四段「投屏」。
    /// v181：顺序与显隐全部由设置里的「主面板页面」决定（可拖拽排序），
    /// 这里只按 `enabledPages` 依次画，不再写死四段。
    private var pageSegments: some View {
        HStack(spacing: 0) {
            ForEach(enabledPages, id: \.self) { item in
                if item == .transfer {
                    segmentItem(PanelSegments.title(item), selected: page == item) {
                        selectPage(item)
                    }
                    // 拖文件到「文件中转」分段 = 存进本地中转（硬链接，不复制数据）
                    .onDrop(of: [.fileURL], isTargeted: $transferTabTargeted) { providers in
                        dropToLocalTransfer(providers)
                    }
                    .overlay {
                        if transferTabTargeted {
                            Capsule(style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.7),
                                              style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                                .padding(-2)
                        }
                    }
                    .help("文件中转：拖文件到这里存进本地中转（硬链接）")
                } else {
                    segmentItem(PanelSegments.title(item), selected: page == item) {
                        selectPage(item)
                    }
                    .help(segmentHelp(item))
                }
            }
        }
        .padding(2)
    }

    private func segmentHelp(_ page: PanelCenterPage) -> String {
        switch page {
        case .home:        return "主页"
        case .performance: return "性能监测"
        case .transfer:    return "文件中转"
        case .cast:        return "投屏：Android 无线配对与镜像"
        }
    }

    private func selectPage(_ page: PanelCenterPage) {
        switch page {
        case .home:        monitorPresenter.selectHome()
        case .performance: monitorPresenter.selectPerformance()
        case .transfer:    monitorPresenter.selectTransferDock()
        case .cast:        monitorPresenter.selectCast()
        }
    }

    /// 文件拖到「文件中转」分段：进本地中转 + 切到中转页 + 轻提示
    private func dropToLocalTransfer(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                if let url { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            let count = LocalTransferStore.shared.add(urls: urls)
            if count > 0 {
                // v181：分段被关掉时不要「偷偷切到一个不存在的页」，只提示文件已进中转
                if enabledPages.contains(.transfer) { monitorPresenter.selectTransferDock() }
                Toast.show("已暂存 \(count) 个文件到本地中转", icon: "internaldrive")
            }
        }
        return true
    }

    private func segmentItem(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // v84：字号 12→11、内边距 12/4→9/3（面板 360pt 宽时与左右图标组共存，
            // 避免三段时间排不下被压缩或压住图标）
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(Theme.accent.opacity(0.16))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // v181：分段可重排后第一个分段不一定还是「主页」，键盘焦点环会随机落在首个分段上，
        // 看着像「同时选中了两个」——统一关掉焦点环（窗口里靠鼠标/快捷键操作）
        .focusable(false)
    }

    /// 截图按钮（原版注入层的「截图按钮 → 功能菜单」）：
    /// 截图 / 截图并复制 / 截图并贴图 / 截图提取文字 / 截图翻译 / 划词翻译
    /// ＋分隔线＋ 长截图 / 录屏（长截图是原版能力，录屏是注入层净新增，独立分组）。
    /// 动作直接调 CaptureModule / StatsBarEngine 公开 API，不经热键——
    /// 用户改了全局绑定也不会让菜单静默失效（注入层当年就栽在写死热键上）。
    private var captureAction: some View {
        Menu {
            Button("截图") { runCapture { CaptureModule.capture(.area) } }
            // v113：窗口截图（原版 CaptureMode.window；入口对齐原版「窗口图标」位置）
            Button("窗口截图") { runCapture { CaptureModule.capture(.window) } }
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
                .font(.system(size: 14))
                .frame(width: 22, height: 22)
                // Menu 的 label 不走外层 foregroundStyle（会落到 accent 色），
                // 显式着色，与右侧 Button 图标（取色/悬浮剪贴板）保持同一灰阶
                .foregroundStyle(Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .foregroundStyle(.secondary)
        .tint(.secondary)      // Menu 图标默认取 accent 色（截图钮显示为粉红），统一为次级灰
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
        HStack(spacing: 5) {
            if isSearchExpanded {
                // 展开态：胶囊内直接搜索剪贴板（用户需求：底部要有搜索框，而不只是图标）
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索剪贴板", text: $clipboard.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 168)
                        .focused($bottomSearchFocused)
                        .onSubmit { closeBottomSearch() }
                    Button {
                        closeBottomSearch(clear: false)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("收起搜索")
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                toolbarIcon("magnifyingglass", help: "搜索") {
                    withAnimation(Theme.Motion.spring) {
                        isSearchExpanded = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { bottomSearchFocused = true }
                }
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
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
                    // v153：只有「筛选生效」时才用强调色。旧版无条件染蓝，
                    // 让用户以为一直有个筛选在起作用（状态色被当成装饰色）。
                    .foregroundStyle(ClipboardManager.shared.filter == .all
                                     ? Color.secondary : Theme.accent)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("分类筛选")
            .accessibilityLabel("分类筛选")

            toolbarIcon("tag", help: "标签") {
                isShowingTagSheet = true
            }
            // v102（2026-10-21 用户：「向上箭头功能应该是回到顶部」）：
            // 按钮此前误做成「上传」占位（只弹提示，用户感知为点击无效）。
            // 改为回到顶部：平滑滚回剪贴板列表顶端（FilterBar_ScrollToTop 语义）。
            toolbarIcon("arrow.up", help: "回到顶部") {
                NotificationCenter.default.post(name: .frsetClipboardScrollTop, object: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // v110（三级玻璃 L3 工具条胶囊）：半透明真玻璃——与页面底（更淡）、
        // 白卡片（实底白玻璃）都不同的第三种质感；亮边 + 浮起投影。
        .background(
            ZStack {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.12),
                                 Color.primary.opacity(0.10)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6)
        )
        .fixedSize()
    }

    private func closeBottomSearch(clear: Bool = true) {
        bottomSearchFocused = false
        if clear { clipboard.searchText = "" }
        withAnimation(Theme.Motion.spring) {
            isSearchExpanded = false
        }
    }

    private func toolbarIcon(_ symbol: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 26, height: 26)
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
                .font(.system(size: 14))
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
        // v136（用户：「毛玻璃效果和之前不一样 + 滑动明显卡顿」诊断结论）：
        // 三/四页常驻 ZStack + opacity(0) 的旧结构，每帧都要合成全部页面图层
        //（v130 增第四页「投屏」后叠到 4 层），且任何面板状态变化（剪贴板每秒
        //  更新等）都会重算隐藏页的 body——滚动掉帧与玻璃观感发闷的共同来源。
        // 改为**按页实例化**：隐藏页完全不进入视图树（零合成、零 body 求值）。
        // 页面数据在单例 Store，切换丢的只是滚动位置，可接受。
        ZStack(alignment: .top) {
            if enabledPages.isEmpty {
                // v177：四个页面全关 —— 一个内容视图都不创建（不占内存），只留提示
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("未启用任何页面")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("到「设置 → 个性化 → 主面板页面」里开启")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { Log.info("Panel", "四个页面全部关闭：未创建任何页面视图") }
            } else if activePage == .home {
                homePage.transition(.opacity)
            } else if activePage == .performance {
                // 第二页：性能监测——与独立窗**同一个容器**（MonitorPerformanceContent：
                // 同一选中态、同一内外边距、同一滚动策略）。v82（2026-10-19）：外层
                // ScrollView 移除——双层嵌套曾导致模块切换按钮点击被吞。
                MonitorPerformanceContent().transition(.opacity)
            } else if activePage == .transfer {
                // 第三页：文件中转（隔空投送 / 扫码直传 / ADB 文件互传 / 本地暂存）
                TransferDockView().transition(.opacity)
            } else {
                // 第四页：投屏（v114 从文件中转拆出；v136 起不再常驻合成）
                CastView().transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.Motion.fast, value: page)
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

            // v74（用户需求 2026-10-19）：网盘链接条——搜索框正下方。
            // 剪贴板最近条目命中网盘分享链接时显示（无链接时不占位）。
            CloudLinkBar()
                .padding(.horizontal, 14)
                .padding(.top, 8)

            Color.clear.frame(height: 12)
            calendarCard
            clipboardSection
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // v74（用户澄清）：复制网盘链接 → 链接条自动弹出，日历与下方列表**平滑下移**；
        // 链接消失（关闭/换新）同样回弹。key 变化驱动整个首页纵向布局动画。
        .animation(Theme.Motion.springSoft,
                   value: CloudLinkBar.detectionKey(items: clipboard.items))
    }

    /// 搜索区段（Toolbox 模块经 PanelSectionRegistry 注入）
    @ViewBuilder private var searchSection: some View {
        if let descriptor = PanelSectionRegistry.all.first(where: { $0.id == "search" }) {
            descriptor.build()
        }
    }

    /// 背景图缓存（v101：路径不变不重读盘）
    private static var bgImageCache: (path: String, image: NSImage?)?
    private static func cachedBackgroundImage(path: String) -> NSImage? {
        if let c = bgImageCache, c.path == path { return c.image }
        let img = NSImage(contentsOfFile: path)
        bgImageCache = (path, img)
        return img
    }

    /// 首页分区统一横向内边距（v91：日历卡与剪贴板行卡必须同宽同缘）
    private let homeSectionInset: CGFloat = 8

    /// 日历卡（由 Toolbox 模块经 PanelSectionRegistry 注入；无区段标题，原版是一张独立卡片）
    @ViewBuilder private var calendarCard: some View {
        if let descriptor = PanelSectionRegistry.all.first(where: { $0.id == "calendar" }) {
            descriptor.build()
                .padding(.horizontal, homeSectionInset)
        }
    }

    /// 剪贴板列表（由 Clipboard 模块注入；原版直接是行列表，无标题/搜索/筛选）
    @ViewBuilder private var clipboardSection: some View {
        if let descriptor = PanelSectionRegistry.all.first(where: { $0.id == "clipboard" }) {
            descriptor.build()
                .padding(.horizontal, homeSectionInset)
        }
    }
}

// MARK: - 页面过渡（v136：改按页实例化后，pageTransition(active:) 已弃用——
// 常驻层淡入淡出是「每帧合成全部页面」的根源；过渡改由 .transition(.opacity) 承担）
