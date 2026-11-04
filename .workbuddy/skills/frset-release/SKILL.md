---
name: frset-release
description: Kitnest 完整发布闭环 + 在线发版。当用户在 Kitnest 项目里完成一次代码/功能更改、要求"发布/更新/改完/出包/看效果"时使用。本地闭环固定顺序：构建部署 → 验证 → git 提交（需求+文件）→ 重打 DMG（版本固定 1.0.0）→ 本地重启 App；要给用户推新版时再走 publish_update.sh 发版。每步的命令、提交格式与验收标准见正文。
agent_created: true
---

# Kitnest 发布闭环

Kitnest（原名 FrsetNext，macOS 菜单栏工具）每次更改的固定收尾流程。顺序不可省：**改代码 → 构建部署 → 验证 → git 提交 → 重打 DMG → 本地重启 App**。

## 执行步骤

1. **构建部署**（约 3 分钟，用后台任务跑）：
   ```bash
   /Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/build.sh 2>&1 | grep -E "error:|✗|已部署" | head -6
   ```
   验收：输出含「已部署(原子)」。失败则看 /tmp/frsetnext_build.log 的首个 error。构建期间不要并行编辑源文件（build/ 清理可能打断）。

2. **验证**：按 `frset-verify` skill 的方法截图/探针确认改动生效。

3. **git 提交**（格式必须含需求与文件）：
   ```bash
   git -C /Users/sunyiyang/Desktop/Project/frset-rebuild add -A apps/FrsetNext/Sources apps/FrsetNext/Resources docs .workbuddy/skills
   git -C /Users/sunyiyang/Desktop/Project/frset-rebuild commit -q -m "<type>(<scope>): <结论>

   需求（日期 用户原话）：「……」
   改动文件：<路径>
   - 改动 1（含数值）
   实测：<验证方式>"
   ```
   验收：`git log --oneline -1` 可见；`git status --short` 为空。

4. **重打 DMG**（版本固定 1.0.0，用户分发用）：
   ```bash
   /Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/package_dmg.sh
   ```
   验收：输出「✓ DMG 已打包」且签名校验通过。

5. **重启 App**（用户要求：更新后本地重启供随时查看）：
   ```bash
   pkill -f "Kitnest.app/Contents/MacOS/Kitnest" 2>/dev/null; sleep 2
   open -a /Applications/Kitnest.app; sleep 5
   open "kitnest://panel?page=home"
   ```

6. **收尾报备**：简述 改动文件 / 对应需求 / DMG 路径，并附验证截图。

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

「立即更新」整包替换链路（下载 → sha256 → 解压 → 备份 → 替换 → 重启）的排障探针（自清理，测完即净）：

```bash
defaults write com.sxyq.frsetnext probe.updateInstall -bool YES
defaults write com.sxyq.frsetnext probe.updateZip "file:///tmp/xxx.zip"   # 本地 zip
defaults write com.sxyq.frsetnext probe.updateSha "<sha256>"              # 可选，不填跳过校验
# 重启 App 后 3s 自动走整包更新；三键读取后自删，不会循环
```

「发现新版」提示链路的排障探针：把设置 → 关于 的更新源临时指向本地 `file://` 清单（build 写大于当前的值），重启即弹；测完删 `update.feedURL / update.notifiedBuild / update.availableBuild / update.ignoredBuild` 四键恢复。

## 参考

- 完整规范与排障：仓库 `docs/00-总览/开发工作流.md`、`AGENTS.md`
- 提交纪律：数值改动写进 message（如 6pt→10pt）；type 用 fix/feat/chore/docs
