#!/bin/bash
# 把主线（main）同步到外置硬盘上的「去中转 / 去投屏」Lite 变体分支。
#
# 用法：
#   bash tools/sync_variant.sh              # 只合并，不构建
#   bash tools/sync_variant.sh --build      # 合并后顺手构建并部署变体
#
# 背景（2026-11-22 用户原话）：
#   「把外置硬盘上的那个单独的、去掉中转和文件传输的那个投屏功能的分支，请你去更新。
#     每次完成之后也需要去及时更新那边。」
# 当前要求（2026-11-23）：Lite 从底层源码移除中转与投屏，其余功能与 main 一致。
#
# 为什么要有这个脚本：
#   变体工作树在外置 exFAT 盘上，路径与分支名容易记错；worktree 会因拔盘变成 prunable。
#   脚本负责：缺失的 worktree 重建 → 主线合入 → 冲突清单 → （可选）构建。
#   合并冲突**不自动解决**——变体去掉的功能目录与主线改动撞车时，必须人看一眼。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARIANT_DIR="${KITNEST_VARIANT_DIR:-/Volumes/Lexar/Project/frset-rebuild-lite}"
BRANCH="${KITNEST_VARIANT_BRANCH:-variant/without-transfer-cast}"
DO_BUILD=0
[ "${1:-}" = "--build" ] && DO_BUILD=1

echo "== 主线 =="
git -C "$ROOT" branch --show-current | xargs echo "  当前分支:"
git -C "$ROOT" log --oneline -1 | xargs echo "  最新提交:"

# 外置盘权限：macOS 会对「可移除宗卷」单独要授权，没授权时这里直接说清楚。
#
# v283 补 timeout：盘被拔掉但 /Volumes 里留着「僵尸挂载点」时，`ls` 会一直卡在
# 内核里（本机 2026-11-22 实测：/Volumes 整目录 stat 卡死，连 `ls /Volumes` 都超时）。
# 没有超时的话这个脚本会把终端一起吊住，看起来像脚本挂了。
VOLUME_ROOT="$(dirname "$(dirname "$VARIANT_DIR")")"
if ! timeout 5 ls "$VOLUME_ROOT" >/dev/null 2>&1; then
  echo "✗ 外置盘不可读：$VOLUME_ROOT"
  echo "  可能原因：① 盘没插/没上电；② 系统没给「可移除宗卷」权限；③ 拔盘留下的僵尸挂载点。"
  echo "  自查：timeout 5 ls /Volumes；timeout 5 mount | grep -i lexar；diskutil list"
  echo "  若 mount 里没有该盘、diskutil 也看不到它，说明盘已经不在系统里，先接好线再说。"
  echo "  到「系统设置 → 隐私与安全性 → 文件与文件夹」给终端/WorkBuddy 打开「可移除宗卷」，或手动拷贝工作树。"
  exit 1
fi

if [ ! -d "$VARIANT_DIR/.git" ] && [ ! -f "$VARIANT_DIR/.git" ]; then
  echo "== 工作树缺失，重建 =="
  git -C "$ROOT" worktree prune
  mkdir -p "$(dirname "$VARIANT_DIR")"
  git -C "$ROOT" worktree add "$VARIANT_DIR" "$BRANCH"
fi

echo "== 变体 =="
git -C "$VARIANT_DIR" branch --show-current | xargs echo "  当前分支:"
git -C "$VARIANT_DIR" status --short | head -5

echo "== 合并 main =="
if git -C "$VARIANT_DIR" merge --no-edit main; then
  echo "✓ 合并完成：$(git -C "$VARIANT_DIR" log --oneline -1)"
else
  echo "✗ 有冲突，未自动解决："
  git -C "$VARIANT_DIR" diff --name-only --diff-filter=U | sed 's/^/    /'
  echo "  处理完再执行： git -C \"$VARIANT_DIR\" add -A && git -C \"$VARIANT_DIR\" commit"
  exit 2
fi

if [ "$DO_BUILD" -eq 1 ]; then
  echo "== 构建变体 =="
  ( cd "$VARIANT_DIR/apps/FrsetNext" && ./build.sh )
fi

echo "✓ 完成。变体分支落后主线 0 个提交。"
