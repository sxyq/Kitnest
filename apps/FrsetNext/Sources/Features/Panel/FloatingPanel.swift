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
        let glass = NSVisualEffectView()
        glass.material = .hudWindow   // v110：页面底减淡（L1 最淡衬底）
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = radius
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        LiquidGlass.embed(hosting, in: glass)
        contentView = glass
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
    /// 「个性化 → 背景材质」即时切换（v74：统一为 popover 原生玻璃，
    /// 与性能监测面板/状态栏 popover 同一视觉语言；仅圆角随设置变化）
    public func applyPersonalizedMaterial() {
        let radius = Personalization.shared.cornerRadius
        if #available(macOS 26.0, *), let glass = contentView as? NSGlassEffectView {
            // v110（三级玻璃 L1）：0.55 → 0.32——页面底减淡（用户「玻璃有点深了」）
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.32)
            glass.cornerRadius = radius
        } else if let effect = contentView as? NSVisualEffectView {
            // v110：popover（偏深）→ hudWindow（更轻的系统玻璃）
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.layer?.cornerRadius = radius
            effect.layer?.cornerCurve = .continuous   // v156: G2（曲率连续）圆角
        } else if let bg = contentView {
            bg.layer?.cornerRadius = radius
            bg.layer?.cornerCurve = .continuous   // v156: G2（曲率连续）圆角
        }
    }
}
