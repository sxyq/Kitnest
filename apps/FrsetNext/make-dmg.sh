#!/bin/bash
# 打包 Kitnest DMG（未签名分发包 + 授权修复脚本）
# 用法：./make-dmg.sh            （直接打包 build/ 里现成的 App）
#       ./make-dmg.sh --build    （先跑一次 build.sh 再打包）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build.noindex/Kitnest.app"

if [ "${1:-}" = "--build" ]; then
  echo "== 先构建 App =="
  "$ROOT/build.sh"
fi
[ -d "$APP" ] || { echo "未找到 $APP —— 先跑 ./build.sh（或 make-dmg.sh --build）"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
STAMP="$(date +%Y%m%d-%H%M)"
STAGE="$ROOT/build.noindex/.dmg-staging"
OUT_DIR="$ROOT/dist.noindex"
OUT="$OUT_DIR/Kitnest-$VERSION-arm64-$STAMP.dmg"

echo "== 组装 DMG 内容（v${VERSION}）=="
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT_DIR"
DIR="$STAGE/Kitnest $VERSION"
mkdir -p "$DIR"
cp -R "$APP" "$DIR/"
ln -s /Applications "$DIR/Applications"
cp "$ROOT/dmg/使用说明.txt" "$DIR/"
cp "$ROOT/dmg/修复Gatekeeper授权.command" "$DIR/"
chmod +x "$DIR/修复Gatekeeper授权.command"

echo "== 生成 DMG =="
hdiutil create -volname "Kitnest $VERSION" -srcfolder "$DIR" -ov -format UDZO -o "$OUT" >/dev/null
SIZE="$(du -h "$OUT" | cut -f1 | tr -d ' ')"
echo
echo "DMG: ${OUT}（${SIZE}）"
echo
echo "提醒：App 用的是自签证书（FrsetDev），没有 Developer ID 签名 ——"
echo "  · 别人下载后 Gatekeeper 会拦，属正常现象"
echo "  · 包内已带《修复Gatekeeper授权.command》：去隔离 + 必要时本机重签"
echo "  · 「使用说明.txt」里也有手动方法（xattr / 右键打开）"
