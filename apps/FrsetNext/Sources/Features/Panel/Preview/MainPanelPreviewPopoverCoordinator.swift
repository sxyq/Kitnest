import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - 主面板预览协调器（specs/12 §4.2，MainPanelPreviewPopoverCoordinator）
//
// v71：NSPopover 底座退役，预览统一承载于 ClipboardPreviewWindowController。
// v206（用户：「JSON 文件的那种预览是不是单独窗口……全部删掉」）：
// 只保留 hover 无边框轻量窗（无标题栏/无红绿灯，移出自动关）；
// persistent 标题栏预览窗已经彻底删除，本类不再提供任何「单独预览窗」入口。
// 本类名与公开接口保持不变（Registry 协议 / PanelRootView / PanelController 零改动）。
//
// 三路触发：悬停（开/关 DispatchWorkItem + hover-intent 阈值 + 总开关）、单击、空格键。
// 关闭仲裁：hoverOut（含鼠标实测位置兜底）/ Esc / 点外 / 滚动出视口 / 条目删除 /
// 面板收起等待（waitsForPreviewClose）。

/// 关闭原因（类型名实证 @0x10096a3f0；case 集⬜，以下为语义推测，禁当实证）
public enum MainPanelPreviewPopoverCloseReason: String {
    case hoverOut              // 鼠标移出条目且不在预览窗内（延时关闭）
    case itemRemoved           // 锚条目被删除
    case panelCollapse         // 面板收起（先等预览关闭，P8）
    case escape                // Esc / 用户手动关闭
    case scrolledOutOfViewport // 条目滚动出视口（P6）
    case programmatic          // 程序化（切换条目/重新呈现）
    case systemInterruption    // 被系统/失焦关闭
}

// MARK: - Slot（specs/12 §4.3）

/// 单个预览窗实例（槽位）。状态机 case 集⬜（原作仅存类型名 @0x10096a420，禁当实证）。
public final class MainPanelPreviewPopoverSlot {
    public enum SlotState { case idle, presenting, presented, closing }

    public internal(set) var state: SlotState = .idle
    public internal(set) var contentModel: PreviewPopoverContentModel?
    /// 关闭时上报的原因（窗口关闭前由协调器写入）
    var pendingCloseReason: MainPanelPreviewPopoverCloseReason = .systemInterruption
    /// 统一预览窗（v71：替代原 NSPopover 底座）
    let windowController: ClipboardPreviewWindowController
    /// 编辑中（暂停 hover 自动关闭，防草稿丢失）
    var isEditing = false

    init(contentModel: PreviewPopoverContentModel, showsHint: Bool) {
        self.contentModel = contentModel
        // v206：预览只剩 hover 无边框窗（独立标题栏预览窗已删除）
        self.windowController = ClipboardPreviewWindowController(item: contentModel.item,
                                                                 showsHint: showsHint)
        windowController.onWindowClosed = { [weak self] in
            MainPanelPreviewPopoverCoordinator.shared.handlePreviewWindowDidClose(self)
        }
        windowController.onEditingChanged = { [weak self] editing in
            self?.isEditing = editing
            if editing { MainPanelPreviewPopoverCoordinator.shared.cancelHoverClose() }
        }
    }
}

// MARK: - 协调器

public final class MainPanelPreviewPopoverCoordinator: NSObject {

    public static let shared = MainPanelPreviewPopoverCoordinator()

    // MARK: 可调参数（字段名沿原作 reflstr；数值⬜ = 原作值未探明，取合理默认，可被设置页覆盖）

    /// 悬停后延时开启（__hoverPreviewOpenWorkItem；⬜ 原作值未探明）
    public var hoverPreviewOpenDelay: TimeInterval = 0.35
    /// 移出后延时关闭（__hoverPreviewCloseWorkItem；⬜ 原作值未探明）
    public var hoverPreviewCloseDelay: TimeInterval = 0.25
    /// hover-intent 阈值：悬停至少这么久才算有意（⬜ 原作值未探明）
    public var activeHoverIntentThreshold: TimeInterval = 0.06
    /// 空格键键盘预览延时（__keyboardPreviewPresentationWorkItem；⬜ 原作值未探明）
    public var keyboardPreviewPresentationDelay: TimeInterval = 0.30
    /// 文本 loading 占位期间指示器延迟显示（F13；⬜ 原作值未探明）
    public var previewLoadingIndicatorDelay: TimeInterval = 0.40

    /// 文本类预览窗高度上限（F13 maxPopoverHeight；⬜ 原作值未探明）
    /// 2026-10-18：480 → 620（正文 1.5 倍字号后行高增加，需同步抬高上限）
    public var maxPopoverHeight: CGFloat = 620
    /// 图片类预览窗高度上限（F13 imagePreviewMaxPopoverHeight；⬜ 原作值未探明）
    public var imagePreviewMaxPopoverHeight: CGFloat = 620
    /// 文本 loading 占位最小高度（F13 textPreviewLoadingMinHeight；⬜ 原作值未探明）
    public var textPreviewLoadingMinHeight: CGFloat = 56
    /// QR 图片预览头尾高度（F13；⬜ 原作值未探明）
    public var imagePreviewHeaderFooterHeightForQRCode: CGFloat = 28
    /// 普通图片预览头尾高度（F13；⬜ 原作值未探明）
    public var imagePreviewHeaderFooterHeightForRegularImage: CGFloat = 12
    /// 图片预览纵向内边距（F13；⬜ 原作值未探明）
    public var imagePreviewVerticalPaddingHeight: CGFloat = 8
    /// JSON 预览字符截断上限（F16 jsonPreviewCharCap；⬜ 原作值未探明）
    public var jsonPreviewCharCap: Int = 20_000
    /// 内容宽度（v71：统一窗口后保留该参数，宽度估算/目录布局仍引用）
    /// 2026-10-19（用户：文本宽度再扩一点）：480 → 560
    public var popoverWidth: CGFloat = 560

    // 代码预览尺寸阶梯（F14；数值⬜ 原作值未探明）
    public var codePreviewCompactMinHeight: CGFloat = 96
    public var codePreviewCompactMaxHeight: CGFloat = 180
    public var codePreviewMinHeight: CGFloat = 220
    public var codePreviewMaxHeight: CGFloat = 480
    public var codePreviewMinWidth: CGFloat = 300
    public var codePreviewMediumWidth: CGFloat = 360
    public var codePreviewMaxWidth: CGFloat = 460
    public var codePreviewContentPadding: CGFloat = 12

    /// 埋点出口：App 总控可注入统一上报；缺省仅打日志。
    /// 事件名：main_panel_preview（action 含 "exposed"）/ preview_navigation / item_preview_navigation（F11）
    public var analyticsSink: ((String, [String: String]) -> Void)?

    // MARK: 运行状态

    private var slot: MainPanelPreviewPopoverSlot?
    private var hoverPreviewOpenWorkItem: DispatchWorkItem?
    private var hoverPreviewCloseWorkItem: DispatchWorkItem?
    private var keyboardPreviewPresentationWorkItem: DispatchWorkItem?
    private var suppressHoverUntilMouseMove = false       // F3 __suppressHoverUntilMouseMove
    private var suppressEventMonitor: Any?
    private var sessionID = UUID()                        // F9 __previewSessionID
    private var hoverStartedAt: Date?
    private var isPreviewPopoverHovered = false           // F4 __isPreviewPopoverHovered
    // v126（性能审计 死代码复审）：删除死属性 cancellables（Set<AnyCancellable>，
    // 全工程无 store(in:) 订阅引用，Combine import 保留供后续订阅使用）
    private var pendingCloseCompletion: (() -> Void)?
    private var escapeMonitor: Any?

    // F7/F8：导航顺序表与滚动跟踪
    private var previewOrder: [String] = []
    private var trackedPreviewItemMinYByID: [String: CGFloat] = [:]
    private var pendingPreviewVisibilityValidationTargetID: String?
    public private(set) var activeItemID: String?
    private var activeSource: PreviewPopoverContentModel.Source = .mainPreview

    /// 面板收起前是否等待预览关闭（P8 waitsForPreviewClose；PanelController.hide() 依赖）
    public var waitsForPreviewClose: Bool { true }

    /// 是否有存活的预览窗
    public var hasActivePreview: Bool {
        slot?.state == .presenting || slot?.state == .presented || slot?.state == .closing
    }

    private override init() {
        super.init()
    }

    // MARK: 公开呈现 API

    /// 呈现预览（hover / 空格 / 探针；单击走 presentPersistent）
    /// - Parameters:
    ///   - item: 目标条目
    ///   - anchorRectInWindow: 行视图的 window 坐标框（SwiftUI 用 GeometryReader(.global) 取得）
    ///   - source: mainPreview / floatingPreview
    ///   - entry: 入口多态（F19）
    ///   - showsKeyboardHint: 是否显示一次性键盘预览提示（F6，仅空格触发时 true）
    @discardableResult
    public func present(for item: ClipboardItem,
                        anchorRectInWindow: CGRect? = nil,
                        anchorView: NSView? = nil,
                        source: PreviewPopoverContentModel.Source = .mainPreview,
                        entry: PreviewPopoverContentModel.Entry = .mainList,
                        showsKeyboardHint: Bool = false) -> Bool {
        cancelHoverWorkItems()
        cancelKeyboardPreview()
        activeSource = source

        // 同条目已呈现 → 前置即可（重复触发不闪烁）
        if let slot, slot.state == .presenting || slot.state == .presented,
           slot.contentModel?.item.id == item.id {
            return true
        }
        // 旧预览窗先程序化关闭（didClose 回调里只做清理，不触发 completion 流程）
        if slot != nil { closeSlot(reason: .programmatic) }

        guard let (anchorHostView, anchorRect) = resolveAnchor(preferredView: anchorView,
                                                               rectInWindow: anchorRectInWindow) else {
            return false
        }
        let panelFrame = anchorHostView.window?.frame ?? .zero
        let screen = anchorHostView.window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let anchorInScreen = anchorHostView.window.map {
            $0.convertToScreen(anchorHostView.convert(anchorRect, to: nil))
        } ?? anchorRect

        sessionID = UUID()
        let text = PreviewPopoverDataBridge.shared.fullText(for: item)
        let model = PreviewPopoverContentModel(item: item,
                                               source: source,
                                               entry: entry,
                                               sessionID: sessionID,
                                               inlineText: text,
                                               showsKeyboardHint: showsKeyboardHint)

        let slot = MainPanelPreviewPopoverSlot(contentModel: model, showsHint: showsKeyboardHint)
        self.slot = slot
        slot.state = .presenting
        slot.windowController.show(item: item,
                                   anchorRectInScreen: anchorInScreen,
                                   panelFrame: panelFrame,
                                   visibleFrame: visibleFrame)
        slot.state = .presented

        activeItemID = item.id
        // v206：预览只剩 hover 态 → 始终安装点外关闭监听
        installOutsideClickMonitor()
        installEscapeMonitor()
        track("main_panel_preview", "exposed", model)
        return true
    }

    // v182（用户）：「点开后常驻、带两个叉」的持久预览窗已删除；
    // v206：单击与悬停共用同一个 hover 预览，独立 persistent 预览窗已删除。

    /// 关闭预览（可带完成回调；面板收起等待预览先关时由 PanelController 调用，reason = .panelCollapse）
    public func dismiss(reason: MainPanelPreviewPopoverCloseReason = .programmatic,
                        completion: (() -> Void)? = nil) {
        removeOutsideClickMonitor()
        guard let slot, slot.state != .idle, slot.state != .closing else {
            completion?()
            return
        }
        if let completion {
            let previous = pendingCloseCompletion
            pendingCloseCompletion = { previous?(); completion() }
        }
        closeSlot(reason: reason)
    }

    // MARK: 触发路 1：悬停（F1）

    /// 行悬停接线：hovering = true 调度开启，false 调度关闭。
    /// - Parameters:
    ///   - item: 悬停条目
    ///   - anchorProvider: 返回行当前 window 坐标框（列表滚动时行会移动，呈现瞬间再取）
    ///   - source: 决定读取哪个总开关（F2）
    public func rowHover(_ hovering: Bool,
                         item: ClipboardItem,
                         source: PreviewPopoverContentModel.Source = .mainPreview,
                         anchorProvider: @escaping () -> CGRect?) {
        // F2 总开关（默认开启：defaults 实测键无落盘值）
        let key = source == .mainPreview
            ? Preferences.Keys.hoverPreviewInMainWindowEnabled
            : Preferences.Keys.hoverPreviewInFloatingClipboardEnabled
        guard Preferences.shared.value(key, default: true) else { return }
        // F3 抑制期：预览窗关闭后鼠标未移动前不复弹
        guard !suppressHoverUntilMouseMove else { return }

        if hovering {
            hoverPreviewCloseWorkItem?.cancel()
            hoverPreviewCloseWorkItem = nil
            hoverStartedAt = Date()
            guard hoverPreviewOpenWorkItem == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverPreviewOpenWorkItem = nil
                // hover-intent 阈值校验
                if let start = self.hoverStartedAt,
                   Date().timeIntervalSince(start) < self.activeHoverIntentThreshold { return }
                guard let rect = anchorProvider() else { return }
                self.present(for: item, anchorRectInWindow: rect, source: source)
            }
            hoverPreviewOpenWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverPreviewOpenDelay, execute: work)
        } else {
            hoverPreviewOpenWorkItem?.cancel()
            hoverPreviewOpenWorkItem = nil
            scheduleHoverClose()
        }
    }

    /// 面板即将出现：清抑制与未决 WorkItem（复用面板时防脏状态）
    public func prepareForPanelAppear() {
        endHoverSuppression()
        cancelHoverWorkItems()
    }

    // MARK: 触发路 3：空格键（F6）

    /// 键盘预览：带延时 WorkItem；首次触发消费一次性提示键
    /// clipboard_keyboard_preview_hint_consumed（defaults 实测值 1）
    public func requestKeyboardPreview(item: ClipboardItem,
                                       anchorProvider: @escaping () -> CGRect?) {
        cancelKeyboardPreview()
        let hintNeeded = !Preferences.shared.value(Preferences.Keys.clipboardKeyboardPreviewHintConsumed,
                                                   default: false)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.keyboardPreviewPresentationWorkItem = nil
            if hintNeeded {
                Preferences.shared.set(Preferences.Keys.clipboardKeyboardPreviewHintConsumed, true)
            }
            guard let rect = anchorProvider() else { return }
            self.present(for: item, anchorRectInWindow: rect, source: .mainPreview,
                         showsKeyboardHint: hintNeeded)
            track("main_panel_preview", "keyboard", nil)
        }
        keyboardPreviewPresentationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + keyboardPreviewPresentationDelay, execute: work)
    }

    /// 选择移动/再次按键时取消未决的键盘预览
    public func cancelKeyboardPreview() {
        keyboardPreviewPresentationWorkItem?.cancel()
        keyboardPreviewPresentationWorkItem = nil
    }

    // MARK: 预览窗内悬停保活（F4）

    /// 预览窗内容悬停仲裁（内容视图 onPreviewPopoverHoverChanged 转入 + 实测位置兜底双保险）：
    /// 在内则取消关闭计时，移出则恢复关闭计时
    public func popoverHoverChanged(_ inside: Bool) {
        isPreviewPopoverHovered = inside
        if inside {
            hoverPreviewCloseWorkItem?.cancel()
            hoverPreviewCloseWorkItem = nil
        } else if hasActivePreview, !previewPinned {
            scheduleHoverClose()
        }
    }

    // MARK: 固定模式（📌）
    //
    // 默认：hover 移出即收；persistent 失焦即收。
    // 固定式（📌 开）：自动关闭全禁（移出不关、失焦不关），只有 Esc / 叉号 /
    // 条目删除 / 滚动出视口 / 程序化关闭生效。两种模式随时用预览头部 📌 切换，选择跨启动记忆。

    /// 预览是否固定（UserDefaults 持久化，跨启动记忆）
    public var previewPinned: Bool {
        get { UserDefaults.standard.bool(forKey: "panel.previewPinned") }
        set { UserDefaults.standard.set(newValue, forKey: "panel.previewPinned") }
    }

    private var outsideGlobalMonitor: Any?
    private var outsideLocalMonitor: Any?

    private func installOutsideClickMonitor() {
        guard outsideGlobalMonitor == nil, outsideLocalMonitor == nil else { return }
        // 点其他 App
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let slot = self.slot, slot.state == .presented, !self.previewPinned else { return }
            self.dismiss(reason: .programmatic)
        }
        // 点本 App（面板本体等）；点击预览窗不算「外部」
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let slot = self.slot, slot.state == .presented else { return event }
            if self.previewPinned { return event }
            if let previewWindow = slot.windowController.window,
               event.window === previewWindow {
                return event
            }
            self.dismiss(reason: .programmatic)
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideGlobalMonitor { NSEvent.removeMonitor(m); outsideGlobalMonitor = nil }
        if let m = outsideLocalMonitor { NSEvent.removeMonitor(m); outsideLocalMonitor = nil }
    }

    /// Esc 兜底（v71）：预览窗未取得 key（用户只悬停未点击）时 onExitCommand 收不到
    /// 键盘事件，本地 keyDown 监听保证 Esc 始终可关预览窗。
    /// 编辑态放行（TextEditor 的 Esc = 取消编辑，不能吞成关窗）。
    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, // Esc
                  let self, let slot = self.slot, slot.state == .presented,
                  !slot.isEditing,
                  let w = slot.windowController.window, w.isVisible else { return event }
            self.dismiss(reason: .escape)
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
    }

    // MARK: 导航（F7）

    /// 提供当前过滤态下的条目顺序表（dev-clipboard 在列表变化时调用）
    public func setPreviewOrder(_ ids: [String]) {
        previewOrder = ids
    }


    // MARK: 滚动跟随与校验（F8/P6）


    // MARK: 条目删除（F10 itemRemoved）

    public func notifyItemRemoved(itemID: String) {
        if itemID == activeItemID { dismiss(reason: .itemRemoved) }
    }

    // MARK: Markdown 滚动记忆（F15）

    private var markdownScrollMemory: [String: MarkdownScrollState] = [:]

    /// 记录某条目的 Markdown/长文滚动位置（键 = dedupeKey，重开预览恢复）
    public func rememberMarkdownScroll(dedupeKey: String, state: MarkdownScrollState) {
        markdownScrollMemory[dedupeKey] = state
    }

    /// 取恢复请求（无则 nil）
    public func markdownScrollState(for dedupeKey: String) -> MarkdownScrollState? {
        markdownScrollMemory[dedupeKey]
    }

    // MARK: 埋点（F11）

    /// 主面板活动区枚举值（main_panel_item / main_panel_preview / main_panel_search_result / main_panel_keyboard）
    public static let activityAreaPreview = "main_panel_preview"

    private func track(_ event: String, _ action: String, _ model: PreviewPopoverContentModel?) {
        var props: [String: String] = ["action": action,
                                       "area": Self.activityAreaPreview]
        if let model {
            props["source"] = model.source.rawValue
            props["entry"] = model.entry.rawValue
            props["kind"] = String(describing: model.kind)
            props["session"] = model.sessionID.uuidString
        }
        analyticsSink?(event, props)
        Log.debug("panel.preview", "\(event) action=\(action)")
    }

    // MARK: 内部

    private func resolveAnchor(preferredView: NSView?, rectInWindow: CGRect?) -> (NSView, CGRect)? {
        if let view = preferredView {
            let rect = rectInWindow.map { view.convert($0, from: nil) } ?? view.bounds
            return (view, rect)
        }
        // SwiftUI 行内无法直接给 NSView：退化为锚到 key window 的 contentView（rect 已是 window 坐标）
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let content = window.contentView else { return nil }
        let rect = rectInWindow.map { content.convert($0, from: nil) } ?? content.bounds
        return (content, rect)
    }

    private func cancelHoverWorkItems() {
        hoverPreviewOpenWorkItem?.cancel()
        hoverPreviewOpenWorkItem = nil
        hoverPreviewCloseWorkItem?.cancel()
        hoverPreviewCloseWorkItem = nil
    }

    /// 编辑开始时取消未决的关闭计时（onEditingChanged 转入）
    func cancelHoverClose() {
        hoverPreviewCloseWorkItem?.cancel()
        hoverPreviewCloseWorkItem = nil
    }

    private func scheduleHoverClose() {
        guard hoverPreviewCloseWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverPreviewCloseWorkItem = nil
            guard let slot = self.slot, slot.state == .presented else { return }
            if slot.isEditing { return }                 // 编辑中不自动关（防草稿丢失）
            if self.previewPinned { return }             // 📌 固定中不自动关
            if self.isPreviewPopoverHovered { return }   // F4：SwiftUI 探测鼠标在预览窗内
            // v71 兜底（用户实障：hover 图片预览想复制 OCR 文本，鼠标一移过去预览即消）：
            // SwiftUI onHover 在窗口动画 / NSViewRepresentable（OCR 的 NSTextView）上方 /
            // nonactivating 面板 key 切换瞬间可能迟到或丢失。以鼠标屏幕实测位置为准：
            // 落在预览窗 frame 内 → 递归重调度继续等待（关闭流程激活期间的轻量轮询），
            // 鼠标真正离开才关。
            if let previewWindow = slot.windowController.window,
               previewWindow.frame.contains(NSEvent.mouseLocation) {
                self.scheduleHoverClose()
                return
            }
            self.dismiss(reason: .hoverOut)
        }
        hoverPreviewCloseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverPreviewCloseDelay, execute: work)
    }

    private func closeSlot(reason: MainPanelPreviewPopoverCloseReason) {
        guard let slot else { return }
        slot.pendingCloseReason = reason
        slot.state = .closing
        // v83（2026-10-19 用户反馈「点叉号关不掉」根因）：
        // performClose 对 **borderless 的 hover 预览窗静默无效**（NSWindow.performClose
        // 要求 isCloseable，hover 模式 styleMask=.borderless 不满足）→ 旧窗变孤儿常驻，
        // 且 present() 已把 self.slot 指向新窗口 → 叉号的 dismiss 关的是另一个窗，
        // 用户观感即「点叉号无法关闭」。
        // 统一 close()：两种模式都可靠（isReleasedWhenClosed=false，controller 不销毁），
        // windowWillClose → onWindowClosed → handlePreviewWindowDidClose 清理链不变。
        // v197：改走控制器收回动画（缩回主面板那一行），再真正 close()。
        slot.windowController.closeAnimated()
    }

    /// 预览窗已关闭（ClipboardPreviewWindowController.onWindowClosed 转入）
    fileprivate func handlePreviewWindowDidClose(_ closingSlot: MainPanelPreviewPopoverSlot?) {
        guard let slot, slot === closingSlot else { return }
        let reason = slot.pendingCloseReason
        self.slot = nil
        activeItemID = nil
        isPreviewPopoverHovered = false
        trackedPreviewItemMinYByID.removeAll()
        pendingPreviewVisibilityValidationTargetID = nil
        // F3：关闭后抑制悬停复弹，直到鼠标移动
        beginHoverSuppression()
        removeEscapeMonitor()
        track("main_panel_preview", reason.rawValue, nil)
        let completion = pendingCloseCompletion
        pendingCloseCompletion = nil
        completion?()
    }

    // MARK: F3 抑制期实现（本地鼠标移动监听）

    private func beginHoverSuppression() {
        suppressHoverUntilMouseMove = true
        guard suppressEventMonitor == nil else { return }
        suppressEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .otherMouseDragged]) { [weak self] event in
            self?.endHoverSuppression()
            return event
        }
    }

    private func endHoverSuppression() {
        suppressHoverUntilMouseMove = false
        if let monitor = suppressEventMonitor {
            NSEvent.removeMonitor(monitor)
            suppressEventMonitor = nil
        }
    }
}

// MARK: - 箭头几何（specs/12 §4.6，PreviewArrowGeometrySupport / PreviewArrowGeometryStore）
//
// v71：NSPopover 箭头退役，几何支撑保留给 SwiftUI .popover() 家族调用方使用。

/// 条目屏几何 + 预览窗内容屏框 → arrowEdge（防越屏翻转）

/// 箭头几何缓存（按条目 id 记忆最近计算的边；classname 实证 @0x100acce7c）

// MARK: - SwiftUI 环境键（specs/12 类清单：isPreviewPopoverHovered / onPreviewPopoverHoverChanged）

private struct IsPreviewPopoverHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// 鼠标是否在预览窗内容内（F4 __isPreviewPopoverHovered；`__` 前缀 = @Environment 包装存储名）
    var isPreviewPopoverHovered: Bool {
        get { self[IsPreviewPopoverHoveredKey.self] }
        set { self[IsPreviewPopoverHoveredKey.self] = newValue }
    }
}

public extension View {
    /// 预览窗内容根视图挂接：写入环境值并通知协调器做保活/关闭仲裁
    func onPreviewPopoverHoverChanged(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(PreviewPopoverHoverChangedModifier(action: action))
    }
}

public struct PreviewPopoverHoverChangedModifier: ViewModifier {
    let action: (Bool) -> Void
    public init(action: @escaping (Bool) -> Void) { self.action = action }
    public func body(content: Content) -> some View {
        PreviewPopoverHoverProbe(content: content, action: action)
    }
}

private struct PreviewPopoverHoverProbe<Content: View>: View {
    let content: Content
    let action: (Bool) -> Void
    @Stored private var inside = false

    var body: some View {
        content
            .environment(\.isPreviewPopoverHovered, inside)
            .onHover { hovering in
                inside = hovering
                action(hovering)
            }
    }
}
