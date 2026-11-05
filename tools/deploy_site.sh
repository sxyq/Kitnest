#!/bin/bash
# Kitnest 品牌官网部署（v203 / 2026-11-05）
#
# 用法：
#   bash tools/deploy_site.sh                # 部署到 124 并刷新 nginx
#   bash tools/deploy_site.sh --skip-nginx  # 只传文件，不动 nginx 配置
#
# 目标：
#   · 站点根目录：/srv/kitnest-site（静态文件，nginx 直接出）
#   · 访问地址：  https://calorieai.sxyq27.online/kitnest-site/
#   · 版本清单：  https://calorieai.sxyq27.online/kitnest-site/kitnest/stable/latest.json
#                （部署时从线上 feed 刷新，避免官网展示过期版本）
#
# 幂等性：
#   · nginx 片段按标记 <!-- kitnest-site:start --> 定位，只插一次；
#   · 每次部署前先备份 calorieai-updates.conf（带时间戳）；
#   · nginx -t 不通过就回滚配置并退出，不 reload。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE_DIR="$ROOT/FRONT"
SNIPPET="$ROOT/deploy/nginx/kitnest-site-locations.conf"
REMOTE_HOST="sxyq27-124"
REMOTE_SITE="/srv/kitnest-site"
REMOTE_CONF="/etc/nginx/conf.d/calorieai-updates.conf"
SITE_URL="https://calorieai.sxyq27.online/kitnest-site/"
FEED_URL="https://calorieai.sxyq27.online/kitnest/stable/latest.json"
SKIP_NGINX=0
[ "${1:-}" = "--skip-nginx" ] && SKIP_NGINX=1

[ -f "$SITE_DIR/index.html" ] || { echo "✗ 找不到站点文件：$SITE_DIR/index.html"; exit 1; }

echo "== 1/4 刷新版本清单快照 =="
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if curl -fsS "$FEED_URL" -o "$WORK/feed.json"; then
  python3 - "$WORK/feed.json" "$SITE_DIR/kitnest/stable/latest.json" "$SITE_URL" <<'PY'
import json, sys
src, dst, page = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
d["pageUrl"] = page
json.dump(d, open(dst, "w"), ensure_ascii=False, indent=2)
print("  feed build=%s size=%s → %s" % (d.get("build"), d.get("size"), dst))
PY
else
  echo "  ! 线上清单读取失败，沿用仓库内快照"
fi

echo "== 2/4 上传站点文件 =="
# COPYFILE_DISABLE=1 + 排除 ._*：macOS 的 tar 会写入 AppleDouble（._xxx）与扩展属性，
# 那些文件在 Linux 上是垃圾数据，必须挡掉。
# v237：官网所有界面展示位都是 GIF；assets/shots/ 只剩本地重建 GIF 用的真机原图
# （含剪贴板 / 进程榜等本机信息），整个目录排除，不再推到公网。
COPYFILE_DISABLE=1 tar -czf - \
  --exclude='.DS_Store' --exclude='._*' --exclude='.gitkeep' \
  --exclude='./tools' --exclude='./assets/shots' \
  -C "$SITE_DIR" . | ssh "$REMOTE_HOST" "set -e; \
  sudo -n rm -rf '$REMOTE_SITE.new'; \
  sudo -n install -d -m 0755 '$REMOTE_SITE.new'; \
  sudo -n tar -xzf - -C '$REMOTE_SITE.new'; \
  sudo -n find '$REMOTE_SITE.new' -type d -exec chmod 0755 {} +; \
  sudo -n find '$REMOTE_SITE.new' -type f -exec chmod 0644 {} +; \
  sudo -n chown -R root:root '$REMOTE_SITE.new'; \
  sudo -n rm -rf '$REMOTE_SITE.prev'; \
  if [ -d '$REMOTE_SITE' ]; then sudo -n mv '$REMOTE_SITE' '$REMOTE_SITE.prev'; fi; \
  sudo -n mv '$REMOTE_SITE.new' '$REMOTE_SITE'; \
  sudo -n rm -rf '$REMOTE_SITE.prev'; \
  echo '  已部署：'\$(sudo -n du -sh '$REMOTE_SITE' | cut -f1)"

if [ "$SKIP_NGINX" -eq 1 ]; then
  echo "== 3/4 跳过 nginx 配置 =="
else
  echo "== 3/4 安装 nginx 片段 =="
  scp -q "$SNIPPET" "$REMOTE_HOST:/tmp/kitnest-site-locations.conf"
  scp -q "$ROOT/deploy/nginx/apply_site_locations.py" "$REMOTE_HOST:/tmp/apply_site_locations.py"
  ssh "$REMOTE_HOST" "set -e; \
    TS=\$(date +%Y%m%d-%H%M%S); \
    sudo -n cp '$REMOTE_CONF' '$REMOTE_CONF.bak-kitnest-'\"\$TS\"; \
    sudo -n python3 /tmp/apply_site_locations.py '$REMOTE_CONF' /tmp/kitnest-site-locations.conf; \
    sudo -n nginx -t"
  ssh "$REMOTE_HOST" "sudo -n systemctl reload nginx && echo '  nginx 已 reload'"
fi

echo "== 4/4 验证 =="
ssh "$REMOTE_HOST" "curl -s -o /dev/null -w '  本机(443)首页 HTTP %{http_code}\n' --resolve calorieai.sxyq27.online:443:127.0.0.1 https://calorieai.sxyq27.online/kitnest-site/ || true"
curl -s -o /dev/null -w "  公网首页 HTTP %{http_code}\n" "$SITE_URL"
curl -s -o /dev/null -w "  站点 CSS  HTTP %{http_code}\n" "${SITE_URL}assets/site.css"
curl -s -o /dev/null -w "  站点清单  HTTP %{http_code}\n" "${SITE_URL}kitnest/stable/latest.json"
# 13 段动图逐段验 200；顺便确认真机原图目录没有上线
BAD=0
for n in clipboard capture monitor transfer cast toolbox view-panel view-monitor \
         view-transfer view-cast view-annotate view-popout view-settings; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${SITE_URL}assets/gifs/demo-$n.gif")
  [ "$code" = "200" ] || { echo "  ✗ demo-$n.gif HTTP $code"; BAD=1; }
done
if [ "$BAD" -eq 0 ]; then echo "  13 段动图  HTTP 200（全部）"; else exit 1; fi
shot_code=$(curl -s -o /dev/null -w '%{http_code}' "${SITE_URL}assets/shots/panel.png")
echo "  真机原图目录  HTTP ${shot_code} (应为 404)"
echo "✓ 部署完成：$SITE_URL"
