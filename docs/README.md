# Kitnest 文档中心

> 这里是全仓唯一的文档入口。所有需求、实现、测试、修改记录按用途分类存放；
> **不要再往仓库根或 `docs/` 根目录丢散文件。**

## 目录（2026-11-23 六分类）

```
docs/
├── 00-总览/                工程全图、构建与工作流、符号索引、模块依赖图、界面与窗口索引
│   └── 数据表/             函数清单、审阅台账、窗口排查、源码与文档映射（机器产物+台账）
├── 10-需求/                当前需求与规格（NN-规格-<模块>.md 01–21）
│   ├── 逆向测绘/           原版功能树与源码级测绘（证据属性，非当前实现描述）
│   ├── 对标参考/           ArcZip / 对标 / 1Capture 竞品材料（不冒充产品要求）
│   └── 规划项/             未落地规划（个性化、悬浮剪贴板、传输与互传）
├── 20-源码实现/            按 apps/FrsetNext/Sources/ 目录组织的模块说明（含 README 导航）
├── 30-测试/                测试方法、测试结果、真机证据（行为对照、原版核对、截图）
├── 40-修改记录/            按模块的变更记录（日期/提交/原因/文件/行为/验证）
├── 90-历史归档/            只读历史：审计报告、性能审计底稿、深度阅读快照、过期材料
└── assets/screenshots/     实机截图（按版本命名）
```

## 阅读顺序（新人 / Agent）

1. `00-总览/工程全图.md` → `工程结构与构建.md`（第 7 节=文档与代码映射规则）→ `模块依赖图.md`
2. `10-需求/README.md` → 按模块读 NN-规格
3. 需要改 UI：`20-源码实现/Core/UI/UI-一致性审计与规范.md`
4. 需要查实现机制：`20-源码实现/README.md`（模块导航表）→ 对应 `模块说明.md`
5. 需要查函数/调用：`00-总览/数据表/FrsetNext-函数清单.csv`（`feature_id`/`doc_path` 列直达文档）
   + `00-总览/符号索引.md`
6. 需要知道改过什么：`40-修改记录/<模块>/变更记录.md`

## 文档权威性

| 目录 | 定位 | 备注 |
|---|---|---|
| 00-总览 / 10-需求 / 20-源码实现 / 40-修改记录 | **当前权威** | 与源码同步维护 |
| 10-需求/对标参考、规划项 | 参考 | 结论以代码为准；未落地部分标注「待做」 |
| 10-需求/逆向测绘 | **证据** | 原版逆向规格保留证据属性，**不直接当作当前实现** |
| 30-测试 | 证据 / 结果 | 区分已有方法 / 已执行 / 未执行 / 真机结果 |
| 00-总览/数据表 | 机器产物 + 台账 | CSV 勿手改；重跑顺序见数据表 README |
| 90-历史归档 | **只读历史** | 不再代表现状，禁止据此改代码 |

## 维护规则

- **一条代码路径只对应一份文档，文档名跟模块走、不跟事件走**（三道门槛见
  `00-总览/工程结构与构建.md` 第 7 节）。新增文档前先问「能不能并进已有那份」。
- 引用路径一律写**仓库相对路径**。结论可验证：函数/文件/数量能被
  `00-总览/数据表/` 的 CSV 或源码直接对上。
- 机器产物改源码后按序重跑（详见 `00-总览/数据表/README.md`）：
  `func_table.py` → `rebuild_ledger.py --strict` → `symbol_index_md.py` → `swift_catalog.py` → `reconcile.py` → `codegraph sync .`
- 同一主题只保留一份主文档；旧版本移 `90-历史归档/` 并在文首注明「已被谁取代」。

## 本仓文档校验

```bash
# 1) 文档内引用的路径是否存在
python3 - <<'PY'
import pathlib, re
root = pathlib.Path('.')
pat = re.compile(r'(?:docs|apps|tools|tests|FRONT)/[^\s`)\]（），、；:："\'<>|]+?\.(?:md|csv|swift|py|json|sh|png)')
bad = {}
for p in list(root.glob('docs/**/*.md')) + [root/'AGENTS.md', root/'README.md']:
    for m in pat.findall(p.read_text(encoding='utf-8', errors='ignore')):
        path = m.rstrip('。.,')
        if '*' in path: continue
        if not pathlib.Path(path).exists(): bad.setdefault(str(p), set()).add(path)
print(bad or 'OK')
PY

# 2) 函数清单与源码对齐（改代码后重跑；唯一解析器在仓库根 tools/）
python3 tools/func_table.py && python3 tools/rebuild_ledger.py --strict
python3 tools/symbol_index_md.py apps/FrsetNext/Sources docs/00-总览/数据表/FrsetNext-函数清单.csv docs/00-总览/符号索引.md
python3 tools/swift_catalog.py && python3 tools/reconcile.py
```

## 整理沿革

- 2026-11-03：docs/ 根 26 个散落文件 + specs/ 21 份规格按 6 分类目录归位。
- 2026-11-22（b974585）：不再按事件建文档；新增文档↔代码映射表与三道门槛。
- **2026-11-23：目录语义重组为「需求/源码实现/测试/修改记录」四类**：
  `10-规格`→`10-需求`（逆向测绘/对标参考/规划项分层归位）；`40-审计与核对` 溶解——
  数据表→`00-总览/数据表`、深度阅读重组进`20-源码实现`后归档 `90-历史归档/深度阅读`、
  带日期审计→`90-历史归档/审计报告`、原版核对与实测→`30-测试`；`40-修改记录` 按模块建档；
  函数 CSV 增 `feature_id`/`doc_path` 列 + `00-总览/源码与文档映射.csv` 唯一归属映射；
  4 个大文件职责拆分（ScreenshotManager/IslandContent/PanelRootView/PersonalizationSettingsPane）。
