import AppKit
import Foundation
import SwiftUI

// MARK: - AI 摘要执行协调器（05 号规格 1.1 / B9）

public enum ClipboardSummaryError: LocalizedError {
    case llmUnavailable
    case emptyContent
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .llmUnavailable: return "未注入 LLM 服务（AI 模块未启用）"
        case .emptyContent: return "条目内容为空"
        case .alreadyRunning: return "摘要任务正在进行"
        }
    }
}

/// AI 摘要执行：按条目串行去重（同一条目并发点击只跑一次），
/// LLM 能力通过 `ServiceLocator.llmService` 获取——未注入时 UI 层直接禁用菜单项。
public final class ClipboardSummaryExecutionCoordinator {

    public static let shared = ClipboardSummaryExecutionCoordinator()

    private let lock = NSLock()
    private var running: Set<String> = []

    private init() {}

    public var isAvailable: Bool { ServiceLocator.llmService != nil }

    // NSLock.lock()/unlock() 在 async 上下文中被标记为不可用（Swift 6 下是 error）。
    // 这里把加解锁收进同步私有方法，async 函数只调用它们，既保留串行去重语义又消除警告。
    private func beginRun(dedupeKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running.contains(dedupeKey) else { return false }
        running.insert(dedupeKey)
        return true
    }

    private func endRun(dedupeKey: String) {
        lock.lock(); defer { lock.unlock() }
        running.remove(dedupeKey)
    }

    /// 生成摘要文本（不落库）
    public func summarize(_ item: ClipboardItem, systemPrompt: String? = nil) async throws -> String {
        guard let service = ServiceLocator.llmService else { throw ClipboardSummaryError.llmUnavailable }
        let source = ClipboardManager.shared.fullText(for: item)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipboardSummaryError.emptyContent }

        guard beginRun(dedupeKey: item.dedupeKey) else { throw ClipboardSummaryError.alreadyRunning }
        defer { endRun(dedupeKey: item.dedupeKey) }

        let system = systemPrompt ?? "你是一个简洁的中文摘要助手，只输出摘要本身，不要加标题或解释。"
        let clipped = String(source.prefix(8000))
        let prompt = "请为以下内容生成不超过 120 字的中文摘要：\n\n\(clipped)"
        let result = try await service.complete(prompt: prompt, system: system, model: nil)
        // 注：ai_request_count 由 LLMService.send 统一计数（complete 内部走 send），此处不重复 bump
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 摘要结果以工具生成条目的形式回流到剪贴板历史（与原作行为一致）
    @discardableResult
    public func summarizeAndWriteBack(_ item: ClipboardItem) async throws -> ClipboardItem {
        do {
            let summary = try await summarize(item)
            return ClipboardManager.shared.ingestToolOutput(text: summary,
                                                            sourceToolKeyword: "AI摘要",
                                                            analyticsId: item.dedupeKey)
        } catch {
            Toast.show("摘要失败：\(error.localizedDescription)", icon: "exclamationmark.triangle", isWarning: true)
            throw error
        }
    }
}
