# B1 — Features/Panel（主面板外壳、预览 Popover、Markdown/Mermaid/JSON、网盘）

> 范围：`apps/FrsetNext/Sources/Features/Panel/` 全部 **19** 个 `.swift`，合计 **7611** 行。
> 读取方式：整文件逐行读完，未抽样。
> 符号核对：`/tmp/frset_symbols.csv` 中本目录声明 **320** 条，其中 `func` **195** 条、`init` 25、`class` 24、`enum` 28、`struct` 43、`extension` 5。
> **CSV 缺口**：解析器对多行签名的 `func` 有漏记——本报告补记 9 个 CSV 缺失的函数：`MainPanelPreviewPopoverCoordinator.present(_:anchorRectInWindow:anchorView:source:entry:showsKeyboardHint:mode:)`、`.dismiss(reason:completion:)`、`.rowHover(_:item:source:anchorProvider:)`、`.requestKeyboardPreview(item:anchorProvider:)`、`PreviewImageLoader.loadImage(at:thumbnailURL:needsFullRebuild:completion:)`、`PreviewPopoverContentModel.estimatedPopoverHeight(...)`、`PanelPreviewPresenterAdapter.presentPreview(...)`、`PanelPreviewPresenterAdapter.rowHover(...)`、`PanelPreviewPresenterAdapter.requestKeyboardPreview(...)`（共 9 个）。本表实际列出 **204** 个函数级条目。

---

## 1. 文件清单

| 路径 | 行数 | 一句话职责 |
|---|---|---|
| `Panel/PanelModule.swift` | 31 | `AppModule` 入口：启 `PanelController.shared.prepare()`、把面板与预览适配器注入 `ServiceLocator`，并处理 `FRSET_JSON_PROBE` 排障探针 |
| `Panel/PanelController.swift` | 330 | 主面板单例控制器：建窗/开合/锚点定位/预热/置顶/尺寸持久化/失焦收起 |
| `Panel/PanelRootView.swift` | 726 | 面板 SwiftUI 根视图：顶部工具条 + 四段分段 + 四页按页实例化 + 底部悬浮工具条 + 拖放 |
| `Panel/FloatingPanel.swift` | 92 | `NSPanel` 子类（nonactivating/borderless）+ 玻璃材质与圆角应用 |
| `Panel/PanelPreviewPreferences.swift` | 99 | 预览相关 UserDefaults 键 + `PreviewPopoverDataBridge`（与 Clipboard 的编译期隔离数据桥） |
| `Panel/MainPanelPreviewPopoverCoordinator.swift` | 657 | 预览窗协调器：hover/空格/单击三路触发、关闭仲裁、抑制期、导航序、滚动记忆、箭头几何 |
| `Panel/PanelPreviewPresenterAdapter.swift` | 69 | `PanelPreviewPresenting` 协议实现，转调协调器（Clipboard 不直连 Panel 类型） |
| `Panel/PreviewPopoverContentView.swift` | 1153 | 预览内容视图族：8 个 kind 分态渲染 + NSTextView 基座 + 行号标尺 + 文件缩略图 + QuickLook |
| `Panel/PreviewPopoverContentModel.swift` | 300 | 内容模型：分态判定（JSON/Markdown/代码启发式）+ 高度估算 + 图片尺寸 |
| `Panel/PreviewMarkdownRenderer.swift` | 756 | Markdown 块级解析/渲染/12 语言语法高亮/表格/目录链接/渲染↔源区间映射 |
| `Panel/MermaidRenderer.swift` | 497 | 轻量 mermaid flowchart/plantuml 解析 + 分层布局 + CG 绘制成 NSImage |
| `Panel/JSONInspectorView.swift` | 696 | JSON 树/表/卡/原始四视图 + 节点懒构建 + 排序 + 筛选 |
| `Panel/JSONInspectorWindow.swift` | 238 | JSON 检视独立窗口（900×640，>32MB 拒绝）+ 宿主状态 |
| `Panel/CloudDriveLink.swift` | 185 | 8 家网盘域名识别、分享页判定、从文本/剪贴板提取链接 |
| `Panel/CloudLinkBar.swift` | 192 | 首页网盘链接条 + 预览底部操作条 + `CloudLinkActions.resolve` |
| `Panel/CloudLinkPrompt.swift` | 228 | 复制网盘链接后状态栏下方小胶囊提示（12s 自动收） |
| `Panel/CloudLinkCenter.swift` | 788 | 网盘解析中心窗口：5 项诊断（含 URLSession 探针）+ 全量下载配置 + 8 家支持列表 |
| `Panel/CloudLinkDownloader.swift` | 460 | 解析下载：直链判定、隐藏 WKWebView 抓直链、cookie 同步、并发队列/重试/aria2 RPC |
| `Panel/PreviewImageLoader.swift` | 114 | 预览图片串行解码器（ImageIO 下采样 + NSCache + in-flight 去重） |

---

## 2. 类型逐个说明

### 2.1 `PanelModule`（enum, `AppModule`）

- **职责**：模块注册入口。`identifier = "panel"`。
- **生命周期**：`ModuleRegistry` 启动期调一次 `start()`，无状态、不持有。
- **依赖**：`PanelController.shared`、`ServiceLocator`、`JSONInspectorWindowController`、`NSPasteboard`。
- **被依赖**：`App` 总控（Registry）。
- **副作用**：创建面板窗口（含整棵 SwiftUI 树）；`FRSET_JSON_PROBE` 存在时 2s 后开检视器。
- **注**：`ServiceLocator.panelPreview = PanelPreviewPresenterAdapter()` —— 只在这一处注册，Clipboard 侧一律经 `ServiceLocator.panelPreview`。

### 2.2 `PanelPresentationState`（ObservableObject）

- 两个 `@Published`：`visible`、`anchored`。**唯一职责**是驱动根视图的 `scaleEffect/offset/opacity` 动画与顶部三角。
- 由 `PanelController` 私有持有（`private let presentation`），以 `@ObservedObject` 传给根视图；不落盘。
- 陷阱：`warmupPanel()` 会临时把它置 `true` 再置回 `false`——若将来有别的观察者依赖它做副作用（如埋点「面板打开」），预热会造成一次假打开。

### 2.3 `PanelController`（NSObject, `PanelControlling`, `NSWindowDelegate`）

- **职责**：面板窗口的全部生命周期与开合策略；是 `ServiceLocator.panel`。
- **内部状态**：`panel: FloatingPanel?`、`presentation`、`warmupScheduled`、`isPinned`（读写 UserDefaults）。
- **生命周期**：`static let shared` 常驻；`prepare()` 幂等建窗；`panel` 只 `orderOut` 不销毁（`isReleasedWhenClosed = false`）。从不销毁。
- **依赖**：`FloatingPanel`、`PanelRootView`、`Preferences`、`Theme`、`ToastAnchor`、`TransientWindowCenter`、`MonitorSampler`、`MainPanelPreviewPopoverCoordinator`、`MonitorPopoutWindowController`、`StatisticsManager`、`RenderProbe`、`Personalization`。
- **被依赖**：状态栏（`toggle/show/hide`）、热键、`PanelModule`、`PanelRootView`（读 `isPinned`）、`CloudLinkPromptController`（间接经 StatusBarController 取锚点）。
- **关键不变量**
  - `prepare()` 必须在任何 `show` 之前（`show` 自带 `prepare()` 兜底）。
  - 面板宽度下限 320pt：`prepare` 与 `syncPanelFrameToPersonalization` 都做了 `max(...,320)` 钳制；`persistSize` 拒绝 <320×400 的尺寸。这是 v73 宽度污染回归的修复。
  - `hide()` 必须等预览关闭（`waitsForPreviewClose`）后再淡出，否则预览窗变孤儿。
  - `show()` 必须 `MonitorSampler.setHomePanelActive(true)`、`hide()` 完成回调里 `setHomePanelActive(false)`——两侧必须配对。

### 2.4 `FloatingPanel`（NSPanel）

- **职责**：无边框 nonactivating 浮窗，玻璃底 + 圆角 + `acceptsMouseMovedEvents`。
- **关键**：`hosting.sizingOptions = []`、`safeAreaRegions = []` —— 阻止 NSHostingView 把 SwiftUI fitting size 反压成窗口尺寸（v73 拉锯根因，与设置窗 800×1554 死循环同族）。
- **生命周期**：由 `PanelController.prepare()` 创建一次，永不销毁；`applyPersonalizedMaterial()` 在个性化变更/每次 `show` 时刷新材质。
- **副作用**：无写盘、无子进程。
- **`init?(coder:)`**：`fatalError`（对齐原作 nib 陷阱）。

### 2.5 `PreviewPopoverDataBridge` / `PreviewDataBridgeError` / `Preferences.Keys` 扩展

- **职责**：Panel 模块与 Clipboard 的**编译期隔离层**——四个闭包（`fullTextProvider` / `ocrTextProvider` / `saveOCRTextProvider` / `recognizeImageProvider` / `richTextProvider`）+ 未接线时的读盘兜底。
- **状态**：`shared` 单例，闭包由 App 总控接线，接线前为 `nil`。
- **失败模式**：未接线时 `fullText` 直接 `String(contentsOfFile:)`（**主线程同步 IO**，见风险 R3）；`recognizeImage` 抛 `notWired`。
- **注意**：`richTextAttributed(for:)` 在 `richTextProvider == nil` 时把 `item.richTextPath`（**相对路径**）当绝对路径读——注释自己也写明"桥内不知道根"。实测这段兜底基本必然失败（返回 nil），于是 `classify` 会退化成启发式链。

### 2.6 `MainPanelPreviewPopoverCoordinator` 家族

| 类型 | 职责 |
|---|---|
| `MainPanelPreviewPopoverCloseReason` | 7 个关闭原因枚举（hoverOut/itemRemoved/panelCollapse/escape/scrolledOutOfViewport/programmatic/systemInterruption），用作埋点 action |
| `PreviewNavigationCommand` | 上/下条导航命令结构（**当前无调用方**，死代码） |
| `MainPanelPreviewPopoverSlot` | 单槽实例：`state`(idle/presenting/presented/closing) + `contentModel` + `windowController` + `isEditing` |
| `MainPanelPreviewPopoverCoordinator` | 单例协调器：三路触发、关闭仲裁、抑制、埋点、滚动记忆 |
| `PreviewArrowGeometrySupport` / `PreviewArrowGeometryStore` | `NSPopover` 时代的箭头几何，**v71 后已无实际消费者**（死代码，仅 `cachedEdges` 自增） |
| `PreviewPopoverHoverChangedModifier` / `PreviewPopoverHoverProbe` / `EnvironmentValues.isPreviewPopoverHovered` | 预览内容 `onHover` → 环境值 + 回调协调器 |

- **槽位只有一个**（`private var slot`）：新预览必然先 `closeSlot(reason: .programmatic)` 关旧窗，因此"同屏两个预览"在结构上不可能。
- **单例 + 全局 NSEvent monitor**：`installOutsideClickMonitor` / `installEscapeMonitor` / `beginHoverSuppression` 都挂本地/全局 monitor，必须成对移除；`handlePreviewWindowDidClose` 是唯一的统一清理点。

### 2.7 `PanelPreviewPresenterAdapter`

- 无状态、`final class`，`private let coordinator = .shared`。纯转调 + 参数归一（`isFloatingSource` → `Source`）。由 `PanelModule.start()` 创建并挂到 `ServiceLocator.panelPreview`。

### 2.8 `PreviewPopoverContentView` 视图族

| 类型 | 职责 / 备注 |
|---|---|
| `PreviewPopoverContentView` | 按 `model.kind` 分态路由；文本命中网盘链接时底部追加 `CloudLinkPreviewAction` |
| `PreviewRichTextView` | `init` 内**同步**取 `richAttributed`（落盘 RTF 读取）→ `AttributedTextView` |
| `PreviewSourceTextView` (NSTextView) | 覆写 `copy(_:)`，按 `rendered↔source` 区间映射把选中内容还原成 Markdown 源文本 |
| `PreviewTextViewRepresentable` + `ScrollCoordinator` | NSScrollView + NSTextView 基座；滚动偏移上报/恢复、目录链接拦截、外链打开、行号标尺挂载 |
| `PreviewLineNumberRulerView` | 行号 `NSRulerView`，v126 改为数前缀换行符（去掉 O(前缀) 数组分配） |
| `PreviewTextContentView` | 纯文本，19.5pt（13×1.5） |
| `MarkdownFilePreviewBody` / `PreviewMarkdownTextView` / `MarkdownPreviewBody` | Markdown 正文 + 左侧目录 + 滚动记忆 + 回源复制，内联与落盘共用 `MarkdownPreviewBody` |
| `PreviewTOCSidebar` | 左侧目录（宽 180），`LazyVStack`，点击设 `scrollRequest` |
| `PreviewFileBackedTextView` | 落盘长文异步加载（`showIndicator` 延时、`loadGeneration` 代际防串）→ 再走 `classifyRawText` 分态 |
| `PreviewJSONTextView` | `prepare()` 截断到 `jsonPreviewCharCap` 后渲染；`body` 实际用 `JSONInspectorView(compact: true)`（`displayText` 计算了却没用 → 死状态） |
| `PreviewCodeTextView` | 语言自动识别 + 高亮 + 行号 |
| `PreviewImageView` | 缩略→大图两段加载、QR 分支、OCR 识别/复制/重识别、右上角「标注」发通知 |
| `PreviewFileView` | 路径列表、QuickLook、归档条目网格、解压、创建归档 |
| `PreviewFileThumbCache` / `PreviewFileThumbnailLoader` / `PreviewFileThumb` | 文件缩略图三级解码（ImageIO / CGPDF / QLThumbnailGenerator）+ NSCache(60) |
| `QuickLookPresenter` | `QLPreviewPanel` 数据源/委托单例 |

### 2.9 `PreviewPopoverContentModel` 家族

- `PreviewPopoverContentModel`：`Source`(mainPreview/floatingPreview)、`Entry`(mainList/filterSession/searchToolResult)、`Kind`(8 态)。`id = item.id`，`sessionID` 每次呈现新生成。
- 分态判定顺序：`type == .image → .image`；`.file → .file`；`.richtext → 有 RTF 则 .richText 否则 textPath ? .fileBackedText : classifyRawText`；`.text/.url → textPath ? .fileBackedText : classifyRawText`。
- `classifyRawText`：JSON → Markdown → 代码 → 文本（v87 统一链）。
- `MarkdownScrollState`（scrollOffset + anchorBlockID + blockFrames，仅 offset 实际使用）、`FilePreviewLoadState`。
- `String.lineCountEstimate` 扩展：逐字符数 `\n`，O(n) 但在高度估算里对全文跑。

### 2.10 `PreviewMarkdownRenderer` 家族

- `MarkdownBlock`（7 种块）、`MarkdownHeading`（含 `indent`）。
- `static var scale: CGFloat = 1.5` —— **全局可变静态量**，所有字号/间距乘它；`estimatedPopoverHeight` 也读同一系数，是"估算高度=实际渲染"的前提。
- `parseSourced` 是全文件最重的一段（122–275 行）：`autoreleasepool` 包裹、按行扫描、记录 `rendered↔source` 区间、裸代码整体识别。**纯同步、主线程**。
- 正则缓存：`cachedRe(_:)` 静态字典（**非线程安全**，见风险 R6）、`firstMatchRange`。
- 语法高亮：12 语言关键字 Set + 单遍标识符扫描（v126 优化）。

### 2.11 `MermaidRenderer`

- 单例；`image(for:maxWidth:)` 带 NSCache(24 项 / 16MB)。
- `parse` → `draw`（最长路径分层 → 同层均分 → CG 绘制）。`draw` 里用 `NSImage(size:flipped:) { }` 延迟绘制，注释明确禁止 `lockFocus` 同步绘制（会触发 Swift 独占访问冲突崩溃）。
- `parseStatement` 注释写明**必须是纯函数**（早前 inout+闭包触发 Fatal access conflict）。

### 2.12 `JSONInspectorView` 家族

- `JSONNodeKind`（6 种）、`JSONNodeModel`（引用语义 ObservableObject，`builtChildren` 懒构建，深度 >64 停止下钻）、`JSONDocument`（`maxNodes = 20000`、JSONL 回退、`sourceText`）。
- `JSONInspectorView`（树/表/卡/原始四模式，`compact` 影响字号/行高/key 宽）。
- 子视图：`JSONCardsView`、`JSONRawView`、`JSONTreeList`（递归 + LazyVStack）、`JSONTableView`（objectRows/keyValue/scalars 三种表型 + 表头排序）。
- **陷阱**：`JSONTableView.rowValues` 是计算属性，每次求值都 `columns`（扫前 500 行子孙）→ 排序/滚动时重复重建列定义。

### 2.13 `JSONInspectorWindowController` 家族

- 单例窗口控制器（`NSWindowController`），900×640，`minSize 640×420`，`isReleasedWhenClosed = false`，`close()` 只 `orderOut`。
- `maxFileBytes = 32MB`；读盘 `String(contentsOf:)` **主线程同步**。
- `JSONInspectorHostController`（`NSHostingController<JSONInspectorRootView>`）+ `JSONInspectorState`（`@Published text/document/parseFailed`）。`load(text:title:subtitle:)` 只写 state，由 `onChange(of: text)` 触发 `parse()`。

### 2.14 网盘链路：`CloudDriveProvider` / `CloudDriveLink` / `CloudDriveLinkDetector`

- `CloudDriveProvider`：8 家（百度/阿里/移动/天翼/迅雷/夸克/UC/123），含 `tint` 品牌色（`NSColor`，非 Sendable 但枚举标了 Sendable——实际上 `tint` 是计算属性，返回即用）。
- `CloudDriveLink`：`url/provider/isSharePage`，`requiresLogin`（139/189 实测无游客直链）。
- `CloudDriveLinkDetector`：`exactHosts` 12 条 + `wildcardSuffixes` 12 条；`isSharePage` 特判 123 的 `/123pan/<id>`（v 用户实证回归）；静态 `NSDataDetector` + 静态裸域名正则。
- `detect(in:)`：先 NSDataDetector 再裸域名兜底；`normalized` 把 http 升 https。

### 2.15 `CloudLinkSettings` / `CloudLinkTester` / `CloudLinkCenterView` / `CloudLinkCenterController`

- `CloudLinkSettings`：**22 个 UserDefaults 键**（脚本、目录、超时、UA、引擎、并发、连接、分片、重试、续传、冲突、Finder 显示、aria2 endpoint/token、更新 URL）。全部裸 `UserDefaults.standard`，不经 `Preferences` 封装。
- `CloudLinkTester`：5 项检查数组（链接识别/脚本/可达性/目录/UA），`probe` 用 `URLSession.ephemeral` GET 分享页，12s 级超时按设置。
- `CloudLinkCenterView`：`@Stored` 镜像 17 个设置项，每项 setter 里**双写**（`@Stored` 本地态 + `CloudLinkSettings` 落盘）。
- `CloudLinkCenterController`：`window?.close()` 后重建，单实例字段 `window`。

### 2.16 `CloudLinkBar` / `CloudLinkPreviewAction` / `CloudLinkActions`

- `CloudLinkBar`：`@ObservedObject ClipboardManager.shared`，扫描最近 20 条（注释说"最近 3 条"，实际 `scanLimit: 20`）；`dismissedURL` 只压一条链接。
- `CloudLinkActions.resolve`：`StatisticsManager.record(.browserOpen)` + `CloudLinkDownloader.shared.start`。

### 2.17 `CloudLinkPromptController` / `CloudLinkPromptView`

- 单例；`start()` 订阅 `ClipboardManager.shared.$items` **且** 订阅 `itemsDidChangeNotification`（双通道）；1.5s 启动静默期 + 2s 后 `catchUpRecentShareLink`（30 分钟内补提示一次）。
- 窗口：322×64 borderless `NSPanel`，`level = .statusBar`，12s 自动 dismiss。**该窗口从不 `close()`，只 `orderOut` 并置 nil**（每次 show 新建）。

### 2.18 `CloudLinkDownloader` / `LinkPageResolver`

- `CloudLinkDownloader`：`@Published items`，`pending: [Job]` + `active: Int` 并发闸；三引擎（builtin/aria2/copy）。
- `LinkPageResolver`：隐藏 `WKWebView`（1280×900）+ 注入 JS 抓文件直链（前 12 个候选）+ 12s 超时 + cookie 同步到 `HTTPCookieStorage.shared`。

### 2.19 `PreviewImageLoader`

- 串行队列 `com.frset.preview-image-decoder`（qos `.userInitiated`）、`NSCache(32)`、`inFlight: [NSString: [(NSImage?)->Void]]` + `NSLock`。
- `decode` 走 `CGImageSourceCreateThumbnailAtIndex` 下采样。

---

## 3. 函数级清单

### 3.1 `PanelModule.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `start()` | 8–30 | 静态入口。`PanelController.shared.prepare()`、注入 `ServiceLocator.panel`/`.panelPreview`、`FRSET_JSON_PROBE` 时 2s 后开 JSON 检视器（`clip` 关键字读剪贴板）。主线程；副作用：建窗、可能读剪贴板。失败模式：探针目标文件不存在时检视器静默不弹（`open(fileURL:)` 内部弹 alert）。 |

### 3.2 `PanelController.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init()` | 22–24 | 私有，仅 `super.init()`。 |
| `prepare()` | 29–64 | 幂等建窗（`guard panel == nil`）。读 `panelWidth`（下限 320）与 `Theme.panelMaxHeight` 建 `FloatingPanel`；设 delegate；注册 `Personalization.didChangeNotification` 观察者（**永久，不移除**）；`scheduleWarmup()`。副作用：建窗、写 UserDefaults（间接）、注册通知。主线程。 |
| `syncPanelFrameToPersonalization()` | 68–79 | 按当前宽度键 + 面板最大高重设 frame，**保持顶边**（`origin.y = maxY - height`），再 `applyPersonalizedMaterial()`。通知链路与 `show()` 双入口；面板隐藏时也执行（v71 修正）。 |
| `scheduleWarmup()` | 90–96 | 一次性：2s 后 `warmupPanel()`。`warmupScheduled` 防重。 |
| `warmupPanel()` | 98–120 | 离屏预热：`alpha=0` + `orderFrontRegardless` + `presentation.visible=true` 强制 SwiftUI 真布局 + `RunLoop.run(until: now+0.12)`（**嵌套 runloop，120ms 卡主线程**）+ 复位并 `orderOut`。跳过条件：已可见或 alpha≠1。 |
| `toggle()` | 124–126 | 可见则 hide 否则 show。 |
| `toggle(atAnchor:)` | 129–131 | 锚点版 toggle。 |
| `show()` | 133–135 | 转 `show(atAnchor: nil)`（右缘停靠）。 |
| `show(atAnchor:)` | 143–190 | 核心。`prepare()` 兜底 → `record(.panelOpen)` → `MonitorPopoutWindowController.dismissPopout()`（互斥）→ 个性化校准 → `level = isPinned ? .statusBar : .floating` → `prepareForPanelAppear()` → 锚点/右缘定位 → `presentation.visible=true` → `alpha=0` → `NSApp.activate` → `makeKeyAndOrderFront` → `TransientWindowCenter.register(...)`（`allowsClickIn` 放行 sheet / `frset.clipboardPreview` / `frset.panelPreviewPopover`）→ `MonitorSampler.setHomePanelActive(true)` → `RenderProbe.snapshot` → 0.18s 级淡入。副作用：统计埋点、采样器状态、全局窗口注册。 |
| `isPanelVisible` (var) | 199 | `panel?.isVisible`。 |
| `panelFrameForPopout` (var) | 202 | 可见时返回 frame，供监测独立窗定位。 |
| `panelWindowForProbe` (var) | 205 | 只读窗口引用（白屏排查）。 |
| `hide()` | 208–219 | `unregister` → `RenderProbe` → `persistSize` → `presentation.visible=false` → **等预览关闭**后 `performHide`。 |
| `performHide(_:)` | 222–231 | 0.12s 淡出 → `orderOut` → `alpha=1` → `MonitorSampler.setHomePanelActive(false)`。 |
| `handleGlobalShortcut()` | 235–237 | `open`，转 `toggle()`；实际热键由 ShortcutManager 接线。 |
| `rightEdgeOrigin(for:)` | 242–247 | 屏幕 `visibleFrame` 右上角（右 -10pt、顶 -2pt）；无屏幕时 `(80,80)`。 |
| `anchorOrigin(_:for:)` | 251–259 | `x = 锚点中心 - 宽/2`，钳制在 `[minX+6, maxX-6]`；`y = vf.maxY - h - 2`。 |
| `persistSize(_:)` | 263–273 | 仅当 `w>=320 && h>=400` 才写 `panelWidth/panelHeight`，否则记日志丢弃。 |
| `isPinned` (var) | 280–289 | 读写 `panelPinned`；setter 同步 `panel.level` 并在开启时 `record(.alwaysOnTopEnable)`。 |
| `windowDidResignKey(_:)` | 291–320 | 收起判定链：`FRSET_PANEL_PIN=1` 放行 → `isPinned` 放行 → 非本面板忽略 → key 是本 app 的 sheet 放行 → key 是 `frset.clipboardPreview` 放行 → key 是 `frset.panelPreviewPopover` 放行 → `TransientWindowCenter.requestDismiss`。 |
| `windowDidResize(_:)` | 322–325 | 可见时 `persistSize`。 |
| `windowWillClose(_:)` | 327–329 | `presentation.visible = false`。 |

**`show(atAnchor:)` 流程与坑（143–190，48 行、多外部副作用）**
① 顺序敏感：必须先 `syncPanelFrameToPersonalization()` 再算 `origin`，否则用的是旧尺寸算出的锚点，面板会偏半个宽度差。
② `presentation.visible = true` 必须在 `makeKeyAndOrderFront` 之前置位，否则首帧 opacity 0 → 淡入动画从错误起点开始（表现为"闪一下"）。
③ `TransientWindowCenter.register` 的 `allowsClickIn` 白名单是硬编码 window identifier 字符串——新增浮窗（如"标注器"）若成为 key window 而未加白名单，用户点它面板会消失。
④ `MonitorSampler.setHomePanelActive(true)` 在这里置位，但复位在 `performHide` 的动画 completion 里；若淡出动画被下一次 `show` 打断（`show` 未取消前一个 animation group），`completion` 可能不执行 → 采样器永久停留"主面板活跃"档。这是"主面板关闭后仍高频采样"的潜在来源。

**`warmupPanel()` 坑（98–120）**
`RunLoop.current.run(until:)` 在启动空闲期阻塞主线程 120ms；若有其它 `asyncAfter(2.0)` 任务（如 `CloudLinkPromptController.catchUpRecentShareLink` 也是 2s）会顺延。`orderFrontRegardless()` 会把一个 alpha=0 的窗口塞进窗口列表，若预热期间用户点了状态栏（面板被真的 show），`presentation.visible=false` 复位会把正在淡入的面板打回透明——竞态窗口约 120ms。

**`windowDidResignKey` 的三层白名单**
sheet / `frset.clipboardPreview` / `frset.panelPreviewPopover`。前两条是"边看边操作"的体验例外，第三条是 v65 引入的 popover 例外。注意这里**没有** `frset.jsonInspector`：从面板拖 JSON 打开检视器时先调 `onDismiss()`，所以不冲突——但任何新增的"从面板打开的独立窗"都必须自己先 dismiss。

### 3.3 `PanelRootView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `body` | 61–191 | 顶条 + 内容 + 底条 overlay + sheet + 一系列 `onReceive/onChange/onDrop/onAppear`。含 `FRSET_PREVIEW_PROBE` 探针（面板可见后 1.2s 自动弹预览，图片探针会**写一条假 OCR 文本**到缓存）。 |
| `bodyTextColor` (var) | 193–195 | Midnight 文本色或 `.primary`。 |
| `cardBackground` (var) | 197–199 | Midnight 卡片色或 `Theme.cardBackground`。 |
| `AnchorArrow.path(in:)` | 203–210 | 顶部三角（26×10）。 |
| `toolbar` (var) | 221–305 | 单行：截图菜单 / 取色 / 悬浮剪贴板 / 分段 / 齿轮菜单。**v84 从 ZStack 改顺序排布**，修重叠。齿轮内含置顶、悬浮剪贴板、暂停记录（v97 从 Toggle 改 Button + Toast）、设置、使用统计、退出。 |
| `pageSegments` (var) | 313–346 | 四段（主页/监测/中转/投屏）；中转+投屏受 `transferDockEnabled` 控制；中转段挂 `.onDrop`。 |
| `dropToLocalTransfer(_:)` | 349–375 | 并发 `loadItem` 收集 URL（`NSLock` 保护数组）→ `DispatchGroup.notify(.main)` → `LocalTransferStore.add` → 切页 + Toast。**返回 true 后仍异步**。 |
| `segmentItem(_:selected:action:)` | 377–397 | 胶囊分段按钮；11pt 字 + `minimumScaleFactor(0.8)`。 |
| `captureAction` (var) | 404–433 | 截图菜单（9 项，含窗口截图 v113、长截图、录屏）。 |
| `runCapture(_:)` | 436–439 | 先 `onDismiss()`，0.12s 后执行（让面板让位覆盖层）。 |
| `bottomToolbar` (var) | 449–545 | 悬浮胶囊：搜索（可展开为输入框）/ 筛选菜单 / 标签 / 回到顶部。三级玻璃 L3。 |
| `closeBottomSearch(clear:)` | 547–553 | 收焦点、可选清空 `searchText`、动画收起。 |
| `toolbarIcon(_:help:action:)` | 555–568 | 26×26 图标按钮。 |
| `captureButton(_:title:mode:)` | 570–584 | 取色按钮 → `CaptureModule.capture(mode)`。 |
| `content` (var) | 589–614 | **按页实例化**（v136）：`if/else if` 只挂当前页，`transition(.opacity)`，`animation(value: page)`。 |
| `homePage` (var) | 618–644 | 搜索区段 → `CloudLinkBar` → 12pt 空隙 → 日历卡 → 剪贴板区；整体 `animation(value: CloudLinkBar.detectionKey)`。 |
| `searchSection` (var) | 647–651 | 从 `PanelSectionRegistry` 取 `id == "search"` 的描述符构建（Toolbox 注入）。 |
| `dropHintOverlay` (var) | 656–676 | 虚线框 + 文案。 |
| `handleFileDrop(_:)` | 678–694 | 只取第一个 provider，`loadItem` 后主线程 `onDismiss()` + `JSONInspectorWindowController.open(fileURL:)`。 |
| `bgImageCache` (static var) | 697 | `(path, image)?` 单槽缓存（v101）。 |
| `cachedBackgroundImage(path:)` | 698–703 | 路径不变不重读盘；路径变了才 `NSImage(contentsOfFile:)`。**主线程同步读盘解码**。 |
| `homeSectionInset` | 706 | 8pt 统一内边距。 |
| `calendarCard` (var) | 709–714 | 取 `id == "calendar"` 描述符。 |
| `clipboardSection` (var) | 717–722 | 取 `id == "clipboard"` 描述符。 |

**`content` 的按页实例化（589–614）是本目录最重要的性能决策**
注释记录：v136 之前是"三/四页常驻 ZStack + opacity(0)"，每帧合成全部图层（v130 增第四页后到 4 层），且任何面板状态变化（剪贴板每秒更新）都会重算隐藏页 `body` —— 用户感知为"玻璃发闷 + 滑动卡顿"。现在隐藏页完全不进视图树。**代价**：切页丢滚动位置（数据在单例 Store，可接受）。这条纪律的反面：任何"需要跨页保持的 UI 态"都不能靠 View 局部状态。

**`dropToLocalTransfer` 的线程细节**
`provider.loadItem` 回调在任意队列；`urls` 用 `NSLock` 保护（正确）；但 `group.notify(queue: .main)` 里读 `urls` 时已无并发写，安全。**缺陷**：函数立刻 `return true`，若用户随后切走面板，`LocalTransferStore.add` 仍会执行并把页面**强行切回**中转页（`selectTransferDock()`）——用户在别的页被"劫持"。

### 3.4 `FloatingPanel.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init(contentRect:rootView:)` | 12–58 | 设 styleMask/level/collectionBehavior/`acceptsMouseMovedEvents`；`NSHostingView` + `sizingOptions=[]` + `safeAreaRegions=[]`；`NSVisualEffectView(.hudWindow, behindWindow)` + 圆角；`LiquidGlass.embed`。 |
| `canBecomeKey` (var) | 62 | 恒 true（搜索框需键盘），靠 `.nonactivatingPanel` 保"不抢焦点"体感。 |
| `init?(coder:)` | 65–67 | `fatalError`。 |
| `applyPersonalizedMaterial()` | 75–91 | 三档：macOS 26 `NSGlassEffectView`（tint 0.32 + cornerRadius）/ `NSVisualEffectView`（`.hudWindow` + 圆角 + continuous）/ 其它只改 layer 圆角。 |

### 3.5 `PanelPreviewPreferences.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `fullText(for:)` | 52–66 | provider 优先；否则读 `textPath`（UTF-8）→ `richTextPath`（RTF 转纯文本）→ `item.content`。**同步 IO，可能主线程**。 |
| `ocrText(for:)` | 69–71 | `ocrTextProvider?(item)`；未接线 nil。 |
| `saveOCRText(_:for:)` | 74–76 | `saveOCRTextProvider?(item, text)`。 |
| `recognizeImage(_:)` | 79–84 | `async throws`；未接线抛 `PreviewDataBridgeError.notWired`。 |
| `richTextAttributed(for:)` | 88–95 | provider 优先；否则把相对路径当绝对路径读 RTF（见 2.5 的缺口说明）。 |

### 3.6 `MainPanelPreviewPopoverCoordinator.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `Slot.init(contentModel:mode:showsHint:)` | 51–63 | 建 `ClipboardPreviewWindowController`，挂 `onWindowClosed` / `onEditingChanged`（编辑中取消 hover 关闭）。 |
| `present(...)` | 164–224 | 见下方流程。返回是否成功。 |
| `presentPersistent(for:anchorView:)` | 227–234 | 单击路径 → `present(mode: .persistent)`。 |
| `dismiss(reason:completion:)` | 237–249 | 移除点外监听；无活跃槽时直接 completion；多个 completion 串成链（`previous?(); completion()`）。 |
| `closeAll(reason:completion:)` | 252–254 | `dismiss` 别名。 |
| `rowHover(_:item:source:anchorProvider:)` | 263–296 | 见下方流程。 |
| `prepareForPanelAppear()` | 299–302 | 清抑制 + 清 WorkItem。 |
| `requestKeyboardPreview(item:anchorProvider:)` | 308–326 | 0.30s 延时；首次触发消费 `clipboard_keyboard_preview_hint_consumed` 并传 `showsKeyboardHint`；埋点 `keyboard`。 |
| `cancelKeyboardPreview()` | 329–332 | 取消未决键盘预览。 |
| `popoverHoverChanged(_:)` | 338–346 | 在内则取消关闭计时；移出且未固定则重排关闭。 |
| `previewPinned` (var) | 355–358 | 裸 `UserDefaults` 键 `panel.previewPinned`。 |
| `installOutsideClickMonitor()` | 363–383 | 全局（点别的 app）+ 本地（点本 app 非预览窗）双 monitor；固定态跳过。 |
| `removeOutsideClickMonitor()` | 385–388 | 成对移除。 |
| `installEscapeMonitor()` | 393–403 | 本地 `keyDown` keyCode 53；`isEditing` 放行；命中则 `dismiss(.escape)` 并吞掉事件。 |
| `removeEscapeMonitor()` | 405–407 | 移除。 |
| `setPreviewOrder(_:)` | 412–414 | 存导航序（**无消费者**，F7 未接线）。 |
| `notifyItemRemoved(itemID:)` | 422–424 | 锚条目被删则 `dismiss(.itemRemoved)`。 |
| `rememberMarkdownScroll(dedupeKey:state:)` | 431–433 | 写内存字典（**无上限**）。 |
| `markdownScrollState(for:)` | 436–438 | 读。 |
| `activityAreaPreview` (static) | 443 | 埋点常量。 |
| `track(_:_:_:)` | 445–456 | 组装 props → `analyticsSink?` + `Log.debug`。 |
| `resolveAnchor(preferredView:rectInWindow:)` | 460–470 | 有 view 用之；否则退化为 `NSApp.keyWindow ?? mainWindow` 的 contentView。失败返回 nil → `present` 返回 false（静默）。 |
| `cancelHoverWorkItems()` | 472–477 | 清开/关两个 WorkItem。 |
| `cancelHoverClose()` | 480–483 | 只清关闭计时（编辑开始用）。 |
| `scheduleHoverClose()` | 485–508 | 见下方。 |
| `closeSlot(reason:)` | 510–522 | 写 `pendingCloseReason` → `.closing` → `window?.close()`（v83：不用 `performClose`，borderless 无效）。 |
| `handlePreviewWindowDidClose(_:)` | 525–540 | 唯一清理点：置 nil、清 activeItemID/跟踪表/抑制开始/移除 Esc monitor/埋点/执行 completion 链。 |
| `beginHoverSuppression()` | 544–552 | 置 `suppressHoverUntilMouseMove` + 挂 `mouseMoved/leftMouseDragged/otherMouseDragged` 本地 monitor。 |
| `endHoverSuppression()` | 554–560 | 复位 + 移除 monitor。 |
| `PreviewArrowGeometrySupport.preferredNSRectEdge(...)` | 570–578 | 右/左/空间大侧。**无调用方**。 |
| `swiftUIEdge(for:)` | 581–589 | NSRectEdge → Edge。**无调用方**。 |
| `PreviewArrowGeometryStore.arrowEdge(...)` | 597–607 | 计算并缓存到 `cachedEdges`。**无调用方**。 |
| `invalidate()` | 610–612 | 清缓存。**无调用方**。 |
| `onPreviewPopoverHoverChanged(_:)` | 631–633 | View 扩展，挂 modifier。 |
| `PreviewPopoverHoverChangedModifier.init(action:)` | 638 | 存闭包。 |
| `body` | 639–641 | → `PreviewPopoverHoverProbe`。 |
| `PreviewPopoverHoverProbe.body` | 649–656 | 写环境值 `isPreviewPopoverHovered` + `onHover` 回调。 |

**`present(...)` 流程（164–224）**
① `cancelHoverWorkItems()` + `cancelKeyboardPreview()`（防"悬停即将开"和"空格即将开"在新预览里再弹一次）。
② 同条目同模式命中 → persistent 只 `focusFront()`，返回 true（不闪烁、保草稿）。
③ 旧槽非 nil → `closeSlot(.programmatic)`；旧窗的 `handlePreviewWindowDidClose` 里 `guard slot === closingSlot` 会因 `self.slot` 已指向新槽而被**丢弃**——所以旧窗的 completion 链在这一路径上不会执行（`pendingCloseCompletion` 被新调用覆盖前的旧值丢失）。这是"面板收起等预览关闭"在某些交错路径下卡住的理论来源，实测因 `dismiss` 先置 completion 才 `closeSlot` 而未爆发。
④ `resolveAnchor` 失败直接 `return false`：**没有任何日志/Toast**，悬停预览"没反应"只能靠猜。
⑤ 锚点坐标转换链：`view.convert(rect, from: nil)` → `window.convertToScreen`。若 `anchorRectInWindow` 由 SwiftUI `GeometryReader(.global)` 给出，此处再 `convert(from: nil)`（nil = window 坐标）是正确口径；若调用方误传 view 坐标就会偏移。
⑥ 新会话 UUID → 取全文（**同步**，`PreviewPopoverDataBridge.fullText` 可能读盘）→ 建 model → 建 slot → `show` → `state = .presented` → 监听安装 → 埋点。
⑦ **主线程同步全文读取**是这里最实的心跳：一条 8MB 的落盘文本，`present` 会卡住主线程读文件——而 `PreviewFileBackedTextView` 明明已经有异步加载路径（`loadFullText`），此处却先把全文读出来塞进 `inlineText` 只为做 kind 判定。

**`rowHover` 流程（263–296）**
总开关（`hoverPreviewInMainWindowEnabled` / `hoverPreviewInFloatingClipboardEnabled`，默认 true）→ 抑制期拦截 → hovering：取消关闭计时、记 `hoverStartedAt`、若已有 open WorkItem 直接 return（**同一条目重复 hover 不会重置计时**）→ 0.35s 后校验 hover-intent（≥0.06s）与 anchor 有效 → `present`。移出：取消 open、`scheduleHoverClose()`。

**`scheduleHoverClose()` 的自递归（485–508）**
关闭 WorkItem 触发时依次守：槽已 presented → 非编辑 → 非固定 → `isPreviewPopoverHovered` 假 → **鼠标实测位置不在预览窗 frame 内**。若鼠标在窗内则 `self.scheduleHoverClose()` 递归重排（0.25s 一轮的轻量轮询）。这是 v71 为"SwiftUI onHover 在 nonactivating 面板 key 切换瞬间丢失"做的兜底，代价是鼠标停在预览窗上时每 250ms 一个 `NSEvent.mouseLocation` 检查——可接受，但若将来把 `hoverPreviewCloseDelay` 调到 0 会变成忙轮询。

### 3.7 `PanelPreviewPresenterAdapter.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `presentPreview(for:anchorRectInWindow:anchorView:isFloatingSource:)` | 16–25 | → `coordinator.present(...)`，`source` 由 `isFloatingSource` 决定，`entry` 固定 `.mainList`。 |
| `dismissPreview()` | 28–30 | → `dismiss(.programmatic)`。 |
| `rowHover(_:item:anchorRectProvider:isFloatingSource:)` | 33–41 | `anchorRectProvider ?? { nil }`。 |
| `requestKeyboardPreview(item:anchorRectProvider:)` | 44–48 | 同上归一。 |
| `cancelKeyboardPreview()` | 51–53 | 转调。 |
| `prepareForPanelAppear()` | 56–58 | 转调。 |
| `setPreviewOrder(_:)` | 61–63 | 转调。 |
| `notifyItemRemoved(itemID:)` | 66–68 | 转调。 |

### 3.8 `PreviewPopoverContentView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `PreviewPopoverContentView.body` | 16–26 | 内容 + （命中网盘链接时）`CloudLinkPreviewAction`；`.frsetThemeChrome()`。 |
| `content` (var) | 29–48 | `switch model.kind` 8 分支。 |
| `PreviewRichTextView.init(model:)` | 61–66 | **同步** `model.richAttributed`（落盘 RTF），失败退化为纯文本 13pt。 |
| `PreviewSourceTextView.copy(_:)` | 84–116 | 按 clip 与 `segments` 求交，整段直接取源、部分选中按比例近似裁剪，`\n` 连接写剪贴板。`pieces` 为空则回落 `super.copy`。 |
| `PreviewTextViewRepresentable.makeNSView(_:)` | 132–187 | 建 `PreviewSourceTextView`（不可编辑/可选中/非富文本/`drawsBackground=false`）、字体（等宽 12 / 系统 13）、link 属性、ruler（可选）、`setAttributedString`、注册 `boundsDidChange` 观察、恢复初始偏移（`async` 一次）。 |
| `updateNSView(_:context:)` | 189–205 | 更新 onScroll/source 映射；文本变化才 `setAttributedString`；`scrollRequest` 去重后滚动。 |
| `dismantleNSView(_:coordinator:)` | 207–209 | 移除通知观察。 |
| `makeCoordinator()` | 211 | 建 `ScrollCoordinator`。 |
| `ScrollCoordinator.boundsDidChange(_:)` | 219–222 | 上报 `clipView.bounds.origin.y`。 |
| `ScrollCoordinator.textView(_:clickedOnLink:at:)` | 225–245 | `frset-toc://loc=N` → `scrollToCharacter`；http(s) → `NSWorkspace.open`；其它返回 false。 |
| `ScrollCoordinator.scrollToCharacter(_:in:)` | 247–260 | 字符 → glyph → `boundingRect` → `scrollToVisible`；clamp 到 `[0, len-1]`。 |
| `ScrollCoordinator.deinit` | 262–264 | 再移除一次观察（双保险）。 |
| `PreviewLineNumberRulerView.init(textView:)` | 273–278 | `ruleThickness = 28`。 |
| `init(coder:)` | 281–283 | `fatalError`。 |
| `isFlipped` (var) | 285 | true。 |
| `drawHashMarksAndLabels(in:)` | 287–326 | 可见 glyph 范围 → 数前缀 `\n` 得起始行号 → 逐行 `lineFragmentRect` 画。**每次滚动重绘都跑**。 |
| `PreviewTextContentView.body` | 334–342 | 19.5pt 纯文本。 |
| `MarkdownFilePreviewBody.init(text:restoreKey:)` | 359–366 | `init` 里同步 `renderBody`（**渲染在视图构造期**）。 |
| `MarkdownFilePreviewBody.body` | 368–377 | → `MarkdownPreviewBody`。 |
| `PreviewFileBackedTextView.body` | 388–433 | idle/loading 占位（延时指示器）、loaded 再分态（markdown/json/code/text）、failed 文案；`.task(id: dedupeKey)`。 |
| `loadFullText()` | 435–458 | 代际 +1；0.40s 延时后显示指示器；`Task.detached` 读全文；代际/取消校验；空 → failed。 |
| `PreviewMarkdownTextView.init(model:)` | 471–477 | 同步 `PreviewMarkdownRenderer.renderBody`。 |
| `render(_:)` (static) | 480–484 | 转调 `renderBody`（供 `estimatedPopoverHeight` 复用量高）。 |
| `PreviewMarkdownTextView.body` | 486–495 | → `MarkdownPreviewBody`。 |
| `MarkdownPreviewBody.body` | 514–539 | 有标题则左侧 `PreviewTOCSidebar`(180) + Divider；正文带初始偏移（读协调器记忆）、滚动上报、`scrollRequest`、回源映射。 |
| `PreviewTOCSidebar.body` | 551–594 | 标题列表，active/hover 高亮，缩进按 level。 |
| `PreviewJSONTextView.init(model:)` | 603–606 | 同步 `prepare(inlineText)`。 |
| `prepare(_:)` | 608–622 | 先按 `jsonPreviewCharCap`(20000) 截断再 pretty-print（注释：超长美化代价高）。 |
| `PreviewJSONTextView.body` | 624–628 | 用 `JSONInspectorView(compact: true)`，**忽略 `displayText`**。 |
| `PreviewCodeTextView.body` | 636–644 | `detectLanguage` → `renderCodeBody` + 行号。 |
| `PreviewImageView.displayImage` (var) | 662 | `fullImage ?? thumbnail`。 |
| `headerFooterHeight` (var) | 665–670 | QR / 普通两档。 |
| `PreviewImageView.body` | 672–749 | 图 / 失败占位 / loading → OCR 操作条 → OCR 文本块（`maxHeight 120`）→ 右上「标注」→ `.task` 加载图 + 刷新 OCR 缓存。 |
| `ocrActionBar` (var) | 753–778 | 识别中 / 有文本（复制+重识别+字数）/ 无文本（识别按钮 + 提示）。 |
| `ocrHint` (var) | 780–782 | 失败/正常两种文案。 |
| `smallAction(_:icon:prominent:action:)` | 784–806 | 小胶囊按钮。 |
| `copyOCR()` | 808–814 | 写剪贴板 + Toast。 |
| `recognizeNow()` | 817–857 | 取 `imagePath` → `ClipboardFileStore.url` → `Task`：`detached` 读 Data（v126 修主线程卡顿）→ `recognizeImage` → 主线程回写 `ocrText` + `saveOCRText`；空结果/异常各有文案。 |
| `editImage()` | 861–872 | 关预览 → 0.12s 后 `post("frset.clipboard.editImage", object: image)`（跨模块走通知）。 |
| `loadImages()` | 875–908 | 缩略先行 → 大图 → QR 检测（`detached .utility`）→ `didFailToLoad = 两者皆 nil`。 |
| `PreviewFileView.paths` (var) | 916–921 | `content` 按行切路径。 |
| `isArchivePath(_:)` | 924–926 | 单文件且 `ArchiveCore.isArchive`。 |
| `PreviewFileView.body` | 928–1004 | 每路径：缩略图（72/260/44 三档）+ 名称/路径 + 快速查看/编辑归档 → 归档条目网格 + 解压到…；末尾「压缩…」。 |
| `PreviewFileThumbnailLoader.decode(path:)` | 1027–1037 | 图片直读 → PDF 渲染 → QL 缩略图。 |
| `renderPDF(url:)` | 1040–1060 | CGPDF 首页 @2x 画到 bitmap。 |
| `qlThumbnail(url:)` | 1063–1074 | 512pt@2x `generateBestRepresentation` + continuation。 |
| `PreviewFileThumb.body` | 1083–1101 | 无图时显示系统图标。 |
| `load()` | 1103–1116 | 缓存命中直接设；否则 `Task` 解码 → 回填缓存 + 主线程设值。 |
| `QuickLookPresenter.show(_:)` | 1128–1137 | `QLPreviewPanel.shared()` 取不到则 `NSWorkspace.open` 兜底。 |
| `numberOfPreviewItems(in:)` | 1139 | 0 或 1。 |
| `previewPanel(_:previewItemAt:)` | 1141–1143 | 返回当前 URL。 |
| `acceptsPreviewPanelControl(_:)` | 1145 | true。 |
| `beginPreviewPanelControl(_:)` | 1147–1150 | 重设 dataSource/delegate。 |
| `endPreviewPanelControl(_:)` | 1152 | 空。 |

**`recognizeNow()` 的坑（817–857）**
① `ClipboardFileStore.url(forRelativePath:)` 在主线程解析（无害），但 `Data(contentsOf:)` 走 detached（正确）。
② 成功后 `saveOCRText` 在 **MainActor** 上调——若 provider 实现里做落盘 IO，会回到主线程阻塞。桥的契约没写线程。
③ 失败只置 `ocrError`，不区分"引擎未配置"（`notWired`）与"识别失败"——用户看到"识别服务尚未接线"这种开发态文案。
④ `ocrBusy` 期间按钮不 disable 而只换成 ProgressView——但 `recognizeNow` 不检查 `ocrBusy`，快速双击会并发两次识别。

### 3.9 `PreviewPopoverContentModel.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init(...)` | 48–65 | `kind = kindOverride ?? classify(...)`。 |
| `classifyRawText(_:)` | 68–73 | JSON → Markdown → 代码 → 文本。 |
| `classify(item:fullText:)` | 82–98 | 按 item.type 分派（见 2.9）。`.richtext` 分支会**同步**调 `richTextAttributed`（读盘）。 |
| `richAttributed` (var) | 101–103 | 桥转调。 |
| `isJSONPreviewEligible(_:)` | 109–128 | ≤200k 字符；单根可解析 或 JSONL（每行对象/数组且 ≥2 行）。 |
| `looksLikeMarkdown(_:)` | 152–175 | 10 条预编译强信号正则命中任一即真；否则最多 40 行扫 `__`/`~~` 计 2 分。 |
| `looksLikeCode(_:)` | 178–193 | ≥4 行；前 30 行 `;{` 结尾或关键字前缀计分 + 缩进行 ≥3 加分；≥3 判定。 |
| `estimatedPopoverHeight(...)` | 198–242 | 分态估高：markdown/richText 实测 `boundingRect`；json 固定 360；text `行数×25.5+30`；code `行数×23+24`；image 按像素比；file 96。 |
| `imagePixelSize(item:)` | 245–255 | `CGImageSourceCopyPropertiesAtIndex` 读像素宽高（不解码）。 |
| `imageDisplayHeight(item:contentWidth:)` | 258–262 | 等比缩放，最小 80。 |
| `MarkdownScrollState.init(...)` | 285–289 | 默认值构造。 |
| `String.lineCountEstimate` (var) | 268–273 | 数字符。 |

### 3.10 `PreviewMarkdownRenderer.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `s(_:)` | 55 | `value * scale`。 |
| `render(_:)` | 62–85 | 正文 + 文首目录；目录里的 `loc` 偏移按目录段长度整体平移。 |
| `renderBody(_:)` | 90–113 | 逐块渲染 + 记 heading 锚点 + 记 `rendered↔source` 段 + 块间补 `\n`。 |
| `parse(_:)` | 117–119 | `parseSourced().map(\.block)`。 |
| `parseSourced(_:)` | 122–275 | 见下方。 |
| `span(_:_:)` | 137–141 | 行区间 → UTF-16 区间。 |
| `flushParagraph()` | 154–161 | 段落落块。 |
| `looksLikeNakedCode(_:)` | 278–292 | 非空行 ≥2 且"像代码"比例 ≥0.6。 |
| `guessLanguage(_:)` | 295–313 | 12 语言特征串判定（顺序敏感）。 |
| `inlineAttributed(_:font:)` | 340–395 | `AttributedString(markdown: .inlineOnlyPreservingWhitespace)` → 按 `.inlinePresentationIntent`（兼容 NSNumber 桥接）现算粗/斜/代码/删除线；链接加色+下划线。 |
| `render(_ block:)` | 397–459 | 7 种块渲染（标题按 level 取字号、段落、列表、引用带 `▍`、分隔线 48 个 `─`、代码、表格）。 |
| `detectLanguage(_:)` | 464–466 | `guessLanguage` 包装。 |
| `renderCodeBody(lang:code:)` | 469–471 | `renderCode(showLabel:false)`。 |
| `renderCode(lang:code:showLabel:)` | 473–503 | mermaid/plantuml → `MermaidRenderer` 图附件；否则逐行 `highlight` + 背景 + 段落样式。 |
| `renderDiagram(image:source:)` | 506–519 | 附件按 420pt 上限缩放宽。 |
| `cachedRe(_:)` | 525–530 | 静态字典缓存正则（**非线程安全**）。 |
| `firstMatchRange(_:in:)` | 535–539 | 缓存正则首匹配。 |
| `normalizedLang(_:)` | 563–576 | 别名归一（c++/py/kt/cs/ts/golang/rs/sh/objc…）。 |
| `highlight(line:lang:font:)` | 579–654 | 整行注释 → 整体灰；字符串正则着色 → 行尾 `//` 注释（数引号平衡）→ 数字 → 标识符单遍扫描查 Set（关键字紫、大写类型青）。`autoreleasepool` 包裹。 |
| `displayWidth(_:)` | 661–672 | 东亚宽字符按 2 列。 |
| `renderTable(_:)` | 674–721 | 算列宽 → 逐行 pad + `│` 拼接 + 首行下加 `─`。 |
| `pad(_:_:_:)` | 692–694 | 补空格。 |
| `renderTOC(_:)` | 725–755 | 文首目录（每标题一个 `frset-toc://loc=` 链接）。 |

**`parseSourced` 流程与坑（122–275，154 行）**
① 外层 `autoreleasepool`（v128 内存优化）：逐行 `NSString` 桥接 + 正则产生大量临时对象。
② 先归一 `\r\n`，再 `components(separatedBy: "\n")`；同时算每行起始 UTF-16 偏移，供 `span()` 反查源区间。
③ **裸代码短路**：全文不含 ``` 且 `looksLikeNakedCode` → 整篇合成一个 code 块并直接返回（此时没有任何 heading，目录为空）。
④ 主循环按优先级判定：围栏 → 空行 → 标题（`^#{1,6}(\s+|(?=[一-鿿]))`，v87 兼容中文 `#标题`）→ 分隔线 → 引用（连续合并）→ 表格（连续 `|...|`，分隔行跳过）→ 列表（缩进/2 作 indent）→ 段落累积。
⑤ 全部在主线程、同步、无缓存（同一文本在 `init` 与 `estimatedPopoverHeight` 里**各渲染一次**）。
⑥ 表格判定要求行**首尾都是 `|`**——`| a | b`（尾无 `|`）不会被识别为表格，落成段落（"表格没格式化"的另一半原因，另一半是宽度算法）。
⑦ `span()` 的 `endLine` 用 `lineOffsets[endLine]`，对最后一块 `flushParagraph` 传 `i`（= lines.count）时走 `ns.length` 分支，不会越界；但段落起始行用 `paragraphStart ?? max(0, i - paragraph.count)`，若段落中间夹了空行已被 flush，这个兜底不会失真。

### 3.11 `MermaidRenderer.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `image(for:maxWidth:)` | 62–78 | 缓存键 `"\(maxWidth)|\(source)"`；`autoreleasepool` 内 parse+draw；按像素字节写 cost。 |
| `parse(_:)` | 88–142 | 头行取方向；跳 `subgraph/end/%%/style/classDef/linkStyle/click`；`splitStatements` 后逐句 `parseStatement`，聚合节点与边。 |
| `ensureNode(_:label:shape:)` | 107–116 | 局部闭包形式的节点去重/补全。 |
| `splitStatements(_:)` | 145–160 | 按 `;` 切分但跟踪括号深度。 |
| `parseStatement(_:)` | 176–211 | 正则抓标识符+形状 token；相邻节点对生成边，边样式/标签从 `textBetween` 判定。**纯函数**（注释强调，防独占访问冲突）。 |
| `parseNodeToken(_:)` | 213–221 | 6 种形状前缀识别。 |
| `clean(_:_:_:)` | 223–230 | 去括号/去引号/trim。 |
| `textBetween(_:fromID:toID:)` | 233–238 | 两次 `range(of:)` 取中间片段。 |
| `draw(nodes:edges:direction:maxWidth:)` | 242–467 | 最长路径分层（上限 `nodes*2` 轮）→ 尺寸测量 → 坐标（LR/RL 与 TD 两套）→ 居中/翻转 → 画布钳制 → `NSImage(size:flipped:)` 延迟绘制（先边后节点）。 |
| `measure(_:)` | 271–274 | 文本宽 + 26，最小 48×34。 |
| `anchorPoint(from:toward:)` | 470–479 | 矩形中心向目标方向求边界点。 |
| `drawArrowHead(_:at:from:color:)` | 481–496 | 7×4 三角箭头。 |

**`draw` 的坑（242–467，226 行）**
① 分层用"最长路径"松弛，迭代上限 `nodes*2`——**环状图**（A→B→A）永不收敛，每轮都在改，跑满上限后层号是最后一轮的状态（层数可能 > 节点数），布局会很宽但不会死循环，这是刻意的保护。
② `if node.shape == .diamond` 用 `==` 比较枚举——`Shape` 未声明 `Equatable`，但无关联值枚举自动可比较，OK。
③ `canvasWidth` 钳到 `maxWidth`（默认 520），超宽时算 `scale` 缩小；`ctx.scaleBy` 在绘制 handler 内做，**图片尺寸不变**（只缩放内容），因此附件按 `image.size` 布局时视觉上是"内容变小、画布不变"。
④ `positions` 用外层 `var` 字典，在 `NSImage` 的延迟闭包里**按值捕获**——闭包可能在任意线程/时机执行，捕获的是不可变副本，安全；但也意味着 `draw` 返回后 `layouts` 仍被闭包强引用直到图片绘制完成（内存驻留期比预期长）。

### 3.12 `JSONInspectorView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `JSONNodeModel.init(key:raw:path:depth:)` | 47–82 | 按类型定 kind/preview/childCount；`depth < 64` 才允许下钻。 |
| `ensureChildren()` | 88–93 | 只建子级不改展开态（表格视图用，避免行闪）。 |
| `toggle()` | 96–102 | 首次展开才建子级，然后翻转。 |
| `makeChildren(raw:parentPath:depth:)` | 105–124 | dict 按键本地化排序；array 按序；路径拼接。 |
| `JSONDocument.init?(text:)` | 141–190 | 先单根解析；失败走 JSONL 逐行；再 `walk` 计数（>20000 停止并标 truncated）。 |
| `walk(_:)` | 174–186 | 递归计数（**递归深度受 JSON 嵌套深度限制**）。 |
| `JSONInspectorView.init(text:compact:initialMode:)` | 201–216 | 解析失败兜底 `"null"`；根可展开则自动展开；根是对象数组且前 20 项全 object → 默认表格模式。 |
| `fontSize` / `rowHeight` / `keyWidth` (var) | 225–228 | compact 三档尺寸。 |
| `body` | 230–245 | 工具栏 + 截断提示 + 内容。 |
| `toolbar` | 249–278 | 四段 Picker + 搜索框。 |
| `content` | 280–298 | 四视图分派。 |
| `displayValue(_:)` | 304–310 | 去首尾引号。 |
| `JSONCardsView.records` (var) | 317–330 | 根数组→每元素一卡，否则一卡；过滤后截 500。 |
| `JSONCardsView.body` | 332–341 | LazyVStack 卡片。 |
| `card(node:index:)` | 343–377 | 序号 + 键值行。 |
| `JSONRawView.pretty` (var) | 386–395 | 非 JSONL 时重新 pretty-print（**每次求值都做一次 JSON 往返**）。 |
| `JSONRawView.body` | 397–406 | 双向滚动文本。 |
| `JSONTreeList.matched` (var) | 418–422 | 过滤器命中。 |
| `JSONTreeList.body` | 424–435 | 行 + 展开时递归。 |
| `JSONTreeList.row` | 437–497 | 箭头/key/徽标/预览/子数。 |
| `JSONTableView.shape` (var) | 524–536 | object→keyValue；array→objectRows/scalars；其它 unsupported。 |
| `JSONTableView.columns` (var) | 538–566 | 三种表型的列定义（objectRows 扫前 500 行子孙求键并集）。 |
| `JSONTableView.rowValues` (var) | 568–606 | 三种表型的行数据 + 排序。 |
| `tapHeader(_:)` | 608–615 | 换列则升序，同列则翻转。 |
| `JSONTableView.body` | 617–663 | 无列→提示；否则表头 + 行（偶数行斑马）。 |
| `header` | 665–695 | 可点击排序列头。 |

### 3.13 `JSONInspectorWindow.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init(window:)` | 18–20 | 私有。 |
| `init?(coder:)` | 22–24 | `fatalError`。 |
| `open(text:title:)` | 29–36 | 建/复用窗 → `host.load` → `showWindow` + `makeKeyAndOrderFront` + `activate`。 |
| `open(fileURL:)` | 39–74 | 查 size、>32MB 拒绝、UTF-8 后 Latin-1 兜底、必须 `{`/`[` 开头，再走 `host.load`。**主线程同步读整文件**。 |
| `close()` | 76–78 | 只 `orderOut`。 |
| `makeWindowIfNeeded()` | 83–99 | 首次建 900×640 窗（min 640×420，官方灰底），装 `JSONInspectorHostController`。 |
| `presentAlert(title:message:)` | 101–107 | `NSAlert.runModal()`（**模态阻塞**）。 |
| `JSONInspectorHostController.init()` | 117–120 | 建共享 `JSONInspectorState`。 |
| `init?(coder:)` | 122–124 | `fatalError`。 |
| `load(text:title:subtitle:)` | 126–130 | 写 state 三个字段。 |
| `JSONInspectorRootView.body` | 147–210 | 工具栏（复制格式化）+ 内容 + 状态条；`onAppear`/`onChange(text)` → `parse()`。 |
| `parse()` | 212–232 | `async` 到下一轮再 `JSONDocument(text:)`（避免阻塞首布局），写 document/parseFailed/nodeCountText。 |
| `copyFormatted()` | 234–237 | **复制的是 `state.text` 原文，不是格式化结果**（按钮名与行为不一致）。 |

### 3.14 `CloudDriveLink.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `CloudDriveLink.init(...)` | 52–56 | 三字段。 |
| `requiresLogin` (var) | 62–64 | 139/189 → true。 |
| `provider(forHost:)` | 102–109 | 精确表 → 通配后缀。 |
| `isSharePage(_:)` | 118–130 | `/share`、`/s/`；189 `/t/`；139 `/w/`、`/m/`；123 `/123pan/` 或 `share.` 子域。 |
| `normalized(_:)` | 133–140 | http→https（仅网盘域）。 |
| `detect(in:)` | 147–173 | NSDataDetector 首个网盘 URL → 裸域名正则兜底 → 补 https。 |
| `recentLink(in:scanLimit:)` | 176–184 | 前 N 条（默认 40）按类型过滤后逐条 detect。 |

### 3.15 `CloudLinkBar.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `CloudLinkBar.init()` | 23 | 空。 |
| `detectionKey(items:)` | 26–28 | 供父视图做布局动画 key（`scanLimit: 20`）。 |
| `link` (var) | 31–35 | 命中且未被 dismiss 才返回。 |
| `body` | 37–56 | 有 link 则条 + 插入动画 + 一次放大脉冲（0.28s 后复位）。 |
| `bar(_:)` | 58–117 | 徽标 + 名称/短 URL + 打开 + 解析下载 + 关闭。 |
| `providerBadge(_:)` | 119–128 | 28×28 圆角底 + SF Symbol。 |
| `shortURL(_:)` | 130–134 | host + path 尾部（>26 截断）。 |
| `CloudLinkPreviewAction.init(link:)` | 142 | 赋值。 |
| `CloudLinkPreviewAction.body` | 144–179 | 复制链接 / 打开 / 解析下载。 |
| `CloudLinkActions.resolve(_:)` | 185–191 | 日志 + `record(.browserOpen)` + `CloudLinkDownloader.shared.start`。 |

### 3.16 `CloudLinkPrompt.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init()` | 24 | 私有。 |
| `start()` | 26–46 | 幂等；记基线 `lastSeenItemID`；订阅 `$items` + 通知双通道；2s 后 `catchUpRecentShareLink`。 |
| `catchUpRecentShareLink()` | 49–64 | 前 20 条、30 分钟内、未提示过的分享页 → 补弹一次。 |
| `handle(_:)` | 66–84 | 启动 1.5s 内忽略；只要「启动后入库」（`timestamp - startedAt > 0.3`）；同 id 去重；同 URL 去重；命中则 `show`。 |
| `show(_:)` | 88–125 | 建 322×64 borderless panel（`.statusBar`），定位，`orderFrontRegardless`，12s 自动 dismiss。 |
| `positionFrame(size:)` | 128–140 | 优先贴状态栏按钮下方，钳制屏内。 |
| `dismiss()` | 142–148 | 取消计时、`orderOut`、置 nil。 |

### 3.17 `CloudLinkCenter.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `CloudLinkSettings.defaultUA(for:)` | 161–170 | 百度 `pan.baidu.com`（**非合法 UA**，仅作网盘校验标记）、夸克定制 UA、其它 Chrome UA。 |
| `CloudLinkTester.run(link:)` | 193–248 | 5 项检查初始化 → 同步判 0/1/3/4 → `probe` 异步判 2。 |
| `probe(url:provider:)` | 250–299 | `URLSession.ephemeral` GET，浏览器 UA，回调主线程；错误码 2 种降级为 warn；非 HTTP warn；200–399 ok（附 `<title>`）；401/403 warn；其它 warn。 |
| `mark(_:_:_:)` | 301–305 | 越界保护后写 checks。 |
| `scriptVersion(at:)` | 307–325 | 读前 4KB，从 `@name`/`@version` 拼版本串。 |
| `htmlTitle(_:)` | 327–334 | 前 8KB 找 `<title>`。 |
| `CloudLinkCenterView.body` | 361–379 | header/滚动配置/footer；`minWidth 560 / minHeight 620`；`onAppear` 跑检测。 |
| `header` / `checkSection` / `configSection` / `providersSection` / `footer` (var) | 383–735 | UI 分区（17 个 `@Stored` 镜像 + 每 setter 双写）。 |
| `stateIcon(_:)` | 459–470 | 5 态图标。 |
| `configRow(title:hint:content:)` | 668–680 | 行布局助手。 |
| `pickScript()` | 739–751 | `NSOpenPanel.runModal`（模态）→ 写配置 → 重跑检测。 |
| `pickDownloadDir()` | 753–763 | 同上选目录。 |
| `CloudLinkCenterController.show(link:)` | 773–787 | 关旧窗 → 建 600×660 窗 → `center` + `makeKeyAndOrderFront` + `activate`。 |

### 3.18 `CloudLinkDownloader.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `downloadsDirectory` (var) | 50–54 | 读配置目录并 `createDirectory`（**每次访问都 mkdir**）。 |
| `start(link:openBrowserOnFailure:)` | 60–92 | copy 引擎 + 直链 → 复制直链；直链 → 入队；否则 WKWebView 解析（成功入队，失败 Toast + 可选开浏览器）。 |
| `startDirectDownload(url:)` | 95–98 | 直连入队（自检用）。 |
| `isDirectFileURL(_:)` | 100–102 | 扩展名白名单（34 种）。 |
| `enqueueDownload(url:preferredName:provider:)` | 117–126 | 插 items 头部 + pending 尾部 + `pump()`。 |
| `pump()` | 128–134 | 在 `active < maxConcurrent` 且 pending 非空时出队执行。 |
| `release()` | 136–139 | `active -= 1` + `pump()`。 |
| `run(_:)` | 141–154 | 按引擎分派（copy 立即完成 / aria2 / builtin）。 |
| `download(_:)` | 156–196 | `URLSession.downloadTask` + UA/超时 → 落盘（冲突策略）→ `finish`。 |
| `sendToAria2(_:)` | 199–267 | 拼 `aria2.addUri` JSON-RPC，8s 超时，解析 `error` 字段。 |
| `handleFailure(_:reason:)` | 269–284 | 未超重试次数 → `release()` 后 1.2s 重插队首；否则 fail + `release()`。 |
| `destination(for:)` | 291–312 | overwrite/skip/rename（`name 2.ext` 递增）。 |
| `setStatus(_:_:)` | 314–319 | 主线程改 items。 |
| `finish(id:localURL:error:note:)` | 321–345 | 主线程收尾：失败 Toast；成功 Toast + `record(.fileDownload)` + 可选 Finder 显示。 |
| `sanitize(_:)` | 347–351 | trim + `/` → `_`。 |
| `LinkPageResolver.resolve(pageURL:completion:)` | 369–385 | 建隐藏 WKWebView（default dataStore）→ load → 12s 超时。 |
| `webView(_:didFinish:)` | 387–392 | 再等 1.2s 抓链接。 |
| `webView(_:didFail:withError:)` | 394–396 | 失败回调。 |
| `webView(_:didFailProvisionalNavigation:withError:)` | 398–400 | 同上。 |
| `extractLinks(from:)` | 402–432 | 注入 JS：`a[href]` + 整页 HTML 正则，去重取前 12；取第一个 → 成功并同步 cookie。 |
| `syncCookiesFrom(_:)` | 435–447 | 7 个域的 cookie 灌进 `HTTPCookieStorage.shared`（**全局副作用**）。 |
| `finish(_:syncCookiesFrom:)` | 449–459 | 取消超时、同步 cookie、断 delegate、清 webView、回调。 |

**并发闸与重试的坑（CloudLinkDownloader）**
`active`/`pending` 只在主线程改？不：`pump()`/`release()` 由 `run` 链调用，而 `download` 的 completion 来自 URLSession 的**后台队列**，`handleFailure` → `release()` → `pump()` 在这条队列上跑，`items`/`pending` 却另有主线程写（`enqueueDownload` 常由 UI 调）。**没有锁**，`pending` 数组与 `active` 计数器存在跨线程数据竞争（实测难复现，但属结构性风险）。
`handleFailure` 先 `release()` 再 1.2s 后重插队首——`release()` 会立刻 `pump()` 启动下一个 job，于是重试的 job 在多并发下可能被"挤出"到最后执行；`attempt` 记在 `Job` 结构体副本上，正确传递。

### 3.19 `PreviewImageLoader.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init()` | 37–39 | `cache.countLimit = 32`。 |
| `loadImage(at:thumbnailURL:needsFullRebuild:completion:)` | 49–85 | 命中缓存**同步**回调；否则登记 in-flight → 解码队列解码 → 主线程摘 in-flight + 写缓存 + 逐个回调。 |
| `detectQRCode(in:)` | 88–95 | `CIDetector` QR，low accuracy。静态。 |
| `cacheKey(url:full:)` | 99–101 | `"full:"/"thumb:" + path`。 |
| `decode(_:maxPixel:)` | 104–113 | ImageIO 下采样缩略。 |

---

## 4. 关键数据流

### 4.1 状态栏点击 → 面板出现

```
NSStatusItem 点击
  → StatusBar 模块 → ServiceLocator.panel?.toggle(atAnchor: rect)
  → PanelController.show(atAnchor:)
      ├─ StatisticsManager.record(.panelOpen)          [跨模块：Stats]
      ├─ MonitorPopoutWindowController.dismissPopout()  [跨模块：Monitor]
      ├─ syncPanelFrameToPersonalization() → Preferences(panelWidth)
      ├─ MainPanelPreviewPopoverCoordinator.prepareForPanelAppear()
      ├─ anchorOrigin / rightEdgeOrigin → setFrameOrigin
      ├─ presentation.visible = true → SwiftUI scale/fade 动画
      ├─ makeKeyAndOrderFront + NSApp.activate
      ├─ TransientWindowCenter.register(allowsClickIn:…)
      └─ MonitorSampler.setHomePanelActive(true)        [跨模块：Monitor]
            └─ 采样档位从"静息"切到"可见"
```

### 4.2 悬停一行 → 预览窗

```
NSTableView/SwiftUI 行 onHover(true)  [Clipboard 模块]
  → ServiceLocator.panelPreview.rowHover(true, item, anchorRectProvider, isFloatingSource)
  → PanelPreviewPresenterAdapter.rowHover → Coordinator.rowHover
      ├─ 读 hoverPreviewInMainWindowEnabled / …FloatingClipboardEnabled（默认 true）
      ├─ suppressHoverUntilMouseMove ? 丢弃
      └─ asyncAfter(0.35s) → hover-intent 校验 → anchorProvider() 取行框
          → Coordinator.present(for:anchorRectInWindow:mode:.hover)
              ├─ PreviewPopoverDataBridge.fullText(for:)   ← 同步读盘（风险点）
              ├─ PreviewPopoverContentModel.init → classify()（启发式）
              ├─ ClipboardPreviewWindowController.show(anchorRectInScreen:panelFrame:visibleFrame:)
              │     └─ [Clipboard 模块] 建 window(identifier=frset.clipboardPreview)
              ├─ installOutsideClickMonitor() + installEscapeMonitor()
              └─ track("main_panel_preview", "exposed")
```

关闭链路（多入口、单收口）：
`hoverOut / Esc / 点外 / itemRemoved / panelCollapse / programmatic` → `dismiss(reason:)` → `closeSlot` → `window.close()` → `onWindowClosed` → `handlePreviewWindowDidClose` → 清槽 + `beginHoverSuppression()`（等鼠标移动）+ 执行 completion（`PanelController.performHide`）。

### 4.3 打开面板 → 预览渲染 Markdown

```
PanelRootView.body (presentation.visible) → 预览窗内容视图
  → PreviewPopoverContentView.content → .markdown
  → PreviewMarkdownTextView.init(model:)
      → PreviewMarkdownRenderer.renderBody(inlineText)      [主线程，parseSourced]
  → MarkdownPreviewBody
      ├─ PreviewTOCSidebar(headings)               → 点击设 scrollRequest
      └─ PreviewTextViewRepresentable
            ├─ makeNSView: NSTextView + NSScrollView + (可选)行号标尺
            ├─ updateNSView: scrollRequest → scrollToCharacter → scrollToVisible
            └─ boundsDidChange → Coordinator.rememberMarkdownScroll(dedupeKey, offset)
                  └─ 下次同条目呈现：initialScrollOffset 恢复
```

### 4.4 复制网盘链接 → 下载落盘

```
用户 Cmd+C（任意 app）
  → [Clipboard 模块] 轮询 1s 入库 items + 发 itemsDidChangeNotification
      ├─ CloudLinkPromptController.handle(items)
      │     └─ detect → show(小胶囊) → 用户点「测试」→ CloudLinkCenterController.show
      └─ CloudLinkBar.link（ObservedObject）→ 首页条出现（父视图动画下移日历）
            └─ 用户点「解析下载」→ CloudLinkActions.resolve
                  → CloudLinkDownloader.start(link:)
                      ├─ 直链：enqueueDownload → pump → downloadTask → destination → finish
                      └─ 分享页：LinkPageResolver.resolve
                            ├─ 隐藏 WKWebView load
                            ├─ didFinish +1.2s → evaluateJavaScript 抓直链
                            ├─ 成功 → syncCookiesFrom → HTTPCookieStorage.shared   [全局副作用]
                            └─ enqueueDownload → 下载 → ~/Downloads（或配置目录）
                                  → Toast + StatisticsManager.record(.fileDownload)
```

### 4.5 拖文件到面板 → JSON 检视器

```
拖 .json 进面板
  → PanelRootView.onDrop → handleFileDrop(providers)
      └─ loadItem("public.file-url") → 主线程: onDismiss() + JSONInspectorWindowController.open(fileURL:)
            ├─ attributesOfItem 查大小 → >32MB 拒绝（NSAlert 模态）
            ├─ String(contentsOf:)（主线程）
            ├─ 必须 {/[ 开头
            └─ JSONInspectorHostController.load → state.text → onChange → parse()
                  └─ JSONDocument.init → JSONNodeModel 树（懒构建）
```

---

## 5. 资源清单

### 定时器 / 延时任务

| 位置 | 延时 | 门控 |
|---|---|---|
| `PanelController.scheduleWarmup` | 2.0s | `!warmupScheduled`，仅一次 |
| `PanelController.warmupPanel` | `RunLoop.run(until: +0.12)` | 面板不可见且 alpha==1 |
| `PanelController.show` 淡入 | `openAnimation.fadeDuration` | — |
| `PanelController.performHide` 淡出 | 0.12s | — |
| `PanelRootView.runCapture` | 0.12s | — |
| `PanelRootView` 探针 | 1.2s | `FRSET_PREVIEW_PROBE` 或 `probe.preview` |
| `PanelRootView` 底部搜索聚焦 | 0.12s | — |
| `CloudLinkBar` 脉冲复位 | 0.28s | — |
| `CloudLinkPromptController.start` 追赶 | 2.0s | 一次 |
| `CloudLinkPromptController.show` 自动收 | 12.0s | 可被 `dismiss` 取消 |
| `Coordinator` hover 开 | `hoverPreviewOpenDelay` = 0.35s | 总开关 + 抑制期 |
| `Coordinator` hover 关 | `hoverPreviewCloseDelay` = 0.25s | 可递归重排 |
| `Coordinator` 键盘预览 | `keyboardPreviewPresentationDelay` = 0.30s | — |
| `PreviewFileBackedTextView.loadFullText` 指示器 | `previewLoadingIndicatorDelay` = 0.40s | 代际校验 |
| `PreviewImageView.editImage` | 0.12s | — |
| `LinkPageResolver` 解析超时 | 12.0s | `timeoutWork` 可取消 |
| `LinkPageResolver.didFinish` 后抓取 | 1.2s | — |
| `CloudLinkDownloader.handleFailure` 重试 | 1.2s | `attempt < retryCount` |

### 线程 / 队列

| 资源 | 用途 |
|---|---|
| 主线程 | 全部 UI、`present`、`parseSourced`、`renderBody`、`JSONDocument.init`、`draw`、读盘（`PresentationBridge.fullText`、`JSONInspectorWindow.open(fileURL:)`、`cachedBackgroundImage`） |
| `Task.detached(.userInitiated)` | `PreviewFileBackedTextView.loadFullText` 读全文；`PreviewImageView.recognizeNow` 读图 Data；`loadImages` 内部 |
| `Task.detached(.utility)` | `PreviewImageLoader.detectQRCode`（QR 检测） |
| `preview-image-decoder`（串行，`.userInitiated`） | `PreviewImageLoader.decode` |
| URLSession 后台队列 | `CloudLinkDownloader.download` completion、`sendToAria2` completion、`CloudLinkTester.probe` |
| WKWebView 内部队列 | `LinkPageResolver` JS 求值回调 |
| `DispatchQueue.main.async` | `LinkPageResolver.finish` 回调链、`CloudLinkDownloader.setStatus/finish` |

### 子进程

| 位置 | 说明 |
|---|---|
| `PreviewFileView` → `ArchiveCore.extract` | 解压（core 内部起 `7zz`，本文件不直接 spawn） |
| `PreviewFileView` → `ArchivePeekView` / `ArchiveCreateWindowController` / `ArchiveBrowserWindowController` | 归档浏览/创建（间接） |
| `CloudLinkDownloader` aria2 | **不 spawn**，只走 JSON-RPC（需用户自备 aria2） |

### 文件路径

| 路径 | 用途 |
|---|---|
| `~/Library/Application Support/<bundle>/…`（`ClipboardFileStore.url(forRelativePath:)`） | 剪贴板图片/文本/富文本相对路径根 |
| `CloudLinkSettings.downloadDirectory`（默认 `~/Downloads`） | 网盘下载落盘 |
| `CloudLinkSettings.scriptPath` | LinkSwift `.user.js` |
| `user script update URL` 默认 `raw.githubusercontent.com/hmjz100/LinkSwift/main/LinkSwift.user.js` | 自动更新源（当前无下载实现，仅存值） |
| `NSImage(contentsOfFile: backgroundImagePath)` | 个性化背景图 |

### UserDefaults 键

| 键 | 类型 | 说明 |
|---|---|---|
| `panelWidth` / `panelHeight` | Double | 面板尺寸（写入前 ≥320×400） |
| `panelPinned` | Bool | 置顶窗口 |
| `panel.previewPinned` | Bool | 预览固定（裸 UserDefaults，非 `Preferences`） |
| `hoverPreviewInMainWindowEnabled` | Bool(默认 true) | 主面板悬停预览总开关 |
| `hoverPreviewInFloatingClipboardEnabled` | Bool(默认 true) | 悬浮剪贴板悬停预览 |
| `clipboard_keyboard_preview_hint_consumed` | Bool | 空格预览一次性提示 |
| `probe.preview` | String | 预览探针（`text`/`image`/`0`） |
| `cloudlink.scriptPath` / `.downloadDirectory` / `.timeout` / `.autoUpdate` / `.uaOverride` | — | 基础配置 |
| `cloudlink.engine` / `.maxConcurrent` / `.connectionsPerFile` / `.chunkSizeMB` / `.retryCount` / `.resume` / `.conflictPolicy` / `.revealAfterDownload` | — | 下载引擎配置 |
| `cloudlink.aria2.endpoint` / `.aria2.token` | String | aria2 RPC |
| `cloudlink.scriptUpdateURL` | String | 脚本更新源 |
| `panelTransferDockEnabled`（`Preferences.Keys.panelTransferDock`） | Bool | 中转/投屏分段显隐 |

### 通知 / 事件

| 名称 | 方向 |
|---|---|
| `Personalization.didChangeNotification` | 收（→ 面板尺寸/材质联动） |
| `.clipboardSelectionChanged` | 收（→ 根视图选中项） |
| `.frsetFocusPanelSearch` | 收（→ 回主页） |
| `.frsetClipboardScrollTop` | 发（→ 剪贴板列表回顶） |
| `ClipboardManager.itemsDidChangeNotification` | 收（→ 网盘提示双通道） |
| `frset.clipboard.editImage` | 发（→ Capture 模块标注器，object = NSImage） |
| `NSView.boundsDidChangeNotification` | 收（→ 滚动偏移上报） |

### NSEvent monitor（全局/本地）

| monitor | 匹配 | 生命周期 |
|---|---|---|
| outsideGlobalMonitor | `leftMouseDown/rightMouseDown` | hover 预览呈现时安装，dismiss/移除时成对卸载 |
| outsideLocalMonitor | 同上 | 同上 |
| escapeMonitor | `keyDown`(53) | 每次 `present` 后安装，`handlePreviewWindowDidClose` 卸载 |
| suppressEventMonitor | `mouseMoved/leftMouseDragged/otherMouseDragged` | 预览关闭后安装，首次鼠标移动卸载 |

---

## 6. 不变量与陷阱

1. **缩放只发生一处**（`PanelRootView` 73–75 注释纪律）：窗口尺寸负责缩放，内容恒 1:1 填充。破坏它 → 360×0.9=324 的"比例怪 + 右侧空条 + hosting 反向压窗拉锯"回归（v73 的历史根因）。
2. **`NSHostingView.sizingOptions = []` 与 `safeAreaRegions = []` 不可去掉**：去掉即恢复"SwiftUI fitting 压窗口"。与设置窗 800×1554 死循环崩溃同族。
3. **面板宽度下限 320**：`prepare` / `sync` / `persistSize` 三处都要钳制。任一处放宽 → 窄值写进偏好、此后每次启动都窄（v73 回归）。
4. **`isActive`/按页实例化纪律**：隐藏页不得留在视图树（不得回退到 opacity(0) ZStack），否则"每帧合成 4 页 + 隐藏页 body 重算"回来（v136 的卡顿与玻璃发闷）。
5. **预览关闭只能走 `window?.close()`，不能 `performClose`**：borderless 的 hover 窗 `isCloseable == false`，`performClose` 静默无效 → 孤儿窗 + "点叉号关不掉"（v83）。
6. **`handlePreviewWindowDidClose` 是唯一清理点**：绕过它（例如直接 `orderOut`）会漏掉抑制期安装、监控卸载、completion 执行 → 面板收起卡住 + 悬停立即复弹。
7. **`present()` 必须先 `closeSlot` 再建新槽**：槽只有一份，两个窗口同时活会导致"叉号关错窗"。
8. **鼠标位置兜底与 `popoverHoverChanged` 双保险不可去掉其一**：SwiftUI `onHover` 在 nonactivating 面板 key 切换 / NSViewRepresentable 上方会丢失；只留 SwiftUI 侧 → "鼠标移向预览想复制 OCR，预览先消失"（v71 实障）。
9. **`parseStatement` 必须是纯函数**（MermaidRenderer 168 行注释）：改成 inout + 闭包会立刻触发 Swift 独占访问冲突崩溃。
10. **Mermaid 绘制不能在 `body`/`init` 里 `lockFocus`**：注释记录会触发 `NSHostingView` 桥接期的 Fatal access conflict（2026-10-18 实测）。
11. **分享页解析不得绕过登录**：`extractLinks` 只取页面已有直链；任何"伪造请求/绕风控"的改动都违反该文件头注释的自我约束。
12. **`CloudLinkSettings` 的 `maxConcurrent`/`connections`/`retryCount` 有区间钳制**（getter 里 clamp）。去掉 → 0 并发死锁 / 16 以上打爆目标站。
13. **预览高度估算与渲染必须同 `scale`**（1.5）：`estimatedPopoverHeight` 与 `renderBody` 共用 `PreviewMarkdownRenderer.scale`。改一处不改另一处 → popover 裁切。
14. **`JSONNodeModel` 深度上限 64**：去掉 → 恶意深嵌套 JSON 递归爆栈。

---

## 7. 重复实现 / 死代码 / 风险

### 重复实现

| 项 | 位置 | 说明 |
|---|---|---|
| 行号标尺 | `PreviewLineNumberRulerView`（Panel 私有）vs `CodeLineNumberRulerView`（AI/Code 模块） | 注释自认"职责相邻，本类为面板侧私有实现" |
| 媒体/文件缩略图 | `PreviewFileThumbnailLoader`（ImageIO/CGPDF/QL）vs `PreviewImageLoader`（ImageIO 下采样） | 两条独立缓存（NSCache 60 vs 32），同一张图可能被解码两次 |
| Markdown 渲染入口 | `PreviewMarkdownRenderer.render`（文首目录）与 `renderBody`（无目录） | `render` 只服务导出/独立窗口场景，当前**无调用方** |
| JSON pretty-print | `PreviewJSONTextView.prepare` 与 `JSONRawView.pretty` | 两处各自 `JSONSerialization` 往返 |
| 网盘链接提取 | `CloudDriveLinkDetector.recentLink` 被 `CloudLinkBar.link`、`CloudLinkBar.detectionKey`、`CloudLinkPromptController.catchUpRecentShareLink` 三处各自调用 | 同一批 items 被反复全量 `detect`（`detectionKey` 在**每次 body 求值**都跑一遍） |

### 死代码 / 未接线

| 符号 | 状态 |
|---|---|
| `PreviewNavigationCommand` | 无任何构造点 |
| `Coordinator.setPreviewOrder` / `previewOrder` / `trackedPreviewItemMinYByID` / `pendingPreviewVisibilityValidationTargetID` | 写入但从不读取（F7/F8/P6 未实现） |
| `PreviewArrowGeometrySupport` / `PreviewArrowGeometryStore`（整两类） | v71 NSPopover 退役后无消费者 |
| `PreviewPopoverContentModel.estimatedPopoverHeight` | 无调用方（统一窗口后不再需要 popover 高度） |
| `PreviewJSONTextView.displayText` | 计算了 `prepare()` 结果但 `body` 不用 |
| `MarkdownScrollState.anchorBlockID` / `blockFrames` | 只写 `scrollOffset`，另外两个字段从不赋值 |
| `CloudLinkSettings.autoUpdate` / `scriptUpdateURL` | 只有 UI 与存储，**没有下载/比对实现**（"脚本自动更新"未落地） |
| `CloudLinkSettings.chunkSizeMB` 在 builtin 引擎下 | 无意义（只传 aria2） |
| `PanelController.isPanelVisible` / `panelFrameForPopout` / `panelWindowForProbe` | 供外部只读，本目录内无消费者 |
| `PreviewPopoverContentModel.Entry.filterSession/searchToolResult` | 定义但从不使用（入口恒 `.mainList`） |

### 风险（按严重度）

| # | 风险 | 位置 | 影响 |
|---|---|---|---|
| R1 | `present()` 在**主线程同步**取全文（`PreviewPopoverDataBridge.fullText` 内含 `String(contentsOfFile:)`、RTF 解析） | Coordinator 196 | 大文本悬停即卡帧；已有异步加载路径却未复用 |
| R2 | `PreviewImageLoader` 用 `NSLock` 保护 `cache`（NSCache 本身线程安全）但 `previewCacheMaxWidth/Height/backingScale` 是可变属性、跨线程读 | PreviewImageLoader 24–28, 65–67 | 数据竞争（读到的可能是撕裂值，实践上 CGFloat 原子） |
| R3 | `PreviewMarkdownRenderer._reCache` 静态可变字典，无锁 | PreviewMarkdownRenderer 524 | 若将来把渲染搬到后台队列 → 字典并发写崩溃 |
| R4 | `CloudLinkDownloader.pending/active` 无锁，多线程写 | CloudLinkDownloader 114–139 | `pending.removeFirst()` 与 `insert` 竞争 → 崩溃或漏 job |
| R5 | `CloudLinkCenterView` 每个 setter 双写（`@Stored` + `CloudLinkSettings`），且 `@Stored` 初值在 `body` 求值前读取 | CloudLinkCenter 342–357 | 外部（其他窗口）改设置后本视图不回读 → UI 显示旧值 |
| R6 | `CloudLinkPromptController.show` 每次都新建 NSPanel，旧的只 `orderOut` 不 `close` | CloudLinkPrompt 88–125 | 若 `show` 连续触发（多链接复制），窗口对象泄漏（`isReleasedWhenClosed` 默认 true 但从未 close） |
| R7 | `handleFileDrop` 只取 `providers.first` | PanelRootView 678–681 | 多文件拖入只剩第一个 |
| R8 | `dropToLocalTransfer` 完成后强切中转页 | PanelRootView 366–372 | 用户在别的页被切走 |
| R9 | `JSONInspectorRootView.copyFormatted` 复制原文而非格式化结果 | JSONInspectorWindow 234–237 | 按钮名与行为不符 |
| R10 | `PanelRootView` 预览探针在图片条目上**写入假 OCR 文本** | PanelRootView 170–175 | 若用户误设 `probe.preview=image` 且未清，会把"（探针样例）"永久写进真实 OCR 缓存 |
| R11 | `CloudLinkSettings.defaultUA(for: .baidu)` 返回 `pan.baidu.com`（非合法 UA） | CloudLinkCenter 163–165 | 若该值被用于真实下载请求，服务端可能 400；目前 `custom` 为空才用它，属"按网盘约定"的刻意 hack，但极脆弱 |
| R12 | `syncCookiesFrom` 把第三方 cookie 灌进 `HTTPCookieStorage.shared`（全 app 共享） | CloudLinkDownloader 435–447 | 其它网络请求会带上这些域 cookie；隐私/隔离面扩大 |
| R13 | `Coordinator.rememberMarkdownScroll` 字典无上限 | Coordinator 428 | 长期运行 + 大量条目 → 内存缓慢增长（每项一个小 struct，量级可控但不收敛） |
| R14 | `warmupPanel` 的 120ms `RunLoop.run(until:)` | PanelController 112 | 启动期主线程卡顿；与其它 2s 定时任务互相挤占 |
| R15 | `JSONTableView.columns` 每次 `rowValues` 求值都扫前 500 行子孙 | JSONInspectorView 538–566 | 大数组每次滚动/排序都重建列定义，O(500×字段数) |
| R16 | `MarkdownFilePreviewBody.init` / `PreviewMarkdownTextView.init` 在视图构造期同步渲染 | 359–366 / 471–477 | 长文档每次视图重建都全量重渲染（父视图 any 状态变化即重建） |
