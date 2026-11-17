import AppKit
import Foundation

// MARK: - 编辑文本视图（05 号规格 1.5：ClipboardItemEditTextView）

/// 纯文本编辑视图：关闭富文本/链接检测，避免粘贴时带入样式与链接属性
public final class ClipboardItemEditTextView: NSTextView {

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        allowsUndo = true
        font = NSFont.systemFont(ofSize: 13)
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainerInset = NSSize(width: 6, height: 8)
        autoresizingMask = [.width]
    }
}

// MARK: - 编辑窗控制器（05 号规格 B7：独立 NSWindow）

/// 独立编辑窗口：编辑 content / alias_title，保存回写数据库。
public final class ClipboardItemEditWindowController: NSWindowController, NSWindowDelegate {

    public private(set) var item: ClipboardItem
    private let aliasField = NSTextField()
    private let textView = ClipboardItemEditTextView()
    private let storage = ClipboardManager.shared

    // MARK: 构建

    public init(item: ClipboardItem) {
        self.item = item
        let initialContent = ClipboardManager.shared.fullText(for: item)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered,
                             defer: false)
        panel.title = "编辑条目"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildLayout(initialContent: initialContent)
        panel.applyOfficialChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现（编辑窗走代码构建）") }

    private func buildLayout(initialContent: String) {
        guard let window, let contentView = window.contentView else { return }

        let aliasLabel = NSTextField(labelWithString: "重命名标题")
        aliasLabel.frame = NSRect(x: 20, y: 378, width: 120, height: 18)
        aliasLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        aliasLabel.textColor = .secondaryLabelColor

        aliasField.frame = NSRect(x: 20, y: 348, width: 520, height: 24)
        aliasField.placeholderString = "留空则显示内容摘要"
        aliasField.stringValue = item.aliasTitle ?? ""
        aliasField.autoresizingMask = [.width]

        let contentLabel = NSTextField(labelWithString: "内容")
        contentLabel.frame = NSRect(x: 20, y: 318, width: 120, height: 18)
        contentLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        contentLabel.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 62, width: 520, height: 250))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 250)
        textView.string = initialContent
        scroll.documentView = textView

        let statLabel = NSTextField(labelWithString: Self.statText(item))
        statLabel.frame = NSRect(x: 20, y: 34, width: 320, height: 16)
        statLabel.font = NSFont.systemFont(ofSize: 11)
        statLabel.textColor = .tertiaryLabelColor

        let cancel = NSButton(frame: NSRect(x: 372, y: 20, width: 88, height: 32))
        cancel.title = "取消"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelTapped(_:))
        cancel.autoresizingMask = [.minXMargin]

        let save = NSButton(frame: NSRect(x: 468, y: 20, width: 88, height: 32))
        save.title = "保存"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.target = self
        save.action = #selector(saveTapped(_:))
        save.autoresizingMask = [.minXMargin]

        contentView.addSubview(aliasLabel)
        contentView.addSubview(aliasField)
        contentView.addSubview(contentLabel)
        contentView.addSubview(scroll)
        contentView.addSubview(statLabel)
        contentView.addSubview(cancel)
        contentView.addSubview(save)
    }

    private static func statText(_ item: ClipboardItem) -> String {
        var parts = [item.type.rawValue]
        if let count = item.fullTextCharCount { parts.append("\(count) 字符") }
        else if let content = item.content { parts.append("\(content.count) 字符") }
        if let lines = item.fullTextLineCount { parts.append("\(lines) 行") }
        if let app = item.sourceApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    // MARK: 展示

    public func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // v198：从触发点（面板编辑按钮）展开整块编辑窗
        if let w = window { WindowReveal.playInFromMouse(on: w) }
    }

    // MARK: 动作

    @objc private func saveTapped(_ sender: NSButton) {
        let content = textView.string
        let aliasText = aliasField.stringValue
        let alias = aliasText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : aliasText
        storage.saveContent(dedupeKey: item.dedupeKey, newContent: content, aliasTitle: alias) { [self] updated in
            guard let updated else {
                Toast.show("保存失败", icon: "exclamationmark.triangle")
                return
            }
            item = updated
            if textView.string == content, aliasField.stringValue == aliasText {
                close()
            }
        }
    }

    @objc private func cancelTapped(_ sender: NSButton) {
        close()
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        ClipboardItemEditWindowRecord.shared.remove(dedupeKey: item.dedupeKey)
    }
}

// MARK: - 打开中的编辑窗登记表（05 号规格 1.5：ClipboardItemEditWindowRecord）

/// 保证同一条目只有一个编辑窗：重复触发时把已有窗口提到前台
public final class ClipboardItemEditWindowRecord {

    public static let shared = ClipboardItemEditWindowRecord()

    private let lock = NSLock()
    private var controllers: [String: ClipboardItemEditWindowController] = [:]

    private init() {}

    public static func open(for item: ClipboardItem) {
        let shared = Self.shared
        shared.lock.lock()
        if let existing = shared.controllers[item.dedupeKey] {
            shared.lock.unlock()
            existing.show()
            return
        }
        let controller = ClipboardItemEditWindowController(item: item)
        shared.controllers[item.dedupeKey] = controller
        shared.lock.unlock()
        controller.show()
    }

    func remove(dedupeKey: String) {
        lock.lock(); defer { lock.unlock() }
        controllers.removeValue(forKey: dedupeKey)
    }
}
