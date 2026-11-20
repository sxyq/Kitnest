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

- 截图拿不到内容 ≠ 功能坏：先确认窗口 id 对不对、是否被遮挡（必要时 `osascript` 把 Kitnest 设为 frontmost 再全屏截）
- 设置类"没生效"：先分清「链路没接」还是「没生效反馈」——后者补 UI 反馈（如关闭项显示「已停用」）
- 网盘下载测试后记得删 ~/Downloads 里的测试文件
