import Foundation
import Translation

// MARK: - 翻译链路自检（v147：Provider 化之后）
//
// 不依赖鼠标的验收入口（`kitnest://translate`）：
//   ① 打印当前偏好、注册了哪些 Provider、实际生效的是谁；
//   ② 逐个 Provider 各翻一次（验证每个实现本身可用）；
//   ③ 再走 TranslationToolSession（验证自动回落链路）。
enum TranslationDiagnostics {

    static let sample = """
    系统设置里找不到这个选项，你可以按下面的路径操作：
    错误码 E1024：连接超时，请重试。
    支持 macOS 14+ / Apple Silicon
    """

    static func run() {
        let preference = AISettings.translationProviderPreference
        let all = TranslationProviderRegistry.shared.all
        let effective = TranslationProviderRegistry.shared.effectiveProvider(preference: preference)
        Log.info("AI", "翻译自检 开始：偏好=\(preference) 生效=\(effective?.displayName ?? "无") "
                 + "注册表=[\(all.map { "\($0.id)\($0.isAvailable ? "" : "(不可用)")" }.joined(separator: ","))]")

        Task {
            // ⓪ 本机翻译语言包状态（决定 apple provider 能不能用）
            if #available(macOS 15.0, *) {
                for (source, target) in [("zh-Hans", "en"), ("en", "zh-Hans")] {
                    let status = await LanguageAvailability().status(
                        from: Locale.Language(identifier: source),
                        to: Locale.Language(identifier: target))
                    Log.info("AI", "本机翻译语言包 \(source)→\(target)：\(label(status))")
                }
            }

            // ① 逐个 Provider 单测（不受偏好影响）
            for provider in all where provider.isAvailable {
                let started = CFAbsoluteTimeGetCurrent()
                do {
                    let text = try await provider.translate(sample, to: "English", mode: .document)
                    let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                    Log.info("AI", "翻译自检 [\(provider.id)] \(ms)ms → \(oneLine(text))")
                } catch {
                    Log.warn("AI", "翻译自检 [\(provider.id)] 失败：\(error.localizedDescription)")
                }
            }

            // ② 走会话（按用户偏好 + 自动回落）
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let text = try await TranslationToolSession.shared.translateDocument(sample)
                let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
                Log.info("AI", "翻译自检 会话(\(preference)) \(ms)ms → \(oneLine(text))")
            } catch {
                Log.warn("AI", "翻译自检 会话失败：\(error.localizedDescription)")
            }
        }
    }

    @available(macOS 15.0, *)
    private static func label(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed:   return "已下载（可用）"
        case .supported:   return "支持但未下载"
        case .unsupported: return "不支持"
        @unknown default:  return "未知"
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " / ")
    }
}
