import Foundation

// MARK: - AI 结果出站
//
// AI 模块**禁止**直接引用剪贴板模块的具体类型（契约 §1.3）。
// 摘要/润色/翻译产出的文本通过一个极简回调广播出去，由总控在 App 层接线到剪贴板：
//
//     AIEventBus.onResultProduced = { text in ClipboardStore.shared.addAIGenerated(text) }
//
// 未接线时退化为空操作（UI 只保留「复制」兜底），不会崩溃。

public enum AIEventBus {
    /// AI 产出的文本（已结束 streaming，参数为最终全文）
    public static var onResultProduced: ((String) -> Bool)?

    /// 便捷调用
    public static func emitResult(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return onResultProduced?(text) ?? false
    }
}
