#!/bin/bash
# Kitnest DMG 打包脚本（版本号固定 1.0.0，用户要求「版本号不变」）
# 用法：./package_dmg.sh
# 前置：build.sh 已构建并部署到 /Applications/Kitnest.app
set -e
APP="${KITNEST_PACKAGE_APP:-/Applications/Kitnest.app}"
OUT="${KITNEST_DMG_OUTPUT:-$HOME/Desktop/Kitnest-1.0.0.dmg}"
APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")
APP_DATA_NAME=FrsetNext
if [ "$APP_NAME" = 'Kitnest Island' ]; then APP_DATA_NAME=Kitnest-Island; fi
STAGE=$(mktemp -d /tmp/frset_dmg.XXXXXX)

[ -d "$APP" ] || { echo "✗ 找不到 $APP（先跑 build.sh）"; exit 1; }
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$APP_NAME.app"

cat > "$STAGE/安装说明.txt" <<TXT
$APP_NAME 安装说明
=================

【系统要求】
· Apple 芯片（M 系列）的 Mac
· macOS 13 或更高版本
（本安装包为 arm64 构建，Intel 芯片的 Mac 无法运行）

【安装步骤】
1. 打开本镜像（双击 Kitnest-1.0.0.dmg）
2. 把 $APP_NAME 图标拖进「应用程序」文件夹
3. 从「应用程序」里启动 $APP_NAME

【首次打开（重要）】
本应用未经过 Apple 公证（个人开发者签名），直接双击可能提示
「无法验证开发者」/「已损坏」。两种打开方式任选其一：

  方式 A（推荐）：在「应用程序」里**右键点击 $APP_NAME → 打开**，
                 在弹窗里再点「打开」，之后就能正常双击使用。

  方式 B（命令行）：打开「终端」执行
                 xattr -cr "/Applications/$APP_NAME.app"
                 然后正常双击打开。

【使用中可能请求的系统权限】（按需在 系统设置 → 隐私与安全性 开启）
· 辅助功能 —— 全局快捷键、自动粘贴、合成输入
· 屏幕录制 —— 截图、长截图、屏幕录制、贴图
· 完全磁盘访问（可选）—— 文件搜索范围更广
· 通知 —— 复制/截图等操作的系统提示

【ZIP 打开与压缩】
安装不会更改 ZIP 的默认打开方式。可在新手教程或
「设置 → 常规 → 启动与语言」开启「用 Kitnest 默认打开 ZIP」，
关闭后恢复此前的应用。
压缩文件：访达选中文件 → 右键 → 服务 → 用 Kitnest 压缩。
访达原有的「压缩」菜单保持不变。

【卸载】
把「应用程序」里的 $APP_NAME 删除即可；历史数据在
「~/Library/Application Support/$APP_DATA_NAME」，不需要就一并删除。

—— 来自 Sun 的自用工具，有问题随时找我
TXT
if [ "$APP_NAME" = 'Kitnest Island' ]; then
  cat > "$STAGE/安装说明.txt" <<'TXT'
Kitnest Island · 界面与动效 Demo
==============================

Apple 芯片 Mac，macOS 13 或更高版本。
拖动 Kitnest Island 到「应用程序」后打开。
自签应用首次打开：右键点击 → 打开。

【展示方式】
收起态贴合真实刘海，悬停展开；移开后收回。
首页展示监测、媒体、日历、近期剪贴板、中转、工具与音量组件。
首页、剪贴板、中转为主导航，组件标题可切换到对应展示页。
布局入口展示模拟设置。Esc 或右上角箭头收回。
状态栏 Demo 图标提供展开与退出。

【范围】
只展示黑色界面、页面切换、悬停和按下反馈。
复制、截图、录屏、播放、保存等按钮不执行真实操作。
不采集剪贴板，不操作文件，不启动网络或系统监测。
不更改主版文件关联，不修改主版设置。
旧并行数据目录保留，不由此 Demo 读取或清理。

卸载：删除「应用程序」里的 Kitnest Island 即可。
TXT
fi

rm -f "$OUT"
hdiutil create -volname "$APP_NAME 1.0.0" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"

# 挂载校验
VOL=$(hdiutil attach "$OUT" -nobrowse -readonly -plist | python3 -c 'import plistlib, sys; print(next(e["mount-point"] for e in plistlib.loads(sys.stdin.buffer.read())["system-entities"] if "mount-point" in e))')
codesign -v "$VOL/$APP_NAME.app" && echo "✓ 签名校验通过"
hdiutil detach "$VOL" -quiet
ls -lh "$OUT"
echo "✓ DMG 已打包：$OUT"
