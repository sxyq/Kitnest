import AppKit

/// 内嵌桌面场景，持有正式画布；不接入控制器、Reveal 或文件系统。
final class CurtainPreviewScene: NSView {
    private let canvas = CurtainCanvasView()
    private let viewport = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let captureButton = NSButton(title: "模拟截图", target: nil, action: nil)
    private let toggleButton = NSButton(title: "展开", target: nil, action: nil)
    private var values: CurtainSettingsDraft.Values?
    private var entries: [(CurtainItem, CGImage?)] = []
    private var shown = false
    private var localWidth: CGFloat?
    private var reduceMotion = false
    private var hideTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var demoTask: Task<Void, Never>?
    private var sequence = 0
    private var previousSize = CGSize.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("图帘预览：回车展开或收起，N 模拟截图，加减缩放，删除键移除模拟卡片")
        canvas.isHidden = true
        viewport.drawsBackground = false
        viewport.hasHorizontalScroller = true
        viewport.autohidesScrollers = true
        viewport.documentView = canvas
        addSubview(viewport)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        addSubview(status)
        for button in [captureButton, toggleButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            addSubview(button)
        }
        captureButton.action = #selector(simulateCapture)
        toggleButton.action = #selector(toggle)
        canvas.onCopy = { [weak self] _ in self?.feedback("复制演示：不写剪贴板") }
        canvas.onDrag = { [weak self] _ in self?.feedback("拖出演示：卡片仍留在场景内") }
        canvas.onReveal = { [weak self] _ in self?.feedback("定位演示：不打开 Finder") }
        canvas.onSave = { [weak self] _ in self?.feedback("保存演示：不写文件") }
        canvas.onPin = { [weak self] _ in self?.feedback("钉图演示：不打开正式窗口") }
        canvas.onRemove = { [weak self] item in
            guard let self else { return }
            self.entries.removeAll { $0.0.id == item.id }
            self.render(animate: false)
            self.feedback("已移除场景卡片 · 剩余 \(self.entries.count) 张")
        }
        canvas.onResizeStep = { [weak self] delta in
            guard let self, let values = self.values else { return }
            self.localWidth = min(CurtainPref.maxCardWidth,
                max(CurtainPref.minCardWidth, (self.localWidth ?? CGFloat(values.cardWidth)) + delta))
            self.render(animate: false, live: true)
            self.feedback("⌘ 缩放演示 · \(Int(self.localWidth!)) pt · 不改草稿宽度")
        }
        canvas.onResizeEnd = { [weak self] in self?.render(animate: false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }
    override func becomeFirstResponder() -> Bool {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        return true
    }
    override func resignFirstResponder() -> Bool { layer?.borderWidth = 0; return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: toggle()
        case 45: simulateCapture()
        case 24, 69: canvas.onResizeStep?(8)
        case 27, 78: canvas.onResizeStep?(-8)
        case 51, 117:
            if !entries.isEmpty { entries.removeLast(); render(animate: false); feedback("剩余 \(entries.count) 张模拟卡片") }
        case 53: hide("已收起 · 模拟卡片仍在")
        default: super.keyDown(with: event)
        }
    }

    func update(values: CurtainSettingsDraft.Values, reduceMotion: Bool, reduceTransparency: Bool) {
        let previous = self.values
        self.values = values
        self.reduceMotion = reduceMotion
        canvas.reduceMotion = reduceMotion
        canvas.reduceTransparency = reduceTransparency
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        captureButton.isEnabled = values.enabled
        toggleButton.isEnabled = values.enabled
        if reduceMotion { demoTask?.cancel() }
        if !values.enabled {
            stop()
            entries.removeAll()
            shown = false
            canvas.isHidden = true
            toggleButton.title = "展开"
            feedback("图帘已关闭 · 保存后应用到正式图帘")
        } else if previous?.enabled != true {
            localWidth = nil
            sequence = 0
            // 固定内容先入暂存区；自动上架仅控制新截图是否进入。
            entries = (0..<Int(values.maxCards)).map { sample(index: $0) }
            sequence = entries.count
            shown = true
            feedback("图帘已展开 · \(entries.count) 张固定卡片")
            scheduleHide()
        } else if previous != values {
            if previous?.cardWidth != values.cardWidth { localWidth = nil }
            if previous?.maxCards != values.maxCards {
                let count = Int(values.maxCards)
                if entries.count > count { entries.removeFirst(entries.count - count) }
                while entries.count < count { entries.append(sample(index: sequence)); sequence += 1 }
            }
            if previous?.duration != values.duration {
                if shown { scheduleHide() }
                feedback(values.duration == 0 ? "永不自动收起 · 内容留在场景" : "展示 \(Int(values.duration)) 秒后收起")
            }
        }
        render(animate: previous?.enabled != values.enabled)
        needsLayout = true
        if values.enabled, previous?.enabled != true, !reduceMotion {
            startDemo()
        }
    }

    private func sample(index: Int) -> (CurtainItem, CGImage?) {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        return (CurtainItem(id: id, fileURL: URL(string: "kitnest-preview://curtain/\(index)")!,
                           createdAt: Date(timeIntervalSince1970: 0),
                           pixelSize: CGSize(width: 640, height: 384)), CapturePreviewImage.image)
    }

    override func layout() {
        super.layout()
        captureButton.frame = NSRect(x: 8, y: 6, width: 80, height: 22)
        toggleButton.frame = NSRect(x: bounds.width - 72, y: 6, width: 64, height: 22)
        status.frame = NSRect(x: 8, y: bounds.height - 21, width: bounds.width - 16, height: 17)
        viewport.frame = NSRect(x: 4, y: 30, width: bounds.width - 8, height: bounds.height - 54)
        if bounds.size != previousSize {
            previousSize = bounds.size
            render(animate: false)
        }
    }

    private func render(animate: Bool, live: Bool = false) {
        guard let values, values.enabled else { return }
        canvas.isHidden = !shown
        toggleButton.title = shown ? "收起" : "展开"
        guard shown else { canvas.stopAnimations(); return }
        guard viewport.contentSize.width > 0 else { return }
        let desired = localWidth ?? CGFloat(values.cardWidth)
        // 卡宽使用正式尺寸，超出视口横向滚动，不整体缩小组件。
        let desktop = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let metrics = CurtainLayout.metrics(desired: desired, count: entries.count,
                                           visible: desktop, railScales: values.railScales)
        let width = metrics.cardWidth
        let railScale = metrics.railScale
        let total = CGFloat(entries.count) * width
            + CGFloat(max(entries.count - 1, 0)) * CurtainMetrics.gap(railScale)
            + 2 * CurtainMetrics.padding(railScale)
        let logicalSize = CGSize(width: max(viewport.contentSize.width, total), height: viewport.contentSize.height)
        canvas.frame = NSRect(origin: .zero, size: logicalSize)
        canvas.setBoundsSize(logicalSize)
        let maxHeight = min(metrics.maxHeight,
                           logicalSize.height - CurtainMetrics.clipHeight(railScale)
                           - CurtainMetrics.bottomInset(railScale))
        if live {
            canvas.updateLayout(items: entries, cardWidth: width, railScale: railScale,
                                maxCardHeight: max(maxHeight, 40), size: logicalSize)
        } else {
            canvas.reload(items: entries, cardWidth: width, railScale: railScale,
                          maxCardHeight: max(maxHeight, 40), style: values.style,
                          size: logicalSize, animate: animate && !reduceMotion)
        }
    }

    @objc private func simulateCapture() {
        demoTask?.cancel()
        capture()
    }
    private func capture() {
        guard let values, values.enabled else { return }
        if values.attachOnCapture {
            entries.append(sample(index: sequence))
            sequence += 1
            let overflow = max(0, entries.count - Int(values.maxCards))
            if overflow > 0 { entries.removeFirst(overflow) }
            shown = true
            render(animate: true)
            scheduleHide()
            feedback("新截图自动上架 · \(entries.count)/\(Int(values.maxCards)) 张 · 最旧卡片已让位")
        } else {
            feedback("自动上架已关闭 · 新截图未进入图帘")
        }
    }
    @objc private func toggle() {
        demoTask?.cancel()
        guard values?.enabled == true else { return }
        shown.toggle()
        if shown { scheduleHide() } else { hideTask?.cancel(); canvas.stopAnimations() }
        render(animate: false)
        feedback(shown ? "手动展开 · \(entries.count) 张卡片" : "已收起 · \(entries.count) 张卡片仍在")
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard let values, values.duration > 0 else { return }
        let seconds = values.duration
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            self?.hide("展示 \(Int(seconds)) 秒：已收起，内容仍在")
        }
    }
    private func hide(_ message: String) {
        shown = false
        canvas.isHidden = true
        canvas.stopAnimations()
        toggleButton.title = "展开"
        feedback(message)
    }
    private func feedback(_ message: String) { status.stringValue = message }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 30),
            options: [.mouseEnteredAndExited, .activeAlways], owner: self,
            userInfo: ["top": true]))
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        leaveTask?.cancel()
        guard values?.enabled == true, values?.revealOnHover == true,
              event.trackingArea?.userInfo?["top"] as? Bool == true else { return }
        shown = true
        render(animate: false)
        scheduleHide()
        feedback("顶边悬停唤出 · \(entries.count) 张卡片")
    }
    override func mouseExited(with event: NSEvent) {
        guard values?.enabled == true, values?.revealOnHover == true,
              event.trackingArea?.userInfo?["top"] == nil else { return }
        leaveTask?.cancel()
        leaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            self?.hide("移开 0.8 秒：已收起，内容仍在")
        }
    }
    private func startDemo() {
        demoTask?.cancel()
        demoTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            self?.capture()
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            guard let self, self.values?.enabled == true else { return }
            self.feedback("悬停卡片显示保存 / 钉图 / 移除；⌘ 拖动缩放整条图帘")
        }
    }
    func stop() {
        hideTask?.cancel()
        leaveTask?.cancel()
        demoTask?.cancel()
        canvas.stopAnimations()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
}
