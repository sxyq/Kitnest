#!/bin/bash
# Kitnest DMG 打包脚本（版本号固定 1.0.0，用户要求「版本号不变」）
# 用法：./package_dmg.sh
# 前置：build.sh 已构建并部署到 /Applications/Kitnest.app
set -e
APP=/Applications/Kitnest.app
OUT=~/Desktop/Kitnest-1.0.0.dmg
STAGE=$(mktemp -d /tmp/frset_dmg.XXXXXX)

[ -d "$APP" ] || { echo "✗ 找不到 $APP（先跑 build.sh）"; exit 1; }
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

cat > "$STAGE/安装说明.txt" <<'TXT'
Kitnest 安装说明
=================

【系统要求】
· Apple 芯片（M 系列）的 Mac
· macOS 13 或更高版本
（本安装包为 arm64 构建，Intel 芯片的 Mac 无法运行）

【安装步骤】
1. 打开本镜像（双击 Kitnest-1.0.0.dmg）
2. 把 Kitnest 图标拖进「应用程序」文件夹
3. 从「应用程序」里启动 Kitnest

【首次打开（重要）】
本应用未经过 Apple 公证（个人开发者签名），直接双击可能提示
「无法验证开发者」/「已损坏」。两种打开方式任选其一：

  方式 A（推荐）：在「应用程序」里**右键点击 Kitnest → 打开**，
                 在弹窗里再点「打开」，之后就能正常双击使用。

  方式 B（命令行）：打开「终端」执行
                 xattr -cr /Applications/Kitnest.app
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
把「应用程序」里的 Kitnest 删除即可；历史数据在
「~/Library/Application Support/FrsetNext」，不需要就一并删除。

—— 来自 Sun 的自用工具，有问题随时找我
TXT

rm -f "$OUT"
hdiutil create -volname "Kitnest 1.0.0" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"

# 挂载校验
VOL=$(hdiutil attach "$OUT" -nobrowse -readonly | tail -1 | awk -F'\t' '{print $NF}')
codesign -v "$VOL/Kitnest.app" && echo "✓ 签名校验通过"
hdiutil detach "$VOL" -quiet
ls -lh "$OUT"
echo "✓ DMG 已打包：$OUT"
