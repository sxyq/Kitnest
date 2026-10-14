#!/bin/bash
# frset-rebuild 工程根自检入口（薄包装）
#
# 用途：在工程根一键触发 FrsetNext 的全部自检，免去 cd apps/FrsetNext。
#   1) 逐模块 + 全量 typecheck：apps/FrsetNext/check.sh
#   2) 跨模块耦合/接线扫描：apps/FrsetNext/coupling_check.py
#
# 用法：
#   ./tools/check.sh                 # typecheck + 耦合扫描
#   ./tools/check.sh --typecheck     # 只跑 typecheck
#   ./tools/check.sh --coupling      # 只跑耦合扫描
#   ./tools/check.sh Monitor AI      # 透传模块名给 check.sh（只检查指定模块）
#
# 退出码：任一步失败即非 0。
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/FrsetNext"

if [ ! -x "$APP/check.sh" ]; then
  echo "✗ 未找到 $APP/check.sh（或缺可执行权限）"
  exit 1
fi

mode="all"
declare -a passthru=()
for arg in "$@"; do
  case "$arg" in
    --typecheck) mode="typecheck" ;;
    --coupling)  mode="coupling" ;;
    *)           passthru+=("$arg") ;;
  esac
done

rc=0

if [ "$mode" != "coupling" ]; then
  echo "==[1/2] typecheck（apps/FrsetNext/check.sh）=="
  if [ "${#passthru[@]}" -gt 0 ]; then
    "$APP/check.sh" "${passthru[@]}" || rc=1
  else
    "$APP/check.sh" || rc=1
  fi
fi

if [ "$mode" != "typecheck" ]; then
  echo
  echo "==[2/2] 耦合与接线扫描（apps/FrsetNext/coupling_check.py）=="
  if command -v python3 >/dev/null 2>&1; then
    ( cd "$APP" && python3 coupling_check.py ) || rc=1
  else
    echo "⚠ 未找到 python3，跳过耦合扫描"
  fi
fi

echo
if [ "$rc" -eq 0 ]; then
  echo "✅ 自检通过（报告见 apps/FrsetNext/build/）"
else
  echo "❌ 自检存在失败项，详见上方输出与 apps/FrsetNext/build/"
fi
exit "$rc"
