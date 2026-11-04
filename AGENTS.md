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

1. **改 → 构建 → 验证 → git 提交 → 重打 DMG → 重启 App**，一步不省
2. commit 写清楚：**需求原话 + 改动文件 + 具体改动**（含数值）+ 实测方式
3. DMG 版本号**固定 1.0.0 不变**；每次改动后重打（用户分发用）
4. 更新后**本地重启 App**（`pkill … ; open -a /Applications/Kitnest.app`），
   供用户随时查看效果
5. 全仓库收尾时 `git status --short` 必须为空

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
- **行为验证**：深链 `frsetnext://…` + defaults 探针（probe.preview /
  probe.openTool，用完删）+ 日志（`~/Library/Application Support/FrsetNext/logs/`）
- **网盘测试**：`frsetnext://cloudlink?url=<URL>&action=download` 直驱解析下载，
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
