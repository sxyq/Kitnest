import AppKit
import SwiftUI

// MARK: - Liquid Glass 基础设施
//
// 设计口径（Apple HIG / Liquid Glass）：
//   · 玻璃表达「层级」而不是装饰：只铺在窗口 / 面板 / 弹出层这一类结构面上；
//     不给每张卡片各叠一层（叠层模糊既费 GPU 又会糊内容）。
//   · 卡片用「玻璃镀边」——极淡斜向高光 + 0.5pt 亮边 + 内阴影，随明暗自适应；
//     观感与玻璃一致，代价接近零。
//   · 辅助功能「降低透明度」开启时退回不透明底色，保证可读性。
//   · macOS 26+ 用真·NSGlassEffectView；旧系统回退 NSVisualEffectView（原观感）。

enum LiquidGlass {

    /// 当前系统是否支持真·液态玻璃
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 用户是否开启「降低透明度」
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// 玻璃容器。返回 NSGlassEffectView（26+）或 NSVisualEffectView（回退）。
    /// 内容由 `embed(_:in:)` 装入。
    static func makeView(frame: NSRect = .zero,
                         cornerRadius: CGFloat,
                         material: NSVisualEffectView.Material = .hudWindow,
                         tint: NSColor? = nil) -> NSView {
        if #available(macOS 26.0, *), !reduceTransparency {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            glass.autoresizingMask = [.width, .height]
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = false
            }
            return glass
        }
        // 回退：毛玻璃（原实现），降低透明度时改不透明底
        let effect = NSVisualEffectView(frame: frame)
        effect.material = reduceTransparency ? .windowBackground : material
        effect.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        if effect.layer == nil { effect.layer = CALayer() }
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        return effect
    }

    /// 把内容装进玻璃容器并铺满
    static func embed(_ content: NSView, in container: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *), let glass = container as? NSGlassEffectView {
            glass.contentView = content
        } else {
            container.addSubview(content)
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - SwiftUI 侧玻璃背景（sheet / 自定义面板）

struct LiquidGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    var tint: Color?

    func makeNSView(context: Context) -> NSView {
        let view = LiquidGlass.makeView(cornerRadius: cornerRadius,
                                        tint: tint.map { NSColor($0) })
        // SwiftUI 的 sheet 窗口默认不透明；不置透明的话玻璃只能采样到纯白底，
        // 看起来就是一块白板（2026-10-17 实测）。
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - 卡片「玻璃镀边」样式
//
// 不叠真玻璃：只加斜向高光 + 细亮边 + 内阴影。玻璃感来自分层与高光，
// 而不是再糊一层背景（列表/网格里逐卡模糊会明显掉帧）。

struct GlassCardBackground: View {
    var cornerRadius: CGFloat = Theme.cornerRadius
    @Environment(\.colorScheme) private var colorScheme

    private var highlight: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
    }

    private var base: Color {
        colorScheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.38)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(base)
            shape.fill(
                LinearGradient(
                    colors: [highlight, Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(colorScheme == .dark ? 0.18 : 0.75),
                             Color.white.opacity(0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.6
            )
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06),
                radius: 6, x: 0, y: 2)
    }
}

// MARK: - 按压回弹按钮样式（工具条 / 图标按钮）
//
// 只动 transform + opacity，短促 0.16s；指针设备高频操作不拖泥带水。

struct SpringyIconButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.88

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.62),
                       value: configuration.isPressed)
    }
}

// MARK: - 悬停微浮起（卡片）

struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.02
    @Stored private var hovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered ? scale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.80), value: hovered)
            .onHover { hovered = $0 }
    }
}

extension View {
}
