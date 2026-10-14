import AppKit
import SwiftUI

/// 面板可见性状态（供 SwiftUI 根视图做缩放淡入动画）
public final class PanelPresentationState: ObservableObject {
    @Published public var visible = false
    public init() {}
}

/// 主面板控制器（原作由 StatusBarController 协作开合面板，此处统一收敛为单例）。
/// 实现 Core/Registry.swift 的 PanelControlling 协议，经 ServiceLocator.panel 供状态栏/热键模块调用。
public class PanelController: NSObject, PanelControlling, NSWindowDelegate {
    public static let shared = PanelController()

    private var panel: FloatingPanel?
    private let presentation = PanelPresentationState()

    private override init() {
        super.init()
    }

    // MARK: - 生命周期

    /// 创建面板与内容（幂等）。由 PanelModule.start() 调用，并注入 ServiceLocator.panel。
    public func prepare() {
        guard panel == nil else { return }
        // 记住上次尺寸（Preferences.Keys.panelWidth/panelHeight，默认 400×700）
        let width = CGFloat(Preferences.shared.value(Preferences.Keys.panelWidth,
                                                      default: Double(Theme.panelWidth)))
        let height = CGFloat(Preferences.shared.value(Preferences.Keys.panelHeight,
                                                       default: Double(Theme.panelMaxHeight)))

        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              rootView: PanelRootView(
                                presentation: presentation,
                                searchHook: PanelSearchHook.shared,
                                onDismiss: { [weak self] in self?.hide() },
                                onOpenSettings: { [weak self] in
                                    // 设置窗口由 07 号模块经 ServiceLocator 注入，此处不引用其具体类型
                                    ServiceLocator.settings?.open(pane: nil)
                                    self?.hide()
                                }))
        p.delegate = self
        panel = p
        ServiceLocator.panel = self
        Log.info("Panel", "prepared \(Int(width))x\(Int(height))")
    }

    // MARK: - PanelControlling

    public func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    public func show() {
        prepare()
        guard let p = panel else { return }
        p.setFrameOrigin(rightEdgeOrigin(for: p.frame.size))
        presentation.visible = true                // 触发 SwiftUI 缩放淡入
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    public func hide() {
        guard let p = panel, p.isVisible else { return }
        persistSize(p)
        presentation.visible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in
            p?.orderOut(nil)
            p?.alphaValue = 1
        })
    }

    /// 全局唤起预留接口：具体热键注册由 ShortcutManager/状态栏模块接线，
    /// 热键触发后调用 ServiceLocator.panel?.toggle() 或本方法即可。
    open func handleGlobalShortcut() {
        toggle()
    }

    // MARK: - 私有

    /// 屏幕右上角、菜单栏图标下方（与实机截图一致：面板停靠屏幕右侧）
    private func rightEdgeOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 80, y: 80) }
        let vf = screen.visibleFrame
        return NSPoint(x: vf.maxX - size.width - 10,
                       y: vf.maxY - size.height - 2)
    }

    private func persistSize(_ p: NSWindow) {
        Preferences.shared.set(Preferences.Keys.panelWidth, Double(p.frame.width))
        Preferences.shared.set(Preferences.Keys.panelHeight, Double(p.frame.height))
    }

    // MARK: - NSWindowDelegate（点外/失焦自动关闭 + 尺寸持久化）

    public func windowDidResignKey(_ notification: Notification) {
        guard let p = panel, (notification.object as? NSWindow) === p else { return }
        // 原作 .transient 行为：点击面板外任意处即关闭
        hide()
    }

    public func windowDidResize(_ notification: Notification) {
        guard let p = panel, (notification.object as? NSWindow) === p, p.isVisible else { return }
        persistSize(p)
    }

    public func windowWillClose(_ notification: Notification) {
        presentation.visible = false
    }
}
