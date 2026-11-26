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
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // v270：页面切换只动内容（10–16pt 横移 + 淡入），外壳尺寸不跟着变。
                .id(controller.page)
                .transition(.asymmetric(
                    insertion: .offset(x: CGFloat(controller.pageSlide) * 12).combined(with: .opacity),
                    removal: .offset(x: CGFloat(-controller.pageSlide) * 8).combined(with: .opacity)))
            pager
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.10)
                                : .timingCurve(0.4, 0, 0.2, 1, duration: 0.20),
                   value: controller.page)
        .islandGlowScene(enabled: controller.glowEnabled && controller.expanded && controller.previewVisible && !controller.editingLayout)
        .padding(.horizontal, IslandLayout.horizontalInset)
        .padding(.top, controller.notchHeight + 6)
        .padding(.bottom, IslandLayout.inset)
        .frame(width: width)
        .frame(width: width, height: height, alignment: .top)
        .modifier(IslandMorph(controller: controller, size: target,
                              progress: controller.expanded ? 1 : 0,
                              reduceMotion: reduceMotion, reduceTransparency: reduceTransparency,
                              expandedSize: CGSize(width: width, height: height)))
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
            Text(controller.configuration.pageTitle(controller.page)).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary)
            if !IslandPage.tabs.contains(controller.page) {
                Button(action: controller.goBack) {
                    Label(controller.configuration.pageTitle(controller.returnPage), systemImage: "chevron.left").padding(.horizontal, 6)
                }
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
                Button {
                    if controller.previewOnly {
                        controller.beginLayoutEditing()
                    } else {
                        controller.performOutside { ServiceLocator.settings?.open(pane: "island.canvas") }
                    }
                } label: {
                    Label("编辑组件", systemImage: "square.and.pencil")
                }.buttonStyle(IslandButtonStyle(help: "在独立设置窗口编辑组件"))
            }
            Button {
                if controller.previewOnly { controller.feedback = "完整主面板入口预览" }
                else { controller.performOutside { ServiceLocator.panel?.show() } }
            } label: {
                Image(systemName: "macwindow").frame(width: 26, height: 26)
            }.buttonStyle(IslandButtonStyle(help: "打开主面板")).accessibilityLabel("打开主面板")
            Button {
                if controller.previewOnly { controller.feedback = "收藏入口预览" }
                else { controller.performOutside { FavoritesWindowController.shared.show() } }
            } label: {
                Image(systemName: "star").frame(width: 26, height: 26)
            }.buttonStyle(IslandButtonStyle(help: "查看收藏")).accessibilityLabel("查看收藏")
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
            Text(pagerHint).font(.system(size: Theme.TextSize.caption)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
                Button {
                    if (controller.page == .home || controller.page == .custom) && controller.componentPageCount > 1 { controller.turnComponentPage(-1) }
                    else { controller.turnPage(-1) }
                } label: { Image(systemName: "chevron.left").frame(width: 24, height: 22) }
                .buttonStyle(IslandButtonStyle()).accessibilityLabel("上一页")
            Text(pagerLabel)
                .font(.system(size: Theme.TextSize.caption)).monospacedDigit().foregroundStyle(.secondary)
                Button {
                    if (controller.page == .home || controller.page == .custom) && controller.componentPageCount > 1 { controller.turnComponentPage(1) }
                    else { controller.turnPage(1) }
                } label: { Image(systemName: "chevron.right").frame(width: 24, height: 22) }
                .buttonStyle(IslandButtonStyle()).accessibilityLabel("下一页")
        }.frame(height: 20)
    }

    /// 详情页底部提示固定为「切换指标 / Esc 返回」，避免深链进入时还显示整页切页文案。
    private var pagerHint: String {
        controller.page == .monitor ? "左右切换指标 · Esc 返回上一页" : controller.feedback
    }

    /// 详情页显示当前指标名；其余显示组件页码或页面序号。
    private var pagerLabel: String {
        if controller.page == .monitor {
            return MonitorCenterPresenter.shared.monitorSelection.module.displayName
        }
        if (controller.page == .home || controller.page == .custom) && controller.componentPageCount > 1 {
            return "组件 \(controller.componentPage + 1) / \(controller.componentPageCount)"
        }
        return controller.configuration.visiblePages.firstIndex(of: controller.page)
            .map { "页面 \($0 + 1) / \(controller.configuration.visiblePages.count)" } ?? "详情"
    }

    private var tabs: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(controller.configuration.visiblePages) { page in
                Button { if controller.page != page { controller.selectPage(page) } } label: {
                    Text(controller.configuration.pageTitle(page)).frame(maxWidth: .infinity).frame(height: 28)
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
    /// 展开态最终尺寸（玻璃取样面用，不参与插值）
    let expandedSize: CGSize
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(size.width, .init(size.height, progress)) }
        set { size = .init(width: newValue.first, height: newValue.second.first); progress = newValue.second.second }
    }

    func body(content: Content) -> some View {
        let phase = min(1, max(0, progress))
        let radius = IslandLayout.collapsedRadius + (IslandLayout.corner - IslandLayout.collapsedRadius) * phase
        let outline = IslandOutline(radius: radius)
        let reveal = reduceMotion ? phase : min(1, max(0, (phase - 0.2) / 0.8))
        // v270：真实面板用 controller 的独立正文透明度（延后淡入 / 先淡出）；
        // 设置页预览没有 expand 时序，继续用几何进度。
        let bodyOpacity = controller.previewOnly ? reveal : min(reveal, controller.contentOpacity)
        content
            .compositingGroup()
            .opacity(bodyOpacity)
            .offset(y: reduceMotion ? 0 : -Theme.Space.sm * (1 - phase))
            .allowsHitTesting(controller.expanded && reveal > 0.5)
            .accessibilityHidden(!controller.expanded)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background {
                IslandMaterialHost(controller: controller, size: size, radius: radius,
                                   expandedSize: expandedSize,
                                   collapsedSize: CGSize(width: controller.collapsedWidth, height: controller.notchHeight),
                                   material: reduceTransparency ? .solid : controller.configuration.effectiveMaterial,
                                   shellOpacity: controller.configuration.opacity)
                    .id(reduceTransparency ? IslandMaterial.solid : controller.configuration.effectiveMaterial)
                    // 收起 → 展开的深色过渡只由这**一层**黑幕负责：
                    //   收起态恒 1（纯黑，与硬件刘海融合）；
                    //   展开态恒 0（深色程度交给玻璃自身的 tint，= 用户「外壳通透度」）。
                    // 旧实现把 tint(0.32) 与这层黑幕(0.32) 叠在一起，展开态实际不透明度
                    // 有 0.54，滑块写着 68% 通透却糊成一块灰毛玻璃（设置与执行不一致）。
                    // 2026-11-24：静止态不再挂这块整窗黑幕。
                    // 展开完成（phase=1）时它的不透明度本来就是 0，却仍作为一层全尺寸
                    // 视图参与每帧合成；只在形变途中需要它做「黑 → 玻璃」的过渡。
                    .overlay {
                        if controller.usesGlass && !reduceTransparency {
                            if phase < 0.999 { Color.black.opacity(1 - phase) }
                        } else {
                            Color.black
                        }
                    }
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
                // v274：系统自带折光（原生液态玻璃）时不再叠仿玻璃亮边——
                // NSGlassEffectView 自己有边缘高光，再画一条就是「双重描边」。
                // 毛玻璃 / 纯色没有系统边缘，保留这条发丝线维持形状可读性。
                if controller.configuration.effectiveMaterial != .liquidGlass || reduceTransparency {
                    outline.stroke(Color.primary.opacity(0.12 * phase), lineWidth: Theme.Stroke.hairline)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                    .init(color: .clear, location: 0.12),
                                                    .init(color: .white, location: 0.3),
                                                    .init(color: .white, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
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
    /// 当前插值尺寸（形变途中每帧变）
    let size: CGSize
    let radius: CGFloat
    /// 展开态 / 收起态的最终尺寸：玻璃**取样面**只在这两个值之间切换
    let expandedSize: CGSize
    let collapsedSize: CGSize
    let material: IslandMaterial
    /// 展开态外壳深色程度（= 设置里「外壳通透度」的补数）。收起态由外层黑幕负责，与它无关。
    let shellOpacity: Double

    func makeNSView(context: Context) -> IslandMaterialView {
        IslandMaterialView(material: material, shellOpacity: shellOpacity,
                           sampling: targetSize(expanded: controller.expanded),
                           samplingInset: controller.expanded ? IslandLayout.corner : Theme.Radius.chip)
    }

    /// v286：几何回调去重。SwiftUI 对**任意**岛状态变化（翻页、透明度动画帧、
    /// 剪贴板刷新）都会走 updateNSView；不带去重时 `surfaceDidChange` 每次都被调，
    /// 内部虽有 size/radius 守卫，但几何没变时这些调用纯属噪音——
    /// 在 Representable 层就拦掉，几何回调与鼠标移动彻底解耦（命中语义不变）。
    final class GeometryCoordinator {
        var lastSize: CGSize = .zero
        var lastRadius: CGFloat = -1
    }

    func makeCoordinator() -> GeometryCoordinator { GeometryCoordinator() }

    func updateNSView(_ view: IslandMaterialView, context: Context) {
        // 2026-11-24（用户：「检查 NSGlassEffectView 的尺寸变更及 CAShapeLayer 遮罩重绘成本」
        // 「避免非几何状态更新导致材质重复创建」）：
        // 形变途中 SwiftUI 每帧都会走到这里。旧实现每帧给玻璃重新设 frame + 圆角，
        // 等于每帧让 NSGlassEffectView 重算一次背景采样；现在只更新遮罩路径，
        // 取样面仅在「展开开始时放大一次 / 收起结束时缩回一次」。
        view.applyGeometry(interpolated: size, radius: radius,
                           sampling: targetSize(expanded: controller.expanded),
                           samplingInset: controller.expanded ? IslandLayout.corner : Theme.Radius.chip)
        // 材质/深色程度都可以事后变：`.id()` 契约下同 id 复用视图时，
        // 只有这里能把状态补齐（否则切材质后玻璃不会出现/不会消失）。
        if view.material != material { view.applyMaterial(material) }
        // 深色程度只改着色，不重建玻璃、不重算遮罩
        if view.shellOpacity != shellOpacity { view.shellOpacity = shellOpacity }
        // v286：几何真实变化才通知控制器（去重后回调次数 = 形变帧数，不再是全部状态帧）。
        if size != context.coordinator.lastSize || radius != context.coordinator.lastRadius {
            context.coordinator.lastSize = size
            context.coordinator.lastRadius = radius
            controller.surfaceDidChange(size: size, radius: radius)
        }
    }

    private func targetSize(expanded: Bool) -> CGSize { expanded ? expandedSize : collapsedSize }
}

private final class IslandMaterialView: NSView {
    var radius: CGFloat = 0
    /// 当前外壳材质。**必须能事后变更**：`.id()` 契约是「同 id → updateNSView」，
    /// 若 SwiftUI 复用了视图而 init 又提前 return，切到玻璃后就永远没有玻璃子视图
    /// （2026-11-23 子代理复核指出的补建陷阱）。这里统一用 `applyMaterial()` 收敛。
    private(set) var material: IslandMaterial = .liquidGlass
    /// 展开态外壳深色程度；改动只重着色（`LiquidGlass.reapplyStyle`），不重建采样层。
    var shellOpacity: CGFloat = 0.32 {
        didSet { if shellOpacity != oldValue { applyTint() } }
    }
    private let mask = CAShapeLayer()
    private var renderedBounds = CGRect.zero
    private var renderedRadius: CGFloat = -1
    /// 玻璃取样面尺寸（只在这两个值之间切换，不跟逐帧插值）
    private var sampling: CGSize = .zero
    /// 取样面自己的圆角/上移量：取该档的**最终**圆角，不跟逐帧插值，
    /// 否则玻璃 frame 每帧都变（= 每帧重采样，正是要消掉的那笔开销）。
    private var samplingInset: CGFloat = Theme.Radius.chip
    private var renderedSampling: CGSize = .zero
    private var renderedSamplingInset: CGFloat = -1
    /// 玻璃采样层。**始终创建**：纯色/降低透明度时只 `isHidden`，不移除——
    /// 隐藏的视图不参与渲染（不采样、不模糊），但材质切回玻璃时不需要补建。
    private var glassView: NSView?
    override var isFlipped: Bool { true }

    // MARK: 实测（2026-11-24，v292 口径修正）
    //
    // 逐帧记 layout 耗时与玻璃取样面更新次数，形变收尾时打一行日志。
    // 只记毫秒/次数，不记画面内容。
    // v292（性能第二轮 A4）：
    //   · 口径：glassFrameUpdates 统计的是 **glass.frame（取样面）变化次数**，不是
    //     NSGlassEffectView 对象重建次数（对象只在 init 建一次，applyMaterial 只切显隐）；
    //   · 默认关闭：普通运行不再累积/排序统计。需要时 `defaults write com.sxyq.frsetnext
    //     probe.islandMaterial -bool true` 再开（与 probe.motionPacing 同族）。
    private static let statsEnabled = UserDefaults.standard.bool(forKey: "probe.islandMaterial")
    private var layoutCount = 0
    private var glassFrameUpdates = 0
    private var maskPathCount = 0
    private var frameCosts: [Double] = []      // layout 总耗时
    private var maskCosts: [Double] = []       // 遮罩路径重算
    private var lastInterpolated: CGSize = .zero

    init(material: IslandMaterial, shellOpacity: CGFloat,
         sampling: CGSize, samplingInset: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.mask = mask
        self.shellOpacity = shellOpacity
        self.sampling = sampling
        self.samplingInset = samplingInset
        // 玻璃自角从 .zero 起：外壳圆角由 IslandMorph 逐帧经 setCornerRadius 注入，
        // 形状交给 CAShapeLayer 遮罩（2026-11-23：0 字面量收编为 .zero）。
        // v286：`systemGlass` 不再写死 true——那会绕过用户偏好，让刘海永远走
        // 焦点自适应的 NSGlassEffectView（点击前后观感跳变的来源之一）。
        // 2026-11-24 v293：改成一条 `LiquidGlass.Style`——材质/焦点/着色/纯色
        // 全部交给解析器，后端对象由 GlassHost 按解析结果持有；毛玻璃分支现在
        // **真的消费 tint**（旧实现直接丢掉，导致「外壳通透度」在默认后端上无效）。
        var style = LiquidGlass.Style(role: .island)
        style.tint = Self.tint(shellOpacity)
        style.cornerRadius = .zero
        style.focus = material == .liquidGlass ? .systemDynamic : .stable
        let glass = GlassHost(frame: .zero, style: style)
        glass.appearance = NSAppearance(named: .darkAqua)
        let host = glass as NSView
        // 关掉 autoresizing：取样面比宿主大（上角移到屏幕外），宿主每帧插值时
        // AppKit 会照旧把子视图拉回 bounds —— 那正好把「只重设一次」变成「每帧一次」。
        host.autoresizingMask = []
        addSubview(host)
        glassView = host
        // 排障口径：一眼看出这一版外壳走的是真玻璃还是毛玻璃回退。
        Log.info("Island", "外壳材质：\(LiquidGlass.resolve(style).backend.rawValue) "
                 + "通透度=\(Int((1 - shellOpacity) * 100))% 降透明=\(LiquidGlass.reduceTransparency)")
        applyMaterial(material)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// 外壳深色程度 = 一层黑 tint（不再与外层黑幕叠加）
    private static func tint(_ opacity: CGFloat) -> NSColor {
        NSColor.black.withAlphaComponent(min(1, max(0, opacity)))
    }

    /// 材质切换收敛：玻璃对象建一次，纯色/降透明只切显隐 + 解析成不透明底。
    ///
    /// v293：`style.solid` 也一起写进去——旧实现只切 `isHidden`，底层对象仍是
    /// 采样玻璃；纯色窗口一旦被系统短暂重绘（如切 Space）就会透出背后的桌面。
    func applyMaterial(_ new: IslandMaterial) {
        material = new
        let needsGlass = new != .solid
        glassView?.isHidden = !needsGlass
        if let host = glassView as? GlassHost {
            var style = host.style
            style.solid = !needsGlass
            style.focus = new == .liquidGlass ? .systemDynamic : .stable
            host.apply(style)
        }
        // 纯色时留一层黑底：即使外层黑幕将来调整，形状也不会透出背后内容
        layer?.backgroundColor = needsGlass ? nil : NSColor.black.cgColor
        applyTint()
        needsLayout = true
    }

    private func applyTint() {
        guard let host = glassView as? GlassHost, !host.isHidden else { return }
        var style = host.style
        style.tint = Self.tint(shellOpacity)
        host.apply(style)
    }

    /// 唯一几何入口：插值尺寸只喂遮罩，取样面只在两档之间整块切换。
    func applyGeometry(interpolated: CGSize, radius newRadius: CGFloat,
                       sampling target: CGSize, samplingInset inset: CGFloat) {
        if Self.statsEnabled { layoutCount += 1 }
        if radius != newRadius { radius = newRadius; needsLayout = true }
        // 放大：展开一开始就按最终尺寸铺玻璃（本帧一次）；
        // 缩小：等遮罩真的收到收起态（插值 == 目标）再缩——提前缩会让收起途中透出桌面。
        let grow = target.width > sampling.width + 0.5 || target.height > sampling.height + 0.5
        let settled = abs(interpolated.width - target.width) < 0.5
            && abs(interpolated.height - target.height) < 0.5
        if sampling != target, grow || settled {
            sampling = target
            samplingInset = inset
            needsLayout = true
        }
        if measure {
            let samePlace = abs(lastInterpolated.width - interpolated.width) <= 0.5
                && abs(lastInterpolated.height - interpolated.height) <= 0.5
            if settled, !samePlace { flushStats(settledAt: interpolated) }
            lastInterpolated = interpolated
        }
    }

    private func flushStats(settledAt size: CGSize) {
        guard !frameCosts.isEmpty else { return }
        func pct(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
            return sorted[index]
        }
        let p50 = pct(frameCosts, 0.50), p95 = pct(frameCosts, 0.95)
        let maximum = frameCosts.max() ?? 0
        let maskP95 = maskCosts.isEmpty ? 0 : pct(maskCosts, 0.95)
        Log.info("Island", String(format:
            "岛材质：几何更新 %d 次 · 取样面更新 %d 次 · 遮罩重算 %d 次 · layout p50 %.3fms p95 %.3fms max %.3fms · 遮罩 p95 %.3fms · 落位 %.0f×%.0f",
            layoutCount, glassFrameUpdates, maskPathCount, p50, p95, maximum, maskP95,
            size.width, size.height))
        layoutCount = 0; glassFrameUpdates = 0; maskPathCount = 0
        frameCosts.removeAll(keepingCapacity: true)
        maskCosts.removeAll(keepingCapacity: true)
    }

    override func layout() {
        super.layout()
        guard bounds != renderedBounds || radius != renderedRadius || sampling != renderedSampling else { return }
        let started = Self.statsEnabled ? CFAbsoluteTimeGetCurrent() : 0
        renderedBounds = bounds
        renderedRadius = radius
        renderedSampling = sampling
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 将玻璃上角移至屏幕外：可见上沿贴顶，下角保持原生折射曲率。
        // 纯色时玻璃隐藏，不参与布局绘制（不采样、不模糊）。
        // 取样面用 sampling（两档之一），与逐帧插值的 bounds 解耦。
        if let glass = glassView, !glass.isHidden {
            let target = CGRect(x: 0, y: -samplingInset,
                                width: sampling.width, height: sampling.height + samplingInset)
            if glass.frame != target {
                glass.frame = target
                if Self.statsEnabled { glassFrameUpdates += 1 }
            }
            if samplingInset != renderedSamplingInset {
                renderedSamplingInset = samplingInset
                LiquidGlass.setCornerRadius(samplingInset, on: glass)
            }
        }
        let maskStart = Self.statsEnabled ? CFAbsoluteTimeGetCurrent() : 0
        mask.frame = bounds
        mask.path = IslandOutline(radius: radius).path(in: bounds).cgPath
        CATransaction.commit()
        if Self.statsEnabled {
            maskPathCount += 1
            maskCosts.append((CFAbsoluteTimeGetCurrent() - maskStart) * 1000)
            frameCosts.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
            if frameCosts.count > 300 { frameCosts.removeFirst(150); maskCosts.removeFirst(min(150, maskCosts.count)) }
        }
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
        let placement = controller.activeDisplayID.flatMap { controller.configuration.peekPlacements[$0] } ?? .both
        let leftItems = placement == .left ? items : placement == .both ? Array(items.prefix((items.count + 1) / 2)) : []
        let rightItems = placement == .right ? items : placement == .both ? Array(items.dropFirst((items.count + 1) / 2)) : []
        let unitWidth: CGFloat = controller.peeksShowValues ? 72 : 38
        let leftWidth = CGFloat(leftItems.count) * unitWidth
        let rightWidth = CGFloat(rightItems.count) * unitWidth
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(leftItems) { peek in button(peek) }
            }.frame(width: leftWidth, alignment: .trailing)
            Button { controller.expand(takeFocus: true) } label: {
                Color.clear.frame(width: controller.notchWidth, height: controller.notchHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("展开刘海")
            HStack(spacing: 0) {
                ForEach(rightItems) { peek in button(peek) }
            }.frame(width: rightWidth, alignment: .leading)
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


