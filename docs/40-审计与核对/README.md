# 40-审计与核对

证据类文档。结论要能对回源码或 CSV；机器产物不要手工编辑。

| 子目录 / 文件 | 内容 | 生成方式 |
|---|---|---|
| `UI-一致性审计与规范.md` | 主题令牌、玻璃分层、圆角/字号规范 | 手写，改 UI 前先读 |
| `2026-10-19-重复实现扫描.md` | 重复实现/死代码/设置双轨扫描 | 一次性报告（历史证据） |
| `2026-10-19-处置方案.md` | 上述问题的分期处置方案 + UI 组件审核 | 一次性报告（历史证据） |
| `数据表/FrsetNext-函数清单.csv` | 全仓函数/属性清单（module,file,owner,kind,name,line,lines,complexity） | `apps/FrsetNext/tools/update_function_csv.py` |
| `数据表/2026-10-20-个性化覆盖核对.csv` | 个性化设置项接入核对 | 一次性 |
| `数据表/预览窗口排查.csv` | 预览窗历史问题台账 | 一次性 |
| `原版功能核对/` | 原版 vs 重建的 CSV/JSON/报告与解析脚本 | `parse_frset_binary.py` / `crosscheck.py` |
| `性能审计/` | 函数性能台账、调用链、实测报告 | `perfast_audit` 系列脚本 |
| `深度阅读/` | 11 份按模块的源码深读（含 symbols.csv） | 手写 + CSV 对账；**结构与行数是测绘时快照**，路径已回填新目录，新增文件未纳入逐函数分析 |

## 对账口径

- 函数清单以 `apps/FrsetNext/Sources/**/*.swift` 为准，正则只认「声明行开大括号」，
  多行签名会漏；因此它是下界，不是全量。
- 符号索引 `docs/00-总览/符号索引.md` 由
  `python3 tools/symbol_index_md.py apps/FrsetNext/Sources <csv> <out>` 生成，
  改代码后与 CSV 一起重跑。
- 原版功能核对里的 `原版-*` 来自原版二进制解析，**不要用重建版数据覆盖**。
