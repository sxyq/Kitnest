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
CSV = os.path.join(ROOT, "docs", "00-总览", "数据表", "FrsetNext-函数清单.csv")
LED = os.path.join(ROOT, "docs", "00-总览", "数据表", "函数审阅台账.csv")
FUNC_KINDS = ("func", "init", "deinit", "subscript")

# 已重命名：台账旧名 → 现名
RENAMES = {
    ("Features/StatusBar/StatusBarMenuBuilder.swift", "StatusBarMenuBuilder", "customIconSubmenu"): "customIconItem",
    ("Features/AI/Views/AICredentialJournal.swift", "AICredentialJournalStore", "loadAll"): "decodeLines",
    ("Features/TransferDock/UI/TransferDockLoginView.swift", "Coordinator", "checkCookies"): "check",
}

# 新增函数的证据（逐个读过源码后写；键 = (file, name)）
EVIDENCE = {
    ("Features/TransferDock/UI/TransferDockView.swift", "removeStagingIfEmpty"):
        "2026-11-26 二轮 low：手机拉取的暂存目录清理抽成独立函数——只搬空（忽略 .DS_Store）才 removeItem，"
        "有残留就保留并记 warn，避免删除未搬走的用户文件；调用点在 pullFromPhone 收尾。",
    ("Models/SearchEngine.swift", "encodeQuery"):
        "2026-11-26 二轮 medium：搜索关键词编码的公共入口，按 RFC 3986 unreserved 编码（等价 encodeURIComponent），"
        "供模板 searchURL 与网页结果抓取共用；此前两条路径各自用 .urlQueryAllowed，& = + 不转义会拼出额外参数。",
    ("App/AppBootstrap.swift", "frontmostForSelection"):
        "2026-11-24 性能第二轮 A2：纯本地 NSWorkspace 查询（不触发 AX IPC），岛展开时固定触发时前台应用上下文供后台选区读取；前台是 Kitnest 自身时返回 nil 沿用原语义；命令面板/划词路径不改",
    ("Features/Island/IslandController.swift", "beginSelectionRefresh"):
        "2026-11-24 性能第二轮 A2：岛展开选区读取改后台执行——先捕获前台上下文，DispatchQueue.global 读 AX（0.25s IPC 超时），回主线程按 selectionGeneration 代次丢弃过期结果；外壳展开不再阻塞在三次同步 AX IPC 上",
    ("Features/Island/IslandController.swift", "logExpandPhases"):
        "2026-11-24 性能第二轮 A1：expand() 单调时钟分步计时（开页/选区发起/剪贴板/状态/定位/上屏/入口/焦点）一行汇总，替代原笼统的「首次布局」单值日志；只记机器耗时不代表真实呈现",
    ("Core/Motion/GenieWarp.swift", "footprintMB"):
        "2026-11-23：神灯 play() 阶段计时的内存读数——task_info 取 phys_footprint 换算 MB，只读无副作用，记录帧序列构建前后占用；与 LogArchive.STATUS 的 footprint 各自短小独立",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "init"):
        "2026-11-21：工作流设置草稿只读取一次配置，当前值与已保存值共用同一组UUID，首次示例不会因两次随机身份生成而被标成未保存",
    ("Features/Clipboard/Store/ClipboardManager.swift", "readAndIngest"):
        "2026-11-21：由poll调用；粘贴板读取失败时仅初次调用安排强制poll补读，可替换已有普通计数Timer且不续排补读，成功后的忽略规则和入库沿原实现",
    ("Features/Clipboard/UI/ClipboardTableHostView.swift", "deinit"):
        "2026-11-20：Coordinator释放时移除bind持有的回顶block observer，结束宿主重建后的旧通知注册；滚动代理仍只弱持有视图",
    ("Features/Monitor/Storage/DiskIndex.swift", "removing"):
        "2026-11-20：trash更新内存与两个范围缓存共用；按路径分隔判断交集，无交集沿用，根被移走或折叠导致目标节点缺失时失效该范围，其余仅裁剪已删除路径并重算总量与分类",
    ("Core/Runtime/AppUpdateChecker.swift", "prepareToTerminate"):
        "2026-11-20：AppDelegate完成原归档退出确认后调用；无待更新时返回原结果，取消清本次目录，允许才启动等待原PID退出的替换程序；启动失败取消退出并提示",
    ("Features/Island/IslandController.swift", "rememberPage"):
        "2026-11-20：主线草稿页面变化与selectPage共用；正式记忆模式且当前屏幕页面发生变化时写入lastPageByDisplay，持久化成功再发布配置，失败显示原提示",
    ("Features/Island/IslandController.swift", "selectDeepLinkPage"):
        "2026-11-21：kitnest://island?page=...使用；任务页沿原selectPage策略更新，功能详情页仅切换当前显示页，不覆盖固定或记忆页配置",
    ("Features/Island/IslandController.swift", "openIsland"):
        "2026-11-21：公开open()与open(page:)共用；未指定目标时应用固定/记忆展开策略，深链指定目标时保留该页并展开，不再被默认页策略覆盖",
    ("Features/Island/IslandDisplay.swift", "entrySize"):
        "2026-11-20：主线草稿入口尺寸属性与entryFrame共用；真实刘海读左右安全区间距和顶部安全高度，普通屏沿配置宽度及28pt高度",
    ("Features/Island/IslandDisplay.swift", "entryFrame"):
        "2026-11-20：主线草稿入口刷新与鼠标命中共用；真实刘海按安全区居中，普通屏按左中右位置及配置宽度定位，沿逻辑点和frame负坐标计算",
    ("Features/Island/IslandContent.swift", "applyTagChange"):
        "2026-11-20：IslandRootView接收TagStore增量通知；映射整体替换或缺少变更信息时重新查询，单标签删除清除对应筛选，仅更新受影响已加载行的tagIDs",
    ("Features/Archive/UI/ArchiveHTMLPreview.swift", "openExternalLink"):
        "2026-11-20：归档网页两种导航回调共用，仅主文档由用户点击的HTTP、HTTPS或mailto链接交系统打开；自动重定向不唤起外部应用",
    ("Features/CodePreview/CodePreviewView.swift", "updateText"):
        "2026-11-20：两个NSTextView宿主装入或更换正文时调用，记录UTF-16行首、更新宽度及请求一次重绘；滚动只读取偏移表",
    ("Features/TransferDock/Cast/TransferCastEngines.swift", "prepareLaunch"):
        "2026-11-20：镜像和独立应用窗口在后台调用；同一串行队列准备改名文件和剪贴板参数，能力缓存只在该队列访问",
    ("Features/TransferDock/Cast/TransferCastEngines.swift", "runMirror"):
        "2026-11-20：startMirror准备完毕回主线程调用；沿原启动、控制条挂载和保持设备唤醒顺序，stderr后台保留末6行，退出按当前PID卸载",
    ("Features/TransferDock/Transfer/TransferDockService.swift", "isLoginDomain"):
        "2026-11-20：登录页候选cookie与saveCookies写入共用；域名转小写，仅接受heytap.com/oppo.com本身及点分子域，保留前导点的域Cookie，拒绝同字尾的其他根域",
    ("Features/TransferDock/Android/ADBExtrasEngine.swift", "runSync"):
        "2026-11-20：异步run及后台目录枚举、图标助手和通知读取共用唯一执行体；自动解析或保留显式设备；并发消费两条pipe且等待汇合，完成取消原超时任务并返回输出及退出状态；只由后台调用",
    ("Features/TransferDock/Cast/DeviceAppCatalog.swift", "scores"):
        "2026-11-20：load每轮排序前调用一次；一次读取使用记录和当前时间，按次数乘14天半衰期计算各应用分数；排序比较只查本轮字典，缺记录仍为0",
    ("Features/TransferDock/Transfer/MCPServer.swift", "close"):
        "2026-11-19：MCP网络失败、取消、接收EOF与响应发送完成共用；在服务串行队列移除登记连接、解绑状态回调并取消会话，stop清空同一连接集合",
    ("Features/TransferDock/Android/AndroidWebDAVServer.swift", "close"):
        "2026-11-19：WebDAV网络失败、取消、头或正文提前结束及响应完成共用；在原服务队列移除连接并解绑取消，关闭服务后迟到响应不再发送",
    ("Features/TransferDock/Android/AndroidWebDAVServer.swift", "escapeXML"):
        "2026-11-19：entryXML中的href和displayname共用；依次转义与号及左右尖括号，使文件名作为XML文本而非标签解释",
    ("App/FrsetNextApp.swift", "updateDockPresence"):
        "2026-11-18：AppDelegate注册窗口激活、最小化、恢复与关闭通知；存在可见或最小化的独立标题窗口时切换regular显示Dock图标，最后窗口关闭切回accessory，关闭通知排除正在关闭的窗口",
    ("Features/Archive/Table/ArchiveEntryTable.swift", "update"):
        "2026-11-18：归档表格viewFor复用行和行初始化共用；更新图标锁路径标记名称大小与压缩率，保留既有控件和约束",
    ("Features/Archive/Table/ArchiveHoverPreview.swift", "windowClosed"):
        "2026-11-18：归档浏览控制器关窗后调用；仅取消本归档待显示预览，全部归档窗口关闭才清共享缓存；切换表格和网格不清他窗缓存",
    ("Features/Archive/Core/ArchiveCore.swift", "extractionDirectory"):
        "2026-11-17：extractEntryToTemp返回的嵌套文件路径，按临时根组件数定位本次唯一的首层提取目录；缩略图、悬停缓存与撤销快照共用精确删除单位",
    ("Features/Archive/Core/ArchiveUndoStack.swift", "deinit"):
        "2026-11-17：Snapshot仅由删除前提取和添加后复制两处构造，持有独立临时根目录；撤销重做及异步回调共享同一引用，最后引用释放才删目录，失败沿原Log提示",
    ("Features/Archive/UI/ArchiveTextPreview.swift", "header"):
        "2026-11-17：body传入本轮唯一分类结果，图标和名称不重复触发内容识别；dirty与编辑按钮沿原Binding和闭包消费",
    ("Features/Archive/UI/ArchiveTextPreview.swift", "rendered"):
        "2026-11-17：body传入同轮分类结果，复用原Markdown/JSON/代码/文本组件；正文仍来自draft，不再保留未读取text入参",
    ("Features/Panel/Inspector/JSONInspectorView.swift", "makeColumns"):
        "2026-11-17：JSONTableView.body每轮调用一次；沿原表型和前500条字段集合生成列序与宽度，同一列结果传给行构造筛选排序表头和单元格",
    ("Features/Panel/Inspector/JSONInspectorView.swift", "makeAllRows"):
        "JSONTableView.body调用；按文档对象与列键复用已构造的最多50000行，离开表格视图时由JSONTableState释放；原筛选排序及分页仍消费同一行数据",
    ("Features/Panel/Inspector/JSONInspectorView.swift", "rows"):
        "JSONTableView.body调用；同一JSONDocument与列键直接返回已构造行，文档或列键变化时重建，缓存不发布界面状态",
    ("Features/Panel/Inspector/JSONInspectorView.swift", "discardRows"):
        "JSONInspectorView切离表格模式调用；释放缓存行、文档引用和列键，不触发表格或其他视图更新",
    ("Features/Archive/UI/ArchiveTextPreview.swift", "loadCode"):
        "ArchiveCodePreviewBody.task调用；在后台按当前代码草稿生成原语法着色与行号排版，草稿变化时丢弃旧结果并复用原PreviewTextViewRepresentable",
    ("Features/Capture/Pin/PinWindow.swift", "flattened"):
        "flattenedImage及copyClicked共用；以图像和旋转翻转快照生成最终像素图，复制路径可在后台执行，不读取窗口状态",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "copyToPasteboard"):
        "钉图复制以预编码PNG调用；在主线程清板、写入PNG和NSImage并发送原教程事件，其他截图调用由单参数入口沿用原有编码流程",
    ("Features/Capture/History/CaptureHistoryView.swift", "loadThumbnail"):
        "CaptureHistoryThumbnail.task调用；后台ImageIO读取并生成最长边240像素图像，任务完成且未取消时在原单元格状态中显示，缺图沿占位图呈现",
    ("Features/Capture/Pin/PinWindow.swift", "flattened"):
        "flattenedImage和复制任务共用；只读传入图像与旋转翻转快照，生成最终像素图，复制任务可在后台执行",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "copyToPasteboard"):
        "单参数入口先编码原图再复用剪贴板写入；预编码重载使用调用方PNG，两个入口都保留NSImage representation、失败提示和教程通知",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "loadThumbnail"):
        "CaptureSectionView最近截图单元格task调用；先读取共享NSCache，未命中时后台ImageIO生成最长边限制缩略图，在主Actor创建NSImage并写入现有有界缓存",
    ("Features/Toolbox/Tools/MediaTools.swift", "compress"):
        "BuiltinTools注册的async执行闭包调用；由ToolRegistry.run与ToolDescriptor.execute沿非MainActor async链执行，压缩流程无需再移出主线程",
    ("Features/Panel/Inspector/JSONInspectorView.swift", "makeRowValues"):
        "2026-11-17：JSONTableView.body每轮调用一次；只消费传入行与列完成原搜索多列筛选和排序；行数页数及500行分页共用此结果",
    ("Features/Panel/Inspector/JSONInspectorView.swift", "header"):
        "2026-11-17：JSONTableView.body把本轮列与未筛选行传入表头；排序与筛选仍写同一JSONTableState；弹层沿参数取得选项而不重建整表",
    ("Features/Island/IslandController.swift", "hitTest"):
        "菜单栏搜索短条的图标和文字共用入口点击区域，事件交回同一控制器迁移原工作台",
    ("Features/Island/IslandController.swift", "accessibilityPerformPress"):
        "菜单栏轻量入口通过辅助功能按下动作调用同一activate回调",
    ("Features/Island/IslandWidgetGrid.swift", "adjustSize"):
        "编辑态方向键和辅助功能共用尺寸调整；候选来自实际可见画布，正常态不挂载此入口",
    ("Features/Monitor/Views/MonitorCharts.swift", "makeNSView"):
        "共用趋势图创建原生输入视图，图形仍由原Canvas绘制",
    ("Features/Monitor/Views/MonitorCharts.swift", "updateNSView"):
        "更新趋势图输入回调，不重新创建原生输入视图",
    ("Features/Monitor/Views/MonitorCharts.swift", "viewDidMoveToWindow"):
        "趋势图输入视图挂载后启用窗口鼠标移动事件",
    ("Features/Monitor/Views/MonitorCharts.swift", "updateTrackingAreas"):
        "按当前可见区域更新图表悬停跟踪区域",
    ("Features/Monitor/Views/MonitorCharts.swift", "mouseEntered"):
        "进入趋势图时沿同一鼠标移动入口定位读数",
    ("Features/Monitor/Views/MonitorCharts.swift", "mouseMoved"):
        "把图表内横坐标交给现有采样读数定位回调",
    ("Features/Monitor/Views/MonitorCharts.swift", "mouseExited"):
        "离开趋势图时发送退出事件，清除临时读数",
    ("Features/Monitor/Views/MonitorCharts.swift", "mouseDown"):
        "记录趋势图按下起点并取得键盘焦点，区分后续点击和拖动",
    ("Features/Monitor/Views/MonitorCharts.swift", "mouseDragged"):
        "位移达到3pt后发送图表拖动定位，保留原固定读数交互",
    ("Features/Monitor/Views/MonitorCharts.swift", "mouseUp"):
        "图表释放时按实际拖动状态发送结束或点击定位事件",
    ("Features/Monitor/Views/MonitorCharts.swift", "becomeFirstResponder"):
        "趋势图取得键盘焦点时更新可见焦点状态",
    ("Features/Monitor/Views/MonitorCharts.swift", "resignFirstResponder"):
        "趋势图失去键盘焦点时清除焦点状态",
    ("Features/Monitor/Views/MonitorCharts.swift", "keyDown"):
        "趋势图左右键逐点定位，回车切换固定，其他键沿用系统处理",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "setPowerMetric"):
        "同一功耗草稿按固定指标顺序更新整机CPU和GPU选择；首次调整保留旧三模块的有效形态，预览与保存共用正式配置读取",
    ("Features/Island/IslandController.swift", "bindRecordScroll"):
        "记录列表原生滚动窗绑定后恢复实际偏移；滚动通知只保存控制器值，不发布整页或另建滚动服务",
    ("Features/Island/IslandController.swift", "releaseRecordScroll"):
        "切页、收回结束和窗口停止时移除记录滚动通知，保留偏移供同一列表返回恢复",
    ("Features/Island/IslandContent.swift", "viewDidMoveToWindow"):
        "记录首行挂载时取得现有外层NSScrollView并交给控制器恢复位置，所有行仍复用原拖出视图",
    ("Features/Island/IslandContent.swift", "sampleDetail"):
        "刘海设置预览将固定样本交给正式正文组件，固定会话保留调参滚动；图片和多路径文件不读取真实文件",
    ("Features/Island/IslandContent.swift", "movePreviewDate"):
        "模拟日历的日期与月份导航只更新控制器选中日期，复用同一五档布局且不调用 EventKit",
    ("Features/Island/IslandContent.swift", "copySelectedDate"):
        "日历各尺寸共用所选日期复制；模拟只反馈，正式经 ClipboardManager 写入并反馈实际结果",
    ("Features/Island/IslandContent.swift", "calendarLayout"):
        "正式和模拟日历共用五档内容布局及全页月历，数据和操作闭包分别从缓存服务与固定样本注入",
    ("Features/Island/IslandContent.swift", "monthGrid"):
        "月历全页与2×2卡片共用42格与周标题，周末、跨月和选中态按实际日期及周起始日显示",
    ("Features/Island/IslandContent.swift", "eventRows"):
        "日程摘要、纵向事件和完整详情共用时间标题排版，区分空日程、授权提示与真实缓存事件",
    ("Features/Island/IslandContent.swift", "monthTitle"):
        "日历完整页与月历卡片共用中文年月标题，沿用 Foundation 日期格式样式",
    ("Features/Island/IslandContent.swift", "monthDay"):
        "日历紧凑、摘要及横向卡片共用中文月日文本，不改变所选日期",
    ("Features/Island/IslandContent.swift", "weekdayTitle"):
        "日历卡片按所选日期显示中文实际星期，和周末判定使用同一日期",
    ("Features/Island/IslandContent.swift", "fullDate"):
        "日历纵向卡片、月历底栏和全页共用完整中文日期标签",
    ("Features/Island/IslandContent.swift", "eventTime"):
        "日历横向带与事件行共用全天或开始时刻标签，保留正式事件字段",
    ("Features/Island/IslandContent.swift", "selectDate"):
        "正式日历选中跨月时读取月缓存，同月只从已加载42格选取事件，避免逐日重复查询",
    ("Features/Island/IslandContent.swift", "moveDate"):
        "正式日历前后日期与月份导航更新同一选中日期并沿用原事件缓存",
    ("Features/Island/IslandController.swift", "setComponentPageCount"):
        "画布排列完成后同步唯一首页组件页数，尺寸或显隐调整时将当前页保持在已有页内",
    ("Features/Island/IslandController.swift", "goBack"):
        "刘海详情返回原四入口，组件页与各页选择保留在同一控制器",
    ("Features/Island/IslandController.swift", "resumeAfterOutside"):
        "外部文件选择结束或取消后复用正式打开方法，恢复原页和已保存的工具输入",
    ("Features/Island/IslandController.swift", "updateNotchMetrics"):
        "读取当前屏幕两侧辅助区域与安全高度作为硬件刘海尺寸；无刘海屏幕使用紧凑顶部入口",
    ("Features/Island/IslandFeatureContent.swift", "submit"):
        "AI设置预览发送固定场景消息与反馈，不初始化真实会话服务或请求网络",
    ("Features/Island/IslandSettings.swift", "requestedSize"):
        "读取用户原五档尺寸，画布临时适配不覆盖原选择；默认仅监测与近期内容占两列",
    ("Features/Island/IslandSurface.swift", "updateVisibility"):
        "收起态媒体使用独立消费者复用系统播放器，展开或移除时释放读取任务，模拟不采集",
    ("Features/Island/IslandToolboxContent.swift", "shortcut"):
        "首页五档快捷目录只选择正式已启用工具并打开同一详情，小卡片保留主要入口",
    ("Features/Island/IslandWidgetGrid.swift", "frame"):
        "按共享画布单格及间隙计算异构卡片实际位置尺寸，排列、辉光和拖动落点使用同一几何",
    ("Features/Island/IslandController.swift", "beginLayoutEditing"):
        "以当前配置建立布局草稿并进入首页编辑，保持刘海展开；已保存配置在编辑过程中保持原样",
    ("Features/Island/IslandController.swift", "updateLayout"):
        "接收有效网格位置或尺寸变化，仅更新当前布局草稿，不调用持久化或启动业务模块",
    ("Features/Island/IslandController.swift", "finishLayoutEditing"):
        "从当前配置合并四项布局字段；保存失败保留草稿和原因，成功后通知设置预览并退出编辑",
    ("Features/Island/IslandController.swift", "cancelLayoutEditing"):
        "丢弃布局草稿、恢复正式配置展示，并结束编辑交互；收起窗口沿用此入口",
    ("Features/Island/IslandController.swift", "setWidgetVisible"):
        "通过现有 hiddenWidgets 在编辑草稿中移出或重新加入组件，不删除功能入口",
    ("Features/Island/IslandWidgetGrid.swift", "layout"):
        "先保留活动组件的候选位置，其他组件保留不冲突的旧位置；冲突项寻找就近空格并沿用分页",
    ("Features/Island/IslandWidgetGrid.swift", "fits"):
        "只接受画布内且未被占用的组件格子，避免拖动和缩放后组件相互覆盖",
    ("Features/Island/IslandWidgetGrid.swift", "rebuild"):
        "配置变化时缓存排列并收集实际受影响组件；连续指针位移由当前卡片的局部状态承担",
    ("Features/Island/IslandWidgetGrid.swift", "begin"):
        "记录手势前配置及所有可见位置，提供无效落点恢复依据，不写入正式配置",
    ("Features/Island/IslandWidgetGrid.swift", "change"):
        "将拖动位置映射到合法格子，连续缩放跨占用格即让位；候选位置、尺寸或占用变化才重新排列",
    ("Features/Island/IslandWidgetGrid.swift", "end"):
        "有效释放保存草稿内的坐标与视觉顺序，无效释放恢复手势前配置；编辑保持到完成或取消",
    ("Features/Island/IslandWidgetGrid.swift", "body"):
        "网格只在编辑态展示把手和移除入口并停用内部业务命中；子卡片局部状态驱动连续拖动和真实尺寸，其他卡片在有效排列变化时让位；正常态复用四页共享流光绘制",
    ("Features/Island/IslandWidgetGrid.swift", "distance"):
        "以行列归一化距离选择现有五档尺寸，并留 0.12 距离差避免边界附近反复切换",
    ("Features/Island/IslandWidgetGrid.swift", "settle"):
        "释放后接续当前卡片的实际位置与宽高，以 0.24 秒可中断弹性过渡吸附；减少动态效果下直接落定",
    ("Features/Island/IslandContent.swift", "hitTest"):
        "布局编辑时原生文件拖出视图退出命中，组件手势接管；普通使用继续原生文件拖出",
    ("Features/Island/IslandContent.swift", "cancelSelection"):
        "进入布局编辑取消原生记录行的延迟选择和待出现的悬停详情，保留真实剪贴板和文件",
    ("Features/Island/IslandGlow.swift", "reduce"):
        "合并当前刘海页面卡片与按钮的边界锚点，单个 Canvas 消费几何；滚动范围附带裁切锚点",
    ("Features/Island/IslandGlow.swift", "body"):
        "卡片修饰器只登记边界；场景修饰器给四页提供同一开关与指针，并只让绘制层订阅鼠标位置",
    ("Features/Island/IslandGlow.swift", "islandGlowScene"):
        "刘海外壳挂载唯一流光场景，覆盖总览、记录、监测、全部功能及其详情；收起或关闭流光时停止位置更新",
    ("Features/Island/IslandGlow.swift", "islandGlowClip"):
        "滚动容器把可见边界附在内部目标锚点上，流光按交集裁切，隐藏记录不在标题和页脚上绘制",
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
    ("Features/Clipboard/Store/ClipboardRepository.swift", "updateNote"):
        "2026-11-17：Manager笔记切换唯一调用；仅绑定is_note及dedupeKey更新；四个附件通用更新参数无调用已删除",
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

# ── v292 性能轮：FuzzyMatcher ASCII 快路径（文件名索引 47 万候选的打分底噪）
EVIDENCE.update({
    ("Features/Toolbox/Search/FuzzyMatcher.swift", "asciiMatch"):
        "纯 ASCII 时按 UTF-8 字节做同一套子序列判定：1 字节=1 字符=1 字素簇，下标与评分"
        "与原 Array<Character> 版本逐项一致（22 万例随机对拍 0 不一致）；含非 ASCII 返回 notApplicable 走原实现",
    ("Features/Toolbox/Search/FuzzyMatcher.swift", "unicodeMatch"):
        "原 match 实现原样保留为慢路径（非 ASCII / 混合文本唯一入口），避免快路径改变中文、"
        "组合字素簇的评分与高亮下标",
})

# ── v292 实测轮：岛定位 A/B 探针（一次性，仅诊断）────────────────────────
EVIDENCE.update({
    ("Features/Island/IslandController.swift", "armFirstUpdateProbe"):
        "展开后挂一次性 NSWindow.didUpdate 观察者，记「距唤起 Xms 的首帧窗口更新」；"
        "口径明确写为非合成呈现，只用于比较 setFrame(display:) 两种模式有没有把首帧推后",
    ("Features/Island/IslandController.swift", "disarmFirstUpdateProbe"):
        "移除上述观察者：didUpdate 只取首次，收到即摘；再次展开前也先摘，避免旧锚点串到下一轮",
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
        "shared私有构造，搜索面板state订阅及计算属性会取得单例，初始化本身不扫描目录",
    ("Features/Toolbox/Search/FileNameIndex.swift", "preloadIfCached"):
        "面板出现时只 mmap 已有缓存，没有就保持「未建立」——不在这里触发建索引",
    ("Features/Toolbox/Search/FileNameIndex.swift", "rebuild"):
        "用户点「重建」：释放旧映射、删缓存文件、后台重扫",
    ("Features/Toolbox/Search/FileNameIndex.swift", "ensureReady"):
        "有缓存就 mmap，没有才后台建；只在用户真的搜文件时调用（零常驻）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "loadFromDisk"):
        "读取24字节头并确认magic及正count/length，未读版本字段；锁内替换mmap和长度，磁盘时间直接发布ready，池偏移使用headerSize常量",
    ("Features/Toolbox/Search/FileNameIndex.swift", "unmap"):
        "重建前释放旧映射（同时把 poolLength 归零，搜索会立刻返回空）",
    ("Features/Toolbox/Search/FileNameIndex.swift", "build"):
        "后台用预留24字节头的Data池扫描并原子写盘，删除整池out与Data转换副本；900MiB路径上限及每20000项发布保持，计时从扫描开始，主线程再映射",
    ("Features/Toolbox/Search/FileNameIndex.swift", "walk"):
        "POSIX递归用同一inout Data追加UTF8及NUL，目录留到递归层写；排除路径静态初始化一次，原长度与池上限保持",
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

# ── 使用手册：文章分类与预设演示 ───────────────────────────────
EVIDENCE.update({
    ("Features/Onboarding/WelcomeView.swift", "step"):
        "欢迎页quickStart调用三次，按序号、标题与说明绘制30秒上手卡片；不读取权限或启动所列功能",
    ("Features/Manual/ManualView.swift", "sidebar"):
        "2026-11-19：body只计算一次搜索命中与可见分类，并传给侧栏；分类展开、文章选择和快速入门沿用原绑定",
    ("Features/Manual/ManualView.swift", "detail"):
        "2026-11-19：body传入本轮无结果状态；有序操作步骤原位展示ManualDemoView，正文和可点击步骤只保留一份，选文时滚回顶部",
    ("Features/Capture/OCR/ScreenshotOCRWindow.swift", "setSourceImage"):
        "2026-11-19：show复用结果窗且截图变化时调用，更新现有SourceNSScrollView的原图，使左侧图片与重新识别输入一致",
    ("Features/Manual/ManualView.swift", "categorySymbol"):
        "2026-11-20：功能分类首页为八类文章选用对应SF Symbol；点击分类进入现有功能卡列表，不启动正式功能",
    ("Features/Manual/ManualView.swift", "categoryDescription"):
        "2026-11-20：分类首页用普通用户词语说明每类用途，配合真实文章数量显示，不把内部接口放入手册",
    ("Features/Manual/ManualDemoView.swift", "advance"):
        "2026-11-20：播放、阶段与逐步点击共用指定步骤索引，文章frame驱动示例画面，0.25秒过渡遵循减少动态效果",
    ("Features/Manual/ManualDemoView.swift", "preset"):
        "2026-11-20：用途、操作、结果跳转使用同一播放状态；手动选择立即停止每2.4秒切换的自动演示",
    ("Features/Manual/ManualDocument.swift", "parse"):
        "2026-11-20：逐篇解析标题、分类、图标、scene与每步frame JSON；解码错误交给load显示，应用网页共用86篇383帧来源",
    ("Features/Manual/ManualDocument.swift", "displayCategory"):
        "把文章文件编号映射成用户分类；截图与录屏归在同一类，导航不显示文件序号",
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
        "渲染一级目录；点击只展开/收起，展开时顺带展开当前页所在小节（没有则第一节），避免只看到小节名",
    ("Features/Settings/Shell/SettingsSidebarView.swift", "sectionHeader"):
        "渲染二级小节标题（缩进22、11.5pt）并切换展开；拆过小节的目录下页面行缩进38，形成三级层次",
    ("Features/Settings/Shell/SettingsNavigation.swift", "section"):
        "按页面反查所属二级小节；小节 ID 以一级目录名为前缀，跨目录唯一",
    ("Features/Settings/Shell/SettingsWindowController.swift", "expandAncestors"):
        "把选中页的一级目录与二级小节一起放进展开集合，深链/搜索落地时直接看到页面行",
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
        "实际进入新分支时以目录路径前缀生成逐层历史，点击祖先只移动深度游标并保留已知前进目标",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "header"):
        "按窗口宽度将统计说明放在弧线外的左上区域，保留右上方扫描、记录与设置操作",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "leftPane"):
        "正文画布内独立滚动全部真实清理记录，行宽使用同一局部异形轮廓，选择与清理操作由candidateControls承载",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "candidateControls"):
        "复用真实候选数量、全选、已选字节、Agent提示词及废纸篓入口，与右侧目录操作区按实际控件高度决定正文上界",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "candidateWidth"):
        "从同一存储图轮廓求记录所在高度的可用宽度，使行内容跟随弧线缩窄而不被曲边截断",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "navigateHistory"):
        "按访问历史游标向前或向后一步，供按钮、快捷键及双指手势共用",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "makeNSView"):
        "创建只负责图形区域双指导航的 AppKit 视图，将方向传回现有根视图",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "updateNSView"):
        "同步目录模式启用态与最新导航回调到同一手势视图，不重建事件监听器",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "init"):
        "手势视图初始化保存导航回调；窗口控制器与 coder 初始化沿用现有原生窗口约定",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "hitTest"):
        "手势背景视图不承接点击，让前景的目录块保持原有命中与点击行为",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "viewDidMoveToWindow"):
        "视图进入窗口后挂载滚动事件监听，离开原窗口时移除旧监听",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "installSwipeMonitor"):
        "以真实触控板手势起点锁定异形图区域，累计整次横纵位移；42pt后执行一次左退右进，结束取消及惯性不导航，左侧清单不截取",
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
    ("Features/Monitor/Storage/StorageTreemap.swift", "make"):
        "DiskLayoutStore 在后台调用 DiskVoronoiLayout.make；按节点数据、索引版本和完整曲面几何生成真实面积布局，超出 maxTiles=14 的尾部节点聚合，可用空间单列",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "displayPath"):
        "StorageCandidateRow 显示当前用户目录的短路径，唯一实现从根视图迁入候选行，悬停只更新当前行",
    ("Features/Monitor/Storage/StorageTreemap.swift", "func"):
        "PolygonAnimatableVector 的 + / - 实现 VectorArithmetic，逐顶点合成与相减动画向量",
    ("Features/Monitor/Storage/StorageTreemap.swift", "path"):
        "StorageMapShape / StorageTileShape 共用 StorageShapeCache 的曲面与裁切路径；缓存键含完整轮廓几何、目标矩形和裁切比例，容量 24；外轮廓与图块坐标映射保持原口径",
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "rightPane"):
        "v274：由 contentTop 把液面外轮廓抬到按钮下方、深色图块仍从搜索条下方开始；rightPane 承载 StorageTreemap 的下钻/返回/选中回调与详情浮层，尺寸取自 StorageBodyLayout.mapSize",
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
        "makeDraft共用完整外观复制入口，同步强调色、字号、密度、圆角、动画、悬停预览、材质、徽章、缩略图、通知、分隔线、Midnight、背景和玻璃参数共20项；设置页刷新草稿时也用它原地覆盖，保持实例身份",
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
        "从 shared 复制最新外观，preservingOwned=true 时再覆回当前模块 DraftField；写入用 copyValues 原地覆盖，不换 personalization 实例，避免控件抓住旧对象后点击无效",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "restoreDefaults"):
        "只把该 scope 的 DraftField 改为 makeDefaultDraft 值；面板恢复400pt及默认页序，悬浮窗恢复网格/中档/0.52分隔，动作条恢复pillBar，通用主题恢复system",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "reduce"):
        "保存外观预览与settingsPreviewViewport相交的可见值；消费方离屏把revealed与revealScale一起复位，开合任务只认openReplay，滚出视口不会留下半缩放状态",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "image"):
        "AppearancePreviewWallpaper 按当前桌面壁纸 URL 缓存图像，经 ImageIO 生成最大1024像素缩略图，供背景预览使用，不重复解码相同 URL",
    ("Features/Settings/Panes/PersonalizationSettingsPane.swift", "press"):
        "原生红黄绿按钮仅调用场景onPress触发重播；通用预览在viewport内按minWidth居中，超宽横向滚动；进页面与切换开合档位时先把面板按到0.90+透明，落地80ms后按当前档位时长easeOut展开，与WindowReveal一致，不随减弱动态效果降级",
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
        "2026-11-20：固定预览仅显示示例选择；正式调用后台startAppWindow，主线程回调成功才记录CastAppUsage，失败不增加使用次数",
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
        "启动、保留期变化或导入相应配置后替换已有retentionTimer；保留期0不设计时，正数时每3600秒调用pruneExpired并立即清理一次，计时加入主runloop common模式",
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
        "内容模型保留source、entry、sessionID及displayPath，仅文件条目拆路径并识别目录；单文件按支持类型加载完整文本或图片，kindOverride避免重复读取；MarkdownScrollState仅保存实际使用的scrollOffset",
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
    ("Features/Panel/Presentation/PanelController.swift", "cancelWarmup"):
        "预热期间窗口已orderFront但停在屏幕外：取消时作废token、复位presentation.visible、orderOut并把窗口移回预热前位置，让toggle按未打开处理（否则连点会判成收起或从屏外长出）",
    ("Features/Panel/Presentation/PanelController.swift", "prewarmAtLaunch"):
        "启动3秒后先prepare建面板再离屏预热：窗口停到屏幕上沿之外且alpha保持1，参与正常显示周期；probe.warmup=NO可关；预热用warmupToken与warmupOnScreen防止把用户刚打开的面板收走",
    ("Features/Panel/Presentation/PanelController.swift", "show"):
        "无锚点重载进入show(atAnchor:)；可见窗口重开保留现有origin、anchorRect及三角态，仅首次显示校准材质尺寸和排版；playIn实际完成后执行finishShow启用采样，同一腿反向不提前启动采样",
    ("Features/Panel/Presentation/PanelController.swift", "toggle"):
        "无锚点重载进入toggle(atAnchor:)；isHiding期间再次触发立即show使旧关闭回调失效，覆盖预览等待与神灯收起两阶段；其余按真实窗口可见性开合",
    ("Features/Clipboard/Store/ClipboardFileStorages.swift", "reencodedIfSmaller"):
        "大于1.5MB的剪贴板图片写盘前重编码：HEIC quality 0.90 优先（保留alpha），失败退JPEG；只有编码结果小于原始70%才替换，否则原样落盘；扩展名随之改为heic/jpg",
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
        "2026-11-21：Linear步骤提交issueCreate；HTTP、JSON和GraphQL错误交回run，只有data.issueCreate.success为true才继续后续步骤，否则沿原失败弹窗和单步重试处理",
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
    ("Features/Clipboard/Store/ClipboardBackup.swift", "cleanupFailure"):
        "2026-11-20：导出、读取和恢复失败出口复用明文目录清理，将原错误及清理失败的具体路径合并返回；恢复附件回滚失败时保留原附件目录",
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
        "用户确认清理后读取未标记已存且未收藏的全部条目，逐条回收附件并保留失败文案需要的标题",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "unsavedCount"):
        "清理历史确认框仅需条数，使用SQLite COUNT统计未标记已存且未收藏的条目，匹配确认后的删除范围",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "savedCount"):
        "clearUnsavedHistory确认文案用SELECT COUNT(*) WHERE is_note=1 OR is_favorite=1说明保留的已存或收藏项目数",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "execute"):
        "备份sheet按钮先置busy并清错误，按已有RestoreSession、导入或导出分派Manager正式入口；读取成功展示摘要并清密码",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "finish"):
        "导出/恢复完成复位busy及operation，成功清会话临时目录和密码、Toast后关闭sheet，失败显示localizedDescription",
})

EVIDENCE.update({
    ("Features/Island/IslandContent.swift", "body"):
        "IslandRecordFocusAppearance仅关闭macOS14及以上记录列表的系统焦点装饰，保留focusable、方向键和复制命令；macOS13沿用原生行focusRingType.none",
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


EVIDENCE.update({
    ("Features/Monitor/Views/MonitorCharts.swift", "init"): "监测趋势数据从原历史组装带时间、间隔和缺失值的序列；预先计算可见采样与量程，鼠标定位不再转换历史。",
    ("Features/Monitor/Views/MonitorCharts.swift", "format"): "按模块格式化百分比、系统内存压力等级、速率、摄氏度或瓦数，缺失读数显示破折号。",
    ("Features/Monitor/Views/MonitorCharts.swift", "drawSeries"): "按真实时间排列各曲线，遇到缺失值或超过采样间隔的空档分段绘制，同一时间共享定位线。",
    ("Features/Monitor/Views/MonitorCharts.swift", "drawRun"): "绘制连续采样段；内存压力采用等级阶梯，其余曲线的控制点限制在相邻读数之间，避免额外峰谷。",
    ("Features/Monitor/Views/MonitorCharts.swift", "xPosition"): "将真实采样时间映射到当前时间窗；历史未满时右对齐，不随采样数量拉伸。",
    ("Features/Monitor/Views/MonitorCharts.swift", "nearest"): "只在已计算的可见采样中查找最接近指针时间的位置，不触发系统读取。",
    ("Features/Monitor/Views/MonitorCharts.swift", "pin"): "固定完整采样时间和值，并保存到现有模块选择对象；新采样进入不会替换固定对象。",
    ("Features/Monitor/Views/MonitorCharts.swift", "unpin"): "清除本模块固定与临时查看读数，恢复最新采样。",
    ("Features/Monitor/Views/MonitorCharts.swift", "restoreSelection"): "按模块与传感器键恢复固定采样；切换数据对象时清除临时悬停位置并更新量程。",
    ("Features/Monitor/Views/MonitorCharts.swift", "timeText"): "以真实采样时间格式化图表刻度与查看读数时间。",
    ("Features/Monitor/Views/MonitorDetailView.swift", "moduleButton"): "整行切换统一模块，悬停不切换；分别绘制悬停、选中与键盘焦点，方向键定位相邻模块。",
    ("Features/Monitor/Views/MonitorDetailView.swift", "currentValue"): "模块列表读取正式当前采样，预览读取固定场景；无 GPU、电池或整机功耗时显示对应状态。",
})


EVIDENCE.update({
    ("Features/Monitor/Views/MonitorDetailView.swift", "ensureSelection"): "模块显隐改变后在仍可见的模块中保留当前选择；设置侧栏指定的单模块详情不改成另一模块。",
    ("Features/Monitor/Window/MonitorSettingsPane.swift", "saved"): "读取正式监测总开关、刷新间隔、模块显隐、温度、网络常驻和分流数量，作为设置草稿初值。",
    ("Features/Monitor/Window/MonitorSettingsPane.swift", "save"): "仅应用本页相对已保存值发生变化的字段；刷新间隔沿用菜单栏同步入口，未改字段保留其他页面的配置。",
    ("Features/Monitor/Window/MonitorSettingsPane.swift", "discard"): "重新读取已保存监测配置，取消只改变草稿和预览。",
    ("Features/Monitor/Window/MonitorSettingsPane.swift", "restoreDefaults"): "默认值先进入监测草稿，保存前不影响正式采样与模块显隐。",
    ("Features/Monitor/Window/MonitorSettingsPane.swift", "applyIntervalToBarWidgets"): "保存刷新间隔时复用各菜单栏模块 updateInterval 写入与重载，不在拖动滑块时写正式配置。",
})


EVIDENCE.update({
    ("Features/Clipboard/Store/ClipboardBackup.swift", "reviewExport"):
        "在Manager既有串行队列锁定剪贴板库读取快照，集中列出缺失附件记录；支持取消，结果回主线程供同一备份sheet显示",
    ("Features/Clipboard/Store/ClipboardBackup.swift", "missingRecords"):
        "按记录原图、缩略图、长正文及富文本相对路径读取真实存在状态，保留记录去重键、标题和缺失路径，导出清单与附件准备共用",
    ("Features/Clipboard/Store/ClipboardManager.swift", "reviewBackupExport"):
        "把备份缺失清单交给既有ClipboardBackup与Manager队列，返回同一取消操作对象，不增加数据库连接或执行链",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "reviewExport"):
        "备份sheet打开及导出失败后读取当前缺失清单，更新busy和错误；完整记录按钮按清单显示，缺失记录不从本机删除",
    ("Features/Monitor/Storage/DiskIndex.swift", "init"):
        "DiskNode与Snapshot保留成员初始化入口；按实际旧home缓存缺失的isAggregate、schema、分类等字段解码，目录树保留；Accumulator初始化空分类边界小计",
    ("Features/Monitor/Storage/DiskIndex.swift", "recomputeDataCategories"):
        "扫描完成、缓存载入及删除重算共用分类汇总；缺失折叠小计或总量不符时清除错误分类并显示具体重新扫描原因",
    ("Features/Monitor/Storage/DiskIndex.swift", "add"):
        "把真实直接字节累加到类别和分类边界路径，父目录只贡献未单列文件；零字节无需存储条目",
    ("Features/Monitor/Storage/DiskIndex.swift", "merge"):
        "扫描合并子目录累加器，折叠节点合并已有类别与来源字节小计；验证路径总量与类别总量一致，避免把折叠内部全归父类",
    ("Features/Monitor/Storage/DiskIndex.swift", "categories"):
        "从类别与边界路径字节生成五类汇总，逐路径按字节排序；复用independentPaths展示来源，保存精确路径字节而非折叠树副本",
})


EVIDENCE.update({
    ("App/AppBootstrap.swift", "supportsDoubleTap"): "仅既有全局动作显示双按模式，工具组合键不新增双按行为",
    ("App/AppBootstrap.swift", "defaultShortcutValue"): "从正式默认热键表生成单项默认，未配置按键的功能保留未绑定状态",
    ("App/AppBootstrap.swift", "shortcutSettingsValue"): "统一读取全局与工具已有绑定，取色归入colorpicker，双按沿用原修饰键存储",
    ("App/AppBootstrap.swift", "applyShortcuts"): "集中保存时注册实际变动动作，组合键批量替换成功后应用双按；冲突返回功能名称并保留原注册",
    ("Core/Runtime/Personalization.swift", "reloadFromDefaults"): "配置导入后从已有偏好重载全局外观并通知正式窗口，沿用同一单例",
    ("Features/AI/Views/AISettingsPane.swift", "save"): "AI服务草稿只提交变动地址模型与凭证，凭证失败返回服务商及原因并保留候选密钥",
    ("Features/AI/Views/AISettingsPane.swift", "discard"): "取消当前AI服务页时重读保存值并丢弃本页候选密钥，不应用其他页草稿",
    ("Features/AI/Views/AISettingsPane.swift", "restoreDefaults"): "AI服务默认只更新本页候选配置，不删除已保存凭证或立即请求服务",
    ("Features/AI/Views/AISettingsPane.swift", "configurationChanged"): "候选服务变化先取消并释放连接任务，再递增代次及清结果，URLSession沿原任务取消链结束",
    ("Features/AI/Views/AISettingsPane.swift", "deinit"): "设置会话end释放草稿时取消唯一连接任务；测试闭包弱持有草稿，不再把设置模型保留到网络完成",
    ("Features/Capture/Screenshot/CaptureSettingsPane.swift", "init"): "截图OCR水印三页复用既有截图预览模型，将其变化转发给窗口草稿会话",
    ("Features/Capture/Screenshot/CaptureSettingsPane.swift", "save"): "按截图OCR或水印所属字段差量提交，固定比例编码及偏好失败保留当前页调整",
    ("Features/Capture/Screenshot/CaptureSettingsPane.swift", "discard"): "取消当前截图子页重读正式值并清理未添加的比例草稿",
    ("Features/Capture/Screenshot/CaptureSettingsPane.swift", "restoreDefaults"): "当前截图子页默认仅在独立草稿模型生效，由所属页保存范围控制正式应用",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "save"): "截图工作流沿用现有文件存储，保存失败返回实际原因且不更新已保存快照",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "discard"): "取消工作流页重读原工作流文件，不执行截图步骤",
    ("Features/Capture/Workflow/WorkflowSettingsPane.swift", "restoreDefaults"): "工作流清空只更新草稿，保存后才改变自动执行列表",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "init"): "历史草稿读取保留期与容量作为保存快照，保留历史清理的正式执行入口",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "save"): "历史保留期容量与捕获隐私分别只写实际变动值，错误反馈保留对应草稿",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "discard"): "取消历史或捕获页只重读该页保存值，不清理数据库内容",
    ("Features/Clipboard/UI/ClipboardSettingsPane.swift", "restoreDefaults"): "历史与捕获默认先进入草稿，不立即清理历史或改变OCR",
    ("Features/Panel/Presentation/PanelSegments.swift", "migrateLegacyVisibility"): "把旧showSystemStatus与panel.transferDock有效展示状态合并入分段键，移除重复展示键",
    ("Features/Recording/RecordingSettingsPane.swift", "save"): "录屏页差量保存参数与目录；effects范围只写光标画中画及按键点击表现，失败保留草稿",
    ("Features/Recording/RecordingSettingsPane.swift", "discard"): "录屏页取消重读正式值，effects取消只还原表现字段并保留音频帧率目录草稿",
    ("Features/Recording/RecordingSettingsPane.swift", "restoreDefaults"): "录屏默认只进入草稿；effects默认排除帧率音频设备忽略应用及保存目录",
    ("Features/Recording/RecordingSettingsPane.swift", "isDirty"): "录屏effects范围只比较六项显示字段，其他参数变化不计入全部个性化默认",
    ("Features/Recording/RecordingSettingsPane.swift", "applyEffects"): "共用录屏显示字段提交，只写相对已保存值变化的光标摄像头位置比例按键和点击开关",
    ("Features/Recording/RecordingSettingsPane.swift", "copyEffects"): "在同一录屏草稿内复制六项显示字段，避免默认保存或取消覆盖采样和输出参数",
    ("Features/Recording/RecordingSettingsPane.swift", "refreshCameras"): "仅录屏页出现时枚举已有摄像头供配置选择，不启动录制",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "isDirty"): "按刘海四页所属字段判断草稿变动，画布页包含未完成的布局编辑",
    ("Features/Settings/Panes/IslandSettingsPane.swift", "merged"): "刘海四页复用字段集合与字典键差量合并，保留当前正式配置及其他页面草稿",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "owns"): "排列页只编辑排列键，部件页只编辑形态颜色且排除独立刷新间隔",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "refreshUnownedValues"): "返回部件页刷新其他页已保存的排列，不覆盖本页形态颜色草稿",
    ("Features/Settings/Panes/MonitorWidgetsPane.swift", "selectTarget"): "菜单部件配置深链按正式模块标识定位页内选择，不新增三级目录",
    ("Features/Settings/Panes/SearchSettingsPane.swift", "isDirty"): "搜索display范围只比较分类显隐与搜索后清空，不把引擎调整纳入全部个性化默认",
    ("Features/Settings/Panes/StatisticsSettingsPane.swift", "applyImportedPreferences"): "配置导入复用正式消费入口与热键注册，迁移旧显隐键，保留独立部件间隔并返回应用错误",
    ("Features/Settings/Panes/StatisticsSettingsPane.swift", "isMenuBarConfigurationKey"): "配置导出导入只接受正式排列及部件配置键，排除无关存储内容",
    ("Features/Settings/Panes/StatisticsSettingsPane.swift", "exportableMenuBarConfiguration"): "导出菜单部件有效配置含各独立间隔与默认值，不含运行采样或预览状态",
    ("Features/Settings/Shell/SettingsComponents.swift", "makeNSView"): "创建不接收命中的滚动位置附着视图，复用正文已有NSScrollView",
    ("Features/Settings/Shell/SettingsComponents.swift", "updateNSView"): "更新页面归属并附着已有滚动窗，不新增滚动容器",
    ("Features/Settings/Shell/SettingsComponents.swift", "dismantleNSView"): "设置正文移除时记住滚动偏移并释放通知",
    ("Features/Settings/Shell/SettingsComponents.swift", "hitTest"): "滚动记忆视图不接受指针事件，保留真实正文交互",
    ("Features/Settings/Shell/SettingsComponents.swift", "attach"): "附着正文已有滚动窗并恢复当前二级页偏移，明确控件定位时不抢滚动目标",
    ("Features/Settings/Shell/SettingsComponents.swift", "remember"): "仅记录正文偏移到设置窗口页状态，不发布每帧草稿变化",
    ("Features/Settings/Shell/SettingsComponents.swift", "detach"): "切页时记录旧页位置并释放对应通知",
    ("Features/Settings/Shell/SettingsComponents.swift", "deinit"): "释放滚动记忆通知，避免关闭设置后继续接收滚动",
    ("Features/Settings/Shell/SettingsPanes.swift", "appearanceSection"): "基础设置页共用正式外观预览与单页保存栏",
    ("Features/Settings/Shell/SettingsPanes.swift", "aboutContent"): "关于页把更新地址纳入草稿，查看更新等即时动作单独呈现",
    ("Features/Settings/Shell/SettingsWindowController.swift", "reveal"): "搜索模块链接及深链展开目标一级目录并定位二级页控件，与普通打开折叠行为分离",
    ("Features/Toolbox/Shortcuts/DoubleTapShortcut.swift", "replaceBindings"): "组合键批量保存成功后替换同一双按中心的绑定和顺序，保留原0.30秒手势",
    ("Features/Toolbox/Shortcuts/DoubleTapShortcut.swift", "cancelPreparedMonitoring"): "组合键注册失败时移除本次临时双按监听，保留已有有效双按监听",
    ("Features/Toolbox/Shortcuts/DoubleTapShortcut.swift", "prepareMonitoring"): "复用原flagsChanged监听并返回真实安装结果，失败释放本次已装监听",
    ("Features/Toolbox/Shortcuts/ShortcutManager.swift", "replaceBindings"): "准备整批新组合键并复用互换旧注册，全部成功后替换；冲突只撤销本批新注册并保留原有效键",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "init"): "快捷键草稿读取全局及工具现有有效值，页面展开状态独立于持久绑定",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "save"): "唯一快捷键页只提交实际调整的动作，注册失败保留调整和原保存值",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "discard"): "取消快捷键页重读原有效绑定，不重新注册",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "restoreDefaults"): "全部功能默认只更新快捷键草稿，保存后统一注册",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "restoreDefault"): "当前功能默认从正式热键表读取，保持其他行草稿",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "clear"): "当前功能设为未绑定只改变草稿，不立即注销热键",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "selectTrigger"): "页内切换既有触发方式，未绑定沿用同一清除入口",
    ("Features/Toolbox/Shortcuts/ShortcutSettingsPane.swift", "record"): "录入组合键只更新指定行候选值，保存前不注册",
    ("Features/Toolbox/Tools/ToolRegistry.swift", "init"): "既有工具描述支持原生自带界面挂载，音频混音器回到正式工具窗口，不留设置正文",
    ("Features/Toolbox/Tools/ToolSettingsPane.swift", "init"): "工具集合草稿读取当前启用表，不直接改变运行功能",
    ("Features/Toolbox/Tools/ToolSettingsPane.swift", "save"): "工具开关与AI动作分别差量保存，提示词编码或偏好失败保留草稿",
    ("Features/Toolbox/Tools/ToolSettingsPane.swift", "discard"): "工具集合或AI文本页取消只重读所属保存值，不覆盖快捷键",
    ("Features/Toolbox/Tools/ToolSettingsPane.swift", "restoreDefaults"): "工具集合与AI文本默认先进入所属草稿，模块默认不再重置快捷键",
    ("Features/Toolbox/Tools/ToolSettingsPane.swift", "shortcutDisplay"): "模块页只读显示有效绑定并跳到唯一快捷键功能行",
    ("Features/Toolbox/Tools/ToolSettingsPane.swift", "addCustomTool"): "把已填写名称与模板添加到AI文本工具草稿，保存后才进入正式工具存储",
    ("Features/Toolbox/Tools/ToolSettingsPane.swift", "clearNewTool"): "提示词加入草稿或取消时清空页内输入，不影响正式工具列表",
})

EVIDENCE.update({
    ("Core/Haptics/HapticFeedback.swift", "isEnabled"): "统一事件入口按独立场景开关取值，总强度由perform后续处理",
    ("Core/Haptics/HapticFeedback.swift", "load"): "从haptic.configuration读取独立Codable偏好，设置草稿与真实事件共用",
    ("Core/Haptics/HapticFeedback.swift", "persist"): "设置保存把强度与禁用事件集合编码到原UserDefaults，不影响刘海配置",
    ("Core/Haptics/HapticFeedback.swift", "perform"): "所有业务事件唯一触觉入口，读取场景偏好后交给公共系统反馈模式",
    ("Core/Haptics/HapticFeedback.swift", "preview"): "设置试听和正式事件共用系统调用，关闭不调用，其余每次仅请求一次离散反馈",
    ("Core/Haptics/TrackpadActuator.swift", "init"): "仅在内建触控板可驱动时打开私有马达并缓存句柄；失败保持 nil，由 emit 回落公开接口",
    ("Core/Haptics/TrackpadActuator.swift", "deinit"): "进程退出前关闭马达句柄，避免占用触控板设备",
    ("Core/Haptics/TrackpadActuator.swift", "actuate"): "业务事件与设置试听的唯一敲击点；直连失败时关掉重开再试一次，仍失败交公开接口",
    ("Core/Haptics/TrackpadActuator.swift", "ensureOpen"): "按需创建并打开马达；睡眠唤醒后句柄失效时由 actuate 关闭重开",
    ("Core/Haptics/TrackpadActuator.swift", "builtInTrackpadID"): "从 IORegistry 取内建且 ActuationSupported 的触控板 Multitouch ID，避开外接设备",
    ("Features/Settings/Shell/SettingsComponents.swift", "sizeThatFits"): "预览/控件/分隔三子视图；内容宽≥650 时返回两栏高度（预览350、控件270），不足时返回上下排总高",
    ("Features/Settings/Shell/SettingsComponents.swift", "placeSubviews"): "两栏把预览贴左、控件贴右、分隔居中；窄窗改上下排，控件限宽320，避免挤出卡片",
    ("Features/Island/IslandController.swift", "turnComponentPage"): "现有页面草稿将组件页码限制在0至componentPageCount减1；当前尚无调用方",
    ("Features/Island/IslandController.swift", "selectPage"): "turnPage和goBack复用可见页选择；记忆模式按显示器身份保存实际页面，保存错误交feedback",
    ("Features/Island/IslandController.swift", "applyOpeningPage"): "现有草稿按固定页或屏幕记忆挑选可见页，并以remember=false交selectPage；当前尚无调用方",
    ("Features/Island/IslandSettings.swift", "pageTitle"): "现有草稿仅对custom页返回自定义名称，其余返回原页面title；当前尚无调用方",
    ("Features/Clipboard/Store/ClipboardManager.swift", "toggleFavorite"):
        "现有草稿新增独立收藏写入：串行队列读取数据库现值取反，成功通知其他窗并更新可见行，保存失败提示；目前尚无界面调用方",
    ("Features/Clipboard/Store/ClipboardManager.swift", "setNote"):
        "现有草稿的笔记入口在串行队列写isNote；失败提示，成功通知其他窗并更新可见行，笔记筛选取消后重新读取列表",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "updateFavorite"):
        "新增草稿由toggleFavorite调用，按dedupe_key参数绑定写is_favorite，数据库错误记录日志并返回false",
    ("Features/Island/IslandController.swift", "refreshDisplays"): "显示参数或Space变化时更新目标及入口，只移动已有业务窗口，指定离线沿原选择临时主屏",
    ("Features/Island/IslandController.swift", "refreshEntries"): "每个启用逻辑显示目标仅持有绘制入口的NSPanel，当前屏沿用原舞台，不创建正文订阅或采样",
    ("Features/Island/IslandController.swift", "activateDisplay"): "点击屏幕入口明确迁移并保持展开，已有预览时保留其键盘焦点和会话",
    ("Features/Island/IslandController.swift", "move"): "迁移原面板及原预览窗口，保持hosting view和业务输入，绕开取消布局草稿的collapse",
    ("Features/Island/IslandController.swift", "entry"): "鼠标事件只在缓存逻辑屏幕入口矩形命中，不在每次移动重新读取UUID或创建视图",
    ("Features/Island/IslandController.swift", "containsEntry"): "预览点外处理识别刘海入口点击，跨屏迁移时不提前关闭预览",
    ("Features/Island/IslandController.swift", "init"): "正式单例与原设置预览构造配置和目标缓存；轻量入口view构造点击回调且不支持归档恢复",
    ("Features/Island/IslandController.swift", "mouseDown"): "轻量入口的本地点击转交唯一controller选择显示目标，不持有业务状态",
    ("Features/Island/IslandController.swift", "draw"): "其他屏幕仅绘制黑色入口和短标记，不挂载完整SwiftUI正文",
    ("Features/Island/IslandDisplay.swift", "init"): "由NSScreen读取显示ID并转换系统UUID，镜像屏统一采用源屏的稳定身份和几何",
    ("Features/Island/IslandDisplay.swift", "sourceID"): "用CGDisplayMirrorsDisplay归一镜像源，独立屏保留自身系统显示ID",
    ("Features/Island/IslandDisplay.swift", "enabled"): "按自动刘海优先、全部、主屏或指定UUID筛选；指定目标全离线临时主屏而不覆写偏好",
    ("Features/Island/IslandSettings.swift", "init"): "默认构造保留原全部字段；JSON逐字段decodeIfPresent新增屏幕范围不丢旧主题布局组件",
    ("Features/Panel/Preview/MainPanelPreviewPopoverCoordinator.swift", "movePreview"): "刘海跨屏时取消旧悬停关闭计时，移动同一预览窗口并限制在目标逻辑可见区域，保留内容模型",
    ("Features/Settings/Panes/HapticSettingsPane.swift", "init"): "独立触觉设置草稿读取正式配置为当前值和保存快照，复用原设置编辑会话",
    ("Features/Settings/Panes/HapticSettingsPane.swift", "save"): "编码成功后更新触觉保存快照，失败返回具体原因并保留草稿",
    ("Features/Settings/Panes/HapticSettingsPane.swift", "discard"): "取消仅将本页草稿恢复已保存强度和场景开关",
    ("Features/Settings/Panes/HapticSettingsPane.swift", "restoreDefaults"): "本页恢复默认只更新草稿，经既有保存按钮应用",
    ("Features/Settings/Panes/HapticSettingsPane.swift", "eventSection"): "按统一事件枚举生成场景名称说明和独立开关，三类场景复用相同行组件",
    ("Features/TransferDock/Cast/TransferCastEngines.swift", "sharingService"): "既有隔空投送服务的完成回调才反馈成功，真实失败反馈失败，用户取消跳过；不把发起分享当完成",
    ("Features/TransferDock/Cast/TransferCastEngines.swift", "deviceConnectionChanged"): "无线连接命令与已有设备扫描共用已知连接集合，实际连接或断开才反馈，后续相同扫描不重复",
})



# ── 2026-11-23 文档体系整理：源码大文件职责拆分（纯类型搬家，无行为变化）──
# 台账把搬家视为新 (file, name)，这里补真实迁入证据。
EVIDENCE.update({
    ('Features/Capture/Screenshot/NativeRegionCapture.swift', 'capture'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/NativeRegionCapture.swift', 'captureOnce'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/NativeRegionCapture.swift', 'captureScreen'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/NativeRegionCapture.swift', 'captureScreenOnDisplay'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/NativeRegionCapture.swift', 'run'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'averageDifference'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'beginEpoch'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'captureScreenAdaptive'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Annotation/MosaicTextOnly.swift', 'clearCache'):
        'AnnotationCanvasView.deinit 按 CGImage 身份调用；释放最近截图与文本框并清除同图在途标记，使已关闭画布的 Vision 结果不再写回全局缓存',
    ('Features/Capture/Annotation/AnnotationEditorWindow.swift', 'deinit'):
        '标注画布销毁时清理 MosaicTextOnly 最近图缓存；后台识别完成后不再保留已关闭画布的截图',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'captureScreenForScreenshot'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'cgCapture'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'cgRect'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'displayID'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'isCurrent'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'isCurrentEpoch'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'isUsableImage'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'legacyCapture'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'legacyCaptureProbed'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'load'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'next'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'pixelColor'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'probe'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'sameColor'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'sckCapture'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'sckCaptureSync'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'sckCaptureWindowSync'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'screencaptureDisplayIndex'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'store'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Capture/Screenshot/ScreenSnapshot.swift', 'windowImageMatchesFrozen'):
        '2026-11-23：随类型自 Features/Capture/Screenshot/ScreenshotManager.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'calendarLayout'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'copySelectedDate'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'eventRows'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'eventTime'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'fullDate'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'monthDay'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'monthGrid'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'monthTitle'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'moveDate'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'movePreviewDate'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'reload'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'reloadEvents'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'selectDate'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandCalendarContent.swift', 'weekdayTitle'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'cancelSelection'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'draggingSession'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'hitTest'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'keyDown'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'makeNSView'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'mouseDown'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'mouseDragged'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'mouseUp'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'updateNSView'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'viewDidMoveToWindow'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandFileDrag.swift', 'viewWillMove'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandRecordRows.swift', 'body'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Island/IslandRecordRows.swift', 'copy'):
        '2026-11-23：随类型自 Features/Island/IslandContent.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Panel/Presentation/PanelToolbar.swift', 'placeSubviews'):
        '2026-11-23：随类型自 Features/Panel/Presentation/PanelRootView.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Panel/Presentation/PanelToolbar.swift', 'sizeThatFits'):
        '2026-11-23：随类型自 Features/Panel/Presentation/PanelRootView.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/AppearanceSettingsDraft.swift', 'discard'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/AppearanceSettingsDraft.swift', 'init'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/AppearanceSettingsDraft.swift', 'observeChanges'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/AppearanceSettingsDraft.swift', 'refreshUnownedValues'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/AppearanceSettingsDraft.swift', 'reloadSavedValues'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/AppearanceSettingsDraft.swift', 'restoreDefaults'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/AppearanceSettingsDraft.swift', 'save'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'dropEntered'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'dropUpdated'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'image'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'init'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'makeCoordinator'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'makeNSView'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'performDrop'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'press'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'reduce'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
    ('Features/Settings/Panes/PersonalizationPreview.swift', 'updateNSView'):
        '2026-11-23：随类型自 Features/Settings/Panes/PersonalizationSettingsPane.swift 拆出迁入（职责拆分，纯搬家，行为不变）',
})

# ── 2026-11-23 存储布局重整 ──
EVIDENCE.update({
    ("Features/Monitor/Storage/StorageManagerWindow.swift", "handleIndexRevisionChange"):
        "2026-11-23：索引换代后的状态收拢（刷新磁盘容量/导航节点重锚/所选过滤/详情刷新/挂起下钻），"
        "从 body 的 onChange 回调抽出为独立函数（打断 ViewBuilder 修饰链的类型检查超时）；行为与原回调一致",
    ("Features/Monitor/Storage/StorageTreemap.swift", "layout"):
        "2026-11-26：StorageTreemap.body 提交当前 node、完整几何和索引版本；Voronoi 在后台计算，布局缓存最多 6 组",
    ("Features/Monitor/Storage/StorageTreemap.swift", "startLayout"):
        "2026-11-26：只运行一个布局请求；完成后启动最新待算请求，过时尺寸的计算结果不发布",
    ("Features/Monitor/Storage/StorageTreemap.swift", "storeLayout"):
        "2026-11-26：将完成布局写入有界缓存并发布 generation；同 node 的最近结果供计算期间过渡显示",
    ("Features/Monitor/Storage/StorageTreemap.swift", "rawPath"):
        "2026-11-26：StorageMapShape 的唯一路径构造与画布到目标矩形映射，由 StorageShapeCache 缓存入口调用",
    ("Features/Monitor/Storage/StorageTreemap.swift", "cached"):
        "2026-11-26：线程安全查找与写入 24 项曲面路径缓存；并发构建后复查已有键，避免重复队列项",
    ("Features/Monitor/Storage/StorageTreemap.swift", "quantize"):
        "2026-11-26：悬停坐标量化到 0.5pt，亚像素重复点不触发新的压力状态更新",
})

# ── 2026-11-23 需求 B：四类表面与交互状态令牌 ──
EVIDENCE.update({
    ("Core/UI/SurfaceStyle.swift", "body"):
        "2026-11-23：四类表面路由器（contentBase 不加层/card=glassCard/floatingGlass=glassPlate+浮动阴影/"
        "transient=glassPlate+柔投影），只路由到既有实现，不新建主题系统",
    ("Core/UI/SurfaceStyle.swift", "surface"):
        "2026-11-23：四类表面统一入口 .surface(_:)，卡片/浮层从这里取样式，替代散落的背景手写",
    ("Core/UI/SurfaceStyle.swift", "stateFill"):
        "2026-11-23：悬停/按下/选中状态底统一口径入口，替代各处 opacity(0.0x) 字面量",
    ("Core/UI/ThemeTokens.swift", "selected"):
        "2026-11-23：选中底统一口径（强调色低强度铺底，深浅分色，可传个性化强调色）；"
        "与 hover/press/disabledOpacity/focusRing 同组收编散落状态字面量",
})

EVIDENCE.update({
    ("Features/Toolbox/Calendar/CalendarSectionView.swift", "lunarDisplay"):
        "2026-11-24：dayCell 在农历文字开启时调用；复用同格 lunarDate、solarTerm 与 lunarFestival，"
        "节日、节气及既有文本优先级保持",
})

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
        # 2026-11-25（函数审查 NEEDS_FIX 落实）：两处修复——
        #   ① `_NAME_ALIASES[0][1] if False else key[3]` 是恒取 key[3] 的死表达式，删掉；
        #   ② Shelf→Curtain 改名只作用于**旧台账里的迁移期残留**（名字仍含 Shelf 或
        #      文件在旧 Shelf 路径下）。v263 之后源码早已没有 Shelf 前缀，对现在新增的
        #      台账行无条件 replace 会静默改写无关函数名（如未来出现的 MyShelfBar）。
        key = (_PATH_ALIASES.get(key[0], key[0]), key[1], key[2], key[3])
        legacy_shelf = "Shelf" in key[3] or "Shelf" in key[0]
        if legacy_shelf:
            key = (key[0], key[1], key[2],
                   key[3].replace("ScreenshotShelfController", "ImageCurtainController")
                         .replace("Shelf", "Curtain"))
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
        dropped += max(0, len(items) - len(cand))
        for slot, (old_line, idx) in enumerate(items[:len(cand)]):
            r = dict(led[idx])
            name = r["name"]
            if (r["file"], r["owner"], name) in RENAMES:
                name = RENAMES[(r["file"], r["owner"], name)]
                renamed += 1
            new_line = cand[slot]
            if new_line != old_line:
                reanchored += 1
            if legacy_shelf:
                name = name.replace("ScreenshotShelfController", "ImageCurtainController").replace("Shelf", "Curtain")
            r["name"] = name
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


EVIDENCE.update({
    ("Features/Toolbox/Search/SearchSectionView.swift", "search"):
        "读取当前启用工具的译名与说明；斜杠沿SlashCommandCatalog，普通搜索沿FuzzyMatcher；只有本地化字段在主线程取值后交原结果项",
    ("Features/Toolbox/Search/CommandPalette.swift", "refreshLanguage"):
        "语言通知到达时用本窗口原选区重建普通及斜杠命令目录，再沿原搜索词refilter；不重建窗口或清输入",
    ("Features/Onboarding/WelcomeView.swift", "step"):
        "quickStart构造三张引导卡；仅呈现步骤序号、标题和操作说明，不持有交互状态",
    ("Features/Manual/ManualView.swift", "quickStartCard"):
        "分类首页保留原有任务卡；实际教程沿WelcomeWindowController入口打开，完整章节使用原文章ID选择，不复制教程状态",
})

EVIDENCE.update({
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "store"):
        "2026-11-19：把窗口与整屏 SCK 异步结果交给有超时的同步入口，锁保护等待与迟到完成间的读写",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "load"):
        "2026-11-19：与 store 共用同一结果锁，超时后调用方返回 nil，不让 SCK 永久卡住截图流程",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "isUsableImage"):
        "2026-11-19：过滤小图、比例错屏与透明空帧；源自安装版 00:04:46 原生抓图失败后仍将 848×77 单色裁图复制成功",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "windowImageMatchesFrozen"):
        "2026-11-19：窗口 SCK 重抓需同时匹配点击点和屏幕九个抽样点，否则保留触发冻结裁片",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "monochromeColor"):
        "2026-11-19：以整屏抽样识别异常平面帧并和另一通道对照；同色候选仍可保存",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "sameColor"):
        "2026-11-19：允许 3 级像素量化差，用于比较两个通道中的合法纯色屏幕",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "averageDifference"):
        "2026-11-19：同尺寸抽样两路同屏像素并略过 Toast 矩形，排除提示卡后平均色差超过 18 才取消保存",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "pixelColor"):
        "2026-11-19：只抽取点击点颜色，用于窗口 SCK 图与触发时屏幕快照的对应校验",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "captureScreenForScreenshot"):
        "2026-11-19：同屏原生彩色帧直接冻结；单色或失败才取 SCK 对照，Toast 可见时排除通知区域比较",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "screencaptureDisplayIndex"):
        "2026-11-19：将 NSScreen 的 CGDirectDisplayID 映射到 screencapture -D 主屏序号，避免抓错屏再套用原坐标",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "captureScreenOnDisplay"):
        "2026-11-19：按已映射的显示器 -D 序号抓取独立原生帧，后台任务不再捕获 NSScreen 对象",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "sckCaptureWindowSync"):
        "2026-11-19：窗口 SCK 等待设 4 秒上限，超时回退触发时冻结图而不阻塞交付",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "globalPoint"):
        "2026-11-19：把覆盖层中的真实点击点转为屏幕全局坐标，窗口候选只和同一画面位置比较",
    ("Features/Settings/Shell/SettingsWindowController.swift", "windowDidChangeScreen"):
        "更新设置窗最小尺寸以匹配进入屏幕的可见区域；窗口根视图仍由同一自适应容器布局",
    ("Features/Manual/ManualView.swift", "quickGuide"):
        "为剪贴板、截图/OCR、文件中转返回对应快速教程的纯文字概览",
    ("Features/Onboarding/QuickTutorialController.swift", "init"):
        "恢复已选教程并监听截图、复制、OCR 与文件发送的真实业务结果以推进任务状态",
    ("Features/Onboarding/QuickTutorialController.swift", "deinit"):
        "释放教程进度轮询计时器及通知观察者",
    ("Features/Onboarding/QuickTutorialController.swift", "status"):
        "按教程独立读取持久化完成状态",
    ("Features/Onboarding/QuickTutorialController.swift", "step"):
        "读取指定教程当前已完成的步骤数",
    ("Features/Onboarding/QuickTutorialController.swift", "select"):
        "保存当前教程选择并标记欢迎页已查看",
    ("Features/Onboarding/QuickTutorialController.swift", "returnToTasks"):
        "清除当前任务选择并返回欢迎页任务列表，保留每项进度",
    ("Features/Onboarding/QuickTutorialController.swift", "skip"):
        "退出当前教程而不标记为完成",
    ("Features/Onboarding/QuickTutorialController.swift", "resumeClipboardRecording"):
        "恢复用户暂停的剪贴板记录并刷新教程视图",
    ("Features/Onboarding/QuickTutorialController.swift", "begin"):
        "开始或恢复指定教程；完成项重新进入时从首步学习",
    ("Features/Onboarding/QuickTutorialController.swift", "restart"):
        "清除该教程完成状态和步骤后重新开始",
    ("Features/Onboarding/QuickTutorialController.swift", "copyClipboardExample"):
        "用户点击后才写入示例文本，记录剪贴板变更标记并等待真实历史项",
    ("Features/Onboarding/QuickTutorialController.swift", "openClipboard"):
        "示例已进入历史后切到主面板并打开剪贴板操作入口",
    ("Features/Onboarding/QuickTutorialController.swift", "startScreenshot"):
        "记录截图前最近路径并调用正式区域截图流程",
    ("Features/Onboarding/QuickTutorialController.swift", "openTransfer"):
        "记录初始暂存条目并打开主面板文件中转页",
    ("Features/Onboarding/QuickTutorialController.swift", "chooseTransferFile"):
        "由用户通过 NSOpenPanel 选择单个文件后加入本地暂存并记录路径",
    ("Features/Onboarding/QuickTutorialController.swift", "openResult"):
        "从剪贴板、截图或文件中转教程跳转到对应真实结果位置",
    ("Features/Onboarding/QuickTutorialController.swift", "resumeTracking"):
        "仅存在进行中的教程时启动一次共享进度轮询",
    ("Features/Onboarding/QuickTutorialController.swift", "refreshProgress"):
        "根据剪贴板历史、自写标记和新增暂存项推进教程，不播放虚构完成动画",
    ("Features/Onboarding/QuickTutorialController.swift", "complete"):
        "保存独立完成状态、最终步骤和实际结果提示",
    ("Features/Onboarding/QuickTutorialController.swift", "setStep"):
        "写入指定教程当前步骤并通知观察视图",
    ("Features/Onboarding/QuickTutorialController.swift", "key"):
        "生成按教程与字段分隔的偏好键",
    ("Features/Onboarding/WelcomeView.swift", "tutorialCard"):
        "绘制单项新手任务入口并根据该项进度提供开始、继续或重学",
    ("Features/Onboarding/WelcomeView.swift", "taskDescription"):
        "提供三项真实教程任务的单行操作摘要",
    ("Features/Onboarding/WelcomeView.swift", "tutorialDetail"):
        "展示当前任务步骤、实际状态、结果和跳过/稍后继续入口",
    ("Features/Onboarding/WelcomeView.swift", "tutorialSteps"):
        "按剪贴板、截图或文件中转分派真实按钮和完成条件",
    ("Features/Onboarding/WelcomeView.swift", "tutorialStep"):
        "按业务状态显示教程步骤及完成图标",
    ("Features/Onboarding/WelcomeView.swift", "shortcutDisplay"):
        "显示按键管理器当前解析出的用户快捷键",
    ("Features/Onboarding/WelcomeWindowController.swift", "showTutorial"):
        "选定新手任务后复用欢迎窗入口",
    ("Features/StatusBar/StatusBarController.swift", "showTutorialAction"):
        "菜单栏教程入口先返回欢迎页任务列表，再展示同一欢迎窗",
    ("Features/TransferDock/UI/TransferDockView.swift", "selectTutorialTransferItem"):
        "正式文件中转页出现和暂存列表变动时调用；仅文件中转教程选中的目标已经入列时勾选该项并切到发送页",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "applyTagChange"):
        "正式浮动窗接收标签通知，整体替换时只对可见窗重查；删除当前标签清筛选；按受影响dedupeKey更新行tagIDs，筛选或加载中重查，所选项变化重建预览",
    ("Features/Clipboard/Store/ClipboardManager.swift", "deinit"):
        "释放初始化登记的标签变化观察者，回调原本弱持有manager，不在释放时写数据库",
    ("Features/Clipboard/Store/ClipboardManager.swift", "applyTagChange"):
        "标签整体替换重查，当前标签被删除时清筛选；其他通知仅更新命中keys的行tagIDs，当前筛选或分页读取中沿原reload刷新",
    ("Features/Clipboard/Store/ClipboardManager.swift", "toggleSaved"):
        "行收藏按钮与菜单共用，将请求交updateSavedState的后台队列读取数据库现值后取反，不依赖过期行状态",
    ("Features/Clipboard/Store/ClipboardManager.swift", "updateSavedState"):
        "setNote及toggleSaved共用串行仓储写入，失败主线程提示；成功通知其他窗，收藏筛选重查，普通列表直接更新原条目isNote并发布items",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "init"):
        "ClipboardQuery显式初始化保存查询条件；filter构造从queryMapping转换类型收藏工具代码及文件分类，剥搜索首尾空白后转交原初始化，供主面板与浮动窗查询",
    ("Features/Clipboard/Store/TagStore.swift", "rename"):
        "标签管理保存调用，先剥空白并排除其他同名标签；参数绑定更新名称时间，成功主线程更新标签并按更新时间排序，失败返回false给表单",
    ("Features/Clipboard/Store/TagStore.swift", "tagIDs"):
        "主列表与浮动窗接收标签增量通知时按单个dedupeKey持锁读原mapping，没有关联返回空数组，不逐行访问SQLite",
    ("Features/Clipboard/Store/TagStore.swift", "publishTags"):
        "创建重命名删除成功后共用，主线程应用传入的标签数组更新并发变化通知；后台调用沿原主队列交付",
    ("Features/Clipboard/Store/TagStore.swift", "postChange"):
        "关联分配取消与标签列表变更共用，主线程发送原didChangeNotification及受影响keys信息，不重新加载整张关联表",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "init"):
        "剪贴板列表组件按item或选中标签及管理回调保存输入；新增收藏按钮与标签徽章init仅保存条目，正式按钮交manager翻转收藏，设置预览不执行写入",
    ("Features/Settings/Shell/SettingsPanes.swift", "saveRename"):
        "标签管理表单回车与保存按钮调用store.rename，失败提示并保留编辑，成功清editingTagID及名称草稿",
})

EVIDENCE.update({
    ("Features/Monitor/Storage/StorageVoronoi.swift", "triangulate"):
        "将凹形存储图边界耳切为三角片，使加权 Voronoi 裁切覆盖原容器形状",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "signedArea"):
        "计算多边形有向面积，为耳切判断顶点顺序",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "cross"):
        "计算三点叉积，供耳切凸角与点内判定使用",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "polygonPath"):
        "将三角裁切轮廓闭合为 SwiftUI Path，供图块填充与命中区域复用",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "init"):
        "将裁切交点量化到百万分之一坐标精度，使相邻三角片的共享边可合并",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "func"):
        "按坐标字典序排列 PointKey，统一共享边的端点方向",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "mergedContours"):
        "抵消三角片间的内部边并追踪剩余外轮廓，避免图块出现分片接缝",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "clockwiseTurn"):
        "在轮廓分叉处按转角选择下一条边，连续追踪凹形边界",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "area"):
        "分别汇总三角片面积和单片面积，供权重收敛与质心加权使用",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "centroid"):
        "分别计算多片面积加权中心与单个多边形质心，供站点松弛和图块定位使用",
    ("Features/Monitor/Storage/StorageVoronoi.swift", "sampledContours"):
        "按间距采样 Path 曲线并保留分离轮廓，供图块边界、标签区域与命中路径生成",
})

EVIDENCE.update({
    ("Core/Runtime/AppUpdateChecker.swift", "isValidSHA256"):
        "自动安装前限定 SHA-256 为64位十六进制文本，供更新清单与实际包摘要比较",
    ("Features/AI/Translation/TranslationProvider.swift", "isAuthorized"):
        "按总开关与服务商授权键判断在线翻译许可；Apple 系统翻译始终本机可用",
    ("Features/AI/Translation/TranslationProvider.swift", "authorize"):
        "首次调用在线 Provider 时说明发送文字并记录用户对此服务的允许或拒绝",
    ("Features/AI/Translation/TranslationProvider.swift", "setOnlineAllowed"):
        "设置在线翻译总许可；关闭时撤销服务商单独许可及此前拒绝记录",
    ("Features/AI/Translation/TranslationToolSession.swift", "remember"):
        "记录最近一次成功翻译的实际 Provider，供结果提示显示真实服务",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "takeCaptureSessionCompletion"):
        "从当前截图会话取出并清空结束回调，交给动作条完成或取消路径单次调用",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "finishCaptureSession"):
        "截图授权拒绝、取消或无法产出时收束当前会话并调用其可选完成回调",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "credentialAccount"):
        "用工作流与步骤的稳定 UUID 组合 Keychain 账号，区分 GitHub 和 Linear 凭证",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "readCredential"):
        "按服务和账号读取 Keychain 凭证；区分条目不存在与钥匙串读取失败",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "writeCredential"):
        "先更新同账号 Keychain 项，不存在时新增，使 JSON 不必保存服务凭证",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "deleteCredential"):
        "删除已移除步骤对应的 Keychain 项，并允许条目本来不存在",
    ("Features/Capture/Workflow/CaptureWorkflow.swift", "presentFailure"):
        "报告工作流失败步骤和原截图路径；重试时从失败步骤继续并沿用上下文",
    ("Features/Clipboard/Store/FavoritesStore.swift", "init"):
        "构造共享收藏 store 时读取 resource_favorites；控制器构造时保留唯一窗口实例",
    ("Features/Clipboard/Store/FavoritesStore.swift", "contains"):
        "按资源类型和稳定 ID 查询本地发布集合中的收藏状态",
    ("Features/Clipboard/Store/FavoritesStore.swift", "set"):
        "幂等写入或删除非剪贴板收藏关联，成功后通知所有界面刷新",
    ("Features/Clipboard/Store/FavoritesStore.swift", "setClipboard"):
        "在同一 SQLite 事务中更新剪贴板旧收藏列与全局关联表，保证两处状态一致",
    ("Features/Clipboard/Store/FavoritesStore.swift", "clipboardRemoved"):
        "剪贴板记录删除后移除对应内存收藏状态并发布变化",
    ("Features/Clipboard/Store/FavoritesStore.swift", "publish"):
        "在主线程更新指定资源收藏键并发送全局收藏变化通知",
    ("Features/Clipboard/Store/FavoritesStore.swift", "toggle"):
        "在 SQLite 事务内读取当前收藏值并切换，避免不同入口使用过期视图值",
    ("Features/Clipboard/Store/FavoritesStore.swift", "removeMissing"):
        "全局收藏视图发现目标资源已不存在时删除对应收藏引用",
    ("Features/Clipboard/Store/FavoritesStore.swift", "references"):
        "按加入时间读取类型、资源 ID 和日期，供全局收藏视图打开或清理条目",
    ("Features/Clipboard/Store/FavoritesStore.swift", "refresh"):
        "从 resource_favorites 重载收藏键集合，用于恢复备份后同步可见界面",
    ("Features/Clipboard/Store/FavoritesStore.swift", "show"):
        "创建或重新呈现可调整大小的全局收藏窗，并激活应用",
    ("Features/Clipboard/Store/FavoritesStore.swift", "reload"):
        "合并剪贴板、暂存文件、工具、命令和网页引用；失效资源移除并提供打开动作",
    ("Features/FloatingBall/FloatingBallController.swift", "columns"):
        "按小窗宽度、组件尺寸、启用数量与列数设置计算实际网格列数",
    ("Features/FloatingBall/FloatingBallController.swift", "pageCapacity"):
        "扣除小窗头尾控件高度后计算每页可容纳的组件数",
    ("Features/FloatingBall/FloatingBallController.swift", "pageCount"):
        "按启用组件数和当前容量计算自然分页数量",
    ("Features/FloatingBall/FloatingBallController.swift", "init"):
        "控制器单例持有复用状态；面板采用无边框非激活样式，避免建立第二主面板",
    ("Features/FloatingBall/FloatingBallController.swift", "start"):
        "监听入口开关、应用失活和显示器变化，再按当前偏好显示或收起面板",
    ("Features/FloatingBall/FloatingBallController.swift", "applyEnabledState"):
        "依据统一入口偏好显示或隐藏悬浮球，并在关闭时释放展开态事件监听",
    ("Features/FloatingBall/FloatingBallController.swift", "applyConfiguration"):
        "应用用户尺寸、透明度、组件网格及当前屏幕边缘位置设置",
    ("Features/FloatingBall/FloatingBallController.swift", "ensurePanel"):
        "只创建一个复用 NSPanel 和 SwiftUI 内容宿主，供悬浮球与快捷窗切换",
    ("Features/FloatingBall/FloatingBallController.swift", "show"):
        "优先恢复上次稳定显示器和相对位置，兼读旧屏幕数字键；不记忆时使用鼠标屏幕",
    ("Features/FloatingBall/FloatingBallController.swift", "toggleExpanded"):
        "在紧凑悬浮球与快捷组件网格之间切换",
    ("Features/FloatingBall/FloatingBallController.swift", "expand"):
        "保留面板实例，按用户宽高展开并恢复该屏上次页或默认页",
    ("Features/FloatingBall/FloatingBallController.swift", "positionExpanded"):
        "按球体贴边方向和中心高度定位快捷窗并约束到可见区域",
    ("Features/FloatingBall/FloatingBallController.swift", "selectPage"):
        "将页码限制在当前分页范围，并按设置保存该显示器的当前页",
    ("Features/FloatingBall/FloatingBallController.swift", "pointerEntered"):
        "鼠标进入时取消收起，唤回半隐藏球体；按设置延迟0.3秒悬停展开",
    ("Features/FloatingBall/FloatingBallController.swift", "pointerLeft"):
        "鼠标离开后延迟0.85秒收起或半隐藏；保持展开和禁用半隐藏设置分别生效",
    ("Features/FloatingBall/FloatingBallController.swift", "collapse"):
        "收起快捷组件并按设置贴边半隐藏或完整显示球体",
    ("Features/FloatingBall/FloatingBallController.swift", "dragChanged"):
        "保存鼠标与球体的初始偏移，并随鼠标更新球体窗口原点",
    ("Features/FloatingBall/FloatingBallController.swift", "dragEnded"):
        "按窗口最大重叠面积选择释放屏幕，左右贴边并在释放事件后恢复点击",
    ("Features/FloatingBall/FloatingBallController.swift", "parkBall"):
        "把球体置于当前屏幕最近侧边，按设置露16pt并保存完整停靠位置",
    ("Features/FloatingBall/FloatingBallController.swift", "installExpandedMonitors"):
        "快捷窗展开期间同时监听应用内与其他App点击及Esc，保留点击事件传递",
    ("Features/FloatingBall/FloatingBallController.swift", "removeExpandedMonitors"):
        "收起或停用快捷窗时移除已安装的点击和按键监听",
    ("Features/FloatingBall/FloatingBallController.swift", "windowDidResignKey"):
        "浮动面板失去键窗口状态后收起展开内容",
    ("Features/FloatingBall/FloatingBallController.swift", "run"):
        "把组件路由到现有业务窗口或共用内容窗，刘海关闭时仍可用；截图结束恢复球体",
    ("Features/FloatingBall/FloatingBallController.swift", "openModule"):
        "复用一个可缩放内容窗承载原业务视图，初始640×520且最小360×280",
    ("Features/FloatingBall/FloatingBallController.swift", "windowWillClose"):
        "共用内容窗关闭时移除内容宿主，释放业务视图和媒体消费者",
    ("Features/FloatingBall/FloatingBallController.swift", "move"):
        "在同一个悬浮面板上动画调整窗口位置与大小",
    ("Features/FloatingBall/FloatingBallController.swift", "savePosition"):
        "使用稳定显示器身份保存相对可见区域的位置，并记录最近使用屏幕",
    ("Features/FloatingBall/FloatingBallController.swift", "clampToConnectedScreen"):
        "显示器配置变化时将现存面板约束到当前连接屏幕可见范围",
    ("Features/FloatingBall/FloatingBallController.swift", "screenAtPointer"):
        "读取鼠标所在显示器作为新面板的放置屏幕",
    ("Features/FloatingBall/FloatingBallController.swift", "screenFor"):
        "选择与窗口重叠面积最大的连接显示器",
    ("Features/FloatingBall/FloatingBallController.swift", "screenKey"):
        "复用IslandDisplay的稳定显示器身份作为位置与页面偏好键",
    ("Features/FloatingBall/FloatingBallController.swift", "legacyScreenKey"):
        "读取旧NSScreenNumber数字键，以继续使用已有球体位置",
    ("Features/FloatingBall/FloatingBallController.swift", "clampedOrigin"):
        "按指定显示器可见区域限制面板原点，避免窗口移出屏幕",
    ("Features/FloatingBall/FloatingBallController.swift", "clamped"):
        "读取用户尺寸偏好并限制在设置界面公布的范围内，未设置时使用指定默认值",
    ("Features/Settings/Panes/FloatingBallSettingsPane.swift", "slider"):
        "展示球体尺寸、小窗宽高、组件尺寸及透明度，并即时应用",
    ("Features/Settings/Panes/FloatingBallSettingsPane.swift", "option"):
        "把位置记忆、逐屏页面记忆、离开保持展开与半隐藏开关写入共用偏好并应用",
    ("Features/StatusBar/StatusBarController.swift", "openFavoritesAction"):
        "状态栏全局收藏菜单项打开共享收藏窗口",
    # v282（用户：「甚至无法打开了」）：僵尸进程占着 pid 且无法激活/结束，
    # 必须从「已有实例」里排除，否则每次启动都会自杀。
    # v282（用户：「点了之后它无法启动」）：单实例检查拆成「抢锁」与「抢到之后的启动路径」两段，
    # 后者保留原来对官方原版 Frset 的提示。
    ("App/FrsetNextApp.swift", "continueAfterSingleInstanceCheck"):
        "抢到实例锁后的公共启动路径；2.5秒后检查官方原版com.maoux.frset是否在跑并提示重复菜单栏，其余沿用原单实例检查后半段",
    # v283（复盘第 7 节）：抢锁拆成「试抢 / 读持有者 / 判断持有者是否合法」三小块，
    # 便于在日志里说清「谁握着锁、它活不活」，也给残留锁回收一个明确判据。
    ("App/FrsetNextApp.swift", "InstanceLock.tryAcquire"):
        "acquire第一次与回收残留锁后各调一次；open带O_CREAT|O_RDWR|O_CLOEXEC防止fd被helper子进程继承，flock非阻塞抢锁成功后写入自身pid并返回fd",
    ("App/FrsetNextApp.swift", "InstanceLock.readHolderPid"):
        "acquire抢锁失败后读取锁文件里记录的持有者pid，读不到返回0，供是否回收残留锁的判断使用",
    # v284（2026-11-22 20:45 用户：「当前这个 APP 又出现了不能打开」）：光看进程在不在不够，
    # 卡死但没死的旧实例会一直攥着锁，让新版本永远礼让。
    ("App/FrsetNextApp.swift", "InstanceLock.startHeartbeat"):
        "持锁成功后启动2秒周期心跳（后台队列，不碰主线程）；无锁接管时也调一次，保证下一个实例能读到「我在跑」",
    ("App/FrsetNextApp.swift", "InstanceLock.touchHeartbeat"):
        "心跳定时器回调与启动时各写一次；把自身pid写入instance.heartbeat，文件mtime即最后存活时间",
    ("App/FrsetNextApp.swift", "InstanceLock.heartbeatStale"):
        "acquire抢锁失败后判活用；心跳文件缺失或mtime超过12秒即认定持锁方卡死，允许接管",
    ("App/FrsetNextApp.swift", "InstanceLock.isOutdatedBuild"):
        "acquire抢锁失败后判活用；比较锁文件里build=记录的二进制mtime与当前二进制，不一致说明占锁的是旧构建，应当让位",
    ("App/FrsetNextApp.swift", "InstanceLock.isLegitimateHolder"):
        "判断握锁者是否仍有资格：pid存在、不是僵尸、且NSRunningApplication的bundleIdentifier与本App一致；三类幽灵（已回收、僵尸、helper或pid复用）都返回false以便回收残留锁",
    ("App/FrsetNextApp.swift", "InstanceLock.acquire"):
        "启动时抢占instance.lock的排他flock；抢到则写入自身pid返回true，抢不到读回持有者pid返回false，锁文件打不开时放行以免把App拦死",
    ("App/FrsetNextApp.swift", "isZombie"):
        "单实例检查过滤用；proc_pidinfo取pbi_status==SZOMB(5)判定僵尸，NSRunningApplication与kill(pid,0)都会把僵尸当成活进程",
    # v282（2026-11-22 用户：「app卡死」「无法打开」）：卡死现场只留面包屑定不到帧，
    # 看门狗线程改为对自己跑一次 sample，把主线程调用栈落到 logs/hang-*.txt。
    ("Core/Runtime/LogArchive.swift", "captureHangStack"):
        "看门狗判定主线程阻塞后由checkHang调用；后台队列启动/usr/bin/sample采本进程1秒，栈落logs/hang-*.txt；每轮卡死最多两次，避免长时间阻塞刷出大文件",
    ("Core/Runtime/LogArchive.swift", "stamp"):
        "卡死栈文件名用HHmmss时间戳，供captureHangStack区分同一轮多次采样",
    # v282（用户：「甚至无法打开了，并且app卡死」）：卡死实例占着「同 bundle 已有实例」
    # 会让所有重启都自杀；标记文件让新实例知道旧的那个已经不省人事。
    ("Core/Runtime/LogArchive.swift", "freshHangMarker"):
        "新实例启动做单实例检查时读取；标记修改时间在窗口期（默认120秒）内视为旧实例仍在阻塞，超期当作历史痕迹忽略",
    ("Core/Runtime/LogArchive.swift", "writeHangMarker"):
        "看门狗判定主线程阻塞且需要写日志时调用；把 pid 与时间写进logs/main-thread.hang，供下次启动判断是否接管",
    ("Core/Runtime/LogArchive.swift", "clearHangMarker"):
        "主线程恢复时删除logs/main-thread.hang，避免下一次正常启动被误判成旧实例卡死",
    # v282（用户：「全方位性能优化……CPU 占用、存储表现」）：剪贴板行卡不再解码整图。
    ("Features/Clipboard/Store/ClipboardFileStorages.swift", "thumbnail"):
        "剪贴板行卡与浮动窗卡片专用；ImageIO按目标像素边长降采样解码，避免为50pt卡片解整张截图；缓存按路径@边长分桶，失败回退原图入口",
    # v282（用户：「悬停到剪贴板预览，它的展开动画之前有，重新实现一下」）：
    # 抽屉展开改纯图层动画，窗口尺寸不再逐帧变化。
    ("Features/Clipboard/UI/ClipboardPreviewWindow.swift", "playDrawerReveal"):
        "预览窗呈现与收回共用；锚点钉在靠主面板的竖直边，只对内容层做scaleX/scaleY与窗口alpha动画，完成后还原锚点；减弱动态效果时直接落位",
    ("Core/UI/LiquidGlass.swift", "makeCoordinator"):
        "NSViewRepresentable为每个玻璃背景实例保存样式签名，供updateNSView跳过未变化的材质重套",
    ("Features/Island/IslandSurface.swift", "tint"):
        "按外壳通透度生成黑色NSColor，供系统玻璃结构面使用单层着色",
    ("Features/Island/IslandSurface.swift", "applyTint"):
        "外壳通透度变化时只更新现有玻璃的tint，不重建采样视图或轮廓遮罩",
    ("Features/Island/IslandSurface.swift", "applyMaterial"):
        "外壳材质变化时切换已创建玻璃视图的显隐与纯色底，保留同一采样视图和轮廓状态",
    ("Features/Monitor/Storage/DiskIndex.swift", "largestDirectories"):
        "存储清理提示复用索引快照，递归前4层后按大小取12个目录；snapshot变化时由属性观察清除缓存",
})

EVIDENCE.update({
    # v287 剪贴板三栏工作台 / 分级收藏 / 海豚精灵（2026-11-23）
    ("Core/UI/Support.swift", "readingBase"):
        "预览/阅读面用不透明底（与窗口同源色），切断玻璃透射；壁纸不会再从正文底下透出，小字号对比度稳定",
    ("Core/UI/Support.swift", "sidebarFill"):
        "第五类表面「侧栏」的微暗底衬：浅色压暗、深色提亮，与中间卡片区做出层次；跟随个性化强调色与暗色主题",
    ("Core/UI/Support.swift", "sidebarFrost"):
        "侧栏霜感薄雾（强度为窗口级 glassFrost 的一半，跟随磨砂滑块）；不另加模糊，避免采样层叠加掉帧",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "clearHover"):
        "hover 预览结束/键盘移动时清掉悬停项并恢复预览到主动选中项，避免悬停反复夺走选中状态",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "currentFilterState"):
        "把当前筛选（类型/收藏等级/最近/已存/分组/标签/搜索词/选中项）打成快照，供返回栈记录",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "pushFilterSnapshot"):
        "侧栏切分类前压栈（上限 30），实现「点击返回恢复上一级筛选与搜索词」；只在用户主动切分类时调用",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "goBackFilter"):
        "弹栈恢复上一级筛选与选中项；Esc/返回按钮共用，栈空返回 false 交给逐维退让与窗口收起",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "refreshCounts"):
        "侧栏各入口条目数走后台 COUNT 聚合并合并 200ms 重复请求，避免切筛选时主线程查库",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "closeDrawerIfNeeded"):
        "窄窗分类抽屉在选中分类后自动收起，避免遮住卡片区",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "iconRailButton"):
        "窄窗图标列按钮（图标+悬停名称+选中底），保持分类在 52pt 列内可用",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "sidebarSectionHeader"):
        "侧栏分区标题（记录/收藏/项目/标签分组），统一字号与缩进",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "sidebarRow"):
        "侧栏分类行（图标/名称/条目数/选中底），并承载「拖卡到分类」落点：收藏等级行设等级、已存行存项目",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "sidebarTagGroup"):
        "侧栏标签分组行：展开折叠、显示归属条目数、双击按分组筛选；删组不删标签与记录由 TagStore 保证",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "sidebarTagRow"):
        "侧栏标签行：单击按标签筛选、拖卡片到标签即打标签（走自定义 dedupeKey 表示）",
    ("Features/Clipboard/Floating/FloatingClipboardDesk.swift", "handle"):
        "统一解析卡片拖拽载荷（com.sxyq.frsetnext.dedupekey），侧栏各落点共用一份实现",
    ("Features/Clipboard/Store/ClipboardRepository.swift", "sidebarCounts"):
        "侧栏计数：6 条 COUNT/GROUP BY 一次取齐（总数/24h/收藏分级/已存/每标签/每分组），不把历史载入内存",
    ("Features/Clipboard/Store/FavoritesStore.swift", "level"):
        "读取某资源的收藏等级（0 未收藏/1 普通/2 重要/3 置顶），供菜单打勾与侧栏判定",
    ("Features/Clipboard/Store/TagStore.swift", "setColor"):
        "只改标签颜色不动归属与排序；写入后按分组顺序重排内存数组",
    ("Features/Clipboard/Store/TagStore.swift", "createGroup"):
        "新建标签分组（排序取当前最大值+1），写入后 refresh 让侧栏立即看到新组",
    ("Features/Clipboard/Store/TagStore.swift", "renameGroup"):
        "重命名分组；同名/空名拒绝，成功后 refresh 同步",
    ("Features/Clipboard/Store/TagStore.swift", "setGroupColor"):
        "分组颜色持久化（侧栏组图标与颜色选择器共用），refresh 保证另一入口同步",
    ("Features/Clipboard/Store/TagStore.swift", "deleteGroup"):
        "删组事务内先把成员标签 group_id 置空再删组行：标签与剪贴板记录全部保留",
    ("Features/Clipboard/Store/TagStore.swift", "setGroup"):
        "标签移入/移出分组；不动标签名与关联记录，移动后按分组顺序重排内存数组",
    ("Features/Clipboard/Store/TagStore.swift", "reorderTags"):
        "按给定 id 顺序重写 sort_order（组内上下移与拖拽排序共用），成功后就地重排",
    ("Features/Clipboard/Store/TagStore.swift", "reorderGroups"):
        "分组排序落库（上下移/拖拽共用），refresh 后侧栏顺序稳定",
    ("Features/Clipboard/Store/TagStore.swift", "sortInPlace"):
        "内存标签数组的统一排序：分组序号 → 组内 sort_order → 更新时间；避免改名/移动后顺序跳变",
    ("Features/Clipboard/UI/ClipboardSectionView.swift", "favoriteLevelRow"):
        "右键菜单单个收藏等级项：当前等级打勾，点击写入等级（不改正文与标签）",
    ("Features/FloatingBall/DesktopPetView.swift", "petContent"):
        "海豚单帧内容：自定义 PNG 优先、否则内置矢量；静态模式与拖动中传 t=0 不跑时钟",
    ("Features/FloatingBall/DesktopPetView.swift", "dolphinBody"):
        "矢量海豚合成（尾鳍/背鳍/身体/腹部/胸鳍/眼睛/嘴线），支持眨眼状态",
    ("Features/FloatingBall/DesktopPetView.swift", "path"):
        "海豚各部件 Shape 的路径定义；尾/背/胸鳍/腹/嘴分别成形，保证纯代码绘制零图片资源",
    ("Features/FloatingBall/FloatingBallController.swift", "petDoubleTap"):
        "海豚双击动作：默认展开面板，也可执行用户配置的快捷动作",
    ("Features/FloatingBall/FloatingBallController.swift", "hidePet"):
        "隐藏精灵（收起并 orderOut），可从右键菜单触发，保留再次启用入口",
    ("Features/FloatingBall/FloatingBallController.swift", "quitPet"):
        "退出精灵：关闭 desktopPet.enabled 并刷新配置，恢复为普通悬浮球形态",
    ("Features/FloatingBall/FloatingBallController.swift", "body"):
        "ConditionalGlassPlate：普通球/展开面板走玻璃，海豚本体不套玻璃（保持清晰不整图模糊）",
    ("Features/Settings/Panes/FloatingBallSettingsPane.swift", "pickCustomPetImage"):
        "选择自定义海豚 PNG：复制到应用支持目录后存路径，避免原文件移动导致形象失效",
    ("Features/Settings/Shell/SettingsPanes.swift", "groupSection"):
        "标签管理里的分组区：颜色/重命名/上下移/解散 + 组内标签列表；解散只解绑不删记录",
    ("Features/Settings/Shell/SettingsPanes.swift", "tagRow"):
        "标签行：颜色、重命名、移动到分组菜单、上下移、删除；删除标签不影响剪贴板条目",
    ("Features/Settings/Shell/SettingsPanes.swift", "createGroup"):
        "从设置页新建分组，空名拒绝",
    ("Features/Settings/Shell/SettingsPanes.swift", "saveGroupRename"):
        "分组重命名提交；名称无效或重复时提示并保留编辑态",
    ("Features/Settings/Shell/SettingsPanes.swift", "moveGroup"):
        "分组上移/下移：交换后整体重写 sort_order，保证顺序稳定",
    ("Features/Settings/Shell/SettingsPanes.swift", "moveTag"):
        "标签在所属分组内上移/下移：只重写同组 id 顺序，不跨组移动",
    ("Features/Settings/Shell/SettingsPanes.swift", "hexString"):
        "Color→#RRGGBB 转换，供分组/标签颜色选择器落库（sRGB 取整避免偏色）",
    ("Models/Models.swift", "init"):
        "TagGroup 初始化（id/名称/颜色/排序/时间戳），侧栏与设置页共用同一模型",
})

EVIDENCE.update({
    # 2026-11-23 GenieWarp 分阶段实测补测（神灯动画）
    ("Core/Motion/GenieWarp.swift", "record"):
        "显示链路回调打点：只把 CACurrentMediaTime 追加进数组（加锁），不做任何计算/绘制，回调里零分配",
    ("Core/Motion/GenieWarp.swift", "start"):
        "一腿动画开始时建 CVDisplayLink 并每帧记时；refresh 取实际刷新率、declaredFrames 用于反推「帧序列需要多少 fps」",
    ("Core/Motion/GenieWarp.swift", "finish"):
        "收尾停表并结算：实测 fps、p50/p95/max 回调间隔、按刷新率推算的缺失回调数，一条日志说明「合成链路有没有被抢占」",
    ("Core/Motion/GenieWarp.swift", "cancel"):
        "停 CVDisplayLink 并释放；finish/cancel/teardown 都会走到，保证探针不常驻、不制造持续开销",
    # 2026-11-23 存储地图录屏/排障
    ("Features/Monitor/Storage/StorageTreemap.swift", "startScriptedHoverIfNeeded"):
        "仅当 probe.storageHover=1（或深链 ?hover=1）时，按面积最大的几块中心生成巡航路线并驱动同一个 hover 状态；默认不启用，真实鼠标交互与产品行为不变",
    ("Features/Monitor/Storage/StorageTreemap.swift", "start"):
        "30Hz 定时器沿「A→B→C→B→A」线性插值移动压力中心，仍走同一条压力场与 0.26/0.86 弹簧，因此录到的是真实形变与回弹（只是输入源非鼠标）",
    ("Features/Monitor/Storage/StorageTreemap.swift", "stop"):
        "停表并置 nil；到时自动停、onDisappear 也停，不留下常驻定时器",
})

EVIDENCE.update({
    # 2026-11-23 触觉遗留项补验：外接板选择逻辑 / 符号缺失回落
    ("Features/Haptics/TrackpadActuator.swift", "selectDeviceID"):
        "纯选择逻辑（不碰 IOKit）：ActuationSupported 且有 Multitouch ID 才是候选，内建优先、外接 Magic Trackpad 兜底；抽成纯函数后可用合成字典验证「仅内建/内建+外接/仅外接/不支持/缺 ID/空表」六种情况，真实枚举仍只读设备属性",
    ("Features/Haptics/TrackpadActuator.swift", "frameworkPath"):
        "私有框架路径，默认永远是系统真实路径；只有排障参数 --haptic-framework=<path> 才指向别处，用于在真实进程里走到「系统移除 MTActuator 符号」分支，业务调用不带该参数",
})


EVIDENCE.update({
    # 2026-11-23 ArcZip 1.2.5 工作区外观对齐
    ("Features/Archive/UI/ArchiveWorkspaceChrome.swift", "navButton"):
        "路径胶囊里的 ‹ › ↑ 单钮：禁用态变淡且不可点，不占 Tab 焦点，命中区固定 22×22",
    ("Features/Archive/UI/ArchiveWorkspaceChrome.swift", "previewCanvas"):
        "检查器预览画布：固定 180pt、圆角用 Theme.Radius.card；有内容才显示展开角标，点开走原大预览 sheet（文本编辑仍在 sheet）",
    ("Features/Archive/UI/ArchiveWorkspaceChrome.swift", "metadata"):
        "元信息行：左标签 58pt 宽灰字 11pt、右值 11pt 截断中间，行高 26 加一条发丝线；压缩包态与条目态共用",
    ("Features/Archive/UI/ArchiveWorkspaceChrome.swift", "init"):
        "PDF 首页缩略：按画布宽度等比生成 NSImage，检查器只放缩略图不嵌完整 PDFView，避免小面板里加载整份文档",
    ("Features/Archive/UI/ArchiveWorkspaceChrome.swift", "describe"):
        "按扩展名给检查器类型说明（ZIP/7Z/TAR.GZ/TAR/RAR 压缩包、DMG/ISO 磁盘映像），不读文件内容",
    ("Features/Archive/UI/ArchiveWorkspaceChrome.swift", "fileType"):
        "条目态副标题：文件夹显示「文件夹」，文件按扩展名显示「PDF 文件」等；空扩展名回落「文件」",
    ("Features/Archive/UI/ArchiveWorkspaceChrome.swift", "symbol"):
        "没有缩略图时按扩展名选 SF Symbol（图片/视频/音频/表格/文档/应用），只在检查器预览画布用",
})


EVIDENCE.update({
    # 2026-11-24 玻璃材质分层收口（底衬+霜感预合成 / 岛取样面解耦）
    ("Core/UI/Support.swift", "glassTint"):
        "结构面单层着色：把「通透度底衬」与「磨砂霜感」按 alpha 合成公式离线算成一层，四个滑块仍全部生效；旧实现两个全尺寸 fill/subview 叠着铺，每窗每帧多一次整窗合成",
    ("Core/UI/Support.swift", "cachedDynamicColor"):
        "带自定义 alpha 的动态色缓存：预合成结果的 alpha 由公式给出，不能再走「基色 + 常量 alpha」的 cachedSurface；按 (通透度,磨砂,midnight) 键复用同一个 Color 实例，面板每秒重算时不新建 NSColor 观察者",
    ("Core/UI/Support.swift", "composite"):
        "纯色叠合：A=a1+a2(1-a1)、C=(C1·a1+C2·a2(1-a1))/A；两色都是纯色 + 常量 alpha，所以结果可缓存，运行期零计算",
    ("Features/Island/IslandSurface.swift", "targetSize"):
        "玻璃取样面只认展开/收起两个最终尺寸：形变途中 SwiftUI 每帧都会 updateNSView，取样面若跟插值走，NSGlassEffectView 每帧重算背景采样",
    ("Features/Island/IslandSurface.swift", "applyGeometry"):
        "岛材质唯一几何入口：插值尺寸只喂 CAShapeLayer 遮罩，取样面在展开开始时放大一次、收起收尾时缩回一次；实测玻璃重建 12–16 次/次开合 → 2 次（展开）/0 次（收起）",
    ("Features/Island/IslandSurface.swift", "flushStats"):
        "形变收尾结算：几何更新次数、玻璃重建次数、遮罩重算次数与 layout p50/p95/max 一行日志（只记毫秒与次数，不记画面）",
})


EVIDENCE.update({
    # 2026-11-24 开合帧节奏探针
    ("Core/Motion/MotionPacingProbe.swift", "run"):
        "起一腿并按 duration 预约收尾；只在展开/收起那一腿存在，到点自动 finish，不常驻轮询（不为测量本身制造开销）",
    ("Core/Motion/MotionPacingProbe.swift", "start"):
        "新建 CVDisplayLink 抓显示链路回调；先 stop 旧的，避免两腿动画叠出两条链路",
    ("Core/Motion/MotionPacingProbe.swift", "record"):
        "回调线程只做「加锁 append 时间戳」，不碰主线程、不分配图像（复刻神灯播放节奏探针的口径）",
    ("Core/Motion/MotionPacingProbe.swift", "stop"):
        "停表并释放 link；finish/cancel 路径都走它，保证不留下常驻 display link",
    ("Core/Motion/MotionPacingProbe.swift", "finish"):
        "结算 p50/p95/max 与缺失回调并打一行日志：量的是合成链路回调节奏，不是主线程每帧耗时",
    ("Core/Motion/MotionPacingProbe.swift", "displayRefresh"):
        "刷新率取当前主屏 maximumFramesPerSecond（60–120Hz），用于算「应有回调数」与缺失数",
    ("Core/Motion/MotionPacingProbe.swift", "init"):
        "单例私有初始化：探针只有一份，避免多腿动画各起一条 display link",
    ("Core/Motion/MotionPacingProbe.swift", "deinit"):
        "析构兜底停表（单例不会走到，但保留以防将来改成实例持有）",
})

# ── v293（2026-11-24 玻璃系统 / 截图链路专项重构）────────────────────
EVIDENCE.update({
    ("Core/UI/LiquidGlassMaterial.swift", "resolve"):
        "玻璃参数唯一解析入口：solid/降透明 → visualEffect(windowBackground/withinWindow/active)；"
        "claim 系统玻璃仅在 focus==.systemDynamic 且全局开关允许时成立；其余一律 visualEffect+inactive。"
        "后端、材质、混合、状态、圆角、着色、外观一次算清并给签名，调用方不再各自判断",
    ("Core/UI/LiquidGlassMaterial.swift", "resolvedTint"):
        "动态 NSColor 必须在目标外观下取分量：performAsCurrentDrawingAppearance 内转 sRGB，"
        "否则深色窗口会拿到浅色 tint（旧实现毛玻璃分支干脆丢掉 tint，岛外壳通透度等于空转）",
    ("Core/UI/LiquidGlassMaterial.swift", "init"):
        "玻璃宿主初始化：按解析结果建底层对象（NSGlassEffectView/NSVisualEffectView），"
        "再叠着色层；内容由 embed 后加，层序固定为 玻璃→着色→内容",
    ("Core/UI/LiquidGlassMaterial.swift", "makeBackend"):
        "唯一创建底层材质对象的地方；系统玻璃在 macOS 27 关掉 effectIsInteractive，"
        "避免玻璃自身的光学按键反馈与内容层 hover 抢同一次合成",
    ("Core/UI/LiquidGlassMaterial.swift", "apply"):
        "幂等状态入口：签名没变只更新样式值、不碰材质（AppKit 对 material/blending/state 的任何赋值"
        "都会作废整窗采样）；后端真的变了才替换底层对象，内容与窗口状态不动",
    ("Core/UI/LiquidGlassMaterial.swift", "configureBackend"):
        "毛玻璃三分支先比较再赋值（material/blending/state 任一不同才在隐式动画里切），"
        "系统玻璃只同步 tintColor/cornerRadius；这是「失焦闪一下」与拖滑块重采样的直接修复点",
    ("Core/UI/LiquidGlassMaterial.swift", "applyTint"):
        "两条后端语义对齐：系统玻璃给 tintColor，毛玻璃交给同色着色层；"
        "系统玻璃时隐藏着色层，避免同一块玻璃被着色两次",
    ("Core/UI/LiquidGlassMaterial.swift", "applyCorner"):
        "圆角只在真变时赋值；radius==0 时关闭 masksToBounds，省掉整窗一次离屏合成",
    ("Core/UI/LiquidGlassMaterial.swift", "layout"):
        "只在 frame 真变时同步底层与着色层尺寸：逐帧插值的岛只更新遮罩，不重设取样面",
    ("Core/UI/LiquidGlassMaterial.swift", "viewDidChangeEffectiveAppearance"):
        "外观切换时重解析动态 tint 并更新签名；材质本身由 AppKit 自适应，不重建对象",
    ("Core/UI/LiquidGlassMaterial.swift", "GlassTintLayerView.init"):
        "着色层初始隐藏、不参与命中；纯 CALayer 填充，比叠一个全尺寸 SwiftUI fill 少一次合成",
    ("Core/UI/LiquidGlassMaterial.swift", "apply"):
        "着色层唯一写入口：颜色相同直接短路（动态色每次解析都是新对象，必须比值不比其他）",
    ("Core/UI/LiquidGlassMaterial.swift", "hitTest"):
        "着色层恒不接事件：覆盖层/面板的首次点击必须落到内容或宿主上",
    ("Features/Capture/Screenshot/ScreenSnapshot.swift", "seconds"):
        "会话预算构造：整轮截图共用一个 deadline，替代旧实现「每条通道各自 4s、可串行叠加 12s」",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "showOverlays"):
        "上屏阶段唯一入口：全部屏幕冻结完成后 activate 一次，光标屏 makeKey、其余 orderFront；"
        "日志明确区分「orderFront 返回」与真实可交互（首次输入事件另记）",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "makeOverlay"):
        "建一块覆盖层（不可见）：接齐五条提交回调 + 预置窗口命中列表；"
        "抓帧期间并行建窗，把上屏阶段的工作提前做掉，但绝不提前显示",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "installSnapshot"):
        "冻结帧直接作为 CALayer.contents 显示：覆盖层不再透出实时桌面，"
        "Kitnest 激活导致原应用预览/菜单消失也不再改变用户看到的画面",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "hitTest"):
        "所有子图层都不接事件，鼠标恒落到覆盖层自己；否则第一下点击会被 NSImageView 的"
        "acceptsFirstMouse=false 吞掉（历史「点一次没反应」同族）",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "layout"):
        "子层尺寸只在真变时同步（窗口不可缩放，正常只走一次）",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "replaceWindowHits"):
        "会话级窗口命中列表晚到时补入（一轮只枚举一次，双屏不再主线程枚举两遍）",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "collectWindowHits"):
        "可后台调用的窗口枚举：排除本进程与桌面元素、过滤 <80×60、CG 全局坐标转 Cocoa；"
        "主线程只在没有预置列表时兜底调用",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "drawCanvas"):
        "高亮/提示绘制：不再整屏填 35% 黑（压暗已下沉为静态层），只画窗口/元素高亮与提示胶囊",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "highlightBounds"):
        "当前高亮包围盒：局部失效的唯一依据，空白桌面时为空 → 不重绘",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "invalidateCanvas"):
        "只失效「旧高亮 ∪ 新高亮」：鼠标在空白处移动不再触发整屏重绘",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "updateCrosshair"):
        "十字准线改 CAShapeLayer 路径更新（关闭隐式动画）：贯穿全屏的两条线不再让整屏 backing store 失效",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "OverlayCanvas.draw"):
        "透传给覆盖层绘制；自身透明、不接事件，只承载「会随鼠标变化」的那一层",
    ("Features/Capture/Screenshot/ScreenshotOverlay.swift", "OverlayCanvas.hitTest"):
        "绘制层恒不接事件（事件统一由覆盖层 hitTest 接管）",
    ("Features/Monitor/Storage/StorageTreemap.swift", "rawPath"):
        "路径真实构造（缓存未命中时）：轮廓 ∩ 图块画布后线性映射；"
        "CGPath 布尔运算只在这里发生，不再每个悬停事件做一次",
    ("Features/Panel/Presentation/FloatingPanel.swift", "glassHost"):
        "在视图树里定位玻璃宿主（面板被 WindowReveal 容器再包一层）；"
        "替代旧实现「取 contentView.subviews.first」的脆弱假设",
})

# ── v293 续（2026-11-25 剩余缺陷逐条修复新增函数）────────────────────
EVIDENCE.update({
    ("Features/TransferDock/Android/AndroidWebDAVServer.swift", "streamDownload"):
        "WebDAV 下载流式化①：先 adb stat 取大小拿 Content-Length，发响应头后进入分块泵送；"
        "旧实现 readDataToEndOfFile 整文件进内存（GB 级视频峰值≈文件大小）",
    ("Features/TransferDock/Android/AndroidWebDAVServer.swift", "pumpDownload"):
        "WebDAV 下载流式化②：后台线程阻塞读 256KB → 连接队列发送 → 完成回调驱动下一块；"
        "连接消失/设备断开时 terminate cat 并关闭，连接关闭路径会清理 spills 与临时文件",
    ("Features/TransferDock/Transfer/LanTransferServer.swift", "pumpDownload"):
        "手机扫码下载流式化②：后台读 256KB → 连接队列发送 → 回调驱动下一块；"
        "长度不符/文件提前读到头按失败收尾（触觉 + 关连接）",
    ("Features/TransferDock/Transfer/LanTransferServer.swift", "finishDownload"):
        "下载收尾唯一出口：防重（done2）、触觉、GET 完成通知、cancel 连接；"
        "与 send() 的成功口径一致（method==GET 且 2xx）",
    ("Features/Capture/History/CaptureHistoryStore.swift", "itemsAsync"):
        "历史查询异步入口：同一串行队列查询、结果回主线程（串行队列保证完成顺序与调用顺序）；"
        "主线程不再 queue.sync 等缩略图生成所在队列",
    ("Features/Capture/History/CaptureHistoryStore.swift", "itemsLocked"):
        "必须在 queue 上调用的查询体（同步版 items 与异步版 itemsAsync 共用），逻辑与原实现一致",
    ("Features/Panel/Preview/PreviewImageLoader.swift", "cachedDecode"):
        "同步解码缓存（NSCache，上限 8 张）：悬停预览模型构造走不了 loadImage 异步缓存/在途去重，"
        "同一文件每次 hover 重新解码；sync- 路径独立 key，不影响 loadImage 的缓存语义",
    ("Features/Toolbox/Search/SearchSectionView.swift", "performFetch"):
        "搜索页抓取体（原 fetchResults 主体）：按引擎 URL 加载→8s 超时→渲染余量→JS 提取；"
        "外层 fetchResults 以任务链串行化后，单槽位 continuation 竞争消失，本体语义不变",
    ("Features/Capture/Curtain/CurtainWindow.swift", "scheduleScrollResizeEnd"):
        "⌘滚轮缩放收尾去抖（350ms）：旧实现每 tick 都 resizeEnd → 写 UserDefaults+rebuild+Toast+"
        "缩略图重扫；拖拽路径的 mouseUp end 不经过这里。CurtainCardView / CurtainCanvasView 两个视图各持一份",
})

# ── v291（2026-11-24 投屏线 v2 立项落地）────────────────────────────
EVIDENCE.update({
    ("Features/TransferDock/Transfer/LanTransferServer.swift", "connectHTML"):
        "立项 v2 主路线 A 的连接页：UA 分流给 iPhone(AirPlay 引导)/Android(无线调试指引)，"
        "直传动作跳 /s/ 复用既有路由；AP 隔离提示；无外链资源",
    ("Features/Toolbox/Calendar/CalendarSectionView.swift", "lunarDisplay"):
        "日历单元格把已计算的农历、节气与传统节日传入展示函数；函数只按原优先级裁短节日名，"
        "不再重复调用 LunarCalendar，节气、节日、农历和节假日文案的显示顺序保持原行为",
    ("Features/Capture/Screenshot/ScreenshotManager.swift", "cleanupStagingAtLaunch"):
        "CaptureModule.start 在启动阶段调用；utility 队列清理私有截图暂存目录，不初始化 ScreenshotManager 单例；同进程只调度一次",
    ("Features/TransferDock/Transfer/LocalTransferStore.swift", "pruneOrphanDirectories"):
        "LocalTransferStore.init 在 load 与 pruneMissing 后调用；串行后台遍历索引外目录，仅删除没有常规文件的空壳目录，保留含真实用户文件的目录",
})

if __name__ == "__main__":
    sys.exit(main())
