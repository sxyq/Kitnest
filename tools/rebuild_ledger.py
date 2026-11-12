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
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "previewItem"):
        "v260 预览缩略窗统一外壳：内容 + 左下角黑色胶囊标注「生效对象」，把主面板与独立窗口两类设置分开看",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "reloadWallpaper"):
        "v260 壁纸按 backgroundImagePath 重载（替换原来一次性 if-nil 缓存）；路径为空回退系统桌面图、再回退渐变，由 onChange 触发",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "trafficLight"):
        "预览缩略窗里的 7pt 装饰红绿灯（纯示意，不碰真实窗口按钮）；v260 从旧预览族迁到 AppearancePreviewBlock",
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
    ("Features/Capture/Curtain/CurtainController.swift", "railScale"):
        "帘线缩放：卡片宽/140 夹 0.8…3；关掉「帘线缩放」恒 1",
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
        "常驻微摆用 CABasicAnimation 改 transform（不重绘、render server）；已在摆则不重挂",
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
        "复制：同时给 PNG 数据与文件 URL（粘聊天窗是图、粘 Finder 是文件）",
    ("Features/Capture/Curtain/CurtainWindow.swift", "beginDrag"):
        "拖出：NSDraggingItem 用文件 URL，拖到 Finder/聊天窗即得文件",
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
        "在 Finder 中选中原暂存文件",
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
        "统一排版：总宽居中、逐张定位、设 ropeTilt/swayPhase、按需播落入动画",
    ("Features/Capture/Curtain/CurtainWindow.swift", "animateDrop"):
        "落入：位移 + 淡入 + 绕顶部衰减回弹，结束后接常驻微摆；只对新增卡片播",
    ("Features/Capture/Curtain/CurtainWindow.swift", "topPivot"):
        "把 CA 旋转中心从图层中心挪到顶部中心",

    # Pin appearance / action bar
    ("Features/Capture/Pin/PinWindow.swift", "init"):
        "PinAppearance 值类型初始化（单张钉图的外观快照）",
    ("Features/Capture/Pin/PinWindow.swift", "preset"):
        "动作条四形态：经典/无边框/卡片/强调，数值与设置页预设一致，只影响这一张",
    ("Features/Capture/Screenshot/CaptureActionChain.swift", "pin"):
        "按形态钉住：PinAppearance.preset → show(appearance:) + Toast",
    ("Features/Capture/Screenshot/CaptureSettingsPane.swift", "row"):
        "截图设置页统一行（标题 + 控件 + 说明），与钉图/图帘页同构",

    # Settings / status bar
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "init"):
        "从 CurtainPref 读初值（开关/样式/时长/张数/宽度/帘线缩放/自动上架）",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "row"):
        "图帘设置页统一行（74pt 标题列 + 控件 + 说明）",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "point"):
        "设置页预览绳线按三次贝塞尔取点，与窗口绘制同参数",
    ("Features/Settings/Panes/CurtainSettingsPane.swift", "path"):
        "设置页预览绳线路径：三次贝塞尔控制点在 1/3、2/3",
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
        "多针候选（连字符拼接 → 末词）→ BMH 扫池 → 字节级 AND 过滤 → 短路径优先排序",
    ("Features/Toolbox/Search/FileNameIndex.swift", "needles"):
        "多词先试 image-html-deck 这种拼接写法，拼不上退回最后一个词（最具体）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "terms"):
        "查询按空白分词并做 ASCII 小写折叠",
    ("Features/Toolbox/Search/FileNameIndex.swift", "asciiLower"):
        "只折叠 ASCII 大小写，保证折叠前后字节数一致（池内偏移才能不变）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "bmh"):
        "大小写不敏感的 Boyer-Moore-Horspool；165MB 池单次扫描约 75ms",
    ("Features/Toolbox/Search/FileNameIndex.swift", "regionContains"):
        "命中点所在路径内的字节级子串检查，替代 String.lowercased()（省 100ms+）",
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
        "将文件 URL 写入系统剪贴板并统一记录复制成功状态",
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
        "从当前用户主目录所在文件系统读取可用空间，供打开、重扫和清理后更新",
    ("Features/Monitor/Storage/StorageTreemap.swift", "scale"):
        "PolygonHitShape.animatableData 传入 SwiftUI 动画的顶点向量按弹性插值比例缩放",
    ("Features/Monitor/Storage/StorageTreemap.swift", "func"):
        "PolygonAnimatableVector 的 + / - 实现 VectorArithmetic，逐顶点合成与相减动画向量",
    ("Features/Monitor/Storage/StorageTreemap.swift", "path"):
        "StorageManagerRootView.rightPane 以 StorageMapShape 裁剪整栏，左缘曲线从左下连续接到上缘内收点",
    ("Features/Monitor/Storage/StorageTreemap.swift", "liquidPoints"):
        "tileView 将 hoverPoint 周边的高斯压力施加到 Voronoi 顶点，减少动态效果时返回原多边形",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "makeNSView"):
        "在设置预览中挂载 AppKit 原生关闭、最小化和缩放按钮",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "updateNSView"):
        "保留设置预览的原生窗口按钮视图，不重复创建装饰控件",
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
        "按当前选择复制文件名或可用路径，并提示不可用文件数量",
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
