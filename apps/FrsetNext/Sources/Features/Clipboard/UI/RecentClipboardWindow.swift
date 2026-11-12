import AppKit

/// 截图动作条与截图热键共用的近期多选窗；列表顺序就是合并正文顺序。
@MainActor
final class RecentClipboardWindowController: NSWindowController, NSWindowDelegate,
                                             NSTableViewDataSource, NSTableViewDelegate {
    private static var instance: RecentClipboardWindowController?
    static var isPresented: Bool { instance?.isVisible == true }
    static var shared: RecentClipboardWindowController {
        if let instance { return instance }
        let controller = RecentClipboardWindowController()
        instance = controller
        return controller
    }
    private let table = ClipboardTableView()
    private let countLabel = NSTextField(labelWithString: "已选 0 条")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "正在读取近期记录…")
    private let copyButton = NSButton(title: "复制 0 条", target: nil, action: nil)
    private var records: [ClipboardItem] = []
    private var visibleRecords: [ClipboardItem] = []
    private var selectedIDs = Set<String>()
    private var outputFormat: ClipboardOutputFormat = .merged
    private var anchor = -1
    private var generation = 0
    private var closing = false
    private var returnApplication: NSRunningApplication?
    var isVisible: Bool { window?.isVisible == true }

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                            styleMask: [.titled, .closable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "复制近期内容"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.isActive = false
        table.addTableColumn(NSTableColumn(identifier: .init("recent.contents")))
        table.dataSource = self
        table.delegate = self
        table.onSelectionClick = { [weak self] row, flags in self?.select(row: row, flags: flags) }
        table.onReturnKey = { [weak self] in self?.copySelected() }
        table.onSelectAll = { [weak self] in
            guard let self else { return }
            self.selectedIDs.formUnion(self.visibleRecords.map(\.id))
            self.updateSelection()
        }
        table.onSelectionCursorMove = { [weak self] in self?.refreshCells() }
        scroll.documentView = table
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = []
        copyButton.isEnabled = false
        copyButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.maximumNumberOfLines = 2
        countLabel.lineBreakMode = .byWordWrapping
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [countLabel, spacer, cancel, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        errorLabel.textColor = .systemOrange
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isHidden = true
        let footer = NSStackView(views: [errorLabel, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        buttons.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        let root = NSStackView(views: [scroll, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
        root.autoresizingMask = [.width, .height]
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true
        footer.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        panel.contentView = root
        panel.applyOfficialChrome()
    }

    required init?(coder: NSCoder) { fatalError("近期选择窗使用代码构建") }

    func show(returnTo application: NSRunningApplication? = nil, items: [ClipboardItem]? = nil,
              format: ClipboardOutputFormat = .merged) {
        guard let window else { return }
        if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        returnApplication = application
        generation += 1
        let current = generation
        closing = false
        anchor = -1
        selectedIDs = Set(items?.map(\.id) ?? [])
        outputFormat = format
        visibleRecords = []
        table.selectionCursor = -1
        table.deselectAll(nil)
        records = []
        table.reloadData()
        updateSelection()
        emptyLabel.stringValue = "正在读取近期记录…"
        emptyLabel.isHidden = false
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(380, visible.width), height: min(300, visible.height))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height), display: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            window.animator().alphaValue = 1
        }
        let loaded: ([ClipboardItem]) -> Void = { [weak self] items in
            guard let self, self.generation == current else { return }
            self.records = items
            self.visibleRecords = items
            self.table.selectionCursor = items.isEmpty ? -1 : 0
            self.table.reloadData()
            self.emptyLabel.stringValue = "暂无剪贴板记录"
            self.emptyLabel.isHidden = !items.isEmpty
            self.updateSelection()
            let height = min(visible.height, max(250, 140 + CGFloat(min(items.count, 5)) * 44))
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
        if let items { loaded(items) }
        else { ClipboardManager.shared.recentItems(limit: ClipboardManager.pageSize, completion: loaded) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRecords.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("recent.row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? RecentClipboardCell
            ?? RecentClipboardCell()
        cell.identifier = identifier
        cell.check.tag = row
        cell.check.target = self
        cell.check.action = #selector(checkTapped(_:))
        let item = visibleRecords[row]
        cell.check.state = selectedIDs.contains(item.id) ? .on : .off
        cell.check.isEnabled = true
        cell.summary.stringValue = item.displayTitle
        cell.summary.toolTip = item.displayTitle
        cell.time.stringValue = item.timestamp.relativeText
        cell.time.toolTip = item.timestamp.formatted(date: .abbreviated, time: .shortened)
        let symbol: String
        switch item.type {
        case .text: symbol = "doc.plaintext"
        case .richtext: symbol = "doc.richtext"
        case .url: symbol = "link"
        case .image: symbol = "photo"
        case .file: symbol = "doc"
        }
        cell.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.keyboardFocused = table.selectionCursor == row
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardRowChromeView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshCells() }

    private func select(row: Int, flags: NSEvent.ModifierFlags) {
        guard visibleRecords.indices.contains(row) else { return }
        table.selectionCursor = row
        if flags.contains(.shift), visibleRecords.indices.contains(anchor) {
            selectedIDs.formUnion(visibleRecords[min(anchor, row)...max(anchor, row)].map(\.id))
        } else {
            let id = visibleRecords[row].id
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            anchor = row
        }
        updateSelection()
        window?.makeFirstResponder(table)
    }

    private func updateSelection() {
        countLabel.stringValue = "已选 \(selectedIDs.count) 条"
        copyButton.title = "复制 \(selectedIDs.count) 条"
        copyButton.isEnabled = !selectedIDs.isEmpty
        let selected = records.filter { selectedIDs.contains($0.id) }
        let hasText = selected.contains(where: isText)
        let hasOther = selected.contains { !isText($0) }
        errorLabel.stringValue = hasText && hasOther ? "文字与图片或文件需分别复制" : ""
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        table.selectRowIndexes(IndexSet(visibleRecords.indices.filter { selectedIDs.contains(visibleRecords[$0].id) }), byExtendingSelection: false)
        refreshCells()
    }

    private func isText(_ item: ClipboardItem) -> Bool { item.type == .text || item.type == .url || item.type == .richtext }
    private func refreshCells() {
        for row in visibleRecords.indices {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RecentClipboardCell {
                cell.check.state = selectedIDs.contains(visibleRecords[row].id) ? .on : .off
                cell.keyboardFocused = table.selectionCursor == row
            }
        }
    }
    @objc private func checkTapped(_ sender: NSButton) { select(row: sender.tag, flags: NSEvent.modifierFlags) }
    @objc private func cancelTapped() { close() }
    @objc private func copyTapped() { copySelected() }

    private func copySelected() {
        guard !selectedIDs.isEmpty else { return }
        let selected = records.filter { selectedIDs.contains($0.id) }
        let message = "已复制 \(selected.count) 条"
        if let reason = ClipboardManager.shared.copy(selected, successMessage: message, format: outputFormat) {
            errorLabel.stringValue = reason
            errorLabel.isHidden = false
            return
        }
        close()
    }

    override func close() {
        guard let window, !closing else { return }
        closing = true
        generation += 1
        let finish = { [self] in
            window.orderOut(nil)
            WindowReveal.reset(window)
            closing = false
            returnApplication?.activate(options: [.activateIgnoringOtherApps])
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            window.animator().alphaValue = 0
        }
            completionHandler: { finish() }
    }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        returnApplication?.activate(options: [.activateIgnoringOtherApps])
    }
}

private final class RecentClipboardCell: NSTableCellView {
    var keyboardFocused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if keyboardFocused {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 7, yRadius: 7)
            outline.lineWidth = 1; outline.stroke()
        }
    }
    // 行底色沿用12%强调色，不使用系统的深色选中底，文字保持主题对比度。
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = .normal }
    }

    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let icon = NSImageView()
    let summary = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        summary.font = .systemFont(ofSize: 13)
        summary.lineBreakMode = .byTruncatingTail
        summary.maximumNumberOfLines = 1
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .systemFont(ofSize: 11)
        time.textColor = .secondaryLabelColor
        let text = NSStackView(views: [summary, time])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let row = NSStackView(views: [check, icon, text])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("近期记录行使用代码构建") }
}
