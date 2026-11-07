# tools — 测绘工具箱

> 配合 `docs/10-规格/02-源码级测绘报告.md` 使用。全部工具已在本机验证可用。

| 工具 | 用途 | 用法 |
|---|---|---|
| `swift_fieldmd.py` | 解析 Swift `__swift5_fieldmd`/`__swift5_reflstr` 段：还原类型字段名与类型签名 | `python3 swift_fieldmd.py <arm64-slice> <out.json>` |
| `func_table.py` | **唯一解析器**：重生成函数清单 CSV（跨行字符串/块注释按状态剥离 + 属性访问器跳体 → owner/行号/成员口径不漂移） | `python3 tools/func_table.py`（`--check` 只统计） |
| `symbol_index_md.py` | 把函数清单 CSV 渲染成 `docs/00-总览/符号索引.md` | `python3 tools/symbol_index_md.py apps/FrsetNext/Sources <csv> docs/00-总览/符号索引.md` |
| `swift_catalog.py` | 重生成 `docs/00-总览/模块依赖图.md`（模块规模 + 跨模块顶层类型引用边；成员口径复用 `func_table`） | `python3 tools/swift_catalog.py` |
| `symbol_index.py` | 逐声明 CSV（含结束行/体行数，供深读对账；口径同 `func_table`） | `python3 tools/symbol_index.py apps/FrsetNext/Sources <out.csv>` |
| `reconcile.py` | **三方对账闸门**：CSV ↔ 审阅台账 ↔ 索引/依赖图头部数字，任一处过期立刻报红 | `python3 tools/reconcile.py`（0=全绿） |
| `ui_arch_audit.py` | 全量 UI 组件 / 交互 / 分层画像：生成 `数据表/源文件分层与组件画像.csv`（每文件 31 列），并打印设计令牌采用率等度量；与 `func_table` 同源扫描 | `python3 tools/ui_arch_audit.py`（`--check` 只打印） |
| `check.sh` | typecheck + 跨模块耦合扫描 | `./tools/check.sh` |

> UI / 架构审计的三件产物：`docs/40-审计与核对/全量UI交互与DDD架构审计报告.md`（详细报告）、
> `docs/40-审计与核对/数据表/UI与架构审计清单.csv`（51 条整改 backlog）、
> `docs/40-审计与核对/数据表/源文件分层与组件画像.csv`（生成器产物，勿手改）。

## 关联工具（在 frset/rea-evidence 内）

| 工具 | 位置 | 用途 |
|---|---|---|
| `da.py` | `frset/rea-evidence/tab-removal/` | 反汇编查询：`fstart`/`fwin`/`callers`/`callees`/`win` |
| `refs.py` | 同上 | adrp/add 函数指针引用解析 |
| `find_tabstrings.py` | 同上 | 立即数短字符串扫描（模式见源码） |
| `rel32scan.py` | 同上 | rel32 相对指针扫描（Swift 元数据引用） |
| `inj_kt3.m` | `frset/rea-evidence/keychain-neuter/` | 注入钩子模板：打调用者返回地址（减 ASLR slide）+ API 参数记录 |
| `pro_xref.py` | `frset/rea-evidence/ui-probe/` | 字符串交叉引用批量扫描 |
| `dump_func.py` / `find_callers_multi.py` | 同上 | 函数解剖 / 批量调用者 |

## 生成物

| 文件 | 说明 |
|---|---|
| `frset/rea-evidence/rea-early/frset-metadata-fields.json` | 96 个类型的字段元数据（含 Sentry/PostHog 协议与 Frset 自有协议） |

## 常用前置命令

```bash
# 提取 arm64 薄片（所有分析的基础）
lipo -thin arm64 /Applications/Frset.app/Contents/MacOS/Frset -output /tmp/frset_sym

# 生成反汇编（约 2 分钟，96MB）
otool -tV -arch arm64 /Applications/Frset.app/Contents/MacOS/Frset > /tmp/disasm_live.txt

# demangle
/Library/Developer/CommandLineTools/usr/bin/swift-demangle '$s5Frset16ClipboardManagerC'
```
