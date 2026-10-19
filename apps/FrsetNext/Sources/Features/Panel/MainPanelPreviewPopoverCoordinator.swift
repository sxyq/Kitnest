import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - 主面板预览 Popover 协调器（specs/12 §4.2，MainPanelPreviewPopoverCoordinator）
//
// 架构：SwiftUI .popover() 家族的 NSPopover 底座 + 本协调器统一调度。
// 三路触发：悬停（开/关 DispatchWorkItem + hover-intent 阈值 + 总开关）、单击、空格键。
// 交互模型（全工程必改项的预览侧）：单击 = 预览（不复制）、双击或 ↩ = 复制、右键 = 菜单。
// 行点击/悬停接线由剪贴板模块（dev-clipboard）调用本类公开 API 完成。
//
// 关闭协议（F10）：CloseReason 枚举 + NSPopoverDidClose 订阅（Combine）+ 关闭后
// __suppressHoverUntilMouseMove 防复弹 + 面板收起等待预览先关（waitsForPreviewClose）。

/// 关闭原因（类型名实证 @0x10096a3f0；case 集⬜，以下为语义推测，禁当实证）
public enum MainPanelPreviewPopoverCloseReason: String {
    case hoverOut              // 鼠标移出条目且不在 popover 内（延时关闭）
    case itemRemoved           // 锚条目被删除
    case panelCollapse         // 面板收起（先等预览关闭，P8）
    case escape                // Esc / 用户手动关闭
    case scrolledOutOfViewport // 条目滚动出视口（P6）
    case programmatic          // 程序化（切换条目/重新呈现）
    case systemInterruption    // popover 被系统关闭（点击 popover 外等）
}

/// 预览导航命令（F7 clipboardPreviewNavigate；⬜ 键位未探明，由热键模块映射后调用）
public struct PreviewNavigationCommand {
    public enum Direction: String { case previous, next }
    public let direction: Direction
    public init(direction: Direction) { self.direction = direction }
}

// MARK: - Slot（specs/12 §4.3，MainPanelPreviewPopoverSlot）

/// 单个预览 popover 实例（槽位）。状态机 case 集⬜（原作仅存类型名 @0x10096a420，
/// 推测 idle/presenting/presented/closing，禁当实证）。
public final class MainPanelPreviewPopoverSlot {
    public enum SlotState { case idle, presenting, presented, closing }

    public internal(set) var state: SlotState = .idle
    public internal(set) var contentModel: PreviewPopoverContentModel?
    /// 关闭时上报的原因（didClose 前由协调器写入）
    var pendingCloseReason: MainPanelPreviewPopoverCloseReason = .systemInterruption
    /// NSPopover 底座
    public let popover = NSPopover()

    init(contentModel: PreviewPopoverContentModel) {
        self.contentModel = contentModel
        // v65：behavior 恒 applicationDefined——关闭完全由协调器仲裁（点外 global+local
        // 监听 / Esc / hoverOut / 滚动出视口 / 条目删除 / 程序化）。
        // 不再用 .transient：主面板是 nonactivating panel，实测 transient popover
        // 在「点击其他 App」时不会被系统关闭（点外即失灵 → 用户反馈"关不掉"）。
        popover.behavior = .applicationDefined
        popover.animates = true
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

    /// 文本类 popover 高度上限（F13 maxPopoverHeight；⬜ 原作值未探明）
    /// 2026-10-18：480 → 620（正文 1.5 倍字号后行高增加，需同步抬高上限）
    public var maxPopoverHeight: CGFloat = 620
    /// 图片类 popover 高度上限（F13 imagePreviewMaxPopoverHeight；⬜ 原作值未探明）
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
    /// popover 内容宽度
    /// 2026-10-18：340 → 480（正文 1.5 倍字号 + 目录侧栏 180pt，原宽度每行挤不下几个字）
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
    private var cancellables = Set<AnyCancellable>()
    private var pendingCloseCompletion: (() -> Void)?

    // F7/F8：导航顺序表与滚动跟踪
    private var previewOrder: [String] = []
    private var trackedPreviewItemMinYByID: [String: CGFloat] = [:]
    private var pendingPreviewVisibilityValidationTargetID: String?
    public private(set) var activeItemID: String?
    private var activeSource: PreviewPopoverContentModel.Source = .mainPreview

    /// 面板收起前是否等待预览关闭（P8 waitsForPreviewClose；PanelController.hide() 依赖）
    public var waitsForPreviewClose: Bool { true }

    /// 是否有存活的预览 popover
    public var hasActivePreview: Bool {
        slot?.state == .presenting || slot?.state == .presented || slot?.state == .closing
    }

    private override init() {
        super.init()
        // F10：订阅 NSPopoverWillShow/DidCloseNotification（Combine，实证 0x1000b5504 / 0x1000aee14）
        NotificationCenter.default.publisher(for: NSPopover.willShowNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handlePopoverWillShow(note) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in self?.handlePopoverDidClose(note) }
            .store(in: &cancellables)
        // v65「点外即消」主通道：applicationDefined popover 取得 key 后，**resignKey =
        // 用户去了别处**（点其他 App / 点面板本体）→ 关闭。
        // 不再用 NSEvent 全局监听：实测 global monitor 对面板场景不可靠，且
        // transient behavior 在 nonactivating panel 上点外也不关（用户反馈"关不掉"）。
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, let slot = self.slot,
                      let w = slot.popover.contentViewController?.view.window,
                      (note.object as? NSWindow) === w,
                      slot.state == .presented else { return }
                self.dismiss(reason: .systemInterruption)
            }
            .store(in: &cancellables)
    }

    // MARK: 公开呈现 API（dev-clipboard 行点击接线入口）

    /// 呈现预览（单击/双击接线用）：window 坐标锚点版
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
        // 同一条目已呈现 → 保持现状（重复单击不闪烁）
        if let slot, slot.state == .presenting || slot.state == .presented,
           slot.contentModel?.item.id == item.id {
            return true
        }
        // 旧 popover 先程序化关闭（didClose 通知里只做清理，不触发 completion 流程）
        if slot != nil { closeSlot(reason: .programmatic) }

        sessionID = UUID()
        let text = PreviewPopoverDataBridge.shared.fullText(for: item)
        let model = PreviewPopoverContentModel(item: item,
                                               source: source,
                                               entry: entry,
                                               sessionID: sessionID,
                                               inlineText: text,
                                               showsKeyboardHint: showsKeyboardHint)

        let slot = MainPanelPreviewPopoverSlot(contentModel: model)
        let host = MainPanelPreviewPopoverSlotHostView(model: model) { [weak self] reason in
            self?.dismiss(reason: reason)
        }
        let controller = NSHostingController(rootView: host)
        let height = estimatedHeight(for: model)
        controller.preferredContentSize = NSSize(width: popoverWidth, height: height)
        slot.popover.contentViewController = controller
        self.slot = slot

        guard let (anchorHostView, anchorRect) = resolveAnchor(preferredView: anchorView,
                                                               rectInWindow: anchorRectInWindow) else {
            self.slot = nil
            return false
        }
        // 箭头边缘：按条目屏几何动态计算，防越屏翻转
        let screenFrame = anchorHostView.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let anchorInScreen = anchorHostView.window.map {
            $0.convertToScreen(anchorHostView.convert(anchorRect, to: nil))
        } ?? anchorRect
        let edge = PreviewArrowGeometrySupport.preferredNSRectEdge(anchorRectInScreen: anchorInScreen,
                                                                   popoverSize: NSSize(width: popoverWidth, height: height),
                                                                   screenFrame: screenFrame)
        slot.state = .presenting
        slot.popover.show(relativeTo: anchorRect, of: anchorHostView, preferredEdge: edge)

        activeItemID = item.id
        // v65：无条件安装点外监听（behavior 恒 applicationDefined，点外关闭由协调器负责；
        // 此前只在 📌 模式安装，transient 模式全靠系统行为——在 nonactivating 面板上失灵）
        installOutsideClickMonitor()
        track("main_panel_preview", "exposed", model)
        return true
    }

    /// 关闭预览（可带完成回调；面板收起等待预览先关时由 PanelController 调用，reason = .panelCollapse）
    public func dismiss(reason: MainPanelPreviewPopoverCloseReason = .programmatic,
                        completion: (() -> Void)? = nil) {
        removeOutsideClickMonitor()
        guard let slot, slot.state != .idle else {
            completion?()
            return
        }
        if let completion {
            let previous = pendingCloseCompletion
            pendingCloseCompletion = { previous?(); completion() }
        }
        closeSlot(reason: reason)
    }

    /// closeAll 别名（语义化入口：面板收起/全局清理）
    public func closeAll(reason: MainPanelPreviewPopoverCloseReason, completion: (() -> Void)? = nil) {
        dismiss(reason: reason, completion: completion)
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
        // F3 抑制期：popover 关闭后鼠标未移动前不复弹
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

    // MARK: popover 内悬停保活（F4）

    /// popover 内容悬停仲裁（宿主视图经 onPreviewPopoverHoverChanged 转入）：
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
    // 默认（跟随式）：鼠标移开预览就收起。
    // 固定式（📌 开）：hover 离开不再收起，只有点击预览外部（面板/其他 App）或 Esc 才关，
    // 方便一边看预览一边操作别处。两种模式随时用预览右上角的 📌 切换，选择会记住。

    /// 预览是否固定（UserDefaults 持久化，跨启动记忆）
    public var previewPinned: Bool {
        get { UserDefaults.standard.bool(forKey: "panel.previewPinned") }
        set {
            UserDefaults.standard.set(newValue, forKey: "panel.previewPinned")
            if newValue { installOutsideClickMonitor() } else { removeOutsideClickMonitor() }
        }
    }

    private var outsideGlobalMonitor: Any?
    private var outsideLocalMonitor: Any?

    private func installOutsideClickMonitor() {
        guard outsideGlobalMonitor == nil, outsideLocalMonitor == nil else { return }
        // 点其他 App
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss(reason: .programmatic)
        }
        // 点本 App（面板本体等）；点击 popover 内容窗口不算「外部」
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popoverWindow = self?.slot?.popover.contentViewController?.view.window,
               event.window === popoverWindow {
                return event
            }
            self?.dismiss(reason: .programmatic)
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideGlobalMonitor { NSEvent.removeMonitor(m); outsideGlobalMonitor = nil }
        if let m = outsideLocalMonitor { NSEvent.removeMonitor(m); outsideLocalMonitor = nil }
    }

    // MARK: 导航（F7）

    /// 提供当前过滤态下的条目顺序表（dev-clipboard 在列表变化时调用）
    public func setPreviewOrder(_ ids: [String]) {
        previewOrder = ids
    }

    /// 条目间移动预览（clipboardPreviewNavigate action；埋点 item_preview_navigation）
    public func navigate(_ command: PreviewNavigationCommand,
                         items: [ClipboardItem],
                         anchorProvider: @escaping () -> CGRect?) {
        guard !previewOrder.isEmpty, let current = activeItemID,
              let index = previewOrder.firstIndex(of: current) else { return }
        let targetID: String?
        switch command.direction {
        case .previous: targetID = index > 0 ? previewOrder[index - 1] : nil
        case .next:     targetID = index < previewOrder.count - 1 ? previewOrder[index + 1] : nil
        }
        guard let id = targetID, let item = items.first(where: { $0.id == id }) else { return }
        guard let rect = anchorProvider() else { return }
        present(for: item, anchorRectInWindow: rect, source: activeSource)
        track("item_preview_navigation", command.direction.rawValue, nil)
        track("preview_navigation", command.direction.rawValue, nil)
    }

    // MARK: 滚动跟随与校验（F8/P6）

    /// 列表滚动时上报条目几何（__trackedPreviewItemMinYByID）；锚条目出视口即关闭
    public func itemFrameChanged(itemID: String, minY: CGFloat, viewportTop: CGFloat, viewportBottom: CGFloat) {
        trackedPreviewItemMinYByID[itemID] = minY
        guard itemID == activeItemID else { return }
        let estimatedRowHeight: CGFloat = Theme.rowHeight
        let itemBottom = minY + estimatedRowHeight
        if itemBottom < viewportTop || minY > viewportBottom {
            pendingPreviewVisibilityValidationTargetID = itemID
            dismiss(reason: .scrolledOutOfViewport)
        }
    }

    /// 滚动停止后的可见性校验钩子（__pendingPreviewVisibilityValidationTargetID/Direction）
    public func validatePreviewVisibility(anchorItemID: String, isVisible: Bool) {
        guard anchorItemID == activeItemID else { return }
        pendingPreviewVisibilityValidationTargetID = isVisible ? nil : anchorItemID
        if !isVisible { dismiss(reason: .scrolledOutOfViewport) }
    }

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

    private func estimatedHeight(for model: PreviewPopoverContentModel) -> CGFloat {
        // 📌 固定条占 18pt
        let extra: CGFloat = 18
        return extra + model.estimatedPopoverHeight(maxPopoverHeight: maxPopoverHeight,
                                     imagePreviewMaxPopoverHeight: imagePreviewMaxPopoverHeight,
                                     textPreviewLoadingMinHeight: textPreviewLoadingMinHeight)
    }

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

    private func scheduleHoverClose() {
        guard hoverPreviewCloseWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverPreviewCloseWorkItem = nil
            if self.isPreviewPopoverHovered { return }   // F4：SwiftUI 探测鼠标在 popover 内
            // v71 兜底（用户实障：hover 图片预览想复制 OCR 文本，鼠标一移过去预览即消）：
            // SwiftUI onHover 在 popover 弹出动画期间 / NSViewRepresentable（OCR 的
            // NSTextView）上方 / nonactivating 面板 key 窗口切换瞬间可能迟到或丢失，
            // isPreviewPopoverHovered 恒 false → 倒计时到点误判「已移出」→ hoverOut 关闭。
            // 改为以鼠标屏幕实测位置为准：落在 popover 窗口 frame（含箭头）内 → 递归
            // 重调度继续等待，形成「关闭流程激活期间的轻量轮询」，鼠标真正离开才关。
            if let popoverWindow = self.slot?.popover.contentViewController?.view.window,
               popoverWindow.frame.contains(NSEvent.mouseLocation) {
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
        slot.popover.performClose(nil)
        // performClose 后 didCloseNotification 会到达 handlePopoverDidClose 完成清理
    }

    private func handlePopoverWillShow(_ note: Notification) {
        guard let slot, (note.object as? NSPopover) === slot.popover else { return }
        slot.state = .presented
        // v65：applicationDefined popover 会成为 key window——打上标识，让
        // PanelController.windowDidResignKey 豁免（否则面板因失焦被 hide，
        // 预览还开着、面板却没了）。
        slot.popover.contentViewController?.view.window?.identifier =
            NSUserInterfaceItemIdentifier("frset.panelPreviewPopover")
    }

    private func handlePopoverDidClose(_ note: Notification) {
        guard let slot, (note.object as? NSPopover) === slot.popover else { return }
        let reason = slot.pendingCloseReason
        self.slot = nil
        activeItemID = nil
        isPreviewPopoverHovered = false
        trackedPreviewItemMinYByID.removeAll()
        pendingPreviewVisibilityValidationTargetID = nil
        // F3：关闭后抑制悬停复弹，直到鼠标移动
        beginHoverSuppression()
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

/// 条目屏几何 + popover 内容屏框 → arrowEdge（防越屏翻转）
public enum PreviewArrowGeometrySupport {
    /// NSPopover 呈现用的优先边：右侧放得下放右侧，否则左侧，再否则取空间大的一侧
    public static func preferredNSRectEdge(anchorRectInScreen: CGRect,
                                           popoverSize: CGSize,
                                           screenFrame: CGRect) -> NSRectEdge {
        let leftRoom = anchorRectInScreen.minX - screenFrame.minX
        let rightRoom = screenFrame.maxX - anchorRectInScreen.maxX
        if rightRoom >= popoverSize.width { return .maxX }
        if leftRoom >= popoverSize.width { return .minX }
        return rightRoom >= leftRoom ? .maxX : .minX
    }

    /// SwiftUI Edge 映射（供 .popover(arrowEdge:) 使用）
    public static func swiftUIEdge(for rectEdge: NSRectEdge) -> Edge {
        switch rectEdge {
        case .maxX: return .trailing
        case .minX: return .leading
        case .maxY: return .top
        case .minY: return .bottom
        @unknown default: return .leading
        }
    }
}

/// 箭头几何缓存（按条目 id 记忆最近计算的边；classname 实证 @0x100acce7c）
public final class PreviewArrowGeometryStore {
    public static let shared = PreviewArrowGeometryStore()
    private var cachedEdges: [String: Edge] = [:]

    public func arrowEdge(for anchorItemID: String,
                          anchorRectInScreen: CGRect,
                          popoverSize: CGSize,
                          screenFrame: CGRect) -> Edge {
        let rectEdge = PreviewArrowGeometrySupport.preferredNSRectEdge(anchorRectInScreen: anchorRectInScreen,
                                                                       popoverSize: popoverSize,
                                                                       screenFrame: screenFrame)
        let edge = PreviewArrowGeometrySupport.swiftUIEdge(for: rectEdge)
        cachedEdges[anchorItemID] = edge
        return edge
    }

    public func cachedEdge(for itemID: String) -> Edge {
        cachedEdges[itemID] ?? .leading
    }

    public func invalidate() {
        cachedEdges.removeAll()
    }
}

// MARK: - SwiftUI 环境键（specs/12 类清单：isPreviewPopoverHovered / onPreviewPopoverHoverChanged）

private struct IsPreviewPopoverHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// 鼠标是否在预览 popover 内容内（F4 __isPreviewPopoverHovered；`__` 前缀 = @Environment 包装存储名）
    var isPreviewPopoverHovered: Bool {
        get { self[IsPreviewPopoverHoveredKey.self] }
        set { self[IsPreviewPopoverHoveredKey.self] = newValue }
    }
}

public extension View {
    /// popover 内容根视图挂接：写入环境值并通知协调器做保活/关闭仲裁
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
