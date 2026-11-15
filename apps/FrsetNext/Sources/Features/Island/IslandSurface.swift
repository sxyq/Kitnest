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
        .islandGlowScene(enabled: controller.glowEnabled && controller.expanded)
        .padding(.horizontal, IslandLayout.inset)
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
                Button { controller.page = .home } label: { Label("总览", systemImage: "chevron.left").padding(.horizontal, 6) }
                    .buttonStyle(IslandButtonStyle()).font(.system(size: Theme.TextSize.caption))
            }
            Spacer()
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
            Text(IslandPage.tabs.firstIndex(of: controller.page).map { "\($0 + 1) / \(IslandPage.tabs.count)" } ?? "详情")
                .font(.system(size: Theme.TextSize.caption)).monospacedDigit().foregroundStyle(.secondary)
            Button { controller.turnPage(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22) }
                .buttonStyle(IslandButtonStyle()).accessibilityLabel("下一页")
        }.frame(height: 20)
    }

    private var tabs: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(IslandPage.tabs) { page in
                Button { controller.page = page } label: {
                    Text(page.title).frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(controller.page == page ? .primary : .secondary)
                        .background {
                            if controller.page == page {
                                RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous)
                                    .fill(Theme.rowHoverFill)
                                    .matchedGeometryEffect(id: "selection", in: navigation)
                            }
                        }
                }.buttonStyle(IslandButtonStyle(navigation: true))
                    .accessibilityAddTraits(controller.page == page ? .isSelected : [])
            }
        }.font(.system(size: Theme.TextSize.small, weight: .medium))
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
        let reveal = phase
        content
            .opacity(reveal)
            .offset(y: reduceMotion ? 0 : -Theme.Space.sm * (1 - phase))
            .allowsHitTesting(controller.expanded && reveal > 0.5)
            .accessibilityHidden(!controller.expanded)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background {
                IslandMaterial(controller: controller, size: size, radius: radius,
                               solid: !controller.usesGlass || reduceTransparency)
                    .id(!controller.usesGlass || reduceTransparency)
                    .overlay(Color.black.opacity(controller.usesGlass && !reduceTransparency ? 1 - phase * (1 - controller.configuration.opacity) : 1))
                    .overlay(alignment: .top) {
                        if controller.previewOnly || (controller.panel?.screen?.safeAreaInsets.top ?? 0) == 0 {
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
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12 * phase), lineWidth: Theme.Stroke.hairline)
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
        var path = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
        path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(radius, rect.height)))
        return path
    }
}

private struct IslandMaterial: NSViewRepresentable {
    let controller: IslandController
    let size: CGSize
    let radius: CGFloat
    let solid: Bool
    func makeNSView(context: Context) -> IslandMaterialView {
        IslandMaterialView(solid: solid)
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
    init(solid: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.mask = mask
        let glass = LiquidGlass.makeView(cornerRadius: 0, tint: IslandLayout.tint, solid: solid, followsWindowFocus: false)
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
    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(label: configuration.label, pressed: configuration.isPressed, help: help,
                         tipAlignment: tipAlignment, navigation: navigation)
    }
}

private struct IslandButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let help: String?
    let tipAlignment: Alignment
    let navigation: Bool
    @Stored private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
        label
            .background {
                RoundedRectangle(cornerRadius: IslandLayout.controlRadius, style: .continuous)
                    .fill(Theme.rowHoverFill.opacity(hovered ? 1 : 0))
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
            HStack(spacing: 4) {
                Image(systemName: peek == .media && controller.playing ? "pause.fill" : peek.icon)
                if controller.peeksShowValues {
                    if peek == .monitor {
                        IslandPeekPowerValue(previewOnly: controller.previewOnly)
                    } else {
                        Text(value(peek)).font(.system(size: 10)).monospacedDigit().lineLimit(1)
                    }
                }
            }.font(.system(size: 12)).frame(width: controller.peeksShowValues ? 72 : 38, height: controller.notchHeight)
        }.buttonStyle(IslandButtonStyle())
            .accessibilityLabel("\(peek.title) · \(controller.peeksQuickActions ? "快捷操作" : "打开页面")")
    }
    private func value(_ peek: IslandPeek) -> String {
        switch peek {
        case .clipboard: return "复制"
        case .media: return controller.playing ? "播放中" : "暂停"
        case .calendar: return Date.now.formatted(.dateTime.day())
        case .monitor:
            if controller.previewOnly { return "8.6 W" }
            return MonitorSampler.shared.sample.powerWatts.map { String(format: "%.1f W", $0) } ?? "— W"
        }
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


