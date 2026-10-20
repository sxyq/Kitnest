import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - 偏好键扩展（键名沿用原作 clipboard.* / floatingClipboard.* 风格）

public extension Preferences.Keys {
    /// 复制后自动粘贴（需辅助功能权限，**默认关闭**）
    static let clipboardAutoPaste = "clipboard.autoPaste"
    /// 浮动窗是否显示
    static let floatingVisible = "floatingClipboard.visible"
    /// 浮动窗是否钉住（始终置顶）
    static let floatingPinned = "floatingClipboard.pinned"
}

// MARK: - 列表过滤（specs/14 §3.6：ClipboardFilterType 九项）

/// 过滤枚举 case 序 = 原作反射串序（0xaed3c0）：all, text, image, link, file, code, color, generated, note。
/// 与重建差异：删 .richtext（并入 text 检索）；.url 更名 .link；新增 .code / .color / .generated。
public enum ClipboardFilterKind: String, CaseIterable, Identifiable, Sendable {
    case all, text, image, link, file, code, color, generated, note

    public var id: String { rawValue }

    /// UI 文案（TODO(specs/18 L10n)：原作标签在 Localizable 资源、不在二进制切片内；
    /// 本轮直接用中文字面量，随 L10n 基建收口为键面英文句）
    public var label: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .image: return "图片"
        case .link: return "链接"
        case .file: return "文件"
        case .code: return "代码"
        case .color: return "颜色"
        case .generated: return "工具生成"
        case .note: return "笔记"
        }
    }

    public var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        case .link: return "link"
        case .file: return "doc"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .color: return "paintpalette"
        case .generated: return "wand.and.stars"
        case .note: return "note.text"
        }
    }

    /// 过滤项 → 查询条件映射（specs/14 §6）：
    /// - generated → is_generated_by_tool=1（工具回流）
    /// - color → 工具回流中 sourceToolKeyword=="colorpicker"（取色工具产物；原作按内容特征分类，
    ///   spec 14 §7 未探明分类规则，证据不足取来源映射，注释说明）
    /// - code → 文本子类的内容特征启发式（原作为内容特征分类，规则数值未探明）
    public var queryMapping: (type: ClipboardItemType?,
                              noteOnly: Bool,
                              toolGeneratedOnly: Bool,
                              generatedSourceKeyword: String?,
                              codeLikeOnly: Bool) {
        switch self {
        case .all:       return (nil, false, false, nil, false)
        case .text:      return (.text, false, false, nil, false)
        case .image:     return (.image, false, false, nil, false)
        case .link:      return (.url, false, false, nil, false)   // 原作 .link ↔ SQL type='url'
        case .file:      return (.file, false, false, nil, false)
        case .code:      return (.text, false, false, nil, true)
        case .color:     return (nil, false, true, "colorpicker", false)
        case .generated: return (nil, false, true, nil, false)
        case .note:      return (nil, true, false, nil, false)
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

    /// 捕获轮询常量（原作汇编立即数，specs/14 §3.1）
    public static let idlePollingInterval: TimeInterval = 1.0     // fmov 1.0 @0x1000f115c（闲置）
    public static let burstPollingInterval: TimeInterval = 0.5    // fmov 0.5 @0x1000f0f98（突发）
    public static let burstDuration: TimeInterval = 2.0           // addingTimeInterval(2.0) @0x1000f0f0c（突发窗口）
    public static let retryIntervalFloor: TimeInterval = 0.5      // fmaxnm 0.5 @0x1000ec8b8（重试下限钳制）
    /// 自写回声标记类型（__cstring `com.frset.selfwrite-token`，specs/14 F3）
    public static let selfWriteMarkerPasteboardType = NSPasteboard.PasteboardType("com.frset.selfwrite-token")
    /// 自写 token TTL（⬜ 原作数值未探明，spec 14 §7；取 5s 合理默认：过期后自写内容按新内容入库）
    public static let selfWriteTokenTTL: TimeInterval = 5.0
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
    /// 主列表是否位于顶部（首条目未滚出；specs/14 Q④ ClipboardListTopScrollTracker 回写）
    @Published public private(set) var isMainListAtTop: Bool = true

    /// 首条目滚出状态变化广播（mainClipboardFirstItemScrolledOutChanged，specs/14 §3.4）
    public static let mainClipboardFirstItemScrolledOutChanged =
        Notification.Name("FrsetNext.Clipboard.mainClipboardFirstItemScrolledOutChanged")

    private let reader = ClipboardPasteboardReader()
    private let repository = ClipboardRepository.shared
    private let tagStore = TagStore.shared
    private let preferences = Preferences.shared
    private let queue = DispatchQueue(label: "com.frsetnext.clipboard.persist", qos: .utility)

    // 捕获管线状态（ivar 面对齐原作 ClipboardManager 81 ivar 中的捕获族，specs/14 §3.1）
    private var pollTimer: Timer?
    private var retryTimer: Timer?
    private var currentPollingInterval: TimeInterval = idlePollingInterval   // 槽 0x988
    private var burstUntil: Date?                                            // 槽 0x990
    private var lastChangeCount: Int = -1                                    // 槽 0x930
    private var lastSelfWriteChangeCount: Int = -1
    private var lastSelfWriteToken: String?
    private var lastSelfWriteExpiresAt: Date = .distantPast
    private var currentPage: Int = 0
    private var isIngesting = false

    private init() {}

    // MARK: 启停

    /// 暂停记录剪贴板（官方菜单项「暂停记录剪贴板」，原版 0x1000e9e34 处 Toggle）。
    /// 暂停期间轮询仍跑（保持 changeCount 同步），但跳过 ingest——恢复后
    /// **不回补**暂停期间的最后一次内容（与原版一致）。
    public var isRecordingPaused: Bool = false {
        didSet {
            guard oldValue != isRecordingPaused else { return }
            if isRecordingPaused {
                lastChangeCount = NSPasteboard.general.changeCount
            }
            NotificationCenter.default.post(name: Self.recordingPausedDidChangeNotification,
                                            object: self)
            Log.info("clipboard", isRecordingPaused ? "已暂停记录剪贴板" : "已恢复剪贴板记录")
        }
    }

    /// 暂停状态变化广播（齿轮菜单勾选态刷新用）
    public static let recordingPausedDidChangeNotification =
        Notification.Name("ClipboardManager.recordingPausedDidChange")

    public func start() {
        lastChangeCount = reader.currentChangeCount
        schedulePoll(interval: Self.idlePollingInterval)
        tagStore.refresh()
        reload(reset: true)
        ClipboardHistoryRetentionPruneScheduler.shared.start()
        ClipboardStoragePruneScheduler.shared.start()
        Log.info("clipboard", "ClipboardManager 已启动（自适应轮询 \(Self.idlePollingInterval)s / 突发 \(Self.burstPollingInterval)s）")
    }

    public func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        retryTimer?.invalidate(); retryTimer = nil
        ClipboardHistoryRetentionPruneScheduler.shared.stop()
        ClipboardStoragePruneScheduler.shared.stop()
    }

    // MARK: 双速率轮询（specs/14 Q①：无事件驱动捕获，纯自适应 Timer）

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollTick() {
        // 速率切换：突发窗口内 0.5s，窗口过期回 1.0s（仅在切换瞬间重建 Timer）
        let effective = (burstUntil ?? .distantPast) > Date()
            ? Self.burstPollingInterval : Self.idlePollingInterval
        if effective != currentPollingInterval {
            currentPollingInterval = effective
            schedulePoll(interval: effective)
        }
        poll()
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        // changeCount 双读比对（原作 0x10016cc40 防撕裂模式）：读取期间变化 → 重试下一拍
        let first = pasteboard.changeCount
        guard first == pasteboard.changeCount else {
            scheduleRetry()
            return
        }
        guard first != lastChangeCount else { return }
        // 暂停记录：只同步 changeCount，不 ingest（恢复后不回补暂停期间内容）
        guard !isRecordingPaused else {
            lastChangeCount = first
            return
        }
        // 自写回声抑制：粘贴板仍带本会话 selfwrite-token 标记且未过 TTL → 跳过；
        // TTL 过期后按新内容入库（spec 14 验收对照）；标记被外部覆盖（无 token/异 token）→ 正常捕获
        if first == lastSelfWriteChangeCount,
           let token = lastSelfWriteToken, Date() < lastSelfWriteExpiresAt,
           let marker = pasteboard.data(forType: Self.selfWriteMarkerPasteboardType),
           String(data: marker, encoding: .utf8) == token {
            lastChangeCount = first
            Log.debug("clipboard", "跳过自写回放（selfwrite-token 未过期）")
            return
        }
        lastChangeCount = first
        ingest()
    }

    /// 读取失败重试：一次性 Timer（repeats=false），间隔 ≥0.5s，.common 模式（specs/14 F2 @0x1000ec8b8）
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let interval = max(Self.retryIntervalFloor, currentPollingInterval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
        Log.debug("clipboard", "粘贴板读取失败，\(interval)s 后一次性重试")
    }

    // MARK: 捕获管线

    /// 读取一次粘贴板并入库（含去重）。isIngesting 串行保护避免重入；
    /// 捕获成功进入 0.5s 突发（持续 2.0s 窗口，specs/14 F1）
    public func ingest() {
        guard !isIngesting else { return }
        isIngesting = true
        defer { isIngesting = false }
        guard let result = reader.read() else {
            scheduleRetry()
            return
        }
        guard !result.isEmpty else { return }
        // 忽略应用（原版「忽略应用」隐私名单）：来源 App 在名单内 → 不采集。
        // 名单存 Preferences（bundle id 数组），设置 → 通用 → 忽略应用里管理。
        if let source = result.sourceApp,
           (Preferences.shared.value(Preferences.Keys.clipboardIgnoredApps, default: [String]()) as [String]).contains(source) {
            Log.info("clipboard", "忽略应用命中：\(source)，不采集")
            return
        }
        burstUntil = Date().addingTimeInterval(Self.burstDuration)
        currentPollingInterval = Self.burstPollingInterval
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

    /// 首条目滚出状态回写（ClipboardListTopScrollTracker.onFirstItemScrolledOutChange 桥接）
    public func updateFirstItemScrolledOut(_ scrolledOut: Bool) {
        let atTop = !scrolledOut
        guard isMainListAtTop != atTop else { return }
        isMainListAtTop = atTop
        NotificationCenter.default.post(name: Self.mainClipboardFirstItemScrolledOutChanged, object: nil)
    }

    /// 当前过滤态下的标准查询条件
    private func makeQuery(limit: Int) -> ClipboardQuery {
        let mapping = filter.queryMapping
        return ClipboardQuery(search: searchText,
                              type: mapping.type,
                              noteOnly: mapping.noteOnly,
                              toolGeneratedOnly: mapping.toolGeneratedOnly,
                              generatedSourceKeyword: mapping.generatedSourceKeyword,
                              codeLikeOnly: mapping.codeLikeOnly,
                              tagID: tagFilterID,
                              limit: limit,
                              offset: 0)
    }

    // MARK: 列表供给

    /// 重新加载当前页（search / filter / 新条目都会触发）
    /// - Parameter reset: true 回到第一页；false 仅刷新已加载区间（加载更多用）
    public func reload(reset: Bool = true) {
        let page = reset ? 0 : currentPage
        var target = makeQuery(limit: Self.pageSize * max(1, page + 1))
        target.offset = 0

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
        let target = makeQuery(limit: Self.pageSize * (currentPage + 1))
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

        // 自写回声抑制（specs/14 F3）：写回粘贴板时打 selfwrite-token 标记 + 记录 token/TTL，
        // 捕获循环据此跳过自写内容（TTL 过期前）
        let token = UUID().uuidString
        pasteboard.setData(token.data(using: .utf8) ?? Data(), forType: Self.selfWriteMarkerPasteboardType)
        lastSelfWriteToken = token
        lastSelfWriteExpiresAt = Date().addingTimeInterval(Self.selfWriteTokenTTL)
        lastSelfWriteChangeCount = pasteboard.changeCount
        // 自己写回的粘贴板不应被再次捕获 → 同步 changeCount
        lastChangeCount = pasteboard.changeCount
        // v84：单条复制埋点（面板列表 / 悬浮剪贴板 / 预览窗复制共用同一收口）
        StatisticsManager.shared.record(.historyCopy)
        Toast.show("已复制", icon: "checkmark.circle.fill")   // spec 13 §4：复制成功场景

        let shouldPaste = autoPaste ?? preferences.value(Preferences.Keys.clipboardAutoPaste, default: false)
        if shouldPaste {
            StatisticsManager.shared.record(.clipboardPaste)
            pasteToFrontmostApplication()
        }
    }

    // MARK: 暂缓的通知条场景（spec 13 §4，等依赖能力落地后接）
    //
    // 下列三项经 Grep 复核（全工程零命中，除本注释外）：重建版确无对应业务分支，故本轮不接。
    // TODO(spec 13 §4)：
    // 1) 已复制 %d 项（0x1000f8070 / 0x1000fa6d4）——依赖主列表多选批量复制能力；
    //    批量入口落在 ClipboardTableHostView（表格多选），能力落地后在此处按批次数
    //    调用 `Toast.show("已复制 \(count) 项", icon: "checkmark.circle.fill")`。
    // 2) 已跳过 %d 项（0x1000f73a4）——依赖清理/去重流程的「跳过计数」返回值；
    //    清理主体在 ClipboardPruneSchedulers（当前只统计 removed，无 skipped），待其返回
    //    skipped 数后接 `Toast.show("已跳过 \(count) 项", icon: "checkmark.circle.fill")`。
    // 3) 已暂停/已恢复剪贴板记录（0x1000e9e34）——重建版无剪贴板「暂停记录」开关
    //    （isPaused 仅存在于 Capture/LongScreenshotSession，与本模块无关），
    //    待开关落地后在开关回调里接 paused/resumed 两条通知条。

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


    // MARK: 辅助

    /// 图片 / 富文本副文件的字节数（编辑正文时 storage_bytes 要保留这部分）
    private func auxiliaryBytes(item: ClipboardItem) -> Int {
        ClipboardFileStore.fileSize(item.imagePath)
            + ClipboardFileStore.fileSize(item.thumbnailPath)
            + ClipboardFileStore.fileSize(item.richTextPath)
    }

    /// 图片 OCR：遵循 IOC 约定，能力缺失时静默跳过
    private func scheduleOCR(dedupeKey: String, imageData: Data) {
        if !Preferences.shared.value("automaticScreenshotOCREnabled", default: true) { return }
        guard let service = ServiceLocator.ocrService else { return }
        Task.detached(priority: .utility) {
            do {
                let text = try await service.recognizeText(imageData: imageData)
                // spec 13 §4：未读取到文字场景（0x10000d45c，空识别结果分支）
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Toast.show("未读取到文字", icon: "exclamationmark.circle.fill")
                    return
                }
                ClipboardOCRTextStorage.write(text, dedupeKey: dedupeKey)
                DatabaseManager.shared.bumpStat("ocr_count")
                Log.info("clipboard", "OCR 完成：\(text.count) 字符")
            } catch {
                Toast.show("文字识别失败", icon: "exclamationmark.circle.fill")   // spec 13 §4：OCR 失败场景
                Log.warn("clipboard", "OCR 失败: \(error)")
            }
        }
    }

    /// 自动粘贴：合成 Cmd+V 到前台应用（**需要辅助功能权限**，默认关闭）
    private func pasteToFrontmostApplication() {
        // spec 13 §4：权限缺失场景（原作 Auto Paste Requires Accessibility）
        guard AXIsProcessTrusted() else {
            Toast.show("自动粘贴需要辅助功能权限", icon: "exclamationmark.circle.fill")
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        // spec 13 §4：粘贴失败场景（合成事件失败，原作 Pasted failed）
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            Toast.show("粘贴失败", icon: "exclamationmark.circle.fill")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        // spec 13 §4：粘贴完成场景（原作 Pasted completed）
        Toast.show("粘贴完成", icon: "checkmark.circle.fill")
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
