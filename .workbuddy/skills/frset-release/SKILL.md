---
name: frset-release
description: FrsetNext 完整发布闭环。当用户在 FrsetNext 项目里完成一次代码/功能更改、要求"发布/更新/改完/出包/看效果"时使用。执行固定顺序：构建部署 → 验证 → git 提交（需求+文件）→ 重打 DMG（版本固定 1.0.0）→ 本地重启 App。每步的命令、提交格式与验收标准见正文。
agent_created: true
---

# FrsetNext 发布闭环

FrsetNext（macOS 菜单栏工具）每次更改的固定收尾流程。顺序不可省：**改代码 → 构建部署 → 验证 → git 提交 → 重打 DMG → 本地重启 App**。

## 执行步骤

1. **构建部署**（约 3 分钟，用后台任务跑）：
   ```bash
   /Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/build.sh 2>&1 | grep -E "error:|✗|已部署" | head -6
   ```
   验收：输出含「已部署(原子)」。失败则看 /tmp/frsetnext_build.log 的首个 error。构建期间不要并行编辑源文件（build/ 清理可能打断）。

2. **验证**：按 `frset-verify` skill 的方法截图/探针确认改动生效。

3. **git 提交**（格式必须含需求与文件）：
   ```bash
   git -C /Users/sunyiyang/Desktop/Project/frset-rebuild add -A apps/FrsetNext/Sources
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
   pkill -f "FrsetNext.app/Contents/MacOS/FrsetNext" 2>/dev/null; sleep 2
   open -a /Applications/FrsetNext.app; sleep 5
   open "frsetnext://panel?page=home"
   ```

6. **收尾报备**：简述 改动文件 / 对应需求 / DMG 路径，并附验证截图。

## 参考

- 完整规范与排障：仓库 `docs/00-总览/开发工作流.md`、`AGENTS.md`
- 提交纪律：数值改动写进 message（如 6pt→10pt）；type 用 fix/feat/chore/docs
