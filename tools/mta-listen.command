#!/bin/bash
# 互传联盟（MTA）接收端 · 一键验证
#
# 用法：双击本文件（或在终端里 ./mta-listen.command）
# 然后在手机上：相册选照片 → 分享 → 「小米互传 / 互传」→ 选择列表里的这台 Mac
#
# 原理（与 mtapy 一致）：
#   BLE 广播等待手机 → 手机写 P2P 凭据（SSID/PSK/端口）→ 本机用 networksetup 连手机热点
#   → WSS 版本协商 → 手机点接受 → HTTPS 下载 ZIP → 解压到 received_files/
#
# 注意：连接手机热点期间，本机若靠 Wi-Fi 上网会短暂断网（有线不受影响）。

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$HOME/Library/Application Support/FrsetNext/mta-venv"
OUT="$HERE/received_files"

echo "== 互传联盟接收端 =="
echo "源码：$HERE/mtapy"

if [ ! -x "$VENV/bin/python" ]; then
  echo "[1/3] 创建 Python 环境…"
  PY="$(command -v python3.13 || command -v python3.12 || command -v python3)"
  "$PY" -m venv "$VENV" || { echo "创建 venv 失败"; exit 1; }
fi

echo "[2/3] 检查依赖（首次约 1-2 分钟）…"
"$VENV/bin/pip" install -q --upgrade bleak websockets cryptography pyobjc-framework-CoreBluetooth \
  || { echo "依赖安装失败（检查网络）"; exit 1; }

echo "[3/3] 开始监听（手机上点分享 → 小米互传 → 选本机）…"
mkdir -p "$OUT"
cd "$HERE/mtapy"
PYTHONPATH=src "$VENV/bin/python" demo.py --auto-connect --timeout "${1:-300}"
