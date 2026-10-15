#!/bin/bash
# FrsetNext 一键构建：编译全部 Swift 源码 → 打包 .app → ad-hoc 签名
set -o pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"
APP="$ROOT/build/FrsetNext.app"
SDK="$(xcrun --show-sdk-path)"

echo "== 源码统计 =="
find "$SRC" -name '*.swift' | wc -l | xargs echo "  Swift 文件:"
find "$SRC" -name '*.swift' -exec cat {} + | wc -l | xargs echo "  总行数:"

echo "== 清理 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

FILES=$(find "$SRC" -name '*.swift' | sort | tr '\n' ' ')

echo "== 资源 =="
# 本地化资源必须在**签名前**拷入 bundle：codesign --deep 会对 bundle 整体做签名封印，
# 签完再添加文件会导致签名失效（资源被判定为篡改），故拷贝严格排在签名步骤之前（契约 §10.2）。
if [ -d "$ROOT/Resources" ]; then
  cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"
  find "$APP/Contents/Resources" -name 'Localizable.strings' | sort | sed 's/^/  打包: /'
else
  echo "  （无 Resources/ 目录，跳过本地化资源打包）"
fi

echo "== 编译 =="
swiftc -O -parse-as-library \
  -sdk "$SDK" -target arm64-apple-macosx13.0 -swift-version 5 \
  -o "$APP/Contents/MacOS/FrsetNext" $FILES \
  -lsqlite3 \
  -framework AppKit -framework SwiftUI -framework Combine \
  -framework CoreGraphics -framework CoreImage -framework ImageIO \
  -framework Vision -framework ScreenCaptureKit -framework EventKit \
  -framework ServiceManagement -framework UniformTypeIdentifiers 2>&1 | tee /tmp/frsetnext_build.log | tail -40

if [ ${PIPESTATUS[0]} -ne 0 ]; then
  echo "✗ 编译失败，详见 /tmp/frsetnext_build.log"
  exit 1
fi

echo "== 签名 =="
codesign --force --deep -s - "$APP" 2>&1 | tail -2

echo "== 完成 =="
ls -la "$APP/Contents/MacOS/FrsetNext"
# 资源落地验证：确认 .lproj 进了 bundle 且签名覆盖（签名有效性由上一步 codesign 负责）
if [ -d "$APP/Contents/Resources" ]; then
  echo "  bundle 内 lproj:"; find "$APP/Contents/Resources" -maxdepth 1 -name '*.lproj' | sort | sed 's/^/    /'
fi
echo "应用包: $APP"
