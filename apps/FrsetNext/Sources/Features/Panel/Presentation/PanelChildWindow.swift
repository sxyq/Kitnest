import AppKit
import SwiftUI

/// 给驻留面板（`FloatingPanel`）里弹出的子窗口打一个可识别的身份。
///
/// 为什么需要它：主面板是 `.nonactivatingPanel` 且自己实现了 transient 语义——
/// `PanelController.windowDidResignKey` 把「除 sheet / 带白名单 identifier 的子窗」之外
/// 的任何取 key 行为都判定成「用户点了面板外面」，于是收起面板。
///
/// SwiftUI 的 `.popover` 起的窗口没有 identifier，一弹出就被判成外部 → 面板收起 →
/// popover 作为附属窗口一起消失。用户看到的就是「点一下闪出来就没了」。
///
/// 这里在内容宿主视图入窗时把 identifier 打到它所在的 NSWindow 上，
/// `PanelController` 侧按前缀放行，popover 就能和面板共存。
private struct PanelChildWindowTag: NSViewRepresentable {

    final class TagView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // popover 的窗口可能在内容重建时更换，所以每次入窗都重新打标
            window?.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        }
        static let identifier = "frset.panelChild"
    }

    func makeNSView(context: Context) -> NSView { TagView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.identifier = NSUserInterfaceItemIdentifier(TagView.identifier)
    }
}

extension View {
    /// 标记「我是主面板弹出的子窗口」，让 `PanelController` 不要因此收起面板。
    func panelChildWindow() -> some View {
        background {
            PanelChildWindowTag()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

public enum PanelChildWindow {
    /// 与 `PanelChildWindowTag.TagView.identifier` 保持一致
    public static let identifier = "frset.panelChild"
    public static func isPanelChild(_ window: NSWindow?) -> Bool {
        window?.identifier?.rawValue.hasPrefix(identifier) == true
    }
}
