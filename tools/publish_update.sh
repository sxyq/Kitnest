#!/bin/bash
# Kitnest 在线更新发布（v201 / 2026-11-04）
#
# 用法：
#   bash tools/publish_update.sh "本次更新说明" [build号] [--skip-build]
#
# 说明：
#   · 更新说明用换行分隔，行首 [新增] / [改进] / [修复] 会进入 WhatsNew 对应分组；
#     不带前缀的行归入「改进」。例如：
#       bash tools/publish_update.sh $'[新增] 支持 XX\n[修复] 修复 YY'
#   · 默认 build = 源码 Info.plist 的 CFBundleVersion + 1；也可显式指定。
#   · 对外显示版本 CFBundleShortVersionString 固定 1.0.0，脚本永不修改。
#   · 默认会重新构建（约 3-8 分钟）；--skip-build 仅用于「已构建好 + build 号不变」的首版发布。
#   · 目标：124（calorieai.sxyq27.online/kitnest/，复用 CalorieAI 官网与更新服务通道）。
#   · Nginx 侧只需首次部署一次 /kitnest/ location，见 docs/00-总览/开发工作流.md。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/FrsetNext"
INFO="$APP/Info.plist"
DEPLOYED="/Applications/Kitnest.app"
REMOTE_HOST="sxyq27-124"
REMOTE_BASE="/srv/calorieai-updates/public/kitnest"
FEED_URL="https://calorieai.sxyq27.online/kitnest/stable/latest.json"
FEED_HOST="https://calorieai.sxyq27.online/kitnest"

NOTES="${1:-功能更新与稳定性改进}"
ARG2="${2:-}"
ARG3="${3:-}"
BUILD=""
SKIP_BUILD=0
[ "$ARG2" = "--skip-build" ] && SKIP_BUILD=1 || { [ -n "$ARG2" ] && BUILD="$ARG2"; }
[ "$ARG3" = "--skip-build" ] && SKIP_BUILD=1

CUR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
[ -n "$BUILD" ] || BUILD=$((CUR + 1))

if [ "$SKIP_BUILD" -eq 1 ] && [ "$CUR" != "$BUILD" ]; then
  echo "✗ --skip-build 只允许 build 与当前 Info.plist 一致（当前 ${CUR}，请求 ${BUILD}）"
  echo "  改了 build 号必须重新构建，否则安装包内版本与清单不一致"
  exit 1
fi

DISPLAY_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
echo "== 发布 build ${BUILD}（当前 ${CUR}，显示版本 ${DISPLAY_VERSION} 固定）=="

if [ "$CUR" != "$BUILD" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$INFO"
  echo "   Info.plist CFBundleVersion -> $BUILD"
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "== 构建并原子部署 =="
  bash "$APP/build.sh"
else
  echo "== 跳过构建，使用已部署的 $DEPLOYED =="
fi

[ -d "$DEPLOYED" ] || { echo "✗ 找不到 $DEPLOYED"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ZIP_NAME="Kitnest-$BUILD.zip"
ZIP="$WORK/$ZIP_NAME"

echo "== 打包 =="
ditto -c -k --keepParent "$DEPLOYED" "$ZIP"
SIZE=$(stat -f%z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "   size=$SIZE sha256=$SHA"

echo "== 生成 latest.json =="
NOTES="$NOTES" BUILD="$BUILD" SIZE="$SIZE" SHA="$SHA" ZIP_NAME="$ZIP_NAME" python3 - <<'PY' > "$WORK/latest.json"
import json, os, datetime
build = int(os.environ["BUILD"])
zip_name = os.environ["ZIP_NAME"]
groups = {"added": [], "improved": [], "fixed": []}
clean_lines = []
for raw in os.environ["NOTES"].splitlines():
    line = raw.strip()
    if not line:
        continue
    if line.startswith("[新增]"):
        groups["added"].append(line[4:].strip()); clean_lines.append(line[4:].strip())
    elif line.startswith("[改进]"):
        groups["improved"].append(line[4:].strip()); clean_lines.append(line[4:].strip())
    elif line.startswith("[修复]"):
        groups["fixed"].append(line[4:].strip()); clean_lines.append(line[4:].strip())
    else:
        groups["improved"].append(line); clean_lines.append(line)
data = {
    "build": build,
    "versionName": "1.0.0",
    "minBuild": 1,
    "force": False,
    "zipUrl": "https://calorieai.sxyq27.online/kitnest/releases/%d/%s" % (build, zip_name),
    "size": int(os.environ["SIZE"]),
    "sha256": os.environ["SHA"],
    "releaseNotes": "；".join(clean_lines),
    "whatsNew": groups,
    "pageUrl": "https://calorieai.sxyq27.online/",
    "publishedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
}
print(json.dumps(data, ensure_ascii=False, indent=2))
PY

echo "== 上传到 124 =="
scp -q "$ZIP" "$REMOTE_HOST:/tmp/$ZIP_NAME"
scp -q "$WORK/latest.json" "$REMOTE_HOST:/tmp/kitnest-latest-$BUILD.json"
ssh "$REMOTE_HOST" "set -e; \
  sudo -n install -d -m 0755 '$REMOTE_BASE/releases/$BUILD' '$REMOTE_BASE/stable'; \
  sudo -n install -m 0644 /tmp/$ZIP_NAME '$REMOTE_BASE/releases/$BUILD/$ZIP_NAME'; \
  sudo -n install -m 0644 /tmp/kitnest-latest-$BUILD.json '$REMOTE_BASE/stable/latest.json'; \
  rm -f /tmp/$ZIP_NAME /tmp/kitnest-latest-$BUILD.json"

echo "== 验证 =="
curl -fsS "$FEED_URL" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  feed build=%s zip=%s" % (d["build"], d["zipUrl"]))'
curl -sS -o /dev/null -w '  zip HTTP %{http_code}\n' -r 0-0 "$FEED_HOST/releases/$BUILD/$ZIP_NAME"
echo "✓ 发布完成：$FEED_URL"
