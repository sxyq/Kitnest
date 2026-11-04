#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Kitnest 官网的 nginx location 片段插入 calorieai-updates.conf（幂等，可重复执行）。

用法（远端执行）：
  sudo python3 apply_site_locations.py /etc/nginx/conf.d/calorieai-updates.conf /tmp/kitnest-site-locations.conf

行为：
  · 片段已存在 → 用新片段**整段替换**旧片段（便于后续改配置后重跑）；
  · 片段不存在 → 以 `location = /healthz {` 为锚点插入（该锚点只存在于 443 server 块内）；
  · 找不到锚点 → 退出码 1，不写文件。
"""

import shutil
import sys

START = "    # kitnest-site:start"
END = "    # kitnest-site:end"


def main() -> int:
    if len(sys.argv) != 3:
        print("✗ 参数不足：<conf> <snippet>")
        return 1

    conf_path, snippet_path = sys.argv[1], sys.argv[2]
    shutil.copy2(conf_path, conf_path + ".bak-before-kitnest-site")

    text = open(conf_path, encoding="utf-8").read()
    snippet = open(snippet_path, encoding="utf-8").read().strip()

    if START in text and END in text:
        head, rest = text.split(START, 1)
        _, tail = rest.split(END, 1)
        text = head + snippet + tail
        open(conf_path, "w", encoding="utf-8").write(text)
        print("  片段已替换")
        return 0

    marker = "    location = /healthz {"
    if marker not in text:
        print("✗ 找不到插入锚点：%s" % marker)
        return 1

    text = text.replace(marker, snippet + "\n\n" + marker, 1)
    open(conf_path, "w", encoding="utf-8").write(text)
    print("  片段已插入")
    return 0


if __name__ == "__main__":
    sys.exit(main())
