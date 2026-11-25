import AppKit
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

extension Notification.Name {
    static let islandGlowShouldHide = Notification.Name("kitnest.islandGlowShouldHide")
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

/// 2026-11-26 修复：指针状态原来用 @Stored（底层 @StateObject）承载，每次指针移动写值
/// 都会经 objectWillChange 作废整个 IslandGlowScene.body，连带重跑 overlayPreferenceValue
/// 闭包（逐卡 geometry[anchor] 解析 + RoundedRectangle.path(in:)），等于每次移动 =
/// O(卡片数) 重算，注释所说的「只更新一个绘制层」并未真正隔离。
/// 改由普通引用类型承载：只有内层 IslandGlow（@ObservedObject）随指针刷新 Canvas，
/// 外层几何/路径映射不再重算。全 App 只有一个流光场景（IslandSurface），故用共享实例，
/// 跨视图重建也保持稳定引用。
private struct IslandGlowPointerState: Equatable {
    var location: CGPoint = .zero
    var active: Bool = false
}

private final class IslandGlowPointer: ObservableObject {
    static let shared = IslandGlowPointer()
    @Published var state = IslandGlowPointerState()
}

private struct IslandGlowScene: ViewModifier {
    let enabled: Bool
    private let pointer = IslandGlowPointer.shared
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
                        if !pointer.state.active { Log.info("Island", "流光指针进入") }
                        pointer.state = IslandGlowPointerState(location: point, active: true)
                    }
                case .ended: pointer.state.active = false
                }
            }
            .onChange(of: enabled) { if !$0 { pointer.state.active = false } }
            .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)
                .merge(with: NotificationCenter.default.publisher(for: .islandGlowShouldHide))
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification),
                       NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))) { _ in
                pointer.state.active = false
            }
            .onDisappear { pointer.state.active = false }
    }
}

/// 复用博客黑色模式：180pt 暖白表面柔光与 1pt 内侧边缘光。
private struct IslandGlow: View {
    @ObservedObject var pointer: IslandGlowPointer
    let cards: [(frame: CGRect, clip: CGRect, path: Path)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let point = pointer.state.location
        // 指针流光同样属于直接操作：减弱动态时只把淡入压成瞬时，不整段关掉。
        let visible = pointer.state.active
        let color = Color(red: 1, green: 244.0 / 255, blue: 227.0 / 255)
        let radius: CGFloat = 180
        Canvas { context, _ in
            for card in cards where card.frame.intersects(card.clip) {
                let frame = card.frame.intersection(card.clip)
                let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
                let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
                if dx * dx + dy * dy < radius * radius {
                    let surface = GraphicsContext.Shading.radialGradient(
                        Gradient(stops: [.init(color: color.opacity(0.16), location: 0),
                                         .init(color: color.opacity(0.06), location: 0.35),
                                         .init(color: color.opacity(0.012), location: 0.65),
                                         .init(color: .clear, location: 1)]),
                        center: point, startRadius: 0, endRadius: radius)
                    let rim = GraphicsContext.Shading.radialGradient(
                        Gradient(stops: [.init(color: color.opacity(0.45), location: 0),
                                         .init(color: color.opacity(0.18), location: 0.55),
                                         .init(color: .clear, location: 1)]),
                        center: point, startRadius: 0, endRadius: radius)
                    var layer = context
                    layer.clip(to: Path(card.clip))
                    layer.clip(to: card.path)
                    layer.fill(card.path, with: surface)
                    layer.stroke(card.path, with: rim, lineWidth: 2)
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.18), value: visible)
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
