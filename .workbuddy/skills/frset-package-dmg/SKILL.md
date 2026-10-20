---
name: frset-package-dmg
description: FrsetNext DMG 打包与安装测试。当需要把 FrsetNext.app 打成可分发的 DMG 安装镜像、或在别的 Mac 上做安装测试时使用。执行 package_dmg.sh 一键脚本（版本固定 1.0.0），含安装说明生成、签名校验、挂载验证，以及 Intel/Apple 芯片、Gatekeeper、权限等安装测试清单。
agent_created: true
---

# FrsetNext DMG 打包与安装测试

## 打包（每次代码更改后都要重打，版本号固定 1.0.0）

前置：build.sh 已构建部署（/Applications/FrsetNext.app 是最新产物）。

```bash
/Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/package_dmg.sh
```

脚本自含：拷贝 App → 生成 安装说明.txt → hdiutil UDZO 压缩 → 挂载 codesign 校验 → 卸载 → 输出 ~/Desktop/FrsetNext-1.0.0.dmg（约 13MB）。

验收：输出「✓ 签名校验通过」+「✓ DMG 已打包」。

## 安装测试清单（发给朋友 / 别的机器）

| 项 | 结论 / 操作 |
|---|---|
| 芯片 | 仅 Apple 芯片 arm64；Intel 机不可用（要 Intel 版需单独构建） |
| 系统 | macOS 13+ |
| 安装 | 打开 dmg → 拖 FrsetNext 进「应用程序」 |
| 首次打开 | 未公证被 Gatekeeper 拦：右键→打开→再点打开；或 `xattr -cr /Applications/FrsetNext.app` |
| 签名 | 自签 FrsetDev；`codesign -v` 通过即可分发 |
| 权限 | 辅助功能 / 屏幕录制 / 完全磁盘访问(可选) / 通知——按需开 |
| 卸载 | 删 App；数据在 ~/Library/Application Support/FrsetNext |

## 手动复核（脚本之外需要再验时）

```bash
hdiutil attach ~/Desktop/FrsetNext-1.0.0.dmg -nobrowse -readonly
codesign -v "/Volumes/FrsetNext 1.0.0/FrsetNext.app"
plutil -p "/Volumes/FrsetNext 1.0.0/FrsetNext.app/Contents/Info.plist" | grep -E "ShortVersion|Identifier|Minimum"
hdiutil detach "/Volumes/FrsetNext 1.0.0" -quiet
```
期望：CFBundleShortVersionString=1.0.0、Identifier=com.sxyq.frsetnext、LSMinimumSystemVersion=13.0。
