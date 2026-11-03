# A2 — FrsetStatsBar / MemoryHelper / OCRHelper 逐行测绘

范围：`Sources/FrsetStatsBar/`（14 文件：6 头 + 5 `.m` + 3 `.c`）、`Sources/MemoryHelper/`（1）、`Sources/OCRHelper/`（3），合计 **18 文件 / 10,577 行**。全部为 C / Objective-C / 独立 Swift 可执行文件，**不含 SwiftUI**。

符号索引对账：`/tmp/frset_symbols.csv` 是 Swift-only 索引，本目录仅覆盖 `MemoryHelper/main.swift`（10 条声明 / 8 个 func）与 `OCRHelper`（8 条 / 6 个 func）。**FrsetStatsBar 的 14 个 C/ObjC 文件不在索引内**，本文的函数清单由逐文件 grep + 通读人工核对得出：C 函数 **58 个**、ObjC 方法 **86 个**、C 静态辅助 **31 个**，合计约 **175 个可调用符号**（含 `static`）。后文每张表都把 static 一并列出，便于对照。

关键背景（`build.sh` 只读，未执行）：
- `Sources/FrsetStatsBar/*.c|*.m` 先由 `clang -c` 编成 `.o`，再与全部 Swift 一起交给 `swiftc` 链接；桥接头是 `FrsetStatsBar.h`（唯一 `-import-objc-header`）。
- `MemoryHelper/main.swift` 与 `OCRHelper/main.swift` **被排除在主 App 的 Swift 文件集之外**（`build.sh:36-38` 的 `-not -path`），单独 `swiftc` 编成两个可执行文件，放在 `FrsetNext.app/Contents/Library/PrivilegedHelperTools/com.sxyq.frsetnext.memoryhelper` 与 `Contents/Helpers/FrsetOCRHelper`，各自单独 `codesign`，**必须在主 App 签名之前完成**（否则破坏签名封印）。

---

## 1. 文件清单

| 路径 | 行数 | 一句话职责 |
|---|---:|---|
| `FrsetStatsBar.h` | 73 | 唯一桥接头：导出 tick 启停、点击回调、合并条按钮/锚点、深数据访问器、PP-OCR C API |
| `frset_barwidgets.h` | 112 | 部件引擎公共接口：`FSSnap` 快照结构、生命周期、设置读写 API、诊断探针 |
| `frset_stats_data.h` | 198 | 采集层接口：SMC/CPU/内存/网络/磁盘/电池/进程/GPU/SMART/连通性结构体与函数 |
| `frset_recorder.h` | 17 | 录屏对外 7 个函数 |
| `frset_runcat_frames.h` | 19 | 奔跑小猫帧资源（5 帧 × 黑白双版）取用接口 |
| `frset_sensor_names.h` | 20 | 传感器 key → 中文名/分组/类型/avg 标记 |
| `frset_barwidgets.m` | 3332 | **部件引擎核心**：配置存储（widgets.plist ↔ Stats 互通）、16 种形态绘制、状态项管理、合并条布局、位置校准/保邻、小猫动画、诊断探针 |
| `frset_barsettings.m` | 1242 | Stats 风格部件设置界面（侧边栏 + 部件选择条 + 逐部件设置块），v54 起改为深链到 App 设置窗 |
| `frset_recorder.m` | 1234 | 录屏：ScreenCaptureKit + AVAssetWriter，设置小窗/计时窗/区域框选/完成面板/GIF 导出 |
| `frset_stats_tick.m` | 267 | 采样 tick：0.5s 定时器 → C 采集 → `g_snap` → 引擎 tick（替代注入版的 `FSStatsView.tick`） |
| `frset_stats_data.c` | 1407 | 采集实现：SMC 直连、host_processor_info、vm_statistics、ifaddrs、IOBlockStorageDriver、AppleSmartBattery、IOAccelerator、NVMe SMART、ICMP 连通性线程、nettop 子进程线程 |
| `frset_ocr_onnx.m` | 228 | ONNX Runtime 的 dlopen 封装（PP-OCR 逐行识别），含遥测关闭与输入名兜底 |
| `frset_sensor_names.c` | 293 | 212 项传感器名表（含 `%` 单字符通配）+ 4 个查表函数 |
| `frset_runcat_frames.c` | 1804 | 10 段 PNG 字节数组（5 帧 × 黑白），纯数据 + 2 个取用函数 |
| `MemoryHelper/main.swift` | 184 | root LaunchDaemon：Unix socket + 白名单命令（`version`/`optimize-memory`），触发内核内存压力 + `purge` |
| `OCRHelper/main.swift` | 114 | 一次性 OCR 子进程：读 `FOCR1` 原始像素 + boxes.json → 逐行 PP-OCR → stdout JSON |
| `OCRHelper/LogStub.swift` | 14 | helper 用的 `Log` 桩（debug/info 丢弃，warn/error 写 stderr） |
| `OCRHelper/ocr_bridge.h` | 19 | helper 侧最小 C 声明（只链接 `frset_ocr_onnx.m`） |

---

## 2. 类型逐段

### 2.1 `FSSnap`（frset_barwidgets.h:19）

- **职责**：引擎的**唯一数据源**。tick 线程写、绘制线程读，全局单例 `g_snap`（`frset_barwidgets.m:16`）。
- **字段**：`valid`、CPU（usage/system/user/idle + `coreUsage[32]`/`coreCount`）、RAM（`ramRatio/ramAppRatio/ramCompRatio/ramWireRatio/ramUsedBytes/ramTotalBytes`）、磁盘（`diskUsedRatio/diskReadBps/diskWriteBps/diskTotalBytes/diskFreeBytes`）、网络（`netDownBps/netUpBps`）、电池（`batteryPresent/Charging/Percent/RemainMin`）、`gpuTemp`、`sensorValue`+`sensorKey[8]`、`load1/5/15`。
- **不变量**：所有 `*Ratio` 必须是 0..1；`sensorKey` 是 8 字节定长 C 串（`strncpy(...,7)` + 手动补 0）。
- **坑**：`g_snap` 是**非原子全局结构体**，tick（主线程 NSTimer）写、`drawRect`（主线程）读 —— 单线程所以安全。但 `FSBarRenderFormPreview` 在离屏上下文里构造临时 `FSSnap`，与 `g_snap` 无关，不会互相干扰。

### 2.2 `FSBarWidgetView`（frset_barwidgets.m:631）

- **职责**：一个部件 = 一个 view，按 `module`+`form` 自绘。
- **状态**：`module/form/snap/histN/lastUpdate/stableWidth/shrinkVotes`，ivar `_hist[130]/_histIn[130]/_histOut[130]`。
- **生命周期**：由 `g_views["module/form"]`（`NSMutableDictionary`）持有；`FSBarReconcile` 创建/淘汰，`FSBarRebuildModuleViews` 形态切换时整体移除重建。
- **关键实现事实**：
  - `isFlipped = YES`（所有绘制 y 轴向下）。
  - `hitTest` 恒 `nil` → 点击穿透到 `NSStatusBarButton`。
  - `viewDidChangeEffectiveAppearance` 触发 `setNeedsDisplay` → 菜单栏明暗反相时自动重绘。
  - 绘制入口 `drawRect` 用 `CGContextTranslateCTM(+FS_WIDGET_PAD, 0)` 把内边距吃掉，**16 个形态的绘制代码都不感知 pad**。

### 2.3 `FSBarManager`（frset_barwidgets.m:1928）

- **职责**：状态项按钮的 target（`openItem:` 独立项 / `openMerged:` 合并条）+ 合并条右键菜单 4 个 action。
- **生命周期**：`FSBarSystemStart` 里 `[[FSBarManager alloc] init]` 存 `g_manager`，进程级常驻。
- **依赖**：`FSBarOpenMonitor(int)`（由 `frset_stats_tick.m` 实现，最终回调 Swift 注册的 C 函数指针）。

### 2.4 `FSBarMergedView` / `FSBarSepView`（frset_barwidgets.m:2157/2163）

- 两者 `hitTest` 均返回 `nil`（点击穿透）。`FSBarSepView.drawRect` 就是一条 1pt 实心线（深色白/浅色黑）。

### 2.5 `FSRecSettings` / `FSRecEngine` / 录屏 UI 类（frset_recorder.m）

- `FSRecSettings`：7 个持久化字段（fps/resScale/areaMode/audioMode/format/dir/region+regionDisplay），读写 `widgets.plist` 的 `Recorder_*` 键。
- `FSRecEngine`：`SCStreamDelegate + SCStreamOutput`。状态 `stream/writer/vIn/sysIn/micIn/outPath/sessionStarted/vw/vh/droppedAudio/q/onStarted/onFinished`，ivar `_pendingSys/_pendingMic`（手动 `CFRetain` 的首帧音频）。
- 串行队列 `frset.recorder.video`：**所有 sampleBuffer 回调都在这个队列**。
- UI 类：`FSRegionView`（全屏选区 overlay）、`FSRecBarBox`（计时药丸）、`FSRecPanelView`（设置小窗，纯 `drawRect` + 命中矩形，无子控件）、`FSRecDoneView`（完成面板）。

### 2.6 `FSWidgetSelector` / `FSWidgetChip` / `FSSidebar`（frset_barsettings.m）

- `FSWidgetSelector`：44pt 高的部件选择条，chip 左右排列，**启用在前/停用在后**由 `resortChips` 维持；拖拽用 `trackEventsMatchingMask` 手写，无 NSCollectionView。
- **坑（重要）**：`activeCountAfterRemoving:` 与 `activeCountForIndexHint:` 两个方法都是**桩**（都直接返回 `[self activeCount]`，行 680/681），所以"拖过分隔线 = 切换启用态"的判定退化成"目标下标 < 当前启用数"。启用区/停用区交界处的拖拽语义不可靠。

### 2.7 `MemoryHelper`（root daemon）

- **职责**：`optimize-memory` = 写 `kern.memorypressure_manual_trigger`（`6<<16 | 4`，通知全部进程 + 丢弃 purgeable）→ `sleep(3)` → 复位到 normal → 跑 `/usr/sbin/purge`。
- **安全模型**：Unix socket `/var/run/com.sxyq.frsetnext.memory.sock`，`chown root:<安装用户组>` + `chmod 0660`；`getpeereid` 校验对端 UID == `/Library/PrivilegedHelperTools/com.sxyq.frsetnext.memoryhelper.client.json` 里的 uid；**只接受两个固定命令**，不接受 shell。
- **不变量**：`defer` 必须复位 normal，否则内核真实压力处理被永久禁用（代码注释明写）。
- **陷阱**：`loadAuthorization()` 在 `serve()` 启动时读一次；安装后换用户必须重启 daemon。

### 2.8 `OCRHelper`（一次性进程）

- **协议**：`FrsetOCRHelper <lib> <model> <dict> <raw> <boxes.json>`；raw = `"FOCR1"` + LE u32 width + LE u32 height + BGRA；boxes = `{"boxes":[[x,y,w,h],...]}`（像素、左上原点）。
- **输出**：stdout 一行 `{"results":[{"text":..,"confidence":..}|null,...]}`；stderr 一行 `recognised n/m`。
- **为什么是独立进程**（注释原文结论）：ONNX Runtime 在进程内**卸载不掉**（`ReleaseSession` + `dlclose` 后 dyld 镜像还在，RSS 不降），只有进程退出才能整块回收。
- **坑**：`boxes` 为空时**不加载模型**直接返回（省 100ms）；`PPOCROCR.shared` 来自 `Features/Capture/OCR/PPOCROCR.swift`，与主 App 共用同一份实现（`LogStub` 顶掉 App 的 `Log`）。

---

## 3. 函数级清单

### 3.1 `frset_barwidgets.m` — 公共 API / 配置层

| 函数 | 行 | 说明 |
|---|---:|---|
| `FSBarAllModules` | 33 | 7 模块常量数组（`dispatch_once` 缓存；v126 从每次新建 NSArray 改静态） |
| `FSBarModuleIndex`(s) | 41 | 模块名 → 面板索引 0..6，未知回落 0 |
| `FSBarFormsForModule` | 53 | 模块 → 支持形态表（v89 起通用 11 形态全模块放开），`dispatch_once` 缓存 |
| `FSBarFormName` | 80 | 形态 → 中文名 |
| `FSBarModuleName` | 93 | 模块 → 中文名（RAM→内存 …） |
| `FSBarNativeModule`(s) | 105 | 原生 autosaveName → 模块（`frset.metrics.*` 三项） |
| `FSBarStorePath`(s) | 119 | `~/Library/Application Support/FrsetStats/widgets.plist`，顺带建目录 |
| `FSBarStatsValue`(s) | 126 | 读 `eu.exelban.Stats` 域（CFPreferences），用于首启导入 |
| `FSBarImportableKeys`(s) | 132 | 可导入的 (form, key) 对表，41 项 |
| `FSBarSeedDefaults`(s) | 152 | 出厂默认（CPU 折线、RAM 柱、Disk mini、Net speed、Sensors mini…） |
| `FSBarImportFromStats`(s) | 168 | 从 Stats 导入模块列表/间隔/选项 + CombinedModules；原生三项保底 |
| `FSBarLoadStore`(s) | 214 | 幂等加载：有 plist 就读，没有就导入+种子+落盘 |
| `FSBarSaveStore` | 231 | 全量写 plist（`writeToFile:atomically:`），**每次 CfgSet 都整表重写** |
| `FSBarCfgKey` | 236 | `module_form_key` / `module_key` 拼键 |
| `FSBarCfgRaw` | 241 | 读配置（懒加载 store） |
| `FSBarCfgSet` | 246 | 写配置 → `g_cfgGen++` → **立即全量落盘** |
| `FSBarAsBool`(s) | 255 | NSNumber/NSString 宽松转 BOOL |
| `FSBarCfgBool/Str/Int` | 261/265/270 | 三个带默认值的读取器 |
| `FSBarEnabledForms` | 276 | 该模块启用的形态（逗号串 → 过滤 → **按 `g_cfgGen` 缓存**） |
| `FSBarSetEnabledForms` | 302 | 写回逗号串 |
| `FSBarModuleInterval`(s) | 307 | 刷新间隔，clamp 1..60 |
| `FSBarGlobalRaw/Set` | 313/318 | 全局键读写（CombinedModules 系列） |
| `FSBarGlobalBool/Str`(s) | 325/326 | 全局键类型化读取 |
| `FSBarMergedEnabled` | 333 | 合并显示开关，**默认 NO**（v44 改拆分默认） |
| `FSBarMergedSeparator` | 334 | 分隔线，默认 YES |
| `FSBarWidgetSpacing` | 340 | 统一间距 0..24（`Widgets_spacing` 优先，回落旧键） |
| `FSBarMergedSpacing` | 350 | 合并条内间距（兼容 `none` / `Widgets_uniform`） |
| `FSBarColorKeys` | 468 | 设置界面颜色候选 11 项 |
| `FSBarSaveStore` 之外的持久化入口 | — | `FSBarReloadFromStore` / `FSBarResetFromStats` / `FSBarResetToDefaults` 见 §3.4 |

**散文：`FSBarCfgSet`（246–253）**
一次配置写入 = 一次**完整 plist 重写**（`writeToFile:atomically:YES` 走临时文件 + rename）。设置界面里连续拖间距滑块（每次 `mouseDragged` 都可能 `CfgSet`）会产生每秒多次全表写盘。当前键总量 ~60 个，实测量级可接受，但**不要在这条路径上加高频调用**。`g_cfgGen` 递增是 `FSBarEnabledForms` 缓存失效的唯一机制——绕过 `FSBarCfgSet` 直接改 `g_cfg`（现有代码里有：`FSBarResetFromStats`/`FSBarResetToDefaults`/`FSBarPositionSave`）必须**手动** `g_cfgGen++` 或 `FSBarSaveStore`，否则形态列表会命中旧缓存。

### 3.2 `frset_barwidgets.m` — 颜色 / 数值 / 文本辅助

| 函数 | 行 | 说明 |
|---|---:|---|
| `FSBarAppearanceDark`(s) | 379 | 用 `effectiveAppearance bestMatch` 判 8 种外观（含 HighContrast/Vibrant）→ 暗色 |
| `FSBarProbeMenuBarDarkAsync`(s) | 393 | **空实现**（v77 移除截屏采样，保留调用点） |
| `FSBarDark`(s) | 405 | 直接转 `FSBarAppearanceDark` |
| `FSBarTextColor`(s) | 412 | 硬编码黑/白（不能用动态系统色：vibrant 上下文会解析成白） |
| `FSBarColorFromKey`(s) | 415 | Stats `SColor` 全表：`custom:#RRGGBBAA`、`monochrome/system/utilization/pressure/cluster` 动态色、25 个静态色；未知回落 accent |
| `FSBarGray`(s) | 475 | Stats `grayscaled()` 近似（0.299/0.587/0.114） |
| `FSSpeedStr`(s) | 482 | 速率格式化（十进制 1000，5 档） |
| `FSSpeedStrShort`(s) | 493 | 去掉单位（速度部件 oneRow） |
| `FSSizeStr`(s) | 500 | 容量格式化（1024 进制，`%.0f`/`%.1f`） |
| `FSRemainStr`(s) | 508 | 剩余分钟 → `H:MM`，<0 → `--:--` |
| `FSBarModuleValue`(s) | 515 | 模块主值 + 显示串 + 单位后缀（唯一的"模块 → 数值"映射点） |
| `FSBarModuleString`(s) | 556 | 主值显示串（CPU/RAM/Disk/Battery 原样，其余同） |
| `FSBarModuleIsRatio`(s) | 567 | 是否 0..1 比例类（决定折线是否按 max 归一） |
| `FSBarTextCenter`(s) | 576 | 居中绘制，**坐标 floor 到整数 pt**（防半像素发虚） |
| `FSBarTextRect`(s) | 581 | 矩形内对齐绘制，段落样式按 3 种对齐静态缓存（v129 省对象 churn） |
| `FSBarSymbolImage`(s) | 1593 | SF Symbol 静态缓存（v129：每次 drawRect 重建会触发 CoreSVG 解码，约 3.8MB 堆） |

### 3.3 `frset_barwidgets.m` — `FSBarWidgetView`（16 形态）

| 方法 | 行 | 说明 |
|---|---:|---|
| `initWithModule:form:` | 658 | 40×22 初始 frame |
| `isFlipped` | 668 | YES |
| `hitTest:` | 669 | 恒 nil（点击穿透） |
| `refreshWithSnap:` | 672 | 存快照 + `line_chart`/`network_chart` 追加历史（129 环形 + memmove）+ `setNeedsDisplay` |
| `netIn` / `netOut` | 691/697 | Network→上下行，Disk→读/写，其余 0 |
| `primaryValue` | 703 | 转 `FSBarModuleValue` |
| `labelWidth` | 711 | 7pt Light 标签实测宽 +1 |
| `stabilizeWidth:` | 715 | **宽度迟滞**：变宽立即、变窄需 <稳定宽-4 且连续 4 次才收 |
| `preferredWidth` | 737 | 16 形态各自算宽（mini 按文本 / speed 按双行文本 / 图表按 historyCount 档位 / battery 按 display 档） |
| `drawLabelColumn:at:dark:height:` | 858 | 竖排 3 字母标签列（自上而下） |
| `labelChars` | 870 | 标题前 3 字母大写反转 |
| `moduleLabel` | 889 | 模块短标签（Sensors 用传感器键、Disk 用 `Disk_mini_title` 默认 SSD） |
| `viewDidChangeEffectiveAppearance` | 906 | 外观变化 → 重绘 |
| `drawRect:` | 910 | 分发到 16 个 draw 方法；未知 form 回落 mini；含 `FRSET_APPEARCHK` 探针 |
| `drawMini:` | 952 | 形态 1：标签+值 两行 / 纯值一行 |
| `drawSpeed:` | 981 | 形态 2：双行/单行、icon(dots/arrows/chars/none)、`SpeedPictogramColor` 四态 |
| `drawSpeedIcon:at:rect:inC:outC:twoRows:` | 1073 | 三种图标的几何绘制 |
| `drawBarChart:` | 1139 | 形态 3：单柱 + 可选底盒/外框 |
| `inverseColor:` | 1168 | 深白/浅黑 |
| `pieSegments` | 1171 | CPU(user/system)、RAM(app/wire/comp)、Disk(used)、其余单段 |
| `drawPie:` | 1189 | 形态 4：自顶顺时针扇形 + 剩余灰段 |
| `drawTachometer:` | 1226 | 形态 5：180° 半圆轨道 + 值弧 + 中心值 |
| `drawRing:` | 1258 | 形态 13：整圆环 + 中心值 |
| `drawWave:` | 1291 | 形态 14：中点法二次贝塞尔平滑 + 渐变填充 |
| `drawDots:` | 1351 | 形态 15：2×4 点阵按比例点亮 |
| `drawProgressBar:` | 1379 | 形态 16：6pt 圆角条 |
| `drawLineChart:` | 1403 | 形态 6：右锚定 60 槽 + 4 种 scale（none/square/cube/log）+ 渐变面积 |
| `drawNetworkChart:` | 1483 | 形态 7：中线上下双图（in 上 / out 下，`reversedOrder` 交换颜色） |
| `drawMemory:` | 1556 | 形态 8：`F:`/`U:` 双行（Disk 复用为 已用/可用） |
| `drawBattery:` | 1606 | 形态 9：外壳 + 电池头 + 内填充 + 充电闪电 + 文本档位 |
| `drawState:` | 1660 | 形态 10：8px 状态点（Network 活跃/静止、Battery 电量分档） |
| `drawIcon:` | 1677 | 形态 11：15pt Semibold SF Symbol，模板着色 |
| `defaultSymbol` | 1693 | 模块默认符号 |

**散文：`preferredWidth` + `stabilizeWidth`（737–855 / 715–735）**
这是全引擎最"贵"的逻辑：每次调用都要 `sizeWithAttributes` 量文本（每 tick、每个部件、每种形态）。v98 曾把 speed 双行**定宽**（按 "888.8 MB/s" 计 62pt）以避免抖动，但轻流量时右侧空 15–20pt，视觉间距被撑大；v134 改为"实际宽 + 迟滞"。迟滞带必须是 **4pt**：v135 实测带 6pt 时 `"305 KB/s"→"29 KB/s"`（差 5.5pt）落在带内永不收缩，网络块锁在历史峰值宽度、右侧留 12pt 死空白。**改这个带宽等于改间距观感，不要凭直觉调。**

**散文：`drawRect:`（910–949）**
用 `CGContextTranslateCTM` 平移坐标系实现 pad，16 个形态的坐标可以全部按"内容区 0 起点"写。`_stableWidth` 的宽度由布局层（`preferredWidth + 2*pad`）决定，绘制层用 `W - 2*pad` 作为内容宽——两者必须同源，否则内容会被裁。

### 3.4 `frset_barwidgets.m` — 状态项管理 / 合并条 / 位置

| 函数 | 行 | 说明 |
|---|---:|---|
| `FSRunCatImage`(s) | 1710 | 帧 PNG → NSImage，按 `white-idx` 缓存 |
| `FSRunCatIconView.drawRect` | 1730 | 按高度定尺寸但不超过按钮宽（v82 防裁头尾） |
| `FSRunCatEnsureMainIconOverlay`(s) | 1751 | 幂等挂覆盖层、zPosition=1000、隐藏原图标子视图、清空 button.image、按 56:36 定主项宽 |
| `FSRunCatIconEnabled` / `SetEnabled` | 1798/1799 | 运行时开关 + 持久化 + 恢复原图标/宽度 + 发通知 `FrsetRunCatIconChanged` |
| `FSRunCatTick`(s) | 1816 | 懒初始化开关（env > `Bar_MainIconCat`）、CPU EMA 只在 CPU 刷新时刻更新、7 档倍速、8fps 基础步进、每 tick 最多 2 帧 |
| `FSRunCatStartTimer`(s) | 1891 | 10Hz `NSTimer`（`.common`） |
| `FSFindMainBarItem`(s) | 1908 | `g_mainItemRef` → `Item-0` → 首个非 `frset.` 前缀项 |
| `FSBarRebuildModuleViews`(s) | 1942 | 移除某模块全部视图（形态切换用） |
| `FSBarShowMergedMenu`(s) | 1953 | 合并条右键菜单：样式列表 / 分隔线 / 间距 / 打开面板 |
| `FSBarManager.openItem:` | 2025 | 独立项点击：反查模块 → 记录锚点 → `FSBarOpenMonitor` |
| `FSBarLastAnchorScreenRect` | 2044 | 最近点击锚点（屏幕坐标 1×1） |
| `FSBarSetDebugAnchorX` | 2045 | 调试直设锚点 |
| `FSBarManager.openMerged:` | 2051 | 合并条点击：CGWindowList 取真实窗口 x → 减 32pt 系统偏差 → 命中模块 → 右键弹菜单 / 左键开面板 |
| `mergedMenuToggleForm:` | 2123 | 切形态 → 删视图 → Reconcile |
| `mergedMenuToggleSeparator:` | 2133 | 切分隔线 → Reconcile |
| `mergedMenuSetSpacing:` | 2140 | 切间距 → Reconcile |
| `mergedMenuOpenPanel:` | 2148 | 打开面板 |
| `FSBarLog` | 2177 | 引擎日志 → `FrsetStats/engine.log`，>200KB 截断；**同步写盘** |
| `FSBarPositionRestore`(s) | 2199 | 从 `g_cfg[@"NSPos_<ident>"]` 恢复 `NSStatusItem Preferred Position` |
| `FSBarPositionSave`(s) | 2207 | 反向保存 |
| `FSBarMergedLayout`(s) | 2225 | 合并条布局：spacing + 1pt 分隔线 + 各部件 `preferredWidth + 2*pad`；同步 `mergedItem.length`；宽度变化时 0.5s 后保邻 |
| `FSBarEnsureMergedItem`(s) | 2295 | 建合并项（清 image、`sendActionOn(MouseDown|RightMouseDown)`、挂 mergedView） |
| `FSBarRemoveMergedItem`(s) | 2325 | 保存位置 → 摘视图 → removeStatusItem |
| `FSBarMainItem`(s) | 2344 | 主图标项（`g_mainItemRef` 优先，否则首个非 `frset.` 项） |
| `FSBarItemRect`(s) | 2356 | 状态项按钮窗口 frame |
| `FSBarItemsAdjacent`(s) | 2361 | 双向相邻判定（容差） |
| `FSBarItemsGap`(s) | 2368 | 双向最小间隙 |
| `FSBarRecreateMerged`(s) | 2373 | 移除 + 重建 + 重排（校准期 `g_posCalibrating` 抑制恢复） |
| `FSBarSetScreenGap` | 2412 | 接收 Swift 下发的屏幕口径空隙 |
| `FSBarKeepAdjacentToMain`(s) | 2414 | **保邻修正两级**：① 屏幕口径优先（目标 16pt，±6 容差，直接 `setFrameOrigin`）② 窗口口径回退（帧稳定性闸门 + 容差 6）；连续 6 次无效 → 升级完整校准（60s 冷却、每会话上限 3 次） |
| `FSBarKeepAdjacentTick` | 2489 | tick 入口；稳态（gap 达标）直接 return，零主队列 hop |
| `FSBarSetMainItem` | 2502 | 注册主图标项（不注册则保邻/校准全部静默跳过） |
| `FSBarMergedItem` | 2508 | 合并项访问器（探针用） |
| `FSBarDebugPosProbe` | 2514 | 位置探针 + 两个**会 `sleep(1.5)` 的实验**（新名项 / 主图标克隆） |
| `FSBarWaitStableFrame`(s) | 2571 | 每 0.3s 轮询，连续两帧相同才算稳定，最多 5 次 |
| `FSBarStartPositionCalibration`(s) | 2601 | 候选值扫描 `[500,600,400,1000,0,1500,-500,2000]`，每个候选重建项 + 等稳定 + 量 gap，命中即采用；全失败恢复 500 |
| `FSBarHideNativeSubviews`(s) | 2665 | 隐藏 `Hosting`/`MenuBarMetric` 子视图（自愈） |
| `FSBarMount`(s) | 2676 | 把部件挂到状态项（定长 → 加子视图 → 置顶 → 同步 frame） |
| `FSBarReconcile`(s) | 2704 | **双模式重建**：合并（隐藏原生、清独立项、建视图、layout）/ 独立（原生挂首个形态 + 其余各建项、清孤儿） |
| `FSBarRefreshAllWidgets`(s) | 2807 | 全量 `setNeedsDisplay`（v19 遗留，当前无调用者） |
| `FSBarRefreshValues`(s) | 2816 | 按模块间隔调 `refreshWithSnap` |
| `FSBarReloadFromStore` | 2828 | 懒加载 + `g_cfgGen++` + Reconcile |
| `FSBarResetFromStats` | 2834 | 清表 → 从 Stats 重导入 → 落盘 → Reconcile |
| `FSBarResetToDefaults` | 2846 | 清表 → 种子默认 → 落盘 → Reconcile |
| `FSBarResolveNativeItems`(s) | 2855 | 扫 `g_statusItems` 填 `g_nativeItems` |
| `FSBarDumpItems`(s) | 2863 | 状态项清单 + 自有项坐标/宽度/间隙日志 |
| `FSBarSystemTick` | 2893 | **每 0.5s**：解析原生项 → Reconcile → 刷新值 → 明暗探针（空） → 第 1/8 tick dump |
| `FSBarSystemStart` | 2906 | 加载 store → 建三个字典 + manager → 解析原生项 → 启小猫定时器 → Reconcile → 3s 后校准 |
| `FSBarDebugMergedReady` | 2932 | 布尔探针 |
| `FSBarDebugPanel`(s) | 2934 | 按类名 `Frset.FloatingPanel` 找面板窗 |
| `FSBarDebugMainItem`(s) | 2941 | 首个非 `frset.` 项 |
| `FSBarDebugCGPointForButton`(s) | 2949 | 按钮中心 → CG 全局坐标 |
| `FSBarDebugSyntheticClickAtCG`(s) | 2956 | 合成鼠标点击（HID tap） |
| `FSBarDebugPostToPidClick`(s) | 2969 | 向本进程投递点击 |
| `FSBarDebugPostInAppClick`(s) | 2983 | `NSApp postEvent` 直投 |
| `FSBarDebugPostTapClick`(s) | 3001 | 指定 tap 投递 |
| `FSBarDebugClosePanelIfNeeded` | 3014 | 面板可见则 `performClick` 主图标关掉 |
| `FSBarDebugClickProbe` | 3021 | **T1–T6 六组点击链路对照实验**（约 15 层嵌套 `dispatch_after`，静默 sleep 累计 >20s） |
| `FSBarModuleSymbol` | 3150 | 模块 SF Symbol |
| `FSBarPreviewSnap`(s) | 3162 | 预览用合成快照（正弦抖动） |
| `FSBarRenderFormPreview` | 3184 | 渲染预览图：24 帧喂历史 → 2x 位图 → **逐像素扫 alpha 包围盒裁剪**（w×h×4 次 `getPixel`） |
| `FSBarDebugAppearanceProbe` | 3255 | 打印各层 appearance |
| `FSBarDebugCharProbe` | 3283 | 4s 后打印合并条完整状态 + 写 `/tmp/frset_merged_bar.png` |

**散文：`FSBarReconcile`（2704–2804）**
每 0.5s 调一次，是**幂等重建**而非纯增量：合并模式下遍历 7 模块 × 形态表 → 缺视图补建 → 清孤儿；独立模式下还会对每个缺失项 `statusItemWithLength:`。这意味着**任何地方的配置抖动都会在 0.5s 内体现**，但也意味着 `NSStatusBar` 的增删调用在异常配置下可能高频发生（每次增删都触发系统重排 → 保邻修正介入 → 又触发校准）。这是"位置漂移"问题的放大器，v30 的两级对策与 60s/3 次上限就是为它设的闸。

**散文：`FSBarStartPositionCalibration`（2601–2661）**
校准是"改 `NSStatusItem Preferred Position` → `removeStatusItem` + 重建 → 等稳定 → 量 gap"的**候选值扫描**，8 个候选、每个约 0.3–1.5s，最坏 >10s。期间 `s_calibrating` 互斥、`g_posCalibrating` 抑制位置恢复。注释记录了两条血泪：① 原候选扫描 0.6s 后读到的是系统"暂放位"（x=860 w=196），数字上恰好相邻 → 误判成功；② position→x 的增益约 **13:1**（ΔP 501 ↔ Δx 38），按 gap 等量微调永远追不上。**改这段之前先读这两条。**

**散文：`openMerged:`（2051–2120）**
菜单栏状态项窗口的 AppKit 坐标**不可靠**（`win.frame` 实测比真实位置偏 24pt），`locationInWindow` 又恒为按钮中心；macOS 26 上 `NSWindow.frame` 还整体右移 **32pt**（`kStatusItemFrameDX`）。所以命中测试走 `CGWindowListCopyWindowInfo` 取真实 x，再用 `(窗口宽 - 合并视图宽)/2` 补偿内边距。这段常量是**屏幕/系统版本相关**的实测值（注释已写明"若未来系统修正该偏差，把常量改 0"）。

### 3.5 `frset_stats_tick.m`

| 函数 | 行 | 说明 |
|---|---:|---|
| `FSStatsSetOpenMonitorHandler` | 54 | Swift 注册点击回调（C 函数指针，非 block） |
| `FSBarOpenMonitor`(s) | 56 | 有回调则转发，否则 NSLog 警告 |
| `FSBarCopySensorKeys` | 67 | 懒扫描 SMC（600 键）+ 只返回 `category==0`（温度类）；v88 修"BDAT 显示 5388°" |
| `FSBarDebugCurrentModule` | 92 | 恒 -1（注入版遗留下来的空实现） |
| `collectTemps`(s) | 96 | 温度降序插入排序 + 前缀过滤（TV/TG） |
| `statsTick`(s) | 112 | 采样主体：CPU/RAM 每拍、net/disk/batt 隔拍、loadavg 每拍、disk 容量每 60 拍、SMC 扫描每 12 拍（后台线程）→ 填 `g_snap` |
| `FSStatsTickStart` | 209 | 幂等：开 SMC、起连通性线程、立即采样、0.5s `NSTimer`（`.commonModes`，体包 `@autoreleasepool`）、启动引擎 |
| `FSStatsTickStop` | 232 | 停 timer + 关 SMC |
| `FSStatsProcName` | 241 | `frset_proc_t*` → name（Swift 侧 C 数组成员不便访问） |
| `FSStatsProcPath` | 247 | → path（v86：归类/图标的唯一可靠依据） |
| `FSStatsSensorKey` | 251 | → key |
| `FSStatsConnHistoryAt` | 255 | → `history[i]`，越界返回 -1 |
| `FSStatsRootFileSystem` | 261 | `statfs("/")` 的 `f_fstypename`（静态缓冲） |

**散文：`statsTick`（112–202）**
所有采样都跑在**主线程**（NSTimer 在 mainRunLoop），只有 SMC 全量扫描被 `dispatch_async` 到 `QOS_CLASS_UTILITY`（v49：单次 ~150ms，是菜单栏周期尖峰元凶）。跨线程发布用 `_Atomic int s_sensorCountA` + `release/acquire`（注释明写"数据发布后不可变，主线程无锁读取不撕裂"）——**这个配对不能拆**，改成普通 `int` 会出现读到半个数组的撕裂。`g_snap.sensorKey` 用 `strncpy(...,7)` + 手动 `[7]=0`，因为字段只有 8 字节。

### 3.6 `frset_stats_data.c`

| 函数 | 行 | 说明 |
|---|---:|---|
| `smc_raw`(s) | 49 | `IOConnectCallStructMethod` 的 SMC 裸调用 |
| `str2key` / `key2str`(s) | 54/58 | 4 字符键 ↔ uint32 |
| `smc_keyinfo`(s) | 63 | 取键元信息（dataSize/dataType） |
| `smc_read`(s) | 71 | 读键字节（≤32） |
| `parse_value`(s) | 85 | 8 种 SMC 数据类型解码（flt/sp78/fpe2/ui8/ui16/ui32/sp5a/sp87/fp88/fpa4），未知 -9999 |
| `frset_smc_open` | 100 | 幂等打开 AppleSMC |
| `frset_smc_close` | 109 | 关闭 |
| `categorize`(s) | 113 | key 首字母 → 类别（T/F/V/I/P/B） |
| `plausible`(s) | 123 | 类型白名单 + 每类值域过滤 |
| `frset_smc_scan` | 138 | 按 `#KEY` 总数遍历 ≤4096 键，解码 + 过滤，返回数量 |
| `frset_cpu_sample` | 171 | `host_processor_info` + 与上轮差分 → usage/user/system/idle/per_core |
| `frset_loadavg` | 212 | `vm.loadavg` |
| `frset_mem_sample` | 225 | `hw.memsize` + `HOST_VM_INFO64`（active+wire+compressor）+ swap |
| `frset_net_sample` | 256 | `getifaddrs` 累加（跳过 lo/utun/bridge/awdl/llw）+ 时间差分 |
| `frset_disk_sample` | 288 | `IOBlockStorageDriver` 的 `Bytes (Read/Write)` 求和 + 差分 |
| `frset_battery_sample` | 333 | AppleSmartBattery：容量三级回退链（AppleRawMax→BatteryData→MaxCapacity）、温度三级回退（根→BatteryData→SMC TB1T/TB2T）、适配器/充电段、PPBR/PDTR 功率 |
| `frset_disk_capacity` | 475 | `statfs("/")` |
| `frset_net_ip` | 488 | en0 IPv4 |
| `frset_battery_remaining_sec` | 504 | `IOPSGetTimeRemainingEstimate` |
| `frset_mem_pressure` | 514 | `kern.memorystatus_vm_pressure_level` |
| `frset_nowsec`(s) | 521 | `CLOCK_MONOTONIC` 秒（double） |
| `frset_proc_top` | 562 | 进程排行：`proc_listallpids` + 每 pid `proc_pid_rusage(V4)`/`proc_name`；200ms 扫描缓存；按 kind 各自差分；top-N 选择排序 |
| `frset_bundle_of`(s) | 674 | 路径 → `.app` 前缀键 |
| `frset_proc_grouped` | 685 | 按 bundle 聚合（cpu/mem/disk 求和、pid 收集 ≤64）→ 按 kind 降序 |
| `frset_kill_bundle` | 749 | 按路径前缀匹配系统进程，跳过自身，SIGTERM/SIGKILL |
| `frset_gpu_usage` | 776 | IOAccelerator `PerformanceStatistics` 三利用率 |
| `frset_gpu_model` | 811 | IOAccelerator `model`（CFData 或 CFString） |
| `frset_cpu_clusters` | 851 | `hw.perflevelN.logicalcpu`（Intel 返回 -1） |
| `frset_cpu_cluster_usage` | 866 | 按集群切分 `per_core` 求均值 |
| `frset_smc_read_fan` | 879 | `F%dAc` RPM，越界返回 -1 |
| `frset_smc_read_key` | 896 | 任意 SMC 键 → double；失败 NAN |
| `frset_smc_read_string` | 909 | `ch8*` 字符串键（去首尾空白/控制字符） |
| `frset_fan_count` | 931 | `FNum` 优先，否则探测 F0..F3 |
| `frset_conn_set_active` | 965 | 暂停/恢复 ICMP 探测 |
| `frset_icmp_checksum`(s) | 969 | 标准反码和 |
| `frset_conn_push`(s) | 977 | 90 样本状态环（memmove） |
| `frset_conn_thread`(s) | 988 | 1 包/秒 ICMP echo（1.1.1.1、SOCK_DGRAM、指纹=发送时刻）→ RTT/jitter EMA(1/16) → 90 样本环 + 增量均值 → 加锁发布 |
| `frset_conn_start` | 1113 | 幂等起线程（detach） |
| `frset_conn_sample` | 1120 | 加锁拷贝快照 |
| `frset_block_storage_device`(s) | 1170 | BSD 名 → 上溯 `IOBlockStorageDevice`（最多 16 层） |
| `frset_disk_smart` | 1185 | NVMe SMART（30s 缓存；IOKit plugin interface + `SMARTReadData`；字段 LE 解码） |
| `frset_disk_model` | 1244 | `Device Characteristics → Product Name` |
| `frset_disk_interconnect` | 1261 | `Protocol Characteristics → Physical Interconnect` |
| `frset_net_top_set_active` | 1292 | 暂停/恢复 nettop 轮询 |
| `frset_net_top_thread`(s) | 1296 | 每 5s `popen("/usr/bin/nettop …")` → CSV 解析 → 与上轮差分 → 按 max(rx,tx) 排序 → 加锁发布 |
| `frset_net_top` | 1399 | 首次调用起线程；加锁读缓存 |

**散文：`frset_proc_top`（562–666）**
三段性能改造都在这一个函数里，且互相耦合：① `FRSET_PROC_CAP` 从 2048 降到 **512**（省约 1MB 静态堆），代价是进程数 >512 时**按枚举序截断**，top 表可能漏掉枚举靠后的进程；② 200ms 扫描缓存（`readProcList` 一个周期内对 kind 0/1/2 连调三次，原来每次全量扫）；③ 每个 kind 各自保留上一轮快照（v86 前共用一份 → 第 2/3 次调用 `dt≈0` → 磁盘速率恒 0）。缓存命中时 `t` 会**回拨到扫描时刻**，否则 dt 会被算大、速率偏低。所有写入都在 `ncur < CAP` 条件内，边界安全。

**散文：`frset_battery_sample`（333–471）**
这是全文件最长的函数，因为它维护**三条回退链**：容量（`AppleRawMaxCapacity` → `BatteryData.FullChargeCapacity` → `NominalChargeCapacity` → `MaxCapacity`）、温度（根 `Temperature` → `BatteryData.Temperature` → SMC `TB1T/TB2T` 均值）、功率（`PPBR` → 电压×电流）。注释记录了两次真实翻车：① Apple Silicon 上 `MaxCapacity` 是**百分比(100)**，直接当 mAh 用会把"最大容量"显示成 100 mAh；② 本机（M5/macOS 26）根节点没有 `AppleRawMaxCapacity`，必须补 `BatteryData` 分支。`g_battSvc` 句柄缓存 + 失效重取是 v126 的 IOKit 优化（原每秒一次注册表匹配 ~100µs）。

**散文：`frset_net_top_thread`（1296–1397）**
每 5s `popen` 一个 `/usr/bin/nettop` 子进程，`-L 1` 采样约 1s。解析按逗号切三段（name.pid, rx, tx）；name 被 nettop 截断到 15 字符，所以再用 `proc_name` 补全名、`proc_pidpath` 取路径——**`proc_pidpath` 的缓冲区必须 ≥4096**（v86：用 512 时恒定返回 0，图标/归类全失效）。差值用 `CLOCK_MONOTONIC`，`dt < 0.5` 兜底为 0.5。

### 3.7 `frset_barsettings.m`

| 函数 | 行 | 说明 |
|---|---:|---|
| `FSActionHub.shared/handle:` | 30/31 | 用关联对象把 block 挂到控件上，统一 target-action |
| `FSSetAction`(s) | 36 | 给任意 NSControl 装 block 动作（`OBJC_ASSOCIATION_COPY_NONATOMIC`） |
| `FSL`(s) | 43 | 内置 90+ 条 zh-Hans 文案表（Stats 官方译文，键=英文句） |
| `FSFormDisplayName`(s) | 103 | 形态 → 官方部件名译文 |
| `FSFlipStack.isFlipped` | 118 | YES（文档翻转） |
| `FSText`(s) | 122 | 造 NSTextField |
| `FSNewSwitch`(s) | 135 | 造 NSSwitch（禁初值隐式动画） |
| `FSNewSelect`(s) | 150 | 造 NSPopUpButton（key↔标题） |
| `FSNewButton`(s) | 171 | 造 NSButton |
| `FSColorHex` / `FSColorResolve` / `FSColorItems`(s) | 179/185/202 | 颜色键 ↔ NSColor ↔ 下拉项 |
| `FSColorPicker.initWithKey:cb:` | 230 | 颜色选择器（色板按钮 + 取色井） |
| `FSColorPicker.picked:` / `wellChanged:` | 249/261 | 选色回调 |
| `FSSpacer`(s) | 269 | 弹性空白 |
| `FSRow`(s) | 276 | 一行（标题 + 右侧控件） |
| `FSSection`(s) | 292 | 圆角分组卡（1pt 分隔线） |
| `FSEmptyView`(s) | 342 | 空态占位 |
| `FSGrayscaleImage`(s) | 356 | 灰度化（停用 chip） |
| `FSSidebarRow.init...` / `setActiveState:` / `mouseDown:` | 391/407/418 | 32pt 侧边栏行 |
| `FSSidebar.initWithFrame:` / `setActive:` | 427/500 | 侧边栏（Settings + 7 模块 + 底部工具行） |
| `FSWidgetChip.initWithForm:img:` / `refreshVisual` / hover / tracking | 517/534/538-540 | 44pt 部件 chip（彩色=启用/灰度=停用） |
| `FSWidgetSelector.initWithModule:onChanged:` | 563 | 选择条：为每个支持形态渲染预览图 |
| `resortChips` / `activeCount` / `layoutChips` | 599/604/609 | 启用部分在前 + 逐个摆位 + 分隔线 |
| `FSWidgetSelector.mouseDown:` | 629 | 拖拽排序（`trackEventsMatchingMask`）+ 点击切换 + 落盘 |
| `activeCountAfterRemoving:` / `activeCountForIndexHint:` | 680/681 | **桩函数**（都返回 `activeCount`） |
| `persist` | 685 | 写 `position` 键 + `FSBarSetEnabledForms` + `FSBarReloadFromStore` |
| `FSWidgetSettingsBlock`(s) | 702 | 设置块（居中标题 + 图标座 + 内容） |
| `FSScroll`(s) | 741 | 造滚动视图 + 内层 stack |
| `FSFormSettingsView`(s) | 767 | 按形态生成选项行（label/box/frame/value/color/historyCount/scale/…） |
| `FSBuildSettingsPage`(s) | 908 | 设置页：信息块 + 合并模块分组 + 配置管理（重导入 / 重置） |
| `FSBuildModulePage`(s) | 987 | 模块页：选择条 + [模块/小组件] 分段 + 两套 tab 内容 |
| `FSSettingsWindowDelegate.shared` | 1126 | 单例 delegate |
| `toolbar:itemForItemIdentifier:...` | 1127 | 工具栏模块开关（`NSSwitch` + CATransaction 禁动画） |
| `toolbarAllowed/DefaultItemIdentifiers` | 1156/1159 | 弹性空白 + 模块开关 |
| `FSSelectPage`(s) | 1165 | 切页：重建页视图 + 更新标题 + 模块开关显隐 + `layoutSubtreeIfNeeded` |
| `FSBarSettingsOpen` | 1200 | **v54 起不再建窗**：`openURL("frsetnext://settings?pane=monitor.widgets")`；`FRSET_SETTINGSHOT=1` 时逐页截图到 `/tmp/frset_settings_*.png` |
| `FSBarSensorKeysList` | 1233 | 传感器 key 转 NSArray（Swift 设置页用） |

**散文：`FSBarSettingsOpen`（1200–1229）**
函数名仍是"打开设置"，实际只发一条深链——真正的 UI 由 App 的 `SettingsWindowController` 托管。`FRSET_SETTINGSHOT` 分支要求 `gWin && gHostContainer` 非空，而 v54 之后**这两个全局不再被赋值**（内嵌模式 `gEmbedded=YES`），所以整段自检代码在当前架构下是**不可达的死代码**。同理 `FSSidebar`/`FSSettingsWindowDelegate` 这套独立窗设施只有内嵌宿主（`Features/Monitor` 的部件设置页）在复用 `FSBuildModulePage` 时才有效。

### 3.8 `frset_recorder.m`

| 函数 | 行 | 说明 |
|---|---:|---|
| `FSRecMakeGlass`(s) | 26 | 玻璃（macOS 26 `NSGlassEffectView`，回退 `.menu`/behindWindow） |
| `FSRecInstallGlass`(s) | 46 | 把窗口 contentView 换成玻璃 |
| `FSRecMainScreenH` / `FSRecCG`(s) | 62/67 | Cocoa ↔ CG 坐标换算 |
| `FSRecSettings.shared` / `load` / `save` | 88/94/112 | 录屏设置单例 + `Recorder_*` 持久化 |
| `needMic` / `needSys` / `isGIF` / `ext` / `fileType` | 123–128 | 派生属性 |
| `FSRecCreateScaledImage`(s) | 140 | 等比缩放 CGImage |
| `FSRecConvertMovieToGIF`(s) | 161 | `AVAssetImageGenerator` 抽帧 + ImageIO 写 GIF（≤720px / ≤12fps） |
| `FSRegionView.drawRect` | 220 | evenOdd 挖洞 + 白虚线 + 黄手柄 + 尺寸标签 |
| `clampPoint` / `mouseDown` / `mouseDragged` / `mouseUp` / `confirm` / `cancel` / `keyDown` | 274–317 | 选区交互（ESC 取消 / 回车确认） |
| `FSRegionOverlayShow` / `Close`(s) | 326/349 | 全屏 overlay 生命周期 |
| `FSRecBarBox.drawRect` / `mouseDown` / `mouseDragged` | 364/389/392 | 计时药丸（红点 + M:SS + 停止）+ 可拖动 |
| `FSRecBarShow` / `Hide`(s) | 399/423 | 计时窗显示（1s `dispatch_source` 刷新） |
| `FSRecPanelView.segItems/segValue/segSet/rows/drawRect/mouseDown/mouseMoved/pickDir/pickRegion/keyDown` | 441–648 | 设置小窗（**纯 drawRect 绘制 + 命中矩形**，无子控件） |
| `FSScreenRecOpenSettings` | 653 | 建/显示设置面板 |
| `FSScreenRecCloseSettings` | 687 | 关闭 |
| `FSRecEngine.init` | 714 | 建串行队列 `frset.recorder.video` |
| `FSRecEngine.start` | 720 | 取 SCShareableContent → 选屏 → filter/config（sourceRect/width/height/fps/queueDepth/audio）→ 加 3 路 output → `startCapture` |
| `releasePending` / `dealloc` | 828/832 | 释放首帧音频 |
| `stream:didOutputSampleBuffer:ofType:` | 834 | 首帧建 writer（H.264 + 独立 AAC 轨）→ append；音频未 session 时缓冲首帧 |
| `stop` | 956 | stopCapture → markAsFinished → finishWriting → （GIF 时）后台转码 |
| `finishWithError` | 1005 | 错误收尾 |
| `stream:didStopWithError:` | 1010 | 系统停流回调 |
| `FSScreenRecDebugPanelView` / `DebugBarView` | 1021/1022 | 调试取视图 |
| `FSRecDoneView.drawRect/mouseDown/mouseMoved/updateTrackingAreas` | 1050–1111 | 完成面板（Finder/打开） |
| `FSScreenRecCloseDone` / `FSRecShowDonePanel`(s) | 1121/1127 | 完成面板显示/关闭 |
| `FSScreenRecBeginFromSettings` | 1160 | 按当前设置开录（区域模式先弹 overlay） |
| `FSScreenRecStop` | 1203 | 停止（带超时兜底） |
| `FSScreenRecIsRunning` | 1233 | `g_engine != nil` |
| `FSRegionOverlayIsActive`（头文件声明） | — | 区域框选进行中 |

**散文：`stream:didOutputSampleBuffer:ofType:`（834–954）**
四个不能改的约束：① **音频轨必须在 `startWriting` 之前 addInput**（写会话开始后再加无效）；② 系统音与麦克风**必须各一条独立 AAC 轨**，共轨会互相覆盖并触发 `-12737`；③ 首帧音频要 `CFRetain` 缓冲（SCK 音频比首帧视频晚到，缓冲法等不到），session 开始后按时间戳补写；④ `cfg.width/height` 有 480×320 下限保护，否则极小区域会得到非法编码尺寸。

### 3.9 `frset_ocr_onnx.m` / `frset_sensor_names.c` / `frset_runcat_frames.c`

| 函数 | 行 | 说明 |
|---|---:|---|
| `FSPPOCRSessionCreate` | 24 | `setenv(ORT_DISABLE_TELEMETRY)` → `dlopen` → `OrtGetApiBase` → CreateEnv → DisableTelemetryEvents → CreateSessionOptions(2 线程) → CreateSession；失败逐级释放 |
| `FSPPOCRSessionDestroy` | 110 | Release session/options/env → dlclose → free |
| `FSPPOCRRun` | 129 | 建 CPU memInfo + 输入 tensor → 取真实输入/输出名（失败回落 `"x"`/`"output"`，**只有 ORT 分配的才 AllocatorFree**）→ Run → 读 T×C → malloc 拷贝 → 全量释放 |
| `FSPPOCRFree` | 226 | `free` |
| `frset_sensor_name` | 256 | key（支持 `%` 通配）→ 中文名 + group |
| `frset_sensor_average` | 268 | avg 标记 |
| `frset_sensor_type` | 277 | 类型（未收录 -1） |
| `frset_sensor_group` | 286 | 分组（未收录 -1） |
| `fsnKeyMatch`(s) | 247 | 单字符通配全串匹配 |
| `frset_runcat_frame` | 1797 | 取 PNG 字节 + 长度（idx clamp 0..4） |
| `frset_runcat_frame_count` | 1804 | 恒 5 |

**散文：`FSPPOCRRun`（129–224）**
名字所有权是个真坑：`SessionGetInputName` 返回的名字由 **ORT 分配器**分配，必须 `AllocatorFree`；但代码在失败时回落成**字符串字面量** `"x"`，此时再 Free 就是 free 一个常量 → 堆损坏（注释记录"实测概率性崩溃"）。所以有 `inOwned/outOwned` 两个标志位。**新增任何 early-return 路径都必须带上这三处释放。**

### 3.10 `MemoryHelper/main.swift` / `OCRHelper/main.swift`

| 函数 | 行 | 说明 |
|---|---:|---|
| `fail(_:code:)` | 24 | 写 stderr + exit |
| `runTool(_:_:)` | 29 | 跑子进程（stdout/stderr 丢空），返回是否 0 退出 |
| `SimulatedMemoryPressure.set(_:)` | 55 | 写 `kern.memorypressure_manual_trigger`（`6<<16 | level`） |
| `optimizeMemory()` | 62 | critical 压力 → sleep 3 → defer 复位 normal → `purge` → 返回 `ok pressure purge` |
| `handle(_:)` | 77 | 命令白名单分发（`version` / `optimize-memory`，参数数校验） |
| `loadAuthorization()` | 91 | 读 client.json，`uid != 0` 才有效 |
| `writeAll(_:_:)` | 99 | 循环写直到写完 |
| `serve(socketPath:)` | 111 | 建 socket → bind → chown root:userGid → 0660 → listen(8) → accept 循环（`getpeereid` 校 UID + 60s 收发超时 + 4KB 读 + 一行回复） |
| `OCRHelper` 顶层脚本 | 25–114 | 参数校验 → 读 `FOCR1` → 建 CGImage → 读 boxes → 逐框裁剪识别 → stdout JSON |

**散文：`serve`（111–170）**
**单线程串行 accept**：一个客户端在读/写期间（最长 60s）其它连接只能排队（backlog 8）。`optimize-memory` 自身要 sleep 3s + purge，期间 Socket 完全阻塞。对"用户点一次清理内存"这个使用频率没问题，但**不要把它当通用 IPC**。另外 `handle` 的命令是纯字符串前缀匹配（`split(separator:" ")`），`optimize-memory` 显式要求 `fields.count == 1` 防参数注入。

---

## 4. 关键数据流

### 4.1 采样 → 菜单栏（0.5s 主循环）

```
NSTimer 0.5s（mainRunLoop, .commonModes）        [frset_stats_tick.m:214]
 └ @autoreleasepool
    ├ statsTick()
    │   ├ frset_cpu_sample / frset_mem_sample        （每拍）
    │   ├ frset_net_sample / disk_sample / battery   （隔拍 = 1s）
    │   ├ frset_loadavg                              （每拍）
    │   ├ frset_disk_capacity (statfs)               （每 60 拍 = 30s）
    │   └ dispatch_async(UTILITY) frset_smc_scan     （每 12 拍 = 6s，~150ms）
    │        └ atomic_store(s_sensorCountA, n)  ← 跨线程发布点
    │   → 写 g_snap（比例/字节/传感器值，温度类过滤 + 最热回退）
    ├ FSBarSystemTick()
    │   ├ FSBarResolveNativeItems → g_nativeItems
    │   ├ FSBarReconcile → 合并/独立双模式重建
    │   └ FSBarRefreshValues → 按 module updateInterval 调 refreshWithSnap
    └ FSBarKeepAdjacentTick → 必要时主队列 setFrameOrigin（保邻）
```

### 4.2 用户点合并条 → 打开性能面板

```
点击 NSStatusBarButton（sendActionOn MouseDown）
 └ FSBarManager.openMerged:                        [barwidgets.m:2051]
    ├ CGWindowListCopyWindowInfo 取真实窗口 x（AppKit 偏 24pt / macOS26 偏 32pt）
    ├ 按 g_views["module/form"].frame.origin.x 命中模块
    ├ 左键 → g_anchorScreen = 鼠标屏幕 x（1×1）
    │        FSBarOpenMonitor(idx)  [stats_tick.m:56]
    │         └ s_openMonitorFn(idx)  ← Swift 注册的 C 函数指针
    └ 右键 → FSBarShowMergedMenu（样式/分隔线/间距/开面板）
```

### 4.3 设置改动 → 立即生效（同一进程内闭环）

```
设置界面控件 block                            [barsettings.m 各处]
 └ FSBarCfgSet / FSBarGlobalSet → g_cfgGen++ → 全量写 widgets.plist
    └ FSBarReloadFromStore → FSBarReconcile → 视图重建/挂载
       └ FSBarMergedLayout → mergedItem.length 变化 → 系统重排
          └ 0.5s 后 FSBarKeepAdjacentToMain（屏幕口径优先）
```

### 4.4 录屏

```
FSScreenRecBeginFromSettings  → (区域模式) FSRegionOverlayShow → onDone(CG rect, display)
 └ FSRecEngine.start
    → SCShareableContent → SCDisplay → SCContentFilter + SCStreamConfiguration
    → addStreamOutput(screen/audio/microphone, queue=frset.recorder.video)
    → startCapture
       └ 首帧视频：建 AVAssetWriter + H.264 input + 最多 2 条 AAC input → startWriting → startSession
       → 逐帧 append
FSScreenRecStop → stopCapture → markAsFinished ×3 → finishWriting → (GIF) 后台转码 → 完成面板
```

### 4.5 OCR（跨进程）

```
主 App（Apple Vision 定位文本行）
 └ 写 raw（FOCR1 + w + h + BGRA）与 boxes.json 到临时目录
    └ 起 Contents/Helpers/FrsetOCRHelper             [OCRHelper/main.swift]
       ├ 无 boxes → 直接 {"results":[]}（不加载模型）
       └ 逐框 crop → PPOCROCR.shared.recognize(line:)
          → PPOCROCR → FSPPOCRRun（dlopen 的 ORT）    [frset_ocr_onnx.m]
       → stdout JSON → 进程退出（内存整块回收）
```

### 4.6 内存优化（跨进程 + root）

```
主 App → Unix socket /var/run/com.sxyq.frsetnext.memory.sock
 └ MemoryHelper（root LaunchDaemon, accept 循环）
    ├ getpeereid 校 UID
    ├ kern.memorypressure_manual_trigger = 6<<16 | 4（critical）
    ├ sleep 3 → 复位 normal（defer）
    └ /usr/sbin/purge
```

---

## 5. 资源清单

### 定时器 / 周期任务
| 位置 | 间隔 | 门控 |
|---|---|---|
| `frset_stats_tick.m:214` NSTimer | 0.5s（`.commonModes`） | 无 |
| net/disk/battery 采样 | 1s（隔拍） | `s_tickCount % 2` |
| SMC 全量扫描 | 6s（每 12 拍） | 后台 UTILITY 队列，~150ms |
| `statfs` 容量 | 30s（每 60 拍） | 无 |
| `FSBarSystemTick` 内 Reconcile | 0.5s | `g_cfg` 未加载则早退 |
| `FSRunCatStartTimer` NSTimer | 0.10s（10Hz） | `g_mainIconCatEnabled` |
| `FSBarBarShow` 计时窗 | 1s `dispatch_source` | 录屏中 |
| `frset_conn_thread` | 1s/包 | `g_netConnActive` |
| `frset_net_top_thread` | 5s + nettop ~1s | `g_netTopActive` |
| 位置校准/保邻 | 3s（启动后一次）+ 0.5s tick | 60s 冷却、每会话 3 次升级上限 |

### 线程 / 队列
- 主线程：tick、全部绘制、状态项增删、布局、录屏 UI、设置界面。
- `QOS_CLASS_UTILITY`（全局并发）：SMC 扫描。
- `pthread` ×2：ICMP 连通性、nettop 轮询（均 detach，永不退出）。
- `frset.recorder.video`（串行）：SCStream 三路 sampleBuffer。
- `QOS_CLASS_USER_INITIATED`：GIF 转码。
- MemoryHelper：单线程 `accept` 循环。

### 子进程
| 命令 | 位置 | 说明 |
|---|---|---|
| `/usr/bin/nettop -P -L 1 -n -k …` | stats_data.c:1309 | 每 5s，`popen`，采样 ~1s |
| `/usr/sbin/purge` | MemoryHelper:70 | root，按需 |
| `Contents/Helpers/FrsetOCRHelper` | 主 App 侧（Features/Capture） | 每次识别一次 |

### 文件路径（绝对）
- `~/Library/Application Support/FrsetStats/widgets.plist`（部件 + 录屏 + 位置锚 `NSPos_*` + `Bar_MainIconCat`）
- `~/Library/Application Support/FrsetStats/engine.log`（>200KB 截断）
- `~/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime/**`（**已通过 `ORT_DISABLE_TELEMETRY` 关闭**）
- `~/Movies/录屏-yyyyMMdd-HHmmss.{mov|mp4|gif}`（默认目录，可改）
- `/tmp/frset_merged_bar.png`、`/tmp/frset_settings_*.png`（探针）
- `/var/run/com.sxyq.frsetnext.memory.sock`
- `/Library/PrivilegedHelperTools/com.sxyq.frsetnext.memoryhelper{,.client.json}`
- `Contents/Library/PrivilegedHelperTools/com.sxyq.frsetnext.memoryhelper`、`Contents/Helpers/FrsetOCRHelper`、`Contents/Frameworks/libonnxruntime.dylib`

### UserDefaults / plist 键
- `eu.exelban.Stats` 域（**只读**，首启导入 + `FSBarResetFromStats`）
- `NSStatusItem Preferred Position frset.bar.merged` / `frset.bar.<module>.<form>`
- widgets.plist 键族：`<Module>_widget`、`<Module>_updateInterval`、`<Module>_<form>_<option>`、`CombinedModules{,_spacing,_separator}`、`Widgets_spacing`、`Sensors_sensor`、`Disk_mini_title`、`Bar_MainIconCat`、`Recorder_*`、`NSPos_*`
- 环境变量：`FRSET_APPEARCHK`、`FRSET_BARCHAR`、`FRSET_CLICKCHK`、`FRSET_POSCHK`、`FRSET_SETTINGSHOT`、`FRSET_MAINICON_CAT`、`FRSET_RENDER_PROBE`(Core)

### 通知
- `FrsetRunCatIconChanged`（小猫开关切换后广播）

---

## 6. 不变量与陷阱

1. **`g_snap` 只允许主线程写**。tick 在主线程，绘制在主线程；任何后台写 `g_snap` 都会造成撕裂。
2. **`_Atomic s_sensorCountA` + `release/acquire` 配对不能拆**。改成普通 int 会让主线程读到半个 `s_sensors`。
3. **SMC 全量扫描必须在后台**（~150ms/次）。移回主线程会立刻复现 v49 记录的"菜单栏周期尖峰卡顿"。
4. **自建状态项按钮必须 `sendActionOn(LeftMouseDown | RightMouseDown)`**。默认 mouseUp 派发会被空内容按钮的状态栏跟踪取消 → 真机点击毫无反应（v14 根因）。
5. **合并条 level/宽度相关常量是实测值**：`kStatusItemFrameDX = 32`（macOS 26）、inset 补偿、`kScreenGapTarget = 16`。改系统版本要重新标定。
6. **位置校准的 `Preferred Position` 增益约 13:1**，按 gap 等量微调无效；必须候选扫描 + 帧稳定性闸门（连续两帧相同）。
7. **`proc_pidpath` 缓冲区必须 ≥4096**（`PROC_PIDPATHINFO_MAXSIZE`）。用 512 恒定返回 0。
8. **进程表上限 512**（`FRSET_PROC_CAP`）。超过时按枚举序截断，top 表会漏。
9. **音频两源不能共轨**（`-12737`）；音频轨必须在 `startWriting` 前建好；`cfg.width/height` 有 480×320 下限。
10. **SF Symbol 必须走 `FSBarSymbolImage` 缓存**。每 `drawRect` 重建会触发 CoreSVG 解码（约 3.8MB 堆）。
11. **`preferredWidth` 的宽度迟滞带 = 4pt**，改大（6pt）会让数值变窄时永不收缩（已实测）。
12. **文本绘制坐标必须 `floor`**（`FSBarTextCenter`/`FSBarTextRect`）。半像素落点 = 菜单栏发虚。
13. **`FSBarLog` 是同步写盘**，不能放在每 tick / 每帧路径（现有代码已用 ≥5s / ≥10s 节流 + 变化才写）。
14. **`FSPPOCRRun` 的 `inOwned/outOwned` 决定能否 `AllocatorFree`**。给字面量名字 Free 会堆损坏。
15. **`ORT_DISABLE_TELEMETRY` 必须在 `dlopen` 之前 `setenv`**（之后只能关事件，关不掉已建的 1DS 通道）。
16. **MemoryHelper 的 `defer { set(normal) }` 不能删**。不复位会永久禁用内核真实压力处理。
17. **`FSScreenRecOpenSettings` 等窗口函数必须在主线程**；`FSRecEngine` 的 sampleBuffer 全在串行队列上，改 UI 要回主线程（现有代码已 `dispatch_async(main)`）。
18. **`widgets.plist` 与官方 Stats 共用**。写入时必须保持 Stats 的键名语义（`M_widget` / `M_<form>_<option>`），否则"配置互通"与 `FSBarResetFromStats` 双向会互相破坏。

---

## 7. 重复实现 / 死代码 / 风险

### 死代码 / 空实现（明确无人调用或恒不生效）

- **`FSBarProbeMenuBarDarkAsync`（393）空实现**，但 `FSBarSystemTick` 每 0.5s 仍调用一次。v77 移除截屏采样后留下的壳。
- **`FSBarRefreshAllWidgets`（2807）无调用者**。v18 时代的"明暗变化全量重绘"，现在靠 `viewDidChangeEffectiveAppearance` 逐视图处理。
- **`FSBarDebugCurrentModule`（stats_tick.m:92）恒返回 -1**，只有 `FSBarDebugClickProbe` 打印用。
- **`FSBarDebugClickProbe`（3021–3145）整段是 T1–T6 点击链路对照实验**：15 层 `dispatch_after` 嵌套 + 三处 `sleep(1.5~2.6)`，累计 >20s 阻塞主线程。只有 `FRSET_CLICKCHK` 触发，但**一旦触发就等于冻结 UI 20 秒**。
- **`FSBarDebugPosProbe`（2514）内有两次 `[NSThread sleepForTimeInterval:1.5]`**，同样阻塞主线程。
- **`FSBarSettingsOpen` 的 `FRSET_SETTINGSHOT` 分支（1206–1228）不可达**：`gWin`/`gHostContainer` 在 v54 内嵌模式下永不赋值。
- **`FSWidgetSelector.activeCountAfterRemoving:` / `activeCountForIndexHint:`（680/681）是桩**，拖拽跨分隔线的启用态切换语义失效。
- **`frset_runcat_frames.c` 的 10 段 PNG 里，当前只有主图标覆盖层用 5 帧×2 色**；合并条 `run_cat` 形态在 v71 已移除（`FSBarFormName` 里也没有 `run_cat`），`g_views` 若读到存量 `run_cat` 会 fallback 成 mini（946 行注释）。

### 重复实现

- **两套"模块 → 数值"映射**：`FSBarModuleValue`（引擎绘制）与 `Features/Monitor` 的 Swift `StatsDataProvider`（面板）各算一遍 CPU%/内存比例；口径不完全一致（引擎 `ramRatio = used/total` 且 `used = active+wire+compressed`）。
- **两套"明暗判定"**：`FSBarAppearanceDark`（C 侧）与 Swift `Features/Settings/AppearanceManager` 的 `AppearanceMode`（用户显式模式）。二者独立，用户在设置里选"浅色"时菜单栏部件仍按视图外观反相。
- **两套"网络速率"**：`frset_net_sample`（ifaddrs 累计差分）与 `frset_net_top`（nettop 单进程差分）——前者是总量、后者是分进程，单位口径一致但采样窗口不同（0.5/1s vs 5s+1s）。
- **三套"进程枚举"**：`frset_proc_top`、`frset_proc_grouped`（内部复用 top）、`frset_kill_bundle`（**又自己 `proc_listallpids` 一遍**）。kill 路径应复用 top 的 pid 集，目前为了"重新扫描保证准确"而重复枚举。

### 风险（按严重度）

- **P0 位置校准会在主线程做多次 `removeStatusItem` + 重建 + 最长 10s 等待**。若 `Preferred Position` 被用户拖动或系统改版打乱，每次启动都会扫 8 个候选；扫描期间合并条反复消失/出现（可见闪烁），且 `dispatch_after` 链与 0.5s tick 的保邻修正并发（有 `s_calibrating` 互斥，但 `g_posCalibrating` 只抑制位置恢复）。
- **P1 `FSBarSaveStore` 每次 `CfgSet` 全量写盘**。设置界面拖滑块时会高频原子替换 plist。
- **P1 `FSBarLog` 同步写盘 + 200KB 截断用 `removeItemAtPath`**：截断是"删文件再重建"，若此时另一处正在追加会丢日志（无锁保护）。
- **P1 小猫覆盖层会 `hidden = YES` 掉主图标按钮的**所有**其他子视图**（1770–1773），并清空 `button.image`/`title`。关闭时必须正确恢复（`FSRunCatIconSetEnabled(false)` 只把 `hidden=NO`，但**不恢复 `button.image`**——原图已被置成空 NSImage，实际恢复依赖 Swift 侧重建图标）。
- **P2 `frset_kill_bundle` 用路径前缀匹配**：`strncmp(pbuf, bundle, blen) && pbuf[blen]=='/'`。若 bundle 是 `/Applications/X.app`，会连 `/Applications/X.app.bak/...`（备份）一起杀——更新脚本刚写的 `.bak` 目录里的进程会被误杀。
- **P2 `FSBarRenderFormPreview` 逐像素扫 alpha**（`w*2 × 24*2` 次 `getPixel`），设置页一次重建会为每个形态各跑一遍；形态 11+ × 每模块 11 形态 ≈ 每页 100+ 次全像素扫描。
- **P2 `FSBarMergedLayout` 的宽度诊断日志**在 `fabs(lastTotal-x) > 0.5` 时会拼 7 个模块的字符串——虽然有 5s 节流，但流量数字每几秒变一次，稳态下仍约每 5s 一次同步写盘。
- **P2 MemoryHelper socket 无并发**：`optimize-memory` 期间（≥3s + purge）整条 socket 阻塞，主 App 若在此期间再请求会等待。
- **P3 探针常量硬编码系统版本行为**（`kStatusItemFrameDX = 32`）。macOS 27 若不再偏移，命中会整体错位一个部件宽度（注释已提示"届时改 0"）。
