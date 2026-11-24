import AppKit
import SwiftUI

private struct SettingsPreviewKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsPreviewClipboardKey: EnvironmentKey {
    static let defaultValue: [ClipboardItem] = []
}

private struct SettingsPreviewPersonalizationKey: EnvironmentKey {
    static let defaultValue: Personalization? = nil
}
private struct SettingsPreviewMidnightKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
private struct SettingsPreviewImageKey: EnvironmentKey {
    static let defaultValue: NSImage? = nil
}
private struct SettingsPreviewSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<String?>? = nil
}
private struct SettingsPreviewFilterKey: EnvironmentKey {
    static let defaultValue = ClipboardFilterKind.all
}
private struct SettingsPreviewQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var isSettingsPreview: Bool {
        get { self[SettingsPreviewKey.self] }
        set { self[SettingsPreviewKey.self] = newValue }
    }
    var settingsPreviewClipboardItems: [ClipboardItem] {
        get { self[SettingsPreviewClipboardKey.self] }
        set { self[SettingsPreviewClipboardKey.self] = newValue }
    }
    var settingsPreviewPersonalization: Personalization? {
        get { self[SettingsPreviewPersonalizationKey.self] }
        set { self[SettingsPreviewPersonalizationKey.self] = newValue }
    }
    var settingsPreviewIsMidnight: Bool? {
        get { self[SettingsPreviewMidnightKey.self] }
        set { self[SettingsPreviewMidnightKey.self] = newValue }
    }
    var settingsPreviewImage: NSImage? {
        get { self[SettingsPreviewImageKey.self] }
        set { self[SettingsPreviewImageKey.self] = newValue }
    }
    var settingsPreviewClipboardSelection: Binding<String?>? {
        get { self[SettingsPreviewSelectionKey.self] }
        set { self[SettingsPreviewSelectionKey.self] = newValue }
    }
    var settingsPreviewClipboardFilter: ClipboardFilterKind {
        get { self[SettingsPreviewFilterKey.self] }
        set { self[SettingsPreviewFilterKey.self] = newValue }
    }
    var settingsPreviewClipboardQuery: String {
        get { self[SettingsPreviewQueryKey.self] }
        set { self[SettingsPreviewQueryKey.self] = newValue }
    }
}

// MARK: - Liquid Glass 基础设施
//
// 设计口径（Apple HIG / Liquid Glass）：
//   · 玻璃表达「层级」而不是装饰：只铺在窗口 / 面板 / 弹出层这一类结构面上；
//     不给每张卡片各叠一层（叠层模糊既费 GPU 又会糊内容）。
//   · 卡片用「玻璃镀边」——极淡明度台阶 + 0.5pt 亮边，随明暗自适应；
//     观感与玻璃一致，代价接近零。同一张卡不再叠「渐变 + 高光 + 描边 + 阴影」四层
//     （2026-11-24：方向不一致的两道渐变会在卡面中间留下可见分界）。
//   · 辅助功能「降低透明度」开启时退回不透明底色，保证可读性。
//   · 后端由 `LiquidGlass.resolve` 统一解析（稳定毛玻璃为默认，系统玻璃显式可选）。
//
// 2026-11-24 v293：旧的 `extension LiquidGlass { makeView(material:personalization:) }`
// 已并入枚举本体的同签名入口——它当初只做「solid 恒 false」的转发，现在这件事由
// `Style.solid` 与 `resolve` 一起负责，保留两份入口只会让调用方分不清该走哪个。

// MARK: - SwiftUI 侧玻璃背景（sheet / 自定义面板）

struct LiquidGlassBackground: NSViewRepresentable {
    @Environment(\.isSettingsPreview) private var isSettingsPreview
    @Environment(\.settingsPreviewPersonalization) private var previewPersonalization
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 16
    var tint: Color?
    /// false = 不接管窗口阴影（调用方自己画内容阴影，窗口带透明留白时避免系统矩形阴影）
    var appliesWindowShadow: Bool = true

    /// v282 同款签名防抖：`reapplyStyle` 会给整窗玻璃重新设 material/blending/state，
    /// AppKit 随之作废整窗采样。数据刷新（性能数字、剪贴板列表）每秒都触发
    /// updateNSView，没有防抖就等于每秒重采样一次玻璃 —— 这是高负载下
    /// 「面板顿一下」的主要来源之一。签名没变就不碰材质。
    final class Coordinator {
        var signature: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = LiquidGlass.makeView(cornerRadius: cornerRadius,
                                        tint: tint.map { NSColor($0) },
                                        role: .panel,
                                        personalization: previewPersonalization ?? .shared)
        context.coordinator.signature = signature
        // SwiftUI 的 sheet 窗口默认不透明；不置透明的话玻璃只能采样到纯白底，
        // 看起来就是一块白板（2026-10-17 实测）。
        if isSettingsPreview {
            applyPreviewStyle(to: view)
        } else {
            DispatchQueue.main.async {
                guard let w = view.window else { return }
                w.applyOfficialBackground()
                w.hasShadow = appliesWindowShadow
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.signature != signature else {
            // 圆角/材质没变：只在预览模式下补一次外观（预览是另一个窗口实例）
            if isSettingsPreview { applyPreviewStyle(to: nsView) }
            return
        }
        context.coordinator.signature = signature
        // 个性化「背景材质 / 圆角 / 着色」变更后重套样式（否则切「纯色卡片」不生效）
        LiquidGlass.reapplyStyle(on: nsView,
                                 cornerRadius: cornerRadius,
                                 tint: tint.map { NSColor($0) },
                                 role: .panel,
                                 personalization: previewPersonalization ?? .shared)
        if isSettingsPreview {
            applyPreviewStyle(to: nsView)
        }
    }

    /// 与玻璃观感相关的全部输入。
    ///
    /// 2026-11-24 v293：**去掉 glassOpacity / glassBlur**。这两个参数只作用于
    /// `GlassSurface` 叠在玻璃之上的着色膜（另一个 SwiftUI 层，自己会随
    /// Personalization 重算），对底层 NSVisualEffectView 的材质没有任何影响。
    /// 旧签名把她们算进来，于是拖一下「通透度」滑块就重套一次材质 = 整窗重采样，
    /// 正是「拖滑块时面板顿一下」的来源。
    /// 新增：外观（深浅）、降透明度、实际后端与焦点策略——这三项才真正决定材质。
    private var signature: String {
        let dark = colorScheme == .dark
        let style = LiquidGlass.Style(role: .panel,
                                      tint: tint.map { NSColor($0) },
                                      cornerRadius: cornerRadius,
                                      focus: .stable)
        let resolved = LiquidGlass.resolve(style)
        return "\(resolved.signature)|dark\(dark ? 1 : 0)|preview\(isSettingsPreview ? 1 : 0)"
    }

    private func applyPreviewStyle(to view: NSView) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if let host = view as? GlassHost {
            // 预览窗：卡片材质只影响卡片，结构面保持采样语义；降透明度退不透明底。
            var style = host.style
            style.role = .panel
            style.solid = LiquidGlass.reduceTransparency
            host.apply(style)
        } else if let effect = view as? NSVisualEffectView {
            let solid = LiquidGlass.reduceTransparency
            effect.material = solid ? .windowBackground : .popover
            effect.blendingMode = solid ? .withinWindow : .behindWindow
        }
    }
}

// MARK: - 统一结构面（v203）
//
// 用户：「这两个改了无效……它的一个透明度调节是覆盖整个这个 APP 的，所以你统一」。
// 旧实现里「通透度 / 磨砂」只被 glassPlate 读取；主面板与悬浮剪贴板各写一套
// 纯 NSVisualEffectView 背景，两个滑块在两个主界面上等于空转。
// 这里收敛为全 App 唯一配方：
//     毛玻璃（采样桌面）→ 通透度底衬（Theme.windowSurface）→ 磨砂霜感（Theme.glassFrost）
// 霜感必须压在底衬之上——若在 93% 底衬之下，最大只剩 ~0.8% 可见度（滑块无效）。
//
// `@ObservedObject` 是必须的：滑块一拖 → Personalization.objectWillChange →
// 本视图重算 → 四个 Theme 计算属性拿到新值；只靠父视图观察时子树不一定重绘。
struct GlassSurface: View {
    var cornerRadius: CGFloat = Theme.Radius.window
    var tint: Color? = nil
    /// false = 窗口本身已有毛玻璃（主面板 FloatingPanel），不再叠第二层模糊
    var includesBlur: Bool = true
    /// false = 阴影由调用方内容层自绘（Toast 窗口有 24pt 透明留白）
    var appliesWindowShadow: Bool = true

    @ObservedObject private var personalization = Personalization.shared
    @ObservedObject private var appearance = AppearanceState.shared
    @Environment(\.settingsPreviewPersonalization) private var previewPersonalization
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight

    var body: some View {
        let p = previewPersonalization ?? personalization
        let colors = ThemeAppearance(personalization: p, isMidnight: previewIsMidnight ?? appearance.isMidnight)
        ZStack {
            if LiquidGlass.reduceTransparency {
                // 辅助功能「降低透明度」：玻璃与霜感一律退化为可读的不透明底，
                // 不再叠半透明色层（半透明正是该设置要关掉的东西）。
                colors.windowSurface.opacity(1)
            } else {
                if includesBlur {
                    // 2026-11-24：不再挂 .id(material) —— 背景材质只决定**内容卡片**
                    // 的实/透（见 GlassCard），与结构面玻璃无关。旧实现每切一次材质
                    // 就把整个 NSVisualEffectView 拆了重建，等于全窗玻璃重采样一次。
                    LiquidGlassBackground(cornerRadius: cornerRadius,
                                          tint: tint,
                                          appliesWindowShadow: appliesWindowShadow)
                }
                // 2026-11-24：底衬 + 霜感合成**一层**（旧实现两个 fill 叠着铺，
                // 同一块玻璃多一次整窗 alpha 合成；预合成结果与叠色等价）
                colors.glassTint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 全窗口玻璃底衬（v204）
//
// 用户：「需要覆盖所有界面」。官方灰底内容窗（设置/预览/检视/归档/截图结果/欢迎页…
// 共 20 余个）此前各自把窗口设成不透明灰，四个玻璃滑块只覆盖到主面板/悬浮剪贴板等。
// 这里给任意 NSWindow 在 contentView 背后插一层统一玻璃底
// （毛玻璃 → 通透度底衬 → 磨砂霜感），并订阅个性化通知实时刷新。
// 内容窗只需 isOpaque=false + 内容背景透明——applyOfficialChrome 已统一处理。

/// 「通透度底衬 + 磨砂霜感」预合成后的**一层**着色（NSView 版）：毛玻璃之上、内容之下。
/// 订阅个性化通知实时刷新——所有窗口的玻璃底都用它，保证与四个滑块一致。
///
/// 2026-11-24：旧实现是两个全尺寸无内容 subview（surface + frost）叠着铺，
/// 每个窗口每帧多一次整窗合成。两色都是纯色 + 常量 alpha，预合成后一层 CALayer 即可。
final class GlassTintOverlayView: NSView {

    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        refreshColors()
        observer = NotificationCenter.default.addObserver(
            forName: Personalization.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshColors() }
    }

    required init?(coder: NSCoder) { fatalError("GlassTintOverlayView 不支持 NSCoder") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
    }

    private func refreshColors() {
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(Theme.glassTint).cgColor
        }
    }
}

final class UnifiedGlassBackingView: NSView {

    private let glassView: NSView
    private let tintView = GlassTintOverlayView()
    private var content: NSView?
    private let topInset: CGFloat

    init(cornerRadius: CGFloat, topInset: CGFloat) {
        self.topInset = topInset
        // 2026-11-24 v293：内容窗统一走 `.window` 角色材质（underWindowBackground），
        // 不再写死 `.hudWindow`——HUD 材质偏暗，浅色外观下会在乳白着色膜底下发灰。
        glassView = LiquidGlass.makeView(cornerRadius: cornerRadius, role: .window)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        // 圆角由窗口自身裁切时（radius == 0）不开启 masksToBounds：
        // 整窗 masksToBounds 会强制一次离屏合成，而这里没有任何需要裁的内容。
        layer?.masksToBounds = cornerRadius > 0
        tintView.autoresizingMask = [.width, .height]
        addSubview(glassView)
        addSubview(tintView)
    }

    required init?(coder: NSCoder) { fatalError("UnifiedGlassBackingView 不支持 NSCoder") }

    func setContent(_ view: NSView) {
        guard content !== view else { return }
        content?.removeFromSuperview()
        content = view
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        layout()
    }

    override func layout() {
        super.layout()
        // 只在真变时赋值：AppKit 对 NSVisualEffectView.frame 的重复赋值会作废采样。
        if glassView.frame != bounds { glassView.frame = bounds }
        if tintView.frame != bounds { tintView.frame = bounds }
        if let content {
            let target = NSRect(x: 0, y: 0, width: bounds.width,
                                height: max(0, bounds.height - topInset))
            if content.frame != target { content.frame = target }
        }
    }
}

private var unifiedGlassAssocKey: UInt8 = 0

public extension NSWindow {
    /// 在 contentView 背后铺统一玻璃底（幂等）。调用后窗口变透明，
    /// 内容视图必须不画不透明整窗底色，否则会盖住玻璃。
    ///
    /// - Parameter cornerRadius: 默认 0 = 不自己画圆角，交给系统窗口自身的
    ///   原生圆角裁切（v205：用户要求窗口圆角恢复成今天早上那种系统原生形态，
    ///   自绘 12pt 会在系统圆角里再套一层，看起来"圆角变小/变尖"）。
    ///   只有无边框浮窗才需要显式传 12。
    func installUnifiedGlassBackground(cornerRadius: CGFloat = 0) {
        guard let content = contentView else { return }
        applyOfficialBackground()
        let backing: UnifiedGlassBackingView
        if let existing = objc_getAssociatedObject(self, &unifiedGlassAssocKey) as? UnifiedGlassBackingView {
            backing = existing
        } else {
            let inset: CGFloat = styleMask.contains(.titled) && !styleMask.contains(.fullSizeContentView)
                ? OfficialChrome.titlebarInset : 0
            backing = UnifiedGlassBackingView(cornerRadius: cornerRadius, topInset: inset)
            objc_setAssociatedObject(self, &unifiedGlassAssocKey, backing, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if content === backing { return }
        // 背景贯穿原生标题区。原来非 fullSize 的内容仍保留 32pt 标题净空。
        if styleMask.contains(.titled) { styleMask.insert(.fullSizeContentView) }
        backing.removeFromSuperview()
        backing.frame = NSRect(origin: .zero, size: frame.size)
        backing.setContent(content)
        if let controller = contentViewController, controller.view === content {
            let wrapper = NSViewController()
            wrapper.addChild(controller)
            wrapper.view = backing
            contentViewController = wrapper
        } else {
            contentView = backing
        }
        backing.layout()
        if UserDefaults.standard.bool(forKey: "probe.glassCoverage") {
            Log.info("Glass", "统一玻璃底：window=\(type(of: self)) content=\(type(of: content)) "
                     + "backing=\(Int(backing.frame.width))x\(Int(backing.frame.height))")
        }
    }
}

// MARK: - 白色玻璃卡（v110 三级玻璃之「内容卡」层）
//
// 三级玻璃口径（2026-10-21 用户）：
//   L1 页面底（FloatingPanel 窗玻璃）——最淡，衬底
//   L2 内容卡（剪贴板行 / 日历卡）——白色玻璃 + liquid 镀边（本样式）
//   L3 工具条胶囊——半透明真玻璃，第三种质感
// 卡片不叠真玻璃（逐卡模糊掉帧）：白渐变实底 + 顶部亮边即「玻璃」的卡片表达
// （亮边与明度台阶是质感来源，不是模糊）。
// 2026-11-24：去掉同卡的斜向高光与投影——一张卡同时挂「渐变 + 高光 + 描边 + 阴影」
// 正是用户点出的材质混乱来源；方向不一致的两道渐变还会在卡面中间留下可见分界。

struct WhiteGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    // 白玻璃基底：上亮下微暗的纵向渐变（玻璃的厚薄感）
                    shape.fill(
                        LinearGradient(
                            colors: dark
                                ? [Color.white.opacity(0.12), Color.white.opacity(0.05)]
                                : [Color.white.opacity(0.93), Color.white.opacity(0.80)],
                            startPoint: .top, endPoint: .bottom)
                    )
                }
            )
            .overlay(
                // liquid 镀边：顶部亮边（白 85%）→ 底部转深（玻璃边缘折光）
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(dark ? 0.24 : 0.85),
                            Color.white.opacity(dark ? 0.06 : 0.22),
                            Color.primary.opacity(0.08),
                        ],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.6)
            )
    }
}

extension View {
    /// 白色玻璃卡（内容卡层）：圆角可覆盖（默认 12）
    func whiteGlassCard(_ radius: CGFloat = 12) -> some View {
        modifier(WhiteGlassCard(cornerRadius: radius))
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
            .animation(Theme.Motion.springBouncy,
                       value: configuration.isPressed)
    }
}

// MARK: - 统一「玻璃面」（v179）
//
// 审计（函数表 11,562 个成员 / 144 个 View·Panel·Window 类型）发现的问题：
//   · 50 个含窗口定义的文件里，只有 4 个真正用了 NSVisualEffectView；
//     其余各写一套「clear 背景 + 自己画圆角卡片」，圆角从 5 到 24 有 17 种取值；
//   · 设置窗是官方灰底、命令面板是 .99 实色、悬停预览是自定义 VisualEffect、
//     云链接弹窗是 regularMaterial + 14pt —— 四个浮层四种"玻璃"。
//
// 定一条规则（与 Apple HIG 一致）：
//   结构面（窗口 / 悬浮面板）→ 真玻璃（26+ NSGlassEffectView，回退毛玻璃）；
//   内容卡片 → 不叠模糊，只用「玻璃镀边」（极淡填充 + 0.5pt 发丝线）。
// 所有浮层从这里取，不再各写一份。

/// 玻璃面修饰符：整块内容铺在统一玻璃上，圆角/描边/裁切一次到位。
struct GlassPlate: ViewModifier {
    var radius: CGFloat = Theme.Radius.window
    var bordered: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                // v203：统一配方（玻璃 → 通透度底衬 → 磨砂霜感），
                // 与主面板 / 悬浮剪贴板同一实现，四个滑块在这类浮层上全部生效。
                GlassSurface(cornerRadius: radius)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if bordered {
                    // v260：深色下 `Theme.hairlineColor` 是 10% 白线，套在整窗外圈
                    // 会变成一道显眼「线框」（用户反馈的四周曲线 + 外部线框）。
                    // 改用跟随「玻璃质感 → 描边」滑块的 cardStroke，深浅一致且可调。
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: Theme.Stroke.hairline)
                        .allowsHitTesting(false)
                }
            }
    }
}

public extension View {
    /// 把视图铺成一块统一玻璃面（浮层根视图用）。
    /// - Parameter radius: 默认窗口档 12；卡片不要用它，用 `glassCard()`。
    func glassPlate(radius: CGFloat = Theme.Radius.window,
                    bordered: Bool = true) -> some View {
        modifier(GlassPlate(radius: radius, bordered: bordered))
    }

    /// 内容卡片：极淡填充 + 发丝边（**不叠模糊**，避免 GPU 与糊内容）。
    /// 同时裁切内容到同一圆角——旧写法里 `.background(x).clipShape(r)` 的裁切语义
    /// 由这里一次到位，换过来时不会再漏一层圆角。
    /// - Parameter fill: 留空 = 自动（Midnight 主题卡片色 ?? `Theme.cardFill`）。
    func glassCard(radius: CGFloat = Theme.Radius.card,
                   fill: Color? = nil) -> some View {
        modifier(GlassCard(radius: radius, fill: fill))
    }
}

/// 内容卡片修饰符（v181：从 View 扩展里抽出来，才能读 environment ——
/// Midnight 主题的卡片覆盖色由 `AppearanceThemeModifier` 注入，这里自动跟随）。
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    var fill: Color? = nil
    @Environment(\.midnightCardBackgroundOverride) private var midnightCard
    /// v203：卡片亮度/描边两个滑块要即时生效——卡片修饰器自己观察个性化，
    /// 不能只依赖父视图（父视图不一定因 Theme 计算属性重绘）。
    @ObservedObject private var personalization = Personalization.shared
    @ObservedObject private var appearance = AppearanceState.shared
    @Environment(\.settingsPreviewPersonalization) private var previewPersonalization
    @Environment(\.settingsPreviewIsMidnight) private var previewIsMidnight

    func body(content: Content) -> some View {
        let p = previewPersonalization ?? personalization
        let colors = ThemeAppearance(personalization: p,
                                     isMidnight: previewIsMidnight ?? appearance.isMidnight)
        // 「背景材质 = 纯色卡片」时卡片走不透明底（同一个基色、alpha 1），
        // 毛玻璃时保留半透明填充（层次感来源）。此前该开关没有任何消费分支，
        // 设置里选什么都一样 —— 用户点名的"玻璃配置与执行不一致"之一。
        let color = fill ?? midnightCard
            ?? (p.material == .solid ? colors.readingBase : colors.cardFill)
        content.glassCard(radius: radius, fill: color, stroke: colors.cardStroke)
    }
}

public extension NSWindow {
    /// 把当前 contentView 重新装进统一玻璃底（悬浮层专用）。
    ///
    /// 幂等：已经是毛玻璃/真玻璃时直接返回。会同时把窗口置为透明，
    /// 否则玻璃只能采样到窗口自身的白底，看起来是一块白板（历史踩过）。
    ///
    /// - Parameters:
    ///   - radius: 圆角，默认窗口档 12。带系统标题栏的窗口不要传（会裁掉标题栏圆角）。
    ///   - material: 回退毛玻璃材质，默认 `.hudWindow`（浮层）。
    func adoptGlassSurface(cornerRadius radius: CGFloat = Theme.Radius.window,
                           material: NSVisualEffectView.Material? = nil) {
        guard let host = contentView else { return }
        // 幂等：已经是统一玻璃宿主 / 裸毛玻璃 / 系统玻璃时直接返回。
        if host is GlassHost { return }
        if host is NSVisualEffectView { return }
        if #available(macOS 26.0, *), host is NSGlassEffectView { return }

        let glass = LiquidGlass.makeView(cornerRadius: radius, material: material, role: .panel)
        glass.frame = host.frame
        LiquidGlass.embed(host, in: glass)
        // 毛玻璃之上补「通透度底衬 + 磨砂霜感」，与所有窗口的玻璃配方一致
        let tint = GlassTintOverlayView(frame: glass.bounds)
        tint.autoresizingMask = [.width, .height]
        glass.addSubview(tint, positioned: .below, relativeTo: host)
        contentView = glass

        applyOfficialBackground()
        glass.layer?.borderWidth = Theme.Stroke.hairline
        glass.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
    }
}
