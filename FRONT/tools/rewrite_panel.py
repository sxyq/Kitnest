#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把官网 mock 主面板的 HTML 重写成与真机 PanelRootView 1:1 的结构。"""
import io, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, 'index.html')

s = io.open(PATH, encoding='utf-8').read()
i = s.find('            <!-- 可交互的主面板 -->')
j = s.find('            <p class="stage-hint">', i)
if i < 0 or j < 0:
    sys.exit('锚点没找到：i=%d j=%d' % (i, j))

NEW = u'''            <!-- 可交互的主面板（结构按真机 PanelRootView 1:1 还原） -->
            <div class="panel-mock lg" id="panelMock">
              <span class="lg__surface" aria-hidden="true"></span>
              <span class="lg__frost" aria-hidden="true"></span>
              <span class="lg__edge" aria-hidden="true"></span>
              <span class="lg__spec" aria-hidden="true"></span>

              <!-- 顶部工具条：左 3 图标 │ 分段 │ 齿轮（真机 40pt 高、左右 padding 14） -->
              <div class="pm-bar">
                <div class="pm-bar-left">
                  <button class="pm-ico" type="button" data-pm-menu="capture" title="截图" aria-label="截图">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8V6.5A2.5 2.5 0 0 1 6.5 4H8"/><path d="M16 4h1.5A2.5 2.5 0 0 1 20 6.5V8"/><path d="M20 16v1.5a2.5 2.5 0 0 1-2.5 2.5H16"/><path d="M8 20H6.5A2.5 2.5 0 0 1 4 17.5V16"/><circle cx="12" cy="12" r="3.4"/></svg>
                  </button>
                  <button class="pm-ico" type="button" data-pm-act="pick" title="取色 ⌥C" aria-label="取色">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="m13.5 6.5 4 4M16.5 3.5l4 4-9.5 9.5H7v-4z"/><path d="M13 15.5 8.5 11"/></svg>
                  </button>
                  <button class="pm-ico" type="button" data-pm-act="float" title="悬浮剪贴板" aria-label="悬浮剪贴板">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="13" rx="2"/><path d="M3 9h18"/></svg>
                  </button>
                </div>

                <div class="pm-segs" id="pmSegs">
                  <button class="pm-seg on" type="button" data-page="home">主页</button>
                  <button class="pm-seg" type="button" data-page="monitor">监测</button>
                  <button class="pm-seg" type="button" data-page="transfer">中转</button>
                  <button class="pm-seg" type="button" data-page="cast">投屏</button>
                </div>

                <button class="pm-ico" type="button" data-pm-menu="gear" title="设置" aria-label="设置">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3.1"/><path d="M18.9 14.2a1.6 1.6 0 0 0 .3 1.8l.1.1a1.9 1.9 0 1 1-2.7 2.7l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5v.2a1.9 1.9 0 1 1-3.8 0v-.1a1.6 1.6 0 0 0-1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a1.9 1.9 0 1 1-2.7-2.7l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1h-.2a1.9 1.9 0 1 1 0-3.8h.1a1.6 1.6 0 0 0 1.5-1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a1.9 1.9 0 1 1 2.7-2.7l.1.1a1.6 1.6 0 0 0 1.8.3h.1a1.6 1.6 0 0 0 1-1.5v-.2a1.9 1.9 0 1 1 3.8 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a1.9 1.9 0 1 1 2.7 2.7l-.1.1a1.6 1.6 0 0 0-.3 1.8v.1a1.6 1.6 0 0 0 1.5 1h.2a1.9 1.9 0 1 1 0 3.8h-.1a1.6 1.6 0 0 0-1.5 1z"/></svg>
                </button>
              </div>

              <!-- 搜索区段（真机 placeholder：搜索或输入 / 使用工具） -->
              <div class="pm-searchwrap">
                <div class="pm-search">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="6.6"/><path d="m20 20-3.4-3.4"/></svg>
                  <input id="pmSearch" type="text" placeholder="搜索或输入 / 使用工具" autocomplete="off" aria-label="搜索">
                  <span class="pm-slash">/</span>
                </div>
                <div class="pm-results" id="pmResults" hidden></div>
              </div>

              <div class="pm-body" id="pmBody">
                <!-- 剪贴板条目的预览浮层（真机：单击/悬停都出，移出即关） -->
                <div class="pm-preview" id="pmPreview" hidden>
                  <div class="pm-preview-body"></div>
                </div>

                <!-- 主页 -->
                <div class="pm-page" data-page="home">
                  <!-- 日历卡（真机：白玻璃卡 14 圆角，标题行 + 星期行 + 两周网格） -->
                  <div class="pm-cal">
                    <div class="pm-cal-head">
                      <button class="pm-cal-nav" type="button" data-pm-act="cal-prev" title="上一周" aria-label="上一周">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m14.5 5.5-6 6.5 6 6.5"/></svg>
                      </button>
                      <button class="pm-cal-title" type="button" data-pm-act="cal-today" title="回到今天">2026 年 11 月</button>
                      <button class="pm-cal-nav" type="button" data-pm-act="cal-next" title="下一周" aria-label="下一周">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9.5 5.5 6 6.5-6 6.5"/></svg>
                      </button>
                      <button class="pm-cal-collapse" type="button" data-pm-act="cal-fold" title="折叠" aria-label="折叠">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9.5 6 6 6-6"/></svg>
                      </button>
                    </div>
                    <div class="pm-cal-week">
                      <span>周日</span><span>周一</span><span>周二</span><span>周三</span><span>周四</span><span>周五</span><span>周六</span>
                    </div>
                    <div class="pm-cal-grid" id="pmCalGrid"></div>
                  </div>

                  <ul class="pm-list" id="pmList"></ul>
                </div>

                <!-- 性能监测 -->
                <div class="pm-page" data-page="monitor" hidden>
                  <div class="pm-modbar" data-jump="features:ch-monitor">
                    <span class="on">温度</span><span>CPU</span><span>内存</span><span>网络</span><span>磁盘</span><span>电池</span>
                  </div>
                  <div class="pm-metrics">
                    <div><b>Average</b><span>41.2 °C</span></div>
                    <div><b>Hottest</b><span>58.4 °C</span></div>
                    <div><b>DC In</b><span>17.2 V</span></div>
                  </div>
                  <div class="pm-bars">
                    <div class="pm-bar"><span>CPU 0</span><i style="width:38%"></i><em>39°</em></div>
                    <div class="pm-bar"><span>CPU 1</span><i style="width:44%"></i><em>41°</em></div>
                    <div class="pm-bar"><span>CPU 2</span><i style="width:57%"></i><em>46°</em></div>
                    <div class="pm-bar"><span>GPU</span><i style="width:72%"></i><em>58°</em></div>
                    <div class="pm-bar"><span>NVMe</span><i style="width:29%"></i><em>35°</em></div>
                  </div>
                </div>

                <!-- 文件中转 -->
                <div class="pm-page" data-page="transfer" hidden>
                  <div class="pm-sect-title">发送</div>
                  <div class="pm-exits">
                    <button class="pm-exit" type="button" data-jump="features:ch-transfer" data-toast="弹出系统隔空投送面板"><b>苹果设备</b><span>iPhone / iPad / Mac</span></button>
                    <button class="pm-exit" type="button" data-jump="features:ch-transfer" data-toast="生成二维码，对方扫码即可接收"><b>安卓 / 其他</b><span>扫码直传</span></button>
                    <button class="pm-exit" type="button" data-jump="features:ch-transfer" data-toast="USB 3.0 直连，实测可跑满 100 MB/s"><b>ADB 直传</b><span>需先连一次设备</span></button>
                  </div>
                  <div class="pm-sect-title">本地暂存</div>
                  <div class="pm-files">
                    <div class="pm-file"><span class="pm-file-ico">ZIP</span><div><b>发布包.zip</b><span>2.1 MB</span></div></div>
                    <div class="pm-file"><span class="pm-file-ico">MD</span><div><b>发布流程.md</b><span>18 KB</span></div></div>
                  </div>
                </div>

                <!-- 投屏 -->
                <div class="pm-page" data-page="cast" hidden>
                  <div class="pm-device">
                    <div class="pm-device-top">
                      <span class="pm-dot"></span>
                      <div><b>已连接的设备</b><span>USB · 1920p / 16 Mbps / 60 fps</span></div>
                    </div>
                    <div class="pm-navkeys">
                      <button type="button" data-jump="features:ch-cast" data-toast="发送返回键">‹</button>
                      <button type="button" data-jump="features:ch-cast" data-toast="回到桌面">⌂</button>
                      <button type="button" data-jump="features:ch-cast" data-toast="打开多任务">▢</button>
                      <button type="button" data-jump="features:ch-cast" data-toast="展开通知栏">▤</button>
                    </div>
                  </div>
                  <div class="pm-sect-title">手机通知</div>
                  <ul class="pm-notify">
                    <li><b>手机通知</b><span>来自手机的一条通知</span></li>
                    <li><b>另一条通知</b><span>手机上刚收到的内容</span></li>
                  </ul>
                </div>
              </div>

              <!-- 底部悬浮工具条（真机：白胶囊浮在列表底部居中） -->
              <div class="pm-dock" id="pmDock">
                <button type="button" data-pm-act="dock-search" title="搜索" aria-label="搜索">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="6.8"/><path d="m20 20-3.5-3.5"/></svg>
                </button>
                <button type="button" data-pm-menu="filter" title="分类筛选" aria-label="分类筛选">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8"/><path d="M6.6 9.6h10.8M8.6 14.4h6.8"/></svg>
                </button>
                <button type="button" data-pm-act="dock-tag" title="标签" aria-label="标签">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 7h16l-6.5 8v5l-3 2v-7z"/></svg>
                </button>
                <button type="button" data-pm-act="dock-top" title="回到顶部" aria-label="回到顶部">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V6m0 0-5 5m5-5 5 5M5 19h14"/></svg>
                </button>
              </div>

              <!-- 悬浮菜单（真机 NSMenu：截图 / 齿轮 / 分类筛选） -->
              <div class="pm-menu" id="pmMenu" hidden>
                <ul class="pm-menu-list" id="pmMenuList"></ul>
              </div>

              <!-- 右键菜单（真机 ClipboardNativeMenuPresenter） -->
              <div class="pm-ctx" id="pmCtx" hidden>
                <ul class="pm-ctx-list" id="pmCtxList"></ul>
              </div>

              <!-- 页面内跳转提示（点页面里的链接时出现） -->
              <div class="pm-jump-hint" id="pmJumpHint" hidden>
                <span id="pmJumpText">看「剪贴板」的完整说明</span>
                <button type="button" id="pmJumpGo">去看</button>
              </div>
            </div>

'''

s = s[:i] + NEW + s[j:]
io.open(PATH, 'w', encoding='utf-8').write(s)
print('面板 HTML 已重写，%d 行' % len(s.split('\n')))
