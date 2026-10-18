import SwiftUI

/// 「性能监测」页（原版 Stats 整页 1:1）。
///
/// 结构与原版实测（400×700 面板）逐块对应：
/// ```
/// ┌ 标签行：CPU 内存 GPU 磁盘 网络 传感器 电池（选中蓝胶囊）┐  46pt
/// ├ 分隔线 ────────────────────────────────────────────┤
/// │ 模块内容（可滚动）：圆环 / 图表 / 分组键值 / 占用进程表 │
/// ├ 分隔线 ────────────────────────────────────────────┤
/// └ 刷新间隔 1.0s                              ↻  ⚙  34pt ┘
/// ```
/// 入口：主面板顶部分段「性能监测」；STATS 合并条部件点击则直达对应模块
/// （StatsBarEngine.openMonitor 预排 MonitorCenterPresenter.presented）。
public struct StatsPageView: View {
    @ObservedObject private var presenter = MonitorCenterPresenter.shared
    @ObservedObject private var sampler = MonitorSampler.shared
    /// 标签高亮胶囊的 matchedGeometry 命名空间（切标签时滑动而非瞬移）
    @Namespace private var tabNamespace
    /// 只有当前页真的在显示时才上报内容高度（两页常驻，主页时不该缩窗口）
    private let isActive: Bool

    public init(isActive: Bool = true) {
        self.isActive = isActive
    }

    /// 原版标签顺序（power 不在原版标签行：电池页含适配器段）
    private static let tabModules: [MonitorModuleID] = [
        .cpu, .memory, .gpu, .disk, .network, .sensors, .battery
    ]

    private var selected: MonitorModuleID {
        let current = presenter.presented ?? presenter.lastModule
        return current == .power ? .battery : current
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabs
            divider
            ScrollView(.vertical, showsIndicators: false) {
                StatsModulePage(module: selected)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: StatsContentHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    }
                    .id(selected)
                    .transition(.opacity)
            }
            .onPreferenceChange(StatsContentHeightKey.self) { [self] contentHeight in
                guard isActive, contentHeight > 1 else { return }
                // 原版性能页窗口高度 = 标签行 46 + 内容 + 底栏 34（上限 700，见 PanelController）
                let total = contentHeight + 46 + 34 + 1
                NotificationCenter.default.post(name: .statsPageHeightDidChange,
                                                object: nil,
                                                userInfo: ["height": total])
            }
            divider
            footer
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 0.5)
    }

    // MARK: - 模块标签行

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabModules, id: \.self) { module in
                let isSelected = selected == module
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        presenter.lastModule = module
                        presenter.presented = module
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: module.systemImage)
                            .font(.system(size: 11, weight: .medium))
                        Text(module.statsTabTitle)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .matchedGeometryEffect(id: "statsTabPill", in: tabNamespace)
                        }
                    }
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help(module.titleForStatsPage)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
    }

    // MARK: - 底部刷新条

    private var footer: some View {
        HStack(spacing: 12) {
            Text("刷新间隔 " + refreshIntervalText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button {
                sampler.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(SpringyIconButtonStyle())
            .help("立即刷新")

            // v59：性能页独立成窗口（⌥M 同款）——内容复用 MonitorDetailView
            Button {
                MonitorPopoutWindowController.shared.open(module: selected)
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(SpringyIconButtonStyle())
            .help("独立窗口 ⌥M")

            Button {
                StatsBarEngine.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(SpringyIconButtonStyle())
            .help("统计部件设置")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var refreshIntervalText: String {
        let value = MonitorPreferences.refreshInterval
        return String(format: "%.1fs", value)
    }
}

// MARK: - 内容高度测量（驱动面板高度自适应，对齐原版 402~602pt 的窗口高度）

private struct StatsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public extension Notification.Name {
    /// 性能页内容高度变化（userInfo["height"]，0 = 回到主页高度）
    static let statsPageHeightDidChange = Notification.Name("frset.statsPage.heightDidChange")
}

// MARK: - 标签行文案

private extension MonitorModuleID {
    /// 原版标签行文案（第 6 项原版写「传感器」，不是设置里的「温度」）
    var statsTabTitle: String {
        switch self {
        case .sensors: return "传感器"
        default: return titleForStatsPage
        }
    }

    /// 原版标签行 hover 提示
    var titleForStatsPage: String {
        switch self {
        case .power: return "功耗"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .gpu: return "GPU"
        case .disk: return "磁盘"
        case .network: return "网络"
        case .sensors: return "传感器"
        case .battery: return "电池"
        }
    }
}
