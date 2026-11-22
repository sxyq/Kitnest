# 全量 UI / 交互一致性与 DDD 分层审计报告（v260）

> 审计时点：2026-11-07 17:0x　基线 commit：`faef064`（v259）　范围：`apps/FrsetNext/Sources` **全量 274 个 Swift 文件**
> 方法：CodeGraph 索引交叉核对 + `func_table` 同源扫描 + 静态度量脚本 `tools/ui_arch_audit.py`（本报告所有数字可一键复跑）
> 配套产物：
> - `数据表/UI与架构审计清单.csv` —— **51 条逐项发现**（问题 / 证据 / 实测 / 动作 / 验收 / 状态）
> - `数据表/源文件分层与组件画像.csv` —— **274 行逐文件画像**（层归属、声明数、令牌采用、单例、钩子、问题、优先级）
> - `tools/ui_arch_audit.py` —— 上面两张表的度量生成器
>
> **时点声明**：审计期间工作区有未提交的 v260 改动（`FrsetNextApp.swift` / `Preferences.swift` / `MemoryOptimizeCard.swift` / `MemoryOptimizer.swift` / 新增 `ProcessFreezer.swift`）。本报告与两张 CSV **按当前源码实扫**，不读已落后的函数清单 CSV；改动未提交，也没有代用户重生成台账或索引。

---

## 0. 一页结论

**这个项目的工程能力明显强于它的产品抽象能力。**

- 模块之间其实**不怎么耦合**（跨 feature 直接引用很少，主要依赖指向 `Core`），注册表 / 服务定位器的解耦方向是对的，C 引擎 0.5s tick 与 `g_snap` 单时间线设计也经得起推敲。**不要重写架构。**
- 真正的问题是**「层」只存在于目录名里，不存在于代码里**：一个 `Features/XXX` 目录同时装实体、持久化、业务规则和视图；`Core/UI/Support.swift` 一个文件塞了 10 个顶层声明；视图直接执行 SQL、直接抓 500 次单例、直接读 47 处调试开关。
- UI 侧的问题不是「不好看」，是**「同一个概念有 N 个实现」**：29 种字号、6 种按钮样式、13 种窗口 styleMask、2 套 NSTableView、19 个文件各写各的胶囊、13 个设置页里 6 个不用现成组件、530 个内联子视图。
- **最关键的一条实证**：`Theme.Radius` 被用了 **183 次**，`Theme.TextSize` 被用了 **0 次**。差别不在设计得好不好，而在于前者有 `ui_lint.py` 的 R1 规则强制、后者只写在文档里。**「提供组件」无效，「强制规则」有效。** 这决定了后面所有建议的做法。

一句话路线：**不重写、不加框架；先立组件目录和 5 条 lint，再抽 3 个架构口子（设计系统 / 应用服务 / 仓储协议），最后按用例渐进迁移。**

---

## 1. 全 App 交互一致性审计

上一轮只看中转站，本轮把同类问题在全 app 复核了一遍。中转的问题不是孤例，是**同一套习惯的局部表现**。

### 1.1 列表行：同一个控件，四套语义

| 表面 | 单击 | 双击 | 右键 | 技术 |
|---|---|---|---|---|
| 剪贴板主列表 | **预览**（不复制） | **复制** | 10 项菜单 + 按下即触发 | `NSTableView`（1020 行 / 11 类型） |
| 归档文件表 | 选中 | 进入目录 | 菜单 | `NSTableView`（303 行，另一套实现） |
| 中转站暂存 | **什么都不发生**（只有 14×14pt 勾选圈可点） | 打开 | 10 项菜单 | SwiftUI `ForEach` |
| 工具箱 / 手册 | 直接执行 | — | — | SwiftUI `ForEach` |

证据：`ClipboardTableHostView.swift:158-234`、`ArchiveEntryTable.swift:89/154`、`TransferDockView.swift:1308-1319`、`ToolboxSectionView.swift`。

> 用户在这四张表之间切换时，鼠标的同一套肌肉记忆会得到四种结果。这是**交互契约缺失**，不是某个页面的 bug。需要先写一张《列表交互契约》，再让组件把契约编码进去——只改某一个页面会制造第五种语义。

### 1.2 主操作的可点面积与空态

- 中转站卡片 hover 会放大、可拖出、可双击、有 10 项右键菜单，**唯独单击不发生任何事**；决定「发哪些」的勾选圈只有 14×14pt（`TransferDockView.swift:1262-1265`），而 macOS 惯例最小命中区是 28×28。
- 未选文件时三枚出口 chip 照常渲染（`:221-231`），点下去只弹 Toast（`:327`）；上方提示「先在下方暂存里勾选文件」，下方列表是空的（`:739`）。**指令指向一个空容器，三个主按钮全是死路**——这是新用户看到的第一屏。
- 全仓 **12 处空态**各写各的文案（`CaptureHistoryView.swift:153`、`StorageManagerWindow.swift:846`、`ArchiveProgressPanel.swift:33`、`CodePreviewView.swift:343`…），没有一处给主按钮。

### 1.3 同一动作、同一状态、不同长相

| 现象 | 证据 |
|---|---|
| 「扫码直传」/「通用互传」/「通用互传这个」是同一个 `showPickQR()` | `TransferDockView.swift:363-369 / 883 / 1351` |
| 接收页三行右侧：绿色「已监听」状态 pill 与动作按钮同尺寸同列 | `:373-396` |
| 云端页顶部「刷新登录」与空态「登录」两个入口 | 同上 |
| 破坏性确认混用 `NSAlert()` 18 处 / `.alert()` 4 处 / `.confirmationDialog()` 4 处 | `ArchiveBrowserWindow.swift` 单文件就 7 处 |

错误反馈同理：`Toast.show` 225 处，其中 **71 条**是失败/错误类，文案无分级、无恢复动作；同一类失败在别处又变成 `NSAlert`。用户看到「失败」但不知道下一步。

### 1.4 窗口与键盘

- **41 个文件自建窗口**，13 种 `styleMask` 组合（`NSWindow(` 13 / `NSPanel(` 5）；`keyDown` 52 处、`cancelOperation` 仅 4 处、`addLocalMonitorForEvents` 16 处——ESC 行为、焦点环、首响应没有统一约定。
- 好消息：`applyOfficialChrome()` 被用了 **30 次**，`Toast.show` **225 次**，`.glassCard()` **40 次**。v209 定的「唯一入口」确实被遵守了。**这说明只要给出唯一入口 + 强制检查，这个团队是能做到的。**
- 坏消息：`ui_lint.py` 当前已报 **29 条新增 R1 违规**，`check.sh:63-77` 因此 **FAIL**。防复发闸门已经失效，而新代码还在继续绕过它。

### 1.5 长任务与到达感

解压、上传、扫码互传三类长任务的进度呈现不统一：有的只有 spinner + 一行字，有的没有百分比，有的完成后只弹 Toast。手机上传 / 空投到达也只在 Toast 里闪一下，中转页 badge 与菜单栏角标都没有。**「东西到了没有」是文件传输类产品的核心确定性，不该只靠 3 秒消失的提示。**

### 1.6 一个不该出现在产品里的东西

全仓 **39 个 `probe.*` 键 / 47 处调用**，散在 27 个文件，其中多处位于 View 的 body 与表格事件里（`TransferDockView.swift:547`、`ArchiveEntryTable.swift:139`、`SearchSectionView.swift:532-566`）。这是把验证脚手架直接写进了产品路径。Release 构建里它们仍可被触发，而且会改变真实交互。

---

## 2. UI 组件与设计系统

### 2.1 设计令牌：一张表说明全部问题

| 令牌 | 定义位置 | 实际采用 | 是否有 lint 强制 |
|---|---|---:|---|
| `Theme.Radius` | `Support.swift:144` | **183** | ✅ R1（零容忍） |
| `Theme.Motion` | `Support.swift:311` | **46** | 部分 |
| `Theme.Stroke` | `Support.swift:162` | **10** | ❌ |
| `Theme.Space` | `Support.swift:281` | **5** | ❌ |
| `Theme.TextSize` | `Support.swift:128` | **0** | ❌ |
| `.system(size: N)` 字面量 | 全仓 | **1073 次 / 29 种取值** | ❌ |
| `cornerRadius: N` 字面量 | 全仓 | **53 次** | R1 存量已漂 |

29 种字号里包含 `7 / 7.5 / 8 / 8.5 / 9 / 9.5 / 10 / 10.5 / 11 / 11.5 / 12 / 12.5 / 13…`。**0.5pt 的差异肉眼不可辨，真正起区分作用的只剩字重**；更实际的影响是「个性化 → 字体缩放」对这 1073 处硬编码字号无效。

> `docs/40-审计与核对/UI-一致性审计与规范.md`（v179）其实已经把「字号六档、间距七档、圆角五档」写清楚了，还做了 R1/R2/R3 三条 lint。**结果：被 lint 守住的圆角归零了，没被守住的字号一点没动。** 这份报告不重复写规范，只补「怎么让它真的发生」。

### 2.2 组件库存量：共享层很薄，自造层很厚

`Core/UI/` 只有 9 个文件 1736 行，且**没有 `Components/` 目录、没有 Preview 样例、没有组件注册表**。

| 组件 | 采用次数 | 判定 |
|---|---:|---|
| `Toast.show` | 225 | ✅ 事实标准 |
| `applyOfficialChrome` | 30 | ✅ 事实标准 |
| `.glassCard()` | 40 | ✅ 主路径 |
| `SettingsSection / Row / GroupBox` | 31 / 26 / 33 | ⚠️ 只有 7/13 个设置页用 |
| `RoundCloseButton` | **0** | ❌ 死组件（34 行） |
| `FlowLayout` | 1 | ❌ 近乎未用 |
| `PointingHandCursor` | 6 | ⚠️ 采用不足 |

反面：**530 个 `some View` 内联子视图**分散在 78 个 SwiftUI 文件（`PersonalizationSettingsPane` 30 个、`TransferDockView` 26 个、`FloatingClipboardDesk` 26 个…），共享组件命中只有 165 次。组件的实际单位是「文件内的 private 计算属性」，不是可复用类型。

具体表现：

- **设置页分裂**：13 个页签里 `MonitorWidgets / Statistics / AI / Pin / TransferDock / Clipboard / General` 复用 `SettingsSection+GroupBox`；`PersonalizationSettingsPane`（827 行 / 30 个内联视图）、`SearchSettingsPane`（506 行）、`MonitorSettingsPane`、`CaptureSettingsPane`、`ShortcutSettingsPane`、`ToolSettingsPane` **一次都没用**，靠裸 `VStack + Divider().opacity(0.5)` 分组。同一个设置窗里存在两套分组外观。
- **卡片**：`RoundedRectangle(cornerRadius:` **229 次 / 51 文件**、`strokeBorder(` **65 次**（37 个文件存在手写卡片组合），对比 `.glassCard()` 40 次。`CaptureActionToolbarView` 一个文件写 14 次。
- **胶囊**：19 个文件各写各的。`PortOccupancySection.swift:80` 是 `padding 7/2.5 + 11 semibold monospaced`；`ArchiveFlowRecommender.swift:380` 是 `padding 9 + 24 高 + 11 medium`。同类标签三套参数。
- **按钮**：226 处 `Button` 声明、6 种 `.buttonStyle`（plain 172 / borderless 28 / link 15 / borderedProminent 12 / bordered 2 / 自定义 2），**零个自定义 `ButtonStyle`**。主次视觉重量靠碰运气，也没有最小命中区约束。
- **搜索框**：57 处 `TextField`，0 个统一组件。

### 2.3 建议的组件体系（不是推倒重来，是把已有事实标准补齐）

```
Core/UI/
├── Theme.swift              ← 从 Support.swift 拆出，唯一设计令牌入口
├── Components/
│   ├── AppButton.swift      primary / secondary / tertiary / destructive；最小 28pt 命中区
│   ├── AppCard.swift        统一填充 + 0.5pt 发丝线 + Theme.Radius.card
│   ├── AppChip.swift        label/icon/selected/action；唯一 Capsule 出口
│   ├── AppSearchField.swift 清除 / 聚焦环 / 占位 / 回车统一
│   ├── ListRow.swift        ★ 承载《列表交互契约》：单击/双击/右键/选中/键盘
│   ├── EmptyState.swift     icon + title + hint + 主按钮（空态必须有出口）
│   ├── StatusBadge.swift    状态与动作分离，杜绝「绿色 pill 看着像按钮」
│   ├── ProgressRow.swift    阶段 + 百分比 + 取消
│   └── ConfirmDialog.swift  危险 / 一般 / 信息三档，统一按钮文案
├── Modifiers/Hoverable.swift
└── COMPONENTS.md            每个组件的用途 / 参数 / Preview / 采用率
```

复合层 3 个：`SettingsSection`（把 6 个脱队页签收编）、`SectionHeader`、`SelectionBar`。

**治理规则（关键，比组件本身重要）**：在 `ui_lint.py` 现有 R1–R3 之后加 R4–R8，并挂进 `reconcile.py` 统一入口：

| 规则 | 禁什么 | 迁移方式 |
|---|---|---|
| R4 | 裸 `.system(size: N)` | 基线记账，只允许减少；新代码零容忍 |
| R5 / R6 | 裸 padding 魔数 / 裸 `RoundedRectangle.fill + strokeBorder` 组合 | 同上 |
| R7 | 新文件自建 `.buttonStyle(.xxx)` | 走 `AppButton` |
| R8 | 组件采用率断言 | 每个共享组件被 ≥3 个模块引用，否则报警（防止再造一个 `RoundCloseButton`） |

再补一条**先决动作**：把当前 29 条 R1 新增违规归零，否则 `check.sh` 一直是红的，新规则没有可信度。

---

## 3. 代码层次：按 DDD 看

### 3.1 现状形态

当前是**按界面切分的 feature-slice（ vertical slice 的松散版）**，不是按领域切分的限界上下文：

```
App/                    装配（AppDelegate / AppBootstrap，2 文件 1042 行）
Core/                   杂物间：日志、DI、协议、主题、路径、动效、窗口外观（22 文件）
Models/                 共享模型（2 文件 509 行）—— 只有 ClipboardItem / Tag / SearchEngine
Storage/               全局 SQLite 连接 + clipboard schema + 统计（1 文件 650 行）
Features/<20 个模块>/    实体 + 持久化 + 业务规则 + 视图 + 窗口控制器，混在一个目录
```

依赖方向实测（按类型引用计数）：**绝大多数是 `Features → Core`**，跨 feature 直接耦合很低（`Panel→Clipboard` 41 次是最多的一对）。所以这里要解决的不是「模块互相缠」，而是**「每个模块内部四层压扁」+「Core 是个杂物间」**。

### 3.2 六个具体的层次违规

| # | 问题 | 证据 |
|---|---|---|
| D-02 | `Core/UI/Support.swift` 423 行里 10 个顶层声明：`Log` / `AppModule` / `ModuleRegistry` / `LLMServiceProtocol` / `OCRServiceProtocol` / `OCRTextObservation` / `ServiceLocator` / `Theme` / `Date+String+Data` 扩展 / `AppDirectories` | `Support.swift:8/35/40/60/67/74/82/103/360/375/393/407` |
| D-03 | **领域目录里直接写 SwiftUI View**：`Archive/Core/ArchiveFlowRecommender.swift:324` 定义 `ArchiveFlowBar: View`；`TransferDock/Transfer/`、`Cast/` 下 4 个文件同理 | 同上 |
| D-04 | **View 直接执行 SQL**：`StatisticsRootView.swift:289` 与 `StatisticsSettingsPane.swift:359` 都调 `DatabaseManager.shared.clipboard.scalarInt("SELECT COUNT(*) FROM clipboard_items")`——而 `ClipboardRepository.count()` 已经存在 | 同上 |
| D-05 | 全仓 **500 次 `.shared` 单例直取**，视图层约 150 次（`ClipboardManager` 19、`StatsDataProvider` 19、`StatisticsManager` 16…）。视图同时承担取状态、编排放业务、渲染 | `ui_arch_audit.py` |
| D-06 | 实体四分五裂：`ClipboardItem`/`Tag` 在 `Models/`，`StatsSnapshot` 在 `Monitor/Sampling/`，`ArchiveEntry` 在 `Archive/Core/`；943 个类型里 19 组跨模块同名 | 同上 |
| D-16 | 47 处 `probe.*` 把验证设施写进产品层 | 见 1.6 |

还有两条结构性的：`ClipboardFilterKind` 在 `ClipboardManager.swift:21` 与 `SearchSectionView.swift:1070` **各定义一份**（同一领域枚举两份实现，Toolbox 那份会遮蔽全局那份）；`clipboard_items` 24 列 schema 在 `Storage/Database.swift:176-240`，查询却在 `Clipboard/Store/`——同一聚合的 schema 与 query 分属两层两目录。

**另一个缺口**：全仓只有 3 个 `ViewModel`，且都在 AI 模块。**没有应用层 / 用例层**——业务用例要么写在 View 的 action 里，要么埋在 `Manager` 的方法里，无法命名、无法复用、无法单测。

### 3.3 DDD 映射（务实版，不要求照搬教科书）

| 限界上下文 | 现有目录 | 核心聚合 / 用例 | 首要动作 |
|---|---|---|---|
| 剪贴板 | `Features/Clipboard` + `Models` | `ClipboardItem` / 采集、检索、保留策略 | 已有 `ClipboardRepository`，补 UseCase 与 Ports |
| 文件中转 | `Features/TransferDock` | `TransferSession` / 发送、接收、通道选择 | 抽 `TransferChannel` 策略；UI 不再碰协议细节 |
| 归档压缩 | `Features/Archive` | `ArchiveTask` / 解压冲突决策 | 把 `ArchiveFlowBar` 移出 `Core/` |
| 截图与标注 | `Features/Capture` | `Capture` / 截图、标注、钉图 | 1881 行的 `AnnotationEditorWindow` 拆用例 |
| 系统监测 | `Features/Monitor` + `FrsetStatsBar/` | `StatsSnapshot` / 采样（唯一时间线 C 引擎） | 保留 C 单源；Swift 侧停采被覆盖字段 |
| AI | `Features/AI` | `LLMRequest` / 补全、翻译、会话 | **模板模块**：已有协议 + Provider + CredentialStore + ViewModel，照它抄 |
| 设置 / 个性化 | `Features/Settings` + `Core/Runtime` | `Preferences` / 读写、导入导出 | 键已中心化（`Preferences.Keys`），补强类型聚合 |
| 共享内核 | `Core` + `Storage` | 日志、窗口、设计系统、事件 | **拆 Support.swift**；窗口与连接下沉 Infrastructure |

### 3.4 目标分层（只加边界，不搬 9 万行）

```
Interface/        SwiftUI View / NSWindow 壳 / 组件
   ↓ 只依赖 ViewState + 用例协议；零 .shared、零 SQL、零 UserDefaults
Application/      UseCase（发送文件 / 解压冲突 / 开始截图 / 保存剪贴板 / 切换监测页）
   ↓ 编排，不持有 UI 类型
Domain/           Entity / ValueObject / 领域服务 / Ports（Repository 协议）
   ↑ 被实现，不依赖任何层
Infrastructure/   SQLite / UserDefaults / C 引擎桥 / 网络 / WindowFactory
```

依赖规则写成一条可检查的：**`Domain/` 与 `Application/` 不得 `import SwiftUI` / `import AppKit`**。这一条 lint 就能挡住 D-03 复发。

### 3.5 迁移路径（按投入产出，不做全量重写）

1. **第一步只拆 `Support.swift`**（半天量级，零行为风险）：`Theme` → `Core/UI/Theme.swift`，协议 → `Core/Contracts/`，`Log`/`AppDirectories` → `Core/Runtime/`。原文件留转发声明兼容。
2. **第二步抽 3 个口子**：`Core/UI/Components/`（第 2.3 节）、`Application/UseCases/` 先做 5 个高频用例、`Domain/*/Ports/` 定义仓储协议。`AI` 模块是现成模板。
3. **第三步逐个掐断层污染**：两处 View 直连 SQL 改走仓储；`Archive/Core` 里的 View 移到 `UI/`；`ClipboardFilterKind` 收敛成一份。
4. **第四步再谈依赖注入**：`ServiceLocator` 保留作兼容门面，新增用例一律走 `CompositionRoot` 协议注入；不要一次性替换 500 处 `.shared`。

> **明确不建议**：把 20 个 `Features/` 目录按 DDD 四层整体重排。跨 feature 耦合本来就低，大搬家的收益远小于冲突成本；上表的边界可以用「新代码守规则 + 老代码按用例抽」渐进达到。

---

## 4. 优先级路线图

| 阶段 | 动作 | 验收标准 | 对应清单 |
|---|---|---|---|
| **P0 · 止血** | 归零 29 条 R1 违规；加 R4 字号规则；拆 `Support.swift`；两处 View 直连 SQL 改走仓储；中转三处 P0（整卡可点 / 空态给按钮 / 一名一动作）；建 `Core/UI/Components` + `COMPONENTS.md` | `check.sh` UI 一致性 PASS；`Theme.TextSize` 命中 > 1000（按批次）；视图层 `DatabaseManager` 命中 = 0；中转首屏零死按钮 | I-01~I-04、C-01/C-03/C-04/C-11/C-12、D-02/D-04 |
| **P1 · 统一** | 8 原子组件落地并迁移 6 个脱队设置页；`ListRow` 承载列表契约；`ConfirmDialog`/`EmptyState`/`ProgressRow`；5 个 UseCase；`ClipboardFilterKind` 收敛；probe 迁 DEBUG；补埋点 | 13 个设置页复用率 100%；四张列表点击语义一致；Release 零 probe 分支；漏斗可按通道拆 | I-05~I-08/I-11/I-12/I-15、C-02/C-05~C-10/C-14、D-03/D-05~D-11/D-16、G-06 |
| **P2 · 收敛** | 窗口工厂 / Hoverable / 键盘契约 / AppSearchField / 表格宿主统一 / 引导收尾 / 事件总线 / 文档时点 | `applyOfficialChrome` 覆盖 100%；裸 `onHover` 归零；Domain 目录零 `import SwiftUI` | I-09/I-10/I-13/I-14、C-09、C-10、D-06/D-09/D-10/D-15、G-05 |

**如果只做一件事**：把「组件 + 规则」绑在一起做——先归零 R1，再上 R4。因为 183 vs 0 那组数字已经证明，只写文档不会改变任何东西。

---

## 5. 度量与闸门

复跑命令：

```bash
python3 tools/ui_arch_audit.py --check          # 打印全量度量，不落盘
python3 tools/ui_arch_audit.py                  # 重生成 274 行逐文件画像 CSV
python3 apps/FrsetNext/tools/ui_lint.py         # 现有 R1-R3（当前 FAIL：29 条）
python3 tools/reconcile.py                      # CSV ↔ 台账 ↔ 索引（当前因 v260 未提交而报红）
```

建议把 `ui_arch_audit.py` 的 `--check` 结果接入 `check.sh`，并让 `reconcile.py` 成为唯一对账入口（现有 R1–R3 + 新增 R4–R8 + 两张新 CSV 的存在性）。

**当前实测基线**（审计时点，源码正在变动，以复跑为准）：

```
274 Swift 文件 / 90,384 行 / 8,361 声明（函数 3,265）
Theme.Radius 183 · Motion 46 · Stroke 10 · Space 5 · TextSize 0
字号字面量 1073（29 种取值）· 圆角字面量 53
内联子视图 530 · 共享组件命中 165 · Button 226 · 单例引用 500
probe.* 47 · SQL 语句 77 · DB 直接访问 21
有问题的文件 54 / 274（P0 6 · P1 14 · P2 34）
```

---

## 6. 针对 CSV 的单独报告

这一节专门回答「现有那两张 CSV 够不够用、还需不需要新表」。

### 6.1 现有 CSV 的状态

| 表 | 条数（HEAD `faef064`） | 口径 | 当前状态 |
|---|---:|---|---|
| `FrsetNext-函数清单.csv` | 8,310 声明 / 3,248 函数 | `func_table` 单一解析器，8 列：`module,file,owner,kind,name,line,lines,complexity` | 与 HEAD 一致；**相对工作区落后 41 条**（v260 新增 `ProcessFreezer.swift` 等） |
| `函数审阅台账.csv` | 3,248 条 | 函数级 KEEP/UNSURE 证据 | 与 HEAD 一致；工作区改动后同样需重锚 |
| `深度阅读/symbols.csv` | v156 快照 | 深读证据基线 | **故意不动**——动了 11 份报告的「（N func，CSV M）」标注会失去对应物 |

`tools/reconcile.py` 现在报「8,070 行不一致」，但**这是误报**：脚本用 `zip` 按行对齐比较（`reconcile.py:73-82`），一旦新增一个文件导致中间插入 41 条声明，后面所有行都会错位。真实差异只有 41 条。建议改成按 `(file,owner,kind,name,line)` 做集合差集。

### 6.2 结构性缺口：CSV 表达不了组件和层

函数清单的 8 列只能回答「这个文件里有什么声明」，回答不了本次审计的三个核心问题：

1. 这个文件属于哪一层？
2. 它复用共享组件了吗，还是又自造了一套？
3. 它有没有把领域逻辑 / 单例 / 调试钩子塞进视图？

所以本次**新增一张 CSV**，与函数清单同源、互补、可逐条核对：

> **`数据表/源文件分层与组件画像.csv`** —— 274 行 × 31 列
> `module, file, loc, claimed_layer, actual_layer, target_layer, decls, funcs, inline_views, view_marks, font_literals, font_sizes, font_values, font_token, corner_literals, radius_token, space_token, stroke_token, motion_token, token_hits, shared_hits, shared_detail, button_calls, button_styles, singleton_refs, probe_hooks, sql_stmts, db_access, domain_in_view, issues, priority`

关键设计：**`claimed_layer`（目录自称）与 `actual_layer`（内容实测）分列**。两者不一致的行就是层次违规候选——例如 `Features/Archive/Core/` 自称「领域/服务」、实测「界面层」，直接定位到 `ArchiveFlowRecommender.swift`。这比人肉翻目录可靠。

另外两张新表：

- **`数据表/UI与架构审计清单.csv`** —— 51 条发现，13 列，含证据位置、实测数据、目标产物、验收方式、状态；可直接当整改 backlog 导入。
- 两张表都由 `tools/ui_arch_audit.py` 生成（清单为人工判定、画像为自动实扫），与 `func_table` 共用扫描口径，不会出现第二套数字。

### 6.3 对账口径建议

```
源码 ──func_table.py──→ FrsetNext-函数清单.csv ──→ 符号索引.md / 模块依赖图.md
  │                          │
  │                          └──→ 函数审阅台账.csv
  └──ui_arch_audit.py──→ 源文件分层与组件画像.csv ──→ UI与架构审计清单.csv（人工判定）
                                │
                                └──→ ui_lint R4-R8 / reconcile.py 统一闸门
```

等 v260 提交后，一次性跑 `func_table.py → symbol_index_md.py → swift_catalog.py → reconcile.py` 把 HEAD 三套数字重新对齐；本轮**没有代用户重生成**，避免把在途改动混进证据链。

---

## 7. 风险与不该做的事

1. **不要全量重写、不要按 DDD 四层整体搬目录。** 跨 feature 耦合本来就低，收益不匹配风险。
2. **不要动 `FrsetStatsBar/` 的 C 引擎和 `g_snap` 单时间线。** 双轨问题按 `2026-10-19-重复实现扫描.md` 的 D 段单独处理，本轮未重新实测，不重复下结论。
3. **不要动 `深度阅读/symbols.csv`。** 它是 v156 快照证据。
4. **不要一次性替换 500 处 `.shared`。** 保留 `ServiceLocator` 门面，只要求新增用例走协议注入。
5. **不要把组件规范再写成一份新文档就结束。** v179 的规范 + 3 条 lint 已经证明：写进文档的没人用，写进 lint 的才有人用。
6. **本轮未改任何 Swift 源码**，因此没有重打 DMG、没有重启 App，二进制与 v258/v259 一致；新增的只有审计文档、CSV 和生成器脚本。

---

## 附录：证据复现

```bash
# 组件/层画像与全部数字
python3 tools/ui_arch_audit.py --check

# 令牌采用率
for p in "Theme.Radius." "Theme.Motion." "Theme.Stroke." "Theme.Space." "Theme.TextSize."; do
  printf "%-20s %s\n" "$p" "$(grep -rhoF "$p" --include='*.swift' apps/FrsetNext/Sources | wc -l)"
done

# 交互/窗口
grep -ro 'NSWindow(\|NSPanel(' --include='*.swift' apps/FrsetNext/Sources | sort | uniq -c
grep -rhoE 'styleMask: *\[[^]]*\]' --include='*.swift' apps/FrsetNext/Sources | tr -d ' ' | sort | uniq -c

# 现有闸门状态
python3 apps/FrsetNext/tools/ui_lint.py
python3 tools/reconcile.py
```

历史依据：`docs/40-审计与核对/UI-一致性审计与规范.md`（v179，含 R1–R3 规范）、`docs/40-审计与核对/2026-10-19-重复实现扫描.md`（双轨与死代码）、`docs/00-总览/工程全图.md`（骨架与注册表）。
