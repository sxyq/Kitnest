import AppKit
import SwiftUI

// MARK: - 设置窗口侧边栏（v41 大侧边栏结构）
//
// 用户 2026-10-18 指定：设置界面改成「左侧大侧边栏」——
//   一级①「主页」= 完整设置（10 个设置页归类成 6 类）
//   一级②「性能监测」= 模块二级目录（CPU/内存/GPU/磁盘/网络/传感器/电池）+ 监测设置
// 配色以性能监测页为准：选中色 MonitorColors.user（与 StatsPageView 标签胶囊同蓝）。

/// 设置项归类（10 个 pane → 6 类）
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case clipboard
    /// 文件中转（2026-10-20 用户要求单独一页：面板入口 / 手机扫码直传 / OPPO 云端通道 / 本地暂存）
    case transfer
    case searchAI
    case tooling
    case statistics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .clipboard: return "剪贴板"
        case .transfer: return "文件中转"
        case .searchAI: return "搜索与 AI"
        case .tooling: return "工具与快捷键"
        case .statistics: return "数据"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .clipboard: return "doc.on.clipboard"
        case .transfer: return "arrow.left.arrow.right.square"
        case .searchAI: return "magnifyingglass"
        case .tooling: return "hammer"
        case .statistics: return "chart.bar.xaxis"
        case .about: return "info.circle"
        }
    }
}

/// 侧边栏选中项
enum SettingsSidebarSelection: Hashable {
    case category(SettingsCategory)
    case monitorModule(MonitorModuleID)
    case monitorSettings
    /// v54：内嵌 STATS 部件设置（形态/颜色/间距/每模块选项，功能对齐 Stats）
    case monitorWidgets
    /// v88：使用手册（交互式树形手册，2026-10-20 用户需求）
    case manual
}

/// 侧边栏视图（宽 186，整窗高）
struct SettingsSidebarView: View {
    @ObservedObject var state: SettingsUIState
    @Environment(\.colorScheme) private var colorScheme

    /// 性能监测二级目录顺序（与性能页标签行一致；功耗不单列）
    private static let monitorModules: [MonitorModuleID] = [
        .cpu, .memory, .gpu, .disk, .network, .sensors, .battery
    ]

    private var accent: Color { MonitorColors.user }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    groupTitle("主页")
                    ForEach(SettingsCategory.allCases) { category in
                        navRow(title: category.title,
                               icon: category.systemImage,
                               selected: state.selection == .category(category)) {
                            state.selection = .category(category)
                        }
                    }

                    groupTitle("性能监测").padding(.top, 16)
                    ForEach(Self.monitorModules, id: \.self) { module in
                        navRow(title: module == .sensors ? "传感器" : module.displayName,
                               icon: module.systemImage,
                               selected: state.selection == .monitorModule(module)) {
                            state.selection = .monitorModule(module)
                        }
                    }
                    navRow(title: "监测设置",
                           icon: "slider.horizontal.3",
                           selected: state.selection == .monitorSettings) {
                        state.selection = .monitorSettings
                    }
                    navRow(title: "部件设置",
                           icon: "menubar.rectangle",
                           selected: state.selection == .monitorWidgets) {
                        state.selection = .monitorWidgets
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(width: Theme.settingsSidebarWidth)
        .background(
            Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035))
        )
    }

    // MARK: - 品牌区

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 20)
            Text(verbatim: "Frset")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        // 左侧留 44：让开窗口左上角的官方圆形关闭钮（14pt 圆 + 14pt 边距）
        .padding(.leading, 44)
        .padding(.trailing, 14)
        .frame(height: 50)
    }

    // MARK: - 行

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 9)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func navRow(title: String, icon: String, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? accent : Color.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? accent : Color.primary.opacity(0.86))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.15))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
            // v88：使用手册固定入口——放在页脚常驻可见（此前挂在滚动列表末尾，
            // 侧边栏内容超出可视区时需要滚动才能看到）
            Button {
                state.selection = .manual
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 11))
                        .frame(width: 16)
                    Text("使用手册")
                        .font(.system(size: 11.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(state.selection == .manual ? Theme.accent : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(.tertiary)
                Text(verbatim: "Frset v1.3.12")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
        }
    }
}
