#!/bin/bash
# Kitnest 屏幕录制授权一键修复（重建版，对应原版 com.maoux.frset 的同款脚本）
#
# 背景（2026-10-18 彻底排查结论）：
#   本工程用固定自签证书「FrsetDev」签名（build.sh 自动），TCC 授权 designated
#   requirement = identifier "com.sxyq.frsetnext" and certificate leaf=H"2efbee..."
#   ——与二进制内容无关，重新构建后授权保留。
#   若哪天又出现「授权了却又提示没授权」，按本脚本重置后重新授权一次即可。
#   （历史根因：ad-hoc 签名的 requirement = cdhash 内容哈希，每次重新编译
#     内容必变 → 授权失效。现已用证书签名根治，正常情况下本脚本不需要跑。）
echo "== 修复 Kitnest 授权（重置屏幕录制记录）=="
pkill -f "Kitnest.app/Contents/MacOS/Kitnest" 2>/dev/null; sleep 1
echo "-- Kitnest 已退出"
tccutil reset ScreenCapture com.sxyq.frsetnext 2>&1
echo
echo "== 完成 =="
echo "下一步："
echo "1) 重新打开 Kitnest（build/Kitnest.app）"
echo "2) 点一次截图（或 设置 → 截图 → 权限 → 检查/申请）"
echo "3) 系统弹窗点「打开系统设置」→ 在「录屏与系统录音」开启 Kitnest.app"
echo "4) 退出 Kitnest 再重新打开（关键：TCC 授权在进程启动时读取）"
echo "5) 再点截图即可——今后重新构建不需要再授权（证书签名保授权）"
