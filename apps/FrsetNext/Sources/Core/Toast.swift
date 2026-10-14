import AppKit
import Foundation
import SwiftUI

// MARK: - 全局轻提示（Core 层：任何模块都可调用 Toast.show，无需引用 StatusBar 模块）

// MARK: - Toast 内容视图（毛玻璃上的标题 + 可选 SF Symbol 图标）

/// Toast 的 SwiftUI 内容（internal：仅本文件装配使用）
struct ToastContentView: View {
    let message: String
    let icon: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Toast 窗口控制器

/// ToastWindowController：右上角浮出的轻提示（毛玻璃圆角、2s 自动淡出）
/// 复用同一个面板：连续调用时更新文案并重置计时器
public final class ToastWindowController: NSObject {

    public static let shared = ToastWindowController()

    /// 默认停留时长（秒）
    private static let defaultDuration: TimeInterval = 2.0

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var hosting: NSHostingController<ToastContentView>?
    private var dismissTimer: Timer?

    private override init() { super.init() }

    /// 显示一条提示（线程安全：自动切主线程）
    public func show(_ message: String, icon: String? = nil) {
        if Thread.isMainThread {
            present(message: message, icon: icon)
        } else {
            DispatchQueue.main.async { self.present(message: message, icon: icon) }
        }
    }

    private func present(message: String, icon: String?) {
        guard !message.isEmpty else { return }
        let p = ensurePanel()
        guard let effect = effectView else { return }
        let content = ToastContentView(message: message, icon: icon)

        if let hosting {
            hosting.rootView = content
        } else {
            let h = NSHostingController(rootView: content)
            h.view.wantsLayer = true
            h.view.layer?.backgroundColor = NSColor.clear.cgColor
            h.view.autoresizingMask = [.width, .height]
            effect.addSubview(h.view)
            hosting = h
        }
        guard let view = hosting?.view else { return }

        // 按内容自适应尺寸后重新定位（右上角，菜单栏下方）
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        p.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        position(panel: p, size: size)

        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true            // 不拦截点击
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovable = false

        // 毛玻璃底 + 圆角
        let effect = NSVisualEffectView(frame: p.contentView?.bounds ?? .zero)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.cornerRadius + 2
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        p.contentView = effect
        effectView = effect

        panel = p
        return p
    }

    /// 右上角定位（避开菜单栏与屏幕圆角）
    private func position(panel p: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - 16
        let y = visible.maxY - size.height - 12
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleDismiss() {
        dismissTimer?.invalidate()
        let t = Timer(timeInterval: Self.defaultDuration, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(t, forMode: .common)
        dismissTimer = t
    }

    /// 淡出并收起（面板保留复用）
    public func dismiss() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.dismiss() }; return }
        dismissTimer?.invalidate(); dismissTimer = nil
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }
}

// MARK: - 静态入口（供其他模块提示；由总控决定是否迁移到 Core）

/// Toast：全局轻提示入口（Core 层，所有模块直接调用，无需 import 任何 Features 模块）
/// 用法：`Toast.show("已复制", icon: "doc.on.doc")`
public enum Toast {
    public static func show(_ message: String, icon: String? = nil) {
        ToastWindowController.shared.show(message, icon: icon)
    }
}
