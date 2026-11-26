#!/bin/bash
# Kitnest 一键构建：编译全部 Swift 源码 → 打包 .app → 固定证书签名
set -o pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${FRSETNEXT_SOURCE_ROOT:-$ROOT/Sources}"
# v31（2026-10-18）：构建产物与部署全程原子化。
# 病灶：原先「rm -rf build/Kitnest.app → 原地编译」，且部署用 ditto 覆盖合并——
#   构建/复制的几秒窗口期内，Finder 双击拿到的是半成品 bundle，Gatekeeper 直接报
#   「已损坏，无法打开」（用户实障：连续多次把 app 拖进废纸篓，Trash 里留有
#    `Kitnest.app 13-41-17-539.app` 这类 Finder 重命名副本为证）。
# 编译、签名在暂存包内完成，再原子部署到 /Applications；退出时删除暂存包。
APP_NAME="${KITNEST_APP_NAME:-Kitnest}"
INFO_PLIST="${KITNEST_INFO_PLIST:-$ROOT/Info.plist}"
SIGNING_IDENTITY="2EFBEE27CEFEF9F60C03BA222A972127D9286542"
SIGNING_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
SIGNING_REQUIREMENT="identifier \"$SIGNING_BUNDLE_ID\" and certificate leaf = H\"2efbee27cefef9f60c03ba222a972127d9286542\""
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$SIGNING_IDENTITY"; then
  echo "✗ 缺少固定 FrsetDev 签名证书；为保留屏幕录制授权，本次不构建临时签名包"
  exit 1
fi
# 外置 exFAT 工作树需把 bundle 留在 APFS，避免 AppleDouble 边车文件破坏签名。
BUILD_ROOT="${KITNEST_BUILD_ROOT:-$ROOT/build.noindex}"
# 并行工作台/Lite 构建曾改写共用目标文件；本次暂存与链接输入由同一目录持有。
mkdir -p "$BUILD_ROOT/.staging"
# 2026-11-26（存储治理）：trap 只清「本次」的暂存包；构建被强杀（kill -9 / 断电 /
# 并行抢占）时残留的 kitnest.XXXXXX 没人认领——实测累积过 8 个 ≈ 744MB。
# 启动时先回收超 1 天的旧暂存（正在跑的并行构建不会误伤，它们的 mtime 是新的）。
find "$BUILD_ROOT/.staging" -maxdepth 1 -name "kitnest.*" -type d -mtime +1 \
    -exec rm -rf {} + 2>/dev/null || true
STAGE=$(mktemp -d "$BUILD_ROOT/.staging/kitnest.XXXXXX")
APP="$STAGE/$APP_NAME.app"
BUILD_LOG="$STAGE/build.log"
trap 'cp "$BUILD_LOG" /tmp/frsetnext_build.log; rm -rf "$STAGE"' EXIT
# 同一工作区的并行编辑会使 Swift 读到中途变化的输入；本次编译只读这份暂存输入。
ditto "$SRC" "$STAGE/Sources"
SRC="$STAGE/Sources"
SDK="$(xcrun --show-sdk-path)"

# 优化档位：固定 `-O` + **关闭全模块优化（no-WMO）**，编译并发限制为 2。
# 为什么关 WMO：`-O` 的 whole-module-optimization 会把 120+ 个源文件当成**一个优化单元**，
# 峰值内存比 typecheck 高一个数量级（实测 26.9MB → 310.6MB，11.5×），在本机
# （16GB RAM + swap 已近满）必然被系统 SIGKILL（退出码 137）。
# 关闭 WMO 后 swiftc **逐文件**优化，峰值降到单文件量级；产出的可执行文件功能完全等价，
# 只损失跨文件的少量内联/去虚化机会（对本 App 无感）。
OPT_FLAGS="-O -no-whole-module-optimization"
SWIFT_JOBS=2
BUILD_NICE=10

echo "== 源码统计 =="
find "$SRC" -name '*.swift' -not -name '._*' | wc -l | xargs echo "  Swift 文件:"
find "$SRC" -name '*.swift' -not -name '._*' -exec cat {} + | wc -l | xargs echo "  总行数:"

echo "== 清理 =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP/Contents/Info.plist"

FILES=$(find "$SRC" -name '*.swift' -not -name '._*' \
  -not -path "$SRC/MemoryHelper/*" -not -path "$SRC/OCRHelper/*" \
  | sort | tr '\n' ' ')

echo "== 资源 =="
# 本地化资源必须在**签名前**拷入 bundle：codesign --deep 会对 bundle 整体做签名封印，
# 签完再添加文件会导致签名失效（资源被判定为篡改），故拷贝严格排在签名步骤之前（契约 §10.2）。
if [ -d "$ROOT/Resources" ]; then
  cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"
  find "$APP/Contents/Resources" -name '._*' -delete
  find "$APP/Contents/Resources" -name 'Localizable.strings' | sort | sed 's/^/  打包: /'
else
  echo "  （无 Resources/ 目录，跳过本地化资源打包）"
fi

# ---- 本地 OCR 运行时（ONNX Runtime）----
# 必须**在签名前**拷入 bundle：codesign 之后添加文件会破坏签名封印。
if [ -f "$ROOT/Vendor/ocr/libonnxruntime.dylib" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp "$ROOT/Vendor/ocr/libonnxruntime.dylib" "$APP/Contents/Frameworks/libonnxruntime.dylib"
  echo "  打包 ONNX Runtime: $(du -h "$APP/Contents/Frameworks/libonnxruntime.dylib" | cut -f1)"
else
  echo "  （无 Vendor/ocr/libonnxruntime.dylib，跳过本地 OCR 运行时）"
fi

echo "== 资源预检 =="
# 编译前显式打印 swap 水位：本机 16GB + swap 近满时，任何 -O 编译都可能被 SIGKILL。
# 这里只做「知情」提示，不做硬拦截——硬拦截会把「内存暂时紧张」误判成「不能构建」。
echo "  $(sysctl -n vm.swapusage 2>/dev/null)"
echo "  优化档位: $OPT_FLAGS"
echo "  编译资源: Swift 并发 $SWIFT_JOBS，nice $BUILD_NICE"

echo "== 编译 =="
# 产物目录先清空：若 swiftc 被中途杀死（SIGKILL），可能留下上一次构建的半成品可执行文件，
# 使"产物存在"被误读成"构建成功"。清空后产物在= 本次真编译出了二进制。
rm -f "$APP/Contents/MacOS/$APP_NAME"

# ---- ObjC/C 部件引擎（FrsetStatsBar）：clang 编译为 .o，供 swiftc 链接 ----
# 来源：stats-recon/inject/（注入版同款代码，原样移植；注入入口/hook 已由
# frset_stats_tick.m 替代为普通启停 API）。编译参数与注入版 build-dylib.sh 一致。
OBJC_DIR="$SRC/FrsetStatsBar"
OBJ_DIR="$STAGE/objc"
mkdir -p "$OBJ_DIR"
: > "$BUILD_LOG"   # clang 和 Swift 共用本次日志，结束后写入原日志位置
OBJ_FILES=""
if [ -d "$OBJC_DIR" ]; then
  for f in "$OBJC_DIR"/*.c "$OBJC_DIR"/*.m; do
    [ -f "$f" ] || continue
    obj="$OBJ_DIR/$(basename "${f%.*}").o"
    nice -n "$BUILD_NICE" clang -c "$f" -o "$obj" \
      -isysroot "$SDK" -target arm64-apple-macosx13.0 \
      -I "$ROOT/Vendor/ocr" \
      -fobjc-arc -O1 2>&1 | tee -a "$BUILD_LOG" | tail -5
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
STAMP="$STAGE/build.stamp"
rm -f "$STAMP"; touch "$STAMP"

nice -n "$BUILD_NICE" swiftc $OPT_FLAGS -j "$SWIFT_JOBS" -parse-as-library \
  -sdk "$SDK" -target arm64-apple-macosx13.0 -swift-version 5 \
  -o "$APP/Contents/MacOS/$APP_NAME" $FILES $OBJ_FILES \
  -import-objc-header "$BRIDGE" \
  -lsqlite3 \
  -lIOReport \
  -framework AppKit -framework SwiftUI -framework Combine \
  -framework CoreGraphics -framework CoreImage -framework ImageIO \
  -framework Vision -Xlinker -weak_framework -Xlinker Translation -framework ScreenCaptureKit -framework EventKit \
  -framework ServiceManagement -framework UniformTypeIdentifiers \
  -framework IOKit -framework SystemConfiguration -framework Security \
  -framework AVFoundation -framework CoreMedia \
  -framework QuickLookThumbnailing \
  -framework WebKit 2>&1 | tee -a "$BUILD_LOG" | tail -40
BUILD_RC=${PIPESTATUS[0]}
rm -f "$STAMP"   # 走到这里说明脚本活着，撤掉标记
LOG_BYTES=$(wc -c < "$BUILD_LOG" | tr -d ' ')

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
  echo "  日志 ${LOG_BYTES} 字节 / 产物$( [ -f "$APP/Contents/MacOS/$APP_NAME" ] && echo存在 || echo缺失)"
  echo "  处置：等空闲后重跑（串行更稳），**不要改代码**"
  exit 137
elif [ "$BUILD_RC" -ne 0 ]; then
  echo "✗ 编译失败（退出码 $BUILD_RC，日志 ${LOG_BYTES} 字节），详见 /tmp/frsetnext_build.log"
  exit 1
fi

if [ ! -f "$APP/Contents/MacOS/$APP_NAME" ]; then
  echo "✗ 编译返回 0 但产物缺失，日志 ${LOG_BYTES} 字节，详见 /tmp/frsetnext_build.log"
  exit 1
fi

# ============================================================================
# 内存维护 helper（root LaunchDaemon，2026-10-18）
#
# 必须在主 app 签名之前编译并签名：
#   · 放在 Contents/Library/PrivilegedHelperTools/（launchd 约定的嵌套工具位置）；
#   · 用与主 app 相同的 FrsetDev 证书签名，安装到 /Library/PrivilegedHelperTools 后
#     launchd 才能加载；证书身份稳定 → helper 的 TCC/签名身份不随主 app 重建变化。
# 该 helper 只接受固定命令（version / optimize-memory），不接受调用方传 shell。
# ============================================================================
HELPER_NAME="com.sxyq.frsetnext.memoryhelper"
HELPER_SRC="$ROOT/Sources/MemoryHelper/main.swift"
HELPER_OUT="$APP/Contents/Library/PrivilegedHelperTools/$HELPER_NAME"
if [ -f "$HELPER_SRC" ]; then
  echo "== 内存服务 helper =="
  mkdir -p "$(dirname "$HELPER_OUT")"
  if nice -n "$BUILD_NICE" swiftc -O -j "$SWIFT_JOBS" -sdk "$SDK" -target arm64-apple-macosx13.0 -swift-version 5 \
       -o "$HELPER_OUT" "$HELPER_SRC" 2>&1 | tail -5; then
    if [ -f "$HELPER_OUT" ]; then
      codesign --force -s "$SIGNING_IDENTITY" -i "com.sxyq.frsetnext.memoryhelper" "$HELPER_OUT" 2>&1 | tail -2
      if codesign -v "$HELPER_OUT" 2>/dev/null; then
        echo "  helper 签名 ✓"
      else
        echo "  ⚠ helper 签名失败"
        exit 1
      fi
    else
      echo "  ⚠ helper 编译无产物"
      exit 1
    fi
  else
    echo "  ⚠ helper 编译失败"
    exit 1
  fi
fi

# ============================================================================
# 本地 OCR helper（2026-10-27 v144）
#
# 为什么要有独立可执行文件：ONNX Runtime 在进程内**卸载不了**——实测
# ReleaseSession + dlclose 之后 dyld 镜像里仍在、RSS 一点不降。要让「识别完就还内存」
# 成立，只能让推理跑在一个一次性进程里，跑完退出，内存整块回收。
#
# 必须在主 App 签名之前编译+签名：它被放在 Contents/Helpers/（嵌套代码），
# 主 App 的签名封印包含它；顺序反了会破坏封印。
# ============================================================================
OCR_H_DIR="$SRC/OCRHelper"
OCR_H_OUT="$APP/Contents/Helpers/FrsetOCRHelper"
if [ -f "$OCR_H_DIR/main.swift" ]; then
  echo "== 本地 OCR helper =="
  mkdir -p "$(dirname "$OCR_H_OUT")"
  OCR_OBJ_DIR="$STAGE/ocr"
  mkdir -p "$OCR_OBJ_DIR"
  if ! clang -c "$OBJC_DIR/frset_ocr_onnx.m" -o "$OCR_OBJ_DIR/frset_ocr_onnx.o" \
       -isysroot "$SDK" -target arm64-apple-macosx13.0 -I "$ROOT/Vendor/ocr" \
       -fobjc-arc -O1 2>&1 | tail -5; then
    echo "  ✗ helper 的 ONNX 封装编译失败"
    exit 1
  fi
  if nice -n "$BUILD_NICE" swiftc -O -j "$SWIFT_JOBS" -sdk "$SDK" -target arm64-apple-macosx13.0 -swift-version 5 \
       -o "$OCR_H_OUT" \
       "$OCR_H_DIR/main.swift" "$OCR_H_DIR/LogStub.swift" \
       "$SRC/Features/Capture/OCR/PPOCROCR.swift" \
       "$OCR_OBJ_DIR/frset_ocr_onnx.o" \
       -import-objc-header "$OCR_H_DIR/ocr_bridge.h" \
       -framework AppKit -framework CoreGraphics 2>&1 | tail -10; then
    if [ -x "$OCR_H_OUT" ]; then
      codesign --force -s "$SIGNING_IDENTITY" -i "com.sxyq.frsetnext.ocrhelper" "$OCR_H_OUT" 2>&1 | tail -2
      codesign -v "$OCR_H_OUT" 2>/dev/null && echo "  OCR helper 签名 ✓" || { echo "  ⚠ OCR helper 签名失败"; exit 1; }
      # 冒烟：无参数运行应返回用法错误（退出码 2），证明二进制能启动
      "$OCR_H_OUT" >/dev/null 2>&1; rc=$?
      [ "$rc" -eq 2 ] && echo "  OCR helper 可执行 ✓" || echo "  ⚠ OCR helper 启动异常（退出码 $rc）"
    else
      echo "  ⚠ OCR helper 未产出"
      exit 1
    fi
  else
    echo "  ✗ OCR helper 编译失败"
    exit 1
  fi
fi

# 先签 Frameworks 里的动态库，再签 app——codesign 不会自动签嵌套 dylib，
# 未签名的库在运行时会被系统拒绝加载（本地 OCR 会静默降级回 Vision）。
if [ -f "$APP/Contents/Frameworks/libonnxruntime.dylib" ]; then
  codesign --force -s "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/libonnxruntime.dylib" 2>&1 | tail -2
  codesign -v "$APP/Contents/Frameworks/libonnxruntime.dylib" 2>/dev/null \
    && echo "  ONNX Runtime 签名 ✓" || echo "  ⚠ ONNX Runtime 签名失败"
fi

# v279：发布构建删本地符号（12.3 万条 / 字符串表 25.7MB，占主二进制六成）。
# 必须在签名前做，否则 strip 会让签名失效。保留全局/动态符号，运行与崩溃符号化不受影响。
if [ "${KITNEST_KEEP_SYMBOLS:-0}" != "1" ]; then
  xcrun strip -u -r "$APP/Contents/MacOS/$APP_NAME" 2>&1 | tail -1
  echo "  strip: $(du -h "$APP/Contents/MacOS/$APP_NAME" | cut -f1)"
fi

echo "== 签名 =="
# v30/v32（2026-10-18）：主程序始终使用固定 FrsetDev 身份。旧 TCC 记录在身份迁移
# 后需重新授权一次；之后构建不得改签名身份。
codesign --force -s "$SIGNING_IDENTITY" "$APP" 2>&1 | tail -2
ACTUAL_REQUIREMENT="$(codesign -d --requirements - "$APP" 2>&1 | sed -n 's/^designated => //p')"
if [ "$ACTUAL_REQUIREMENT" != "$SIGNING_REQUIREMENT" ]; then
  echo "✗ 主程序签名身份与已授权身份不符：$ACTUAL_REQUIREMENT"
  exit 1
fi

# 签名有效性必须**显式复核**：codesign 的输出被 tail -2 截断，且「bundle 存在」不等于「已签名」
# （历史踩坑：build/ 下存在一个 MacOS/ 为空、未签名的残件，被误读成构建成功）。
if codesign -v "$APP" 2>/dev/null; then
  SIGN_STATE="已签名 ✓"
else
  SIGN_STATE="未签名或签名无效 ✗"
fi

echo "== 完成 =="
ls -la "$APP/Contents/MacOS/$APP_NAME"
echo "  签名: $SIGN_STATE"
# 资源落地验证：确认 .lproj 进了 bundle
if [ -d "$APP/Contents/Resources" ]; then
  echo "  bundle 内 lproj:"; find "$APP/Contents/Resources" -maxdepth 1 -name '*.lproj' | sort | sed 's/^/    /'
fi
# 收尾自检：把「存在 ≠ 通过」的判据显式化
if [ ! -s "$APP/Contents/MacOS/$APP_NAME" ]; then
  echo "  ⚠ 可执行文件缺失或为空 —— 本次构建未真正产出，**不要**把 build/ 目录存在当作成功"
  exit 1
fi
if [ "$SIGN_STATE" != "已签名 ✓" ]; then
  echo "  ⚠ 签名未通过 —— 产物可能无法运行"
  exit 1
fi
# ============================================================================
# 部署到固定路径 /Applications（2026-10-18 v31：原子部署）
#
# 为什么必须：用户在 Finder 里双击 build/ 下的 app 会踩两个坑——
#   ① 构建过程（二进制重建 + 重签名）的几秒窗口期双击 → 系统报"已损坏"；
#   ② build/ 每次重建后目录项 inode 全变，Finder 旧窗口/旧引用双击报"打不开"。
# /Applications/Kitnest.app 路径稳定，LaunchServices 引用不会失效；
# TCC 授权按 bundle ID + 证书（FrsetDev）记录，与路径无关，部署后保留。
#
# v31 关键：不再直接 ditto 覆盖现有部署（那会在复制期间留下"半成品 bundle"，
# 用户恰好此时双击就报"已损坏"）。改为：
#   ① ditto 到同卷暂存 → ② 暂存重新签名 + 去隔离属性 → ③ 严格校验 →
#   ④ rename 换位（旧版先移开，毫秒级空窗）→ ⑤ 重注册 LaunchServices → ⑥ 再校验最终路径。
# 任一步失败都保留旧版不动，绝不把坏包放到用户双击的路径上。
# app 正在运行时换位仍可完成（进程持旧 inode），下次启动即新版。
# ============================================================================
DEPLOY="/Applications/$APP_NAME.app"
DEPLOY_STAGE="/Applications/.$APP_NAME.app.staging.$$"
DEPLOY_OLD="/Applications/.$APP_NAME.app.old.$$"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ -d "$DEPLOY" ] && pgrep -f "$DEPLOY/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  echo "  ℹ️ 旧版本正在运行——部署完成后退出并重新打开即新版"
fi

rm -rf "$DEPLOY_STAGE"
if ditto "$APP" "$DEPLOY_STAGE" 2>/dev/null; then
  # 复制后校验：签名有效就保持原样——绝不能用 `--deep` 重签，否则会把 helper
  # 的代码身份改成主 app 的 identifier（两个不同可执行文件不应共用身份）。
  # 只有复制导致封印失效时才补签（不带 --deep，helper 保留自身签名）。
  if ! codesign -v --deep --strict "$DEPLOY_STAGE" 2>/dev/null; then
    codesign --force -s "$SIGNING_IDENTITY" "$DEPLOY_STAGE" >/dev/null 2>&1
  fi
  xattr -dr com.apple.quarantine "$DEPLOY_STAGE" 2>/dev/null || true

  if codesign -v --deep --strict "$DEPLOY_STAGE" 2>/dev/null; then
    rm -rf "$DEPLOY_OLD"
    if [ -d "$DEPLOY" ]; then mv "$DEPLOY" "$DEPLOY_OLD" 2>/dev/null || true; fi
    if mv "$DEPLOY_STAGE" "$DEPLOY" 2>/dev/null; then
      rm -rf "$DEPLOY_OLD"
      [ -x "$LSREG" ] && "$LSREG" -f "$DEPLOY" >/dev/null 2>&1 || true
      if codesign -v --deep --strict "$DEPLOY" 2>/dev/null; then
        echo "已部署(原子): ${DEPLOY}（暂存包随构建结束清理）"
      else
        echo "  ⚠ 部署后最终校验失败：$DEPLOY"
      fi
    else
      [ -d "$DEPLOY_OLD" ] && mv "$DEPLOY_OLD" "$DEPLOY"
      echo "  ⚠ 部署换位失败，已回滚旧版"
    fi
  else
    echo "  ⚠ 暂存副本签名校验失败，保留旧版不动：$DEPLOY"
    rm -rf "$DEPLOY_STAGE"
  fi
else
  echo "  ⚠ 部署暂存复制失败（旧版未受影响）"
  rm -rf "$DEPLOY_STAGE"
fi
