---
name: frset-verify
description: Kitnest 改动验证方法集。当需要确认 Kitnest 的 UI/行为改动是否生效时使用——包含窗口截图、defaults 探针、深链唤起、日志核对四类手段与已知坑（玻璃窗捕获发黑、环境变量探针不生效等）。配合 frset-release 发布闭环的验证步骤使用。
agent_created: true
---

# Kitnest 验证方法

确认改动生效的四类手段。UI 改动用截图，行为改动用深链/探针+日志。

## 1. 窗口截图（UI 验证）

```bash
/usr/bin/swift /tmp/winall2.swift        # 列出窗口 id/尺寸/位置
screencapture -x -o -l<窗id> /tmp/shot.png
```
- 玻璃/透明窗（层叠面板、弹窗）按 id 截出来是**黑的** → 改全屏 `screencapture -x /tmp/full.png` 后 `sips` 裁目标区域：
  ```bash
  sips -c <高> <宽> --cropOffset <Y> <X> /tmp/full.png --out /tmp/crop.png
  ```
- 判断对齐/间距：裁左右边缘窄条对比，或目视缩放图
- 截完用 Read 工具查看图片确认效果

## 2. defaults 探针（非交互触发）

```bash
defaults write com.sxyq.frsetnext probe.preview -string "text"     # 启动3s后预览首条文本
defaults write com.sxyq.frsetnext probe.openTool -string "qrcode"  # 启动3.5s后打开工具窗
pkill -f "Kitnest.app/Contents/MacOS/Kitnest"; sleep 2; open -a /Applications/Kitnest.app
# 用完删除：defaults delete com.sxyq.frsetnext probe.preview
```
注意：`launchctl setenv` 环境变量探针对 `open` 启动的 App **不生效**，一律用 defaults 探针。

## 3. 深链唤起（打开页面/驱动功能）

```
kitnest://panel?page=home                 主面板
kitnest://settings?pane=monitor           设置页（monitor / monitor.widgets / about）
kitnest://settings?pane=clipboard.appearance  剪贴板预览字号
kitnest://clipdesk                        独立剪贴板工作台
kitnest://storage                         存储管理（读取现有索引）
kitnest://statistics                      使用统计
kitnest://cloudlink?url=<URL>&action=download   直驱网盘解析下载（测试矩阵用）
kitnest://toast?text=测试                 全局提示
```

## 4. 日志核对

```bash
python3 -c "
import datetime
p=f'/Users/sunyiyang/Library/Application Support/FrsetNext/logs/{datetime.date.today()}.log'
print(''.join(open(p,errors='replace').readlines()[-8:]))"
```
关键词：`已部署` `解析下载` `下载完成` `工具窗已打开` `启动追赶` `show: frame=`。

## 5. 本次入口与任务链

- 剪贴板正文改动用独立工作台搜索已有纯文本、Markdown 和 JSON；主面板失焦会自动收起。字号保存后可在设置页重开核对。
- 存储管理使用现有索引验证目录进退。两指横滑从色块区域开始；带 phase 的触控板与无 phase 的横向滚动都识别，一次手势只切一层（260ms 静默才重新计数）。
- 收藏状态以 SQLite `resource_favorites` 为共享来源；剪贴板另外同步写 `clipboard_items.is_favorite`。核对其他入口时从状态栏「查看收藏…」或命令面板打开收藏窗。
- 悬浮球界面目录复用 `IslandWidget`；显示开关、组件顺序、宽高、格子尺寸、列数、默认页及逐屏记忆均由「设置 → 入口与交互 → 悬浮球」读取。
- 悬浮球从球面拖动，释放后左右贴边，半隐藏露16pt；快捷窗底部箭头切页。关闭刘海入口后再打开媒体、日历等组件，确认共用内容窗仍展示真实业务。临时启用或改布局前记录对应偏好，结束后仅恢复这些键。
- 悬浮球触发截图后，恢复依赖截图取消或动作条关闭回调；不要用固定计时器推断截图结束。
- 在线翻译分别查看 Apple 本机 Provider 与 AI/360 在线 Provider；在线 Provider 首次请求会展示授权说明。仅用成功结果提示里的 Provider 名称确认实际服务。
- 工作流首次打开使用 `kitnest://settings?pane=workflow`；没有保存文件时，示例应直接显示「已保存」，不能因重复生成 UUID 出现未操作的脏草稿。
- Linear 工作流仅 `data.issueCreate.success=true` 作为成功；业务失败沿现有失败步骤提示与重试入口。真实调用需要用户的 Team ID 与凭证。
- 2026-11-21安装版用现有更新探针读取真实发布地址且不提供SHA-256，日志记录提示「更新包缺少有效的 SHA-256 或未使用 HTTPS，已取消安装」，visible=true；探针键读取后自删。

### 屏幕录制授权

```bash
codesign -d --requirements - /Applications/Kitnest.app 2>&1
rg '屏幕录制权限启动实况|权限探测|截图快照冻结完成' "$HOME/Library/Application Support/FrsetNext/logs/$(date +%F).log"
```

- requirement 必须与 `apps/FrsetNext/build.sh` 的固定 FrsetDev 身份一致；身份迁移后的旧 TCC 记录只需对最终安装版重新授权一次。
- `CGPreflightScreenCaptureAccess()` 可能假阴性，结合 `ScreenshotManager.probePermission()` 的真实抓屏结果和实际截图日志判断。
- 不因部署后弹过一次权限提示就重置 TCC；先确认运行包签名身份及真实抓屏结果。

## 常见坑

- 截图拿不到内容 ≠ 功能坏：先确认窗口 id 对不对、是否被遮挡（必要时 `osascript` 把 Kitnest 设为 frontmost 再全屏截）
- 设置类"没生效"：先分清「链路没接」还是「没生效反馈」——后者补 UI 反馈（如关闭项显示「已停用」）
- 网盘下载测试后记得删 ~/Downloads 里的测试文件
