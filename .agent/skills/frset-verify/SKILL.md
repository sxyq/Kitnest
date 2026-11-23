---
name: frset-verify
description: Kitnest 改动验证方法集。当需要确认 Kitnest 的 UI/行为改动是否生效时使用——包含窗口截图、defaults 探针、深链唤起、日志核对四类手段与已知坑（玻璃窗捕获发黑、环境变量探针不生效等）。配合 frset-release 发布闭环的验证步骤使用。
agent_created: true
---
# Kitnest 验证方法

确认改动生效的四类手段。UI 改动用截图，行为改动用深链/探针+日志。

## 0. 零打扰验证（用户正在用电脑时必须遵守）

硬约束：**不抢鼠标、不改变前台焦点、不弹出无关窗口打断、不重启/终止 Kitnest**。

- **默认允许**：静态分析、无 UI 编译、读现有日志（第 4 节）、读源码。这些不需要任何窗口。
- **本节及后面所有会创建窗口 / 打开页面 / 录屏 / 重启实例的手段**（`open -g` 深链、
  defaults 探针 + 重启、`screencapture -l`、AX 关窗等）**默认禁止自动执行**——
  「不激活」不等于「不打扰」：`open -g` 与深链仍会弹出新窗口盖在用户屏幕上。
  它们只在**用户明确批准的独占验证时段**使用（开工前先 `git status` 保护未提交改动，
  用完即清理探针键与截图/录屏）。

已批准的独占时段内可用的做法：

```bash
# 1) 启动时只上屏不激活（二选一；probe.noActivate 对已运行实例也即时生效）
open -g -a /Applications/Kitnest.app --args --panel-pin --no-activate
defaults write com.sxyq.frsetnext probe.noActivate -bool true   # 验完删掉

# 2) 深链一律加 -g（只投递 URL，不把 App 带到前台）
open -g "kitnest://paneltoggle?count=2&gap=1.0"
open -g "kitnest://storage?hover=1"

# 3) 只拍/只录目标窗口（被遮挡也能拍，不置前、不录桌面）
screencapture -l<窗id> -o /tmp/shot.png
screencapture -l<窗id> -V 8 -o /tmp/clip.mov
```

- 动画太短录不到：`defaults write com.sxyq.frsetnext probe.genieDuration -float 2.5` 慢放（验完删除）；日志会写「动画 2500ms」证明是同一套动画。
- 液态悬停不能移鼠标：`defaults write … probe.storageHover -bool true` + `kitnest://storage?hover=1`，让压力中心沿最大图块巡航（同一压力场/弹簧），默认关闭。
- 关窗/关 sheet 用 AX 按关闭按钮（不激活、不动鼠标）；`CGEvent.postToPid` 对 SwiftUI 无边框 sheet/`onContinuousHover` 常无效，别当可靠手段。
- 禁止：无 `-g` 的 `open`、`osascript activate`、`NSApp.activate`、真实光标移动、`tccutil reset`。
- 做不到的（真实鼠标手感、触控板震动、Instruments 帧率）如实标注待实测，不用截图/编译成功代替。

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

### 1.1 动效验证（录屏 + 逐帧，2026-11-22 v274；2026-11-23 改为窗口直录优先）

单张截图看不出「有没有动画」——弹簧可能被合并成单帧跳变，也可能被系统「减弱动态效果」吃掉。

```bash
# 首选：只录目标窗口（不录桌面、不打扰）
screencapture -l<窗id> -V 8 -o /tmp/loop.mov
# 仅当用户明确允许录屏区域时才用 -R（会录到该区域里的一切）
# screencapture -x -v -V 8 -R <x>,<y>,<w>,<h> /tmp/loop.mov

rm -rf /tmp/frames && mkdir -p /tmp/frames
ffmpeg -v error -i /tmp/loop.mov -vf fps=30 /tmp/frames/f%04d.png
# 用 PIL 统计目标图标/色块像素：帧间应出现小→大→过冲→稳态，而不是 0→满值
defaults read com.apple.universalaccess reduceMotion   # 1 = 系统已减弱动态效果
```

设置页通知条预览的稳定判据：弹入 77→450→533→586（过冲）→530；隐藏 474→261→0。
若只有 0→满值，先查 `reduceMotion`，再查 `withAnimation` 的两帧是否被合并。
短动画（如神灯 380ms）常短于录制启动：用 `probe.genieDuration` 慢放，日志里的「动画 2500ms」可证明是同一套动画。

## 2. defaults 探针（非交互触发；**会重启实例，仅限已批准的独占时段**）

```bash
defaults write com.sxyq.frsetnext probe.preview -string "text"     # 启动3s后预览首条文本
defaults write com.sxyq.frsetnext probe.openTool -string "qrcode"  # 启动3.5s后打开工具窗
# 下面的 pkill + open 会杀掉运行中的实例，用户在用电脑时禁止：
pkill -f "Kitnest.app/Contents/MacOS/Kitnest"; sleep 2; open -a /Applications/Kitnest.app
# 用完删除：defaults delete com.sxyq.frsetnext probe.preview
```

注意：`launchctl setenv` 环境变量探针对 `open` 启动的 App **不生效**，一律用 defaults 探针。

## 3. 深链唤起（打开页面/驱动功能）

```
kitnest://panel?page=home                 主面板
kitnest://settings?pane=monitor           设置页（monitor / monitor.widgets / about）
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

## 常见坑

- 截图拿不到内容 ≠ 功能坏：先确认窗口 id 对不对、是否被遮挡（被遮挡时**等独占时段**或请用户配合，不要 `osascript` 抢 frontmost）
- 设置类"没生效"：先分清「链路没接」还是「没生效反馈」——后者补 UI 反馈（如关闭项显示「已停用」）
- 网盘下载测试后记得删 ~/Downloads 里的测试文件
