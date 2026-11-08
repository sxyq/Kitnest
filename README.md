# frset-rebuild — Frset 重建工程（Kitnest，原名 FrsetNext）

> 2026-10-14 创建。目标：用**正向 Swift 工程**重建 Frset 的核心体验 + 原生集成 Stats 监测，
> 终止"每个新功能都要逆向注入"的边际成本上升。
> 规格来源：`~/Desktop/Project/frset/`（完整逆向档案——报告/UI 截图/偏好键/补丁点/行为记录）。

## 现状

**Kitnest 已是日常主力**（`/Applications/Kitnest.app`，菜单栏常驻）：
主面板（搜索/日历/剪贴板/中转站）、STATS 部件合并条（12 形态 × 8 模块）、
性能监测独立窗、截图/OCR/长截图/取色、工具箱、悬浮剪贴板、JSON 检视器等。
构建/验收/打包链路齐备（见下）。版本演进与剩余工作见 `docs/90-历史归档/接手清单-剩余工作.md`。

## 目录结构

```
frset-rebuild/
├── README.md                 本文件
├── AGENTS.md                 项目操作手册（改动铁律 / 模块约定）
├── docs/                     文档中心（唯一入口，见 docs/README.md）
│   ├── README.md             导航 + 权威性分级 + 维护规则
│   ├── 00-总览/              工程全图 / 符号索引 / 模块依赖 / 构建 / 工作流
│   ├── 10-规格/              01–21 规格书 + 索引（重建依据与验收标准）
│   ├── 20-产品与对标/        ArcZip、三方项目对标、工具箱/压缩包对照
│   ├── 30-规划/              个性化、悬浮剪贴板、传输与互传
│   ├── 40-审计与核对/        UI 审计、原版功能核对、性能审计、深度阅读、数据表
│   ├── 90-历史归档/          接手清单等只读历史
│   └── assets/screenshots/   实机截图（按版本命名）
├── apps/FrsetNext/           主工程（Swift 源码 + 构建/打包脚本 + 契约）
│   ├── Sources/              全部源码（Core/{Runtime,UI}、Features/<模块>/<子职责>、App）
│   ├── Resources/            本地化与资源
│   ├── build.sh              一键构建（原子部署到 /Applications）
│   ├── check.sh               typecheck + 跨模块耦合自检
│   ├── package_dmg.sh        DMG 打包（~/Desktop/FrsetNext-1.0.0.dmg）
│   └── CONTRACT.md           模块间契约
├── tests/                    行为对照表（原 App vs FrsetNext，对账标准）
├── FRONT/                   品牌官网（纯静态，v214 起；与 App 源码隔离）
│   ├── index.html            hash 路由 7 视图（首页/功能/界面/下载/更新/帮助/安全）
│   ├── assets/               样式、脚本、图标、脱敏后的实机截图
│   └── kitnest/stable/       版本清单快照（部署时从线上刷新）
├── deploy/nginx/             官网 nginx 配置（路径挂载片段 + 独立子域 vhost）
└── tools/                    测绘/自检工具 + publish_update.sh（在线更新一键发版）+ deploy_site.sh（官网部署）
```

## 常用命令

```bash
cd apps/FrsetNext && bash build.sh          # 构建 + 原子部署（日常从这里打开）
./tools/check.sh                            # typecheck + 耦合扫描
cd apps/FrsetNext && bash package_dmg.sh    # 重打 ~/Desktop/Kitnest-1.0.0.dmg（版本号固定）
bash tools/publish_update.sh "更新说明"      # 发版：递增 build → 构建 → 打包 → 上传 124 → 验证
bash tools/deploy_site.sh                   # 部署品牌官网到 124（并幂等更新 nginx 片段）
```

## 核心原则

1. **规格书驱动**：每一处重建，先在 `docs/10-规格/` 写清楚（来源=反汇编/截图/偏好键），再写代码；
2. **行为对照**：与原 App 同操作对账（`tests/` 清单化），行为等价是质量标准；
3. **版本留痕**：每个用户需求一个版本号 + 接手清单记录（v30 起）。

> **交接入口**：`docs/90-历史归档/接手清单-剩余工作.md`。
> 原版侧的完整测绘见 `~/Desktop/Project/frset/界面-机器码对照与缺口清单.md`。
