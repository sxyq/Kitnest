import AppKit
import Foundation
import NaturalLanguage
import SwiftUI
import Translation

// MARK: - 本地翻译 Provider（Apple 系统自带，离线）
//
// 定位：**最后一道兜底**。优先级仍是「外部 API 优先」——
//   ① llm  大模型（配了 Key，质量最好）
//   ② qnw  360（免 Key，联网可用）
//   ③ apple 本机系统翻译（完全离线，无需 Key）
//
// 实现说明：Apple 的 `TranslationSession` 只能通过 SwiftUI 的 `.translationTask`
// 拿到，没有同步构造入口。这里挂一个 1×1、透明、鼠标穿透的隐藏窗口承载该修饰符，
// 把拿到的 session 交回给调用方；带 8 秒超时，拿不到就当失败（上层继续回落）。
//
// 语言包未下载（status = .supported 而非 .installed）时直接抛错，**不弹系统下载框**——
// 翻译这种动作不该突然弹窗要求下载几个 G 的语言包。

public enum AppleTranslationError: Error, LocalizedError {
    case unavailable          // 系统低于 macOS 15
    case languageNotInstalled // 语言包未下载
    case timedOut             // 拿不到 session
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .unavailable:          return "系统低于 macOS 15，无法使用本机翻译"
        case .languageNotInstalled: return "系统语言包未下载，无法离线翻译"
        case .timedOut:             return "本机翻译启动超时"
        case .emptyInput:           return "没有可翻译的文本"
        }
    }
}

public final class AppleTranslationProvider: TranslationProvider {
    public let id = "apple"
    public let displayName = "本机翻译（Apple 系统）"
    public let summary = "离线、免 Key；语言包需已在系统中下载"
    public let requiresCredential = false

    public init() {}

    public var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    public func translate(_ text: String, to targetLanguage: String?, mode: TranslationMode) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppleTranslationError.emptyInput }
        guard #available(macOS 15.0, *) else { throw AppleTranslationError.unavailable }

        let pair = Self.languagePair(for: trimmed, target: targetLanguage)
        guard await Self.isInstalled(pair) else { throw AppleTranslationError.languageNotInstalled }
        let session = try await AppleTranslationBridge.shared.session(from: pair.source, to: pair.target)
        let response = try await session.translate(trimmed)
        return response.targetText
    }

    public func translateLines(_ lines: [String], to targetLanguage: String?) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        guard #available(macOS 15.0, *) else { throw AppleTranslationError.unavailable }

        let joined = lines.joined(separator: "\n")
        let pair = Self.languagePair(for: joined, target: targetLanguage)
        guard await Self.isInstalled(pair) else { throw AppleTranslationError.languageNotInstalled }
        let session = try await AppleTranslationBridge.shared.session(from: pair.source, to: pair.target)

        // 空行不送翻译、原样回填，保证「行数严格对齐」
        var slotOf: [Int] = []
        var requests: [TranslationSession.Request] = []
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            slotOf.append(index)
            requests.append(.init(sourceText: line))
        }
        guard !requests.isEmpty else { return lines }
        let responses = try await session.translations(from: requests)
        guard responses.count == requests.count else { throw TranslationToolError.formatMismatch }
        var out = lines
        for (offset, index) in slotOf.enumerated() {
            out[index] = responses[offset].targetText
        }
        return out
    }

    // MARK: - 语言

    static func languagePair(for text: String,
                             target: String?) -> (source: Locale.Language, target: Locale.Language) {
        let targetCode = languageCode(for: target, fallbackSource: text)
        let sourceCode = detectSourceCode(for: text, targetCode: targetCode)
        return (Locale.Language(identifier: sourceCode), Locale.Language(identifier: targetCode))
    }

    /// 目标语言文案（"English" / "简体中文"…）→ BCP-47
    static func languageCode(for target: String?, fallbackSource text: String) -> String {
        guard let target, !target.isEmpty else {
            return TranslationToolSession.cjkRatio(text) > 0.25 ? "en" : "zh-Hans"
        }
        let t = target.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("english", "英文", "英语") { return "en" }
        if has("繁体", "繁體", "traditional") { return "zh-Hant" }
        if has("简体", "簡體", "中文", "chinese", "汉语", "漢語") { return "zh-Hans" }
        if has("日语", "日文", "japanese") { return "ja" }
        if has("韩语", "韩文", "korean") { return "ko" }
        if has("法语", "french") { return "fr" }
        if has("德语", "德文", "german") { return "de" }
        if has("西班牙", "spanish") { return "es" }
        if has("俄语", "俄文", "russian") { return "ru" }
        if has("葡萄牙", "portuguese") { return "pt" }
        if has("意大利", "italian") { return "it" }
        if has("泰语", "泰文", "thai") { return "th" }
        if has("阿拉伯", "arabic") { return "ar" }
        return TranslationToolSession.cjkRatio(text) > 0.25 ? "en" : "zh-Hans"
    }

    /// 源语言：系统识别器优先，识别不出来按字符集兜底
    static func detectSourceCode(for text: String, targetCode: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(400)))
        if let dominant = recognizer.dominantLanguage?.rawValue, !dominant.isEmpty,
           dominant != targetCode {
            return dominant
        }
        let isCJK = TranslationToolSession.cjkRatio(text) > 0.25
        let fallback = isCJK ? "zh-Hans" : "en"
        return fallback == targetCode ? (isCJK ? "en" : "zh-Hans") : fallback
    }

    @available(macOS 15.0, *)
    private static func isInstalled(_ pair: (source: Locale.Language, target: Locale.Language)) async -> Bool {
        let status = await LanguageAvailability().status(from: pair.source, to: pair.target)
        return status == .installed
    }
}

// MARK: - SwiftUI 桥（拿 TranslationSession）

@available(macOS 15.0, *)
@MainActor
private final class AppleTranslationBridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
}

@available(macOS 15.0, *)
private struct AppleTranslationBridgeView: View {
    @ObservedObject var model: AppleTranslationBridgeModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                await MainActor.run {
                    AppleTranslationBridge.shared.deliver(session)
                }
            }
    }
}

@available(macOS 15.0, *)
@MainActor
final class AppleTranslationBridge {
    static let shared = AppleTranslationBridge()

    private let model = AppleTranslationBridgeModel()
    private var window: NSWindow?
    private var pending: CheckedContinuation<TranslationSession, Error>?

    /// 拿一个配置好语言方向的 session（8 秒超时）
    func session(from source: Locale.Language, to target: Locale.Language) async throws -> TranslationSession {
        try await withCheckedThrowingContinuation { continuation in
            // 同一时刻只允许一个等待者（翻译是串行动作）
            if let previous = pending {
                pending = nil
                previous.resume(throwing: AppleTranslationError.timedOut)
            }
            pending = continuation
            ensureWindow()
            model.configuration = .init(source: source, target: target)

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, let waiter = self.pending else { return }
                self.pending = nil
                Log.warn("AI", "本机翻译：等待 session 超时")
                waiter.resume(throwing: AppleTranslationError.timedOut)
            }
        }
    }

    fileprivate func deliver(_ session: TranslationSession) {
        guard let waiter = pending else { return }
        pending = nil
        waiter.resume(returning: session)
    }

    /// 1×1 透明、鼠标穿透、不抢焦点的隐藏宿主窗口
    private func ensureWindow() {
        if window != nil { return }
        let hosting = NSHostingController(rootView: AppleTranslationBridgeView(model: model))
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.borderless]
        w.setContentSize(NSSize(width: 1, height: 1))
        w.isOpaque = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.level = .normal
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.orderFront(nil)
        window = w
        Log.debug("AI", "本机翻译桥已创建宿主窗口")
    }
}
