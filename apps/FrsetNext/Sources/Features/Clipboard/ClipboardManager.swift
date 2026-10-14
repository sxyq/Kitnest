import AppKit
import CoreGraphics
import Foundation

// MARK: - 偏好键扩展（键名沿用原作 clipboard.* / floatingClipboard.* 风格）

public extension Preferences.Keys {
    /// 复制后自动粘贴（需辅助功能权限，**默认关闭**）
    static let clipboardAutoPaste = "clipboard.autoPaste"
    /// 是否启用 CGEventTap 复制动作感知（权限不足自动退化为轮询）
    static let clipboardEventTapEnabled = "clipboard.eventTapEnabled"
    /// 浮动窗是否显示
    static let floatingVisible = "floatingClipboard.visible"
    /// 浮动窗是否钉住（始终置顶）
    static let floatingPinned = "floatingClipboard.pinned"
}

// MARK: - 列表过滤

public enum ClipboardFilterKind: String, CaseIterable, Identifiable, Sendable {
    case all, text, richtext, image, file, url, note

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .richtext: return "富文本"
        case .image: return "图片"
        case .file: return "文件"
        case .url: return "链接"
        case .note: return "笔记"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .text: return "doc.plaintext"
        case .richtext: return "doc.richtext"
        case .image: return "photo"
        case .file: return "doc"
        case .url: return "link"
        case .note: return "note.text"
        }
    }

    /// 映射为 SQL 条件：type 过滤 or 笔记位
    public var itemType: ClipboardItemType? {
        switch self {
        case .all, .note: return nil
        case .text: return .text
        case .richtext: return .richtext
        case .image: return .image
        case .file: return .file
        case .url: return .url
        }
    }
}

// MARK: - 核心协调器（05 号规格 1.1：ClipboardManager）

/// 剪贴板总管：捕获 → 去重 → 入库 → 列表供给 → 清理。
/// 线程模型：
/// - `queue`（串行 utility）：一切 SQLite / 文件 IO，避免阻塞主线程与并发写冲突；
/// - 主线程：NSPasteboard 读取（AppKit 要求）+ ObservableObject 发布。
public final class ClipboardManager: ObservableObject {

    public static let shared = ClipboardManager()

    /// 条目变化时广播（浮动窗等非 SwiftUI 消费者使用）
    public static let itemsDidChangeNotification = Notification.Name("FrsetNext.Clipboard.itemsDidChange")

    // MARK: 常量

    /// 轮询间隔（changeCount 兜底方案）
    public static let pollInterval: TimeInterval = 0.5
    /// 主列表分页大小
    public static let pageSize: Int = ClipboardRepository.defaultPageSize
    /// 长文本落盘阈值：超过 64KB 写 texts/，避免大字符串常驻数据库与内存
    public static let inlineTextByteLimit: Int = 64 * 1024
    /// 超阈值时内联保留的预览长度
    public static let inlinePreviewLength: Int = 4000

    // MARK: 状态

    @Published public private(set) var items: [ClipboardItem] = []
    @Published public var searchText: String = "" { didSet { reload(reset: true) } }
    @Published public var filter: ClipboardFilterKind = .all { didSet { reload(reset: true) } }
    /// 按标签过滤（05 号规格 B6）；nil = 不过滤
    @Published public var tagFilterID: String? = nil { didSet { reload(reset: true) } }
    @Published public private(set) var isLoadingMore: Bool = false

    private let reader = ClipboardPasteboardReader()
    private let repository = ClipboardRepository.shared
    private let tagStore = TagStore.shared
    private let preferences = Preferences.shared
    private let queue = DispatchQueue(label: "com.frsetnext.clipboard.persist", qos: .utility)

    private var pollTimer: Timer?
    private var eventMonitor: EventMonitor?
    private var lastChangeCount: Int = -1
    private var currentPage: Int = 0
    private var isIngesting = false

    private init() {}

    // MARK: 启停

    public func start() {
        lastChangeCount = reader.currentChangeCount
        if pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        // 事件监听是增强项：开启失败（无辅助功能权限）不影响主流程
        let monitor = EventMonitor(enabled: { Preferences.shared.value(Preferences.Keys.clipboardEventTapEnabled, default: false) },
                                   onCopyDetected: { [weak self] in
            // 复制快捷键触发时粘贴板尚未落写，稍作延迟读取
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.ingest() }
        })
        eventMonitor = monitor
        if !monitor.start() {
            Log.info("clipboard", "使用轮询捕获（\(Self.pollInterval)s changeCount）")
        }
        tagStore.refresh()
        reload(reset: true)
        ClipboardHistoryRetentionPruneScheduler.shared.start()
        ClipboardStoragePruneScheduler.shared.start()
        Log.info("clipboard", "ClipboardManager 已启动")
    }

    /// 设置里改动"是否启用按键监听"后重建监听
    public func reloadEventMonitor() {
        eventMonitor?.stop()
        eventMonitor = nil
        if preferences.value(Preferences.Keys.clipboardEventTapEnabled, default: false) {
            let monitor = EventMonitor(enabled: { true }, onCopyDetected: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.ingest() }
            })
            eventMonitor = monitor
            _ = monitor.start()
        }
    }

    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        eventMonitor?.stop(); eventMonitor = nil
        ClipboardHistoryRetentionPruneScheduler.shared.stop()
        ClipboardStoragePruneScheduler.shared.stop()
    }

    private func poll() {
        let changeCount = reader.currentChangeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        ingest()
    }

    // MARK: 捕获管线

    /// 读取一次粘贴板并入库（含去重）。isIngesting 串行保护避免重入
    public func ingest() {
        guard !isIngesting else { return }
        isIngesting = true
        defer { isIngesting = false }
        guard let result = reader.read(), !result.isEmpty else { return }
        persist(result)
    }

    private func persist(_ result: ClipboardReadResult) {
        queue.async { [weak self] in
            guard let self else { return }
            self.writeToDatabase(result)
        }
    }

    /// 在持久化串行队列上执行：落盘 + 去重判定 + 入库
    private func writeToDatabase(_ result: ClipboardReadResult) {
        let key = ClipboardItem.makeDedupeKey(type: result.type,
                                              content: result.content,
                                              imageHash: result.imageHash)

        // 去重命中：更新时间戳 → 置顶
        if repository.exists(dedupeKey: key) {
            repository.touch(dedupeKey: key)
            Log.debug("clipboard", "去重置顶：\(key.prefix(24))")
            DispatchQueue.main.async { self.reload(reset: true) }
            return
        }

        var imagePath: String?
        var thumbnailPath: String?
        var richTextPath: String?
        var textPath: String?
        var charCount: Int?
        var lineCount: Int?
        var content = result.content
        // storage_bytes 口径：**实际落盘产物 + 数据库内联内容**，与 ClipboardStorageUsageProvider 的磁盘口径一致。
        // 注意不要用 result.approximateBytes 起步再叠加落盘字节，否则同一份内容会被计两次。
        var fileBytes = 0

        switch result.type {
        case .image:
            if let data = result.imageData, let stored = ClipboardImageStorage.store(imageData: data) {
                imagePath = stored.imagePath
                thumbnailPath = stored.thumbnailPath
                fileBytes += stored.byteCount
                fileBytes += ClipboardFileStore.fileSize(stored.thumbnailPath)
            } else {
                fileBytes += result.approximateBytes
            }
        case .richtext:
            if let rtf = result.richTextData {
                richTextPath = ClipboardRichTextStorage.write(rtf)
                fileBytes += rtf.count
            }
            // 富文本正文同样受长文本阈值约束：索引/搜素用 content，全量用 rich_text_path
            if let text = result.content, (text as NSString).length > Self.inlineTextByteLimit,
               let stored = ClipboardTextStorage.write(text) {
                textPath = stored.path
                charCount = (text as NSString).length
                lineCount = text.lineCount
                fileBytes += stored.bytes
                content = String(text.prefix(Self.inlinePreviewLength))
            }
            fileBytes += (content ?? "").utf8.count
        case .file, .text, .url:
            if let text = result.content, (text as NSString).length > Self.inlineTextByteLimit,
               let stored = ClipboardTextStorage.write(text) {
                textPath = stored.path
                charCount = (text as NSString).length
                lineCount = text.lineCount
                fileBytes += stored.bytes
                content = String(text.prefix(Self.inlinePreviewLength))
            }
            fileBytes += (content ?? "").utf8.count
        }

        let item = ClipboardItem(
            type: result.type,
            content: content,
            title: result.title,
            subtitle: result.subtitle,
            timestamp: Date(),
            sourceApp: result.sourceApp,
            imagePath: imagePath,
            thumbnailPath: thumbnailPath,
            textPath: textPath,
            richTextPath: richTextPath,
            fullTextCharCount: charCount,
            fullTextLineCount: lineCount,
            fileIconKey: result.fileIconKey,
            imageDimensionUnit: "px",
            storageBytes: fileBytes,
            dedupeKey: key
        )

        if repository.insert(item) {
            DatabaseManager.shared.bumpStat("capture_count")
            Log.debug("clipboard", "入库 [\(result.type.rawValue)] \(key.prefix(24))")
            // 图片条目：有 OCR 能力时后台补识别文本（无能力则静默跳过）
            if result.type == .image, let data = result.imageData { scheduleOCR(dedupeKey: key, imageData: data) }
        } else {
            // INSERT 失败且行已存在（并发窗口）→ 退化为置顶
            repository.touch(dedupeKey: key)
        }
        DispatchQueue.main.async { self.reload(reset: true) }
    }

    // MARK: 列表供给

    /// 重新加载当前页（search / filter / 新条目都会触发）
    /// - Parameter reset: true 回到第一页；false 仅刷新已加载区间（加载更多用）
    public func reload(reset: Bool = true) {
        let page = reset ? 0 : currentPage
        let target = ClipboardQuery(search: searchText,
                                    type: filter.itemType,
                                    noteOnly: (filter == .note),
                                    toolGeneratedOnly: false,
                                    tagID: tagFilterID,
                                    limit: Self.pageSize * max(1, page + 1),
                                    offset: 0)

        queue.async { [weak self] in
            guard let self else { return }
            let fetched = self.repository.fetch(target)
            DispatchQueue.main.async {
                self.items = fetched
                self.currentPage = page
                NotificationCenter.default.post(name: Self.itemsDidChangeNotification, object: nil)
            }
        }
    }

    public func loadMoreIfNeeded(currentItem: ClipboardItem) {
        guard items.count >= Self.pageSize * (currentPage + 1) else { return }
        guard let last = items.last, last.id == currentItem.id else { return }
        guard !isLoadingMore else { return }
        isLoadingMore = true
        currentPage += 1
        let target = ClipboardQuery(search: searchText,
                                    type: filter.itemType,
                                    noteOnly: (filter == .note),
                                    toolGeneratedOnly: false,
                                    tagID: tagFilterID,
                                    limit: Self.pageSize * (currentPage + 1),
                                    offset: 0)
        queue.async { [weak self] in
            guard let self else { return }
            let fetched = self.repository.fetch(target)
            DispatchQueue.main.async {
                self.items = fetched
                self.isLoadingMore = false
            }
        }
    }

    /// 浮动窗用：只要最近若干条（不受过滤/搜索影响）
    public func recentItems(limit: Int, completion: @escaping ([ClipboardItem]) -> Void) {
        var query = ClipboardQuery()
        query.limit = limit
        queue.async {
            let fetched = ClipboardRepository.shared.fetch(query)
            DispatchQueue.main.async { completion(fetched) }
        }
    }

    // MARK: 读取全文

    /// 完整文本：长文本走落盘文件，短文本直接返回内联 content
    public func fullText(for item: ClipboardItem) -> String {
        if let path = item.textPath, let text = ClipboardTextStorage.read(path) { return text }
        if let rich = item.richTextPath, let attributed = ClipboardRichTextStorage.read(rich) { return attributed.string }
        return item.content ?? ""
    }

    public func ocrText(for item: ClipboardItem) -> String? {
        ClipboardOCRTextStorage.read(dedupeKey: item.dedupeKey)
    }

    // MARK: 操作

    /// 写回系统粘贴板；可选自动粘贴（需辅助功能权限，默认关闭）
    public func copy(_ item: ClipboardItem, autoPaste: Bool? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .image:
            if let path = item.imagePath, let data = ClipboardFileStore.read(path) {
                let type: NSPasteboard.PasteboardType = path.hasSuffix(".png") ? .png : .tiff
                pasteboard.setData(data, forType: type)
            }
        case .file:
            let urls = (item.content ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }
        case .richtext:
            let richData = item.richTextPath.flatMap { ClipboardFileStore.read($0) }
            if let richData { pasteboard.setData(richData, forType: .rtf) }
            pasteboard.setString(fullText(for: item), forType: .string)
        case .text, .url:
            pasteboard.setString(fullText(for: item), forType: .string)
        }

        // 自己写回的粘贴板不应被再次捕获 → 同步 changeCount
        lastChangeCount = pasteboard.changeCount

        let shouldPaste = autoPaste ?? preferences.value(Preferences.Keys.clipboardAutoPaste, default: false)
        if shouldPaste { pasteToFrontmostApplication() }
    }

    /// 删除条目（含文件回收）
    public func delete(_ item: ClipboardItem) {
        queue.async { [weak self] in
            self?.repository.delete(dedupeKey: item.dedupeKey)
            DispatchQueue.main.async {
                self?.items.removeAll { $0.dedupeKey == item.dedupeKey }
                NotificationCenter.default.post(name: ClipboardManager.itemsDidChangeNotification, object: nil)
            }
        }
    }

    /// 重命名（写入 alias_title）
    public func rename(_ item: ClipboardItem, aliasTitle: String?) {
        queue.async { [weak self] in
            self?.repository.updateAliasTitle(dedupeKey: item.dedupeKey, aliasTitle: aliasTitle)
            DispatchQueue.main.async { self?.reload(reset: false) }
        }
    }

    /// 编辑窗保存：回写正文（超阈值重新落盘）与标题
    public func saveContent(dedupeKey: String, newContent: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let existing = self.repository.item(dedupeKey: dedupeKey) else { return }
            let length = (newContent as NSString).length
            let auxiliary = self.auxiliaryBytes(item: existing)
            if length > Self.inlineTextByteLimit {
                // 旧的落盘文件先标记，写入成功后再删除，避免中途失败丢数据
                if let stored = ClipboardTextStorage.write(newContent) {
                    if let old = existing.textPath, old != stored.path { ClipboardTextStorage.remove(old) }
                    let previewBytes = String(newContent.prefix(Self.inlinePreviewLength)).utf8.count
                    self.repository.updateContent(dedupeKey: dedupeKey,
                                                  content: String(newContent.prefix(Self.inlinePreviewLength)),
                                                  textPath: stored.path,
                                                  charCount: length,
                                                  lineCount: newContent.lineCount,
                                                  storageBytes: stored.bytes + previewBytes + auxiliary)
                }
            } else {
                if let old = existing.textPath { ClipboardTextStorage.remove(old) }
                self.repository.updateContent(dedupeKey: dedupeKey,
                                              content: newContent,
                                              textPath: nil,
                                              charCount: nil,
                                              lineCount: nil,
                                              storageBytes: newContent.utf8.count + auxiliary)
            }
            DispatchQueue.main.async { self.reload(reset: false) }
        }
    }

    /// 笔记标记（笔记 = 特殊剪贴板条目，走同一张表）
    public func setNote(_ item: ClipboardItem, isNote: Bool) {
        queue.async { [weak self] in
            self?.repository.updateFields(dedupeKey: item.dedupeKey, note: isNote)
            DispatchQueue.main.async { self?.reload(reset: false) }
        }
    }

    /// 工具回流：工具箱产物以 is_generated_by_tool=1 进历史（05 号规格 B10），供 10 号模块复用
    @discardableResult
    public func ingestToolOutput(text: String, sourceToolKeyword: String, analyticsId: String? = nil) -> ClipboardItem {
        let key = "tool:" + text.sha256
        if repository.exists(dedupeKey: key) {
            repository.touch(dedupeKey: key)
        } else {
            var content = text
            var textPath: String? = nil
            var charCount: Int? = nil
            var lineCount: Int? = nil
            var bytes = text.utf8.count
            if (text as NSString).length > Self.inlineTextByteLimit,
               let stored = ClipboardTextStorage.write(text) {
                textPath = stored.path
                charCount = (text as NSString).length
                lineCount = text.lineCount
                content = String(text.prefix(Self.inlinePreviewLength))
                bytes = stored.bytes + content.utf8.count
            }
            let item = ClipboardItem(type: .text,
                                     content: content,
                                     title: text.firstLineBrief,
                                     subtitle: "工具 · \(sourceToolKeyword)",
                                     isGeneratedByTool: true,
                                     sourceToolAnalyticsId: analyticsId,
                                     sourceToolKeyword: sourceToolKeyword,
                                     textPath: textPath,
                                     fullTextCharCount: charCount,
                                     fullTextLineCount: lineCount,
                                     storageBytes: bytes,
                                     dedupeKey: key)
            _ = repository.insert(item)
        }
        reload(reset: true)
        return ClipboardItem(type: .text, content: text, dedupeKey: key)
    }

    // MARK: 跨模块写入（App 总控事件接线：截图 / OCR 等外部产出）

    /// 通用写入：外部构造的读取结果走与粘贴板捕获完全相同的 去重 → 落盘 → 入库 管线
    public func insert(_ result: ClipboardReadResult) {
        guard !result.isEmpty else { return }
        queue.async { [weak self] in self?.writeToDatabase(result) }
    }

    /// 外部事件写入：图片（截图模块产出；data 为 PNG/TIFF 原始数据，指纹在内部补算）
    public func insertImage(data: Data, fileURL: URL? = nil, sourceApp: String? = nil) {
        guard !data.isEmpty else { return }
        insert(ClipboardPasteboardReader.imageResult(data: data, fileURL: fileURL, sourceApp: sourceApp))
    }

    /// 外部事件写入：文本（截图 OCR / 其他模块产出）
    public func insertText(_ text: String, sourceApp: String? = nil, subtitle: String? = nil) {
        insert(ClipboardPasteboardReader.textResult(text, sourceApp: sourceApp, subtitle: subtitle))
    }

    /// 全局搜索源：把剪贴板条目接入主面板搜索（总控经 SearchHookRegistry 注册时调用）。
    /// 返回模块自有 DTO，映射为搜索 UI 类型的职责留在总控，保持模块间零耦合。
    public func searchGlobal(query: String, limit: Int = 8) async -> [ClipboardGlobalSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 只捕获 Sendable 的仓储与队列，避免把非 Sendable 的 self 带进 @Sendable 闭包
        let repository = self.repository
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async {
                let fetched = repository.fetch(ClipboardQuery(search: trimmed, limit: limit))
                continuation.resume(returning: fetched.map { ClipboardGlobalSearchHit(item: $0) })
            }
        }
    }

    // MARK: 辅助

    /// 图片 / 富文本副文件的字节数（编辑正文时 storage_bytes 要保留这部分）
    private func auxiliaryBytes(item: ClipboardItem) -> Int {
        ClipboardFileStore.fileSize(item.imagePath)
            + ClipboardFileStore.fileSize(item.thumbnailPath)
            + ClipboardFileStore.fileSize(item.richTextPath)
    }

    /// 图片 OCR：遵循 IOC 约定，能力缺失时静默跳过
    private func scheduleOCR(dedupeKey: String, imageData: Data) {
        guard let service = ServiceLocator.ocrService else { return }
        Task.detached(priority: .utility) {
            do {
                let text = try await service.recognizeText(imageData: imageData)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                ClipboardOCRTextStorage.write(text, dedupeKey: dedupeKey)
                DatabaseManager.shared.bumpStat("ocr_count")
                Log.info("clipboard", "OCR 完成：\(text.count) 字符")
            } catch {
                Log.warn("clipboard", "OCR 失败: \(error)")
            }
        }
    }

    /// 自动粘贴：合成 Cmd+V 到前台应用（**需要辅助功能权限**，默认关闭）
    private func pasteToFrontmostApplication() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

// MARK: - 全局搜索结果条目

/// 剪贴板模块自有的搜索命中类型。
/// 主面板搜索 UI 的结果类型（SearchResultItem）属于工具箱模块，模块间不互相引用，
/// 由总控在接线时做一次性映射。
public struct ClipboardGlobalSearchHit {
    public let item: ClipboardItem
    public let title: String
    public let subtitle: String?

    public init(item: ClipboardItem) {
        self.item = item
        self.title = item.displayTitle
        self.subtitle = item.subtitle
    }
}

// MARK: - 行号统计

extension String {
    /// 行数（空串计 0 行）
    var lineCount: Int {
        if isEmpty { return 0 }
        var count = 0
        var index = startIndex
        while index < endIndex {
            if self[index] == "\n" { count += 1 }
            index = self.index(after: index)
        }
        return count + 1
    }
}
