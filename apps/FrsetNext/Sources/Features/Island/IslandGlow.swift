import SwiftUI

private struct IslandGlowEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var islandGlowEnabled: Bool {
        get { self[IslandGlowEnabledKey.self] }
        set { self[IslandGlowEnabledKey.self] = newValue }
    }
}

private struct IslandGlowRegion {
    let bounds: Anchor<CGRect>
    let radius: CGFloat
    var clips: [Anchor<CGRect>] = []
}

private struct IslandGlowRegions: PreferenceKey {
    static var defaultValue: [IslandGlowRegion] { [] }
    static func reduce(value: inout [IslandGlowRegion], nextValue: () -> [IslandGlowRegion]) {
        value += nextValue()
    }
}

/// 卡片与按钮只登记几何；指针移动只更新一个绘制层。
struct IslandGlowTarget: ViewModifier {
    var radius: CGFloat
    @Environment(\.islandGlowEnabled) private var enabled
    func body(content: Content) -> some View {
        content.transformAnchorPreference(key: IslandGlowRegions.self, value: .bounds) { regions, anchor in
            if enabled { regions.append(IslandGlowRegion(bounds: anchor, radius: radius)) }
        }
    }
}

private struct IslandGlowScene: ViewModifier {
    let enabled: Bool
    @Stored private var pointer = StoredBox((location: CGPoint.zero, active: false))
    func body(content: Content) -> some View {
        content
            .environment(\.islandGlowEnabled, enabled)
            .overlayPreferenceValue(IslandGlowRegions.self) { regions in
                GeometryReader { geometry in
                    IslandGlow(pointer: pointer, cards: regions.map { region in
                        let frame = geometry[region.bounds]
                        let clip = region.clips.reduce(CGRect(origin: .zero, size: geometry.size)) {
                            $0.intersection(geometry[$1])
                        }
                        return (frame, clip, RoundedRectangle(cornerRadius: region.radius, style: .continuous).path(in: frame))
                    })
                }.allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if enabled {
                        if !pointer.value.active { Log.info("Island", "流光指针进入") }
                        pointer.value = (point, true)
                    }
                case .ended: pointer.value.active = false
                }
            }
            .onChange(of: enabled) { if !$0 { pointer.value.active = false } }
            .onDisappear { pointer.value.active = false }
    }
}

/// 流光只照亮边缘，不叠加整张卡片的白色填充或改变玻璃透明度。
private struct IslandGlow: View {
    @ObservedObject var pointer: StoredBox<(location: CGPoint, active: Bool)>
    let cards: [(frame: CGRect, clip: CGRect, path: Path)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let point = pointer.value.location
        let visible = pointer.value.active
        Canvas { context, _ in
            for card in cards where card.frame.intersects(card.clip) {
                let radius = min(card.frame.width, card.frame.height) * 0.9
                if card.frame.insetBy(dx: -radius, dy: -radius).contains(point) {
                    let center = reduceMotion ? CGPoint(x: card.frame.midX, y: card.frame.midY) : point
                    let light = GraphicsContext.Shading.radialGradient(
                        Gradient(stops: [.init(color: .white.opacity(0.9), location: 0),
                                         .init(color: .white.opacity(0.45), location: 0.2),
                                         .init(color: .white.opacity(0.07), location: 0.65),
                                         .init(color: .clear, location: 1)]),
                        center: center, startRadius: 0, endRadius: radius)
                    var layer = context
                    layer.clip(to: Path(card.clip))
                    layer.clip(to: card.path)
                    layer.stroke(card.path, with: light, lineWidth: 3)
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? Theme.Motion.tap : visible ? Theme.Motion.fast : Theme.Motion.page, value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: cards.count) { Log.info("Island", "流光目标 \($0)") }
    }
}

extension View {
    func islandGlowScene(enabled: Bool) -> some View { modifier(IslandGlowScene(enabled: enabled)) }

    /// 滚动区域将其裁切边界传给同一绘制层，隐藏行不照亮标题或页脚。
    func islandGlowClip() -> some View {
        transformAnchorPreference(key: IslandGlowRegions.self, value: .bounds) { regions, clip in
            for index in regions.indices { regions[index].clips.append(clip) }
        }
    }
}
