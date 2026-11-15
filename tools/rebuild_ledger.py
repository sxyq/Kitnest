#!/usr/bin/env python3
"""重建函数审阅台账：行号重锚 + 补新增函数 + 处理重命名/删除。

为什么需要它
------------
`函数审阅台账.csv` 是**人工撰写证据**的产物（每条 evidence 写清"为什么留"），
但它的坐标（line）会随每次改码漂移。以前靠手工维护，结果 202 条行号过期、
v249–v260 新增函数整批漏账。本脚本只做机械部分：

  · 行号重锚：按 (file, owner, kind, name) 分组，组内按旧行号顺序与清单行号顺序
    一一对齐（同 owner 同名的重载不会互相吸行）；
  · 重命名：RENAMES 里登记的旧名 → 新名；
  · 补新增：清单里有、台账里没有的函数，按 EVIDENCE 补证据；缺证据时用占位文案
    并打印 `??`（`--strict` 下直接失败，防止"待补证据"混进主线）；
  · 丢弃：源码里已不存在的函数（真删）从台账移除。

不做什么
--------
不自动编造 evidence。新增函数的"为什么留"必须由人读源码后写进 EVIDENCE，
否则宁可在 `--strict` 下报红，也不要让台账变成一张没有信息量的表。

用法
----
    python3 tools/rebuild_ledger.py            # 重建并打印统计
    python3 tools/rebuild_ledger.py --strict   # 有缺证据条目时返回 1（闸门用）
"""
from __future__ import annotations

import collections
import csv
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV = os.path.join(ROOT, "docs", "40-审计与核对", "数据表", "FrsetNext-函数清单.csv")
LED = os.path.join(ROOT, "docs", "40-审计与核对", "数据表", "函数审阅台账.csv")
FUNC_KINDS = ("func", "init", "deinit", "subscript")

# 已重命名：台账旧名 → 现名
RENAMES = {
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "Coordinator", "checkCookies"): "check",
}

# 新增函数的证据（逐个读过源码后写；键 = (file, name)）
EVIDENCE = {
    ("Features/Panel/Preview/MainPanelPreviewPopoverCoordinator.swift", "hasPreview"):
        "刘海控制器收起时按来源窗口关闭共用预览，指针进入该预览时保留展开；只读取现有窗口与会话状态",
    ("Features/Island/IslandContent.swift", "updateTrackingAreas"):
        "记录行原生拖出视图沿可见范围接收悬停进入离开事件，重建跟踪区域时先移除旧区域",
    ("Features/Island/IslandContent.swift", "mouseEntered"):
        "展开中的刘海记录行把正式剪贴板条目及来源窗口坐标交给共用 rowHover，不读取正文或创建第二套预览",
    ("Features/Island/IslandContent.swift", "mouseExited"):
        "记录行离开时由共用 rowHover 取消待呈现任务并安排关闭，沿用主面板悬停时序",
    ("Features/Island/IslandContent.swift", "showPreview"):
        "刘海记录单击、回车与空格用同一个 present 入口，行边界经所属窗口换算为屏幕坐标；双击仍走原复制方法",
    ("Features/Monitor/Views/MonitorDetailView.swift", "powerGrid"):
        "功耗页六项芯片读数按两列或三列排布，ViewThatFits 随窗口宽度选择；共享 powerMetric，不重采样",
    ("Features/Monitor/Views/MonitorDetailView.swift", "powerMetric"):
        "功耗页系统/适配器、芯片及原始传感器共用标签与瓦数排版，沿用网络页 18pt 数字层级并保持缺读数状态",
    ("Features/Capture/Screenshot/CaptureActionToolbarView.swift", "reduce"):
        "合并三种动作条样式的按钮实际边界锚点，供同一浮层按触发图标定位并留出窗口边距",
    # ── v249–v258 ────────────────────────────────────────────────────────
    ("Features/Archive/UI/ArchiveBrowserWindow.swift", "stamp"):
        "v256 源包指纹（mtime+字节数）；init/confirmOverwriteIfSourceChanged/refreshSourceStamp 三处调用",
    ("Features/Archive/UI/ArchiveBrowserWindow.swift", "confirmOverwriteIfSourceChanged"):
        "v256 写回前三选确认（仍然保存/重新载入/取消）；addFiles/updateEntry/renameEntry/removeEntries 写操作前调用",
    ("Features/Archive/UI/ArchiveBrowserWindow.swift", "refreshSourceStamp"):
        "v256 写入成功后刷新指纹基线，避免自写内容被判成外部修改",
    ("Features/Archive/UI/ArchiveBrowserWindow.swift", "decideExtractConflicts"):
        "v256 解压前扫目标顶层同名项，返回 覆盖/跳过已存在/取消；extractAll 与 extractSelected 调用",
    ("Features/Archive/Table/ArchiveEntryTable.swift", "startHoverProbeIfNeeded"):
        "v258 排障探针 probe.archiveHover：列表就绪后依次悬停前 4 行，只读不写",
    ("Features/Monitor/Window/MonitorPopoutWindow.swift", "reverseToOpen"):
        "v257 收起途中被要求重开：复用已有帧反向播，不重抓快照",
    ("Features/Monitor/Window/MonitorPopoutWindow.swift", "parkOrigin"):
        "神灯展开前停靠屏幕上方之外（抓快照临时位，抓完移回）",
    ("Features/Monitor/Window/MonitorPopoutWindow.swift", "defaultSlot"):
        "无锚点路径兜底插槽（窗口上沿右侧 22pt 方块）",
    ("Features/StatusBar/StatusItemDropProxy.swift", "init"):
        "在状态栏按钮上加透明覆盖层并注册 fileURL 拖放（按钮不可子类化）",
    ("Features/StatusBar/StatusItemDropProxy.swift", "hitTest"):
        "恒返回 nil：拖放靠 registerForDraggedTypes 派发，点击仍落到 NSStatusBarButton",
    ("Features/StatusBar/StatusItemDropProxy.swift", "draggingEntered"):
        "有文件才给 .copy 并高亮",
    ("Features/StatusBar/StatusItemDropProxy.swift", "draggingUpdated"):
        "拖动中维持 .copy",
    ("Features/StatusBar/StatusItemDropProxy.swift", "draggingExited"):
        "拖出取消高亮",
    ("Features/StatusBar/StatusItemDropProxy.swift", "draggingEnded"):
        "拖放结束取消高亮",
    ("Features/StatusBar/StatusItemDropProxy.swift", "performDragOperation"):
        "先 ServiceLocator.panel?.show() 再发 .frsetTransferIntake（转入弹框挂在面板内容树）",
    ("Features/StatusBar/StatusItemDropProxy.swift", "hasFiles"):
        "pasteboard 是否含文件 URL",
    ("Features/StatusBar/StatusItemDropProxy.swift", "setActive"):
        "强调色底 22% alpha；仅状态变化时改 layer",
    ("Features/TransferDock/Transfer/TransferDockService.swift", "verifySession"):
        "v249 桥回验 status：写 cookie 成功≠会话有效（服务端可回 1003）",
    ("Features/TransferDock/Transfer/TransferDockService.swift", "archiveCookieEvidence"):
        "v249 覆盖前留证 credentials/evidence/cookies-时间戳.json，只留最近 20 份",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "userContentController"):
        "探针消息回调：记 path/cookie 长度/localStorage 键（同签名去重）",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "installProbe"):
        "每次页面落地重注入 setInterval 探针（跨页导航会清掉上一页）",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "detach"):
        "摘 frsetProbe handler + 清 interval + 停轮询",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "dumpCookieNames"):
        "排障：打印全部 cookie 的 domain/name",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "applyForceTick"):
        "「重新检测」按钮：tick 变化才执行，走 check(force: true)",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "check"):
        "抓取判定：会话类 cookie 名 / 从授权页回业务页 / 强制，三条件触发 onCandidate",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "webView"):
        "WKNavigationDelegate：didFinish 落页面 → 重装探针 + 立刻 check；didFail / didFailProvisional 只回进度文案",
    ("Features/TransferDock/UI/TransferIntakeDialog.swift", "card"):
        "转入弹框单选卡片（hover 高亮 + 描边，点击 onConfirm）",

    # ── v259：解析器修好后从 ClipboardRepository 找回的 16 条 ──────────────
    ("Features/Clipboard/Store/ClipboardRepository.swift", "fetch"):
        "读：拼 WHERE（appendClauses）+ ORDER BY timestamp DESC LIMIT/OFFSET，查完挂标签；ClipboardManager.reload 调用",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "count"):
        "计数：同一套 appendClauses 条件，分页总数用",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "item"):
        "按 dedupe_key 取单条（去重命中 / 编辑前刷新），取完挂标签",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "exists"):
        "去重判定：COUNT>0；ClipboardManager.writeToDatabase 入库前唯一调用点",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "insert"):
        "写：24 列 INSERT；UNIQUE(dedupe_key) 冲突按「已存在」返回 false，上层退化为置顶",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "touch"):
        "去重置顶：UPDATE timestamp",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "updateContent"):
        "编辑保存：回写 content/text_path/字行数/占用，title 同步为 content.firstLineBrief",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "updateAliasTitle"):
        "重命名：写 alias_title；空串按清除处理（写 NULL）",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "updateFields"):
        "工具回流与 OCR 回填：rich_text_path/image_path/thumbnail_path/storage_bytes/is_note 各自按需单条 UPDATE",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "delete"):
        "删条目：事务删行+标签，再回收 image/thumbnail/text/richText 四个落盘文件与 OCR 缓存",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "rowsOlderThan"):
        "时间保留期清理：早于 cutoff 的条目（ClipboardPruneSchedulers 调用）",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "oldestRows"):
        "容量超限清理：最旧 N 条",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "totalStorageBytes"):
        "SUM(storage_bytes)：存储占用统计（设置页配额）",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "makeItem"):
        "SQL 行 → ClipboardItem（24 列；tagIDs 留空由 TagStore 回填）",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "bindings"):
        "ClipboardItem → 24 个 SQLiteValue 绑定值（insert 唯一消费者）",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "escapeLike"):
        "LIKE 转义 \\ % _；v126 改 Array+join，避免字符串拼接 O(n²)",

    # ── v260：十张截图修复带出来的新函数 ──────────────────────────────────
    ("Core/UI/Support.swift", "scaledSystem"):
        "v260 全局字号缩放入口：.system(size:) × Personalization.fontScale，「界面字号」三项从此真正生效；Theme 字号统一走它",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "select"):
        "悬浮剪贴板按 item 反查 selectedIndex：外部点卡片时键盘选中位跟着同步，避免两套高亮",
    ("Features/Monitor/Views/BatteryPanel.swift", "designHealthRatio"):
        "v260 健康度副口径：满充/设计容量（第三方工具算法），与主口径（满充/标称，系统设置口径）并列展示并注明差异",
    ("Features/TransferDock/UI/TransferDockPreferences.swift", "migrateLegacyFeatureFlag"):
        "v260 拆键迁移：featureEnabled 缺失时从旧键 panelVisible 继承，老用户的「启用文件中转」状态不因换键丢失",

    # ── v261：解析器补 nonisolated 后找回的声明 ─────────────────────────
    ("Features/Monitor/Memory/ProcessFreezer.swift", "init"):
        "private init()：单例私有化，外部只能走 shared；同时挂激活通知/看门狗/过期计时器",
    ("Features/Monitor/Memory/ProcessFreezer.swift", "visibleWindowPIDs"):
        "用 CGWindowListCopyWindowInfo 取「屏幕上有窗口」的 pid 集合：有可见窗口的 App 一律不冻（冻住等于当面把窗口卡死；QQ/微信/浏览器靠这条躲过）",
    ("Features/Monitor/Memory/ProcessFreezer.swift", "collectCandidates"):
        "后台线程收集候选：只用 proc_* 接口（不碰 NSWorkspace.runningApplications——后台取会返回空），按主进程/helper .app 路径层级归组，排除前台、最近使用、受保护、有可见窗口",
    ("Features/Monitor/Memory/ProcessFreezer.swift", "isProtected"):
        "保护名单：系统壳、终端、IDE、虚拟机、会议与音视频、com.sxyq.* 自家，以及宿主 App（它是菜单栏应用、无可见窗口，「屏幕上有窗口」那条拦不住）",
    ("Features/Toolbox/Search/SearchSectionView.swift", "webView"):
        "nonisolated WKNavigationDelegate：didFinish / didFail 两个重载都回 MainActor resume navContinuation，等待导航时不会卡死或泄漏",
}

# ── v263：图帘（原悬挂架）整族函数 + 钉住多形态 ─────────────────────────
# 键是 (file, name)，同名函数（不同 owner）共用一条证据，所以文案写成合并描述。
EVIDENCE.update({
    # Controller
    ("Features/Capture/Curtain/CurtainController.swift", "init"):
        "单例私有 init：订阅 curtainPreferencesChanged / curtainToggleRequested",
    ("Features/Capture/Curtain/CurtainController.swift", "attach"):
        "截图落盘后挂载；manual=true 供动作条「挂到图帘」；缩略图按当前卡片宽解码",
    ("Features/Capture/Curtain/CurtainController.swift", "insert"):
        "新图插最左；超过 maxCards 从最旧挤掉（只出帘不删文件）",
    ("Features/Capture/Curtain/CurtainController.swift", "show"):
        "唤出入口：开关校验 + 空帘不显示 + 无动画重建后上屏",
    ("Features/Capture/Curtain/CurtainController.swift", "hide"):
        "只 orderOut，不动 items；下次唤出内容还在",
    ("Features/Capture/Curtain/CurtainController.swift", "dismissAll"):
        "关功能时销毁窗口并清空 items/缩略图/临时宽度",
    ("Features/Capture/Curtain/CurtainController.swift", "remove"):
        "移除单张；帘空则销毁窗口，否则原地重排并续计时",
    ("Features/Capture/Curtain/CurtainController.swift", "toggle"):
        "显示/收起切换（快捷键、菜单栏、设置页共用）",
    ("Features/Capture/Curtain/CurtainController.swift", "showPanel"):
        "上屏：重建 + orderFrontRegardless + 启动自动收起计时",
    ("Features/Capture/Curtain/CurtainController.swift", "ensurePanel"):
        "首次创建 Panel/Canvas，接移除/保存/钉图与 ⌘ 缩放回调",
    ("Features/Capture/Curtain/CurtainController.swift", "layoutMetrics"):
        "按屏幕宽反算能放下的卡片宽（张数多自动收窄）+ 卡片高度上限",
    ("Features/Capture/Curtain/CurtainController.swift", "contentSize"):
        "按实际卡片宽/缩放/间距算内容尺寸（帘线 + 最高卡 + 投影余量）",
    ("Features/Capture/Curtain/CurtainController.swift", "rebuild"):
        "统一重排：live 走 updateLayout（原地），否则 reload（可重播落入）",
    ("Features/Capture/Curtain/CurtainController.swift", "resizeStep"):
        "⌘ 拖动/滚轮每格：只改 liveCardWidth 并原地重排，不写偏好不发通知",
    ("Features/Capture/Curtain/CurtainController.swift", "resizeEnd"):
        "松手：临时宽度写回偏好、Toast 报数值、按需重解高清缩略图",
    ("Features/Capture/Curtain/CurtainController.swift", "upgradeThumbnailsIfNeeded"):
        "卡片 >220pt 后对不够清晰的缩略图后台重解一次",
    ("Features/Capture/Curtain/CurtainController.swift", "windowFrame"):
        "贴鼠标所在屏顶部居中；宽度夹进屏幕，避免大卡片时 x 为负",
    ("Features/Capture/Curtain/CurtainController.swift", "activeScreen"):
        "以鼠标所在屏为准（多显示器）",
    ("Features/Capture/Curtain/CurtainController.swift", "scheduleAutoHide"):
        "展示时长到点只收起，不清内容；0 = 永不收起",
    ("Features/Capture/Curtain/CurtainController.swift", "toggleRequested"):
        "curtainToggleRequested 通知入口（菜单栏/设置页）",
    ("Features/Capture/Curtain/CurtainController.swift", "preferencesChanged"):
        "开关关掉 → dismissAll；开着且可见 → 原地重排（不重播落入）",
    ("Features/Capture/Curtain/CurtainController.swift", "saveAs"):
        "卡片保存：NSSavePanel 另存，不移动暂存文件",
    ("Features/Capture/Curtain/CurtainController.swift", "pin"):
        "卡片钉住：从原文件解码后交给 PinnedScreenshotManager",
    ("Features/Capture/Curtain/CurtainController.swift", "runProbe"):
        "深链 curtainprobe：合成 N 张图挂帘，可指定宽度/允许抓屏/跑压测",
    ("Features/Capture/Curtain/CurtainController.swift", "runResizeSweep"):
        "缩放压测：140→420→140 共 30 帧，每帧真实 rebuild(live:) + displayIfNeeded，记录单帧最大耗时",
    ("Features/Capture/Curtain/CurtainController.swift", "probeImage"):
        "自检合成图：渐变底 + 标题/内容条 + 序号块",
    ("Features/Capture/Curtain/CurtainController.swift", "writePNG"):
        "自检图落盘到临时目录，返回 URL 供 attach",

    # Model
    ("Features/Capture/Curtain/CurtainModel.swift", "init"):
        "CurtainItem 值类型初始化（id/fileURL/createdAt/pixelSize）",
    ("Features/Capture/Curtain/CurtainModel.swift", "cardSize"):
        "卡片宽高：宽度按偏好，高度按原图比例并受 railScale 与屏幕高度上限双重约束",
    ("Features/Capture/Curtain/CurtainModel.swift", "normalized"):
        "旧值 twine（麻绳）归一化到 candyCane，升级后不会退回 classic",
    ("Features/Capture/Curtain/CurtainModel.swift", "make"):
        "按目标像素解码缩略图（ThumbnailFromImageAlways），避免整张大图常驻",
    ("Features/Capture/Curtain/CurtainModel.swift", "pixelSize"):
        "只读元数据像素尺寸，不解码整图（卡片长宽比用）",

    # Window / metrics
    ("Features/Capture/Curtain/CurtainWindow.swift", "ropeHeight"):
        "帘线区域高度 × 缩放（28pt @1×）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "ropeInset"):
        "线端距顶 12pt × 缩放（1Capture 反汇编 y = height - 12）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "sagMax"):
        "下垂上限 28pt × 缩放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "ropeEndInset"):
        "两端绳结留白 5pt × 缩放，最小 3pt",
    ("Features/Capture/Curtain/CurtainWindow.swift", "gap"):
        "卡片间距 16pt × 缩放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "padding"):
        "左右留白 22pt × 缩放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "clipHeight"):
        "夹子高度 20pt × 缩放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "bottomInset"):
        "窗口底部投影余量 12pt × 缩放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "cornerRadius"):
        "卡片圆角：宽×0.16 夹 8…25 再乘缩放（1Capture 写死 25，我们宽度可变）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "init"):
        "图帘各类型初始化：帘线几何 / 卡片（夹子+三按钮）/ 画布 / 面板（非激活浮窗）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "t"):
        "按 x 反解贝塞尔参数 t（控制点在 1/3、2/3，x(t) 精确线性）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "y"):
        "曲线上某点 y = y0 + 3·sag·t(1-t)",
    ("Features/Capture/Curtain/CurtainWindow.swift", "slope"):
        "切线斜率 dy/dx = 3·sag·(1-2t)/width，卡片倾斜用",
    ("Features/Capture/Curtain/CurtainWindow.swift", "tilt"):
        "卡片沿帘线切线倾斜，限幅 ±4°",
    ("Features/Capture/Curtain/CurtainWindow.swift", "update"):
        "⌘ 缩放时原地更新卡片尺寸/按钮位置并重绘，不重建视图、不重挂动画",
    ("Features/Capture/Curtain/CurtainWindow.swift", "draw"):
        "绘制入口：卡片（倾斜+缩略图+描边+夹子）与帘线（四样式+绳结）；缩放中卡片低插值",
    ("Features/Capture/Curtain/CurtainWindow.swift", "placeholderGradient"):
        "缩略图未解码时的占位渐变（1Capture 四段灰度 0.62/0.94/0.80/0.61，水平）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "drawClip"):
        "夹子：小梯形 + 投影 + 夹口暗线；尺寸乘 railScale",
    ("Features/Capture/Curtain/CurtainWindow.swift", "updateTrackingAreas"):
        "重建 .inVisibleRect 悬停追踪区（卡片尺寸变化后仍覆盖全卡）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "mouseEntered"):
        "悬停：停摆、显示保存/钉图/移除、上浮 2pt",
    ("Features/Capture/Curtain/CurtainWindow.swift", "mouseExited"):
        "移出：收起按钮、复位、恢复微摆",
    ("Features/Capture/Curtain/CurtainWindow.swift", "startSway"):
        "Card常驻摆动总入口仅在animatesIdleSway=true、未减少动态、未悬停且已有窗口时执行；正式默认true，预览false；沿用CABasicAnimation且已有摆动不重复挂载",
    ("Features/Capture/Curtain/CurtainWindow.swift", "stopSway"):
        "停止微摆（悬停/缩放/窗口收起时）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "viewDidMoveToWindow"):
        "窗口收起时撤动画，避免不可见图层空转",
    ("Features/Capture/Curtain/CurtainWindow.swift", "setupButtons"):
        "创建关闭/保存/钉图三个悬停按钮",
    ("Features/Capture/Curtain/CurtainWindow.swift", "layoutButtons"):
        "按钮位置/圆角随卡片尺寸与 railScale 走（⌘ 缩放每帧调用）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "configure"):
        "悬停按钮样式：无边框、白色图标、半透明黑底、圆角随缩放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "setButtonsHidden"):
        "统一显隐三个悬停按钮",
    ("Features/Capture/Curtain/CurtainWindow.swift", "removeTapped"):
        "关闭按钮 → 从图帘移除",
    ("Features/Capture/Curtain/CurtainWindow.swift", "saveTapped"):
        "保存按钮 → 控制器 saveAs",
    ("Features/Capture/Curtain/CurtainWindow.swift", "pinTapped"):
        "钉图按钮 → 控制器 pin 到屏幕",
    ("Features/Capture/Curtain/CurtainWindow.swift", "acceptsFirstMouse"):
        "首击即响应（图帘是非激活面板）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "mouseDown"):
        "卡片/画布按下：⌘ 进入缩放并记屏幕坐标；普通按下记录起点供拖出/点击判定",
    ("Features/Capture/Curtain/CurtainWindow.swift", "mouseDragged"):
        "⌘ 拖动按屏幕坐标增量缩放；否则卡片超过 4pt 拖出成文件",
    ("Features/Capture/Curtain/CurtainWindow.swift", "mouseUp"):
        "⌘ 缩放结束回调；普通点击复制图片；画布空白处只结束缩放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "scrollWheel"):
        "⌘ + 滚轮缩放图帘；非 ⌘ 交给系统",
    ("Features/Capture/Curtain/CurtainWindow.swift", "copyToPasteboard"):
        "卡片复制先交给宿主 onCopy 回调；正式图帘无回调时读取 PNG，同时写入图片数据及文件 URL",
    ("Features/Capture/Curtain/CurtainWindow.swift", "beginDrag"):
        "卡片拖出先交给宿主 onDrag 回调；正式图帘无回调时以文件 URL 和卡片快照开始复制拖放",
    ("Features/Capture/Curtain/CurtainWindow.swift", "snapshot"):
        "拖拽缩略图：优先用已解码 CGImage，避免再读原图",
    ("Features/Capture/Curtain/CurtainWindow.swift", "menu"):
        "右键菜单：复制/保存/在 Finder 显示/钉住/放大缩小图帘/移除",
    ("Features/Capture/Curtain/CurtainWindow.swift", "zoomIn"):
        "右键放大 40pt（走与 ⌘ 拖动同一条 resizeStep/resizeEnd）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "zoomOut"):
        "右键缩小 40pt（同 resizeStep/resizeEnd）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "copyFromMenu"):
        "右键「复制图片」→ copyToPasteboard",
    ("Features/Capture/Curtain/CurtainWindow.swift", "revealInFinder"):
        "有 onReveal 回调时只反馈预览定位动作；正式卡片使用 NSWorkspace 在 Finder 选中文件",
    ("Features/Capture/Curtain/CurtainWindow.swift", "draggingSession"):
        "拖出操作固定 .copy，不移动原文件",
    ("Features/Capture/Curtain/CurtainWindow.swift", "ropePath"):
        "帘线三次贝塞尔路径，两端留绳结位；inset 随 scale",
    ("Features/Capture/Curtain/CurtainWindow.swift", "drawKnots"):
        "两端绳结（实心圆 + 暗描边），半径/描边随 scale",
    ("Features/Capture/Curtain/CurtainWindow.swift", "clearShadow"):
        "清掉 CG 阴影，避免细芯/装饰重复投影",
    ("Features/Capture/Curtain/CurtainWindow.swift", "stroke"):
        "圆头描边封装（宽度/灰度/透明度）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "dashed"):
        "圆头虚线描边封装（拐杖糖红条纹）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "drawLights"):
        "圣诞彩灯：沿帘线等距、四色循环、低透明外圈当光晕",
    ("Features/Capture/Curtain/CurtainWindow.swift", "drawSnow"):
        "积雪：确定性伪随机球径 1.3–3.2pt，间距 6.5pt，随 scale",
    ("Features/Capture/Curtain/CurtainWindow.swift", "samplePoints"):
        "按 x 均匀取样再用贝塞尔求 y，间距随 scale",
    ("Features/Capture/Curtain/CurtainWindow.swift", "reload"):
        "重建卡片视图并排版；animate=false 用于缩放后的高质量重绘",
    ("Features/Capture/Curtain/CurtainWindow.swift", "updateLayout"):
        "⌘ 缩放专用：卡片数与 id 不变时只改尺寸/位置，不 remove/add 子视图",
    ("Features/Capture/Curtain/CurtainWindow.swift", "layoutCards"):
        "按item.cardSize累计卡片真实宽度并居中定位，创建新卡时传播Canvas.animatesIdleSway，原卡仅更新尺寸和辅助功能；新卡显式落入受减少动态控制，其余摆动交startSway统一判断",
    ("Features/Capture/Curtain/CurtainWindow.swift", "animateDrop"):
        "新增卡片播放位移、淡入及绕顶部衰减回弹；完成后调用startSway，由animatesIdleSway决定是否接常驻摆动，预览false仍保留显式落入效果",
    ("Features/Capture/Curtain/CurtainWindow.swift", "topPivot"):
        "把 CA 旋转中心从图层中心挪到顶部中心",

    # Pin appearance / action bar
    ("Features/Capture/Pin/PinWindow.swift", "init"):
        "PinAppearance.init建立单图外观值；PinImageView.init接收图像/尺寸/外观并一次取样描边色，正式PinnedScreenshotContentView继承它并挂控制条和鼠标追踪，预览使用同一图像基类",
    ("Features/Capture/Pin/PinWindow.swift", "preset"):
        "动作条四形态：经典/无边框/卡片/强调，数值与设置页预设一致，只影响这一张",
    ("Features/Capture/Screenshot/CaptureActionChain.swift", "pin"):
        "按形态钉住：PinAppearance.preset → show(appearance:) + Toast",
    ("Features/Capture/Screenshot/CaptureSettingsPane.swift", "row"):
        "截图设置页统一行（标题 + 控件 + 说明），与钉图/图帘页同构",

    # Settings / status bar
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "init"):
        "CurtainSettingsPane公共init创建页面外壳；SettingsDraftEditor以curtain标识按需借用CurtainSettingsDraft，实际偏好初值由草稿Values.current读取",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "row"):
        "图帘设置页统一行（74pt 标题列 + 控件 + 说明）",
    ("Features/Settings/Shell/SettingsWindowController.swift", "jumpCapture"):
        "截图与钉图页内跳转：同值时先归零再设回，重复深链也能重新定位",
    ("Features/StatusBar/StatusBarController.swift", "toggleCurtainAction"):
        "菜单栏「图帘」项：发 curtainToggleRequested，与快捷键/设置页同一入口",
})

# ── v267：截图覆盖层合并为「自适应」（取消窗口/区域模式选择）──────────────
EVIDENCE.update({
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "commitFullScreen"):
        "自适应覆盖层单击空白桌面：原生像素抓整屏（失败回退 SCK/legacy）→ finishRegion 统一收尾，历史标签 full",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "acceptsFirstMouse"):
        "首击即生效：App 未激活时 AppKit 会吞掉激活点击，覆盖层必须返回 true，否则要点第二次",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "windowRect"):
        "光标所在窗口的视图矩形，供拖框吸附丢弃「整窗大小」的 AX 命中（否则一拉就吸回整窗）",
})

# ── v264：存储索引扫全盘 + 自建全盘文件名索引 ────────────────────────────
EVIDENCE.update({
    ("Features/Monitor/Storage/DiskIndex.swift", "physicalSize"):
        "文件物理占用 = st_blocks×512（APFS 透明压缩下 st_size 会虚高，/System 差 17GB）",
    ("Features/Monitor/Storage/DiskIndex.swift", "decodeSnapshot"):
        "缓存格式迁移：先按二进制 plist 解，失败回落旧 JSON，升级后老缓存仍能读",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "statusLine"):
        "「已索引 X / 整盘已用 Y」+ 节点数 + 截断提示，把覆盖率摊开给用户看",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "openFullDiskAccessSettings"):
        "跳系统设置「完全磁盘访问权限」页，引导补全 TCC 保护目录",
    ("Features/Toolbox/Search/FileNameIndex.swift", "init"):
        "单例私有 init（零常驻：App 启动、面板打开都不会走到这里）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "preloadIfCached"):
        "面板出现时只 mmap 已有缓存，没有就保持「未建立」——不在这里触发建索引",
    ("Features/Toolbox/Search/FileNameIndex.swift", "rebuild"):
        "用户点「重建」：释放旧映射、删缓存文件、后台重扫",
    ("Features/Toolbox/Search/FileNameIndex.swift", "ensureReady"):
        "有缓存就 mmap，没有才后台建；只在用户真的搜文件时调用（零常驻）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "loadFromDisk"):
        "校验 magic/版本/长度后 mmap 整个池；锁内替换指针，避免搜索读到已释放的页",
    ("Features/Toolbox/Search/FileNameIndex.swift", "unmap"):
        "重建前释放旧映射（同时把 poolLength 归零，搜索会立刻返回空）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "build"):
        "后台遍历盲区根 → 扁平字节池 → 写盘 → 立刻 mmap 回来；每 2 万条回主线程报进度",
    ("Features/Toolbox/Search/FileNameIndex.swift", "walk"):
        "POSIX readdir 递归；目录留给下一层写（避免同一条写两遍），文件直接入池",
    ("Features/Toolbox/Search/FileNameIndex.swift", "roots"):
        "只取 Spotlight 不覆盖的：~ 下点开头目录、~/Library、/Applications、/opt、/usr/local",
    ("Features/Toolbox/Search/FileNameIndex.swift", "search"):
        "按字节子序列扫描完整 mmap 池，32 字符以上复用连续匹配口径；只解码命中项，先筛文件类型，再按正式 FuzzyMatcher 得分保留 limit 条，不因时间或前部命中数量漏掉后部目录",
    ("Features/Toolbox/Search/FileNameIndex.swift", "terms"):
        "普通关键词按全部空白分词并小写归一化，绝对路径保留内部空格",
    ("Features/Toolbox/Search/FileNameIndex.swift", "depth"):
        "路径深度（/ 的个数），用于「浅层优先」重排",
    ("Features/Toolbox/Search/FileNameIndex.swift", "u32"):
        "索引头小端 UInt32 解码",
    ("Features/Toolbox/Search/FileNameIndex.swift", "f64"):
        "索引头小端 Double 解码（建立时间）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "appendU32"):
        "索引头小端 UInt32 编码",
    ("Features/Toolbox/Search/FileNameIndex.swift", "appendF64"):
        "索引头小端 Double 编码",
    ("Features/Toolbox/Search/SearchSectionView.swift", "ago"):
        "「22 分钟前建立」相对时间文案",
    ("Features/Toolbox/Search/SearchSectionView.swift", "includes"):
        "FileNameIndex.search 在候选限额前按既有文稿、图片、影音、压缩、文件夹口径过滤隐藏目录记录；完整路径直达复用同一筛选",
    ("Features/Toolbox/Search/SearchSectionView.swift", "pathURL"):
        "文件搜索统一展开 ~/ 并标准化绝对路径，去除目录末尾 /；首页复用同一入口识别本机路径，避免自动网页抓取",
})

# ── v265：在线手册动图的加载与播放（上次提交漏补的证据）────────────────────
# 37 段 GIF 不入 App 包（DMG 会从 43 MB 涨到 81 MB），改成按需下载 + 落盘缓存；
# SwiftUI Image 只画首帧，必须落 NSImageView 才会动。
EVIDENCE.update({
    ("Features/Manual/ManualView.swift", "cachedFile"):
        "v265 把 gifs/xxx.gif 映射到 ~/Library/Caches/Kitnest/manual-gifs/xxx.gif；load/fetch 共用同一路径，下载落盘与下次读缓存必须一致",
    ("Features/Manual/ManualView.swift", "fetch"):
        "v265 从官网 remoteBase 拉单段 GIF，仅 HTTP 200 且能解码成 NSImage 才原子落盘并入内存缓存，回调回主线程；失败返回 nil，由视图给出在线手册入口",
    ("Features/Manual/ManualView.swift", "makeNSView"):
        "v265 SwiftUI Image(nsImage:) 只画 GIF 首帧，改用 NSImageView 并开 animates=true 才能真正播放动图；缩放用 scaleProportionallyUpOrDown",
    ("Features/Manual/ManualView.swift", "updateNSView"):
        "v265 复用视图时按对象身份比对换图，重设 image 与 animates，避免翻章后停在上一章的静帧",
    ("Features/Manual/ManualView.swift", "sizeThatFits"):
        "v265 NSViewRepresentable 无固有尺寸，按图片宽高比回报（上限 520pt），否则会撑满正文区把 4:3 录屏拉成竖条并裁掉右侧",
    ("Features/Manual/ManualView.swift", "start"):
        "v265 onAppear 触发三级取图（内存→随包→磁盘缓存），都没有才联网补；失败计数置位后显示在线手册按钮，不伪装成有内容",
})

# ── v266：截图默认窗口自动识别 + 同一次截图里可直接拖拽拉自定义框 ──────────
EVIDENCE.update({
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "startCapture"):
        "v266 统一截图入口：先异步校验屏幕录制权限，再带 flow 与初始拾取方式建覆盖层；区域/窗口/直接 OCR/钉图/复制/翻译六条链路共用",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "beginCapture"):
        "v266 合并 beginRegionCapture/beginWindowCapture：按 initialMode 建窗，区域/单窗/多窗/模式切换四类回调一次接齐，历史模式标签随实际模式走",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "setPickMode"):
        "v266 W 键与顶部开关共用的切换入口：清选区/高亮/多选状态、同步控件并回调；切换只对本次生效，不写默认偏好",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "modeControlChanged"):
        "v266 顶部 NSSegmentedControl 的 action：把选中段映射成 .window / .region",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "syncModeControl"):
        "v266 pickMode didSet 时回写分段控件选中态，保证键盘 W 切换与开关显示始终一致",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "positionModeControl"):
        "v266 把开关与不透明底板固定在距顶 64pt，避开刘海与菜单栏；draw 每帧调用，frame 不变时无副作用",
})

# ── v272：统一窗口内容挂载与设置二级导航 ───────────────────────────────
EVIDENCE.update({
    ("Core/UI/OfficialWindowChrome.swift", "setOfficialContent"):
        "替换 NSView/NSViewController 内容后重挂统一玻璃底，避免底层仍附着在旧 contentView",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "tagCountText"):
        "按标签数量选择本地化单复数格式，供剪贴板标签行显示计数",
    ("Features/Settings/Shell/SettingsNavigation.swift", "group"):
        "由二级 SettingsPage 反查一级 SettingsGroup，统一驱动分组高亮与导航归属",
    ("Features/Settings/Shell/SettingsSidebarView.swift", "init"):
        "将旧深链/搜索的 0…4 下标映射回 CaptureSettingsBlock，维持现有入口定位",
    ("Features/Settings/Shell/SettingsSidebarView.swift", "groupHeader"):
        "渲染一级目录并把点击映射到该组首个二级页",
    ("Features/Settings/Shell/SettingsSidebarView.swift", "footerChip"):
        "渲染设置侧栏底部的数据、关于、手册入口并更新当前二级页",
})

# ── 2026-11-12：截图、剪贴板与界面交互更新 ─────────────────────────────
EVIDENCE.update({
    ("Features/Archive/Core/ArchiveServices.swift", "refresh"):
        "从 NSWorkspace 读取 ZIP 实际默认应用，供教程与设置共用开关显示状态和应用名称",
    ("Features/Archive/Core/ArchiveServices.swift", "setEnabled"):
        "用户切换开关时设置 ZIP 默认应用或恢复此前应用，系统操作完成后显示实际关联与失败原因",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "sampledPoints"):
        "按指定间距采样正式曲线路径，为异形布局与液态轮廓提供静态点集，悬停时复用缓存",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "navigate"):
        "进入目录或点击面包屑时记录实际访问路径，并删除游标之后的旧前进记录",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "header"):
        "按窗口宽度将统计说明放在弧线外的左上区域，保留右上方扫描、记录与设置操作",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "leftPane"):
        "在连续弧线外展示全部真实清理记录，顶部保留选择与清理操作，列表独立滚动填满左侧区域",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "candidateWidth"):
        "从同一存储图轮廓求记录所在高度的可用宽度，使行内容跟随弧线缩窄而不被曲边截断",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "navigateHistory"):
        "按访问历史游标向前或向后一步，供按钮、快捷键及双指手势共用",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "makeNSView"):
        "创建只负责图形区域双指导航的 AppKit 视图，将方向传回现有根视图",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "updateNSView"):
        "同步 SwiftUI 最新导航回调到现有手势视图，不重建事件监听器",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "init"):
        "手势视图初始化保存导航回调；窗口控制器与 coder 初始化沿用现有原生窗口约定",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "hitTest"):
        "手势背景视图不承接点击，让前景的目录块保持原有命中与点击行为",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "viewDidMoveToWindow"):
        "视图进入窗口后挂载滚动事件监听，离开原窗口时移除旧监听",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "installSwipeMonitor"):
        "只在异形图区域累计真实触控板横向滚动，42pt 后按实际手指方向执行一次左退右进",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "deinit"):
        "图形手势视图销毁时移除 AppKit 本地事件监听，释放该区域的滚动处理",
    ("Core/UI/LiquidGlass.swift", "setContent"):
        "替换统一玻璃容器的内容视图并按 topInset 重排内部区域",
    ("Core/UI/OfficialWindowChrome.swift", "applyOfficialBackground"):
        "窗口设为透明底色，由统一玻璃容器提供可见背景",
    ("Features/Capture/OCR/ScreenshotOCRWindow.swift", "replacePreservingScroll"):
        "替换 OCR 文本后恢复滚动坐标并刷新 clip view",
    ("Features/Capture/OCR/ScreenshotOCRWindow.swift", "organizeText"):
        "调用 ClipboardTextTransforms.organizeOCR 生成整理稿并切换版本控件",
    ("Features/Capture/OCR/ScreenshotOCRWindow.swift", "versionChanged"):
        "在识别原文与整理稿间切换，保持滚动位置并同步编辑状态",
    ("Features/Capture/OCR/ScreenshotOCRWindow.swift", "updateTextInfo"):
        "同步复制按钮标题、识别字数、换行整理反馈和按钮可用状态",
    ("Features/Capture/Screenshot/ColorValuePanel.swift", "cancelOperation"):
        "把 Escape 取消动作转发到色值面板关闭回调",
    ("Features/Capture/Screenshot/ColorValuePanel.swift", "windowDidResignKey"):
        "色值窗失去键盘焦点后请求 TransientWindowCenter 收起",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "handleScreenshotShortcut"):
        "快捷键在选择窗前重复时保持窗口；截图进行中再次触发则取消并打开近期选择窗",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "openRecentClipboard"):
        "通过共享 RecentClipboardWindowController 打开选择窗并记录返回应用",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "commitWindows"):
        "逐窗调用 ScreenSnapshot，失败时从覆盖层快照裁切，再按 pendingFlow 交付合成图",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "composeVertically"):
        "按 16pt 间隔、24pt 留白纵向拼图，并把输出控制在 120MP 内",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "commitMultiWindows"):
        "按用户勾选顺序生成窗口矩形列表并提交给 ScreenshotManager",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "toggleMultiSelection"):
        "按 windowID 添加或移除窗口，并重绘已选状态",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "constrained"):
        "优先应用已设定比例，否则按住 Shift 生成正方形选区",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "drawWindowMultiHint"):
        "展示已选窗口数、回车提交、Command 点选增删与 Escape 取消提示",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "drawHint"):
        "顶部居中绘制截图说明，并附当前截图快捷键对应的近期复制提示",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "drawWindowSelection"):
        "给已选窗口绘制强调色蒙层、描边和顺序编号",
    ("Features/Clipboard/Store/ClipboardManager.swift", "pauseRecording"):
        "设置可选恢复时限、刷新剩余分钟并发布暂停通知与提示",
    ("Features/Clipboard/Store/ClipboardManager.swift", "resumeRecording"):
        "清除剪贴板暂停状态并按调用选项显示恢复提示",
    ("Features/Clipboard/Store/ClipboardManager.swift", "refreshPauseDeadline"):
        "根据截止时间更新剩余分钟并在到期时恢复记录；无截止时间时清空分钟数",
    ("Features/Clipboard/Store/ClipboardManager.swift", "copyText"):
        "写入纯文本剪贴板，失败返回原因，成功统一调用 finishCopy",
    ("Features/Clipboard/Store/ClipboardManager.swift", "copyFiles"):
        "写入非空文件URL列表成功后立即回读系统剪贴板并交insert入历史，再调用finishCopy记录成功；中转复制文件与单项文件菜单共用此路径",
    ("Features/Clipboard/Store/ClipboardManager.swift", "copyImageFile"):
        "确认图片持久文件可读后沿用 copyFiles 复制图片文件 URL",
    ("Features/Clipboard/Store/ClipboardManager.swift", "finishCopy"):
        "写入自有剪贴板标记与变更计数、登记统计事件并显示成功 Toast",
    ("Features/Clipboard/Store/ClipboardTextTransforms.swift", "combine"):
        "按选定格式将多段原文以换行或缩进编号合并",
    ("Features/Clipboard/Store/ClipboardTextTransforms.swift", "deduplicate"):
        "按行去重，可选忽略大小写或首尾空白，并返回移除数量",
    ("Features/Clipboard/Store/ClipboardTextTransforms.swift", "cleanLink"):
        "移除常见跟踪参数，签名链接保持原样并回报移除项数",
    ("Features/Clipboard/Store/ClipboardTextTransforms.swift", "organizeOCR"):
        "合并符合中英文续行条件的 OCR 断行，保留列表、缩进和结构行",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "quickActions"):
        "按 JSON、链接和富文本类型提供对应的剪贴板快捷动作",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "items"):
        "按记录类型提供复制图片文件、格式化、二维码、去重、纯文本与清链动作",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "body"):
        "读取记录完整正文；读取失败时将原因显示为提示并终止动作",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "tool"):
        "把正文交给工具窗执行，并先关闭预览和主面板",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "plainText"):
        "通过 ClipboardManager.copyText 复制富文本记录的纯文本",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "cleanLink"):
        "清除可移除的链接追踪参数，并明确保留签名参数时的结果提示",
    ("Features/Clipboard/UI/ClipboardTableHostView.swift", "mouseDown"):
        "整行支持单击预览、双击复制及 Command/Shift 多选，并把键盘焦点交给列表",
    ("Features/Clipboard/UI/ClipboardTableHostView.swift", "toggleRowSelection"):
        "切换指定行的选择状态，Shift 将锚点至当前行合并为连续范围",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "init"):
        "创建 380pt 紧凑选择窗；列表行由复选框、类型图标、摘要和相对时间构成，底栏提供计数、取消和复制",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "show"):
        "复用单例窗口；空入口默认不选，读取最新记录并按不超过五行调整窗高",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "numberOfRows"):
        "向 NSTableView 返回当前可见记录数",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "tableView"):
        "构建带复选框、类型图标、内容摘要、时间和键盘焦点的列表行",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "tableViewSelectionDidChange"):
        "列表选择变化时更新行内复选框和键盘焦点外观",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "select"):
        "单击切换单行，Shift 扩展连续范围，并即时刷新已选数量",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "updateSelection"):
        "同步已选计数、复制按钮和文字与媒体混选说明",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "isText"):
        "区分文字、链接、富文本与图片、文件以呈现混选原因",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "refreshCells"):
        "刷新可见行复选框和当前键盘焦点描边",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "checkTapped"):
        "复选框动作复用整行选择逻辑并传递当前修饰键",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "cancelTapped"):
        "取消按钮关闭选择窗并返回触发前的应用",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "copyTapped"):
        "底栏复制按钮转发到统一的选中记录复制方法",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "copySelected"):
        "按最新到最旧的列表顺序调用 ClipboardManager 批量复制，失败保留勾选并显示原因",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "close"):
        "短淡出后收起窗口、复位动画状态并激活原应用；尊重减少动态效果",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "windowWillClose"):
        "原生关闭按钮关闭时使异步加载作废并返回触发前的应用",
    ("Features/Clipboard/UI/RecentClipboardWindow.swift", "draw"):
        "仅为键盘当前行绘制强调色焦点描边",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "refreshDiskSpace"):
        "首开、快照变化、清理后及应用回到前台时读取可用空间、数据卷已用字节和完全磁盘访问状态；视图刷新复用展示值",
    ("Features/Monitor/Storage/StorageTreemap.swift", "scale"):
        "LiquidTileDrawing.animatableData 传入 SwiftUI 动画的顶点向量按弹性插值比例缩放，单次插值共用填色、裁切、同心线和描边",
    ("Features/Monitor/Storage/StorageTreemap.swift", "inradius"):
        "DiskVoronoiLayout.make 在布局时计算标签质心到各边的最小距离，供标签档位和宽度复用；悬停不再求内切圆半径",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "displayPath"):
        "StorageCandidateRow 显示当前用户目录的短路径，唯一实现从根视图迁入候选行，悬停只更新当前行",
    ("Features/Monitor/Storage/StorageTreemap.swift", "func"):
        "PolygonAnimatableVector 的 + / - 实现 VectorArithmetic，逐顶点合成与相减动画向量",
    ("Features/Monitor/Storage/StorageTreemap.swift", "path"):
        "StorageManagerRootView.rightPane 以 StorageMapShape 裁剪整栏，左缘曲线从左下连续接到上缘内收点",
    ("Features/Monitor/Storage/StorageTreemap.swift", "liquidPoints"):
        "tileView 将 hoverPoint 周边的高斯压力施加到 Voronoi 顶点，减少动态效果时返回原多边形",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "makeNSView"):
        "PreviewWindowChrome 向内嵌 NSView 添加 macOS 标准关闭/最小化/缩放按钮，统一绑定 Coordinator.press，仅作用预览场景",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "updateNSView"):
        "更新 PreviewWindowChrome 的协调器 onPress 为最新场景闭包，保留三颗原生按钮实例",
    ("Features/StatusBar/StatisticsRootView.swift", "moveFocus"):
        "按左右每周七天、上下逐日移动活动矩阵键盘焦点",
    ("Features/StatusBar/StatisticsRootView.swift", "showKeyboardCell"):
        "忽略未来日期并同步高亮日期及提示框锚点",
    ("Features/StatusBar/StatisticsRootView.swift", "sizeThatFits"):
        "提示框布局占用矩阵全宽，不额外撑高父级布局",
    ("Features/StatusBar/StatisticsRootView.swift", "placeSubviews"):
        "将日期提示框定位在对应日期格上方，并限制在矩阵宽度内",
    ("Features/StatusBar/StatusBarController.swift", "updatePauseBadge"):
        "按剪贴板暂停状态更新菜单栏徽标和图标提示文字",
    ("Features/StatusBar/StatusBarController.swift", "pauseRecordingAction"):
        "根据菜单项分钟数恢复记录、定时暂停或暂停至手动恢复",
    ("Features/StatusBar/StatusBarMenuBuilder.swift", "refreshPauseMenu"):
        "刷新暂停菜单状态，提供立即恢复及 5、15、30 分钟和手动暂停选项",
    ("Features/Toolbox/Calendar/CalendarService.swift", "refreshAuthorization"):
        "读取 EventKit 完整日历访问状态并同步未授权说明",
    ("Features/Toolbox/Calendar/CalendarService.swift", "requestAccess"):
        "macOS 14 请求完整事件访问，旧系统沿用 EventKit 事件授权接口",
    ("Features/Toolbox/Shell/ToolboxSectionView.swift", "completed"):
        "更新工具结果提示并短暂显示复制完成状态",
    ("Features/Toolbox/Tools/BuiltinTools.swift", "registerDeduplicateTool"):
        "注册按整行去重工具，并将行数与移除数量写入输出说明",
    ("Features/Toolbox/Tools/MediaTools.swift", "inputInfo"):
        "读取图片格式、透明通道和帧数；拒绝无法解码或含多帧的动图",
    ("Features/Toolbox/Tools/ToolRunnerWindow.swift", "reveal"):
        "标准调用使用窗口锚点动画，预览调用使用 0.16 秒淡入",
    ("Features/TransferDock/Cast/CastControlBar.swift", "isAttached"):
        "通过进程 PID 判断 scrcpy 控制条是否附着到当前投屏窗口",
    ("Features/TransferDock/Transfer/LanTransferServer.swift", "selectionURL"):
        "为选中文件生成独立令牌和带 pick 参数的局域网分享链接",
    ("Features/TransferDock/UI/BatchImageCompressionWindow.swift", "init"):
        "建立共享压缩窗口、绑定原生内容和 Return/Escape 键行为",
    ("Features/TransferDock/UI/BatchImageCompressionWindow.swift", "show"):
        "复用可见窗口；重置图片队列、压缩选项和状态后淡入显示",
    ("Features/TransferDock/UI/BatchImageCompressionWindow.swift", "startCompression"):
        "按队列调用 ImageCompressor，逐项更新结果与失败状态并登记成功文件",
    ("Features/TransferDock/UI/BatchImageCompressionWindow.swift", "copyResults"):
        "将压缩结果文件 URL 一次写入剪贴板并显示成功状态",
    ("Features/TransferDock/UI/BatchImageCompressionWindow.swift", "viewInTransferDock"):
        "关闭压缩窗并打开文件中转面板中的中转页",
    ("Features/TransferDock/UI/BatchImageCompressionWindow.swift", "cancelOrClose"):
        "压缩期间请求停止；空闲时关闭窗口",
    ("Features/TransferDock/UI/BatchImageCompressionWindow.swift", "windowShouldClose"):
        "关闭窗口时先请求停止压缩并阻止任务运行中的窗口销毁",
    ("Features/TransferDock/UI/TransferDockView.swift", "copySelectedMetadata"):
        "预览仅设置copyCompleted和本地反馈；正式按选择复制文件名或仍可用路径，提示不可用文件数量",
})


# ── 2026-11-13：七页外观草稿实时预览、保存才应用 ───────────────────────
EVIDENCE.update({
    ("Core/Runtime/Personalization.swift", "makeDraft"):
        "AppearanceSettingsDraft 初始化与 discard 调用：创建 persistsChanges=false 的 Personalization，再经 copyValues 复制当前外观；草稿属性变更只发布到预览，不写偏好",
    ("Core/Runtime/Personalization.swift", "applyDraft"):
        "模块保存传入明确的DraftField列表，在isLoading期间只复制该模块字段，随后flushPersist(keys:)只写这些偏好并发外观变化通知，避免覆盖其他页已保存值",
    ("Core/Runtime/Personalization.swift", "copyValues"):
        "makeDraft共用完整外观复制入口，同步强调色、字号、密度、圆角、动画、悬停预览、材质、徽章、缩略图、通知、分隔线、Midnight、背景和玻璃参数共20项",
    ("Core/UI/AppearanceTheme.swift", "baseBackground"):
        "AppearanceThemeModifier 与 Theme.windowSurface(for:midnight:) 调用：将指定 Personalization.midnightHueShift 传给 h，生成 Midnight 窗口基色；静态属性继续传 shared",
    ("Core/UI/AppearanceTheme.swift", "cardBackground"):
        "AppearanceThemeModifier 与 Theme.cardFill(for:midnight:) 调用：按指定草稿 glassCardLift/0.55 提升 RGB 基色，再经 h 应用 midnightHueShift，使卡片亮度和色相随预览更新",
    ("Core/UI/AppearanceTheme.swift", "textColor"):
        "AppearanceThemeModifier.body 调用并注入 midnightTextColorOverride：冷白蓝文本色经 h 应用指定草稿的 midnightHueShift，与预览背景使用同一色相设置",
    ("Core/UI/LiquidGlass.swift", "applyPreviewStyle"):
        "LiquidGlassBackground.makeNSView/updateNSView 的设置预览分支共用：按预览 colorScheme 设置 aqua/darkAqua，按草稿材质选择 hudWindow/windowBackground，并固定 withinWindow 混合",
    ("Core/UI/Support.swift", "init"):
        "ThemeAppearance.init 保存传入的 Personalization 与 isMidnight；AppearancePreviewBlock、PanelRootView、剪贴板、Toast、GlassSurface/GlassCard 共用其颜色和尺寸属性，预览传草稿、正式视图传应用值",
    ("Core/UI/Support.swift", "windowSurface"):
        "ThemeAppearance.windowSurface 与 Theme 静态属性调用：读取指定 Personalization.glassOpacity；Midnight 使用同对象基色，普通主题经 cachedSurface 按系统明暗生成窗口底色与透明度",
    ("Core/UI/Support.swift", "glassFrost"):
        "GlassSurface → ThemeAppearance.glassFrost → Theme.glassFrost(for:)：读取指定草稿 glassBlur，经 cachedSurface 生成白色霜感层，深浅色透明度分别为 0.11×blur 与 0.20×blur",
    ("Core/UI/Support.swift", "cardFill"):
        "GlassCard、剪贴板卡片与缩略图 → ThemeAppearance.cardFill：Midnight 传同对象给 cardBackground，普通主题读取 glassCardLift，深浅色透明度分别为 0.035+0.065×lift 与 0.55+0.43×lift",
    ("Core/UI/Support.swift", "insetFill"):
        "FloatingClipboardDeskView.previewPane → ThemeAppearance.insetFill：从指定草稿 glassOpacity 求 k=0.6+0.4×opacity，生成深浅色透明度为 0.22×k/0.045×k 的黑色内嵌区底色",
    ("Core/UI/Support.swift", "cardStroke"):
        "GlassCard、剪贴板行和 AppearancePreviewBlock 外框 → ThemeAppearance.cardStroke：读取指定草稿 glassStroke，深色白边/浅色黑边透明度分别为 0.02+0.16×stroke 与 0.02+0.14×stroke",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "init"):
        "AppearanceSettingsDraft.init 接收模块 scope 并订阅个性化/悬浮窗草稿；AppearanceSettingsEditor 和 PersonalizationSettingsView 接收 scope/draft；原生窗口按钮 Coordinator.init 保存场景 onPress 回调",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "observeChanges"):
        "合并 personalization 与 floating 的 objectWillChange 并转发到外观草稿，使缓存编辑器和正式预览同步重绘，不再通过 previewRevision 重建内容",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "save"):
        "按 scope 只应用该页面板、悬浮窗、动作条或主题字段，再经 Personalization.applyDraft 写该模块 DraftField；synchronize 失败保留草稿并返回原因，成功更新保存快照",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "discard"):
        "调用 reloadSavedValues(preservingOwned:false) 重新读取应用保存值，再更新 savedPersonalization 和该模块 savedValues，取消当前页编辑",
    ("Features/Settings/Shell/SettingsPanes.swift", "appearanceChoices"):
        "通用外观四选 Picker 双向绑定当前 AppearanceSettingsDraft.appearance；正式主题只由 shared scope 的 save 调用 AppearanceManager.apply",
})


# ── 2026-11-13：中央草稿与正式组件的固定内容预览 ─────────────────────
EVIDENCE.update({
    ("Core/Runtime/Personalization.swift", "init"):
        "Personalization.init 仅在 persistsChanges=true 时装载偏好；DraftField.init 将可写键路径与偏好键配成 copy/matches 闭包，供模块草稿只应用并比较自己拥有的字段",
    ("Core/Runtime/Personalization.swift", "makeDefaultDraft"):
        "AppearanceSettingsDraft.restoreDefaults 调用：创建不装载偏好、不会持久写入的 Personalization，按模块 DraftField 取其出厂值",
    ("Core/Runtime/Personalization.swift", "flushPersist"):
        "普通属性持久写入全部外观值；applyDraft 传 keys 时只写本模块字段，nil 缩略图值移除对应偏好，最后发外观变化通知",
    ("Core/Runtime/Personalization.swift", "load"):
        "装载个性化偏好时按键是否存在选默认值，保留已保存的字号、圆角、通知时长、描边透明度、背景压暗值 0 与 hoverPreviewEnabled=false",
    ("Features/Capture/Annotation/Watermark.swift", "save"):
        "CaptureAppearanceDraft.save 调用 Configuration.save，一次应用启用、文字、透明度、旋转角度、平铺及字号比例六个水印偏好",
    ("Features/Capture/Annotation/Watermark.swift", "applied"):
        "正式截图重载读取 Configuration.current，设置预览重载接收草稿配置；两者共用 CGContext 绘字，允许透明度 0，平铺和右下单枚均按配置角度旋转",
    ("Features/Capture/Curtain/CurtainWindow.swift", "refreshAccessibility"):
        "CurtainCanvasView.layoutCards 给每张卡片同步辅助功能：降低透明度时三颗操作按钮用不透明黑底，减少动态时移除图层动画并复位变换",
    ("Features/Capture/Curtain/CurtainWindow.swift", "metrics"):
        "正式 ImageCurtainController.layoutMetrics 与 CurtainPreviewScene.render 共用：两轮按可见宽度和卡片数反算卡宽，帘线缩放夹在 0.8…3，并扣除绳高与底边求卡片高度上限",
    ("Features/Capture/Curtain/CurtainWindow.swift", "stopAnimations"):
        "为全部画布卡片设置reduceMotion并移除图层动画，供预览收起、禁用及卸载停止摆动，保留卡片内容和视图",
    ("Features/Capture/Pin/PinWindow.swift", "applyPreset"):
        "PinAppearance.preset 与设置页共用四种外观赋值：经典 1.5pt/10pt、无边框 0/0、白色卡片 2pt/16pt、强调描边 2pt/12pt，保留吸附、不透明度和控制条时长",
    ("Features/Capture/Pin/PinWindow.swift", "snapped"):
        "正式钉图与内嵌 PinPreviewScene 共用纯坐标计算：距可见区域或其他钉图的边缘小于 8pt 时吸附，返回新的窗口原点",
    ("Features/Capture/Pin/PinWindow.swift", "draw"):
        "PinImageView 同时承载正式钉图和预览：按圆角裁剪、四分之一圈旋转、水平/垂直翻转及不透明度绘制图像，描边向内缩半线宽避免边缘裁掉",
    ("Features/Capture/Screenshot/CaptureActionChain.swift", "pick"):
        "动作条统一选中入口：设置预览按工具 id 找标题并发布 previewFeedback；正式路径只调用 onPick，预览不进入截图动作执行链",
    ("Features/Capture/Screenshot/CaptureActionToolbarView.swift", "makeBody"):
        "三种动作条按钮共用按下外观：透明度降为 0.7，普通模式缩至 0.96 并用 0.1 秒动画，减少动态时保留透明反馈而取消缩放和动画",
    ("Features/Capture/Screenshot/CaptureActionToolbarView.swift", "thumbnail"):
        "正式动作条与设置预览共用截图缩略图：按比例适配到 340×200pt，裁圆角并画发丝边；拖到外部应用仅由正式路径附加",
    ("Features/Capture/Screenshot/CaptureActionToolbarView.swift", "pick"):
        "主动作及子动作按钮先 collapse 清理悬停和展开状态，再转给 CaptureToolbarModel.pick，由模型区分正式执行与预览反馈",
    ("Features/Capture/Screenshot/CaptureActionToolbarView.swift", "collapse"):
        "点击背景、缩略图或执行动作时取消 hoverTask，清空两种悬停值并收起展开组；减少动态时即时收起",
    ("Features/Capture/Screenshot/CaptureActionToolbarView.swift", "handleHover"):
        "动作条悬停使用可取消 Task：进入组 300ms 后展开、离开 220ms 后收起，新悬停替换旧任务，视图消失时取消",
    ("Features/Capture/Screenshot/CaptureSettingsPane.swift", "chooseDirectory"):
        "截图设置的目录选择器仅接受文件夹，选中后更新 savePath 并写 ScreenshotManager.saveDirectory；保存路径沿用独立设置，不进入外观草稿",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "setPreviewItems"):
        "仅设置预览Store接收AppearancePreviewBlock按SettingsPreviewSamples原顺序传入的固定条目，不按代表场景重排；缓存每条内联预览模型并本地reload，真实剪贴板仓库不参与",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "reload"):
        "预览 Store 同步按类型和搜索词过滤内存条目，保留选中 id 并重建右栏模型；正式 Store 沿用可取消防抖工作与 SQLite 读取",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "paste"):
        "预览双击只选择条目；正式路径先收起面板和归还焦点，再调用 ClipboardManager.copy 自动粘贴",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "delete"):
        "预览删除只移除 previewSource 并本地重筛；正式路径删除仓库条目并防抖重载",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "rebuildPreviewModel"):
        "预览选中项直接从 previewContents 取内联模型；正式路径继续在后台读取长文本及富文本文件",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "dragProvider"):
        "预览拖放返回空 NSItemProvider，不提供固定示例的文件或正文；正式路径按文本、富文本、图片和文件类型构造可拖内容",
    ("Features/Clipboard/Store/ClipboardManager.swift", "matches"):
        "主剪贴板和悬浮窗的固定预览共用九类过滤：按条目类型、https 链接前缀、代码/JSON 分类、colorpicker 来源、工具生成标记及笔记标记匹配",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "selectPreview"):
        "固定列表点击、悬停和方向键共用：更新本地 previewSelectedID，并写入可选 settingsPreviewClipboardSelection 绑定，不复制或打开内容",
    ("Features/Recording/RecordingCompositor.swift", "composite"):
        "ScreenRecorder 正式视频帧与 RecordingAppearancePreview 共用 CIImage 合成：按位置/比例叠摄像头、按区域原点及 pixelScale 定位点击环，最后把最多四键键帽条居中置于底部",
    ("Features/Recording/RecordingCompositor.swift", "keyOverlay"):
        "按传入 RecordedKey 绘制最多四个键帽并按时间淡出；预览可传 reduceTransparency=true 将键帽底从 0.82 改为不透明",
    ("Features/Recording/RecordingCompositor.swift", "clickOverlay"):
        "按传入 progress 和左右键在 160×160 画布绘制中心点及两圈扩散环；降低透明度时使用不透明填色和环线",
    ("Features/Capture/Screenshot/CaptureAppearanceDraft.swift", "init"):
        "读取声音、OCR 语言/自动识别/结果窗、默认动作、延迟、固定比例、文件名、OCR 提示、文字马赛克及水印为 Values 和 saved，供 isDirty 比较",
    ("Features/Capture/Screenshot/CaptureAppearanceDraft.swift", "save"):
        "统一保存先处理未完成的自定义比例并编码比例数组，失败返回具体原因；成功后应用截图/OCR/命名/通知/马赛克及水印偏好，再更新 saved",
    ("Features/Capture/Screenshot/CaptureAppearanceDraft.swift", "discard"):
        "取消截图外观编辑时还原 saved，清空未添加比例的名称和宽高输入，不写任何截图偏好",
    ("Features/Capture/Screenshot/CaptureAppearanceDraft.swift", "restoreDefaults"):
        "恢复本模块默认只用 Values() 替换草稿，并清空比例输入；保存后才应用默认声音、语言、动作及水印等值",
    ("Features/Capture/Screenshot/CaptureAppearanceDraft.swift", "addRatio"):
        "解析两个正整数宽高；命中内置或已有自定义比例时选中原项，否则向草稿追加新比例，完成后清空名称和宽高输入",
    ("Features/Recording/RecordingAppearanceDraft.swift", "init"):
        "将当前帧率、音频来源、鼠标显示、摄像头设备/位置/大小、按键/点击及排除应用读取为 values 和 saved",
    ("Features/Recording/RecordingAppearanceDraft.swift", "save"):
        "统一保存将十项录屏 Values 写入 RecordingOptions，包括 excludedBundleIDs；写入后更新 saved 并以 nil 返回成功",
    ("Features/Recording/RecordingAppearanceDraft.swift", "discard"):
        "取消录屏编辑仅将 values 还原为 saved，正式录制参数保持保存值",
    ("Features/Recording/RecordingAppearanceDraft.swift", "restoreDefaults"):
        "恢复录屏默认只替换为 Values()：30fps、无音频、显示鼠标、关闭摄像头/键鼠叠加并清空排除列表",
    ("Features/Recording/RecordingSettingsPane.swift", "row"):
        "RecordingSettingsContent 复用 92pt 单行标题列，右侧放实际控件和弹性留白，供帧率、音频、摄像头和键鼠叠加设置使用",
    ("Features/Recording/RecordingSettingsPane.swift", "appName"):
        "排除应用列表按 bundleID 查找安装的应用并读取显示名称，无法定位时直接显示 bundleID",
    ("Features/Recording/RecordingSettingsPane.swift", "addExcludedApp"):
        "应用选择器从 /Applications 多选 .app，把各 Bundle 的唯一标识去重追加到 draft.values.excluded，保存前不改 RecordingOptions",
    ("Features/Recording/RecordingSettingsPane.swift", "removeExcluded"):
        "从 draft.values.excluded 移除指定 bundleID，排除行为在统一保存后才应用",
    ("Features/Recording/RecordingSettingsPane.swift", "chooseDirectory"):
        "录屏目录选择器选文件夹后直接更新 savePath 和 RecordingOptions.saveDirectory；目录设置继续独立生效",
    ("Features/Settings/Panes/PinSettingsPane.swift", "save"):
        "将 PinAppearance 草稿中的描边宽度/颜色、圆角、阴影、吸附、不透明度及控制条隐藏时长写到 PinStyle，随后记录 saved 并刷新未保存标记",
    ("Features/Settings/Panes/PinSettingsPane.swift", "discard"):
        "取消钉图编辑仅将 appearance 恢复为 saved，实时场景读取恢复后的值",
    ("Features/Settings/Panes/PinSettingsPane.swift", "restoreDefaults"):
        "把钉图 appearance 草稿改为 PinAppearance.defaults，统一保存前不改变 PinStyle",
    ("Features/Settings/Panes/PinSettingsPane.swift", "row"):
        "钉图细项复用 74pt 标题列和控件行，供描边、圆角、阴影、不透明度、吸附和控制条时长使用",
    ("Features/Settings/Panes/PinSettingsPane.swift", "shortcut"):
        "钉图快捷键说明以等宽键帽和操作标题显示，供拖动、缩放及复位提示复用",
    ("Features/Settings/Panes/PinSettingsPane.swift", "isActive"):
        "四张钉图预设卡按草稿描边宽度、颜色、圆角及阴影判断选中，两个数值差在 0.01 内视为一致",
    ("Features/Settings/Panes/PinSettingsPane.swift", "apply"):
        "预设卡动作只调用 draft.appearance.applyPreset，实时更新同一正式图像组件而不写全局 PinStyle",
    ("Features/Settings/Panes/PinSettingsPane.swift", "makeNSView"):
        "PinLivePreview 为大场景及缩略预设创建 PinPreviewScene，interactive 参数决定是否挂控制条和交互",
    ("Features/Settings/Panes/PinSettingsPane.swift", "updateNSView"):
        "将当前PinAppearance与系统降低透明度传给既有PinPreviewScene，复用图像和控制条，不再传无用reduceMotion参数",
    ("Features/Settings/Panes/PinSettingsPane.swift", "dismantleNSView"):
        "SwiftUI移除钉图场景时调用stop，取消控制条隐藏任务并移除图层动画及气泡",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "save"):
        "图帘草稿先在快捷键变更时注册组合键，失败返回占用/系统原因；成功写完八项图帘偏好才发 curtainPreferencesChanged，再记录 saved",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "discard"):
        "取消图帘编辑只将 values 恢复为 saved，正式控制器不接收偏好变化通知",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "restoreDefaults"):
        "把图帘草稿置为关闭、经典样式、12秒、8张、140pt、帘线随卡缩放及自动上架，关闭悬停唤出并取 AppBootstrap 默认快捷键",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "makeNSView"):
        "CurtainPreview 创建承载正式画布的 CurtainPreviewScene；CurtainRopeThumb 创建正式 CurtainRopeView 展示样式，两者不建立图帘窗口",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "updateNSView"):
        "CurtainPreview 向场景传 Values 和辅助功能状态；CurtainRopeThumb 更新 rope style 并清除 geometry，使绳线按正式绘制路径刷新",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "dismantleNSView"):
        "图帘大场景卸载时调用 stop，取消自动收起、移开收起及示范任务，停止卡片摆动",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "save"):
        "SettingsEditableDraft 要求保存返回 nil 或具体失败原因；统一底栏和 saveAll 通过此方法应用模块草稿，失败文案留在当前编辑器",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "discard"):
        "SettingsEditableDraft 取消接口由统一底栏及 discardAll 调用，各模块负责恢复保存值而不把草稿写入正式设置",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "restoreDefaults"):
        "SettingsEditableDraft 默认恢复接口由模块底栏和 restoreAllDefaults 调用，仅准备各模块默认草稿，最后保存才应用",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "init"):
        "SettingsEditingSession.init注册各类外观和八个模块工厂，新增transferLocal供本地暂存设置缓存；SettingsDraftEditor.init保存id、工厂及内容闭包，切页借用同一草稿",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "register"):
        "将 id 和草稿工厂保存为惰性闭包，restoreAllDefaults 可以创建未访问页面的同一份缓存草稿",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "draft"):
        "按 id 返回既有草稿；首次创建时缓存 isDirty/save/discard/restoreDefaults 闭包及对象变化订阅，让切页共享同一编辑实例",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "isDirty"):
        "将页面 editingDraftIDs 与会话 dirtyIDs 求交集，供页标题和侧边栏显示对应页面未保存状态",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "restoreAllDefaults"):
        "先调用所有已注册工厂补齐页面草稿，再对每份草稿执行 restoreDefaults，并标记 allDefaultsPrepared",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "saveAll"):
        "按 id 排序只保存脏草稿，遇到首个具体失败原因立即返回；全部成功后清除 allDefaultsPrepared 并返回 nil",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "discardAll"):
        "对缓存草稿逐个调用 discard，取消全部默认准备标记，不关闭设置窗口",
    ("Features/Settings/Shell/SettingsEditingSession.swift", "end"):
        "设置窗口关闭时清空草稿实例和全部默认标记，并递增 generation，使下次打开重建内容与预览生命周期",
    ("Features/Settings/Shell/SettingsRootView.swift", "init"):
        "SettingsRootView 同时观察传入 SettingsUIState 和其 editingSession，内容树通过 environmentObject 共用该会话，按 generation 和窗口可见性重建预览",
    ("Features/Settings/Shell/SettingsWindowController.swift", "windowWillClose"):
        "原生关闭按钮回调将 isVisible 设为 false 并结束 editingSession，销毁未保存草稿和预览内容",
    ("Features/Settings/Shell/SettingsWindowController.swift", "windowDidMiniaturize"):
        "设置窗口最小化时将 isVisible 设为 false，使 SettingsRootView 卸载预览内容，缓存草稿仍保留",
    ("Features/Settings/Shell/SettingsWindowController.swift", "windowDidDeminiaturize"):
        "设置窗口恢复时将 isVisible 设为 true，重新挂载当前页并借用原缓存草稿",
    ("Features/Settings/Shell/SettingsWindowController.swift", "windowDidChangeOcclusionState"):
        "用window.isVisible且未最小化更新uiState.isVisible，使临时遮挡下设置内容和预览状态保持挂载；仅monitorModule或monitorSettings页按真正occlusionState.visible调用MonitorSampler.setSettingsActive暂停或恢复采样，其他页不启动监测",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "init"):
        "把正式CurtainCanvasView放入横向NSScrollView并设animatesIdleSway=false，挂模拟截图、展开按钮和键盘说明；复制、定位、保存、钉图仅反馈，移除和缩放只改变场景",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "update"):
        "首次启用装入maxCards张固定卡片并静态显示；调参保留收起态与卡片数量，卡宽变化清本地缩放，上限变化补删卡片，样式原地更新，时长变化续收起计时；禁用时停任务并清空场景",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "sample"):
        "按 index 生成固定 UUID、kitnest-preview://curtain 地址、零时间和 640×384 像素尺寸，图像引用内存 CapturePreviewImage，不读取文件",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "layout"):
        "定位顶部模拟截图/展开按钮、底部状态行及中间横向滚动视口，场景尺寸变化时按原尺寸无动画重排正式画布",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "render"):
        "按正式CurtainLayout.metrics与每项item.cardSize累加真实画布宽度，窄内容居中、超宽横向滚动并保留滚动原点；静态重排走updateLayout保留未变卡片状态，仅显式落入且未减少动态时reload播放新卡动画",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "simulateCapture"):
        "模拟截图按钮和N键共用capture，只按当前自动上架开关追加场景卡片，不再调度自动截图任务",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "capture"):
        "只在 enabled 且 attachOnCapture 时追加固定卡片，超过 maxCards 移除最旧项，展开并续收起计时；关闭自动上架时仅反馈",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "toggle"):
        "用户切换shown；展开续自动收起计时，收起取消隐藏任务并停止卡片动画，两向均静态重排并保留场景卡片",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "scheduleHide"):
        "替换已有 hideTask；duration>0 时等待指定秒数后收起场景，duration=0 不安排任务",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "hide"):
        "隐藏正式画布、停止其卡片动画并把按钮改为展开，状态文字写明收起原因，卡片内容不删除",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "feedback"):
        "把动作说明写到场景底部 NSTextField，供模拟复制、定位、保存、缩放和收起复用",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "updateTrackingAreas"):
        "重建场景整体和顶部 30pt 两个悬停区域，用 userInfo.top 区分顶边唤出与离开场景",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "mouseEntered"):
        "取消移开收起任务；仅 enabled/revealOnHover 且命中顶边时展开现有卡片并续自动收起计时",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "mouseExited"):
        "离开整个场景且启用悬停唤出时安排 0.8 秒收起，离开顶边小区域不会触发",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "stop"):
        "统一取消hideTask与leaveTask并停止画布卡片动画，供关闭、禁用及卸载调用",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "viewDidMoveToWindow"):
        "失去宿主window时调用stop，停止收起计时和卡片动画",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "init"):
        "使用 CapturePreviewImage 创建正式 PinImageView；交互场景挂控制条/关闭按钮及键盘操作辅助说明，标注、复制、缩放、气泡和关闭只作用本地场景，缩略预设不挂控件",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "update"):
        "把PinAppearance原值交正式PinImageView绘制图像、阴影；降低透明度仅改变控制条底色，外观变化显示控制条并请求静态排版，更新接口不再接收reduceMotion",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "layout"):
        "初始scale=1、offset=0时按场景中心定位图像，原点限制在对称8pt可见边界；仅offset非零且吸附开启时调用PinMagnet，图像和控制条直接同步设置frame，不启动自动位移或缩放",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "hitTest"):
        "非交互预设缩略图不接鼠标；图像和状态行命中转给场景处理拖动，其余命中仍交给正式控制条",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "updateTrackingAreas"):
        "交互场景建立跟随可见区域的进入、移动、离开追踪，非交互缩略图不建追踪区域",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "mouseEntered"):
        "移入场景重新显示被模拟关闭的图像，并显示控制条与关闭按钮",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "mouseMoved"):
        "鼠标在场景移动时复用 showChrome，保持控制条可见并刷新静止自动隐藏计时",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "mouseExited"):
        "离开场景取消隐藏任务，隐藏控制条及关闭按钮并移除当前气泡",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "mouseDown"):
        "点击将场景设为窗口第一响应者；双击复位为100%缩放，单击记录鼠标原点及当前offset供手动拖动，并显示控制条",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "mouseDragged"):
        "按鼠标与 dragOrigin 的差值更新 offset，触发局部排版并反馈吸附是否启用，不移动真实窗口",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "scrollWheel"):
        "滚轮按scrollingDeltaY/150调整本地scale并限制55%…115%，交setScale显示缩放反馈，不改变外观草稿",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "magnify"):
        "捏合把magnification加到本地scale并限制55%…115%，复用setScale更新场景缩放",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "setScale"):
        "更新本地 scale、请求排版、显示百分比并唤出控制条，草稿 PinAppearance 不改变",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "feedback"):
        "将拖动、复制、标注、缩放和自动隐藏说明写入场景状态行",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "showBubble"):
        "移除旧气泡后按 PinBubbleModel 创建正式 PinBubbleView 并请求排版，nil 表示关闭气泡",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "showChrome"):
        "显示正式控制条及关闭按钮并替换 hideTask；chromeAutoHide>0 时到期收起，工具条悬停时保留，0 表示永不自动隐藏",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "stop"):
        "取消控制条自动隐藏任务，移除图像图层动画及气泡，供场景关闭和SwiftUI卸载调用",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "viewDidMoveToWindow"):
        "预览场景不再属于 window 时调用 stop，清理场景内计时及动画",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "init"):
        "从 FSBarConfigurationSnapshot 读取部件配置并保存一份 saved，模块列表由 FSBarAllModules 提供，编辑时只改 configuration",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "bool"):
        "部件草稿的布尔读取接受 NSNumber.boolValue，缺键才使用选项默认值，因此显式 false 保留",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "string"):
        "部件草稿读取字符串或 NSNumber.stringValue，供保存为文字的更新间隔、形态列表和数值控件共用",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "forms"):
        "从草稿 module_widget 的逗号序列读取启用形态，过滤到 FSBarFormsForModule 支持项并保留顺序",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "setForms"):
        "把形态 id 按传入顺序以逗号连接写入草稿 module_widget，不调用正式引擎持久接口",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "move"):
        "模块上/下移按钮交换 orderedModules 中相邻两项，结果只写草稿 Widgets_order",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "moveForm"):
        "形态上/下移按钮交换对应模块已启用形态序列，复用 setForms 写入草稿",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "restoreModule"):
        "清除指定 module_ 前缀的草稿项，再从 FSBarDefaultConfiguration 复制该模块出厂项",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "restoreDefaults"):
        "对所有模块恢复出厂项，并重置合并、两种间距、分隔线/颜色及 Widgets_order，变化只留在草稿",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "discard"):
        "从 FSBarConfigurationSnapshot 重新读取真实保存配置，同时替换 configuration 和 saved",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "importStats"):
        "先把草稿恢复默认，再合并 FSBarImportedConfiguration 读取的 Stats 配置，统一保存前不写 widgets.plist",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "save"):
        "按 NSObjectEqual 求出相对 saved 的变更值及移除键，交给 FSBarSaveConfiguration 原子写入；失败返回原因，成功更新 saved 并重载正式部件",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "NSObjectEqual"):
        "保存时用 NSObject.isEqual 比较草稿值和原值；原键不存在则视为新值，供只写改动的配置差异使用",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "moduleCard"):
        "按草稿顺序绘制模块卡、启用形态及各形态设置；显示、模块/形态排序、更新间隔、传感器选择和单模块默认都只更新 draft.configuration",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "optionRow"):
        "部件细项复用 96pt 标题列及至少 26pt 控件行，供间隔、传感器和四类形态控件使用",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "boolBinding"):
        "形态开关从 draft.bool 读取，赋值只写 configuration 的指定键，不调用 FSBarCfgSet",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "stringBinding"):
        "形态菜单及颜色控件从 draft.string 读取，赋值只更新指定草稿字符串键",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "numberBinding"):
        "数值滑条把草稿字符串转 Double，拖动后按零位小数写回同一草稿键，供配置序列化复用",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "optionControl"):
        "按 OptionSpec 分发开关、菜单、颜色和滑条，统一拼 module_form_ 前缀并绑定草稿配置",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "makeNSView"):
        "直接返回FSBarCreateConfiguredPreview创建的22pt正式部件画布，按草稿模块/形态顺序装入固定数值和图线历史，不增加空宿主容器或菜单栏状态项",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "updateNSView"):
        "调用FSBarUpdateConfiguredPreview先将原生画布高度设为22pt，再按module/form复用部件并更新草稿配置、移除失效形态及重排；新增图线装入120个固定样本，其他形态取最后一个样本",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "sizeThatFits"):
        "SwiftUI尺寸提案保留原生画布实际宽度并固定返回22pt高度，与FSBarUpdateConfiguredPreview设置的画布高度一致，避免被压至8pt而裁掉图线和双行网络",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "dismantleNSView"):
        "部件预览卸载时移除容器全部子视图，释放正式绘制组件",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "optionGroups"):
        "按模块和形态列出真实 FSBar 配置选项：文字/边框/值、颜色、图表样式、柱/扇区、传感器单位及网络读写显示，供 optionControl 使用",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "moduleSymbol"):
        "模块标题按 CPU、GPU、RAM、磁盘、网络、电池和传感器名映射 SF Symbol，保持正式设置卡图标含义",
    ("Features/Settings/Shell/SettingsPanes.swift", "init"):
        "MenuBarSettingsDraft 读取当前图标样式/自定义符号、Bar_MainIconCat 与七项入口标记，保存值组合供 isDirty 比较",
    ("Features/Settings/Shell/SettingsPanes.swift", "select"):
        "菜单栏图标选择只改变 draft.iconStyle，正式状态项在统一保存后刷新",
    ("Features/Settings/Shell/SettingsPanes.swift", "restoreDefaults"):
        "菜单栏草稿恢复 logo、默认自定义符号、关闭小猫并启用七项入口，正式图标和入口不立即变化",
    ("Features/Settings/Shell/SettingsPanes.swift", "discard"):
        "重新读取图标存储、引擎小猫配置与七项入口偏好，替换草稿并更新 saved",
    ("Features/Settings/Shell/SettingsPanes.swift", "save"):
        "先验证自定义 SF Symbol，变更小猫时调用 FSBarSaveConfiguration；只应用变化的图标/符号/入口键，发入口通知并刷新正式图标和小猫，失败返回具体原因",
    ("Features/Settings/Shell/SettingsPanes.swift", "entryRow"):
        "常规菜单栏设置行把指定入口开关双向绑定 draft.flags[key]，不直接写 Preferences",
    ("Features/StatusBar/MenuBarIconStyle.swift", "configure"):
        "正式图标应用器和预览共用按钮绘制：logo/custom 使用模板 SF Symbol，date 写日期标题，fan 挂居中的 18pt RotatingLayerView 并返回视图",
    ("Features/StatusBar/MenuBarIconStyle.swift", "dateTitle"):
        "使用 en_US_POSIX 的 M/d 日期格式，正式状态项传当前时间，菜单栏预览传固定日期",
    ("Features/StatusBar/MenuBarIconStyle.swift", "makeNSView"):
        "建立 40×22pt 内嵌图标容器，预览不安装 NSStatusItem 或采样器",
    ("Features/StatusBar/MenuBarIconStyle.swift", "updateNSView"):
        "移除旧预览内容；小猫调用固定第3帧 FSRunCatCreatePreview，其余样式用 MenuBarIconDrawing.configure 绘制固定日期图标，并设置 aqua/darkAqua",
    ("Features/StatusBar/MenuBarIconStyle.swift", "dismantleNSView"):
        "菜单栏图标预览卸载时移除容器所有子视图，释放风扇或小猫绘制组件",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "refreshUnownedValues"):
        "页面重新出现时调用 reloadSavedValues(preservingOwned:true)，读取其他页面已保存值，同时保留当前模块尚未保存的字段",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "reloadSavedValues"):
        "从 shared 复制最新外观，preservingOwned=true 时再覆回当前模块 DraftField；仅刷新非本模块的面板、动作条、主题与悬浮窗设置",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "restoreDefaults"):
        "只把该 scope 的 DraftField 改为 makeDefaultDraft 值；面板恢复400pt及默认页序，悬浮窗恢复网格/中档/0.52分隔，动作条恢复pillBar，通用主题恢复system",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "reduce"):
        "保存外观预览与settingsPreviewViewport相交的可见值；消费方离屏恢复revealed，开合任务标识不含isVisible，滚动重新进入不会触发重播",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "image"):
        "AppearancePreviewWallpaper 按当前桌面壁纸 URL 缓存图像，经 ImageIO 生成最大1024像素缩略图，供背景预览使用，不重复解码相同 URL",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "press"):
        "原生红黄绿按钮仅调用场景onPress触发重播；通用预览在viewport内按minWidth居中，超宽横向滚动，无整块宽度或toolbarStyle隐式动画；openReplay=0初始静止，手动重播或开合设置变化触发播放",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "makeCoordinator"):
        "为 PreviewWindowChrome 创建保存 onPress 的协调器，三颗原生窗口按钮共用其 press 回调",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "init"):
        "SearchDisplayDraft 用 shared.makeDraft 获取非持久引擎管理器并恢复分类值，订阅服务变化；SearchSettingsContent 观察同一草稿和服务，统一缓存标识为 searchDisplay",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "save"):
        "统一保存先处理未完成的自定义引擎新增/编辑表单，返回具体格式或写入原因；成功 applyDraft 引擎后写三项分类开关并刷新脏状态",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "discard"):
        "取消时清空未完成新增/编辑表单，从共享服务恢复引擎及行为值，再按偏好键是否存在读取三项分类，保留显式 false",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "restoreDefaults"):
        "只清空草稿表单并恢复内置引擎/默认搜索栏，打开三项分类和搜索后清空输入，正式搜索在统一保存后才改变",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "validateEngineForm"):
        "新增和行内编辑共用名称非空、仅字母数字、20字符上限及 {query} URL 格式判断，编辑查重排除自身 id，失败返回具体说明",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "saveCustomEngine"):
        "校验并修剪新增名称和 URL，成功只调用草稿 service.addCustomEngine，清空表单并退出新增态",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "clearForm"):
        "重置草稿新增名称为空、URL为 customEngineURLPlaceholder 并清除错误，供添加完成、取消及恢复默认共用",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "beginEditing"):
        "把指定自定义引擎 id、名称和 URL 复制到缓存草稿表单，并清除旧编辑错误，切页保留当前输入",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "cancelEditing"):
        "清空草稿编辑 id、名称、URL 和错误，仅退出行内表单，不改正式引擎",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "saveEngineEdit"):
        "行内编辑校验后调用非持久服务 updateCustomEngine，保持引擎 id，完成后清空编辑表单，最后由模块保存应用",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "categoryValue"):
        "用 UserDefaults.object 转 Bool 读取搜索分类，只有键缺失才默认 true，已保存 false 不被覆盖",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "searchBarRow"):
        "搜索栏行显示草稿引擎名和移除按钮，整行拖放在草稿序列中交换位置，不再写一次性排序提示键",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "searchBarDropDelegate"):
        "拖放代理通过闭包实时读取 draft.service.activeBarItems 和拖拽 id，悬停落位仅调用草稿 moveInSearchBar",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "removeFromSearchBar"):
        "移除按钮只修改草稿激活集，最后一项沿用既有拒绝规则并把原因显示在本页 notice，不打开 Toast",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "engineRow"):
        "全量引擎行按草稿 allEngines 显示名称/URL/搜索栏勾选；菜单的排序、增删和自定义编辑都指向同一草稿服务",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "addToSearchBar"):
        "引擎菜单将指定 id 加入草稿搜索栏，正式 activeBarItems 在统一保存后更新",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "engineIcon"):
        "引擎列表和拖拽预览共用 SearchEngine.systemImage 的单色 SF Symbol，不加载品牌位图",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "engineEditForm"):
        "缓存草稿名称/URL/错误双向绑定行内表单，应用到草稿调用 saveEngineEdit，局部取消调用 cancelEditing",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "engineFormFields"):
        "新增与编辑共用名称和搜索 URL 字段、{query} 说明及具体错误文字，输入值属于缓存草稿",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "performDeletePendingEngine"):
        "确认删除先退出该引擎编辑态，再从草稿服务移除自定义项并清空待删对象，取消模块可恢复保存项",
    ("Features/Toolbox/Search/SearchSectionView.swift", "init"):
        "正式 SearchSectionView.init 观察共享服务；草稿重载观察 SearchDisplayDraft.service 并注入三项分类绑定，预览与正式路径复用同一视图",
    ("Features/Toolbox/Search/SearchSectionView.swift", "resultFileIcon"):
        "设置预览文件行用 doc SF Symbol，正式文件行继续读取缓存的 NSWorkspace 文件图标",
    ("Features/Toolbox/Search/SearchSectionView.swift", "updatePreviewCategories"):
        "仅设置预览响应分类开关；当前类关闭时切回全部并调用本地 scheduleSearch，不写持久分类",
    ("Features/Toolbox/Search/SearchSectionView.swift", "filterPreviewItems"):
        "固定工具名/命令、副标题、五类文件名及网页标题/摘要通过 FuzzyMatcher 本地筛选，更新结果与搜索状态，不进入注册检索源、文件索引或网页抓取",
    ("Features/Toolbox/Search/SearchSectionView.swift", "previewSelectionFill"):
        "按 previewSelectedResultID 给被点击的固定结果绘制强调色圆角底，正式搜索行使用透明底",
    ("Features/Toolbox/Search/SearchSectionView.swift", "scheduleSearch"):
        "设置预览非空词直接过滤固定内存项；正式路径保留250ms防抖、工具源汇总、文件索引准备/精排和支持引擎的网页抓取",
    ("Features/Toolbox/Search/SearchSectionView.swift", "fetchWebResults"):
        "预览调用直接改走本地 scheduleSearch；正式路径保持当前引擎抓取、DuckDuckGo补充与 generation 匹配后发布结果",
    ("Features/Toolbox/Search/SearchSectionView.swift", "performWebSearch"):
        "设置预览仅选择引擎并按草稿 clearSearchInputAfterWebAction 清输入；正式路径构造 URL、记录搜索事件并用默认浏览器打开",
    ("Models/SearchEngine.swift", "makeDraft"):
        "以同一 defaults 创建 persistsChanges=false 管理器再复制当前值，草稿复用正式引擎操作而不装载/写偏好",
    ("Models/SearchEngine.swift", "copyValues"):
        "makeDraft、草稿取消与正式 applyDraft 共用：复制 customEngines、allEngines、activeBarItems 和搜索后清空输入值",
    ("Models/SearchEngine.swift", "applyDraft"):
        "统一保存先 JSON 编码自定义引擎，失败返回具体原因；成功复制草稿到正式服务并写自定义项、全量顺序、搜索栏顺序及行为偏好",
    ("Features/Monitor/Views/BatteryPanel.swift", "init"):
        "BatteryStatsContent 接收 StatsSnapshot、可选电量和可选 LowPowerModeController；真实页注入控制器，固定预览传 nil，低电量开关只改本地状态",
    ("Features/Monitor/Views/BatteryPanel.swift", "hero"):
        "用传入电池百分比或 batteryLevel 绘制74pt电量环，按充电/接电状态显示标题、副标题及状态色",
    ("Features/Monitor/Views/BatteryPanel.swift", "headline"):
        "按传入电池的充电、充满和外接电源状态返回正在充电、已充满、接电未充或电池供电，缺值显示状态未知",
    ("Features/Monitor/Views/BatteryPanel.swift", "subline"):
        "结合充电状态和 batteryRemainSec 显示预计充满/可用时长、暂缓充电或未接电源说明",
    ("Features/Monitor/Views/BatteryPanel.swift", "adapterRow"):
        "接电状态下展示有效的适配器额定功率、充电电压及毫安转安培的电流，供传入真实或固定电池共用",
    ("Features/Monitor/Views/BatteryPanel.swift", "spec"):
        "适配器规格项以次级标题和等宽数值纵向展示，额定功率、电压与电流共用该组件",
    ("Features/Monitor/Views/BatteryPanel.swift", "hint"):
        "按是否充电及80%阈值显示涓流充电、温升、暂缓充电或电池供电建议，读取调用方电池值",
    ("Features/Monitor/Views/BatteryPanel.swift", "healthRatio"):
        "电池主健康度用满充容量除标称容量，标称缺失时用设计容量，有效比例上限1.2，供健康卡和剩余寿命条复用",
    ("Features/Monitor/Views/BatteryPanel.swift", "healthColor"):
        "健康比例低于80%显示红色、低于90%显示橙色，其余使用充电色，缺值显示次级色",
    ("Features/Monitor/Views/BatteryPanel.swift", "healthCard"):
        "同一健康卡展示主容量口径、循环数、健康/磨损条和设计容量副口径，使用调用方电池/Stats数据，预览无需采样器",
    ("Features/Monitor/Views/BatteryPanel.swift", "electricalCard"):
        "把调用方 StatsSnapshot 和电池数据交给 BatteryFlowModel，展示充电输入、系统供电与电池充放电能量流",
    ("Features/Monitor/Views/MonitorDetailView.swift", "init"):
        "MonitorDetailView 保存选择/页模式/宽度；MonitorDetailContent 接收采样、历史、Stats、额外指标和卷列表及可选真实控制器，固定预览使用独立选择与静态数据",
    ("Features/Monitor/Views/MonitorDetailView.swift", "availableModules"):
        "预览返回全部 MonitorModuleID；真实页按模块偏好、温度开关、电池可用性和GPU数据决定分类，并保留当前选中项",
    ("Features/Monitor/Views/MonitorDetailView.swift", "chipStrip"):
        "正式页显示实际CPU品牌、核数、热压力及系统版本，设置预览使用Apple M3/8核/macOS15.0固定值，P/E核数量取传入Stats",
    ("Features/Monitor/Views/MonitorDetailView.swift", "uptimeText"):
        "正式CPU页从 ProcessInfo.systemUptime 格式化天/小时/分钟，设置预览显示固定2天4小时，不读取运行时启动时长",
    ("Features/Monitor/Views/MonitorDetailView.swift", "loadCell"):
        "CPU平均负载的1/5/15分钟值复用紧凑标题和等宽数值显示，调用方传 extra.loadAverages",
    ("Features/Monitor/Views/MonitorDetailView.swift", "primaryTemperature"):
        "先从传入 sample.temperatures 取CPU包温/二极管/邻近温度，再用同一 stats.sensors 构建CPU热区取得最热点",
    ("Features/Monitor/Views/MonitorDetailView.swift", "legendItem"):
        "内存和网络图例共用6pt颜色圆点与次级文字，颜色由各数据系列传入",
    ("Features/Monitor/Views/MonitorDetailView.swift", "networkFlowNodes"):
        "按传入十分钟窗口快照取limit个应用，余量与未归因字节归为其他/未采集；预览不读取应用图标，当前流量高于1024B/s标为活跃",
    ("Features/Monitor/Views/MonitorDetailView.swift", "flowCoverageText"):
        "网络统计覆盖不足60秒显示已统计秒数，未满10分钟显示实际分钟，满窗显示最近10分钟",
    ("Features/Monitor/Views/MonitorDetailView.swift", "flowNode"):
        "将 BatteryFlowNode 的瓦数、标题、图标、颜色和可用性转为通用 MonitorFlowNode，缺功率用破折号",
    ("Features/Monitor/Views/MonitorDetailView.swift", "powerExtraBranches"):
        "从传入传感器的功率类别4筛选0.05…500W，匹配显示器和USB关键字，各分支取最大有效读数",
    ("Features/Monitor/Views/MonitorDetailView.swift", "connCellColor"):
        "连通性格子的整数状态1使用MonitorColors.battery、0使用MonitorColors.system，其余使用低透明底色，供真实与固定连通性网格共用",
    ("Features/Monitor/Views/MonitorDetailView.swift", "externalVolumeCard"):
        "传入 DiskVolume 直接显示名称、类型/只读标记、已用/空闲容量条和总容量，固定预览不查询卷目录",
    ("Features/Monitor/Views/MonitorDetailView.swift", "sensorCategorySection"):
        "按传入类别筛选并降序显示，温度<110、电压<300、电流<100；温度最多6行，其余3行，温度条用20…110°C标尺",
    ("Features/Monitor/Views/MonitorDetailView.swift", "temperatureDetailSection"):
        "筛选0…110°C温度并降序，折叠组最多展示30颗传感器，展开态由本地 showsAllTemperatures 持有",
    ("Features/Monitor/Views/MonitorDetailView.swift", "sensorBarRow"):
        "温度和风扇共用168pt两行名称、68pt进度条和62pt数值列，保留完整名称help并用传入ratio绘宽",
    ("Features/Monitor/Views/MonitorDetailView.swift", "sensorValueText"):
        "将传入值按温度、电压、电流、功率及瓦时单位交给 MonitorFormat/StatsFormat 格式化，统一传感器行文案",
    ("Features/TransferDock/Cast/CastView.swift", "init"):
        "CastContent 接收可选二维码配对与面板选择服务；正式宿主注入服务并读取剪贴板同步偏好，固定预览不取得ADB配对单例",
    ("Features/TransferDock/Cast/CastView.swift", "qrButton"):
        "扫码连接入口只设置 showQrPair；正式页在hero锚点打开配对弹层，设置预览在当前场景内覆盖固定二维码",
    ("Features/TransferDock/Cast/CastView.swift", "deviceCard"):
        "按设备serial和连接state展示图标、状态及投屏/重新授权操作，所有开始投屏动作复用 startMirror",
    ("Features/TransferDock/Cast/CastView.swift", "stateLabel"):
        "将ADB device/unauthorized/offline状态转换为已连接、未授权和离线文字，供设备卡统一展示",
    ("Features/TransferDock/Cast/CastView.swift", "startMirror"):
        "固定预览只写投屏反馈，正式页调用 ScreenCastEngine.startMirror(serial:)，所有投屏按钮共用该入口",
    ("Features/TransferDock/Cast/CastView.swift", "reauthorize"):
        "预览只显示设备授权反馈；正式未授权设备沿用ADB重授权动作并在完成后刷新设备列表",
    ("Features/TransferDock/Cast/CastView.swift", "appTile"):
        "设备应用磁贴显示名称及可用图标，点击通过 openApp；固定应用无 iconPath，不触发真实设备启动",
    ("Features/TransferDock/Cast/CastView.swift", "openApp"):
        "固定预览仅显示已选示例应用名称；正式记录CastAppUsage并调用ADBExtrasEngine.startAppWindow打开对应手机应用窗口",
    ("Features/TransferDock/Cast/CastView.swift", "serviceRow"):
        "MCP/WebDAV服务行共用图标、地址、复制及启停控件；预览复制只反馈，真实复制地址并由调用方启停服务",
    ("Features/TransferDock/Cast/CastView.swift", "disclosureRow"):
        "设备辅助工具折叠标题显示图标、标题及展开箭头，点击转给提供的展开动作，减少动态时无展开动画",
    ("Features/TransferDock/Cast/CastView.swift", "subHeader"):
        "通知、存储、应用及互传服务段共用图标/标题/刷新按钮，刷新闭包由对应段落提供",
    ("Features/TransferDock/Cast/CastView.swift", "hint"):
        "设备辅助段落的无设备或空内容提示复用次级说明文字，不执行设备操作",
    ("Features/TransferDock/Cast/CastView.swift", "iconAction"):
        "设备刷新按钮复用指定SF Symbol、help和动作闭包，父层在预览时只发布示例已更新反馈",
    ("Features/TransferDock/Cast/CastView.swift", "primaryButton"):
        "设备卡主动作使用强调色的开始投屏按钮，闭包指向 startMirror，而非直接启动设备进程",
    ("Features/TransferDock/Cast/CastView.swift", "secondaryButton"):
        "设备授权/无线调试次级按钮共用边框和标签，父层区分预览反馈与真实ADB动作",
    ("Features/TransferDock/Cast/CastView.swift", "refreshDevices"):
        "设置预览仅反馈固定内容；正式路径调用 ScreenCastEngine.connectedDevices 更新devices，quiet=false时按数量显示发现结果",
    ("Features/TransferDock/Cast/CastView.swift", "refreshNotifications"):
        "设置预览不调用ADB；正式路径用 notifBusy 控制当前通知请求，ADBExtrasEngine.notifications 返回后替换列表并结束忙状态",
    ("Features/TransferDock/Cast/CastView.swift", "loadStorage"):
        "预览保留固定容量与条目，仅显示反馈；正式调用ADBExtrasEngine.storage获取手机总量及目录容量列表",
    ("Features/TransferDock/Cast/CastView.swift", "loadApps"):
        "预览保留固定应用，仅显示反馈；正式通过activeSerial调用DeviceAppCatalog.load并在返回后更新列表和appsBusy",
    ("Features/TransferDock/Cast/CastView.swift", "notifTint"):
        "按通知应用包名从蓝、绿、橙、粉、紫、青、红七色中选择识别色，通知行与应用标识共用",
    ("Features/TransferDock/UI/TransferDockView.swift", "init"):
        "TransferDockContent 接收可选云服务、本地暂存、LAN与压缩控制器；正式宿主注入共享服务，预览由场景内固定本地和云文件数组提供内容",
    ("Features/TransferDock/UI/TransferDockView.swift", "segmentPill"):
        "发送、接收和文件中转分段复用胶囊按钮，点击只改变当前内容分段，固定预览与正式页共用布局",
    ("Features/TransferDock/UI/TransferDockView.swift", "sendChip"):
        "发送方式按钮复用图标、标题及help，调用方分别接隔空投送、浏览器扫码和ADB发送入口",
    ("Features/TransferDock/UI/TransferDockView.swift", "sendableURL"):
        "正式文件发送优先使用仍存在的暂存硬链接/副本，暂存不存在时返回 originalPath，供已选发送与元信息复制复用",
    ("Features/TransferDock/UI/TransferDockView.swift", "stagedSelection"):
        "从 localItems 中按 selectedIDs 取勾选文件，映射 sendableURL 并过滤实际存在的文件，供正式AirDrop与ADB发送使用",
    ("Features/TransferDock/UI/TransferDockView.swift", "addFilesToStaging"):
        "预览把场景列表重置为固定示例并反馈；正式多选文件/目录后调用本地store.add加入暂存并显示实际结果",
    ("Features/TransferDock/UI/TransferDockView.swift", "sendViaAirDrop"):
        "预览只反馈已选数量；正式取得可发送暂存项后调用AirDropSendEngine.send，空选择显示既有提示",
    ("Features/TransferDock/UI/TransferDockView.swift", "sendViaADB"):
        "预览切换本地进度显示并设0.62固定进度；正式调用ADBFileBridge.push，更新文件数/字节/速度/剩余时长及完成状态",
    ("Features/TransferDock/UI/TransferDockView.swift", "sendViaBrowser"):
        "预览直接显示固定定向接收二维码；正式要求当前勾选项后复用showPickQR启动直传入口",
    ("Features/TransferDock/UI/TransferDockView.swift", "receiveRow"):
        "接收方式共用图标、名称、说明和右侧操作区，供隔空投送、手机拉取及扫码接收的三行使用",
    ("Features/TransferDock/UI/TransferDockView.swift", "openUploadQR"):
        "固定预览在当前覆盖层显示示例上传二维码；正式按既有LAN上传地址提供扫码入口并启动所需直传服务",
    ("Features/TransferDock/UI/TransferDockView.swift", "openSettings"):
        "预览只显示文件中转设置入口反馈；正式通过ServiceLocator.settings打开transfer页",
    ("Features/TransferDock/UI/TransferDockView.swift", "runTransferProbe"):
        "仅正式onAppear调用：probe.transfer指定preview/select后延时展示真实文件悬停或选前两项出码，再清空选择观察直传服务收起",
    ("Features/TransferDock/UI/TransferDockView.swift", "smallAction"):
        "文件添加、刷新、扫码、复制等紧凑操作复用11pt图标文字及圆角细边按钮，执行传入闭包",
    ("Features/TransferDock/UI/TransferDockView.swift", "pullFromPhone"):
        "预览只恢复三个固定本地示例并反馈接收数量；正式ADB拉取到暂存目录后经LocalTransferStore.add登记实际文件",
    ("Features/TransferDock/UI/TransferDockView.swift", "refreshCloudLogin"):
        "预览仅反馈云登录入口；正式运行现有extract_edge_cookies.py并按退出状态提示，最后刷新云服务",
    ("Features/TransferDock/UI/TransferDockView.swift", "toggleSelect"):
        "切换selectedIDs中指定id并更新selectionAnchorID，供勾选按钮及Command单击共用",
    ("Features/TransferDock/UI/TransferDockView.swift", "showPickQR"):
        "预览只写固定kitnest-preview.invalid接收地址；正式按勾选id启动所需LAN服务并取得带pick参数的分享URL",
    ("Features/TransferDock/UI/TransferDockView.swift", "stopServiceIfStartedForTransfer"):
        "预览直接返回；正式仅停止由本次传输拉起的LAN服务，保留用户手动启动的服务",
    ("Features/TransferDock/UI/TransferDockView.swift", "pushSelectedToCloud"):
        "预览只反馈已选数量；正式检查已选文件与云登录状态后批量上传暂存URL",
    ("Features/TransferDock/UI/TransferDockView.swift", "removeSelected"):
        "预览仅改场景文件数组；正式把勾选项整批交local.remove，完成后仅保留仍在索引中的选择，失败项保持可见并显示具体原因",
    ("Features/TransferDock/UI/TransferDockView.swift", "pickOverlay"):
        "定向接收覆盖层展示二维码、地址及关闭操作；预览复制/浏览器按钮只反馈，真实路径复制或打开已生成的分享链接",
    ("Features/TransferDock/UI/TransferDockView.swift", "localCard"):
        "复用LocalCardRowView的选择、扫码、预览和移除回调，首个被选项持有空格预览目标；行内悬停、菜单预览和预览按钮均传PanelController.shared.panelWindowForProbe供共享预览贴面板同侧定位，设置预览不打开真实窗口；移除成功后才清除正式选择",
    ("Features/TransferDock/UI/TransferDockView.swift", "sectionHeader"):
        "云端、本地暂存及文件发送区域共用图标、标题、条目数和右侧操作闭包，不参与服务状态变更",
    ("Features/TransferDock/UI/TransferDockView.swift", "dropHint"):
        "拖放目标高亮用浅色圆角底、虚线边与提示文字，allowsHitTesting=false使文件拖放落到正式容器",
    ("Features/TransferDock/UI/TransferDockView.swift", "urls"):
        "正式拖放用DispatchGroup加载各NSItemProvider的public.file-url，接受Data或URL并用NSLock汇总，全部完成后在主队列返回",
    ("Features/TransferDock/UI/TransferDockView.swift", "handleLocalDrop"):
        "预览拒绝真实拖放；正式解析URL后调用本地store.add，按实际错误或新增数量显示反馈",
    ("Features/TransferDock/UI/TransferDockView.swift", "handleCloudDrop"):
        "预览拒绝真实拖放；正式解析URL后交云服务uploadBatch处理",
    ("Features/TransferDock/UI/TransferDockView.swift", "downloadCloudFile"):
        "预览把云文件元数据追加到场景暂存并反馈，不下载字节；正式调用service.download",
    ("Features/TransferDock/UI/TransferDockView.swift", "deleteCloudFile"):
        "预览只从previewCloudFiles移除指定id；正式调用service.delete删除云文件",
    ("Features/TransferDock/UI/TransferDockView.swift", "pickAndUpload"):
        "预览装入固定云文件列表并反馈；正式通过文件选择器多选后交service.uploadBatch上传",
    ("Features/Settings/Shell/SettingsComponents.swift", "init"):
        "SettingsRow、SettingsSection、SettingsGroupBox 初始化时立即执行 ViewBuilder 并保存实际 View，使父级草稿变化重建数字标签及控件；VisualOptionCard.init 保存卡片标题、尺寸、选中态、动作和预览闭包",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "becomeFirstResponder"):
        "交互钉图场景取得原生键盘焦点时，在场景图层绘制 2pt 系统强调色描边并返回成功",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "resignFirstResponder"):
        "钉图场景失去原生键盘焦点时将图层描边宽度归零，不改变图像外观草稿",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "keyDown"):
        "方向键每次移动8pt，加减每次缩放5%并限55%…115%，0复位中心偏移和100%缩放；回车显示控制条，Escape隐藏控制条及气泡，其余键交NSView",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "becomeFirstResponder"):
        "图帘场景取得原生键盘焦点时绘制2pt系统强调色场景边框，返回成功以接收键盘动作",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "resignFirstResponder"):
        "图帘场景失去原生键盘焦点时清除场景边框，不改变卡片、图帘样式或收起状态",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "mouseDown"):
        "点击场景空白区域将本视图设为窗口第一响应者，让回车、N、加减、删除和Escape操作留在预览",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "keyDown"):
        "回车切换展开/收起，N模拟截图，加减调用正式画布缩放回调每次8pt，删除键移除最后一张场景卡片，Escape只收起保留内容，其余键转给NSView",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "columnItems"):
        "gridContent按实际栏宽以150pt计算可容纳列数，最多使用卡片档位列数、至少1列；columnItems按传入列数对原下标取模分列，保留固定条目顺序",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "card"):
        "网格条目复用FloatingClipCard并连接选择、悬停、拖放及操作回调；图片在GeometryReader得到的本列宽高内scaledToFit，高度为minHeight-34，模拟文件用PDF类型图标，正式文件按真实路径取图标",
    ("Features/Settings/Shell/SettingsRootView.swift", "panePage"):
        "设置页统一纵向ScrollView显示滚动条，内容水平34pt/垂直18pt内边距并靠左撑满；monitorWidgets分发也经过此入口，使所有模块卡及底部保存区可整页滚动访问",
    ("Features/Capture/Pin/PinSettingsPreview.swift", "accessibilityPerformPress"):
        "辅助功能按下动作将PinPreviewScene设为宿主窗口第一响应者并返回聚焦结果；无宿主窗口返回false，键盘随后在本场景内移动、缩放和操作控制条",
    ("Features/Capture/Curtain/CurtainSettingsPreview.swift", "accessibilityPerformPress"):
        "辅助功能按下动作将CurtainPreviewScene设为窗口第一响应者并返回聚焦结果；无窗口返回false，回车、N、加减、删除和Escape交给场景键盘处理",
    ("App/AppBootstrap.swift", "start"):
        "启动接线在filesCapturedNotification到达时同时读取中转总开关和自动暂存开关，允许时交LocalTransferStore.autoStage；成功只记录同步数量，启动阶段按已保存保留期启动暂存清理",
    ("Features/Clipboard/Store/ClipboardManager.swift", "copy"):
        "单条文件按原格式复制成功后立即reader.read并insert，纯文本复制不进入文件同步；多条文本继续合并，单条图片/文件转单条重载，媒体混选返回既有说明",
    ("Features/Clipboard/Store/ClipboardManager.swift", "writeToDatabase"):
        "去重命中时touch并刷新剪贴板列表，文件结果仍发scheduleAutoStage通知，使重复复制同步刷新中转addedAt；新增结果沿用落盘、入库及文件通知路径",
    ("Features/Clipboard/Store/ClipboardManager.swift", "scheduleAutoStage"):
        "把读取到的文件URL列表发到主线程filesCapturedNotification，由AppBootstrap按两个中转开关决定同步，不限定文档或压缩包扩展名",
    ("Features/Clipboard/Store/ClipboardPasteboardReader.swift", "read"):
        "读取粘贴板类型和来源应用后依次尝试文件、图片、URL、富文本和文本；文件URL先于TIFF图片读取，避免Finder复制文件附带的图标被识别为图片",
    ("Features/Clipboard/Store/ClipboardPasteboardReader.swift", "readFiles"):
        "从fileURL或NSFilenamesPboardType读取文件列表，将NSURL.filePathURL解析出的真实路径用于content、标题、目录副标题和fileURLs；未取得URL时沿用旧文件名列表路径，返回.file结果",
    ("Features/TransferDock/Transfer/LocalTransferStore.swift", "autoStage"):
        "文件与文件夹URL标准化并按路径去重，pendingAutoStagePaths在add开始前登记、完成后移除以避免首次暂存未完成时重复复制；原路径或暂存路径命中同项刷新addedAt并降序置顶持久化，其他项走add，不限定扩展名",
    ("Features/TransferDock/Transfer/LocalTransferStore.swift", "add"):
        "暂存队列逐项对原始URL调用startAccessingSecurityScopedResource，defer仅在scoped成功时调用stop，使授权覆盖该项文件IO；标准化路径后交stage并统计尺寸，主线程仅发布成功项、持久化及通知，回调实际成功数量并保留失败原因",
    ("Features/TransferDock/Transfer/LocalTransferStore.swift", "startRetentionCleanup"):
        "启动及本地设置保存后替换已有retentionTimer；保留期0不设计时，正数时每3600秒调用pruneExpired并立即清理一次，计时加入主runloop common模式",
    ("Features/TransferDock/Transfer/LocalTransferStore.swift", "pruneExpired"):
        "按已保存retentionDays和最近addedAt计算天数×86400秒截止点，过期条目交统一remove并传递实际移除结果；0表示不清理并回调.none",
    ("Features/TransferDock/Transfer/LocalTransferStore.swift", "remove"):
        "单项重载转给数组重载；后台逐项把stagingRoot/item.id目录送废纸篓，主线程仅从索引移除成功id并持久化/通知，失败项保留并列出原因，原文件不操作",
    ("Features/TransferDock/Transfer/LocalTransferStore.swift", "clearAll"):
        "清空暂存复用remove(items)异步送废纸篓，不再直接删除目录或提前清空索引，错误和成功数量由同一路径报告",
    ("Features/TransferDock/UI/TransferDockSettingsPane.swift", "init"):
        "LocalTransferSettingsDraft读取自动暂存、悬停预览和保留天数三个已保存值，以字符串序列saved比较是否有待保存编辑",
    ("Features/TransferDock/UI/TransferDockSettingsPane.swift", "save"):
        "把自动暂存、悬停和保留期写入transferDock.autoStageClipboard、transferDock.previewOnHover、transferDock.local.retentionDays后synchronize；失败保留编辑并返回写入说明，成功重设清理计时和saved",
    ("Features/TransferDock/UI/TransferDockSettingsPane.swift", "discard"):
        "重新读取中转自动暂存、悬停预览与retentionDays已保存值，刷新草稿和saved，取消未保存设置",
    ("Features/TransferDock/UI/TransferDockSettingsPane.swift", "restoreDefaults"):
        "仅把本地暂存草稿恢复自动同步true、悬停预览true、保留期0；统一保存前不启动或停止正式清理计时",
    ("Features/TransferDock/UI/TransferDockView.swift", "copySelectedFiles"):
        "设置预览仅显示复制文件演示反馈；正式用stagedSelection取得实际文件URL并调用ClipboardManager.copyFiles，失败显示原因，成功状态保留1.2秒",
    ("Features/TransferDock/UI/TransferDockView.swift", "selectLocal"):
        "使用鼠标按下时记录的selectionModifiers，避免SwiftUI点击回调延后到按键释放后丢失组合选择；单击选择当前id，Command切换单项；Shift按selectionAnchorID与当前项在displayedLocalItems形成连续范围，Command+Shift合并范围，保持锚点供后续多选；页面离开即移除本地事件监听",
    ("Features/TransferDock/Transfer/FileHoverPreview.swift", "readText"):
        "文件与剪贴板共用的正文读取：mappedIfSafe读取完整文件，依次解码UTF-8和Latin-1，无法解码抛出fileReadInapplicableStringEncoding，不再截前8KB",
    ("Features/TransferDock/Transfer/FileHoverPreview.swift", "itemID"):
        "按URL.path构造file-preview:前缀内存条目id，供任意文件呈现、取消悬停关闭及主动隐藏确认当前项",
    ("Features/TransferDock/Transfer/FileHoverPreview.swift", "scheduleShow"):
        "取消共用协调器的悬停关闭任务并替换showWork，按同一hoverPreviewOpenDelay延时调用showNow，传屏幕锚点和弱引用sourceWindow",
    ("Features/TransferDock/Transfer/FileHoverPreview.swift", "showNow"):
        "取消待显示任务、记录currentURL，再交MainPanelPreviewPopoverCoordinator.presentFile；不再创建独立文件预览Panel或保存另一套尺寸",
    ("Features/TransferDock/Transfer/FileHoverPreview.swift", "scheduleHide"):
        "取消待显示任务，仅按currentURL对应itemID安排共享协调器关闭，不会把别的当前预览项关闭",
    ("Features/TransferDock/Transfer/FileHoverPreview.swift", "hide"):
        "取消待显示任务；仅当前共享协调器activeItemID仍为本文件时执行programmatic关闭，最后清除currentURL",
    ("Features/Panel/Preview/MainPanelPreviewPopoverCoordinator.swift", "presentFile"):
        "把任意磁盘URL构造成只在内存存在的ClipboardItem(type:file)，使用file-preview路径id和文件名；显式屏幕锚点或鼠标位置交present，不写剪贴板历史",
    ("Features/Panel/Preview/MainPanelPreviewPopoverCoordinator.swift", "present"):
        "按源视图或屏幕锚点确定可见区并创建requestedSession；文件模型在userInitiated后台读取，主线程仅接纳sessionID仍匹配的结果，其他类型同步呈现；换项复用包括收回中的slot，统一窗口连续调整内容和尺寸",
    ("Features/Panel/Preview/MainPanelPreviewPopoverCoordinator.swift", "dismiss"):
        "先更换sessionID撤销尚未完成的文件模型呈现，再移除点外监听；无活动窗口直接完成回调，活动窗口合并完成回调并交closeSlot播放收回动画",
    ("Features/Panel/Preview/MainPanelPreviewPopoverCoordinator.swift", "cancelHoverClose"):
        "文件悬停进入、归档有效条目切换及开始编辑时取消共享预览的待关闭任务，使内容准备期间保留同一窗口",
    ("Features/Panel/Preview/MainPanelPreviewPopoverCoordinator.swift", "scheduleHoverClose"):
        "带itemID时仅匹配当前项安排关闭；到期无已呈现slot则更换sessionID撤销后台读取结果，已呈现时编辑、固定或鼠标仍在窗内保留，真正离开后按hoverPreviewCloseDelay收回",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "copyContent"):
        "编辑态把draft交ClipboardManager.copyText；普通预览交ClipboardManager.copy(item,autoPaste:false)，文件保持原格式并由统一复制入口回读入历史及通知中转",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "init"):
        "窗口控制器和ClipboardPreviewWindowView都接收同一PreviewPopoverContentModel；控制器按完整模型测量无边框窗并装内容，视图保留传入文件正文/图片和会话id",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "imageSize"):
        "图片和磁盘图片文件共用窗口尺寸计算：长图高宽比超过1.6时保留可读宽度并纵向滚动，其余图按可用宽高等比缩放，窗口包含调用方传入工具区高度",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "initialSize"):
        "按真实Markdown、代码或文本折行测量并受面板侧空间与屏幕限制；目录和归档目标740×560pt，Word及其他支持文档680×560pt，普通单文件560×420pt；图片共用imageSize，文件文本及JSON留100pt操作区",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "installContent"):
        "用当前完整model构造ClipboardPreviewWindowView，装入可随窗口伸缩的NSHostingView并转发编辑状态，文件与剪贴板共用同一外壳",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "show"):
        "同一控制器换model时复位正在收回的WindowReveal状态；仅不同条目或提示模式重装内容，已可见换项只动画调整尺寸位置，首次出现才播放主面板配置的展开动画",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "place"):
        "有源窗口时贴其左右可用侧，无源窗口时从条目屏幕锚点右侧18pt尝试，放不下改左侧；8pt屏幕边距内定位并据相邻边设置共用展开/收回锚点",
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "closeAnimated"):
        "收回使用Personalization.openAnimation时长×0.7及减少动态口径；完成回调只在isClosing且model.sessionID仍为本次关闭会话时关窗，换项复用不被旧回调关掉",
    ("Features/Panel/Preview/PreviewPopoverContentModel.swift", "init"):
        "内容模型保留source、entry、sessionID及displayPath，按真实文件元数据识别目录，目录不读取正文或图片；单文件按支持类型加载完整文本或图片，kindOverride避免重复读取；MarkdownScrollState初始化保存滚动偏移、锚点和块矩形",
    ("Features/Panel/Preview/PreviewPopoverContentView.swift", "fileContent"):
        "文件夹与归档共用FileContainerPreview；完整文本按Markdown、JSON、代码或纯文本复用正式组件，读取失败显示原因，图片共用长图滚动，其余文档交独立DocumentInlinePreview",
    ("Features/Panel/Preview/PreviewPopoverContentView.swift", "decode"):
        "PreviewFileThumbnailLoader按FilePreviewBuilder.imageExtensions共用图片类型表，图片直接解码，PDF及其余文件保留既有缩略图路径，取消另一份图片扩展名列表",
    ("Features/Archive/Table/ArchiveHoverPreview.swift", "schedule"):
        "目录、空文件、超过sizeCap或不可渲染条目仍收起；有效条目取消共享hover关闭后按既有延迟解压/取缓存，文件准备完成才交共用文件预览，换项期间保留原窗口",
    ("Features/TransferDock/UI/TransferDockView.swift", "func"):
        "CloudRowView相等比较保留文件值判断；LocalCardRowView同时比较item、selected、isKeyboardPreviewTarget和showsCloud，使首个选择项变化时空格预览目标随行重绘",
    ("Features/Panel/Preview/DocumentInlinePreview.swift", "init"):
        "WordDocumentRevision按标准化文件路径、修改时间和大小构成修订标识；WordDocumentStore.Entry保存该修订及导入正文，供缓存判断是否仍对应同一文档",
    ("Features/Panel/Preview/DocumentInlinePreview.swift", "cached"):
        "按文档URL读取最多8项的NSCache，只有修订标识一致才返回富文本正文及页面背景，供WordInlineContent和load复用",
    ("Features/Panel/Preview/DocumentInlinePreview.swift", "load"):
        "复用8项修订缓存及同修订在途Task；后台原生导入Word正文后，仅OOXML用ArchiveCore.run内存提取word/document.xml并交restoreOpenXMLFormatting恢复格式，再缓存正文与页面背景；读取或解析错误传递，完成后移除在途记录",
    ("Features/Panel/Preview/DocumentInlinePreview.swift", "makeNSView"):
        "为非Word文档构造compact样式QLPreviewView，关闭自动播放和随窗口关闭设置，指定URL为previewItem；Word正文另由AttributedTextView显示",
    ("Features/Panel/Preview/DocumentInlinePreview.swift", "updateNSView"):
        "SwiftUI更新QuickLook宿主时仅在URL不同才替换previewItem，由系统异步加载新文档，不再调用refreshPreviewItem",
    ("Features/Panel/Preview/DocumentInlinePreview.swift", "dismantleNSView"):
        "SwiftUI拆除内联QuickLook宿主时调用QLPreviewView.close释放预览内容",
    ("Features/Archive/UI/ArchivePeekView.swift", "init"):
        "FileContainerPreview按传入路径创建持有浏览状态的StateObject；FileContainerPreviewBrowser初始化根URL，共用文件夹和归档导航、选择及内联预览",
    ("Features/Archive/UI/ArchivePeekView.swift", "pathButton"):
        "把当前目录路径显示为单行按钮，点击交ClipboardManager.copyText复制完整路径，失败原因写入浏览器errorText",
    ("Features/Archive/UI/ArchivePeekView.swift", "load"):
        "先close撤销旧目录和文件预览，再在串行队列确认路径、解析符号链接并读取修订；主线程仅接纳当前listingGeneration结果，文件夹读目录、归档读条目，失败显示路径及原因",
    ("Features/Archive/UI/ArchivePeekView.swift", "readArchive"):
        "按URL、修改时间和大小复用最近4个归档条目缓存；未命中交ArchiveCore.list读取含辅助条目列表，同一浏览器已有读取时仅保存下一修订，当前代结果进入目录导航，失败显示具体原因",
    ("Features/Archive/UI/ArchivePeekView.swift", "readDirectory"):
        "增加listingGeneration并清空选择及预览；后台按归档路径前缀生成直属条目和隐含目录，或读取真实目录元数据，目录优先再按自然文件名排序，主线程只发布当前代结果",
    ("Features/Archive/UI/ArchivePeekView.swift", "enter"):
        "仅进入目录条目，把当前目录压入history后切换entry.path并读取下一层",
    ("Features/Archive/UI/ArchivePeekView.swift", "openSelectedDirectory"):
        "把当前选中的目录交enter，供进入按钮、回车和向右导航共用",
    ("Features/Archive/UI/ArchivePeekView.swift", "goUp"):
        "取history最后一层返回父目录并重新读取；无历史时保留根目录",
    ("Features/Archive/UI/ArchivePeekView.swift", "goRoot"):
        "清空history并把directory置空，重新读取文件夹或归档根目录",
    ("Features/Archive/UI/ArchivePeekView.swift", "select"):
        "选择变化先撤销旧预览并清理临时文件；目录只选中，普通文件直接后台render，归档文件交单项解压，已有解压时只保留最新待处理选择",
    ("Features/Archive/UI/ArchivePeekView.swift", "extract"):
        "调用ArchiveCore.extractEntryToTemp解压选中文件，当前previewGeneration结果交render；离开或换项后的落地文件立即清理，失败显示归档和条目路径，结束后执行最新待解压选择",
    ("Features/Archive/UI/ArchivePeekView.swift", "render"):
        "后台解析文件符号链接并创建只在内存存在的ClipboardItem及完整预览模型；归档条目用displayPath显示原包内路径，主线程仅接纳当前previewGeneration；FileContainerPreview以usesWindowChrome:false复用内容并隐藏快速查看按钮",
    ("Features/Archive/UI/ArchivePeekView.swift", "clearPreview"):
        "增加previewGeneration、取消预览任务及待解压选择，清空预览、加载态、选择和错误，存在临时解压文件时清理其所属目录",
    ("Features/Archive/UI/ArchivePeekView.swift", "removeTemporaryFile"):
        "从落地文件逐级定位temporaryDirectory的直接子目录并删除整个解压目录，内部同名前缀目录不作为清理单元，删除失败显示具体原因",
    ("Features/Archive/UI/ArchivePeekView.swift", "close"):
        "将浏览器设为非活动并增加listingGeneration，取消目录任务和待归档读取，交clearPreview撤销文件结果并清理临时解压目录",
    ("Features/Archive/Core/ArchiveCore.swift", "extractEntryToTemp"):
        "拒绝硬不安全条目路径后，在独立临时目录用已存密码解压单项；成功按完整条目路径或递归同名定位文件，解压失败或找不到文件时删除临时目录，清理失败与原原因一起返回",
    ("Features/Panel/Preview/PreviewPopoverContentView.swift", "fileInfo"):
        "按showsName和showsPath控制文件名及路径显示，路径使用model.displayPath或真实路径并交ClipboardManager复制；usesWindowChrome传入showsQuickLook控制快速查看按钮，打开、Finder和压缩仍作用真实文件，设置预览仅反馈",
    ("Features/Clipboard/UI/LargeTextPreviewView.swift", "refreshGridCache"):
        "记录当前textStorage及容器宽度，showsTableGrid为false时清空矩形并直接返回；开启时仅对含textBlocks的段落获取字形及单元格矩形，非表格段落跳过，不强制全文排版",
    ("Features/Clipboard/UI/LargeTextPreviewView.swift", "layout"):
        "AppKit布局后仅在同一textStorage且容器宽度变化时重算表格矩形并请求重绘，不在每轮布局强制排版",
    ("Features/Panel/Preview/DocumentInlinePreview.swift", "restoreOpenXMLFormatting"):
        "解析word/document.xml，按正文run顺序前向匹配导入文本，仅去掉原文w:b或w:i明确val=0的字体特性；按tblGrid及columnSpan恢复表格百分比列宽，结合gridSpan定位tcPr，把原文vAlign=top的单元格设为顶对齐",
    ("Features/Clipboard/UI/LargeTextPreviewView.swift", "init"):
        "保存传入富文本及showsTableGrid开关，默认true保留Markdown表格网格；WordInlineContent传false，使Word预览不额外绘制Markdown网格",
    ("Features/Clipboard/UI/LargeTextPreviewView.swift", "makeNSView"):
        "构造只读可选择的PreviewTextView及纵向NSScrollView，传入showsTableGrid、富文本和随视图宽度折行设置，再按网格开关建立单元格矩形缓存",
    ("Features/Clipboard/UI/LargeTextPreviewView.swift", "updateNSView"):
        "SwiftUI更新时传递showsTableGrid；仅富文本内容不同才替换textStorage并刷新表格矩形缓存，保持现有滚动宿主",
    ("Core/Motion/GenieWarp.swift", "duration"):
        "把已有配置0.18/0.22/0.28秒按min(0.44,max(0.28,0.28+(configured-0.18)))映射为280/320/380ms，开合共用此播放时长，输出限制为280…440ms",
    ("Core/Motion/GenieWarp.swift", "play"):
        "playIn与playOut共用入口；同一窗口反向请求交switchDirection复用现有帧序列，新动画采用probe.genieDuration或duration(for:)并预渲染后交startLeg；现有展开/收起日志追加self.duration×1000的实际播放毫秒",
    ("Core/Motion/GenieWarp.swift", "switchDirection"):
        "读取当前播放位置并翻转legSpeed，复用同一帧序列从当前位置续播；移除位置不足20ms时直接finish的分支，连续反向后接近起点仍可向终点播放",
    ("Features/Panel/Presentation/PanelController.swift", "show"):
        "无锚点重载进入show(atAnchor:)；可见窗口重开保留现有origin、anchorRect及三角态，仅首次显示校准材质尺寸和排版；playIn实际完成后执行finishShow启用采样，同一腿反向不提前启动采样",
    ("Features/Panel/Presentation/PanelController.swift", "toggle"):
        "无锚点重载进入toggle(atAnchor:)；isHiding期间再次触发立即show使旧关闭回调失效，覆盖预览等待与神灯收起两阶段；其余按真实窗口可见性开合",
    ("Features/Clipboard/Store/ClipboardFileStorages.swift", "write"):
        "基础写盘原子写入Data并返回成功标记；长文本和RTF返回已写相对路径，长文本含字节数；OCR按dedupeKey写UTF-8，成功后更新已有小写索引并在主线程发clipboardOCRTextChanged，PreviewImageView仅接收当前键且非设置预览的通知，回读ocrText、重算tidiedOCR并清除ocrError",
})


# 2026-11-15：补历史缺条；截图说明复用 1Capture-B-C-落地对照-2026-11-08.md，并按现有实现写明消费点。
EVIDENCE.update({
    ("Features/Capture/Annotation/AnnotationEditorWindow.swift", "textLines"):
        "仅文本马赛克落笔时调用；首次用MosaicTextOnly识别图像文本行，同次编辑复用textLineCache",
    ("Features/Capture/Annotation/AnnotationEditorWindow.swift", "selectShape"):
        "形状落笔及选择操作更新selectedShapeID，通知工具条同步选中属性并请求画布重绘",
    ("Features/Capture/Annotation/AnnotationEditorWindow.swift", "applyShapeStyleToSelection"):
        "形状样式浮层调用，交mutateSelectedShape修改当前选中标注的shapeStyle并记录撤销",
    ("Features/Capture/Annotation/AnnotationEditorWindow.swift", "applyShapeSizeToSelection"):
        "形状线宽控件调用，交mutateSelectedShape修改当前选中标注的lineWidth",
    ("Features/Capture/Annotation/AnnotationEditorWindow.swift", "mutateSelectedShape"):
        "按selectedShapeID定位标注，属性实际改变才记录不可合并的modify撤销项并通知工具条",
    ("Features/Capture/Annotation/MosaicTextOnly.swift", "textLineRects"):
        "AnnotationCanvasView.textLines调用Vision准确识别，把左下归一化文本框转为左上图像像素框；识别失败记录原因并返回空列表",
    ("Features/Capture/Annotation/MosaicTextOnly.swift", "stroke"):
        "仅文本马赛克按笔刷半径扩大文本行矩形，判断笔触点及相邻点中点是否命中，决定生成哪些行遮盖",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "init"):
        "控制器单例订阅图帘偏好和屏幕布局通知，启动时sync热区；RevealStripPanel按传入5pt框创建透明不激活状态栏级浮窗，只接进入事件不取键盘焦点",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "sync"):
        "CaptureModule启动及偏好、屏幕通知共用；图帘总开关与悬停开关同时开启才安装热区",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "install"):
        "相同屏幕几何复用已有热区，否则先拆旧窗，再为每个visibleFrame菜单栏下沿创建5pt透明条并接pointerEntered",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "uninstall"):
        "关闭悬停功能时拆除热区、停止轮询并清空安装状态和屏幕签名",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "teardownWindows"):
        "install重建与uninstall共用，将所有热区窗口orderOut后清空持有数组",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "pointerEntered"):
        "热区onEnter清除收起期限，调用正式ImageCurtainController.show并启动离开轮询",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "startPolling"):
        "只保留一个Task，每200ms调用tick判断热区与图帘之间的指针转移",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "stopPolling"):
        "卸载或图帘已隐藏时取消Task，清空任务与收起期限",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "tick"):
        "指针在热区扩展2pt或图帘扩展4pt内清除期限；离开800ms才hide，图帘已隐藏则停止轮询",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "preferencesChanged"):
        "curtainPreferencesChanged选择器交sync更新热区安装状态",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "screensChanged"):
        "屏幕参数通知选择器交sync按新屏幕几何重建热区",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "updateTrackingAreas"):
        "RevealStripView布局更新先移除旧跟踪区，再沿可见边界接收始终活动的进入事件",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "mouseEntered"):
        "RevealStripView把系统进入事件转给安装时接入的onEnter，不自行管理图帘内容",
    ("Features/Capture/Curtain/CurtainRevealController.swift", "hitTest"):
        "RevealStripView仅在自身bounds内返回自己，供透明5pt热区接收事件",
    ("Features/Capture/Pin/PinWindow.swift", "repinLast"):
        "AppBootstrap重新钉住快捷键复用lastImage及正式show；没有上一张图时返回false供上层提示",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "init"):
        "预置与用户比例共用模型构造，保存id、名称和builtin，宽高整数各至少1",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "parse"):
        "比例输入把中英文冒号、x、乘号、星号和斜杠统一为冒号，两个正整数经gcd约为最简宽高",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "gcd"):
        "parse用欧几里得余数循环约简输入比例，返回至少1的公因数",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "add"):
        "新增比例约简正整数宽高，已有相同比例直接复用，否则追加自定义项并save",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "remove"):
        "只移除customItems中的指定id；删除当前选中比例时清空selectedID恢复自由框选",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "save"):
        "add/remove将自定义比例数组编码为JSON Data存入capture.aspectRatios，预置表独立保留",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "greatestCommonDivisor"):
        "CaptureRatioStore.add用余数循环取得公因数，约简后比较与保存宽高",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "constrain"):
        "ScreenshotOverlay锁比例拖框以起点为锚，保持拖拽象限并按ratio推算另一边，超屏幕边界时等比缩小",
    ("Features/Capture/Screenshot/CaptureAspectRatio.swift", "square"):
        "ScreenshotOverlay自由框选按住Shift时，以较大的横纵距离构造保留象限的正方形终点",
    ("Features/Capture/Screenshot/CaptureExtraSettings.swift", "init"):
        "ExtraSettingRow保存标题与ViewBuilder内容，截图扩展设置共用92pt标签及7pt纵向间距",
    ("Features/Capture/Screenshot/CaptureFileName.swift", "make"):
        "ScreenshotManager正式落盘文件名入口，展开模板并sanitize，空名用时间戳且只补一次.png",
    ("Features/Capture/Screenshot/CaptureFileName.swift", "preview"):
        "截图设置以2560×1664和固定日期展示模板效果，consumeSequence=false不消耗当日序号",
    ("Features/Capture/Screenshot/CaptureFileName.swift", "expand"):
        "make/preview共用日期、尺寸、模式、应用名替换，seq和random由replacePattern处理；预览序号固定1并用确定数字串",
    ("Features/Capture/Screenshot/CaptureFileName.swift", "replacePattern"):
        "expand扫描不含右括号的seq/random前缀，解析可选数字参数并交transform；不完整参数保留原文继续扫描",
    ("Features/Capture/Screenshot/CaptureFileName.swift", "nextSequence"):
        "正式命名遇到seq时按yyyyMMdd读取当日计数，跨日从0起递增并写回日期及计数键",
    ("Features/Capture/Screenshot/CaptureFileName.swift", "sanitize"):
        "make/preview共用文件名字符替换，去首尾空白和前导点，长度截到180字符",
    ("Features/Capture/Screenshot/CaptureOCRNotify.swift", "show"):
        "CaptureOCRNotify入口交OCRNotePanel单例；面板把已复制文本压为单行，在屏幕顶部居中复用320×54窗，160ms淡入并按偏好延时收起",
    ("Features/Capture/Screenshot/CaptureOCRNotify.swift", "init"):
        "OCRNotePanel创建不激活且忽略鼠标的透明窗，装识别图标、单行文本及已复制标签",
    ("Features/Capture/Screenshot/CaptureOCRNotify.swift", "fadeOut"):
        "静默OCR提示期限到后220ms淡出，完成时orderOut并恢复alpha供下一条提示复用",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "init"):
        "WorkflowStep保存kind及两个参数；CaptureWorkflow保存名称、启用态和步骤，默认禁用；Runner私有构造供shared执行截图回调",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "load"):
        "设置页和截图回调从workflows/workflows.json解码数组，无可读配置时返回禁用的保存/识别/复制示例",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "save"):
        "设置persist将步骤数组原子写入workflows/workflows.json并设0600，含Token，保存失败记日志",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "imageCaptured"):
        "AppBootstrap截图落盘回调筛出启用且非空的工作流，已有执行时记录跳过，否则在既有串行队列逐个run",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "run"):
        "建立文件、名称、OCR文字和上传URL上下文，按步骤顺序perform，每步错误记录后继续后续步骤",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "perform"):
        "按步骤分派保存、复制PNG、OCR、钉图、上传及GitHub/Linear Issue；OCR和上传结果写入上下文供后续模板使用",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "recognizeText"):
        "OCR步骤调用正式OCRService.fast，后台信号量等待最多20秒，返回识别文本或传出实际错误",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "upload"):
        "上传步骤构造指定文件字段的PNG multipart请求，HTTP成功后取顶层url或data内url，缺字段抛出原因",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "createGitHubIssue"):
        "GitHub步骤按配置owner/repo及Bearer Token提交模板标题正文到issues端点，非2xx抛状态及响应前200字符",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "createLinearIssue"):
        "Linear步骤以Team ID及API Key发送issueCreate GraphQL，标题正文复用上下文模板，HTTP或GraphQL错误向run传出",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "template"):
        "两个Issue步骤共用name/text/url/date替换，上传URL为空显示未上传，日期按本地yyyy-MM-dd HH:mm:ss格式",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "synchronousRequest"):
        "上传与Issue步骤在后台队列用URLSession等待响应，30秒超时、网络错误和无响应均传给步骤日志",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "workflowBlock"):
        "设置页每条工作流显示启用和名称，按数组顺序列步骤，新增或删除立即persist",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "stepRow"):
        "步骤行按kind.fieldTitles显示最多两个参数框，绑定a/b；减号删除对应步骤并persist",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "icon"):
        "stepRow将七种正式步骤映射为各自SF Symbol图标",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "defaultArgument"):
        "添加保存步骤时预填RecordingOptions.saveDirectory.path，其余步骤参数为空供用户填写",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "binding"):
        "启用和名称控件按索引及可写KeyPath读写CaptureWorkflow，每次修改persist",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "stepBinding"):
        "参数框按工作流、步骤索引及KeyPath读写WorkflowStep，每次修改persist",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "persist"):
        "设置新增、删除及字段绑定共用WorkflowStore.save保存当前workflows",
})

EVIDENCE.update({
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "loadMoreIfNeeded"):
        "悬浮列表尾项onAppear调用，非设置预览且未加载、尚未达分类总数时将loadedLimit加120并fetch",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "cancel"):
        "备份sheet取消或离开时锁内标记cancelled，已finish则不改结果；已有归档taskID交ArchiveTaskQueue取消",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "install"):
        "export/prepareRestore登记异步归档taskID，登记前已取消的操作立即取消该任务",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "checkCancellation"):
        "备份准备、读取、分析及恢复循环锁内读取cancelled，取消时抛已取消，沿原完成回调返回",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "finish"):
        "导出发布、读取完成和恢复事务提交前锁内确认未取消并标记finished，后续cancel不改最终结果",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "init"):
        "prepareRestore成功构造RestoreSession持有解密目录、已读Manifest和分析摘要，供用户选择后restore",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "cleanup"):
        "RestoreSession被取消、完成或释放时在utility队列移除本次解密目录，复用removeTemporaryDirectory",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "deinit"):
        "RestoreSession释放时调用cleanup回收其临时明文目录",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "summary"):
        "prepareRestore把分析中的新增、重复、冲突原因和失效外部文件路径与条目/笔记/附件数量展示给sheet",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "export"):
        "ClipboardManager串行队列读快照与私有附件，以密码及加密文件名创建7z；新包先复制到目标旁临时文件再发布，清理明文并在主线程返回结果",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "prepareRestore"):
        "Manager读取入口确认7z签名，用归档任务列举并解密，验证Manifest和附件后与本机快照分析；只返回RestoreSession摘要，此阶段不写本机资料",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "restore"):
        "sheet确认后在Manager串行队列按replace及useBackupConflicts调用apply，成功清理解密目录；错误交主线程完成回调",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "prepare"):
        "export在数据库事务内读条目、标签和关联快照，复制四类私有附件及已有OCR并记字节数，最后原子写manifest.json",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "readSnapshot"):
        "导出和恢复分析共用正式ClipboardRepository列及makeItem，从SQLite读条目、标签和现存关联，再挂tagIDs构造version=1的Manifest",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "validateEntries"):
        "解压前要求唯一且加密的manifest.json与受支持attachments目录，拒绝链接、重名及未加密附件，附件相对路径交validatePath",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "readManifest"):
        "解密后和apply前读取version=1清单，核对条目/标签id及关联、必要与声明附件、实际普通文件及字节长度，异常抛具体资料路径",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "analyze"):
        "按dedupeKey比本机与备份的笔记、标题、标签名、正文、附件字节及OCR，计新增/重复/冲突；文件型正文路径不存在则列失效引用",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "apply"):
        "恢复时锁住数据库重新读取与分析，按合并/替换及冲突选择导入条目、标签和重映射私有附件；事务失败还原已移动附件，提交后仅回收不再引用附件并报告数量与失败路径",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "attachmentPaths"):
        "prepare/readManifest/apply共用image、thumbnail、text、richText四个非空相对路径，OCR按dedupeKey单独加入",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "fullText"):
        "analyze失效文件引用与apply文件分类优先读取备份textPath的UTF-8完整正文，无长文本附件才用item.content",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "validatePath"):
        "备份附件只接受images/thumbnails/texts/rich_texts/ocr下一层非空文件名，拒绝点路径、反斜杠及控制字符，限制真实导入路径",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "attachmentURL"):
        "私有附件读写共用validatePath，从解析过链接的root逐层确认普通目录及文件；mustExist=false仅允许尚未创建的路径段",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "byteCount"):
        "prepare记附件大小、readManifest比长度及apply计回收字节，共用FileManager.size读取",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "counts"):
        "导出结果和读取摘要共用Manifest条目总数、isNote数量及附件数量文案",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "temporaryDirectory"):
        "export/prepareRestore在系统临时目录创建带UUID的本次备份目录并设0700，承载待加密或解密内容",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "removeTemporaryDirectory"):
        "备份导出、取消、会话释放及恢复清理共用指定URL移除；失败写日志并返回含路径的明文清理原因",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "archiveFailure"):
        "7zz失败沿ArchivePasswords.looksLikePasswordError识别密码错误并保留原因，其余返回服务消息或7zz操作失败",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "deliver"):
        "备份后台成功与失败统一DispatchQueue.main.async交给sheet完成回调",
    ("Features/Clipboard/Store/ClipboardFileStorages.swift", "invalidateIndex"):
        "恢复备份成功后锁内将OCR内存索引设nil，下次正式检索重新读取恢复后的OCR文件",
    ("Features/Clipboard/Store/ClipboardManager.swift", "clearCurrentPasteboard"):
        "主面板和悬浮剪贴板菜单只清系统pasteboard，同步changeCount并清自写标记，提示已清空；历史数据库保留",
    ("Features/Clipboard/Store/ClipboardManager.swift", "clearUnsavedHistory"):
        "设置清历史先统计全部is_note=0和已存数量，确认后串行逐条调用正式repository.delete回收私有附件，通知预览移除并刷新，失败条目逐项报告",
    ("Features/Clipboard/Store/ClipboardManager.swift", "exportBackup"):
        "备份sheet导出入口把目标URL、密码、完成回调及Manager既有串行队列传给ClipboardBackup.export",
    ("Features/Clipboard/Store/ClipboardManager.swift", "prepareBackupRestore"):
        "备份sheet读取入口把文件、密码和Manager串行队列交ClipboardBackup.prepareRestore，返回可取消Operation",
    ("Features/Clipboard/Store/ClipboardManager.swift", "restoreBackup"):
        "确认恢复交ClipboardBackup.restore；成功才失效OCR索引、刷新标签、关闭共享预览、发选择变化并重载正式列表",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "unsavedHistory"):
        "clearUnsavedHistory统计与删除共用SELECT is_note=0，读取全部历史，不受当前列表筛选或分页影响",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "savedCount"):
        "clearUnsavedHistory确认文案用SELECT COUNT(*) WHERE is_note=1说明保留的已存项目数",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "execute"):
        "备份sheet按钮先置busy并清错误，按已有RestoreSession、导入或导出分派Manager正式入口；读取成功展示摘要并清密码",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "finish"):
        "导出/恢复完成复位busy及operation，成功清会话临时目录和密码、Toast后关闭sheet，失败显示localizedDescription",
})

EVIDENCE.update({
    ("Features/Island/IslandContent.swift", "updateMonitoring"):
        "页面、展开及首页监测组件可见性变化时交MonitorSampler.setIslandActive，设置预览不启动真实采样",
    ("Features/Island/IslandContent.swift", "pageContent"):
        "IslandRootView按唯一controller.page分派正式内容；中转页在近期记录与utilitiesOnly传输内容间切换",
    ("Features/Island/IslandContent.swift", "widgetContent"):
        "首页异构格按组件种类及尺寸装现有监测、近期记录、媒体、音量、日历和功能入口，预览用既有样例",
    ("Features/Island/IslandContent.swift", "widget"):
        "首页共用组件标题、颜色与glassCard外壳，标题切对应page；仅剪贴板格接收URL拖入",
    ("Features/Island/IslandContent.swift", "compactRecord"):
        "首页近期项显示单行及选中标记，原生IslandFileDragSource接单击预览、双击复制与文件拖出，延迟首页单击换页",
    ("Features/Island/IslandContent.swift", "receiveFiles"):
        "组件与记录页拖入仅收fileURL，真实文件交LocalTransferStore.add；开始/结束交互保留刘海，完成反馈并重载，预览仅反馈数量",
    ("Features/Island/IslandContent.swift", "select"):
        "设置selectedRecord与列表焦点，可切剪贴板页；显式预览且非设置预览时按来源panel交共用present",
    ("Features/Island/IslandContent.swift", "moveSelection"):
        "列表方向键及原生行onMove把选中索引夹在记录范围，调用select并scrollTo居中定位",
    ("Features/Island/IslandContent.swift", "copySelectedRecord"):
        "列表复制命令和原生行Cmd+C只按selectedRecord找到一行，交统一copy",
    ("Features/Island/IslandContent.swift", "draggingChanged"):
        "原生文件拖出回调更新recordDragging，拖出结束再reloadRecords，拖动中保留当前行视图",
    ("Features/Island/IslandContent.swift", "reloadRecords"):
        "展开、页面、剪贴板及中转通知只递增recordsRevision，触发现有.task(id:)的独立近期查询",
    ("Features/Island/IslandContent.swift", "loadRecords"):
        "后台独立fetch剪贴板并合并中转项，原路径和暂存路径别名去重，文件按路径拆行、按最新日期排序；取消或拖出中不发布，预览仅用样例，主列表筛选分页保留",
    ("Features/Island/IslandContent.swift", "fileIcon"):
        "loadRecords按真实目录及共用图片、归档、文档、影音、文本类型表选行图标",
    ("Features/Island/IslandContent.swift", "copy"):
        "Root的Task把结果写feedback；IslandRecentRow图片交copy、单文件交copyFiles，文本后台fullText并传出读取错误，富文本带原RTF交正式copy，预览仅反馈",
    ("Features/Island/IslandContent.swift", "makeNSView"):
        "IslandFileDragSource创建原生IslandFileDragView覆盖行内容，统一接记录点击、键盘和文件拖出",
    ("Features/Island/IslandContent.swift", "updateNSView"):
        "SwiftUI行更新把URL、controller、选择/复制/双击/移动回调、延迟选择及previewItem同步给同一原生视图",
    ("Features/Island/IslandContent.swift", "mouseDown"):
        "记录按下取消上次待选择工作，记录窗口起点并使原生行成为firstResponder，松手再区分点击与拖出",
    ("Features/Island/IslandContent.swift", "keyDown"):
        "原生行Cmd+C调用onCopy、上下键调用onMove、回车/空格showPreview并select，其余交AppKit",
    ("Features/Island/IslandContent.swift", "mouseDragged"):
        "文件移动至少3pt后逐项确认可读，使用NSURL pasteboardWriter及32pt文件图标发起copy拖出会话，开始时标记交互",
    ("Features/Island/IslandContent.swift", "mouseUp"):
        "非拖出双击调用onDoubleClick；首页单击等系统双击间隔再showPreview/select，其余立即预览选择，最后清起点",
    ("Features/Island/IslandContent.swift", "viewWillMove"):
        "原生行离开窗口时取消延迟选择工作，避免已卸载首页行再触发换页",
    ("Features/Island/IslandContent.swift", "draggingSession"):
        "NSDraggingSource操作掩码仅copy；结束重载清拖动与起点，endInteraction并回调onDraggingChanged(false)，反馈完成或取消",
    ("Features/Island/IslandContent.swift", "previewEvent"):
        "设置日历样例按钮只切controller.completedEvents中的示例索引，演示完成勾选，不写EventKit",
    ("Features/Island/IslandContent.swift", "eventRow"):
        "正式日历eventList复用标题和全天/开始时间排版，完整页可多行，组件格限单行",
    ("Features/Island/IslandContent.swift", "moveMonth"):
        "完整日历左右按钮以Calendar加减月份更新selectedDate后reload",
    ("Features/Island/IslandContent.swift", "reload"):
        "出现、每周首日、授权态及EventKit变更通知共用；完整页读monthDays后reloadEvents，组件只读事件",
    ("Features/Island/IslandContent.swift", "reloadEvents"):
        "完整月历优先复用选中CalendarDay.events，组件或未找到日期时按当天起止向CalendarService.events查询",
    ("Features/Island/IslandController.swift", "init"):
        "保存传入或.load的唯一配置和previewOnly；设置预览给180×28pt示例刘海，正式几何由position读屏幕",
    ("Features/Island/IslandController.swift", "surfaceAnimation"):
        "Surface及设置预览共用几何时序，减少动态用120ms easeOut，否则展开280ms/收起240ms无回弹spring",
    ("Features/Island/IslandController.swift", "apply"):
        "设置保存与组件排序共用，正式实例persist失败返回原因，成功替换配置并按enabled启停；预览只更新内存",
    ("Features/Island/IslandController.swift", "move"):
        "首页拖放或前后移动从widgetOrder移除来源并插到目标前，apply成功后通知layoutDidChange同步设置草稿",
    ("Features/Island/IslandController.swift", "beginInteraction"):
        "文件拖入拖出、格拖放及媒体滑杆操作置interacting，取消待收回工作",
    ("Features/Island/IslandController.swift", "endInteraction"):
        "交互结束重新读取指针，仍在外且非显式展开时按配置collapseDelay安排收回",
    ("Features/Island/IslandController.swift", "turnPage"):
        "底部翻页、Option方向键和横向滚动按IslandPage.tabs循环切换唯一page",
    ("Features/Island/IslandController.swift", "changeTrack"):
        "演示tracks按步长循环更新track并把seek归零；当前源码未找到调用，正式媒体send走NowPlayingController",
    ("Features/Island/IslandController.swift", "refreshClipboard"):
        "expand前独立取最近一条正文前24字符压平为摘要；预览取IslandSample标题",
    ("Features/Island/IslandController.swift", "copyLatest"):
        "收起态剪贴板快捷操作独立fetch最近一项交ClipboardManager.copy(autoPaste:false)，空列表给反馈，预览不写系统剪贴板",
    ("Features/Island/IslandController.swift", "copyDate"):
        "收起态日历快捷操作把当天ISO年月日交copyText并反馈，预览只改feedback",
    ("Features/Island/IslandController.swift", "activatePeek"):
        "收起态图标按peeksQuickActions执行复制或展开指定页，关闭快捷操作时统一打开peek.page",
    ("Features/Island/IslandController.swift", "surfaceDidChange"):
        "材质更新回传动画中实际size/radius，重算命中轮廓；到收起目标才卸内容、缩panel、归还焦点及执行afterCollapse，真实刘海无图标时隐藏外壳",
    ("Features/Island/IslandController.swift", "performOutside"):
        "截图、工具文件面板和正式外窗入口在展开时保存afterCollapse并收回，几何完成后执行；预览仅反馈",
    ("Features/Island/IslandController.swift", "start"):
        "App启动和apply启用时仅正式且enabled实例show，不启动设置预览窗口",
    ("Features/Island/IslandController.swift", "open"):
        "菜单栏、深链和键盘入口，禁用时打开刘海设置，否则show并expand(takeFocus:true)",
    ("Features/Island/IslandController.swift", "show"):
        "首次创建唯一透明非激活IslandPanel、事件监听和屏幕通知，装IslandRootView；后续复用窗口定位，空图标的真实刘海收起态不留可见外壳",
    ("Features/Island/IslandController.swift", "position"):
        "优先摄像头屏幕两侧auxiliaryTop区域求真实刘海中心宽高，无刘海用180×28入口；动画舞台不提前缩小，到收起态才按像素对齐缩到入口尺寸",
    ("Features/Island/IslandController.swift", "expand"):
        "取消待收回，首次展开前保存AppBootstrap划词结果、刷新摘要并挂内容；正式舞台扩大后显示，takeFocus请求键盘焦点",
    ("Features/Island/IslandController.swift", "collapse"):
        "收回先关闭来源panel的共用预览并取消悬停任务，清显式展开及采样、归还firstResponder，动画末由surfaceDidChange卸载内容",
    ("Features/Island/IslandController.swift", "stop"):
        "apply禁用时collapse并隐藏panel，移除本实例事件和屏幕通知后释放唯一窗口",
    ("Features/Island/IslandController.swift", "installMonitors"):
        "首次show挂全局/本地指针及按下事件，外部点击收回；窗内水平滚动累计超过36pt切页，交互结束统一endInteraction",
    ("Features/Island/IslandController.swift", "updatePointer"):
        "按实际可见动画轮廓判断鼠标并设置ignoresMouseEvents；摄像头区域悬停按配置延时展开，进入共享预览仍算在内，非显式且非交互离开才延时收回",
    ("Features/Island/IslandController.swift", "performKeyEquivalent"):
        "IslandPanel接Esc收回、Cmd+O展开、Option左右翻页及Cmd数字选所有页面并展开，其余交AppKit",
    ("Features/Island/IslandFeatureContent.swift", "compact"):
        "首页格尺寸决定录屏紧凑组件、截图/OCR正式CaptureModule按钮或详情页入口，较大格显示功能摘要",
    ("Features/Island/IslandFeatureContent.swift", "start"):
        "下载页按钮及回车先识别网盘分享交CloudLinkActions.resolve，否则完整http/https URL交现有直接下载器，预览只反馈",
    ("Features/Island/IslandFeatureContent.swift", "chooseImage"):
        "OCR页图片入口收回后用NSOpenPanel选图，后台读取Data交现有manager.recognize(inline:true)，失败给路径读取原因，结束重开刘海",
    ("Features/Island/IslandFeatureContent.swift", "choose"):
        "归档页收回后选择文件，创建模式可多选目录并交ArchiveCreateWindowController，打开模式交ArchiveBrowserWindowController，取消重新open",
    ("Features/Island/IslandMediaContent.swift", "cover"):
        "媒体大小形态共用播放器真实artwork，没有封面显示音乐图标；按side裁连续圆角并注明封面来源状态",
    ("Features/Island/IslandMediaContent.swift", "metadata"):
        "媒体完整页与格共用标题、歌手、专辑和播放器来源，full控制字号及折行，小格省歌手",
    ("Features/Island/IslandMediaContent.swift", "transport"):
        "完整/紧凑播放器共用上一首5、下一首4及playButton，send闭包由正式或设置预览宿主提供",
    ("Features/Island/IslandMediaContent.swift", "playButton"):
        "媒体不同尺寸共用命令2切播放，图标及无障碍标签跟snapshot.isPlaying变化",
    ("Features/Island/IslandMediaContent.swift", "progress"):
        "仅有正duration及position时提供Slider，拖动用scrub并beginInteraction，松手seek后endInteraction；未知时长完整页显示服务状态",
    ("Features/Island/IslandMediaContent.swift", "time"):
        "progress和方形媒体格将非负秒格式为分:秒，达到一小时使用时:分:秒",
    ("Features/Island/IslandMonitorChart.swift", "values"):
        "图表及指标卡共用正式sampler.history，CPU/GPU百分比、内存GiB、下载KB/s、功耗W与电池百分比；无当前读数返回空，预览取既有固定曲线",
    ("Features/Island/IslandMonitorChart.swift", "upperBound"):
        "CPU/GPU/电池上界100，内存取真实总GiB，下载及功耗取窗口最大值×1.15且至少1，预览用metric上界",
    ("Features/Island/IslandMonitorChart.swift", "positionLabel"):
        "图表头将最后点标当前，预览标相对秒、正式标前N个采样，并按pinned追加固定态",
    ("Features/Island/IslandMonitorChart.swift", "xPosition"):
        "图表游标按索引映射0…1横坐标，单个电池点置最右端",
    ("Features/Island/IslandMonitorChart.swift", "index"):
        "悬停与拖动把横向位置按图宽四舍五入为采样索引并夹入现有values范围",
    ("Features/Island/IslandMonitorChart.swift", "plot"):
        "按style复用MonitorAreaSparkline/MonitorSparkline或实际采样柱，compact控制线宽和间距，柱选中态提高透明度",
    ("Features/Island/IslandMonitorChart.swift", "statistic"):
        "趋势页平均、峰值、当前共用标签和等宽数值排版，数值由同一范围的正式values生成",
    ("Features/Island/IslandSettings.swift", "size"):
        "组件排列和设置Picker共用配置尺寸，未配置监测/剪贴板默认wide、其余small；单行和不足列数时适配到可放尺寸",
    ("Features/Island/IslandSettings.swift", "color"):
        "widget与metric两个重载分别读取配置十六进制颜色，没有有效颜色用各自枚举色，正式与设置预览共用",
    ("Features/Island/IslandSettings.swift", "load"):
        "正式controller和设置草稿解码island.configuration，新组件补到已有widgetOrder尾部，失败日志后使用默认配置",
    ("Features/Island/IslandSettings.swift", "persist"):
        "正式IslandController.apply把当前Codable配置编码存入唯一island.configuration键，编码错误传回设置保存",
    ("Features/Island/IslandSettings.swift", "format"):
        "图表、指标卡和统计共用单位格式，百分比/KB/s取0小数，GiB/W取1小数并带unit",
    ("Features/Island/IslandSettings.swift", "islandMove"):
        "设置顺序按钮、键盘和指标拖放从既有数组移除item后插到目标索引，不创建第二份排序状态",
    ("Features/Island/IslandSurface.swift", "body"):
        "IslandMorph以同一size/progress补间驱动圆角、材质遮罩、内容透明度和命中；IslandGlow按共享鼠标位置只在卡片内绘制径向背景及边框亮光",
    ("Features/Island/IslandSurface.swift", "path"):
        "IslandOutline在连续圆角矩形顶端补矩形，使可见上沿贴顶，材质mask与controller命中轮廓共用",
    ("Features/Island/IslandSurface.swift", "makeNSView"):
        "IslandMaterial用当前solid创建唯一原生材质视图，不在每帧重建玻璃",
    ("Features/Island/IslandSurface.swift", "updateNSView"):
        "动画几何更新仅在radius变化时请求layout，并把当前size/radius回报controller.surfaceDidChange",
    ("Features/Island/IslandSurface.swift", "init"):
        "IslandMaterialView创建固定darkAqua、followsWindowFocus=false的正式LiquidGlass并加轮廓mask；coder初始化明确不可用",
    ("Features/Island/IslandSurface.swift", "layout"):
        "仅bounds或radius变化时更新玻璃frame和mask，关闭CALayer隐式动画，上角移出屏幕保持顶边贴合及底部曲率",
    ("Features/Island/IslandSurface.swift", "makeBody"):
        "IslandButtonStyle把label、按压态、help及提示对齐交IslandButtonBody，所有刘海按钮复用悬停与焦点绘制",
    ("Features/Island/IslandSurface.swift", "button"):
        "收起态按peekOrder与可见集合生成图标，点击交activatePeek，配置决定是否带72pt数值或38pt纯图标，功耗订阅正式采样",
    ("Features/Island/IslandSurface.swift", "value"):
        "收起态标签返回复制、播放/暂停和当天日期，功耗读已有sample.powerWatts，设置预览显示8.6W",
    ("Features/Island/IslandSurface.swift", "islandGlow"):
        "WidgetGrid给每个卡片传共享pointer、局部frame、半径和enabled，修饰器只交IslandGlow绘制层消费位置",
    ("Features/Island/IslandToolboxContent.swift", "init"):
        "Root传唯一controller、预览标志和selectedTool绑定，保留onFileDialog回调让系统文件面板期间不卸输入页",
    ("Features/Island/IslandToolboxContent.swift", "directory"):
        "全部功能目录按query匹配页面标题及已启用工具名称/关键字/描述，category筛工具；回车选首项、按钮更新page或selectedTool",
    ("Features/Island/IslandToolboxContent.swift", "previewContent"):
        "设置预览复用IslandSample文本及工具默认选项，仅切结果区域和复制/保存反馈，不创建ToolRunnerView或ToolOutput",
    ("Features/Island/IslandWidgetGrid.swift", "move"):
        "组件把手点击、菜单及方向键按现有widgetOrder前后索引交controller.move，末端不越界",
    ("Features/Monitor/Sampling/MonitorSampler.swift", "setIslandActive"):
        "刘海监测实际可见时设置islandActive并applyPreferences重新安排现有采样，激活立即refresh，状态相同不重复安排",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "init"):
        "草稿加载唯一配置并建立previewOnly控制器，预览排序回调只同步widgetSizes/widgetOrder/metricOrder到草稿",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "save"):
        "SettingsDraftEditor保存交正式IslandController.apply，失败返回原因，成功才更新saved与脏态通知",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "discard"):
        "设置取消把configuration恢复saved，didSet同步内存预览",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "restoreDefaults"):
        "设置恢复默认只替换草稿为IslandConfiguration，保存按钮才应用正式顶部组件",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "updatePreview"):
        "草稿configuration.didSet交previewController.apply，仅更新previewOnly实例内存",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "setGrid"):
        "画布列/行Picker更新草稿gridColumns/gridRows，宽高至少新minimumWidth/minimumHeight，didSet自动刷新预览",
    ("Features/Audio/AudioMixer.swift", "setIslandVisible"):
        "刘海音量组件按consumer登记可见性，只监听默认输出状态，不启动设置页出声进程采样；最后消费者离开且设置不可见时移除监听",
    ("Features/Audio/AudioMixer.swift", "addOutputListeners"):
        "设置页或刘海音量首次可见时监听设备列表、默认输出、实际音量属性与静音，登记成功项供成对移除，失败显示状态码",
    ("Features/Audio/AudioMixer.swift", "removeOutputListeners"):
        "最后输出消费者离开时按保存的object/property逐项移除CoreAudio listener，清监听数组及设备id",
    ("Features/Audio/AudioMixer.swift", "refreshOutputState"):
        "音量监听及设置/刘海出现共用读取，按设备实际属性更新可读态、音量、静音和设备列表，readingOutput覆盖本次读取",
    ("Features/Audio/AudioMixer.swift", "volumeProperties"):
        "音量读写和监听共用设备公开属性，依次选voll或VolumeScalar主音量，没有则读取首选左右声道并保留存在的声道属性",
    ("Features/Audio/NowPlayingController.swift", "setVisible"):
        "正式媒体宿主按UUID登记消费者，首次可见立即刷新并每秒更新，最后离开停止timer、osascript及封面任务并清快照",
    ("Features/Audio/NowPlayingController.swift", "refresh"):
        "可见媒体timer仅在process为空时request(read)，复用同一系统正在播放读取路径",
    ("Features/Audio/NowPlayingController.swift", "send"):
        "媒体上一首/播放暂停/下一首把命令整数转为action交request，再读取系统返回的实际快照",
    ("Features/Audio/NowPlayingController.swift", "seek"):
        "媒体进度松手把秒数用MediaRemote命令24及seconds交request",
    ("Features/Audio/NowPlayingController.swift", "request"):
        "同一osascript JXA脚本读取或控制MediaRemote，后台收stdout并在主线程仅接纳当前Process结果；解码快照、反馈commandAccepted，曲目或封面变化才loadArtwork",
    ("Features/Audio/NowPlayingController.swift", "loadArtwork"):
        "新快照先取消旧封面任务，优先解播放器base64图片，否则读取播放器提供的文件或网络URL；取消后不发布，失败给实际读取原因",
})

EVIDENCE.update({
    ("Features/Recording/RecordingCompositor.swift", "cameraRect"):
        "摄像头合成按视频宽度2%留边，画中画宽占10…35%、高为宽×4/3，按四角返回左上原点像素矩形",
    ("Features/Recording/RecordingConfig.swift", "init"):
        "RecordingOptions默认值构造供.current及录制器currentOptions使用，配置集中为单个值类型",
    ("Features/Recording/RecordingConfig.swift", "current"):
        "整屏、区域及模块入口读取现有fps/音源/光标/摄像头/键鼠叠加/排除应用偏好，附传入region和displayID组装本次RecordingOptions",
    ("Features/Recording/RecordingEditorWindow.swift", "init"):
        "RecordingEditorController私有构造限制为shared，持有唯一录后编辑窗及播放器",
    ("Features/Recording/RecordingEditorWindow.swift", "open"):
        "ScreenRecorder.stop成功交实际mp4 URL，复用编辑窗换AVURLAsset/AVPlayer，重置入出点滑杆到全片并显示时长",
    ("Features/Recording/RecordingEditorWindow.swift", "makeWindow"):
        "首次open建720×520可缩放原生编辑窗，统一officialChrome，装AVPlayerLayer预览、两条裁剪滑杆和播放/静音/导出/Finder按钮",
    ("Features/Recording/RecordingEditorWindow.swift", "makeLabel"):
        "编辑窗入出点与区间提示共用11pt等宽数字NSTextField并按指定坐标放置",
    ("Features/Recording/RecordingEditorWindow.swift", "makeButton"):
        "编辑窗播放、导出和Finder按钮共用圆角NSButton，target=self接对应Selector",
    ("Features/Recording/RecordingEditorWindow.swift", "trimChanged"):
        "两条滑杆动作使入点不超过出点减0.1秒，更新标签并把播放器seek到入点",
    ("Features/Recording/RecordingEditorWindow.swift", "updateLabels"):
        "open及trimChanged把当前两条滑杆值格式为入点/出点一位小数秒，复用现有标签",
    ("Features/Recording/RecordingEditorWindow.swift", "togglePlay"):
        "播放按钮按AVPlayer.rate暂停或播放，当前时间在所选区间外时先seek入点；没有另设时间轴",
    ("Features/Recording/RecordingEditorWindow.swift", "revealInFinder"):
        "编辑窗Finder按钮按当前AVURLAsset.url定位录制原文件",
    ("Features/Recording/RecordingEditorWindow.swift", "exportMovie"):
        "导出按钮读取入出点，用NSSavePanel选择-trimmed.mp4目标，确认后把CMTimeRange及静音勾选传performExport",
    ("Features/Recording/RecordingEditorWindow.swift", "performExport"):
        "最高质量AVAssetExportSession导出选中区间到目标旁临时mp4，静音时各音轨音量置0；成功才替换/移动目标并定位Finder，失败显示原因，末尾清临时输出",
    ("Features/Recording/RecordingHUD.swift", "init"):
        "HUD控制器与区域选择器都私有构造供shared，分别持有唯一控制条和本次截图覆盖窗数组",
    ("Features/Recording/RecordingHUD.swift", "show"):
        "录制开始复用或首次makePanel的控制条orderFrontRegardless，再refresh真实录制状态",
    ("Features/Recording/RecordingHUD.swift", "hide"):
        "ScreenRecorder.stop将已持有控制条orderOut，下一次录制继续复用",
    ("Features/Recording/RecordingHUD.swift", "refresh"):
        "录制timer及暂停/恢复共用elapsedText，按paused切橙点/播放图标，其余红点/暂停图标，控制条跟鼠标所在屏幕顶部定位",
    ("Features/Recording/RecordingHUD.swift", "makePanel"):
        "首次show创建190×40非激活浮窗，sharingType=.none排除自身录屏，装红点、计时、暂停与停止按钮",
    ("Features/Recording/RecordingHUD.swift", "iconButton"):
        "HUD暂停及停止共用24pt无边框图标NSButton，接本控制器Selector",
    ("Features/Recording/RecordingHUD.swift", "togglePause"):
        "HUD暂停按钮调用正式ScreenRecorder.togglePause后刷新图标和计时态",
    ("Features/Recording/RecordingHUD.swift", "stopRecording"):
        "HUD停止按钮在Task中等待正式ScreenRecorder.stop收尾与打开编辑器",
    ("Features/Recording/RecordingHUD.swift", "pick"):
        "区域录制取得正式屏幕权限及快照，为各屏复用ScreenshotOverlayWindow，确认局部框转换AppKit全局坐标交finish，取消交nil",
    ("Features/Recording/RecordingHUD.swift", "finish"):
        "区域选择完成统一隐藏并释放覆盖窗，只对宽高均大于8pt的框回调一次，取消清completion",
    ("Features/Recording/RecordingInputMonitor.swift", "init"):
        "RecordingInputMonitor私有构造供shared，锁内键鼠列表由唯一录制生命周期启停",
    ("Features/Recording/RecordingInputMonitor.swift", "start"):
        "ScreenRecorder启用按键/点击叠加时读现有AX授权，开512KiB栈线程runTap并等待50ms返回可用态，失败由录制器列不可用功能",
    ("Features/Recording/RecordingInputMonitor.swift", "stop"):
        "录制停止、取消或启动失败时停止tap RunLoop、关闭CFMachPort并清锁内键鼠记录",
    ("Features/Recording/RecordingInputMonitor.swift", "reset"):
        "录制开始且输入tap成功时锁内清历史，避免录前按键和点击进入首帧",
    ("Features/Recording/RecordingInputMonitor.swift", "currentKeys"):
        "合成视频帧锁内移除超过1.6秒按键后返回快照，供RecordingCompositor.keyOverlay",
    ("Features/Recording/RecordingInputMonitor.swift", "currentClicks"):
        "合成视频帧锁内移除超过0.65秒点击后返回快照，供扩散点击环",
    ("Features/Recording/RecordingInputMonitor.swift", "cursorPoint"):
        "既有注入探针将NSEvent鼠标左下全局坐标按主屏高度翻为CG左上全局坐标",
    ("Features/Recording/RecordingInputMonitor.swift", "injectProbeEvents"):
        "仅FRSET_RECORD_OVERLAY_PROBE既有路径锁内放入Cmd/Shift/K及当前位置左击，供原合成探针显示；正常事件由CGEventTap提供",
    ("Features/Recording/RecordingInputMonitor.swift", "runTap"):
        "输入线程创建listenOnly全局keyDown及左右按下tap，回调交handle并原样返回事件，在本线程RunLoop启用采集，创建失败日志并置running=false",
    ("Features/Recording/RecordingInputMonitor.swift", "handle"):
        "tap键事件经describe，80ms内相同键去重并保留最近6项；点击保存CG坐标/时刻/左右态，最多12项",
    ("Features/Recording/RecordingInputMonitor.swift", "describe"):
        "handle把CGEvent修饰键拼为符号并接specialKey或大写可显示字符，控制字符只保留修饰键",
    ("Features/Recording/RecordingInputMonitor.swift", "specialKey"):
        "describe按keycode映射回车、空格、删除、Esc、方向及翻页键为可显示标签",
    ("Features/Recording/RecordingModule.swift", "start"):
        "AppModule启动登记priority=45的正式录屏面板区段；已有FRSET_RECORD_PROBE显式环境路径延迟4秒启动并录3秒后停止",
    ("Features/Recording/ScreenRecorder.swift", "init"):
        "RecordingPipeline构造保存本次options、视频像素尺寸、区域原点、缩放与输出URL；ScreenRecorder私有构造供shared管理唯一当前会话",
    ("Features/Recording/ScreenRecorder.swift", "prepareWriter"):
        "start创建mp4 H.264实时视频轨，按像素量限制码率4…24Mbps，合成适配器用BGRA；选音源时建48kHz双声道128kbps AAC轨，startWriting失败传具体原因",
    ("Features/Recording/ScreenRecorder.swift", "setPaused"):
        "ScreenRecorder.pause/resume将paused变更交管线串行queue，视频和所选音频回调据此丢弃暂停帧",
    ("Features/Recording/ScreenRecorder.swift", "finish"):
        "stop或取消启动在管线queue停止摄像头/麦克风，标记轨完成并等待AVAssetWriter.finishWriting，成功返回本次URL，失败日志并返回nil",
    ("Features/Recording/ScreenRecorder.swift", "startCamera"):
        "本次cameraEnabled时按配置设备或系统默认摄像头建AVCaptureSession.high，BGRA帧交cameraQueue回调，不可用返回false供录制提示",
    ("Features/Recording/ScreenRecorder.swift", "startMicrophone"):
        "本次音源microphone才建默认音频AVCaptureSession，delegate在audioQueue供写入AAC轨；启动失败返回false供上层提示",
    ("Features/Recording/ScreenRecorder.swift", "stopDevices"):
        "管线finish停止并释放cameraSession与micSession，屏幕流另由ScreenRecorder停止",
    ("Features/Recording/ScreenRecorder.swift", "stream"):
        "SCStreamOutput按screen/audio分派handleVideo/handleAudio；SCStreamDelegate错误回调记录中断并交onStopped，由当前管线身份匹配后正式stop",
    ("Features/Recording/ScreenRecorder.swift", "handleVideo"):
        "首个有效视频PTS开启writer会话，暂停丢帧；无摄像头/键鼠叠加时直接append原缓冲，否则取像素池、实际输入与摄像头交正式Compositor再按原PTS写盘",
    ("Features/Recording/ScreenRecorder.swift", "currentCameraBuffer"):
        "handleVideo合成前cameraLock内读取latestCamera，摄像头delegate用同一锁发布帧",
    ("Features/Recording/ScreenRecorder.swift", "handleAudio"):
        "屏幕流音频仅本次system音源且audioInput可写、非暂停时append，不混入麦克风路径",
    ("Features/Recording/ScreenRecorder.swift", "captureOutput"):
        "AVCapture视频回调锁内更新latestCamera；麦克风回调仅microphone音源且可写、非暂停时append同一音频轨",
    ("Features/Recording/ScreenRecorder.swift", "startDisplayRecording"):
        "主面板、快捷键及toggle入口读取鼠标所在显示器id和.current配置，在Task调用统一start",
    ("Features/Recording/ScreenRecorder.swift", "startRegionRecording"):
        "主面板及快捷键复用RecordingRegionPicker，确认实际全局矩形后按当前显示器和偏好调用统一start",
    ("Features/Recording/ScreenRecorder.swift", "start"):
        "唯一录制入口取得本次屏幕/所选设备授权并报告不可用叠加，makeStream与prepareWriter后接屏幕及可选系统音轨，启动设备和SCStream成功才置recording、计时并显示HUD；失败收尾当前管线",
    ("Features/Recording/ScreenRecorder.swift", "pause"):
        "recording态设置管线paused，累加有效计时并清startedAt，停timer、置paused和刷新HUD",
    ("Features/Recording/ScreenRecorder.swift", "resume"):
        "paused态恢复管线写入、startedAt和recording态，重开timer并刷新HUD",
    ("Features/Recording/ScreenRecorder.swift", "togglePause"):
        "HUD、面板与刘海暂停入口只按recording/paused选择pause或resume",
    ("Features/Recording/ScreenRecorder.swift", "stop"):
        "设置finishing后停止timer/HUD/输入采集；准备中标取消，其余停SCStream并等待管线finish，成功显示实际文件并开编辑器，中断仍保留已写视频及原因",
    ("Features/Recording/ScreenRecorder.swift", "startTimer"):
        "start/resume先停旧timer再每200ms发布accumulated加本段时间，刷新同一HUD",
    ("Features/Recording/ScreenRecorder.swift", "stopTimer"):
        "暂停、停止及重开计时共用invalidate并清唯一timer",
    ("Features/Recording/ScreenRecorder.swift", "makeStream"):
        "从SCShareableContent选目标显示器并排除配置App，将AppKit区域换CG及显示器本地points；按实际缩放、fps、光标、BGRA和可选系统音频建SCStreamConfiguration，返回同一流队列及尺寸原点",
    ("Features/Recording/ScreenRecorder.swift", "currentDisplayID"):
        "整屏及区域入口按NSEvent鼠标所在NSScreen用ScreenSnapshot.displayID取得实际显示器id",
    ("Features/Recording/ScreenRecorder.swift", "uniqueOutputURL"):
        "start在RecordingOptions.saveDirectory按日期时分秒生成Recording文件名，存在时递增-2、-3后缀，不覆盖录制原片",
    ("Features/Recording/ScreenRecorder.swift", "toggleRecording"):
        "设置页、状态栏和快捷键共用入口，当前state.isActive则Task等待stop，否则startDisplayRecording",
})

EVIDENCE.update({
    ("App/AppBootstrap.swift", "readSelection"):
        "命令面板、划词快捷键及刘海展开前读取真实前台AX焦点的SelectedText，拒绝自身前台及密码字段，不取系统剪贴板，返回具体授权或应用选区错误",
    ("App/AppBootstrap.swift", "runSelectionAction"):
        "快捷键、命令面板和刘海OCR划词按钮共用已捕获SelectionResult或readSelection；失败Toast，翻译取消旧请求交translateAndIngest，其他动作交正式ToolRunnerWindow自动执行",
    ("Core/UI/LiquidGlassMaterial.swift", "makeView"):
        "正式玻璃背景和刘海共用工厂，26+且非纯色、随焦点及系统玻璃开关允许时建NSGlassEffectView，其余建固定inactive的NSVisualEffectView；降低透明度走不透明材质",
    ("Core/UI/LiquidGlassMaterial.swift", "reapplyStyle"):
        "LiquidGlassBackground更新共用已建容器重设圆角，真玻璃改tint，毛玻璃按solid与降低透明度更新材质/混合并固定inactive",
    ("Core/UI/LiquidGlassMaterial.swift", "setCornerRadius"):
        "工厂、重套样式与刘海layout共用几何更新，真玻璃设cornerRadius，其余CALayer设连续圆角，不重设材质",
    ("Core/UI/LiquidGlassMaterial.swift", "embed"):
        "正式材质宿主统一addSubview并用四边约束铺满内容；沿既有崩溃记录不使用NSGlassEffectView.contentView",
    ("Core/UI/LiquidGlassMaterial.swift", "glassCard"):
        "正式GlassCard修饰器和刘海格共用传入fill/stroke的连续圆角裁剪、背景及hairline描边，描边不接鼠标事件",
    ("Core/UI/ThemeTokens.swift", "accent"):
        "刘海正式与设置预览等明确颜色入口返回传入Color，无指定时用系统accentColor，不读取服务状态",
    ("Core/UI/ThemeTokens.swift", "cardFillAlpha"):
        "Support.swift的Theme.cardFill消费卡片亮度，按深浅色计算透明度：深色0.035+0.065×lift、浅色0.55+0.43×lift，正式与设置预览共用数值公式",
    ("Core/UI/ThemeTokens.swift", "cardStrokeAlpha"):
        "Support.swift的Theme.cardStroke消费描边强度，深色透明度0.02+0.16×strength、浅色0.02+0.14×strength，供正式卡片与设置预览使用",
    ("Features/AI/Views/AISummaryView.swift", "init"):
        "029de12台账已有StateObject构造说明；现有inputText构造创建ViewModel，ToolRunnerWindow传model重载持有同一运行模型，使停止请求作用当前摘要",
    ("Features/Archive/Core/ArchiveServices.swift", "copyPaths"):
        "Finder服务从传入pasteboard读真实文件URL，把绝对路径逐行写系统剪贴板并提示数量，无文件或写入失败写服务error并Toast",
    ("Features/Archive/Core/ArchiveServices.swift", "openInTerminal"):
        "Finder服务把文件转换父目录、目录保留自身并去重，找到com.apple.Terminal后逐目录用NSWorkspace.open；读取、应用缺失或打开失败各显示具体路径原因",
    ("Features/Monitor/Storage/DiskIndex.swift", "match"):
        "summarize按实际目录名与Library层级识别缓存、日志、开发与应用支持类别，/var/log及Xcode.app有明确分类，其他返回nil沿父类别",
    ("Features/Monitor/Storage/DiskIndex.swift", "summarize"):
        "扫描及缓存更新递归将目录ownSize、文件size各计一次，遇实际分类目录切类别和归属路径，最终各类别用independentPaths列包含目录",
    ("Features/Monitor/Storage/DiskIndex.swift", "retainFile"):
        "扫描目录文件时只保留达到minimumFileBytes的条目，按字节数降序插入，超过childrenPerDirectory移除最小项，完整占用另计",
    ("Features/Monitor/Storage/DiskIndex.swift", "independentPaths"):
        "分类汇总及多路径操作将路径集合排序，已有父路径时移除被包含子路径，避免同一目录重复参与操作",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "rightPane"):
        "存储窗口右区复用StorageTreemap并接既有目录历史、钻取、选择及返回；根目录传实际空闲空间，顶部标签让出contentTop，分类详情只展示，真实路径删除仍交原确认流程",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "categoryDetail"):
        "右区系统数据分类详情显示本次扫描根、类别字节、独立目录与coverageHelp，说明折叠及子分类扣除范围，不自动加入清理推荐",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "refreshedNavigationNode"):
        "索引变化刷新访问历史与详情，真实路径取新snapshot节点，disk-files聚合按父ownSize更新，其余聚合递归保留现存孩子并重算大小与折叠数量",
    ("Features/Monitor/Views/MonitorCard.swift", "init"):
        "正式指标卡ViewBuilder内容一次构造成持有的Content，body沿原10pt padding及GlassCardBackground材质",
    ("Features/Panel/Presentation/PanelController.swift", "hide"):
        "029de12已有onDismiss/toggle/TransientWindowCenter消费说明；当前无参重载交带completion入口，收回保存尺寸并关闭来源预览，Genie正在展开立即反向，其余按hideGeneration只启动一次performHide",
    ("Features/Settings/Shell/SettingsBlockProbeWindow.swift", "init"):
        "SettingsBlockProbeWindowController私有构造供shared，现有设置区块深链持有展示窗",
    ("Features/Settings/Shell/SettingsBlockProbeWindow.swift", "open"):
        "FrsetNextApp现有区块深链按recording/workflow/capture或个性化scope装正式设置内容，注入SettingsEditingSession，用760×980原生officialChrome窗展示独立区块",
    ("Features/StatusBar/MenuBarIconStyle.swift", "makeCoordinator"):
        "菜单栏图标设置预览创建Coordinator保存style/symbol及rotatingView，update只在样式变化重建，拆除时停止旋转",
    ("Features/StatusBar/StatusBarController.swift", "openIslandAction"):
        "菜单栏刘海工作台Selector只交唯一IslandController.shared.open，不另建展示窗口",
    ("Features/Toolbox/Calendar/CalendarService.swift", "calendar"):
        "monthDays与CalendarSectionView共用Gregorian Calendar，指定zh_CN、用户firstWeekday和当前时区，月历周排列沿同一口径",
    ("Features/Toolbox/Search/SearchSectionView.swift", "previewAction"):
        "设置预览的网页/工具/引擎动作仅显示演示反馈，消费clearSearchInputAfterWebAction决定调用clearInput或保留输入",
    ("Features/Toolbox/Shell/ToolboxSectionView.swift", "outputContent"):
        "ToolRunnerView正式与刘海紧凑结果共用图片、可选文本及note排版，compact把图片最大高度降到120，文本错误着红且可选择，图片菜单沿copyImage",
    ("Features/Toolbox/Shell/ToolboxSectionView.swift", "startRun"):
        "执行按钮、输入提交及去重选项变化共用run；紧凑刘海取消旧runTask并持有新Task，完整页沿原Task执行",
    ("Features/Toolbox/Tools/ToolRunnerWindow.swift", "stopAIRequest"):
        "AppBootstrap划词翻译启动前调用当前summaryModel.stop，取消与翻译竞争的已有工具摘要请求",
    ("Models/Models.swift", "classify"):
        "ClipboardItem构造、入库、旧资料迁移及备份恢复共用换行文件路径分类，按UTType把PDF/音频/视频位合并到fileCategories",
})

# ── v263：图帘改名（悬挂架 → 图帘；Shelf* → Curtain*，文件同步改名）──────────
# 证据本身没变，只是键跟着改名。不迁移的话，100+ 条老函数会被判成「新增」。
_PATH_ALIASES = {
    "Features/Capture/Shelf/ShelfModel.swift": "Features/Capture/Curtain/CurtainModel.swift",
    "Features/Capture/Shelf/ShelfWindow.swift": "Features/Capture/Curtain/CurtainWindow.swift",
    "Features/Capture/Shelf/ShelfController.swift": "Features/Capture/Curtain/CurtainController.swift",
    "Features/Settings/Panes/ShelfSettingsPane.swift": "Features/Settings/Panes/CurtainSettingsPane.swift",
}
_NAME_ALIASES = [
    ("ScreenshotShelfController", "ImageCurtainController"),
    ("Shelf", "Curtain"),
]
for (_old_file, _old_name), _ev in list(EVIDENCE.items()):
    _new_file = _PATH_ALIASES.get(_old_file, _old_file)
    _new_name = _old_name
    for _a, _b in _NAME_ALIASES:
        _new_name = _new_name.replace(_a, _b)
    if (_new_file, _new_name) != (_old_file, _old_name):
        EVIDENCE.setdefault((_new_file, _new_name), _ev)


def main() -> int:
    strict = "--strict" in sys.argv

    inv = list(csv.DictReader(open(CSV, encoding="utf-8-sig")))
    led = list(csv.DictReader(open(LED, encoding="utf-8-sig")))

    by_name = collections.defaultdict(list)
    for r in inv:
        by_name[(r["file"], r["owner"], r["kind"], r["name"])].append(int(r["line"]))
    for k in by_name:
        by_name[k].sort()

    # 重载（同 owner 同名多条）按旧行号顺序与清单行号顺序一一对齐，
    # 否则两条台账会同时吸到最近的那一行（v259 实测 7 组）。
    grouped = collections.defaultdict(list)
    for idx, r in enumerate(led):
        name = r["name"]
        key = (r["file"], r["owner"], r["kind"], name)
        # v263：文件 / 类型改名后，旧台账行要按新键归组，否则整段被当成
        # 「源码已无此函数」丢掉，再以占位证据重新加入。
        key = (_PATH_ALIASES.get(key[0], key[0]), key[1], key[2],
               _NAME_ALIASES[0][1] if False else key[3])
        key = (key[0], key[1], key[2],
               key[3].replace("ScreenshotShelfController", "ImageCurtainController").replace("Shelf", "Curtain"))
        if (r["file"], r["owner"], name) in RENAMES:
            name = RENAMES[(r["file"], r["owner"], name)]
            key = (r["file"], r["owner"], r["kind"], name)
        grouped[key].append((int(r["line"]), idx))

    out = []
    renamed = reanchored = dropped = 0
    for key, items in grouped.items():
        items.sort()
        cand = by_name.get(key, [])
        if not cand:
            dropped += len(items)
            print("  -- 源码已无此函数，台账移除:", key[0], key[3])
            continue
        for slot, (old_line, idx) in enumerate(items):
            r = dict(led[idx])
            name = r["name"]
            if (r["file"], r["owner"], name) in RENAMES:
                name = RENAMES[(r["file"], r["owner"], name)]
                renamed += 1
            if slot < len(cand):
                new_line = cand[slot]
            else:                       # 台账条数多于清单（重载被删）→ 就近
                new_line = min(cand, key=lambda x: abs(x - old_line))
            if new_line != old_line:
                reanchored += 1
            r["name"] = name.replace("ScreenshotShelfController", "ImageCurtainController").replace("Shelf", "Curtain")
            r["file"] = _PATH_ALIASES.get(r["file"], r["file"])
            r["line"] = str(new_line)
            out.append(r)

    covered = {(r["file"], r["owner"], r["kind"], r["name"], int(r["line"])) for r in out}
    added = 0
    no_evidence = []
    for r in inv:
        if r["kind"] not in FUNC_KINDS:
            continue
        key = (r["file"], r["owner"], r["kind"], r["name"], int(r["line"]))
        if key in covered:
            continue
        ev = EVIDENCE.get((r["file"], r["name"]))
        if not ev:
            ev = "待补证据：新增函数，尚未逐个读源码填写"
            no_evidence.append((r["file"], r["owner"], r["name"]))
        out.append({"module": r["module"], "file": r["file"], "owner": r["owner"],
                    "name": r["name"], "kind": r["kind"], "line": r["line"],
                    "status": "KEEP", "evidence": ev})
        added += 1

    out.sort(key=lambda r: (r["file"], int(r["line"])))
    # 回填：上一次用占位文案落盘的条目，若现在 EVIDENCE 已补上，直接改写。
    # （否则补完证据重跑脚本也修不好那条，只能手工动 CSV。）
    backfilled = 0
    for r in out:
        if r["evidence"].startswith("待补证据"):
            ev = EVIDENCE.get((r["file"], r["name"]))
            if ev:
                r["evidence"] = ev
                backfilled += 1

    with open(LED, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=["module", "file", "owner", "name",
                                           "kind", "line", "status", "evidence"])
        w.writeheader()
        w.writerows(out)

    funcs = sum(1 for r in inv if r["kind"] in FUNC_KINDS)
    print(f"台账 {len(led)} → {len(out)}；函数 {funcs}；重命名 {renamed}；"
          f"行号重锚 {reanchored}；新增 {added}；移除 {dropped}；回填证据 {backfilled}")

    if no_evidence:
        print(f"\n✗ 有 {len(no_evidence)} 条新增函数缺证据（请补 EVIDENCE）：")
        for f, o, n in no_evidence:
            print(f"  {f}  {o}.{n}")
        if strict:
            return 1
        print("  （非 --strict 模式：已写占位文案）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
