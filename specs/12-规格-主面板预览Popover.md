# 12 - 规格：主面板条目预览 Popover

> 2026-10-15。补全 04 号 B4 的粗粒度描述（原句「悬停/空格 → PreviewPopoverView」不准确，见本文勘正）。
> 上游：11 号总纲 §2 任务书 ＋ 02 号方法论 ＋ 04 号主面板 / 05 号剪贴板。
> 方法：类型名 xref（ObjC classname 反查 + Swift 反射字段考古）+ 字符串考古 + defaults 实测 + cstring 文案。
> 探针截图无预览 Popover 实拍（`rea-evidence/ui-probe/` 只有设置页）——UI 视觉细节⬜。

---

## ⚠️ 重建版交互差异（必改项，planning 金证确认）

**原作主面板条目交互：单击 = 打开预览（不复制）、双击或按 ↩ = 复制、右键 = 菜单。**
重建版现行为「单击 = 复制」（05 号 §4 交互注记）与原作不符，**实现本规格时必须把行点击语义改为单击预览/双击复制**，并同步 05 号 B 系与行为对照表。证据：提示文案簇 0x100b43c50-0x100b43da0（§1 F5）。

---

## 0. 一句话结论

主面板条目预览是一个由 `MainPanelPreviewPopoverCoordinator` 统一调度的 **SwiftUI `.popover()`（NSPopover 底座）**：**悬停（带开/关延时与 hover-intent 阈值）、单击、空格键**三种触发方式；内容按 `PreviewPopoverContentModel` 分态渲染（文本/落盘长文本/Markdown/JSON/代码/图片/文件）；箭头边缘由 `PreviewArrowGeometryStore` 按条目几何动态计算；**单击=预览、双击=复制、右键=菜单**是全局交互模型（Tip 文案实证）。

---

## 1. 功能点表

| # | 功能点 | 状态 | 证据 |
|---|---|---|---|
| F1 | 悬停预览：条目行/缩略图 hover → 延时开启 popover（DispatchWorkItem：`__hoverPreviewOpenWorkItem`）；移出 → 延时关闭（`__hoverPreviewCloseWorkItem`） | ✅ 行为/⬜ 数值 | reflstr `hoverPreviewOpenDelay`@0x100aef750、`hoverPreviewCloseDelay`@0x100aef770、`activeHoverIntentThreshold`@0x100aef790、`__hoverWorkItem`@0x100aed215 |
| F2 | 悬停预览总开关：主面板 `hoverPreviewInMainWindowEnabled`、悬浮剪贴板 `hoverPreviewInFloatingClipboardEnabled` | ✅ | cstring UserDefaults 键 @0x100b4deb0/0x100b4ded0；设置键枚举 switch 表 0x100382b88-0x100382bc0；设置行标题 "Quick Preview"（immediate 串 0x100612244-0x100612260）与描述 "Show preview when hovering over clipboard icons" @0x100b52240 |
| F3 | hover 抑制：popover 关闭后 `__suppressHoverUntilMouseMove` 抑制复弹，鼠标移动才恢复 | ✅ 行为 | reflstr 0x100aef650、0x100af9f10、`isHoverSuppressed`@0x100af06c0、`onSuppressHoverUntilMouseMove`@0x100af0720 |
| F4 | popover 悬停保活：鼠标移入 popover 内不关闭（`__isPreviewPopoverHovered` 环境值 + `onPreviewPopoverHoverChanged` 修饰符） | ✅ | reflstr 0x100aef590 / 0x100aefa50；`_isClipboardSummaryPreviewHovered`@0x100af00d0 |
| F5 | 单击预览 / 双击或按 ↩ 复制 / 右键菜单（主面板与悬浮窗同模型） | ✅ | Tip 文案簇（中英双语全量）：英文 "Frset Tip: Single-click an item to preview"@0x100b43c80、"Double-click an item to copy"@0x100b43c50、"Right-click for more actions"@0x100b43ce0；中文 "单击或按空格预览"@0x100b43d30、"双击或按 ↩ 复制"@0x100b43d10、"Frset 提示：单击条目可预览"@0x100b43da0、"Frset 提示：双击条目可复制"@0x100b43d70 |
| F6 | 键盘预览（空格）：带延时 WorkItem（`__keyboardPreviewPresentationWorkItem`）+ 一次性提示（`clipboard_keyboard_preview_hint_consumed`） | ✅ | reflstr 0x100aef480/0x100aef4a0；defaults 实测 `clipboard_keyboard_preview_hint_consumed = 1`；hint 文案 "Click or Space to preview"@0x100b43c10 |
| F7 | 预览导航：在条目间移动预览（`clipboardPreviewNavigate` AppKit action 名 + `preview_navigation`/`item_preview_navigation` 事件 + `_previewOrder` 顺序表） | ✅ 行为/⬜ 键位 | action 字符串 @0x100b4ace0（bridge 存 0x100d3b9f8 @0x100283f3c）；事件名 @0x100b43580/0x100b435a0；命令字段 `__mainListPreviewNavigationCommand`@0x100af1f80、`__previewNavigationCommandSequence`@0x100af1f50 |
| F8 | 跟随与校验：列表滚动时跟踪条目位置（`__trackedPreviewItemMinYByID`）、滚动后校验锚条目可见性再决定保持/关闭（`__pendingPreviewVisibilityValidationTargetID/Direction`）、程序化滚动（`__isProgrammaticPreviewScrollInFlight`、`__programmaticPreviewScrollTargetID`）、分页请求（`__pendingPreviewPaginationRequest`） | ✅ 行为 | reflstr 0x100aefc70/0x100aefd20/0x100aefd50/0x100aefc90/0x100aefcc0/0x100aefe10 |
| F9 | 会话化：每次呈现携带 `__previewSessionID`；`__previewSource` 区分 mainPreview / floatingPreview | ✅ | reflstr 0x100aefbc0 / 0x100aef426；case 名 `mainPreview`@0x100aecdb6、`floatingPreview`@0x100aecde2 |
| F10 | 关闭协议：`MainPanelPreviewPopoverCloseReason` 枚举分类关闭原因；面板收起前等待预览关闭（`waitsForPreviewClose`、`previewWindows`、`previewCloseObserver`）；订阅 NSPopoverWillShow/DidCloseNotification（Combine） | ✅ 行为/⬜ case 集 | 类型名 @0x10096a3f0；reflstr 0x100aecd40-0x100aecd80；`_NSPopoverWillShowNotification` 订阅 @0x1000b5504、DidClose @0x1000aee14 |
| F11 | 埋点：`main_panel_preview` 事件（action 态含 "exposed" 等）与主面板活动区枚举 `main_panel_item / main_panel_preview / main_panel_search_result / main_panel_keyboard` | ✅ | 事件名 @0x100b42e40（×4 引用 0x1000aa92c-0x1000ad540，枚举哈希函数逐 case 解码）；"exposed" 立即数 @0x1000ad410 |
| F12 | 图片加载：`PreviewImageLoader` 专用队列 `com.frset.preview-image-decoder`；缓存尺寸上限 `previewCacheMaxWidth/Height`；按屏 `previewBackingScale` 渲染；缩略→大图 `previewNeedsFullRebuild` | ✅ 行为/⬜ 数值 | 队列 label cstring @0x100b424c0（创建函数 0x1000446c0：`objc_allocWithZone`→setName→set qos）；reflstr 0x100af8490-0x100af8879 |
| F13 | 内容尺寸约束：`maxPopoverHeight`、`imagePreviewMaxPopoverHeight`、`imagePreviewHeaderFooterHeightForQRCode`/`ForRegularImage`、`imagePreviewVerticalPaddingHeight`、`textPreviewLoadingMinHeight`、`previewLoadingIndicatorDelay` | ✅ 字段/⬜ 数值 | reflstr 0x100aec3f0、0x100af4bd0-0x100af4c50、0x100af5350/0x100af5370 |
| F14 | 代码预览尺寸阶梯：compact/min/max 高度、min/medium/max 宽度、行数/字符分析上限、内边距 | ✅ 字段/⬜ 数值 | reflstr 0x100af5170-0x100af5290（`codePreviewCompactMinHeight`…`codePreviewContentPadding`） |
| F15 | 滚动位置记忆（Markdown/长文）：块帧表 + 偏移 + 恢复请求 + 程序化滚动请求（重开预览回到原滚动位） | ✅ 行为 | reflstr 0x100aee8d0-0x100aeea60（`__markdownPreviewBlockFrames`…`__markdownPreviewCapabilityTask`） |
| F16 | JSON 预览资格与截断：`__isJSONPreviewEligible`、`__jsonPreviewEligibilityKey`、`jsonPreviewCharCap` | ✅ 字段/⬜ 数值 | reflstr 0x100af4f20/0x100af4f40/0x100af50f0 |
| F17 | 落盘长文本异步加载：`__fileBackedPreviewLoadState` + `__filePreviewLoadTask` + `__filePreviewLoadGeneration`（代际防串）+ `__filePreviewFullText` | ✅ | reflstr 0x100af4d00-0x100af4d80 |
| F18 | 呈现模式/过渡：`__previewPresentationMode`、`__previewTransitionStyle` | ✅ 字段/⬜ case 值 | reflstr 0x100aefb80/0x100aefba0 |
| F19 | 入口多态：主列表 / 过滤会话 / 搜索工具结果 三种入口各自标记（`__isMainListPreviewPresented`、`__isFilterSessionPreviewPresented`、`__isSearchToolResultPreviewPresented`） | ✅ | reflstr 0x100af1dd0/0x100af1df0/0x100af20f0 |

---

## 2. 类清单

| 类 | 推断职责 | 证据地址 |
|---|---|---|
| `MainPanelPreviewPopoverCoordinator` | 预览协调器：管理 Slot 生命周期、订阅 NSPopoverWillShow/DidClose（Combine sink）、发 `main_panel_preview` 埋点、被视图模型以 `mainPanelPreviewCoordinator` 字段持有 | classname @0x100acbadc；通知订阅 @0x1000b5504（WillShow）/0x1000aee14（DidClose）；埋点发射函数 0x1000ad37c；持有字段 reflstr 0x100afecf0、0x100aefb30、0x100af19b0、0x100af9bb0 |
| `MainPanelPreviewPopoverSlot` | 单个预览 popover 实例（槽位）：状态机 SlotState + 关闭原因 CloseReason；`init()` 报告「未实现初始化器」（仅 ObjC 运行时占位） | classname @0x100acbb0c；`reportUnimplementedInitializer` 调用 @0x10005a0b0（串 "Frset.MainPanelPreviewPopoverSlot" @0x100b42500） |
| `MainPanelPreviewPopoverSlotHostView` | Slot 的宿主视图（承接 popover 内容/命中判定） | 类型名 @0x10096a3c0（__TEXT,__const 类型名区） |
| `MainPanelPreviewPopoverSlotState` | Slot 状态机枚举（case 集⬜） | 类型名 @0x10096a420 |
| `MainPanelPreviewPopoverCloseReason` | 关闭原因枚举（case 集⬜） | 类型名 @0x10096a3f0 |
| `PreviewPopoverContentModel` | 内容状态模型：条目 + 分态（文本/MD/JSON/代码/图片/文件）+ 加载状态 + 会话 | classname @0x100accfcc；持有字段 `_previewContentModel`@0x100aebe40、`__previewContentItem`@0x100aefb60、`previewContentImage`@0x100af8430、`previewContentSegmentCount`@0x100af8450、`previewNeedsFullRebuild`@0x100af8470 |
| `PreviewPopoverView` | 内容 NSView（`init(coder:)` fatal → NSView 子类，PreviewPopoverView.swift:37）；负责代码/文本类渲染（与 05 号 `CodeLineNumberRulerView` 协作） | init(coder:) fatal @0x100354718（file 串 @0x100b4ca70，line=0x25）；源文件清单 04 号 |
| `PreviewImageLoader` | 图片解码器：专用 DispatchQueue `com.frset.preview-image-decoder`（带 qos）、缓存上限、backingScale | classname @0x100acbabc；队列创建 @0x1000446c0（label @0x100b424c0）；字段 `_previewImageLoader`@0x100aebe60/0x100af47d0 |
| `PreviewArrowGeometryStore` | 箭头几何缓存/计算（条目在屏几何 → arrowEdge） | classname @0x100acce7c；字段 `_previewArrowGeometryStore`@0x100af1be0/0x100af47b0；配套源文件 "Frset/PreviewArrowGeometrySupport.swift" @0x100b4ca20（代码引用 @0x10033025c） |
| 环境键 `isPreviewPopoverHovered` / 修饰符 `onPreviewPopoverHoverChanged` | SwiftUI EnvironmentValues 扩展（`__` 前缀 = `@Environment` 包装存储名） | reflstr 0x100aef590 / 0x100aefa50 |

---

## 3. 还原依据（四源对齐）

| 源 | 内容 |
|---|---|
| 汇编 | 类型名 xref（§2 地址列）；提示文案 cstring（0x100b43bf0-0x100b43da0 簇）；设置键枚举 switch 表 0x100382b88 区；`clipboardPreviewNavigate` bridge @0x100283f3c；队列创建 @0x1000446c0；`main_panel_preview` 埋点簇 0x1000aa92c-0x1000ad540；init(coder:) fatal @0x100354718；WhatsNew 注记 "优化长篇 Markdown 文本与代码的预览体验。" @0x100b57e00（引用 0x100779738）/ "悬浮剪贴板交互调整为单击预览、双击粘贴。" @0x100b57d50（引用 0x1007797c4，planning 提供） |
| defaults | `clipboard_keyboard_preview_hint_consumed = 1`（实测 /tmp/frset-re/defaults-com.maoux.frset.txt:18）；`hoverPreviewInMainWindowEnabled` 无存储值 → **默认开启**（键存在而未落盘）；`hasSeenDoubleTapShortcutTip_v1 = 1` |
| 探针截图 | ⬜ 无预览 Popover 实拍（ui-probe/final-test 均为设置页）——popover 视觉（宽度/圆角/材质）未证实 |
| 既有 schema/文档 | 04 号 B4（预览入口）、05 号 B13（大文本 MD/JSON 渲染 + Preview*PreferenceStore 开关）、05 号 §1.6（渲染类群）、01 号 191 类清单（类名群） |

**对 04 号的勘正**：B4「悬停/空格 → PreviewPopoverView（文本/图片/JSON/Markdown 高亮）」应更新为——
触发 = 悬停（延时+开关）+ 单击 + 空格；交互模型 = 单击预览/双击复制/右键菜单；内容另含代码高亮、文件落盘文本异步加载、图片（含 QR 分支）、滚动位置记忆、条目间导航。

**技术栈判定**：SwiftUI `.popover(isPresented:attachmentAnchor:arrowEdge:content:)` 家族调用全量反汇编 7 处（0x10006c944、0x1000703e8、0x1000822d8、0x1000c3f18、0x1001a2748、0x1001d7380、0x10061bc48，符号桩 `_$s7SwiftUI4ViewPAAE7popover…` / `popoverCore…`，anchor 形参 `PopoverAttachmentAnchor.rect(SourceRect)`）+ NSPopover 通知订阅——主面板预览用 SwiftUI `.popover()`（NSPopover 底座），**不是**自制 NSPanel。`PreviewPopoverView`（NSView）经 representable/宿主层挂入。

---

## 4. 源码骨架（Swift，类型名沿原作；与 04/05 号衔接）

```swift
// 4.1 挂接点：ClipboardSectionView（05 号 §1.3）行视图上；FloatingClipboard 行复用同一 ContentModel（source = .floatingPreview）
struct ClipboardRowView: View {
    @Environment(\.isPreviewPopoverHovered) private var isPreviewPopoverHovered   // reflstr 0x100aef590
    @State private var previewArrowEdge: Edge                                      // __previewArrowEdge 0x100aef670

    var body: some View {
        rowContent
            .popover(isPresented: $presented,
                     attachmentAnchor: .rect(boundsOf: rowFrame),                  // .rect(SourceRect) 实证
                     arrowEdge: previewArrowEdge) {                                // 动态箭头
                MainPanelPreviewPopoverSlotHostView(
                    model: contentModel,
                    onClose: { coordinator.close(reason:) })                       // CloseReason 枚举
            }
            .onHoverChanged { hovering in
                coordinator.rowHover(hovering, itemID: item.id)                    // hoveredRowItemID 0x100aef270
            }
            .onPreviewPopoverHoverChanged { inside in
                coordinator.popoverHoverChanged(inside)                            // 保活/关闭仲裁
            }
    }
}

// 4.2 协调器（单例 per 面板；视图模型字段 mainPanelPreviewCoordinator）
final class MainPanelPreviewPopoverCoordinator {
    private var slot: MainPanelPreviewPopoverSlot?
    private var openWorkItem: DispatchWorkItem?      // __hoverPreviewOpenWorkItem
    private var closeWorkItem: DispatchWorkItem?     // __hoverPreviewCloseWorkItem
    private var suppressHoverUntilMouseMove = false  // __suppressHoverUntilMouseMove
    private var sessionID = UUID()                   // __previewSessionID

    // 延时常量（数值⬜，命名沿原作反射字段）
    var hoverPreviewOpenDelay: TimeInterval          // 开启延时
    var hoverPreviewCloseDelay: TimeInterval         // 关闭延时
    var activeHoverIntentThreshold: TimeInterval     // hover-intent 阈值

    private init() {
        // NSPopoverWillShow/DidCloseNotification 订阅（Combine，实证 0x1000b5504/0x1000aee14）
        NotificationCenter.default.publisher(for: NSPopover.willShowNotification)...
        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)...
    }

    func rowHover(_ hovering: Bool, itemID: String) {
        guard settings.hoverPreviewInMainWindowEnabled else { return }             // 开关（默认 true）
        if suppressHoverUntilMouseMove { return }                                  // 抑制期
        hovering ? scheduleOpen(itemID) : scheduleClose()
    }
    func requestKeyboardPreview(_ itemID: String) { /* WorkItem 延时呈现；一次性提示 hasConsumedKeyboardPreviewHint */ }
    func navigate(_ command: PreviewNavigationCommand) { /* _previewOrder 表内移动；clipboardPreviewNavigate action */ }
    func popoverHoverChanged(_ inside: Bool) { inside ? cancelClose() : scheduleClose() }
    func itemFrameChanged(itemID: String, minY: CGFloat) { /* __trackedPreviewItemMinYByID；出视口校验关闭 */ }
    func close(reason: MainPanelPreviewPopoverCloseReason) { /* 置 CloseReason → Slot → 关闭 → suppressUntilMouseMove */ }
}

// 4.3 Slot 与状态
final class MainPanelPreviewPopoverSlot {
    enum SlotState { /* case 集⬜：推测 idle/loading/presented/closing */ }
    var state: SlotState
    var contentModel: PreviewPopoverContentModel
}
enum MainPanelPreviewPopoverCloseReason { /* case 集⬜：推测 hoverOut/panelDismiss/itemRemoved/escape/programmatic */ }

// 4.4 内容模型分态（PreviewPopoverContentModel）
struct PreviewPopoverContentModel {
    enum Source { case mainPreview, floatingPreview }                              // 0x100aecdb6/0x100aecde2
    enum Content {                                                                 // 分态（渲染开关来自 05 号 §1.6 PreferenceStore）
        case text(String)                                   // textPreviewLoadingMinHeight + loading delay
        case fileBacked(path: String)                       // __fileBackedPreviewLoadState/LoadTask/LoadGeneration 异步全文
        case markdown(String, restore: MarkdownScrollState) // blockFrames/scrollOffset 恢复
        case json(String)                                   // eligibility key + jsonPreviewCharCap 截断
        case code(String)                                   // codePreview 尺寸阶梯 + 行号标尺
        case image(URL, fullRebuild: Bool)                  // PreviewImageLoader；cacheMax 尺寸；backingScale
    }
}

// 4.5 图片加载（原作实证：专用串行队列）
final class PreviewImageLoader {
    private let decoderQueue = DispatchQueue(label: "com.frset.preview-image-decoder",
                                             qos: .userInitiated)                   // 0x1000446c0
    var previewCacheMaxWidth: CGFloat      // 缩略→大图重建阈值
    var previewCacheMaxHeight: CGFloat
    var previewBackingScale: CGFloat       // 屏幕倍率
    func load(item: ClipboardItem, needsFullRebuild: Bool) { /* decoderQueue 解码 → 发布 */ }
}

// 4.6 箭头几何
enum PreviewArrowGeometrySupport {                                                 // 源文件名 @0x100b4ca20
    // 条目屏几何 + popover 内容屏框(__popoverContentScreenFrame) → arrowEdge（防越屏翻转）
}
final class PreviewArrowGeometryStore {                                            // classname @0x100acce7c
    func arrowEdge(for anchorItemID: String, contentFrame: CGRect) -> Edge
}
```

---

## 5. 行为对照条目（回填 tests/行为对照表.md）

| # | 场景 | 原作行为（证据） |
|---|---|---|
| P1 | 悬停主面板条目（开关开启） | 延时开启预览 popover；`hoverPreviewInMainWindowEnabled` 控制开关且默认开启（键 0x100b4deb0 无落盘值） |
| P2 | 鼠标移出条目 | 延时关闭（`hoverPreviewCloseDelay` WorkItem）；移入 popover 内则取消关闭（`__isPreviewPopoverHovered`） |
| P3 | popover 关闭后鼠标未移动 | 悬停被抑制直到鼠标移动（`__suppressHoverUntilMouseMove`） |
| P4 | 单击条目 | 打开预览（不复制）；双击或按 ↩ 复制（Tip 文案 0x100b43c80/0x100b43d10/0x100b43d70 + `hasSeenDoubleTapShortcutTip_v1`）；⚠️ 重建版现「单击=复制」须改 |
| P5 | 选中列表后按空格 | 延时打开键盘预览；首次显示提示（`clipboard_keyboard_preview_hint_consumed`，defaults=1） |
| P6 | 预览打开时滚动列表 | 跟踪条目 minY；滚动停止后校验锚条目可见性，出视口则关闭（`__trackedPreviewItemMinYByID`/`__pendingPreviewVisibilityValidation*`） |
| P7 | 预览导航命令 | 按顺序表在条目间移动预览（`clipboardPreviewNavigate` action、`_previewOrder`、埋点 `item_preview_navigation`） |
| P8 | 面板收起时预览开着 | 先等预览关闭再收起（`waitsForPreviewClose`/`previewWindows`/`previewCloseObserver`） |
| P9 | 图片条目预览 | 缩略图先显示，`previewNeedsFullRebuild` 触发大图重建；专用队列解码；缓存尺寸上限 |
| P10 | 长文本/Markdown 预览关闭再开 | 恢复上次滚动位置（`__markdownPreviewBlockFrames`/`__markdownPreviewScrollOffset`/restore request） |
| P11 | 落盘长文本预览 | 显示 loading 最小高度占位，异步加载全文（`__filePreviewLoadTask` + generation 防串），`previewLoadingIndicatorDelay` 延迟显示指示器 |
| P12 | 埋点 | 预览呈现/交互发 `main_panel_preview` 事件（action 含 "exposed"），面板活动区枚举含 `main_panel_preview` 态 |

---

## 6. 待查清单（⬜ 未探明 + 已尝试手段）

| # | 待查 | 已尝试手段 | 结论状态 |
|---|---|---|---|
| 1 | hover 开/关延时与 hover-intent 阈值**数值** | 全文件搜字段名（仅 reflstr 命中 0x100aef750-0x100aef790，非 UserDefaults 键）；未能在无符号反汇编中定位赋值常量 | ⬜ 数值未知（骨架按可调参数留位） |
| 2 | `maxPopoverHeight` / `imagePreviewMaxPopoverHeight` / code 尺寸阶梯等**数值** | reflstr 字段名实证（0x100aec3f0、0x100af4bd0-0x100af5290）；数值需逐函数窗读初始化路径 | ⬜ |
| 3 | `MainPanelPreviewPopoverCloseReason` / `SlotState` case 集 | 类型名区 dump（0x10096a3f0/0x10096a420 邻域为二进制元数据非字符串）；__DATA_CONST 0x100bb34b9 邻域为编码数据；`__swift5_types` 扫描未命中（strip 后描述符布局异构） | ⬜（推测语义见 §4.3，禁当实证） |
| 4 | 7 处 SwiftUI `.popover` 调用点中主面板预览的具体归属 | 调用点邻域无字符串池（SwiftUI 内容闭包隔离），数据流回溯成本高 | ⬜（架构判定不受影响：.popover 家族 + NSPopover 通知已实证） |
| 5 | Popover 视觉规格（宽度/材质/圆角/阴影） | 探针截图无实拍 | ⬜（需实机截图，ui-probe 补帧） |
| 6 | 单击切预览时同 item 重复点击/连续切换的精确判定窗口 | Tip/defaults 键证明交互模型；窗口值未见常量 | ⬜ |
| 7 | `__previewPresentationMode`/`__previewTransitionStyle` 的 case 值 | reflstr 字段名实证；case 名未解出 | ⬜ |
| 8 | `onWillOpenPersistentPreview`（持久预览）语义 | reflstr 0x100af0300 命中；上下文函数未回溯 | ⬜（疑与钉住/长驻预览相关，可能是 16 号钉图体系的相邻概念） |

## 7. 验收要点
- [ ] 悬停/单击/空格三路触发全部工作，开关默认开启
- [ ] 单击=预览、双击=复制、右键=菜单与原作一致
- [ ] 箭头边缘随条目位置翻转，不越屏
- [ ] 列表滚动跟随 + 出视口关闭
- [ ] 图片大图重建、落盘长文异步加载、Markdown 滚动恢复可用
- [ ] 行为对照 P1-P12 逐项通过

## 2026-10-20 富渲染修复（Markdown / JSON / 代码）

用户反馈：悬停预览与点击预览里 Markdown 富渲染不生效、JSON 表格没验证、代码没有语法高亮。
逐项定位到的根因与修复：

### 1. Markdown 行内样式（粗体/斜体）从来没生效

`AttributedString(markdown:)` 不会产出粗体字体，而是给 `.inlinePresentationIntent`。
Foundation 桥接到 NSAttributedString 时把它存成 **NSNumber**（NSInlinePresentationIntent = 1/2/4），
旧代码 `value as? InlinePresentationIntent` 恒为 nil → 粗体/斜体/行内代码样式全部丢失，
只有标题/列表/表格这类块级样式还在，观感上就是「富渲染没生效」。

修复 `PreviewMarkdownRenderer.inlineAttributed`：
- intent 取值兼容 `NSNumber`；`stronglyEmphasized` → bold、`emphasized` → italic、
  `code` → 等宽 + 浅底、`strikethrough` → 删除线；
- `.link` 统一染成 linkColor + 下划线 + 手型光标（AttributedString 只给 URL，不会着色）。

### 2. Markdown 识别过严（短文档被当成纯文本）

旧启发式要累计 2 分：一条 `**粗体**` 或一个行内代码只有 1 分 → 分态成 `.text`，走纯文本视图。
改为强信号命中即判定：标题 / 围栏 / 列表 / 引用 / 表格行 / 粗体 / 行内代码 / 链接 / 分隔线；
`__`/`~~` 仍需两条。误判成本仅是「排版更好看」，内容不丢。

### 3. 代码预览没有语法高亮

`PreviewCodeTextView` 之前是纯等宽文本（高亮只在 Markdown 围栏代码块里生效）。
改为 `PreviewMarkdownRenderer.renderCodeBody`：
- 按内容自动识别语言（新增 Swift 判定：import SwiftUI/Foundation、@State/@Published、func+->/guard；
  Go/Rust/Kotlin/Java 也各有特征），
- 关键字紫 / 字符串红 / 数字蓝 / 类型青 / 注释灰，行号与源码行一一对应。

### 4. JSON 表格只有「对象数组」可用

- 表格视图按根类型自动选表型：对象数组 → 键并集成列；对象根 → 键/值两列；标量数组 → 序号/值；
- 修复表格每次 body 求值调用 `toggle()` 反复翻转展开态的问题，新增 `ensureChildren()`（只建子级）；
- 为可测试性新增 `initialMode` 初始化参数（默认 .tree，行为不变）。

### 5. Markdown 表格列错位

`pad` 用 `String.count` 补空格，中文按 1 计而等宽字体占 2 列 → 行列全错位。
新增 `displayWidth`（东亚宽字符按 2 列）用于列宽与补白。

### 验证

- 离屏渲染（同一份 PreviewMarkdownRenderer 源码）：标题/列表/表格/引用/分隔线/有序列表正常；
  「粗体」属性为 SFNS-Bold、「Markdown」为斜体、代码块关键字紫色；
  中文表格三列对齐（/tmp 探针图，构建产物同源）。
- JSON：NSHostingView 离屏渲染对象根 → 键/值表（enabled/features/maxItems/name/owner/version）；
  对象数组 → id/name/score 三列表格。
- 代码：Swift/Python 样本语言识别正确，token 配色齐全。
- 应用内 popover 截图在本机被其它窗口抢焦点打断，未能稳定截到；渲染器与视图分态链路已按同源代码验证。
