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
    /// 文件拖入高亮（拖 .json 进面板 → 打开 JSON 检视器）
    @Stored private var isDropTargeted = false
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
    /// 「文件中转」分段显隐（设置 → 常规 → 功能）
    @AppStorage(Preferences.Keys.panelTransferDock) private var transferDockEnabled = true
    /// 首页网盘链接条数据源（v74：复制网盘链接 → 自动弹出 + 日历下移）
    @ObservedObject private var clipboard = ClipboardManager.shared

    private var page: PanelCenterPage { monitorPresenter.activePage }

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
            // 切到中转页才起局域网直传服务（默认不在后台常开端口）
            if newPage == .transfer { LanTransferServer.shared.startIfEnabled() }
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
        // 面板直接以中转页打开时（上次停留页）也要把直传服务拉起来
        .onAppear {
            if page == .transfer { LanTransferServer.shared.startIfEnabled() }
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
                .help("拖文件到这里：存进本地中转（硬链接）")
            }
        }
        .padding(2)
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
                monitorPresenter.selectTransferDock()
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
                            .font(.system(size: 9, weight: .bold))
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
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
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
                    // 官方该图标为蓝色激活态（当前筛选生效）
                    .foregroundStyle(Theme.accent)
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
        .fixedSize()
    }

    private func closeBottomSearch(clear: Bool = true) {
        bottomSearchFocused = false
        if clear { clipboard.searchText = "" }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
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
        // v71（用户：主页/性能检测同一套内容，渐入渐出动画要一样）：三页共用
        // 同一过渡语言——fade + 轻微 scale（与性能检测独立窗 popout 动画同族），
        // 不再一页一方向。
        ZStack(alignment: .top) {
            homePage
                .pageTransition(active: page == .home)

            // 第二页：性能监测（v71 恢复三页切换）——与独立窗**同一个容器**
            // （MonitorPerformanceContent：同一选中态、同一内外边距、同一滚动策略），
            // 不允许各自再写一份版式。
            // v82（2026-10-19）：外层 ScrollView 移除——滚动由 MonitorDetailView
            // 内部按内容区自行管理（切换条固定）。双层 ScrollView 嵌套曾导致
            // 模块切换按钮的点击被外层滚动容器吞掉（用户实证「点不动」）。
            MonitorPerformanceContent()
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
        .animation(.spring(response: 0.34, dampingFraction: 0.86),
                   value: CloudLinkBar.detectionKey(items: clipboard.items))
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
                .fill(Theme.accent.opacity(0.06))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45),
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
