# FrsetNext 并行开发契约（所有模块代理必须遵守）

## 0. 项目背景

我们在**正向重建**一款 macOS 菜单栏效率工具（逆向目标：闭源应用 Frset 1.3.12）。
技术栈（已实证）：**AppKit + SwiftUI 混用 / Combine / libsqlite3 / Swift 6.4（用 `-swift-version 5` 语法模式）**。
全部功能规格书在 `../../specs/`。本工程源码目录：

```
apps/FrsetNext/Sources/
├── Core/        ✅ 已完成：Support(Log/Theme/ServiceLocator/ModuleRegistry/String.sha256/Date.relativeText/AppDirectories)
│                             Preferences、Registry(面板区段/设置页签/状态栏项 三个注册表 + 控制协议)
├── Models/      ✅ 已完成：ClipboardItem/Tag/FileTypeIcon/Tool*/LLM*/MonitorSample/Calendar*
├── Storage/     ✅ 已完成：SQLiteDatabase(封装) + DatabaseManager(schema 已建表，含 LLM/工具表)
├── Features/    ⬜ 各模块（你负责其中一个目录）
└── App/         ✅ 已完成（FrsetNextApp + AppBootstrap 总控接线；模块代理请勿修改）
```

## 1. 硬性约束（违反会导致整轮返工）

1. **只在你被分配的 `Features/<模块>/` 目录内创建/修改文件**。不要动 `Core/`、`Models/`、`Storage/`、其他 `Features/*`、根目录文档、`App/`。
2. **不要执行任何 git 命令**（总控统一提交）。
3. **禁止模块间直接引用彼此的具体类型**（如 Clipboard 不要 `import` 或调用 Monitor 的类）。跨模块一律走 §3 的注册表 / ServiceLocator。这是并行可独立编译的前提。
4. **不要创建 `App/` 目录、不要写 `@main`**（唯一入口由总控最后写）。
5. 每个模块必须提供 `AppModule` 实现（见 §2），在 `start()` 里完成自我注册。
6. 代码风格：类名/方法名**沿用原作命名**（见各自规格的「类清单」），注释用中文，克制使用第三方依赖（**零外部依赖**，只用系统框架）。

## 2. 模块必须实现的入口

```swift
public enum MonitorModule: AppModule {          // 名字换成你的模块名
    public static let identifier = "monitor"
    public static func start() {
        // 1) 启动服务/定时器
        // 2) 注册面板区段 / 设置页签 / 状态栏项（按需，见 §3）
        // 3) 若你提供共享能力，注入 ServiceLocator（如 AI 模块注入 llmService）
    }
}
```

## 3. 跨模块交互的三个注册表（Core/Registry.swift 已定义，直接调用）

```swift
// ① 主面板区段（供 04 面板模块渲染）
PanelSectionRegistry.register(PanelSectionDescriptor(
    id: "clipboard", title: "剪贴板", priority: 20,
    build: { AnyView(ClipboardSectionView()) }))

// ② 设置窗口页签（供 07 设置模块渲染，id 建议用 general/monitor/clipboard/search/ai/tools/shortcuts/about）
SettingsPaneRegistry.register(SettingsPaneDescriptor(
    id: "monitor", title: "监测", systemImage: "gauge",
    build: { AnyView(MonitorSettingsPane()) }))

// ③ 状态栏项（供 08 状态栏模块创建 NSStatusItem）
StatusItemRegistry.register(StatusItemDescriptor(
    id: "monitor.cpu", priority: 10,
    title: { "12%" },
    attributedTitle: nil,
    onTap: nil,
    popover: { AnyView(CPUPopoverView()) }))

// ④ 共享能力注入（AI 模块 / 截图模块用）
ServiceLocator.llmService = AnthropicService.shared
ServiceLocator.ocrService = OCRService.shared
// ⑤ 需要唤起面板/设置窗口时（不要引用具体类）
ServiceLocator.panel?.toggle()
ServiceLocator.settings?.open(pane: "monitor")
```

## 4. 可用共享 API 速查

| API | 位置 | 说明 |
|---|---|---|
| `Log.info/debug/warn/error(tag, msg)` | Core/Support | 日志 |
| `Theme.cornerRadius/rowHeight/thumbSize/cardBackground/sectionHeader()` | Core/Support | 视觉常量 |
| `Preferences.shared.value/set/binding` + `Preferences.Keys` | Core/Preferences | 偏好（键名见文件） |
| `AppDirectories.base` / `.sub("images")` | Core/Support | 数据目录 |
| `DatabaseManager.shared.clipboard / .statistics` | Storage | 已建好 schema 的库 |
| `db.run(sql, [SQLiteValue])` / `db.query(sql, [SQLiteValue])` / `db.transaction{}` | Storage | SQLite 操作 |
| `row.string("content") / .int() / .real() / .bool()` | Storage | 取值便捷方法 |
| `String.sha256` / `.truncatedForDisplay`、`Date.relativeText` | Core/Support | 工具扩展 |
| `MonitorSample` / `ClipboardItem` / `Tag` / `LLMChatSession` / `CalendarDay` 等 | Models | 数据模型 |
| `OCRTextObservation`、`OCRServiceProtocol`、`LLMServiceProtocol` | Core/Support | 协议 |

## 5. 完成前必须自检（把错误修到 0）

```bash
cd /Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/Sources
SDK=$(xcrun --show-sdk-path)
swiftc -typecheck -sdk "$SDK" -target arm64-apple-macosx13.0 -swift-version 5 \
  Core/*.swift Models/*.swift Storage/*.swift Features/<你的模块>/*.swift
```

要求：**0 错误**（警告可留）。若确需新系统框架，确认它在 macOS SDK 中存在（如 `ScreenCaptureKit`、`Vision`、`EventKit`、`CoreGraphics`、`IOKit`、`Combine`、`AppKit`、`SwiftUI`）。

## 6. 交付

完成后回报：创建了哪些文件 + 每个文件职责一句话 + typecheck 结果 + 你认为需要总控接线的点（如"需要 App 层调用 MonitorModule.start()"）。

## 7. 总装补充裁决（2026-10-15，planning；优先级等同 §1，禁止回退）

总装阶段发现并已修复的跨模块问题，以下为最终裁决，后续任何代理不得回退：

### 7.1 快捷键体系归属
- `ShortcutRegistry` / `ShortcutManager` / `ShortcutDefinition`（Carbon 全局热键 + 冲突检测）**唯一实现在 `Features/Toolbox/ShortcutManager.swift`**。
- 设置页签「快捷键」（id `"shortcuts"`）由 **ToolboxModule** 注册（`ShortcutSettingsPane`）；设置模块只保留 `general` / `about`。原 Settings 内的展示用简化版 `ShortcutRegistry`/`ShortcutEntry` 已删除，**禁止恢复或改名重加**。
- 页签 id 归属表：`general`/`about`→Settings，`tools`/`shortcuts`→Toolbox，`monitor`→Monitor，`clipboard`→Clipboard，`capture`→Capture，`ai`→AI。同一 id 只允许注册一次。

### 7.2 剪贴板跨模块写入 API（App 层事件接线用）
```swift
ClipboardManager.shared.insert(_ result: ClipboardReadResult)   // 通用：复用捕获管线（去重/落盘/统计）
ClipboardManager.shared.insertImage(data:fileURL:sourceApp:)    // 截图模块产出
ClipboardManager.shared.insertText(_:sourceApp:subtitle:)       // OCR / 文本产出
ClipboardManager.shared.ingestToolOutput(text:sourceToolKeyword:analyticsId:)  // 工具/AI 产出（is_generated_by_tool=1）
await ClipboardManager.shared.searchGlobal(query:limit:)        // 全局搜索源 → [ClipboardGlobalSearchHit]
```
配套：`ClipboardPasteboardReader.imageResult(...)` / `.textResult(...)` 静态工厂（图片自动补算指纹）；
`ClipboardGlobalSearchHit`（剪贴板模块自有 DTO；映射为 Toolbox `SearchResultItem` 的职责在总控，保持模块零耦合）。

### 7.3 事件总线签名冻结（App 层已接线，禁止改动）
- `CaptureEventBus.onImageCaptured: ((URL, Data) -> Void)?`、`onTextRecognized: ((String) -> Void)?`
- `AIEventBus.onResultProduced: ((String) -> Void)?` + `emitResult(_:)`
- `ToolboxEventBus.onResultProduced: ((String, ToolKind) -> Void)?` + `emitResult(_:kind:)`
- `SearchHookRegistry.register(_:)` / `search(_:)`

### 7.4 @Stored 属性包装器补充规则（本机替代 @State 的唯一方式）
```swift
@Stored private var mode: Mode          // 无默认值 OK
@Stored private var opt: String?        // Optional 无默认值 OK
// 自定义 init 中的初始化（后备存储是 StateObject<StoredBox<T>>）：
self._mode = Stored(wrappedValue: mode ?? .infer(from: text))   // ✅
self._mode = State(initialValue: ...)                            // ❌ 类型不匹配
```

### 7.5 新版工具链 C 函数迁移
遇到旧 API obsoleted/迁移提示时：`CGEventTapCreate` → `CGEvent.tapCreate(tap:place:options:eventsOfInterest:callback:userInfo:)`；
`CGEventTapEnable` → `CGEvent.tapEnable(tap:enable:)`。准确签名查 SDK `CoreGraphics.framework/Headers/CoreGraphics.apinotes` 的 `SwiftName:` 字段。

### 7.6 自检工具（每次改动后必跑）
- 逐模块 + 全量 typecheck：`apps/FrsetNext/check.sh`（逐模块 + 全量，报告写入 `build/typecheck-report.txt`）
- 跨模块耦合/重名/入口对账：`apps/FrsetNext/coupling_check.py`（报告 `build/coupling-report.txt`）
- 标准：全量总装与逐模块自检均须 **0 error**。

---

## 5. 窗口事件与焦点归属（新建 NSWindow / NSPanel 必答两问）

> 本轮共性坑：四个 NSPanel 分属不同模块、不同时期编写，**全部**依赖 `mouseMoved`，**全部**漏设
> `acceptsMouseMovedEvents`；另有两处 P0 缺陷同属此类。每个新窗口都要重新踩一遍，故立为契约。

1. **是否需要 `acceptsMouseMovedEvents = true`？**
   窗口内若有任何依赖 `mouseMoved` 的逻辑（悬停预览、抑制解除、拖拽跟手），必须显式开启。
   否则依赖 `addLocalMonitorForEvents(.mouseMoved)` 的链路**静默失效**——不报错、不崩溃，
   只是功能永远不恢复。
   （证据：`Panel/FloatingPanel.swift` 曾漏设，导致预览关闭后永久无法复弹。）

2. **first responder 归属谁？**
   - `canBecomeKey` / `canBecomeMain` 是否为 true？点击后谁接收键盘事件？
   - **非激活面板**（`.nonactivatingPanel`）内含 NSView 子视图时，子视图 `acceptsFirstMouse`
     会抢走键盘归属，需显式 `window.makeFirstResponder(目标视图)` 反向夺权。
   - 跨 SwiftUI 边界：`TextField` 获得焦点后会持续持有 first responder，纯 NSView 侧键盘通路
     必须显式夺权并在真机验证。
   （证据：`RowHostingView.acceptsFirstMouse = true` 使 NSTableView 收不到空格/↩；
   已用「显式 `selectRowIndexes` + `makeFirstResponder(table)`」修复。）

### 5.3 新建窗口四项检查表（缺一即 review 不通过）

| # | 项 | 判定标准 |
|---|---|---|
| 1 | `canBecomeKey` / `canBecomeMain` | 窗口内需要键盘输入 → `canBecomeKey = true`；纯展示窗可 false |
| 2 | `acceptsMouseMovedEvents` | **按窗体实际用途判**：需要跟鼠标移动（悬停态/拖拽跟手/抑制解除）才 true；气泡类点击穿透窗、对话框类无 hover 态 → **不要无条件全开**（mouseMoved 分发有持续开销，且会让本应穿透的窗吞事件） |
| 3 | 呈现方式 | 需要键盘焦点用 `makeKeyAndOrderFront`；纯展示用 `orderFrontRegardless` |
| 4 | first responder 归属 | 谁承接键盘事件；点击后焦点落在哪；非激活面板是否需显式夺权 |

> 证据一：`FloatingPanel` 漏设 `acceptsMouseMovedEvents` → 悬停抑制永久无法解除（功能静默失效）。
> 证据二（两个独立模块同因）：`MenuBarIconEasterEggDialogOverlay`（borderless）沿用默认
> `canBecomeKey = false` → 卡片按钮拿不到焦点、`keyboardShortcut(.defaultAction)` 回车静默失效；
> `ClipboardTableHostView` 行视图 `acceptsFirstMouse` 抢焦点 → 表格收不到空格/↩。
> 两者修法一致：显式声明归属 + `makeFirstResponder` 夺权。

## 6. 视图/对象反查纪律

读取或编写「取视图/取句柄/取节点」类代码（`subviews`、`superview` 链、`hitTest`、
`rowView(at:)`、`cellView(at:)`）时：

1. **先验证来源本身能否拿到目标对象**，再验证取值逻辑（边界、判空、相交判断）。
2. 必须确认容器的**数据源模式**：view-based（`tableView(_:viewFor:row:)`）与 cell-based
   （`cellFor`）**视图层级完全不同**——view-based 会把 delegate 返回的视图包进 `NSTableRowView`，
   `table.subviews` 的直接子元素不是你的视图，**强转恒为 nil**。差异就写在方法签名里。

> 证据：`table.subviews.first { … } as? RowHostingView` 恒 nil，致 hover 高亮从未亮过、
> 单击预览贴在面板左上角而非被点行、键盘预览锚点为 nil——三条链路同时哑，且审计据此签发的
> ✅ 判定是错的（已撤回）。修复改用「行号 → 弱引用视图」侧表 + 复用时覆盖 + reload 时按行号裁剪。

## 7. 引用原作地址前必须回读反汇编

注释里写「`0x…` = 某语义」之前，**必须回读该地址附近的指令确认**；相邻地址语义相似时尤其危险
（钳制 vs 限幅、比较 vs 传送）。

> 证据：贴图缩放「8 倍上限」误引 `0x1002f5a00`，实测该处为
> `fmov d3,#1.0` / `fcmp d2,d3` / `fcsel d2,d3,d4,ls`（下限钳制），原作无上限。

## 8. 审计判定纪律

1. **静态证据只支撑 ⚠️（待实测），✅ 必须有真机验证支撑**。代码修好 ≠ 判定通过——
   静态只能证明「接线正确」，证明不了「运行时 first responder 归属」与「实际呈现位置」。
2. 审计代理发现自己的误判必须**主动撤回**并修正统计（勘误优于沉默）。
3. 结论双侧举证：原作侧引 SPEC 实证地址/字面量，重建侧给 `文件:行号`。

## 9. 收尾守门纪律

1. **静置再跑**：并发写文件期间跑 typecheck 会出现
   `error: input file 'X' was modified during the build` 的**假红**（swiftc 读到半个文件）。
   收尾汇总前必须在无人改文件的时间点静置 30~60 秒再跑 `tools/check.sh`。
2. 不可把假红误判为回归后草率派单——先确认 git status 是否有并发写入。

## 10. 资源与本地化

1. 文案资源放 `Resources/<lang>.lproj/Localizable.strings`，**键面 = 英文句本身**，缺失回退英文。
2. `build.sh` 必须把 `Resources/` 打进 app bundle。
3. 切换语言须广播 `languageDidChange` **并有观察者刷新 UI**，否则语言下拉是装饰性开关。
4. 基建类注入器（EnvironmentKey / ViewModifier / protocol 适配器）必须有真实消费点，
   零挂载的死代码等同未实现——收尾须 grep 验证消费点存在。

---

## 11. 推测措辞纪律（本条最重要）

**推测只能标 ⬜，不能写成「建议」。**

当你只读了部分代码、对某处的理解低于该处 owner 的理解时，正确的输出是：

> ⚠️ 此处存疑（我未通读 `文件:行` 前后），建议由 owner 确认。

**严禁**输出「这看着像 X，可能有问题」「建议检查一下」这类替换性判断——它会让 owner 失去
自主判断，并在 owner 未复核时直接引入真实缺陷。

> 证据（本轮最贵的一次）：审计代理对 CPU 读取处输出「`vm_deallocate` 的字节数疑似算错，
> 跑起来可能出问题」——但它只读了 21 行、未见调用点。owner 照此"修复"，改成了
> `infoCount * MemoryLayout<processor_cpu_load_info_t>.size`，而头文件宏
> `PROCESSOR_CPU_LOAD_INFO_COUNT = sizeof(...) / sizeof(natural_t)` 表明 infoCount 的单位本就是整数个数——
> 照此修改会把释放量放大 4 倍。owner 与另一代理交叉核实后驳回该建议。
>
> 讽刺的是它同一时刻对**另一处未读全的代码**给出了正确判断——因为那处它确实读全了。
> 这恰好证明：**输出的可信度取决于覆盖范围，与结论的自信程度无关。**
>
> 配套约束：
> 1. 结论必须标注覆盖范围（读了哪几行 / 是否通读）；
> 2. 涉及资源释放、内存布局、指针算术、C ABI 边界的推测，一律先回读权威来源（头文件宏、反汇编）；
> 3. 他人转述的结论同样适用本条——引用前必须独立核实（本轮已出现三条转述全部过时/误判）。

---

## 12. 检索结论对账纪律（正向 + 反向）

### 12.1 正向：凡以计数/分布形式回答检索类问题，必须做「应有项 vs 实有项」对账

查「某符号/某配置/某键是否在某处被使用」时，单点命中不足以支撑结论。必须先列出
**应有项清单**（按机制应存在的全部位置），再与实有项比对，差异要么修、要么显式列为待办，
不得只在正文里轻描淡写地提一句。

> 证据：审计代理以「grep 零命中」断言「hover 高亮从未生效、popover 一直贴在面板左上角」，
> 但工程里早已存在 hover 操作区按钮、popover 位置可跟随行移动等反证——对账缺失导致断言过强。

### 12.2 反向：**异常沉默也必须解释**（零命中 ≠ 不存在）

若某历史行为「本应出现却从未被观察到」，这个现象本身就是**推翻当前结论的证据**，
而不是无关信息。遇到时必须停下来问：我这个推导是不是漏了什么？

> 证据：`table.subviews … as? RowHostingView` 恒为 nil 这个结论，形式上无懈可击；
> 但若 hover 高亮在历史上正常用过，就说明推导有缺口——两者不可共存，必须重新审视推导链。

### 12.3 呈现越干净，越要追问

「零命中」「单点命中」「无任何警告」这三类信号本身要成为待查项，而不是结论的加分项。
一条检索结论越显得干净利落，越容易让人停止追问。

> 附带：本条与 §11（推测措辞）互为表里——§11 管「没读全就不要下判断」，本条管「读全了也要对账」。

---

## 13. 代码建议交付纪律（示例代码不是推测，是交付物）

**凡输出「可直接落地的代码建议」（补丁片段、替换代码、新 API 用法、诊断埋点写法），必须先实际编译验证过。**

- 最低标准：用 `swiftc -typecheck` 对最小复现跑一遍（或对该文件跑模块 typecheck）；
- 做不到时，**必须显式标注**：「⚠️ 未验证，请自行 typecheck 后再落」——不得让读者以为它已验证。

> 证据（本轮两次）：同一处诊断埋点，审计代理给出「在 `handleSpaceKey` 入口加一行日志」的方案，
> 实测①编译不过（`use of local variable 'item' before its declaration`——守卫在前、`let item` 在后）；
> ②落点错误：`keyDown:247` 的 `if selectedRow >= 0` 守卫使 `selectedRow == -1` 时
> `onSpaceKey` 根本不被调用，日志一行都执行不到——恰好漏掉最该被观察的失败模式。
> 两处都被他人实测挡下；若无人挡，代价分别是"验证多绕一轮"与"更坏的情况"。

### 13.1 §11 与 §13 的分工

| 条 | 覆盖对象 | 判据 |
|---|---|---|
| §11 推测措辞 | **判断/结论**（对他人代码的解读、缺陷断言） | 没读全 → 只标 ⬜ + 注明覆盖范围 |
| §13 代码建议 | **交付物**（可直接粘贴运行的代码） | 必须编译验证；未验证必须显式声明 |

> 教训：同一轮里代理对自己写的「结论」执行了 ⬜ 纪律，却对自己顺手写的「示例代码」没有——
> 因为示例代码看起来不像"推测"。它会被直接粘贴运行，所以必须按交付物标准对待。

### 13.2 配套：结论默认需 owner 复核

跨模块审计结论、在他人领地代码上的缺陷断言、以及一切代码建议，**默认需 owner（总控）复核后才执行**。
这不是对审计严谨性的质疑，而是工程纪律：审计代理的覆盖率天然受限（只能读到被指到的文件），
而 owner 掌握全库视图与历史信息（本轮已有三条转述全部过时/误判的记录）。

---

## 14. 检索式必须对冲命名变体

判定「某能力未接线 / 不存在」时，检索式至少覆盖三种写法，**三种都零命中**才可下结论：

1. `属性名\s*=`（裸赋值）
2. `\.属性名\s*=`（带对象前缀，如 `xxx.shared.属性名 = `）
3. 声明处与注释（`var 属性名:` / 文档示例）

若只命中注释，**必须再扫调用侧**（谁会消费它、在哪初始化）才能下结论。

**自检问句：「如果它已经接好了，我这个模式还能找到吗？」——答不上来就不能报『未接线』。**

> 证据：审计代理用 `fullTextProvider\s*=` 判定「预览数据桥未接线」。该次读数恰好正确（缺陷真实存在），
> 但**方法上依赖运气**——真实接线写成 `PreviewPopoverDataBridge.shared.fullTextProvider = `，
> 模式无法命中。若当时接线已存在只是前缀不同，它会再报一次「未接线」，那就是真误判。
> 同一根因此前已出现过一次（grep 为回答计数而非诊断、模式未对冲变体）。

### 14.1 结论须附审计时点

每条审计结论必须标注**审计时点**，并说明是否存在「后续提交可能改变该结论」的情况。

> 证据：本轮出现「时序失真」——审计报告发出后，owner 提交修复（11:30），
> 使报告内容在读者眼中变成「误判」，而实际上审计读数在其时点完全准确。
> 不附时点的结论无法区分「读错」与「时序差」，会让审计档案失真。

### 5.4 键盘兜底与 SwiftUI 快捷键不得双挂（否则一次按键触发两次回调）

窗口层用 `performKeyEquivalent` 兜底（Return/Esc）时，**必须检查卡片内的 SwiftUI 按钮是否还挂着
`.keyboardShortcut(.defaultAction)` / `.keyboardShortcut(.cancelAction)`**——两者同时生效会让**一次按键走两条路径**，
回调执行两次（彩蛋对话框曾因此把 `ServiceLocator.settings?.open` 调两次）。

- 处置：窗口层兜底 + 视图层快捷键**二选一**；若必须共存，则在展示入口用 `fireOnce` 语义包一层
  （一次展示只允许触发一次）并在该处统一收窗；
- 收窗时**清空键盘回调**并**复用窗口不置 nil**（对齐 Toast 与原作浮层的「窗口复用不销毁」语义），
  否则残留回调会在下一次展示前被误响应。

> 证据：彩蛋庆祝框加窗口层 Return 兜底后，与 `.keyboardShortcut(.defaultAction)` 形成双触发。
> 该缺陷肉眼几乎不可见（彩蛋只在解锁一瞬出现），但任何后续往回调里加 toast/统计/持久化的改动都会中招——
> 典型的「现在不出错、加一行就出错」陷阱。

### 11.1 风险等级须区分「机制上可能」与「操作序列下必然」

判定风险等级时，必须区分这两者，**不得把"机制上可能"表述为"确定阻断"**：

- **操作序列下必然** = 不存在任何规避它的用户操作序列 → 需**证明**这一点（通常要核对调用时序与守卫顺序）；
- **机制上可能** = 理论上可触发，但需要用户做出特定动作 → 标为**条件性风险**，并**写明触发条件**。

> 证据：审计代理把「空格预览的 0.30s WorkItem 可能被取消」判为「确定阻断」，
> 但未核时序——`handleSpaceKey` 先校验 `selectedRow >= 0` 才入队 WorkItem，
> 因此触发取消需要「再一次选中变化」，而那与用户「按空格看预览」的意图互斥。
> 这是**结论强度超出证据强度**，与 §11 的"读不到就标 ⬜"同源：
> 读到了机制，却没读时序，就给了比证据更强的结论。
>
> 自检问句：**「有没有一条用户操作序列能让它必然发生？举不出就别写『确定』。」**
