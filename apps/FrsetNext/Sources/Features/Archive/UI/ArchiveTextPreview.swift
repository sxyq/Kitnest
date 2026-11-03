import AppKit
import SwiftUI

// MARK: - 归档右栏的文本预览（v181）
//
// 用户需求：「压缩包里的 TXT / Markdown / JSON，预览要跟剪贴板那个文件预览一样；
// Markdown 要自动渲染成浏览器那样的排版界面」。
//
// 因此这里**不自己实现渲染**，直接复用剪贴板预览那一套组件（同一口径，改一处两边一致）：
//   · Markdown → `MarkdownFilePreviewBody`（标题/列表/表格/代码块排版 + 左侧目录）
//   · JSON     → `JSONInspectorView`（树形/表格/卡片/原始，默认表格或树）
//   · 代码     → `PreviewTextViewRepresentable` + `renderCodeBody`（带行号标尺）
//   · 纯文本   → `PreviewTextViewRepresentable`（系统字体，可选中复制）
//
// 归档可能是可编辑的（打开时不是只读），所以额外给一个「预览 / 编辑」开关：
// 默认预览（与剪贴板一致），要改内容时切到编辑态，编辑态仍是原来的纯文本编辑器。

// MARK: 文本分态

enum ArchiveTextKind {
    case markdown, json, code, plain

    var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .json:     return "JSON"
        case .code:     return "代码"
        case .plain:    return "纯文本"
        }
    }

    var symbol: String {
        switch self {
        case .markdown: return "text.book.closed"
        case .json:     return "curlybraces"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .plain:    return "doc.plaintext"
        }
    }

    /// 先按扩展名判（`.md` / `.json` / `.swift` 这类明确意图优先），
    /// 扩展名不认识时再退回剪贴板那条启发式链（JSON → Markdown → 代码 → 纯文本）。
    static func detect(name: String, text: String) -> ArchiveTextKind {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown", "mkd", "mdx":
            return .markdown
        case "json", "jsonl", "geojson", "ipynb":
            return .json
        case "swift", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs",
             "java", "kt", "kts", "c", "h", "m", "mm", "cpp", "cc", "hpp", "cs",
             "php", "sh", "bash", "zsh", "fish", "sql", "css", "scss", "html", "htm",
             "xml", "yml", "yaml", "toml", "ini", "conf", "gradle", "plist", "diff", "patch":
            return .code
        default:
            break
        }
        switch PreviewPopoverContentModel.classifyRawText(text) {
        case .json:     return .json
        case .markdown: return .markdown
        case .code:     return .code
        default:        return .plain
        }
    }
}

// MARK: 预览面板

struct ArchiveTextPreview: View {
    /// 归档里的原始文本（用于判断「有没有改过」）
    let text: String
    let entryName: String
    /// 归档可写时才给「编辑」开关
    let editable: Bool
    /// 正在编辑的内容（外部 @Published draftText）
    @Binding var draft: String
    let dirty: Bool
    /// 滚动位置记忆键（Markdown 用；同一归档同一路径复用）
    let restoreKey: String
    /// 编辑内容变化（外部据此算 dirty）
    let onEdit: (String) -> Void

    @Stored private var editing = false

    private var kind: ArchiveTextKind { .detect(name: entryName, text: draft) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editing, editable {
                editor
            } else {
                rendered
            }
        }
        // 换条目时回到预览态（否则下一条还是编辑框，容易误改）
        .onChange(of: entryName) { _ in editing = false }
    }

    // MARK: 顶栏（类型 + 预览/编辑 + 保存状态）

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(kind.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("·").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            Text(entryName)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if dirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .help("有未保存的修改")
            }
            if editable {
                modeSwitch
                    // 窄窗口下优先压缩文件名，别把「预览/编辑」挤成省略号
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    /// 「预览 / 编辑」胶囊分段——与截图编辑器的分段同一套观感（选中项强调色浅底）
    private var modeSwitch: some View {
        HStack(spacing: 1) {
            modeItem("预览", active: !editing) { editing = false }
            modeItem("编辑", active: editing) { editing = true }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Theme.cardFill))
    }

    private func modeItem(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.accent : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background {
                    if active {
                        Capsule(style: .continuous).fill(Theme.accent.opacity(0.14))
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    // MARK: 三种正文

    @ViewBuilder private var rendered: some View {
        switch kind {
        case .markdown:
            // 右栏被挤窄时（目录 180pt 会把正文压成细缝）自动收掉目录
            GeometryReader { geo in
                MarkdownFilePreviewBody(text: draft, restoreKey: restoreKey,
                                        showsTOC: geo.size.width >= 620)
            }
        case .json:
            JSONInspectorView(text: draft)
        case .code:
            PreviewTextViewRepresentable(
                attributedText: PreviewMarkdownRenderer.renderCodeBody(
                    lang: PreviewMarkdownRenderer.detectLanguage(draft), code: draft),
                monospaced: true,
                showsLineNumbers: true)
        case .plain:
            PreviewTextViewRepresentable(attributedText: plainAttributed(draft))
        }
    }

    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 11.5, design: .monospaced))
            .padding(6)
            .onChange(of: draft) { new in onEdit(new) }
    }

    private func plainAttributed(_ string: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }
}
