# B2 — Features/Monitor（监测中心、采样器、7 模块面板、监测详情窗）

> 范围：`apps/FrsetNext/Sources/Features/Monitor/` 全部 **23** 个 `.swift`（含 `Memory/` 5 个），合计 **7623** 行。整文件逐行读完。
> 符号核对：CSV 中本目录声明 **354** 条，其中 `func` **215**、`init` 33、`class` 13、`enum` 21、`struct` 70、`extension` 2。
> 本报告列出 **215 个 CSV func** + 补齐 CSV 漏记的多行签名函数/关键计算属性（`MonitorSampler.uiActive`、`StatsDataProvider.current`、`MonitorPopoverController.currentModule`、`MemoryHelperClient.isInstalled`/`helperURL`/`plistURL`、`MonitorDetailView.modulePicker`/`content`/各 `*Panel`、`StatsProcTable.body` 等），表内共 **241** 行。

---

## 1. 文件清单

| 路径 | 行数 | 一句话职责 |
|---|---|---|
| `Monitor/MonitorModule.swift` | 41 | 模块入口：启采样器、注册设置页签、启 STATS 引擎、预热独立窗；`stop()` 反注册 |
| `Monitor/MonitorSampler.swift` | 325 | 周期采样器（唯一 Swift 侧数据泵）：间隔门控、环形缓冲、`@Published` 发布、旁路 `MonitorExtra` |
| `Monitor/MonitorReader.swift` | 636 | 用系统 API 直读 CPU/内存/网络/磁盘/SMC 温度/电池/功耗 + `MonitorExtra` 容器的定义 |
| `Monitor/StatsDataProvider.swift` | 857 | STATS 深数据提供者：GPU/集群/内存构成/电池/连通性/磁盘 SMART/传感器/进程排行，按成本与可见性节流 |
| `Monitor/StatsModulePanels.swift` | 1509 | 原版 Stats 版式的 7 个模块面板（CPU/内存/GPU/磁盘/网络/传感器/电池）+ 环形图/进程表/进程退出/图标 |
| `Monitor/MonitorDetailView.swift` | 985 | 监测正文容器（主面板性能页与独立窗共用）+ 8 模块详情面板 + 模块切换条 + 页脚 |
| `Monitor/MonitorPopoutWindow.swift` | 433 | 监测独立窗控制器：borderless 玻璃面板、内容高度驱动 resize、CA 层入场退场、锚点定位、点外收起 |
| `Monitor/MonitorCenterView.swift` | 59 | `PanelCenterPage` 四页枚举 + `MonitorCenterPresenter`（页与模块共享选中态、导航埋点） |
| `Monitor/StatsBarEngine.swift` | 285 | STATS 菜单栏合并条桥：启停 C 引擎、点击跳板 → 独立窗、0.5s 空隙探针、设置/录屏入口、探针 |
| `Monitor/MonitorStatusItems.swift` | 183 | 双排状态栏项文案（CPU/内存/网络/功耗/磁盘/温度/合并）+ `registerAll()`（**当前未被调用**） |
| `Monitor/MonitorPreferences.swift` | 140 | `MonitorModuleID` 枚举 + monitor.* 偏好读写（含 legacy 键、范围钳制、变更通知） |
| `Monitor/MonitorHistory.swift` | 50 | 环形缓冲 `MonitorHistoryBuffer`（含 v129 的 `values(into:)` 零分配回填） |
| `Monitor/MonitorFormat.swift` | 66 | 字节/速率/百分比/温度/负载/功耗格式化 |
| `Monitor/MonitorCharts.swift` | 281 | Sparkline/Area/Bar/Ring/StackedBar + 语义色 + Card/Row/SectionTitle |
| `Monitor/MonitorSettingsPane.swift` | 196 | 设置 → 监测页：总开关、刷新间隔（联动菜单栏部件）、模块开关、温度采集、重置 |
| `Monitor/NetworkDiagnostics.swift` | 441 | 网络诊断：网卡枚举、公网 IP/归属、代理识别（系统代理+端口探测+进程）、站点延迟、DNS 出口 |
| `Monitor/PortInspector.swift` | 251 | 端口占用检查器：`lsof -FpcnPT` 子进程 + 解析 + 30s 轮询 + 3s 最小间隔 |
| `Monitor/PortOccupancySection.swift` | 210 | 端口占用卡片：摘要徽标、行（端口/协议/进程/地址）、对外过滤、点击复制、手动刷新 |
| `Monitor/Memory/MemoryHelperClient.swift` | 224 | root LaunchDaemon 客户端：Unix socket 协议、管理员授权安装/卸载、`AdministratorShell` |
| `Monitor/Memory/MemoryOptimizer.swift` | 158 | 内存优化流程：就绪 → 采基线 → 调 helper → 1s 结算 → 前后差值报告 |
| `Monitor/Memory/MemoryBreakdown.swift` | 88 | 活动监视器口径的内存分类（app/wired/compressed/cached/swap/pressure） |
| `Monitor/Memory/ProcessMemoryInspector.swift` | 101 | 按 `.app` 归并的进程内存排行（`proc_pid_rusage` + `proc_pidpath`） |
| `Monitor/Memory/MemoryOptimizeCard.swift` | 139 | 「内存维护」卡片：释放按钮 + 诚实报告（无释放时明说） |

---

## 2. 类型逐个说明

### 2.1 `MonitorModule`（enum, `AppModule`）

- **职责**：`start()` 做 4 件事：`MonitorSampler.start()`、注册 `SettingsPaneDescriptor(id:"monitor")`、`StatsBarEngine.start()`、`MonitorPopoutWindowController.scheduleWarmup()`。
- **注释档案**：v42 明确**不注册**官方 4 个独立状态项；v60 定"性能监测只留独立窗"；v62 加独立窗预热。
- **被依赖**：`ModuleRegistry`。`stop()` 供总开关/退出调用。

### 2.2 `MonitorSampler`（ObservableObject, 单例）

- **职责**：唯一的 Swift 侧采样泵。每 tick：`StatsDataProvider.refresh(uiActive:)` → `MonitorReader.readResult(needFull:)` → 用 `g_snap` 覆写 5 组核心指标 → 写环形缓冲 + `MonitorExtra` → 主线程发布 `sample/history/tick`。
- **内部状态**：`sample`、`history`（7 条 60 点）、`tick`、`isRunning`；`panelActive`/`homePanelActive`/`settingsActive` 三个可见性闸；`buffers`（7 个环形缓冲）+ `scratchA/B` 双缓冲；`pendingWork`；`observers`。
- **生命周期**：`shared` 常驻；`start()` 只允许一个 pendingWork；`stop()` 取消并置 `frset_conn_set_active(0)`/`frset_net_top_set_active(0)`；`deinit` 移除观察者。
- **依赖**：`MonitorReader`、`StatsDataProvider`、`MonitorPreferences`、`MonitorExtra`、C 层 `g_snap`/`frset_conn_set_active`/`frset_net_top_set_active`。
- **被依赖**：所有面板视图（`@ObservedObject`）、`MonitorStatusItems`、`MonitorSettingsPane`、`MonitorDetailView` footer。
- **不变量**
  1. 三个 `*Active` 闸必须**独立**（注释明确：合并会导致"面板 5s / 独立窗 1.5s 两套时间"）。
  2. UI 不可见时间隔 `max(base, 5.0)`；`scheduleNext` 的重排路径也复算这个门控（v73 修复）。
  3. `g_snap.valid != 0` 时跳过 CPU/内存/网络/磁盘/电池 5 路直采（v125）。
  4. `buffers` 与 `scratch` 只在 `lock` 内访问；`History` 发布走主线程。

### 2.3 `MonitorReader` + `MonitorExtra` + `MonitorReadResult`

- **职责**：系统 API 直采。CPU（`host_processor_info` 差分）、内存（`host_statistics64`）、Swap（`sysctlbyname vm.swapusage`）、负载（`getloadavg`）、网络（`getifaddrs` 差分）、磁盘（IOKit `IOBlockStorageDriver` 差分）、温度（AppleSMC 6 个 key，150ms 超时）、电池（`IOPSCopyPowerSourcesInfo`）、功耗（`AppleSmartBattery PowerTelemetryData`）。
- **内部状态**：`previousCPUTicks/previousNetwork/previousDisk`（差分基线）、`cachedTemperatures` + `sensorReadInFlight`（SMC 单飞）、`sensorQueue`、`temperatureEnabled`。
- **`MonitorExtra`**：`NSLock` 保护的全局旁路快照（峰值/累计/压缩内存/负载），因契约禁止改 `MonitorSample`。`MonitorSample` 扩展把 6 个便捷属性转发到它（**每次读都取一次锁**）。
- **生命周期**：`MonitorSampler` 私有持有 `reader`，随其销毁。
- **不变量**
  - `readResult(needFull: false)` 必须仍采 `readMemory()`（压力/交换/压缩不在 g_snap 中）。
  - SMC 读取必须带超时：`sensorReadInFlight` 为真时直接返回上次缓存（避免重入堆积）。
  - `delta(_:_:)` 计数回绕返回 0（不返回负数）。

### 2.4 `StatsDataProvider`（单例）

- **职责**：深数据（C 层 `frset_*` 采集层）。`refresh(uiActive:)` 在采样队列调用，内部四档节流：每帧（内存/连通性）、`heavyDue`（GPU/集群/电池，可见每帧、隐藏随 slow）、`slowDue`（磁盘容量/SMART/网络 Top/本地 IP）、`scanInterval`（SMC 全量扫描）、`procInterval`（进程排行）。
- **内部状态**：`storage: StatsSnapshot` + `lock`；`connScratchA/B`；`lastProcAt/lastScanAt/lastSlowAt`；`sensorMeta` 静态元数据缓存；静态 `lastOrders`（按 kind 分开的上一轮名次）+ `orderLock`；静态 `procBuffer`（512×612B 复用）+ `procBufferLock`；`displayNameCache` + 锁。
- **依赖**：C 桥（`frset_gpu_usage`/`frset_cpu_clusters`/`frset_mem_sample`/`frset_battery_sample`/`frset_conn_sample`/`frset_smc_scan`/`frset_proc_top`/`frset_net_top`/`frset_sensor_*`/`frset_fan_count`/`frset_smc_read_key`）、`SCDynamicStore`。
- **被依赖**：`MonitorSampler.sampleOnce`（唯一写者）、所有面板视图（`current` 只读）、`MonitorDetailView.availableModules`、`MonitorSettingsPane.statusLine`。
- **不变量**
  - `refresh` 只允许采样队列单线程调用（注释多次强调；`procBuffer` 的锁是"防御性"）。
  - `sensorMeta` 只在采样队列读写（首次扫描建表）。
  - `lastOrders` 的语义是"同桶内沿用上一轮相对次序"——排序稳定性直接决定用户能否点中想展开的行。
  - `frset_conn_set_active`/`frset_net_top_set_active` 必须在每次 refresh 开头按 `uiActive` 置位，否则后台 ICMP/nettop 常驻。

### 2.5 `StatsModulePage` 及组件（StatsModulePanels.swift）

| 类型 | 职责 / 备注 |
|---|---|
| `StatsModulePage` | 按 `MonitorModuleID` 分发 7 个 Panel（`.cpu/.power` 共用 CPU 面板） |
| `StatsRing` | 分段环形图；v84 修复 `inset(by: lineWidth/2)` 防描边出框被裁；v85 移除 GeometryReader 内的 `.environment` 注入（曾导致 render→layout 死循环，主线程阻塞 60s+ 只能强杀） |
| `StatsHalfGauge` | 内存半圆仪表（绿/黄/红三段 + 指针） |
| `StatsLegendRow` / `StatsHistoryChart` / `StatsHistoryDualChart` / `StatsCoreGrid` | 图例行 / 面积图 / 双线图 / 每核方块条 |
| `StatsProcTable` | 进程表：展开（`expandedIDs` 按 `groupKey`）、行内退出按钮、右键 contextMenu、`values(item)` 每行只算一次（v129） |
| `StatsAppIcon` | 按 `.app` 路径取图标，`NSCache(192)`，**只缓存成功结果**（v86/v129） |
| `ProcMenuPresenter` | `NSMenu` 在鼠标位置弹出（点击路径），菜单持 `item` 作 `representedObject` |
| `StatsProcContextMenu` | SwiftUI 右键菜单（与 NSMenu 版内容一致） |
| `StatsProcQuitter` | `kill(pid, SIGTERM)` 全部合并 pid；行内按钮走 `confirmAndQuit`（`NSAlert.runModal`），右键直接退 |
| `StatsConnGrid` | 30×3 连通性格子，`LazyVGrid + aspectRatio(1)`（v45 修重叠） |
| `SensorGroup` | 传感器分组（名称/比例条/值），`fraction` 按 `scaleMax` 或组内峰值归一 |
| `SensorsStatsPanel` 内 `orderedTemperatures` | 计算项在前（avg/hottest CPU/GPU）+ 其余降序取 12 |
| `BatteryStatsPanel` / `StatsBarRow` | 电池环 + 温度/电压/电流/容量/健康度比例条 + 适配器段 |
| `CPUStatsPanel` / `MemoryStatsPanel` / `GPUStatsPanel` / `DiskStatsPanel` / `NetworkStatsPanel` | 各模块面板（私有） |

### 2.6 `MonitorDetailView` / `MonitorPerformanceContent` / `MonitorDetailSelection`

- `MonitorDetailSelection`：`@Published module`，独立窗与主面板**共用同一个实例**（`MonitorCenterPresenter.shared.monitorSelection`）。
- `MonitorPerformanceContent`：唯一入口，只差 `topInset`（独立窗 22，主面板 0）。
- `MonitorDetailView`：`pageMode` 决定是否渲染 `modulePicker` + footer；`fixedWidth`（292 或 nil）。
- **不变量（注释明写）**：主面板性能页与独立窗除 `topInset` 外必须完全一致——"任何一侧单独改版式都会造成两套 UI"。
- **陷阱**：`modulePicker` 不能被外层 `ScrollView` 包裹（v82：macOS SwiftUI 下 ScrollView 会吞掉直接子级按钮的点击）；选中胶囊不能用 `matchedGeometryEffect` 放在 `.background{}`（会生成拦截视图，未选中项点不动）。

### 2.7 `MonitorPopoutWindowController` 家族

| 类型 | 职责 |
|---|---|
| `ContentHeightKey` | PreferenceKey，内容高度上报 |
| `MonitorPopoutPanel` | `NSPanel` 子类，`canBecomeKey = true`（borderless 默认 false，点外收起依赖 key） |
| `PopoutScrollState` | `resetToken`，每次 open 递增 → 滚回顶部 |
| `PopoutRootView` | ScrollViewReader + ScrollView + `MonitorPerformanceContent(topInset: 22)` + 高度偏好 |
| `MonitorPopoutWindowController` | 单例；borderless 玻璃窗；`appearToken` + `isDismissing` 幂等；CA 入场/退场；锚点定位；`dismissPopout` 200ms 硬兜底 |

- **关键状态**：`appearToken`（防在途 dismiss 关掉重开的窗）、`isDismissing`（多路触发幂等）、`lastDismissUptime`（供状态项去抖）、`warmupDone`。
- **生命周期**：`shared` 首次访问即建窗（`convenience init`），永不销毁；`orderOut` 复用。
- **依赖**：`MonitorCenterPresenter`（共享选中态）、`TransientWindowCenter`、`MonitorSampler`、`PanelController.panelFrameForPopout`、`RenderProbe`、`Theme.Motion`。

### 2.8 `MonitorCenterPresenter` / `PanelCenterPage`

- `page`（home/performance/transfer/cast）+ `monitorSelection`。四个 `select*` 各自打点（`monitorPanelOpen`+`activityMonitorClick` / `transferDockOpen` / `screenCastOpen`）。
- 被 `PanelRootView`（页切换、`selectHome/selectTransferDock/selectCast`）、`MonitorPopoutWindowController`、`MonitorPerformanceContent` 依赖。

### 2.9 `StatsBarEngine`（enum, 命名空间）

- **职责**：C 引擎桥。`start()`（幂等 `isStarted`）→ 注册录屏保存通知 → 设 C 回调跳板 → `syncMainItem()` → `startScreenGapProbe()` → `FSStatsTickStart()` → 自检/探针。
- **内部状态**：`isStarted`、`screenGapTimer`、`gapUnchangedStreak`/`gapIdleSkip`/`lastGapValue`（静息降频）。
- **被依赖**：`MonitorModule`、`PanelRootView`（录屏）、`MonitorDetailView.footer`（`openSettings`）。
- **副作用**：创建/销毁 0.5s `Timer`、注册全局 C 回调、读 `FSBarMergedItem`/`StatusBarController.mainStatusItem` 窗口坐标。

### 2.10 `MonitorStatusItems`（enum）

- **职责**：双排文案 + `registerAll()`。**`registerAll()` 当前无调用方**（`MonitorModule.start()` 里被注释掉，见 v42）。
- 所有 `*TwoLine()` 都先检查 `combinedMode`、`isEnabled`、模块开关。
- `hiddenMarker = "⟨monitor:hidden⟩"`：状态栏模块据此隐藏该项。

### 2.11 `MonitorPreferences` / `MonitorModuleID`

- `MonitorModuleID`：8 个 case，`displayName`/`systemImage`/`enabledByDefault`（memory/network/disk 默认开，其余默认关）。
- `MonitorPreferences`：`keyEnabled`/`keyRefreshInterval`（legacy 键）/`keyCombinedMode`（legacy）/`keyShowTemperatures`/`keyEnabled(for:)`。
- **陷阱**：`refreshInterval` 有 `0.5...10` 钳制；`visibleStatusItemIDs()` 在合并模式下只返回 `monitor.combined`，但**总是把 `monitor.combined` 加进集合**（非合并模式也含它）。

### 2.12 `MonitorHistoryBuffer`

纯值类型环形缓冲；`append` 把非有限值归零；`values(into:)` 复用调用方数组（v129 零分配）；`values()` 是其包装（会新建数组）。

### 2.13 `MonitorFormat`

纯函数格式化。`bytes` 按 1024 进制、≥100 时取整；`compactRate` 去空格（菜单栏）；`percent`/`percentFine`/`temperature`/`load`/`power` 全部带 `isFinite` 兜底。

### 2.14 图表与基础组件（MonitorCharts.swift）

`MonitorSparkline`/`MonitorAreaShape`/`MonitorAreaSparkline`（`.drawingGroup()`）/`MonitorBarChart`/`MonitorRing`（v84 inset 修复）/`MonitorStackedBar`/`MonitorColors`/`MonitorCard`/`MonitorRow`/`MonitorSectionTitle`。

### 2.15 `NetworkDiagnostics`（单例, ObservableObject）

- **职责**：网卡枚举、公网 IP+归属（myip.ipip.net → ip.3322.net + ipwho.is）、代理识别（系统代理 / 端口探测 / `ps` 进程名）、站点 HEAD 延迟、DNS 泄漏检测（bash.ws 两步）。
- **状态**：14 个 `@Published`（接口/公网/境外/代理三段/延迟/DNS/loading/lastRefresh）+ `inFlight`。
- **依赖**：`URLSession(ephemeral)`、`Process`（`/bin/ps`、`/sbin/route`）、socket/poll、`CFNetworkCopySystemProxySettings`。
- **被依赖**：`NetworkStatsPanel.diagnosticsSection`（`onAppear` 60s 节流刷新）。

### 2.16 `PortInspector` / `PortBinding` / `PortOccupancySection`

- `PortInspector`：单例，`lsof -nP -FpcnPT -iTCP -sTCP:LISTEN -iUDP`，30s 轮询、3s 最小间隔、非前台跳过、3s 看门狗。
- `PortBinding`：同 (proto, port, process) 的 v4/v6 合并；`isExposed`（地址含 `*`）、`addressLabel`、`copyHost`。
- `PortOccupancySection`：摘要徽标 + 行 + 对外过滤 + 展开全部 + 点击复制；`onAppear/onDisappear` 控制 `start/stop`。

### 2.17 `Memory/*`

| 类型 | 职责 |
|---|---|
| `MemoryHelperClient` | Unix socket 客户端（`/var/run/com.sxyq.frsetnext.memory.sock`）；`getpeereid` 校验对端 UID==0；`install/uninstall` 经 `AdministratorShell`（NSAppleScript `with administrator privileges`） |
| `AdministratorShell` | 单次管理员授权执行 shell；`quote` 单引号转义；`appleScriptEscape` 转义 `\` 与 `"` |
| `MemoryOptimizer` | `@MainActor` 单例；就绪 → 基线 → helper optimize → 1s 等待 → 复测 → 生成报告 |
| `MemoryOptimizationReport` | 前后差值（used/app/compressed/cached/swap）+ ≥32MB 才算"可感知"+ 按 App 释放清单 |
| `MemoryBreakdown` / `MemoryBreakdownReader` | 活动监视器口径分类：app = internal − purgeable、cached = external、pressure 走 sysctl |
| `ProcessMemoryInspector` / `AppMemoryUsage` | `proc_listpids` + `proc_pid_rusage(RUSAGE_INFO_V4)` + `proc_pidpath`，按 `.app` 归并 |
| `MemoryOptimizeSection` | 「内存维护」UI：状态点、按钮/进度、报告或诚实话术 |

---

## 3. 函数级清单

### 3.1 `MonitorModule.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `start()` | 8–34 | 采样器启动 → 注册设置页 → （不注册状态项）→ `StatsBarEngine.start()` → 独立窗 3s 预热。主线程；副作用：起定时器/C 引擎/建窗。 |
| `stop()` | 37–40 | `MonitorSampler.stop()` + `StatsBarEngine.stop()`。 |

### 3.2 `MonitorSampler.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init()` | 97–107 | 注册 `MonitorPreferences.didChangeNotification`（主队列）→ `applyPreferences()`。 |
| `deinit` | 109–112 | 移除观察者 + 取消 pendingWork。 |
| `setPanelActive(_:)` | 60–65 | 独立窗可见闸；变化时 `applyPreferences()` + `refresh()`。 |
| `setHomePanelActive(_:)` | 71–76 | 主面板可见闸（与独立窗**分开**）。 |
| `setSettingsActive(_:)` | 78–83 | 设置页可见闸。 |
| `uiActive` (var) | 85 | 三闸或。 |
| `start()` | 116–122 | `pendingWork == nil` 时 `applyPreferences()` + 立即采一帧。 |
| `stop()` | 124–135 | 取消 pendingWork 并置 nil；`frset_conn_set_active(0)`、`frset_net_top_set_active(0)`；主线程 `isRunning=false`。 |
| `refresh()` | 138–140 | 采样队列 `sampleOnce()`（不等定时器）。 |
| `applyPreferences()` | 145–163 | 设 `reader.temperatureEnabled`（温度开关 ∧ sensors 模块）；总开关关 → `stop()`；间隔按 `uiActive` 取 `base` 或 `max(base,5)`；`scheduleNext`。 |
| `scheduleNext(interval:)` | 165–188 | 取消旧 WorkItem → 建新 WorkItem（内含**重算门控**的 `scheduleNext`）→ `asyncAfter`。 |
| `sampleOnce()` | 190–313 | 见下方流程。 |
| `resetHistory()` | 316–324 | 重建 buffers、`MonitorExtra.reset()`、主线程清 `history`。 |

**`sampleOnce()` 流程（190–313，124 行，跨模块 + 跨线程）**
① `FRSET_PERF_PROBE` 分段计时（生产路径只多一次静态布尔）。
② `StatsDataProvider.shared.refresh(uiActive:)` —— **跨模块边界**：这里驱动 C 层 GPU/SMC/进程/连通性采集，也是 `frset_conn_set_active` 的置位点。
③ 读 `g_snap`（C 全局快照）判 `valid`；有效则 `reader.readResult(needFull:false)`（跳过 5 路直采），无效则 `needFull:true` 兜底。
④ `g_snap` 有效时用 C 值覆写 `cpuUsage/systemCPU/userCPU/idleCPU/perCore/内存/磁盘/网络/电池`（**"两套时间"的修复点**：SwiftUI 面板与菜单栏此后同一时刻同一组值）。
⑤ `reader.loadAverages()`。
⑥ `lock` 内 append 7 个环形缓冲 + 双 scratch 轮换回填 → 解锁。
⑦ `MonitorExtra.update{}` 一次性写压缩内存/负载/峰值/累计（v129 合并两次加锁）。
⑧ 主线程发布 `sample/history/tick`。
**坑**：`perCore` 从 `coreUsage` 元组 `withUnsafeBytes` 读最多 32 核——超过 32 核的机器会被截断（当前无此硬件，但逻辑上写死）。累计流量按 `netBytes × refreshInterval` 估算，而 UI 不可见时实际间隔是 5s——**隐藏期累计值会偏小**（门控改了间隔但没改乘法因子）。

### 3.3 `MonitorReader.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `MonitorReadResult.init` | 11–14 | 赋值。 |
| `MonitorExtra.current` (var) | 42–45 | 加锁读快照。 |
| `MonitorExtra.update(_:)` | 47–51 | 加锁 inout 变异。 |
| `MonitorExtra.reset()` | 53–57 | 重建 Snapshot。 |
| `init()` | 128 | 空。 |
| `readResult(needFull:)` | 141–181 | 见下方。 |
| `loadAverages()` | 184–186 | → `readLoadAverages()`。 |
| `readCPU()` | 190–249 | `host_processor_info` 差分；`vm_deallocate` 释放；首帧无基线返回 `(0,0,0,1,perCore 全 0)`。 |
| `readMemory()` | 253–281 | `host_statistics64` → used = active+inactive+wired+compressed−purgeable（钳到 total）；pressure = used/total；swap。 |
| `readSwapUsage()` | 283–288 | `sysctlbyname("vm.swapusage")`。 |
| `readLoadAverages()` | 290–297 | `getloadavg`；非有限归零。 |
| `readNetworkCounters()` | 301–330 | `getifaddrs` 汇总 UP 非 loopback 接口（按名去重），`read`=incoming。 |
| `readNetworkRate()` | 333–343 | 与上次差分 / elapsed。 |
| `readDiskRate()` | 347–381 | `IOBlockStorageDriver` 遍历累加 `Bytes (Read/Write)` 差分。 |
| `readTemperatures(timeout:)` | 386–415 | 单飞 + `DispatchSemaphore` 等待（默认 150ms）；超时返回缓存。 |
| `readRawTemperatures()` | 418–437 | 打开 AppleSMC → 逐 key 读，值域 `(-20...130)` 过滤。 |
| `readSMCTemperature(connection:key:)` | 440–473 | `kSMCGetKeyInfo`(9) + `kSMCReadKey`(5)；解码 `sp78`/`fpe2`/`flt `。 |
| `smcCall(connection:input:output:)` | 475–490 | `IOConnectCallStructMethod` selector 2；`status == KERN_SUCCESS && output.result == 0`。 |
| `readBatteryLevel()` | 494–507 | `IOPSCopyPowerSourcesInfo` → current/max。 |
| `readPower(into:)` | 516–554 | 见下方。 |
| `prop(_:)`（嵌套） | 521–523 | `IORegistryEntryCreateCFProperty` 单键。 |
| `delta(_:_:)` | 558–560 | 回绕保护。 |
| `rate(_:elapsed:)` | 562–567 | 非有限/负值归零，钳 `UInt64.max`。 |
| `clamp(_:)` | 569–572 | `[0,1]` + isFinite。 |
| `uint64Value(_:)` | 574–578 | NSNumber/UInt64 → UInt64。 |
| `fourCharCode(_:)` / `fourCharString(_:)` | 580–590 | SMC key ↔ UInt32。 |

**`readResult(needFull:)`（141–181）**
`needFull` 是 v125 的性能开关：`true` 走 CPU+内存+网络+磁盘+电池全量；`false` 只读 `readMemory()`（压力/交换/压缩）+ 温度 + 功耗。**风险**：`false` 路径下 `sample.memoryUsed/memoryTotal` 保持默认 0——若某次 `g_snap` 不可用而 `needFull` 又误传 false，面板会显示 0。当前调用点用 `!gSnapValid` 决定，逻辑自洽。

**`readPower(into:)`（516–554）语义**
接电源时：充电且 `BatteryPower > 0` → 用电池充入功率；否则用 `SystemPowerIn`（适配器输入）。放电时取 `|BatteryPower|`。注释记录了 M4 MacBook Pro 实测值（接电 19464mW / 放电 -19904mW）作为口径依据。**坑**：`prop("PowerTelemetryData")` 在部分机型不存在 → `powerWatts` 为 nil → 面板显示 "—"（优雅降级，符合预期）。

### 3.4 `StatsDataProvider.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `StatsProcItem.init(...)` | 37–45 | 默认 `pids=[pid]`、`iconPath=""`、`children=[]`。 |
| `StatsSnapshot.init()` | 168 | 空。 |
| `init()` | 215 | 私有。 |
| `current` (var) | 218–221 | 加锁只读快照。 |
| `refresh(uiActive:)` | 233–536 | 见下方。 |
| `mark(_:)`（嵌套） | 251–256 | `FRSET_PERF_PROBE` 分段日志。 |
| `readProcList(kind:max:)` | 553–683 | 见下方。 |
| `sortChildren(_:)`（嵌套） | 615–630 | 按 kind 分桶降序 + 名称兜底。 |
| `key(_:)`（嵌套） | 616–622 | 子进程分桶键。 |
| `rank(_:)`（嵌套） | 633–639 | 组排序分桶键。 |
| `appBundlePath(_:)` | 695–699 | 截到首个 `.app`。 |
| `appDisplayName(bundle:)` | 705–723 | `CFBundleDisplayName` → `CFBundleName`(≤24) → 文件名；带锁缓存。 |
| `readFans()` | 726–750 | `FNum` + `F{i}ID/Ac/Mn/Mx`，percent = (rpm−min)/(max−min)。 |
| `primaryInterfaceName()` | 753–758 | `SCDynamicStore` 的 `State:/Network/Global/IPv4` → PrimaryInterface。 |
| `genericSensorName(key:category:)` | 766–769 | 「功率传感器（PHPB）」式回落名。 |
| `railFamilyName(key:)` | 778–787 | v132：4 字符 V/I/P 开头 + b/l 结尾 → 供电轨三件套命名。 |
| `sensorDisplayName(_:)` | 791–808 | 官方名 → 供电轨 → 首字母族推断。 |
| `StatsFormat.voltage/amperage/watts/wattHours/rpm/ms/capacity/remaining` | 815–856 | 8 个格式化函数（`remaining` 把秒转「h 小时 m 分」）。 |

**`refresh(uiActive:)` 结构（233–536，304 行）**
四档节流参数：`procInterval`（3s/15s）、`scanInterval`（5s/30s）、`slowInterval`（5s/30s）、`heavyDue = uiActive || slowDue`。
① 先置 `frset_conn_set_active(uiActive)` / `frset_net_top_set_active(uiActive)`（**跨模块副作用：控制 C 层后台线程**）。
② `lock` 拷出 `storage` 到局部 `snap`（读-改-写不带锁，末尾再整体写回）——**这意味着 refresh 期间其他线程读到的仍是旧快照**（正确），但若将来出现第二个写者就会互相覆盖。
③ `heavyDue`：GPU（3 个 Double 缓冲，先清零防 C 层未写留垃圾）→ CPU 集群（`frset_cpu_clusters` + 自采 `frset_cpu_sample` 算 cluster usage）→ 电池（26 字段）。
④ 每帧：内存构成（`frset_mem_sample` + `frset_mem_pressure`）、连通性（非阻塞读 C 缓存 + `connHistory` 双缓冲回填）、GPU 型号（只取一次）。
⑤ `slowDue`：磁盘容量、型号/连接/文件系统（静态，取到即缓存）、SMART、网络 Top、本地 IP/主接口。
⑥ `scanInterval`：`frset_smc_scan(600)` → 逐项走 `sensorMeta` 缓存（首次建表时 4 次 C 名表调用）→ 计算 avg/hottest CPU/GPU、GPU 温度最大值、风扇。
⑦ `procInterval`：CPU/内存/磁盘三份进程排行。
⑧ `snap.updatedAt = Date()` → 加锁写回。
**坑**：
- `sensorPtr` 分配 600 项 × `frset_sensor_t`，`defer` 释放；若 C 层返回 >600 会被截断（无告警）。
- `category` 必须用扫描层的 `raw.category`（0温1扇2压3流4功5能），**不能**用官方名表的 `type`（口径不同，注释记录了"BDAT 显示 5388°"的事故）。

**`readProcList(kind:max:)`（553–683，131 行，带锁 + 静态缓冲）**
① `procBufferLock` 串行化后复用静态 512 项 `frset_proc_t` 缓冲（v129：原每周期 4 次 313KB malloc）。
② 逐条：路径 → `appBundlePath` → 归类键（bundle / name / path 三级）；组内累加 cpu/mem/r/w，并记录 `ChildRec`（只存下标+数值，不建字符串）。
③ 排序：`rank` 分桶 + 上一轮名次（`lastOrders[kind]`）+ 名称字典序 → 稳定不跳。
④ 只对 `prefix(max)` 的组**实体化** `StatsProcItem`（含 pids / children），并对子进程 `sortChildren`。
**坑**：`ChildRec.idx` 是 `ptr` 下标，靠"函数返回前缓冲不被复用"成立——依赖 `procBufferLock` 与"只有采样队列调用"两个前提，二者缺一即读到别的进程的数据。

### 3.5 `StatsModulePanels.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `StatsModulePage.init(module:)` | 22–24 | 赋值。 |
| `StatsModulePage.body` | 26–39 | 7 分支分发（power 与 cpu 共用）。 |
| `StatsRing.init(segments:lineWidth:trackOpacity:)` | 50–54 | 赋值。 |
| `StatsRing.init(value:color:lineWidth:)` | 56–60 | 单段包装（clamp）。 |
| `StatsRing.body` | 62–91 | `GeometryReader` + 内缩 Circle + 分段 trim + `rotationEffect(-90)`；v85 注释：不可在闭包内注入基于 `geo.size` 的 environment（死循环）。 |
| `StatsHalfGauge.body` | 101–140 | 三段弧 + 指针 + 中心点 + 底部 caption。 |
| `gaugeSegments` (var) | 142–148 | 0–0.5 绿 / 0.5–0.75 黄 / 0.75–1 红。 |
| `gaugeIndex` (var) | 150–154 | 当前段（其余段 0.35 透明度）。 |
| `StatsLegendRow.body` | 165–183 | 色点 + 标签 + 右对齐值。 |
| `StatsHistoryChart.body` | 192–202 | 圆角底 + `MonitorAreaSparkline`。 |
| `StatsHistoryDualChart.body` | 212–226 | 面积 + 第二条折线。 |
| `StatsProcTable.columnWidth` (var) | 253 | 单列 86 / 双列 64。 |
| `childValueTexts(_:)` | 255–258 | 子进程数值（可覆盖）。 |
| `childLabel(_:group:)` | 262–272 | 去掉与组名重复前缀；同名 → 「主进程」。 |
| `StatsProcTable.body` | 274–393 | 表头 + 行（chevron / 图标 / 名称 / 副标题 / 「N 进程」/ 数值列 / 退出按钮）+ 点击展开或弹菜单 + contextMenu + 展开子行。 |
| `StatsAppIcon.cachedIcon(path:name:)` | 437–455 | 路径存在 → `NSWorkspace.icon(forFile:)`；否则按名在运行 app 找；成功才写 `NSCache(192)`；`image.size = 32`。 |
| `ProcMenuPresenter.present(for:values:at:)` | 464–467 | `menu.popUp(at:)`。 |
| `ProcMenuPresenter.buildMenu(item:values:)` | 470–489 | 信息项 + 退出项（`representedObject = item`）+ 取消。 |
| `ProcMenuPresenter.quit(_:)` | 491–494 | 取 `representedObject` → `StatsProcQuitter.quit`。 |
| `StatsProcQuitter.quit(item:)` | 520–530 | 逐 pid `kill(SIGTERM)`，主线程 Toast 汇总。 |
| `StatsProcQuitter.confirmAndQuit(item:)` | 534–545 | `NSAlert.runModal`（模态）确认后 quit。 |
| `StatsCoreGrid.body` | 553–571 | 每核方块，性能核橙 / 能效核青，亮度 = 占用。 |
| `CPUStatsPanel.body` | 579–664 | 温度环 + 分段环 + 图例 + 启动时间 + 负载历史 + 每核条 + 集群 + 平均负载 + 进程表(5)。 |
| `CPUStatsPanel.loadCell(_:value:)` | 666–675 | 三列负载小格。 |
| `CPUStatsPanel.primaryTemperature()` | 679–689 | calcHottest/avg → CPU group max → `sample.temperatures` 三键 → 首个值。 |
| `CPUStatsPanel.uptimeText()` | 691–698 | 天/小时/分钟。 |
| `MemoryStatsPanel.body` | 707–784 | 半圆仪表 + 环 + 图例 + 内存维护 + 使用历史 + 构成条 + 图例 + 进程表(5)。 |
| `MemoryStatsPanel.segment(width:color:)` | 786–788 | 构成条一段。 |
| `MemoryStatsPanel.pressureCaption(_:)` | 790–797 | sysctl level 优先，否则按 used/total 0.6 阈值。 |
| `MemoryStatsPanel.pressureColor(_:)` | 799–806 | 同上配色。 |
| `GPUStatsPanel.body` | 814–844 | 三环（usage/renderer/tiler）+ 历史 + 详细信息。 |
| `GPUStatsPanel.ring(value:size:fontSize:)` | 846–853 | 环 + 百分比。 |
| `DiskStatsPanel.body` | 862–957 | 卷名折叠头 + 图例 + 双线历史 + 容量条 + SMART + 进程表（双列）。 |
| `DiskStatsPanel.legendValue(color:value:)` | 959–966 | 小图例。 |
| `NetworkStatsPanel.body` | 976–1050 | 速率历史 + 峰值/累计 + 连接状态 + 连通网格 + 诊断段 + 接口 + 网络进程表。 |
| `NetworkStatsPanel.diagnosticsSection` | 1054–1168 | 内网下拉 / 公网 / 归属 / 代理 / 境外 / 站点延迟网格 / DNS；`onAppear` 60s 节流 refresh。 |
| `NetworkStatsPanel.latencyColor(_:)` | 1172–1180 | <80 绿 / <200 黄 / <400 橙 / 其余红；超时淡灰。 |
| `NetworkStatsPanel.legendValue(color:value:)` | 1182–1189 | 同 Disk 版（**重复实现**）。 |
| `StatsConnGrid.color(for:)` | 1222–1228 | 1 绿 / 0 红 / 其它淡灰。 |
| `SensorsStatsPanel.body` | 1234–1274 | 温度/电压/电流/功率四组 + 风扇。 |
| `SensorsStatsPanel.orderedTemperatures(_:stats:)` | 1277–1296 | 4 个计算项置顶 + 其余降序取 12。 |
| `SensorGroup.body` | 1307–1342 | 分节线 + 每行（名称 96 宽 / 比例条 / 值 72 宽）。 |
| `SensorGroup.fraction(_:)` | 1344–1348 | `scaleMax` 优先，否则组内峰值；最小 0.04。 |
| `SensorGroup.line` (var) | 1350–1352 | 0.5pt 分隔线。 |
| `BatteryStatsPanel.body` | 1360–1453 | 环 + 状态/剩余/循环/健康 + 温度/电压/电流比例条 + 容量堆叠 + 健康度 + 适配器段。 |
| `BatteryStatsPanel.statusText(_:)` | 1455–1461 | 无电池/充电中/已充满/已接电源/放电中。 |
| `BatteryStatsPanel.healthText(_:)` | 1463–1467 | max/design（上限 1.2 防 >100%）。 |
| `BatteryStatsPanel.healthFraction(_:)` | 1469–1472 | 上限 1。 |
| `BatteryStatsPanel.batteryTempColor(_:)` | 1475–1481 | <40 绿 / 40–50 橙 / >50 红。 |
| `StatsBarRow.body` | 1491–1508 | 标签 + 比例条（最小 0.02）+ 值。 |

### 3.6 `MonitorDetailView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `MonitorDetailSelection.init(_:)` | 9 | 默认 `.cpu`。 |
| `MonitorPerformanceContent.init(topInset:)` | 20–22 | 默认 0。 |
| `MonitorPerformanceContent.body` | 24–31 | `MonitorDetailView(selection: shared, pageMode:false, fixedWidth:nil)` + 14/10 内边距 + topInset。 |
| `MonitorDetailView.init(module:pageMode:)` | 42–46 | 自建 `MonitorDetailSelection`，`fixedWidth = 292`。 |
| `MonitorDetailView.init(selection:pageMode:fixedWidth:)` | 48–52 | 共享 selection 版。 |
| `MonitorDetailView.body` | 54–78 | pageMode 直出 content；否则 modulePicker + Divider + ScrollView(content) + Divider + footer，`frame(width: fixedWidth)`。 |
| `modulePicker` (var) | 90–122 | `FlowHStack` 自适应换行；选中项条件填充 + contentShape（v82 修复点不动的两处根因）。 |
| `availableModules()` | 128–149 | 过滤关闭模块（保留当前选中）+ sensors 看温度开关 + battery/gpu 看有无数据；最后补当前项。 |
| `content` (var) | 154–165 | 8 模块分发。 |
| `powerPanel` | 169–197 | 图标 + 输入/输出 + 瓦数 + 电量 + 电源 + 数据源说明。 |
| `cpuPanel` | 201–277 | 温度环 + 总占用环 + 图例（含启动时间）+ 历史 + 每核柱 + 集群 + 平均负载 + 进程表(8)。 |
| `uptimeText()` (static) | 280–287 | 与 `CPUStatsPanel.uptimeText` **重复实现**。 |
| `loadCell(_:value:)` | 289–298 | 负载小格（12pt，`StatsModulePanels` 版 14pt）。 |
| `primaryTemperature()` | 300–306 | **只**读 `sample.temperatures`（不读 SMC 全量扫描）——与 StatsModulePanels 版口径不同。 |
| `memoryPanel` | 310–367 | 环 + 已用/总量/Swap/压缩 + 内存维护 + 构成条 + 图例 + 历史 + 压力 + 进程表(8)。 |
| `legendItem(_:color:)` | 369–374 | 圆点 + 文案。 |
| `networkPanel` | 378–485 | 双速率 + 双线曲线 + 峰值/累计 + 连接 + 网格 + 接口 + 网络进程表(8) + `PortOccupancySection`。 |
| `connCellColor(_:)` | 488–494 | 1/0/其它。 |
| `diskPanel` | 498–597 | 读/写 + 历史 + 峰值 + 容量 + 详情 + SMART(8 行) + 磁盘进程表(8) + 来源说明。 |
| `sensorsPanel` | 601–699 | 无数据降级 / 计算项 + 风扇 + 五类分节 / 降级卡片网格；末尾电池电量。 |
| `sensorCategorySection(title:category:unit:items:)` | 708–740 | 过滤 + 值域过滤（温度<110/电压<300/电流<100）+ 降序 + 限行（温度 6、其它 3）。 |
| `sensorBarRow(name:valueText:ratio:color:)` | 743–764 | 温度可视化行（92 名称 + 条 + 70 值）。 |
| `batteryPanel` | 768–849 | 环 + 状态徽章 + 剩余/容量 + 健康度 + 电池段 + 适配器段；无电池降级。 |
| `batteryStatusText(_:)` | 852–856 | 三态（无「已充满」分支）。 |
| `sensorValueText(_:unit:)` | 859–867 | 5 种单位格式化。 |
| `gpuPanel` | 871–912 | 环 + 型号/渲染/平铺/温度 + 历史 + 来源。 |
| `footer` | 916–947 | 刷新间隔文案 + 立即刷新 + 部件设置 + 监测设置。 |
| `StatsProcRows.body` | 956–969 | **无调用方的私有组件**（被 `StatsProcTable` 取代）。 |
| `StatsDualValue.body` | 977–983 | 同上。 |

### 3.7 `MonitorPopoutWindow.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `ContentHeightKey.reduce(value:nextValue:)` | 20–23 | 取最近非 0 值。 |
| `PopoutRootView.body` | 45–67 | ScrollViewReader + "top" 锚点 + `MonitorPerformanceContent(topInset:22)` + 高度偏好 + `resetToken` 滚顶。 |
| `convenience init()` | 83–129 | 建 hosting（`sizingOptions=[]`）+ `.frsetThemeChrome()` + `NSVisualEffectView(.popover)` 12pt 圆角 + borderless `MonitorPopoutPanel` 380×640 + 自绘关闭钮 + delegate。 |
| `init(window:)` | 131–133 | 私有 override。 |
| `init?(coder:)` | 135 | `fatalError`。 |
| `isVisible` (var) | 140 | `window?.isVisible`。 |
| `currentModule` (var) | 156 | `sharedSelection.module`。 |
| `wasJustDismissed(within:)` | 160–162 | `uptime - lastDismissUptime < interval`。 |
| `scheduleWarmup(after:)` | 170–184 | 3s 后离屏布局（`orderFrontRegardless` + `layoutSubtreeIfNeeded` + `RunLoop 0.1s` + `orderOut`）。 |
| `toggle(module:)` | 187–193 | 可见 → dismiss，否则 open。 |
| `open(module:anchor:)` | 197–236 | 见下方。 |
| `cancelDismiss()` | 240–248 | 撤销在途收起：清 `isDismissing`、`appearToken += 1`、清动画、复位 transform/opacity。 |
| `showModule(_:)` | 251–257 | 已开则 `cancelDismiss()` + 换模块（不动位置）。 |
| `resize(toContentHeight:)` | 267–281 | clamp `[200, min(880, 屏高-40)]`；差异 >1pt 才动；**顶边固定**（`origin.y -= delta`）；`animator().setFrame` + `dPage`。 |
| `playAppearAnimation(anchor:)` | 286–306 | scale 0.93 + 位移（锚点方向）+ 淡入，0.28s `caBackOut`，completion 复位。 |
| `dismissPopout()` | 312–343 | 见下方。 |
| `finishDismiss(token:)` | 346–364 | 幂等收尾：token 校验 → `orderOut` + 层复位 + `unregister` + `setPanelActive(false)` + 探针。 |
| `anchorDx(anchor:)` | 367–371 | 锚点相对窗口中心的水平比例 → 反向位移。 |
| `origin(for:anchor:)` | 376–392 | 有锚点：居中钳制、顶边 `visibleFrame.maxY - h - 2`；无锚点：右上贴边，若主面板占着右上方则左移让位。 |
| `screen(for:)` (static) | 398–406 | 锚点命中屏 → `NSScreen.main` → 首屏（v71 修「超出右缘 145pt」）。 |
| `windowDidResignKey(_:)` | 412–430 | `FRSET_PANEL_PIN=1` 放行；`NSApp.isActive` 时**不关**（本 app 内换 key，交给点击目标）；否则 `TransientWindowCenter.requestDismiss`。 |

**`open` 的五步纪律（197–236）**
① `appearToken += 1` 让在途 dismiss completion 失效；② `isDismissing = false` 清锁；③ `scrollState.resetToken += 1` 滚回顶部（否则重开时顶部模块条在视口外，用户以为"没有切换按钮"）；④ 清 layer 动画并 `transform = identity / opacity = 1` 兜底（防上次白屏态残留）；⑤ `setFrameOrigin` + `alphaValue = 1` + `playAppearAnimation` + `activate` + `makeKeyAndOrderFront` + `TransientWindowCenter.register` + `setPanelActive(true)`。
**坑**：`setPanelActive(true)` 在 open 里置位、`finishDismiss` 里复位。如果窗口被系统直接关掉（非本类路径），复位永远不会发生 → 采样器停在"可见"档。

**`dismissPopout()` 的双保险（312–343）**
layer 退场动画 + `CATransaction.setCompletionBlock` 调 `finishDismiss`；同时 `asyncAfter(0.2)` 也调 `finishDismiss`。注释记录了历史 bug：只靠 completion 时窗口被遮挡/动画被跳过 → completion 不执行 → 窗口永远留屏（"点外不关"）。`isDismissing` 保证多路触发只跑一次，`appearToken` 保证重开后不误关。

### 3.8 `MonitorCenterView.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `activePage` (var) | 22 | `page` 的兼容别名。 |
| `selectHome()` | 24–26 | `page = .home`。 |
| `selectPerformance(module:)` | 28–36 | 可选设模块 → `page = .performance` → `record(.monitorPanelOpen)` + `record(.activityMonitorClick)`。 |
| `selectTransferDock()` | 38–42 | `page = .transfer` + `record(.transferDockOpen)`。 |
| `selectCast()` | 45–48 | `page = .cast` + `record(.screenCastOpen)`。 |
| `isTransferDockEnabled` (static) | 52–54 | 读 `panelTransferDock`（默认 true）。 |
| `init()` | 58 | 空。 |

### 3.9 `StatsBarEngine.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `module(forIndex:)` | 20–31 | 0 CPU / 1 内存 / 2 GPU / 3 磁盘 / 4 网络 / 5 传感器 / 6 电池。 |
| `start()` | 38–144 | 幂等；注册 `FrsetScreenRecDidSave` 通知；`FSStatsSetOpenMonitorHandler(trampoline)`；`syncMainItem()`；`startScreenGapProbe()`；`FSStatsTickStart()`；`WidgetSettingsSelfTest.runIfRequested()`；`FRSET_STATSBAR_PROBE` 六种探针。 |
| `stop()` | 147–152 | `FSStatsTickStop()` + 停 Timer + `isStarted = false`。 |
| `startScreenGapProbe()` | 167–213 | 0.5s `Timer(.common)`；静息降频（连续 4 拍不变且 app 非活跃 → 每 4 拍测一次）；不可见时下发 -1。 |
| `syncMainItem(attempts:)` | 219–227 | 取不到主状态项时 0.2s 重试最多 10 次，拿到后 `FSBarSetMainItem`。 |
| `openMonitor(index:)` | 233–259 | 见下方。 |
| `openSettings()` | 262–268 | 收敛到设置窗 `pane: "barSettings"`（v71：不再用 `FSBarSettingsOpen`）。 |
| `openRecorder()` | 271–277 | `record(.screenRecord)` + Toast + `FSScreenRecOpenSettings()`。 |
| `statsBarOpenMonitorTrampoline(_:)` | 282–285 | 无捕获 C 跳板：主队列 → `openMonitor`。 |

**`openMonitor(index:)` 判定树（233–259）**
窗口已开 → 同模块再点 = `dismissPopout()`（**v63 修「点了关不掉」**）；不同模块 = `showModule`。窗口未开 → 若 `wasJustDismissed() && currentModule == module` 则保持关闭（防"关了又立刻弹回来"）。否则 `FSBarLastAnchorScreenRect()` 作锚点 open。

### 3.10 `MonitorStatusItems.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `isHidden(id:)` | 13–15 | 不在 `visibleStatusItemIDs()` 即隐藏。 |
| `cpuTitle()` | 18–20 | 单行化。 |
| `memoryTitle()` | 22–24 | 同上。 |
| `networkTitle()` | 26–28 | 同上。 |
| `cpuTwoLine()` | 31–37 | 合并模式/总开关/模块开关三重门禁；`百分比 + 趋势符`。 |
| `memoryTwoLine()` | 40–44 | `RAM` + 压力百分比。 |
| `networkTwoLine()` | 47–52 | `↑compactRate` / `↓compactRate` 双排。 |
| `powerTitle()` | 54–56 | 单行化。 |
| `powerTwoLine()` | 59–66 | `输入/功耗` + `⚡瓦数`。 |
| `powerDetailText()` | 69–77 | 详情文案（充电中/接电源/输出/无数据）。 |
| `diskTitle()` | 80–82 | 单行化。 |
| `diskTwoLine()` | 85–90 | `R..` / `W..`。 |
| `sensorsTitle()` | 93–95 | 单行化。 |
| `sensorsTwoLine()` | 97–104 | 需 `showTemperatures`；取 temperatures 最大值。 |
| `combinedTitle()` | 107–109 | 单行化。 |
| `combinedTwoLine()` | 111–119 | `CPU..` / `RAM..`，两者都关则 nil。 |
| `title(from:)` | 121–124 | nil → `hiddenMarker`；否则空格连接。 |
| `trendSymbol(_:)` | 127–133 | 最近两点差 >0.03 ↑ / <-0.03 ↓ / 否则 →。 |
| `registerAll()` | 138–167 | 注册 7 项（power/cpu/network/memory/disk/sensors/combined），priority 9–15。**当前无调用方**。 |
| `register(id:priority:title:twoLineTitle:popover:)` | 169–182 | → `StatusItemRegistry.register`。 |

### 3.11 `MonitorPreferences.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `keyEnabled(for:)` | 70–72 | `"monitor.\(rawValue).enabled"`。 |
| `isEnabled` (var) | 75–78 | 读 `monitor.enabled`（默认 true），setter 后 `notify()`。 |
| `refreshInterval` (var) | 81–90 | legacy 键，钳 `[0.5,10]`，默认 2.0。 |
| `combinedMode` (var) | 93–96 | legacy 键，默认 false。 |
| `showTemperatures` (var) | 99–102 | 默认 true。 |
| `isModuleEnabled(_:)` | 105–107 | 读 `keyEnabled(for:)`，默认 `enabledByDefault`。 |
| `setModuleEnabled(_:_:)` | 109–112 | 写 + notify。 |
| `visibleStatusItemIDs()` | 115–123 | 总开关关 → `[]`；合并模式 → `["monitor.combined"]`；否则含 combined + 各启用模块。 |
| `resetToDefaults()` | 126–135 | 全部写回默认 + notify。 |
| `notify()` | 137–139 | post `didChangeNotification`。 |

### 3.12 `MonitorHistory.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init(capacity:)` | 10–13 | 预填 0 数组。 |
| `append(_:)` | 15–19 | 非有限归零；环形推进。 |
| `values()` | 22–26 | 新建数组包装。 |
| `values(into:)` | 31–39 | 复用缓冲（`removeAll(keepingCapacity:)` + 顺序回填）。 |
| `count` / `last` (var) | 41–43 | 已填数量 / 最新值。 |
| `reset()` | 45–49 | 重建。 |

### 3.13 `MonitorFormat.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `bytes(_:)` | 8–17 | 1024 进制，≥100 取整。 |
| `rate(_:)` | 20–22 | `bytes + "/s"`。 |
| `compactRate(_:)` | 25–27 | 去空格（菜单栏省宽）。 |
| `directionalRate(upload:download:)` | 30–32 | `↑.. ↓..`。 |
| `percent(_:)` | 35–38 | clamp + 取整。 |
| `percentFine(_:)` | 41–44 | 一位小数。 |
| `temperature(_:)` | 47–49 | `%.0f°`。 |
| `load(_:)` | 52–54 | `%.2f` + isFinite。 |
| `diskRate(read:write:)` | 57–59 | `R.. W..`。 |
| `power(_:)` | 62–65 | ≥100W 取整。 |

### 3.14 `MonitorCharts.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `MonitorSparkline.init(values:upperBound:)` | 11–14 | 赋值。 |
| `MonitorSparkline.path(in:)` | 16–32 | 归一化折线；≤1 点返回空 path。 |
| `MonitorAreaShape.init(...)` | 40–43 | 赋值。 |
| `MonitorAreaShape.path(in:)` | 45–54 | 折线 + 闭合到底边。 |
| `MonitorAreaSparkline.init(...)` | 63–67 | 赋值。 |
| `MonitorAreaSparkline.body` | 69–83 | 渐变填充 + 描边 + `.drawingGroup()`。 |
| `MonitorBarChart.init(...)` | 94–98 | 赋值。 |
| `MonitorBarChart.body` | 100–115 | 底部对齐柱状，透明度随值。 |
| `MonitorRing.init(...)` | 132–136 | 赋值。 |
| `MonitorRing.body` | 138–150 | 内缩环 + trim + `-90°`。 |
| `MonitorStackedBar.Segment.init` | 161–165 | 赋值。 |
| `MonitorStackedBar.init(segments:height:)` | 171–174 | 赋值。 |
| `MonitorStackedBar.body` | 176–192 | 归一化 HStack + 圆角裁剪。 |
| `MonitorCard.init(content:)` | 217–219 | 存闭包结果。 |
| `MonitorCard.body` | 221–226 | padding 10 + `GlassCardBackground`。 |
| `MonitorRow.init(label:value:color:)` | 234–238 | 赋值。 |
| `MonitorRow.body` | 240–254 | 标签 + 右对齐等宽值（`minimumScaleFactor 0.8`）。 |
| `MonitorSectionTitle.init(_:)` | 260–262 | 赋值。 |
| `MonitorSectionTitle.body` | 264–275 | 两侧细线 + 居中标题。 |

### 3.15 `MonitorSettingsPane.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `MonitorSettingsState.init()` | 9 | 空。 |
| `MonitorSettingsPane.init(state:)` | 16–18 | 注入 state。 |
| `body` | 20–42 | 三段 + `onReceive(didChange)` → `bump()`；`onAppear/onDisappear` 控制 `setSettingsActive`。 |
| `generalSection` | 46–98 | 总开关、刷新滑杆（setter 内 `applyIntervalToBarWidgets`）、菜单栏部件入口。 |
| `modulesSection` | 102–127 | 8 个模块开关 + 实时状态行。 |
| `advancedSection` | 131–159 | 温度采集开关 + 清空历史 + 恢复默认 + 已采样次数。 |
| `applyIntervalToBarWidgets(_:)` | 164–170 | `FSBarAllModules()` → 逐模块 `FSBarCfgSet(updateInterval)` → `FSBarReloadFromStore()`。**跨模块副作用：改菜单栏部件刷新率**（v93：不联动则用户觉得"设置没生效"）。 |
| `statusLine(for:)` | 172–193 | 关闭的模块显示「已停用」；否则按模块取实时值。 |
| `bump()` | 195 | `state.version &+= 1`。 |

### 3.16 `NetworkDiagnostics.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init()` | 57–63 | ephemeral 会话（6s 超时、忽略缓存、跟随系统代理）。 |
| `selectedAddress` (var) | 76–79 | 选中网卡地址或首个或「—」。 |
| `selectInterface(_:)` | 81–83 | 写 `selectedInterface`。 |
| `refresh()` | 87–113 | `inFlight` 去重；`frset.netdiag` 队列依次：网卡 → 代理 → 公网IP（回调主线程）→ 延迟 → DNS；末尾主线程置 `isLoading=false/lastRefresh`。 |
| `looksProxied(location:)` | 115–120 | 归属含「中国」→ false，否则 true。 |
| `probeProxy()` | 130–168 | 系统代理 + 端口探测 + 进程名三源 → 主线程写 6 种组合的 label/address/note。 |
| `systemProxyInfo()` | 171–184 | HTTP 优先，其次 SOCKS。 |
| `clientName(forPort:)` | 187–196 | 端口 → 客户端名映射。 |
| `detectProxyProcess()` | 199–221 | `Process` 跑 `/bin/ps -Ao comm=`，**`waitUntilExit` 同步阻塞**，按名匹配 6 种客户端。 |
| `detectListeningProxyPort()` | 227–229 | 8 个候选端口首个可连的。 |
| `isLocalPortOpen(_:)` | 232–252 | 非阻塞 connect + `poll` 80ms。 |
| `reloadInterfaces()` | 256–290 | `getifaddrs` 收集 UP 非 loopback IPv4；主线程写 interfaces 并修正选中项。 |
| `primaryInterfaceName()` | 293–308 | `Process` 跑 `/sbin/route -n get default`，**同步阻塞**，失败回落 `en0`。 |
| `probePublicIP(completion:)` | 313–333 | `myip.ipip.net`（UA `curl/8.0`）→ 解析 IP + 归属；失败转 fallback。 |
| `probePublicIPFallback(completion:)` | 336–365 | `ip.3322.net` 取 IP → `ipwho.is` 反查 country/region/city。 |
| `extractIP(from:)` | 372–378 | 静态正则首个 IPv4。 |
| `extractLocation(from:)` | 380–387 | 「来自于：」之后 → 归一空格。 |
| `probeLatencies()` | 391–414 | 并发 HEAD 8 站点 + `DispatchGroup.wait()` **阻塞 frset.netdiag 队列**，主线程发布。 |
| `probeDNS()` | 418–440 | bash.ws/id → test/{id}?json → 取 `type=dns` 前 4 条。 |

**`refresh()` 的阻塞结构（87–113）**
整个函数体在 `queue`（`frset.netdiag`）上串行执行，且内部有**两处同步阻塞**：`detectProxyProcess` 等 `ps` 退出、`primaryInterfaceName` 等 `route` 退出、`probeLatencies` 的 `group.wait()`。它们不卡主线程，但会让"刷新"整体比单个请求慢；`refresh()` 从 UI 的 `onAppear` 触发，用户在网络页停留超过 60s 再切回会重跑一次。

### 3.17 `PortInspector.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `init()` | 81 | 私有。 |
| `start()` | 86–97 | 主线程断言（否则转主线程）；`isRunning` 去重；立即 `scan(force:true)`；建 30s Timer（tolerance 1.5，`.common`）。 |
| `stop()` | 100–105 | 停 Timer（保留快照）。 |
| `scan(force:)` | 109–135 | 非强制时：非前台跳过、`minInterval 3s` 节流；`isScanning` 去重；`queue` 上 `runLsof` → 主线程写结果或 `lastError`（**失败保留旧数据**）。 |
| `runLsof()` | 144–176 | `Process` + `lsof -nP -FpcnPT -iTCP -sTCP:LISTEN -iUDP`；`LC_ALL=C`；3s 看门狗（`terminationHandler` + semaphore）；超时 `terminate()`。 |
| `parse(_:)` | 180–250 | 字段流解析（p/c/f/P/n/T），按 `proto-port-process` 合并，`isExposed` 优先排序。 |
| `flush()`（嵌套） | 188–210 | 一条 socket 落库：跳过 `->`（已连接）、TCP 必须 LISTEN、取末段冒号后端口、`0.0.0.0`/`::` 归一为 `*`。 |

### 3.18 `PortOccupancySection.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `filtered` / `visible` / `tcpCount` / `udpCount` / `exposedCount` (var) | 18–26 | 派生数据（每 body 求值各跑一遍 filter）。 |
| `body` | 28–59 | 标题 + 刷新钮 + 摘要 + 卡片或空态 + 页脚；`onAppear/onDisappear` 控制 `start/stop`。 |
| `summary` | 63–78 | 3 个 chip + 扫描中指示器。 |
| `chip(_:color:active:action:)` | 80–98 | 可选可点的胶囊。 |
| `row(_:)` | 102–148 | 端口（verbatim 防千分位）/协议徽标/进程/地址/对外圆点；点击复制。 |
| `emptyState` | 152–164 | 检测中/无监听/无对外。 |
| `footer` | 166–183 | 说明 + 展开全部。 |
| `refreshButton` | 185–200 | 扫描时旋转（`repeatForever`）。 |
| `copy(_:)` | 204–209 | 写剪贴板 + Toast。 |

### 3.19 `Memory/MemoryHelperClient.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `isInstalled` (var) | 32–35 | helper 可执行 + plist 存在。 |
| `isReady()` | 38–43 | `send("version", 2s)` 且版本匹配。**同步阻塞 ≤2s**。 |
| `ensureReady()` | 46–51 | `@MainActor`；detached 探活，不稳则 `install()`。 |
| `install()` | 54–89 | 见下方。 |
| `uninstall()` | 92–107 | bootout + rm 4 个路径（一次授权）。 |
| `optimize()` | 109–113 | detached `send("optimize-memory", 45s)`。 |
| `helperURL` / `plistURL` (var) | 117–127 | Bundle 内路径定位。 |
| `send(_:timeoutSeconds:)` | 131–193 | 见下方。 |
| `AdministratorShell.run(_:)` | 204–215 | `NSAppleScript` + `do shell script ... with administrator privileges`；`-128`/`User canceled.` → `isCancelled`。 |
| `quote(_:)` | 217–219 | 单引号包裹 + `'\''` 转义。 |
| `appleScriptEscape(_:)` | 221–223 | 转义 `\` 与 `"`。 |

**`install()`（54–89）**
一次性 `install` 12 条命令 `&&` 串联：建目录 → 拷 helper → 拷 plist → 写 `client.json`（base64 的 `{uid}`）→ chown/chmod 600 → 去 quarantine → bootout 旧实例 → 删旧 socket → enable → `bootstrap`。成功后 30×200ms 轮询 `isReady()`（最多 6s）。
**坑**：把 `getuid()` 写进 `client.json` 是 root 服务的"谁被允许连"白名单；**该文件在卸载/换用户后不会自动更新**（换账户登录后需重装）。

**`send()`（131–193）**
`AF_UNIX/SOCK_STREAM` + `SO_NOSIGPIPE` + 收发超时 → `connect` → **`getpeereid` 校验对端 UID == 0**（防同机伪造 socket）→ 写 `command\n`（EINTR 重试）→ 读到 `\n` 或 64KB 上限 → `ok `/`error ` 前缀解析。
**坑**：`reply.contains(10)` 在 64KB 上限内扫全文，若响应体里含 `\n` 但尾部不是 `\n` 会返回 `.unavailable`；`timeoutSeconds` 对 `connect` 也生效（SYN 不会卡住 Unix socket，影响可忽略）。

### 3.20 `Memory/MemoryOptimizer.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `MemoryOptimizationStep.parse(_:)` | 12–14 | 空格分隔 → Set。 |
| `title` (var) | 16–21 | 中文名。 |
| `MemoryOptimizationReport.usedDelta` 等 5 个 (var) | 38–42 | 前后差值。 |
| `isNoticeable(_:)` | 44–46 | 负值且 ≥32MB。 |
| `hasNoticeableRelease` (var) | 49–51 | 四项任一可感知。 |
| `releases(before:after:)` | 53–62 | 按 id 求差，≥32MB 才记，降序。 |
| `delta(_:)` | 64–66 | `Int64(clamping:)` 防溢出。 |
| `init()` | 78 | 私有。 |
| `optimize()` | 81–122 | `@MainActor`：去重 → 清 report/message → `ensureReady` → detached 基线（`MemoryBreakdownReader.read` + `topConsumers(40)`）→ helper optimize → 1s 等待 → 复测 → 生成 report；failure/unavailable 写 message。`defer` 复位 `isOptimizing` 与 `helperInstalled`。 |

### 3.21 `Memory/MemoryBreakdown.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `MemoryBreakdown.used/available/usedFraction/pressure` (var) | 23–29 | 派生值。 |
| `MemoryPressureLevel.title` (var) | 37–43 | 正常/偏高/紧张。 |
| `read()` | 47–73 | `host_statistics64` → app（internal−purgeable）/wired/compressed/cached(external)/swap/pressure。 |
| `readSwapUsed()` | 75–80 | `sysctlbyname`。 |
| `readPressureLevel()` | 82–87 | `kern.memorystatus_vm_pressure_level`，失败默认 1。 |

### 3.22 `Memory/ProcessMemoryInspector.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `AppMemoryUsage.nonResident` (var) | 22 | `footprint - resident`。 |
| `topConsumers(limit:)` | 30–63 | 遍历 pid → rusage + path → 归并到 `.app` → 降序 → 取 limit → 排除自身 bundle → 名字三级回落。**同步、遍历全部 pid**（调用方需在后台线程）。 |
| `resourceUsage(of:)` | 65–73 | `proc_pid_rusage(RUSAGE_INFO_V4)`。 |
| `applicationBundlePath(containing:)` | 76–80 | 取**最外层** `.app`。 |
| `allProcessIdentifiers()` | 82–94 | `proc_listpids` 两次调用（先问大小再多给 32 余量）。 |
| `executablePath(of:)` | 96–100 | `proc_pidpath`。 |

### 3.23 `Memory/MemoryOptimizeCard.swift`

| 函数 | 行 | 说明 |
|---|---|---|
| `MemoryOptimizeSection.body` | 7–56 | 状态点（已装绿/未装橙）+ 按钮或进度 + 四态说明（报告/消息/未安装/默认说明）。 |
| `reportView(_:)` | 59–120 | 有可感知释放 → 前后对比 + 4 行差值；否则诚实说明"这次没有可回收的缓存"；响应应用前 3；步骤行。 |
| `deltaRow(_:_:)` | 122–132 | 差值行（负值绿）。 |
| `signed(_:)` | 134–138 | ±0 / + / − 前缀 + 单位。 |

---

## 4. 关键数据流

### 4.1 采样主链（每 tick）

```
Timer/DispatchWorkItem（samplingQueue, interval = uiActive ? base : max(base,5)）
  → MonitorSampler.sampleOnce()
      ├─ StatsDataProvider.shared.refresh(uiActive:)        [跨模块：C 采集层]
      │     ├─ frset_conn_set_active / frset_net_top_set_active
      │     ├─ heavyDue: GPU / CPU 集群 / 电池（IOKit）
      │     ├─ slowDue:  磁盘容量/SMART/网络 Top/本地 IP
      │     ├─ scan:     frset_smc_scan(600) → sensors/fans
      │     └─ proc:     frset_proc_top ×3 → procCPU/Mem/Disk
      ├─ g_snap 有效性判定 → MonitorReader.readResult(needFull:)
      │     ├─ needFull: CPU(host_processor_info) / 内存 / 网络(getifaddrs) / 磁盘(IOKit) / 电池
      │     └─ 恒采:     温度(SMC 150ms 超时) / 功耗(AppleSmartBattery)
      ├─ 用 g_snap 覆写 5 组核心指标（统一菜单栏与面板数值）
      ├─ lock: buffers.append ×7 + scratch 轮换回填
      ├─ MonitorExtra.update{ 峰值/累计/压缩/负载 }
      └─ DispatchQueue.main: sample / history / tick
            → 所有 @ObservedObject 视图重绘
```

### 4.2 菜单栏部件点击 → 独立窗

```
STATS 引擎（C）部件点击
  → statsBarOpenMonitorTrampoline(index)        [无捕获 C 函数指针]
  → DispatchQueue.main → StatsBarEngine.openMonitor(index:)
      ├─ module(forIndex:) 0..6 → MonitorModuleID
      ├─ popout.isVisible
      │    ├─ 同模块 → dismissPopout()
      │    └─ 异模块 → showModule()（cancelDismiss 防被抢关）
      ├─ wasJustDismissed() && 同模块 → 保持关闭
      └─ open(module:anchor:)
            ├─ sharedSelection.module = target（与主面板共用）
            ├─ appearToken += 1 / isDismissing = false / scrollState.resetToken += 1
            ├─ origin(for:anchor:) → screen(for:) 命中屏
            ├─ playAppearAnimation（CALayer，GPU 合成）
            ├─ makeKeyAndOrderFront + TransientWindowCenter.register
            └─ MonitorSampler.setPanelActive(true)        [跨模块：采样门控]
```

### 4.3 独立窗高度自适应

```
内容布局完成
  → GeometryReader.size.height → ContentHeightKey preference
  → PopoutRootView.onPreferenceChange → controller.resize(toContentHeight:)
      ├─ maxH = min(880, 屏高-40)；target = clamp(height, 200, maxH)
      ├─ frame.origin.y -= (target - height)     ← 顶边固定
      └─ animator().setFrame（dPage / caEaseOut）
```

### 4.4 内存优化

```
用户点「释放内存」（MemoryOptimizeSection）
  → Task { await optimizer.optimize() }        [MainActor]
      ├─ MemoryHelperClient.ensureReady()
      │     ├─ detached isReady() → send("version", 2s) → Unix socket + getpeereid(uid==0)
      │     └─ 未就绪 → install() → NSAppleScript(admin) 12 条命令 → 轮询 30×200ms
      ├─ detached: MemoryBreakdownReader.read() + ProcessMemoryInspector.topConsumers(40)
      ├─ detached: send("optimize-memory", 45s)   ← root helper 广播压力 + purge
      ├─ sleep 1s（等内核页统计结算）
      ├─ detached: 复测
      └─ MemoryOptimizationReport(before/after/steps/releases) → @Published → UI
```

### 4.5 网络页诊断

```
NetworkStatsPanel.diagnosticsSection.onAppear
  → 60s 节流判断 → NetworkDiagnostics.refresh()
      ├─ queue(frset.netdiag): reloadInterfaces()（getifaddrs + route 子进程）
      ├─ probeProxy()（CFNetwork 系统代理 + 8 端口 poll + ps 子进程）
      ├─ probePublicIP()（myip.ipip.net → 失败转 ip.3322.net + ipwho.is）
      ├─ probeLatencies()（8 站点 HEAD，group.wait 阻塞本队列）
      └─ probeDNS()（bash.ws 两步）
            → 主线程 @Published → 视图
```

---

## 5. 资源清单

### 定时器 / 周期性任务

| 位置 | 间隔 | 门控 |
|---|---|---|
| `MonitorSampler.scheduleNext` | `uiActive ? refreshInterval(0.5–10, 默认 2) : max(refreshInterval, 5)` | 总开关、三闸 |
| `StatsBarEngine` 空隙探针 | 0.5s（静息降到 2.0s） | `gapUnchangedStreak>=4 && !NSApp.isActive` |
| `PortInspector` 轮询 | 30s（tolerance 1.5） | 页面可见（`start/stop`）、非前台跳过、最小 3s |
| C 引擎 `FSStatsTickStart` | 0.5s（C 内部） | `isStarted` |
| C 层 conn（ICMP 1 包/秒） | 1s | `frset_conn_set_active(uiActive)` |
| C 层 nettop | ~5s（内部 popen） | `frset_net_top_set_active(uiActive)` |
| C 层 SMART 缓存 | 30s | 内部 |
| `MonitorPopoutWindow.scheduleWarmup` | 3.0s 一次性 | `warmupDone` |
| `StatsBarEngine.syncMainItem` 重试 | 0.2s × 10 | 主状态项存在即停 |
| `MemoryOptimizer` 等待 | 1.0s（优化后结算） | — |
| `MemoryHelperClient.install` 轮询 | 200ms × 30 | `isReady()` |

### 线程 / 队列

| 资源 | 用途 |
|---|---|
| `com.frset.monitor.sampler`（`.utility`） | `MonitorSampler` 全部采样 |
| `com.frset.monitor.smc`（`.utility`） | SMC 温度读取（单飞 + semaphore） |
| 主线程 | 所有 `@Published` 发布、UI、`Timer` 回调、`PortInspector.start/stop`、`NetworkDiagnostics` 的 `DispatchQueue.main` 写 |
| `com.frset.monitor.ports`（`.utility`） | `PortInspector.runLsof`（含子进程） |
| `frset.netdiag`（`.utility`） | `NetworkDiagnostics` 全流程（含两处同步等子进程、`group.wait`） |
| `Task.detached(.userInitiated)` | `MemoryHelperClient.isReady/optimize` |
| `Task.detached(.utility)` | `MemoryOptimizer` 前后采样 |
| URLSession 后台队列 | 公网 IP / 延迟 / DNS 回调 |

### 子进程

| 命令 | 位置 | 频率 | 备注 |
|---|---|---|---|
| `/bin/ps -Ao comm=` | `NetworkDiagnostics.detectProxyProcess` | 每次 refresh | `waitUntilExit` 同步 |
| `/sbin/route -n get default` | `NetworkDiagnostics.primaryInterfaceName` | 每次 refresh | 同步 |
| `/usr/sbin/lsof -nP -FpcnPT -iTCP -sTCP:LISTEN -iUDP` | `PortInspector.runLsof` | 30s | 3s 看门狗 |
| `nettop`（C 层内部 popen） | `frset_net_top` | ~5s（受 active 开关） | 注释记录"单次 ~1s" |
| `do shell script … with administrator privileges`（osascript 路径） | `AdministratorShell.run` | 仅安装/卸载 | 12 条命令串联 |
| root LaunchDaemon（`com.sxyq.frsetnext.memoryhelper`） | 常驻 | — | socket `/var/run/com.sxyq.frsetnext.memory.sock` |

### 文件路径

| 路径 | 用途 |
|---|---|
| `/Library/PrivilegedHelperTools/com.sxyq.frsetnext.memoryhelper` | helper 二进制 |
| `/Library/LaunchDaemons/com.sxyq.frsetnext.memoryhelper.plist` | LaunchDaemon |
| `/Library/PrivilegedHelperTools/com.sxyq.frsetnext.memoryhelper.client.json` | 客户端 uid 白名单 |
| `/var/run/com.sxyq.frsetnext.memory.sock` | Unix socket |
| `/var/log/com.sxyq.frsetnext.memoryhelper.log` | helper 日志（错误提示里引用） |
| `Bundle/Contents/Library/PrivilegedHelperTools/…`、`Bundle/Resources/…plist` | 安装源 |
| `~/Library/Application Support/FrsetStats/widgets.plist` | STATS 部件配置（C 引擎侧） |

### UserDefaults / Preferences 键

| 键 | 说明 |
|---|---|
| `monitor.enabled` | 总开关（默认 true） |
| `monitor.refreshInterval` | legacy 键，`0.5...10`，默认 2.0 |
| `monitor.combinedMode` | legacy 键，默认 false |
| `monitor.showTemperatures` | 默认 true |
| `monitor.<module>.enabled` | 8 个模块开关（默认见 `enabledByDefault`） |
| `Preferences.Keys.monitorEnabledModules` / `monitorCombinedMode` / `monitorRefreshInterval` | legacy 别名（`MonitorPreferences` 私有引用） |
| `FSBarCfg` 侧 `updateInterval`（按模块） | 设置页刷新滑杆联动写入 |

### 通知 / 事件名

| 名称 | 方向 |
|---|---|
| `MonitorPreferencesDidChange`（`MonitorPreferences.didChangeNotification`） | 发（setter）；收（`MonitorSampler`、`MonitorSettingsPane`） |
| `FrsetScreenRecDidSave` | 收（`StatsBarEngine` → Toast） |
| `MonitorStatusItems.hiddenMarker = "⟨monitor:hidden⟩"` | 状态栏约定（非通知） |

### C 桥函数（本目录直接调用）

`g_snap`（全局快照）、`frset_conn_set_active`、`frset_net_top_set_active`、`frset_gpu_usage`、`frset_gpu_model`、`frset_cpu_clusters`、`frset_cpu_sample`、`frset_cpu_cluster_usage`、`frset_mem_sample`、`frset_mem_pressure`、`frset_battery_sample`、`frset_battery_remaining_sec`、`frset_conn_sample`、`FSStatsConnHistoryAt`、`frset_disk_capacity`、`frset_disk_model`、`frset_disk_interconnect`、`FSStatsRootFileSystem`、`frset_disk_smart`、`frset_net_ip`、`frset_smc_scan`、`frset_sensor_name/type/group/average`、`FSStatsSensorKey`、`frset_fan_count`、`frset_smc_read_key`、`frset_smc_read_string`、`frset_proc_top`、`frset_net_top`、`FSStatsProcPath`、`FSStatsProcName`、`FSStatsTickStart/Stop`、`FSStatsSetOpenMonitorHandler`、`FSBarMergedItem`、`FSBarSetScreenGap`、`FSBarSetMainItem`、`FSBarLastAnchorScreenRect`、`FSBarAllModules`、`FSBarCfgSet`、`FSBarReloadFromStore`、`FSScreenRecOpenSettings/BeginFromSettings/Stop/IsRunning`。

---

## 6. 不变量与陷阱

1. **三个可见性闸必须独立**（`panelActive` / `homePanelActive` / `settingsActive`）。合并 = "面板 5s / 独立窗 1.5s 两套时间"回归（v57 注释逐字记录）。
2. **`scheduleNext` 的 WorkItem 内部必须重算门控**（v73 修复）：直接用 `refreshInterval` 重排会丢掉隐藏降频，"常驻开销大"回归。
3. **`stop()` 必须关 C 层后台线程**（`frset_conn_set_active(0)`/`frset_net_top_set_active(0)`），否则 ICMP/nettop 无人消费仍常驻。
4. **`g_snap` 有效时必须用其覆写核心指标**（v76）：否则面板与菜单栏是两条时间线——用户反复反馈的"两套时间"。
5. **`needFull:false` 仍要读内存**：压力/交换/压缩不在 g_snap 里。
6. **SMC 读取必须单飞 + 带超时**：`sensorReadInFlight` 为真时返回缓存，`semaphore.wait(150ms)` 超时也要返回值。
7. **`StatsRing` 路径必须 `inset(by: lineWidth/2)`**（v84）：否则描边出框被裁，表现为"环左上缺边"。
8. **`StatsRing` 的 GeometryReader 闭包内不得注入基于 `geo.size` 的 environment**（v85）：会 render→layout 死循环，主线程阻塞 60s+ 只能强杀。
9. **`modulePicker` 不能包在 `ScrollView` 里，选中态不能用 `matchedGeometryEffect` 放 `.background{}`**（v82）：否则非选中模块按钮点不动。
10. **主面板性能页与独立窗除 `topInset` 外必须一致**（`MonitorPerformanceContent` 注释）：任一侧单独改版式 = 两套 UI。
11. **独立窗 `isDismissing` + `appearToken` 双机制缺一不可**：少了 `isDismissing` 会多路触发互相打断动画；少了 `appearToken` 会在重开后被在途 completion 关掉。
12. **`dismissPopout` 的 200ms 硬兜底不能删**：CATransaction completion 在窗口被遮挡/动画被跳过时不执行 → 窗口永远留屏（"点外不关"）。
13. **`MonitorPopoutPanel.canBecomeKey = true` 必须保留**：borderless 默认 false，点外收起依赖 key 状态。
14. **`PopoutRootView` 的 `resetToken` 滚动复位不能删**：窗口长复用，不复位则重开时顶部模块切换条在视口外（"没有切换按钮"）。
15. **`windowDidResignKey` 里 `NSApp.isActive` 时要直接 return**：本 app 内换 key 时收起，会被状态项 `mouseUp` 重新拉起 → "点图标不关"。
16. **`StatsBarEngine` 的 `isStarted` 幂等 + observer 注册顺序**（v126）：在守卫之前注册会导致重复 start 叠加 N 个录屏 Toast。
17. **`readProcList` 的 `ChildRec.idx` 依赖 `procBufferLock` 与"仅采样队列调用"**：任一前提破坏 → 读到别的进程数据。
18. **传感器 `category` 必须用扫描层的 `raw.category`**（不是官方名表的 `type`）：错位会导致"BDAT 显示 5388°"。
19. **`PortInspector` 的 lsof 看门狗不能删**：lsof 在某些 fd 状态下会卡住，无看门狗会永久占住 `com.frset.monitor.ports` 队列。
20. **`MemoryHelperClient.send` 的 `getpeereid(uid==0)` 校验不能删**：否则同机非 root 用户可伪造 socket 冒充 helper。
21. **`StatsProcTable.expandedIDs` 必须用 `groupKey`（bundle 路径）而非 pid**：pid 会随排序换人，展开态每帧跳动。
22. **`StatsAppIcon` 只缓存成功结果**：缓存 nil 会"一次落空、永不刷新"（v86 根因）。

---

## 7. 重复实现 / 死代码 / 风险

### 重复实现

| 项 | 位置 | 说明 |
|---|---|---|
| 温度主选 | `CPUStatsPanel.primaryTemperature`（读 SMC 全量 + fallback）vs `MonitorDetailView.primaryTemperature`（只读 `sample.temperatures`） | 同一语义两套口径：统一窗口后两页温度可能不同 |
| 启动时长 | `CPUStatsPanel.uptimeText` vs `MonitorDetailView.uptimeText` | 完全相同的实现复制两份 |
| 负载小格 | `CPUStatsPanel.loadCell`（14pt）vs `MonitorDetailView.loadCell`（12pt） | 字号不同 |
| 图例小格 | `DiskStatsPanel.legendValue` vs `NetworkStatsPanel.legendValue` | 逐字相同 |
| 连通性格子 | `StatsConnGrid`（LazyVGrid）vs `MonitorDetailView.networkPanel` 内联 `Grid` | 两套布局，颜色函数也各一份 |
| 内存构成 | `MemoryStatsPanel` 的 `GeometryReader` 手拼 vs `MonitorStackedBar` | 前者是四段手算宽度 |
| 传感器分节 | `SensorsStatsPanel`（`SensorGroup`）vs `MonitorDetailView.sensorCategorySection` | 两套渲染（限行 12/6 vs 6/3 也不一致） |
| 电池面板 | `BatteryStatsPanel` vs `MonitorDetailView.batteryPanel` | 字段集合不同（前者有剩余时间/健康度条，后者有适配器段） |
| 进程表 | `StatsProcTable`（统一）vs `MonitorDetailView.StatsProcRows`/`StatsDualValue`（**无调用方**） | 后者是 v84 前的遗留 |
| 环形图 | `StatsRing` vs `MonitorRing` | 两个几乎相同的组件（StatsModulePanels 用前者，MonitorDetailView/Charts 用后者） |
| 双排状态项 | `MonitorStatusItems.*TwoLine` | `registerAll()` 被注释掉后**整文件仅剩文案函数无人调用** |

### 死代码 / 未接线

| 符号 | 状态 |
|---|---|
| `MonitorStatusItems.registerAll()` 及全部 `*Title/*TwoLine` | `MonitorModule.start()` 里被注释（v42 决策），无其他调用方 |
| `MonitorDetailView.StatsProcRows` / `StatsDualValue` | 私有类型，无引用 |
| `MonitorDetailView.init(module:pageMode:)` | 与 selection 版并存，`fixedWidth` 恒 292；当前主要走 selection 版 |
| `MonitorSparkline` 在 `StatsHistoryChart` 之外的使用 | 少量 |
| `MonitorHistoryBuffer.values()` | 仅包装 `values(into:)`，实际生产路径用后者 |
| `StatsDataProvider.sensorDisplayName` | 注释说"供设置页传感器选择器使用"，当前设置页无传感器选择器 |
| `MonitorOptimizationStep` 的 `.pressure` 在 C helper 未返回时 | 仅字符串解析，无本地实现 |
| `StatsBarEngine` 的 `FRSET_STATSBAR_PROBE` 六种探针 | 生产代码里的排障分支（`poschk`/`recchk`/`recorder`/`cycle` 等），长期保留 |
| `MonitorSettingsPane.state.version`（`bump()`） | 自增但只有 `@ObservedObject` 存在（`body` 未读 `version`）——靠对象失效触发重绘，属隐式契约 |
| `MonitorFormat.diskRate` / `percentFine` / `MonitorStatusItems.trendSymbol` | 依赖已死路径或极少使用 |

### 风险

| # | 风险 | 位置 | 影响 |
|---|---|---|---|
| M1 | `MonitorExtra` 是全局可变单例，`MonitorSample` 扩展每读一个属性取一次锁（6 次/帧/视图） | MonitorReader 61–74 | 视图多时锁竞争；且**峰值/累计属于"进程级全局"**，多窗口共享同一份（设计如此，但语义上不是"每个样本的"） |
| M2 | `netTotalIn/Out` 用 `netBps × refreshInterval` 累加，隐藏期实际间隔 5s | MonitorSampler 292–304 | 面板隐藏时累计流量偏小（最多偏 ~2.5×） |
| M3 | `perCore` 读取硬编码上限 32 核 | MonitorSampler 230 | 未来 >32 核机器截断（当前无此硬件） |
| M4 | `StatsDataProvider.refresh` 读-改-写不带锁（局部 `snap`），末尾整体写回 | 257–259 / 533–535 | 若将来出现第二个写者会互相覆盖；当前唯一写者是采样队列 |
| M5 | `sensorMeta` 无锁但只在采样队列访问；若有人从 UI 线调用 `refresh` 会崩 | 213 | 结构性约束靠注释维持 |
| M6 | `NetworkDiagnostics.detectProxyProcess` / `primaryInterfaceName` 同步 `waitUntilExit` | 199–221 / 293–308 | 阻塞 `frset.netdiag` 队列；若 `ps` 卡住（大量进程）刷新会整体变慢 |
| M7 | `NetworkDiagnostics.probeLatencies` 用 `group.wait()` 无超时 | 412 | 单站点 DNS 卡死 → 整轮刷新卡住（每请求 5s 超时兜底，最坏 5s） |
| M8 | `PortInspector.parse` 的 `flush()` 依赖字段顺序（p/c/f/P/n/T） | 180–250 | lsof 字段顺序变化（不同版本）会静默丢数据 |
| M9 | `PortInspector.start()` 用 `Timer` 强引用 self？——实为 `[weak self]`，但 `timer` 由 self 持有，`stop` 必须被调到 | 86–105 | 视图 `onDisappear` 未触发（如被系统回收）时轮询常驻 |
| M10 | `MonitorPopoutWindowController.resize` 在内容高度抖动时每帧 `animator().setFrame` | 267–281 | 频繁 resize 会造成窗口动画打架（有 `abs(diff) > 1` 阈值兜底） |
| M11 | `MemoryHelperClient.install` 把 `getuid()` 写进 `client.json` 且从不更新 | 58–68 | 换用户/共享机器后需重装；且**只校验 uid**，同一用户下任何进程都可连 root helper |
| M12 | `AdministratorShell.run` 把整条命令拼进 AppleScript 字符串 | 205–215 | 路径经 `quote()` 转义，但 `appleScriptEscape` 只转义 `\` 与 `"`——若路径含控制字符仍有注入面（实际路径来自 Bundle，风险低） |
| M13 | `MemoryOptimizer.optimize` 在 `@MainActor` 上串联 3 次 await + 1s sleep | 81–122 | 期间 UI 只显示"正在释放"，无进度；45s 超时期间无法取消 |
| M14 | `StatsProcQuitter.quit` 直接 `SIGTERM` 整组 pid | 520–530 | 用户可能杀掉正在写文件的 App（行内按钮有确认框，右键菜单没有——注释认为"右键是显式选择"） |
| M15 | `StatsAppIcon.cachedIcon` 在路径不存在时回落到"按名找运行 app" | 437–455 | 同名不同 App 仍可能串图标（v86 声称已根治，实际兜底分支保留了旧隐患） |
| M16 | `MonitorSettingsPane.applyIntervalToBarWidgets` 把浮点秒四舍五入成**整秒**（1–60） | 164–170 | 用户设 0.5s 时菜单栏仍是 1s——"设置没生效"的残留语义差 |
| M17 | `MonitorPopoutWindowController` 的 `setPanelActive(true)` 只在 `open` 里置位 | 228 / 361 | 窗口被系统直接关闭（非本类路径）时复位不执行 → 采样器停在"可见"档 |
| M18 | `StatsBarEngine.startScreenGapProbe` 每 0.5s 跨进程读 `NSStatusItem.button.window.frame` | 167–213 | 主线程高频桥接；降频只在"app 非活跃 + 读数不变"时生效（面板开着时仍 0.5s） |
| M19 | `StatsModulePanels` 的 `CPUStatsPanel.body` 里 `StatsDataProvider.shared.current` 每次 body 求值取一次锁快照 | 581 | 每个 tick 多表 × 每次取锁；与 M1 叠加 |
| M20 | `MemoryStatsPanel` 的 `used - compressed - wired` 可能为负（已 clamp 0），但构成条用 `geo.size.width * appBytes / total` 会出现"四段总和 > 宽度" | 758–765 | 视觉溢出（无裁剪保护） |
