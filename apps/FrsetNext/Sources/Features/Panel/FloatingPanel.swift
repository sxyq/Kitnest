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

        // 玻璃底层：macOS 26+ 用 Liquid Glass（NSGlassEffectView），旧系统回退毛玻璃。
        // 圆角由玻璃层裁切；SwiftUI 内容铺满其上（内容自身不再铺底色）。
        // tint 抬高对比：纯 regular 玻璃透得太狠，面板上的 10-11pt 小字会发飘；
        // 用窗口底色 55% 做底衬（Apple 自家玻璃面板同做法），既保留透光又不牺牲可读性。
        let glass = LiquidGlass.makeView(frame: NSRect(origin: .zero, size: contentRect.size),
                                         cornerRadius: 14,
                                         material: .hudWindow,
                                         tint: NSColor.windowBackgroundColor.withAlphaComponent(0.55))

        // SwiftUI 根视图铺满玻璃层
        let hosting = NSHostingView(rootView: rootView)
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
