import Foundation
import SwiftUI

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
    var sha256: String {
        // 纯 Swift 实现（避免 CommonCrypto 链接问题）
        var h: [UInt64] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let k: [UInt64] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
        ]
        var msg = Array(self.utf8)
        msg.append(0x80)
        while (msg.count % 64) != 56 { msg.append(0) }
        let bitLen = UInt64(self.utf8.count) * 8
        for i in stride(from: 56, through: 0, by: -8) { msg.append(UInt8((bitLen >> UInt64(i)) & 0xff)) }
        func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt64](repeating: 0, count: 64)
            for i in 0..<16 {
                w[i] = (0..<8).reduce(UInt64(0)) { $0 | (UInt64(msg[chunk + i * 8 + Int($1)]) << UInt64(56 - 8 * $1)) }
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = (w[i-16] &+ s0 &+ w[i-7] &+ s1) & 0xffffffff
            }
            var a = h
            for i in 0..<64 {
                let s1 = rotr(a[4], 6) ^ rotr(a[4], 11) ^ rotr(a[4], 25)
                let ch = (a[4] & a[5]) ^ ((~a[4]) & a[6])
                let t1 = (a[7] &+ s1 &+ ch &+ k[i] &+ w[i]) & 0xffffffff
                let s0 = rotr(a[0], 2) ^ rotr(a[0], 13) ^ rotr(a[0], 22)
                let maj = (a[0] & a[1]) ^ (a[0] & a[2]) ^ (a[1] & a[2])
                let t2 = (s0 &+ maj) & 0xffffffff
                a[7] = a[6]; a[6] = a[5]; a[5] = a[4]
                a[4] = (a[3] &+ t1) & 0xffffffff
                a[3] = a[2]; a[2] = a[1]; a[1] = a[0]
                a[0] = (t1 &+ t2) & 0xffffffff
            }
            for i in 0..<8 { h[i] = (h[i] &+ a[i]) & 0xffffffff }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    var truncatedForDisplay: String {
        var s = replacingOccurrences(of: "\n", with: " ")
        if s.count > 120 { s = String(s.prefix(120)) + "…" }
        return s
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
