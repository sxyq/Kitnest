# 数据表（机器生成索引 + 人工台账）

本目录是全仓唯一的数据表目录（2026-11-23 自 `00-总览/数据表/` 迁入）。
结论要能对回源码或 CSV；机器产物不要手工编辑。

| 文件 | 内容 | 生成方式 |
|---|---|---|
| `FrsetNext-函数清单.csv` | 全仓函数/属性清单，原八列 `module,file,owner,kind,name,line,lines,complexity` + 2026-11-23 新增 `feature_id,doc_path`（功能归属与实现文档定位） | `python3 tools/func_table.py`（唯一解析器，勿手改） |
| `函数审阅台账.csv` | 逐函数审阅结论（KEEP/UNSURE + 调用点证据） | 人工审阅后维护；行号随 `func_table.py` 重跑重锚（`rebuild_ledger.py --strict`） |
| `预览窗口排查.csv` | 全部自建窗体、附属弹层、系统文件面板与提示框的目录及问题记录（136 行登记） | 随窗口源码改动和用户反馈持续更新（手写） |
| `2026-10-20-个性化覆盖核对.csv` | 个性化设置项接入核对 | 一次性证据（勿扩） |
| `UI与架构审计清单.csv`、`源文件分层与组件画像.csv` | UI 架构审计产物（层级违规/组件切片） | `python3 tools/ui_arch_audit.py` 产出（勿手改） |
| `源码与文档映射.csv` | **功能归属唯一映射**：源码路径前缀 → feature_id → 实现文档（2026-11-23 新增） | 手写维护；`func_table.py` 读它填 `feature_id/doc_path` 两列 |

## 窗口目录维护

- 目录范围：`apps/FrsetNext/Sources/` 中 Swift 与 `FrsetStatsBar/` Objective-C 的窗体创建入口、SwiftUI sheet/popover、系统文件面板和提示框。普通内嵌页面按所属窗口定位；同一窗口类的多个显示器实例不重复登记。
- 2026-11-19 登记 136 行：`W-` 自建窗体 56 行（含面板、覆盖层和隐藏宿主），`P-` 附属弹层 16 行，`F-` 文件选择入口 31 行，`A-` 提示/确认入口 24 行，`S-` 共享系统面板 2 行，`H-` 历史及非活动实现 7 行。一个文件内存在多个呈现入口时分别记录。
- 按「源文件 + 定位符/入口」找到实现；用同一源文件及所属类型/函数查阅 `FrsetNext-函数清单.csv` 和 `函数审阅台账.csv`。定位符中标出的行号是登记时位置，代码变化后一起更新。
- `minSize` 为整窗约束，`contentMinSize/contentMaxSize` 为内容区约束；初始大小与内容加载后的动态大小分别记录，不能只凭 `.resizable` 判断能否改变尺寸。
- 新增、修改、移除窗体或收到相关反馈时，同次更新原行。问题记录追加日期、现象、处理位置及运行结果；同一窗口沿用编号，已移除实现保留历史，不再建立另一份窗口目录。
- 「源码登记日期」与「实测日期与结果」分别维护。当前未运行的入口标记「待实测」；完成真实交互后写入日期、窗口大小和实际行为。

## 对账口径

- 函数清单以 `apps/FrsetNext/Sources/**/*.swift` 为准，由 `tools/func_table.py` 唯一解析：
  多行字符串 / 块注释按状态剥离，属性访问器与闭包初始化器的体跳读，因此
  **getter 内局部 `let` 不计入成员、SQL 字面量里的 `{}` 不污染括号深度**（v259 修）。
- 口径仍有两个已知边界：① 只收 `.swift`，`FrsetStatsBar/` 的 C/ObjC 不在表内；
  ② 函数体内的嵌套函数（如 `func both(...)`）按设计不入表，只算所属的外层函数。
- 符号索引 `docs/00-总览/符号索引.md` 由
  `python3 tools/symbol_index_md.py apps/FrsetNext/Sources docs/00-总览/数据表/FrsetNext-函数清单.csv docs/00-总览/符号索引.md` 生成，
  改代码后与 CSV 一起重跑。
- 三方对账：`python3 tools/rebuild_ledger.py --strict` → `python3 tools/reconcile.py`（函数清单 ↔ 台账 ↔ 符号索引/依赖图数字全部一致为全绿）。
- `feature_id`/`doc_path` 两列由 `func_table.py` 按 `源码与文档映射.csv` 的**最长前缀匹配**自动填入；
  匹配不到的声明两列填 `未映射`（明确标注，不生成不存在的链接）。
  同名重载靠 `file + owner + kind + name` 定位，禁止只按函数名建映射。
- **映射率 ≠ 文档内容正确性（2026-11-24 审计包 03 口径钉死）**：`doc_path` 非空只证明
  「该文件归属于哪份模块说明」，**不证明该函数在文档里有逐条说明**。2026-11-24 抽查
  （12 个 ≥12 行的复杂函数）：6 个符号在所属模块说明中被提及，6 个未提及——属预期，
  模块说明按「结构/链路」组织而非逐函数罗列。`0 未映射`、`reconcile 全绿` 都**不得**
  换算成「文档已逐函数核实」。要求逐函数定位时用 CSV 的 `file+owner+name+line` 回源码，
  不要把 `doc_path` 当精确章节锚点（表里没有章节锚点字段；需要时在 `源码与文档映射.csv`
  单表内扩展，不另造第二套解析器）。
- `func_table.py` 的其余已知边界：`override_symbol` 无参数签名（区分不了同名重载）；
  行数/复杂度来自轻量解析近似。
- 原版功能核对（`docs/30-测试/原版功能核对/`）里的 `原版-*` 来自原版二进制解析，**不要用重建版数据覆盖**。

## 重跑顺序（改源码后）

```bash
python3 tools/func_table.py
python3 tools/rebuild_ledger.py --strict
python3 tools/symbol_index_md.py apps/FrsetNext/Sources docs/00-总览/数据表/FrsetNext-函数清单.csv docs/00-总览/符号索引.md
python3 tools/swift_catalog.py
python3 tools/reconcile.py
codegraph sync .
```
