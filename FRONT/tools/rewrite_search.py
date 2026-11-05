#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把官网 mock 的搜索区段简化。

真机（SearchSectionView）有网页 / 剪贴板 / 文件 / 工具四路检索源 + 分类 chips，
网页版做个够用的简化版：
  · 输入普通关键词 → 过滤剪贴板列表 + 匹配工具命令（两段结果）
  · 输入 /        → 只出工具命令（真机 SlashCommandCatalog 的形态）
不做网页检索、不做分类 chips，交互一眼看得懂。
"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'assets', 'site.js')
s = io.open(PATH, encoding='utf-8').read()

# 1) 检索源定义 → 工具命令表
i = s.find('  /* 搜索结果源：真机是网页')
j = s.find('  var clipState = {')
if i < 0 or j < 0:
    sys.exit('锚点没找到 i=%d j=%d' % (i, j))

NEW_SRC = u'''  /*
     搜索：真机有网页 / 剪贴板 / 文件 / 工具四路检索源 + 分类 chips，
     网页版做个**够用的简化版**——
       · 输入普通关键词 → 过滤剪贴板列表 + 匹配工具命令（两段结果）
       · 输入 /        → 只出工具命令（真机 SlashCommandCatalog 的形态）
     不做网页检索、不做分类 chips，交互一眼看得懂。
  */
  var TOOL_COMMANDS = [
    { token: "/hash", title: "计算哈希", sub: "文本 / 文件 → SHA-256" },
    { token: "/qr", title: "生成二维码", sub: "文本 → 二维码" },
    { token: "/ip", title: "查看本机 IP", sub: "局域网地址" },
    { token: "/convert", title: "媒体格式转换", sub: "图片 / 视频 / 音频" },
    { token: "/time", title: "时间与时区", sub: "世界时钟 / 转换" },
    { token: "/color", title: "取色", sub: "屏幕取色 ⌥C" }
  ];

'''
s = s[:i] + NEW_SRC + s[j:]

# 2) renderSearchResults 重写
i = s.find('  function renderSearchResults() {')
j = s.find('  /* ---------------- 事件绑定 ---------------- */')
if i < 0 or j < 0:
    sys.exit('renderSearchResults 锚点没找到')

NEW_FN = u'''  function renderSearchResults() {
    if (!pmResults) return;
    var q = clipState.query.trim();
    if (!q) {
      pmResults.hidden = true;
      pmResults.innerHTML = "";
      return;
    }

    var isCommand = q.charAt(0) === "/";
    var token = isCommand ? q.slice(1).toLowerCase() : q.toLowerCase();

    // 工具命令：/ 开头时只出命令；普通关键词也把匹配的工具带上
    var cmds = TOOL_COMMANDS.filter(function (c) {
      if (isCommand) return c.token.toLowerCase().indexOf(token) >= 0;
      return (c.token + c.title + c.sub).toLowerCase().indexOf(token) >= 0;
    });

    // 剪贴板匹配（/ 模式下不匹配剪贴板）
    var clips = [];
    if (!isCommand) {
      clips = clipState.items.filter(function (it) {
        return it.title.toLowerCase().indexOf(token) >= 0;
      });
    }

    if (!cmds.length && !clips.length) {
      pmResults.innerHTML = '<div class="pm-result-empty">没有匹配的结果</div>';
      pmResults.hidden = false;
      return;
    }

    var html = "";
    if (cmds.length) {
      html += '<div class="pm-result-group">命令</div><ul>';
      cmds.forEach(function (c) {
        html += '<li data-result-token="' + c.token + '"><span class="r-kind code">' + c.token.charAt(1) + "</span><b></b><span></span></li>";
      });
      html += "</ul>";
    }
    if (clips.length) {
      html += '<div class="pm-result-group">剪贴板</div><ul>';
      clips.forEach(function (it) {
        html += '<li data-result-id="' + it.id + '"><span class="r-kind ' + it.kind + '"></span><b></b><span></span></li>';
      });
      html += "</ul>";
    }
    pmResults.innerHTML = html;

    // 用 textContent 填内容，避免标题里的引号破坏 HTML
    var lis = pmResults.querySelectorAll("li");
    var k = 0;
    cmds.forEach(function (c) {
      if (!lis[k]) return;
      lis[k].querySelector("b").textContent = c.token + " " + c.title;
      lis[k].querySelector("span:last-child").textContent = c.sub;
      k++;
    });
    clips.forEach(function (it) {
      if (!lis[k]) return;
      lis[k].querySelector("b").textContent = it.title;
      lis[k].querySelector("span:last-child").textContent = it.meta;
      k++;
    });

    pmResults.hidden = false;
  }

'''
s = s[:i] + NEW_FN + s[j:]

# 3) 结果区点击：命令执行 / 剪贴板定位
old_click = '''  if (pmSearch) {
    pmSearch.addEventListener("input", function () {'''
new_click = '''  if (pmResults) {
    pmResults.addEventListener("click", function (e) {
      var li = e.target.closest("li");
      if (!li) return;
      var token = li.getAttribute("data-result-token");
      if (token) {
        toast("已执行 " + token);
        pmSearch.value = token;
        clipState.query = token;
        renderSearchResults();
        return;
      }
      var id = li.getAttribute("data-result-id");
      if (id) {
        var item = findItem(id);
        if (item) {
          var row = pmList.querySelector('[data-id="' + id + '"]');
          if (row) {
            row.scrollIntoView({ behavior: "smooth", block: "center" });
            showPreview(item, row, true);
          }
        }
      }
    });
  }

  if (pmSearch) {
    pmSearch.addEventListener("input", function () {'''
if old_click in s:
    s = s.replace(old_click, new_click, 1)
else:
    print('（结果区点击未挂上：锚点没找到）')

io.open(PATH, 'w', encoding='utf-8').write(s)
print('搜索已简化，JS %d 行' % len(s.split('\n')))
