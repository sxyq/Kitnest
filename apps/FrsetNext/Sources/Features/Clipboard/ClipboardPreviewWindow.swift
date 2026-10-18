import AppKit
import SwiftUI

// MARK: - 常驻预览窗（v53，用户需求 2026-10-19）
//
// 两种预览方式：
//   · hover  → 临时预览（NSPopover，鼠标移出即关、不可缩放）——沿用
//              MainPanelPreviewPopoverCoordinator，本文件不碰。
//   · 单击   → 本窗口：常驻、可拖动缩放、可切「编辑」改内容并保存。
//
// 版式：标题栏（类型图标 + 标题 + 时间/字数 + 预览|编辑 分段 + 复制）
//       → 预览态直接复用 PreviewPopoverContentView（Markdown/代码/JSON/图片/文件同款渲染）
//       → 编辑态为等宽 TextEditor + 保存/取消。

public final class ClipboardPreviewWindowController: NSWindowController, NSWindowDelegate {

    private var item: ClipboardItem

    public init(item: ClipboardItem) {
        self.item = item
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "预览"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 420, height: 320)
        // PanelController 据此识别"这是本 app 的常驻预览窗"——取得 key 时不收起主面板
        window.identifier = NSUserInterfaceItemIdentifier("frset.clipboardPreview")
        super.init(window: window)
        window.delegate = self
        installContent()
        window.applyOfficialChrome()   // 放在 contentView 就位之后：自绘关闭钮挂到新视图上
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现（预览窗走代码构建）") }

    private func installContent() {
        guard let window else { return }
        let host = NSHostingView(rootView: ClipboardPreviewWindowView(item: item))
        let bounds = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 720, height: 620)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.applyOfficialChrome()   // contentView 已替换 → 把圆形关闭钮重新挂上
    }

    /// 打开/切换条目。同一条目重复点击只前置窗口，不重建内容（保留缩放尺寸与编辑草稿）。
    public func show(item newItem: ClipboardItem, anchorView: NSView?) {
        let changed = newItem.id != item.id
        item = newItem
        if changed { installContent() }
        if window?.isVisible != true { place(anchorView: anchorView) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 位置：优先贴主面板左侧（顶边对齐被点行），放不下则右侧，最后居中；并夹在可见区内
    private func place(anchorView: NSView?) {
        guard let window else { return }
        let size = window.frame.size
        guard let screen = anchorView?.window?.screen ?? NSScreen.main else {
            window.center()
            return
        }
        let vf = screen.visibleFrame
        var origin: NSPoint
        if let av = anchorView, let host = av.window {
            let anchor = host.convertToScreen(av.convert(av.bounds, to: nil))
            let leftX = host.frame.minX - size.width - 12
            let rightX = host.frame.maxX + 12
            let x = leftX >= vf.minX + 8 ? leftX : rightX
            let y = anchor.maxY - size.height
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        window.setFrameOrigin(origin)
    }

    // MARK: NSWindowDelegate

    /// v65（用户反馈"点击预览关不掉"）：失焦即关——常驻窗此前只有标题栏关闭钮一条
    /// 退路。resign 后短暂复核：焦点去了其他 App（本 App 失活）→ 关闭；
    /// 焦点在本 App 内其他窗口（点主面板换条目/悬浮剪贴板）→ 保持「边看边换」。
    public func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let w = self.window, w.isVisible, !w.isKeyWindow else { return }
            if NSApp.isActive, NSApp.keyWindow != nil { return }
            w.performClose(nil)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        ClipboardPreviewWindowRecord.shared.clear(self)
    }
}

// MARK: - 打开中的预览窗登记（全局单窗：再点别的条目就地换内容）

public final class ClipboardPreviewWindowRecord {

    public static let shared = ClipboardPreviewWindowRecord()

    private var controller: ClipboardPreviewWindowController?

    private init() {}

    public static func open(for item: ClipboardItem, anchorView: NSView?) {
        let record = Self.shared
        if let existing = record.controller {
            existing.show(item: item, anchorView: anchorView)
            return
        }
        let controller = ClipboardPreviewWindowController(item: item)
        record.controller = controller
        controller.show(item: item, anchorView: anchorView)
    }

    /// v65：Esc 关闭入口（常驻预览窗 onExitCommand）
    public static func closeActive() {
        Self.shared.controller?.window?.performClose(nil)
    }

    func clear(_ controller: ClipboardPreviewWindowController) {
        if self.controller === controller { self.controller = nil }
    }
}

// MARK: - 窗口内容

struct ClipboardPreviewWindowView: View {

    let item: ClipboardItem

    // 注：本项目用 swiftc 直编（无 macro plugin），@State 宏不可用 → 统一用 @Stored（StateCompat）
    @Stored private var model: PreviewPopoverContentModel
    @Stored private var isEditing = false
    @Stored private var draft = ""

    init(item: ClipboardItem) {
        self.item = item
        _model = Stored(wrappedValue: Self.makeModel(item: item, editedText: nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isEditing {
                editor
            } else {
                preview
            }
        }
        .background(Color(nsColor: OfficialChrome.windowBackground))
        .frame(minWidth: 420, minHeight: 320)
        .onExitCommand {
            // v65：Esc 关闭常驻预览窗（此前只有标题栏关闭钮一条退路）
            ClipboardPreviewWindowRecord.closeActive()
        }
    }

    // MARK: 预览态

    private var preview: some View {
        PreviewPopoverContentView(model: model)
            .id(model.sessionID)          // 编辑保存后换会话 → 视图重建、滚动位置归零
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: typeSymbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Picker("", selection: $isEditing) {
                Text("预览").tag(false)
                Text("编辑").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)
            .onChange(of: isEditing) { editing in
                if editing {
                    draft = PreviewPopoverDataBridge.shared.fullText(for: item)
                    model = Self.makeModel(item: item, editedText: nil)
                }
            }
            Button {
                copyContent()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("复制内容")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 编辑态

    private var editor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
            Divider()
            HStack(spacing: 10) {
                Text("\(draft.count) 字符")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { isEditing = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: 动作

    private func copyContent() {
        let text = isEditing ? draft : PreviewPopoverDataBridge.shared.fullText(for: item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("已复制", icon: "doc.on.doc")
    }

    private func save() {
        ClipboardManager.shared.saveContent(dedupeKey: item.dedupeKey, newContent: draft)
        model = Self.makeModel(item: item, editedText: draft)
        isEditing = false
        Toast.show("已保存", icon: "checkmark.circle")
    }

    // MARK: 模型 / 文案

    /// editedText == nil → 按条目分类（长文走异步落盘加载）；
    /// 编辑保存后 → 直接按内存里的新文本分类，避免读到旧文件。
    static func makeModel(item: ClipboardItem, editedText: String?) -> PreviewPopoverContentModel {
        let full = editedText ?? PreviewPopoverDataBridge.shared.fullText(for: item)
        var kind: PreviewPopoverContentModel.Kind?
        if editedText != nil {
            switch item.type {
            case .image: kind = .image
            case .file:  kind = .file
            default:     kind = PreviewPopoverContentModel.classifyRawText(full)
            }
        }
        return PreviewPopoverContentModel(item: item,
                                          source: .mainPreview,
                                          entry: .mainList,
                                          sessionID: UUID(),
                                          inlineText: full,
                                          showsKeyboardHint: false,
                                          kindOverride: kind)
    }

    private var typeSymbol: String {
        switch item.type {
        case .text:     return "text.alignleft"
        case .richtext: return "doc.richtext"
        case .image:    return "photo"
        case .url:      return "link"
        case .file:     return "doc"
        }
    }

    private var displayTitle: String {
        if let alias = item.aliasTitle, !alias.isEmpty { return alias }
        if let title = item.title, !title.isEmpty { return title }
        let text = item.content ?? ""
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? "（空内容）"
        return String(firstLine.prefix(80))
    }

    private var subline: String {
        var parts: [String] = [item.timestamp.relativeText]
        switch item.type {
        case .text, .richtext:
            let count = item.fullTextCharCount ?? item.content?.count ?? 0
            if count > 0 { parts.append("\(count) 个字符") }
        case .image:
            parts.append("图片")
        case .url:
            if let host = item.content.flatMap({ URL(string: $0)?.host }) { parts.append(host) }
        case .file:
            parts.append("文件")
        }
        if let app = item.sourceApp, !app.isEmpty { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}
