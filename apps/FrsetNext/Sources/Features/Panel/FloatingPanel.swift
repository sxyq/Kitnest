import AppKit
import SwiftUI

/// 主面板浮窗（原作 Frset.FloatingPanel 的正向重建）
/// 实证行为：置顶(.floating)、nonactivating 不抢占应用焦点、400×700、
/// 点击面板外部 / 失焦自动关闭、毛玻璃 + 圆角、弹出时轻微缩放淡入。
public final class FloatingPanel: NSPanel {

    /// - Parameters:
    ///   - contentRect: 初始尺寸（宽度 400、高度默认 700，来自 Preferences.panel.width/height）
    ///   - rootView: SwiftUI 根视图（PanelRootView）
    public init(contentRect: NSRect, rootView: some View) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating                          // 浮在普通窗口之上
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false               // 只 orderOut，不销毁实例
        hidesOnDeactivate = false                  // 失焦关闭由 PanelController 统一处理
        // 接收 mouseMoved：悬停预览的行高亮/预览调度与「关闭后移动鼠标才解除抑制」
        // 依赖本地 mouseMoved 监视器（specs/12 §3.7），缺此设置抑制将无法解除。
        // 原作贴图窗亦有同名设置（specs/16 §3.5 实证 acceptsMouseMovedEvents=true）。
        acceptsMouseMovedEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        // v71（用户：透明玻璃态用性能检测这边的）：solid = 性能检测窗同款
        // 纯色圆角卡片（windowBackgroundColor 不透桌面）；vibrancy = LiquidGlass 毛玻璃。
        // 原实现 solid 也走 NSGlassEffectView（tint 1.0 仍透光），与性能检测窗观感不一致。
        let solid = Personalization.shared.material == .solid
        let radius = Personalization.shared.cornerRadius
        let hosting = NSHostingView(rootView: rootView)
        if solid {
            let bg = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            bg.layer?.cornerRadius = radius
            bg.layer?.cornerCurve = .continuous
            bg.layer?.masksToBounds = true
            hosting.frame = bg.bounds
            hosting.autoresizingMask = [.width, .height]
            bg.addSubview(hosting)
            contentView = bg
        } else {
            let glass = LiquidGlass.makeView(frame: NSRect(origin: .zero, size: contentRect.size),
                                             cornerRadius: radius,
                                             material: .hudWindow,
                                             tint: NSColor.windowBackgroundColor.withAlphaComponent(0.55))
            LiquidGlass.embed(hosting, in: glass)
            contentView = glass
        }
    }

    /// 允许成为 key（顶部搜索框需要键盘输入）；
    /// .nonactivatingPanel 保证弹出/点击时不把焦点从当前应用抢走（即"不成为 key 的体感"）。
    public override var canBecomeKey: Bool { true }

    /// 对齐原作 init(coder:) 陷阱（0x10023c3e8）：禁止从 nib 反序列化创建
    public required init?(coder: NSCoder) {
        fatalError("FloatingPanel 不支持 NSCoder 初始化，请使用 init(contentRect:rootView:)")
    }
}

// MARK: - v66 个性化材质

extension FloatingPanel {
    /// 「个性化 → 背景材质」即时切换：纯色（性能检测窗同款圆角卡片）/ 毛玻璃
    public func applyPersonalizedMaterial() {
        let solid = Personalization.shared.material == .solid
        let radius = Personalization.shared.cornerRadius
        // v71：solid = 纯色圆角容器（非玻璃层）
        if solid, let bg = contentView {
            var isEffect = bg is NSVisualEffectView
            if #available(macOS 26.0, *), bg is NSGlassEffectView { isEffect = true }
            if !isEffect {
                bg.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                bg.layer?.cornerRadius = radius
                return
            }
        }
        let tint = NSColor.windowBackgroundColor.withAlphaComponent(solid ? 1.0 : 0.55)
        if #available(macOS 26.0, *), let glass = contentView as? NSGlassEffectView {
            glass.tintColor = tint
            glass.cornerRadius = radius
        } else if let effect = contentView as? NSVisualEffectView {
            effect.material = solid ? .windowBackground : .hudWindow
            effect.blendingMode = solid ? .withinWindow : .behindWindow
            effect.layer?.cornerRadius = radius
        }
    }
}
