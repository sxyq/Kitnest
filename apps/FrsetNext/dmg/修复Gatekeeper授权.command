#!/bin/bash
# Kitnest 授权修复：去隔离 + 必要时本机 ad-hoc 重签
# 用法：把 Kitnest.app 拖到本文件图标上；或直接双击（自动找 /Applications）
APP_ARG="$1"
CANDIDATES=()
[ -n "$APP_ARG" ] && CANDIDATES+=("$APP_ARG")
CANDIDATES+=("/Applications/Kitnest.app" "$HOME/Applications/Kitnest.app" "$PWD/Kitnest.app")

echo "== Kitnest 授权修复 =="
APP=""
for c in "${CANDIDATES[@]}"; do
  if [ -d "$c" ]; then APP="$c"; break; fi
done
if [ -z "$APP" ]; then
  echo "没找到 Kitnest.app。"
  echo "请把 App 拖到本脚本图标上，或先安装到 /Applications。"
  if [ -t 0 ] && [ -z "${FRSET_FIX_NONINTERACTIVE:-}" ]; then read -n1 -r -p "按任意键关闭…"; fi
  exit 1
fi
echo "目标：$APP"

echo "-- 1) 去除隔离属性（Gatekeeper 只拦带 quarantine 标记的 App）"
if xattr -dr com.apple.quarantine "$APP" 2>/dev/null; then
  echo "   完成"
else
  echo "   跳过（本来就没有隔离属性；若本脚本无法运行，请右键 → 打开）"
fi

echo "-- 2) 校验签名"
if codesign -v "$APP" 2>/dev/null; then
  echo "   签名有效（开发者自签证书，本机不认识是正常的，不影响运行）"
else
  echo "   签名校验失败（常见于传输损坏 → 报「已损坏」）→ 用本机 ad-hoc 重新签名"
  codesign --force --deep --sign - "$APP" 2>&1 | tail -2
  if codesign -v "$APP" 2>/dev/null; then
    echo "   重签完成"
  else
    echo "   重签失败，请重新下载 DMG"
  fi
fi

echo
echo "== 完成 =="
echo "现在双击 Kitnest.app 即可。如果系统仍提示「无法验证」："
echo "  · 右键 App → 打开（只需一次）"
echo "  · 或 系统设置 → 隐私与安全性 → 仍要打开"
echo
# 自动化/无终端场景（FRSET_FIX_NONINTERACTIVE=1）不等待按键
if [ -t 0 ] && [ -z "${FRSET_FIX_NONINTERACTIVE:-}" ]; then read -n1 -r -p "按任意键关闭…"; fi
