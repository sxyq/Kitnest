# A1 — Core / App / Storage / Models 逐行测绘

范围：`apps/FrsetNext/Sources/Core/`（18 文件）、`App/`（2）、`Storage/`（1）、`Models/`（2），共 **23 个 Swift 文件 / 4,883 行**。
符号索引对账：`/tmp/frset_symbols.csv` 中本范围为 **303 条声明**，其中 `func`+`init` **196 条**（其余为 struct/class/enum/extension/protocol 声明本身）。本文表格覆盖 196 条可调用符号 + 关键 computed property（索引未收录 computed var，故正文额外列出，数量已在各节标注）。

阅读前置：全工程注释里的 `vNN（日期，用户原话）` 是设计意图档案。本目录的 v41/v66/v71/v73/v84/v101/v126/v128/v143/v153/v155/v156 注释都已读到，下文引用其结论而非重复原文。

---

## 1. 文件清单

| 路径 | 行数 | 一句话职责 |
|---|---:|---|
| `Core/Support.swift` | 273 | 全局底座：`Log`（唯一日志出口）、`AppModule`+`ModuleRegistry`、`ServiceLocator`（LLM/OCR 协议槽）、`Theme` 设计令牌（尺寸/字号/圆角/动效）、`Date/String/Data` 扩展（sha256）、`AppDirectories` |
| `Core/Registry.swift` | 182 | 跨模块注册表：面板区段 / 设置页签 / 状态栏项三个 Registry + `PanelControlling`/`SettingsWindowControlling`/`PanelPreviewPresenting` 三个协议槽 |
| `Core/StateCompat.swift` | 36 | `@Stored` — 本机缺 SwiftUIMacros、`@State` 不可用时的等价属性包装器（底层 `@StateObject` 承载） |
| `Core/Preferences.swift` | 105 | `Preferences.shared`：UserDefaults 薄封装 + 全工程键名常量表 `Keys` |
| `Core/Personalization.swift` | 267 | 个性化单例（15 个 `@Published` + 150ms 防抖落盘 + `didChangeNotification` 广播） |
| `Core/LogArchive.swift` | 308 | 分天日志（`logs/YYYY-MM-DD.log`，3 天/4MB）、主线程心跳 + 卡死看门狗、60s 状态快照、6h 清理 |
| `Core/LiquidGlass.swift` | 261 | 玻璃材质工厂（macOS 26 `NSGlassEffectView` / 回退 `NSVisualEffectView`）、三级玻璃的卡片样式、按压/悬停样式 |
| `Core/AppearanceTheme.swift` | 193 | 外观模式枚举、Midnight 色板（含色相偏移）、Environment 注入器、`frsetThemeChrome()` 统一主题入口 |
| `Core/L10n.swift` | 134 | 键面=英文句的轻量 L10n（22 语言），`LanguageManager` 持久化 + `languageDidChange` 广播 |
| `Core/Toast.swift` | 301 | 屏幕中间偏下的胶囊通知卡：复用单窗口 + 代际防串台 + 层级 `CGWindowLevelKey(14)` |
| `Core/TransientWindows.swift` | 140 | 唯一的「点外/失焦自动收起」仲裁器（本地/全局鼠标监视器 + 失活通知） |
| `Core/ContinuousCorner.swift` | 57 | `NSBezierPath.continuousRoundedRect`：取 SwiftUI `.continuous` 同一几何路径，供 AppKit 手绘 |
| `Core/FlowLayout.swift` | 46 | `FlowHStack` 流式换行 Layout（全工程唯一实现，v62 收敛） |
| `Core/OfficialWindowChrome.swift` | 34 | 官方灰窗口底色 + 透明标题栏 + 自动挂圆形关闭钮 |
| `Core/RoundCloseButton.swift` | 107 | 14pt 自绘圆形关闭钮（hover 显 × ），用 objc associated object 挂在窗口上 |
| `Core/PointingHandCursor.swift` | 76 | 悬停手型光标（v132 改为 `resetCursorRects`+`activeAlways` tracking，`hitTest` 恒 nil） |
| `Core/RenderProbe.swift` | 117 | 渲染健康探针（默认关闭，`FRSET_RENDER_PROBE=1` 开启），dump 窗口 frame/alpha/layer |
| `Core/AppUpdateChecker.swift` | 255 | 更新检查：可配置 feed、语义化版本比较、整包 zip 下载校验后 shell 替换 `/Applications` |
| `App/FrsetNextApp.swift` | 279 | `@main` App + `AppDelegate`：单实例护栏、`frsetnext://` 深链路由（20+ host）、退出前 flush |
| `App/AppBootstrap.swift` | 571 | 启动装配总控：8 模块注册启动、事件总线接线、15 条默认热键、双击快捷键、截图翻译会话 |
| `Storage/Database.swift` | 621 | SQLite 薄封装（WAL/journal_size_limit）+ 两库 schema 迁移 + `StatisticsManager` 窄表埋点与 8 个查询 |
| `Models/Models.swift` | 241 | 纯数据模型：剪贴板条目/标签/图标、工具调用、LLM 会话、监测采样、日历日/事件 |
| `Models/SearchEngine.swift` | 279 | 搜索引擎模型 + `SearchServiceManager`（11 内置引擎、自定义引擎、搜索栏激活集与排序） |

合计 4,883 行。

---

## 2. 类型逐段

### 2.1 `Log`（enum，Support.swift:8）

- **职责**：全工程唯一日志出口。`write` 同时写 stderr 与 `LogArchive`；`breadcrumb` 只进环形缓冲（20 条）+ 日志。
- **内部状态**：`static var isVerbose`（debug 级门控，默认 false）。
- **生命周期**：无实例，纯静态。
- **依赖**：`LogArchive.shared`。**被依赖**：全工程（几乎每个文件）。
- **线程**：任意线程可调；`LogArchive.appendRaw` 内部有 `NSLock` 串行化，因此**日志调用会阻塞在别人的写盘上**。
- **陷阱**：`guard level != .debug || isVerbose` 意味着 debug 级在发布态直接丢弃（连 breadcrumb 的 DEBUG 落盘也会被丢，但 `pushBreadcrumb` 走的是 `appendRaw` 直通，不受 `isVerbose` 影响——两条路径不一致，见 §7）。

### 2.2 `AppModule` / `ModuleRegistry`（Support.swift:35/40）

- **职责**：模块自注册 + 统一 `start()`。
- **状态**：`private static var list`，`NSLock` 保护；`register` 按 `identifier` 去重（同 id 二次注册被静默忽略）。
- **生命周期**：`AppBootstrap.start()` 里 8 次 `register` → 一次 `startAll()`；无销毁路径。
- **陷阱**：`startAll` 先在锁内快照再逐个 `start()`，**启动期间若某模块再注册新模块，本轮不会启动**（快照语义）。
- **被依赖**：`App/AppBootstrap.swift`、各 `Features/*/XxxModule.swift`。

### 2.3 `ServiceLocator`（Support.swift:82 + Registry.swift:132 扩展）

- **职责**：跨模块解耦的服务槽。`internal static let lock` 供同文件的三个 extension 共用。
- **槽位**：`llmService`、`ocrService`（Support）；`panel`、`settings`（Registry:135/139）；`panelPreview`（Registry:178）。全部 `private static var` + `NSLock` get/set。
- **生命周期**：由各 Features 模块在 `start()` 里 `set`；App 退出时不清理（进程结束）。
- **陷阱**：所有 getter 都加锁，但**返回的是 `AnyObject?` 强引用**——释放由模块自己负责；如果模块把窗口控制器置 nil 而没同步清槽，后续调用会拿到僵尸语义（对象已 dealloc 时槽里其实是 nil，因为 weak 不成立——这里是强引用，所以不会 zombie，但会延长生命周期）。

### 2.4 `Theme`（enum，Support.swift:103）

- **职责**：设计令牌唯一来源。尺寸全部**动态读 `Personalization.shared`**（`cornerRadius`/`panelWidth`/`panelMaxHeight`/`rowHeight`/`statsRowHeight`/`thumbSize`/`accent`/`accentNS`），静态令牌为 `TextSize`(11/12/13/15)、`Radius`(12/8/6)、`Motion`（4 个 easeOut + 4 档 spring + 2 个 linear + CA 曲线）、`rowHoverFill`、`tertiaryText`。
- **注释要点（v153/v155/v156）**：审计发现 297 处 <11pt 字号、132 处 `.tertiary` 实测 3.2:1 不达 AA、圆角曾出现 9 种；**连续循环动画只能线性**（旋转接缝速度不连续会被看成"转一下顿一下"）。
- **陷阱**：`Theme.*` 是 computed property，**不触发 SwiftUI 重绘**（无 `@Published` 依赖链）。要让个性化改动即时生效，根视图必须挂 `frsetThemeChrome()`（观察两个单例）。

### 2.5 `AppDirectories`（Support.swift:257）

- **路径**：`~/Library/Application Support/FrsetNext[-Dev]/`，`sub(name)` 自动建子目录。
- **副作用**：每次访问 `base` 都会 `createDirectory`（幂等但有一次 syscall）。
- **陷阱**：`LogArchive` **没有**走这里，它硬编码 `FrsetNext/logs`（见 §7-P1）。

### 2.6 三个 Registry（Registry.swift）

| 类型 | 状态 | 排序规则 | 消费者 |
|---|---|---|---|
| `PanelSectionRegistry` | `[PanelSectionDescriptor]` + lock | 注册时按 `priority` 升序排；同 id 覆盖 | 主面板（Panel 模块） |
| `SettingsPaneRegistry` | `[SettingsPaneDescriptor]` + lock | `all` 时按硬编码 `order` 数组（general/audio/monitor/clipboard/capture/search/ai/tools/shortcuts/statistics/about），未列出的排 99 | 设置窗（Settings 模块） |
| `StatusItemRegistry` | `[StatusItemDescriptor]` + lock | 注册时按 `priority` 升序 | `StatusBarController` |

- `StatusItemDescriptor` 有 4 种标题表达：`title`（短文本）、`attributedTitle`（富文本）、`twoLineTitle`（双层自绘子视图，优先于 title）、`onTap`/`popover`。
- **不变量**：菜单栏监控只允许 STATS 合并条一套（v43），`StatusItemRegistry` 是给**非 STATS** 的补充项用的（如网盘链接提示）；新增监控项绕过 STATS 会造成重复组件。

### 2.7 `PanelControlling` / `SettingsWindowControlling` / `PanelPreviewPresenting`（Registry.swift:111/127/149）

- 三个协议 + 两个 `public extension` 默认实现（`toggle(atAnchor:)`→`toggle()`）。
- `PanelPreviewPresenting` 8 个方法，是 docs/10-规格/12 契约面：Clipboard 模块**不得**直接引用 Panel 的 `MainPanelPreviewPopoverCoordinator`。
- **依赖方向**：Core 定义协议 → Features 实现并注入 → Core 只通过 `ServiceLocator` 调用。**唯一破例**见 `RenderProbe`（Core 直接引用 `PanelController`/`SettingsWindow`）。

### 2.8 `Stored` / `StoredBox`（StateCompat.swift）

- **职责**：`@State` 的等价物。`StoredBox<Value>: ObservableObject`（`@Published value`），`Stored<Value>: DynamicProperty` 内含 `@StateObject private var box`。
- **语义**：`wrappedValue` get 读 box、`nonmutating set` 写 box；`projectedValue` 现造 `Binding`。
- **生命周期**：`init(wrappedValue:)` 每次 View 重建都会新建 `StoredBox`，但 `@StateObject` 只保留首次实例 → 状态跨重建存活。
- **不变量（本机硬约束）**：**任何 `@State` 都会编译失败**（缺 `SwiftUIMacros` 插件）。新代码一律 `@Stored`。`@StateObject`/`@Binding`/`@Environment`/`@AppStorage`/`@FocusState` 实测可用。
- **已知代价**：每次写值走 `objectWillChange`，比 `@State` 重；密集拖拽滑块时要注意（见 §6）。

### 2.9 `Preferences`（Preferences.swift:5）

- **职责**：`UserDefaults.standard` 薄封装。`value(_:default:)` 做 `as? T` 强转（类型不符静默回落默认值）；`set` 直写；`binding(_:default:)` 生成 SwiftUI `Binding`。
- **状态**：仅 `defaults`。`init(suiteName:)` 支持测试用 suite。
- **`Keys` 常量表**：通用 10 个、剪贴板 6 个、监测 3 个、截图 3 个、AI 3 个、工具箱 2 个、个性化 15 个（`ui.accent.color` … `ui.background.dim`）。
- **陷阱**：`value` 用 `defaults.object(forKey:) as? T`——存进去是 `Int` 而读 `Double` 会拿不到（返回 fallback），所以数值键必须**写入与读取类型一致**（`Personalization` 全部用 `Double(fontScale)` 写，就是为了这个）。

### 2.10 `Personalization`（Personalization.swift:88）

- **职责**：个性化唯一真源。15 个 `@Published`：`accentColor`(Color?)、`fontScale`、`density`、`cornerRadius`、`openAnimation`、`material`、`showSourceBadge`、`thumbOverride`、`toastDuration`、`toastFollowPanel`、`barDividerColorHex`、`barDividerAlpha`、`midnightHueShift`、`backgroundImagePath`、`backgroundImageDim`。
- **内部状态**：`isLoading`（加载期抑制 persist，v66 修"半初始化覆盖"）、`persistWork: DispatchWorkItem?`（150ms 防抖）。
- **生命周期**：`shared`，进程级。`init` 私有 → `load()`。退出时 `flushPendingPersist()`（`AppDelegate.applicationWillTerminate`）。
- **依赖**：`Preferences.Keys`（键名）、`Log`。**被依赖**：`Theme`（8 个 computed var）、`LiquidGlass`、`Toast`、`AppearanceTheme`、设置页。
- **广播**：`didChangeNotification`（`personalization.didChange`）在**落盘时**（防抖窗口结束后）才 post，不是每次 didSet。AppKit 侧（窗口尺寸/材质）订阅它。
- **陷阱**：`@Published` 的 `didSet` 与 `objectWillChange` 顺序——`didSet` 在值写入**之后**触发，所以 `persist()` 读到的是新值；但 `flushPersist` 里 post 通知时，SwiftUI 侧可能已经重绘过一轮（AppKit 侧因此总是"晚 150ms"，可接受）。

### 2.11 `LogArchive`（LogArchive.swift:21）

- **职责**：分天日志 + 卡死取证。
- **内部状态**：`directory`、`fileLock`、`keepDays=3`、`maxFileSize=4MB`、`currentDay`、`handle: FileHandle?`；看门狗侧 `beatLock`、`lastBeat`、`hangStartedAt`、`lastHangLogAt`、`breadcrumbs[20]`、`watchdog/statusTimer/cleanupTimer`（3 个 `DispatchSourceTimer`）、`runLoopObserver: CFRunLoopObserver?`、`started`、`bootAt`、`warmupSeconds=10`。
- **生命周期**：`init` 建目录 + 立即 `cleanupOldLogs()`；`AppBootstrap.start()` 第一步 `start()`；`applicationWillTerminate` 里 `stop()`。
- **线程**：写入任意线程（`fileLock`）；看门狗/状态/清理三个 timer 都在 `DispatchQueue.global(qos:.utility)`；心跳回调在**主线程 runloop**。
- **关键不变量**：`start()` 幂等（`guard !started`）；前 10s 预热期不判卡死（否则会把 bootstrap 同步启动误报成"阻塞 18s"）。

### 2.12 `LiquidGlass` / `LiquidGlassBackground` / `GlassCardBackground` / `WhiteGlassCard` / `SpringyIconButtonStyle` / `HoverLift`（LiquidGlass.swift）

- **职责**：玻璃材质的**唯一**工厂。`makeView` 三态：macOS 26+ 真玻璃（`NSGlassEffectView`，`effectIsInteractive=false`）、回退 `NSVisualEffectView`、`solid`（`material==.solid` 或系统「降低透明度」）→ 不透明 `windowBackground`。
- **口径（注释）**：玻璃只铺结构面（窗口/面板/弹出层），**卡片不叠真玻璃**（逐卡模糊掉帧）——卡片用 `WhiteGlassCard` 的"白渐变 + 斜向高光 + 0.6pt 亮边 + 柔投影"。
- **`embed(_:in:)`**：`NSGlassEffectView` 走 `contentView`，其余走 `addSubview`，统一四边约束。
- **`LiquidGlassBackground.makeNSView`**：`DispatchQueue.main.async` 里把宿主窗口设 `isOpaque=false / backgroundColor=.clear`，否则 sheet 玻璃只能采样到白底（2026-10-17 实测）。
- **陷阱**：`reapplyStyle` 对 `NSVisualEffectView` 硬编码回 `.hudWindow`（丢掉 `makeView` 传入的自定义 `material`）——只有非 solid 分支会走到这里，视觉上可接受但语义不一致。

### 2.13 `AppearanceState` / `MidnightTheme` / `EnvironmentValues` 四键 / `AppearanceThemeModifier` / `ThemeChromeModifier`（AppearanceTheme.swift）

- **职责**：Midnight 不是自定义 `NSAppearance`，而是 **DarkAqua 之上的 SwiftUI 覆盖层**（对齐原作反射字段 `midnightBaseBackgroundOverride` / `usesMidnightTextColor`）。
- **状态**：`AppearanceState.shared.isMidnight: Bool`（`@Published`）。真正的 `NSAppearance` 应用在 `Features/Settings/AppearanceManager.swift`（不在本范围）。
- **注入**：`frsetAppearanceTheme()` 注入 4 个 environment 键；`frsetThemeChrome()` = `.tint(Theme.accent)` + 上面那个（观察 `Personalization` + `AppearanceState`）。
- **消费点（注释明确）**：`PanelRootView`、`SettingsRootView`、`FloatingClipboardWindow` 三个根视图各挂一次。**漏挂 = 主题不生效**。
- **`MidnightTheme.h()`**：手写 RGB→HSB→旋转 hue→Color，因为 `Color.hueRotation` 返回 View 不能当 Color 用。

### 2.14 `L10n` / `LanguageManager`（L10n.swift）

- **职责**：键面=英文句，缺失回退键面。22 语言码 + 各语言自称表。
- **状态**：`bundleCache: [String: Bundle]`（`t()` 在 body 内高频调用，`Bundle(path:)` 很贵）；`LanguageManager.overrideDisplayLanguage`（`@Published private(set)`）。
- **持久化**：defaults 键 `language`（值 `auto` 或语言码）。广播 `languageDidChange`。
- **坑**：`bundleCache` 是普通 `static var` **无锁**——`t()` 可从后台线程调用（如导出），理论上存在 Dictionary 并发写风险；实际写只发生在首次未命中，概率极低但确实存在。
- **落地范围（注释自述）**：只有「通用设置页 + 统计窗」接入了 `t()`，其余仍是硬编码中文（"待本地化"）。

### 2.15 `ToastAnchor` / `MenuBarToastAnimationState` / `MenuBarToastContentView` / `MenuBarToastManager` / `Toast`（Toast.swift）

- **职责**：全局提示卡。单例窗口复用、不销毁。
- **状态**：`toastWindow`、`hosting`、`hideWorkItem`、`animationState`（5 个 `@Published`）、`animationGeneration`。
- **层级**：`NSWindow.Level(Int(CGWindowLevelForKey(CGWindowLevelKey(rawValue: 14)!)))`——实测 2147483631。注释明确**不能用** `.utilityWindow`（桥接映射返回 19，不对）。
- **其它窗口属性**：`borderless` + `backgroundColor=.clear` + `hasShadow=false`（阴影由内容层画）+ `ignoresMouseEvents=true` + `hidesOnDeactivate=false` + `sharingType = .none`（**永不进截图/录屏**，长截图曾把它截进去）+ `collectionBehavior=[.canJoinAllSpaces, .fullScreenAuxiliary]`。
- **定位**：目标屏 = 面板窗所在屏 → 鼠标所在屏 → `mainScreen`；默认"屏幕中线偏下 6%"（2026-10-20 用户改需求，不再用原版 18.3% 底部公式）；`toastFollowPanel` 时贴面板下方 8pt。
- **风控**：`generation` 代际比对，连续 `show` 时旧 hide 作废。
- **`Toast` 静态入口**：签名 `show(_:icon:isWarning:)`，全工程调用点零改动。

### 2.16 `TransientWindowCenter`（TransientWindows.swift:18）

- **职责**：**唯一**的"点外/失焦自动收起"仲裁器（取代此前 5 套并存实现）。
- **状态**：`entries: [ObjectIdentifier: Entry]`，`Entry{ weak window, dismiss, isPinned, allowsClickIn }`；`localMonitor`、`globalMonitor`、`resignObserver`。
- **收起信号**：① `NSApplication.didResignActiveNotification`（最可靠、不要权限）② 本地点击落在注册窗之外 ③ 窗口 `resignKey` 转发 ④ 全局监视器（需辅助功能权限，仅作补充）。
- **不变量**：注册即"同一时刻只保留一个浮层"——`register` 末尾 `dismissAll(except: window)`。
- **白名单**：菜单栏区域（`screenPoint.y >= maxY - statusBar.thickness - 2`）、`Menu` 类窗口、`.popUpMenu`/`.mainMenu` 层级不触发收起。
- **坑**：`entries` 只在 `unregister` 时移除；窗口若被直接释放而没走 unregister，条目会**泄漏**（`window` 变 nil，遍历时被 `guard let` 跳过，但字典无限增长）；全局/本地监视器在 `entries` 非空期间常驻。

### 2.17 `RenderProbe` / `PanelWindowHandle`（RenderProbe.swift）

- **职责**：白屏排障。默认**关闭**（v73 性能审计：生产环境每 5s 全窗口快照会 5s 一次主线程遍历 + 一天 100KB+ 日志）。`FRSET_RENDER_PROBE=1` 开启。
- **状态**：`timer: Timer?`、`lastSnapshot: [String: String]`。
- **输出**：单行 `key=value`，`flags=alpha0,invisible,cvHidden,cvZero,noSubviews,noLayer,occluded`；无 flag 时"变化才打"。
- **架构破例**：直接引用 `PanelController.shared.panelFrameForPopout`、`PanelWindowHandle`（间接 `PanelController`）、`SettingsWindow`——**Core → Features 反向依赖**，与 `Registry.swift` 头注"功能模块之间禁止直接引用彼此具体类型"及本文件自身"避免依赖"意图冲突。因为探针默认关，编译期耦合但运行期零成本。
- **异味**：`snapshotAll` 里 `dumpWindow(PanelController.shared.panelFrameForPopout.map { _ in PanelWindowHandle.shared }, ...)` —— 对 `NSRect?`（或类似）做 `.map` 只为了转成常量，纯多余表达；行为等价但读起来像 bug。

### 2.18 `AppUpdateChecker`（AppUpdateChecker.swift:16）

- **职责**：可配置 feed 的更新检查 + 整包替换。
- **状态**：仅偏好键 `update.feedURL` / `update.ignoredVersion` / `update.lastCheckAt`。
- **流程**：`checkOnLaunch`（feed 空跳过 / <24h 跳过）→ `check(manual:)` → `URLSession` 取 `tag_name`/`html_url`/`body`/`zip_url|download_url|assets[0].browser_download_url`/`sha256` → 比较版本 → `presentUpdate`（`NSAlert.runModal`）→ 可选 `installUpdate`。
- **`installUpdate`**：下载到临时目录 → 可选 SHA256（CryptoKit）→ `ditto -x -k` 解压 → 找 `.app` → 写 `/tmp/frset-swap.sh`（sleep 2 → 备份 `/Applications/X.app.bak` → `ditto` 覆盖 → 失败回滚 → 去 quarantine → `open`）→ 起 `/bin/sh` → 0.8s 后 `NSApp.terminate`。
- **风险**：脚本用字符串插值拼 `appName`（来自 zip 内容）与 `newApp.path`（临时路径），未做 shell 转义；`rm -rf "$BACKUP"` 与 `mv` 无路径校验。只在自己构建的 feed 下安全（见 §7-P2）。

### 2.19 `FrsetNextApp` / `AppDelegate`（FrsetNextApp.swift）

- **职责**：App 入口。`Settings { EmptyView() }` + `commands` 把 ⌘, 指向自管设置窗（v85：**永远只有一个设置窗参与布局**，否则 `NSHostingView.layout → GeometryReader → layout` 死循环）。
- **`AppDelegate` 状态**：无实例字段，全静态入口。
- **生命周期**：`applicationDidFinishLaunching` → 单实例护栏 → `.accessory` → `AppBootstrap.start()` → `NSApp.servicesProvider = ArchiveServicesProvider.shared`。
- **`application(_:open:)`**：`frsetnext://` 深链路由，**全部包在 `DispatchQueue.main.async`** 里（Apple Event 上下文内建 NSWindow 会触发 `_postWindowNeedsUpdateConstraints` 异常，2026-10-16 实测）。
- **深链 host 全表**：`settings`(pane) / `statistics` / `monitor`(module) / `longshot` / `longshotdemo` / `longshotfinish` / `longshotcancel` / `longshotpreview` / `longshotcheck` / `ocr` / `translate` / `panel`(anchor=icon, monitor=, page=transfer|cast|performance) / `annotate`(file, tool) / `capture`(action) / `archive`(path, action=extract|compress|filebox|mini) / `cloudlink`(url, action=download) / `toast`(text, icon)。

### 2.20 `AppBootstrap`（AppBootstrap.swift:7）

- **职责**：唯一装配点。
- **状态**：`started`（幂等）、`screenshotTranslateLock`+`screenshotTranslatePending`（一次性会话标志）、`doubleTapBindingsKey`/`doubleTapTipSeenKey`。
- **启动序**：`disableAutomaticTermination` → `LogArchive.start()` → 8 个 `ModuleRegistry.register` → `startAll()` → `RenderProbe.install()` → `wireEventBuses()` → 预览数据桥 5 个 provider → 剪贴板文件自动暂存观察者 → 空投观察者 → `registerAppLevelTools()` → 音频设置页注册 → `registerDefaultHotkeys()` → `CloudLinkPromptController.start()` → 探针门 → 欢迎窗(1.5s)/WhatsNew(2.2s) → `AppUpdateChecker.checkOnLaunch()`。
- **依赖方向**：App 层是唯一允许同时引用所有 Features 具体类型的地方（契约允许）。
- **陷阱**：`start()` 在主线程同步跑完，期间 runloop 不 tick（`LogArchive` 的 10s 预热期就是为它准备的）。

### 2.21 `SQLiteDatabase` / `DatabaseManager` / `StatisticsManager` / `AnalyticsEvent`（Database.swift）

- **`SQLiteDatabase`**：`sqlite3_open_v2(FULLMUTEX)` + WAL + `foreign_keys=ON` + `journal_size_limit=1MB` + 启动即 `wal_checkpoint(TRUNCATE)`。`handle: OpaquePointer?` 非线程安全（但 FULLMUTEX 让 sqlite 内部串行）。4 个执行入口 `exec/run/query/scalarInt` + `transaction`。
- **`DatabaseManager`**：两库 `clipboard.sqlite` / `statistics.sqlite`，`init` 里 `migrate()`（clipboard 6 张表 + statistics 2 张表 + 旧宽表迁移）。**`fatalError` on init failure**——数据库打不开直接崩，没有降级。
- **`StatisticsManager`**：`queue = DispatchQueue("com.frset.statistics.queue")` 串行；`record` 异步、7 个"操作类"事件有 1s 去重窗口；8 个查询用 `queue.sync`；`importMerge` 事务内 `MAX(旧,新,0)`。
- **状态**：`lastEventTime`/`dedupeWindows`（**只在 queue 内访问**，这是正确用法）、`analyticsEnabled`（defaults `analyticsEnabled`，默认开）、`trackedEventNames`（54 枚举 + 5 裸串 + `ai_request_count` = 60）。
- **`AnalyticsEvent`**：`eventName` 把 camelCase 转 snake_case（手写循环，非正则）。

### 2.22 数据模型（Models.swift / SearchEngine.swift）

- `ClipboardItem`（24 字段，与 `clipboard_items` 列一一对应）、`ClipboardItemType`、`Tag`、`FileTypeIcon`、`ToolKind`(14)、`ToolInvocationRecord`、`LLMProviderKind`(4)、`LLMMessage`、`LLMChatSession`、`MonitorSample`（含功耗 4 字段）、`CalendarDay`（`id` = `yyyyMMdd`，static `DateFormatter` 复用）、`CalendarEvent`。
- `SearchEngine` + `SearchServiceManager`：11 内置引擎（URL 模板逐字对齐原作字面量）、品牌 logo 名映射、`activeBarItems`（默认 7 项，旧 3 项默认集自动迁移）、`engineOrder`（未入表引擎补在后面）、`customEngines`（JSON 编码进 defaults）、`{query}`/`{tl}` 模板替换。
- **不变量**：搜索栏**至少保留 1 项**（`removeFromSearchBar` 在 `count > 1` 才允许）；`activeBarItems` 里的孤儿 id 在 `load()` 时清洗。

---

## 3. 函数级清单

> 行号为声明起始行。`CSV` 列标注该符号是否在 `/tmp/frset_symbols.csv` 中（Y=有）。共 196 条 CSV 可调用符号全部在表内，另有 24 条 computed property / 私有辅助未入索引，单列在每张表末尾的「属性」行。

### 3.1 `Core/Support.swift`（14 func + 1 init = 15，CSV 15）

| 函数 | 行 | 说明 |
|---|---:|---|
| `Log.write(_:_:_:)` | 16 | debug 门控 + stderr + `LogArchive.append`。副作用：写 stderr/写盘。线程任意（写盘加锁）。失败模式：静默（全部 `try?`）。 |
| `Log.debug/info/warn/error` | 22–25 | 四个薄封装。 |
| `Log.breadcrumb` | 28 | 进 20 条环形缓冲 + 写盘（`pushBreadcrumb`）。 |
| `ModuleRegistry.register` | 43 | 锁内按 id 去重后 append。 |
| `ModuleRegistry.startAll` | 49 | 锁内快照 → 锁外逐个 `start()`。失败模式：某模块 `start()` 抛/崩会中断后续（无 catch）。 |
| `OCRTextObservation.init` | 77 | 值类型构造。 |
| `Theme.sectionHeader` | 200 | 小标题 View（11pt semibold + uppercase）。 |
| `Date.relativeFormatter` | 222 | 按"是否今天"选两个 static formatter 之一。 |
| `AppDirectories.sub` | 268 | 建子目录并返回 URL。副作用：`createDirectory`。 |

> 属性（未入 CSV）：`Log.isVerbose`、`ModuleRegistry.list/lock`、`ServiceLocator.lock/llm/ocr` 及 4 个访问器、`Theme` 8 个动态尺寸 + `accent/accentNS`、`Date.relativeText`、`String.sha256`、`String.truncatedForDisplay`、`Data.sha256Hex`、`AppDirectories.base`。

**散文（>40 行或带副作用）**

- `Log.write`（16–21）：唯一出口。两级过滤（debug + isVerbose）后**同步**写 stderr 再同步进 `LogArchive`（内部 `NSLock`）。因为 `appendRaw` 在锁内做 `seekToEnd`+`write`，主线程每打一条日志都可能等后台线程的整次写盘；这也是为什么全工程在热路径上（每帧/每行）都避免 `Log.info`。
- `Data.sha256Hex`（246–253 注释）：历史坑——曾手写纯 Swift SHA-256，消息调度字被 `& 0xffffffff` 掩成 32 位，32KB 输入（剪贴板指纹）崩溃（`FrsetNext-2026-10-15-111300.ips`）。现统一 `CC_SHA256`。**改这里必须用 `shasum -a 256` 对照空串/abc/1MB 三组向量**。

### 3.2 `Core/Registry.swift`（7，CSV 7）

| 函数 | 行 | 说明 |
|---|---:|---|
| `PanelSectionDescriptor.init` | 16 | 值构造（含 `build: () -> AnyView` 闭包）。 |
| `PanelSectionRegistry.register` | 24 | 锁内 removeAll(同 id) → append → 按 priority 排序。 |
| `SettingsPaneDescriptor.init` | 43 | 值构造。 |
| `SettingsPaneRegistry.register` | 51 | 同 id 覆盖（**不排序**，排序在 `all` 时做）。 |
| `StatusItemRegistry.register` | 97 | 同 id 覆盖 + priority 排序。 |
| `PanelControlling.toggle/show(atAnchor:)` | 123/124 | 协议默认实现，回落到无锚点版本。 |

> 属性：`PanelSectionRegistry.all`、`SettingsPaneRegistry.all/order`、`StatusItemRegistry.all`、`ServiceLocator.panel/settings/panelPreview`（6 个访问器）。

### 3.3 `Core/StateCompat.swift`（2，CSV 2）

| 函数 | 行 | 说明 |
|---|---:|---|
| `StoredBox.init` | 17 | 包一个 `@Published value`。 |
| `Stored.init(wrappedValue:)` | 24 | 造 `StateObject(wrappedValue: StoredBox(...))`。 |

> 属性：`Stored.wrappedValue`（nonmutating set）、`Stored.projectedValue`（现造 Binding）。

### 3.4 `Core/Preferences.swift`（4，CSV 4）

| 函数 | 行 | 说明 |
|---|---:|---|
| `Preferences.init(suiteName:)` | 10 | suite 不存在回落 `.standard`。 |
| `Preferences.value(_:default:)` | 16 | `object(forKey:) as? T`，类型不符静默回落。 |
| `Preferences.set` | 20 | 直写，nil 即 remove。 |
| `Preferences.binding(_:default:)` | 101 | SwiftUI Binding 适配。 |

### 3.5 `Core/Personalization.swift`（8，CSV 8）

| 函数 | 行 | 说明 |
|---|---:|---|
| `Personalization.init` | 121 | 私有；`load()`。 |
| `persist()` | 136 | 取消旧 `DispatchWorkItem`，150ms 后 `flushPersist`。主线程（didSet 均在主线程）。 |
| `flushPendingPersist()` | 145 | 立即落盘（退出前兜底）。 |
| `flushPersist()` | 151 | 写 15 个 defaults 键 + post `didChangeNotification`。**不校验线程**。 |
| `load()` | 173 | 读 15 键，`isLoading=true` 抑制 didSet 回写。 |
| `Personalization.color(fromHex:)` | 218 | 6/7 位 hex → Color；`Scanner` 解析失败返回 nil。 |
| `Personalization.hex(fromColor:)` | 228 | Color → 大写 6 位 hex；`usingColorSpace(.sRGB)` 失败返回 ""。 |
| `resetAll()` | 250 | 15 个属性一次性回默认（会触发 15 次 persist，但被防抖合并成 1 次）。 |

> 属性：`accentColorHex`（get/set 桥）、`effectiveThumbSize`、`accentPresets`、`didChangeNotification`。

**散文**

- `persist`/`flushPersist`（136–171）：v84 之前每个属性 didSet 都立刻写 15 个键 + 发通知，拖滑块时每帧一轮（15 写 + N 个状态栏监听者重建）淹掉主线程。现在防抖 150ms。**代价**：进程被 `kill -9` / 崩溃时最后 150ms 的个性化改动会丢；正常退出走 `flushPendingPersist()` 兜底。
- `load`（173–204）：`isLoading` 是关键。没有它时，按属性逐个赋值会让先赋值的属性触发 `persist()`，把还没读到的属性用默认值反写回盘（注释里的真实事故：`accentColor` 先赋值 → persist 把 `fontScale=1.0` 写盘 → 用户字号设置永远失效）。

### 3.6 `Core/LogArchive.swift`（12，CSV 12）

| 函数 | 行 | 说明 |
|---|---:|---|
| `LogArchive.init` | 49 | 建 `FrsetNext/logs` + `cleanupOldLogs()`。 |
| `start()` | 60 | 幂等；装 `CFRunLoopObserver`（beforeWaiting/afterWaiting/beforeTimers）+ 3 个 timer（看门狗 2s、状态 60s、清理 6h）+ 写启动横幅。 |
| `stop()` | 119 | cancel 3 timer、移除 observer、关 handle、`started=false`。 |
| `append(level:tag:message:)` | 137 | `appendRaw` 直通。 |
| `pushBreadcrumb` | 142 | 锁内 append + 截断到 20 + 写 DEBUG 日志。 |
| `checkHang()` | 152 | 预热期跳过；`stalled > 2.0` 记 HANG（每 5s 一次），恢复记 RECOVER。 |
| `appendStatus()` | 197 | `footprint / threads / uptime` 一行。 |
| `LogArchive.footprintMB()` | 206 | `proc_pid_rusage(RUSAGE_INFO_CURRENT).ri_phys_footprint`。 |
| `LogArchive.threadCount()` | 218 | `proc_pidinfo(PROC_PIDTASKINFO).pti_threadnum`。 |
| `appendRaw` | 246 | 组行 → 锁内按天切文件 → 超 4MB 丢 DEBUG → 写。 |
| `cleanupOldLogs()` | 280 | 按 mtime 删 >3 天的 `.log`。 |
| `tail(lines:)` | 300 | 读当前文件尾部 N 行（设置页「导出诊断」）。 |

**散文**

- `start()`（60–117）：三个 timer 全在 `global(qos:.utility)`，回调都包 `autoreleasepool`（v128：后台 timer 线程无 runloop tick，临时对象会更久才回收）。看门狗周期 v101 从 0.5s 降到 2s，**阈值仍是 2.0s**——注释承认"采样再稀会漏掉 2~5s 的短阻塞"，即 2~4s 的卡顿可能完全不被记录。这是有意的性能取舍，别当成 bug 去"修"。
- `checkHang()`（152–193）：`lastHangLogAt` 只在 `shouldLog` 分支内写且在锁外（`beatLock` 已释放），多线程下理论上可重入两次——但只有看门狗单线程调用，实际安全。
- `appendRaw`（246–277）：**在锁内做完整文件 IO**（close/open/seek/write）。日志量突增时（例如异常循环里 `Log.info`）会把所有调用线程（含主线程）串行堵在磁盘上。另外 `handle` 跨天切换时先 close 再重开，若 `FileHandle(forWritingTo:)` 失败，`handle` 为 nil，此后**所有日志静默丢弃**直到下一天。
- `tail()`（300–307）：读的是 `currentDay` 对应的文件；若跨过 00:00 且还没有新日志写入，`currentDay` 仍是昨天，读到的是旧文件——语义可接受。

### 3.7 `Core/LiquidGlass.swift`（9，CSV 9）

| 函数 | 行 | 说明 |
|---|---:|---|
| `LiquidGlass.reapplyStyle` | 65 | 已存在容器重套圆角/着色/材质（个性化即时生效）。 |
| `LiquidGlass.embed` | 84 | 内容铺满容器（glass 走 contentView，其余 addSubview + 4 约束）。 |
| `LiquidGlassBackground.makeNSView` | 106 | 建玻璃 + 异步把宿主窗口置透明。 |
| `LiquidGlassBackground.updateNSView` | 120 | 转 `reapplyStyle`。 |
| `WhiteGlassCard.body` | 186 | 白玻璃卡（渐变底 + 斜向高光 + 三色描边 + 投影）。 |
| `View.whiteGlassCard` | 225 | 修饰器入口。 |
| `SpringyIconButtonStyle.makeBody` | 237 | 按压 0.88 scale + 0.65 透明 + `springBouncy`。 |
| `HoverLift.body` | 252 | hover 放大 1.02（内部用 `@Stored`，**不是** `@State`）。 |

> 属性：`isSupported`、`reduceTransparency`、`prefersSolid`、`makeView`（无 `self` 的 static func 被索引漏收）。

### 3.8 `Core/AppearanceTheme.swift`（7，CSV 7）

| 函数 | 行 | 说明 |
|---|---:|---|
| `MidnightTheme.h` | 57 | RGB→HSB→hue+shift→Color；`hueShift==0` 直接返回原色。 |
| `AppearanceState.init` | 95 | public 空构造（非单例私有，允许测试实例）。 |
| `AppearanceThemeModifier.init` | 146 | 默认 `state: .shared`。 |
| `AppearanceThemeModifier.body` | 150 | 注入 4 个 environment 键（非 midnight 时全部 nil/false）。 |
| `View.frsetAppearanceTheme` | 168 | 修饰器入口。 |
| `View.frsetThemeChrome` | 175 | `.tint(Theme.accent)` + Midnight。 |
| `ThemeChromeModifier.body` | 188 | 观察 `Personalization` + `AppearanceState`。 |

> 属性：`AppearanceMode.title/systemImage`、`MidnightTheme.baseBackground/cardBackground/textColor`、`EnvironmentValues` 4 个键、`AppearanceState.isMidnight`。

### 3.9 `Core/L10n.swift`（6，CSV 6）

| 函数 | 行 | 说明 |
|---|---:|---|
| `L10n.t` | 30 | 查当前语言 bundle；缺失回退键面。 |
| `lprojBundle(for:)` | 38 | 缓存 `Bundle(path:)`；资源缺失返回 nil。 |
| `L10n.invalidateCache` | 47 | 清缓存（`apply` 调用）。 |
| `LanguageManager.init` | 106 | 读 defaults `language`，默认 `auto`。 |
| `LanguageManager.apply` | 126 | 规范化（不在表内→auto）→ 写盘 → 清缓存 → post `languageDidChange`。 |

> 属性：`L10n.isRightToLeft`、`resolvedLanguageCode`、`availableLanguages`、`displayNames`。

### 3.10 `Core/Toast.swift`（12，CSV 12）

| 函数 | 行 | 说明 |
|---|---:|---|
| `MenuBarToastManager.init` | 122 | 私有空构造。 |
| `MenuBarToastManager.show` | 127 | 线程安全入口：非主线程 `DispatchQueue.main.async` 转发。 |
| `present` | 135 | 空串早退 → 代际+1 → 取消旧 hide → `ensureWindow` → 换文案 → `layoutContent` → `positionOnTargetScreen` → alpha=1 + `orderFrontRegardless` → spring 显形 → 排 3s 隐藏。 |
| `hideAnimated` | 180 | spring 隐 → 0.4s 后（代际一致才）`orderOut`。 |
| `ensureWindow` | 194 | 建 borderless 透明窗 + level 14 + 穿透 + `sharingType=.none` + 内容视图 + `syncAppearance`。 |
| `makeContentView` | 221 | `NSHostingController(MenuBarToastContentView)`，透明 layer。 |
| `syncAppearance` | 231 | 读 `AppleInterfaceStyle` 设 `appearance`。 |
| `layoutContent` | 237 | `layoutSubtreeIfNeeded` → `fittingSize` → `setContentSize`。 |
| `resolveTargetScreen` | 249 | 面板屏 → 鼠标屏 → mainScreen。 |
| `positionOnTargetScreen` | 264 | 跟随面板 或 中线偏下 6% + 8pt 边距 clamp。 |
| `Toast.show` | 298 | 静态入口。 |

**散文**

- `present`（135–176）：**每次 show 都重新量尺寸并重新定位**，因为文案长度不同（胶囊 `fixedSize()`）。`toastWindow?.alphaValue = 1` 直接置 1，出现感完全交给 SwiftUI 的 `scaleEffect+opacity`，这是原作反汇编对齐的做法（`fmov d0,#1.0`）。日志里打 `frame` 是 2026-10-18 定位勘误时留下的排障点，**高频 Toast 场景会刷日志**。
- `ensureWindow`（194–219）：`level` 用 `CGWindowLevelKey(rawValue: 14)` 而非 `.utilityWindow`（实测后者 bridge 成 19）。`sharingType = .none` 是"提示卡永不进截图"的唯一手段——`SCK.excludingApplications` 对高 level 覆盖窗无效。
- `positionOnTargetScreen`（264–290）：两个分支都要对 `x/y` 做 `min/max` clamp，且用 `visibleFrame`（不含菜单栏/Dock）。`toastFollowPanel` 分支的 `y = max(visible.minY+8, panelFrame.minY - height - 8)`——面板贴着屏幕上沿时 Toast 会被 clamp 到屏幕底部而不是面板下方（视觉上"跳走"）。

### 3.11 `Core/TransientWindows.swift`（7，CSV 7）

| 函数 | 行 | 说明 |
|---|---:|---|
| `TransientWindowCenter.init` | 34 | 私有空构造。 |
| `register(window:isPinned:allowsClickIn:onDismiss:)` | 39 | 写 entries → 装监听 → `dismissAll(except:)`。 |
| `unregister` | 51 | 移除条目；空则停监听。 |
| `requestDismiss` | 57 | resignKey 转发：可见且未置顶才 dismiss。 |
| `dismissAll(except:)` | 64 | 遍历可见未置顶条目逐个 dismiss。 |
| `startMonitoringIfNeeded` | 73 | 三路监听（本地鼠标/全局鼠标/失活通知），各自判 nil 幂等。 |
| `stopMonitoring` | 101 | 全摘。 |
| `handleLocalClick` | 112 | 菜单栏白名单 → 菜单类窗口白名单 → 逐条目判 `frame.contains` 与 `allowsClickIn` → dismiss。 |

**散文**

- `handleLocalClick`（112–133）：用 `NSEvent.mouseLocation`（屏幕坐标）而不是 `event.locationInWindow`，所以必须用 `w.frame.contains(point)` 判定。菜单栏白名单用 `NSStatusBar.system.thickness` 推算，**多屏且菜单栏只在主屏**时会误判副屏顶部 22pt 也是"菜单栏"（副屏顶部其实是可用区域）→ 在副屏顶部点击不会收起浮层。这是已知的小偏差。
- 全局监视器分支（83–89）无条件 `dismissAll()`：点任何其它 app 都收起，包括"拖动窗口时松手"等鼠标按下事件。

### 3.12 `Core/ContinuousCorner.swift` / `FlowLayout.swift` / `OfficialWindowChrome.swift` / `PointingHandCursor.swift` / `RoundCloseButton.swift` / `RenderProbe.swift`（CSV 1 / 2 / 1 / 10 / 7 / 6）

| 函数 | 行 | 说明 |
|---|---:|---|
| `NSBezierPath.continuousRoundedRect` | 20 | 取 `RoundedRectangle(r, .continuous).path(in:)` 的 `cgPath` 逐元素搬到 `NSBezierPath`；半径 clamp 到 `min(w,h)/2`；quad 升阶成 cubic。 |
| `FlowHStack.sizeThatFits` | 13 | 单行累加 + 超宽折行，返回 `(maxWidth 或内容宽, 总高)`。 |
| `FlowHStack.placeSubviews` | 30 | 同样的折行规则落位。 |
| `NSWindow.applyOfficialChrome` | 28 | 灰底 + 透明标题栏 + 挂圆形关闭钮。 |
| `PointingHandCursor.init/body` | 20/22 | 背景挂 `PointingHandCursorRegionBackground`。 |
| `PointingHandCursorRegionBackground.makeNSView/updateNSView` | 29/36 | 建 `CursorRegionNSView`，`translatesAutoresizingMaskIntoConstraints=false`。 |
| `CursorRegionNSView.resetCursorRects` | 42 | `addCursorRect(bounds, .pointingHand)`。 |
| `CursorRegionNSView.updateTrackingAreas` | 46 | 先删全部再加 `[.cursorUpdate,.mouseEnteredAndExited,.activeAlways,.inVisibleRect]`。 |
| `cursorUpdate / mouseEntered / mouseExited` | 56/60/64 | `set()` 替换光标（**无 push/pop**，v132 修 hover 乱序导致光标卡死）。 |
| `hitTest` | 68 | 恒 nil，不参与命中。 |
| `View.pointingHandCursor` | 73 | 修饰器入口。 |
| `RoundCloseButton.init(frame:)` | 17 | 无边框、无标题、`momentaryChange`、无 focus ring。 |
| `RoundCloseButton.init(coder:)` | 26 | `fatalError`。 |
| `draw` | 28 | 画圆 + hover 画 ×；颜色随 aqua/darkAqua 动态。 |
| `updateTrackingAreas` | 54 | 重建 hover 区域。 |
| `mouseEntered/mouseExited` | 62/63 | 置 `isHovering` + `needsDisplay`。 |
| `NSWindow.attachOfficialRoundCloseButton` | 71 | 隐藏三红绿灯 → 取 contentView → 已有且换了 superview 则重挂并三次 `place` → 否则新建 + 关联对象。 |
| `place(_:in:)`（嵌套） | 80 | 按 `host.isFlipped` 算 y；`x=14,y=14 或 h-28`；14pt。 |
| `RenderProbe.install` | 34 | 仅 `isEnabled` 且未装过；5s `Timer` 加到 `.common`。 |
| `RenderProbe.snapshotAll` | 45 | 主线程异步：面板窗 + 按标题/类名匹配的 4 类窗口。 |
| `RenderProbe.snapshot` | 54 | 单窗口即时快照。 |
| `dumpNamedWindows` | 64 | 按 `SettingsWindow` 类型 / 标题含"性能监测/预览|检视/统计"命名。 |
| `dumpWindow` | 80 | 从 `PanelWindowHandle` 取窗。 |
| `emit` | 85 | 组 `key=value` 行；无 flag→变化才打；有 flag→必打。 |

**散文**

- `attachOfficialRoundCloseButton`（71–106）：为什么不用 Auto Layout——实测 `NSHostingView` 不参与子视图约束求解，`translatesAutoresizingMaskIntoConstraints=false` 后按钮 frame 恒为 0。为什么三次 `place`——挂载瞬间 `host.bounds` 还没布局（高度 128），必须 `async` 再 `asyncAfter(0.15)` 各补一次。`isFlipped` 必须判：NSHostingView 是 flipped，普通 NSView 不是，一律按未翻转算会挂到左下角。**这三个坑任一踩中都是"按钮不见了/位置错了"且无报错。**
- `continuousRoundedRect`（20–56）：`NSBezierPath(cgPath:)` 要 macOS 14+，部署目标是 13，所以手工搬 `CGPathElement`。quad 分支用标准 2/3 控制点升阶——如果系统改算法也不会丢段。
- `RenderProbe.emit`（85–110）：字符串拼 `flags` 后做 `flags.joined(...).contains("alpha0|cvZero|noSubviews")` —— 这是**把 `|` 当分隔符用的字符串字面量**，实际永远匹配不到（`joined` 用 `,` 连接）。`<<<< 异常` 标记从未出现。死逻辑。

### 3.13 `Core/AppUpdateChecker.swift`（6，CSV 6）

| 函数 | 行 | 说明 |
|---|---:|---|
| `AppUpdateChecker.init` | 20 | 私有空构造。 |
| `checkNowManual` | 44 | 手动检查（无论有无更新都 Toast/弹窗）。 |
| `checkOnLaunch` | 49 | feed 空或 <24h 跳过。 |
| `check(manual:)` | 56 | URLSession 取 JSON → 解析 tag/url/notes/zip/sha → 比较 → `presentUpdate`。回调切主线程。 |
| `installUpdate(zipURL:expectedSHA256:)` | 152 | 下载→可选 SHA256→`ditto` 解压→找 .app→写替换脚本→`/bin/sh` 执行→0.8s 后 `NSApp.terminate`。**起 2 个子进程 + 写 /tmp + 终止 App**。 |
| `compare(_:_:)` | 243 | 逐段取数字（正则剥非数字）比较，缺段按 0。 |

> 属性：`feedURL`、`currentVersion`、`Keys`。

**散文**

- `installUpdate`（152–238）：整条链在 `URLSession.downloadTask` 的后台回调里跑（`ditto` 用 `waitUntilExit` **阻塞该后台线程**，可接受但有更优写法）。`Data(contentsOf: tmp)` 把整个 zip 读进内存做 SHA256——大包（>500MB）会明显吃内存。脚本 `sleep 2` 等本进程退出，若用户在 0.8s 内又激活了 App 会与新进程竞争（`open` 时旧进程可能还在）。
- `compare`（243–254）：纯数字段比较，`1.2.10 > 1.2.9` 成立；`1.10.0-beta.2` 的 `beta`→剥成空串→`0`，可与 `1.10.0-beta.10` 判等（预发布序号被吃掉）——对当前用途足够。

### 3.14 `App/FrsetNextApp.swift`（6，CSV 6）

| 函数 | 行 | 说明 |
|---|---:|---|
| `AppDelegate.applicationDidFinishLaunching` | 33 | 单实例护栏 → `.accessory` → `AppBootstrap.start()` → 注册 servicesProvider → 可选 Toast 探针。 |
| `enforceSingleMenubarOwner` | 65 | 同 bundle 多实例→激活旧的并退出本进程；2.5s 后检测 `com.maoux.frset` 原版并提示。 |
| `applicationShouldTerminate` | 89 | 归档任务未完成时 `terminateCancel`。 |
| `applicationWillTerminate` | 94 | `Personalization.flushPendingPersist()` → `LogArchive.stop()` → `AppBootstrap.stop()`。 |
| `applicationShouldHandleReopen` | 101 | Dock/再次点击→`ServiceLocator.panel?.show()`。 |
| `application(_:open:)` | 112 | 17 个 host 的深链路由，整体 `async` 到下一 runloop。 |

**散文**

- `application(_:open:)`（112–278）：**所有窗口创建都延迟到 `DispatchQueue.main.async`**——Apple Event 处理上下文内建 `NSWindow`+`NSHostingView` 会在 display cycle 的 layout observer 里触发次级约束更新，抛 `NSWindow._postWindowNeedsUpdateConstraints`，最小视图也复现。`panel` 分支必须**先** `NSApp.activate` 再 `show`，否则 transient 面板成为 key 后立即 resign 被自动关闭。`URLComponents` 只解析一次（v126 前 `panel` 分支解析 4 次）。
- `enforceSingleMenubarOwner`（65–85）：两道防线是"进程内能做的全部"。原版 `Frset.app` 在跑无法阻止，只能提示。**返回 false 时直接 `return`，后续 `AppBootstrap.start()` 不执行**——即"第二个实例完全不初始化"，这是有意的（否则会建第二套 STATS）。

### 3.15 `App/AppBootstrap.swift`（20，CSV 20）

| 函数 | 行 | 说明 |
|---|---:|---|
| `start()` | 10 | 见 §2.20 启动序。主线程同步。 |
| `stop()` | 193 | 仅打一行日志（**没有实际清理**：热键/监听器都不摘）。 |
| `wireEventBuses()` | 199 | 5 个 `CaptureEventBus` 闭包 + `AIEventBus` + `ToolboxEventBus` + 3 个 `NotificationCenter` 观察者（自动暂存/空投/截图翻译/划词翻译）。 |
| `registerAppLevelTools()` | 255 | 注册 `colorpicker` 工具（走 `EyedropperPickBridge.pickColor()`）。 |
| `registerDefaultHotkeys()` | 377 | 先 `installDoubleTapBindings()`，再逐条判"用户自定义/双击模式"跳过，最后 `ShortcutRegistry.register`。 |
| `doubleTapModifier(for:)` | 410 | 读 `shortcuts.doubleTap` 字典。 |
| `installDoubleTapBindings()` | 415 | 注入全部 handler + 按默认表顺序恢复绑定（保证同修饰键"先者优先"稳定）。 |
| `setDoubleTap(_:enabled:)` | 429 | 开：写盘 + 注销组合键 + bind；关：删键 + unbind + 按覆盖值重注册。 |
| `setDoubleTapModifier(_:_:)` | 457 | 仅已开启时改修饰键。 |
| `presentDoubleTapCompatibilityTipIfNeeded()` | 467 | 无辅助功能权限且首次 → 弹提示窗（只弹一次）。 |
| `shortcutBinding(for:)` | 474 | 用户覆盖优先，否则默认表。 |
| `setShortcut(_:keyCode:modifiers:)` | 483 | 双击态先切回组合键；`bind` 失败返回 false；`keyCode=nil` 表示解绑（存空数组）。 |
| `restoreDefaultShortcuts()` | 503 | 全注销 + `unbindAll` + 清两个 defaults 键 + 重新注册。 |
| `userCustomizableToolID(for:)` | 514 | 仅 `colorPicker→colorpicker` 有用户自定义通道。 |
| `beginScreenshotTranslate()` | 528 | 置挂起标志 + `captureAndOCR()`。 |
| `takeScreenshotTranslatePending()` | 536 | 一次性消费标志（锁内）。 |
| `translateAndIngest(_:successTip:)` | 546 | `Task @MainActor` 翻译 → `ingestToolOutput` → Toast。 |
| `runTranslateSelection()` | 561 | 降级实现：翻译剪贴板当前文本（无 CGEventTap 取词）。 |

> 属性：`started`、`defaultHotkeys`（15 条）、`screenshotTranslateLock/Pending`、`doubleTapBindingsKey`、`doubleTapTipSeenKey`。

**散文**

- `start()`（10–191）：**唯一装配点，顺序即依赖顺序**。`ModuleRegistry.startAll()` 在主线程同步执行，期间 runloop 不 tick（`LogArchive` 10s 预热期的原因）。后半段全是"延后/门控"逻辑：欢迎窗 1.5s、WhatsNew 2.2s（且与欢迎窗互斥）、探针在 3s 后、`checkOnLaunch` 立即。`v143` 取消 OCR 预热是重要的性能决策：预热会把 43MB 运行时 + 10MB 模型常驻（RSS +54MB），`dlclose` 也还不了，所以改懒加载。**不要"优化"回去。**
- `wireEventBuses()`（199–249）：App 层是唯一知道"截图→剪贴板→统计"三方的人。`onImageCaptured` 里同时 `ClipboardManager.insertImage` + `bumpStat("screenshot_count")`；`onTextRecognized` 里先判空再插入，然后**消费**截图翻译挂起标志。注意：`onTextRecognized` 对**所有** OCR 生效，包括用户普通"截图提取文字"——只要挂起标志被消费过一次就复位，不会串台。
- `registerDefaultHotkeys()`（377–399）：三重跳过（用户自定义 / 双击模式 / 无绑定）。冲突时**后注册者失败**（`restoreAll` 先注册用户绑定，默认表后注册），失败计入 `ShortcutManager.failureReason`。注释里的 `restoreAll` 在本文件不存在，是 ShortcutManager 侧的方法名。
- `setShortcut`（483–501）：`guard ShortcutManager.shared.bind(definition) else { return false }`——**失败时不写 defaults**，所以用户录入的冲突组合键不会被记住，下次打开设置仍是旧值。这是正确行为但用户会觉得"点了没反应"（需要 UI 提示）。

### 3.16 `Storage/Database.swift`（27，CSV 27）

| 函数 | 行 | 说明 |
|---|---:|---|
| `SQLiteDatabase.init(path:)` | 26 | `open_v2(FULLMUTEX)` + WAL + FK + `journal_size_limit` + 启动 checkpoint。失败 throw。 |
| `exec` | 49 | `sqlite3_exec`；失败抛带 SQL 的错误。 |
| `bindValues` | 59 | 5 种 `SQLiteValue` 绑定，text/blob 用 `SQLITE_TRANSIENT`。 |
| `run` | 72 | prepare→bind→`step != DONE` 抛错。 |
| `query` | 86 | prepare→bind→列名外提→逐行转 `[String: SQLiteValue]`。 |
| `scalarInt` | 132 | 取首行首列 int，否则 0。 |
| `transaction` | 139 | `BEGIN` → body → `COMMIT`，catch 则 `ROLLBACK` 后 rethrow。 |
| `Dictionary.string/int/real/bool` | 155–158 | 取值便捷方法。 |
| `DatabaseManager.init` | 169 | 打开两库 + `migrate()`；**失败 `fatalError`**。 |
| `migrate()` | 180 | 建 6 张 clipboard 表 + 4 索引 + 2 张 statistics 表 + 旧表迁移。 |
| `migrateLegacyDailyStats()` | 284 | 旧 `daily_stats` 宽表 → `usage_daily_metrics` 窄表（列名映射 + day 规范化 + DROP）。幂等。 |
| `normalizedDay` | 313 | `yyyyMMdd` → `yyyy-MM-dd`。 |
| `bumpStat` | 332 | 旧列名 → 事件名，转 `StatisticsManager.record`。 |
| `StatisticsManager.init` | 435 | 取 statistics 库 + `ensureInstallDate()`。 |
| `record(_:day:)` | 443 | 门控 → 串行队列 → 操作类 1s 去重 → `ON CONFLICT` 累加。 |
| `record(_ event: AnalyticsEvent)` | 460 | 枚举重载。 |
| `totalCounts` | 466 | Q1 全量按事件。 |
| `todayCounts(day:events:)` | 478 | Q2 指定日按事件（IN 占位）。 |
| `activeDaysCount(events:)` | 493 | Q3 活跃天数。 |
| `dailyTotals(since:events:)` | 505 | Q4 每日总计（热力图）。 |
| `dailyBreakdowns(since:events:)` | 518 | Q5 每日按事件。 |
| `total(event:)` | 535 | Q6 单事件总计。 |
| `reviewRequestUsage` | 544 | Q7 `history_copy + screenshot_capture`。 |
| `exportAll` | 553 | Q8 全量导出。 |
| `importMerge` | 565 | 事务内 `MAX(旧,新,0)`，不削减。 |
| `ensureInstallDate` | 582 | `app_meta.install_date` 惰性初始化。 |
| `dayString(from:)` | 611 | `yyyy-MM-dd`；时区变了回落新建 formatter。 |

**散文**

- `SQLiteDatabase.init`（26–45）：WAL 无上限增长是真实事故（`statistics.sqlite` 主库 4KB / `-wal` 2.1MB）。`journal_size_limit=1MB` + 启动 `wal_checkpoint(TRUNCATE)` 两项都是幂等且无数据风险的。**`TRUNCATE` 仅在无其他读者时生效**，所以多进程（本 app + 原版 Frset）同开同一库时可能不收缩。
- `query`（86–130）：v126 把列名提取从"每行每列"提到循环外（N×C 次字符串分配 → C 次）。`SQLITE_TEXT` 用 `String(cString:)` 而非 `String(bytes:count:encoding:)`——**嵌入 0x00 的文本会被截断**；对剪贴板正文（走 `text_path` 文件，不落库）影响有限，但 `content` 列若含 NUL 会静默丢后半段。
- `record`（443–458）：整个去重判断 + 写库都在串行队列里，`lastEventTime` 是**该队列的私有状态**（无锁正确）。`ON CONFLICT ... count = MAX(0, count) + 1` 的 `MAX(0,…)` 只为兜住历史上被写成负数的行（`importMerge` 里 `MAX(旧,新,0)` 也会归零）。
- `importMerge`（565–578）：`queue.async` 异步，**调用方无法知道何时完成**；导入后立刻 `exportAll()` 可能读到旧值。导入 UI 若需要"导入即刷新"，必须自己做延时或用 `queue.sync` 包一层。
- `migrateLegacyDailyStats`（284–310）：整表读进内存逐行 INSERT（N 行 × 最多 5 个事件）。历史数据量小（按天一行），可接受；`try?` 吞掉所有错误，失败就是"迁移静默不完整"。

### 3.17 `Models/Models.swift`（6，CSV 6）

| 函数 | 行 | 说明 |
|---|---:|---|
| `ClipboardItem.makeDedupeKey` | 75 | image → `img:`+hash（**nil 时用 UUID → 永不去重**）；file/text → `file:/txt:` + content.sha256。 |
| `FileTypeIcon.init` | 109 | 值构造。 |
| `ToolInvocationRecord.init` | 129 | 值构造。 |
| `LLMMessage.init` | 145 | 值构造。 |
| `MonitorSample.init` | 194 | 全字段零值（`idleCPU=1`、`perCore=[]`、`temperatures=[:]`）。 |

> 属性：`ClipboardItem.displayTitle`（alias > title > content 截断 120 字）、`CalendarDay.id`（`yyyyMMdd`）、`ClipboardItem.init`（24 参数默认值构造，被索引计为 struct 而非 func）。

### 3.18 `Models/SearchEngine.swift`（16，CSV 16）

| 函数 | 行 | 说明 |
|---|---:|---|
| `SearchEngine.init` | 20 | 值构造。 |
| `SearchServiceManager.init` | 98 | 私有；`load()`。 |
| `searchURL(for:query:)` | 119 | `{query}` URL 编码替换、`{tl}` 目标语言替换 → URL。 |
| `addToSearchBar` | 143 | 去重后 append + 落盘。 |
| `removeFromSearchBar` | 152 | **仅 >1 时**允许移除。 |
| `moveInSearchBar(fromOffsets:toOffset:)` | 166 | 拖拽排序（toOffset 语义坑见注释）。 |
| `addCustomEngine` | 173 | 新建 `custom-UUID` + `rebuildOrder` + 落盘。 |
| `deleteCustomEngine` | 184 | 同时从激活集移除。 |
| `updateCustomEngine` | 195 | 改名/改模板，id 不变。 |
| `reloadFromDefaults` | 205 | 重新 `load()`（配置导入后用）。 |
| `moveEngine(engineID:up:)` | 212 | `swapAt` 相邻项 + 落盘。 |
| `resetToDefaults` | 222 | 清自定义 + 恢复 7 项激活集 + 删两个键。 |
| `load` | 233 | 解码自定义 + 按 order 排序 + 补孤儿 + 旧默认集迁移 + 清洗。 |
| `rebuildOrder` | 258 | 按现有 `allEngines` 序重建并落盘。 |
| `persistCustomEngines` | 268 | JSON 编码。 |
| `persistActiveBarItems` | 272 | 字符串数组。 |
| `persistEngineOrder` | 276 | id 数组。 |

**散文**

- `load()`（233–256）：三步容错——① `engineOrder` 里有但引擎已删（孤儿 id）→ `compactMap` 丢掉；② 引擎存在但不在 order 里（新增内置/自定义）→ 追加到末尾；③ `activeBarItems` 里的孤儿 id 清掉，清空则回默认集。**"至少一项"不变式**在此与 `removeFromSearchBar` 两处共同保证。
- `moveInSearchBar`（166–169）：`Array.move(fromOffsets:toOffset:)` 的 `toOffset` 是**移除前**坐标——向下拖要 `+1`。注释把换算责任明确推给调用方（`Settings/SearchSettingsPane`），这是本文件最容易踩的坑。

---

## 4. 关键数据流

### 4.1 启动（进程 → 全部模块可用）

```
NSApplication 启动
 └ AppDelegate.applicationDidFinishLaunching            [App/FrsetNextApp.swift:33]
    ├ enforceSingleMenubarOwner()  ← 同 bundle 多实例则 terminate 本进程    [:65]
    ├ NSApp.setActivationPolicy(.accessory)
    ├ AppBootstrap.start()                                                   [App/AppBootstrap.swift:10]
    │   ├ ProcessInfo.disableAutomaticTermination
    │   ├ LogArchive.shared.start()  → 3 timer + runloop observer            [Core/LogArchive.swift:60]
    │   ├ ModuleRegistry.register × 8 → startAll()  ── 跨模块边界：Panel/Settings/
    │   │      StatusBar/Monitor/Clipboard/Capture/AI/Toolbox 各自注入 ServiceLocator
    │   ├ PreviewPopoverDataBridge 5 个 provider（Panel ← Clipboard 数据桥）
    │   ├ NotificationCenter 观察者 ×4（filesCaptured / AirDrop / 📷翻译 / 划词翻译）
    │   ├ registerAppLevelTools()  → ToolRegistry.register("colorpicker")
    │   ├ SettingsPaneRegistry.register("audio")
    │   ├ registerDefaultHotkeys() → ShortcutRegistry/Carbon 15 条 + 双击绑定
    │   ├ CloudLinkPromptController.start()
    │   └ 延时：欢迎窗 1.5s / WhatsNew 2.2s / 更新检查（立即，异步）
    └ NSApp.servicesProvider = ArchiveServicesProvider.shared
```

### 4.2 埋点（用户动作 → 统计窗）

```
任意模块动作（截图/OCR/工具/复制…）
 ├ CaptureEventBus.onImageCaptured / onTextRecognized / onColorPicked   [AppBootstrap:201/217/229]
 │   → ClipboardManager.insertXxx() + DatabaseManager.bumpStat("…")   [Storage/Database.swift:332]
 │      → StatisticsManager.shared.record(event, day)                  [Storage/Database.swift:443]
 │         → queue.async（com.frset.statistics.queue）
 │            → analyticsEnabled 门控 → 操作类 1s 去重
 │            → INSERT … ON CONFLICT DO UPDATE count+1  → statistics.sqlite
 └ 统计窗打开：totalCounts/todayCounts/dailyTotals/dailyBreakdowns（全部 queue.sync）[466-532]
```

**跨模块边界**：Capture 不直接写库（只发 `CaptureEventBus`）→ App 层接线 → Storage。Toolbox 同理走 `ToolboxEventBus`。

### 4.3 个性化改动（设置页 → 三个窗口 + AppKit 侧）

```
设置滑块 didSet
 └ Personalization.@Published 变更 → SwiftUI 观察者立即重绘（同一 runloop）
    └ persist() 防抖 150ms → flushPersist()
       ├ 写 15 个 UserDefaults 键
       └ post .personalization.didChange  → AppKit 侧（窗口尺寸/材质/分隔线）重建
    退出时 applicationWillTerminate → flushPendingPersist()   [:96]
```

### 4.4 Toast

```
Toast.show(msg, icon, isWarning)   [Core/Toast.swift:298]
 └ MenuBarToastManager.show → 非主线程则 async 主线程 [:127]
    └ present()  → 代际+1 → ensureWindow（首次建 level-14 透明窗）
       → layoutContent（fittingSize）→ positionOnTargetScreen（面板屏/鼠标屏）
       → orderFrontRegardless + spring 显形 → 3s 后 hideAnimated → 0.4s 后 orderOut
```

### 4.5 深链（`open "frsetnext://…"`）

```
Apple Event → AppDelegate.application(_:open:)  [App/FrsetNextApp.swift:112]
 └ DispatchQueue.main.async（必须！否则约束异常）
    └ switch host → 各模块单例 / ServiceLocator 协议槽
       panel 分支：NSApp.activate → MonitorCenterPresenter.select* → ServiceLocator.panel?.show(atAnchor:)
```

---

## 5. 资源清单

### 定时器
| 位置 | 周期 | 门控 |
|---|---|---|
| `LogArchive.checkHang` | 2s（首 3s 后起） | 启动 10s 预热期跳过；`stalled>2.0` 才写 |
| `LogArchive.appendStatus` | 60s | 无 |
| `LogArchive.cleanupOldLogs` | 6h（首 6h 后） | 无 |
| `LogArchive` runloop observer | 每轮 runloop 的 beforeWaiting/afterWaiting/beforeTimers | 无 |
| `RenderProbe` | 5s `Timer`（`.common`） | `FRSET_RENDER_PROBE=1`，默认关闭 |
| `Personalization.persist` | 150ms 防抖 | `isLoading` 抑制 |
| `Toast` auto-hide | `toastDuration`（默认 3s）+ 0.4s orderOut | 代际一致 |

### 线程 / 队列
- 主线程：全部 UI、`Personalization` 落盘、`Toast`、`TransientWindowCenter` 监听、`AppBootstrap.start()`。
- `DispatchQueue.global(qos:.utility)` ×3：LogArchive 看门狗/状态/清理。
- `com.frset.statistics.queue`（串行）：`StatisticsManager` 全部读写/事务。
- `URLSession.shared` 回调：更新检查/下载（内部线程）。
- `Task { @MainActor }`：`translateAndIngest` / `runTranslateSelection`。

### 子进程
| 场景 | 命令 | 位置 |
|---|---|---|
| 更新解压 | `/usr/bin/ditto -x -k <zip> <payload>` | AppUpdateChecker.swift:181 |
| 更新替换 | `/bin/sh /tmp/frset-swap.sh`（内部 `rm -rf`/`mv`/`ditto`/`xattr -dr`/`open`） | AppUpdateChecker.swift:222 |
| 旧日志清理 | 无（纯 FileManager） | — |

### 文件路径（绝对）
- `~/Library/Application Support/FrsetNext/clipboard.sqlite`（+ `-wal`/`-shm`）
- `~/Library/Application Support/FrsetNext/statistics.sqlite`
- `~/Library/Application Support/FrsetNext/logs/YYYY-MM-DD.log` ← **注意 LogArchive 硬编码，不走 AppDirectories，DEBUG 也写这里**
- `~/Library/Application Support/FrsetNext-Dev/`（仅 DEBUG 的 `AppDirectories.base`）
- `$TMPDIR/frset-update-<UUID>/update.zip`、`…/payload/`
- `$TMPDIR/frset-swap.sh`
- `/Applications/<AppName>.app` + `.app.bak`

### UserDefaults 键（本范围写入）
- `Preferences.Keys.*`：`launchAtLogin`、`onboarding.welcomeSeenVersion`、`menuBar.iconsVisible`、`panel.width|height|pinned|transferDock|width.v2`、`search.category.{web,clipboard,files}`、`clipboard.{retentionDays,ignoredApps,storageLimitMB}`、`floatingClipboard.{originX,originY,width,height}`、`monitor.{refreshInterval,enabledModules,combinedMode}`、`capture.{soundEnabled,savePath}`、`ocr.languages`、`ai.{provider,model,baseURL}`、`toolbox.enabled`、`calendar.showLunar`、`ui.*`（15 个）
- 其它：`language`（L10n）、`AppleInterfaceStyle`（只读）、`analyticsEnabled`、`update.feedURL|ignoredVersion|lastCheckAt`、`shortcuts.bindings`、`shortcuts.doubleTap`、`shortcuts.doubleTapTipSeen`、`customEngines`、`engineOrder`、`activeBarItems`、`clearSearchInputAfterWebAction`、`probe.{lan,mcp,webdav,whatsnew}`、`FRSET_*` 环境变量（不入 defaults）

### 通知名
| 名 | 发出 | 收 |
|---|---|---|
| `personalization.didChange` | `Personalization.flushPersist` | AppKit 侧（窗口尺寸/材质/分隔线） |
| `languageDidChange` | `LanguageManager.apply` | 全 UI 刷新 |
| `NSApplication.didResignActiveNotification` | 系统 | `TransientWindowCenter` |
| `.frsetAirDropFiles` | 其它模块 | `AppBootstrap` |
| `ClipboardManager.filesCapturedNotification` | Clipboard | `AppBootstrap` |
| `.frsetScreenshotTranslate` / `.frsetTranslateSelection` / `.frsetFocusPanelSearch` | Capture / 热键 | `AppBootstrap` |

---

## 6. 不变量与陷阱

1. **`@State` 不可用**（缺 `SwiftUIMacros` 插件）。任何新视图状态必须 `@Stored`（`Core/StateCompat.swift`）；`@StateObject/@Binding/@Environment/@AppStorage/@FocusState` 可用。写成 `@State` 直接编译失败。
2. **`Settings` scene 只能是 `EmptyView()`**。v85 事故：SwiftUI `Settings` 空窗 + 自管 `NSHostingView` 窗**同时布局** → `NSHostingView.layout → GeometryReader → layout` 主线程死循环（sample 栈可复现）。⌘, 必须走 `commands` 转发到自管窗。
3. **Apple Event 上下文不能建窗口**。`application(_:open:)` 里所有窗口创建必须包 `DispatchQueue.main.async`，否则 `_postWindowNeedsUpdateConstraints` 异常（最小视图也复现）。
4. **transient 面板打开前必须 `NSApp.activate`**。否则面板成为 key 后立即 resign → `TransientWindowCenter`/`windowDidResignKey` 把它关掉（"打开即关"）。
5. **菜单栏监控只允许 STATS 合并条一套**。同 bundle 多实例必须退出；原版 `com.maoux.frset` 在跑只能提示。新增监控项若自建 `NSStatusItem` 会与 STATS 并列重复。
6. **`UserDefaults` 数值类型必须写入/读取一致**。`Preferences.value` 用 `as? T`，`Int` 写 `Double` 读会静默回落默认值。
7. **`LogArchive` 10s 预热期不能删**。bootstrap 主线程同步跑模块启动，期间 runloop 不 tick，删掉会误报"主线程阻塞 18s"。
8. **Toast 层级不能用 `.utilityWindow`**。必须 `CGWindowLevelKey(rawValue: 14)`（实测 2147483631）；`.utilityWindow` bridge 成 19，会被普通窗口盖住。
9. **Toast/覆盖窗必须 `sharingType = .none`**。`SCK.excludingApplications` 对高 level 覆盖窗无效，长截图会把它截进去。
10. **`attachOfficialRoundCloseButton` 的三次 `place` 与 `isFlipped` 判定不能简化**：NSHostingView 不参与子视图约束求解（Auto Layout 会让 frame 恒 0）；挂载瞬间 bounds 未布局（高度 128）；flipped 判错会挂到左下角。
11. **`Personalization.load` 必须保持 `isLoading` 抑制**。否则逐属性赋值会互相覆盖，用户设置永远失效。
12. **搜索栏至少 1 项**（`removeFromSearchBar` 门控 + `load()` 清洗回默认）。
13. **`StatisticsManager` 的 `lastEventTime`/`dedupeWindows` 只能在 `queue` 内访问**。在外部读写会数据竞争（当前实现正确）。
14. **连续循环动画只能线性**（v155）。给 `RotatingLayerView` 之类套 ease 会"转一下顿一下"。
15. **`.continuous` 圆角三路径统一**（v156）：SwiftUI 必须 `style: .continuous`；CALayer 必须 `cornerCurve = .continuous`；AppKit 手绘必须走 `NSBezierPath.continuousRoundedRect`。漏了就是 G1。

---

## 7. 重复实现 / 死代码 / 风险

### P0/P1（会坏功能或丢数据）

- **P1 `LogArchive.directory` 硬编码 `FrsetNext/logs`，绕开 `AppDirectories`**（LogArchive.swift:52）。DEBUG 构建的 `AppDirectories.base` 是 `FrsetNext-Dev`，但日志仍写 `FrsetNext/logs` → **开发版与正式版日志混在同一目录**，3 天清理会互相删。日志里有 `FRSET_*` 探针输出，混在一起会误判。
- **P1 `DatabaseManager.init` 失败 `fatalError`**（Database.swift:176）。磁盘满/权限异常/库损坏 → 启动即崩，无"进入安全模式/重建库"的降级路径。
- **P1 `AppUpdateChecker` 更新脚本未做 shell 转义**（AppUpdateChecker.swift:200-215）。`appName` 来自 zip 包内容、`newApp.path` 来自临时目录，两者直接插值进 `/bin/sh` 脚本，并且脚本里 `rm -rf "$BACKUP"`。feed 一旦被劫持（HTTP 或 DNS）可执行任意 shell。当前 feed 默认空 + 手动填写，风险受限但**分发时必须换 HTTPS + 强校验**。
- **P2 `Log.write` 在锁内做文件 IO**（LogArchive.swift:252-277）。异常循环里打日志会把主线程一起拖住（卡死看门狗反而会记录到"主线程阻塞"，掩盖真因）。
- **P2 `query` 用 `String(cString:)` 读 TEXT**（Database.swift:118）。含 `0x00` 的文本被截断，静默丢数据。

### 重复实现

- **两套"日志级别过滤"**：`Log.write` 的 `isVerbose` 门控 vs `appendRaw` 里"超 4MB 丢 DEBUG"。前者丢 debug 全部，后者只在超限时丢。`Log.breadcrumb` **绕过** `Log.write` 直接 `pushBreadcrumb → appendRaw`，所以 breadcrumb 的 DEBUG 行在 4MB 以下时**始终落盘**，与 `Log.debug` 行为不一致。
- **两套"屏幕目标解析"**：`Toast.resolveTargetScreen`（面板屏→鼠标屏→main）与 `ShortcutManager`/其它模块各自的 `NSScreen.main` 用法（他模块范围）。
- **`LiquidGlass.makeView` 与 `reapplyStyle` 的材质分支各写一遍**：`reapplyStyle` 对 VisualEffect 硬编码 `.hudWindow`，丢失调用方传入的 `material`。
- **`StatisticsManager.record` 与 `DatabaseManager.bumpStat` 与 `importMerge` 三处 `count` 累加 SQL**：`MAX(0, count)+1` / `MAX(旧,新,0)` 写法不一致（语义都正确，但改口径要改三处）。
- **`AppDirectories.base` 与 `LogArchive.init` 两套目录解析**（见 P1）。

### 死代码 / 无用符号

- **`RenderProbe` 整体默认关闭**，且 `emit` 里的异常标记判断 `flags.joined(separator: ",").contains("alpha0|cvZero|noSubviews")` **永远为 false**（把 `|` 当分隔符），`<<<< 异常` 后缀从未出现。`snapshotAll` 里 `PanelController.shared.panelFrameForPopout.map { _ in PanelWindowHandle.shared }` 是无意义表达。
- **`ToastAnchor.button`**（`weak static var`）注释自述"新定位不再使用"，保留只为兼容既有引用 —— 无引用点即死字段。
- **`LiquidGlass.embed(_:in:)`** 与 `LiquidGlassBackground` 在**本范围内无调用者**（消费点在 Features/Panel 等，需跨范围确认）；`GlassCardBackground` 同样。
- **`HoverLift`** 的 `extension View {}`（LiquidGlass.swift:260-261）是**空扩展**，纯残留。
- **`RoundCloseButton.init(coder:)` 的 `fatalError`**：从 nib 恢复会直接崩（当前无 nib，安全但脆）。
- **`AppBootstrap.stop()` 只打日志**，不摘热键、不关监听、不 flush —— 与 `start()` 严重不对称。

### 架构异味

- **`RenderProbe` 让 Core 反向依赖 Features**（`PanelController`/`SettingsWindow`/`PanelWindowHandle`），违反 `Registry.swift` 头注的契约。因为默认关闭所以运行期无成本，但破坏"Core 可独立 typecheck"的目标。
- **`Theme.accent` 的注释自相矛盾**（Support.swift:174 写"`Theme.accent` 不跟随个性化"，实际 `accent` 就是读 `Personalization.shared.accentColor`）。
- **`AppearanceState` 不是严格单例**（`public init()`），与同目录其它 `shared` 风格不一致；多实例会导致 `frsetThemeChrome()` 观察不到真正被写入的那个。
- **`L10n.bundleCache` 无锁**（见 §2.14）。
- **`TransientWindowCenter.entries` 无淘汰**（见 §2.16）。

### 建议（不改代码，仅记录）

- 日志目录应改走 `AppDirectories.sub("logs")`，一行修复 P1。
- `DatabaseManager.init` 失败应降级到内存库 + Toast，而不是 `fatalError`。
- 更新脚本应改为 `Process` 直传 `arguments`（避免 shell 拼接）或用 `NSFileManager` + 特权 helper。
