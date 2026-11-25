// 本文件由 IslandContent.swift 拆出（2026-11-23 文档体系整理，纯类型搬家，无行为变化）。
import AppKit
import EventKit
import SwiftUI
import UniformTypeIdentifiers

/// 记录单击、双击与文件拖出共用原生事件；拖动会话不触碰系统剪贴板。
struct IslandFileDragSource: NSViewRepresentable {
    let urls: [URL]
    let controller: IslandController
    var onDraggingChanged: (Bool) -> Void
    var onMove: ((Int) -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    var defersSelection = false
    var tracksScroll = false
    var select: () -> Void

    func makeNSView(context: Context) -> IslandFileDragView {
        let view = IslandFileDragView()
        view.focusRingType = .none
        return view
    }
    func updateNSView(_ view: IslandFileDragView, context: Context) {
        view.urls = urls; view.controller = controller; view.select = select
        view.onDraggingChanged = onDraggingChanged
        view.onMove = onMove; view.onCopy = onCopy
        view.onDoubleClick = onDoubleClick; view.defersSelection = defersSelection
        view.tracksScroll = tracksScroll
        if controller.editingLayout { view.cancelSelection() }
    }
}

final class IslandFileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    weak var controller: IslandController?
    var select: (() -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?
    var onMove: ((Int) -> Void)?
    var onCopy: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var defersSelection = false
    var tracksScroll = false
    private var selectionWork: DispatchWorkItem?
    private var mouseStart: NSPoint? = nil
    private var dragging = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if tracksScroll, window != nil {
            DispatchQueue.main.async { [weak self] in
                if let self, let scrollView = self.enclosingScrollView { self.controller?.bindRecordScroll(scrollView) }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        controller?.editingLayout == true ? nil : super.hitTest(point)
    }

    func cancelSelection() {
        selectionWork?.cancel(); selectionWork = nil
        mouseStart = nil
    }

    override func mouseDown(with event: NSEvent) {
        selectionWork?.cancel(); selectionWork = nil
        mouseStart = event.locationInWindow
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.editingLayout == true { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let onCopy {
            onCopy(); return
        }
        if (event.keyCode == 125 || event.keyCode == 126), let onMove {
            onMove(event.keyCode == 125 ? 1 : -1); return
        }
        if event.keyCode == 36 || event.keyCode == 49 { select?(); return }
        super.keyDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty, !dragging, let start = mouseStart,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3 else { return }
        for url in urls where !FileManager.default.isReadableFile(atPath: url.path) {
            controller?.feedback = "无法拖出文件：" + url.path
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        dragging = true
        onDraggingChanged?(true)
        controller?.beginInteraction()
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging, mouseStart != nil {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
            } else if defersSelection {
                // 首页单击会换页；等待系统双击间隔，避免第一击提前移走目标。
                let work = DispatchWorkItem { [weak self] in self?.select?() }
                selectionWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            } else { select?() }
        }
        mouseStart = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { selectionWork?.cancel(); selectionWork = nil }
        super.viewWillMove(toWindow: newWindow)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false; mouseStart = nil
        controller?.endInteraction()
        onDraggingChanged?(false)
        controller?.feedback = operation.isEmpty ? "拖出已取消" : "拖出已结束"
    }
}
