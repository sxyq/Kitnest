import AppKit
import Foundation

// MARK: - 预览 Popover 偏好键扩展（键名沿用原作，specs/12 F2/F6）
//
// 本文件只落键定义与读取，设置行 UI（"Quick Preview"）归 specs/18 第二波实现。

public extension Preferences.Keys {
    /// 主面板悬停预览总开关（cstring @0x100b4deb0；defaults 实测无落盘值 → **默认开启**）
    static let hoverPreviewInMainWindowEnabled = "hoverPreviewInMainWindowEnabled"
    /// 悬浮剪贴板悬停预览总开关（cstring @0x100b4ded0；默认开启）
    static let hoverPreviewInFloatingClipboardEnabled = "hoverPreviewInFloatingClipboardEnabled"
    /// 键盘（空格）预览一次性提示是否已消费（defaults 实测 `clipboard_keyboard_preview_hint_consumed = 1`）
    static let clipboardKeyboardPreviewHintConsumed = "clipboard_keyboard_preview_hint_consumed"
}

// MARK: - 预览数据桥（与 Clipboard 模块解耦的编译期隔离层）
//
// specs/12 数据源是 ClipboardManager.fullText(for:)/ocrText(for:)（public）。
// 但契约 §1.3 禁止模块间编译期直接引用，且本模块 typecheck 只含 Features/Panel/，
// 故经此桥注入闭包：App 总控 / dev-clipboard 接线一行即可：
//     PreviewPopoverDataBridge.shared.fullTextProvider = { ClipboardManager.shared.fullText(for: $0) }
//     PreviewPopoverDataBridge.shared.ocrTextProvider = { ClipboardManager.shared.ocrText(for: $0) }
// 未接线时走内置后备（直接读落盘文件 / 内联 content），预览仍然可用。

public final class PreviewPopoverDataBridge {
    public static let shared = PreviewPopoverDataBridge()

    /// 全文提供者（接 ClipboardManager.fullText(for:)）
    public var fullTextProvider: ((ClipboardItem) -> String)?
    /// OCR 文本提供者（接 ClipboardManager.ocrText(for:)；图片条目预览的附加文本）
    public var ocrTextProvider: ((ClipboardItem) -> String?)?

    public init() {}

    /// 完整文本：优先走注入的提供者；否则后备直读 textPath / richTextPath / content
    public func fullText(for item: ClipboardItem) -> String {
        if let provider = fullTextProvider { return provider(item) }
        if let path = item.textPath, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return text
        }
        if let path = item.richTextPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil) {
            return attributed.string
        }
        return item.content ?? ""
    }

    /// 图片条目 OCR 文本（未接线时返回 nil，预览不显示 OCR 区块）
    public func ocrText(for item: ClipboardItem) -> String? {
        ocrTextProvider?(item)
    }

    /// v65 富文本保真渲染数据：条目的 RTF → NSAttributedString（保真字体/颜色/列表）。
    /// 相对路径经 ClipboardFileStore 解析（与 ClipboardRichTextStorage.read 同口径）。
    public func richTextAttributed(for item: ClipboardItem) -> NSAttributedString? {
        guard let relative = item.richTextPath else { return nil }
        // 后备路径解析：ClipboardFileStore 的根目录在 App 支持目录，桥内不知道根——
        // 经注入闭包（Clipboard 侧接线）最干净；未接线时按绝对路径兜底。
        if let provider = richTextProvider { return provider(item) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: relative)) else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    /// 富文本提供者（接 ClipboardRichTextStorage.read；App 总控接线）
    public var richTextProvider: ((ClipboardItem) -> NSAttributedString?)?
}
