# FrsetNext 文档中心

> 这里是全仓唯一的文档入口。所有规格、规划、审计、对标材料按用途分类存放；
> **不要再往仓库根或 `docs/` 根目录丢散文件。**

## 目录

```
docs/
├── 00-总览/                工程全图、符号索引、模块依赖、构建与工作流
├── 10-规格/                逆向测绘 + 各子系统规格（01–21 + 索引）
├── 20-产品与对标/          ArcZip 能力、第三方项目对标、工具箱对照
│   ├── ArcZip/             立项材料 / 集成规划 / 融入统计 / 用例 / 归档对齐
│   └── 对标/               三项目对照 / 综合对标 / 工具箱 / 压缩包
├── 30-规划/                个性化、悬浮剪贴板、传输与互传（含 LinkSwift）
│   └── 传输/               LinkSwift、投屏重构、互传联盟、窗口识别
├── 40-审计与核对/          UI 一致性、重复实现、原版功能核对、性能审计、深度阅读
│   ├── 数据表/             函数清单、个性化覆盖核对、预览窗排查
│   ├── 原版功能核对/       原版 vs 重建的 CSV/JSON/报告
│   ├── 性能审计/           函数性能台账、调用链、实测报告
│   └── 深度阅读/           按模块的源码深读笔记
├── 90-历史归档/            一次性排查、旧版接手清单（只作追溯）
└── assets/screenshots/     实机截图（按版本命名）
```

## 阅读顺序（新人 / Agent）

1. `00-总览/工程全图.md` → `工程结构与构建.md` → `模块依赖图.md`
2. `10-规格/README.md` → 按模块读 01–21
3. 需要改 UI：`40-审计与核对/UI-一致性审计与规范.md`
4. 需要核对原版功能：`40-审计与核对/原版功能核对/原版功能覆盖核对报告.md`
5. 需要查函数/调用：`00-总览/符号索引.md` + `40-审计与核对/数据表/FrsetNext-函数清单.csv`

## 文档权威性

| 目录 | 定位 | 备注 |
|---|---|---|
| 00-总览 / 10-规格 | **当前权威** | 与源码同步维护 |
| 20-产品与对标 | 参考 | 结论以代码为准，统计数字标注日期 |
| 30-规划 | 参考 | 未落地部分明确标注「待做」 |
| 40-审计与核对 | 证据 / 报告 | CSV 为机器产物，可重跑生成 |
| 90-历史归档 | **只读历史** | 不再代表现状，禁止据此改代码 |

## 维护规则

- 新增文档：先定分类再落盘；文件名用中文短名，不加日期前缀（一次性报告除外）。
- 引用路径一律写**仓库相对路径**（如 `apps/FrsetNext/Sources/Core/Support.swift`）。
- 结论必须可验证：函数/文件/数量要能被 `00-总览/符号索引.md`、
  `40-审计与核对/数据表/FrsetNext-函数清单.csv` 或源码直接对上。
- 机器产物（函数清单、符号索引、审计 CSV）不要手工改；改源码后用
  `apps/FrsetNext/tools/update_function_csv.py` / `tools/symbol_index_md.py` 重新生成。
- 同一主题只保留一份主文档；旧版本移到 `90-历史归档/` 并在文首注明「已被谁取代」。

## 本仓文档校验

```bash
# 1) 文档内引用的路径是否存在（Python 片段，可粘到终端）
python3 - <<'PY'
import pathlib, re
root = pathlib.Path('.')
pat = re.compile(r'(?:docs|apps|tools|tests)/[^\s`)\]（），、；:："\'<>|]+?\.(?:md|csv|swift|py|json|sh|png)')
bad = {}
for p in list(root.glob('docs/**/*.md')) + [root/'AGENTS.md', root/'README.md']:
    for m in pat.findall(p.read_text(encoding='utf-8', errors='ignore')):
        path = m.rstrip('。.,')
        if '*' in path: continue
        if not pathlib.Path(path).exists(): bad.setdefault(str(p), set()).add(path)
print(bad or 'OK')
PY

# 2) 函数清单与源码对齐（改代码后重跑）
python3 apps/FrsetNext/tools/update_function_csv.py
```

## 本次整理（2026-11-03）

- 原 `docs/` 根 26 个散落 md/csv + 顶层 `specs/` 21 份规格 → 按 6 个分类目录归位。
- 旧路径引用（`specs/…`、`docs/screenshots/…`、旧文件名）已批量改写为仓库相对路径。
- `docs/screenshots/` → `docs/assets/screenshots/`，截图按版本保留。
- 历史一次性材料（接手清单、旧扫描报告）移入 `90-历史归档/`，只作追溯。
- 重复内容处理：同一主题的「扫描 → 处置」两份保留在 40 目录（互补关系，不删）；
  互传联盟「调查结论 / 源码级调研」保留两份（结论 vs 源码证据），在各自文首互相引用。
