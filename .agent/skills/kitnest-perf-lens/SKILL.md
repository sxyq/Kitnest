---
name: kitnest-perf-lens
description: Kitnest 全链路性能/交互/渲染热点诊断；先独立读函数完整实现与调用链，再借鉴 fast-anything 方法，未确定的热点先要求本地隔离或既有数据测量。适用 screenshot、Island、Storage、Glass、Archive、Clipboard、FloatingBall、Monitor、GenieWarp。
---

# Kitnest Perf Lens — 本项目分析方法

> 2026-11-24 性能第二轮（v292）复核更新：6 项过时检查点已移除/改写，新增测量口径纪律。
> 引用检查点前先看「当前检查点」节，别把已修的东西再报一遍。

## 不可覆盖的用户约束

用户使用电脑期间：**不抢鼠标、不变更前台焦点、不弹窗打断、不重启/终止 Kitnest**。不执行 `launch_smoke.sh`、`open -a`、`open -g`、会打开窗口的 `kitnest://` 深链、AX 点击、鼠标模拟、`pkill/kill`、会触发窗口的 `defaults probe`、启动会覆盖 `/Applications` 的 build.sh，也不自动清理缓存、推送 main、打 DMG。对于需要窗口操作的测量，注明「需用户空闲或单独授权」，先继续其他静态修复。分析工具只能对已存在的日志/源码或独立、无 UI 的纯函数负载使用。

## 使用 fast-anything 的准确边界

原版 Skill（相邻 `../fast-anything/SKILL.md`）针对 Python/Node/TypeScript/Ruby/Java/Go/PHP/C/C++/C# 的**纯函数**，流程为 scan→port→verify→enable→bench→report，不能自动识别 SwiftUI、AppKit、NSWindow、Metal/Core Animation 或 Swift 的业务行为。对 Kitnest 主程序 **不要**启动 `fast-anything` 或转换 Rust。只借鉴其方法：真实热点 → 可分离的纯计算 → 语义等价 → 端到端收益。若独立 Python/Node/C 工具脚本有代表性安全工作负载且函数占用明显，才考虑原版 CLI；CLI 会重新运行用户给的命令并记录真实调用，不能录制含机密的任务输入。

## 分析算法（每次任务必须走这一逻辑，不创建额外文档）

1. 独立观察：读真实本地 `git status/HEAD`、完整相关源码、父级调用者、数据结构、取消/缓存/刷新路径；别看摘要就定性；旧文档只用作定位。
2. 构造业务链：入口事件 → 状态 → 计算/IO → UI 发布/渲染 → 退出/取消/缓存失效。标出每个方法实际在哪个线程或队列、每次触发次数与副作用。
3. 明确区分：源码可证缺陷、性能热点候选、已有日志观察、缺设备/交互时不能确认的事项。
4. 对热点候选，若必须测量才知，先给本地 Agent 一个独立的**只读/无前台**测量包：具体方法、需要哪段计时、数据格式、如何避免系统行为变化；未获得数据前不臆测"快 xx%"。
5. 对源码已经能证明的语义缺陷，直接交付最小修复指令，不强制等性能测量。
6. 批量只修改当前目标相关职责，沿用原功能和数据模型；截图画质、UI、动画曲线、滑动、玻璃观感不准被"优化"删减。必要验证限于不会打断用户的编译/静态/纯函数检查。

## 测量口径纪律（2026-11-24 第二轮加入；违反会得出错误结论）

1. **玻璃 frame 更新 ≠ 玻璃对象重建**：`IslandMaterialView` 的取样面只在两档间切换（`glass.frame` 赋值次数），NSGlassEffectView 对象只在 init 建一次；日志已更名「取样面更新」。
2. **显示时钟回调 ≠ 实际应用 FPS**：CVDisplayLink 只报「显示时钟回调节奏」；主面板/岛日志里的 fps 是回调频率，不是提交/呈现帧率。
3. **CPU 用 `proc_pid_rusage` 取，不靠 top/ps**：本机（macOS 27）`top`/`ps` 被系统策略拒（operation not permitted）。可靠通道是 `proc_pid_rusage(pid, RUSAGE_INFO_V2)` 的 `ri_user_time+ri_system_time` 差分（脚本见下），能给出真实进程 CPU%，同时用 `footprint <pid>` 取 phys_footprint。sample 的等待样本比例只说明线程闲，不能当 CPU%。
   ```python
   # 0.5s 间隔差分 user+system 纳秒；buf 前 16B 是 uuid，随后两个 uint64
   libc.proc_pid_rusage(pid, 2, buf); user=int.from_bytes(buf.raw[16:24],'little')
   ```
4. **orderFront 返回 ≠ 可交互**：`presentOverlay` 的计时已拆「建窗/状态/激活/orderFront返回」；真实可交互看覆盖层首次输入事件（`presentedAt` → `noteFirstInput`）。
5. **`NSWindow.didUpdate` ≠ 首帧呈现**：它只在窗口进入更新周期时发；实测岛展开呈双峰（30–50ms / 140–170ms）且与 `setFrame(display:)` 模式无关，不能拿它比较「首帧早晚」。首帧早晚只能靠屏录/signpost；单次 A/B 至少要交替 6 轮以上，冷启动值要多次重启取分布。
6. **CPU / 内存 / 存储 / 延迟必须分开报**：footprint 是物理占用不是缓存总量；du 是落盘不是常驻；日志毫秒是机器耗时不是呈现时间。三种口径不能混在一张「优化了多少」的结论里。
7. **mmap 的字节池几乎不计入 footprint**：`FileNameIndex`（177MB）、`disk-index` 缓存等走 mmap/文件映射，进程内存只 +5MB 量级；这类模块的「占用」要分别报「磁盘体积 / 常驻 footprint / 查询耗时」，不能把磁盘体积当内存。
8. **索引查表复杂度 ≠ 完整上游业务调用链**：`childIndex[currentPath]` O(1) 不代表 `visibleEntries` 整体 O(1)（v288 就遗留了每访问一次全量辅助过滤）；要测整条属性/body 求值路径。
9. **非同版本、非同条件测试不能算可归因降幅**：旧安装版 vs 当前 main、空闲 vs 满载、单屏 vs 双屏，只允许并列陈述，不允许算百分比降幅；同一纯数据模型的新旧两版对比（同机同轮）才算。**一次性的冷进程值（如部署后首次展开）不得写成常态值。**

## 当前检查点（以本地 HEAD 为准）

### 已修复——不要重复报告（每条附落地提交）

- `StorageMapShape` 液面已按用户定案延伸到上半部（v286 `9a3800b2` 整窗共享画布）；不要再报"局部矩形上沿"。
- 玻璃焦点一致性：主面板/剪贴板/悬浮小窗走稳定 `.inactive` 策略（v286 `d4b67051`）；岛外壳默认 `material=.liquidGlass` 走 NSGlassEffectView 是**当前设计路径**，日志如实报告，不是 bug；不要自动改用户偏好。
- `IslandController.openedExplicitly` 点击保护已拆分（v286 `d4b67051`）；`endInteraction` 语义已修。
- `children(in:of:)` 每列全扫已改 parent→children 索引（v288 `e8136ff2`）；`visibleEntries` 空搜索白算全量辅助过滤已修（v292 `28b79c86`）。
- `DesktopPetView` 每帧 `NSImage(contentsOfFile:)` 已改 path+mtime 绑定缓存（v288 `e8136ff2`）。
- AGENTS.md / frset-release / frset-verify 的强制重启口径已修（`c0ba36d5`）；零打扰为默认。
- 岛展开选区读取已异步（v292 `fb415594`）：捕获前台上下文 + 后台 AX + 0.25s IPC 超时 + 代次丢弃；命令面板/划词仍同步。不要再要求"展开时同步读选区"。
- 截图流式取消已修（v292 `7e65f000`）：Task 取消/epoch 过期后不再 addTask 后续屏幕；后续屏幕改 orderFront 不再抢 key。
- **岛定位不是持续热点（v292 实测复核，勿再报 163ms）**：冷展开 36–45ms / 热展开 15–20ms；`setFrame(display:true/false)` 交替 6 轮差 <8ms，`didUpdate` 也无可比差异。163/173ms 只出现在「部署后第一次冷进程」场景，属一次性冷布局，不能当常态。`probe.islandPositionDisplay` 保留为诊断开关（默认 true）。
- 归档 `ArchiveEntry` 字符串驻留**收益很小**（实测 100k 条：227B/条 → 182B/条，只省 4.3MB）：不要再提「驻留省 30–50%」。100k 的 293MB 峰值主要来自解析瞬态与视图快照，不是条目数组本身。

### 仍准确（保留）

- 标注编辑器仅在「仅文本马赛克」启用时预热 Vision；关闭该功能时不要仅为预热加载文本模型。岛材质关闭 `probe.islandMaterial` 时跳过诊断位置采样，遮罩、采样几何和动画照常更新。
- `MosaicTextOnly` 仅缓存最近一张图；`AnnotationCanvasView` 释放时按 `CGImage` 身份清缓存，避免截图长期驻留；取色器结束时取消 SCK 等待，取消后不启动抓屏回退。

- `GlassSurface/GlassTintOverlayView` 在 `6aafe4eb` 已合并底衬+霜感为单层；**不得重复要求合并**。
- `tools/func_table.py` 的 `doc_path` 为路径最长前缀映射，0 条未映射 ≠ 文档内容正确；重载只有 file#owner#name 粒度。
- 外置 exFAT 工作树的 Swift 类型编译需排除 `._*` 边车文件；沿用 `check.sh` 的 `-j 2` 与 `nice -n 10`。存储布局仅运行一个后台请求并保留最新待算请求，节点回退缓存按 node ID 淘汰，不能拿布局复合键删除节点缓存。
- 存储缓存的早期和现行格式都可能是 schema=6。复用分类汇总应依据非空 `dataCategories` 及每类 `pathBytes` 的存在；缺明细或空分类仍调用原整树汇总，不能仅凭版本跳过旧缓存处理。
- 清理孤儿目录时，递归删除必须以全部层级的内容为依据；只读第一层会漏掉嵌套用户文件。沿原后台队列使用原生递归枚举，遇到文件或读取失败保留目录，不跟随符号链接。
- 文件名索引按剩余映射长度使用 `strnlen` 定位终止符；`min(offset + strlen(...), length)` 无法约束 `strlen` 自身的读取。保持 main 与 Lite 共用相同实现。
- 磁盘「可清除」查询的正式方法独立调用实测首次64ms、热态中位17ms；`diskPanel` 按原 `extra.updatedAt` 在后台查询，渲染只读状态，预览不查询真实卷；离页及采样换代取消旧任务。窗口交互与整窗收益仍按安装版实测。
- `TagStore.delete` 的关联删除已由 `SQLiteDatabase.init` 启用的外键及 `clipboard_item_tags.tag_id ON DELETE CASCADE` 实现；实际库表声明一致。旧审阅中「需确认级联」的问题已经核实，不额外补写关联删除 SQL。
- `DatabaseManager.migrate` 已合并重复的收藏插入，保留level列就绪后的显式level=1缺失收藏迁移及反向兼容字段同步；不额外增加迁移版本标记。实际库3318条、剪贴板收藏0条，level默认1及索引已只读核实；完整启动及大量收藏耗时仍待实测。
- 标注文字 `wrapText` 保留逐字符测宽，以原文、完整NSFont和精确宽度缓存结果（32项、1MiB成本预算）；真实5905字三组设置输出与原方法一致，同轮原计算83.62–189.24ms、复用0.007–0.293ms。只说明换行方法，窗口拖动、字体切换与导出仍待实机交互。
- `ScreenshotManager.reloadRecent` 当前已在utility队列调用 `scanCapturedImages` 并回主线程发布；审阅目录扫描时沿现有后台路径分析，不重复要求后台化。
- `ScreenTranslator.runAsync` 在原detached任务中连续渲染与PNG编码，MainActor继续暂存、登记和钉图；现有1925×911截图的正式编码方法三次为131.06/140.16/174.81ms，整轮翻译完成交互仍待实机确认。
- `CaptureSectionView.pickAndStitch` 在原后台拼接闭包中继续PNG编码，再传给 `saveStitchedResult`；失败反馈、保存、历史与触感仍按原主线程顺序执行。写盘耗时及选图完成交互仍待实机测量。
- `PinMenuView.setEntries` 按原字号与固定色准备当前行图标，`draw`复用；换菜单替换行，不建立全局缓存。原15种符号两色1x/2x离屏像素一致，同轮24次图标绘制49.98–58.41ms→2.35–2.92ms；首次符号初始化准备151.34ms，窗口悬停及子菜单交互仍待实测。
- `ClipboardRepository.delete` 已把原文件存在条件移到共享SQL之前，首次复制才创建临时目录；真实旧历史200条的438个候选路径中229个已不存在。后续分析沿现存附件的共享查询继续取证，保留原事务、失败恢复和OCR/标签清理。
- `JSONInspectorView.refreshMatches` 只在树形模式建立命中集合，切回树形按当前查询重建；表格、卡片与原始模式不再额外递归。真实1440条JSONL的原首次遍历42.30–49.09ms、热态7.41–8.73ms，切回后170命中及472路径相同；表格行构建、筛选排序及窗口输入仍待各自测量。
- `LongScreenshotPreviewController` 的保存与复制共用串行后台队列执行原PNG编码，主线程继续保存登记与剪贴板写入；复制的PNG失败时保留原NSImage分支。真实2745×1365图的工作队列编码21.80–22.82ms、输出字节相同；大长图、连续点击、关闭及落盘仍待窗口实测。
- `LongScreenshotStitcher` 的canvas、preview及graySignature均在数组withUnsafeMutableBytes作用域内创建和使用位图上下文；保持原复制范围、DeviceGray插值及画布缓存。真实2745×1365图三轮完整画布、底部500行和512×255签名字节均相同；实时卡片的上游已提供尾部至多500行，沿当前源码分析，滚动交互待实测。
- `LongScreenshotStitcher.append` 先完成原尺寸归一化与静帧签名判定，随后才转换整帧RGBA。实际2745×1365图三组12次调用均unchanged、画布及状态相同，原均值0.79–6.18ms、新均值0.26–0.44ms，命中时跳过14987700字节RGBA构造。Session已在上游跳过过期流帧，方法结果只覆盖进入append的静帧；会话CPU及峰值内存另测。
- `LongScreenshotFrameStream.start` 在Task创建前锁内固定代次，startCapture完成后同锁比较代次并保存stream/连接状态；与stop的递增和清理成对，connected读取也用同一锁。不能把代次快照放到Task内部，也不能把末尾比较和发布拆开，否则停止仍可被旧启动覆盖；快速取消及录制指示灯回落待实机交互。

### 已实测结论（2026-11-24 授权时段，v292 同版本）

- **CPU 基线**（`proc_pid_rusage` 差分，20s 中位）：干净空闲 **0.3%**；岛展开态 0.3%；主面板 0.3%；剪贴板工作台 0.2%；十万条归档静置 0.2%；存储窗 2.4%；传输坞 0.3%；投屏页 0.4%；桌面精灵（静态）0.3%。
- **内存基线**（footprint）：冷启动 90–128MB；主面板 141MB；存储窗落定 **229MB**（打开 1.4s 内 +121~170MB，磁盘索引 plist 解码；关窗后仍常驻 **~120MB**，`DiskIndexStore.shared.snapshot` 是单例）；剪贴板工作台 97MB；十万条归档峰值 **293MB** / 落定 190MB。
- **存储关窗历史现场（v292）**：2026-11-24曾观察到20s+等待，302/577个样本在`Path.contains`。2026-11-27完整阅读当前路径与窗口调用链：地图悬停派发使用矩形，曲面路径按几何/矩形/top复用24项缓存，Voronoi由DiskLayoutStore后台计算；旧「每次命中重建整图」描述已过时。当前安装版关闭耗时待独占时段实测，窗口与快照驻留沿现有实现。
- **文件索引是当前最大单点（已优化）**：144.7 万条 / 177MB 池。原实现每个命中都构造 `path` 串 + `URL` + `lastPathComponent`，短词 `deck`（47 万命中）实测 **19.0s**；改为「字节取 name → 先跑 name 模糊 → path 串惰性构造 → `.all` 不建 URL」+ `FuzzyMatcher` 纯 ASCII 字节快路径后：`deck` **683ms**、多词 `workbuddy skill` 395ms / `kitnest perf` 319ms，命中集不变（22 万例随机对拍 0 不一致、144.7 万条 name 取法与 URL 0 不一致）。改匹配语义（分词 `strcasestr`）会快到 173-204ms 但命中从 3371 掉到 161，**不能**未经产品确认就换。
- `FuzzyMatcher.match` 的慢在 `Array<Character>`（每字符 16B）：127B 路径≈2KB/次。ASCII 快路径实测 **6.3-6.5×**（10 万条 91ms→14ms），非 ASCII 原样回退。
- 搜索是 **250ms 防抖 + detached 任务**：detached 不继承取消，必须 `withTaskCancellationHandler` 显式 `job.cancel()`，`FileNameIndex.search` 里每 8192 条的 `Task.isCancelled` 才会生效。
- **OCR 常驻来自 Vision，不是 PP-OCR**：主进程 `vmmap` 可见 `TextRecognition.framework` 的 `cr_tr_model_cj_v3` 与 ANECompiler；自检日志「识别前 185.2 → Vision 后 243.8 → PP-OCR 后 244.2 → 1.5s 后 242.0MB」= Vision +57MB 常驻，PP-OCR 子进程只 +0.4MB（helper 退出后为 0 个进程）。不要再把 +146MB 记到 PP-OCR 头上。
- **归档渐进索引**：10k 首批 56 条@28ms、完整@165ms；100k 首批 56 条@46ms、完整@1338ms（发布 9 次）、UI 完成 1381ms、末次 rebuild 0ms；峰值 90→293MB，3s 后 189MB、10s 后 154MB。

### 待实测（需要授权时段或人手交互，未测前不准写结论）

- 双屏第二块 +66–70ms 的落点（v292 日志已埋，需双屏抓屏时读）。
- 截图满载 20 样本分布；首次框选事件时延（需真实鼠标）；内存/磁盘压力组合场景。
- 归档表格滚动、剪贴板三栏滚动与搜索（需键入）；桌面精灵轻动/自定义 PNG 三态（需指针交互）。
- 单进程 GPU 归属不可测（ioreg 只有全系统读数）；Instruments 需 Xcode。

### 测量开关（默认关，先开再测）

`probe.islandMaterial`（岛材质 layout 统计）、`probe.motionPacing`（显示时钟节奏）、`probe.glassCoverage`、`probe.reveal`、`probe.genieDuration`。
命令形如 `defaults write com.sxyq.frsetnext probe.islandMaterial -bool true`；测完删键。

### 已知存储事实（2026-11-24 只读核查）

- `images/` 1.0GB 中历史 TIFF 297 张占 989MB，其中 171 张 >1.5MB；重编码（v280）只对新入库 >1.5MB 图生效，**不回溯**。部署（11-22 19:36）后新增 14 张 TIFF 全部 <1.5MB（阈值下正常保留）。
- 真实样张实测：42.1MB TIFF → HEIC 0.90 0.3MB / 219ms；12.7MB → 0.4MB / 77ms（均在持久化串行队列，不在主线程）。
- `quality 0.90` 是**有损**，禁止称"无损/画质不变"。

## 回答结构

按需求分成**已修改（代码）**、**仅增加计时/埋点**、**已取得实测（同版本同条件）**、**尚待用户授权验证**四类。不要把源码修改、编译通过、历史数据和最新实测混为一谈；不要把 CVDisplayLink 回调、orderFront 返回、30fps 屏录、源码索引全绿当实际帧率/功能正确性的证据。
