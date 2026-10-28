# frset-rebuild — Frset 重建工程（FrsetNext）

> 2026-10-14 创建。目标：用**正向 Swift 工程**重建 Frset 的核心体验 + 原生集成 Stats 监测，
> 终止"每个新功能都要逆向注入"的边际成本上升。
> 规格来源：`~/Desktop/Project/frset/`（完整逆向档案——报告/UI 截图/偏好键/补丁点/行为记录）。

## 现状

**FrsetNext 已是日常主力**（`/Applications/FrsetNext.app`，菜单栏常驻）：
主面板（搜索/日历/剪贴板/中转站）、STATS 部件合并条（12 形态 × 8 模块）、
性能监测独立窗、截图/OCR/长截图/取色、工具箱、悬浮剪贴板、JSON 检视器等。
构建/验收/打包链路齐备（见下）。版本演进与剩余工作见 `docs/接手清单-剩余工作.md`。

## 目录结构

```
frset-rebuild/
├── README.md                 本文件
├── docs/                     交接与规划（活跃文档）
│   ├── 接手清单-剩余工作.md    ★ 版本演进全记录（v30 → 最新）+ 交接入口
│   ├── 工程全图.md             ★ 逐行级测绘总览（骨架/数据流/域名地图/不变量/风险）
│   ├── 工程全图-符号索引.md     3510 个声明逐条（自动生成，可重跑）
│   ├── deepread/              11 份分模块逐文件逐函数测绘报告
│   ├── 规划-个性化设置.md      待实施规划（P0 待确认范围）
│   └── 工程结构与构建.md       构建系统说明
├── specs/                    规格书（逆向档案提炼，重建依据与验收标准）
├── apps/FrsetNext/           主工程（Swift 源码 + 构建/打包脚本 + 契约）
│   ├── Sources/              全部源码（Core/Features/App）
│   ├── Resources/            本地化与资源
│   ├── build.sh              一键构建（原子部署到 /Applications）
│   ├── check.sh / coupling_check.py   typecheck + 跨模块耦合自检
│   ├── make-dmg.sh + dmg/    DMG 打包（未签名分发 + Gatekeeper 修复脚本）
│   └── CONTRACT.md           模块间契约
├── tests/                    行为对照表（原 App vs FrsetNext，对账标准）
└── tools/                    测绘/自检工具（配合 specs/02）
```

## 常用命令

```bash
cd apps/FrsetNext && bash build.sh          # 构建 + 原子部署（日常从这里打开）
./tools/check.sh                            # typecheck + 耦合扫描
cd apps/FrsetNext && bash make-dmg.sh       # 打 DMG（dist/ 产物，不入 git）
```

## 核心原则

1. **规格书驱动**：每一处重建，先在 `specs/` 写清楚（来源=反汇编/截图/偏好键），再写代码；
2. **行为对照**：与原 App 同操作对账（`tests/` 清单化），行为等价是质量标准；
3. **版本留痕**：每个用户需求一个版本号 + 接手清单记录（v30 起）。

> **交接入口**：`docs/接手清单-剩余工作.md`。
> 原版侧的完整测绘见 `~/Desktop/Project/frset/界面-机器码对照与缺口清单.md`。
