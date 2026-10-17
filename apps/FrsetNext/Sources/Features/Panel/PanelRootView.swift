import AppKit
import SwiftUI

/// 主面板 SwiftUI 根视图（1:1 复刻原版 Frset 1.3.12 实测版式）：
///
/// ```
/// ┌ 工具条：[截图][取色][悬浮剪贴板]   (主页│性能监测)   [⚙] ┐ 40pt
/// ├ 主页 ────────────────────────────────────────────────┤
/// │  🔍 搜索或输入 / 使用工具                                │
/// │  （建议位留白，原版同布局）                              │
/// │  ‹ 2026年10月 ›                              ⌄          │
/// │  周日 周一 周二 周三 周四 周五 周六                       │
/// │  11  12  13  14  15  16  [17]                           │
/// │  18  19  20  21  22  23  24                             │
/// │  [缩略图] 标题 …                         ↓  ↵           │
/// ├ 性能监测 ── StatsPageView（标签行 + 模块页 + 刷新条）────┤
/// └──────────────────────────────────────────────────────┘
/// ```
///
/// 说明：原版主页**没有**区段标题、没有底部退出/设置栏、没有「⋯」菜单，
/// 剪贴板也不是「标题 + 过滤栏 + 表格」——就是一条条的行。这里按原版收敛。
struct PanelRootView: View {
    @ObservedObject var presentation: PanelPresentationState
    @ObservedObject var searchHook: PanelSearchHook
    var onDismiss: () -> Void
    var onOpenSettings: () -> Void

    /// 顶部搜索框焦点（⌥F「打开并搜索」经 .frsetFocusPanelSearch 通知程序化聚焦）
    @FocusState private var searchFieldFocused: Bool

    /// 当前页与选中模块（nil = 主页；非 nil = 性能监测页 + 该模块）
    @ObservedObject private var monitorPresenter = MonitorCenterPresenter.shared
    /// 文件拖入高亮（拖 .json 进面板 → 打开 JSON 检视器）
    @Stored private var isDropTargeted = false

    private var isPerformance: Bool { monitorPresenter.isPerformance }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 弹出/收起：缩放 + 轻微上移 + 淡入（锚点贴菜单栏，像从图标「长出来」）。
        // 只动 transform/opacity，弹簧可被下一次开合打断。
        .scaleEffect(presentation.visible ? 1 : 0.93, anchor: .top)
        .offset(y: presentation.visible ? 0 : -10)
        .opacity(presentation.visible ? 1 : 0)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: presentation.visible)
        // 主页/性能切换：内容横移 + 交叉淡入，与顶部分段高亮同一条弹簧
        .animation(.spring(response: 0.30, dampingFraction: 0.88), value: page)
        // 切回主页：窗口高度还原（性能页按内容缩高，见 PanelController.applyStatsPageHeight）
        .onChange(of: page) { newPage in
            if newPage != .performance {
                NotificationCenter.default.post(name: .statsPageHeightDidChange,
                                                object: nil,
                                                userInfo: ["height": CGFloat(0)])
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
            if let base = midnightBaseBackground { base }
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
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("frset.focusPanelSearch"))) { _ in
            monitorPresenter.presented = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                searchFieldFocused = true
            }
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
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(SpringyIconButtonStyle())
                .focusable(false)
                .foregroundStyle(.secondary)
                .help("设置")
                .accessibilityLabel("设置")
            }

            // 中间分段（原版胶囊式：选中项浅蓝底）
            pageSegments
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// 「主页 | 性能监测」分段（自绘胶囊，对齐原版选中态）
    private var pageSegments: some View {
        HStack(spacing: 0) {
            segmentItem("主页", selected: page == .home) {
                monitorPresenter.selectHome()
            }
            segmentItem("性能监测", selected: page == .performance) {
                monitorPresenter.selectPerformance(true)
            }
            segmentItem("文件中转", selected: page == .transfer) {
                monitorPresenter.selectTransferDock()
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

    // MARK: - 内容区（两页常驻：滚动位置/动画状态互不干扰）

    @ViewBuilder private var content: some View {
        ZStack(alignment: .top) {
            homePage
                .opacity(page == .home ? 1 : 0)
                .offset(x: page == .home ? 0 : -16)
                .allowsHitTesting(page == .home)
                .accessibilityHidden(page != .home)

            StatsPageView(isActive: page == .performance)
                .opacity(page == .performance ? 1 : 0)
                .offset(x: page == .performance ? 0 : 16)
                .allowsHitTesting(page == .performance)
                .accessibilityHidden(page != .performance)

            // 第三页：中转站（文件暂存与转发）
            TransferDockView()
                .opacity(page == .transfer ? 1 : 0)
                .offset(x: page == .transfer ? 0 : 16)
                .allowsHitTesting(page == .transfer)
                .accessibilityHidden(page != .transfer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 主页：搜索框 → 建议位 → 日历 → 剪贴板

    private var homePage: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 14)
                .padding(.top, 2)

            if searchHook.query.isEmpty {
                // 建议位（原版：搜索框与日历之间留白，输入时这里出结果）
                Color.clear.frame(height: 96)
                calendarCard
                clipboardSection
                    .padding(.top, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    PanelSearchResultsView(hook: searchHook)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("搜索或输入 / 使用工具", text: $searchHook.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(bodyTextColor)
                .focused($searchFieldFocused)
            if !searchHook.query.isEmpty {
                Button {
                    searchHook.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
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

/// 搜索结果列表（过滤本地剪贴板文本条目，点击复制）
struct PanelSearchResultsView: View {
    @ObservedObject var hook: PanelSearchHook
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground

    private var cardBackground: Color {
        midnightCardBackground ?? Theme.cardBackground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("剪贴板搜索 · \(hook.results.count) 条")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            ForEach(hook.results) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(r.timestamp.relativeText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
                .cornerRadius(Theme.smallRadius)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(r.snippet, forType: .string)
                }
            }
            if hook.results.isEmpty {
                Text("没有匹配的剪贴板条目")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
            }
        }
        .onAppear { hook.performSearch() }
        .onChange(of: hook.query) { _ in hook.performSearch() }
    }
}
