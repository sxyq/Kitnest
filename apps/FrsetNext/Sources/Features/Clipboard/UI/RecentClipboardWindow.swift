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
    private var anchor = -1
    private var generation = 0
    private var closing = false
    private var returnApplication: NSRunningApplication?
    var isVisible: Bool { window?.isVisible == true }

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
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
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 3)
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [countLabel, spacer, cancel, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        errorLabel.textColor = .systemOrange
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true
        let footer = NSStackView(views: [errorLabel, buttons])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 8
        buttons.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        let root = NSStackView(views: [scroll, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        root.autoresizingMask = [.width, .height]
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        footer.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        panel.contentView = root
        panel.minSize = NSSize(width: 440, height: 300)
        panel.applyOfficialChrome()
    }

    required init?(coder: NSCoder) { fatalError("近期选择窗使用代码构建") }

    func show(returnTo application: NSRunningApplication? = nil) {
        guard let window else { return }
        if window.isVisible { window.makeKeyAndOrderFront(nil); return }
        returnApplication = application
        generation += 1
        let current = generation
        closing = false
        anchor = -1
        table.deselectAll(nil)
        records = []
        table.reloadData()
        updateSelection()
        emptyLabel.stringValue = "正在读取近期记录…"
        emptyLabel.isHidden = false
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = NSSize(width: min(560, visible.width), height: min(520, visible.height))
        window.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                               width: size.width, height: size.height), display: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            WindowReveal.playInFromMouse(on: window, duration: 0.16)
        }
        ClipboardManager.shared.recentItems(limit: ClipboardManager.pageSize) { [weak self] items in
            guard let self, self.generation == current else { return }
            self.records = items
            self.table.reloadData()
            self.emptyLabel.stringValue = "暂无剪贴板记录"
            self.emptyLabel.isHidden = !items.isEmpty
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("recent.row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? RecentClipboardCell
            ?? RecentClipboardCell()
        cell.identifier = identifier
        cell.check.tag = row
        cell.check.target = self
        cell.check.action = #selector(checkTapped(_:))
        cell.check.state = table.selectedRowIndexes.contains(row) ? .on : .off
        cell.summary.stringValue = records[row].displayTitle
        cell.time.stringValue = records[row].timestamp.formatted(date: .abbreviated, time: .shortened)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardRowChromeView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func select(row: Int, flags: NSEvent.ModifierFlags) {
        table.toggleRowSelection(row: row, shift: flags.contains(.shift), anchor: &anchor)
        window?.makeFirstResponder(table)
    }

    private func updateSelection() {
        let selected = table.selectedRowIndexes
        countLabel.stringValue = "已选 \(selected.count) 条"
        copyButton.title = "复制 \(selected.count) 条"
        copyButton.isEnabled = !selected.isEmpty
        let hasImage = selected.contains { records[$0].type == .image }
        errorLabel.stringValue = hasImage && selected.count > 1 ? "文字与图片需分别复制；图片请逐张复制。" : ""
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        for row in 0..<records.count {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RecentClipboardCell)?.check.state
                = selected.contains(row) ? .on : .off
        }
    }

    @objc private func checkTapped(_ sender: NSButton) { select(row: sender.tag, flags: NSEvent.modifierFlags) }
    @objc private func cancelTapped() { close() }
    @objc private func copyTapped() { copySelected() }

    private func copySelected() {
        let items = table.selectedRowIndexes.map { records[$0] }
        guard !items.isEmpty else { return }
        if let reason = ClipboardManager.shared.copy(items, successMessage: "已复制 \(items.count) 条") {
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
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { finish() }
        else { WindowReveal.playOutToLastAnchor(on: window, duration: 0.12, completion: finish) }
    }

    func windowWillClose(_ notification: Notification) {
        generation += 1
        returnApplication?.activate(options: [.activateIgnoringOtherApps])
    }
}

private final class RecentClipboardCell: NSTableCellView {
    // 行底色沿用12%强调色，不使用系统的深色选中底，文字保持主题对比度。
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = .normal }
    }

    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
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
        text.spacing = 4
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [check, text])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            summary.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("近期记录行使用代码构建") }
}
