#!/bin/bash
# 捆绑 scrcpy 官方 release 到 Resources/bin/scrcpy/（v291，立项 v2 P0）
#
# 用法：tools/bundle_scrcpy.sh [来源目录]
#   来源目录缺省按顺序探测：$1 > ~/.local/share/scrcpy > /opt/homebrew/share/scrcpy
#   （Homebrew 安装无 server 同目录布局时请优先用官方 release zip 解压目录）
#
# 产物（不入库，.gitignore 已排除）：
#   Resources/bin/scrcpy/scrcpy          主二进制（只链系统框架）
#   Resources/bin/scrcpy/scrcpy-server   设备端服务（与二进制同目录，scrcpy 自行定位）
#   Resources/bin/scrcpy/adb             平台工具（universal）
#   Resources/bin/scrcpy/LICENSE 等旁置文件
#
# 运行时：ScreenCastEngine.findScrcpy/findADB 优先用随包路径，缺失时回退
# 工程目录副本 → PATH → Homebrew → SDK（三处全空才提示「未安装投屏组件」）。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # apps/FrsetNext
DEST="$ROOT/Resources/bin/scrcpy"

SRC="${1:-}"
if [ -z "$SRC" ]; then
  for candidate in "$HOME/.local/share/scrcpy" "/opt/homebrew/share/scrcpy"; do
    if [ -x "$candidate/scrcpy" ]; then SRC="$candidate"; break; fi
  done
fi
if [ -z "$SRC" ] || [ ! -x "$SRC/scrcpy" ]; then
  echo "✗ 未找到 scrcpy 来源目录（传参：tools/bundle_scrcpy.sh <release目录>）" >&2
  exit 1
fi

echo "来源：$SRC"
mkdir -p "$DEST"
# 整目录同步（保留 server/图标/LICENSE 布局；删多余以保持随包内容确定）
rsync -a --delete \
  --exclude '.DS_Store' \
  "$SRC/" "$DEST/"

# 校验：server 必须同目录（scrcpy 靠它拉起设备端），adb 一并随包
for f in scrcpy scrcpy-server adb; do
  [ -e "$DEST/$f" ] || { echo "✗ 缺 $f（官方 release 目录应含全部三件）" >&2; exit 1; }
done

# 校验：主二进制不得依赖 bundle 外的非系统 dylib（官方构建满足；Homebrew 构建不满足）
BAD=$(otool -L "$DEST/scrcpy" | awk 'NR>1 {print $1}' | grep -v \
  -e '^/System/Library/' -e '^/usr/lib/' -e '^$' | grep -v '^$' || true)
if [ -n "$BAD" ]; then
  echo "⚠ 二进制依赖 bundle 外 dylib（Homebrew 构建需另拷依赖，建议改用官方 release）：$BAD" >&2
fi

SIZE=$(du -sh "$DEST" | awk '{print $1}')
echo "✓ 已捆绑 ${DEST}（${SIZE}）"
