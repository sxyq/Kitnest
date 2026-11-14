import SwiftUI

/// 顶部锚点固定；内容不缩放，黑色轮廓从硬件刘海尺寸连续伸展。
struct IslandSurface<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: IslandConfiguration
    let expanded: Bool
    @Binding var page: IslandPage
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let height: CGFloat
    var onCollapse: () -> Void
    var onOpen: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.contentShape(Rectangle()).onTapGesture(perform: onOpen)
                .accessibilityLabel("展开 Kitnest Demo")
            VStack(spacing: 0) {
                header
                tabs
                content().padding(.horizontal, 16).padding(.top, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                HStack {
                    Text("界面与动效 Demo").foregroundStyle(.secondary)
                    Spacer()
                    Label("完整界面", systemImage: "arrow.up.right").foregroundStyle(.secondary)
                }.font(.system(size: 11)).padding(.horizontal, 18)
                    .padding(.top, 8).padding(.bottom, 14)
            }
            .padding(.top, notchHeight + 6)
            .frame(width: configuration.width, height: height, alignment: .top)
            .opacity(expanded ? 1 : 0)
            .offset(y: expanded || reduceMotion ? 0 : -4)
            .animation(.easeOut(duration: expanded ? 0.16 : 0.12).delay(expanded ? 0.04 : 0), value: expanded)
            .allowsHitTesting(expanded).accessibilityHidden(!expanded)
        }
        .frame(width: expanded ? configuration.width : notchWidth,
               height: expanded ? height : notchHeight, alignment: .top)
        .clipShape(IslandOutline(radius: expanded ? 24 : 6, shoulders: expanded ? 8 : 0))
        .shadow(color: .black.opacity(expanded ? 0.28 : 0), radius: 12, y: 8)
        .animation(reduceMotion ? .easeOut(duration: 0.12) :
            expanded ? .spring(response: 0.20, dampingFraction: 0.88) : .easeOut(duration: 0.16), value: expanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: height)
        .foregroundStyle(.white).preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.3.layers.3d").foregroundStyle(Color.blue)
            Text("Kitnest").fontWeight(.medium)
            Text("工作台").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { page = .settings } label: { Image(systemName: "slider.horizontal.3") }
                .help("布局展示").accessibilityLabel("布局展示")
            Button {} label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("完整界面 · 仅展示").accessibilityLabel("完整界面 · 仅展示")
            Button(action: onCollapse) { Image(systemName: "chevron.up") }
                .help("收回刘海").accessibilityLabel("收回刘海")
        }.font(.system(size: 13)).buttonStyle(IslandButtonStyle())
            .padding(.horizontal, 18).frame(height: 30)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(IslandPage.tabs) { item in
                Button { page = item } label: {
                    Text(item.title).frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(page == item ? Color.blue : .white.opacity(0.6))
                        .background(page == item ? Color.blue.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityAddTraits(page == item ? .isSelected : [])
            }
        }.font(.system(size: 12)).buttonStyle(IslandButtonStyle())
            .padding(.horizontal, 16).padding(.bottom, 10)
            .overlay(alignment: .bottom) { Color.white.opacity(0.10).frame(height: 0.5) }
    }
}

struct IslandOutline: Shape {
    var radius: CGFloat
    var shoulders: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulders) }
        set { radius = newValue.first; shoulders = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        let s = min(shoulders, rect.height / 3)
        return Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.minY + s),
                           control: CGPoint(x: rect.maxX - s, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY),
                           control: CGPoint(x: rect.maxX - s, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + s + r, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.maxY - r),
                           control: CGPoint(x: rect.minX + s, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + s, y: rect.minY + s))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                           control: CGPoint(x: rect.minX + s, y: rect.minY))
            p.closeSubpath()
        }
    }
}

struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct IslandButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Stored private var hovered = false
    var body: some View {
        label.frame(minWidth: 26, minHeight: 26)
            .background(Color.white.opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .opacity(pressed ? 0.7 : 1)
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

