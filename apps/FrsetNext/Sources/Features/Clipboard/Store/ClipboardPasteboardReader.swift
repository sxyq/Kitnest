import AppKit
import CoreGraphics
import Foundation
import ImageIO

// MARK: - 读取结果

/// 一次粘贴板读取的归一化结果（05 号规格 B1）
public struct ClipboardReadResult {
    public let type: ClipboardItemType
    public let content: String?
    public let title: String?
    public let subtitle: String?
    public let imageData: Data?
    public let richTextData: Data?
    public let fileURLs: [URL]
    public let sourceApp: String?
    public let imageHash: String?
    public let fileIconKey: String?

    public init(type: ClipboardItemType,
                content: String? = nil,
                title: String? = nil,
                subtitle: String? = nil,
                imageData: Data? = nil,
                richTextData: Data? = nil,
                fileURLs: [URL] = [],
                sourceApp: String? = nil,
                imageHash: String? = nil,
                fileIconKey: String? = nil) {
        self.type = type; self.content = content; self.title = title; self.subtitle = subtitle
        self.imageData = imageData; self.richTextData = richTextData; self.fileURLs = fileURLs
        self.sourceApp = sourceApp; self.imageHash = imageHash; self.fileIconKey = fileIconKey
    }

    /// 空负载判定：纯空白文本 / 空图数据 / 空文件列表都不入库
    public var isEmpty: Bool {
        switch type {
        case .image: return (imageData ?? Data()).isEmpty
        case .file:  return fileURLs.isEmpty
        default:     return (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 存储占用估算（用于 capacity 清理）
    public var approximateBytes: Int {
        switch type {
        case .image: return imageData?.count ?? 0
        case .file:  return fileURLs.reduce(0) { $0 + ($1.path.utf8.count) }
        case .richtext: return max(richTextData?.count ?? 0, (content ?? "").utf8.count)
        default:     return (content ?? "").utf8.count
        }
    }
}

// MARK: - 读取器

/// NSPasteboard 读取：多类型优先级 图片 > 文件 > 富文本 > 文本 > URL（05 号规格 B1）
public final class ClipboardPasteboardReader {

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var currentChangeCount: Int { pasteboard.changeCount }

    public func read() -> ClipboardReadResult? {
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        // 来源应用：bundle id 优先（与实机 source_app 字段一致），取不到退化为应用名
        let source = Self.frontmostAppIdentifier()

        if let r = readImage(types: types, source: source) { return r }
        if let r = readFiles(types: types, source: source) { return r }
        // v202：URL 优先于纯文本——复制链接时粘贴板几乎同时带 .string，
        // 旧顺序（文本 > URL）会把链接全部存成 text，「链接」分类永远空。
        if let r = readURL(types: types, source: source) { return r }
        if let r = readRichText(types: types, source: source) { return r }
        if let r = readText(types: types, source: source) { return r }
        return nil
    }

    // MARK: 优先级 1：图片

    private func readImage(types: [NSPasteboard.PasteboardType], source: String?) -> ClipboardReadResult? {
        var data: Data?
        if types.contains(.tiff) {
            data = pasteboard.data(forType: .tiff)
        }
        if data == nil, types.contains(.png) {
            data = pasteboard.data(forType: .png)
        }
        guard let imageData = data, !imageData.isEmpty else { return nil }

        let size = Self.imageSize(of: imageData)
        let subtitle: String?
        if size.width > 0, size.height > 0 {
            subtitle = String(format: "%.0f×%.0f 图片", size.width, size.height)
        } else {
            subtitle = "图片"
        }
        return ClipboardReadResult(type: .image,
                                   content: nil,
                                   title: "图片",
                                   subtitle: subtitle,
                                   imageData: imageData,
                                   sourceApp: source,
                                   imageHash: Self.fingerprint(imageData))
    }

    // MARK: 优先级 2：文件

    private func readFiles(types: [NSPasteboard.PasteboardType], source: String?) -> ClipboardReadResult? {
        var urls: [URL] = []
        if types.contains(.fileURL) || types.contains(.init("NSFilenamesPboardType")) {
            if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                urls = objects.filter { $0.isFileURL }
            }
            if urls.isEmpty,
               let legacy = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
                urls = legacy.map { URL(fileURLWithPath: $0) }
            }
        }
        guard !urls.isEmpty else { return nil }

        let paths = urls.map { $0.path }
        let content = paths.joined(separator: "\n")
        let names = urls.map { $0.lastPathComponent }
        let title = names.count == 1 ? names[0] : (names.prefix(3).joined(separator: "、") + (names.count > 3 ? " 等 \(names.count) 个文件" : ""))
        let subtitle = (urls.count > 1 ? "\(urls.count) 个文件 · " : "") + (urls.first?.deletingLastPathComponent().path ?? "")
        return ClipboardReadResult(type: .file,
                                   content: content,
                                   title: title,
                                   subtitle: subtitle,
                                   fileURLs: urls,
                                   sourceApp: source,
                                   fileIconKey: urls.first?.pathExtension.lowercased())
    }

    // MARK: 优先级 3：富文本

    private func readRichText(types: [NSPasteboard.PasteboardType], source: String?) -> ClipboardReadResult? {
        var richData = types.contains(.rtf) ? pasteboard.data(forType: .rtf) : nil
        if richData == nil, types.contains(.html) {
            if let htmlData = pasteboard.data(forType: .html) { richData = htmlData }
        }
        guard let data = richData, !data.isEmpty else { return nil }

        // 富文本同时带一份纯文本副本，作为 content / 搜索源
        let plain = pasteboard.string(forType: .string) ?? Self.plainText(from: data) ?? ""
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        return ClipboardReadResult(type: .richtext,
                                   content: plain,
                                   title: plain.firstLineBrief,
                                   subtitle: "富文本 · \(plain.count) 字符",
                                   richTextData: data,
                                   sourceApp: source)
    }

    // MARK: 优先级 4：纯文本

    private func readText(types: [NSPasteboard.PasteboardType], source: String?) -> ClipboardReadResult? {
        guard types.contains(.string), let text = pasteboard.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // v202：地址栏/聊天窗复制来的链接常常只有 .string（没有 .URL 类型）。
        // 整段就是一个链接时按 url 入库，避免「链接」分类漏收。
        if let url = Self.singleURL(from: trimmed) {
            return ClipboardReadResult(type: .url,
                                       content: trimmed,
                                       title: trimmed.firstLineBrief,
                                       subtitle: url.host,
                                       sourceApp: source)
        }
        return ClipboardReadResult(type: .text,
                                   content: text,
                                   title: trimmed.firstLineBrief,
                                   subtitle: source.map { "文本 · \($0)" } ?? "文本",
                                   sourceApp: source)
    }

    /// 整段文本是否恰好是一个 http(s)/www 链接（首尾无其他字符）
    private static func singleURL(from text: String) -> URL? {
        guard !text.contains("\n") else { return nil }
        let lowered = text.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("www.") else {
            return nil
        }
        let normalized = lowered.hasPrefix("www.") ? "https://" + text : text
        guard let url = URL(string: normalized), url.host != nil else { return nil }
        return url
    }

    // MARK: 优先级 5：URL

    private func readURL(types: [NSPasteboard.PasteboardType], source: String?) -> ClipboardReadResult? {
        guard types.contains(.URL), let urlString = pasteboard.string(forType: .URL),
              let url = URL(string: urlString), url.host != nil else { return nil }
        return ClipboardReadResult(type: .url,
                                   content: urlString,
                                   title: urlString.firstLineBrief,
                                   subtitle: url.host,
                                   sourceApp: source)
    }

    // MARK: 工具

    private static func frontmostAppIdentifier() -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier ?? app?.localizedName
    }

    private static func plainText(from richData: Data) -> String? {
        if let attributed = NSAttributedString(rtf: richData, documentAttributes: nil) { return attributed.string }
        if let attributed = try? NSAttributedString(data: richData,
                                                    options: [.documentType: NSAttributedString.DocumentType.html],
                                                    documentAttributes: nil) { return attributed.string }
        return nil
    }

    /// 图片尺寸（走 ImageIO 只读头信息，不解码全图）
    private static func imageSize(of data: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return .zero }
        return CGSize(width: w, height: h)
    }

    /// 图片/大数据指纹：用于去重键。对超长数据采样（长度 + 首 8KB + 尾 8KB 字节）后做 SHA-256。
    ///
    /// 实现说明：原实现先把头尾各 8KB 转成十六进制字符串再哈希，输入膨胀到约 32KB，
    /// 且当时走的是有缺陷的手写 SHA-256 —— 双开实测时于轮询热路径崩溃
    /// （FrsetNext-2026-10-15-111300.ips：`poll → ingest → read → fingerprint → String.sha256`）。
    /// 现直接对字节流摘要（Data.sha256Hex → CommonCrypto CC_SHA256），输入体积小两个数量级且实现可靠。
    public static func fingerprint(_ data: Data) -> String {
        var payload = Data()
        payload.reserveCapacity(16_400)
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(data.prefix(8192))
        if data.count > 16_384 { payload.append(data.suffix(8192)) }
        return payload.sha256Hex
    }

    // MARK: 外部事件写入的结果构造（截图 / OCR 等经 ClipboardManager 复用同一管线）

    /// 由原始图片数据构造图片结果。补算指纹，避免去重键退化为随机值（见 makeDedupeKey）
    public static func imageResult(data: Data,
                                   fileURL: URL? = nil,
                                   sourceApp: String? = nil,
                                   subtitle: String? = nil) -> ClipboardReadResult {
        let size = imageSize(of: data)
        let sizeText = (size.width > 0 && size.height > 0)
            ? String(format: "%.0f×%.0f 图片", size.width, size.height)
            : "图片"
        return ClipboardReadResult(type: .image,
                                   content: nil,
                                   title: fileURL?.lastPathComponent ?? "截图",
                                   subtitle: subtitle ?? sizeText,
                                   imageData: data,
                                   sourceApp: sourceApp,
                                   imageHash: fingerprint(data))
    }

    /// 由外部文本构造文本结果（标题/副标题规则与粘贴板读取保持一致）
    public static func textResult(_ text: String,
                                  sourceApp: String? = nil,
                                  subtitle: String? = nil) -> ClipboardReadResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClipboardReadResult(type: .text,
                                   content: text,
                                   title: trimmed.firstLineBrief,
                                   subtitle: subtitle ?? (sourceApp.map { "文本 · \($0)" } ?? "文本"),
                                   sourceApp: sourceApp)
    }
}

// MARK: - 辅助
// 说明：统一的 `firstLineBrief` 实现放在 ClipboardRepository.swift（全局 extension），这里不重复声明。
