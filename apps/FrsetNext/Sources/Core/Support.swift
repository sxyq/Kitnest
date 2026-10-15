import Foundation
import SwiftUI
import CommonCrypto

// MARK: - 日志（贴近原作：Sentry 已断，本地统一出口）

public enum Log {
    public enum Level: String { case debug, info, warn, error }
    public static var isVerbose = false
    public static func write(_ level: Level, _ tag: String, _ message: String) {
        guard level != .debug || isVerbose else { return }
        let line = "[\(level.rawValue.uppercased())][\(tag)] \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    public static func debug(_ tag: String, _ m: String) { write(.debug, tag, m) }
    public static func info(_ tag: String, _ m: String) { write(.info, tag, m) }
    public static func warn(_ tag: String, _ m: String) { write(.warn, tag, m) }
    public static func error(_ tag: String, _ m: String) { write(.error, tag, m) }
}

// MARK: - 模块注册（各功能模块自行实现 AppModule，由 App 层统一 start）

public protocol AppModule {
    static var identifier: String { get }
    static func start()
}

public enum ModuleRegistry {
    private static var lock = NSLock()
    private static var list: [any AppModule.Type] = []
    public static func register(_ m: any AppModule.Type) {
        lock.lock(); defer { lock.unlock() }
        guard !list.contains(where: { $0.identifier == m.identifier }) else { return }
        list.append(m)
        Log.info("Module", "registered: \(m.identifier)")
    }
    public static func startAll() {
        lock.lock(); let snapshot = list; lock.unlock()
        for m in snapshot {
            Log.info("Module", "start: \(m.identifier)")
            m.start()
        }
    }
}

// MARK: - 服务定位器（跨模块解耦：模块 A 只依赖协议，实现由模块 B 注入）

public protocol LLMServiceProtocol: AnyObject {
    /// 一次性补全
    func complete(prompt: String, system: String?, model: String?) async throws -> String
    /// 流式补全
    func stream(prompt: String, system: String?, model: String?) -> AsyncThrowingStream<String, Error>
}

public protocol OCRServiceProtocol: AnyObject {
    /// 返回识别出的整段文本
    func recognizeText(imageData: Data) async throws -> String
    /// 返回带坐标的片段（用于取词/翻译定位）
    func recognizeObservations(imageData: Data) async throws -> [OCRTextObservation]
}

public struct OCRTextObservation: Sendable {
    public let text: String
    public let boundingBox: CGRect   // 归一化坐标（左下原点）
    public init(text: String, boundingBox: CGRect) {
        self.text = text; self.boundingBox = boundingBox
    }
}

public enum ServiceLocator {
    /// internal（供 Core/Registry.swift 的 extension 复用同一把锁）
    static let lock = NSLock()
    private static var llm: LLMServiceProtocol?
    private static var ocr: OCRServiceProtocol?

    public static var llmService: LLMServiceProtocol? {
        get { lock.lock(); defer { lock.unlock() }; return llm }
        set { lock.lock(); defer { lock.unlock() }; llm = newValue }
    }
    public static var ocrService: OCRServiceProtocol? {
        get { lock.lock(); defer { lock.unlock() }; return ocr }
        set { lock.lock(); defer { lock.unlock() }; ocr = newValue }
    }
}

// MARK: - 主题（视觉对齐 Frset：毛玻璃 + 圆角 + SF 字体）

public enum Theme {
    public static let cornerRadius: CGFloat = 10
    public static let smallRadius: CGFloat = 6
    public static let panelWidth: CGFloat = 400
    public static let panelMaxHeight: CGFloat = 700
    public static let rowHeight: CGFloat = 56
    public static let thumbSize: CGFloat = 44

    public static let accent = Color.accentColor
    public static let secondaryText = Color.secondary
    public static let cardBackground = Color(NSColor.controlBackgroundColor).opacity(0.6)
    public static let separator = Color(NSColor.separatorColor).opacity(0.5)

    public static func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - 通用扩展

public extension Date {
    /// 相对时间文案（"刚刚" / "3分钟前" / 昨天具体时间）
    var relativeText: String {
        let interval = -timeIntervalSinceNow
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(self) ? "今天 HH:mm" : "M月d日 HH:mm"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: self)
    }
}

public extension String {
    /// SHA-256 十六进制摘要（小写）。
    ///
    /// 实现说明：此处曾为手写纯 Swift SHA-256（注释写"避免 CommonCrypto 链接问题"），
    /// 但消息调度字被 `& 0xffffffff` 掩成 32 位等缺陷，使长输入在剪贴板指纹路径
    /// （约 32KB）崩溃——实测崩溃报告 FrsetNext-2026-10-15-111300.ips：
    /// poll → ingest → read → fingerprint → String.sha256（自适应轮询每秒一次，故为间歇性崩溃）。
    /// 现统一走 CommonCrypto CC_SHA256（与 Features/AI/AICredentialJournal 同一实现），
    /// 已用标准向量（空串 / "abc" / 1MB 数据）对照 `shasum -a 256` 验证。
    var sha256: String { Data(utf8).sha256Hex }

    var truncatedForDisplay: String {
        var s = replacingOccurrences(of: "\n", with: " ")
        if s.count > 120 { s = String(s.prefix(120)) + "…" }
        return s
    }
}

public extension Data {
    /// SHA-256 十六进制摘要（小写）；空输入合法（e3b0c442…）。
    /// 逐字节摘要，供剪贴板指纹等热路径使用（CommonCrypto，单次调用 O(n) 无堆分配风暴）。
    var sha256Hex: String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 文件与目录

public enum AppDirectories {
    public static var base: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEBUG
        let dir = root.appendingPathComponent("FrsetNext-Dev", isDirectory: true)
        #else
        let dir = root.appendingPathComponent("FrsetNext", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    public static func sub(_ name: String) -> URL {
        let d = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
