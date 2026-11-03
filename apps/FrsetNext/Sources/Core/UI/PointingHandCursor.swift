import SwiftUI
import AppKit

// MARK: - 悬停手型光标（v114 引入；v132 重写为 AppKit 光标区实现）
//
// 原版逆向实锤：日历卡可点热区（日期格、"打开日历"按钮等）悬停时把箭头光标
// 换成手型（pointingHandCursor），提示"这里能点"——对应原版
// PointingHandCursorRegion / CursorRegionView。
//
// v114 版用 SwiftUI onHover + NSCursor.push/pop——实测在主面板（non-activating
// 瞬态 NSPanel）里不生效，且 push/pop 栈在 hover 事件乱序时失衡（退出面板时
// 光标卡死）。v132 改 AppKit 规范机制：
//   · resetCursorRects 声明光标区（窗口 key 时的系统级光标管理）
//   · cursorUpdate + .activeAlways tracking（面板非 key 时也生效）
//   · mouseEntered/Exited 兜底 set/arrow（无栈操作，set 是替换不是压栈）
//   · hitTest 恒 nil——不参与命中测试，绝不挡点击/手势

public struct PointingHandCursor: ViewModifier {

    public init() {}

    public func body(content: Content) -> some View {
        content.background(PointingHandCursorRegionBackground())
    }
}

private struct PointingHandCursorRegionBackground: NSViewRepresentable {

    func makeNSView(context: Context) -> CursorRegionNSView {
        let view = CursorRegionNSView()
        // 背景视图不吞事件；约束随宿主布局走
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: CursorRegionNSView, context: Context) {}
}

/// 对应原版 CursorRegionView：只声明光标，不参与命中
final class CursorRegionNSView: NSView {

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

public extension View {
    /// 悬停变手型光标（可点击热区的可发现性提示；对应原版 PointingHandCursorRegion）
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}
