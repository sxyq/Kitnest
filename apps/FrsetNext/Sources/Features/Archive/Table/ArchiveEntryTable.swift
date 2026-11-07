import AppKit

// MARK: - 归档条目表（v127（ArcZip P0/P1）：AppKit NSTableView）
//
// 为什么不用 SwiftUI List：拖出要 NSFilePromiseProvider（NSPasteboardWriting，非
// NSItemProvider，见 ArchiveEntryDrag.swift），而 NSTableView 的
// `pasteboardWriterForRow` 每行给一个承诺 —— 多选拖出 = N 个承诺 = N 个文件，是
// AppKit 原生语义。顺带拿到原生 Shift 连选 / ⌘ 点选 / 方向键 / 双击（doubleAction）。
//
// 数据单向同步：updateNSView 里按「路径签名」比对 → reloadData / 回填选中；
// 表侧改选 → selectionDidChange 写回 model.selection（同值不循环）。

final class ArchiveEntryTableView: NSTableView {
    weak var host: ArchiveEntryTableHost?

    /// v258（用户：「悬浮 1 秒预览」）：表格自己装跟踪区——行视图会被 reload 复用，
    /// 装在行上每次重载都要重挂；装在表上只需跟着可见区域走。
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // v258 实测：归档窗被深链打开时主面板可能抢走 key，`.activeInKeyWindow`
        // 会让列表的悬停完全不触发（图标视图的 onHover 没这个限制，所以只坏一半）。
        // 改成 `.activeAlways`：只要窗口在屏幕上能看见鼠标，就跟踪。
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        host?.hoverChanged(to: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        host?.hoverChanged(to: -1)
    }

    override func scrollWheel(with event: NSEvent) {
        // 滚动时行会从指针底下滑过，不收起会连弹好几个
        host?.hoverChanged(to: -1)
        super.scrollWheel(with: event)
    }

    /// v127：右键先选中命中行（不在选中集里才换选），再弹共用条目菜单
    override func rightMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard let host else { return }
        host.menuActions.model = host.model
        let menu = host.menuActions.buildMenu(
            hasDirectory: host.model?.selectedEntries.first?.isDirectory == true)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class ArchiveEntryTableHost: NSView {

    let scrollView = NSScrollView()
    let tableView = ArchiveEntryTableView()
    weak var model: ArchiveBrowserModel?
    /// 上次渲染的条目签名（路径拼接），变化才 reloadData
    var lastSignature = ""
    /// 回填选中时置位，避免 selectionDidChange 反写 model 造成循环
    var applyingSelection = false
    /// v258：当前悬停行（-1 = 不在任何行上），用于「悬浮 1 秒预览」
    private var hoverRow = -1
    lazy var menuActions = ArchiveMenuActions(model: model)

    init() {
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: .init("entry"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.target = self
        tableView.delegate = self
        tableView.dataSource = self
        // 默认「本地=Every / 外部=None」→ 拖去 Finder 必须显式放开外部 copy
        tableView.setDraggingSourceOperationMask(.every, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.host = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    /// v258：表格离开窗口（归档窗关闭）→ 清掉悬停预览的临时解压目录
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ArchiveHoverPreview.shared.cleanup() }
    }

    /// 悬停行变化：换行走「先收旧、再等 1 秒」，离开表格直接取消
    func hoverChanged(to row: Int) {
        guard row != hoverRow else { return }
        hoverRow = row
        guard row >= 0, let model, row < model.visibleEntries.count else {
            ArchiveHoverPreview.shared.cancel()
            return
        }
        ArchiveHoverPreview.shared.schedule(archive: model.url, entry: model.visibleEntries[row])
    }

    // MARK: 排障

    /// v258：`probe.archiveHover=1` → 列表就绪后自动依次悬停前 4 行。
    /// 用途与 `?select=first` 同源：真机合成鼠标点不中列表（窗口可能在别的 Space、
    /// 或被系统权限弹窗挡住），用进程内调用把「1 秒预览」整条链路跑一遍。
    private var hoverProbeStarted = false

    func startHoverProbeIfNeeded() {
        guard !hoverProbeStarted, UserDefaults.standard.bool(forKey: "probe.archiveHover"),
              let model, !model.visibleEntries.isEmpty else { return }
        hoverProbeStarted = true
        let rows = min(4, model.visibleEntries.count)
        Log.info("Archive", "probe.archiveHover：依次悬停 \(rows) 行")
        for i in 0..<rows {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 2.2) { [weak self] in
                self?.hoverChanged(to: i)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(rows) * 2.2) { [weak self] in
            self?.hoverChanged(to: -1)
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, let model else { return }
        let list = model.visibleEntries
        guard row < list.count else { return }
        // v127（ArcZip P1）：双击目录进层级；文件仅选中（预览已在右栏）
        model.activate(list[row])
    }

    /// 模型侧数据/选中变化 → 同步到表
    func syncFromModel() {
        guard let model else { return }
        // 保护标志要在 reloadData 之前置位：重载可能触发 selectionDidChange，
        // 不挡住会把「模型里的选中」误写成空
        applyingSelection = true
        defer { applyingSelection = false }
        let list = model.visibleEntries
        let signature = list.map { $0.path }.joined(separator: "\u{1}")
        if signature != lastSignature {
            lastSignature = signature
            // v258：列表内容换了，旧行的悬停预览已经没有意义
            hoverRow = -1
            ArchiveHoverPreview.shared.cancel()
            tableView.reloadData()
        }
        var indexes = IndexSet()
        for (i, e) in list.enumerated() where model.selection.contains(e.path) {
            indexes.insert(i)
        }
        if tableView.selectedRowIndexes != indexes {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        startHoverProbeIfNeeded()
    }
}

extension ArchiveEntryTableHost: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        model?.visibleEntries.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model, row < model.visibleEntries.count else { return nil }
        // v128（内存优化）：包 autoreleasepool——滚动时每行构造行视图 + 取系统图标，
        // 产生 NSImage/NSAttributedString 临时对象，成批渲染时显式 drain
        return autoreleasepool {
            ArchiveEntryRowView(entry: model.visibleEntries[row])
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let model else { return }
        let list = model.visibleEntries
        let selected = Set(tableView.selectedRowIndexes.compactMap { $0 < list.count ? list[$0].path : nil })
        if selected != model.selection {
            model.selection = selected
        }
    }

    // v127（ArcZip P0）：每行一个文件承诺；拖选中行 → 系统自动带上全部选中行 = 多选拖出
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let model, row < model.visibleEntries.count else { return nil }
        return ArchiveFilePromiseDelegate.makeProvider(archiveURL: model.url,
                                                       entry: model.visibleEntries[row])
    }
}

// MARK: - 行视图（图标 + 加密锁 + 名字 + 辅助标 + 大小 + 压缩率）

final class ArchiveEntryRowView: NSView {

    // v129（内存）：lock/unsafe 两个 SF Symbol 静态缓存——每行 init 都新建
    // NSImage(systemSymbolName:)（滚动/reload 时 N 行 ×2 次符号解码，
    // CoreSVG SVGAttribute/SVGPathCommand 就是这么被churn 出来的），
    // 符号内容恒定，一次解码全局复用。
    private static let lockIcon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "已加密")
    private static let unsafeIcon = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                            accessibilityDescription: "路径不安全")

    private let iconView = NSImageView()
    private let lockView = NSImageView()
    // v127 接线（arch-engine P2-3）：不安全路径（../ 穿越 / 绝对路径 / 设备名）警告图标
    private let unsafeView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let auxLabel = NSTextField(labelWithString: "辅助")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let ratioLabel = NSTextField(labelWithString: "")

    init(entry: ArchiveEntry) {
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = ArchiveFileIcon.icon(for: entry)

        lockView.image = Self.lockIcon
        lockView.contentTintColor = .systemOrange
        lockView.isHidden = !entry.isEncrypted

        unsafeView.image = Self.unsafeIcon
        unsafeView.contentTintColor = .systemOrange
        unsafeView.isHidden = !entry.isUnsafe
        unsafeView.toolTip = "路径不安全（../ 穿越 / 绝对路径 / 设备名）。穿越与绝对路径解压时拦截跳过，设备名仅警告（v127.1）"

        nameLabel.stringValue = entry.path
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        auxLabel.font = .systemFont(ofSize: 8)
        auxLabel.textColor = .tertiaryLabelColor
        auxLabel.isHidden = !ArchiveCore.isAuxiliary(entry.path)

        sizeLabel.stringValue = entry.sizeText
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right

        ratioLabel.stringValue = entry.ratioText
        ratioLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        ratioLabel.textColor = .tertiaryLabelColor
        ratioLabel.alignment = .right

        let stack = NSStackView(views: [iconView, lockView, unsafeView, nameLabel, auxLabel,
                                       sizeLabel, ratioLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            lockView.widthAnchor.constraint(equalToConstant: 10),
            unsafeView.widthAnchor.constraint(equalToConstant: 10),
            sizeLabel.widthAnchor.constraint(equalToConstant: 64),
            ratioLabel.widthAnchor.constraint(equalToConstant: 48)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
}
