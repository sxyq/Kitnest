import AppKit
import CoreGraphics
import Foundation

// MARK: - 长截图编辑器文档视图

/// 编辑器 DocumentView（原作 LongScreenshotEditorDocumentView）：
/// 初始居中且尺寸钳制——size = min(请求尺寸, scrollView 可视尺寸)，
/// 超限时 setFrameSize 后 setFrameOrigin((fw-vw)/2, (fh-vh)/2)（spec 15 §3④，0x10044cdbc-0x10044ce74）。
final class LongScreenshotEditorDocumentView: NSView {
    let image: CGImage
    /// 图片在文档视图内的绘制矩形（水平居中；宽度不足容器时两侧留白）
    private var imageRect: NSRect = .zero

    init(image: CGImage) {
        self.image = image
        // 请求尺寸 = 图像点尺寸（72dpi 基准）
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: image.width, height: image.height)))
        imageRect = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.12, alpha: 1).setFill()
        bounds.fill()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: imageRect)
    }

    /// 按容器宽度等比缩放（v150 修复「预览里也被拉扁 / 一打开是空白」）
    ///
    /// 关键：**不要改 documentView.frame.origin**。NSClipView 会按 bounds.origin 再偏移
    /// 一次，两边都设等于偏移算两遍——实测 dirtyRect 落在图片之外，整窗空白。
    /// 现在文档宽度至少铺满容器、图片在文档内水平居中，origin 恒为 (0,0)，
    /// 竖向位置完全交给 clipView.scroll(to:)。
    func fitCentered(in containerSize: NSSize) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, containerSize.width > 0, containerSize.height > 0 else { return }
        // v181（用户：「预览框看不清」）：原来 scale 上限锁死 1，窄图（1x 截的 480 宽长图）
        // 在大窗里只占中间一条，两侧全是黑边。现在允许按宽度放大（最多 2 倍，
        // 再大就糊成马赛克）；Retina 长图仍然是缩小到适合宽度。
        let fill = containerSize.width / iw
        let scale = min(max(fill, 0.02), 2.0)
        let drawW = max(1, (iw * scale).rounded())
        let drawH = max(1, (ih * scale).rounded())
        let docW = max(containerSize.width, drawW)
        setFrameSize(NSSize(width: docW, height: drawH))
        setFrameOrigin(.zero)
        imageRect = NSRect(x: ((docW - drawW) / 2).rounded(), y: 0, width: drawW, height: drawH)
        needsDisplay = true
    }
}

// MARK: - 编辑器滚动视图 / 容器视图

/// 滚动视图封装（原作 LongScreenshotImageScrollView / LongScreenshotEditorScrollView，
/// 均有 init(coder:) fatalError 骨架 0x10044c060）
final class LongScreenshotImageScrollView: NSScrollView {
    init(document: LongScreenshotEditorDocumentView) {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        allowsMagnification = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = document
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    var document: LongScreenshotEditorDocumentView? { documentView as? LongScreenshotEditorDocumentView }
}

/// 编辑器容器（原作 LongScreenshotEditorContainerView）：滚动视图 + 底部工具条
///
/// 2026-10-18 重写布局（用户反馈"提示窗太小"）：
///   旧实现内容区固定 640×480 且不随窗口缩放——窗口 880×640 里内容只占一角，
///   长截图预览显得很小。现在：
///   · scrollView 撑满工具条以上全部区域（autoresizing + layout 双保险）
///   · 工具条贴底、按钮靠右随宽度重排
///   · 窗口尺寸由窗口侧按图像尺寸钳制到屏幕可视区（见 LongScreenshotEditorWindow.init）
final class LongScreenshotEditorContainerView: NSView {
    let scrollView: LongScreenshotImageScrollView
    private let toolbar = NSView(frame: .zero)
    private let saveButton = FirstMouseButton(title: "保存", target: nil, action: nil)
    private let copyButton = FirstMouseButton(title: "复制", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "关闭", target: nil, action: nil)
    private static let toolbarHeight: CGFloat = 48
    private static let buttonW: CGFloat = 76
    private static let buttonH: CGFloat = 30
    /// 只定位一次：之后用户滚动/改窗口大小时不要把人拉回顶部
    private var didPositionInitially = false

    init(document: LongScreenshotEditorDocumentView,
         onSave: @escaping () -> Void,
         onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        scrollView = LongScreenshotImageScrollView(document: document)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 960, height: 700)))
        autoresizingMask = [.width, .height]

        scrollView.frame = bounds.insetBy(dx: 0, dy: 0)
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        for (btn, action) in [(saveButton, onSave), (copyButton, onCopy), (closeButton, onClose)] {
            btn.bezelStyle = .rounded
            btn.autoresizingMask = [.minXMargin]
            ClosureButtonAction.bind(btn, handler: action)
            toolbar.addSubview(btn)
        }
        saveButton.keyEquivalent = "\r"
        toolbar.autoresizingMask = [.width, .minYMargin]
        addSubview(toolbar)
        layoutEditor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override func layout() {
        super.layout()
        layoutEditor()
        // DocumentView 按容器宽度等比缩放（0x10044cdbc）
        scrollView.document?.fitCentered(in: scrollView.contentSize)
        // 首次显示滚到顶部：NSClipView 会忽略 documentView.frame.origin 的负值，
        // 必须通过 clipView.scroll(to:) 定位，否则长图一打开停在**底部**（页脚）。
        // 注意：首次 layout 时 clipView 尺寸可能还是 0——此时算出的 maxY = 文档高，
        // 会把可视区滚到图片**上方**（全白空白）。必须等尺寸就绪再定位。
        if !didPositionInitially, let doc = scrollView.document {
            let clip = scrollView.contentView
            if clip.bounds.height > 1, doc.frame.height > 1 {
                didPositionInitially = true
                let maxY = max(0, doc.frame.height - clip.bounds.height)
                clip.scroll(to: NSPoint(x: 0, y: maxY))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }

    private func layoutEditor() {
        let bar = Self.toolbarHeight
        toolbar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bar)
        scrollView.frame = NSRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))

        let w = Self.buttonW, h = Self.buttonH, y = (bar - h) / 2
        var x = bounds.width - 16 - w
        closeButton.frame = NSRect(x: x, y: y, width: w, height: h)
        x -= (w + 10)
        copyButton.frame = NSRect(x: x, y: y, width: w, height: h)
        x -= (w + 10)
        saveButton.frame = NSRect(x: x, y: y, width: w, height: h)
    }

    /// 排障探针：直接 performClick 三个按钮，验证 action 链是否真的执行。
    func debugPerformButtons() {
        saveButton.performClick(nil)
        copyButton.performClick(nil)
        closeButton.performClick(nil)
    }

    /// 排障探针：按钮中心的命中视图 + 该屏幕点上是否还有别的窗口压在编辑器上。
    /// 入口：`defaults write com.sxyq.frsetnext probe.longshotHit -bool true` +
    /// `kitnest://longshotpreview`。
    func debugHitReport(window: NSWindow) -> [String] {
        [("保存", saveButton), ("复制", copyButton), ("关闭", closeButton)].map { name, btn in
            let p = btn.convert(NSPoint(x: btn.bounds.midX, y: btn.bounds.midY), to: self)
            let hit = hitTest(p)
            let screenPoint = window.convertPoint(toScreen: convert(p, to: nil))
            let above = NSWindow.windowNumber(at: screenPoint,
                                              belowWindowWithWindowNumber: window.windowNumber)
            return "\(name)：hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")，"
                + "上方窗口=\(above)（本窗 \(window.windowNumber)）"
        }
    }
}

/// v200：非激活/非 key 窗口的第一次点击也直接落到按钮上。
/// 默认 NSButton 要「先点一下激活窗口，再点才生效」，用户体感就是「点了没反应」。
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// target-action → 闭包 的轻量桥接（编辑器工具条按钮用）
final class ClosureButtonAction: NSObject {
    private let handler: () -> Void
    private init(handler: @escaping () -> Void) { self.handler = handler }

    static func bind(_ button: NSButton, handler: @escaping () -> Void) {
        let target = ClosureButtonAction(handler: handler)
        button.target = target
        button.action = #selector(fire(_:))
        objc_setAssociatedObject(button, "frset.closureAction", target, .OBJC_ASSOCIATION_RETAIN)
    }

    @objc private func fire(_ sender: NSButton?) { handler() }
}

// MARK: - 编辑器窗口 / 控制器

/// 编辑窗（原作 LongScreenshotEditorWindow + LongScreenshotEditorWindowController）
final class LongScreenshotEditorWindow: NSWindow {
    let editorContent: LongScreenshotEditorContainerView

    init(document: LongScreenshotEditorDocumentView,
         onSave: @escaping () -> Void,
         onCopy: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        let container = LongScreenshotEditorContainerView(document: document,
                                                          onSave: onSave,
                                                          onCopy: onCopy,
                                                          onClose: onClose)
        editorContent = container
        // 窗口按图像像素宽自适应（旧实现固定 ÷2 假设 Retina，1x 屏上会显得很小），
        // 钳制到屏幕可视区 85%；内容区再按宽度等比缩放（见 fitCentered）。
        let img = document.image
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let docW = CGFloat(img.width)
        let docH = CGFloat(img.height)
        // v181（用户：「预览框可以扩大一点，看不清」）：上限 85% → 92%，
        // 下限 760×560 → 920×700。长截图本来就是「窄而长」，宽度不放大时正文
        // 被压成一条细缝，根本看不清内容；高度贴满可视区也让「这是张长图」直观。
        let capW = screen.width * 0.92
        let capH = screen.height * 0.92
        let wantW = min(max(docW + 48, 920), capW)
        let wantH = min(max(docH + 48 + 56, 700), capH)
        super.init(contentRect: NSRect(origin: .zero, size: NSSize(width: wantW, height: wantH)),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "长截图"
        // v209：统一窗口外观入口（原生标题栏 + 原生红黄绿 + 统一玻璃底 + 系统圆角）。
        // 此前这里手工透明窗 + 隐藏三颗灯，与其它内容窗两套实现。
        minSize = NSSize(width: 760, height: 560)
        isReleasedWhenClosed = false
        contentView = container
        applyOfficialChrome()
        center()
    }
}

/// 预览/编辑器入口（原作 LongScreenshotPreviewController）：
/// 会话收尾产物进入这里（spec 15 §3④：DocumentView 居中、钳制到可视区）。
final class LongScreenshotPreviewController: NSObject, NSWindowDelegate {
    static let shared = LongScreenshotPreviewController()

    private var window: LongScreenshotEditorWindow?

    private override init() { super.init() }

    func show(image: CGImage) {
        window?.close()
        let document = LongScreenshotEditorDocumentView(image: image)
        let editor = LongScreenshotEditorWindow(
            document: document,
            onSave: { [weak self] in
                guard let doc = self?.window?.editorContent else {
                    Log.warn("Capture", "长截图保存：编辑器窗口不可用")
                    return
                }
                guard let image = doc.scrollView.document?.image else {
                    Log.warn("Capture", "长截图保存：取不到文档图")
                    return
                }
                guard let data = ImageProcessor.pngData(image) else {
                    Log.warn("Capture", "长截图保存：PNG 编码失败")
                    return
                }
                guard let url = ScreenshotManager.shared.savePNG(data, pixelSize: CGSize(width: image.width, height: image.height)) else {
                    Log.warn("Capture", "长截图保存：savePNG 返回 nil")
                    return
                }
                ScreenshotManager.shared.registerCaptured(url: url, data: data, playSound: true, mode: "long")   // v130②
                Log.info("Capture", "长截图保存：\(url.path)")
            },
            onCopy: { [weak self] in
                guard let doc = self?.window?.editorContent,
                      let image = doc.scrollView.document?.image else {
                    Log.warn("Capture", "长截图复制：内容视图/文档图不可用")
                    return
                }
                ScreenshotManager.shared.copyToPasteboard(image)
                Log.info("Capture", "长截图复制：已写入剪贴板")
            },
            onClose: { [weak self] in
                // v200（用户「保存/复制/关闭点了没反应」）：工具栏关闭原来走 performClose，
                // 而自绘圆钮的 v181 实测结论是「标准关闭钮被隐藏/禁用后 performClose 静默无效」。
                // 与圆钮统一：直接 close()，不依赖标准关闭钮状态。
                Log.info("Capture", "长截图关闭：close()")
                self?.window?.close()
            })
        editor.delegate = self
        window = editor
        // v200：先激活再置 key——LSUIElement 下反序会让窗口当不上 key，
        // 第一次点击只激活窗口、不落到按钮上（用户体感「点了没反应」）。
        NSApp.activate(ignoringOtherApps: true)
        editor.makeKeyAndOrderFront(nil)
        if UserDefaults.standard.bool(forKey: "probe.longshotHit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let w = self?.window else { return }
                Log.info("Capture", "长截图探针：active=\(NSApp.isActive) key=\(w.isKeyWindow) "
                         + "level=\(w.level.rawValue) " + w.editorContent.debugHitReport(window: w).joined(separator: " | "))
            }
        }
        if UserDefaults.standard.bool(forKey: "probe.longshotClick") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let c = self?.window?.editorContent else { return }
                Log.info("Capture", "长截图探针：开始 performClick")
                c.debugPerformButtons()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    Log.info("Capture", "长截图探针：点击后 isVisible=\(self?.window?.isVisible == true)")
                }
            }
        }

        // 排障（v181）：`probe.longshotClose=YES` → 1.5s 后**按一下自绘关闭钮**
        // （performClick 等价真点击），2s 后记录窗口是否真的关了。
        // 无人值守环境下点不到按钮，靠它验收「关闭钮无效」的修复。
        if UserDefaults.standard.bool(forKey: "probe.longshotClose") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let win = self?.window,
                      let btn = win.standardWindowButton(.closeButton) else {
                    Log.warn("Capture", "关闭钮探针：没找到标准关闭钮")
                    return
                }
                btn.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    Log.info("Capture", "关闭钮探针：点击后 isVisible=\(win.isVisible)")
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? LongScreenshotEditorWindow) === window { window = nil }
    }
}

// MARK: - 采集中实时预览卡（v176）

/// 长截图采集中，选区旁边一张小卡片：随画布增长实时变大。
///
/// 原版（Frset 长截图）在滚动采集时右侧就有这么一张预览，用户能一边滚一边确认
/// 「截到哪儿了」。我们此前只有采集结束后的编辑器，过程中只有一个高度数字。
///
/// 实现要点：
/// - 面板 `ignoresMouseEvents`，不挡滚动、不抢焦点；
/// - 放在选区外侧（右 → 左 → 上 → 下），**永远不会**压在采集区里；
/// - `sharingType = .none`：连系统捕获都取不到它（SCK 的 app 级排除对覆盖窗不生效）；
/// - 只显示画布**顶部**一段（按宽度缩放后最多裁到 288pt 高），长图不会缩成细条；
///   选区太宽导致左右都没位置时，缩略图高度跟着可用空间缩，卡片不消失。
final class LongScreenshotLivePreviewPanel: NSPanel {

    private final class FlippedCard: NSView {
        override var isFlipped: Bool { true }
    }

    private let card = FlippedCard()
    private let imageView = NSImageView()
    private let sizeLabel = NSTextField(labelWithString: "")

    private let padding: CGFloat = 8
    private let footerH: CGFloat = 18
    private let contentW: CGFloat = 156

    /// 位置算下来无论如何都会压在选区上时（选区几乎占满整屏宽），宁可不显示——
    /// 这张卡的意义是「让你看见画布」，压住内容反而坏事。
    private var suppressed = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 172, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // v181（复查）：HUD/选区边框踩过的同一个坑——SCK 的 excludingApplications 对
        // 覆盖层级窗口不生效，只有 sharingType = .none 是系统级开关。
        // 少了这行，一旦卡片因为翻边/贴边压进选区，就会被逐帧截进长截图里。
        // 排障开关 probe.cardCapture=1：临时放回可捕获，用于截图核对卡片样式与位置
        // （默认 .none 时连 screencapture 都拍不到它，验收时注意）。
        sharingType = UserDefaults.standard.bool(forKey: "probe.cardCapture") ? .readOnly : .none

        card.wantsLayer = true
        card.layer?.cornerRadius = Theme.Radius.window
        card.layer?.cornerCurve = .continuous
        // v205：实时预览卡不再用固定白底——统一玻璃底（通透度/磨砂跟随个性化）
        card.layer?.backgroundColor = NSColor.clear.cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor
        card.layer?.masksToBounds = true
        contentView = card
        installUnifiedGlassBackground(cornerRadius: Theme.Radius.window)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        card.addSubview(imageView)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.textColor = NSColor.secondaryLabelColor
        sizeLabel.alignment = .right
        card.addSubview(sizeLabel)

        let caption = NSTextField(labelWithString: "长截图")
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.textColor = NSColor.secondaryLabelColor
        card.addSubview(caption)
        self.captionLabel = caption
    }

    private var captionLabel: NSTextField!

    /// 可用槽位：位置 + 该位置允许的最大卡片高度。
    /// 先算槽位再裁缩略图——这样「选区几乎占满屏宽」时卡片不会因为长高了放不下就整体消失，
    /// 而是缩略图跟着变矮，始终留在屏幕上（这才是「实时预览」该有的样子）。
    private enum Slot {
        /// 选区左右两侧：顶边与选区顶对齐
        case side(x: CGFloat, top: CGFloat, maxHeight: CGFloat)
        /// 选区上方：卡片底边贴 `top`
        case above(x: CGFloat, top: CGFloat, maxHeight: CGFloat)
        /// 选区下方：卡片顶边在 `top`
        case below(x: CGFloat, top: CGFloat, maxHeight: CGFloat)
    }

    /// 更新预览（`selection` 是 AppKit 坐标下的选区，用来定位）
    func update(image: CGImage, near selection: NSRect) {
        guard let slot = resolveSlot(near: selection) else {
            if !suppressed {
                suppressed = true
                orderOut(nil)
            }
            return
        }

        // 缩略图高度上限：既不能超过 288pt（长图不缩成细条），也要塞得进槽位
        let maxDisplayH = max(24, slotMaxHeight(slot) - footerH - padding * 2)
        let scale = contentW / CGFloat(max(1, image.width))
        let limit = min(288, maxDisplayH)
        let visibleSrcH = max(1, min(CGFloat(image.height), (limit / max(scale, 0.0001)).rounded()))
        let cropRect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: visibleSrcH)
        let cropped = image.cropping(to: cropRect) ?? image
        imageView.image = NSImage(cgImage: cropped,
                                  size: NSSize(width: cropRect.width, height: cropRect.height))

        let displayH = max(20, (visibleSrcH * scale).rounded())
        let cardW = contentW + padding * 2
        let cardH = displayH + footerH + padding * 2

        setContentSize(NSSize(width: cardW, height: cardH))
        imageView.frame = NSRect(x: padding, y: padding, width: contentW, height: displayH)
        captionLabel.frame = NSRect(x: padding, y: padding + displayH + 1,
                                    width: 60, height: 13)
        sizeLabel.frame = NSRect(x: cardW - padding - 90, y: padding + displayH + 1,
                                 width: 90, height: 13)
        sizeLabel.stringValue = "\(image.width)×\(image.height)"

        setFrameOrigin(slotOrigin(slot, size: NSSize(width: cardW, height: cardH)))
        if suppressed { suppressed = false }
        if !isVisible { orderFrontRegardless() }
    }

    private func slotMaxHeight(_ slot: Slot) -> CGFloat {
        switch slot {
        case .side(_, _, let h), .above(_, _, let h), .below(_, _, let h): return h
        }
    }

    private func slotOrigin(_ slot: Slot, size: NSSize) -> NSPoint {
        switch slot {
        case .side(let x, let top, _):   return NSPoint(x: x, y: top - size.height)
        case .above(let x, let top, _):  return NSPoint(x: x, y: top)
        case .below(let x, let top, _):  return NSPoint(x: x, y: top - size.height)
        }
    }

    /// 排障（v176）：不跑真实会话，直接渲染一张长图到预览卡上，用来核对样式与位置
    static var debugInstance: LongScreenshotLivePreviewPanel?

    static func debugShow(image: CGImage, near selection: NSRect) {
        let panel = LongScreenshotLivePreviewPanel()
        debugInstance = panel
        panel.update(image: image, near: selection)
        Log.info("Capture", "排障：长截图预览卡已显示（\(image.width)×\(image.height)）")
    }

    /// 选一处**不与选区相交**的位置：右侧 → 左侧 → 上方 → 下方；都给不出可用高度就返回 nil（收起）。
    /// 「不与选区相交」是硬约束：压进采集区会被逐帧截进长截图，也会挡住用户正要看的内容。
    private func resolveSlot(near selection: NSRect) -> Slot? {
        guard let screen = screen(containing: selection) else { return nil }
        let vf = screen.visibleFrame
        let gap: CGFloat = 16
        let margin: CGFloat = 8
        let w = frame.width
        let vfMinY = vf.minY + margin
        let vfMaxY = vf.maxY - margin
        let fullH = max(0, vfMaxY - vfMinY)
        /// 卡片最矮也要放得下「一截缩略图 + 页脚」，低于这个值不如不显示
        let minUseful: CGFloat = footerH + padding * 2 + 24

        // ① 右侧（顶边与选区顶对齐）
        if selection.maxX + gap + w <= vf.maxX - margin {
            return .side(x: selection.maxX + gap, top: min(selection.maxY, vfMaxY), maxHeight: fullH)
        }
        // ② 翻到左侧
        if selection.minX - gap - w >= vf.minX + margin {
            return .side(x: selection.minX - gap - w, top: min(selection.maxY, vfMaxY), maxHeight: fullH)
        }
        // ③ 选区上方（底边贴选区顶）——超宽选区时左右都没地方
        let aboveSpace = vfMaxY - (selection.maxY + gap)
        if aboveSpace >= minUseful {
            let x = clampX(selection.minX, width: w, vf: vf, margin: margin)
            return .above(x: x, top: selection.maxY + gap, maxHeight: aboveSpace)
        }
        // ④ 选区下方（顶边贴选区底）
        let belowSpace = (selection.minY - gap) - vfMinY
        if belowSpace >= minUseful {
            let x = clampX(selection.minX, width: w, vf: vf, margin: margin)
            return .below(x: x, top: selection.minY - gap, maxHeight: belowSpace)
        }
        Log.warn("Capture", "长截图预览卡：选区几乎占满屏幕，找不到不重叠的位置，已收起")
        return nil
    }

    private func clampX(_ x: CGFloat, width w: CGFloat, vf: NSRect, margin: CGFloat) -> CGFloat {
        min(max(vf.minX + margin, x), max(vf.minX + margin, vf.maxX - w - margin))
    }

    /// 选区所在的屏幕（不能只用 NSScreen.main：副屏上框选时会跑到主屏去）
    private func screen(containing rect: NSRect) -> NSScreen? {
        var best: (NSScreen, CGFloat)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.1 { best = (screen, area) }
        }
        return best?.0 ?? NSScreen.main ?? NSScreen.screens.first
    }
}
