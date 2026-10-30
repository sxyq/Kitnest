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

        // v74（用户需求）：**玻璃态统一**——主面板与「性能监测」面板/状态栏部件
        // 展开的 NSPopover 用同一材质 `NSVisualEffectMaterial.popover`（系统 popover
        // 的原生玻璃）。此前 solid = windowBackground 纯色（与监测面板观感割裂），
        // 用户明确要求参考性能图标展开面板。
        let radius = Personalization.shared.cornerRadius
        let hosting = NSHostingView(rootView: rootView)
        // v73（2026-10-19 用户反馈「比例非常怪/按钮全挤一起」的深层根因）：
        // NSHostingView 默认 sizingOptions 会把 SwiftUI 内容 fitting size 折成
        // 窗口尺寸请求。PanelRootView 根部有 .scaleEffect(fontScale=0.9)，内容
        // fitting 缩到 0.9 后 hosting 反向把窗口压成 360×0.9=324pt，与
        // PanelController 设定的 400×0.9=360 打架——每轮布局反复拉锯，最终
        // 停在窄值并被 persistSize 记住。与设置窗 800×1554 死循环崩溃同族。
        // 纪律：宿主窗口决定尺寸，内容只负责填充（sizingOptions=[] + safeArea=[]）。
        hosting.sizingOptions = []
        if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
        // v166.5（用户：「黑色背景下的主页高斯模糊效果不好」）：
        // 这里原本是直接 `NSVisualEffectView()` + `.hudWindow` + `.behindWindow`，
        // 绕过了 LiquidGlass 工厂 —— 也就是说 macOS 26+ 上主面板**根本没吃到**
        // Liquid Glass，用的还是老式背窗模糊；黑色/深色背景上会被糊成一块均匀灰雾，
        // 既没有玻璃的折射层次，也没有和背景分离的边缘。
        // 改走 makeView：26+ 得到真 NSGlassEffectView，旧系统仍是原观感（无损回退）。
        let glass = LiquidGlass.makeView(
            cornerRadius: radius,
            material: .hudWindow,
            // 着色随外观走：浅色外观一点点乳白保证可读；深色外观几乎不加色。
            // 深色壁纸 + 白 tint 会变成一块脏灰，这正是「黑色背景下糊得不好看」的来源。
            tint: FloatingPanel.glassTint)
        glass.autoresizingMask = [.width, .height]
        LiquidGlass.embed(hosting, in: glass)
        contentView = glass
        Log.info("Panel", "玻璃容器: \(type(of: glass)) material=\(Personalization.shared.material.rawValue) reduceTransparency=\(LiquidGlass.reduceTransparency)")
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

    /// 面板玻璃的着色：浅色外观给淡乳白保证可读，深色外观几乎不加色
    /// （深色壁纸 + 白色 tint 会变成一块脏灰，这正是「黑色背景下模糊不好看」的观感来源）
    static let glassTint = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor.black.withAlphaComponent(0.10)
            : NSColor.white.withAlphaComponent(0.18)
    }

    /// 「个性化 → 背景材质」即时切换（v166.5：统一走 LiquidGlass，保留 solid 语义）
    public func applyPersonalizedMaterial() {
        guard let content = contentView else { return }
        LiquidGlass.reapplyStyle(on: content,
                                 cornerRadius: Personalization.shared.cornerRadius,
                                 tint: Self.glassTint)
    }
}
