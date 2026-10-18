import AppKit
import Foundation

// MARK: - 编辑会话（05 号规格 1.5：ClipboardItemEditSession）

/// 一次编辑会话的可变状态。
/// 并发安全：**串行队列保护**（等价于 actor 的串行执行语义），
/// 这样 UI 线程（文本变更回调）与保存线程（写库）不会同时读写同一份快照，
/// 又不必把 NSWindow 的同步回调改成 `Task { await ... }`。
public final class ClipboardItemEditSession {

    public let dedupeKey: String
    private let queue = DispatchQueue(label: "com.frsetnext.clipboard.edit.session")
    private var originalContent: String
    private var currentContent: String
    private var currentAliasTitle: String?

    public init(dedupeKey: String, originalContent: String, aliasTitle: String?) {
        self.dedupeKey = dedupeKey
        self.originalContent = originalContent
        self.currentContent = originalContent
        self.currentAliasTitle = aliasTitle
    }

    public func setContent(_ content: String) { queue.async { self.currentContent = content } }
    public func setAliasTitle(_ title: String?) { queue.async { self.currentAliasTitle = title } }

    /// 快照（同步返回，供保存按钮 / 关闭前校验使用）
    public func snapshot() -> (content: String, aliasTitle: String?, isDirty: Bool) {
        queue.sync {
            (self.currentContent, self.currentAliasTitle,
             self.currentContent != self.originalContent || self.currentAliasTitle != nil)
        }
    }

    /// 标记已保存：以当前内容为新的基线
    public func markSaved(aliasTitle: String?) {
        queue.async { self.originalContent = self.currentContent; self.currentAliasTitle = aliasTitle }
    }
}

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

// MARK: - 编辑窗代理（05 号规格 1.5：ClipboardItemEditWindowDelegate）

public protocol ClipboardItemEditWindowDelegate: AnyObject {
    func editWindow(_ controller: ClipboardItemEditWindowController, didSave item: ClipboardItem)
    func editWindowDidCancel(_ controller: ClipboardItemEditWindowController)
}

// MARK: - 编辑窗控制器（05 号规格 B7：独立 NSWindow）

/// 独立编辑窗口：编辑 content / alias_title，保存回写数据库。
public final class ClipboardItemEditWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {

    public private(set) var item: ClipboardItem
    private let session: ClipboardItemEditSession
    private let aliasField = NSTextField()
    private let textView = ClipboardItemEditTextView()
    private let storage = ClipboardManager.shared

    public weak var delegate: ClipboardItemEditWindowDelegate?

    // MARK: 构建

    public init(item: ClipboardItem) {
        self.item = item
        let initialContent = ClipboardManager.shared.fullText(for: item)
        self.session = ClipboardItemEditSession(dedupeKey: item.dedupeKey,
                                                originalContent: initialContent,
                                                aliasTitle: item.aliasTitle)

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered,
                             defer: false)
        panel.title = "编辑条目"
        panel.applyOfficialChrome()   // 官方外观：灰底 + 透明标题栏
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildLayout(initialContent: initialContent)
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
        aliasField.target = self
        aliasField.action = #selector(aliasDidChange(_:))

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
        textView.delegate = self
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
    }

    // MARK: 动作

    @objc private func aliasDidChange(_ sender: NSTextField) {
        session.setAliasTitle(sender.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sender.stringValue)
    }

    @objc private func saveTapped(_ sender: NSButton) {
        let snapshot = session.snapshot()
        let alias = snapshot.aliasTitle
        let content = textView.string
        storage.saveContent(dedupeKey: item.dedupeKey, newContent: content)
        storage.rename(item, aliasTitle: alias)
        session.markSaved(aliasTitle: alias)

        var updated = item
        updated.aliasTitle = alias
        if (content as NSString).length <= ClipboardManager.inlineTextByteLimit { updated.content = content }
        item = updated

        delegate?.editWindow(self, didSave: updated)
        close()
    }

    @objc private func cancelTapped(_ sender: NSButton) {
        delegate?.editWindowDidCancel(self)
        close()
    }

    // MARK: NSTextDelegate

    /// 文本变更 → 会话增量更新（走会话串行队列，不阻塞输入）
    public func textDidChange(_ notification: Notification) {
        session.setContent(textView.string)
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        delegate = nil
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

    public static func open(for item: ClipboardItem, delegate: ClipboardItemEditWindowDelegate? = nil) {
        let shared = Self.shared
        shared.lock.lock()
        if let existing = shared.controllers[item.dedupeKey] {
            shared.lock.unlock()
            existing.show()
            return
        }
        let controller = ClipboardItemEditWindowController(item: item)
        controller.delegate = delegate
        shared.controllers[item.dedupeKey] = controller
        shared.lock.unlock()
        controller.show()
    }

    func remove(dedupeKey: String) {
        lock.lock(); defer { lock.unlock() }
        controllers.removeValue(forKey: dedupeKey)
    }
}
