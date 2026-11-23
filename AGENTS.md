# AGENTS.md — Kitnest 项目指南

## 本工作树：Kitnest Lite

本分支不包含刘海工作台、文件中转、手机投屏和相关传输服务。
当前分支 `variant/without-transfer-cast`，外置 SSD 路径为 `/Volumes/Lexar/Project/frset-rebuild-lite`。
所有源码、Git、构建和发布操作在此工作树执行；下文及项目 Skill 中的完整版绝对路径仅作背景，不用于本分支。
构建部署到 `/Applications/KitnestLite.app`，DMG 输出到本树 `apps/FrsetNext/build.noindex/KitnestLite-1.0.0.dmg`；在线更新执行本树的 `tools/publish_update.sh`。

> 给在本仓库工作的 Agent / 开发者的操作手册。**先读本文再动手。**

## 项目是什么

Kitnest（原名 FrsetNext）：macOS 菜单栏效率工具（arm64，macOS 13+），对原版 Frset 的重建 +
功能增强。模块：剪贴板、搜索与 AI、工具箱、网盘下载助手、
性能监测（STATS 引擎）、标注、使用统计等。

- 源码：`apps/FrsetNext/Sources/`（SwiftUI + AppKit 混合；FrsetStatsBar/ 为 C/ObjC 引擎）
- 构建：`apps/FrsetNext/build.sh`（产物部署到 `/Applications/KitnestLite.app`）
- 打包：`apps/FrsetNext/package_dmg.sh` → 本树 `apps/FrsetNext/build.noindex/KitnestLite-1.0.0.dmg`
- 详细工作流：`docs/00-总览/开发工作流.md`（Git 规范 / 打包 / 安装测试 / 排障速查）

## 铁律（每次改动必走）

1. **改 → 构建 → 验证 → 重生成函数表 → CodeGraph 同步 → git 提交 → 推送 origin → 重打完整版 DMG → 重启 App → 复核 skill/AGENTS.md**，一步不省
   （DMG 指 `package_dmg.sh` 的**完整版**，不是 Lite 变体；Skill/AGENTS 与实际流程不一致时同一次改动里改掉）
2. **每次改完必须提交并推送**：不允许把改动留在工作区过夜。收尾时 `git status --short` 必须为空。
   commit 写清楚：**需求原话 + 改动文件 + 具体改动**（含数值）+ 实测方式
3. **每次改完必须重生成函数表**：`python3 tools/func_table.py`
   （唯一解析器：跨行字符串/块注释按状态剥离，属性访问器体跳读，声明修饰符白名单；
   手工改表会让 owner/行号再次漂移）
   再 `python3 tools/rebuild_ledger.py --strict` 重锚台账（新增函数必须补 `EVIDENCE`，
   缺证据会失败——**不要用占位文案蒙过去**），
   然后 `python3 tools/symbol_index_md.py apps/FrsetNext/Sources docs/00-总览/数据表/FrsetNext-函数清单.csv docs/00-总览/符号索引.md`
   与 `python3 tools/swift_catalog.py`，最后 `python3 tools/reconcile.py` 必须全绿
   （CSV ↔ 审阅台账 ↔ 两份索引文档四步对账，v261 起闸门会区分「行号漂移」与「真缺函数」）
4. **每次改完必须重跑 CodeGraph 索引**：`codegraph sync .`
   （不 sync 时 `codegraph_explore` 会跳过「索引后已改动」的文件，拿不到源码）
5. DMG 版本号**固定 1.0.0 不变**；每次改动后重打（用户分发用）
6. 更新后**本地重启 App**（只退出 Lite 进程，再打开 `/Applications/KitnestLite.app`），
   供用户随时查看效果

11. **启动路径纪律（2026-11-22 「点了打不开」P0 之后新增，违反即视为未完成）**
    - 启动路径（`applicationDidFinishLaunching` 到 `启动完成` 之间）**禁止任何同步 TCC / 同步 XPC / 同步等待**：
      `CGPreflightScreenCaptureAccess`、`CGRequestScreenCaptureAccess`、`AXIsProcessTrusted`、
      `SCShareableContent`、`AVCaptureDevice.authorizationStatus`、`NSAppleScript`、
      `Process.waitUntilExit` 一律改「后台队列查询 → 回主线程发布」。
      tccd 卡住会让 App 在画出第一个界面之前挂死，用户看到的就是“点了没反应”。
    - **单实例判定只能用内核对象**（`InstanceLock` 的 `flock` + pid 文件），不得只用
      `NSRunningApplication.runningApplications(withBundleIdentifier:)`：进程列表在「主线程卡死」
      与「僵尸（defunct）」两种状态下都会说谎，两种情况下旧实现都会让新实例自杀。
    - **禁止无条件 `NSApp.terminate(nil)`**：先判断旧实例是否还活着；不确定时选择**接管**
      （菜单栏重复一秒，比打不开一小时轻）。判活不能只看进程还在——必须看
      `instance.heartbeat`（每 2s 一跳）和锁文件里的 `build=` 构建戳；心跳 >12s 或构建戳不一致
      就接管，杀不掉就无锁启动，不准自杀。
    - 每次构建后必须跑 `bash tools/launch_smoke.sh`：杀掉全部本机 Kitnest 进程 → 冷启动 →
      确认日志出现新的 `启动完成` 且没有 `已有实例在运行` / `应用退出`。**不通过不算改完。**
    - 排查与成因：`docs/00-总览/开发工作流.md` 第六节「启动不了 / 点了没反应 / 卡死」。

7. **窗口目录与函数 CSV 同步维护**：窗口、面板、附属表单、浮层及系统对话框新增、修改、移除，或收到窗口问题反馈时，在同一次改动中更新
   `docs/00-总览/数据表/预览窗口排查.csv`。每个窗口或呈现入口单独一行，记录源码定位、尺寸约束、关闭与状态保留、日期及问题处理；同一窗口沿用编号，移除后保留历史记录，不另建平行目录。源码结论与实际运行结果分开填写，尚未实测就标记待实测。
8. **屏幕录制授权身份固定**：本机部署只用 `build.sh` 声明的 FrsetDev 身份和指定 requirement；缺证书或身份不符就停止，不得退回临时签名。旧身份迁移后，macOS 不会把已有 TCC 记录自动改绑，需对最终安装版重新授权一次；身份固定后构建不得再要求重复授权。勿用 `tccutil reset` 清权限。
9. **整机编译负载有上限**：本机 16GB 内存环境固定 no-WMO、Swift 并发 2、`nice -n 10`；不叠加多个完整构建，不用环境变量恢复全模块优化或无限并发。
10. **外置变体分支随主线同步**：每次主线改完，跑 `bash tools/sync_variant.sh`
    把 main 合入外置盘上的 `variant/without-transfer-cast`（去掉中转与文件传输、保留投屏）。
    变体工作树在 `/Volumes/Lexar/Project/frset-rebuild-lite`，拔盘后 worktree 会变 prunable，
    脚本会自动 `worktree prune` + 重建；合并冲突不自动解决，脚本会列出冲突文件。
    外置盘属「可移除宗卷」，未授权时脚本会在第一步就明确报出来（不是静默跳过）；
    拔盘后 `/Volumes` 里可能留下僵尸挂载点，`ls` 会卡在内核里，脚本已加 5s 超时。
    需要连构建一起做就加 `--build`。

## 项目级 Skill（可复用操作，`.agent/skills/`）

收尾时更新或新增与本次工作对应的 Skill，优先合并进现有内容；项目 Skill 总数最多 10 个，达到上限时合并，不再增加。

| Skill | 用途 | 触发词 |
|---|---|---|
| `frset-release` | 完整发布闭环（构建→提交→打包→重启） | 发布 / 更新 / 改完 / release |
| `frset-verify` | 截图 / 探针 / 深链验证方法 | 验证 / 截图 / 看效果 / 探针 |
| `frset-package-dmg` | DMG 打包与安装测试 | 打包 / dmg / 安装测试 |

## 操作清单（历史做过的全部操作类型）

- **代码修复/功能**：按模块改 Sources → build.sh → 验证 → 提交
- **UI 观感**：间距/圆角/卡片/宽度——改后截图对比（screencapture -l<窗id>，
  玻璃窗发黑就全屏裁剪）
- **行为验证**：深链 `kitnest-lite://…` + defaults 探针（probe.preview /
  probe.openTool，用完删）+ 日志（`~/Library/Application Support/KitnestLite/logs/`）
- **网盘测试**：`kitnest-lite://cloudlink?url=<URL>&action=download` 直驱解析下载，
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
- Lite 深链一律写 `kitnest-lite://`；不要注册完整版协议或接入已移除的传输服务。
- 在线更新（v201）：显示版本 1.0.0 固定，**更新比较只用 `CFBundleVersion` build 号**，每次发版 +1；
  发版一律走 `tools/publish_update.sh`，不要手改 124 上的 `latest.json`；
  App 自签无 APNs，「推送」= 轮询 + 本地通知，别去接推送证书
- Lite 更新清单：`https://calorieai.sxyq27.online/kitnest-site/kitnest/lite/stable/latest.json`。
  发布包目录：124 上 `/srv/calorieai-updates/public/kitnest/releases/lite/`。
  复用现有 Nginx 静态路由；不要改写完整版清单或运行指向公共官网的 `tools/deploy_site.sh`。
