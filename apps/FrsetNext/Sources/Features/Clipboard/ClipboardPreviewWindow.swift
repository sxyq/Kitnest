import AppKit
import SwiftUI

// MARK: - 统一预览窗（v71，用户需求 2026-10-19「两种预览要一致，不能两套实现」）
//
// hover 与点击统一为**同一个窗口实现**（NSPopover 退役）：
//   · hover 触发  → .hover      模式：无边框轻量态，鼠标移出自动关（移出判定由
//                  MainPanelPreviewPopoverCoordinator 统一仲裁，含实测位置兜底）
//   · 单击触发    → .persistent 模式：标题栏常态，可拖动缩放、失焦即关
// 两者共用同一内容视图 ClipboardPreviewWindowView（头部：类型图标 + 标题 + 时间/字数 +
// 预览|编辑分段 + 📌 固定 + 复制 + 关闭叉号；正文：PreviewPopoverContentView 同款渲染），
// 仅「窗口外壳」与「自动关闭策略」随触发方式不同。
//
// 📌 固定语义（两模式一致）：开 = 自动关闭全禁（移出不关、失焦不关），
//    只有 Esc / 叉号 / 条目删除 / 滚动出视口 / 程序化关闭会生效。
//
// 面板豁免：窗口 identifier = "frset.clipboardPreview"（PanelController.windowDidResignKey
// 据此在预览窗取得 key 时保持面板）。

public final class ClipboardPreviewWindowController: NSWindowController, NSWindowDelegate {

    public enum Mode { case hover, persistent }

    private var item: ClipboardItem
    private(set) var mode: Mode
    /// 一次性空格预览提示（hover 态首帧显示）
    private let showsHint: Bool
    /// 编辑态变化上报（协调器据此暂停 hover 自动关闭）
    var onEditingChanged: ((Bool) -> Void)?
    /// 窗口已关闭上报（协调器 handleWindowDidClose 统一清理）
    var onWindowClosed: (() -> Void)?

    public init(item: ClipboardItem, mode: Mode, showsHint: Bool = false) {
        self.item = item
        self.mode = mode
        self.showsHint = showsHint
        let initial = Self.initialSize(for: mode)
        let window: NSWindow
        switch mode {
        case .persistent:
            window = NSWindow(contentRect: NSRect(origin: .zero, size: initial),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.title = "预览"
        case .hover:
            window = HoverPreviewWindow(contentRect: NSRect(origin: .zero, size: initial),
                                        styleMask: [.borderless],
                                        backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 420, height: 320)
        window.identifier = NSUserInterfaceItemIdentifier("frset.clipboardPreview")
        super.init(window: window)
        window.delegate = self
        installContent()
        if mode == .persistent {
            window.applyOfficialChrome()   // 官方外观：灰底 + 透明标题栏 + 圆形关闭钮
        } else {
            configureHoverChrome(window: window)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现（预览窗走代码构建）") }

    /// 两种模式同一初始尺寸（一致性优先；persistent 可缩放，hover 跟随 place 钳制）
    private static func initialSize(for mode: Mode) -> NSSize {
        NSSize(width: 720, height: 620)
    }

    private func installContent() {
        guard let window else { return }
        let view = ClipboardPreviewWindowView(item: item, showsHint: showsHint,
                                              hoverStyle: mode == .hover,
                                              onEditingChanged: { [weak self] editing in
                                                  self?.onEditingChanged?(editing)
                                              })
        let host = NSHostingView(rootView: view)
        let bounds = window.contentView?.bounds ?? NSRect(origin: .zero, size: Self.initialSize(for: mode))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        // v121：文件态窗口高度贴合内容。窗口默认 720×620，而文件预览内容通常只有
        // 250~420pt，不收缩就会在下面留一大片空白（用户形容"里面啥也没有"）。
        if item.type == .file {
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            if fit.height > 40, fit.height < Self.initialSize(for: mode).height {
                var f = window.frame
                f.size.height = max(window.minSize.height, fit.height)
                window.setFrame(f, display: false)
                Log.info("Preview", "文件态高度自适应：内容 \(Int(fit.height)) → 窗口 \(Int(f.size.height))")
            }
        }
        if mode == .persistent {
            window.applyOfficialChrome()   // contentView 已替换 → 圆形关闭钮重新挂上
        }
    }

    /// hover 态外观：透明窗口 + 内容自裁圆角。
    /// v71 修正：不再用 contentView.layer.masksToBounds 裁圆角——那会切断系统
    /// 阴影的形状采样，阴影退化成「窗口矩形」，肉眼看就是圆角外多了一层图层
    /// （用户实障截图）。改为 SwiftUI 内容自身 clipShape，阴影自动跟随圆角。
    private func configureHoverChrome(window: NSWindow) {
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    // MARK: 呈现

    /// 打开/切换条目。同条目同模式重复呈现只前置窗口（persistent 保留缩放与编辑草稿）。
    func show(item newItem: ClipboardItem,
              anchorRectInScreen: CGRect, panelFrame: CGRect, visibleFrame: CGRect) {
        let sameItem = newItem.id == item.id
        item = newItem
        if !sameItem { installContent() }
        place(anchorRectInScreen: anchorRectInScreen,
              panelFrame: panelFrame, visibleFrame: visibleFrame)
        switch mode {
        case .hover:
            // 轻量呈现：不激活 app、不抢面板焦点（key 在用户点击窗体时才取得）
            window?.orderFront(nil)
        case .persistent:
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// persistent 同条目重复点击：仅前置
    func focusFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 位置：贴主面板左侧（顶边对齐锚条目），放不下则右侧，最后夹在可见区内
    private func place(anchorRectInScreen: CGRect, panelFrame: CGRect, visibleFrame: CGRect) {
        guard let window else { return }
        let size = window.frame.size
        var origin: NSPoint
        if panelFrame != .zero {
            let leftX = panelFrame.minX - size.width - 12
            let rightX = panelFrame.maxX + 12
            let x = leftX >= visibleFrame.minX + 8 ? leftX : rightX
            let y = anchorRectInScreen.maxY - size.height
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: visibleFrame.midX - size.width / 2,
                             y: visibleFrame.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        origin.y = min(max(origin.y, visibleFrame.minY + 8), visibleFrame.maxY - size.height - 8)
        window.setFrameOrigin(origin)
    }

    // MARK: NSWindowDelegate

    /// 失焦策略（两模式同一 📌 语义：固定中失焦不关）：
    ///   · persistent：焦点去其他 App → 关；焦点在本 App 内其他窗口 → 保持「边看边换」
    ///   · hover：焦点去任何别处 → 关（轻量态不驻留；点条目会立刻由协调器换 persistent 窗）
    public func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let w = self.window, w.isVisible, !w.isKeyWindow else { return }
            if MainPanelPreviewPopoverCoordinator.shared.previewPinned { return }
            switch self.mode {
            case .hover:
                w.performClose(nil)
            case .persistent:
                if NSApp.isActive, NSApp.keyWindow != nil { return }
                w.performClose(nil)
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }
}

/// hover 态无边框窗：可成为 key（点击编辑/选中文本时取得键盘焦点），但呈现时不主动抢
public final class HoverPreviewWindow: NSWindow {
    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

// MARK: - 打开中的预览窗登记（兼容壳；窗口单例由协调器统一持有）

public final class ClipboardPreviewWindowRecord {

    public static let shared = ClipboardPreviewWindowRecord()

    private init() {}

    /// 单击路径入口：统一转调协调器（persistent 模式）
    public static func open(for item: ClipboardItem, anchorView: NSView?) {
        MainPanelPreviewPopoverCoordinator.shared.presentPersistent(for: item, anchorView: anchorView)
    }

    /// Esc 关闭入口
    public static func closeActive() {
        MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .escape)
    }
}

// MARK: - 窗口内容

struct ClipboardPreviewWindowView: View {

    let item: ClipboardItem
    var showsHint: Bool = false
    /// hover 态：内容自裁圆角（窗口透明，系统阴影跟随圆角形状）
    var hoverStyle: Bool = false
    var onEditingChanged: ((Bool) -> Void)? = nil

    // 注：本项目用 swiftc 直编（无 macro plugin），@State 宏不可用 → 统一用 @Stored（StateCompat）
    @Stored private var model: PreviewPopoverContentModel
    @Stored private var isEditing = false
    @Stored private var draft = ""
    /// 📌 固定态（v71 起两模式共用：开 = 自动关闭全禁）
    @Stored private var pinned = MainPanelPreviewPopoverCoordinator.shared.previewPinned
    /// 关闭钮悬停态（红底白叉反馈）
    @Stored private var closeHover = false
    /// v106：液态玻璃入场态（easeOut 0.18s）
    @Stored private var glassAppeared = false

    init(item: ClipboardItem, showsHint: Bool = false, hoverStyle: Bool = false,
         onEditingChanged: ((Bool) -> Void)? = nil) {
        self.item = item
        self.showsHint = showsHint
        self.hoverStyle = hoverStyle
        self.onEditingChanged = onEditingChanged
        _model = Stored(wrappedValue: Self.makeModel(item: item, editedText: nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHint {
                hintBar
                Divider()
            }
            header
            Divider()
            if isEditing {
                editor
            } else {
                preview
            }
        }
        // v106：hover 态根背景置空，让液态玻璃面透出来（persistent 保留原实底）
        .background(hoverStyle ? Color.clear : Color(nsColor: OfficialChrome.windowBackground))
        .frame(minWidth: 420, minHeight: 320)
        // v121：内容顶部对齐（原来默认垂直居中，文件态内容少时上下各留一大片空白）
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(HoverClipModifier(active: hoverStyle))
        // v106 入场动效（GSAP 原则：ease-out 进场、0.96 缩放、0.18s、可中断；
        // 高频 hover 复现同条目时不重播——只在内容安装时播一次）
        .opacity(glassAppeared ? 1 : 0)
        .scaleEffect(glassAppeared ? 1 : 0.96, anchor: .center)
        .animation(.easeOut(duration: 0.18), value: glassAppeared)
        .onAppear { glassAppeared = true }
        .onExitCommand {
            // Esc 关闭（hover / persistent 两模式同效）
            MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .escape)
        }
        // hover 保活探测（与协调器的实测位置兜底双保险）
        .onPreviewPopoverHoverChanged { inside in
            MainPanelPreviewPopoverCoordinator.shared.popoverHoverChanged(inside)
        }
    }

    // MARK: 一次性提示条（空格预览 F6）

    private var hintBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
            Text("Click or Space to preview · 单击或按空格预览")
                .font(.system(size: 10))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.separator)
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
            // v71：图片/文件条目没有可编辑的文本内容（content 是 @image#N: 文件名
            // 之类的引用串），对齐原版交互——隐藏「预览|编辑」分段，只保留预览
            if item.type != .image && item.type != .file {
                Picker("", selection: $isEditing) {
                    Text("预览").tag(false)
                    Text("编辑").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)
                .onChange(of: isEditing) { editing in
                    onEditingChanged?(editing)
                    if editing {
                        draft = PreviewPopoverDataBridge.shared.fullText(for: item)
                        model = Self.makeModel(item: item, editedText: nil)
                    }
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
            // 📌 固定（v71 两模式统一语义：开 = 移出不关、失焦不关）
            Button {
                let newValue = !pinned
                MainPanelPreviewPopoverCoordinator.shared.previewPinned = newValue
                pinned = newValue
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(pinned ? Color.primary : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(pinned ? 0.1 : 0)))
            }
            .buttonStyle(.borderless)
            .help(pinned ? "固定中：移开鼠标/失焦不再自动关闭（点击取消固定）"
                         : "固定预览：自动关闭全关，只能 Esc/叉号关闭")
            // 显式关闭叉号（v66）
            Button {
                MainPanelPreviewPopoverCoordinator.shared.dismiss(reason: .escape)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(closeHover ? Color.white : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(closeHover ? Color.red : Color.primary.opacity(0.06)))
            }
            .buttonStyle(.borderless)
            .onHover { hovering in
                closeHover = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help("关闭预览（Esc）")
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

/// hover 态内容裁剪：圆角 + 半透明描边（active=false 时不裁，persistent 走系统标题栏圆角）
/// v106（2026-10-21 用户：「文本预览框要玻璃改造」，对齐 liquid-glass 规范）：
/// 毛玻璃材质 + 顶部高光渐变描边 + 柔和投影；对比度靠半实底 tint 保障
/// （设计守则：材质不能压过文字对比）；开启「减弱透明度」时回退纯色。
private struct HoverClipModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let radius: CGFloat = 12

    func body(content: Content) -> some View {
        if active {
            content
                .background(glassSurface)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(reduceTransparency ? 0.12 : 0.38),
                                    Color.white.opacity(0.10),
                                    Color.primary.opacity(0.10),
                                ],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                )
                // 液态玻璃的"浮起"感：大而柔的投影（仅 hover 态，滚动列表不受影响）
                .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        } else {
            content
        }
    }

    /// 玻璃面：ultraThin 材质 + 半实底 tint（文字对比度），减弱透明度时纯色兜底
    @ViewBuilder private var glassSurface: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
        }
    }
}
