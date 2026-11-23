import AppKit
import SwiftUI

private struct SettingsTargetFieldKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var settingsTargetField: String? {
        get { self[SettingsTargetFieldKey.self] }
        set { self[SettingsTargetFieldKey.self] = newValue }
    }
}

// MARK: - 设置窗口通用 UI 组件
// 对齐 Frset 视觉：左侧图标 + 标题/副标题 + 右侧控件；圆角卡片分组。

/// 通用设置行：左侧可选图标 + 标题/副标题，右侧任意控件
struct SettingsRow<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsTargetField) private var targetField
    let icon: String?
    let title: String
    var subtitle: String? = nil
    let trailing: Trailing

    init(icon: String? = nil, title: String, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon; self.title = title; self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent.opacity(0.12))
                    .cornerRadius(Theme.Radius.chip)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 6)
        .background(targetField == title ? Theme.State.selected(isDark: colorScheme == .dark) : Color.clear)
        .id(title)
    }
}

/// 分组标题（分节头）
struct SettingsSection<Content: View>: View {
    @Environment(\.settingsTargetField) private var targetField
    @Stored private var isExpanded: Bool
    let title: String
    let collapsible: Bool
    /// v274（用户：「预览不需要自动折叠，所有的这种界面都不需要自动折叠」）：
    /// 预览类区块常驻展开——保留标题与右侧摘要，但不给折叠入口。
    let alwaysExpanded: Bool
    let summary: String?
    let content: Content

    init(_ title: String, collapsible: Bool = false, expanded: Bool = false,
         alwaysExpanded: Bool = false, summary: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.collapsible = collapsible
        self.alwaysExpanded = alwaysExpanded
        self.summary = summary
        self._isExpanded = Stored(wrappedValue: expanded)
        self.content = content()
    }

    var body: some View {
        // v273：title 为空时不画标题行——二级页的页头已经有大标题，
        // 段内再写一遍同名的会形成「标题下又一个同名标题」的重复。
        VStack(alignment: .leading, spacing: title.isEmpty ? 0 : 8) {
            if alwaysExpanded {
                HStack(spacing: 7) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    if let summary {
                        Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 24)
                content
            } else if collapsible {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 8)
                        if let summary {
                            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
                if isExpanded { content }
            } else {
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                content
            }
        }
        .id(title)
        .onAppear { if targetField != nil { isExpanded = true } }
        .onChange(of: targetField) { if $0 != nil { isExpanded = true } }
    }
}

/// 只记正文滚动位置；切页不创建第二个滚动视图。
struct SettingsScrollPosition: NSViewRepresentable {
    let state: SettingsUIState
    let page: SettingsPage
    func makeNSView(context: Context) -> PositionView { PositionView() }
    func updateNSView(_ view: PositionView, context: Context) {
        if view.page != page { view.detach() }
        view.state = state; view.page = page
        DispatchQueue.main.async { view.attach() }
    }
    static func dismantleNSView(_ view: PositionView, coordinator: ()) { view.detach() }
    final class PositionView: NSView {
        var state: SettingsUIState?
        var page: SettingsPage?
        private weak var scroll: NSScrollView?
        private var observation: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func attach() {
            guard scroll == nil, let owner = enclosingScrollView, let state, let page else { return }
            scroll = owner
            if state.detailPaneID == nil, let y = state.pageScrollOffsets[page] {
                owner.contentView.scroll(to: NSPoint(x: 0, y: y))
                owner.reflectScrolledClipView(owner.contentView)
            }
            owner.contentView.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: owner.contentView, queue: .main) { [weak self] _ in self?.remember() }
        }
        private func remember() {
            if let page, let scroll { state?.pageScrollOffsets[page] = scroll.contentView.bounds.origin.y }
        }
        func detach() {
            remember()
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil; scroll = nil
        }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}

/// 圆角卡片容器（分组内容底板）
struct SettingsGroupBox<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: Theme.Radius.card)
    }
}

/// 预览在左、控件在右的两栏。剪贴板外观页先用，其余外观页统一走这里。
/// 左列吃剩余宽度（预览按自身上限缩放），右列固定宽度，控件不会被压扁或越界。
struct SettingsPreviewColumns<Preview: View, Controls: View>: View {
    var controlsWidth: CGFloat = 270
    let preview: Preview
    let controls: Controls

    init(controlsWidth: CGFloat = 270,
         @ViewBuilder preview: () -> Preview,
         @ViewBuilder controls: () -> Controls) {
        self.controlsWidth = controlsWidth
        self.preview = preview()
        self.controls = controls()
    }

    var body: some View {
        SettingsPreviewColumnsLayout(controlsWidth: controlsWidth) {
            preview
            controls
            Rectangle().fill(Theme.separator)
        }
    }
}

/// 预览左、控件右；可用宽度不足时自动改成上下排。
/// 用 Layout 而不是 HStack + ViewThatFits：ViewThatFits 按理想宽度判断，
/// 预览的固定宽度会让它在 820 宽窗口仍选两栏，把右列挤出卡片。
private struct SettingsPreviewColumnsLayout: Layout {
    var controlsWidth: CGFloat = 270
    var previewWidth: CGFloat = 350
    var spacing: CGFloat = 14
    var breakpoint: CGFloat = 650

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? breakpoint
        guard subviews.count == 3 else { return .zero }
        if width >= breakpoint {
            let preview = subviews[0].sizeThatFits(.init(width: previewWidth, height: nil))
            let controls = subviews[1].sizeThatFits(.init(width: controlsWidth, height: nil))
            return CGSize(width: width, height: max(preview.height, controls.height))
        }
        let preview = subviews[0].sizeThatFits(.init(width: width, height: nil))
        let controls = subviews[1].sizeThatFits(.init(width: min(320, width), height: nil))
        return CGSize(width: width,
                      height: preview.height + spacing + 0.5 + spacing + controls.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let width = bounds.width
        if width >= breakpoint {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                              proposal: .init(width: previewWidth, height: nil))
            let controlsX = bounds.maxX - controlsWidth
            subviews[1].place(at: CGPoint(x: controlsX, y: bounds.minY),
                              proposal: .init(width: controlsWidth, height: nil))
            subviews[2].place(at: CGPoint(x: controlsX - spacing, y: bounds.minY),
                              proposal: .init(width: 0.5, height: bounds.height))
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                              proposal: .init(width: width, height: nil))
            let previewHeight = subviews[0].sizeThatFits(.init(width: width, height: nil)).height
            let ruleY = bounds.minY + previewHeight + spacing
            subviews[2].place(at: CGPoint(x: bounds.minX, y: ruleY),
                              proposal: .init(width: width, height: 0.5))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: ruleY + 0.5 + spacing),
                              proposal: .init(width: min(320, width), height: nil))
        }
    }
}

/// 分隔线（行与行之间）
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .opacity(0.6)
            .padding(.leading, 38)
    }
}

// MARK: - 可视化选项卡片（v234）
//
// 对齐 1Capture 设置里的「拖放架」四选一：**预览图 + 文字**，选中用强调色描边。
// 比下拉框贵一点地方，但外观类设置（钉图描边、主题、布局）用户必须"看见"才能选。

struct VisualOptionCard<Preview: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    /// 预览尺寸：默认 104×66；四张卡片并排放进「标签列 + 内容」的行里时需要收窄
    let previewSize: CGSize
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var preview: () -> Preview

    init(title: String,
         previewSize: CGSize = CGSize(width: 104, height: 66),
         selected: Bool,
         action: @escaping () -> Void,
         @ViewBuilder preview: @escaping () -> Preview) {
        self.title = title
        self.previewSize = previewSize
        self.selected = selected
        self.action = action
        self.preview = preview
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview()
                    .frame(width: previewSize.width, height: previewSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(selected ? Theme.accent : Theme.cardStroke,
                                          lineWidth: selected ? 2 : Theme.Stroke.hairline)
                    )
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.primary.opacity(0.82))
            }
            .padding(7)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(selected ? Theme.State.selected(isDark: colorScheme == .dark) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
