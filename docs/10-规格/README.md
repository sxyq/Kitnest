# 规格书索引

> 规格书 = 从逆向档案提炼的"可开发规格"（模板与流程见 `../docs/00-总览/工程全图.md` §2）。
> 上游档案库：`~/Desktop/Project/frset/`（本工程所有规格的来源）。

## 上游档案速查（frset/）

| 档案 | 用途 | 路径 |
|---|---|---|
| 逆向分析报告 | 付费机制/外联接口/补丁方案（逻辑规格首选来源） | `frset/逆向分析报告.md` |
| 遥测与钥匙串排查报告 | 钥匙串三段式/ACL 机制/根治记录（数据模型参考） | `frset/遥测与钥匙串排查报告.md` |
| Pro 界面清理记录 | 设置窗口结构/文案清单（UI 规格参考） | `frset/Pro界面清理记录.md` |
| 性能监测集成规划 v2 | 监测 UI 信息架构（状态栏/面板/设置三层的设计定稿） | `frset/性能监测集成规划-v2.md` |
| UI 实测截图 | 主面板/设置窗/About/面板全段（UI 规格的视觉基准） | `frset/rea-evidence/{ui-probe,deploy-test,final-test,tab-removal}/` |
| 反汇编与分析工具 | da.py/refs.py/rel32scan.py 等（逻辑规格的取证工具） | `frset/rea-evidence/tab-removal/` 与临时反汇编（可重新生成） |
| 偏好键与行为记录 | `defaults read com.maoux.frset` 快照（散见各报告） | `frset/` 各报告 + 本机实机 |

## 规格书清单（全部已建 ✅）

### 总纲与方法论
| 编号 | 规格 | 内容 |
|---|---|---|
| 01 | [功能树与逆向映射总览](01-功能树与逆向映射总览.md) | 全部功能树（18 体系）+ 汇编映射总表 + 调用链 + 逆向待办 |
| 02 | [源码级测绘报告](02-源码级测绘报告.md) | 技术栈全貌 + Swift 元数据测绘 + 工具箱 + 还原工作流（7 步） |

### 模块规格（每份含：类清单 / 数据模型 / 行为 / UI 规格 / **源码骨架** / 还原依据 / 待查 / 验收）
| 编号 | 规格 | 关键内容 | 里程碑 |
|---|---|---|---|
| 03 | [监测区与状态栏](03-规格-监测区与状态栏.md) | Stats 体系映射 + 桥接骨架 + 偏好键 | M1 |
| 04 | [主面板](04-规格-主面板.md) | FloatingPanel（类区实证）+ NSPanel 骨架 + 区段 | M2 |
| 05 | [剪贴板](05-规格-剪贴板.md) | 35 类 6 体系 + schema→模型 + 捕获/去重骨架 | M2 |
| 06 | [截图与OCR](06-规格-截图与OCR.md) | 双通道（Vision/Worker）+ 权限链骨架 | M3 |
| 07 | [设置窗口](07-规格-设置窗口.md) | 5 页签 + SettingsScene 骨架 | M3 |
| 08 | [菜单栏与图标](08-规格-菜单栏与图标.md) | 状态项/Toast/图标缓存骨架 | M3 |
| 09 | [AI 体系](09-规格-AI体系.md) | 协议实证（11 个）+ 适配器骨架 | M4+ |
| 10 | [工具箱与其余](10-规格-工具箱与其余子系统.md) | 工具箱/日历/长截图/钉图/取色器/窗口群 | M4+ |

### 代码骨架分布（"贴近源码还原"的实现锚点）
| 骨架 | 位置 | 对应原始证据 |
|---|---|---|
| `StatsBridge`（注入桥接） | 03 §4.1 | Stats Module/SWidget 体系 |
| `FloatingPanel`（NSPanel） | 04 §4.1 | 类区 `0x10023c000` + 截图行为 |
| `ClipboardManager` / `ClipboardItem` / `dedupeKey` | 05 §5 | Combine 符号 + schema |
| `ScreenshotManager` / `OCRService` | 06 §4 | 类名双通道 + ScreenCaptureKit |
| `SettingsScene` / `SettingsTab` | 07 §3 | 补丁 I 数组实证 + 选择器 `0x1005fd7e8` |
| `StatusBarController` / `FileTypeIconProvider` | 08 §3 | 实机状态项 + 缓存表 |
| `LLMProviderAdapting` 协议族 | 09 §2/4 | **元数据协议实证** |
| `Tool` / `Stitcher` 等 | 10 §A-D | 类清单 + 键 |

> **流程**：先逆向完（01/02 为底）→ 每份规格 → 评审 → 动工；开发中发现不清楚 → 按各规格"待查清单"与 02 号工作流回查原 App。

