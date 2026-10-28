# B4 — Settings / Onboarding / Manual / Audio

> 范围：`Sources/Features/Settings/`（13 个）+ `Onboarding/`（6 个）+ `Manual/`（2 个）+ `Audio/`（1 个），共 **22** 个 `.swift`，合计 **6901** 行。整文件逐行读完。
> 符号核对：CSV 中四个目录声明 **658** 条（Settings 141、Onboarding 51、Manual 41、Audio 18 之外的其余为 struct/enum/class 声明）；其中 `func` **162**（Settings 98 / Onboarding 28 / Manual 24 / Audio 12）。
> 本报告列出 **162 个 CSV func** + 补齐 CSV 漏记的多行签名函数与 `init`（`StatisticsSettingsPane.body`、`MonitorWidgetsPane.body`、`SettingsUIState.init`、`PreferenceValue.init?(defaultsValue:)`/`init(from:)`/`encode(to:)`、`PermissionCenter.init`、`AudioMixerController.init`、`ManualDocument.Doc` 构造等），表内共 **178** 行。

---

## 1. 文件清单

| 路径 | 行数 | 一句话职责 |
|---|---|---|
| `Settings/SettingsModule.swift` | 39 | `AppModule` 入口：注册 4 个基础页签、注入 `ServiceLocator.settings`、应用外观 |
| `Settings/SettingsWindowController.swift` | 169 | 设置窗单例 + `SettingsUIState`（旧 pane id → 侧边栏映射）+ `SettingsWindow`（Esc 关） |
| `Settings/SettingsRootView.swift` | 182 | 根视图：186 侧边栏 + 内容区分发（7 类 / 7 模块 / 监测设置 / 部件设置 / 手册）+ 分段子页 |
| `Settings/SettingsSidebarView.swift` | 224 | 大侧边栏：品牌区 / 主页分组 / 性能监测分组 / 页脚（使用手册 + 版本） |
| `Settings/SettingsComponents.swift` | 95 | 通用组件：`SettingsRow` / `SettingsSection` / `SettingsGroupBox` / `SettingsDivider` |
| `Settings/SettingsPanes.swift` | 732 | 通用页（启动/外观/语言/个性化/菜单栏/剪贴板/忽略应用）+ 关于页 + 标签管理 sheet |
| `Settings/PersonalizationSettingsPane.swift` | 320 | 个性化 14 行：强调色/字号/密度/圆角/动画/宽度/材质/徽章/缩略图/通知条/分隔线/色相/背景图/重置 |
| `Settings/MonitorWidgetsPane.swift` | 867 | 部件设置：布局（合并/间距/分隔线）+ 7 模块 × 形态 × 选项 + 维护（重置/导入 Stats） |
| `Settings/StatisticsSettingsPane.swift` | 633 | 数据页：用量图表 + 关键指标 + 功能明细 + 评分口径 + `.frsetconfig` 导出/导入 |
| `Settings/SearchSettingsPane.swift` | 509 | 搜索页：首页分类开关 + 引擎全量表（增删改/上下移）+ 搜索栏拖拽排序 + 重置 |
| `Settings/DiagnosticsExporter.swift` | 189 | 诊断包导出（usage.csv / performance.csv / logs / system.txt → ditto zip） |
| `Settings/WidgetSettingsSelfTest.swift` | 318 | `FRSET_WIDGET_SELFTEST=1` 全量自测（写入→读回→覆盖断言→还原） |
| `Settings/AppearanceManager.swift` | 77 | 外观四档（system/light/dark/midnight）→ `NSApp.appearance` + `AppearanceState` 单向同步 |
| `Onboarding/PermissionCenter.swift` | 292 | 四类权限（屏幕录制/辅助功能/麦克风/日历）状态探测、请求、跳系统设置 |
| `Onboarding/WelcomeWindowController.swift` | 110 | 欢迎窗（760×620）单例 + 首启判定 + Esc「稍后再说」 |
| `Onboarding/WelcomeView.swift` | 236 | 欢迎窗内容：Hero + 8 能力卡 + 12 快捷键 + 权限横幅 + 页脚 |
| `Onboarding/PermissionGuideWindowController.swift` | 90 | 权限引导窗（660×600）单例 + Esc |
| `Onboarding/PermissionGuideView.swift` | 220 | 权限引导内容：4 张卡（purpose/features/状态/动作）+ 进度胶囊 + 页脚 |
| `Onboarding/WhatsNew.swift` | 282 | 「本次更新」浮层（400×500）+ 目录/分组 + 每版一次记忆 |
| `Manual/ManualDocument.swift` | 370 | 手册 Markdown 解析器（标题树 / 块 / 表格 / 图片 / 代码）+ 索引与平铺 |
| `Manual/ManualView.swift` | 618 | 交互式手册：左侧树（展开/搜索）+ 右侧内容（面包屑/小节链/图片放大/上下节） |
| `Audio/AudioMixer.swift` | 329 | CoreAudio 混音器：系统音量/静音/设备切换/有声 App 监视/本进程 bypass + 设置页 |

---

## 2. 类型逐个说明

### 2.1 `SettingsModule`（enum, `AppModule`）

- `start()`：注册 `general` / `search` / `statistics` / `about` 四个 `SettingsPaneDescriptor`（其余页签由各模块自己注册：monitor / clipboard / transfer / tools / shortcuts / capture / ai）；`ServiceLocator.settings = SettingsWindowController.shared`；`AppearanceManager.shared.applyCurrent()`。
- **注释即分工裁决**：「快捷键」页签由 Toolbox 注册（消费 `ShortcutRegistry` 真实数据），本模块不自带简化注册表。

### 2.2 `SettingsWindowController` / `SettingsUIState` / `SettingsWindow`

- `SettingsUIState`：`selectedPaneID`（旧 id 字符串）、`selection: SettingsSidebarSelection`、`searchAISub`、`toolingSub`。`selectPane(_:)` 做 **16 条 id → 侧边栏项** 的映射（含 `monitor.<module>` 前缀兜底）。
- `SettingsWindow`：`performKeyEquivalent` 拦 Esc（keyCode 53）→ `close()`。
- `SettingsWindowController`：`shared` 单例，`window: SettingsWindow?` 复用，`open(pane:)` 打点 + `ensureWindow` + 映射 + `makeKeyAndOrderFront` + `RenderProbe`。
- **窗口纪律（本文件是全工程最危险的一段注释）**
  1. 窗口 940×620，`contentMinSize == contentMaxSize == 940×620`，miniaturize/zoom 隐藏。
  2. **不用 `setFrameAutosaveName`**：autosave 会在 display cycle 内用旧帧覆盖目标尺寸，与强制尺寸构成约束更新循环 → `NSWindow._postWindowNeedsUpdateConstraints` 异常（2026-10-16 崩溃实测）。
  3. **SwiftUI 内容延后一个 runloop 装载**：同 cycle 内建窗 + NSHostingView 首次布局 → AppKit 在 updateConstraints observer 内收到次级请求即抛 NSException（三组崩溃栈实证）。占位 `NSView()` 避免"无内容窗口"。
  4. 根视图 `frame(width:940,height:620)` 必须与 contentRect 一致；`sizingOptions = []`、`safeAreaRegions = []`、`ignoresSafeArea()`。

### 2.3 `SettingsRootView` / `SettingsSidebarView` / `SettingsComponents`

- `SettingsRootView`：HStack(侧边栏 | 0.5pt 分隔 | VStack(header 56 | 0.5pt | content))；根 `.frame(940×620)`；`onChange(selection)` 打面包屑（卡死定位）。
- 内容分发：`.category` 7 类（general/clipboard/transfer/searchAI/tooling/statistics/about）、`.monitorModule`（`StatsModulePage`）、`.monitorSettings`、`.monitorWidgets`（`MonitorWidgetsPane`）、`.manual`（`ManualPaneView`）。
- `segmentedPage(selection:tabs:)`：分段胶囊 + 内容滚动（搜索与 AI 2 段 / 工具与快捷键 3 段）。
- `SettingsSidebarView`：宽 `Theme.settingsSidebarWidth`（186）；`monitorModules` 7 项（无 power）；about 单独置底（v153）；页脚常驻「使用手册」（v88）。
- `SettingsComponents`：四个极简容器（`SettingsRow` 带可选图标；`SettingsSection` 两个 init；`SettingsGroupBox`；`SettingsDivider` 左缩进 38）。

### 2.4 `GeneralSettingsPane` / `AboutSettingsPane` / `TagManagementSheet` / `IgnoredAppsEditor`

- `GeneralSettingsPane`：`compact` 参数（v40 面板内嵌模式）——本版由设置窗使用（compact=false，标题列 190pt）。
  - `@AppStorage`：`launchAtLogin`、`showSystemStatus`、`showCalendar`、`automaticScreenshotOCREnabled`、`panelTransferDock`。
  - `@AppStorage` 菜单栏图标四布尔键 + 自定义 symbol + reveal 开关（**跨模块只按 defaults 键名读写，不引用 StatusBar 类型**）。
  - 文案全走 `L10n.t(...)`，语言切换靠 `l10nVersion` 自增重绘。
  - 探针 `probe.settingsMenuBarFirst`（把菜单栏区置顶便于截屏）。
- `AboutSettingsPane`：图标 + "Frset" + `v1.0.0`（v90 回退，不再显示 1.3.12）+ 「导出使用记录」+「检查更新」+ 「更新源」TextField + 版权行。`displayVersion = "1.0.0"`；5 个 URL 常量全部指向 GitHub 占位（**当前未被使用**，外链已移除）。
- `TagManagementSheet`：480×360，列表 + 行内新建 + 删除（`TagStore`）。
- `IgnoredAppsEditor`：`revision` 驱动重绘（`Preferences` 无观察者）；「+ 添加当前前台应用」用 `NSWorkspace.frontmostApplication.bundleIdentifier`。

### 2.5 `PersonalizationSettingsView`

14 行设置，全部直接绑定 `Personalization.shared`（`@Published` + persist 即改即生效）：强调色（6 预设 + ColorPicker + 跟随系统）/ 字号 4 档 / 密度 / 圆角 3 档 / 打开动画 / 面板宽度 3 档（写 `panelWidth` + post `didChangeNotification`）/ 材质 / 来源徽章 / 缩略图 4 档 / 通知条（时长 + 定位）/ 合并条分隔线（裸键 `CombinedModules_separator`）/ Midnight 色相 / 背景图（`NSOpenPanel.begin` 异步）/ 恢复默认。

### 2.6 `MonitorWidgetsPane` ★本目录最复杂的视图

- **核心纪律（v84）**：所有 `FSBar*` 查询结果在 `onAppear`/`bump` 时**一次性缓存**到 5 个 `@Stored` 字典，重绘期零 C 调用。原因记录：原实现每 `body` 求值调 ~50+ 次 C 函数（8 模块 × 若干形态的 `FSBarAllModules/EnabledForms/FormsForModule/ModuleName/FormName`），与 `FSBarReloadFromStore` 的状态项重建叠加 → "设置页随便点两下就卡死"。
- `OptionSpec`（4 种 kind：toggle/menu/color/slider）+ `OptionGroup`。`optionGroups(module:form:)` 是**与引擎设置窗逐项对齐的静态表**（13 种形态）。
- `ColorKeyControl`：预设色 30 项 + `custom:#RRGGBB`；`presets` 静态表；hex↔Color 互转。
- `FormPreviewCache`：`NSCache(32)`，键 `module/form/dark`。
- **不变量**：任何写配置的 setter 都必须 `FSBarCfgSet/GlobalSet` → `FSBarReloadFromStore()` → `bump()`（bump = `reloadCache()` + `revision += 1`）。漏 `FSBarReloadFromStore` 会导致引擎不重建状态项；漏 `bump` 则 UI 不刷新。

### 2.7 `StatisticsSettingsPane` / `FrsetConfigFile` / `PreferenceValue`

- `FrsetConfigFile`：`format`（"frsetconfig"）/ `version`（1）/ `exportedAt` / `preferences: [String: PreferenceValue]` / `statistics: [(day,event,count)]`。
- `PreferenceValue`：6 case 枚举 + **自定义 Codable**（`{type, value}` 判别）；`init?(defaultsValue:)` 用 `NSNumber.objCType` 区分 bool/int/double（注释：直接 `as? Bool` 会把整数 1/0 吃掉）。
- 页结构：用量图表（`StatisticsChartsView`，`chartsEpoch` 强制重建）→ 关键指标（5 行）→ 功能明细（19 行）→ 评分 → 导出/导入 → 说明。
- **不变量**
  1. 统计导入必须走 `importMerge` 的 `MAX(旧,新,0)`（不削减）。
  2. 偏好导入必须过白名单（`exportablePreferenceKeys` 40 项），未命中者写 `settings.invalid-<key>` 标记并回报。
  3. `SearchServiceManager.reloadFromDefaults()` 必须回主线程（v126：`@Published` 后台写是未定义行为）。

### 2.8 `SearchSettingsPane` + `SearchBarReorderDelegate`

- 三块：首页分类开关（3 个 `@AppStorage`）、引擎全量表（列 Name/URL/More，行内 Menu：加入/移出搜索栏、上移/下移、编辑、删除、清空输入开关）、搜索栏列（拖拽排序 + 移除）。
- `validateEngineForm`：**三连校验**（仅字母数字 / 长度上限 / URL 必须含 `{query}` 且可解析）+ URL 查重（排除自身）。
- `SearchBarReorderDelegate`：`dropEntered` 里读**实时** order 与 draggingID → `move(IndexSet(from), from < to ? to+1 : to)`；`dropUpdated` 返回 `.move`；`performDrop` 清状态。

### 2.9 `DiagnosticsExporter` / `WidgetSettingsSelfTest` / `AppearanceManager`

- `DiagnosticsExporter`：`NSSavePanel`（主线程）→ 后台 `writeBundle`：拷贝 `logs/*.log` → `usage.csv`（`StatisticsManager.exportAll`）→ `performance.csv`（关键词过滤 + CSV 转义）→ `system.txt`（版本/macOS/内存/uptime/footprint/cpu time）→ `/usr/bin/ditto -c -k --sequesterRsrc --keepParent` 压缩。
- `WidgetSettingsSelfTest`：`FRSET_WIDGET_SELFTEST=1` → 5s 后跑；备份 plist 到 `/tmp` → 布局/模块/选项/维护三段 → `restore` 还原 → 报告写 `/tmp/frset_widget_selftest.txt`。**`expectedKeys` 是与引擎设置窗的权威键集合对照**（UI 少键=功能缺失，多键=写引擎不认识的配置）。
- `AppearanceManager`：`mode` 从 defaults 读；`apply` 写/删 `appearance` 键 → `applyNSAppearance()`（system→nil / light→aqua / dark+midnight→darkAqua）→ `AppearanceState.shared.isMidnight = isMidnight`。**`isMidnight` 必须从 `mode` 派生**（注释：反向转发会退化成自赋值，主题永远 false）。

### 2.10 Onboarding：`PermissionKind` / `PermissionStatus` / `PermissionCenter`

- `PermissionKind`（4 case）自带 `title/symbol/purpose/features/isCore/settingsFragment/settingsURL`。
- `PermissionStatus`（granted/denied/notDetermined/unsupported）带 `label/symbol/tint`。
- `PermissionCenter`：`@Published statuses` + `probingScreenRecording`；`refreshAll()` 走 `quickStatus`（**屏幕录制用 CGPreflight，可能假阴性**）；`probeScreenRecording()` 是**权威探测**（macOS 14+ `SCShareableContent`，能枚举到显示器才算授权）；`request(_:completion:)` 四路（CGRequestScreenCaptureAccess / AXIsProcessTrustedWithOptions / AVCaptureDevice.requestAccess / EKEventStore.requestAccess）。
- **不变量**：屏幕录制/辅助功能授权后系统**无回调**，只能靠 1.2s 延迟刷新 + `didBecomeActive` 重新探测。

### 2.11 Onboarding：三个窗口控制器

| 控制器 | 尺寸 | 关闭语义 |
|---|---|---|
| `WelcomeWindowController` | 760×620 | 「开始使用」写 `onboardingWelcomeSeenVersion`；Esc/叉号 **不写**（下次启动还弹） |
| `PermissionGuideWindowController` | 660×600 | Esc/稍后再见/完成都只 `orderOut`（无 seen 标记） |
| `WhatsNewWindowController` | 400×500 | 「知道了」/Esc/`performClose` **都写** `whatsNewLastSeenVersion` |

三者共享同一套建窗纪律：固定 `contentMinSize/MaxSize`、`applyOfficialChrome()`、`contentView = NSView()` 占位 + 下一 runloop 装 `NSHostingView`、`sizingOptions = []`、`safeAreaRegions = []`、隐藏 miniaturize/zoom、`attachOfficialRoundCloseButton()`。

### 2.12 Onboarding：`WhatsNewCatalog` / `WhatsNewStore` / `WelcomeView` / `PermissionGuideView` / `WhatsNewView`

- `WhatsNewCatalog`：`contentVersion = 1` + 9 条 entries + `grouped()`（按类别保序）。
- `WhatsNewStore`：`shouldShow` = `defaults.integer(key) < contentVersion`；`markSeen()` 写当前版本。
- `WelcomeView`：Hero + 2 组 4 卡（核心工作区 / 效率与互联）+ 12 条快捷键 + 权限横幅（`allCoreGranted` 驱动文案与颜色）+ 页脚（使用手册 / 开始使用）；`didBecomeActive` 时 `refreshAll`。
- `PermissionGuideView`：4 张 `PermissionCard`（状态图标/徽章/`FlowHStack` features/动作按钮四态）+ 进度胶囊 + 核心权限未齐时橙色提示。
- `WhatsNewView`：header（sparkles + 标题）+ 分组 section（类别色 + 圆点条目）+ 页脚（知道了 + "每版只显示一次"）。

### 2.13 Manual：`ManualNode` / `ManualBlock` / `ManualDocument`

- `ManualNode`：`id/title/level/blocks/children/searchText`（v128：解析期固化搜索文本）。
- `ManualBlock`（8 case）+ `id`（`divider` 用 `UUID()` → **每次求值 id 都变**，`Identifiable` 不稳定）+ `plainText`。
- `ManualDocument.Doc`：`roots/index/title/parentIndex/flatNodes`（后两者 v128 新增，查询 O(1)）。
- `load(bundle:)`：找不到资源时返回「手册未打包」单节点。
- `parse(_:)`：全局自增 id（v88 修「层级+序号」跨章撞 id）；`flush(into:)` 按 stack.last；`register` 递归建 index/parentIndex/flatNodes 并 `finalizeSearchText()`。
- `parseBlocks(_:)`：代码块/分隔线/图片/表格/引用/无序/有序/段落八类；3 个静态正则（v126 缓存）+ `firstMatch` 字典缓存（**无锁**）。

### 2.14 Manual：`ManualPaneView` 及子视图

- `ManualPaneView`：左侧 236pt 树（搜索框 + 展开/收起全部 + 节数 + 递归 `ManualTreeRow`）+ 右侧内容（面包屑 / 标题 / 本节目录 / 块渲染 / 上下节）。
- `searchIndex`：一次算出 `matched` 与 `visible`（含命中节点全部祖先），行过滤退化为 Set 查表（v128）。
- 子视图：`ManualTreeRow`（`DisclosureGroup` + 搜索时强制展开）、`ManualDisclosureStyle`、`FlowLinks`、`ManualBlockView`（8 种块）、`ManualImageView`（加载失败显示「截图待补」虚线框）、`ManualImageLoader`、`ZoomSheet`（960×700 sheet）、`ManualTableView`。

### 2.15 Audio：`AudioMixerController` / `AudioMixerPane`

- 文件头注释记录了 **公开 CoreAudio 的能力边界实测**：`'prs#'`（进程列表）、`'piro'`（实时出声）、`'pmut'`（本进程 bypass）可用；**其他进程音量/静音选择器全部返回 `'what'`**（每 App 音量在系统设置里是私有 HAL）。因此 `perAppVolumeSupported = false` 是**结论而非未实现**。
- `outputVolume`/`outputMuted`/`selfAudible` 都是 `didSet → set*`（即改即写硬件）；`selectedDevice` didSet → `selectDefaultDevice`。
- `refreshPlayingApps`：`'prs#'` 列表 → 逐对象读 `'piro'`/`'ppid'` → `NSRunningApplication` → 图标按 pid 缓存 → **列表 pid 序列不变则不写 `@Published`**（v128：避免每 2s 全页 Form 重绘）。
- `AudioMixerPane`：`Form(.grouped)` 4 段；`onAppear/onDisappear` 启停 2s 定时器。

---

## 3. 函数级清单

### 3.1 `SettingsModule.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `start()` | 14–38 | 注册 4 个基础页签 → 注入 `ServiceLocator.settings` → `AppearanceManager.applyCurrent()`。主线程；副作用：全局 `NSApp.appearance`。 |

### 3.2 `SettingsWindowController.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `SettingsUIState.init(selectedPaneID:)` | 24–27 | 存 id 并做一次映射。 |
| `selectPane(_:)` | 30–36 | 两条日志（含面包屑）→ 置 id → 清 `detailPaneID` → `applyPaneMapping`。 |
| `applyPaneMapping(_:)` | 38–60 | 16 条 switch 映射 + `monitor.<module>` 前缀兜底。未知 id **静默不动**（保持原选中项）。 |
| `SettingsWindow.performKeyEquivalent(with:)` | 65–72 | Esc → `close()` 并吞事件。 |
| `SettingsWindowController.open(pane:)` | 91–104 | 打点 `.settingsOpen` → `ensureWindow()` → 可选切页 → activate → `makeKeyAndOrderFront` → `RenderProbe`。 |
| `close()` | 106–110 | `orderOut`（窗口复用）。 |
| `isVisible` (var) | 113 | `window?.isVisible`。 |
| `ensureWindow()` | 117–168 | 见下方。 |

**`ensureWindow()`（117–168）**
① 940×620 `SettingsWindow`（titled + closable + fullSizeContentView）；② 隐藏标题、`applyOfficialChrome`、`isMovableByWindowBackground`、`isReleasedWhenClosed = false`；③ `contentMinSize = contentMaxSize = 940×620`（**必须**，否则 NSHostingView 会在首轮 layout 请求尺寸变更并触发约束异常）；④ 隐藏 miniaturize/zoom；⑤ `center()`；⑥ `contentView = NSView()` 占位；⑦ 下一 runloop 装 `NSHostingView(SettingsRootView(state:))` + `sizingOptions = []` + `safeAreaRegions = []` + `attachOfficialRoundCloseButton()`。
**坑**：`window` 字段在 ⑥ 就赋值（不是 ⑦），因此 `open()` 立即 `makeKeyAndOrderFront` 时窗口是**空内容**——先闪一帧空窗，再在下一 runloop 出内容。这是为了避免崩溃付的代价。

### 3.3 `SettingsRootView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `body` | 24–52 | 侧边栏 + 分隔 + (header/分隔/content)；`.frame(940×620)`、`ignoresSafeArea`、`.frsetThemeChrome()`、`onChange(selection)` 面包屑。 |
| `backgroundColor` (var) | 54–57 | Midnight → `MidnightTheme.baseBackground`；亮色 `white: 222/255`；暗色 `windowBackgroundColor`。 |
| `currentTitle` (var) | 61–69 | 5 类选中项的标题（sensors 显示"传感器"）。 |
| `header` | 71–79 | 16pt 半粗标题，高 56，左右 34。 |
| `content` (var) | 83–126 | 一级分发（7 类 / 模块 / 监测设置 / 部件设置 / 手册）。 |
| `panePage(_:)` | 129–136 | 单页滚动容器（34/18 内边距）。 |
| `segmentedPage(selection:tabs:)` | 139–181 | 分段胶囊（`MonitorColors.user` 选中）+ 内容滚动；越界索引保护。 |

### 3.4 `SettingsSidebarView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `body` | 72–125 | brand + 滚动列表（主页 6 项 / 性能监测 7 模块 + 监测设置 + 部件设置 / 分隔 / 关于）+ 页脚；宽 `Theme.settingsSidebarWidth`。 |
| `brand` | 129–143 | 左侧留 44pt 让开官方关闭钮；高 50。 |
| `groupTitle(_:)` | 147–154 | 11pt 半粗分组标题。 |
| `navRow(title:icon:selected:action:)` | 156–182 | 29pt 高行，选中态强调色 15% 圆角 7 底。 |
| `footer` | 186–223 | 分隔线 + 「使用手册」入口 + 版本号（`Frset v1.0.0` 硬编码）。 |

### 3.5 `SettingsComponents.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `SettingsRow.init(icon:title:subtitle:trailing:)` | 13–17 | 赋值。 |
| `SettingsRow.body` | 19–43 | 可选 26×26 图标底 + 标题/副标题 + 右侧控件。 |
| `SettingsSection.init(_:content:)` | 51–54 | 标题式 init。 |
| `SettingsSection.init(title:content:)` | 57–60 | 兼容旧调用。 |
| `SettingsSection.body` | 62–69 | 12pt 半粗标题 + 内容。 |
| `SettingsGroupBox.body` | 76–85 | 14/8 内边距 + `Theme.cardBackground` + 圆角。 |
| `SettingsDivider.body` | 89–94 | 左缩进 38 的 Divider。 |

### 3.6 `SettingsPanes.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `GeneralSettingsPane.body` | 51–130 | 通用/个性化/菜单栏/剪贴板四组；sheet + 3 个 `onReceive`。 |
| `appearanceChoices` | 133–154 | 4 档圆形 radio。 |
| `probeMenuBarFirst` (var) | 157–159 | 读 `probe.settingsMenuBarFirst`。 |
| `menuBarSection` | 162–203 | 功能 / AI 服务商 / 菜单栏图标 / 菜单栏部件。 |
| `menuBarIconChoices` | 208–225 | 两行排布（3 + 2）；含小猫覆盖。 |
| `runCatChoice` | 229–249 | 小猫 Toggle（读写引擎 `FSRunCatIconEnabled`）。 |
| `providerCountText` / `tagCountText` (var) | 254–263 | 计数文案（单复数）。 |
| `todayDayNumber` (static var) | 266–268 | 当日日期。 |
| `featuresChoices` | 272–284 | 4 个功能开关（系统监控/日历/截图检索/文件中转）。 |
| `formRow(_:height:content:)` | 286–297 | 左标题列（compact 104 / 常规 190）+ 右内容。 |
| `actionButton(_:action:)` | 300–306 | 56×24 borderedProminent。 |
| `iconChoice(_:symbol:value:help:dayBadge:)` | 308–338 | 图标样式选项（选中白字 + 强调色胶囊）。 |
| `openDetail(_:)` | 340–342 | `ServiceLocator.settings?.open(pane:)`。 |
| `currentMenuBarIconStyle` (var) | 374–379 | 四布尔键 → 内部标识（custom > fan > date > logo）。 |
| `menuBarIconStyleBinding` (var) | 382–398 | set 时清四键再置一（**必须**保持"互斥"语义）。 |
| `runCatBinding` (var) | 402–407 | 引擎 C API 桥。 |
| `customMenuBarSymbolBinding` (var) | 409–417 | 空则回落 `sparkles`。 |
| `appearanceTitle(_:)` | 424–431 | `AppearanceMode` → L10n 键面。 |
| `languageBinding` (var) | 435–440 | `LanguageManager.apply`。 |
| `launchAtLoginBinding` (var) | 444–465 | `SMAppService.mainApp.register/unregister`；失败**不改开关**（保持原值）。 |
| `AboutSettingsPane.body` | 484–537 | 图标/名称/版本/两按钮/更新源/版权。 |
| `aboutButton(_:action:)` | 550–558 | 112×32 borderedProminent。 |
| `TagManagementSheet.body` | 574–635 | 480×360 列表 + 新建行 + 删除。 |
| `createTag()` | 637–643 | trim 非空 → `store.create` → 清状态。 |
| `IgnoredAppsEditor.apps` (var) | 655–658 | 读偏好（`_ = revision` 建立依赖）。 |
| `persist(_:)` | 660–663 | 写偏好（空则写 nil）+ `revision += 1`。 |
| `IgnoredAppsEditor.body` | 665–732 | 管理/添加当前前台应用按钮 + 展开列表 + 逐项移除。 |

### 3.7 `PersonalizationSettingsPane.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `body` | 14–36 | 14 行 + 4 条分隔线。 |
| `accentRow` | 41–73 | 6 预设 + ColorPicker + 跟随系统。 |
| `fontScaleRow` / `densityRow` / `cornerRow` / `animationRow` | 76–130 | 4 档 / 密度 / 3 档圆角 / 动画。 |
| `widthRow` | 133–152 | 360/400/440 + 重置。 |
| `applyPanelWidth(_:)` | 155–158 | 写 `panelWidth` + post `didChangeNotification`（**该通知同时驱动面板尺寸与材质**）。 |
| `materialRow` / `badgeRow` / `thumbRow` / `toastRow` | 163–224 | 材质/徽章/缩略图/通知条。 |
| `dividerRow` | 227–243 | 裸键 `CombinedModules_separator`（默认 true）。 |
| `midnightHueRow` / `backgroundImageRow` / `resetRow` | 248–290 | 色相 / 背景图 + 遮罩 / 恢复默认。 |
| `settingRow(_:content:)` | 294–303 | 96pt 标题列 + 内容。 |
| `presetColor(_:)` | 305–307 | hex → Color（失败 accent）。 |
| `pickBackgroundImage()` | 310–319 | `NSOpenPanel.begin`（异步，仅 png/jpeg/heic）→ 写路径（**不复制文件**）。 |

### 3.8 `MonitorWidgetsPane.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `reloadCache()` | 40–59 | 一次性读 5 组引擎查询 → 写 5 个 `@Stored` 缓存。 |
| `body` | 61–99 | 三区 + `onAppear`（空缓存才 reload）+ 两个确认 alert。 |
| `layoutSection` | 103–140 | 合并开关 / 间距滑条 0–24（0.5 步）/ 分隔线（仅合并态）。 |
| `modulesSection` | 144–152 | 逐模块 `moduleCard`。 |
| `moduleCard(_:)` | 154–233 | 二级头（图标+名+摘要+开关）+ 展开区（形态 chips / 间隔滑条 1–60 / 传感器选择器 / 每形态选项）。 |
| `formChip(module:form:active:allForms:current:)` | 235–273 | 形态多选（**保持顺序，新勾选追加末尾**）+ 预览图 14pt。 |
| `formOptionsBlock(module:form:)` | 276–300 | 三级标题 + 选项组 + 选项行。 |
| `optionControl(module:form:spec:)` | 303–332 | 4 种 kind 渲染（toggle/menu/slider/color）。 |
| `maintenanceSection` | 336–364 | 重新导入 Stats / 初始化 / config 说明 + 模块数。 |
| `optionRow(_:control:)` | 368–380 | 96pt 标题 + 控件。 |
| `mergedBinding` (var) | 384–391 | `CombinedModules`。 |
| `spacingSliderBinding` (var) | 394–402 | 双写 `Widgets_spacing` + `CombinedModules_spacing`。 |
| `spacingValueText` (var) | 404–407 | 整数/一位小数显示。 |
| `spacingValueFromStore` (static var) | 409–413 | 新键优先，旧键兜底，默认 2。 |
| `separatorBinding` (var) | 415–422 | `CombinedModules_separator`。 |
| `enabledBinding(module:allForms:current:)` | 424–436 | 开=保留当前或取首形态；关=空数组。 |
| `boolBinding/stringBinding` | 438–454 | 通用配置读写 + reload + bump。 |
| `numericStringBinding(...)` | 458–470 | 步进对齐后写回整数串。 |
| `numericValueText(...)` | 472–476 | 数值显示。 |
| `intervalBinding(_:)` | 479–486 | `updateInterval` 1–60 秒。 |
| `sensorBinding(_:)` / `sensorKeys(_:)` | 488–500 | 传感器键选择（默认 PPBR）。 |
| `summary(module:forms:)` | 502–508 | "形态 等 N 种 · 每 X 秒"。 |
| `bump()` | 510–513 | `reloadCache()` + `revision += 1`。 |
| `OptionSpec.toggle/menu/color/slider` | 529–542 | 4 个静态构造器。 |
| `optionGroups(module:form:)` | 579–704 | 13 种形态的权威选项表（与引擎逐项对齐）。 |
| `moduleSymbol(_:)` | 706–717 | 模块名 → SF Symbol。 |
| `ColorKeyControl.write(_:)` | 767–771 | 写配置 + reload + 回调。 |
| `customBinding` (var) | 773–779 | ColorPicker ↔ `custom:#hex`。 |
| `displayName(_:)` / `swatch(_:)` | 781–814 | 预设名/色（30 项）。 |
| `ColorKeyControl.color(hex:)` / `hex(_:)` | 816–832 | hex ↔ Color。 |
| `FormPreviewCache.image(module:form:)` | 859–866 | `NSCache(32)` + 明暗键。 |

### 3.9 `StatisticsSettingsPane.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `PreferenceValue.init?(defaultsValue:)` | 60–75 | NSNumber `objCType` 分派（c/B→bool、f/d→double、其余→int）。 |
| `defaultsValue` (var) | 78–87 | 还原原生值（data 走 base64 解码）。 |
| `PreferenceValue.init(from:)` | 91–105 | 按 `type` 字段解码；未知类型抛 `dataCorruptedError`。 |
| `PreferenceValue.encode(to:)` | 107–117 | 写 `type` + `value`。 |
| `body` | 143–160 | 六区 + `onAppear(refresh)` + `confirmationDialog`（导入确认）。 |
| `chartsSection` | 164–190 | 用量图表（`chartsEpoch` 强制重建）+ 刷新。 |
| `importConfirmBinding` (var) | 192–195 | `pendingImportURL != nil`。 |
| `metricsSection` | 199–248 | 5 项关键指标 + 刷新行。 |
| `featureSection` | 275–288 | 19 项功能明细。 |
| `reviewSection` / `transferSection` / `infoSection` | 292–343 | 评分口径 / 导出导入 / 说明。 |
| `refresh()` | 347–376 | 后台读 7 类统计 + 剪贴板条数 → 主线程写 7 个 `@Stored`。 |
| `performExport()` | 380–420 | savePanel（主线程）→ 后台 `exportAll` + `exportablePreferences` + JSONEncoder → 原子写 → 主线程结果/Toast。 |
| `chooseImportFile()` | 424–432 | openPanel → `pendingImportURL`。 |
| `performImport(_:)` | 434–478 | 见下方。 |
| `exportablePreferences()` (static) | 560–570 | 白名单逐键读（未落盘跳过）。 |
| `applyPreferences(_:)` (static) | 579–593 | 白名单写入；未命中写 `settings.invalid-<key>`；返回被忽略键（排序）。 |
| `defaultExportFileName(now:)` | 604–606 | `FrsetNext-配置-yyyyMMdd-HHmmss.frsetconfig`。 |
| `dayStamp(_:)` / `iso8601Now()` | 625–632 | 复用静态 DateFormatter（v126）。 |

**`performImport`（434–478）**
后台：读文件 → decode → 校验 `format` → 校验 `version <= 1` → `applyPreferences`（收集 ignored）→ `StatisticsManager.importMerge`（MAX 合并）→ 打点 → 主线程：`SearchServiceManager.reloadFromDefaults()`（**必须主线程**）→ 结果文案（有 ignored 时提示"被忽略 N 个键"）→ `refresh()` → Toast。异常分支统一写 `lastActionFailed`。
**坑**：`importMerge` 与 `applyPreferences` **无事务包裹**——偏好已写、统计合并失败时会留下"偏好已导入但统计未导入"的半状态，`lastActionFailed` 只反映异常文案，不区分阶段。

### 3.10 `SearchSettingsPane.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `hasSeenOrderingTip` (var) | 51–53 | 读 `hasSeenSearchBarOrderingTip`。 |
| `searchCategorySection` | 57–79 | 3 个分类开关（网页/剪贴板/本地文件）。 |
| `body` | 81–151 | 分类卡 + 左引擎表 + 右搜索栏列 + 两个 confirmationDialog + 坐标系命名。 |
| `deleteConfirmBinding` (var) | 154–156 | `enginePendingDelete != nil`。 |
| `searchBarRow(_:)` | 161–207 | 拖拽手柄/名称/移除；`.onDrag`（记 draggingID + 消费提示 + preview）+ `.onDrop`（非编辑模式传空类型=关闭接收）。 |
| `searchBarDropDelegate(targetID:)` | 211–222 | 构造 `SearchBarReorderDelegate`（order/dragging 均传闭包，实时读取）。 |
| `markOrderingTipShownIfNeeded()` | 225–229 | 一次性 Toast。 |
| `removeFromSearchBar(_:)` | 232–239 | 成功 Toast / 失败「最少一项」警示。 |
| `engineRow(_:index:)` | 243–282 | 名称(142)/URL/已加入勾/More 菜单（加入移出/上下移/编辑删除/清空输入）。 |
| `addToSearchBar(_:)` | 284–287 | 加 + Toast。 |
| `engineIcon(_:size:)` | 292–296 | SF Symbol（**不用品牌 logo**，v42）。 |
| `customEngineForm` / `engineEditForm(_:)` | 300–333 | 新增/编辑表单（同一套字段 + 保存/取消）。 |
| `engineFormFields(...)` | 336–362 | 名称 + URL + 占位符 + 错误位。 |
| `validateEngineForm(name:url:excludingID:)` | 367–386 | **三连校验** + URL 查重。 |
| `saveCustomEngine()` | 388–401 | 校验 → `addCustomEngine` → 清表单 + Toast。 |
| `clearForm()` | 403–407 | 清名称/URL（写回占位符）/错误。 |
| `beginEditing(_:)` / `cancelEditing()` | 411–423 | 行内编辑态进出。 |
| `saveEngineEdit(_:)` | 425–436 | 校验（排除自身）→ `updateCustomEngine` → Toast。 |
| `clearInputBinding` (var) | 440–445 | `SearchServiceManager.clearSearchInputAfterWebAction`。 |
| `performReset()` | 449–458 | `resetToDefaults` + 清 7 项局部状态 + Toast。 |
| `performDeletePendingEngine()` | 462–468 | 若正在编辑该引擎先 `cancelEditing` → 删除 → Toast。 |
| `SearchBarReorderDelegate.dropEntered(info:)` | 486–494 | 实时读 order/dragging → `move(IndexSet(from), from < to ? to+1 : to)` + 落点高亮。 |
| `dropUpdated(info:)` | 496–498 | `.move`。 |
| `performDrop(info:)` | 500–504 | 清 dragging/dropTarget，返回 true。 |
| `dropExited(info:)` | 506–508 | 清落点高亮。 |

### 3.11 `DiagnosticsExporter.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `export()` | 16–43 | savePanel（主线程）→ 后台 `writeBundle` → 成功 Toast + 打点 + Finder 显示；失败 Toast。 |
| `writeBundle(to:)` | 47–97 | 见下方。 |
| `usageRows()` | 101–104 | `StatisticsManager.exportAll()`。 |
| `performanceLines()` | 109–126 | 8 个关键词过滤所有 `logs/*.log` → CSV 行。 |
| `csvLine(_:)` | 129–143 | 正则拆 `[time][level][tag] message`，拆不动整体进 message。 |
| `csvEscape(_:)` | 145–150 | 含逗号/引号/换行则加引号并双写引号。 |
| `systemSnapshot()` | 154–175 | 版本/包名/macOS/物理内存/uptime/生成时间 + `proc_pid_rusage` footprint + cpu time。 |
| `stamp()` | 177–181 | `yyyyMMdd-HHmm`。 |
| `AnalyticsEvent.recordNow()` | 186–188 | `StatisticsManager.record(eventName)`。 |

**`writeBundle`（47–97）**
临时目录 `frset-diag-<UUID>`（`defer` 删除）→ 拷贝 `logs/*.log` → `usage.csv`（**逐行字符串拼接**）→ `performance.csv` → `system.txt` → `ditto -c -k --sequesterRsrc --keepParent`（阻塞 `waitUntilExit`）→ 校验 terminationStatus。
**坑**：`usage += "..."` 在数万行时是 O(n²) 拼接；`performanceLines` 把**所有日志文件整份读入内存**再逐行过滤（日志保留窗口内可能几十 MB）。

### 3.12 `WidgetSettingsSelfTest.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `runIfRequested()` | 46–51 | 环境变量门控 + 5s 延迟。 |
| `run()` | 55–71 | 读 plist 原文 + 备份 `/tmp` → 三段测试 → `restore` → `report`。 |
| `testLayout()` | 75–109 | 合并开/关、间距 0/3/3.5/24、分隔线开关；结束还原。 |
| `testModules()` | 113–187 | 7 模块 × 全形态：开关、键集合对照、逐选项、间隔 1/30/60、传感器首尾 key；结束还原形态列表。 |
| `testOption(module:form:spec:)` | 189–232 | 4 种 kind 的写读校验（含 custom 颜色与滑条步进）。 |
| `key(of:)` | 234–241 | 取 spec 的 key。 |
| `testMaintenance()` | 245–255 | 初始化默认 + 重新导入 Stats 后的断言。 |
| `check(_:_:)` / `checkEqual(_:_:_:)` | 262–272 | `@autoclosure` 惰性断言（v126）。 |
| `restore(_:)` | 274–293 | 见下方。 |
| `diffKeys(_:_:)` | 295–304 | 差异键前 6 个。 |
| `report()` | 306–317 | NSLog 汇总 + 失败项 + 写 `/tmp/frset_widget_selftest.txt`。 |

**`restore`（274–293）**：先删"测试期间新增且原文没有"的键（跳过 `NSPos_`）→ 逐键写回原值（跳过 `NSPos_`）→ `FSBarReloadFromStore()` → **最后**才写 `NSPos_*`（状态项位置缓存，reload 会被校准重写）→ 比对 plist 是否与原文相等并断言。
**坑**：这条路径依赖 "`FSBarGlobalSet(key, nil)` 表示删除键" 的引擎语义；`NSPos_` 特殊处理必须保持在最后，否则校准会把位置改掉。

### 3.13 `AppearanceManager.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init(defaults:)` | 33–36 | 读 `appearance` 键（默认 system）。 |
| `apply(_:)` | 39–49 | 写/删键 → `applyNSAppearance()` → 同步 `AppearanceState.isMidnight` → 日志。 |
| `applyCurrent()` | 52–55 | 启动时只应用 + 同步（不写键）。 |
| `applyNSAppearance()` | 58–68 | system→nil / light→aqua / dark+midnight→darkAqua。 |
| `isMidnight` (var) | 76 | **从 `mode` 派生**（不是转发 `AppearanceState`）。 |

### 3.14 `PermissionCenter.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `PermissionKind.title/symbol/purpose/features/isCore/settingsFragment/settingsURL` | 33–99 | 8 个计算属性（含 `x-apple.systempreferences:...?Privacy_XXX`）。 |
| `PermissionStatus.isGranted/label/symbol/tint` | 108–135 | 4 态表现。 |
| `PermissionCenter.init()` | 152–154 | `refreshAll()`（构造期即探测）。 |
| `status(_:)` | 158–160 | 缺省 `.notDetermined`。 |
| `refreshAll()` | 163–169 | 全量 `quickStatus` → 一次性写 `statuses`。 |
| `quickStatus(_:)` | 172–198 | 屏幕录制 `CGPreflight`（假阴性已知）；辅助功能 `AXIsProcessTrusted`；麦克风 `AVCaptureDevice.authorizationStatus`；日历用 **rawValue** 兼容 macOS 14 的 `.fullAccess/.writeOnly`。 |
| `probeScreenRecording()` | 204–223 | `@MainActor`；preflight 真则直接 granted；否则 macOS 14+ `SCShareableContent` 实探（displays 非空即 granted）；否则 notDetermined。 |
| `request(_:completion:)` | 229–264 | 四路请求；屏幕录制/辅助功能 1.2s 后刷新并回调。 |
| `openSystemSettings(_:)` | 269–279 | `NSWorkspace.open(settingsURL)`；失败 Toast「无法打开链接」。 |
| `allCoreGranted` (var) | 284–286 | 两个核心权限都 granted。 |
| `grantedCount` (var) | 289–291 | 已授权数。 |

### 3.15 `WelcomeWindowController.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `shouldPresentOnLaunch` (static var) | 28–31 | `defaults.integer(onboardingWelcomeSeenVersion) < 1`。 |
| `show()` | 35–41 | ensureWindow + activate + makeKey + RenderProbe。 |
| `finishOnboarding()` | 44–49 | 写 seenVersion + close。 |
| `dismissWelcome()` (static) | 52–54 | 只关不写（权限窗复用）。 |
| `close()` | 56–59 | orderOut。 |
| `isVisible` (var) | 61 | — |
| `ensureWindow()` | 65–97 | 760×620 固定 + 占位视图 + 延后装载（同设置窗纪律）。 |
| `WelcomeWindow.performKeyEquivalent(with:)` | 103–109 | Esc → `close()`（**不写 seen**）。 |

### 3.16 `WelcomeView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `body` | 20–75 | Hero + 两组 4 卡 + 快捷键 + 权限横幅 + 页脚；`.frame(760×620)`；`onAppear`/`didBecomeActive` 刷新权限。 |
| `hero` | 79–93 | 图标 + 标题 + 副标题。 |
| `featureSection(_:items:)` | 104–116 | 两列 `LazyVGrid` + 卡片。 |
| `featureCard(_:)` | 118–146 | 图标/标题/要点列表。 |
| `hotkeySection` | 150–173 | 12 条快捷键两列。 |
| `hotkeyRow(_:_:)` | 175–188 | 键位胶囊 + 说明。 |
| `permissionBanner` | 192–215 | 权限状态横幅 + 「权限引导」按钮。 |
| `footer` | 219–235 | 使用手册 / 开始使用。 |

### 3.17 `PermissionGuideWindowController.swift` / `PermissionGuideView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `show()` | 27–35 | ensureWindow + activate + `refreshAll` + `probeScreenRecording` + RenderProbe。 |
| `close()` | 37–41 | orderOut。 |
| `isVisible` (var) | 43 | — |
| `ensureWindow()` | 47–77 | 660×600 固定 + 延后装载。 |
| `PermissionGuideWindow.performKeyEquivalent(with:)` | 83–89 | Esc 关闭。 |
| `PermissionGuideView.body` | 17–49 | header + 4 张卡 + footer；`onAppear`/`didBecomeActive` 刷新 + 实探。 |
| `header` / `progressPill` | 53–87 | 标题 + `granted/total` 胶囊。 |
| `footer` | 91–114 | 核心权限未齐提示 + 稍后再说/完成。 |
| `backdrop` (var) | 116–118 | 官方灰底。 |
| `PermissionCard.body` | 131–172 | 状态图标 + 标题/核心徽章/状态徽章 + purpose + features 流式 + 动作行。 |
| `statusIcon` / `statusBadge` | 174–197 | 圆底图标 / 检测中 or 状态。 |
| `actionRow` | 199–219 | 四态动作。 |

### 3.18 `WhatsNew.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `WhatsNewCategory.title/symbol/tint` | 25–47 | 3 类表现。 |
| `WhatsNewCatalog.grouped()` | 76–84 | 按类别保序分组。 |
| `WhatsNewStore.shouldShow` (var) | 99–101 | 版本比较。 |
| `markSeen()` | 104–107 | 写当前 version。 |
| `WhatsNewWindowController.show(force:)` | 121–128 | force 或 shouldShow 才弹。 |
| `finish()` | 131–134 | markSeen + close。 |
| `close()` | 136–139 | orderOut。 |
| `isVisible` (var) | 141 | — |
| `ensureWindow()` | 145–175 | 400×500 固定 + 延后装载。 |
| `WhatsNewWindow.performClose(_:)` | 180–183 | **叉号也算知道了**。 |
| `WhatsNewWindow.performKeyEquivalent(with:)` | 185–192 | Esc 也算知道了。 |
| `WhatsNewView.body` | 201–217 | header + 分组滚动 + footer。 |
| `header` / `section(_:entries:)` / `footer` | 219–281 | 三段 UI。 |

### 3.19 `ManualDocument.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ManualNode.init(id:title:level:)` | 26–30 | 赋值。 |
| `finalizeSearchText()` | 33–38 | 标题 + 全部块 `plainText` 拼接（解析期一次）。 |
| `flatten()` | 41–45 | 子树先序平铺（**当前无调用方**，已被 `flatNodes` 取代）。 |
| `ManualBlock.id` (var) | 64–75 | 稳定 id（divider 用 UUID → 不稳定）。 |
| `ManualBlock.plainText` (var) | 79–90 | 8 种块的纯文本。 |
| `ManualDocument.load(bundle:)` | 108–118 | 读 `Manual/用户手册.md`；缺失返回 "手册未打包" 单节点。 |
| `ManualDocument.parse(_:)` | 120–181 | 见下方。 |
| `flush(into:)`（嵌套） | 128–135 | 缓冲行 → `parseBlocks` → 追加到节点（id 为 `<node>-b<i>`）。 |
| `register(_:parentID:)`（嵌套） | 170–177 | 建 index/parentIndex/finalizeSearchText/flatNodes，递归子树。 |
| `heading(of:)` | 184–195 | `#` 计数（1–4）+ 必须有空格；返回 `(level-1, 去反引号的标题)`。 |
| `parseBlocks(_:)` | 199–311 | 八类块的行扫描状态机。 |
| `splitTableRow(_:)` | 313–320 | 去首尾 `|` 后切分。 |
| `isSeparatorRow(_:)` | 322–324 | 每格匹配 `^:?-{2,}:?$`。 |
| `matches(_:_:)` | 335–338 | 静态正则整串匹配。 |
| `firstRange(_:_:)` | 341–346 | 静态正则首区间。 |
| `firstMatch(_:pattern:)` | 352–369 | **无锁字典缓存** + 全捕获组返回。 |

### 3.20 `ManualView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `body` | 31–50 | 左树 236 + 0.5 分隔 + 右内容；`onAppear` 默认选中第一节 + 展开章节点；`sheet(item: zoom)`。 |
| `sidebar` | 54–114 | 搜索框 + 展开/收起全部 + 节数 + 树。 |
| `detail` | 118–150 | 面包屑/标题/本节目录/块/上下节。 |
| `breadcrumb(for:)` | 153–169 | 祖先路径可点。 |
| `sectionLinks(_:)` | 172–182 | 本节目录网格。 |
| `flat` (var) | 187 | 直读 `doc.flatNodes`。 |
| `navFooter(_:)` | 189–212 | 上/下一节。 |
| `allGroupIDs()` | 216–219 | 有子节点的 id 列表。 |
| `ancestorPath(_:)` | 221–229 | 由 `parent(of:)` 上溯。 |
| `parent(of:)` | 231–239 | `parentIndex` O(1) 查表。 |
| `searchIndex` (var) | 247–266 | 命中集合 + 命中及其祖先的可见集合。 |
| `visibleRoots` (var) | 268–271 | 可见根过滤。 |
| `ManualTreeRow.isExpanded` (var) | 287–292 | 搜索时强制展开（get 里 `|| !query.isEmpty`）。 |
| `visibleChildren` (var) | 294–296 | 集合查表。 |
| `ManualTreeRow.body` | 298–314 | 叶行 or DisclosureGroup 递归。 |
| `row` (var) | 316–341 | 缩进点（level≥3）+ 标题 + 选中/淡化。 |
| `ManualDisclosureStyle.makeBody(configuration:)` | 346–366 | 三角旋转 + 缩进。 |
| `FlowLinks.body` | 376–395 | 自适应列网格。 |
| `ManualBlockView.body` | 404–472 | 8 种块渲染。 |
| `inline(_:)` | 475–482 | 行内 Markdown → AttributedString（失败回退）。 |
| `ManualImageLoader.load(_:)` | 488–496 | Bundle `Manual/shots` 下按名找图。 |
| `ManualImageView.body` | 504–536 | 图（最大 560×420，点击放大）或「截图待补」虚线框。 |
| `ZoomSheet.body` | 550–568 | 960×700 sheet + 双向滚动 + Esc 关。 |
| `ManualTableView.body` | 577–590 | 表头 + 斑马行 + 圆角描边。 |
| `row(_:isHeader:)` | 592–606 | 单元格 + 分隔。 |
| `inlineCell(_:)` | 608–614 | 单元格行内 Markdown。 |

### 3.21 `AudioMixer.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `cc(_:)` | 19–23 | 字符串 → FourCC。 |
| `addr(_:_:_:)` | 25–28 | 构造 `AudioObjectPropertyAddress`。 |
| `AudioMixerController.init()` | 90–95 | 读音量/静音/bypass + `reloadDevices()`。 |
| `startRefreshing()` | 99–110 | 立即刷新 + 2s Timer（回调内 `autoreleasepool`）。 |
| `stopRefreshing()` | 112–115 | 停 Timer。 |
| `defaultOutputID` (var) | 119–127 | `'dOut'`，取不到回退 `AudioObjectID(1)`。 |
| `getSystemVolume()` / `setSystemVolume(_:)` | 129–141 | `'voll'`（output scope）；set 夹 [0,1]。 |
| `getSystemMuted()` / `setSystemMuted(_:)` | 143–155 | `'mute'`。 |
| `getSelfAudible()` / `setSelfAudible(_:)` | 159–171 | `'pmut'`（系统对象）。 |
| `reloadDevices()` | 175–200 | `'dev#'` 列表 → 过滤有 output stream 的设备 → 名称 + 默认标记 → 写 `devices`/`selectedDevice`。 |
| `selectDefaultDevice(_:)` | 202–208 | 写 `'dOut'` → `reloadDevices()`（**递归一次**，因为 didSet 又赋 selectedDevice）。 |
| `refreshPlayingApps()` | 212–257 | `'prs#'` → 逐对象 `'piro'`/`'ppid'` → 图标缓存 → pid 序列不变则不写 `@Published`。 |
| `AudioMixerPane.body` | 267–328 | 4 段 Form；`onAppear/onDisappear` 启停。 |

---

## 4. 关键数据流

### 4.1 打开设置并直达某页

```
任意模块 ServiceLocator.settings?.open(pane: "clipboard")
  → SettingsWindowController.open(pane:)
      ├─ StatisticsManager.record(.settingsOpen)
      ├─ ensureWindow()（首次：940×620 窗 + 占位视图 + 下一 runloop 装 NSHostingView）
      ├─ uiState.selectPane("clipboard")
      │     ├─ applyPaneMapping: "clipboard" → .category(.clipboard)
      │     └─ breadcrumb 日志
      ├─ NSApp.activate
      └─ makeKeyAndOrderFront + RenderProbe
            → SettingsRootView.content 分发 → ClipboardSettingsPane()
```

### 4.2 部件设置改一项配置

```
用户在 MonitorWidgetsPane 切换某形态开关
  → boolBinding.set(value)
      ├─ FSBarCfgSet(module, form, key, NSNumber(value))     [跨模块：C 引擎]
      ├─ FSBarReloadFromStore()                              → 引擎重建状态项
      └─ bump()
            ├─ reloadCache()   ← 一次性重读 5 组引擎查询（避免 body 期 C 调用）
            └─ revision += 1   → 整页重绘
```

### 4.3 导出 / 导入配置

```
导出：StatisticsSettingsPane 导出…
  → performExport()
      ├─ NSSavePanel.runModal（主线程，阻塞）
      └─ 后台：StatisticsManager.exportAll() + exportablePreferences()
            → FrsetConfigFile(format:"frsetconfig", version:1, exportedAt, preferences, statistics)
            → JSONEncoder(prettyPrinted+sortedKeys+withoutEscapingSlashes).write(.atomic)
            → 主线程 Toast + lastActionResult

导入：导入…
  → chooseImportFile() → pendingImportURL
  → confirmationDialog → performImport(url)
      ├─ 后台：读文件 → decode → 校验 format/version
      ├─ applyPreferences（白名单 40 键；未命中写 settings.invalid-<key>）
      ├─ StatisticsManager.importMerge（MAX 合并，不削减）
      └─ 主线程：SearchServiceManager.reloadFromDefaults() → 结果文案 → refresh()
```

### 4.4 权限引导

```
PermissionGuideWindowController.show()
  → PermissionCenter.refreshAll()（CGPreflight / AXIsProcessTrusted / AVFoundation / EventKit）
  → probeScreenRecording()（macOS 14+ SCShareableContent 实探，修 preflight 假阴性）
  → PermissionGuideView 渲染 4 张卡
用户点「授权」
  → PermissionCenter.request(kind)
      ├─ screenRecording: CGRequestScreenCaptureAccess() → 1.2s 后 refresh + 实探
      ├─ accessibility:   AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])
      ├─ microphone:      AVCaptureDevice.requestAccess(.audio)
      └─ calendar:        EKEventStore.requestAccess(to: .event)
用户从系统设置切回
  → NSApplication.didBecomeActiveNotification → refreshAll + probeScreenRecording
```

### 4.5 手册加载与搜索

```
SettingsRootView .manual → ManualPaneView
  → @Stored doc = ManualDocument.load()
      ├─ Bundle 找 Manual/用户手册.md（缺失 → "手册未打包" 单节点）
      └─ parse：标题树（全局自增 id）+ 每节 parseBlocks + register（index/parentIndex/flatNodes/finalizeSearchText）
  → 用户输入搜索词
      → searchIndex：matched（searchText contains）+ visible（含全部祖先）
      → 树行按 Set 查表过滤；命中行不淡化，其余淡化
```

---

## 5. 资源清单

### 定时器

| 位置 | 间隔 | 门控 |
|---|---|---|
| `AudioMixerController.startRefreshing` | 2.0s | 设置 → 音频页可见（`onAppear/onDisappear`） |
| `WidgetSettingsSelfTest.runIfRequested` | 5.0s 一次性 | `FRSET_WIDGET_SELFTEST=1` |
| `PermissionCenter.request` (screenRecording/accessibility) | 1.2s 一次性 | 请求后刷新 |
| `SecurityWindowController.ensureWindow` 装载块 | 下一 runloop | — |

### 线程 / 队列

| 资源 | 用途 |
|---|---|
| 主线程 | 全部 SwiftUI、`NSSavePanel/NSOpenPanel.runModal`、`FSBar*` C 调用、`NSApp.appearance`、`NSAppleScript`（间接） |
| `DispatchQueue.global(.userInitiated)` | `StatisticsSettingsPane.refresh/performExport/performImport`、`DiagnosticsExporter.export` |
| `SCShareableContent` async | `probeScreenRecording` |
| AVFoundation / EventKit 回调队列 | `request` 回调 → 内部切主线程 |

### 子进程

| 命令 | 位置 | 说明 |
|---|---|---|
| `/usr/bin/ditto -c -k --sequesterRsrc --keepParent` | `DiagnosticsExporter.writeBundle` | 阻塞 `waitUntilExit`（在后台队列） |
| （间接）`osascript with administrator privileges` | 不在此目录（Memory 模块） | — |

### 文件路径

| 路径 | 用途 |
|---|---|
| `Bundle/Resources/Manual/用户手册.md` | 手册正文 |
| `Bundle/Resources/Manual/shots/*.png` | 手册截图 |
| `LogArchive.shared.directory/*.log` | 诊断包日志源 |
| `~/Library/Application Support/FrsetStats/widgets.plist` | 自测读写目标 |
| `/tmp/frset_widgets_selftest_backup.plist` | 自测备份 |
| `/tmp/frset_widget_selftest.txt` | 自测报告 |
| 用户选择的 `*.frsetconfig` | 配置导出/导入 |
| 用户选择的 `FrsetNext-诊断-*.zip` | 诊断包输出 |
| 用户选择的背景图路径（**不复制**） | 个性化背景 |

### UserDefaults / Preferences 键

| 键 | 说明 |
|---|---|
| `appearance` | system/light/dark/midnight（system 时**删除键**） |
| `language` | 语言覆盖 |
| `launchAtLogin` | 开机启动（配合 `SMAppService`） |
| `showSystemStatus` / `showCalendar` / `automaticScreenshotOCREnabled` / `panelTransferDock` | 功能开关 |
| `menu-bar-icon-logo/fan/date/custom`、`menu-bar-icon-custom-symbol`、`revealCustomMenuBarIconOption` | 菜单栏图标四布尔键 |
| `panelWidth` / `panelHeight` | 面板尺寸（个性化宽度行直接写） |
| `CombinedModules` / `CombinedModules_separator` / `Widgets_spacing` / `CombinedModules_spacing` | 合并条布局（**裸键**，与引擎共享） |
| `settings.invalid-<key>` | 导入时被忽略键的标记 |
| `clearSearchInputAfterWebAction` / `customEngines` / `engineOrder` / `activeBarItems` | 搜索设置 |
| `analyticsEnabled` | 埋点开关 |
| `hasSeenSearchBarOrderingTip` | 一次性拖拽提示 |
| `whatsNewLastSeenVersion` | WhatsNew 记忆（**非 Preferences.Keys**） |
| `onboardingWelcomeSeenVersion`（`Preferences.Keys`） | 欢迎窗记忆 |
| `probe.settingsMenuBarFirst` | 排障探针 |
| `preview.markdown.enabled` / `preview.json.enabled` | （Clipboard 模块，非本目录） |

### 通知

| 名称 | 方向 |
|---|---|
| `MonitorPreferences.didChangeNotification` | 收（通用页重绘） |
| `LanguageManager.languageDidChange` | 收（通用/关于/标签 sheet 重绘） |
| `Personalization.didChangeNotification` | 发（宽度行） |
| `NSApplication.didBecomeActiveNotification` | 收（欢迎窗/权限引导刷新权限） |

---

## 6. 不变量与陷阱

1. **设置窗尺寸三件套缺一不可**：`contentRect` == 根视图 `.frame` == `contentMin/MaxSize`（当前均为 940×620）。任一不一致 → NSHostingView 请求尺寸变更 → `_postWindowNeedsUpdateConstraints` 异常（历史崩溃）。
   - ⚠️ **口径订正**：流传的「设置窗必须固定 800×530」已过时——940×620 是**设置窗**（v41 加大侧边栏后），**800×530 是 `StatusBar/StatisticsWindowController`（使用统计窗）**，两者不是同一个窗口。三件套纪律对两者都成立，但数值不可互换。
2. **不得使用 `setFrameAutosaveName`**：autosave 会用旧帧覆盖目标尺寸，与强制尺寸构成约束更新循环。
3. **SwiftUI 内容必须延后一个 runloop 装载**（占位 `NSView()`）：同 cycle 建窗 + 首次布局会抛 NSException（三组崩溃栈实证）。
4. **`hostingView.sizingOptions = []` 与 `safeAreaRegions = []` 不可去**：与浮动面板/预览窗同一条纪律。
5. **每个窗口 `isReleasedWhenClosed = false` + `orderOut` 复用**：关闭不销毁，`ensureWindow` 只在 `window == nil` 时建。
6. **`AppearanceManager.isMidnight` 必须由 `mode` 派生**：反向转发 `AppearanceState.isMidnight` 会退化成自赋值，Midnight 永远 false。
7. **`apply(.system)` 必须 `removeObject(forKey:)`**（原作：未改过不落盘）；写 `"system"` 会让"跟随系统"变成显式档位。
8. **`MonitorWidgetsPane` 的 C 查询只能发生在 `onAppear`/`bump`**：任何在 `body` 里调 `FSBar*` 的写法都会回到"点两下卡死"（v84）。
9. **每次写配置必须 `FSBarReloadFromStore()` + `bump()` 成对**：漏前者引擎不重建状态项，漏后者 UI 不刷新。
10. **菜单栏图标四布尔键必须互斥**：`menuBarIconStyleBinding.set` 先清四键再置一；否则"多 true"会让 `currentMenuBarIconStyle` 与引擎实际样式分叉。
11. **`PreferenceValue` 的数值类型必须走 `NSNumber.objCType`**：`as? Bool` 会把整数 1/0 导成 true/false（面板宽度、保留天数）。
12. **配置导入必须过白名单**，未命中写 `settings.invalid-<key>`：放任任意键写入等于允许配置文件改任意 defaults。
13. **统计导入必须 `MAX` 合并**：覆盖会削减用户已有计数（spec 17 S12 明确）。
14. **`SearchServiceManager.reloadFromDefaults()` 必须回主线程**（v126）：`@Published` 后台写是未定义行为。
15. **`PermissionCenter.probeScreenRecording` 是屏幕录制的唯一权威判据**：`CGPreflight` 在自签/重签名/异常启动方式下返回 false 而实际可用（假阴性）。
16. **授权后无回调**：屏幕录制/辅助功能只能靠 1.2s 延迟刷新 + `didBecomeActive` 重探；去掉这两条 → "授权了但界面仍显示未授权"。
17. **`WhatsNewWindow` 的 `performClose` 与 Esc 都必须 `markSeen`**：否则每次关闭方式不同会导致下次启动是否重弹不一致。
18. **`WelcomeWindow` 的 Esc 不得写 seen**：语义是"稍后再说"（下次还弹），与「开始使用」不同。
19. **`ManualDocument` 的节点 id 必须全局自增**：v88 修过"层级+序号"跨章撞 id → 索引去重丢节点、跳转串页。
20. **`ManualNode.searchText` 必须解析期固化**：改成按需计算会回到"搜索每键 × 全树块 join"的卡顿（v128）。
21. **`ManualBlock.id` 的 `divider` 用 `UUID()`**：同一次 body 求值内稳定，但跨求值变化 —— 若将来给 divider 加状态（展开/选中）会丢。**已知缺陷**。
22. **`AudioMixerController.selectedDevice` 的 didSet 会触发 `selectDefaultDevice` → `reloadDevices` → 再赋 `selectedDevice`**：靠 `guard oldValue != selectedDevice` 终止递归，去掉即无限递归。
23. **`refreshPlayingApps` 的 pid 序列比较不能删**：否则每 2s 写一次 `@Published` → 整页 Form（含 Slider/Picker）重绘。
24. **自测的 `restore` 必须最后写 `NSPos_*`**：`FSBarReloadFromStore` 会重写状态项位置缓存。

---

## 7. 重复实现 / 死代码 / 风险

### 重复实现

| 项 | 位置 | 说明 |
|---|---|---|
| 固定尺寸窗建窗套路 | `SettingsWindowController` / `WelcomeWindowController` / `PermissionGuideWindowController` / `WhatsNewWindowController` | 四份几乎相同的"固定尺寸 + 官方外观 + 占位视图 + 延后装载 + 隐藏 mini/zoom + attachOfficialRoundCloseButton"（约 30 行 × 4） |
| Esc 关闭窗口子类 | `SettingsWindow` / `WelcomeWindow` / `PermissionGuideWindow` / `WhatsNewWindow` | 四个 `performKeyEquivalent` 各自实现（WhatsNew 版多一步 markSeen） |
| 权限状态判断 | `PermissionCenter.quickStatus` 与各模块自己的判断（`ClipboardManager` 用 `AXIsProcessTrusted`、`ScreenshotManager` 用 preflight） | 同一语义多处口径 |
| 通知条/模板 | `Toast.show` 在各页大量直调，文案硬编码 | 无统一 L10n 键（部分走 `L10n.t`，部分是中文字面量） |
| Markdown 渲染 | `ManualDocument.parseBlocks` + `ManualBlockView.inline` 与 Panel/Clipboard 的渲染器 | 第三套 Markdown 实现 |

### 死代码 / 未接线

| 符号 | 状态 |
|---|---|
| `SettingsUIState.detailPaneID` | 只有写 `nil`，无读取方 |
| `SettingsUIState.selectedPaneID` | 只写不读（映射后由 `selection` 驱动） |
| `GeneralSettingsPane.compact`（=true 分支） | 设置窗恒 false；面板内嵌入口已不存在 |
| `AboutSettingsPane` 的 5 个 URL 常量（rate/feedback/changelog/privacy/terms） | v90 外链移除后**全部无引用** |
| `AboutSettingsPane.l10nVersion` | 自增但 body 不读（靠对象失效重绘） |
| `GeneralSettingsPane.monitorRevision` / `l10nVersion` / `ignoredAppsRevision` | 同类"自增但不读"模式 |
| `PreviewMarkdownPreferenceStore` / `PreviewJSONPreferenceStore`（Clipboard 目录） | 仅在同文件内被 `LargeTextPreviewMode.infer` 与 `MarkdownCodeSyntaxHighlighter.render` 读取；全仓**无任何 UI 写这两个键** → 永远默认 true，等价死开关 |
| `WidgetSettingsSelfTest` 整个 enum | 仅 `FRSET_WIDGET_SELFTEST=1` 时运行 |
| `ManualDocument.ManualNode.flatten()` | v128 后由 `flatNodes` 取代，无调用方 |
| `AudioMixerController.perAppVolumeSupported` | 恒 false（能力边界结论），UI 未读取 |
| `ManualBlock.divider` 的 UUID id | 每次求值变化（不稳定 id） |
| `PermissionStatus.unsupported` | 只有日历 `@unknown default` 会产生 |

### 风险

| # | 风险 | 位置 | 影响 |
|---|---|---|---|
| S1 | `ensureWindow` 在占位视图阶段就赋 `window`，`open()` 随即 `makeKeyAndOrderFront` → 先闪一帧空窗 | SettingsWindowController 153–166 | 观感问题；若宿主机器慢会明显"白窗一闪" |
| S2 | `MonitorWidgetsPane` 每次 setter 都 `FSBarReloadFromStore()`（重建全部状态项）+ `reloadCache()`（~50 次 C 调用） | 全文件 | 拖滑条时每 0.5 步一次全量重建；连续拖动会明显卡（v134 把间隔改滑条后触发频率大幅上升） |
| S3 | `StatisticsSettingsPane.performImport` 无事务：偏好已写、统计合并失败留半状态 | 434–478 | 导出/导入不是原子的，用户可能拿到"偏好已改、统计没进"的状态 |
| S4 | `DiagnosticsExporter.usage +=` 在后台做 O(n²) 字符串拼接；`performanceLines` 整份读入所有日志 | 66–79 / 117–124 | 日志/统计量大时导出耗时长、内存峰值高 |
| S5 | `ditto` 用 `waitUntilExit` 无超时 | writeBundle 91–92 | ditto 卡住则导出线程永久占用（后台队列，不冻 UI 但任务不结束） |
| S6 | `SearchSettingsPane` 的 `onDrop(of: isEditingSearchBar ? [UTType.text] : [])` 用空类型列表"关闭接收" | 206 | 依赖 SwiftUI 对空类型列表的处理；不同系统版本行为可能不同（未验证） |
| S7 | 引擎表单校验只允许**字母数字**名称 | validateEngineForm 369–371 | 中文名（"必应"）会被拒；注释称与原作一致，但对中文用户是硬门槛 |
| S8 | `ManualDocument.firstMatch` 的 `_reCache` 静态字典**无锁** | 350–369 | 手册解析只在主线程（`@Stored doc = load()`），当前安全；若将来后台预热会崩 |
| S9 | `ManualBlock.divider` 用 `UUID()` 作 id | ManualDocument 73 | 每次 body 求值 id 变化 → 该块 SwiftUI 视图永远重建（无状态时无害，加状态即坏） |
| S10 | `ManualImageLoader.load` 每次 body 求值都 `NSImage(contentsOf:)`（无缓存） | 488–496 | 手册含多张大图时滚动每帧读盘解码 |
| S11 | `AudioMixerController` 的 `outputVolume.didSet → setSystemVolume` 在**程序读取时也会写回**（`init` 里先读后赋值，赋值触发 didSet 再写一次） | 58–60 / 90–95 | 启动时对硬件多写一次；`reloadDevices()` 里赋 `selectedDevice` 同理 |
| S12 | `selectDefaultDevice` → `reloadDevices` → 赋 `selectedDevice` 的递归靠 `oldValue != selectedDevice` 终止 | 202–207 / 175–200 | 若设备列表刷新后 defaultID 与所选不同，会再触发一次 `selectDefaultDevice`（两次写硬件） |
| S13 | `refreshPlayingApps` 的 `iconCache` 按 pid 无界增长 | 88 | 长期运行（进程反复生灭）会累积 NSImage；无上限、无淘汰 |
| S14 | `WhatsNewStore.markSeen` 是 `func`（非 public）但被 `WhatsNewWindow`（internal）调用 | 104 | 跨文件可见性依赖同 module；将来拆 target 会编译失败 |
| S15 | `WidgetSettingsSelfTest` 直接读写用户真实 `widgets.plist` | 57–69 | 自测崩溃/被杀会把用户部件配置留在测试中间态（只有 `/tmp` 备份可人工恢复） |
| S16 | 诊断包会包含**完整运行日志**（含设备名、路径、可能的剪贴板/URL 片段） | writeBundle 54–63 | 用户分享诊断包时可能泄露隐私；UI 未提示"日志含本机信息" |
| S17 | `PermissionCenter.init` 在构造期同步探测 4 类权限（含 `AXIsProcessTrusted`） | 152–154 | 首次访问 `shared` 的线程承担 4 次系统调用；若在启动关键路径会有毫秒级开销 |
| S18 | **`Audio` 页签注册了但不可达**：`AppBootstrap.swift:96-101` 注册了 `SettingsPaneDescriptor(id:"audio")`，但 `SettingsSidebarView` 只枚举 `SettingsCategory.allCases`（7 类，无 audio），`SettingsUIState.applyPaneMapping` 也没有 `audio` 分支——`open(pane:"audio")` 落到 default 分支静默不动 | AudioMixer.swift 262 / SettingsWindowController 38-60 / SettingsSidebarView 79 | 整页音频混音器**没有任何用户入口**；且它用 `Form(.grouped)`，与其它设置页的 `SettingsSection/GroupBox` 视觉不一致 |
