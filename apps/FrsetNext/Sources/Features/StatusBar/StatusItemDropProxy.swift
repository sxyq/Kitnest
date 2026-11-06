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

    /// 不拦点击：拖放靠 registerForDraggedTypes 派发，不依赖 hitTest
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
