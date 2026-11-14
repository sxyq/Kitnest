import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 外壳、导航和摘要共用一套结构；内容保持最终字号，只有外壳尺寸与遮罩变化。
struct IslandSurface<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let configuration: IslandConfiguration
    let expanded: Bool
    @Binding var page: IslandPage
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let height: CGFloat
    var onCollapse: () -> Void
    var onOpen: () -> Void
    var onSettings: () -> Void
    var onFullWindow: () -> Void
    var onReorder: ([IslandPage]) -> Void
    var summary: String
    var detail: String
    @ViewBuilder var content: () -> Content
    @Stored private var hovered: IslandPage?
    @Stored private var dragging: IslandPage?
    @Stored private var dragOrder: [IslandPage] = []
    @Stored private var didDrag = false
    private var width: CGFloat { CGFloat(configuration.width) }
    private var compactWidth: CGFloat { max(340, notchWidth + 180) }
    private var compactHeight: CGFloat { max(38, notchHeight + 8) }
    private var compactSideWidth: CGFloat {
        (compactWidth - notchWidth - 32 - (notchWidth > 0 ? 16 : 8)) / 2
    }
    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.12) :
            expanded ? .spring(response: 0.32, dampingFraction: 0.92) : .easeOut(duration: 0.22)
    }
    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    Label(summary, systemImage: "circle.hexagongrid.fill")
                        .lineLimit(1).truncationMode(.tail)
                }.buttonStyle(.plain).frame(width: compactSideWidth, alignment: .leading)
                if notchWidth > 0 { Color.clear.frame(width: notchWidth) }
                Text(detail).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: compactSideWidth, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .frame(width: compactWidth, height: compactHeight)
            .opacity(expanded ? 0 : 1)
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)

            VStack(spacing: 10) {
                header
                content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
            .padding(.top, notchHeight + 8)
            .frame(width: width, height: height)
            .opacity(expanded ? 1 : 0)
            .offset(y: expanded || reduceMotion ? 0 : -4)
            .animation(reduceMotion ? .easeOut(duration: 0.12) :
                .easeOut(duration: 0.16).delay(expanded ? 0.06 : 0), value: expanded)
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
        }
        .frame(width: expanded ? width : compactWidth,
               height: expanded ? height : compactHeight, alignment: .top)
        .background {
            if configuration.glass && !reduceTransparency { Rectangle().fill(.regularMaterial) }
            else { Color(nsColor: .windowBackgroundColor) }
        }
        .clipShape(IslandOutline(radius: expanded ? 28 : 14, shoulders: configuration.shoulders ? 10 : 0))
        .overlay {
            IslandOutline(radius: expanded ? 28 : 14, shoulders: configuration.shoulders ? 10 : 0)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(motion, value: expanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: height)
        .frsetThemeChrome()
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(configuration.pages) { item in
                let index = configuration.pages.firstIndex(of: item)!
                let near = hovered.flatMap { configuration.pages.firstIndex(of: $0) }
                    .map { abs($0 - index) == 1 } ?? false
                Button { if !didDrag { page = item } } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 14, weight: .medium))
                        .scaleEffect(reduceMotion || dragging != nil ? 1 : hovered == item ? 1.22 : near ? 1.07 : 1)
                        .offset(y: reduceMotion ? 0 : hovered == item ? -2 : near ? -1 : 0)
                        .frame(width: 28, height: 30)
                        .background(page == item ? Theme.accent.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(IslandButtonStyle()).help(item.title)
                .accessibilityLabel(item.title).accessibilityAddTraits(page == item ? .isSelected : [])
                .onHover { hovered = $0 ? item : nil }
                .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in
                        if dragging == nil { dragging = item; dragOrder = configuration.pages; didDrag = true }
                        let from = dragOrder.firstIndex(of: item)!
                        let to = min(dragOrder.count - 1, max(0, from + Int((value.translation.width / 36).rounded())))
                        var order = dragOrder
                        order.remove(at: from); order.insert(item, at: to)
                        if order != configuration.pages { onReorder(order) }
                    }
                    .onEnded { _ in dragging = nil; DispatchQueue.main.async { didDrag = false } })
            }
            Button(action: onCollapse) { Color.clear.frame(maxWidth: .infinity, minHeight: 30) }
                .buttonStyle(.plain).help("收起").accessibilityLabel("收起顶部刘海")
            Button(action: onFullWindow) { Image(systemName: "macwindow") }
                .buttonStyle(IslandButtonStyle()).help("在完整窗口继续")
                .accessibilityLabel("在完整窗口继续")
            Button(action: onSettings) { Image(systemName: "gearshape") }
                .buttonStyle(IslandButtonStyle()).help("顶部刘海设置").accessibilityLabel("顶部刘海设置")
            Button(action: onCollapse) { Image(systemName: "chevron.up") }
                .buttonStyle(IslandButtonStyle()).help("收起").accessibilityLabel("收起")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: configuration.pages)
    }
}

struct IslandOutline: InsettableShape {
    var radius: CGFloat
    var shoulders: CGFloat
    var inset: CGFloat = 0
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulders) }
        set { radius = newValue.first; shoulders = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let r = min(radius, box.height / 2)
        let s = min(shoulders, box.height / 3)
        return Path { p in
            p.move(to: CGPoint(x: box.minX, y: box.minY))
            p.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            p.addQuadCurve(to: CGPoint(x: box.maxX - s, y: box.minY + s),
                           control: CGPoint(x: box.maxX - s, y: box.minY))
            p.addLine(to: CGPoint(x: box.maxX - s, y: box.maxY - r))
            p.addQuadCurve(to: CGPoint(x: box.maxX - s - r, y: box.maxY),
                           control: CGPoint(x: box.maxX - s, y: box.maxY))
            p.addLine(to: CGPoint(x: box.minX + s + r, y: box.maxY))
            p.addQuadCurve(to: CGPoint(x: box.minX + s, y: box.maxY - r),
                           control: CGPoint(x: box.minX + s, y: box.maxY))
            p.addLine(to: CGPoint(x: box.minX + s, y: box.minY + s))
            p.addQuadCurve(to: CGPoint(x: box.minX, y: box.minY),
                           control: CGPoint(x: box.minX + s, y: box.minY))
            p.closeSubpath()
        }
    }
    func inset(by amount: CGFloat) -> Self { var copy = self; copy.inset += amount; return copy }
}

struct IslandButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 28, minHeight: 30)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

