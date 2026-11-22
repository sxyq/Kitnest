# 20-源码实现

按 `apps/FrsetNext/Sources/` 真实目录组织的实现说明。每份 `模块说明.md` 覆盖：
模块职责、真实源码位置、主要类型与关键函数、入口与调用链、数据流与状态、依赖关系、
异常和取消处理、性能边界、需求/测试/修改记录链接。

> **以真实源码为依据。** 历史测绘快照（2026-10-29 基线的逐函数深读）归档在
> [`90-历史归档/深度阅读/`](../90-历史归档/深度阅读/)，行号与结构已漂移，只作补充参考；
> 现行结论以本目录文档与源码为准。
>
> 功能归属映射（源码路径 → feature_id → 本目录文档）唯一维护在
> [`00-总览/源码与文档映射.csv`](../00-总览/源码与文档映射.csv)；函数清单的
> `feature_id`/`doc_path` 两列由 `tools/func_table.py` 据它自动填入。

## 模块导航（feature_id ↔ 源码 ↔ 文档）

| feature_id | 源码路径 | 实现文档 |
|---|---|---|
| APP | `apps/FrsetNext/Sources/App/` | [App/模块说明.md](App/模块说明.md) |
| CORE-UI | `Core/UI/`（主题/玻璃/Toast） | [Core/UI/模块说明.md](Core/UI/模块说明.md)（改 UI 先读 [UI-一致性审计与规范](Core/UI/UI-一致性审计与规范.md)） |
| CORE-MOTION | `Core/Motion/`（神灯/WindowReveal） | [Core/Motion/模块说明.md](Core/Motion/模块说明.md) |
| CORE-RUNTIME | `Core/Runtime/`（日志/个性化/更新/挂钟） | [Core/Runtime/模块说明.md](Core/Runtime/模块说明.md) |
| CORE-SHARED | `Core/ServiceLocator.swift` 等 | 本页「辅助模块」节 |
| CAPTURE | `Features/Capture/`（截图/OCR/工作流/钉图/长截图/图帘） | [Features/Capture/模块说明.md](Features/Capture/模块说明.md) + [Screenshot](Features/Capture/Screenshot/模块说明.md) + [Workflow](Features/Capture/Workflow/模块说明.md) |
| CLIPBOARD | `Features/Clipboard/` | [Features/Clipboard/模块说明.md](Features/Clipboard/模块说明.md) |
| PANEL | `Features/Panel/` | [Features/Panel/模块说明.md](Features/Panel/模块说明.md) |
| PANEL-PREVIEW | `Features/Panel/Preview/` | [Features/Panel/Preview/模块说明.md](Features/Panel/Preview/模块说明.md) |
| PANEL-CLINK | `Features/Panel/CloudLink/` | [Features/Panel/CloudLink/模块说明.md](Features/Panel/CloudLink/模块说明.md) |
| MONITOR | `Features/Monitor/` | [Features/Monitor/模块说明.md](Features/Monitor/模块说明.md) |
| STORAGE | `Features/Monitor/Storage/` | [Features/Monitor/Storage/模块说明.md](Features/Monitor/Storage/模块说明.md) |
| ISLAND | `Features/Island/` | [Features/Island/模块说明.md](Features/Island/模块说明.md) |
| TRANSFER | `Features/TransferDock/` | [Features/TransferDock/模块说明.md](Features/TransferDock/模块说明.md) + [Cast](Features/TransferDock/Cast/模块说明.md) |
| SETTINGS | `Features/Settings/` | [Features/Settings/模块说明.md](Features/Settings/模块说明.md) |
| ONBOARDING | `Features/Onboarding/` | [Features/Onboarding/模块说明.md](Features/Onboarding/模块说明.md) |
| AI | `Features/AI/` | [Features/AI/模块说明.md](Features/AI/模块说明.md) |
| TOOLBOX | `Features/Toolbox/` | [Features/Toolbox/模块说明.md](Features/Toolbox/模块说明.md) |
| ARCHIVE | `Features/Archive/` | [Features/Archive/模块说明.md](Features/Archive/模块说明.md) |
| STATUSBAR | `Features/StatusBar/` | [Features/StatusBar/模块说明.md](Features/StatusBar/模块说明.md) |
| HAPTICS | `Features/Haptics/` | [Features/Haptics/模块说明.md](Features/Haptics/模块说明.md) |
| RECORDING | `Features/Recording/` | [Features/Recording/模块说明.md](Features/Recording/模块说明.md) |
| AUDIO | `Features/Audio/` | [Features/Audio/模块说明.md](Features/Audio/模块说明.md) |
| CODEPREVIEW | `Features/CodePreview/` | [Features/CodePreview/模块说明.md](Features/CodePreview/模块说明.md) |
| FLOATINGBALL | `Features/FloatingBall/` | [Features/FloatingBall/模块说明.md](Features/FloatingBall/模块说明.md) |
| STATSBAR | `FrsetStatsBar/`（ObjC 状态栏宿主） | [FrsetStatsBar/模块说明.md](FrsetStatsBar/模块说明.md) |

## 辅助模块（无独立说明文档，归属映射指向本页）

| feature_id | 源码 | 职责一句话 |
|---|---|---|
| MODELS | `Sources/Models/`（30 文件） | 跨模块共享数据模型（CapturedImage、TransferEntry、DeviceInfo 等） |
| MEMORYHELPER | `Sources/MemoryHelper/`（2 文件） | 内存整理辅助进程（内存压缩/释放由主进程调起） |
| OCRHELPER | `Sources/OCRHelper/`（2 文件） | OCR 辅助进程（Vision 识别由主进程按需调起） |
| MANUAL | `Sources/Features/Manual/`（1 文件） | 内置用户手册视图（内容源在 `FRONT/manual/`） |
| DATABASE | `Sources/Storage/`（Database.swift） | SQLite 数据库层（剪贴板仓库等的落库通道） |

## 从哪里进、到哪里去

- **业务功能入口**：[`10-需求/`](../10-需求/)（NN-规格-<模块>.md）→ 本目录对应模块说明 → 源码
- **界面/窗口入口**：[`00-总览/界面与窗口索引.md`](../00-总览/界面与窗口索引.md) → 本目录模块说明
- **函数/符号入口**：[`00-总览/数据表/FrsetNext-函数清单.csv`](../00-总览/数据表/)（`doc_path` 列直达本文档）→ [`00-总览/符号索引.md`](../00-总览/符号索引.md)
- **修改历史入口**：[`40-修改记录/`](../40-修改记录/)（每模块变更记录，交叉引用）
- **测试证据入口**：[`30-测试/`](../30-测试/)
