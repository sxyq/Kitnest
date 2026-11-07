# AGENTS.md — Kitnest 项目指南

> 给在本仓库工作的 Agent / 开发者的操作手册。**先读本文再动手。**

## 项目是什么

Kitnest（原名 FrsetNext）：macOS 菜单栏效率工具（arm64，macOS 13+），对原版 Frset 的重建 +
功能增强。模块：剪贴板、文件中转、搜索与 AI、工具箱、网盘下载助手、
性能监测（STATS 引擎）、标注、使用统计等。

- 源码：`apps/FrsetNext/Sources/`（SwiftUI + AppKit 混合；FrsetStatsBar/ 为 C/ObjC 引擎）
- 构建：`apps/FrsetNext/build.sh`（约 3 分钟，产物部署到 `/Applications/Kitnest.app`）
- 打包：`apps/FrsetNext/package_dmg.sh` → `~/Desktop/Kitnest-1.0.0.dmg`
- 详细工作流：`docs/00-总览/开发工作流.md`（Git 规范 / 打包 / 安装测试 / 排障速查）

## 铁律（每次改动必走）

1. **改 → 构建 → 验证 → 重生成函数表 → CodeGraph 同步 → git 提交 → 重打 DMG → 重启 App**，一步不省
2. **每次改完必须提交**：不允许把改动留在工作区过夜。收尾时 `git status --short` 必须为空。
   commit 写清楚：**需求原话 + 改动文件 + 具体改动**（含数值）+ 实测方式
3. **每次改完必须重生成函数表**：`python3 tools/func_table.py`
   （唯一解析器：跨行字符串/块注释按状态剥离，属性访问器体跳读；手工改表会让 owner/行号再次漂移）
   再 `python3 tools/symbol_index_md.py apps/FrsetNext/Sources docs/40-审计与核对/数据表/FrsetNext-函数清单.csv docs/00-总览/符号索引.md`
   与 `python3 tools/swift_catalog.py`，最后 `python3 tools/reconcile.py` 必须全绿
   （CSV ↔ 审阅台账 ↔ 两份索引文档三方对账；v259 起新增函数要同步补台账）
4. **每次改完必须重跑 CodeGraph 索引**：`codegraph sync .`
   （不 sync 时 `codegraph_explore` 会跳过「索引后已改动」的文件，拿不到源码）
5. DMG 版本号**固定 1.0.0 不变**；每次改动后重打（用户分发用）
6. 更新后**本地重启 App**（`pkill … ; open -a /Applications/Kitnest.app`），
   供用户随时查看效果

## 项目级 Skill（可复用操作，`.workbuddy/skills/`）

| Skill | 用途 | 触发词 |
|---|---|---|
| `frset-release` | 完整发布闭环（构建→提交→打包→重启） | 发布 / 更新 / 改完 / release |
| `frset-verify` | 截图 / 探针 / 深链验证方法 | 验证 / 截图 / 看效果 / 探针 |
| `frset-package-dmg` | DMG 打包与安装测试 | 打包 / dmg / 安装测试 |

## 操作清单（历史做过的全部操作类型）

- **代码修复/功能**：按模块改 Sources → build.sh → 验证 → 提交
- **UI 观感**：间距/圆角/卡片/宽度——改后截图对比（screencapture -l<窗id>，
  玻璃窗发黑就全屏裁剪）
- **行为验证**：深链 `kitnest://…` + defaults 探针（probe.preview /
  probe.openTool，用完删）+ 日志（`~/Library/Application Support/FrsetNext/logs/`）
- **网盘测试**：`kitnest://cloudlink?url=<URL>&action=download` 直驱解析下载，
  测完删下载文件
- **设置项生效**：改 Preferences 键后看消费点（采样器/过滤/联动），补「生效反馈」
- **统计埋点**：`StatisticsManager.shared.record(.事件)`（AnalyticsEvent 枚举在
  Storage/Database.swift）
- **打包分发**：package_dmg.sh（含安装说明.txt 与签名校验）

## 关键约定

- 数值改动写进 commit（如 6pt→10pt、≥20→≥101）
- 两套分类枚举勿混用（传感器：扫描层 0温1扇2压3流4功5能 ≠ 名表 0温1压2流3功4能5扇）
- 主题色：涨=红 跌=绿（中式）；强调色 Theme.accent
- 排障用注释写「为什么」（vNN + 日期 + 用户原话），方便回溯
- 版本显示：About 页 displayVersion = 1.0.0；别再改回 1.3.12
- 深链一律写 `kitnest://`（`frsetnext://` 仍在 Info.plist 注册，仅作旧链接兼容；历史归档里的原文不改写）
- 安全基线（v200）：MCP 需 token 且拒绝浏览器 Origin；MCP / WebDAV 只绑 127.0.0.1；
  `LanTransferServer` 刻意对 LAN 开放（手机扫码），**不要**给它加回环绑定；LAN token 为 8 位
- 在线更新（v201）：显示版本 1.0.0 固定，**更新比较只用 `CFBundleVersion` build 号**，每次发版 +1；
  发版一律走 `tools/publish_update.sh`，不要手改 124 上的 `latest.json`；
  App 自签无 APNs，「推送」= 轮询 + 本地通知，别去接推送证书
- 124 上 `/kitnest/` 端点挂在 CalorieAI 官网的 Nginx conf 里：改前先备份，
  `sudo nginx -t` 通过后用 **reload 而非 restart**，并回归验证官网与旧 `/android/stable/latest.json`
