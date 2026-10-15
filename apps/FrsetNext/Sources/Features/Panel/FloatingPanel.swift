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

        // 毛玻璃底层（hudWindow 材质，behindWindow 混合），圆角由该层裁切
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentRect.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        if effect.layer == nil { effect.layer = CALayer() }
        effect.layer?.cornerRadius = Theme.cornerRadius
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        // SwiftUI 根视图铺满毛玻璃层
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    /// 允许成为 key（顶部搜索框需要键盘输入）；
    /// .nonactivatingPanel 保证弹出/点击时不把焦点从当前应用抢走（即"不成为 key 的体感"）。
    public override var canBecomeKey: Bool { true }

    /// 对齐原作 init(coder:) 陷阱（0x10023c3e8）：禁止从 nib 反序列化创建
    public required init?(coder: NSCoder) {
        fatalError("FloatingPanel 不支持 NSCoder 初始化，请使用 init(contentRect:rootView:)")
    }
}
