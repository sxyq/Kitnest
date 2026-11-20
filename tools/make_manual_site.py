#!/usr/bin/env python3
"""从应用随包的每功能文档生成在线手册；正文只有 Guides 一份来源。"""
from __future__ import annotations

import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "apps/FrsetNext/Resources/Manual/Guides"
OUTPUT = ROOT / "FRONT/manual/index.html"


def inline(text: str) -> str:
    """渲染普通用户文案中的强调和链接。"""
    text = html.escape(text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)


def category_title(raw: str) -> str:
    """把文件编号合并成普通用户能理解的功能分类。"""
    groups = {
        "01": "开始使用", "02": "剪贴板", "03": "截图与录屏", "04": "截图与录屏",
        "05": "电脑状态", "06": "文件与传输", "07": "搜索与 AI", "08": "工具箱",
        "09": "日常与设置",
    }
    return groups.get(raw[:2], raw.split(" ", 1)[-1])


def article(path: Path) -> dict:
    """读取与原生手册相同的文章元数据、段落与操作步骤。"""
    text = path.read_text(encoding="utf-8")
    title = re.search(r"^# (.+)$", text, re.M).group(1)
    metadata = dict(re.findall(r"<!-- (\w+): (.*?) -->", text))
    blocks, steps, listing = [], [], None
    for raw in text.splitlines():
        line = raw.strip()
        ordered = re.match(r"\d+[.)]\s+(.+)", line)
        unordered = re.match(r"[-*]\s+(.+)", line)
        kind = "ol" if ordered else "ul" if unordered else None
        if listing and listing != kind:
            blocks.append(f"</{listing}>")
            listing = None
        if not line or line.startswith(("# ", "<!--")):
            continue
        if kind:
            if listing is None:
                blocks.append(f"<{kind}>")
                listing = kind
            item = (ordered or unordered).group(1)
            blocks.append(f"<li>{inline(item)}</li>")
            if ordered:
                steps.append(re.sub(r"[*`]", "", item))
        elif line.startswith("## "):
            blocks.append(f"<h2>{inline(line[3:])}</h2>")
        elif line.startswith("> "):
            blocks.append(f"<blockquote>{inline(line[2:])}</blockquote>")
        else:
            blocks.append(f"<p>{inline(line)}</p>")
    if listing:
        blocks.append(f"</{listing}>")
    return dict(id=path.stem, title=title, category=category_title(metadata["category"]),
                demo=metadata["demo"], steps=steps,
                body=re.sub(r"<ol>.*?</ol>", "__DEMO__", "\n".join(blocks), flags=re.S), text=text)


PAGE = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kitnest 使用手册</title>
<style>
:root{color-scheme:light;--bg:#fff;--soft:#f5f6f8;--line:#e5e7ec;--ink:#20232a;--muted:#686e7a;--accent:#315ee8}
@media(prefers-color-scheme:dark){:root{color-scheme:dark;--bg:#191a1e;--soft:#24262c;--line:#393c43;--ink:#ebedf3;--muted:#a8aebb;--accent:#89a8ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.75 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
header{height:64px;display:flex;align-items:center;gap:20px;padding:0 28px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}header a{color:inherit;text-decoration:none;font-weight:650}header span{color:var(--muted);font-size:13px}input{font:inherit;color:inherit;border:1px solid var(--line);border-radius:8px;background:var(--soft);padding:7px 10px;min-width:0;width:100%}header label{margin-left:auto;width:240px}
.layout{display:grid;grid-template-columns:258px minmax(0,850px);gap:36px;max-width:1210px;margin:auto;padding:0 22px}aside{position:sticky;top:64px;height:calc(100vh - 64px);overflow:auto;padding:20px 0}summary{cursor:pointer;font-size:13px;font-weight:650;padding:8px 4px}details a{display:block;font-size:13px;color:var(--muted);text-decoration:none;padding:6px 12px;margin:1px 0;border-radius:7px}details a:hover,details a[aria-current]{background:var(--soft);color:var(--accent)}[hidden]{display:none!important}main{padding:32px 0 80px;min-width:0}h1{font-size:29px;margin:4px 0 22px;line-height:1.35}h2{font-size:18px;margin:28px 0 8px}p{margin:8px 0;color:var(--muted)}li{margin:7px 0}ol,ul{padding-left:24px}blockquote{border-left:3px solid var(--accent);margin:18px 0;padding:6px 16px;background:var(--soft)}.crumb{font-size:12px;color:var(--muted)}button{font:inherit;color:inherit;cursor:pointer;border:1px solid var(--line);background:var(--bg);border-radius:7px;padding:5px 12px}button:hover{color:var(--accent);border-color:var(--accent)}button:disabled{opacity:.4;cursor:default}.demo{background:var(--soft);border:1px solid var(--line);border-radius:14px;padding:16px;margin:20px 0}.bar{display:flex;align-items:center;gap:8px}.bar b{margin-right:auto;font-size:13px}.bar button{font-size:12px}.stage{min-height:190px;display:flex;align-items:center;justify-content:center;position:relative;margin:16px 0;background:var(--bg);border-radius:10px;overflow:hidden}.scene{width:88%;max-width:440px;border:1px solid var(--line);border-radius:12px;padding:18px;position:relative;box-shadow:0 12px 28px #0000000b}.scene-title{font-size:13px;font-weight:650;border-bottom:1px solid var(--line);padding-bottom:9px;margin-bottom:12px}.scene-body{font-size:15px;line-height:1.7;min-height:50px}.scene small{display:block;color:var(--muted);font-size:11px;margin-top:10px}.cursor{position:absolute;right:18px;bottom:14px;color:var(--accent);font-size:24px;transform:translate(-30px,-15px);transition:transform .35s ease}.scene.active .cursor{transform:translate(0,0)}.progress{height:3px;background:var(--line);margin-top:14px;border-radius:3px}.progress i{display:block;height:100%;background:var(--accent);transition:width .3s}.steps{display:grid;gap:5px}.steps button{text-align:left;display:flex;gap:10px;border-color:transparent;background:transparent;font-size:12px;padding:7px}.steps button[aria-current]{background:var(--bg);color:var(--accent);border-color:var(--line)}.steps span{flex:none;border:1px solid var(--line);border-radius:50%;width:22px;height:22px;text-align:center;line-height:20px}.foot{display:flex;justify-content:space-between;border-top:1px solid var(--line);padding-top:18px;margin-top:30px;font-size:12px}.foot a{color:var(--accent);text-decoration:none;max-width:45%}#empty{color:var(--muted);padding:18px 8px;font-size:13px}
.example{display:grid;gap:6px;font-size:12px}.example div{border:1px solid var(--line);padding:7px 10px;border-radius:7px;white-space:pre-wrap;overflow-wrap:anywhere}.example .chosen{border-color:var(--accent);background:var(--soft)}.landscape{height:85px;border-radius:7px;background:linear-gradient(145deg,transparent 50%,#556996 51% 70%,transparent 71%),linear-gradient(35deg,#2a4560 45%,transparent 46%),linear-gradient(#8998d3,#efd1a8);position:relative}.landscape b{position:absolute;inset:13px 25px;border:2px dashed #fff}.chart{display:flex;height:65px;gap:8px;align-items:flex-end}.chart i{flex:1;background:var(--accent);opacity:.6;border-radius:3px 3px 0 0;transition:height .3s}.demo-action{margin-top:9px;font-size:11px}.sample-pair{display:grid;grid-template-columns:1fr 1fr;gap:9px}
.dock-demo{display:grid;gap:18px;justify-items:center;width:100%}.dock-window{width:min(100%,360px);padding:12px;border:1px solid var(--line);border-radius:9px;background:var(--bg);box-shadow:0 8px 22px #00000012;font-size:12px}.dock-window header{position:static;height:auto;padding:0 0 8px;border:0;border-bottom:1px solid var(--line)}.dock-window p{margin:8px 0 0}.dock-bar{display:flex;align-items:center;gap:12px;min-height:42px;padding:6px 16px;border:1px solid var(--line);border-radius:12px;background:var(--soft)}.dock-app{display:grid;place-items:center;width:28px;height:28px;border-radius:8px;background:var(--accent);color:#fff;font-size:17px}.dock-empty{color:var(--muted);font-size:11px}
.presets{display:flex;flex-wrap:wrap;gap:6px;margin-top:12px}.presets button{font-size:12px}.presets button[aria-pressed=true]{color:var(--accent);border-color:var(--accent)}
.displays{display:grid;grid-template-columns:1fr 1fr;gap:12px}.display{text-align:center;font-size:10px;color:var(--muted)}.display-screen{height:100px;position:relative;border:1px solid var(--line);border-radius:7px;background:var(--soft);margin-bottom:6px}.display-notch{position:absolute;top:0;left:35%;width:30%;height:8px;border-radius:0 0 5px 5px;background:#111}.display-search{position:absolute;top:5px;left:20%;width:60%;border:1px solid var(--line);border-radius:9px;background:var(--bg);font-size:9px}.display-workspace{position:absolute;inset:18px 8px 8px;border:1px solid var(--accent);border-radius:6px;background:var(--bg);color:var(--ink);display:grid;align-content:center;font-size:10px}.display-workspace b{color:var(--accent)}
@media(max-width:760px){header{padding:0 14px;gap:12px}header span{display:none}.layout{grid-template-columns:1fr;gap:0;padding:0 16px}header label{width:170px}aside{position:static;height:auto;max-height:260px;border-bottom:1px solid var(--line)}main{padding-top:22px}h1{font-size:25px}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}
</style></head><body>
<header><a href="../">Kitnest</a><span>使用手册</span><label><input id="q" type="search" placeholder="搜索功能或操作" aria-label="搜索使用手册"></label></header>
<div class="layout"><aside aria-label="功能分类" id="nav">__NAV__<p id="empty" hidden>没有找到相关功能，换个词试试。</p></aside><main id="main"></main></div>
<script id="guides" type="application/json">__DATA__</script>
<script>
const guides=JSON.parse(document.getElementById('guides').textContent);
const main=document.getElementById('main'), links=[...document.querySelectorAll('aside a')];
let timer=null, current=0, active=0;
const escape=s=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function stop(){clearInterval(timer);timer=null;const button=document.getElementById('play');if(button)button.textContent='播放'}
function sample(g,index){
 const t=g.title,done=index===g.steps.length-1,started=index>0;
 const rows=items=>'<div class="example">'+items.map((s,i)=>'<div class="'+(i===Math.min(index,items.length-1)?'chosen':'')+'">'+escape(s)+'</div>').join('')+'</div>';
 const step=()=>rows([g.steps[index]]);
 let pair=null;
 const examples=[['随机编号','点击生成','A1B2C3D4-1234-4ABC-8DEF-0123456789AB'],['时间戳','1700000000','2023-11-14 22:13:20 UTC'],['特殊文字写法','Hello','SGVsbG8='],['网址文字','hello world','hello%20world'],['数据文字','{"name":"小林"}','{\n  "name": "小林"\n}'],['去重','苹果\n香蕉\n苹果','苹果\n香蕉'],['变量','user name','userName'],['网络地址','选择「公网 + 内网」','本机地址 192.168.1.8 · 示例内容'],['文本翻译','Good morning','早上好'],['文本总结','今天整理照片，明天发送给同事。','整理照片，随后发送。'],['文本润色','资料发你了看看','资料已发送，请查收。'],['确认两段文字','依次输入两份文字','比较两次生成的字符是否相同'],['压缩图片','照片.png · 2 MB','照片.jpg · 420 KB'],['代码预览','print("你好")','带颜色的代码预览']];
 for(const [key,input,output] of examples)if(t.includes(key)){pair=[input,output];break}
 if(pair)return '<div class="sample-pair">'+rows(['输入',pair[0]])+rows(['结果',started?pair[1]:'等待操作'])+'</div>';
 if(g.demo==='monitor'){
  if(t==='释放内存')return rows(['先保存文稿',started?'深度释放 → 按系统提示授权':'选择是否暂停闲置应用',done?'查看释放结果与暂停应用名单':'等待处理']);
  if(t==='存储管理')return rows(['扫描下载文件夹','设计资料 · 1.2 GB',done?'选中不需要的文件 → 移到废纸篓':'进入文件夹查看占用']);
  if(t==='查看网络连接')return rows(['本地地址 192.168.1.8 · 示例','8080 · 示例应用 · 127.0.0.1',started?'9000 · 示例服务 · 对外连接':'点击「对外」筛选']);
  const metrics=t==='处理器使用情况'?['CPU 使用率','24%']:t==='图形处理器使用情况'?['GPU 使用率','18%']:t.includes('温度')?['温度','48 ℃']:t.includes('电池')?['电量','82%']:t==='查看电脑用电情况'?['整机功耗','12 W']:t.includes('内存')?['内存用量','8.2 GB']:t.includes('磁盘')?['已用空间','180 GB']:t==='查看电脑状态'?['CPU 24% · 内存 8.2 GB','网络下载 1.8 MB/s']:['下载速度','1.8 MB/s'];
  return '<b>'+metrics[0]+' · '+(started?metrics[1]:'查看概况')+'</b><div class="chart">'+[24,41,32,56,43,64].map((h,i)=>'<i style="height:'+(started?h:20+i*3)+'px"></i>').join('')+'</div>';
 }
 if(g.demo==='capture'){
  let result=t.includes('翻译')?'Good morning → 早上好':t.includes('文字识别')?'周五交付，整理照片。':t.includes('二维码')?'识别到链接，可复制使用':t.includes('标注')?'添加箭头与文字':t.includes('水印')?'已添加水印':t.includes('钉图')?'图片留在桌面上':t.includes('图帘')?'截图卡片收在屏幕边缘 → 展开取用':t.includes('取色')?'#7B5CFF':t.includes('抹除')?'选中的物体已移除':t.includes('美化')?'添加背景和留白':t.includes('长截图')?'滚动后拼接成长图':'保存、复制或继续编辑';
  return '<div class="landscape">'+(!started?'<b></b>':'')+'</div>'+rows([started?result:'拖动选择屏幕区域']);
 }
 if(g.demo==='clipboard'){
  if(t.includes('备份'))return rows(['选择备份位置',started?'输入密码，生成加密备份':'待创建备份',done?'备份已保存':'保存中']);
  if(t.includes('隐私'))return rows(['记录状态：'+(started?'已暂停':'记录中'),'可排除不想记录的应用']);
  if(t==='剪贴板历史'||t==='剪贴板预览')return '<div class="sample-pair">'+rows(['会议记录','旅行照片','设计说明.pdf'])+rows([started?'完整内容':'选择一条记录',started?'点击或空格主动预览':'等待选择'])+'</div>';
  return step();
 }
 if(g.demo==='recording')return rows(t.includes('剪辑')?['原视频 00:00 — 00:20',started?'上方滑块：开始 00:03':'上方滑块：开始 00:00',started?'下方滑块：结束 00:12':'下方滑块：结束 00:20',done?'已导出新视频并在访达中显示':'预览保留片段']:['选择录制范围',done?'00:08 · 已停止':started?'● 00:08 · 录制中':'等待开始',done?'视频已保存并打开录屏编辑':'可暂停或停止']);
 if(g.demo==='transfer'){
  if(t==='手机直传'){
   const mac=['勾选文件 → 扫码直传','显示接收二维码','在接收区点击「出码」','等待接收','本地暂存 · 已收到文件'][index];
   const phone=['准备扫码','扫码 → 保存文件','扫描上传用的二维码','选择文件 → 上传','上传完成'][index];
   return '<div class="sample-pair">'+rows(['Mac',mac])+rows(['手机',phone])+'</div>';
  }
  if(t==='隔空投送')return rows(['加入设计说明.pdf','勾选文件 → 隔空投送','选择附近设备','请对方点击「接受」','设计说明.pdf · 已传送']);
  if(t==='安卓有线直传')return rows(['用数据线连接手机，开启 USB 调试','在手机上允许连接','Mac → 手机：ADB 直传','手机 → Mac：文件放进「下载 → Kitnest」，在 Mac 的「接收」区点击「拉取」','手机：下载 → Kitnest · Mac：本地暂存']);
  if(t==='云端中转')return rows(['在设置中开启云端中转','登录云端中转','选中文件 → 加入云端','在云端列表下载文件','从云端列表删除不再需要的文件']);
  if(t.includes('默认'))return rows(['ZIP 当前默认应用',started?'选择 Kitnest':'归档实用工具','在访达使用压缩与解压服务']);
  if(t.includes('拆分'))return rows(['项目资料 · 180 MB',started?'7z · 密码保护 · 每卷 100 MB':'选择格式，确认「保存到」显示的文件夹',done?'项目资料.7z.001\n项目资料.7z.002':'开始压缩']);
  if(t.includes('解压'))return rows(['打开资料.zip','查看其中的照片与文档',done?'文件已解压到所选位置':'选择解压位置']);
  if(t.includes('任务'))return rows(['资料.zip · 解压任务',started?'转到后台，任务继续':'查看当前进度',done?'解压完成 → 在访达中显示':'正在处理']);
  if(t.includes('投屏'))return rows(['连接手机',started?'手机画面出现在电脑上':'等待设备',done?'关闭镜像窗口结束投屏':'可调整画面']);
  return step();
 }
 if(g.demo==='search'){
  if(t.includes('AI'))return rows(['输入问题',started?'正在生成回复':'等待发送',done?'回复完成，可复制使用':'继续输入']);
  if(t.includes('网盘'))return rows(['复制完整分享信息',started?'点击「解析下载」后自动处理':'等待解析',index>1?'成功后自动下载到保存位置':'准备下载',done?'失败时按分享网页要求继续操作':'完成时显示「已下载」和文件名']);
  if(t==='全局搜索')return rows(['输入「会议」',started?'文件 · 剪贴板 · 工具':'等待输入',done?'网页搜索：选择引擎后打开':'点击文件定位、剪贴板复制、工具打开']);
  return step();
 }
 if(t.includes('Dock')){
  const label=['打开设置窗口','Dock 中显示 Kitnest 图标','窗口已最小化，图标仍在 Dock','设置窗口已恢复','最后一个独立窗口已关闭'][index];
  const window=index===2||done?'<p>'+label+'</p>':'<div class="dock-window"><header><span>●</span> 设置</header><p>'+label+'</p></div>';
  return '<div class="dock-demo">'+window+'<div class="dock-bar"><span>Finder</span>'+(done?'<span class="dock-empty">Kitnest 图标已隐藏</span>':'<span class="dock-app" aria-label="Kitnest">K</span>')+'<span>废纸篓</span></div></div>';
 }
 if(t.includes('刘海')){
  const screen=(name,notch,search,expanded)=>'<div class="display"><div class="display-screen">'+(notch?'<div class="display-notch"></div>':search?'<div class="display-search">⌕ 搜索…</div>':'')+(expanded?'<div class="display-workspace"><b>Kitnest 工作台</b><span>剪贴板 · 搜索 · 工具</span><span>正在查看的内容随窗口保留</span></div>':'')+'</div>'+name+'</div>';
  return '<div class="displays">'+screen('普通外接屏',false,index===1,index===3)+screen('内置刘海屏',true,false,index===2)+'</div><p>'+escape(g.steps[index])+'</p>';
 }
 if(t.includes('二维码'))return rows(['输入网址或文字',started?'▦ 二维码已生成':'等待生成',done?'保存或复制二维码':'调整尺寸']);
 return step();
}
function selectStep(index){
 active=index;const guide=guides[current],scene=document.querySelector('.scene');
 scene.classList.remove('active');
 document.querySelector('.scene-body').innerHTML=sample(guide,index);
 document.querySelector('.scene small').textContent=index===guide.steps.length-1?'完成这一步，即可查看结果':'第 '+(index+1)+' 步 / 共 '+guide.steps.length+' 步';
 document.querySelector('.progress i').style.width=((index+1)/guide.steps.length*100)+'%';
 document.querySelectorAll('[data-preset]').forEach(b=>b.setAttribute('aria-pressed',Number(b.dataset.preset)===(index===0?0:index===guide.steps.length-1?2:1)));
 document.querySelectorAll('.steps button').forEach((b,i)=>{if(i===index)b.setAttribute('aria-current','step');else b.removeAttribute('aria-current')});
 requestAnimationFrame(()=>scene.classList.add('active'));
}
function show(){
 stop();const id=decodeURIComponent(location.hash.slice(1));current=Math.max(0,guides.findIndex(g=>g.id===id));
 const g=guides[current];
 links.forEach(a=>{const on=a.dataset.id===g.id;if(on){a.setAttribute('aria-current','page');a.parentElement.open=true}else a.removeAttribute('aria-current')});
 const demo='<section class="demo" aria-label="交互操作演示"><div class="bar"><b>跟着做一遍 · 内置示例</b><button id="play">播放</button><button id="restart">重来</button></div>'+
 '<div class="presets" aria-label="演示阶段">'+['看懂用途','跟着操作','查看结果'].map((name,i)=>'<button data-preset="'+i+'">'+name+'</button>').join('')+'</div>'+
 '<div class="stage"><div class="scene"><div class="scene-title">'+escape(g.title)+' · 操作示范</div><div class="scene-body" aria-live="polite"></div><small></small><div class="progress"><i></i></div><div class="cursor" aria-hidden="true">➤</div></div></div>'+
 '<div class="steps">'+g.steps.map((s,i)=>'<button data-step="'+i+'"><span>'+(i+1)+'</span>'+escape(s)+'</button>').join('')+'</div></section>';
 main.innerHTML='<div class="crumb">'+escape(g.category)+'</div><h1>'+escape(g.title)+'</h1>'+g.body.replace('__DEMO__',demo)+
 '<nav class="foot">'+(current?'<a href="#'+guides[current-1].id+'">← '+escape(guides[current-1].title)+'</a>':'<span></span>')+(current+1<guides.length?'<a href="#'+guides[current+1].id+'">'+escape(guides[current+1].title)+' →</a>':'')+'</nav>';
 selectStep(0);
 document.getElementById('play').onclick=()=>{if(timer){stop();return}if(active===g.steps.length-1)selectStep(0);document.getElementById('play').textContent='暂停';timer=setInterval(()=>{if(active+1<g.steps.length)selectStep(active+1);else stop()},2400)};
 document.getElementById('restart').onclick=()=>{stop();selectStep(0)};
 document.querySelectorAll('[data-preset]').forEach((b,i)=>b.onclick=()=>{stop();selectStep([0,1,g.steps.length-1][i])});
 document.querySelectorAll('[data-step]').forEach(b=>b.onclick=()=>{stop();selectStep(Number(b.dataset.step))});
 window.scrollTo(0,0);
}
document.getElementById('q').oninput=function(){const query=this.value.trim().toLocaleLowerCase();let count=0;links.forEach(a=>{const g=guides.find(g=>g.id===a.dataset.id);a.hidden=query&&!g.text.toLocaleLowerCase().includes(query);if(!a.hidden)count++});document.querySelectorAll('aside details').forEach(group=>{group.hidden=![...group.querySelectorAll('a')].some(a=>!a.hidden);if(query)group.open=true});document.getElementById('empty').hidden=count>0};
document.addEventListener('visibilitychange',()=>{if(document.hidden)stop()});
window.addEventListener('hashchange',show);show();
</script></body></html>'''


def build() -> None:
    """生成分类导航与每次仅显示一篇的手册页面。"""
    guides = [article(path) for path in sorted(SOURCE.glob("*.md")) if not path.name.startswith("._")]
    order = ["开始使用", "剪贴板", "截图与录屏", "文件与传输", "搜索与 AI", "工具箱", "电脑状态", "日常与设置"]
    guides.sort(key=lambda guide: (order.index(guide["category"]) if guide["category"] in order else len(order), guide["id"]))
    categories = dict.fromkeys(guide["category"] for guide in guides)
    navigation = []
    for category in categories:
        links = [f'<a href="#{guide["id"]}" data-id="{guide["id"]}">{html.escape(guide["title"])}</a>'
                 for guide in guides if guide["category"] == category]
        navigation.append(f'<details><summary>{html.escape(category)}</summary>{"".join(links)}</details>')
    data = json.dumps(guides, ensure_ascii=False).replace("<", "\\u003c")
    OUTPUT.write_text(PAGE.replace("__NAV__", "\n".join(navigation)).replace("__DATA__", data), encoding="utf-8")
    print(f"手册：{len(categories)} 类，{len(guides)} 篇；{OUTPUT}")


if __name__ == "__main__":
    build()
