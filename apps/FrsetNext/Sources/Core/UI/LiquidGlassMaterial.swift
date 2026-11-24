import AppKit
import SwiftUI

// MARK: - 玻璃材质系统（v293 重构）
//
// 用户需求（2026-11-24，三条同时成立）：
//   ① 同一窗口点击前 / 点击后 / 失焦时玻璃外观一致；
//   ② 有参考 macOS 天气的自然背景采样、通透感、柔和边缘与清晰层次；
//   ③ 不造成明显 CPU/GPU 开销、掉帧与交互延迟。
//
// 旧实现（49cd59ed）的四类结构缺陷，本文件按「参数解析 / 后端对象 / 着色层」拆开解决：
//   B1 参数语义不一致：NSGlassEffectView 消费 tint，NSVisualEffectView 分支直接丢掉 tint
//      （岛的「外壳通透度」在默认后端上等于空转）；reapplyStyle 又把材质硬写成 .hudWindow，
//      覆盖调用方创建时指定的 .popover / .menu。
//   B2 对象类型不切换：部分宿主只在 init 建一次底层对象，之后只切 isHidden，
//      材质真的从毛玻璃换到系统玻璃（或反向）时底层对象根本没换。
//   B3 签名不完整 / 过多：LiquidGlassBackground 的签名包含只影响「着色膜」的
//      glassOpacity/glassBlur，漏掉实际后端、焦点策略与外观，导致该重采样时不重采样、
//      不该重采样时每秒重采样一次。
//   B6 布局重复赋值：frame/圆角/着色无变化时也重设，触发 AppKit 作废整窗采样。
//
// 设计边界：
//   · 只做「一个窗口一块结构面玻璃」，不给每张卡片叠模糊（HIG：玻璃表达层级）；
//   · NSGlassEffectView 没有公开的焦点锁定口子，稳定档一律走 NSVisualEffectView.fixed(.inactive)，
//     不虚构、不碰私有接口；
//   · 系统动态玻璃保留为显式可选（`uiUseSystemGlass`），且只在调用方声明
//     `followsSystemFocus` 时启用。

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

    /// 是否允许使用 macOS 26 的系统动态玻璃（默认关；显式写 true 才开）。
    ///
    /// 历史：v205 默认开 NSGlassEffectView，但它会随窗口 key/inactive 改变观感，
    /// 且 SDK 无公开固定口子（v202 的「焦点两套观感」由此回归）。
    /// 2026-11-24 定案：稳定玻璃为默认，系统玻璃显式可选。
    /// 「降低透明度」始终优先于本开关。
    static var prefersSystemGlass: Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: "uiUseSystemGlass") != nil else { return false }
        return d.bool(forKey: "uiUseSystemGlass")
    }

    /// 焦点策略：决定后端能不能用系统动态玻璃。
    enum FocusPolicy {
        /// 外观稳定：NSVisualEffectView + 硬钉 .inactive，任何窗口状态下浓淡一致。
        case stable
        /// 跟随系统：允许 NSGlassEffectView（会随 key/inactive 变化，用户显式选择才用）。
        case systemDynamic
    }

    /// 实际后端。
    enum Backend: String {
        case systemLiquid = "systemLiquid"
        case visualEffect = "visualEffect"
    }

    /// 材质角色：决定「用哪种系统材质」，不再让二十多个窗口各自猜一个 material。
    ///
    /// 2026-11-24 实测复核（浅色外观）：旧实现所有结构面统一 `.hudWindow`。
    /// HUD 材质本身偏暗，浅色外观下再压一层乳白着色膜 → 脏灰塑料感（用户反复提的
    /// 「灰雾」「白雾和深灰污染」）。角色化后：
    ///   window  → `.underWindowBackground`（Apple 给内容窗/侧栏的采样式材质，随明暗自适应）
    ///   panel   → `.popover`（浮层，浅色下通透、深色下不发灰）
    ///   menu    → `.menu`
    ///   hud     → `.hudWindow`（真正的深色 HUD：录制条、提示条）
    ///   island  → `.hudWindow`（刘海外壳恒深色，见 IslandSurface 强制 darkAqua）
    enum Role {
        case window, panel, menu, hud, island

        var material: NSVisualEffectView.Material {
            switch self {
            case .window: return .underWindowBackground
            case .panel: return .popover
            case .menu: return .menu
            case .hud, .island: return .hudWindow
            }
        }

        /// 稳定档的「体感厚度」：窗口最薄（采样优先），HUD 最厚。
        var filmScale: CGFloat {
            switch self {
            case .window: return 0.82
            case .panel: return 0.9
            case .menu: return 0.95
            case .hud, .island: return 1
            }
        }
    }

    /// 一份玻璃样式（纯值，可比较、可缓存）。所有参数都是**真实影响渲染**的输入。
    struct Style: Equatable {
        var role: Role = .panel
        /// 调用方显式指定的回退材质；nil = 按角色解析
        var material: NSVisualEffectView.Material?
        /// 着色：系统玻璃走 tintColor，毛玻璃走独立的着色层（两条后端语义一致）
        var tint: NSColor?
        /// 纯色（不采样）：降低透明度、或业务明确要求不透明底
        var solid: Bool = false
        var cornerRadius: CGFloat = 0
        var focus: FocusPolicy = .stable
        /// 显式指定是否允许系统玻璃（nil = 读全局偏好）
        var systemGlass: Bool?

        var resolvedMaterial: NSVisualEffectView.Material { material ?? role.material }
    }

    /// 解析后的样式：后端、材质、混合、状态、着色一次算清。
    struct Resolved: Equatable {
        var backend: Backend
        var material: NSVisualEffectView.Material
        var blending: NSVisualEffectView.BlendingMode
        var state: NSVisualEffectView.State
        var cornerRadius: CGFloat
        var tint: NSColor?
        var solid: Bool
        var appearanceName: String

        /// 真正影响渲染的签名。少一项会漏更新，多一项会让数据刷新误触发整窗重采样。
        var signature: String {
            var s = "\(backend.rawValue)|\(material.rawValue)|\(blending.rawValue)|\(state.rawValue)"
            s += "|r\(Int(cornerRadius * 100))|s\(solid ? 1 : 0)|a\(appearanceName)"
            if let tint {
                let c = tint.usingColorSpace(.sRGB) ?? tint
                s += String(format: "|t%.3f,%.3f,%.3f,%.3f",
                            c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
            } else {
                s += "|t-"
            }
            return s
        }
    }

    /// 参数解析：唯一入口。后端选择只在这里发生。
    static func resolve(_ style: Style, appearance: NSAppearance? = nil) -> Resolved {
        let solid = style.solid || reduceTransparency
        let appearanceName = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? "dark" : "light"
        let tint = resolvedTint(style.tint, appearance: appearance)
        if solid {
            // 降低透明度 / 纯色：不采样、不透明底，两条后端都退到同一语义。
            return Resolved(backend: .visualEffect, material: .windowBackground,
                            blending: .withinWindow, state: .active,
                            cornerRadius: style.cornerRadius, tint: nil, solid: true,
                            appearanceName: appearanceName)
        }
        let wantsSystem = style.focus == .systemDynamic
            && (style.systemGlass ?? prefersSystemGlass)
        if #available(macOS 26.0, *), wantsSystem {
            return Resolved(backend: .systemLiquid, material: style.resolvedMaterial,
                            blending: .behindWindow, state: .followsWindowActiveState,
                            cornerRadius: style.cornerRadius, tint: tint, solid: false,
                            appearanceName: appearanceName)
        }
        // 稳定档：state 硬钉 .inactive —— 不随 key window / App 前后台改变浓淡。
        return Resolved(backend: .visualEffect, material: style.resolvedMaterial,
                        blending: .behindWindow, state: .inactive,
                        cornerRadius: style.cornerRadius, tint: tint, solid: false,
                        appearanceName: appearanceName)
    }

    /// 动态 NSColor 必须在目标外观下取 CGColor，否则深色窗口会拿到浅色分量。
    static func resolvedTint(_ tint: NSColor?, appearance: NSAppearance?) -> NSColor? {
        guard let tint else { return nil }
        var out: NSColor = tint
        let work: () -> Void = { out = tint.usingColorSpace(.sRGB) ?? tint }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(work)
        } else {
            work()
        }
        return out
    }

    // MARK: 兼容入口（旧签名保留，内部统一走 Style）

    /// 玻璃容器。返回 `GlassHost`（NSGlassEffectView / NSVisualEffectView 由解析结果决定）。
    /// 内容由 `embed(_:in:)` 装入。
    static func makeView(frame: NSRect = .zero,
                         cornerRadius: CGFloat,
                         material: NSVisualEffectView.Material = .hudWindow,
                         tint: NSColor? = nil,
                         solid: Bool, followsWindowFocus: Bool = true,
                         systemGlass: Bool? = nil) -> NSView {
        var style = Style(role: .panel)
        style.material = material
        style.tint = tint
        style.solid = solid
        style.cornerRadius = cornerRadius
        style.focus = followsWindowFocus ? .systemDynamic : .stable
        style.systemGlass = systemGlass
        return GlassHost(frame: frame, style: style)
    }

    /// 结构面（窗口 / 悬浮面板 / 浮层）入口：材质按角色解析，不受「内容卡片材质」影响。
    static func makeView(frame: NSRect = .zero, cornerRadius: CGFloat,
                         material: NSVisualEffectView.Material? = nil,
                         tint: NSColor? = nil, role: Role = .window,
                         personalization: Personalization = .shared) -> NSView {
        var style = Style(role: role)
        style.material = material
        style.tint = tint
        style.cornerRadius = cornerRadius
        style.focus = .stable
        // 「降低透明度」与纯色都由 resolve 处理；结构面恒为采样态。
        _ = personalization
        return GlassHost(frame: frame, style: style)
    }

    /// 已存在的玻璃容器在「材质 / 圆角 / 着色 / 降透明度」变更后重新套样式。
    ///
    /// 幂等：解析后的签名没变时**完全不碰**底层对象（AppKit 会因 material/blending/state
    /// 的任何赋值作废整窗采样 → 肉眼闪一下）。真变了才在隐式动画里切换。
    static func reapplyStyle(on view: NSView, cornerRadius: CGFloat, tint: NSColor?,
                             solid: Bool) {
        if let host = view as? GlassHost {
            var style = host.style
            style.cornerRadius = cornerRadius
            style.tint = tint
            style.solid = solid
            host.apply(style)
            return
        }
        // 非 GlassHost（历史遗留的裸 NSVisualEffectView / NSGlassEffectView）
        setCornerRadius(cornerRadius, on: view)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.tintColor = tint
            return
        }
        guard let effect = view as? NSVisualEffectView else { return }
        let solid = solid || reduceTransparency
        let targetMaterial: NSVisualEffectView.Material = solid ? .windowBackground : .hudWindow
        let targetBlending: NSVisualEffectView.BlendingMode = solid ? .withinWindow : .behindWindow
        let targetState: NSVisualEffectView.State = solid ? .active : .inactive
        guard effect.material != targetMaterial
                || effect.blendingMode != targetBlending
                || effect.state != targetState else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.dFast
            context.allowsImplicitAnimation = true
            effect.material = targetMaterial
            effect.blendingMode = targetBlending
            effect.state = targetState
        }
    }

    static func reapplyStyle(on view: NSView, cornerRadius: CGFloat, tint: NSColor?,
                             role: Role = .window,
                             personalization: Personalization = .shared) {
        _ = personalization
        if let host = view as? GlassHost {
            var style = host.style
            style.cornerRadius = cornerRadius
            style.tint = tint
            style.role = role
            style.solid = false
            host.apply(style)
            return
        }
        reapplyStyle(on: view, cornerRadius: cornerRadius, tint: tint, solid: false)
    }

    /// 动画只更新几何，不重复设置材质与着色。
    static func setCornerRadius(_ radius: CGFloat, on view: NSView) {
        if let host = view as? GlassHost {
            host.setCornerRadius(radius)
            return
        }
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            guard glass.cornerRadius != radius else { return }
            glass.cornerRadius = radius
        } else {
            guard view.layer?.cornerRadius != radius else { return }
            view.layer?.cornerRadius = radius
            view.layer?.cornerCurve = .continuous
        }
    }

    /// 把内容装进玻璃容器并铺满
    ///
    /// v166.5：**不再用 `NSGlassEffectView.contentView`**。
    /// 该分支 2026-10-30 首次启用后实测崩溃（`_postWindowNeedsUpdateConstraints`
    /// → NSException → SIGABRT）。统一 addSubview：玻璃在底、着色层居中、内容在上。
    static func embed(_ content: NSView, in container: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

// MARK: - 玻璃宿主

/// 玻璃宿主：拥有「底层材质对象 + 着色层」，内容永远在上面。
///
/// 职责分离（用户要求的四件事，不新建框架）：
///   1. 参数解析 → `LiquidGlass.resolve`（纯函数）；
///   2. 实际后端 → 本类按解析结果持有 NSGlassEffectView / NSVisualEffectView，
///      **只有后端真的变了才替换对象**，普通着色/圆角变化复用现有对象；
///   3. 着色与内容层 → 毛玻璃用独立着色视图（与系统玻璃的 tintColor 语义对齐），
///      内容由 `embed` 装在两者之上；
///   4. 几何 → `layout()` 只在 frame 真变时赋值，不参与逐帧动画。
final class GlassHost: NSView {

    private(set) var style: LiquidGlass.Style
    private(set) var resolved: LiquidGlass.Resolved
    private var backendView: NSView
    private let tintView = GlassTintLayerView()
    private var appliedSignature = ""

    init(frame: NSRect = .zero, style: LiquidGlass.Style) {
        self.style = style
        self.resolved = LiquidGlass.resolve(style)
        self.backendView = Self.makeBackend(resolved)
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        addSubview(backendView)
        addSubview(tintView)
        apply(style, force: true)
    }

    required init?(coder: NSCoder) { fatalError("GlassHost 不支持 NSCoder") }

    /// 后端对象工厂：只有这里创建 NSGlassEffectView / NSVisualEffectView。
    private static func makeBackend(_ r: LiquidGlass.Resolved) -> NSView {
        let view: NSView
        if r.backend == .systemLiquid {
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.autoresizingMask = [.width, .height]
                if #available(macOS 27.0, *) {
                    // 玻璃自身不做交互式高光：点击反馈由内容层负责，避免和 hover 抢合成。
                    glass.effectIsInteractive = false
                }
                view = glass
            } else {
                view = NSVisualEffectView()
            }
        } else {
            view = NSVisualEffectView()
        }
        view.autoresizingMask = [.width, .height]
        return view
    }

    /// 唯一状态入口。幂等：签名没变时只补必要的颜色解析，不碰材质。
    func apply(_ newStyle: LiquidGlass.Style, force: Bool = false) {
        let r = LiquidGlass.resolve(newStyle, appearance: effectiveAppearance)
        let signature = r.signature
        if !force, signature == appliedSignature, newStyle.cornerRadius == resolved.cornerRadius {
            style = newStyle
            return
        }
        let backendChanged = r.backend != resolved.backend || force
        style = newStyle
        resolved = r
        appliedSignature = signature

        if backendChanged {
            // 只换底层对象，不动内容与窗口状态（内容视图的约束挂在宿主上，不受影响）。
            let replacement = Self.makeBackend(r)
            replacement.frame = bounds
            backendView.removeFromSuperview()
            // 玻璃永远在着色层之下、内容之上（内容由 embed 后加，顺序不变）。
            addSubview(replacement, positioned: .below, relativeTo: tintView)
            backendView = replacement
        }
        configureBackend(r)
        applyTint(r.tint)
        applyCorner(r.cornerRadius)
    }

    private func configureBackend(_ r: LiquidGlass.Resolved) {
        if #available(macOS 26.0, *), let glass = backendView as? NSGlassEffectView {
            if glass.tintColor != r.tint { glass.tintColor = r.tint }
            if glass.cornerRadius != r.cornerRadius { glass.cornerRadius = r.cornerRadius }
            return
        }
        guard let effect = backendView as? NSVisualEffectView else { return }
        // 三个属性都会作废整窗采样：值没变就不赋值（这是「失焦闪一下」的直接原因）。
        guard effect.material != r.material
                || effect.blendingMode != r.blending
                || effect.state != r.state else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.dFast
            context.allowsImplicitAnimation = true
            effect.material = r.material
            effect.blendingMode = r.blending
            effect.state = r.state
        }
    }

    /// 着色：两条后端语义一致——系统玻璃给 tintColor，毛玻璃给同色着色层。
    ///
    /// 旧实现毛玻璃分支把 tint 丢掉，岛的「外壳通透度」在默认后端上完全无效，
    /// 设置页却显示 68% 通透（用户点名的「参数与实际效果不一致」）。
    private func applyTint(_ tint: NSColor?) {
        if #available(macOS 26.0, *), backendView is NSGlassEffectView {
            tintView.isHidden = true
            return
        }
        tintView.isHidden = tint == nil
        tintView.apply(tint)
    }

    private func applyCorner(_ radius: CGFloat) {
        guard layer?.cornerRadius != radius else {
            // 圆角为 0 时不要留 masksToBounds（会让整窗多一次离屏合成）
            if radius == 0, layer?.masksToBounds == true { layer?.masksToBounds = false }
            return
        }
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = radius > 0
    }

    /// 几何专用入口（动画里只更新圆角，不重设材质）。
    func setCornerRadius(_ radius: CGFloat) {
        guard style.cornerRadius != radius else { return }
        style.cornerRadius = radius
        resolved.cornerRadius = radius
        applyCorner(radius)
        if #available(macOS 26.0, *), let glass = backendView as? NSGlassEffectView {
            glass.cornerRadius = radius
        }
        appliedSignature = resolved.signature
    }

    override func layout() {
        super.layout()
        // 只在尺寸真变时赋值：逐帧插值的岛只更新遮罩，不重设取样面。
        if backendView.frame != bounds { backendView.frame = bounds }
        if tintView.frame != bounds { tintView.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 动态 tint（黑白随明暗）与外观签名都要跟着走；材质本身由 AppKit 自适应。
        apply(style)
    }
}

/// 毛玻璃后端的着色层（纯 CALayer 填充，不参与布局/命中）。
private final class GlassTintLayerView: NSView {

    private var color: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("GlassTintLayerView 不支持 NSCoder") }

    func apply(_ color: NSColor?) {
        guard self.color != color else { return }
        self.color = color
        layer?.backgroundColor = color?.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
}

/// 一份内容卡片绘制实现，正式配置与内存展示只提供颜色。
public extension View {
    func glassCard(radius: CGFloat = Theme.Radius.card, fill: Color, stroke: Color) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: Theme.Stroke.hairline)
                    .allowsHitTesting(false)
            }
            .modifier(IslandGlowTarget(radius: radius))
            .islandGlowClip()
    }
}
