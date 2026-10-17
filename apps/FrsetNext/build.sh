#!/bin/bash
# FrsetNext 一键构建：编译全部 Swift 源码 → 打包 .app → ad-hoc 签名
set -o pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"
APP="$ROOT/build/FrsetNext.app"
SDK="$(xcrun --show-sdk-path)"

# 优化档位：默认 `-O` + **关闭全模块优化（no-WMO）**。
# 为什么关 WMO：`-O` 的 whole-module-optimization 会把 120+ 个源文件当成**一个优化单元**，
# 峰值内存比 typecheck 高一个数量级（实测 26.9MB → 310.6MB，11.5×），在本机
# （16GB RAM + swap 已近满）必然被系统 SIGKILL（退出码 137）。
# 关闭 WMO 后 swiftc **逐文件**优化，峰值降到单文件量级；产出的可执行文件功能完全等价，
# 只损失跨文件的少量内联/去虚化机会（对本 App 无感）。
# 需要极限优化时可覆盖：FRSETNEXT_OPT="-O" ./build.sh   （前提：内存充足）
OPT_FLAGS="${FRSETNEXT_OPT:--O -no-whole-module-optimization}"

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

echo "== 资源预检 =="
# 编译前显式打印 swap 水位：本机 16GB + swap 近满时，任何 -O 编译都可能被 SIGKILL。
# 这里只做「知情」提示，不做硬拦截——硬拦截会把「内存暂时紧张」误判成「不能构建」。
echo "  $(sysctl -n vm.swapusage 2>/dev/null)"
echo "  优化档位: $OPT_FLAGS"

echo "== 编译 =="
# 产物目录先清空：若 swiftc 被中途杀死（SIGKILL），可能留下上一次构建的半成品可执行文件，
# 使"产物存在"被误读成"构建成功"。清空后产物在= 本次真编译出了二进制。
rm -f "$APP/Contents/MacOS/FrsetNext"

# ---- ObjC/C 部件引擎（FrsetStatsBar）：clang 编译为 .o，供 swiftc 链接 ----
# 来源：stats-recon/inject/（注入版同款代码，原样移植；注入入口/hook 已由
# frset_stats_tick.m 替代为普通启停 API）。编译参数与注入版 build-dylib.sh 一致。
OBJC_DIR="$SRC/FrsetStatsBar"
OBJ_DIR="/tmp/frsetnext_objc"
rm -rf "$OBJ_DIR"; mkdir -p "$OBJ_DIR"
: > /tmp/frsetnext_build.log   # 重建日志：clang 段追加写，swiftc 段随后追加
OBJ_FILES=""
if [ -d "$OBJC_DIR" ]; then
  for f in "$OBJC_DIR"/*.c "$OBJC_DIR"/*.m; do
    [ -f "$f" ] || continue
    obj="$OBJ_DIR/$(basename "${f%.*}").o"
    clang -c "$f" -o "$obj" \
      -isysroot "$SDK" -target arm64-apple-macosx13.0 \
      -fobjc-arc -O1 2>&1 | tee -a /tmp/frsetnext_build.log | tail -5
    CLANG_RC=${PIPESTATUS[0]}
    if [ "$CLANG_RC" -ne 0 ] || [ ! -f "$obj" ]; then
      echo "✗ ObjC 编译失败: $f（退出码 $CLANG_RC）"
      exit 1
    fi
    OBJ_FILES="$OBJ_FILES $obj"
  done
  echo "  ObjC/C 目标文件:$OBJ_FILES"
fi
BRIDGE="$OBJC_DIR/FrsetStatsBar.h"

# 进度标记：编译**开始前**写入、结束后删除。
# 用途：若 bash 自身与 swiftc 一起被 SIGKILL（整进程组被杀），下面的三分法不会执行，
# 终端上只会停在「== 编译 ==」而无任何结论——此时本文件是否残留就成了唯一的判据：
#   残留 + 无产物 → 死在编译阶段（进程组被杀），不是代码问题，别改代码
#   已删除+ 无产物 → 编译阶段正常结束却没出产物（真编译失败），去读 build log
STAMP=/tmp/frsetnext_build.stamp
rm -f "$STAMP"; touch "$STAMP"

swiftc $OPT_FLAGS -parse-as-library \
  -sdk "$SDK" -target arm64-apple-macosx13.0 -swift-version 5 \
  -o "$APP/Contents/MacOS/FrsetNext" $FILES $OBJ_FILES \
  -import-objc-header "$BRIDGE" \
  -lsqlite3 \
  -framework AppKit -framework SwiftUI -framework Combine \
  -framework CoreGraphics -framework CoreImage -framework ImageIO \
  -framework Vision -framework ScreenCaptureKit -framework EventKit \
  -framework ServiceManagement -framework UniformTypeIdentifiers \
  -framework IOKit -framework SystemConfiguration \
  -framework AVFoundation -framework CoreMedia 2>&1 | tee -a /tmp/frsetnext_build.log | tail -40
BUILD_RC=${PIPESTATUS[0]}
rm -f "$STAMP"   # 走到这里说明脚本活着，撤掉标记
LOG_BYTES=$(wc -c < /tmp/frsetnext_build.log | tr -d ' ')

# 三分法（实测判据，见 docs/l10n-original-reference/MANIFEST.md 同类「无输出≠通过」原则）：
#   log 0 字节 + 产物空 → 被 SIGKILL（资源竞争域），**不是代码问题**，别去改代码
#   log 有内容 + 产物空 → 真编译失败，读 log 改代码
#   log 有内容 + 产物在 → 通过
# 判据依据：真编译错误必被 2>&1 捕获进 log（>0 字节）；0 字节日志 = 进程没来得及输出就被外部终止。
#
# ⚠️ 本三分法**只在本脚本活着时有效**。若 bash 与 swiftc 一起被杀（整进程组 SIGKILL），
# 下面两条分支都不会打印，终端表现为「停在『== 编译 ==』且无结论」。
# 该情形的判据见上方 $STAMP 标记残留 —— 别把「没输出」读成「不知道发生了什么」。
if [ "$BUILD_RC" -eq 137 ]; then
  echo "⚠ swiftc 被系统终止（退出码 137 = SIGKILL）：资源竞争，非代码问题"
  echo "  日志 ${LOG_BYTES} 字节 / 产物$( [ -f "$APP/Contents/MacOS/FrsetNext" ] && echo存在 || echo缺失)"
  echo "  处置：等空闲后重跑（串行更稳），**不要改代码**"
  exit 137
elif [ "$BUILD_RC" -ne 0 ]; then
  echo "✗ 编译失败（退出码 $BUILD_RC，日志 ${LOG_BYTES} 字节），详见 /tmp/frsetnext_build.log"
  exit 1
fi

if [ ! -f "$APP/Contents/MacOS/FrsetNext" ]; then
  echo "✗ 编译返回 0 但产物缺失，日志 ${LOG_BYTES} 字节，详见 /tmp/frsetnext_build.log"
  exit 1
fi

echo "== 签名 =="
codesign --force --deep -s - "$APP" 2>&1 | tail -2

# 签名有效性必须**显式复核**：codesign 的输出被 tail -2 截断，且「bundle 存在」不等于「已签名」
# （历史踩坑：build/ 下存在一个 MacOS/ 为空、未签名的残件，被误读成构建成功）。
if codesign -v "$APP" 2>/dev/null; then
  SIGN_STATE="已签名 ✓"
else
  SIGN_STATE="未签名或签名无效 ✗"
fi

echo "== 完成 =="
ls -la "$APP/Contents/MacOS/FrsetNext"
echo "  签名: $SIGN_STATE"
# 资源落地验证：确认 .lproj 进了 bundle
if [ -d "$APP/Contents/Resources" ]; then
  echo "  bundle 内 lproj:"; find "$APP/Contents/Resources" -maxdepth 1 -name '*.lproj' | sort | sed 's/^/    /'
fi
# 收尾自检：把「存在 ≠ 通过」的判据显式化
if [ ! -s "$APP/Contents/MacOS/FrsetNext" ]; then
  echo "  ⚠ 可执行文件缺失或为空 —— 本次构建未真正产出，**不要**把 build/ 目录存在当作成功"
  exit 1
fi
if [ "$SIGN_STATE" != "已签名 ✓" ]; then
  echo "  ⚠ 签名未通过 —— 产物可能无法运行"
  exit 1
fi
echo "应用包: $APP"
