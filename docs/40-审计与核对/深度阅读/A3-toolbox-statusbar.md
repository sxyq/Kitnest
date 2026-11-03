# A3 — Features/StatusBar + Features/Toolbox 逐行测绘

范围：`Features/StatusBar/`（7 文件 / 2,425 行）、`Features/Toolbox/`（23 文件 / 5,987 行），合计 **30 文件 / 8,412 行**。

符号索引对账（`/tmp/frset_symbols.csv`）：StatusBar **126 条声明 / 93 个 func**，Toolbox **289 条声明 / 183 个 func**。本文表格覆盖 276 个 `func`（含 `static`/`private`）+ 各 `View.body`（computed property，索引不计入 func）。

阅读深度说明（诚实标注）：
- StatusBar 7 个文件 **逐行全读**（`StatusBarController` 618、`MenuBarIconStyle` 544、`StatisticsRootView` 785 读到 360 行后按结构 + 关键段核实、`StatusBarMenuBuilder` 218、`StatisticsWindowController` 86、`FileTypeIconProvider` 157、`StatusBarModule` 17）。
- Toolbox：`ToolRegistry` / `ToolboxModule` / `ToolShortcutStore` / `FuzzyMatcher` / `CommandPalette` / `ToolboxSectionView` / `ToolRunnerWindow` / `WindowManager` / `MediaTools` / `ShortcutRecorder` / `ShortcutManager` / `CalendarService`(前半) **全读或近全读**；`SearchSectionView`（1504 行）读 30–300、444–565、1395–1504 三个关键段 + 全量函数签名；`BuiltinTools` / `DoubleTapShortcut` / `ToolConverters` / `LunarCalendar` / `HolidayManager` / `IPAddressService` / `CalendarSectionView` / 两个设置页 / `DoubleTapTipWindow` 按**全量签名 + 头部注释 + 关键实现**核实（纯函数/表格类文件语义由签名与注释可完全确定）。

---

## 1. 文件清单

| 路径 | 行数 | 一句话职责 |
|---|---:|---|
| `StatusBar/StatusBarController.swift` | 618 | 菜单栏总控：主图标（Item-0）+ 动态状态项（最多 6 + 「⋯」溢出）+ 1s 标题刷新 + 5s 注册表同步 + 位置持久化 + popover 呈现 |
| `StatusBar/StatusBarMenuBuilder.swift` | 218 | 右键主菜单（含 v128 两段式缓存）：打开面板/设置/监测项开关/图标样式子菜单/退出 |
| `StatusBar/StatusBarModule.swift` | 17 | `AppModule.start()`：安装状态栏 + 预热文件图标 + 启动图标样式应用器 |
| `StatusBar/MenuBarIconStyle.swift` | 544 | 四种主图标样式（logo/fan/date/custom）+ `RotatingLayerView` 变速旋转 + CPU 负载采样 + 样式应用器 |
| `StatusBar/StatisticsRootView.swift` | 785 | 统计窗 SwiftUI：5 张指标卡 + 总览 + 30 天柱图 + 60×7 活动热力图（含 hover tooltip） |
| `StatusBar/StatisticsWindowController.swift` | 86 | 统计窗 800×530 固定尺寸壳 + 延后一个 runloop 装 `NSHostingView` |
| `StatusBar/FileTypeIconProvider.swift` | 157 | 文件类型图标三级缓存（内存 LRU 128 → 磁盘 PNG → `NSWorkspace`），并写 `file_type_icons` 表 |
| `Toolbox/ToolboxModule.swift` | 43 | 模块入口：注册内置工具 / 3 个面板区段 / 2 个设置页 / 搜索数据源 / 恢复工具热键 / 日历授权 |
| `Toolbox/ToolRegistry.swift` | 206 | 工具元数据（`ToolDescriptor`/`ToolOutput`/`ToolOption`/`ToolCategory`）+ 注册表 + 启用开关 + 执行与埋点 |
| `Toolbox/BuiltinTools.swift` | 361 | 注册 13 个内置工具（translate/summary/uuid/timestamp/ip/varName/base64/urlencode/json/codePreview/imageCompress/hash/qrcode）+ 默认输出行为 |
| `Toolbox/ToolConverters.swift` | 573 | 纯函数转换器：时间戳/变量名/Base64/URL/JSON/SHA256/MD5/SHA1/代码高亮/代码卡片图 |
| `Toolbox/MediaTools.swift` | 147 | 本地图片压缩（CGImageSource 缩略图 + 重编码）+ 二维码生成（CIQRCodeGenerator） |
| `Toolbox/IPAddressService.swift` | 125 | 内网 IP（getifaddrs）+ 公网 IP（api.ipify.org）+ 中文错误映射 |
| `Toolbox/FuzzyMatcher.swift` | 110 | fzf 式子序列模糊匹配 + 整型评分 + 命中下标（供高亮） |
| `Toolbox/SearchSectionView.swift` | 1504 | 主面板搜索区段：工具模糊检索 / Spotlight 文件检索（mdfind）/ 剪贴板历史 / 网页结果离屏抓取 + 内嵌预览 |
| `Toolbox/CommandPalette.swift` | 507 | ⌥K 命令面板：`CommandCatalog` 聚合 5 类命令 + 模糊过滤 + 键盘导航 |
| `Toolbox/ToolboxSectionView.swift` | 317 | 主面板「工具」区段（4 列网格）+ `ToolRunnerView`（输入/选项/执行/输出/复制/存条目） |
| `Toolbox/ToolRunnerWindow.swift` | 83 | 全局工具窗（v88 从 `.sheet` 改独立窗口，修「点工具没反应」） |
| `Toolbox/ToolSettingsPane.swift` | 144 | 设置「工具」页（逐工具启用开关 + 默认输出行为） |
| `Toolbox/ToolShortcutStore.swift` | 102 | 工具级全局热键持久化与注册（键 `toolbox.toolShortcuts`） |
| `Toolbox/ShortcutManager.swift` | 323 | Carbon `RegisterEventHotKey` 全局热键：注册/重绑/冲突检测/失败原因/键名展示 |
| `Toolbox/ShortcutRecorder.swift` | 84 | 快捷键录入控件（本地 monitor，Esc 取消，强修饰键必需） |
| `Toolbox/ShortcutSettingsPane.swift` | 163 | 设置「快捷键」页（成对展示 + 录入 + 双击切换） |
| `Toolbox/DoubleTapShortcut.swift` | 180 | 双击修饰键触发（global+local `flagsChanged`，0.3s 窗口，7 种修饰键） |
| `Toolbox/DoubleTapTipWindow.swift` | 93 | 双击快捷键的辅助功能权限提示小窗 |
| `Toolbox/CalendarService.swift` | 177 | EventKit 授权 + 事件读取 + 42 格月视图数据 |
| `Toolbox/CalendarSectionView.swift` | 340 | 日历卡（月视图网格 + 农历/节日 + 滚动切换月 + 事件列表） |
| `Toolbox/LunarCalendar.swift` | 220 | 农历换算（`LunarDate`）+ 24 节气 + 农历节日 |
| `Toolbox/HolidayManager.swift` | 74 | 法定节假日/调休表 + 公历节日 |
| `Toolbox/WindowManager.swift` | 111 | 辅助窗口弱引用登记表 + 按类型批量关闭 |

---

## 2. 类型逐段

### 2.1 `StatusBarController`（StatusBarController.swift:73）

- **职责**：菜单栏的**唯一总控**。主图标 `Item-0`（autosaveName `frsetnext.main`）+ `StatusItemRegistry` 注册的动态项。
- **状态**：`mainItem`、`entries[StatusItemEntry]`、`overflowItem`、`overflowDescriptors`、`lastIDs`、`lastLayoutKeys`、`currentPopover`、`refreshTimer`(1s)、`syncTimer`(5s)、`defaultsObservation`、`statisticsObservation`、`isSyncing`、`prefSyncWorkItem`、`didInstall`。
- **生命周期**：`StatusBarModule.start()` → `install()`（幂等，主线程兜底）；`uninstall()` 全拆。
- **依赖**：`StatusItemRegistry`、`ServiceLocator.panel/settings`、`Preferences`、`MonitorPreferences`、`MonitorSampler`、`StatsBarEngine`、`MenuBarIconStyleApplier`、`AppUpdateChecker`、`StatisticsWindowController`、`WelcomeWindowController`。
- **不变量**：
  - 动态项最多 **6** 个，其余进「⋯」溢出菜单；溢出菜单是 `menuNeedsUpdate` 动态重建。
  - 创建顺序**反向**（系统把新项插到左侧），因此描述符序 = 显示序的反序。
  - `isSyncing` 防重入是**必需**的（见 §6）。

### 2.2 `MenuBarTwoLineView`（:30）

- 自绘两行 9pt light 文本；`contentWidth` = max 两行宽 + 4；宽度**只增不减**（`refreshTitles` 里只在 `w > frame.width + 0.5` 时才更新 item.length）。
- **坑**：`draw` 用 `bounds.height/2` 分行，line1 在**上半**（NSView 原点左下）。若按钮高度不足 20pt 会挤在一起。

### 2.3 `MenuBarIconStyle` / `MenuBarIconStyleStore` / `RotatingLayerView` / `MenuBarIconStyleApplier` / `SystemCPULoad`（MenuBarIconStyle.swift）

- **四样式**：`logo`（`square.stack.3d.up` 模板图）、`fan`（18pt 旋转视图，CPU 驱动 7 档 0.8–4.0s/圈）、`date`（`M/d`，60s 刷新）、`custom`（用户 SF Symbol）。
- **持久化**：四个布尔键 `menu-bar-icon-{logo,fan,date,custom}` + `menu-bar-icon-custom-symbol` + `revealCustomMenuBarIconOption`。`current` 取第一个为 true 的（多 true 时按 CaseIterable 序，即 logo 优先）。
- **`RotatingLayerView`**：单条 `CABasicAnimation("transform.rotation.z")` + `repeatCount=.infinity` + **linear**（v155）；变速时读 `presentation()` 当前角度续接，模型层同步角度后重建动画（防跳相位）。`layout()` 里把 `anchorPoint` 改成 (0.5,0.5) 且 `position=bounds 中心`（v49：NSView 托管 layer 默认 anchorPoint 是 (0,0)，会"公转"）。
- **`MenuBarIconStyleApplier`**：观察 `UserDefaults.didChangeNotification`（**全量**偏好变化的通知，非常频繁）→ `apply()`，内部用 `appliedStyle/appliedCustomSymbol` 守卫"未变则跳过"。
- **坑**：`fan` 样式要求 `button.image = NSImage()`（空图占位）且 `setMainItemLength(30)`；否则旋转视图不渲染（v2026-10-16 实证）。

### 2.4 `StatisticsRootView` / `StatisticsChartsView`（StatisticsRootView.swift）

- **结构**：`StatisticsRootView`（页头 + `StatisticsChartsView`）→ `StatisticsChartsView`（5 指标卡 / 总览+30 天柱图 / 60×7 热力图）。
- **状态**（全部 `@Stored`，本机无宏）：`totalInteractions`、`activeDaysCount`、`storedItemsCount`、`todayCountsMap`、`activityTotals`、`last30DayBreakdowns`、`metricNumbersAnimatedIn`。
- **数据源**：`StatisticsManager` 的 Q1–Q5 + `clipboard_items` 的 `COUNT(*)`。
- **坑**：`@Stored` 对**元组数组**（`[(day:String,event:String,count:Int)]`）也要走 `ObservableObject`，每次赋值触发整表重算；`activityTotals` 用 `Dictionary(uniqueKeysWithValues:)`，**若 Q4 返回重复 day 会直接崩**（SQL `GROUP BY day` 保证唯一，但任何人改 Q4 都可能触发）。
- **热力图尺寸**：60 列 × 7 行、格 8pt、间距 3pt → 内容宽 60*8+59*3 = 657，正好落在 660 的内容宽里（**改任一个常量都会溢出**）。

### 2.5 `StatisticsWindowController`（86）

- 固定 **800×530**（`contentMin/MaxSize` 都钉死），`fullSizeContentView` + 透明标题栏 + 官方灰底；`installContent` **延后一个 runloop** 装 `NSHostingView`（否则 `_postWindowNeedsUpdateConstraints` 异常）。
- `openStatistics()` 每次重建内容视图（数据/入场动画重放）+ 埋点 `statistics_open` + 1/30s 后再 `makeKeyAndOrderFront`。

### 2.6 `FileTypeIconProvider`（157）

- 三级缓存：内存 LRU（128，`NSLock` + `lruOrder` 数组）→ 磁盘 `AppDirectories.sub("icons")/<safe>.png` → `NSWorkspace.icon(for: UTType)`。
- 写回：磁盘 PNG + `file_type_icons` 表（`ON CONFLICT DO UPDATE`）。
- **坑**：`diskURL` 用字符白名单替换非法字符（`_`），`"a/b"` 与 `"a_b"` 会撞同一文件；`memoryIcon` 命中时 `touchLocked` 会 O(n) `firstIndex`，128 上限下可接受。

### 2.7 `ToolRegistry` 与工具模型（ToolRegistry.swift）

- `ToolDescriptor`（值类型，含 `async` 闭包）、`ToolOutput`（text/image/isError/note）、`ToolOption`、`ToolCategory`(5)、`ToolInputKind`(text/filePath)。
- `ToolRegistry`：`NSLock` + `items`；同 id 覆盖；启用状态存 `toolbox.tool.<id>.enabled`（默认 true）；`grouped()` 按 `ToolCategory.allCases` 顺序分组。
- `run()` 执行后**必定** `recordInvocation`（写 `tool_invocations` + `bumpStat("tool_count")`），输入/输出各截断 4000 字。

### 2.8 `SearchHookRegistry` / `ToolboxSearchSource` / `FileSearchSource` / `WebResultScraper` / `SearchSectionView`（SearchSectionView.swift）

- `SearchHookRegistry`：`[(String) async -> [SearchResultItem]]`，`search` 用 `withTaskGroup` 并发汇总（单源抛错不影响整体，因为签名非 throwing）。
- `FileSearchSource`：`mdfind "kMDItemFSName == \"*q*\"cd"`（字符间插 `*` 做子序列预过滤）→ 512KB 封顶读取 → 200 候选 → `FuzzyMatcher` 精排（文件名 2 倍权重）→ 同分按目录深度、字母序。
- `WebResultScraper`：单个复用 `WKWebView`（`nonPersistent`），只支持 bing/duckduckgo/google 三家出结果列表，其余回落浏览器；`didFinish` 用 `CheckedContinuation` 单飞 + 超时标志。
- `SearchSectionView`：13 个 `@Stored` 状态 + 3 个 `@AppStorage` 分类开关；`scheduleSearch()` 250ms 防抖 + `generation` 防串台；四类结果视图（web / clipboard / files / tool）。

### 2.9 `CommandPaletteController` / `CommandPalettePanel` / `CommandPaletteState`（CommandPalette.swift）

- `CommandCatalog.build()`（`@MainActor`）每次打开构建 ~40–48 条：截图动作（`CaptureMode.allCases`）、监测、5 个开关、设置页（`SettingsPaneRegistry.all`）、工具（`ToolRegistry.enabledTools`）。
- 窗口：`NSPanel` 660×470、`.nonactivatingPanel + .utilityWindow`、`level = .floating`、`canBecomeKey = true`、居中偏上（visibleFrame 12% 处）。
- `CommandPaletteState.refilter()`：`FuzzyMatcher` 评分排序 + **id 序列比对后才发布**（v128 防 40 行重绘）。

### 2.10 `ToolboxUIState` / `ToolRunnerWindowController`（ToolboxSectionView.swift:12 / ToolRunnerWindow.swift:20）

- `ToolboxUIState.shared`：`activeToolID` 单值 + `open()` 转 `ToolRunnerWindowController.show`。
- 工具窗：480×560、可缩放、`fullSizeContentView`、`isReleasedWhenClosed=false`；同工具二次打开 = 原地换内容；关闭时复位 `activeToolID`。

### 2.11 快捷键体系（ShortcutManager / ShortcutRecorder / ToolShortcutStore / DoubleTapShortcut）

- `ShortcutManager`（单例，`NSLock`）：Carbon `RegisterEventHotKey` + `InstallEventHandler(GetApplicationEventTarget())`，事件签名 `'FRST'`，`hotKeyID → definitionID` 反查后**统一回主线程**执行 handler。
- `bind()` 语义：已存在 → `reconfigure`（**新组合注册成功才撤旧**，失败不改动）；不存在 → `register`。
- `conflictsLocked`：keyCode + modifiers 全等即冲突（不做"⌘ 是否等价 ⌃⌘"之类的归一化）。
- `ShortcutCapture`：本地 `keyDown` monitor，Esc 取消，必须含 ⌘/⌥/⌃ 才采纳，录制期间**吞掉所有按键**。
- `DoubleTapShortcutCenter`：`flagsChanged` 的 global + local 双监听，只看"按下沿"，0.3s 内同键两次触发；`order` 保证同修饰键冲突时先绑定者优先。
- `ToolShortcutStore`：键 `toolbox.toolShortcuts` → `[toolID: [keyCode, modifiers]]`；`set` 先注册成功才落盘；`restoreAll` 在 `ToolboxModule.start` 调用。

### 2.12 其余工具实现

- `BuiltinTools`：13 个注册函数，每个都是 `ToolRegistry.register(ToolDescriptor(...))`；AI 类（translate/summary）走 `TranslationToolSession` / `ServiceLocator.llmService`，未配置时返回 `.error("请先配置 AI 服务商")`。
- `ToolConverters`：纯函数（timestamp 双向 / VarName 5 风格 / Base64 / URL / JSON 美化+错误定位 / SHA256 手写实现 / MD5 / SHA1 / 代码 tokenize + `NSAttributedString` / `cardImage` 离屏渲染）。
- `MediaTools`：`ImageCompressor.compress`（缩略图重采样 + JPEG/PNG 重编码，**纯本地**，注释明确与原作 TinyPNG 网络方案的差异）+ `QRCodeGenerator.image`（CIQRCodeGenerator + 最近邻放大）。
- `IPAddressService`：`getifaddrs` 取内网（en0 优先）+ `api.ipify.org` 取公网（6s 超时）+ 中文错误映射。
- `CalendarService`：EventKit 授权（`rawValue` 判定兼容 macOS 14 的 fullAccess/writeOnly）+ 42 格月视图（周日为起点）。
- `LunarCalendar` / `HolidayManager`：农历换算（1900 起表驱动）+ 24 节气 + 农历节日 + 法定节假日/调休。
- `WindowManager`：弱引用 `Entry` 表 + `pruneLocked` + 按 kind 批量 `close`。

---

## 3. 函数级清单

### 3.1 `StatusBarController.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `MenuBarTwoLineView.setTexts` | 38 | 文本无变化不重绘 |
| `MenuBarTwoLineView.draw` | 52 | 两行 9pt 文本，`NSColor.textColor` 自适应 |
| `StatusBarController.install` | 109 | 主线程兜底 → `performInstall` |
| `performInstall` | 117 | 幂等安装 + 起 timer + 观察偏好 + 注册统计通知 |
| `uninstall` | 131 | 停 timer / 摘通知 / 拆项 / 移除主项 |
| `installMainItem` | 142 | 清 `Preferred Position` → 建 variableLength 项 → 模板图 → `sendAction(on: leftUp/rightUp)` → `ToastAnchor.button` → `StatsBarEngine.syncMainItem()` |
| `setMainItemLength` | 171 | 主线程兜底设长度（fan 固定 30pt） |
| `startTimers` | 179 | 1s 刷新 + 5s 同步，均 `.common`，体包 `autoreleasepool` |
| `observePreferences` | 207 | `UserDefaults.didChangeNotification` → **250ms 合并** 后 `syncStatusItems` |
| `syncStatusItems` | 227 | 主线程 + `didInstall` + `!isSyncing` 三重门 → id 序列变化才 `rebuild`，否则 `refreshTitles` |
| `isHidden(_:)` | 244 | 隐藏标记前缀 / 双层项返回 nil 视为隐藏 |
| `diagnose(_:button:item:)` | 255 | 打印按钮窗口/图/标题/可见性/是否在屏 |
| `statusItemName(_:)` | 276 | `"frsetnext." + id` |
| `saveStatusItemPosition` | 278 | 系统位置键 → 自家 `Restore Position` 键 |
| `restoreStatusItemPosition` | 284 | 反向写回并删除备份 |
| `rebuild(_:)` | 292 | 拆旧 → 取前 6 → **反向创建** → 溢出项 + 菜单 → `refreshTitles` |
| `makeStatusItem(for:)` | 326 | 双层项先量宽 → `restoreStatusItemPosition` → 建项 → 空图占位 + 子视图 → 单行项设 title → `diagnose` |
| `teardownItems` | 362 | 关 popover → 逐项存位置 → remove |
| `refreshTitles` | 377 | 逐项：隐藏则就地隐藏并标记 resync；双层项更新文本且宽度只增；单行项设 title/attributedTitle |
| `verifyLayout(tag:)` | 435 | 主项 + 各项 frame 变化才记日志 |
| `mainItemClicked` | 456 | 右键 → `StatusBarMenuBuilder.mainMenu` 弹出；左键 → `panel.toggle(atAnchor:)` |
| `statusItemClicked` | 476 | 反查 entry → `handle` |
| `overflowItemAction` | 482 | 溢出菜单项 → `handle` |
| `handle(descriptor:anchor:)` | 490 | onTap > popover > 回落 `panel.toggle(atAnchor:)` |
| `showPopover(_:relativeTo:)` | 503 | transient popover 340×620 + `MonitorSampler.setSettingsActive(true)` |
| `presentStatsPopover(_:anchor:)` | 522 | STATS 部件点击 → 按内容自适应高度（上限屏幕高-36） |
| `openPanelAction` | 547 | 菜单打开面板（锚点展开） |
| `openSettingsAction` | 552 | `settings.open(nil)` |
| `openMonitorSettingsAction` | 554 | `settings.open("monitor")` |
| `showOnboardingAction` | 559 | 欢迎窗 |
| `checkForUpdatesAction` | 564 | `AppUpdateChecker.checkNowManual` |
| `toggleMonitorModuleAction` | 568 | 切模块开关 → 重新同步 |
| `toggleMonitorCombinedAction` | 575 | 切合并模式 → 重新同步 |
| `showStatisticsAction` | 581 | 打开统计窗 |
| `toggleIconsAction` | 585 | 切 `menuBar.iconsVisible` + Toast |
| `quitAction` | 592 | `NSApp.terminate` |
| `popoverDidClose` | 598 | 清 popover + `setSettingsActive(false)` |
| `menuNeedsUpdate` | 605 | 溢出菜单按最新数据重建 |

**散文：`refreshTitles` → `syncStatusItems` 的递归环（377–430）**
2026-10-16 崩溃实证：`refreshTitles` 里改 `item.isVisible` → 系统写 defaults → `UserDefaults.didChangeNotification` → `observePreferences` → `syncStatusItems` → `rebuild` → `refreshTitles` …… 深栈后栈溢出（EXC_BAD_ACCESS at stack guard）。现在的两道防线是 **`isSyncing` 防重入 + `needsResync` 走 `DispatchQueue.main.async`**。**任何在 `refreshTitles` 里新增的 `isVisible`/`length` 写操作都必须走同样的异步出口**，否则复发。

**散文：`makeStatusItem`（326–360）**
四条 STATS 实证约束：① 状态项长度必须等于视图宽（否则按钮过窄把子视图裁成「<<」）；② 必须 `button.image = NSImage()` 空图占位（无图按钮不绘制子视图）；③ 双层项不能再设 `title`（会与子视图重叠成多行）；④ 位置键必须在**创建前**写回（系统在 `removeStatusItem` 时会删掉它）。

### 3.2 `StatusBarMenuBuilder.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `mainMenu(target:)` | 46 | 缓存命中只刷勾选态/target；未命中 `buildMenu` |
| `buildMenu(target:revealed:)` | 67 | 全量构造 20+ 项并登记需刷新项 |
| `customIconSubmenu(revealed:)` | 165 | 四样式单选 + 隐藏/恢复项（+ 自定义 Symbol 入口） |
| `item(_:key:modifiers:action:target:)` | 208 | 统一构造带快捷键的菜单项 |

**散文**：`revealed` 变化会改变菜单结构（增删项），所以缓存**按 revealed 分版本**；勾选态**不缓存值**（每次读 `Preferences`/`MonitorPreferences`/`MenuBarIconStyleStore.current`），避免串态。这是 v128 的性能修改，改回"每次全建"会重新引入右键首帧卡顿。

### 3.3 `MenuBarIconStyle.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `MenuBarIconStyleStore.current` | 74 | 首个为 true 的布尔键，否则 logo |
| `MenuBarIconStyleStore.select` | 83 | 四键全写（只目标为 true） |
| `MenuBarIconStyleStore.setRevealsCustomOption` | 99 | 写 reveal 键 |
| `RotatingLayerView.init(frame:)` / `init(coder:)` | 133/143 | 建 imageView + 四向弹性边距 |
| `setSymbol(_:)` | 153 | 14pt 符号 + **中心实心圆点**（v56：SF Symbol 风车轴心是空心环） |
| `layout` | 177 | imageView 铺满 + `anchorPoint=(0.5,0.5)` + `position=中心`（禁隐式动画） |
| `setRotationDuration` | 198 | clamp 0.6–4.0s；变速从 presentation 当前角度续接 |
| `applyRotation(duration:resumeFrom:)` | 210 | 模型层同步角度 + `CABasicAnimation` linear 无限循环 |
| `spin` | 231 | 首次开转 |
| `stop` | 238 | 移除动画 + 复位 transform |
| `MenuBarIconStyleMenuActions.selectIconStyle` | 257 | 写偏好 + `refresh()` |
| `openCustomIconSettings` | 265 | 打开设置 general 页 |
| `hideIconOption` | 271 | `setRevealsCustomOption(false)` + Toast |
| `restoreIconOption` | 281 | 恢复 + `refresh()` + Toast |
| `SystemCPULoad.current` | 300 | 区间 CPU 负载 + EMA(0.6/0.4) |
| `SystemCPULoad.readTotals` | 315 | `host_processor_info` 累加 user/system/idle + `vm_deallocate` |
| `MenuBarIconStyleApplier.start` | 372 | 观察 defaults + 小猫开关通知 → `apply` |
| `refresh` | 398 | 外部主动刷新 |
| `apply` | 402 | 未变则跳过；按样式设图/标题/长度/定时器 |
| `startDateTimer` | 455 | 60s 刷日期 |
| `startFan(on:)` | 469 | 建旋转视图 + 约束居中 + CPU 采样 timer |
| `updateFanSpeed` | 507 | 7 档映射 + 换档才记日志 |
| `stopRotating` | 533 | 停转 + 摘视图 + 恢复 imagePosition |
| `stopTimers` | 540 | 停 date/cpu timer |

**散文：`setRotationDuration` + `applyRotation`（198–228）**
变速必须"从当前相位续接"：读 `layer.presentation()` 的 `transform.rotation.z` → `removeAnimation` → 模型层 `transform` 设成该角度 → 新动画 `from=当前角, to=当前角+2π`。少了模型层同步，窗口重建/动画移除时会瞬间跳回 0°。`timingFunction` **必须 linear**（v155），否则每圈"加速→减速"、接缝速度从 0 跳回最大。

### 3.4 `StatisticsRootView.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `StatisticsRootView.body` | 39 | 页头 + 图表块，800×530，Midnight/个性化背景 + `frsetThemeChrome` |
| `header` | 68 | "Frset" + 锁图标"数据仅存储在本机" + 日期/月 |
| `currentMonth` | 100 | 静态 `MMMM` formatter |
| `StatisticsChartsView.body` | 131 | 指标卡 / 分隔线 / 总览+30 天柱图 / 热力图 |
| `overviewCards` | 212 | 5 张 `MetricCardView` |
| `cardValue(for:)` | 222 | 事件集合求和 |
| `overviewSummary` | 226 | 三行总览 |
| `summaryRow` | 242 | 单行（图标/标题/数值） |
| `loadData` | 260 | 后台 `autoreleasepool` 内跑 Q1–Q5 + `COUNT(*)`，回主线程赋值 + 一次性入场动画 |
| `MetricCardView.body` | 316 | 图标 + 标题 + 数值（缩放/淡入） |
| `ActivityHeatmapView.body` 及其子视图 | 354+ | 60×7 网格 + hover tooltip（0.4s） |
| `HeatmapGridView.body` | 501 | Equatable 网格渲染 |
| `MonthLabelsView.body` | 668 | 月份标签 |
| `Last30BarsView.body` | 716 | 30 天柱图（6pt 宽 / 4pt 间距 / 48pt 高） |

**散文：`loadData`（260–306）**
5 条 SQL 全在 `DispatchQueue.global(qos:.userInitiated)` + `autoreleasepool` 里跑（v128：临时 NSNumber/NSString 池不排空会拖到 runloop 回收）。热力图起点用"同一周日对齐"的算法：`-((60-1)*7 + weekday-1)` 天，保证矩阵右端对齐本周。`activityTotals` 用 `Dictionary(uniqueKeysWithValues:)`——**Q4 若返回重复 day 会崩**。

### 3.5 `StatisticsWindowController.swift` / `FileTypeIconProvider.swift` / `StatusBarModule.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `StatisticsWindowController.init` | 16 | 800×530 固定壳 + 官方外观 + 只留关闭钮 |
| `installContent(in:)` | 46 | 钉死 min/max 尺寸 + 延后一拍装 `NSHostingView` + 重挂圆形关闭钮 |
| `openStatistics` | 66 | 重建内容 + show + center + 埋点 + 1/30s 再前置 |
| `windowWillClose` | 83 | 仅 debug 日志 |
| `FileTypeIconProvider.icon(forExtension:)` | 27 | 内存 → 磁盘 → 系统 → 写盘 + 落库 |
| `icon(forFileURL:)` | 42 | 走扩展名链 |
| `systemIcon(forExtension:)` | 52 | UTType 优先 |
| `handlerBundleID(forExtension:)` | 62 | `LSCopyDefaultApplicationURLForContentType` → bundle id |
| `diskURL(_:)` | 72 | 字符白名单换名 |
| `diskIcon(_:)` | 79 | 读 PNG |
| `writePNG(_:key:)` | 87 | TIFF → PNG → 写盘 |
| `persist(key:handler:path:)` | 106 | UPSERT `file_type_icons` |
| `memoryIcon(_:)` / `remember(_:_:)` / `touchLocked(_:)` | 127/134/144 | LRU（128，锁内） |
| `normalize(_:)` | 152 | 去点、小写 |
| `StatusBarModule.start` | 10 | 装状态栏 + 预热图标缓存 + 起样式应用器 |

### 3.6 `Toolbox/ToolRegistry.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `ToolOutput.init` / `ToolOutput.error` | 47/51 | 结果构造 / 错误结果 |
| `ToolOption.init` | 63 | `defaultIndex` 双侧 clamp |
| `ToolDescriptor.init` | 88 | 值构造（`keyword` 缺省 = identifier） |
| `ToolDescriptor.defaultOptions()` | 108 | 选项默认值字典 |
| `ToolboxEventBus.emitResult` | 123 | 空串不发射；转交总控接线 |
| `ToolRegistry.register` | 137 | 同 id 覆盖（锁内） |
| `ToolRegistry.all` | 144 | 快照 |
| `ToolRegistry.tool(id:)` | 149 | 查找 |
| `isEnabled/setEnabled` | 157/161 | `toolbox.tool.<id>.enabled`（默认 true） |
| `enabledTools` | 166 | 过滤 |
| `grouped()` | 171 | 按分类声明序分组（空组剔除） |
| `run(_:input:options:)` | 183 | 执行 + **必定**记调用 |
| `recordInvocation` | 191 | 写 `tool_invocations`（输入/输出截 4000 字）+ `bumpStat("tool_count")` |

### 3.7 `Toolbox/BuiltinTools.swift`（13 个注册函数）

| 函数 | 行 | 说明 |
|---|---:|---|
| `setDefaultAction` | 22 | 写 `toolbox.defaultAction` |
| `registerAll` | 28 | 顺序注册 13 个工具（translate/summary 走 AI） |
| `registerAITool` | 46 | 翻译走 `TranslationToolSession`；摘要走 `ServiceLocator.llmService` + `AISummaryAction` |
| `registerUUIDTool` | 70 | UUID v4 小写 |
| `registerTimestampTool` | 83 | 三向（自动/戳→日期/日期→戳） |
| `registerIPTool` | 105 | 公网+内网 / 仅内网 |
| `registerVarNameTool` | 134 | 5 种命名风格 |
| `registerBase64Tool` | 158 | 编/解 |
| `registerURLEncodeTool` | 186 | 编/解（strict 选项） |
| `registerJSONTool` | 217 | 美化/压缩 + 错误定位 |
| `registerCodePreviewTool` | 240 | 代码高亮卡片图 |
| `registerImageCompressTool` | 265 | 本地压缩（尺寸/质量/格式选项） |
| `registerHashTool` | 311 | SHA256/MD5/SHA1 |
| `registerQRCodeTool` | 336 | 二维码（尺寸/纠错级） |

### 3.8 `Toolbox/ToolConverters.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `TimestampConverter.convert` | 11 | 按 direction 分流（自动识别纯数字） |
| `timestampToDate` / `dateToTimestamp` | 29/55 | 双向（含多时区展示） |
| `format(_:zone:)` | 82 | 统一日期格式 |
| `VarNameConverter.tokenize` | 105 | 分词（分隔符/驼峰/数字边界） |
| `VarNameConverter.convert(_:to:)` | 138 | 5 风格重拼 |
| `Base64Coder.encode/decode` | 159/164 | 编/解（解失败返回错误说明） |
| `URLEncoderTool.encode/decode` | 192/197 | strict 选项 + 解码失败说明 |
| `JSONFormatterTool.process` | 211 | 美化/压缩；失败带**行号列号**说明 |
| `chineseDescription(_:)` | 230 | NSError → 中文定位串 |
| `HashGenerator.digest` | 246 | 按算法名分派 |
| `HashGenerator.sha256/md5/sha1` | 268/313/360 | **手写实现**（无 CommonCrypto 依赖） |
| `rotateRight/rotateLeft` | 307/398 | 位旋转 |
| `CodeHighlighter.tokenize` | 445 | 按语言切 token（注释/字符串/数字/关键字） |
| `CodeHighlighter.attributed` | 523 | token → `NSAttributedString` |
| `CodeHighlighter.color(for:)` | 538 | token 配色 |
| `CodeHighlighter.cardImage` | 549 | 离屏渲染代码卡片图 |

**散文**：`HashGenerator.sha256`（268–312）是**手写 SHA-256**。注意 `Core/UI/Support.swift` 的 `String.sha256` 曾因手写实现的消息调度字被掩成 32 位而在 32KB 输入上崩溃（注释有崩溃报告名），最终改用 CommonCrypto。这里是另一份独立实现，**未被剪贴板指纹路径使用**，但同样的位运算风险存在——若将来复用它算大文件指纹，必须先与 `shasum -a 256` 对照三组向量。

### 3.9 `Toolbox/MediaTools.swift` / `IPAddressService.swift` / `FuzzyMatcher.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `ImageCompressor.compress` | 33 | 存在性校验 → `CGImageSourceCreateThumbnailAtIndex`（maxDimension>0）或原图 → 编码 → 写 `toolbox/compressed-<ts>.<ext>` |
| `ImageCompressor.encode` | 82 | PNG/JPEG（质量 clamp 0.05–1.0） |
| `ImageCompressor.byteText` | 104 | KB/MB 友好串 |
| `QRCodeGenerator.image` | 119 | CIQRCodeGenerator + 最近邻放大 |
| `correctionLevel(_:)` | 139 | L/M/Q/H 归一化 |
| `IPAddressService.localIPAddress` | 28 | `getifaddrs`（IPv4 优先） |
| `queryPublicIP` | 56 | `api.ipify.org`，6s 超时 |
| `query` | 82 | 组合成 `Report` |
| `displayText(_:)` | 94 | 报告 → 多行文本 |
| `chineseNetworkError(_:)` | 114 | URLError → 中文原因 |
| `FuzzyMatcher.match` | 37 | 贪心定位 + 反向收紧 + `rate` 评分；query > 32 字退化为子串直查 |
| `FuzzyMatcher.isMatch` | 76 | 布尔版 |
| `rate(indices:original:)` | 82 | 整型评分（连续 +8、词边界 +14/+10、靠前 +8、gap −min(gap,8)） |

**散文：`compress`（33–80）**
`maxDimension > 0` 走 `CGImageSourceCreateThumbnailAtIndex`（`kCGImageSourceThumbnailMaxPixelSize`），这是**唯一**能避免整图解码到内存的路径；`maxDimension <= 0` 会 `CreateImageAtIndex` 全解码（大图内存峰值高）。输出固定写到 `AppDirectories.sub("toolbox")`，**不覆盖原文件**——工具语义是"另存压缩版"，与原作 TinyPNG 一致。

### 3.10 `Toolbox/SearchSectionView.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `SearchHookRegistry.register` | 63 | 追加检索源（锁内） |
| `SearchHookRegistry.search` | 69 | `withTaskGroup` 并发汇总（空查询直接返回） |
| `ToolboxSearchSource.register` | 90 | 注册工具检索源（`/` 前缀 = 工具模式） |
| `ToolboxSearchSource.item(for:match:)` | 115 | 工具 → 结果行 |
| `FileSearchSource.search` | 184 | mdfind 预过滤 → 精排（文件名 2 倍权重）→ 深度/字母序稳定排序 |
| `fuzzySpotlightPattern` | 218 | 字符间插 `*` |
| `runMdfind` | 226 | 起 `/usr/bin/mdfind`，读满 512KB 或 EOF 即 `terminate` |
| `WebResultScraper.supportsResultList` | 284 | 仅 bing/duckduckgo/google |
| `WebResultScraper.searchURL` | 289 | DDG 用 html 端点、Google 加 `num=10&pws=0` |
| `ensureWebView` | 298 | 单例 `WKWebView(nonPersistent)` |
| `WebResultScraper.fetchResults` | 309 | 加载 + 注入 JS 提取结果 |
| `resolveURL` | 370 | 相对/跳转链 URL 解析 |
| `webView(didFinish/didFail)` | 390/398 | 续体唤醒 + 超时标志 |
| `listContentHeight` PreferenceKey | 622 | 测量结果列表高度做展开动画 |
| `categoryHeader` | 711 | 分类头（眼睛开关） |
| `webCategory` / `webResultArea` | 774/832 | 网页分类视图 / 结果/预览切换 |
| `matches(_:)` | 1004 | 剪贴板类型筛选判定 |
| `filterChips` | 1066 | 通用筛选 chip 行 |
| `clipboardCategory` | 1088 | 剪贴板历史分类（内存模糊匹配） |
| `clipboardIcon(_:)` | 1172 | 类型 → SF Symbol |
| `fileIcon(for:)` | 1193 | 走 `FileTypeIconProvider` |
| `filesCategory` | 1218 | 文件结果分类 |
| `toolCategory` | 1302 | 工具结果分类 |
| `highlighted(_:match:size:)` | 1365 | 按命中下标做 accent 高亮 |
| `performWebSearch` | 1400 | 打开引擎 URL + 埋点 `searchExecute`/`webSearchOpen` + 可选清空 |
| `clearInput` | 1414 | 清空 11 个状态 |
| `fetchWebResults` | 1428 | 后台抓取 + `generation` 防串台 |
| `scheduleSearch` | 1443 | 250ms 防抖 → 并发检索 + 文件检索（`Task.detached(.utility)`）→ 提交 + 触发网页抓取 |
| `WebPreviewRepresentable.makeNSView/updateNSView/dismantleNSView` | 1485/1495/1501 | 内嵌预览（nonPersistent，切换 URL 重载，销毁时 `stopLoading`） |

**散文：`runMdfind`（226–255）**
`Process` + `Pipe`，**读满 512KB 或 EOF 才 `terminate`**（单字符查询会命中十万级文件）。`pattern` 只转义 `\` 和 `"`——`*`、`?`、`[` 未转义，但它们是**故意**保留的通配（`fuzzySpotlightPattern` 生成）。若用户输入含 `"` 之外的 Spotlight 语法字符（如 `(`）会改变查询语义，最坏情况是 mdfind 语法错误返回空（不致崩）。`process.waitUntilExit()` 在**主线程**调用（`search()` 由 `Task.detached` 调用，所以实际在后台）。

**散文：`scheduleSearch`（1443–1477）**
`generation` 是防串台的唯一机制：每次输入 +1，并在**三个 await 点之后**各比对一次。任何新增的异步阶段都必须带上同样的 `guard current == generation`，否则快速输入会出现"旧结果覆盖新结果"。

### 3.11 `Toolbox/CommandPalette.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `CommandCatalog.build` | 51 | `@MainActor` 构建 ~48 条命令（截图/监测/开关/设置页/工具） |
| `CommandPaletteController.toggle` | 204 | 可见则关，否则 show |
| `show` | 213 | 新建 panel + 居中偏上 + 前置 |
| `windowWillClose` | 222 | 清引用 |
| `CommandPalettePanel.init` | 232 | 660×470 浮动 panel + `NSHostingView` |
| `centerInScreen` | 255 | visibleFrame 12% 处居中 |
| `CommandPaletteState.init` | 280 | 构建全量目录 |
| `refilter` | 286 | 模糊评分排序 + **id 序列比对后才发布** |
| `move(_:)` | 317 | 选中项 clamp 移动 |
| `executeSelected` | 322 | 先 dismiss 再执行 handler |
| `CommandPaletteView.body` | 336 | 输入框 + 列表 + 底部提示 |
| `keyHandler` | 405 | ↑↓/Esc 本地事件 |
| `CommandRowView.body` | 424 | 单行（图标/标题/副标题/开关态/类型标签） |
| `KeyEventCatcher.makeNSView/updateNSView` | 468/474 | 桥接 |
| `KeyEventCatcherView.viewDidMoveToWindow/deinit` | 483/496 | 装/摘本地 monitor（只处理本窗口事件） |

**⚠️ 已确认缺陷**：`keyHandler` 里 `case 0x7D: state.move(-1)`、`case 0x7E: state.move(1)`。macOS 虚拟键码 **0x7D = 下箭头、0x7E = 上箭头**，而列表是自上而下渲染 —— **上下方向键的行为是反的**（按下箭头选上一项）。修法：两行对调。

### 3.12 `Toolbox/ToolboxSectionView.swift` / `ToolRunnerWindow.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `ToolboxUIState.open` | 16 | 置 `activeToolID` + 开全局工具窗 |
| `ToolboxUIState.close` | 20 | 清状态 + 关窗 |
| `ToolboxSectionView.body` | 36 | 标题 + 齿轮（跳设置）+ 按分类网格 |
| `toolGrid(_:)` | 73 | 4 列 `LazyVGrid`，52pt 高按钮 |
| `ToolRunnerView.body` | 116 | 输入（文本/文件）+ 选项分段 + 执行 + 输出 |
| `outputArea(_:)` | 216 | 图片/文本/备注 + 复制/存条目按钮 |
| `run()` | 259 | 置运行态 → `ToolRegistry.run` → 主线程赋值 + 默认行为 |
| `applyDefaultAction` | 271 | 按设置自动复制或存为条目 |
| `copyText` / `copyImage` | 283/291 | 写 `NSPasteboard` |
| `saveToClipboard` | 301 | 走 `ToolboxEventBus` |
| `chooseFile` | 306 | `NSOpenPanel`（仅图片） |
| `ToolRunnerWindowController.show(toolID:)` | 28 | 未注册则警告；有窗则换内容；否则建 480×560 可缩放窗 |
| `close` / `windowWillClose` | 61/66 | 关窗 + 复位 `activeToolID` |
| `installContent(tool:in:)` | 73 | `ToolRunnerView` + `frsetThemeChrome()` + `NSHostingView` |

**散文**：`ToolRunnerWindow` 的存在理由写在文件头（2026-10-20 用户实障）：工具面板原是 `ToolboxSectionView` 的 `.sheet`，但主面板 homePage **只渲染 search/calendar/clipboard 三个区段**，"tools" 区段不挂载 → 搜索/命令面板/快捷键点工具时 sheet 无宿主 → 看起来"点了没反应"。**不要把它改回 sheet。**

### 3.13 `Toolbox/ShortcutManager.swift` / `ShortcutRecorder.swift` / `ToolShortcutStore.swift` / `DoubleTapShortcut.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `ShortcutManager.installEventHandler` | 47 | 装 Carbon `kEventHotKeyPressed` 处理器（无捕获闭包 → C 函数指针） |
| `handleCarbonEvent` | 57 | 校验 signature `'FRST'` → 反查 definition → **回主线程**执行 |
| `register(_:)` | 85 | 冲突检测 → `RegisterEventHotKey` → 记映射/清失败原因 |
| `unregister(id:)` | 116 | 锁内注销 |
| `bind(_:)` | 123 | 已存在 → `reconfigure`，否则 `register` |
| `reconfigure` | 138 | **新注册成功才撤旧**（失败保留原绑定） |
| `unregisterLocked` | 180 | 撤热键 + 清两表 + 清失败原因 |
| `all` / `failureReason` | 195/200 | 列表（按 title 排序）/ 失败原因 |
| `conflictsLocked` | 206 | keyCode + modifiers 全等 |
| `modifierText` / `keyText` / `display` | 213/223/286 | 键名展示（⌘⇧T 等） |
| `carbonModifiers(from:)` | 295 | NSEvent flags → Carbon 掩码 |
| `ShortcutRegistry.register/unregister` | 308/318 | 静态门面（转发 `shared`） |
| `ShortcutCapture.toggle/start/stop` | 19/21/40 | 本地 `keyDown` monitor；Esc 取消；强修饰键必需；录制期吞键 |
| `ShortcutRecorderButton.body` | 64 | 录入按钮 + 右键清除 |
| `ToolShortcutStore.registrationID` | 27 | `"tool.<id>"` 命名空间 |
| `binding(for:)` / `all` | 44/50 | 持久化读取 |
| `set(toolID:keyCode:modifiers:)` | 61 | 强修饰键校验 → 注册成功才落盘 → 失败分类返回 |
| `clear(toolID:)` | 88 | 注销 + 删键 |
| `restoreAll` | 97 | 启动恢复（工具已被删则跳过） |
| `DoubleTapShortcutCenter.setHandlers/bind/unbind/unbindAll/modifier` | 95–119 | 绑定表 + 监听生命周期 |
| `startMonitoringIfNeeded/stopMonitoringIfNeeded` | 128/142 | global + local `flagsChanged` 双监听 |
| `handleFlags(_:)` | 153 | 只取"按下沿"；0.3s 内同键二次按下触发 |

### 3.14 其余 Toolbox 文件

| 函数 | 行 | 说明 |
|---|---:|---|
| `IPAddressService.*`（5） | 28–114 | 见 §3.9 |
| `CalendarService.requestAccessIfNeeded` | 26 | 已授权/未决定/被拒三分支 |
| `isGranted(rawValue:)` | 51 | `>= authorized`（兼容 fullAccess/writeOnly） |
| `update(authorized:hint:)` | 56 | 发布状态 + 告警日志 |
| `refresh` | 64 | 手动重查授权 |
| `events(on:)` / `todayEvents` / `weekEvents` | 72/78/81 | 日/今/本周（周一起） |
| `events(from:to:)` | 88 | 未授权返回空；按开始时间排序 |
| `monthDays(for:)` | 105 | 42 格月视图（周日起点，zh_CN） |
| `monthTitle(_:)` | 171 | "2026年10月" |
| `CalendarSectionView.dayCell(row:column:)` | 177 | 单格（今天/周末/节日/事件点） |
| `installScrollMonitor` / `removeScrollMonitor` | 230/250 | 滚动切月（滚轮事件监听） |
| `isFestivalDay` / `shift(_:)` / `reload()` | 290/298/304 | 节日判定 / 月偏移 / 重载 |
| `CalendarDay.shortName(_:)` | 322 | 节日名缩写 |
| `LunarDate` 相关（`lunarDate`/`solarTerm`/`lunarFestival`） | 131/189/210 | 农历换算 / 24 节气 / 农历节日 |
| `HolidayManager.holiday/festival/components` | 48/56/70 | 法定假日 / 公历节日 / 取年月日 |
| `AuxiliaryWindowKind.title` | 18 | 类型中文名 |
| `WindowManager.register/unregister` | 51/62 | 弱引用登记（同窗去重） |
| `allWindows` / `windows(of:)` / `count(of:)` | 68/80/105 | 快照（先 prune） |
| `closeAll(kind:)` | 85 | 主线程逐个 `close` + 清条目 |
| `pruneLocked` | 108 | 清已释放条目 |
| `ToolSettingsPane.body` / `toolRow(_:)` | 4/81 | 工具开关列表 + 默认输出行为 |
| `ShortcutSettingsPane.body` / `pair` / `staticRow` / `shortcutRow` | 4/50/60/75 | 快捷键页（成对展示、静态行、录入行） |
| `DoubleTapSwitch.body` | 142 | 双击开关（含修饰键下拉） |
| `DoubleTapTipPanel.show/dismiss/position` | 20/80/85 | 权限提示小窗 |

---

## 4. 关键数据流

### 4.1 菜单栏状态项生命周期

```
StatusBarModule.start                          [StatusBarModule.swift:10]
 └ StatusBarController.install                 [:109]
    ├ installMainItem（清 Preferred Position → 建项 → 模板图 → ToastAnchor.button → StatsBarEngine.syncMainItem）
    ├ syncStatusItems → rebuild（前 6 项 + 「⋯」）→ makeStatusItem
    │    └ restoreStatusItemPosition（创建前写回系统位置键）
    ├ startTimers：1s refreshTitles / 5s syncStatusItems
    └ observePreferences：defaults 变化 → 250ms 合并 → syncStatusItems
```

### 4.2 监测状态项 → popover

```
StatusItemRegistry（Monitor 模块注册 descriptor）
 └ syncStatusItems（5s 或偏好变化）→ rebuild → makeStatusItem
    └ 点击 → statusItemClicked → handle(descriptor:anchor:)
       ├ onTap?()                                  （如打开监测窗）
       ├ popover?() → showPopover（340×620, transient, setSettingsActive(true)）
       └ 回落 → ServiceLocator.panel?.toggle(atAnchor: button.window?.frame)
popoverDidClose → MonitorSampler.setSettingsActive(false)
```

### 4.3 搜索（输入 → 四类结果）

```
TextField.onChange(query) → scheduleSearch()          [SearchSectionView:1443]
 ├ generation += 1（防串台）
 ├ 250ms 防抖
 ├ SearchHookRegistry.search(text)   ── 并发：ToolboxSearchSource（FuzzyMatcher）
 ├ Task.detached(.utility) FileSearchSource.search   ── /usr/bin/mdfind + FuzzyMatcher 精排
 └ 提交 → previewQuery = trimmed → 若引擎支持列表 → fetchWebResults()
      └ WebResultScraper（WKWebView nonPersistent + JS 提取）→ webResults
```

### 4.4 工具执行（任一入口）

```
ToolboxUIState.open(id)  ← 工具格 / 搜索结果 / 命令面板 / 工具热键
 └ ToolRunnerWindowController.show(toolID:)           [ToolRunnerWindow:28]
    └ ToolRunnerView → run() → ToolRegistry.run
       ├ tool.execute(input, options)                 （async）
       ├ recordInvocation → tool_invocations + bumpStat("tool_count")
       └ applyDefaultAction：copy（写剪贴板）或 save（ToolboxEventBus → 剪贴板条目）
```

### 4.5 统计窗

```
StatisticsWindowController.openStatistics           [:66]
 ├ installContent（重建 NSHostingView，延后一拍）
 ├ showWindow + center + 埋点 statistics_open
 └ StatisticsChartsView.onAppear → loadData
    └ 后台 autoreleasepool：StatisticsManager Q1/Q2/Q3/Q4/Q5 + clipboard COUNT(*)
       └ 主线程赋值 7 个 @Stored + 一次性入场动画
```

---

## 5. 资源清单

### 定时器
| 位置 | 周期 | 门控 |
|---|---|---|
| `StatusBarController.refreshTimer` | 1s（`.common`） | `didInstall` |
| `StatusBarController.syncTimer` | 5s（`.common`） | 同上 |
| `MenuBarIconStyleApplier.dateTimer` | 60s | 仅 `date` 样式 |
| `MenuBarIconStyleApplier.cpuTimer` | 2s | 仅 `fan` 样式 |
| `RoutedLayerView` 旋转 | CABasicAnimation 无限（0.8–4.0s/圈） | 仅 `fan` |
| `SearchSectionView` 防抖 | 250ms | 每次输入重置 |
| `ActivityHeatmapView` hover tooltip | 0.4s 延时 | 悬停中 |

### 线程 / 队列
- 主线程：全部 AppKit 状态项操作、SwiftUI、popover、Carbon handler 分发（统一 `DispatchQueue.main.async`）。
- `DispatchQueue.global(.userInitiated)`：统计查询（`autoreleasepool`）。
- `Task.detached(.utility)`：`FileSearchSource.search`（mdfind）。
- `Task`（继承 MainActor）：`scheduleSearch` / `fetchWebResults`。
- `WKWebView` 内部线程：网页抓取与预览。

### 子进程
| 命令 | 位置 | 说明 |
|---|---|---|
| `/usr/bin/mdfind "kMDItemFSName == \"*q*\"cd"` | SearchSectionView:233 | 文件搜索，512KB 封顶后 `terminate` |

### 文件 / 目录
- `~/Library/Application Support/FrsetNext/icons/<ext>.png`（`FileTypeIconProvider`）
- `~/Library/Application Support/FrsetNext/toolbox/compressed-<ts>.png|jpg`（`ImageCompressor`）
- `clipboard.sqlite` 的 `file_type_icons` / `tool_invocations` 表
- `statistics.sqlite` 的 `usage_daily_metrics`

### UserDefaults 键
- 状态项：`NSStatusItem Preferred Position frsetnext.<id>`、`NSStatusItem Restore Position frsetnext.<id>`、`frsetnext.main`
- 图标样式：`menu-bar-icon-{logo,fan,date,custom}`、`menu-bar-icon-custom-symbol`、`revealCustomMenuBarIconOption`
- 搜索分类：`search.category.{web,clipboard,files}`
- 工具：`toolbox.tool.<id>.enabled`、`toolbox.defaultAction`、`toolbox.toolShortcuts`
- 快捷键：`shortcuts.bindings`、`shortcuts.doubleTap`、`shortcuts.doubleTapTipSeen`（AppBootstrap 侧）
- 探针：`probe.openTool`、`FRSET_SEARCH_PROBE`、`FRSET_PERF_PROBE`

### 通知
- 消费：`frset.openStatistics`、`.frsetFocusPanelSearch`、`UserDefaults.didChangeNotification`、`LanguageManager.languageDidChange`、`FrsetRunCatIconChanged`
- 发出：`.frsetFocusPanelSearch`（⌘K 聚焦搜索）

---

## 6. 不变量与陷阱

1. **状态项同步必须防重入**（`isSyncing`）+ 变更 `isVisible` 后必须**异步**再同步。否则 `refreshTitles ↔ syncStatusItems` 递归到栈溢出（已发生一次 EXC_BAD_ACCESS）。
2. **状态项 `autosaveName` 必须带 `frsetnext.` 前缀**。与原版 Frset.app 同名时系统会拒绝对后注册项布局（frame=(0,0,w,0)，菜单栏不显示）。
3. **移除状态项前必须备份 `NSStatusItem Preferred Position`**（系统会删该键），创建前写回。否则重建项落到默认位、互相重叠。
4. **双层项：长度 = 视图宽 + `button.image = NSImage()` 空图占位 + 不设 title**。任一条漏掉 → 子视图被裁 / 不渲染 / 与 title 重叠。
5. **动态项上限 6 + 「⋯」溢出**，且创建顺序要**反向**（系统向左插入）。
6. **`StatisticsWindowController` 内容必须延后一个 runloop 装载**，窗口尺寸必须钉死（min == max）。否则 `_postWindowNeedsUpdateConstraints` 异常。
7. **热力图常量互相咬合**：60 列 × 8pt + 59 × 3pt = 657 ≈ 内容 660。改任一常量要重算。
8. **`MainActor` 的统计查询必须在后台 + `autoreleasepool`**；`activityTotals` 构造要求 day 唯一。
9. **`@Stored` 不能替换成 `@State`**（本机缺 SwiftUIMacros，编译失败）。
10. **工具面板必须是独立 `NSWindow`**，不能回退成 `.sheet`（主面板不挂载 tools 区段 → sheet 无宿主）。
11. **热键重绑必须"先注册新的成功、再撤旧的"**（`reconfigure` 语义）。反过来会出现"改绑冲突 → 旧热键也没了"。
12. **`RegisterEventHotKey` 的冲突检测只看 keyCode + modifiers 全等**，不做 ⌘ vs ⌃⌘ 归一化；`failureReason` 是 UI 唯一能拿到的原因来源。
13. **快捷键录制期必须吞掉按键**（返回 nil），否则会同时触发系统快捷键。
14. **`DoubleTapShortcutCenter` 需要辅助功能权限**；未授权时 global monitor 收不到事件（代码"仍尝试"，但实际只有 app 在前台时 local monitor 生效）。
15. **`FileSearchSource.runMdfind` 必须封顶读取**（512KB）。单字符查询不加会搬十万条结果。
16. **`scheduleSearch` 的每一处 await 后都要 `guard current == generation`**。
17. **`ToolRegistry.run` 必定埋点**；新增执行路径必须走 `run`，直接调 `tool.execute` 会漏 `tool_invocations` 与 `tool_count`。

---

## 7. 重复实现 / 死代码 / 风险

### 已确认缺陷

- **命令面板上下键反向**（CommandPalette.swift:410-411）：`0x7D`（↓）调 `move(-1)`、`0x7E`（↑）调 `move(1)`。列表自上而下渲染，因此方向键行为与直觉相反。
- **`MenuBarIconStyleApplier` 监听全量 `UserDefaults.didChangeNotification`**（:374）。任何写 defaults 的模块（窗口尺寸、个性化 15 键、位置键…）都会触发一次 `apply()`。虽然有"未变则跳过"守卫，但**守卫之前**已经做了 `MenuBarIconStyleStore.current`（4 次 defaults 读）+ `customSymbol` 读。窗口拖拽尺寸时会高频触发。
- **`StatusBarController.verifyLayout` 在每次 `refreshTitles` 都跑**（1s 一次，遍历全部项 + 拼字符串 key）。虽然只有变化才写日志，但 key 拼接本身每帧分配。
- **`presentStatsPopover` 用 `Theme.panelWidth`（400×fontScale）作最小宽**，而主面板 popover 是 340 —— 两个 popover 宽度不一致，用户会看到"同一位置弹出两种宽度"。

### 重复实现

- **两套"状态项"体系并存**：`StatusBarController` 的动态项（`StatusItemRegistry`）+ STATS 引擎的合并条/独立项（C 层 `g_ownItems`）。两者都能在菜单栏建项，**位置校准只认 STATS 侧**，动态项不参与保邻。新增监控类 UI 必须明确归哪一套（归 STATS 才能被"唯一一套"护栏覆盖）。
- **两套 CPU 负载采样**：`MenuBarIconStyle.SystemCPULoad`（Swift，2s）与 `frset_stats_data.c:frset_cpu_sample`（C，0.5s）。数值口径不同（Swift 侧只算 user+system / total；C 侧算 (user+system+nice)/total）。
- **两套模糊匹配**：`FuzzyMatcher`（文件/工具/命令面板）与列表内的 `localizedCaseInsensitiveContains` 类简单匹配（剪贴板历史分类）。
- **两套快捷键注册入口**：`AppBootstrap.registerDefaultHotkeys`（默认表）与 `ToolShortcutStore.restoreAll`（工具自定义），二者都调 `ShortcutRegistry.register`，冲突时**后注册者失败**且失败原因只在 `failureReason` 里（UI 不一定展示）。

### 死代码 / 弱代码

- **`StatusBarController.overflowItemAction`**：溢出项的菜单由 `menuNeedsUpdate` 动态建，`representedObject = d.id`，只有"溢出项存在且某项被隐藏"时才用到；正常 6 项以内永不触发。
- **`MenuBarTwoLineView.widthHandler`**：声明并调用（`refreshTitles` 里 `view.widthHandler?()`），但**全工程没有任何地方赋值** → 永远 nil。
- **`ToolboxSectionView` 的 `@Stored refreshTick` + `.id(refreshTick)`**：只在 `onAppear` +1，用来在返回主页时强制重建；配合 `ToolRegistry.grouped()` 每次 body 重算，实际是"每次出现重建整棵树"的重手段。
- **`SearchSectionView` 的三个探针**（`FRSET_SEARCH_PROBE`、`probe.openTool`、`FRSET_PERF_PROBE`）散落在 `onAppear` 与各视图里，生产环境零开销但属于长期调试残留。
- **`WindowManager`** 目前只有 `closeAll` 有实际调用价值，`count(of:)` / `windows(of:)` 无消费者（设置页/调试声明未落地）。

### 风险

- **P1 `StatisticsRootView` 的 `@Stored` 大数组**：`last30DayBreakdowns` 是元组数组，每次 `loadData` 整体替换会触发 `ObservableObject` 全量重算（5 张卡 + 柱图 + 热力图）。窗口每次 `openStatistics` 都重建内容视图 → 每次打开都跑一次全量查询 + 全量重绘。
- **P1 `runMdfind` 的 `waitUntilExit` + `terminate`**：`terminate()` 后仍 `waitUntilExit()`，若 mdfind 因 Spotlight 索引损坏卡住，会阻塞后台线程（不阻塞主线程，因为调用方是 `Task.detached`）。
- **P2 `FileTypeIconProvider.diskURL` 的字符白名单冲突**（`a/b` 与 `a_b` 同文件）。
- **P2 `ShortcutManager.conflictsLocked` 无归一化**：`⌘T` 与 `⌃⌘T` 被判为不同，但系统层面二者可同时注册且后者优先——用户会看到"两个都能注册，只有一个生效"。
- **P2 `CommandPaletteCatalog.build()` 在 `@MainActor` 且每次都读 `ToolRegistry`/`SettingsPaneRegistry`（都要 `NSLock`）**：面板每次打开几十次锁，量级很小但属于"UI 路径取全局锁"的模式，未来注册表变热会放大。
- **P3 `StatisticsWindowController` 每次打开重建 `NSHostingView`**：窗口复用但内容重建，`onAppear` 每次都跑 5 条 SQL。
