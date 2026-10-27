#!/bin/bash
# FrsetNext 自检脚本：逐模块 typecheck + 全量 typecheck，并输出报告。
#
# 用法：
#   ./check.sh              # 全量检查（逐模块 + 全量）
#   ./check.sh Monitor      # 只检查指定模块（可多个：./check.sh Monitor AI）
#
# 退出码：全部通过 0，否则 1（模块目录不存在/无 swift 文件时安全跳过）
set -o pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"
OUT="$ROOT/build"
REPORT="$OUT/typecheck-report.txt"

SDK="$(xcrun --show-sdk-path 2>/dev/null)"
if [ -z "$SDK" ]; then
  echo "✗ 无法获取 SDK 路径（xcrun --show-sdk-path 失败）"
  exit 1
fi

TARGET="arm64-apple-macosx13.0"
BRIDGE="$SRC/FrsetStatsBar/FrsetStatsBar.h"
BRIDGE_ARG=""
[ -f "$BRIDGE" ] && BRIDGE_ARG="-import-objc-header $BRIDGE"
SWIFT_VERSION="5"
# 每个模块最多展示的错误行数
ERR_LINES="${ERR_LINES:-15}"

mkdir -p "$OUT"

# 基础源码（Core / Models / Storage）始终参与编译
BASE_FILES=""
for d in Core Models Storage; do
  if [ -d "$SRC/$d" ]; then
    BASE_FILES="$BASE_FILES $(find "$SRC/$d" -name '*.swift' -maxdepth 1 | sort | tr '\n' ' ')"
  fi
done

# App 目录（可能尚未创建，存在才参与全量编译）
APP_FILES=""
if [ -d "$SRC/App" ]; then
  APP_FILES="$(find "$SRC/App" -name '*.swift' | sort | tr '\n' ' ')"
fi

overall=0
module_lines=()

# 清空报告
: > "$REPORT"
{
  echo "FrsetNext typecheck 报告"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "SDK: $SDK"
  echo "target: $TARGET   swift-version: $SWIFT_VERSION"
  echo "================================================================"
} >> "$REPORT"

run_typecheck() {
  # $@ = 参与编译的文件；完整输出写入 $LOG_OUT，退出码写到标准输出首行
  local tmp attempt code=1
  tmp="$(mktemp)"
  for attempt in 1 2 3; do
    # shellcheck disable=SC2086
    # v153：补 ObjC 桥接头（PP-OCR 的 FSPPOCR* 等 C 接口在其中）。此前漏传，
    # 全量检查恒定报 6 处 "cannot find FSPPOCR*"，是脚本缺陷不是代码问题。
    swiftc -typecheck -sdk "$SDK" -target "$TARGET" -swift-version "$SWIFT_VERSION" \
      ${BRIDGE_ARG:-} "$@" > "$tmp" 2>&1
    code=$?   # 紧跟 swiftc 捕获退出码（注意：for 循环中的 break 会把 $? 吞成 0，不能循环后再取）
    # 并行开发时文件可能被同伴改写：swiftc 报 "was modified during the build" 时重试一次
    if ! grep -q "was modified during the build" "$tmp"; then break; fi
    sleep 1
  done
  echo "$code"
  cat "$tmp"
  : > "$LOG_OUT"
  cat "$tmp" >> "$LOG_OUT"
  rm -f "$tmp"
}

check_module() {
  local module="$1"
  local dir="$SRC/Features/$module"
  local files
  files="$(find "$dir" -name '*.swift' | sort | tr '\n' ' ')"

  if [ ! -d "$dir" ]; then
    module_lines+=("SKIP    $module  (目录不存在)")
    { echo "[SKIP] $module — 目录不存在"; echo; } >> "$REPORT"
    return 0
  fi
  if [ -z "$(echo "$files" | tr -d ' ')" ]; then
    module_lines+=("SKIP    $module  (无 swift 文件)")
    { echo "[SKIP] $module — 无 swift 文件"; echo; } >> "$REPORT"
    return 0
  fi

  local output code
  LOG_OUT="$OUT/errors-$module.log"
  # shellcheck disable=SC2086
  output="$(run_typecheck $BASE_FILES $files)"
  code="$(echo "$output" | head -1)"
  local body
  body="$(echo "$output" | tail -n +2)"

  echo "----------------------------------------------------------------" >> "$REPORT"
  if [ "$code" -eq 0 ]; then
    module_lines+=("PASS    $module")
    {
      echo "[PASS] $module"
      echo "  文件数: $(echo "$files" | wc -w | tr -d ' ')"
    } >> "$REPORT"
    [ -n "$body" ] && { echo "  （警告）"; echo "$body" | head -"$ERR_LINES"; } >> "$REPORT"
  else
    # v153：逐模块编译只喂 Core+Models+Storage+本模块，跨模块引用（RenderProbe → PanelController
    # 等）必然找不到——这类错误不算回归，仅供定位；退出码只看下面的「全量」。
    local errcount
    errcount="$(echo "$body" | grep -c 'error:')"
    module_lines+=("参考    $module  (${errcount} 处，多为跨模块缺失)")
    {
      echo "[FAIL] $module  —  ${errcount} 处 error"
      echo "  完整错误: build/errors-$module.log"
      echo "$body" | head -"$ERR_LINES"
    } >> "$REPORT"
  fi
  echo >> "$REPORT"
  return 0
}

# 收集模块列表：传参优先，否则自动扫描
if [ "$#" -gt 0 ]; then
  modules=("$@")
else
  modules=()
  if [ -d "$SRC/Features" ]; then
    while IFS= read -r line; do modules+=("$line"); done < <(find "$SRC/Features" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
  fi
fi

echo "== 逐模块 typecheck =="
echo "基础源码: Core + Models + Storage"
echo

if [ "${#modules[@]}" -eq 0 ]; then
  echo "（未发现任何 Features 模块）"
fi

for m in "${modules[@]}"; do
  printf '  检查 %-12s ... ' "$m"
  before=${#module_lines[@]}
  check_module "$m"
  echo "${module_lines[$before]}"
done

# 全量检查
echo
echo "== 全量 typecheck（Core + Models + Storage + Features/** + App）=="
ALL_FILES="$BASE_FILES"
if [ -d "$SRC/Features" ]; then
  ALL_FILES="$ALL_FILES $(find "$SRC/Features" -name '*.swift' | sort | tr '\n' ' ')"
fi
if [ -n "$(echo "$APP_FILES" | tr -d ' ')" ]; then
  ALL_FILES="$ALL_FILES $APP_FILES"
else
  echo "  （App 目录不存在，已跳过）"
fi

LOG_OUT="$OUT/errors-ALL.log"
out="$(run_typecheck $ALL_FILES)"
code="$(echo "$out" | head -1)"
body="$(echo "$out" | tail -n +2)"

{
  echo "================================================================"
  echo "全量 typecheck（含 Features/** $( [ -n "$(echo "$APP_FILES" | tr -d ' ')" ] && echo '+ App/' || echo '，App 已跳过')）"
} >> "$REPORT"

if [ "$code" -eq 0 ]; then
  echo "  PASS"
  {
    echo "[PASS] 全量"
    [ -n "$body" ] && { echo "  （警告）"; echo "$body" | head -"$ERR_LINES"; }
  } >> "$REPORT"
  full_line="PASS    全量"
else
  overall=1
  errcount="$(echo "$body" | grep -c 'error:')"
  echo "  FAIL（${errcount} 处错误）"
  {
    echo "[FAIL] 全量 — ${errcount} 处 error"
    echo "  完整错误: build/errors-ALL.log"
    echo "$body" | head -"$ERR_LINES"
  } >> "$REPORT"
  full_line="FAIL    全量 (${errcount} 处错误)"
fi

# 汇总
{
  echo
  echo "================================================================"
  echo "汇总"
  for line in "${module_lines[@]}"; do echo "  $line"; done
  echo "  $full_line"
  echo
  if [ "$overall" -eq 0 ]; then
    echo "结论：全部通过 ✅"
  else
    echo "结论：存在失败项 ❌（见上方错误摘录，完整日志可重跑单模块查看）"
  fi
} >> "$REPORT"

echo
echo "================ 汇总 ================"
for line in "${module_lines[@]}"; do echo "  $line"; done
echo "  $full_line"
echo "======================================"
echo "报告已写入: $REPORT"

exit "$overall"
