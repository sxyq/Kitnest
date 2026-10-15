import AppKit
import SwiftUI

/// 主面板 SwiftUI 根视图（对应原作 PageRootView / 实测截图布局）：
/// 顶部工具条（应用名 + 设置 + ⋯）→ 搜索框 → 区段列表（PanelSectionRegistry）→ 底部退出/设置入口。
struct PanelRootView: View {
    @ObservedObject var presentation: PanelPresentationState
    @ObservedObject var searchHook: PanelSearchHook
    var onDismiss: () -> Void
    var onOpenSettings: () -> Void

    /// 顶部搜索框焦点（⌥F「打开并搜索」经 .frsetFocusPanelSearch 通知程序化聚焦）
    @FocusState private var searchFieldFocused: Bool

    // Midnight 主题覆盖（由 .frsetAppearanceTheme() 注入；非 Midnight 时全为 nil/false）
    @Environment(\.midnightBaseBackgroundOverride) private var midnightBaseBackground
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground
    @Environment(\.usesMidnightTextColor) private var usesMidnightTextColor
    @Environment(\.midnightTextColorOverride) private var midnightTextColor

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            searchBar
            content
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 弹出时轻微缩放淡入（隐藏时复位，配合 PanelController 的 alpha 动画）
        .scaleEffect(presentation.visible ? 1 : 0.96, anchor: .top)
        .opacity(presentation.visible ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: presentation.visible)
        .onExitCommand { onDismiss() }             // Esc 关闭面板
        // Midnight：深色基底（原作只在 DarkAqua NSAppearance 之上叠 SwiftUI 覆盖层）；
        // 非 Midnight 时不铺任何底色，保持 NSVisualEffectView 毛玻璃透出
        .background {
            if let base = midnightBaseBackground { base }
        }
        .foregroundStyle(bodyTextColor)
        // 主题注入器挂载点（注入器与四个 EnvironmentKey 在共享层 Core/AppearanceTheme.swift）
        .frsetAppearanceTheme()
        // ⌥F「打开并搜索」：原作聚焦的是**主面板顶部搜索框**，不是区段内的搜索框
        // （区段内 SearchSectionView 的接收保留：面板区段搜索框也能被聚焦不算回归）。
        // 通知名字面量与 Toolbox/SearchSectionView.swift 的 frsetFocusPanelSearch 一致；
        // 此处不引用该模块类型，遵守契约 §1.3（跨模块零直接类型引用）。
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("frset.focusPanelSearch"))) { _ in
            // 面板可能刚被 show()，稍等一拍让 TextField 挂到窗口后再聚焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                searchFieldFocused = true
            }
        }
    }

    /// 正文色：Midnight 且 usesMidnightTextColor 为真时用冷白蓝，否则用系统 primary
    private var bodyTextColor: Color {
        (usesMidnightTextColor ? midnightTextColor : nil) ?? .primary
    }

    /// 卡片底色：Midnight 覆盖优先，否则沿用 Theme.cardBackground
    private var cardBackground: Color {
        midnightCardBackground ?? Theme.cardBackground
    }

    // MARK: - 顶部工具条（约 40pt）

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Frset")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(bodyTextColor)     // Midnight 正文色覆盖
            Spacer()
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                // 预留：MoreMenuPopover（原作类名，更多菜单本期未接线）
            } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // MARK: - 搜索框

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索或输入 / 使用工具", text: $searchHook.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(bodyTextColor)
                // ⌥F 聚焦落点（契约 §5.2：仅 SwiftUI 侧焦点，不夺 NSView 的 first responder）
                .focused($searchFieldFocused)
            if !searchHook.query.isEmpty {
                Button {
                    searchHook.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(cardBackground)                 // Midnight 下取 cardBackground 覆盖
        .cornerRadius(Theme.smallRadius)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 内容区

    @ViewBuilder private var content: some View {
        if !searchHook.query.isEmpty {
            // 搜索态：本地剪贴板文本过滤结果
            PanelSearchResultsView(hook: searchHook)
        } else if PanelSectionRegistry.all.isEmpty {
            // 空状态：注册表为空时给出引导
            ScrollView {
                emptyState
                    .frame(maxWidth: .infinity)
            }
        } else {
            sections
        }
    }

    /// 区段列表：只经 PanelSectionRegistry.all 渲染，禁止引用其他 Features/* 类型
    private var sections: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(PanelSectionRegistry.all, id: \.id) { d in
                    PanelSectionView(title: d.title) {
                        d.build()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("还没有启用任何模块")
                .font(.system(size: 13, weight: .medium))
            Text("在设置中开启剪贴板、监测、工具等模块后，会在这里显示对应区段")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开设置") { onOpenSettings() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(30)
    }

    // MARK: - 底部入口

    private var bottomBar: some View {
        HStack {
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                onOpenSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 搜索结果列表（过滤本地剪贴板文本条目，点击复制）
struct PanelSearchResultsView: View {
    @ObservedObject var hook: PanelSearchHook
    // Midnight 卡片底色覆盖（由根视图的 .frsetAppearanceTheme() 注入）
    @Environment(\.midnightCardBackgroundOverride) private var midnightCardBackground

    private var cardBackground: Color {
        midnightCardBackground ?? Theme.cardBackground
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text("剪贴板搜索 · \(hook.results.count) 条")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .onAppear { hook.performSearch() }
        .onChange(of: hook.query) { _ in hook.performSearch() }
    }
}
