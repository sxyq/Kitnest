# 14 - 规格：剪贴板列表交互族 + 捕获时序（逆向待查 #1）

> 2026-10-15。作者：re-clipboard（汇编探索代理）。上游：specs/11 §2 任务书、specs/05（本篇深化其 4.3 节并回答其待查 #1）。
> 方法：`otool -oV` ObjC 元数据（类/方法表/ivar 表，含 IMP 地址）+ disasm.txt 函数窗读 + 反射字符串考古（__swift5_reflstr / __cstring）+ `__objc_stubs` 二进制解析（otool -tvV 不含 __objc_stubs，选择器调用必须经 stub 映射才能找到调用者——本轮自建 `/tmp/re14/stubs.py`，1188 条 stub 全解）。
> 工件：`/tmp/frset-re/`（disasm.txt / strings-all.txt / Frset.arm64 / defaults）。工具脚本沉淀：`/tmp/re14/strat.py`（按虚拟地址读 C 串）、`/tmp/re14/stubs.py`（stub→selref 映射）、`/tmp/re14/xref.py`（串→指针引用）。

---

## 0. 结论速览（六问答案）

| # | 问题 | 结论 |
|---|---|---|
| ① | 捕获时序 | **纯自适应轮询，无事件驱动捕获**。Timer 双速率：闲置 **1.0s**，捕获后突发 **0.5s × 2.0s 窗口**；失败重试一次性定时器 ≥0.5s；自写回声用标记类型 `com.frset.selfwrite-token` 抑制。CGEventTap 仅有一个且为键盘 tap（ShortcutRuntimeCoordinator 双击/快捷键用），**与捕获无关** |
| ② | 右键判定 | `ClipboardRowContextMenuActivationTrackerNSView.rightMouseDown:` —— **右键按下即触发**（非抬起），调用 `onRightMouseDown` 闭包并吞掉事件不透传 super |
| ③ | hover 抑制 | 控制器持有 `isSuppressedUntilMouseMove + hoveredRowItemID + hoveredIconItemID`；对外 API `onSuppressHoverUntilMouseMove` / `isHoverSuppressed` / `onRowHoverChanged`；抑制后鼠标再次移动即恢复高亮 |
| ④ | 顶部滚动 | `ClipboardListTopScrollTracker`（band/isOut/lastMinY）以**迟滞双阈值**（`firstItemScrollOutEnterThreshold`/`firstItemScrollOutExitThreshold`）监测首条目是否滚出，发布 `mainClipboardFirstItemScrolledOutChanged`；过滤栏出现 `FilterBar_ScrollToTop`（arrow.up.to.line）按钮，经 `scrollToTopNotification`/`__scrollToTopRequestSequence` 回滚到顶 |
| ⑤ | 双击激活 | 双击**可配置修饰键**（`DoubleTapModifier`）触发 `ShortcutAction`（默认打开悬浮剪贴板，"在鼠标附近打开"/"支持双击快捷键唤起" `0x100b57910`）；`AppKitDoubleTapMonitor`（4 个 NSEvent 监视器）+ ShortcutRuntimeCoordinator 的 CGEventTap（session tap / listen-only / 掩码 0x1c00=keyDown+keyUp+flagsChanged）双通道；默认间隔常量 **1000**（ms）；`hasSeenDoubleTapShortcutTip_v1` 一次性提示（读取+写入 @`0x100654288`/`0x1006542fc`，withAnimation(easeOut) 动画呈现，位于快捷键设置区）。**另注意主面板行交互：单击/空格=预览，双击/↩=复制**（§3.7） |
| ⑥ | 过滤栏 | `ClipboardFilterType` 9 项：**all, text, image, link, file, code, color, generated, note**（反射串序即此序）；另有搜索框（`FilterBar_Search`，square.and.pencil）与回顶按钮（`FilterBar_ScrollToTop`，arrow.up.to.line）；漏斗图标 `line.3.horizontal.decrease.circle`；标签菜单 `__clipboard_tag_filter_all_tagged__` 哨兵 |

---

## 1. 功能点表

| # | 功能点 | 实证等级 |
|---|---|---|
| F1 | 捕获=自适应轮询（1.0s 闲置 / 0.5s 突发 / 2.0s 突发窗口） | ★★★（常量级汇编证据） |
| F2 | 捕获重试：一次性 Timer，间隔 max(0.5, 计算)，.common 模式 | ★★★ |
| F3 | 自写回声抑制：changeCount 双读比对 + lastSelfWriteToken/TTL + 粘贴板标记类型 `com.frset.selfwrite-token` | ★★★（机制）/ ⬜ TTL 数值 |
| F4 | 行右键菜单：右键**按下**即激活 tracker 闭包；普通按下可被 `interceptPlainMouseDown` 拦截为选中 | ★★★ |
| F5 | 行 hover：`onRowHoverChanged` + 图标/行双通道 `hoveredRowItemID`/`hoveredIconItemID` | ★★★ |
| F6 | hover 抑制：滚出/交互后抑制至下次鼠标移动 | ★★（字段+API 实证，触发场景清单 ⬜） |
| F7 | 顶部滚动跟踪：band+isOut+lastMinY 迟滞状态机，双阈值常量名实证 | ★★★（结构）/ ⬜ 阈值数值 |
| F8 | 回顶：FilterBar 回顶按钮 + `scrollToTopNotification` + `onRequestScrollToListTop` | ★★★ |
| F9 | 悬浮剪贴板行 hover tracker：单击预览、双击粘贴（历史更新日志实证 + 类方法实证） | ★★★ |
| F10 | 双击修饰键激活：DoubleTap 族类型 + 1000ms 默认 + 一次性 tip 键 | ★★（默认 action ⬜ 推断） |
| F11 | 过滤栏 9 类型项 + 搜索 + 回顶 + 标签菜单 | ★★★ |
| F12 | 主列表搜索：NSTextField 子类（acceptsFirstMouse/needsPanelToBecomeKey/performKeyEquivalent/onDeleteKey）+ 键盘选择与粘贴 | ★★★ |

---

## 2. 类清单（含地址证据）

> 类对象/描述符/访问器/方法表地址均来自 `otool -arch arm64 -oV` 与 Swift 类型上下文解析；IMP 为方法表实测。

### 2.1 捕获族
| 类 | 证据 |
|---|---|
| `ClipboardManager` | ObjC 类对象 `0x100c5fba8`（classlist 槽 `0x100c008d0`），Swift ctx `0x1009bbd64`，metadata accessor `0x100119464`；instanceSize 480；**81 个 ivar 全曝光**（§3.1）；无任何 ObjC classref（纯 Swift 引用） |
| `ClipboardPasteboardReader` | 类对象 `0x100c45fa0` 附近（name `0x100acc380`），无 objc 方法 |
| `EventTapContext`（键盘 tap 载体） | CGEventTapCreate 调用 `0x1005c1894`：`(tap=1 session, place=0 headInsert, options=1 listenOnly, mask=0x1c00, callback=0x1005c2ed0)`；回调分派 keyDown/keyUp→`0x1005c19b4`，flagsChanged→`0x1005c2a70`；区域字符串 `Frset/ShortcutRuntimeCoordinator.swift`(0x1005c370c) 与 action id `translateSelection`/`screenshotTranslate`/`floatingClipboard`(0x1005c10f8-0x1005c111c) |
| `AppKitDoubleTapMonitor` | ctx `0x1009c5ff4`，accessor `0x1005c6398`，instanceSize 144；ivars `globalFlagsMonitor/localFlagsMonitor/globalKeyMonitor/localKeyMonitor`（4×32B，即 NSEvent global/local 监视器对）；init 常量 **1000** 写入偏移 0x28（`0x1005c0858`） |
| `DoubleTapShortcutDetector` | ctx `0x1009c5ed4`，accessor `0x1005bf794` |
| `DoubleTapModifier`/`DoubleTapRuntimeAvailability`/`DoubleTapUnavailableReason`/`ShortcutAction`/`ShortcutPreferredMode` | ctx `0x1009c855c` / `0x1009c84ec` / `0x1009c8524` / `0x1009c8508` / `0x1009c8540`（均为 enum，kind=18） |

### 2.2 列表交互族
| 类 | 证据 |
|---|---|
| `ClipboardRowContextMenuActivationTrackerNSView` | NSView 子类；methlist `0x100958940`（7 方法）：`acceptsFirstMouse:`→`0x1001b15b4`、`hitTest:`→`0x1001b16a4`、`rightMouseDown:`→`0x1001b16f0`、`mouseDown:`→`0x1001b1890`、`initWithFrame:`→`0x1001b18e0`、`initWithCoder:`→`0x1001b1a14`；ivars `onRightMouseDown`/`onSelectionMouseDown`/`interceptPlainMouseDown`；类对象 `0x100c45fa0` |
| `ClipboardRowHoverSuppressionController` | Swift 类（SwiftObject 基）；ctx `0x1009bd41c`，accessor `0x1001db2f0`；instanceSize 17；ivars `isSuppressedUntilMouseMove`(Bool)/`hoveredRowItemID`/`hoveredIconItemID`；使用点 `0x1002795d4`、`0x10027f360`（列表视图 @State 初始化） |
| `ClipboardListTopScrollTracker` | Swift 类；ctx `0x1009bd3d8`，accessor `0x1001db258`；instanceSize 41；ivars `band`(8B)/`isOut`(Bool)/`lastMinY`(9B)；使用点 `0x100279590`、`0x10027f31c` |
| `FloatingClipboardActiveHoverTrackerNSView` | NSView 子类；methlist `0x1009588c8`（9 方法）：`updateTrackingAreas`→`0x1001d8bdc`、`mouseEntered:`→`0x1001d8c04`(w3=1)、`mouseExited:`→`0x1001d8c0c`(w3=0)、公共体 `0x1001d8c14` 调 `onHoverChanged(Bool, NSEvent)`；`acceptsFirstMouse:`→`0x1001d8cb8` **恒返回 true**；`mouseDown:`→`0x1001d8d58`→`0x1001d8cc0`；`hitTest:`→`0x1001d8da8`（CGRectContainsPoint + `isPreviewPresented` 门控）；ivars `isPreviewPresented`/`onHoverChanged`/`onPreviewIconClick`/`currentTrackingArea` |
| `ClipboardSearchTextField` | **NSTextField 子类**；methlist `0x100958868`（7 方法）：`acceptsFirstMouse:`→`0x1000d87d0`、`needsPanelToBecomeKey`(readonly 属性)→`0x1000d87d8`、`mouseDown:`→`0x1000d8b80`、`performKeyEquivalent:`→`0x1000d8c6c`、`initWithFrame:`→`0x1000d8cc8`；ivar `onRequestActivation`；配套 `ClipboardSearchInputField.Coordinator`（name `0x100acbe80`）、`DeleteKeyMonitor`（反射名） |
| `ClipboardFilterBarView` / `ClipboardFilterBarHostView` | **SwiftUI struct**（无 objc 元数据）；源路径串 `Frset/ClipboardFilterBarView.swift`(0xb43306)；访问性标识 `FilterBar_Search`(0xb43380)、`FilterBar_ScrollToTop`(0xb433ea) |
| `ClipboardFilterType` | enum；反射名 0x96e9b0；**case 集反射串块 @0xaed3c0**：`all, text, image, link, file, code, color, generated, note`（+`placeholder` 属搜索框） |
| `ClipboardNativeMenuPresenter` / `ClipboardMenuActionItem(+Coordinator)` | 反射名 `0x96ecb0` 区；原生菜单呈现层 |

### 2.3 关键选择器 stub（换算表，供后续复用）
`changeCount` stub `0x1009462c0`（selref `0x100c3d758`），**19 个调用点**：`0x1000eebf4/0x1000eee40/0x1000ef1f8/0x1000efb80/0x1000efd48/0x1000efeac/0x1000f266c/0x1000f44ec/0x1000f81f4/0x1000f8434/0x1000f8cd8/0x1000f9ccc`（ClipboardManager+Reader 主簇）、`0x100156aec`、`0x10016cc78/0x10016cc84/0x10016cfc4/0x10016cfe4`（双读比对点）、`0x1005c4c5c/0x1005c4fd8`。

---

## 3. 六个探明问题详解（还原依据）

### 3.1 Q① 捕获时序（待查 #1）——★★★

**ClipboardManager 81 个 ivar 中的捕获相关全集**（objc ivar 表实测，偏移槽页 `0x100c5f000`，基址+0x860 起）：
```
pasteboard / lastChangeCount(槽0x930) / lastSelfWriteChangeCount / lastSelfWriteToken /
lastSelfWriteExpiresAt / selfWriteTokenTTL / selfWriteMarkerPasteboardType / timer /
paywallBoundaryTimer / idlePollingInterval / burstPollingInterval / burstDuration /
currentPollingInterval(槽0x988) / burstUntil(槽0x990) / pasteboardReader /
monitoringGeneration / isMonitoringRequested / pendingBaselineGeneration /
pendingCaptureRetryGeneration / isReaderWorkDispatchScheduled /
activeClipboardCaptureTransaction / monitoringStartRequestedDuringCaptureTransaction
```

**双速率轮询常量（汇编立即数）**：
- 闲置间隔 **1.0s**：`fmov d0, #1.0` @`0x1000f115c` → 调下一拍调度器 `0x1000effd4`（参数 d0=间隔）
- 突发间隔 **0.5s**：`fcmp currentPollingInterval, 0.5` @`0x1000f0f90`；不等则 `fmov d0, #0.5` @`0x1000f0f98` 后调度
- 突发窗口 **2.0s**：`fmov d0, #2.0` @`0x1000f0f0c`（第二处 `0x1000f0fd8`）→ `Date.addingTimeInterval(2.0)`（stub `0x10093efd4`）→ 写 `burstUntil`
- 重试定时器：`Date().timeIntervalSince` + `fmov d0, #0.5; fmaxnm d8, d8, d0` @`0x1000ec8b8-0x1000ec8c0`（下限 0.5s 钳制）→ `timerWithTimeInterval:repeats:block:`（repeats=0 一次性）@`0x1000ec950` → `addTimer:forMode:` **NSRunLoopCommonModes** @`0x1000ec9b8`（stub `0x100944c80`）
- 排除项：区域内 `fmov #20.0`×7（如 `0x1002bd010` 调用点前）为**错误 Toast 展示时长**（伴随 `exclamationmark.circle.fill`），非轮询参数

**自写回声抑制**：
- `0x10016cc40` 起函数：`objc_opt_self`（NSPasteboard 类）→ `generalPasteboard` → **连续两次 `changeCount`**（`0x10016cc78`/`0x10016cc84`，比对 `cmp x21, x23`）——"读取时变化则重读/放弃"的防撕裂模式
- 标记类型字符串 **`com.frset.selfwrite-token`**（`__cstring` 0xb43f 区）；配合 `lastSelfWriteToken/lastSelfWriteExpiresAt/selfWriteTokenTTL` 做 TTL 化回声忽略
- `copy(_:)` 写回后同步 `lastChangeCount`（specs/05 5.1 已推断，ivar 表证实）

**CGEventTap 与捕获无关**：全二进制仅 1 处 `CGEventTapCreate`（`0x1005c1894`），参数 (session, headInsert, **listenOnly**, mask `0x1c00` = keyDown(1<<10)+keyUp(1<<11)+flagsChanged(1<<12))，回调经 MainActor Task 分派，归属 `ShortcutRuntimeCoordinator`（双击/快捷键）；捕获路径零 CGEventTap。

**与重建的差异（必须修正）**：`apps/FrsetNext/.../ClipboardManager.swift` 现为固定 0.5s 轮询 + 可选 EventMonitor 复制键检测（0.15s 延迟 ingest）。原作无复制键检测路径；应改为：Timer 自适应（1.0/0.5/2.0）+ changeCount 双读防撕裂 + selfwrite-token 标记 + 重试一次性 Timer。

### 3.2 Q② 右键判定 ——★★★

`rightMouseDown:`（IMP `0x1001b16f0`）逐指令语义：
1. 计算 location（`0x10094cac0`/`0x100946d80`，返回 CGPoint 在 v0/v1）
2. 读 ivar `onRightMouseDown` 闭包（offset 槽 `0x100c62000+0xe40`）；**非 nil → 调用闭包(CGPoint) 并吞事件**（tail `0x100052c64`，无 objc_msgSendSuper2）
3. nil → 仅 release 返回（也不透传）

`mouseDown:`（IMP `0x1001b1890`，即 `0x1001b17b8` 起）：
- `swift_getObjectType` + 类标志 `tst x0, #0x120000`；读 `interceptPlainMouseDown`（Bool，槽 `0x100c62000+0xe50`）
- **intercept==1 → 调 `onSelectionMouseDown`(location) 并吞事件**；否则 `objc_msgSendSuper2 mouseDown:` 透传
- 结论：**右键按下即算**（AppKit 语义 rightMouseDown 在按下时回调）；行视图用它做"右键即激活菜单 + 可选拦截普通按下为选中"

### 3.3 Q③ hover 抑制 ——★★

`ClipboardRowHoverSuppressionController` 三 ivar + 反射 API 面（reflstr 实测）：
`isHoverSuppressed` / `onSuppressHoverUntilMouseMove` / `__suppressHoverUntilMouseMove` / `__hoverSuppression` / `onRowHoverChanged` / `__hoveredIconItemID` / `__scrollWheelMonitor` / `__isPreviewPopoverHovered` / `hoverPreviewOpenDelay` / `hoverPreviewCloseDelay` / `activeHoverIntentThreshold`
- 语义：事件（滚轮滚动/菜单打开/预览打开等）→ `onSuppressHoverUntilMouseMove()` 置位 `isSuppressedUntilMouseMove` 并清 `hoveredRowItemID`（高亮熄灭）；**鼠标下一次移动**（mouseMoved/Entered 带新坐标）→ 清抑制、恢复 `onRowHoverChanged` 高亮
- 行为对照：滚动列表时行高亮不闪跳（抑制）；手一动立即恢复
- ⬜ 置位触发的完整场景清单（滚轮监视器 `__scrollWheelMonitor` 存在，逐分支未解码）

### 3.4 Q④ 顶部滚动 tracker ——★★

- 状态机 ivar：`band`(8B) / `isOut`(Bool) / `lastMinY`(9B) —— 对首条目 minY 做**迟滞双阈值**判定：`firstItemScrollOutEnterThreshold`（进入"已滚出"）与 `firstItemScrollOutExitThreshold`（退出，防抖动），反射名实证（reflstr 0xaf2 区）
- 输出：`onFirstItemScrolledOutChange` → ClipboardManager ivar `isMainListAtTop` + `pendingMainListPromotedItems`（新条目置顶 promote 的同步闸 `__suppressMainListTopPromotionSync`/`__pendingMainListTopPromotionReleaseWorkItem`）
- 通知：`mainClipboardFirstItemScrolledOutChanged`（cstring 0xb43200 区）；`scrollToTopNotification` + `__scrollToTopRequestSequence`（序列号防重复）
- 入口按钮：过滤栏 `FilterBar_ScrollToTop`（icon `arrow.up.to.line`，accessibility/埋点标识），触发 `onRequestScrollToListTop`/`onScrollToTop`
- 关联布局常量名：`restingTopInset` / `topInsetClearLineThreshold` / `emptyTopPadding` / `topReservedSpace`（吸顶区的让位布局）
- ⬜ band 高度与两个阈值的数值（字面量为字面池 Double，未逐池解码）

### 3.5 Q⑤ 双击激活 ——★★

- 类型族（全反射实证）：`DoubleTapShortcutDetector` / `AppKitDoubleTapMonitor` / `AppKitDoubleTapEvent` / `DoubleTapModifier` / `doubleTapModifiers` / `doubleTapInterval` / `DoubleTapInlineSwitch` / `DoubleTapModifierInputView`（设置 UI）/ `DoubleTapRuntimeAvailability` / `DoubleTapUnavailableReason`（权限可用性态）/ `ShortcutAction` / `ShortcutPreferredMode`
- 双通道监听：
  1. `AppKitDoubleTapMonitor`：4 个 NSEvent 监视器（global/local × flags/key）——**flagsChanged 双击检测**（修饰键双按）；init 默认间隔常量 **1000**（`mov w8, #0x3e8` @`0x1005c0858`，写 ivar 0x28；推断单位 ms，即 1.0s，⬜ 精确语义）
  2. `ShortcutRuntimeCoordinator` CGEventTap：session tap、listen-only、掩码 0x1c00（keyDown/keyUp/flagsChanged）——权限/运行时兜底通道（`DoubleTapRuntimeAvailability`）
- 触发对象：`ShortcutAction` 分发表字符串 `translateSelection` / `screenshotTranslate` / `floatingClipboard`（0x1005c10f8 区）；历史更新日志实证交互意图：**"悬浮剪贴板在鼠标附近打开（需开启辅助功能权限）"**（cstring `0xb57ae6`）→ 双击修饰键 = 打开悬浮剪贴板（⬜ 默认 action 与 DoubleTapModifier 枚举 case 名未解出）
- tip：`hasSeenDoubleTapShortcutTip_v1`（defaults 实测）对应一次性引导；读取点 `0x100654288`（UserDefaults bool）→ 未读时置位并 `withAnimation(easeOut(duration:))`（`0x100654324`）呈现动画提示，位于快捷键设置视图区（ShortcutsSettingsView/ShortcutKeyView 邻域）；`DoubleTapUnavailableReason` 驱动设置页可用性文案
- ⚠️ **与主面板行点击语义区分**：悬浮列表是 **单击=预览、双击=粘贴**（cstring `0xb57d56`"悬浮剪贴板交互调整为单击预览、双击粘贴。"）；主面板是 **单击/空格=预览、双击/↩=复制**（§3.7）。两者都不是"单击=复制"

### 3.6 Q⑥ 过滤栏 ——★★★

- `ClipboardFilterType` case 全集（反射串块 `0xaed3c0`，顺序即反射序）：**all, text, image, link, file, code, color, generated, note**
  - 与重建差异：原作**无独立"富文本"过滤项**；多出 `code`（代码）与 `color`（颜色）两项；`url` 原作叫 `link`；`generated`（工具生成）是过滤项（specs/05 B10）
  - ⬜ UI 展示顺序是否严格等于反射序（推断是，case 表常以声明序）
- 过滤栏组成（反射 + cstring）：类型项 + 搜索（`FilterBar_Search`，placeholder "Search Clipboard"，icon `square.and.pencil`）+ 回顶（`FilterBar_ScrollToTop`，icon `arrow.up.to.line`）+ 漏斗菜单（icon `line.3.horizontal.decrease.circle`，`__isFilterMenuPresented`）+ 标签菜单（`__isTagMenuPresented`，全标签哨兵 `__clipboard_tag_filter_all_tagged__`）
- 状态字段：`_searchQuery` / `_isSearchActive` / `_selectedFilter` / `filterSession*`（ClipboardManager 侧 7 个 filterSession ivar，会话式过滤搜索）
- 过滤栏 hover：`__isHoveringFilterBar` + `__hoverTimer`
- 其他实证交互字段：`isDoubleClickSearchInsertionEnabled`（双击插入搜索）、`showsSearchDefaultHighlight`、`showsKeyboardPreviewHint`、`clipboardItemTitleLineMode`
- 文案来源注记：过滤项中文标签（全部/文本/图片/链接/笔记…）**不在 Mach-O 切片内**（已用 allstrings-addr.txt 全文验证，仅 whatsNew 句子命中）；标签在 Localizable 资源，开发时按 §4 枚举自拟中文，随 specs/18 L10n 基建收口

### 3.7 主面板行点击语义（planning 补证）——★★★

提示文案 cstring（planning 提供 VA，本轮复核存在）：
- `0x100b43d30` **"单击或按空格预览"** —— 主面板**单击=预览**（非复制！）
- `0x100b43d10` **"双击或按 ↩ 复制"** —— 双击或回车=复制
- `0x100b43d70` "Frset 提示：双击条目可复制" —— 一次性引导
- 悬浮窗特性串（WhatsNew）：`0x100b57910` "支持双击快捷键唤起"（与 §3.5 双击修饰键唤起互证）、`0x100b57030` 搜索与类型筛选、`0x100b577e0` 取消置顶、`0x100b57840` 键盘 ↑/↓ Enter Space、`0x100b57ae0` 鼠标附近打开需辅助功能

**重建关键差异（必须修）**：重建版现行为"单击=复制"；原作主面板为 **单击/空格=预览（Popover，接 specs/12）+ 双击/↩=复制**。NSTableView 骨架的行点击分派应为：
```swift
// 行点击分派（对齐原作）
单击 / Space   -> previewCoordinator.present(item)      // specs/12 Popover
双击 / ↩       -> manager.copy(item)                    // 并按偏好可选自动粘贴
右键按下       -> contextMenu(for: item)                // §3.2
```
（此分派与双击修饰键唤起悬浮窗无关，后者在 ShortcutRuntimeCoordinator 层）

---

## 4. NSTableView 化实现骨架（衔接重建 ClipboardSectionView）

> 重建现状：SwiftUI `LazyVStack`。原作交互族（右键 tracker / hover 抑制 / 顶部滚动 / 复用行）本质是 AppKit 行为。迁移策略：**主列表换 NSViewRepresentable 承载 NSScrollView+NSTableView，行内容仍用 SwiftUI（NSHostingView 包 ClipboardRow）**，交互回调经现有 `ClipboardManager` 发布字段桥接。

```swift
// Features/Clipboard/List/ClipboardTableHostView.swift（新文件骨架）
struct ClipboardTableHostView: NSViewRepresentable {
    @ObservedObject var manager: ClipboardManager
    let onRightMouseDown: (ClipboardItem, CGPoint) -> Void
    let onSelectionMouseDown: (ClipboardItem) -> Bool   // interceptPlainMouseDown
    let onRowHoverChanged: (ClipboardItem?, CGPoint?) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        let tv = ClipboardTableView()          // NSView 子类承载 trackers
        tv.headerView = nil                    // 无表头；style = .inset/fullWidth 按探针
        tv.rowHeight = 56                      // 行高：图/文统一 56（探针 44pt 缩略图 + 上下留白），按 item 类型 delegate 覆盖
        tv.usesAutomaticRowHeights = false     // 固定行高 + 每类型常量表（见下），避免 SwiftUI 测量
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        sv.documentView = tv
        // Q④: contentView boundsChange → TopScrollTracker.feed(minY:)
        NotificationCenter.default.addObserver(...)          // NSView.boundsDidChangeNotification
        return sv
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        // 复用池：按 ClipboardItemType 注册行视图标识
        func tableView(_ tv: NSTableView, viewFor tableColumn:, row:) -> NSView? {
            let id = ReuseID(for: item)   // "row.text" / "row.image" / "row.file" / "row.link" / "row.note" / "row.code" / "row.color" / "row.generated"
            let host = tv.makeView(withIdentifier: id, owner: nil) as? RowHostingView
                ?? RowHostingView(reuseIdentifier: id)
            host.setItem(item, filterKind: manager.filter)     // diff 驱动，swiftUI body 仅行内
            host.onRightMouseDown = onRightMouseDown           // Q②: 右键按下即回调
            host.interceptPlainMouseDown = manager.isExplicitMultiSelectMode
            return host
        }
        // 行高策略：文本行按行数模式 clipboardItemTitleLineMode 两档；
        // 图片/文件行 56；大文本行仍 56（预览交给 popover/specs-12）
        func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat { RowHeights[for: item] }

        // Q④: 滚动 → 首条目 minY 迟滞
        func scrollViewDidScroll(_ sv: NSScrollView) { topTracker.feed(minY: firstVisibleMinY) }
        // Q③: 滚轮监视 → 抑制 hover
        override func scrollWheel(with event: NSEvent) { hoverSuppression.suppressUntilMouseMove() }
    }
}

// Q②: 行视图三件套（对照原作 tracker NSView）
final class ClipboardRowInteractionTrackerNSView: NSView {
    var onRightMouseDown: ((CGPoint) -> Void)?          // rightMouseDown: 按下即触发，吞事件
    var onSelectionMouseDown: ((CGPoint) -> Void)?      // interceptPlainMouseDown==true 时吞 mouseDown:
    var interceptPlainMouseDown = false
    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(convert(event.locationInWindow, from: nil))  // 不调 super
    }
    override func mouseDown(with event: NSEvent) {
        if interceptPlainMouseDown, let h = onSelectionMouseDown { h(...); return }
        super.mouseDown(with: event)
    }
    override func hitTest(_ p: NSPoint) -> NSView? { /* 透传子按钮 */ }
    override func acceptsFirstMouse(for n: NSWindow?) -> Bool { true }
}

// Q③: 抑制控制器（字段对齐原作）
final class ClipboardRowHoverSuppressionController {
    private(set) var isSuppressedUntilMouseMove = false
    var hoveredRowItemID: String?
    var hoveredIconItemID: String?
    func suppressUntilMouseMove() { isSuppressedUntilMouseMove = true; hoveredRowItemID = nil }
    func mouseMoved(at p: NSPoint) { isSuppressedUntilMouseMove = false }   // 移动即恢复
    var isHoverSuppressed: Bool { isSuppressedUntilMouseMove }
}

// Q④: 顶部滚动 tracker（ivar 对齐原作 band/isOut/lastMinY）
final class ClipboardListTopScrollTracker {
    private(set) var band: Double = 0          // 顶部监测带高（⬜ 原作数值）
    private(set) var isOut = false
    private var lastMinY: Double?
    var enterThreshold: Double = 40            // ⬜ 原作数值，需实测校准
    var exitThreshold: Double = 24             // ⬜ 迟滞：exit < enter
    var onFirstItemScrolledOutChange: ((Bool) -> Void)?
    func feed(minY: Double?) { /* lastMinY 迟滞判定 → isOut 翻转时回调 */ }
}

// Q①: 自适应轮询（对齐原作 ClipboardManager）
final class AdaptiveClipboardPoller {
    static let idleInterval: TimeInterval = 1.0      // fmov 1.0 @0x1000f115c
    static let burstInterval: TimeInterval = 0.5     // fmov 0.5 @0x1000f0f98
    static let burstWindow: TimeInterval = 2.0       // addingTimeInterval(2.0) @0x1000f0f0c
    static let retryFloor: TimeInterval = 0.5        // fmaxnm 0.5 @0x1000ec8b8
    private var currentInterval = idleInterval
    private var burstUntil: Date?
    private var lastChangeCount = -1, lastSelfWriteChangeCount = -1
    private var lastSelfWriteToken: String?; private var lastSelfWriteExpiresAt = Date.distantPast
    static let selfWriteMarkerType = "com.frset.selfwrite-token"
    // tick: changeCount 双读防撕裂(0x10016cc40 模式) → 命中自写 token 且未过期 → 忽略；
    // 命中新内容 → ingest + burstUntil = now+2.0 + interval=0.5；burstUntil 过期 → interval=1.0
    // 失败 → 一次性 Timer(max(0.5, backoff)) .common 模式重试
}

// Q⑥: 过滤枚举（修正重建 ClipboardFilterKind）
enum ClipboardFilterKind: String, CaseIterable {          // 反射序 0xaed3c0
    case all, text, image, link, file, code, color, generated, note
    // 原 .richtext 删除（并入 text 索引/检索）；.url → .link；新增 .code / .color / .generated
}
```

**迁移策略（对现 LazyVStack 的衔接）**：
1. 保留 `ClipboardSectionView` 外壳（搜索框/过滤栏仍是 SwiftUI）；仅列表主体替换为 `ClipboardTableHostView`。
2. `ClipboardManager` 数据供给不变（items 分页 loadMoreIfNeeded 挂在 `tableView(_:willDisplay:)` 尾行）。
3. 行 hover 高亮从 SwiftUI onHover 迁到 tracker NSView 的 mouseEntered/mouseExited（NSTrackingArea，`activeHoverIntentThreshold` 用 NSTrackingArea.Options.activeWhenFirstResponder 语义近似）；浮动窗 `FloatingClipboardActiveHoverTrackerNSView` 已是原样（单击预览/双击粘贴由 hitTest+mouseDown 处理，骨架照抄 §2.2）。
4. 回顶按钮与 `isMainListAtTop` 经 `topTracker.onFirstItemScrolledOutChange` 驱动，替代现有 GeometryReader 方案。
5. 过滤枚举先改 `.url→.link`、删 `.richtext`、加 `.code/.color/.generated`（UI 文案后随 specs/18 L10n 基建补齐）。

---

## 5. 还原依据（四源对齐）

| 依据 | 来源 |
|---|---|
| 类/方法/ivar 地址 | `otool -arch arm64 -oV`（/tmp/objc_dump.txt，1072 组方法表） |
| 方法名 | __objc_methname 相对指针解码（selref 链式 fixup 低 36 位）；`/tmp/re14/stubs.py` 解析 __objc_stubs 1188 条 |
| 轮询常量 | disasm 立即数：1.0@`0x1000f115c`、0.5@`0x1000f0f98`、2.0@`0x1000f0f0c`、0.5 重试钳制@`0x1000ec8b8` |
| changeCount 调用 | stub `0x1009462c0` 的 19 个 bl 调用点（含 `0x10016cc78/84` 双读比对） |
| CGEventTap | `0x1005c1894`：(1,0,1,0x1c00,cb 0x1005c2ed0)；action 串 `0x1005c10f8-0x1005c111c` |
| 过滤枚举 | reflstr `0xaed3c0`：all/text/image/link/file/code/color/generated/note |
| 交互字段面 | reflstr `0xaef100-0xaf2400`（hover/scroll/filter/preview 全集） |
| 自写标记 | cstring `com.frset.selfwrite-token` |
| 行为意图 | 历史更新日志 cstring：`0xb57d56` 单击预览/双击粘贴、`0xb57ae6` 鼠标附近打开、`0xb57036` 悬浮搜索与类型筛选、`0xb57846` 键盘操作 |
| 主面板点击语义 | 提示 cstring：`0xb43d30` 单击/空格预览、`0xb43d10` 双击/↩ 复制、`0xb43d70` "Frset 提示：双击条目可复制"；双击唤起 `0xb57910` |
| tip 机制 | `hasSeenDoubleTapShortcutTip_v1` 读/写 @`0x100654288`/`0x1006542fc`，withAnimation(easeOut) @`0x100654324`（快捷键设置区） |
| 实机偏好 | defaults：`hasSeenDoubleTapShortcutTip_v1`、`clipboard_keyboard_preview_hint_consumed`、`auto_paste_prompt_count_v1` |
| 埋点标识 | `item_row_interaction` / `item_context_menu_unlock` / `item_copy_shortcut` / `preview_navigation` / `FilterBar_*` |

---

## 6. 行为对照条目（回填 tests/行为对照表 C 系）

| C# | 行为 | 期望（原作语义） |
|---|---|---|
| C1 | 复制后捕获延迟 | 闲时 ≤1.0s；突发窗内 ≤0.5s；无"复制快捷键检测"路径 |
| C2 | 连续快速复制多条 | 突发轮询 0.5s 持续 2.0s 窗口，多条依次入库 |
| C3 | Frset 自写回放 | 写回粘贴板带 selfwrite-token 标记，捕获循环跳过自写（TTL 过期前） |
| C4 | 行右键 | 右键**按下**立即弹菜单（不等抬起）；按下期间不透传 |
| C5 | 滚动中 hover | 滚轮滚动时行高亮被抑制；鼠标移动立即恢复 |
| C6 | 首条目滚出 | 过滤栏出现回顶按钮（arrow.up.to.line）；点击平滑回顶；回到顶部按钮消失（迟滞） |
| C7 | 双击修饰键 | 双按配置的修饰键 → 悬浮剪贴板在鼠标附近打开（需辅助功能）；仅首次弹 tip |
| C8 | 过滤栏类型项 | 全部/文本/图片/链接/文件/代码/颜色/工具生成/笔记 九项；无独立"富文本"项 |
| C9 | 悬浮列表行 | 单击=预览、双击=粘贴；首次点击可激活（acceptsFirstMouse） |
| C10 | 搜索框 | 单击即获焦（needsPanelToBecomeKey）；支持按键选择条目并粘贴；DeleteKey 监听清空 |
| C11 | 主面板行点击 | **单击/空格=预览（Popover）**、**双击/↩=复制**；一次性提示"双击条目可复制"（⇒ 重建须把"单击=复制"改为预览） |
| C12 | 双击快捷键唤起提示 | "支持双击快捷键唤起"随 whatsNew 记录；tip 仅首次（withAnimation easeOut 呈现于快捷键设置区） |

---

## 7. ⬜ 未探明清单（附已尝试手段）

| 项 | 状态 | 已尝试 |
|---|---|---|
| `selfWriteTokenTTL` 数值 | ⬜ | ivar 名实证；TTL 写入点未在轮询簇中定位（该函数簇未逐窗读完） |
| burst 触发分支全清单 | ⬜ | 已证成功捕获进入 burst（0x1000f0f04 路径），其余入口（应用激活等）未枚举 |
| `paywallBoundaryTimer` 用途/间隔 | ⬜ | ivar 实证；未定位创建点 |
| TopScroll 阈值数值（enter/exit/band） | ⬜ | 字面量为字面池 Double，需逐池反解；字段名与迟滞结构已证 |
| hover 抑制置位场景全清单 | ⬜ | 滚轮监视器 `__scrollWheelMonitor` 实证；逐分支未解码 |
| `DoubleTapModifier` 枚举 case 名 | ⬜ | 猜测 capsLock/fn/command 等均未命中（case 名可能经本地化表） |
| `doubleTapInterval` 单位与可配置性 | ⬜ | 默认常量 1000 实证（@0x1005c0858）；单位推断 ms；设置页 `DoubleTapModifierInputView` 存在，绑定细节未读 |
| 双击默认 `ShortcutAction` | ⬜ | action 串 floatingClipboard/translateSelection/screenshotTranslate 实证；默认项未解码 |
| 过滤项 UI 顺序与文案 | ⬜（文案在 Localizable 资源，不在切片内——已用 allstrings-addr.txt/xref-index.txt 复核：独立标签"全部/文本/…"无 VA、无 adrp+add 引用；二进制中文仅 whatsNew/日志 9 条） | reflstr 序即声明序（推断） |

---

## 8. 验收要点（对本 SPEC 骨架的实现验收）
- [ ] 轮询参数与原作常量一致（1.0/0.5/2.0/重试钳 0.5）
- [ ] 自写回声不重复入库（含 TTL 过期后再入库的对照）
- [ ] 右键按下即弹菜单；普通按下在多选态被拦截为选中
- [ ] 滚动抑制 hover、移动恢复（对照 C5）
- [ ] 首条目滚出出现回顶按钮，回到顶部消失（对照 C6）
- [ ] 过滤栏九项与 C8 一致；`.link` 语义与 SQL `type='url'` 映射正确
