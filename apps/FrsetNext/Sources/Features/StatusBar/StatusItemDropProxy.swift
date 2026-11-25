import AppKit

// MARK: - 菜单栏图标的投放区
//
// 为什么用一层覆盖视图：NSStatusBarButton 本身不是 NSDraggingDestination，
// 也不能子类化（系统创建）。所以在按钮上加一层透明的 NSView，专收文件拖放，
// hitTest 返回 nil 保证点击仍然落到按钮上（开合面板不受影响）。

final class StatusItemDropProxy: NSView {

    /// 拖进来时给图标加一层强调色底，让用户知道「松手能放」
    private var active = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 2026-11-26 修复：原实现恒返回 nil，而 AppKit 选取拖放目的地的方式是「先 hitTest
    /// 找到最深的视图，再沿 superview 链找注册过该类型的视图」——命中未注册拖放的
    /// NSStatusBarButton 后就断链，draggingEntered / performDragOperation 永远收不到，
    /// 拖文件到图标会静默失效。现在命中自身以承接拖放，并把鼠标事件转发给底层按钮，
    /// 点击开合面板 / 右键菜单不受影响。
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { forwardMouse(event) }
    override func rightMouseDown(with event: NSEvent) { forwardMouse(event) }
    override func mouseUp(with event: NSEvent) { forwardMouse(event) }
    override func rightMouseUp(with event: NSEvent) { forwardMouse(event) }

    /// 把点击转交给底下的状态栏按钮（NSButton 的 mouseDown 会自行进入跟踪循环并在抬起时派发 action）
    private func forwardMouse(_ event: NSEvent) {
        guard let button = superview else { return }
        switch event.type {
        case .leftMouseDown:  button.mouseDown(with: event)
        case .leftMouseUp:    button.mouseUp(with: event)
        case .rightMouseDown: button.rightMouseDown(with: event)
        case .rightMouseUp:   button.rightMouseUp(with: event)
        default: break
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        setActive(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setActive(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setActive(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setActive(false)
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        // 先开面板，再发通知：转入弹框挂在面板内容树上，没开就没人接
        ServiceLocator.panel?.show()
        NotificationCenter.default.post(name: .frsetTransferIntake,
                                        object: nil,
                                        userInfo: ["urls": urls])
        return true
    }

    private func hasFiles(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }

    private func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
    }
}
