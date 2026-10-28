# B3 — Features/Clipboard（剪贴板历史、NSTableView 行交互、悬浮剪贴板、文件存储）

> 范围：`apps/FrsetNext/Sources/Features/Clipboard/` 全部 **16** 个 `.swift`，合计 **5957** 行。整文件逐行读完（含 `ClipboardTableHostView` 1015 行）。
> 符号核对：CSV 中本目录声明 **358** 条，其中 `func` **236**、`init` 43、`class` 34、`enum` 15、`struct` 22、`extension` 7、`protocol` 1。
> 本报告列出 **236 个 CSV func** + 补齐 CSV 漏记的多行签名函数（`ClipboardManager.copy`、`ClipboardPreviewWindowController.init/show`、`ClipboardTableHostView.Coordinator.init(owner:)`、`FloatingClipboardStore.init/deinit`、`ClipboardItemEditWindowController.init(item:)`、`ClipboardItemEditSession.init`、`ClipboardItemEditTextView.init`×3、`ClipboardSectionView.runSummary`）等，表内共 **252** 行。

---

## 1. 文件清单

| 路径 | 行数 | 一句话职责 |
|---|---|---|
| `Clipboard/ClipboardManager.swift` | 812 | 总管：双速率轮询捕获 → 去重 → 落盘/入库 → 分页供给 → 复制/删除/编辑/工具回流/OCR/自动粘贴 |
| `Clipboard/ClipboardTableHostView.swift` | 1015 | 主列表 NSTableView 宿主：行复用、行点击语义、hover 抑制、顶部迟滞、分页、回顶代理、原生右键菜单、选中绘制接管 |
| `Clipboard/ClipboardSectionView.swift` | 675 | 主面板区段（列表容器）、九类过滤栏、标签过滤菜单、行视图、缩略图、独立预览窗登记、`Color(hex:)` |
| `Clipboard/LargeTextPreviewView.swift` | 588 | 大文本预览：JSON/Markdown 高亮渲染、NSTextTable 真表格 + 自绘边框、`AttributedTextView` 承载 |
| `Clipboard/ClipboardPreviewWindow.swift` | 523 | 统一预览窗（hover/persistent 双模式）：内容视图、头部操作、编辑态、玻璃材质 |
| `Clipboard/FloatingClipboardWindow.swift` | 447 | 悬浮剪贴板：几何/钉住持久化、`NSPanel`、独立数据源（最近 12 条）、内容视图与行 |
| `Clipboard/ClipboardRepository.swift` | 373 | `clipboard_items` 全部 SQL（查询/插入/更新/删除/清理辅助/行映射/LIKE 转义） |
| `Clipboard/ClipboardFileStorages.swift` | 324 | 相对路径文件存储（图片/缩略图/长文本/富文本/OCR）+ 内存索引 + 用量统计 |
| `Clipboard/ClipboardPasteboardReader.swift` | 257 | `NSPasteboard` 多类型读取（图>文件>富文本>文本>URL）+ 指纹 + 外部结果构造 |
| `Clipboard/ClipboardItemEditWindowController.swift` | 270 | 独立编辑窗（正文 + 重命名）+ 编辑会话（串行队列）+ 单例登记表 |
| `Clipboard/ClipboardPruneSchedulers.swift` | 145 | 两个清理调度器（保留天数 1h / 容量上限 10min）+ 清理结果 |
| `Clipboard/TagStore.swift` | 151 | 标签 CRUD + 分配/取消（增量内存索引）+ 批量 attach |
| `Clipboard/ClipboardModule.swift` | 72 | 模块入口 + `DoubleTapCommandMonitor`（0.4s 双击 ⌘ 呼出悬浮窗） |
| `Clipboard/ClipboardAppIconCache.swift` | 64 | 来源应用图标缓存（正/负缓存 + 5 个应用目录探测） |
| `Clipboard/ClipboardSummaryExecutionCoordinator.swift` | 78 | AI 摘要：按条目串行去重 + 写回为工具回流条目 |
| `Clipboard/ClipboardSettingsPane.swift` | 162 | 设置 → 剪贴板页：保留天数/容量上限/占用/立即清理/自动粘贴/浮动窗 |

---

## 2. 类型逐个说明

### 2.1 `ClipboardManager`（ObservableObject 单例）★核心

- **职责**：捕获 → 去重 → 落盘/入库 → 分页列表 → 操作（复制/删除/重命名/编辑/笔记/工具回流）。
- **线程模型（注释即契约）**：`queue`（`com.frsetnext.clipboard.persist`，串行 `.utility`）承担**一切 SQLite/文件 IO**；主线程只做 `NSPasteboard` 读取与 `@Published` 发布。
- **内部状态**：`items`、`searchText`/`filter`/`tagFilterID`（三者 `didSet → reload(reset:true)`）、`isLoadingMore`、`isMainListAtTop`；捕获族 `pollTimer`/`retryTimer`/`currentPollingInterval`/`burstUntil`/`lastChangeCount`/`lastSelfWrite*`/`currentPage`/`isIngesting`；`reloadGate`+`reloadPending`（合并 reload）。
- **生命周期**：`shared` 常驻；`start()` 起轮询 + 两个清理调度器 + 首次 reload；`stop()` 反注册。从不销毁。
- **依赖**：`ClipboardPasteboardReader`、`ClipboardRepository`、`TagStore`、`Preferences`、`DatabaseManager`、`ClipboardTextStorage`/`ClipboardRichTextStorage`/`ClipboardImageStorage`/`ClipboardOCRTextStorage`/`ClipboardFileStore`、`ServiceLocator.ocrService`、`PermissionGuideWindowController`、`PermissionCenter`、`StatisticsManager`、`Toast`。
- **被依赖**：`PanelRootView`（`CloudLinkBar` 观察 `items`）、`ClipboardSectionView`、`ClipboardTableHostView`、`FloatingClipboardStore`、`CloudLinkPromptController`、`ClipboardPreviewWindow`、`ClipboardItemEditWindowController`、两个 `PruneScheduler`、`ClipboardSummaryExecutionCoordinator`、`ClipboardSettingsPane`。
- **不变量**
  1. 所有写库/写盘必须在 `queue` 上（`writeToDatabase`/`saveContent`/`delete`/`rename`/`setNote`/`ingestToolOutput` 里除最后一条外都在 queue）。
  2. `poll()` 读 `changeCount` **两次比对**，不一致则 `scheduleRetry()`（防撕裂，原作 0x10016cc40 同款）。
  3. 自写回声必须打 `com.frset.selfwrite-token` + 5s TTL，并同步 `lastChangeCount`，否则复制即重复入库。
  4. `inlineTextByteLimit = 64KB`：超过则写 `texts/`，内存只留前 4000 字符；`storage_bytes` 必须"落盘产物 + 内联内容"，不得用 `approximateBytes` 起步再叠加（会双计）。
  5. `maxResidentItems = 800`：`items` 硬上限，`makeQuery` 与两处 fetch 都钳制。
  6. `isRecordingPaused` 期间**只同步 changeCount，不 ingest**，恢复后不回补。
  7. `reload` 必须经 `autoreleasepool`（GCD 队列无 runloop 边界）。

### 2.2 `ClipboardFilterKind`（enum, 9 case）

`all/text/image/link/file/code/color/generated/note`。`queryMapping` 把 UI 语义翻译成 `ClipboardQuery`：
- `.link → (.url)`（原作 SQL 里 type='url'）；
- `.code → (.text, codeLikeOnly: true)`（SQL LIKE 近似）；
- `.color → (toolGeneratedOnly + generatedSourceKeyword:"colorpicker")`（证据不足时的来源映射，注释明说）；
- `.note → noteOnly`。

### 2.3 `ClipboardQuery` / `ClipboardRepository`

- `ClipboardQuery`：search/type/noteOnly/toolGeneratedOnly/generatedSourceKeyword/codeLikeOnly/tagID/limit/offset。
- `ClipboardRepository`：`@unchecked Sendable`（底层 FULLMUTEX 连接），24 列常量。所有值走 `SQLiteValue` 绑定；搜索 `LIKE ... ESCAPE '\'` 且 `escapeLike` 逐字符转义。
- **被依赖**：`ClipboardManager`（唯一业务调用方）、两个 Prune 调度器、`TagStore`（同库）。

### 2.4 `ClipboardTableHostView` 家族 ★表交互核心

| 类型 | 职责 |
|---|---|
| `ClipboardTableScrollProxy` | 弱持 `NSScrollView`；`scrollToTop()` 用 `animator().setBoundsOrigin` 平滑回顶 |
| `ClipboardRowHoverSuppressionController` | 滚轮/菜单/多选 → `suppressUntilMouseMove`；鼠标移动解除 |
| `ClipboardListTopScrollTracker` | 首行底边与视口顶的**迟滞双阈值**（enter 40 / exit 24）→ `isOut` |
| `ClipboardRowChromeView` | `NSTableRowView` 子类，接管 `drawSelection`（内缩 6/1.5 + 圆角 9 + 强调色 12%/8%）与 `drawBackground`（空） |
| `RowHostingView` | `NSHostingView<AnyView>` 行容器：`sizingOptions = []`、`setItem/setHovered` 同值短路、`mouseDown` 分派、右键按下即回调、`acceptsFirstMouse = true` |
| `WeakRowBox` | 行号侧表弱引用盒（view-based NSTableView 无法从 subviews 反查行视图） |
| `ClipboardTableView` | `NSTableView` 子类：`layout()` 钉列宽=剪辑宽、`frameOfCell` 去 6pt 缩进、tracking area 随 `isActive`、`keyDown` 空格/↩ 分派、`isKeyboardNavigating` 标记 |
| `ClipboardListScrollView` | `NSScrollView` 子类，`scrollWheel` → 抑制 hover |
| `ClipboardTableHostView` | `NSViewRepresentable`，`@ObservedObject manager` + `personalization` |
| `Coordinator` | DataSource+Delegate+全部交互仲裁（约 420 行） |
| `ClipboardNativeMenuPresenter` | 原生 `NSMenu`（右键按下即弹）；符号 `NSCache(32)` |
| `BlockMenuItemAction` | `NSMenuItem.representedObject` 的闭包载体 |

- **不变量（逐条都有历史事故背书）**
  1. `isActive == false` 时**必须移除 tracking area**——`NSTrackingArea` 是 AppKit 层机制，不受 SwiftUI `allowsHitTesting(false)` 控制，否则透明页会弹"幽灵预览"。
  2. 行视图**不透传 super**，所以必须自己 `selectRowIndexes` + `makeFirstResponder(table)`（修复 C11，两个动作缺一不可，否则空格/↩ 永久不可用）。
  3. `layout()` 里钉列宽必须用**剪辑视图宽**，不能用 `table.bounds.width`（后者=列宽之和，会自增循环，实测爆到 22686）。
  4. 选中态必须由 `ClipboardRowChromeView.drawSelection` 接管，否则系统整行铺 `controlAccentColor`（"蓝色实心砖"）。
  5. `reloadTable()` 后**不能整体清空** `rowViewsByRow`（会抹掉 reloadData 期间刚登记的新映射），只能按"行号越界/视图已回收"裁剪。
  6. `hoveredItemID` 与 `hoveredRowView` 必须同时清空（只清视图会让下一次 mouseMoved 因同 ID 短路而永久失去高亮）。
  7. `isKeyboardNavigating` 只在 `keyDown` 到 `super.keyDown` 的同步窗口内置位，且必须兜底复位（边界处不产生选中变化时 `selectionDidChange` 不触发）。

### 2.5 `ClipboardSectionView` / `ClipboardFilterBarView` / `ClipboardTagFilterMenu` / `ClipboardRow` / `ClipboardThumbnailView` / `ClipboardPreviewWindow`

- `ClipboardSectionView`：只渲染 `list`（原版主页无标题/搜索/过滤栏）；`onAppear` 清协调器抑制 + reload + tagStore.refresh。
  - **死代码**：`header`（含标签菜单/浮动窗/刷新按钮）定义完整但 `body` 未使用——三个入口已收进右键菜单/状态栏（注释说明）。
- `ClipboardFilterBarView`：九段胶囊 + 可选回顶按钮（`accessibilityIdentifier("FilterBar_ScrollToTop")`）。**当前无调用方**（过滤改由底部工具条 Menu 驱动）。
- `ClipboardTagFilterMenu`：标签下拉（再选一次取消）。
- `ClipboardRow`：缩略图 + 来源徽章 + 单行标题 + 副行（时间 · 详情）+ hover 时两个图标按钮；`Theme.rowHoverFill` 内缩 6/1.5 圆角 9。
- `ClipboardRowMenuContent`：SwiftUI 右键菜单（与原生 `NSMenu` 版内容重复）。
- `ClipboardThumbnailView`：图片→缩略图、文件→系统图标（`NSCache(256)`）、其它→类型符号。
- `ClipboardPreviewWindow`（**enum 命名空间**）：`controllers: [String: NSWindowController]` 按 dedupeKey 登记大文本预览窗（640×480），`PreviewWindowCleaner` 在 `windowWillClose` 时释放。

### 2.6 `LargeTextPreviewView` 家族

| 类型 | 职责 |
|---|---|
| `PreviewMarkdownPreferenceStore` / `PreviewJSONPreferenceStore` | `preview.markdown.enabled` / `preview.json.enabled` 开关（默认 true） |
| `LargeTextPreviewMode` | plain/markdown/json + `infer(from:)`（JSON → Markdown → plain） |
| `JSONHighlighter` | `prettify` / `isParseableJSON` / `render`（字符串 key 紫、值绿、字面量橙、数字蓝）+ 静态正则缓存（**带锁**） |
| `MarkdownCodeSyntaxHighlighter` | 逐行拼 `AttributedString`（**用 AppKit 作用域**，v127 修"字体静默丢失"）+ NSTextTable 真表格 |
| `AttributedTextView` | `NSViewRepresentable` + `PreviewTextView` |
| `PreviewTextView` | 自绘 NSTextTable 单元格边框（`refreshGridCache` + `draw` + `layout`） |
| `LargeTextPreviewView` | 模式 Picker + 渲染 |
| `LargeTextPreviewContainerView` | 条目 → 全文（`onAppear` 同步读） |

### 2.7 `ClipboardPreviewWindowController` / `HoverPreviewWindow` / `ClipboardPreviewWindowRecord` / `ClipboardPreviewWindowView`

- 双模式：`.hover`（borderless，`orderFront` 不激活）与 `.persistent`（titled 可缩放，`makeKeyAndOrderFront`）。
- `identifier = "frset.clipboardPreview"` —— `PanelController.windowDidResignKey` 据此保持主面板。
- **生命周期**：由 `MainPanelPreviewPopoverCoordinator` 的 `Slot` 创建与持有；`windowWillClose` → `onWindowClosed` → 协调器清理。
- **不变量**
  1. `isReleasedWhenClosed = false`（只 close 不销毁，靠 controller 存活）。
  2. hover 态**不能用 `contentView.layer.masksToBounds` 裁圆角**（会切断阴影形状采样，v71 实障），改由 SwiftUI `clipShape`。
  3. `windowDidResignKey` 延迟 0.12s 再判定（避让"点击瞬间的临时失焦"）；persistent 在本 app 内换 key 时**不关**（边看边换）。

### 2.8 `FloatingClipboardPinState` / `FloatingClipboardPanel` / `FloatingClipboardStore` / `FloatingClipboardWindowController` / `FloatingClipboardContentView` / `FloatingRow`

- `PinState`：几何 + `isVisible` + `isPinned`（默认 true）全落 `Preferences`（`floatingClipboard.*`）；`clampedFrame()` 做屏幕越界夹取。
- `Store`：`recentItems`（最近 12）+ `searchText` + `filteredItems`；**订阅 `itemsDidChangeNotification` 的第二个消费者**（第一个是 `CloudLinkPromptController`）。
- `Controller`：`show/hide/toggle/showNearMouse/restoreVisibilityIfNeeded`；`windowDidMove/Resize` 持久化 frame。
- `FloatingRow`：单击预览、双击复制、hover 预览（`isFloatingSource: true`）。

### 2.9 `ClipboardItemEditSession` / `ClipboardItemEditTextView` / `ClipboardItemEditWindowController` / `ClipboardItemEditWindowRecord`

- Session 用自有串行队列保护三个字段；`snapshot()` 用 `queue.sync`（**在 UI 线程同步取快照**，若队列上有长任务会卡）。
- Controller：纯 AppKit 手写布局（560×420），`save` 时 `saveContent` + `rename` 两次异步写库（**无事务**）。
- Record：`NSLock` 保护的 `[dedupeKey: controller]`，保证同一条目单窗。

### 2.10 `TagStore`

- `tags`（`@Published`）+ `mapping: [String: [String]]`（dedupeKey → tagIDs，`NSLock` 保护）。
- `attachTags` 在 fetch 内被调用（持锁就地查表，v126 去掉整表拷贝）。
- `assign/unassign` 走**增量索引**而非全表 refresh（v126）；`create` 遇 UNIQUE 冲突回查同名。

### 2.11 `ClipboardHistoryRetentionPruneScheduler` / `ClipboardStoragePruneScheduler` / `ClipboardPruneResult`

- Retention：1h Timer，批量 200 步进删除 `timestamp < cutoff`。
- Storage：10min Timer，`usage.exceeds(target=0.9×limit)` 循环删最旧（`exceeds` 短路：先 SQL SUM，超限才遍历目录）。
- 两者 `prune()` 都会 `ClipboardManager.shared.reload()`。

### 2.12 `ClipboardModule` / `DoubleTapCommandMonitor`

- `start()`：`DoubleTapCommandMonitor.start()` → `ClipboardManager.start()` → **再次** start 两个 Prune 调度器（与 `ClipboardManager.start()` 内部重复，靠 `guard timer == nil` 幂等）→ 恢复浮动窗 → 注册面板区段与设置页签。
- `DoubleTapCommandMonitor`：`flagsChanged` 全局+本地监听，0.4s 内两次 cmd 按下 → `showNearMouse()`。**返回值未保存**（monitor 永不移除）。

### 2.13 `ClipboardAppIconCache` / `ClipboardSummaryExecutionCoordinator` / `ClipboardSettingsPane`

- 图标缓存：正缓存 `NSCache(256)` + **负缓存** `NSCache(256)` + 5 个探测目录。
- 摘要协调器：`running: Set<String>` + `NSLock`（加解锁收进同步方法，规避 Swift 6 async 中 lock 不可用）；`summarize` 截断 8000 字符；`summarizeAndWriteBack` 走 `ingestToolOutput`。
- 设置页：三组（历史/捕获/浮动窗）；`usageBytes` 是 `@Stored` 状态（v115 修"清理后占用不刷新"）。

---

## 3. 函数级清单

### 3.1 `ClipboardManager.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `isRecordingPaused` (var, didSet) | 158–168 | 置位时同步 `changeCount`；post `recordingPausedDidChangeNotification`。 |
| `start()` | 174–182 | 记基线 changeCount → `schedulePoll(idle)` → `tagStore.refresh()` → `reload(reset:true)` → **起两个 Prune 调度器**。 |
| `stop()` | 184–189 | 停两个 Timer + 停调度器。 |
| `schedulePoll(interval:)` | 193–200 | 重建 `Timer(.common)`。 |
| `pollTick()` | 202–211 | 按 `burstUntil` 决定有效间隔，变化时重建 Timer，然后 `poll()`。 |
| `poll()` | 213–243 | `autoreleasepool`；changeCount 双读比对 → 相等才继续；暂停/自写回声抑制；最后 `ingest()`。 |
| `scheduleRetry()` | 246–256 | 一次性 Timer（≥0.5s）重试 `poll`；`retryTimer` 去重。 |
| `ingest()` | 262–281 | 见下方。 |
| `persist(_:)` | 283–288 | `queue.async` → `writeToDatabase`。 |
| `writeToDatabase(_:)` | 291–395 | 见下方。 |
| `scheduleReloadCoalesced()` | 405–418 | `reloadPending` 合并：同批 main 派发只跑一次 `reload(reset:true)`。 |
| `updateFirstItemScrolledOut(_:)` | 421–426 | 变化才写 `isMainListAtTop` + post 通知。 |
| `makeQuery(limit:)` | 429–441 | filter 映射 + tag + `limit` 钳到 800 + `offset 0`。 |
| `reload(reset:)` | 447–464 | 见下方。 |
| `loadMoreIfNeeded(currentItem:)` | 466–486 | 四重门禁（未到 800 / 已有整页 / 是尾行 / 非 loading）→ `page+1` → fetch → 截断。 |
| `recentItems(limit:completion:)` | 489–496 | 浮动窗专用：不受过滤影响，主线程回调。 |
| `fullText(for:)` | 501–505 | `textPath` → `richTextPath` → `content`（**同步读盘**）。 |
| `ocrText(for:)` | 507–509 | `ClipboardOCRTextStorage.read`。 |
| `copy(_:autoPaste:)` | 514–553 | 见下方。 |
| `delete(_:)` | 570–578 | queue 上 `repository.delete` → 主线程移除 + 通知。 |
| `rename(_:aliasTitle:)` | 581–586 | `updateAliasTitle` → `reload(reset:false)`。 |
| `saveContent(dedupeKey:newContent:)` | 589–618 | 见下方。 |
| `setNote(_:isNote:)` | 621–626 | `updateFields(note:)` → reload。 |
| `ingestToolOutput(...)` | 630–664 | 见下方。 |
| `insert(_:)` | 669–672 | 外部结果走同一 `writeToDatabase`。 |
| `insertImage(data:fileURL:sourceApp:)` | 675–678 | 构造 imageResult → `insert`。 |
| `insertText(_:sourceApp:subtitle:)` | 681–683 | 构造 textResult → `insert`。 |
| `auxiliaryBytes(item:)` | 689–693 | 图片+缩略图+富文本副文件字节和。 |
| `scheduleAutoStage(_:)` | 697–704 | 主线程 post `filesCapturedNotification`（跨模块不直接引用）。 |
| `scheduleOCR(dedupeKey:imageData:)` | 707–726 | 见下方。 |
| `pasteToFrontmostApplication()` | 729–748 | `AXIsProcessTrusted` 检查 → `CGEvent` Cmd+V 合成 → Toast。 |
| `presentAccessibilityGuide()` | 756–778 | 首次弹模态三选一，之后只 Toast。 |

**`ingest()`（262–281）**
`isIngesting` 单飞 → `reader.read()`（失败 → `scheduleRetry`）→ `isEmpty` 丢弃 → 来源 app 在忽略名单则丢弃 → 置 0.5s 突发（`burstUntil = now+2s`）→ `persist`。
**坑**：`burstUntil` 与 `currentPollingInterval` 在**主线程**改，`pollTick` 也主线程读，一致；但 `poll()` 的 `lastChangeCount` 更新发生在暂停/回声分支里，若 `ingest` 抛错（无 throws）无影响。

**`writeToDatabase()`（291–395，104 行，全部在 queue 上）**
① `autoreleasepool`（GCD 无 runloop 边界）。
② `makeDedupeKey(type/content/imageHash)`；命中则 `touch` + 合并 reload 返回。
③ 按类型落盘：
  - `.image` → `ClipboardImageStorage.store`（原图 + 200px 缩略图，**一次 ImageIO 解析**），`fileBytes` = 原图 + 缩略图字节；失败则退回 `approximateBytes`。
  - `.richtext` → RTF 落盘 + 正文超 64KB 再落 `texts/`。
  - `.file/.text/.url` → 超 64KB 落 `texts/`，内存留前 4000 字符。
④ 构造 `ClipboardItem`（`imageDimensionUnit = "px"`, `storageBytes = fileBytes`）。
⑤ `insert` 成功 → `bumpStat("capture_count")` + 图片→`scheduleOCR` + 文件→`scheduleAutoStage`；失败（UNIQUE 冲突）→ `touch` 退化置顶。
⑥ `scheduleReloadCoalesced()`。
**坑**：`fileBytes` 对 `.richtext` 只累加 `rtf.count` 与正文；若 RTF 写入成功但正文超阈值落盘，两者都计入（正确）；但 `.image` 分支失败时用 `approximateBytes`，与 `ClipboardStorageUsageProvider.diskBytes` 口径不同（前者估算、后者实测），会出现"DB 口径 < 磁盘口径"。

**`reload(reset:)`（447–464）**
目标页 → `makeQuery(pageSize×(page+1))` → queue 上 `autoreleasepool { fetch }` → 主线程 `items = prefix(800)` + `currentPage` + post `itemsDidChangeNotification`。
**坑**：每次 reload 都是"从头拉 N 页"的累积模型，翻到第 4 页就是 4 次 200 行 fetch 的等价（实际一次 LIMIT 800）；深翻到 800 条后停止。搜索每敲一个字触发一次 reload（`searchText.didSet`），每次都是完整 SQL + `attachTags`。

**`copy(_:autoPaste:)`（514–553）**
清剪贴板 → 按类型写（image: png/tiff data；file: `writeObjects` NSURL；richtext: rtf data + 纯文本；text/url: string）→ 打 `selfwrite-token`（新 UUID）+ 记 TTL/changeCount → 同步 `lastChangeCount` → `record(.historyCopy)` → Toast → 可选自动粘贴（`record(.clipboardPaste)`）。
**坑**：`setData(token, forType:)` 是**追加**一个自定义类型到同一个 pasteboard item；写完后 `lastSelfWriteChangeCount` 取的是"打完 token 之后"的 changeCount，而 `poll` 里比对的是"这次 changeCount == lastSelfWriteChangeCount 且 marker == token"——两者一致（同一次写操作只有一次 changeCount 递增）；但如果外部程序在 5s 内**追加**类型（不递增？实际会递增），抑制即失效（按设计）。

**`saveContent(dedupeKey:newContent:)`（589–618）**
取旧条目 → 算副文件字节 → 超阈值：先写新文件、再删旧文件（**注释：避免中途失败丢数据**）→ `updateContent`；否则删旧 textPath、写内联 → `updateContent` → 主线程 `reload(reset:false)`。
**坑**：`storageBytes` 里 `+ auxiliary`，但 `auxiliary` 是**改动前**的图片/缩略图/富文本字节（正文编辑不改它们，正确）。

**`ingestToolOutput(...)`（630–664，`@discardableResult`）**
`key = "tool:" + text.sha256` → 命中 touch，否则超阈值落盘 + 构造 `isGeneratedByTool=true` 条目 → `insert` → `reload(reset:true)` → 返回一个**不带 id/timestamp 的临时 item**（只用来回传给调用方）。
**坑**：该函数在**调用线程**直接同步访问 `repository`（`exists`/`insert`），没有走 `queue`——与"所有 IO 在 queue"的约定冲突。当前调用方是 `ClipboardSummaryExecutionCoordinator`（async 上下文，可能在任意线程），属结构性隐患。

**`scheduleOCR(...)`（707–726）**
开关 `automaticScreenshotOCREnabled`（默认 true）+ `ServiceLocator.ocrService` 存在才跑；`Task.detached(.utility)` 识别 → 空结果 Toast「未读取到文字」→ 写 OCR + `bumpStat("ocr_count")`；异常 Toast + warn。
**坑**：`Toast.show` 在 detached 任务里直接调用（未回主线程）——依赖 `Toast` 自身线程安全；`ClipboardOCRTextStorage.write` 也在后台（其内部有锁）。

### 3.2 `ClipboardTableHostView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardTableScrollProxy.init()` | 29 | 空。 |
| `scrollToTop()` | 34–44 | `animator().setBoundsOrigin(.zero)` + `reflectScrolledClipView`（`dPage`/`caEaseOut`）。 |
| `ClipboardRowHoverSuppressionController.init()` | 55 | 空。 |
| `suppressUntilMouseMove()` | 59–63 | 置位 + 清两个 hovered ID。 |
| `mouseMoved()` | 66–68 | 解除。 |
| `ClipboardListTopScrollTracker.init()` | 89 | 空。 |
| `feed(firstRowMinY:firstRowHeight:viewportOriginY:)` | 96–109 | `distance = viewportOriginY − (minY+height)`；迟滞 enter 40 / exit 24。 |
| `setOut(_:)` | 111–115 | 变化才回调。 |
| `ClipboardRowChromeView.drawSelection(in:)` | 131–138 | `insetBy(6,1.5)` + 圆角 9 + `Theme.accentNS` 12%/8%。 |
| `drawBackground(in:)` | 141 | 空（不画行底色）。 |
| `RowHostingView.init(reuseIdentifier:frame:)` | 168–179 | `sizingOptions = []`（v100 修"每行宽度不一"）。 |
| `init(rootView:)` / `init?(coder:)` | 182–189 | `fatalError`。 |
| `setItem(_:hovered:)` | 194–200 | 同 id 同 hover 短路；否则重挂 `rootView`。 |
| `setHovered(_:)` | 203–208 | 同值短路后重挂。 |
| `rightMouseDown(with:)` | 211–215 | 直接回调（**不调 super**，吞事件）。 |
| `mouseDown(with:)` | 217–248 | 见下方。 |
| `acceptsFirstMouse(for:)` | 250 | true。 |
| `ClipboardTableView.layout()` | 298–309 | 列宽钉到剪辑视图宽（防自增循环）。 |
| `frameOfCell(atColumn:row:)` | 314–319 | x=0，宽=剪辑宽（去 6pt 缩进）。 |
| `updateTrackingAreas()` | 321–332 | 先移旧区；`isActive` 为假则不建。 |
| `mouseMoved(with:)` | 334–337 | `isActive` 才上报。 |
| `mouseExited(with:)` | 339–342 | 同上。 |
| `keyDown(with:)` | 345–371 | 空格（选中行才拦截）/↩ 或 `\u{3}` / 其余置 `isKeyboardNavigating` 后 `super` 并兜底复位。 |
| `ClipboardListScrollView.scrollWheel(with:)` | 379–382 | 先 `onScrollWheel?()` 再 super。 |
| `ClipboardTableHostView.init(...)` | 400–414 | 赋值。 |
| `makeCoordinator()` | 416–418 | 建 Coordinator。 |
| `makeNSView(context:)` | 427–472 | scrollView（overlay 滚动条、bottom inset 52）+ table（`allowsMultipleSelection`、`intercellSpacing(0,3)`、`.fullWidth`）+ 单列 + 绑定 + bounds 通知。 |
| `updateNSView(_:context:)` | 474–489 | 同步 owner/isActive；行高变化改 height；`sizeLastColumnToFit` + `reloadTableIfNeeded`。 |
| `Coordinator.reloadTableIfNeeded()` | 500–507 | items id 哈希 + 行高变化才全表 reload。 |
| `Coordinator.init(owner:)` | 524–531 | 挂 `topTracker.onFirstItemScrolledOutChange` → `manager.updateFirstItemScrolledOut`。 |
| `bind(scrollView:table:proxy:)` | 533–552 | 弱持三者；`proxy.scrollView = scrollView`；注册 `.frsetClipboardScrollTop`；挂四类回调 + 滚轮抑制。 |
| `numberOfRows(in:)` | 556–558 | `manager.items.count`。 |
| `tableView(_:viewFor:row:)` | 560–599 | 见下方。 |
| `tableView(_:heightOfRow:)` | 601–604 | `Theme.statsRowHeight`。 |
| `tableView(_:rowViewForRow:)` | 607–609 | 返回 `ClipboardRowChromeView()`。 |
| `tableView(_:didAdd:forRow:)` | 611–618 | 只在最后 3 行触发 `loadMoreIfNeeded`。 |
| `tableViewSelectionDidChange(_:)` | 620–637 | post `.clipboardSelectionChanged`；仅键盘导航时 `cancelKeyboardPreview`。 |
| `reloadTable()` | 641–681 | 见下方。 |
| `clipboardBoundsDidChange(_:)` | 685–688 | 非锚定滚动时 `feedTopTracker()`。 |
| `feedTopTracker()` | 693–702 | row 0 的 rect 与 clipView 原点喂 tracker。 |
| `handleMouseMoved(_:)` | 706–731 | 解除抑制 → row 命中 → 同 ID 短路 → 清旧 → 未抑制则设新 hover + `rowHover(true)`。 |
| `handleMouseExited()` | 733–735 | 清 hover。 |
| `clearHoverHighlight()` | 737–749 | 清视图/ID，并向协调器 `rowHover(false)`。 |
| `rowView(at:)` | 752–755 | 走侧表。 |
| `handlePlainMouseDown(row:event:)` | 765–780 | 未选中则 `selectRowIndexes`；`makeFirstResponder(table)`（修复 C11）。 |
| `consumeOneTimeHint(_:)` | 789–794 | 一次性提示键消费。 |
| `anchorProvider(for:)` | 796–801 | 弱引用 view → window 坐标闭包。 |
| `handleSingleClick(_:)` | 803–816 | 清多选 → post 选中 → `dismissPreview()` → 一次性 Toast → `ClipboardPreviewWindowRecord.open`（persistent）。 |
| `handleDoubleClick(_:)` | 818–826 | `dismissPreview()` → 一次性提示日志 → `onCopy`。 |
| `handleSpaceKey()` | 828–843 | 诊断日志 → 门禁 → 清多选 → `requestKeyboardPreview`。 |
| `handleModifierClick(row:shift:)` | 850–871 | ⌘ toggle / ⇧ 范围；同步 `selectRowIndexes`；抑制 hover。 |
| `handleReturnKey()` | 873–905 | 多选>1 → 拼接文本直写 pasteboard + `record(.historyBatchCopy)`；否则 `onCopy`。 |
| `rowView(forItemID:)` | 907–910 | ID → row → 侧表。 |
| `ClipboardNativeMenuPresenter.symbol(_:)` | 930–936 | 静态符号缓存（`NSCache(32)`）。 |
| `presentMenu(for:at:in:)` | 938–1003 | 见下方。 |
| `menuAction(_:)` | 1005–1007 | 执行 `representedObject` 闭包。 |
| `BlockMenuItemAction.run()` | 1014 | 执行闭包。 |

**`RowHostingView.mouseDown`（217–248）**
① 尾部 104pt（`hoverActionsZoneWidth`）内 → 交 `super`（让 SwiftUI 按钮接管，不抢焦点）。
② ⌘/⇧ → `onModifierClick(row, shift)` + `onPlainMouseDown`（夺键盘归属），**不触发预览/复制**。
③ `clickCount >= 2` → `onDoubleClick`；否则 `onSingleClick`（并打诊断日志）。
④ 分派**之后**才 `onPlainMouseDown`（建立选中 + 设 first responder）——注释明确：放在分派后面是为了让 popover 先呈现再落 first responder。
**坑**：`acceptsFirstMouse = true` 会抢走 first responder，这是必须显式夺回的理由；若将来把第④步提到前面，单击预览会先夺焦点再弹窗，观感为"点一下两次响应"。

**`tableView(_:viewFor:row:)`（560–599）**
按 `row.<type>` 复用标识取/建 `RowHostingView` → 设 `identifier`/`row` → 每次重建 `contentBuilder`（闭包捕获 self，**弱引用**）→ 挂 5 个回调（单击/双击/修饰键/普通按下/右键）→ `setItem(item, hovered:)` → 登记 `rowViewsByRow[row] = WeakRowBox(host)`。
**坑**：`contentBuilder` 每次 viewFor 都重新赋值（闭包捕获 `[weak self]`），这意味着行控件行为随 Coordinator 存活；`setItem` 有同 id 同 hover 短路，避免重挂 rootView（NSHostingView 最贵操作）。

**`presentMenu(for:at:in:)`（938–1003）**
`NSMenu` + 局部 `addItem` 助手（`representedObject = BlockMenuItemAction`，`isEnabled` 可控，图标走缓存）→ 复制 / 隔空投送（`airDropFileURL != nil` 才可用）/ 编辑 / 重命名 / 笔记切换 / 大文本预览 / AI 摘要（`isAvailable` 才可用）→ 标签子菜单（勾选态 + 空态）→ 分隔 → 删除（先 `notifyItemRemoved` 再 `delete`）→ `autoenablesItems = false` → `popUp(at:in:)`。
**坑**：`menu.popUp` 是**同步阻塞**调用（内部跑 modal run loop），期间 `hoverSuppression` 已抑制（正确）；但 `popUp` 返回后菜单项闭包才执行——`presentMenu` 已返回，`NSMenu` 靠 `representedObject` 保活闭包。

**`reloadTable()`（641–681）**
① 记录 reload 前首个可见行 → 锚点 ID + 顶部间隙。
② `table.reloadData()`。
③ 侧表**按行号裁剪**（保留 reloadData 期间新登记的条目）。
④ 清 `hoveredRowView` + `hoveredItemID`（必须同清）。
⑤ 非顶部浏览态 + 有锚点 → `isAnchorScrolling = true` → `scrollRowToVisible` + `scroll(_:)` + `reflect`，保持视口不跳。
⑥ `ServiceLocator.panelPreview?.setPreviewOrder(items.map(\.id))`（预览导航顺序表）。
**坑**：`isAnchorScrolling` 只包住第⑤步；`scrollRowToVisible` 会**异步**触发 bounds 变化，`clipboardBoundsDidChange` 若在 `isAnchorScrolling` 复位后到达，会把锚定滚动误判为"用户滚出首行"，导致回顶按钮闪烁。当前靠 `scroll(_:)` 同步 + `reflect` 缓解，未彻底消除。

### 3.3 `ClipboardSectionView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardSectionView.init()` | 23 | 空。 |
| `body` | 25–44 | 只渲染 `list` + `onAppear`（清抑制/reload/tagStore.refresh）+ `.alert(summaryState)`。 |
| `header` | 48–69 | **无调用方**（标签菜单/浮动窗/刷新按钮）。 |
| `list` | 73–104 | 空态或 `ClipboardTableHostView`（`isActive: pagePresenter.activePage == .home`）。 |
| `runSummary(for:)` | 108–115 | `summarize` → `summaryState.show`；异常显示错误。 |
| `SummaryState.show(title:message:)` | 125–127 | 写三字段。 |
| `SummaryState.reset()` | 128–130 | 清空。 |
| `ClipboardFilterBarView.init(...)` | 142–148 | 赋值。 |
| `ClipboardFilterBarView.body` | 150–190 | 九段胶囊 + 可选回顶按钮。 |
| `ClipboardTagFilterMenu.init(selectedTagID:)` | 201 | 绑定。 |
| `ClipboardTagFilterMenu.body` | 203–221 | 菜单：全部标签 + 各标签 toggle。 |
| `ClipboardMenuActionItem.init(...)` | 234–238 | 赋值。 |
| `ClipboardItem.airDropFileURL` (var) | 244–257 | 按类型取可投递文件路径（存在才返回）。 |
| `ClipboardRowMenuContent.init(item:newTagName:)` | 267–270 | 赋值。 |
| `ClipboardRowMenuContent.body` | 272–291 | 动作列表 + 标签子菜单（含新建标签 TextField）。 |
| `actionsView` | 293–300 | 逐项渲染。 |
| `actions` (var) | 303–333 | 8 项动作构造（与原生菜单重复实现）。 |
| `ClipboardRow.init(...)` | 357–367 | 赋值。 |
| `ClipboardRow.body` | 369–439 | 缩略图 + 徽章 + 标题/副行 + hover 按钮 + 内缩 hover 底 + 底部分隔线。 |
| `sourceAppBadge` (var) | 442–445 | `ClipboardAppIconCache.icon`。 |
| `subline` (var) | 448–452 | 时间 + 详情。 |
| `detailText` (var) | 454–475 | 按类型给"字符数 / 像素 / host / 文件名"。 |
| `imagePixelSize()` | 477–481 | 由 `imagePath` 解析。 |
| `imagePixelSize(at:)` | 483–485 | 直接路径。 |
| `imageSizeText(at:)` | 498–515 | `CGImageSource` 元数据 + `NSCache(512)`（v126 缓存、v101 改 ImageIO 不解码）。 |
| `iconButton(_:help:action:)` | 517–527 | 20×20 图标按钮。 |
| `ClipboardThumbnailView.init(item:size:corner:)` | 539–541 | 赋值。 |
| `ClipboardThumbnailView.body` | 543–568 | 图/文件图标/类型符号三选一 + 圆角底 + 描边。 |
| `image` (var) | 570–572 | `ClipboardImageStorage.image(thumbnailPath ?? imagePath)`。 |
| `fileIcon` (var) | 583–590 | `NSWorkspace.icon(forFile:)` + `NSCache(256)`。 |
| `symbolName` (var) | 592–600 | 类型符号。 |
| `ClipboardPreviewWindow.open(item:)` | 609–620 | 已有则前置；否则建窗 + 登记 + center + show。 |
| `ClipboardPreviewWindow.make(item:)` | 622–633 | 640×480 窗 + `LargeTextPreviewContainerView` + `PreviewWindowCleaner` 绑定。 |
| `PreviewWindowCleaner.bind(key:window:)` | 642–644 | 加锁登记。 |
| `PreviewWindowCleaner.windowWillClose(_:)` | 646–653 | 摘登记 → `ClipboardPreviewWindow.release`。 |
| `ClipboardPreviewWindow.release(dedupeKey:)` | 657 | 移除 controller。 |
| `Color.init?(hex:)` | 664–674 | `#RGB`/`#RRGGBB`。 |

### 3.4 `LargeTextPreviewView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `PreviewMarkdownPreferenceStore.isEnabled` (var) | 14–17 | `preview.markdown.enabled`（默认 true）。 |
| `PreviewJSONPreferenceStore.isEnabled` (var) | 27–30 | `preview.json.enabled`。 |
| `LargeTextPreviewMode.infer(from:)` | 47–59 | JSON（且开关开）→ Markdown（缓存正则命中）→ plain。 |
| `JSONHighlighter.cachedRe(_:)` | 75–81 | **带 NSLock** 的正则缓存（注释：infer/render 可能非主线程）。 |
| `prettify(_:)` | 84–91 | 解析 + prettyPrinted + sortedKeys。 |
| `isParseableJSON(_:)` | 96–99 | 只解析不回写（v126）。 |
| `render(_:enabled:)` | 101–134 | 字符串（key 紫/值绿）+ 字面量（bool/null 橙）+ 数字蓝。 |
| `MarkdownCodeSyntaxHighlighter.render(_:enabled:)` | 143–234 | 见下方。 |
| `bodyContainer` / `codeContainer` / `bulletContainer` / `quoteContainer` (var) | 244–270 | AppKit 作用域样式容器。 |
| `headingContainer(level:)` | 272–278 | 6 档字号。 |
| `inlineCodeContainer()` | 280–285 | 等宽橙。 |
| `boldContainer(base:)` | 287–292 | 同尺寸加粗。 |
| `headingLevel(of:)` | 296–306 | `#` 计数 + 必须空白或 `#` 跟随。 |
| `bulletPrefix(of:)` | 308–311 | `- / * / +` → `•`。 |
| `appendInline(_:container:to:)` | 314–349 | 缓存正则匹配 `**粗**|__粗__|\`代码\``，逐段 append。 |
| `appendRun(_:container:to:)` | 351–356 | 设属性后 append。 |
| `isTableRowLine(_:)` | 361–363 | `|` 开头且长度≥2。 |
| `isTableSeparatorLine(_:)` | 366–373 | 每格匹配 `:?-+:?`。 |
| `parseTableCells(_:)` | 375–380 | 去首尾 `|` 后 `|` 切分。 |
| `tableAttributedString(_:)` | 385–428 | `NSTextTable` + `NSTextTableBlock` 逐格段落；表头底纹。 |
| `emit(_:row:isHeader:)`（嵌套） | 401–424 | 单行单元格输出（含 `\n` 段落分隔符）。 |
| `AttributedTextView.init(_:)` | 438–440 | 存 valued。 |
| `AttributedTextView.makeNSView(context:)` | 442–456 | 建 `PreviewTextView` + `refreshGridCache` + 滚动视图。 |
| `AttributedTextView.updateNSView(_:context:)` | 458–464 | 文本不同才替换 + 重算网格。 |
| `PreviewTextView.refreshGridCache()` | 479–498 | 遍历 `.paragraphStyle` run → `boundsRect(for: block)` → 缓存矩形。 |
| `PreviewTextView.draw(_:)` | 500–511 | super 后自绘单元格边框（只画与 dirtyRect 相交的）。 |
| `PreviewTextView.layout()` | 513–520 | 宽度变化重算矩形 + `needsDisplay`。 |
| `LargeTextPreviewView.init(text:mode:)` | 530–533 | 未指定则 `infer`。 |
| `LargeTextPreviewView.body` | 535–546 | Picker + `AttributedTextView(rendered)`。 |
| `rendered` (var) | 548–559 | 三模式渲染。 |
| `LargeTextPreviewContainerView.init(item:)` | 569 | 赋值。 |
| `LargeTextPreviewContainerView.body` | 571–587 | 空 → ProgressView；`onAppear` 同步 `fullText`。 |

**`MarkdownCodeSyntaxHighlighter.render`（143–234）**
逐行状态机：``` 围栏 toggle（行本身不输出）→ 围栏内 `codeContainer` → 空行 → 标题 → **表格块**（表头 + 分隔行 + 连续数据行 → flush 已拼 `AttributedString` 到 `result` 再 append `NSTextTable`）→ 列表 → 引用 → 普通段落。末尾 flush。
**坑**：表格检测要求"当前行是表格行且**下一行**是分隔行"，因此没有分隔行的 `| a | b |` 会被当普通段落（与原版 mermaid 表检测口径不同）；`result` 与 `output` 双缓冲的 flush 时机若写错会丢内容。

### 3.5 `ClipboardPreviewWindow.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardPreviewWindowController.init(item:mode:showsHint:)` | 33–62 | 按模式建 titled/borderless 窗（720×620，min 420×320）+ identifier + `installContent` + chrome。 |
| `init?(coder:)` | 64 | `fatalError`。 |
| `initialSize(for:)` | 67–69 | 两模式同尺寸。 |
| `installContent()` | 71–98 | 建 `ClipboardPreviewWindowView` + NSHostingView；**文件态**用 `fittingSize` 收缩高度（≥min 320）。 |
| `configureHoverChrome(window:)` | 104–109 | 透明/阴影/可拖（不裁圆角）。 |
| `show(item:anchorRectInScreen:panelFrame:visibleFrame:)` | 114–129 | 换条目则重装内容 → `place` → hover `orderFront` / persistent `makeKeyAndOrderFront` + activate。 |
| `focusFront()` | 132–135 | 前置 + activate。 |
| `place(anchorRectInScreen:panelFrame:visibleFrame:)` | 138–155 | 面板左侧优先（放不下转右侧），y 对齐锚点顶；最后夹在可见区。 |
| `windowDidResignKey(_:)` | 162–174 | 0.12s 后复查；固定态跳过；hover→关；persistent 在本 app 内换 key 则保持。 |
| `windowWillClose(_:)` | 176–178 | `onWindowClosed?()`。 |
| `ClipboardPreviewWindowRecord.open(for:anchorView:)` | 196–198 | → 协调器 `presentPersistent`。 |
| `closeActive()` | 201–203 | → 协调器 `dismiss(.escape)`。 |
| `ClipboardPreviewWindowView.init(...)` | 227–234 | 建初始 model。 |
| `ClipboardPreviewWindowView.body` | 236–270 | hint 条 + header + 编辑/预览；玻璃底/实底；入场动效；`onExitCommand`；hover 保活探测。 |
| `hintBar` | 274–286 | 一次性键盘提示。 |
| `preview` | 290–294 | `PreviewPopoverContentView`（`.id(sessionID)` 强制重建）。 |
| `header` | 296–376 | 类型图标 + 标题/副行 + 预览|编辑 Picker（图/文件不显示）+ 复制 + 📌 + 关闭叉。 |
| `editor` | 380–400 | `TextEditor` + 字数 + 取消/保存（⌘S）。 |
| `copyContent()` | 404–409 | 编辑态复制草稿，否则复制全文。 |
| `save()` | 411–416 | `saveContent` → 用新文本重建 model → 退出编辑 → Toast。 |
| `makeModel(item:editedText:)` | 422–439 | 编辑后按内存文本分类（`kindOverride`）。 |
| `typeSymbol` / `displayTitle` / `subline` (var) | 441–475 | 头部文案。 |
| `HoverClipModifier.body(content:)` | 488–510 | hover 态：玻璃面 + 圆角裁剪 + 顶亮渐变描边 + 阴影；`reduceTransparency` 回退。 |
| `glassSurface` (var) | 513–522 | `ultraThinMaterial` + 0.55 tint 或纯色。 |

### 3.6 `FloatingClipboardWindow.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `FloatingClipboardPinState.originX/originY/width/height` (var) | 20–35 | 读偏好，负数/0 走中央或默认 240×290。 |
| `isVisible` / `isPinned` (var) | 38–47 | 偏好读写（pinned 默认 true）。 |
| `save(frame:)` | 49–54 | 写 4 个几何键。 |
| `clampedFrame()` | 57–67 | 屏幕内夹取（含尺寸裁剪）。 |
| `centeredOriginX/Y` (static var) | 69–76 | 居中兜底。 |
| `FloatingClipboardPanel.init(contentRect:)` | 84–101 | nonactivating + titled + resizable + fullSizeContentView；`canJoinAllSpaces`；min 200×220。 |
| `canBecomeKey` / `canBecomeMain` (var) | 104–105 | true / false。 |
| `FloatingClipboardStore.filteredItems` (var) | 120–128 | 搜索词匹配 alias/title/content。 |
| `FloatingClipboardStore.init()` | 134–138 | 订阅 `itemsDidChangeNotification`。 |
| `deinit` | 140–142 | 移除观察者。 |
| `refresh()` | 144–148 | `recentItems(12)` 回填。 |
| `setVisible(_:)` / `setPinned(_:)` | 150–158 | 同步内存态 + 持久化。 |
| `FloatingClipboardWindowController.init()` | 172–181 | 建面板 + hosting（`environmentObject(store)` + `frsetThemeChrome`）。 |
| `show()` | 185–190 | 置可见 + refresh + 恢复 frame + `orderFrontRegardless`。 |
| `hide()` | 192–195 | 置不可见 + `orderOut`。 |
| `toggle()` | 197–204 | 切换（显示时 `record(.floatingClipboardActivate)`）。 |
| `showNearMouse()` | 207–215 | 以鼠标为中心定位 + 显示。 |
| `restoreVisibilityIfNeeded()` | 218–222 | 一次性恢复。 |
| `windowDidMove(_:)` / `windowDidResize(_:)` | 226–234 | 存 frame。 |
| `windowWillClose(_:)` | 236–238 | 置不可见。 |
| `FloatingClipboardContentView.init()` | 259 | 空。 |
| `bodyTextColor` / `windowBackground` (var) | 262–272 | Midnight 覆盖。 |
| `FloatingClipboardContentView.body` | 274–325 | 搜索框 + 列表/空态 + 工具条；玻璃底；`onAppear` refresh。 |
| `searchField` | 328–349 | 搜索框。 |
| `filterBar` | 352–371 | 搜索/钉住/回顶。 |
| `barButton(_:help:active:action:)` | 373–385 | 22×22 图标按钮。 |
| `FloatingRow.body` | 397–424 | GeometryReader 记行框 + hover 预览 + 双击复制 + 单击预览。 |
| `rowContent` | 426–446 | 缩略图 28 + 标题/时间 + hover 底。 |

**`FloatingRow.body` 的双击顺序（412–423）**
先注册 `onTapGesture(count: 2)` 再注册 `count: 1`——注释明确"避免被 count:1 吞掉"。SwiftUI 的 tap 手势优先级依赖注册顺序，反过来会导致双击永远只触发单击（预览而非复制）。

### 3.7 `ClipboardPasteboardReader.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardReadResult.init(...)` | 21–34 | 赋值。 |
| `isEmpty` (var) | 37–43 | 三类型空判定。 |
| `approximateBytes` (var) | 46–53 | 估算（清理用）。 |
| `ClipboardPasteboardReader.init(pasteboard:)` | 63–65 | 注入 pasteboard。 |
| `currentChangeCount` (var) | 67 | `pasteboard.changeCount`。 |
| `read()` | 69–80 | 优先级：图 → 文件 → 富文本 → 文本 → URL。 |
| `readImage(types:source:)` | 84–108 | tiff 优先、png 兜底；ImageIO 读尺寸做 subtitle；指纹。 |
| `readFiles(types:source:)` | 112–137 | `.fileURL` / 旧 `NSFilenamesPboardType`；多文件标题"前 3 + 等 N 个"。 |
| `readRichText(types:source:)` | 141–158 | RTF 优先、HTML 兜底；必须能取到纯文本。 |
| `readText(types:source:)` | 162–171 | 纯文本（保留原始含空白，仅判空用 trimmed）。 |
| `readURL(types:source:)` | 175–183 | `.URL` + 必须有 host。 |
| `frontmostAppIdentifier()` | 187–190 | bundleId 优先，回落 localizedName。 |
| `plainText(from:)` | 192–198 | RTF → HTML → nil。 |
| `imageSize(of:)` | 201–207 | ImageIO 头信息。 |
| `fingerprint(_:)` | 215–222 | 长度 + 首 8KB + 尾 8KB（>16KB 时）→ `sha256Hex`。 |
| `imageResult(data:fileURL:sourceApp:subtitle:)` | 227–242 | 外部图片结果构造（补指纹）。 |
| `textResult(_:sourceApp:subtitle:)` | 245–254 | 外部文本结果构造。 |

**`fingerprint` 的历史（209–222 注释）**
原实现"头尾各 8KB 转十六进制字符串再哈希"（输入膨胀到 32KB）+ 手写 SHA-256 → 在轮询热路径崩溃（有 `.ips` 记录）。现直接对字节流摘要（`Data.sha256Hex` → CommonCrypto）。**这是全模块唯一有崩溃取证注释的位置**，改动此函数等于重开旧崩溃面。

### 3.8 `ClipboardRepository.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardQuery.init(...)` | 20–38 | 全字段默认值。 |
| `appendClauses(_:clauses:values:)` | 60–103 | 见下方。 |
| `fetch(_:)` | 107–125 | SELECT + WHERE + `ORDER BY timestamp DESC LIMIT/OFFSET` → `makeItem` → `attachTags`。 |
| `count(_:)` | 127–134 | COUNT(*)（同 WHERE）。 |
| `item(dedupeKey:)` | 137–144 | 单条 + attachTags。 |
| `exists(dedupeKey:)` | 146–148 | COUNT>0。 |
| `insert(_:)` | 153–170 | 24 列 INSERT；失败按"去重冲突"处理返回 false。 |
| `touch(dedupeKey:timestamp:)` | 173–176 | 更新时间戳（置顶）。 |
| `updateContent(dedupeKey:content:textPath:charCount:lineCount:storageBytes:)` | 179–197 | 回写正文 + 元数据 + `title = content.firstLineBrief`。 |
| `updateAliasTitle(dedupeKey:aliasTitle:)` | 200–207 | 空则写 NULL。 |
| `updateFields(dedupeKey:richTextPath:imagePath:thumbnailPath:storageBytes:note:)` | 210–232 | 5 个可选字段各自一条 UPDATE（**非原子**）。 |
| `delete(dedupeKey:)` | 238–257 | 先查四路径 → 事务删行+关联 → 删 4 文件 + OCR 文件。 |
| `rowsOlderThan(_:limit:)` | 262–267 | 升序取旧条目。 |
| `oldestRows(limit:)` | 270–275 | 最旧 N 条。 |
| `totalStorageBytes()` | 277–279 | `SUM(storage_bytes)`。 |
| `makeItem(_:)` | 284–313 | 行 → 模型（char/line count 为 0 时置 nil）。 |
| `bindings(_:)` | 315–344 | 模型 → 24 个 `SQLiteValue`。 |
| `optionalInt(_:)` / `optionalText(_:)`（嵌套） | 316–317 | nil → `.null`。 |
| `escapeLike(_:)` | 348–360 | `\ % _` 转义（v126 改 Array+join）。 |

**`appendClauses`（60–103）**
依次拼：`type = ?`、`is_note = 1`、`is_generated_by_tool = 1`、`source_tool_keyword = ?`、`codeLikeOnly` 的 9 个 LIKE、`tagID` 子查询、`search` 三列 LIKE + **OCR 命中的 `dedupe_key IN (...)`**。
**坑**：`codeLikeOnly` 的 LIKE 条件全用 `%...%`，无索引可用（全表扫）；`search` 里 `ClipboardOCRTextStorage.matchingDedupeKeys` 会触发 OCR 索引加载（首次全盘扫描 2000 份文件）——**在 SQL 构建阶段同步执行**，即 UI 键盘输入路径。

### 3.9 `ClipboardFileStorages.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardFileStore.url(forRelativePath:)` | 14–16 | `base` 拼接。 |
| `write(_:toRelativePath:)` | 20–31 | 建父目录 + 原子写。 |
| `read(_:)` | 33–35 | `Data(contentsOf:)`。 |
| `remove(_:)` | 37–40 | 忽略错误。 |
| `fileSize(_:)` | 42–46 | 属性大小。 |
| `directorySize(_:)` | 49–60 | 枚举子目录累加（`skipsHiddenFiles`）。 |
| `ClipboardTextStorage.write(_:id:)` | 69–74 | `texts/<uuid>.txt`，返回相对路径+字节。 |
| `ClipboardTextStorage.read(_:)` | 76–79 | UTF-8 解码。 |
| `ClipboardTextStorage.remove(_:)` | 81 | 转 `ClipboardFileStore.remove`。 |
| `ClipboardRichTextStorage.write(_:id:)` | 89–93 | `rich_texts/<uuid>.rtf`。 |
| `ClipboardRichTextStorage.read(_:)` | 95–98 | `NSAttributedString(rtf:)`。 |
| `ClipboardRichTextStorage.remove(_:)` | 100 | 同上。 |
| `ClipboardOCRTextStorage.relativePath(dedupeKey:)` | 110–113 | `ocr/<key 的 / 换成 _>.txt`。 |
| `ClipboardOCRTextStorage.keyName(forRelativePath:)` | 116–118 | 去扩展名的主文件名。 |
| `ClipboardOCRTextStorage.write(_:dedupeKey:)` | 120–128 | 落盘 + **增量更新索引**（加锁）。 |
| `ClipboardOCRTextStorage.read(dedupeKey:)` | 130–133 | 走 `ClipboardTextStorage.read`。 |
| `ClipboardOCRTextStorage.remove(dedupeKey:)` | 135–142 | 删文件 + 失效索引。 |
| `ClipboardOCRTextStorage.loadIndex(maxFiles:)` | 153–173 | 惰性建索引（首次全盘 ≤2000 份）。 |
| `matchingDedupeKeys(query:maxFiles:)` | 179–189 | ≥2 字符才检索；命中集合。 |
| `ClipboardImageStorage.store(imageData:id:)` | 209–227 | 原图落盘 + **一次** ImageIO 解析同时出缩略图与像素尺寸。 |
| `makeThumbnail(from:toRelativePath:)` | 231–234 | Data 版包装。 |
| `makeThumbnail(from source:toRelativePath:)` | 238–252 | 200px 缩略图 → PNG。 |
| `image(relativePath:)` | 265–273 | `NSCache(80, 16MB)` + 读盘解码。 |
| `fileExtension(for:)` | 277–284 | 魔数判 png/jpg/gif/webp，否则 tiff。 |
| `pixelSize(of:)` | 287–292 | 从已建 source 读尺寸。 |
| `ClipboardStorageUsageProvider.databaseBytes` (var) | 301 | SQL SUM。 |
| `diskBytes` (var) | 304–310 | 5 个目录遍历。 |
| `totalBytes` (var) | 313 | `max(db, disk)`。 |
| `exceeds(_:)` | 320–323 | 短路版 `totalBytes > target`。 |

**`loadIndex` 的锁与重入（153–173）**
`indexLock.lock(); defer { unlock }` 包住**整个建索引过程**（含最多 2000 次读盘）。若索引未建时两个线程同时搜索，第二个会阻塞在锁上等第一次全盘扫描完成——**这是可感知的卡顿**（`searchText.didSet` 在主线程触发 `reload` → `fetch` 在 queue 上 → 这里阻塞 queue，不阻塞主线程；但 UI 的列表刷新会等 queue）。

### 3.10 `ClipboardItemEditWindowController.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardItemEditSession.init(...)` | 18–23 | 赋值。 |
| `setContent(_:)` / `setAliasTitle(_:)` | 25–26 | `queue.async` 写（不阻塞输入）。 |
| `snapshot()` | 29–34 | `queue.sync` 取三元组（含 isDirty）。 |
| `markSaved(aliasTitle:)` | 37–39 | 以当前内容为新基线。 |
| `ClipboardItemEditTextView.configure()` | 62–73 | 关富文本/链接/智能替换；开 undo。 |
| `ClipboardItemEditWindowController.init(item:)` | 98–116 | 读全文（**同步**）→ 建 session → 560×420 窗 → `buildLayout`。 |
| `buildLayout(initialContent:)` | 120–176 | 手写 frame 布局（标签/输入框/文本视图/统计/取消/保存），`autoresizingMask` 只护宽。 |
| `statText(_:)` | 178–185 | 类型 · 字符 · 行 · 来源。 |
| `show()` | 189–194 | center + activate + showWindow + makeKey。 |
| `aliasDidChange(_:)` | 198–200 | 写 session。 |
| `saveTapped(_:)` | 202–217 | 见下方。 |
| `cancelTapped(_:)` | 219–222 | 回调 + close。 |
| `textDidChange(_:)` | 227–229 | 写 session。 |
| `windowWillClose(_:)` | 233–236 | 清 delegate + 摘登记。 |
| `ClipboardItemEditWindowRecord.open(for:delegate:)` | 251–264 | 已有则前置；否则建 + 登记（**持锁期间建窗**）。 |
| `remove(dedupeKey:)` | 266–269 | 摘登记。 |

**`saveTapped`（202–217）**
`session.snapshot()` 取 alias（**注意：content 取的是 `textView.string` 而非 snapshot.content**）→ `saveContent`（异步写库）→ `rename`（异步写库）→ `markSaved` → 更新内存 item → delegate 回调 → close。
**坑**：两次写库**无事务**且都是 `queue.async`（异步），close 后若 app 退出，可能只写了 content 没写 alias；`snapshot().content` 与 `textView.string` 的差别在于 session 的写是 `async`（可能滞后于最新一次 `textDidChange`）——这里刻意用 `textView.string` 取最新值，但 `isDirty` 判断仍基于 session（可能误判）。

### 3.11 `ClipboardPruneSchedulers.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `retentionDays` (var) | 31–33 | 偏好，最小 0（0=不清理）。 |
| `ClipboardHistoryRetentionPruneScheduler.start()` | 35–43 | 3600s Timer + 立即 `prune()`。 |
| `stop()` | 45–48 | 停 Timer。 |
| `prune()` | 52–73 | 见下方。 |
| `ClipboardStoragePruneScheduler.limitBytes` (var) | 96–99 | MB → 字节。 |
| `start()` | 101–109 | 600s Timer + 立即 `prune()`。 |
| `stop()` | 111–114 | 停 Timer。 |
| `prune()` | 118–144 | 见下方。 |

**两个 `prune()` 的坑**
① 都在**主线程**（`Timer.scheduledTimer` + `.common` runloop）执行批量删除——每批 200 条，每条 `repository.delete` 里有事务 + 4 次文件删除 + OCR 删除。删 1000 条就是 5 批 × 200 次同步磁盘操作，**主线程会明显卡住**。
② `retention.prune` 的循环 `while true { batch = rowsOlderThan; if empty break; ... if count<200 break }`，若 `delete` 失败（返回 false 但行仍在），下一批仍会取到同样的行 → **理论死循环**（当前 `delete` 失败只在异常时，且会 `Log.error` 后返回 false，行未删 → 死循环可复现的前提是持续性数据库错误）。
③ `storage.prune` 注释说"先删文件再删行"，但实际代码是 `repository.delete`（内部先删行再删文件）——**注释与实现相反**。

### 3.12 `TagStore.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `refresh()` | 23–46 | 两次查询（tags + 关联表）→ 加锁换 mapping → 主线程换 tags。 |
| `attachTags(to:)` | 49–60 | 持锁就地查表（v126 去整表拷贝）。 |
| `tags(for:)` | 62–67 | 某条目的 Tag 对象列表。 |
| `create(name:colorHex:)` | 72–88 | 插入成功 refresh 返回；冲突回查同名。 |
| `rename(id:name:)` | 90–98 | UPDATE + refresh。 |
| `delete(id:)` | 101–105 | DELETE（关联行 CASCADE）。 |
| `assign(tagID:toDedupeKey:)` | 109–125 | `INSERT OR IGNORE` + **增量**更新 mapping。 |
| `unassign(tagID:fromDedupeKey:)` | 127–140 | DELETE + 增量摘除。 |
| `toggle(tagID:dedupeKey:)` | 143–149 | 查 mapping 决定 assign/unassign。 |

### 3.13 `ClipboardModule.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ClipboardModule.start()` | 10–35 | 双击 ⌘ 监听 → `ClipboardManager.start()` → **再** start 两个 Prune 调度器 → 恢复浮动窗 → 注册区段/设置页 → `ModuleRegistry.register`。 |
| `DoubleTapCommandMonitor.start()` | 48–71 | `installed` 单次；`flagsChanged` 全局 + 本地；只认按下沿；0.4s 内两次 → `showNearMouse()`。 |

**`DoubleTapCommandMonitor` 的监听器泄漏**
`NSEvent.addGlobalMonitorForEvents` 返回 `Any?`（要 `removeMonitor` 才能卸），`addLocalMonitorForEvents` 同样；两处返回值都被丢弃 → 监听器永生。`installed` 保证只装一次，所以实际泄漏量固定 2 个，不影响正确性，但**无法在运行时关闭该功能**。

### 3.14 `ClipboardAppIconCache.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `icon(forAppName:)` | 32–63 | 正缓存 → 负缓存 → bundleId 直查 → 运行中 app 按名/ID → 5 目录探测 → 写正/负缓存。 |

### 3.15 `ClipboardSummaryExecutionCoordinator.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `isAvailable` (var) | 32 | `ServiceLocator.llmService != nil`。 |
| `isRunning(dedupeKey:)` | 34–37 | 加锁查询。 |
| `beginRun(dedupeKey:)` | 41–46 | 加锁插入（已存在返回 false）。 |
| `endRun(dedupeKey:)` | 48–51 | 加锁移除。 |
| `summarize(_:systemPrompt:)` | 54–68 | 服务检查 → 全文（**同步读盘**）→ 空检查 → `beginRun` → 8000 字符截断 → `service.complete` → `defer endRun`。 |
| `summarizeAndWriteBack(_:)` | 72–77 | `summarize` → `ingestToolOutput`（写回历史）。 |

### 3.16 `ClipboardSettingsPane.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `body` | 27–128 | 三组：历史（保留天数/容量上限/占用/立即清理）、捕获（轮询说明 + 自动粘贴 + 去授权）、浮动窗（显示开关 + 重置位置）。 |
| `sliderRow(...)` | 133–155 | 标题+数值+通栏滑块（拖动提交）。 |
| `bytesText(_:)` | 157–161 | MB/KB 文本。 |

**「立即清理」（57–71）**
依次调两个 `prune()`（**同步、主线程**）→ 求和 → 刷新 `usageBytes` → 有删除则 Toast「已清理 N 条，回收 X」，否则 Toast「没有超过…的条目」（v115 修"删 0 条时零提示"）。

---

## 4. 关键数据流

### 4.1 捕获 → 入库 → 列表（主链）

```
NSPasteboard 变化
  → Timer(0.5s 突发 / 2.0s 闲置) pollTick
      → poll(): changeCount 双读比对 → 暂停/自写回声抑制 → ingest()
          ├─ ClipboardPasteboardReader.read()   [主线程，AppKit 要求]
          │     图 > 文件 > 富文本 > 文本 > URL；指纹 = 长度+首8K+尾8K → SHA256
          ├─ 忽略应用名单（Preferences.clipboardIgnoredApps）
          └─ persist → queue(com.frsetnext.clipboard.persist)
                └─ writeToDatabase()
                      ├─ makeDedupeKey → repository.exists → touch（置顶）
                      ├─ 落盘：images/ thumbnails/ texts/ rich_texts/
                      ├─ repository.insert → bumpStat("capture_count")
                      │     ├─ image → scheduleOCR（ServiceLocator.ocrService → ocr/<key>.txt）
                      │     └─ file  → scheduleAutoStage → post filesCapturedNotification
                      └─ scheduleReloadCoalesced → main: reload(reset:true)
                            └─ repository.fetch → attachTags(TagStore)
                                  → items（≤800）→ post itemsDidChangeNotification
                                        ├─ CloudLinkPromptController（状态栏网盘提示）
                                        ├─ CloudLinkBar（首页链接条）
                                        └─ FloatingClipboardStore（悬浮窗最近 12 条）
```

### 4.2 行交互 → 预览 / 复制（跨模块边界最多的一条）

```
用户在 NSTableView 行上操作
  → RowHostingView.mouseDown（不透传 super）
      ├─ 尾部 104pt → super（SwiftUI 按钮）
      ├─ ⌘/⇧ → Coordinator.handleModifierClick（多选，不预览/不复制）
      ├─ clickCount>=2 → handleDoubleClick → onCopy → ClipboardManager.copy
      │       → 写 pasteboard + selfwrite-token + lastChangeCount 同步
      │       → 可选 pasteToFrontmostApplication（CGEvent Cmd+V）
      └─ clickCount==1 → handleSingleClick
              → ServiceLocator.panelPreview.dismissPreview()
              → ClipboardPreviewWindowRecord.open → 协调器 presentPersistent
                    → ClipboardPreviewWindowController(mode:.persistent)
                          → identifier "frset.clipboardPreview"
                                （PanelController.windowDidResignKey 据此保持主面板）

hover:
  ClipboardTableView.mouseMoved（isActive 才上报）
    → Coordinator.handleMouseMoved → panelPreview.rowHover(true, isFloatingSource:false)
          → Panel 模块协调器（跨模块：Clipboard → Panel 协议）
```

### 4.3 键盘路径（空格/↩）

```
点击行 → handlePlainMouseDown
  ├─ table.selectRowIndexes(row)
  └─ window.makeFirstResponder(table)          ← 缺这两步，空格/↩ 永久无效（修复 C11）
        → ClipboardTableView.keyDown
            ├─ " "  → onSpaceKey → handleSpaceKey → requestKeyboardPreview（0.30s 延时）
            └─ "\r" → onReturnKey → handleReturnKey
                        ├─ 多选>1 → 拼接文本直写 pasteboard + record(.historyBatchCopy)
                        └─ 单选   → onCopy
```

### 4.4 清理链

```
ClipboardHistoryRetentionPruneScheduler（1h）/ ClipboardStoragePruneScheduler（10min）
  → prune()（主线程）
      ├─ rowsOlderThan / oldestRows（200/批）
      ├─ repository.delete → 事务删行+关联 + 删 4 文件 + 删 OCR 文件
      └─ ClipboardManager.shared.reload()
```

---

## 5. 资源清单

### 定时器

| 位置 | 间隔 | 门控 |
|---|---|---|
| `ClipboardManager.schedulePoll` | 0.5s（突发窗口 2s 内）/ 2.0s | `burstUntil` |
| `ClipboardManager.scheduleRetry` | `max(0.5, currentInterval)`，一次性 | 仅 changeCount 撕裂时 |
| `ClipboardHistoryRetentionPruneScheduler` | 3600s | `retentionDays > 0` |
| `ClipboardStoragePruneScheduler` | 600s | `limitBytes > 0` |
| `ClipboardPreviewWindow` 失焦复查 | 0.12s 一次性 | 每次 resignKey |
| `DoubleTapCommandMonitor` | 无定时器，0.4s 判定窗口 | — |

### 线程 / 队列

| 资源 | 用途 |
|---|---|
| 主线程 | `NSPasteboard` 读取、`@Published` 发布、全部 Timer 回调（含两个 prune 的批量删除）、`snapshot()` 的 `queue.sync` |
| `com.frsetnext.clipboard.persist`（串行 `.utility`） | 全部 SQLite/文件 IO（`writeToDatabase`/`reload`/`loadMore`/`saveContent`/`delete`/`rename`/`setNote`/`recentItems`） |
| `com.frsetnext.clipboard.edit.session`（串行） | 编辑会话三字段 |
| `Task.detached(.utility)` | OCR 识别 |
| 未指定队列 | `ingestToolOutput`（**直接在当前线程访问 repository**——违反线程约定） |
| 未指定队列 | `ClipboardSummaryExecutionCoordinator.summarize`（async 上下文，`fullText` 同步读盘） |

### 子进程 / 系统 API

本目录**无子进程**。系统 API：`NSPasteboard`、`CGImageSource`/`CGImageDestination`、`NSWorkspace`、`AXIsProcessTrusted` + `CGEvent.post(cghidEventTap)`、`NSEvent` 全局/本地 monitor、`NSAttributedString(rtf:)`。

### 文件路径（相对 `AppDirectories.base`）

| 相对路径 | 内容 | 清理时机 |
|---|---|---|
| `images/<uuid>.<ext>` | 原图 | `repository.delete` |
| `thumbnails/<uuid>.png` | 200px 缩略图 | 同上 |
| `texts/<uuid>.txt` | 超 64KB 正文 | 同上 / `saveContent` 重写时删旧 |
| `rich_texts/<uuid>.rtf` | 富文本 | 同上 |
| `ocr/<dedupeKey 中 / 换 _>.txt` | OCR 文本 | 同上 |

### UserDefaults / Preferences 键

| 键 | 说明 |
|---|---|
| `clipboardAutoPaste`（`clipboard.autoPaste`） | 复制后自动粘贴（默认 false） |
| `floatingVisible`（`floatingClipboard.visible`） | 浮动窗可见（默认 false） |
| `floatingPinned`（`floatingClipboard.pinned`） | 钉住（默认 **true**） |
| `floatingOriginX/Y`、`floatingWidth`、`floatingHeight` | 浮动窗几何 |
| `clipboardRetentionDays` | 保留天数（默认 30） |
| `clipboardStorageLimitMB` | 容量上限（默认 2048） |
| `clipboardIgnoredApps` | 忽略应用（bundleId 数组） |
| `automaticScreenshotOCREnabled` | 抓图后自动 OCR（默认 true，裸键） |
| `preview.markdown.enabled` / `preview.json.enabled` | 大文本渲染开关 |
| `hasSeenClipboardSingleClickPreviewHint` / `hasSeenClipboardDoubleClickCopyHint` | 一次性提示（自拟键名） |

### 通知名

| 名称 | 方向 |
|---|---|
| `FrsetNext.Clipboard.itemsDidChange`（`itemsDidChangeNotification`） | 发（`reload`/`delete`）→ 收（`FloatingClipboardStore`、`CloudLinkPromptController`） |
| `FrsetNext.Clipboard.filesCaptured`（`filesCapturedNotification`） | 发（文件条目入库后，userInfo["urls"]）→ AppBootstrap 接 `LocalTransferStore` |
| `FrsetNext.Clipboard.mainClipboardFirstItemScrolledOutChanged` | 发（顶部迟滞变化） |
| `ClipboardManager.recordingPausedDidChange` | 发（暂停态变化） |
| `frset.clipboardSelectionChanged` | 发（选中项，object=ClipboardItem?）→ `PanelRootView` 收 |
| `frset.clipboardScrollTop` | 收（`Coordinator.bind` → `proxy.scrollToTop`）；发（面板底部工具条） |
| `.frsetAirDropFiles` | 发（隔空投送，userInfo["urls"]） |

### 观测器 / 事件监听

| 位置 | 类型 | 是否可卸 |
|---|---|---|
| `ClipboardManager` | 2 个 `Timer` | `stop()` |
| `FloatingClipboardStore` | `itemsDidChangeNotification` observer | `deinit` |
| `Coordinator.bind` | `.frsetClipboardScrollTop`（闭包式，**未保存 token**） | **不可卸** |
| `Coordinator.makeNSView` | `NSView.boundsDidChangeNotification`（selector 式，coordinator 为 observer） | 未移除（依赖 observer 释放） |
| `DoubleTapCommandMonitor` | 全局 + 本地 `flagsChanged` | **不可卸** |
| `PreviewWindowCleaner` | `NSWindowDelegate`（按窗） | 随窗 |

---

## 6. 不变量与陷阱

1. **`NSTrackingArea` 必须在非激活页移除**（`ClipboardTableView.isActive`）：SwiftUI 的 `allowsHitTesting(false)` 管不到 AppKit 层，否则透明页会弹"幽灵预览"。
2. **行选中态必须由 `ClipboardRowChromeView.drawSelection` 接管**：否则系统整行铺 `controlAccentColor`（用户原话"蓝色框会直接填满"）。
3. **行视图 `mouseDown` 必须自己 `selectRowIndexes` + `makeFirstResponder(table)`**：因为不透传 super 且 `acceptsFirstMouse = true`，两件事缺一，空格/↩ 永久失效。
4. **列宽只能钉到剪辑视图宽**：钉 `table.bounds.width` 会触发自增循环（实测 22686）。
5. **`rowViewsByRow` 只能裁剪不能整体清空**；`hoveredItemID` 与 `hoveredRowView` 必须同清。
6. **`isKeyboardNavigating` 必须在 `super.keyDown` 返回后复位**，否则泄漏到下一次鼠标点击 → 误取消键盘预览。
7. **`RowHostingView.sizingOptions = []`**：否则每行宽度自适内容 → 卡片宽窄不一（v100）。
8. **`poll()` 的 changeCount 双读比对不能删**：读取期间粘贴板变化会采到撕裂内容。
9. **自写回声抑制必须同时做三件事**：打 token、记 TTL、同步 `lastChangeCount`。少一件 → 复制即重复入库 or 外部内容被误吞。
10. **阈值 64KB 双写口径**：`content` 只留 4000 字符预览，全文在 `textPath`；`storage_bytes` 不得用 `approximateBytes` 起步再叠加（双计）。
11. **`maxResidentItems = 800`**：`makeQuery` 与两处 fetch 都要截断；否则深翻页会无限涨内存。
12. **`reloadTableIfNeeded` 的 items 签名必须覆盖 `id`**（不是 dedupeKey 或 index）：条目置顶/删除都靠它触发全表 reload。
13. **`ClipboardPreviewWindowController.identifier` 必须是 `frset.clipboardPreview`**：`PanelController` 的白名单靠它。
14. **hover 模式不能用 `layer.masksToBounds` 裁圆角**：会破坏系统阴影形状采样（v71 实障）。
15. **`windowDidResignKey` 必须延迟 0.12s 复查**：否则点击预览窗内部控件会先失焦再判定。
16. **`DoubleTapCommandMonitor` 只认按下沿 + 0.4s 窗口**：改成长按会误触；去掉 `!wasDown` 会一次按放算两次。
17. **`ClipboardItemEditWindowRecord.open` 的唯一性靠 dedupeKey**：改名不影响；但编辑窗保存后 `item.dedupeKey` 不变，符合预期。
18. **OCR 索引的 `dedupe_key` 中 `/` 必须统一替换为 `_`**（write/read/remove/loadIndex 四处同口径），否则检索命中但写/删错文件。
19. **`JSONHighlighter.cachedRe` 的锁不能去掉**：`infer`/`render` 可能在非主线程（注释明确）。
20. **Markdown 样式必须用 `c.appKit.*` 作用域**（v127）：用 `c.font = SwiftUI.Font` 时桥接后字体停留在自定义键，NSTextView 读回 nil → 全部样式静默丢失。

---

## 7. 重复实现 / 死代码 / 风险

### 重复实现

| 项 | 位置 | 说明 |
|---|---|---|
| 右键菜单 | `ClipboardNativeMenuPresenter.presentMenu`（NSMenu，1000 行文件尾部）vs `ClipboardRowMenuContent.actions`（SwiftUI，675 行文件中部） | 8 个菜单项两份实现，字段与文案需手工同步（v112 空投联动两处都改过） |
| 缩略图 | `ClipboardThumbnailView`（28/50pt 行缩略图，`ClipboardImageStorage.image`）vs `PreviewFileThumb`（Panel 模块，三级解码） | 两套缓存策略（`NSCache(80,16MB)` vs `NSCache(60)`） |
| 文本渲染 | `MarkdownCodeSyntaxHighlighter`（大文本窗）vs `PreviewMarkdownRenderer`（Panel 预览） | **两套完整的 Markdown 渲染器**，表格一边用 NSTextTable 一边用等宽字符拼 |
| JSON 渲染 | `JSONHighlighter`（大文本窗）vs `JSONInspectorView`（Panel 预览树/表） | 同一份 JSON 两种呈现 |
| 正则缓存 | `JSONHighlighter.cachedRe`（带锁）vs `PreviewMarkdownRenderer._reCache`（**无锁**，Panel 模块） | 同职责两种线程安全等级 |
| 图标缓存 | `ClipboardAppIconCache`（正+负缓存）vs `StatsAppIcon`（Monitor） | 前者按名字探测 5 目录，后者按路径 |
| 预览窗 | `ClipboardPreviewWindow`（大文本，enum 命名空间，640×480）vs `ClipboardPreviewWindowController`（统一预览，720×620） | 两个"预览窗"，前者是历史遗留入口（右键「大文本预览」） |
| 顶部回顶 | `ClipboardFilterBarView` 的回顶按钮（`FilterBar_ScrollToTop`，无调用方）vs 面板底部工具条「回到顶部」（经通知） | 两套入口 |

### 死代码 / 未接线

| 符号 | 状态 |
|---|---|
| `ClipboardSectionView.header` | 定义完整（标签菜单/浮动窗/刷新）但 `body` 不用 |
| `ClipboardFilterBarView`（整类） | 无调用方（过滤改由底部工具条 Menu 驱动） |
| `ClipboardTableHostView.rowGap` 注释 | 注释写 "6pt/10pt"，实际值 `3`（v156 改过但注释未全改） |
| `Coordinator.handleModifierClick` 里的 `let anchor = ...; _ = anchor` | 计算后丢弃（多选锚点未使用） |
| `ClipboardItemEditSession` 的 `isDirty` | `snapshot()` 返回但 `saveTapped` 不用 |
| `ClipboardSummaryExecutionCoordinator.isRunning` | 无调用方（只有内部 `beginRun` 用） |
| `ClipboardHistoryRetentionPruneScheduler.prune` 返回值 | 仅设置页用；启动路径丢弃 |
| `ClipboardAppIconCache` 的 `probeDirectories` 中 `NSHomeDirectory()/Applications` | 沙箱下通常不可见 |
| `DoubleTapCommandMonitor` 的两处 monitor token | 未保存，无法移除 |
| `ClipboardPreviewWindow` 与 `ClipboardPreviewWindowController` 命名冲突 | 前者是 enum 命名空间（旧入口），后者是类 |

### 风险

| # | 风险 | 位置 | 影响 |
|---|---|---|---|
| C1 | **`ingestToolOutput` 不走 `queue`**，直接在当前线程 `repository.exists/touch/insert` | ClipboardManager 630–664 | 与"所有 IO 在 queue"约定冲突；并发捕获时可能与 `writeToDatabase` 交错写同一 dedupeKey |
| C2 | **两个 `prune()` 在主线程做批量删除**（每批 200 条 × 事务 + 4 次文件删） | ClipboardPruneSchedulers 52/118 | 清理上千条时主线程明显卡顿；UI 完全冻结 |
| C3 | `retention.prune` 的 `while true` 若 `delete` 持续失败会**死循环** | 58–67 | 数据库异常时主线程永久卡死 |
| C4 | `storage.prune` 注释"先删文件再删行"与实现相反 | 131 vs 133 | 误导后续维护者；实际是"先删行再删文件" |
| C5 | `ClipboardItemEditWindowRecord.open` **持锁建窗**（`ClipboardItemEditWindowController.init` 内同步读全文 + 建 NSWindow） | 251–263 | 锁持有时间包含 UI 构建；并发打开不同条目会互相阻塞 |
| C6 | 编辑保存 `saveContent` + `rename` 两次异步写、无事务 | 202–217 | App 退出/崩溃时可能只落一半 |
| C7 | `snapshot()` 用 `queue.sync` 且 UI 线程调用 | 29–34 | 若 session 队列上有长任务（不太可能）会卡 UI |
| C8 | `OCRTextStorage.loadIndex` 在锁内全盘扫描 ≤2000 文件 | 153–173 | 首次搜索（≥2 字符）会阻塞 `persist` 队列数秒；`searchText` 每次改动都触发 |
| C9 | `appendClauses` 的 `codeLikeOnly` 9 个 `%LIKE%` + OCR 子查询 | 71–102 | 无索引可用；搜索路径全表扫 |
| C10 | `repository.updateFields` 5 条独立 UPDATE | 210–232 | 非原子；中途失败会留下半更新状态 |
| C11 | `Coordinator.bind` 的 `.frsetClipboardScrollTop` observer 用闭包式且**不保存 token** | 539–541 | 无法移除；View 重建会叠加 observer（每次 `makeNSView` 一次） |
| C12 | `DoubleTapCommandMonitor` 的 monitor token 丢弃 | ClipboardModule 66–70 | 无法关闭该功能；每次 App 启动固定 2 个常驻全局监听 |
| C13 | `handleSpaceKey`/`mouseDown`/`keyDown` 内保留 info 级诊断日志 | 237/351/834 | 每次点击/按键都格式化字符串 + 落盘；注释自称"临时"但已在生产路径 |
| C14 | `saveContent` 里 `storageBytes = 新内容 + auxiliary`，但 `auxiliary` 读的是**旧** item 的三路径 | 594–605 | 若原 textPath 已删、图片路径变化，`storage_bytes` 会漂移 |
| C15 | `ClipboardPreviewWindow.controllers` 静态字典 | ClipboardSectionView 607 | 键=dedupeKey，`release` 依赖 `windowWillClose`；若窗口被强引用（如 `isReleasedWhenClosed=false` 且 delegate 未触发）则永不释放 |
| C16 | `imageSizeText` 缓存键是**绝对路径**，条目删除后缓存不失效 | ClipboardSectionView 492–515 | `NSCache(512)` 会保留已删文件的尺寸文本（无害但污染） |
| C17 | 设置页「立即清理」同步调两个 `prune()` | ClipboardSettingsPane 59–60 | 与 C2 同源：点击后 UI 冻结，无进度提示 |
| C18 | `ClipboardRow` 的 `subline`/`detailText` 每次 body 求值重算（含 URL 解析） | ClipboardSectionView 448–475 | 滚动热路径的字符串分配；已有缓存覆盖的只有图片尺寸 |
