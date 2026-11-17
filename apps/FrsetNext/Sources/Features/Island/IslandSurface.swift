import AppKit
import SwiftUI

struct IslandSurface<Content: View>: View {
    @ObservedObject var controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var navigation
    let height: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        let width = controller.effectiveWidth
        let target = CGSize(width: controller.expanded ? width : controller.collapsedWidth,
                            height: controller.expanded ? height : controller.notchHeight)
        VStack(spacing: Theme.Space.sm) {
            header
            tabs
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            pager
        }
        .islandGlowScene(enabled: controller.glowEnabled && controller.expanded && controller.previewVisible && !controller.editingLayout)
        .padding(.horizontal, IslandLayout.horizontalInset)
        .padding(.top, controller.notchHeight + 6)
        .padding(.bottom, IslandLayout.inset)
        .frame(width: width)
        .frame(width: width, height: height, alignment: .top)
        .modifier(IslandMorph(controller: controller, size: target,
                              progress: controller.expanded ? 1 : 0,
                              reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
        .animation(controller.surfaceAnimation(reduceMotion: reduceMotion),
                   value: [target.width, target.height, controller.expanded ? 1 : 0])
        .foregroundStyle(.primary)
        .tint(Theme.accent(for: nil))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary)
            Text("Kitnest").fontWeight(.medium)
            Text(controller.page.title).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
            if !IslandPage.tabs.contains(controller.page) {
                Button(action: controller.goBack) { Label(controller.returnPage.title, systemImage: "chevron.left").padding(.horizontal, 6) }
                    .buttonStyle(IslandButtonStyle()).font(.system(size: Theme.TextSize.caption))
            }
            Spacer()
            if controller.editingLayout {
                Menu {
                    ForEach(controller.layoutConfiguration.widgetOrder.filter {
                        controller.layoutConfiguration.hiddenWidgets.contains($0)
                    }) { item in
                        Button(item.title) { controller.setWidgetVisible(item, visible: true) }
                    }
                } label: { Label("添加组件", systemImage: "plus") }
                    .disabled(controller.layoutConfiguration.hiddenWidgets.isEmpty)
                Button("取消", action: controller.cancelLayoutEditing).buttonStyle(IslandButtonStyle())
                Button("完成", action: controller.finishLayoutEditing).buttonStyle(IslandButtonStyle())
            } else {
                Button(action: controller.beginLayoutEditing) {
                    Label("编辑布局", systemImage: "square.and.pencil")
                }.buttonStyle(IslandButtonStyle())
            }
            Button {
                if controller.previewOnly { controller.feedback = "完整主面板入口预览" }
                else { controller.performOutside { ServiceLocator.panel?.show() } }
            } label: {
                Image(systemName: "macwindow").frame(width: 26, height: 26)
            }.buttonStyle(IslandButtonStyle(help: "打开主面板")).accessibilityLabel("打开主面板")
            Button {
                if controller.previewOnly { controller.feedback = "设置位于总设置 → 刘海工作台" }
                else { controller.performOutside { ServiceLocator.settings?.open(pane: "island") } }
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26)
            }.buttonStyle(IslandButtonStyle(help: "总设置 · 刘海工作台")).accessibilityLabel("总设置 · 刘海工作台")
            Button(action: controller.collapse) {
                Image(systemName: "chevron.up").frame(width: 26, height: 26)
            }.buttonStyle(IslandButtonStyle(help: "收回刘海 · Esc", tipAlignment: .bottomTrailing)).accessibilityLabel("收回刘海")
        }.font(.system(size: Theme.TextSize.body))
    }

    private var pager: some View {
        HStack(spacing: 8) {
            Text(controller.feedback).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Button { controller.turnPage(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 22) }
                .buttonStyle(IslandButtonStyle()).accessibilityLabel("上一页")
            Text(controller.page == .home && controller.componentPageCount > 1
                 ? "组件 \(controller.componentPage + 1) / \(controller.componentPageCount)"
                 : IslandPage.tabs.firstIndex(of: controller.page).map { "入口 \($0 + 1) / \(IslandPage.tabs.count)" } ?? "详情")
                .font(.system(size: Theme.TextSize.caption)).monospacedDigit().foregroundStyle(.secondary)
            Button { controller.turnPage(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22) }
                .buttonStyle(IslandButtonStyle()).accessibilityLabel("下一页")
        }.frame(height: 20)
    }

    private var tabs: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(IslandPage.tabs) { page in
                Button { if controller.page != page { controller.page = page } } label: {
                    Text(page.title).frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle((IslandPage.tabs.contains(controller.page) ? controller.page : controller.returnPage) == page ? .primary : .secondary)
                        .background {
                            if (IslandPage.tabs.contains(controller.page) ? controller.page : controller.returnPage) == page {
                                RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous)
                                    .fill(Theme.rowHoverFill)
                                    .matchedGeometryEffect(id: "selection", in: navigation)
                            }
                        }
                }.buttonStyle(IslandButtonStyle(navigation: true))
                    .accessibilityAddTraits(controller.page == page ? .isSelected : [])
            }
        }.font(.system(size: Theme.TextSize.small, weight: .medium))
            .disabled(controller.editingLayout)
            .animation(reduceMotion ? nil : Theme.Motion.page, value: controller.page)
    }
}

/// 同一补间驱动尺寸、曲率、材质与内容，反向操作接续正在显示的几何。
private struct IslandMorph: AnimatableModifier {
    let controller: IslandController
    var size: CGSize
    var progress: CGFloat
    let reduceMotion: Bool
    let reduceTransparency: Bool
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(size.width, .init(size.height, progress)) }
        set { size = .init(width: newValue.first, height: newValue.second.first); progress = newValue.second.second }
    }

    func body(content: Content) -> some View {
        let phase = min(1, max(0, progress))
        let radius = IslandLayout.collapsedRadius + (IslandLayout.corner - IslandLayout.collapsedRadius) * phase
        let outline = IslandOutline(radius: radius)
        let reveal = reduceMotion ? phase : min(1, max(0, (phase - 0.2) / 0.8))
        content
            .compositingGroup()
            .opacity(reveal)
            .offset(y: reduceMotion ? 0 : -Theme.Space.sm * (1 - phase))
            .allowsHitTesting(controller.expanded && reveal > 0.5)
            .accessibilityHidden(!controller.expanded)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background {
                IslandMaterialHost(controller: controller, size: size, radius: radius,
                                   material: reduceTransparency ? .solid : controller.configuration.effectiveMaterial)
                    .id(reduceTransparency ? IslandMaterial.solid : controller.configuration.effectiveMaterial)
                    .overlay(Color.black.opacity(controller.usesGlass && !reduceTransparency ? 1 - phase * (1 - controller.configuration.opacity) : 1))
                    .overlay(alignment: .top) {
                        if controller.previewOnly && controller.displayScreen.safeAreaInsets.top > 0 {
                            Color.black.frame(width: controller.notchWidth, height: controller.notchHeight)
                                .clipShape(IslandOutline(radius: Theme.Radius.chip))
                        }
                    }
                    .allowsHitTesting(false)
            }
            .clipShape(outline)
            .overlay(alignment: .top) {
                IslandCollapsedView(controller: controller)
                    .opacity(1 - phase)
                    .allowsHitTesting(!controller.expanded)
                    .accessibilityHidden(controller.expanded)
            }
            .overlay {
                outline.stroke(Color.primary.opacity(0.12 * phase), lineWidth: Theme.Stroke.hairline)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                .init(color: .clear, location: 0.12),
                                                .init(color: .white, location: 0.3),
                                                .init(color: .white, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
            .contentShape(outline)
    }
}

struct IslandOutline: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let shoulder = min(radius * 0.45, rect.height / 2)
        let bottom = min(radius, rect.height - shoulder)
        let left = rect.minX + shoulder, right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(to: CGPoint(x: left, y: rect.minY + shoulder),
                      control1: CGPoint(x: left, y: rect.minY), control2: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addCurve(to: CGPoint(x: left + bottom, y: rect.maxY),
                      control1: CGPoint(x: left, y: rect.maxY), control2: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addCurve(to: CGPoint(x: right, y: rect.maxY - bottom),
                      control1: CGPoint(x: right, y: rect.maxY), control2: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: right, y: rect.minY + shoulder))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                      control1: CGPoint(x: right, y: rect.minY), control2: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct IslandMaterialHost: NSViewRepresentable {
    let controller: IslandController
    let size: CGSize
    let radius: CGFloat
    let material: IslandMaterial
    func makeNSView(context: Context) -> IslandMaterialView {
        IslandMaterialView(material: material)
    }
    func updateNSView(_ view: IslandMaterialView, context: Context) {
        if view.radius != radius { view.radius = radius; view.needsLayout = true }
        controller.surfaceDidChange(size: size, radius: radius)
    }
}

private final class IslandMaterialView: NSView {
    var radius: CGFloat = 0
    private let mask = CAShapeLayer()
    private var renderedBounds = CGRect.zero
    private var renderedRadius: CGFloat = -1
    override var isFlipped: Bool { true }
    init(material: IslandMaterial) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.mask = mask
        let glass = LiquidGlass.makeView(cornerRadius: 0, tint: IslandLayout.tint, solid: material == .solid,
                                        followsWindowFocus: material == .liquidGlass, systemGlass: material == .liquidGlass)
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout()
        guard bounds != renderedBounds || radius != renderedRadius else { return }
        renderedBounds = bounds; renderedRadius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 将玻璃上角移至屏幕外：可见上沿贴顶，下角保持原生折射曲率。
        subviews[0].frame = CGRect(x: 0, y: -radius, width: bounds.width, height: bounds.height + radius)
        LiquidGlass.setCornerRadius(radius, on: subviews[0])
        mask.frame = bounds
        mask.path = IslandOutline(radius: radius).path(in: bounds).cgPath
        CATransaction.commit()
    }
}

struct IslandButtonStyle: ButtonStyle {
    var help: String? = nil
    var tipAlignment: Alignment = .bottom
    var navigation = false
    var showsFocus = true
    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(label: configuration.label, pressed: configuration.isPressed, help: help,
                         tipAlignment: tipAlignment, navigation: navigation, showsFocus: showsFocus)
    }
}

private struct IslandButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let help: String?
    let tipAlignment: Alignment
    let navigation: Bool
    let showsFocus: Bool
    @Stored private var hovered = false
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
        label
            .background {
                RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous)
                    .fill(Theme.rowHoverFill.opacity(hovered ? 1 : 0))
            }
            .overlay {
                if showsFocus && focused {
                    RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous)
                        .strokeBorder(Theme.accent(for: nil), lineWidth: Theme.Stroke.emphasis)
                }
            }
            .scaleEffect(reduceMotion || !pressed ? 1 : 0.99)
        }
            .contentShape(Rectangle())
            .modifier(IslandGlowTarget(radius: IslandLayout.controlRadius))
            .onHover { hovered = $0 }
            .animation(Theme.Motion.tap, value: pressed)
            .animation(Theme.Motion.fast, value: hovered)
            .help(help ?? "")
    }
}

private struct IslandCollapsedView: View {
    @ObservedObject var controller: IslandController
    var body: some View {
        let items = controller.peekOrder.filter { controller.visiblePeeks.contains($0) }
        let leftCount = (items.count + 1) / 2
        let sideWidth = CGFloat(leftCount) * (controller.peeksShowValues ? 72 : 38)
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.prefix(leftCount))) { peek in button(peek) }
            }.frame(width: sideWidth, alignment: .trailing)
            Button { controller.expand(takeFocus: true) } label: {
                Color.clear.frame(width: controller.notchWidth, height: controller.notchHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("展开刘海")
            HStack(spacing: 0) {
                ForEach(Array(items.dropFirst(leftCount))) { peek in button(peek) }
            }.frame(width: sideWidth, alignment: .leading)
        }.frame(height: controller.notchHeight).foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
    private func button(_ peek: IslandPeek) -> some View {
        Button { controller.activatePeek(peek) } label: {
            if peek == .media {
                IslandPeekMediaValue(controller: controller)
            } else {
            HStack(spacing: 4) {
                Image(systemName: peek.icon)
                if controller.peeksShowValues {
                    if peek == .monitor {
                        IslandPeekPowerValue(previewOnly: controller.previewOnly)
                    } else {
                        Text(value(peek)).font(.system(size: 10)).monospacedDigit().lineLimit(1)
                    }
                }
            }.font(.system(size: 12)).frame(width: controller.peeksShowValues ? 72 : 38, height: controller.notchHeight)
            }
        }.buttonStyle(IslandButtonStyle())
            .help(controller.peeksQuickActions ? peek.quickActionTitle : "打开\(peek.title)")
            .accessibilityLabel(controller.peeksQuickActions ? peek.quickActionTitle : "打开\(peek.title)")
    }
    private func value(_ peek: IslandPeek) -> String {
        switch peek {
        case .clipboard: return controller.previewOnly ? IslandSample.clipboard[0].title : controller.clipboardSummary
        case .media: return controller.playing ? "播放中" : "暂停"
        case .calendar: return (controller.previewOnly ? SettingsPreviewSamples.date : Date.now).formatted(.dateTime.day())
        case .monitor:
            if controller.previewOnly { return "8.6 W" }
            return MonitorSampler.shared.sample.powerWatts.map { String(format: "%.1f W", $0) } ?? "— W"
        }
    }
}

private struct IslandPeekMediaValue: View {
    @ObservedObject var controller: IslandController
    @ObservedObject private var player = NowPlayingController.shared
    @Stored private var consumer = UUID()
    private var playing: Bool { controller.previewOnly ? controller.playing : player.snapshot.isPlaying }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: playing ? "pause.fill" : "music.note")
            if controller.peeksShowValues {
                Text(controller.previewOnly ? (playing ? "播放中" : "暂停")
                     : player.snapshot.available ? (playing ? "播放中" : "暂停") : "未播放")
                    .font(.system(size: Theme.TextSize.micro)).lineLimit(1)
            }
        }.font(.system(size: Theme.TextSize.small))
            .frame(width: controller.peeksShowValues ? 72 : 38, height: controller.notchHeight)
            .onAppear { updateVisibility() }
            .onChange(of: controller.expanded) { _ in updateVisibility() }
            .onDisappear { if !controller.previewOnly { player.setVisible(false, consumer: consumer) } }
    }
    private func updateVisibility() {
        if !controller.previewOnly { player.setVisible(!controller.expanded, consumer: consumer) }
    }
}

private struct IslandPeekPowerValue: View {
    let previewOnly: Bool
    @ObservedObject private var sampler = MonitorSampler.shared
    var body: some View {
        Text(previewOnly ? "8.6 W" : sampler.sample.powerWatts.map { String(format: "%.1f W", $0) } ?? "— W")
            .font(.system(size: 10)).monospacedDigit().lineLimit(1)
    }
}


