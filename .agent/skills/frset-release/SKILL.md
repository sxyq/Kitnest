---
name: frset-release
description: Kitnest 完整发布闭环 + 在线发版。当用户在 Kitnest 项目里完成一次代码/功能更改、要求"发布/更新/改完/出包/看效果"时使用。本地闭环固定顺序：构建部署 → 验证 → 函数表/台账对账 → CodeGraph 同步 → git 提交（需求+文件）→ 推送 origin → 重打**完整版** DMG（版本固定 1.0.0，不是 Lite 变体）→ 本地重启 App → 复核 skill/AGENTS.md；要给用户推新版时再走 publish_update.sh 发版。**零打扰优先（2026-11-24）**：用户在用电脑时，本 Skill 的部署/重启/冷启动闸门/DMG/深链验证一律不自动执行——默认只做无 UI 编译、静态检查、读日志与 git 提交，交付时报告「已准备好构建、未部署」；涉及打断的步骤须用户明确授权后执行。每步的命令、提交格式与验收标准见正文。
agent_created: true
---

# Kitnest 发布闭环

Kitnest（原名 FrsetNext，macOS 菜单栏工具）每次更改的固定收尾流程。顺序不可省：
**改代码 → 构建部署 → 验证 → 函数表/台账对账 → CodeGraph 同步 → git 提交 → 推送 → 重打完整版 DMG → 本地重启 App → 复核 skill/AGENTS.md**。

> **零打扰优先（2026-11-24 修订）**：用户正在使用电脑时，第 1 步部署、第 2 步冷启动闸门、
> 第 5 步 DMG、第 6 步重启、任何会开窗口的验证**都不自动执行**——它们会杀运行实例、覆盖
> `/Applications`、抢前台。默认收尾=无 UI 编译/静态检查/读现有日志 + git 提交，并如实报告
> 「已准备好构建、未部署/未重启」。用户明确授权独占时段后才按下面步骤执行。

## 授权与整机负载

- `build.sh` 固定使用源码中指定的 FrsetDev 签名身份与 requirement；证书缺失或签名身份不符时停止构建，禁止临时签名回退。主程序、helper 与随包动态库共用该证书。
- 更新包解压后由 `AppUpdateChecker.installUpdate` 核验同一 FrsetDev 证书与应用标识，成功才准备替换。`codesign` 内联表达式参数写为 `--test-requirement==<表达式>`；第一个等号分隔命令选项，第二个表示表达式内容。本机既有 Kitnest 通过，系统计算器因身份不同返回 3。
- v30/v32 历史结论：从旧签名身份迁移后，TCC 不会自动改写旧授权记录，最终安装版需重新授权一次；此后保持同一身份，不能每次部署都要求用户授权。不要运行 `tccutil reset`。
- 构建固定 no-WMO、Swift 并发 2、`nice -n 10`。本机 16GB 内存下完整构建不与其他完整构建并发；不得通过环境变量恢复 WMO 或提高并发。
- 外置源码构建用 `KITNEST_BUILD_ROOT` 把中间产物放在 APFS 临时目录，日常只部署 `/Applications/Kitnest.app`。必须并存的短期前后对照结束即删除额外 App；生成资料和 CodeGraph 同步后及时合入本地主线，移除已完成的工作树，继续审阅只保留一棵活动外置树。本地构建不创建备份，收尾清理本次临时包和目录。
- `build.sh` 从暂存包直接部署，结束时自动删除暂存 App 与 OCR 目标文件，不在 `build.noindex` 常留第二个 App；打包仍读取唯一正式安装。
- 部署后查看 `ScreenshotManager` 启动日志中的屏幕录制权限状态；“已获得”且抓帧成功时保持授权状态，不再要求用户重复授权。

## 执行步骤

1. **构建部署**（按本机负载约 3–9 分钟，串行运行）：
   ```bash
   /Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/build.sh 2>&1 | grep -E "error:|✗|已部署" | head -6
   ```
   验收：输出含「已部署(原子)」且签名 requirement 与 `build.sh` 固定值一致。失败则看 /tmp/frsetnext_build.log 的首个 error。构建期间不要并行编辑源文件（build/ 清理可能打断）。

2. **冷启动闸门（仅用户明确授权可打断时执行；默认跳过并如实标注「未跑」）**：
   ```bash
   bash /Users/sunyiyang/Desktop/Project/frset-rebuild/tools/launch_smoke.sh 25
   ```
   它先 `pkill -9 -x Kitnest` 再冷启动，只认**本次新增**的日志行。验收：输出
   「✓ 冷启动通过」且能看到 `获得实例锁` + `启动完成`。

   **为什么必须有这一步**（2026-11-22 P0 复盘）：那天改动全是 UI/性能，收尾只验证了
   「改动生效」，没人从零启动过一次。结果单实例检查把卡死/僵尸的旧实例当成「健康实例」，
   新进程无条件自杀；启动路径上还有两次同步 TCC 查询，tccd 一卡就挂在 `appTools begin`。
   用户侧看到的是「点了 App 打不开」，而且重装都没用。

   失败时不要重试了事，按输出提示抓栈：
   ```bash
   sample $(pgrep -x Kitnest | head -1) 3 -f /tmp/hang.txt
   ```
   并读 `docs/00-总览/开发工作流.md` 第六节「启动不了 / 点了没反应 / 卡死」。
   该文档里还有两条硬纪律：**启动路径禁止同步 TCC/XPC**、**单实例只能用 flock 判定**。

3. **验证**：按 `frset-verify` skill 的方法截图/探针确认改动生效。
   没有辅助功能权限、点不到菜单栏图标时，用 `defaults write com.sxyq.frsetnext probe.openPanel -bool YES`
   让 App 启动 4s 后自动开面板（验完 `defaults delete`）。
   该验证会打开窗口并需重启实例，**同样只在用户授权的独占验证时段执行**。

4. **git 提交**（格式必须含需求与文件）：
   ```bash
   git -C /Users/sunyiyang/Desktop/Project/frset-rebuild add -A apps/FrsetNext/Sources apps/FrsetNext/Resources docs .agent/skills
   git -C /Users/sunyiyang/Desktop/Project/frset-rebuild commit -q -m "<type>(<scope>): <结论>

   需求（日期 用户原话）：「……」
   改动文件：<路径>
   - 改动 1（含数值）
   实测：<验证方式>"
   ```
   验收：`git log --oneline -1` 可见；`git status --short` 为空。

5. **重打 DMG**（版本固定 1.0.0，用户分发用）：
   ```bash
   /Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/package_dmg.sh
   ```
   验收：输出「✓ DMG 已打包」且签名校验通过。

6. **重启 App**（仅用户明确要求重启并已允许打断时执行；默认不执行，改动在用户下次自行重启后生效）：
   ```bash
   pkill -f "Kitnest.app/Contents/MacOS/Kitnest" 2>/dev/null; sleep 2
   open -a /Applications/Kitnest.app; sleep 5
   open "kitnest://panel?page=home"
   ```

7. **收尾报备**：简述 改动文件 / 对应需求 / DMG 路径，并附验证截图。

## 发版给用户（在线更新通道，v201）

上面的闭环只影响本机。要让**已装 Kitnest 的用户**收到更新通知，走 `tools/publish_update.sh`（它会自动 +1 内部 build 号、重新构建打包、上传 124）：

```bash
cd /Users/sunyiyang/Desktop/Project/frset-rebuild
bash tools/publish_update.sh $'[新增] 一句话\n[改进] 一句话\n[修复] 一句话'
```

- 说明按 `[新增] / [改进] / [修复]` 前缀分组，服务端自动生成 WhatsNew 分组清单；
- **必须让 publish_update.sh 自己跑 build.sh**（不要带 `--skip-build` 后手动构建，build 号会对不上）；`--skip-build` 仅限 build 号不变时；
- 脚本收尾自动 curl 验证 124 上的 feed 与 zip（HTTP 200 / 206）；另应完整下载一次核对 sha256 与清单一致；
- 版本口径：显示版本固定 1.0.0，**比较与记账全用 `CFBundleVersion` build 号**；旧 4 位 LAN 二维码在 v200 后失效属预期。

「立即更新」整包替换链路的现有探针只接受 HTTPS 安装包地址及对应的 64 位十六进制 SHA-256；解压后的应用还须通过固定 FrsetDev 身份核验。空摘要或 `file://` 地址会进入原失败提示，不能用来验证成功安装：

```bash
defaults write com.sxyq.frsetnext probe.updateInstall -bool YES
defaults write com.sxyq.frsetnext probe.updateZip "<实际 HTTPS 安装包地址>"
defaults write com.sxyq.frsetnext probe.updateSha "<该安装包的 SHA-256>"
# 重启 App 后 3s 自动走整包更新；三键读取后自删，不会循环
```

更新源同样必须使用 HTTPS；查询日志只记录源主机，不记录路径和查询参数。验证更新提示时使用实际清单及现有手动查询入口，保留用户的更新源和忽略记录。

## 参考

- 完整规范与排障：仓库 `docs/00-总览/开发工作流.md`、`AGENTS.md`
- 提交纪律：数值改动写进 message（如 6pt→10pt）；type 用 fix/feat/chore/docs
