import AppKit
import Foundation

// MARK: - 统一的悬停气泡（对齐标注竖栏 v221 的「冒泡」）
//
// 标注竖栏的气泡是：标题 11.5 + 等宽快捷键徽章 9.5 + 一句用法 10，
// 圆角 6 的玻璃面，插入时 scale 0.84 → 1 并淡入。
// 钉图的工具条是 AppKit（本 target 的 SwiftUIMacros 缺失，@State 编不过），
// 这里用 NSView 复刻同一套排版与动效，保证两处观感一致。

struct PinBubbleModel {
    let title: String
    let shortcut: String
    let usage: String
}

final class PinBubbleView: NSView {

    private let model: PinBubbleModel

    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let badgeFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
    static let usageFont = NSFont.systemFont(ofSize: 10)

    private static let hPad: CGFloat = 9
    private static let vPad: CGFloat = 6
    private static let badgeH: CGFloat = 14
    private static let gap: CGFloat = 6

    init(model: PinBubbleModel) {
        self.model = model
        let size = Self.measure(model)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.20
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private var badgeText: String { model.shortcut }

    private func badgeWidth() -> CGFloat {
        let w = (badgeText as NSString).size(withAttributes: [.font: Self.badgeFont]).width
        return max(16, ceil(w) + 9)
    }

    static func measure(_ m: PinBubbleModel) -> NSSize {
        let titleW = (m.title as NSString).size(withAttributes: [.font: titleFont]).width
        let badgeW = max(16, ceil((m.shortcut as NSString).size(withAttributes: [.font: badgeFont]).width) + 9)
        let usageW = (m.usage as NSString).size(withAttributes: [.font: usageFont]).width
        let width = max(titleW + gap + badgeW, usageW) + hPad * 2
        let height = vPad * 2 + 15 + 2 + 12
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25),
                                xRadius: 6, yRadius: 6)
        NSColor(white: 1, alpha: 0.96).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.12).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // 第二行：用法
        (model.usage as NSString).draw(
            at: NSPoint(x: Self.hPad, y: Self.vPad),
            withAttributes: [.font: Self.usageFont,
                             .foregroundColor: NSColor(white: 0.38, alpha: 1)])

        // 第一行：标题 + 快捷键徽章
        let titleY = bounds.height - Self.vPad - 14
        (model.title as NSString).draw(
            at: NSPoint(x: Self.hPad, y: titleY),
            withAttributes: [.font: Self.titleFont,
                             .foregroundColor: NSColor(white: 0.11, alpha: 1)])

        let titleW = (model.title as NSString).size(withAttributes: [.font: Self.titleFont]).width
        let bw = badgeWidth()
        let badge = NSRect(x: Self.hPad + titleW + Self.gap,
                           y: titleY - 1.5,
                           width: bw, height: Self.badgeH)
        NSColor(white: 0.35, alpha: 0.10).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        let tw = (badgeText as NSString).size(withAttributes: [.font: Self.badgeFont]).width
        (badgeText as NSString).draw(
            at: NSPoint(x: badge.midX - tw / 2, y: badge.midY - 6),
            withAttributes: [.font: Self.badgeFont,
                             .foregroundColor: NSColor(white: 0.35, alpha: 1)])
    }
}

/// 气泡面板：独立小窗，避免被钉图窗边界裁掉（工具条贴在图片底边）
final class PinBubblePanel: NSPanel {

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    private var isShowing = false

    /// 在屏幕坐标 rect 的正上方弹出（rect 用底左原点）
    func show(_ model: PinBubbleModel, above anchor: NSRect) {
        let size = PinBubbleView.measure(model)
        let view = PinBubbleView(model: model)
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        contentView = view

        var origin = NSPoint(x: anchor.midX - size.width / 2,
                             y: anchor.maxY + 7)
        if let screen = (NSScreen.main ?? NSScreen.screens.first) {
            let v = screen.visibleFrame
            origin.x = min(max(v.minX + 6, origin.x), v.maxX - size.width - 6)
            if origin.y + size.height > v.maxY - 4 { origin.y = anchor.minY - size.height - 7 }
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        ignoresMouseEvents = true

        if isShowing {
            alphaValue = 1
            return
        }
        isShowing = true
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        // 冒泡：从 84% 弹到 100%（中心锚点，不动布局，避免改 anchorPoint 把视图挪位）
        if let layer = view.layer {
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.84
            pop.toValue = 1.0
            pop.duration = 0.18
            pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.25, 0.4, 1.0)
            layer.add(pop, forKey: "pin.bubble.pop")
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShowing else { return }
            self.orderOut(nil)
        })
    }
}

// MARK: - 统一的弹出列表（替代 NSMenu）
//
// 用户：「上下展现出来那个列表，也是需要这种统一的，这种按钮，不要这种单独的其他的实现」。
// 所以「更多」不再用系统 NSMenu，而是自绘面板：行高 30、图标 + 标题 + 右侧值、
// 悬停底色与工具条按钮同一套（8pt 圆角、primary 8%），子菜单就地推入/返回。

enum PinMenuEntry {
    case action(id: String, title: String, symbol: String, detail: String?)
    case toggle(id: String, title: String, symbol: String, on: Bool)
    /// 单选（缩放档位 / 描边宽度这类），选中项右侧打勾
    case choice(id: String, title: String, symbol: String, selected: Bool)
    case submenu(id: String, title: String, symbol: String, detail: String?, children: [PinMenuEntry])
}

final class PinMenuView: NSView {

    static let width: CGFloat = 236
    static let rowHeight: CGFloat = 30
    static let pad: CGFloat = 6

    private var rows: [(entry: PinMenuEntry?, title: String, symbol: String, detail: String?, isBack: Bool)] = []
    private var hovered = -1
    private var tracking: NSTrackingArea?

    var onPick: ((String) -> Void)?
    var onPush: ((String, String, [PinMenuEntry]) -> Void)?
    var onBack: (() -> Void)?

    static let titleFont = NSFont.systemFont(ofSize: 12)
    static let detailFont = NSFont.systemFont(ofSize: 11)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.98).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0, alpha: 0.12).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    func setEntries(_ entries: [PinMenuEntry], parentTitle: String?) {
        var built: [(entry: PinMenuEntry?, title: String, symbol: String, detail: String?, isBack: Bool)] = []
        if let parentTitle {
            built.append((nil, "返回 \(parentTitle)", "chevron.left", nil, true))
        }
        for e in entries {
            switch e {
            case .action(let id, let title, let symbol, let detail):
                built.append((e, title, symbol, detail, false))
                _ = id
            case .toggle(_, let title, let symbol, _):
                // 开关只用右侧勾表达，不再叠「开/关」两个字
                built.append((e, title, symbol, nil, false))
            case .choice(_, let title, let symbol, _):
                built.append((e, title, symbol, nil, false))
            case .submenu(_, let title, let symbol, let detail, _):
                built.append((e, title, symbol, detail, false))
            }
        }
        rows = built
        needsDisplay = true
    }

    static func height(for rowCount: Int) -> CGFloat {
        pad * 2 + CGFloat(rowCount) * rowHeight
    }

    /// 当前行数（含「返回 X」那一行）
    var rowCount: Int { rows.count }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func rowIndex(at point: NSPoint) -> Int {
        let localY = bounds.height - point.y - Self.pad
        guard localY >= 0 else { return -1 }
        let idx = Int(localY / Self.rowHeight)
        return (idx >= 0 && idx < rows.count) ? idx : -1
    }

    override func mouseMoved(with event: NSEvent) {
        let idx = rowIndex(at: convert(event.locationInWindow, from: nil))
        if idx != hovered { hovered = idx; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != -1 { hovered = -1; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let idx = rowIndex(at: convert(event.locationInWindow, from: nil))
        guard idx >= 0, idx < rows.count else { return }
        let row = rows[idx]
        if row.isBack { onBack?(); return }
        guard let entry = row.entry else { return }
        switch entry {
        case .action(let id, _, _, _):
            onPick?(id)
        case .toggle(let id, _, _, _):
            onPick?(id)
        case .choice(let id, _, _, _):
            onPick?(id)
        case .submenu(let id, let title, _, _, let children):
            onPush?(id, title, children)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()

        for (index, row) in rows.enumerated() {
            let y = bounds.height - Self.pad - CGFloat(index + 1) * Self.rowHeight
            let rect = NSRect(x: Self.pad, y: y, width: bounds.width - Self.pad * 2, height: Self.rowHeight)
            if index == hovered {
                NSColor(white: 0.25, alpha: 0.10).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
            }
            // 分隔线（返回行之后）
            if row.isBack {
                NSColor(white: 0, alpha: 0.08).setFill()
                NSRect(x: 10, y: y + 1, width: bounds.width - 20, height: 0.5).fill()
            }

            let symbolColor = row.isBack ? NSColor(white: 0.42, alpha: 1) : NSColor(white: 0.22, alpha: 1)
            if !row.symbol.isEmpty,
               let image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular)) {
                let tinted = image.tinted(with: symbolColor)
                tinted.draw(in: NSRect(x: 12, y: rect.midY - 7, width: 14, height: 14))
            }

            // 右侧要放什么：箭头（子菜单）> 勾（选中/开关）> 纯数值
            var isSubmenu = false
            if case .submenu = row.entry { isSubmenu = true }
            var checked = false
            if case .toggle(_, _, _, let on) = row.entry, on { checked = true }
            if case .choice(_, _, _, let selected) = row.entry, selected { checked = true }
            let trailing: CGFloat = (isSubmenu || checked) ? 26 : 14

            let textX: CGFloat = 34
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: Self.titleFont,
                .foregroundColor: row.isBack ? NSColor(white: 0.42, alpha: 1) : NSColor(white: 0.12, alpha: 1)
            ]
            let maxW = bounds.width - textX - (row.detail == nil ? trailing : trailing + 48)
            (row.title as NSString).draw(in: NSRect(x: textX, y: rect.midY - 8, width: maxW, height: 17),
                                         withAttributes: titleAttrs)

            if let detail = row.detail, !detail.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Self.detailFont,
                    .foregroundColor: NSColor(white: 0.45, alpha: 1)
                ]
                let w = (detail as NSString).size(withAttributes: attrs).width
                (detail as NSString).draw(at: NSPoint(x: bounds.width - trailing - w, y: rect.midY - 7),
                                          withAttributes: attrs)
            }

            // 子菜单箭头
            if isSubmenu {
                NSColor(white: 0.5, alpha: 1).setStroke()
                let c = NSPoint(x: bounds.width - 15, y: rect.midY)
                let chevron = NSBezierPath()
                chevron.move(to: NSPoint(x: c.x - 2, y: c.y + 4))
                chevron.line(to: NSPoint(x: c.x + 2, y: c.y))
                chevron.line(to: NSPoint(x: c.x - 2, y: c.y - 4))
                chevron.lineWidth = 1.4
                chevron.lineCapStyle = .round
                chevron.stroke()
            }
            if checked {
                NSColor.controlAccentColor.setStroke()
                let check = NSBezierPath()
                let cx = bounds.width - 16
                check.move(to: NSPoint(x: cx - 5, y: rect.midY))
                check.line(to: NSPoint(x: cx - 1, y: rect.midY - 4))
                check.line(to: NSPoint(x: cx + 5, y: rect.midY + 5))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            }
        }
    }
}

extension NSImage {
    /// 用模板图 + tint 着色（NSImage 没有直接 tint 接口）
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// 菜单面板：堆栈式（子菜单推入，顶部有「返回 X」）
final class PinMenuPanel: NSPanel {

    private let listView = PinMenuView(frame: NSRect(x: 0, y: 0, width: PinMenuView.width, height: 40))
    private var stack: [(title: String, entries: [PinMenuEntry])] = []

    var onPick: ((String) -> Void)?
    /// 关闭后把键盘焦点还给钉图窗，否则 Esc/A/C 这些快捷键就失灵了
    weak var ownerWindow: NSWindow?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: PinMenuView.width, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        listView.onPick = { [weak self] id in
            self?.onPick?(id)
            self?.dismiss()
        }
        listView.onPush = { [weak self] _, title, children in
            guard let self else { return }
            self.stack.append((title, children))
            self.reload(push: true)
        }
        listView.onBack = { [weak self] in
            guard let self, self.stack.count > 1 else { return }
            self.stack.removeLast()
            self.reload(push: false)
        }
        contentView = listView
    }

    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        dismiss()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// 在屏幕坐标 rect 上方弹出（放不下就翻到下方）
    func present(entries: [PinMenuEntry], above anchor: NSRect) {
        stack = [("更多", entries)]
        reload(push: false)
        layoutPanel(anchor: anchor)
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        if let layer = listView.layer {
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.94
            pop.toValue = 1.0
            pop.duration = 0.16
            pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.4, 1.0)
            layer.add(pop, forKey: "pin.menu.pop")
        }
    }

    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.ownerWindow?.makeKey()
        })
    }

    private func reload(push: Bool) {
        guard let current = stack.last else { return }
        let parent = stack.count > 1 ? stack[stack.count - 2].title : nil
        listView.setEntries(current.entries, parentTitle: parent)
        let h = PinMenuView.height(for: listView.rowCount)
        let frame = NSRect(origin: frame.origin, size: NSSize(width: PinMenuView.width, height: h))
        setFrame(frame, display: true)
        listView.frame = NSRect(origin: .zero, size: frame.size)
        if push {
            // 轻微从右滑入，表示「进入了下一层」
            if let layer = listView.layer {
                let slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.fromValue = 18
                slide.toValue = 0
                slide.duration = 0.14
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(slide, forKey: "pin.menu.push")
            }
        }
    }

    private func layoutPanel(anchor: NSRect) {
        let size = frame.size
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8)
        if let screen = (NSScreen.main ?? NSScreen.screens.first) {
            let v = screen.visibleFrame
            origin.x = min(max(v.minX + 8, origin.x), v.maxX - size.width - 8)
            if origin.y + size.height > v.maxY - 6 { origin.y = anchor.minY - size.height - 8 }
            if origin.y < v.minY + 6 { origin.y = v.minY + 6 }
        }
        setFrameOrigin(origin)
    }
}

private extension PinMenuView {
}
