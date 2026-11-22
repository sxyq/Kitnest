#!/bin/bash
# 冷启动闸门（2026-11-22「点了打不开」P0 之后新增）
#
# 用法：bash tools/launch_smoke.sh [超时秒数，默认 25]
#
# 它验的不是「改动生效」，而是一件更基本的事：**这台机器现在真的能把 App 起起来**。
# 顺序刻意做成「先杀干净再启动」——被杀掉的进程可能变成僵尸，而这正是
# 2026-11-22 那次打不开的现场：旧实例不省人事 → 新实例每次都「已有实例在运行 → 退出」。
#
# 通过条件（全部满足）：
#   1) 本次启动之后，日志出现**新的**「启动完成」；
#   2) 本次启动之后，日志出现「获得实例锁」；
#   3) 本次启动之后，日志**没有**「已有实例在运行」或「应用退出」。
set -uo pipefail

TIMEOUT="${1:-25}"
APP="/Applications/Kitnest.app"
LOG_DIR="$HOME/Library/Application Support/FrsetNext/logs"
LOG="$LOG_DIR/$(date +%Y-%m-%d).log"

[ -d "$APP" ] || { echo "✗ 找不到 $APP（先跑 build.sh）"; exit 1; }
mkdir -p "$LOG_DIR"

# 起点：先记日志行数，之后只认新增部分（日志是跨实例共用的，历史「启动完成」不能当本次通过）
BEFORE=0
[ -f "$LOG" ] && BEFORE=$(wc -l < "$LOG" | tr -d ' ')

echo "== 冷启动冒烟 =="
echo "  日志起点：第 $BEFORE 行"
echo "  结束全部 Kitnest 进程（含卡死/僵尸，这正是要验证的场景）"
# pkill 在受限环境（沙箱/无辅助功能）里可能枚举不到别的进程，
# 所以再补一条：直接按 instance.lock 里记录的 pid 杀，直到锁真能抢到为止。
pkill -9 -x Kitnest 2>/dev/null
LOCK="$HOME/Library/Application Support/FrsetNext/instance.lock"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.3
  PID=$(head -1 "$LOCK" 2>/dev/null | tr -dc '0-9')
  [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null
  if python3 - "$LOCK" <<'PY'
import fcntl, sys, os
p = sys.argv[1]
try:
    f = open(p, "a+")
except OSError:
    sys.exit(0)          # 文件都没有，当然算空闲
try:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    sys.exit(0)          # 抢到了 → 空闲
except OSError:
    sys.exit(1)          # 还被占着
PY
  then break; fi
done
sleep 1

# 结束不掉旧实例时，绝不能报「App 有病」——那是环境的锅（沙箱/权限不让 pkill）。
# 这种情况用退出码 2 表示「跳过」，让调用方知道结论无效。
if ! python3 - "$LOCK" <<'PY'
import fcntl, sys
try:
    f = open(sys.argv[1], "a+")
except OSError:
    sys.exit(0)
try:
    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    sys.exit(0)
except OSError:
    sys.exit(1)
PY
then
  echo "⚠ 跳过：仍有一个活着的实例握着实例锁，当前环境结束不掉它（沙箱/权限）"
  echo "   这不算失败。请在普通「终端」里重跑："
  echo "     pkill -9 -x Kitnest; bash tools/launch_smoke.sh 25"
  exit 2
fi

echo "  启动 $APP"
open -n "$APP" || { echo "✗ open 失败"; exit 1; }

DEADLINE=$(( $(date +%s) + TIMEOUT ))
OK_START=0
OK_LOCK=0
BAD=""

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 0.5
  [ -f "$LOG" ] || continue
  NEW=$(tail -n +"$((BEFORE + 1))" "$LOG" 2>/dev/null)
  case "$NEW" in *"启动完成"*) OK_START=1 ;; esac
  case "$NEW" in *"获得实例锁"*) OK_LOCK=1 ;; esac
  if printf '%s' "$NEW" | grep -qE "已有实例在运行|应用退出"; then
    BAD=$(printf '%s' "$NEW" | grep -E "已有实例在运行|应用退出" | tail -2)
  fi
  if [ "$OK_START" = 1 ] && [ "$OK_LOCK" = 1 ]; then break; fi
done

echo
if [ "$OK_START" = 1 ] && [ "$OK_LOCK" = 1 ] && [ -z "$BAD" ]; then
  echo "✓ 冷启动通过：已拿到实例锁并完成启动"
  printf '%s' "$(tail -n +"$((BEFORE + 1))" "$LOG" | grep -E "获得实例锁|启动完成" | head -3)" | sed 's/^/    /'
  echo
  PIDS=$(pgrep -x Kitnest | tr '\n' ' ')
  echo "  运行中 pid：${PIDS:-（无）}"
  exit 0
fi

echo "✗ 冷启动失败"
[ -n "$BAD" ] && { echo "  命中失败特征："; printf '%s\n' "$BAD" | sed 's/^/    /'; }
[ "$OK_LOCK" = 0 ] && echo "  没看到「获得实例锁」——单实例检查可能又走了进程列表"
[ "$OK_START" = 0 ] && echo "  没看到「启动完成」——启动路径被卡住（优先查同步 TCC/XPC，见复盘文档）"
echo "  最近日志："
tail -n +"$((BEFORE + 1))" "$LOG" 2>/dev/null | tail -12 | sed 's/^/    /'
echo
echo "  下一步：sample \$(pgrep -x Kitnest | head -1) 3 -f /tmp/hang.txt 看主线程栈；"
echo "  排查手册：docs/00-总览/开发工作流.md §六「启动不了 / 点了没反应 / 卡死」"
exit 1
