import SwiftUI

// MARK: - 设置窗口根视图
//
// 结构：五个居中顶部页签（通用/搜索/工具/快捷键/关于）+ 内容区。
// 页签几何对齐原版：居中成组，中心归一化 x = 0.262/0.377/0.500/0.623/0.741，
// 页签栏高 92pt（specs/07 §5-5 实证）。
//
// 布局纪律（2026-10-16 实证，勿改）：
// 根视图必须固定 .frame(width: 800, height: 530)。SwiftUI App lifecycle 下
// NSHostingView 会把根视图 fitting size 折成窗口尺寸请求；高度自由的根视图
// （.frame(maxHeight: .infinity)）令窗口被反复请求撑到内容自然高（实测 1554pt），
// 与窗口固定尺寸冲突，触发无限 Update Constraints 循环 →
// NSGenericException（"has already had more Update Constraints in Window passes
// than there are views in the window"）。各页内部滚动由 ScrollView 承担。

struct SettingsRootView: View {
    @ObservedObject var state: SettingsUIState
    @ObservedObject private var appearance = AppearanceState.shared
    @Environment(\.colorScheme) private var colorScheme
    /// 页签高亮块：切换时平滑滑动（matchedGeometry）
    @Namespace private var tabNamespace

    private let tabIDs = ["general", "search", "tools", "shortcuts", "about"]
    private let tabIcons = ["gearshape.fill", "magnifyingglass.circle.fill", "square.fill", "command.square.fill", "info.circle.fill"]

    private var panes: [SettingsPaneDescriptor] { SettingsPaneRegistry.all }
    private var selectedPane: SettingsPaneDescriptor? {
        panes.first { $0.id == state.selectedPaneID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(Array(tabIDs.enumerated()), id: \.element) { index, id in
                    if let pane = panes.first(where: { $0.id == id }) {
                        Button {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                                state.selectedPaneID = id
                                state.detailPaneID = nil
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: tabIcons[index])
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(height: 24)
                                    .overlay {
                                        if id == "tools" {
                                            Image(systemName: "line.diagonal")
                                                .font(.system(size: 14, weight: .heavy))
                                                .foregroundStyle(Color(NSColor.windowBackgroundColor))
                                        }
                                    }
                                Text(pane.title)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .frame(width: 76, height: 56)
                            .foregroundStyle(state.selectedPaneID == id ? Color.primary : Color.secondary)
                            .background {
                                if state.selectedPaneID == id {
                                    RoundedRectangle(cornerRadius: 13)
                                        .fill(Color.primary.opacity(0.07))
                                        .matchedGeometryEffect(id: "settingsTab", in: tabNamespace)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.tab.\(id)")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .offset(y: 2)
            Divider()
            if let pane = selectedPane {
                Group {
                    if state.selectedPaneID == "general" {
                        ScrollView {
                            pane.build()
                                .padding(.horizontal, 50)
                                .padding(.top, 12)
                                .padding(.bottom, 24)
                        }
                    } else if state.selectedPaneID == "about" {
                        pane.build()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if state.selectedPaneID == "tools" || state.selectedPaneID == "search" {
                        pane.build()
                            .padding(.horizontal, 30)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        ScrollView {
                            pane.build()
                                .padding(.horizontal, 30)
                                .padding(.vertical, 16)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                }
                .id(state.selectedPaneID)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(width: 800, height: 530)
        .background(appearance.isMidnight ? MidnightTheme.baseBackground :
                    colorScheme == .light ? Color(white: 222.0 / 255.0) : Color(NSColor.windowBackgroundColor))
        .foregroundStyle(appearance.isMidnight ? MidnightTheme.textColor : Color.primary)
        .frsetAppearanceTheme()
        .ignoresSafeArea()
        .sheet(isPresented: Binding(
            get: { state.detailPaneID != nil },
            set: { if !$0 { state.detailPaneID = nil } }
        )) {
            if let pane = panes.first(where: { $0.id == state.detailPaneID }) {
                VStack(spacing: 0) {
                    HStack {
                        Text(pane.title).font(.headline)
                        Spacer()
                        Button("完成") { state.detailPaneID = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(20)
                    Divider()
                    ScrollView { pane.build().padding(24) }
                }
                .frame(width: 700, height: 460)
                .frsetAppearanceTheme()
            }
        }
    }
}
