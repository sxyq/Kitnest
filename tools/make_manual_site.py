#!/usr/bin/env python3
"""应用与网页共用每功能一篇的指南、步骤和预设画面。"""
from __future__ import annotations

import html
import base64
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "apps/FrsetNext/Resources/Manual/Guides"
OUTPUT = ROOT / "FRONT/manual/index.html"
GROUPS = {"01": "开始使用", "02": "剪贴板", "03": "截图与录屏", "04": "截图与录屏",
          "05": "电脑状态", "06": "文件与传输", "07": "搜索与 AI", "08": "工具箱", "09": "日常与设置"}
ORDER = ["开始使用", "剪贴板", "截图与录屏", "文件与传输", "搜索与 AI", "工具箱", "电脑状态", "日常与设置"]


def inline(text: str) -> str:
    """保留正文强调和普通链接。"""
    text = html.escape(text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)


def article(path: Path) -> dict:
    """读取一篇文章和与编号步骤一一对应的演示画面。"""
    text = path.read_text(encoding="utf-8")
    title = re.search(r"^# (.+)$", text, re.M).group(1)
    category = re.search(r"<!-- category: (.*?) -->", text).group(1)
    scene = re.search(r"<!-- scene: (.*?) -->", text).group(1)
    frames = [json.loads(frame) for frame in re.findall(r"<!-- frame: (.*?) -->", text)]
    blocks, steps = [], []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("# ", "<!--")):
            continue
        ordered = re.match(r"\d+[.、)]\s+(.+)", line)
        if ordered:
            if not steps:
                blocks.append("__DEMO__")
            steps.append(ordered.group(1))
        elif line.startswith("## "):
            blocks.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("- "):
            blocks.append(f"<p>• {inline(line[2:])}</p>")
        elif line.startswith("> "):
            blocks.append(f"<blockquote>{inline(line[2:])}</blockquote>")
        else:
            blocks.append(f"<p>{inline(line)}</p>")
    return dict(id=path.stem, title=title, category=GROUPS[category[:2]], steps=steps, scene=scene,
                frames=frames, body="\n".join(blocks), text=title + " " + " ".join(blocks) + " ".join(steps))


PAGE = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kitnest 使用手册</title><style>
:root{color-scheme:light dark;--bg:light-dark(#fff,#191a1e);--soft:light-dark(#f5f6f8,#24262c);--line:light-dark(#e5e7ec,#393c43);--ink:light-dark(#20232a,#ebedf3);--muted:light-dark(#686e7a,#a8aebb);--accent:light-dark(#315ee8,#89a8ff)}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.75 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
header{height:64px;display:flex;align-items:center;gap:20px;padding:0 28px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}header a{color:inherit;text-decoration:none;font-weight:650}header span{color:var(--muted);font-size:13px}header label{margin-left:auto;width:240px}input{font:inherit;color:inherit;border:1px solid var(--line);border-radius:8px;background:var(--soft);padding:7px 10px;min-width:0;width:100%}
.layout{display:grid;grid-template-columns:250px minmax(0,850px);gap:32px;max-width:1210px;margin:auto;padding:0 22px}aside{position:sticky;top:64px;height:calc(100vh - 64px);overflow:auto;padding:20px 0}summary{cursor:pointer;font-size:13px;font-weight:650;padding:8px 4px}aside a{display:block;font-size:13px;color:var(--muted);text-decoration:none;padding:6px 12px;margin:1px 0;border-radius:7px}aside a:hover,aside a[aria-current]{background:var(--soft);color:var(--accent)}[hidden]{display:none!important}main{padding:32px 0 80px;min-width:0}h1{font-size:29px;margin:4px 0 22px;line-height:1.35}h2{font-size:18px;margin:28px 0 8px}p{margin:8px 0;color:var(--muted)}blockquote{border-left:3px solid var(--accent);margin:18px 0;padding:6px 16px;background:var(--soft)}.crumb{font-size:12px;color:var(--muted)}button{font:inherit;color:inherit;cursor:pointer;border:1px solid var(--line);background:var(--bg);border-radius:7px;padding:5px 12px}button:hover{color:var(--accent);border-color:var(--accent)}button:focus-visible,a:focus-visible,input:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.demo{background:var(--soft);border-radius:14px;padding:16px;margin:20px 0}.bar{display:flex;align-items:center;gap:8px}.bar b{margin-right:auto;font-size:13px}.bar button,.presets button{font-size:12px}.presets{display:flex;gap:6px;margin:12px 0}.presets button{flex:1}.presets button[aria-pressed=true]{color:var(--accent);border-color:var(--accent)}.stage{border-radius:12px;padding:14px;background:var(--bg);margin-bottom:12px}.scene-head{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);margin-bottom:12px}.scene{display:grid;gap:9px;animation:arrive .25s ease}.scene b{font-size:14px}.items{display:grid;gap:6px}.item{border-radius:7px;padding:9px 12px;background:var(--soft);font-size:13px;white-space:pre-wrap;overflow-wrap:anywhere;display:flex;align-items:flex-start;gap:8px}.item.chosen{background:color-mix(in srgb,var(--accent) 12%,var(--bg));color:var(--accent)}.dot{flex-shrink:0;width:14px;height:14px;border:1px solid currentColor;border-radius:50%;margin-top:4px}.chosen .dot{background:var(--accent)}.gesture{font-size:12px;color:var(--accent)}.action{justify-self:end;background:var(--accent);color:var(--bg);font-size:12px}.action:hover{color:var(--bg);opacity:.85}.track{height:3px;background:var(--soft);margin-top:14px}.track i{display:block;height:100%;background:var(--accent);transition:width .25s}.steps{display:grid;gap:5px}.steps button{text-align:left;display:flex;gap:10px;border-color:transparent;background:transparent;font-size:13px;padding:7px}.steps button[aria-current]{background:var(--bg);color:var(--accent)}.steps span{flex:none;border-radius:50%;width:22px;height:22px;text-align:center;background:var(--soft)}.note{font-size:12px;margin-top:12px}.foot{display:flex;justify-content:space-between;border-top:1px solid var(--line);padding-top:18px;margin-top:30px;font-size:12px}.foot a{color:var(--accent);text-decoration:none;max-width:45%}.tasks{display:grid;grid-template-columns:1fr 1fr;gap:12px}.tasks a{padding:18px;background:var(--soft);border-radius:12px;text-decoration:none;color:inherit}.tasks b{display:block}.tasks p{font-size:13px}.tasks span{color:var(--accent);font-size:12px}#empty{font-size:13px;padding:12px}@keyframes arrive{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:translateY(0)}}
@media(max-width:760px){header{padding:0 14px;gap:12px}header span{display:none}.layout{grid-template-columns:1fr;gap:0;padding:0 16px}header label{width:170px}aside{position:static;height:auto;max-height:260px;border-bottom:1px solid var(--line)}main{padding-top:22px}h1{font-size:25px}.tasks{grid-template-columns:1fr}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
.illustration{margin:0;position:relative;text-align:center}.illustration img{height:110px;max-width:100%;border-radius:8px}.illustration .crop{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);width:125px;height:72px;border:2px dashed var(--accent);border-radius:4px;transition:width .25s,height .25s}.illustration .crop.first{width:65px;height:38px}.display-pair{display:flex;gap:18px;justify-content:space-around;color:var(--muted);font-size:12px}.display-pair .chosen{color:var(--accent)}.display-pair span{display:block;border:2px solid currentColor;border-radius:4px;width:90px;height:48px;margin:4px auto}.clipboard-pair{display:grid;grid-template-columns:1fr 2fr;gap:10px;font-size:12px;padding:10px;background:var(--soft);border-radius:7px}.clipboard-pair span{white-space:pre-wrap}.row-cursor{margin-left:auto;color:var(--accent);font-size:16px}
</style></head><body>
<header><a href="../">Kitnest</a><span>使用手册</span><label><input id="q" type="search" placeholder="搜索功能或操作" aria-label="搜索使用手册"></label></header>
<div class="layout"><aside aria-label="功能分类"><a href="#" id="intro">快速入门</a><div id="nav">__NAV__</div><p id="empty" hidden>没有找到相关功能，换个词试试。</p></aside><main id="main"></main></div>
<script id="guides" type="application/json">__DATA__</script><script>
const guides=JSON.parse(document.getElementById('guides').textContent),main=document.getElementById('main'),links=[...document.querySelectorAll('#nav a')];
let timer=null,current=0,active=0;
const escape=s=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function stop(){clearInterval(timer);timer=null;const button=document.getElementById('play');if(button)button.textContent='播放'}
function illustration(g,index){
 if(g.scene==='photo'||g.scene==='crop')return '<figure class="illustration"><img src="data:image/png;base64,__PHOTO__" alt="与设置页相同的示例图片">'+(g.scene==='crop'?'<span class="crop '+(index===0?'first':'')+'"></span>':'')+'</figure>';
 if(g.scene==='displays')return '<div class="display-pair">'+['普通外接屏','内置刘海屏'].map((name,i)=>'<div class="'+((index===g.steps.length-1)===(i===0)?'chosen':'')+'"><span></span>'+name+'</div>').join('')+'</div>';
 if(g.scene==='clipboard')return '<div class="clipboard-pair"><span>周五交付</span><span>'+(index===0?'点选记录查看内容':'周五交付<br>整理图片、文字和交付清单。')+'</span></div>';
 return '';
}
function selectStep(index){
 active=index;const g=guides[current],f=g.frames[index],host=document.getElementById('scene');
 host.innerHTML='<div class="scene"><b>'+escape(f.title)+'</b>'+illustration(g,index)+'<div class="items">'+f.items.map((s,i)=>'<div class="item '+(i===f.selected?'chosen':'')+'"><i class="dot" aria-hidden="true"></i><span>'+escape(s)+'</span>'+(i===f.selected?'<span class="row-cursor" aria-hidden="true">↖</span>':'')+'</div>').join('')+'</div><div class="gesture">操作：'+escape(f.action)+'</div><button class="action" id="action">'+(index===g.steps.length-1?'重新演示':'演示：'+escape(f.action))+'</button></div>';
 document.getElementById('counter').textContent=(index+1)+' / '+g.steps.length;
 document.querySelector('.track i').style.width=((index+1)/g.steps.length*100)+'%';
 document.querySelectorAll('[data-preset]').forEach(b=>b.setAttribute('aria-pressed',Number(b.dataset.preset)===index));
 document.querySelectorAll('[data-step]').forEach((b,i)=>{if(i===index)b.setAttribute('aria-current','step');else b.removeAttribute('aria-current')});
 document.getElementById('action').onclick=()=>{stop();selectStep(index===g.steps.length-1?0:index+1)};
}
function show(){
 stop();const id=decodeURIComponent(location.hash.slice(1));
 links.forEach(a=>a.removeAttribute('aria-current'));
 document.getElementById('intro').toggleAttribute('aria-current',!id);
 if(!id){
  const categories=[...new Set(guides.map(g=>g.category))];
  main.innerHTML='<h1>按功能找说明</h1><p>每项功能都有独立说明和可播放的操作演示。</p><div class="tasks">'+categories.map(c=>'<a href="#category='+encodeURIComponent(c)+'"><b>'+escape(c)+'</b><p>'+guides.filter(g=>g.category===c).length+' 项功能</p><span>浏览这一类 →</span></a>').join('')+'</div>';
  return;
 }
 if(id.startsWith('category=')){
  const category=decodeURIComponent(id.slice('category='.length)),items=guides.filter(g=>g.category===category);
  main.innerHTML='<div class="crumb">功能分类</div><h1>'+escape(category)+'</h1><div class="tasks">'+items.map(g=>'<a href="#'+g.id+'"><b>'+escape(g.title)+'</b><p>'+escape(g.steps[0])+'</p><span>阅读完整说明 →</span></a>').join('')+'</div>';
  return;
 }
 current=guides.findIndex(g=>g.id===id);if(current<0){main.innerHTML='<h1>未找到这篇说明</h1><p>请从左侧选择功能。</p>';return}
 const g=guides[current];links.forEach(a=>{if(a.dataset.id===g.id){a.setAttribute('aria-current','page');a.parentElement.open=true}});
 const demo='<section class="demo" aria-label="操作演示"><div class="bar"><b>预设操作演示</b><button id="play">播放</button><button id="restart">重来</button></div><div class="presets">'+[['看懂用途',0],['跟着操作',Math.min(1,g.steps.length-1)],['查看结果',g.steps.length-1]].map(([t,i])=>'<button data-preset="'+i+'">'+t+'</button>').join('')+'</div><div class="stage"><div class="scene-head"><span>'+escape(g.title)+'</span><span id="counter"></span></div><div id="scene" aria-live="polite"></div><div class="track"><i></i></div></div><div class="steps">'+g.steps.map((s,i)=>'<button data-step="'+i+'"><span>'+(i+1)+'</span>'+escape(s)+'</button>').join('')+'</div><p class="note">预设演示只展示操作步骤，不会打开或修改你的文件。</p></section>';
 main.innerHTML='<div class="crumb">'+escape(g.category)+'</div><h1>'+escape(g.title)+'</h1>'+g.body.replace('__DEMO__',demo)+'<nav class="foot">'+(current?'<a href="#'+guides[current-1].id+'">← '+escape(guides[current-1].title)+'</a>':'<span></span>')+(current+1<guides.length?'<a href="#'+guides[current+1].id+'">'+escape(guides[current+1].title)+' →</a>':'')+'</nav>';
 selectStep(0);document.getElementById('play').onclick=()=>{if(timer){stop();return}if(active===g.steps.length-1)selectStep(0);document.getElementById('play').textContent='暂停';timer=setInterval(()=>{if(active+1<g.steps.length)selectStep(active+1);else stop()},2400)};
 document.getElementById('restart').onclick=()=>{stop();selectStep(0)};document.querySelectorAll('[data-preset],[data-step]').forEach(b=>b.onclick=()=>{stop();selectStep(Number(b.dataset.preset??b.dataset.step))});window.scrollTo(0,0);
}
document.getElementById('q').oninput=function(){const q=this.value.trim().toLocaleLowerCase();let count=0;links.forEach(a=>{const g=guides.find(g=>g.id===a.dataset.id);a.hidden=q&&!g.text.toLocaleLowerCase().includes(q);if(!a.hidden)count++});document.querySelectorAll('#nav details').forEach(group=>{group.hidden=![...group.querySelectorAll('a')].some(a=>!a.hidden);if(q)group.open=true});document.getElementById('empty').hidden=count>0};
document.addEventListener('visibilitychange',()=>{if(document.hidden)stop()});window.addEventListener('hashchange',show);show();
</script></body></html>'''


def build() -> None:
    """生成八类导航和每次只打开一篇的在线手册。"""
    guides = [article(path) for path in sorted(SOURCE.glob("*.md")) if not path.name.startswith("._")]
    guides.sort(key=lambda guide: (ORDER.index(guide["category"]), guide["id"]))
    navigation = []
    for category in ORDER:
        links = [f'<a href="#{g["id"]}" data-id="{g["id"]}">{html.escape(g["title"])}</a>' for g in guides if g["category"] == category]
        navigation.append(f'<details><summary>{category}</summary>{"".join(links)}</details>')
    data = json.dumps(guides, ensure_ascii=False).replace("<", "\\u003c")
    photo = base64.b64encode((SOURCE.parent / "preview.png").read_bytes()).decode()
    OUTPUT.write_text(PAGE.replace("__NAV__", "\n".join(navigation)).replace("__DATA__", data).replace("__PHOTO__", photo), encoding="utf-8")
    print(f"手册：{len(ORDER)} 类，{len(guides)} 篇；{OUTPUT}")


if __name__ == "__main__":
    build()
