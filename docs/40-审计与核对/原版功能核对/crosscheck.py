#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
原版 Frset vs FrsetNext 一一核对（CSV 生成）
============================================
输入（本目录）：
  原版-类清单.csv          531 个 ObjC 类（含模块归属）
  原版-Swift类型清单.csv    1,396 个 Swift 类型 + 82 协议
  原版-ObjC方法明细.csv     2,670 个 ObjC 方法
  FrsetNext-类型清单.csv    724 个类型声明
  FrsetNext-函数清单.csv    2,309 个函数
输出：
  核对-原版vs-FrsetNext-类型级.csv
  核对-原版vs-FrsetNext-方法级.csv
  核对汇总.json
"""
import csv, json, os, re

OUT_DIR = "/Users/sunyiyang/Desktop/Project/frset-rebuild/docs/audit-原版功能核对"

# ---------- 人工映射表（原版类 → FrsetNext 对应实现，2026-10-24 逐类核实） ----------
# 状态：迁移=功能已由 FrsetNext 等价实现（改名/重组）；未实现=功能缺口；不适用=有意不含
MANUAL_MAP = {
    # AI 体系
    "AIProviderConnectionController": ("Features/AI/AIConnectionService.swift", "迁移"),
    "AIProviderConnectionService": ("Features/AI/AIConnectionService.swift", "迁移"),
    "AIProviderStore": ("Features/AI/CredentialStore.swift", "迁移"),
    "AIProviderURLSessionDelegate": ("Features/AI/AIConnectionService.swift", "迁移"),
    "AIToolStreamingSession": ("Features/AI/TranslationToolSession.swift", "迁移"),
    "AnthropicLLMAdapter": ("Features/AI/AnthropicService.swift", "迁移"),
    "GeminiLLMAdapter": ("Features/AI/GeminiService.swift", "迁移"),
    "OpenAICompatibleLLMAdapter": ("Features/AI/OpenAICompatibleService.swift", "迁移"),
    "AICredentialJournalStore": ("Features/AI/AICredentialJournal.swift", "迁移"),
    "AICredentialCommitCoordinator": ("Features/AI/AICredentialJournal.swift", "迁移"),
    # 生命周期
    "AppLaunchCoordinator": ("App/AppBootstrap.swift", "迁移"),
    "AppActivationPolicyCoordinator": ("App/AppBootstrap.swift", "迁移"),
    "AppUpdateManager": ("—", "未实现"),
    "LaunchAtLoginManager": ("Features/Settings/SettingsPanes.swift（SMAppService）", "迁移"),
    "ReviewRequestCoordinator": ("—", "未实现"),
    "WelcomeWindowController": ("—", "未实现"),
    "WelcomeWindowDelegate": ("—", "未实现"),
    "WhatsNewPresenter": ("—", "未实现"),
    "WhatsNewStore": ("—", "未实现"),
    "ApplicationIconProvider": ("Features/Clipboard/ClipboardAppIconCache.swift", "迁移"),
    # 菜单栏
    "MenuBarMetricsHostingView": ("Features/Monitor/StatsBarEngine.swift（合并条）", "迁移"),
    "MenuBarMetricsStatusBarController": ("Features/Monitor/StatsBarEngine.swift（合并条取代 4 独立项）", "迁移"),
    "NetworkSpeedChartLayerView": ("Features/Monitor/MonitorCharts.swift", "迁移"),
    "DiskActivityLampsLayerView": ("Features/Monitor/MonitorStatusItems.swift", "迁移"),
    "MemoryIconPinsLayerView": ("Features/Monitor/MonitorStatusItems.swift", "迁移"),
    "CustomMenuBarIconEasterEggManager": ("Features/StatusBar/MenuBarIconStyle.swift", "迁移"),
    "ToastAnimationState": ("Core/Toast.swift", "迁移"),
    "SettingsToastManager": ("Core/Toast.swift", "迁移"),
    # 主面板
    "MainPanelHostingView": ("Features/Panel/PanelRootView.swift", "迁移"),
    "FloatingClipboardHostingView": ("Features/Clipboard/FloatingClipboardWindow.swift", "迁移"),
    "FloatingClipboardActiveHoverTrackerNSView": ("Features/Clipboard/FloatingClipboardWindow.swift", "迁移"),
    "FloatingClipboardPaywallPanel": ("—", "不适用（无内购/Paywall）"),
    "SearchStateManager": ("Models/SearchEngine.swift", "迁移"),
    "SearchInteractionGeometry": ("Features/Toolbox/SearchSectionView.swift", "迁移"),
    "ClipboardSearchTextField": ("Features/Toolbox/SearchSectionView.swift", "迁移"),
    "SearchBarMouseWheelController": ("Features/Toolbox/SearchSectionView.swift", "待确认"),
    "SearchInputScrollController": ("Features/Toolbox/SearchSectionView.swift", "待确认"),
    "SystemStatusInteractionGeometry": ("Features/Monitor/StatsModulePanels.swift", "迁移"),
    # 剪贴板
    "ClipboardHistoryRetentionPruneScheduler": ("Features/Clipboard/ClipboardPruneSchedulers.swift", "迁移"),
    "ClipboardStoragePruneScheduler": ("Features/Clipboard/ClipboardPruneSchedulers.swift", "迁移"),
    "ClipboardItemEditSession": ("Features/Clipboard/ClipboardItemEditWindowController.swift", "迁移"),
    "ClipboardItemEditTextView": ("Features/Clipboard/ClipboardItemEditWindowController.swift", "迁移"),
    "ClipboardItemEditWindowController": ("Features/Clipboard/ClipboardItemEditWindowController.swift", "同名"),
    "ClipboardItemEditWindowDelegate": ("Features/Clipboard/ClipboardItemEditWindowController.swift", "迁移"),
    "ClipboardItemEditWindowRecord": ("Features/Clipboard/ClipboardItemEditWindowController.swift", "迁移"),
    "ClipboardListTopScrollTracker": ("Features/Clipboard/ClipboardTableHostView.swift", "迁移"),
    "ClipboardRowContextMenuActivationTrackerNSView": ("Features/Clipboard/ClipboardTableHostView.swift", "迁移"),
    "ClipboardRowHoverSuppressionController": ("Features/Clipboard/ClipboardTableHostView.swift", "迁移"),
    "AutoPasteEligibilityManager": ("Features/Clipboard/ClipboardManager.swift", "迁移"),
    "AutoPastePromptCoordinator": ("Features/Clipboard/ClipboardManager.swift", "迁移"),
    "AppKitDoubleTapMonitor": ("Features/Toolbox/DoubleTapShortcut.swift", "迁移"),
    "EventMonitor": ("App/AppBootstrap.swift + Features/Clipboard/ClipboardManager.swift", "迁移"),
    "EventTapContext": ("Features/Toolbox/DoubleTapShortcut.swift", "迁移"),
    # 截图/OCR/长截图
    "ColorPickerManager": ("Features/Capture/Eyedropper.swift", "迁移"),
    "ColorPickerWindow": ("Features/Capture/Eyedropper.swift", "迁移"),
    "ColorPickerOverlayView": ("Features/Capture/EyedropperBridge.swift", "迁移"),
    "ColorPickerMagnifierView": ("Features/Capture/EyedropperBridge.swift", "迁移"),
    "LongScreenshotEditorWindowController": ("Features/Capture/LongScreenshotPreviewWindow.swift", "迁移"),
    "LongScreenshotEditorScrollView": ("Features/Capture/LongScreenshotPreviewWindow.swift", "迁移"),
    "LongScreenshotEditorContainerView": ("Features/Capture/LongScreenshotPreviewWindow.swift", "迁移"),
    "LongScreenshotEditorDocumentView": ("Features/Capture/LongScreenshotPreviewWindow.swift", "迁移"),
    "LongScreenshotImageDocumentView": ("Features/Capture/LongScreenshotPreviewWindow.swift", "迁移"),
    "LongScreenshotPreviewModel": ("Features/Capture/LongScreenshotCoordinator.swift", "迁移"),
    "ScreenshotOCRResultWindowDelegate": ("Features/Capture/ScreenshotOCRWindow.swift", "迁移"),
    "ScreenshotOCRSourceNSTextView": ("Features/Capture/ScreenshotOCRWindow.swift", "迁移"),
    "ScreenshotOCRDirectVisionClient": ("Features/Capture/OCRService.swift", "迁移"),
    "ScreenshotOCRWorkerClient": ("Features/Capture/OCRService.swift", "迁移"),
    "PinnedScreenshotTipHostingView": ("Features/Capture/PinWindow.swift", "迁移"),
    "AnnotationCompositor": ("Features/Capture/AnnotationCompositor.swift", "同名"),
    "CodePreviewScrollView": ("Features/Panel/JSONInspectorView.swift", "迁移"),
    "CodeLineNumberRulerView": ("Features/Panel/JSONInspectorView.swift", "迁移"),
    "CodePreviewScrollAxisLockNSView": ("Features/Panel/JSONInspectorView.swift", "待确认"),
    "LargeTextPreviewContainerView": ("Features/Clipboard/LargeTextPreviewView.swift", "迁移"),
    # 日历
    "CalendarAuthorizationService": ("Features/Toolbox/CalendarService.swift", "迁移"),
    "CalendarEventService": ("Features/Toolbox/CalendarService.swift", "迁移"),
    "CalendarPanelState": ("Features/Toolbox/CalendarSectionView.swift", "迁移"),
    "CalendarFoldedWeekScrollMonitorView": ("Features/Toolbox/CalendarSectionView.swift", "迁移"),
    "CalendarScrollDismissObserverView": ("Features/Toolbox/CalendarSectionView.swift", "迁移"),
    # 网络信息
    "NetworkInfoService": ("Features/Monitor/NetworkDiagnostics.swift", "迁移"),
    "NetworkInfoPopoverController": ("Features/Monitor/NetworkDiagnostics.swift", "迁移"),
    "IPAddressToolPresentationState": ("Features/Toolbox/IPAddressService.swift", "迁移"),
    "IPAddressToolUsageTracker": ("Features/Toolbox/IPAddressService.swift", "迁移"),
    "NetworkMonitor": ("Features/Monitor/MonitorSampler.swift", "迁移"),
    "SystemMetricsCollector": ("Features/Monitor/MonitorSampler.swift", "迁移"),
    # 工具箱
    "ToolManager": ("Features/Toolbox/ToolRegistry.swift", "迁移"),
    "ToolShortcutManager": ("Features/Toolbox/ShortcutManager.swift + ToolShortcutStore.swift", "迁移"),
    "ToolShortcutExecutionCoordinator": ("Features/Toolbox/ToolRunnerWindow.swift", "待确认"),
    "ToolShortcutEnablePromptPresenter": ("Features/Toolbox/ToolRunnerWindow.swift", "待确认"),
    "ToolModeSession": ("Features/Toolbox/ToolRunnerWindow.swift", "待确认"),
    "ToolUsageQuotaManager": ("—", "待确认"),
    "TinyPNGWindowController": ("Features/Toolbox/MediaTools.swift", "迁移"),
    "TinyPNGWindowDelegate": ("Features/Toolbox/MediaTools.swift", "迁移"),
    "TinyPNGWorkerClient": ("Features/Toolbox/MediaTools.swift", "迁移"),
    "TinyPNGTaskViewModel": ("Features/Toolbox/MediaTools.swift", "迁移"),
    "TinyPNGThumbnailCache": ("Features/Toolbox/MediaTools.swift", "迁移"),
    "TinyPNGOutputDirectoryStore": ("Features/Toolbox/MediaTools.swift", "迁移"),
    "TimestampSettings": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "VarNameSettings": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "VisionGate": ("Features/AI/AISettings.swift", "待确认"),
    "ModelDiscoveryMenuButtonView": ("Features/AI/AISettingsPane.swift", "迁移"),
    "ScaleMenuButton": ("Features/Capture/AnnotationEditorWindow.swift", "待确认"),
    # 设置
    "SettingsStore": ("Core/Preferences.swift", "迁移"),
    "SettingsRouter": ("Features/Settings/SettingsModule.swift", "迁移"),
    "StatisticsWindowDelegate": ("Features/StatusBar/StatisticsWindowController.swift", "迁移"),
    "ShortcutCaptureNSView": ("Features/Toolbox/ShortcutRecorder.swift", "迁移"),
    "ShortcutKeyView": ("Features/Toolbox/ShortcutRecorder.swift", "迁移"),
    "ShortcutRuntimeCoordinator": ("Features/Toolbox/ShortcutManager.swift", "迁移"),
    # 权限引导
    "PermissionWindow": ("—", "未实现"),
    "PermissionWindowController": ("—", "未实现"),
    "PermissionPromptModel": ("—", "未实现"),
    # Pro/遥测（有意不含）
    "ProPurchaseManager": ("—", "不适用（无内购）"),
    "ProTrialOverrideManager": ("—", "不适用（无内购）"),
    "TrialUsageStore": ("—", "不适用（无内购）"),
    "PostHogManager": ("—", "不适用（遥测已斩断）"),
    "SentryManager": ("—", "不适用（遥测已斩断）"),
    "ResourceBundleClass": ("—", "不适用（构建机制）"),
    # 小型内部 UI 组件（FrsetNext 用 SwiftUI 等价实现，无 1:1 类）
    "AutoSidebarTextView": ("Features/Manual/ManualView.swift", "待确认"),
    "ConfiguringView": ("—", "待确认（内部UI组件）"),
    "CursorRegionView": ("—", "待确认（内部UI组件）"),
    "DragView": ("—", "待确认（内部UI组件）"),
    "ExpandingTextView": ("—", "待确认（内部UI组件）"),
    "HoverTintIconButton": ("—", "待确认（内部UI组件）"),
    "PromptTextView": ("—", "待确认（内部UI组件）"),
    "ReportingView": ("—", "待确认（内部UI组件）"),
    "RequestState": ("—", "待确认（内部UI组件）"),
    "SavePreparation": ("—", "待确认（内部UI组件）"),
    "SettingsConfettiHostingView": ("—", "待确认（内部UI组件）"),
    "SettingsFocusSentinelNSView": ("—", "待确认（内部UI组件）"),
    "TextInputBorderView": ("—", "待确认（内部UI组件）"),
    "WindowDelegate": ("—", "待确认（内部UI组件）"),
    "WindowReader": ("—", "待确认（内部UI组件）"),
    "StreamingTextScrollViewContainer": ("Features/AI/AISummaryView.swift", "迁移"),
    "PreviewJSONPreferenceStore": ("Features/Panel/PanelPreviewPreferences.swift", "迁移"),
    "PreviewMarkdownPreferenceStore": ("Features/Panel/PanelPreviewPreferences.swift", "迁移"),
    "OCRReadOnlyScrollView": ("Features/Capture/ScreenshotOCRWindow.swift", "迁移"),
    "RotatingLayerView": ("Features/StatusBar/MenuBarIconStyle.swift", "迁移"),
    # 工具箱-时间戳
    "TimestampTool": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "TimestampSettingsView": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "TimestampSettings": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "TimestampOutputType": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "TimestampPrecision": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "TimestampToolError": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    "TimestampToolSettings": ("Features/Toolbox/ToolConverters.swift", "迁移"),
    # 工具箱-管理/配置
    "ToolManagementView": ("Features/Toolbox/ToolRegistry.swift + ToolSettingsPane.swift", "迁移"),
    "ToolManagementRow": ("Features/Toolbox/ToolRegistry.swift", "迁移"),
    "ToolCommandDescriptor": ("Features/Toolbox/ToolRegistry.swift", "迁移"),
    "ToolCustomConfig": ("Features/Toolbox/ToolSettingsPane.swift", "迁移"),
    "ToolEditSheet": ("Features/Toolbox/ToolSettingsPane.swift", "迁移"),
    "ToolConfigError": ("Features/Toolbox/ToolRegistry.swift", "迁移"),
    "ToolExecutionSource": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolOperationMode": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolButtonPositionKey": ("Features/Toolbox/ToolRegistry.swift", "迁移"),
    "ToolSettings": ("Features/Toolbox/ToolSettingsPane.swift", "迁移"),
    "ToolShortcutBehavior": ("Features/Toolbox/ToolShortcutStore.swift", "迁移"),
    "ToolShortcutConfiguration": ("Features/Toolbox/ToolShortcutStore.swift", "迁移"),
    "ToolShortcutEnablePromptCard": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolShortcutEnablePromptOverlayView": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolShortcutEnablePromptPresenter": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolShortcutExecutionCoordinator": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolShortcutExecutionRequest": ("Features/Toolbox/ToolShortcutStore.swift", "迁移"),
    "ToolShortcutInputView": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolShortcutInvocation": ("Features/Toolbox/ToolShortcutStore.swift", "迁移"),
    "ToolModeSession": ("Features/Toolbox/ToolRunnerWindow.swift", "迁移"),
    "ToolUsageQuotaManager": ("Features/Toolbox/MediaTools.swift（纯本地实现，无配额）", "不适用"),
    # IP 工具
    "IPAddressTool": ("Features/Toolbox/IPAddressService.swift", "迁移"),
    "IPAddressToolAnchorView": ("Features/Toolbox/IPAddressService.swift", "迁移"),
    # 主面板/预览
    "MoreMenuPopover": ("Features/StatusBar/StatusBarMenuBuilder.swift + Features/Panel/PanelRootView.swift", "迁移"),
    "PreviewPopoverView": ("Features/Panel/PreviewPopoverContentView.swift", "迁移"),
    "ScreenshotOCRPanelView": ("Features/Capture/ScreenshotOCRWindow.swift", "迁移"),
    "SystemStatusSectionView": ("Features/Monitor/StatsModulePanels.swift", "迁移"),
    # 设置彩蛋（候选缺口）
    "SettingsConfettiHostingView": ("—", "待确认"),
    "SettingsConfettiOverlayView": ("—", "待确认"),
}

APPLE_PREFIX = re.compile(
    r"^(CG|NS|CF|UI|AX|SC|IO|EK|CN|MK|CL|CM|AV|CA|WK|Web|Swift|Darwin|Dispatch|os_|xpc|"
    r"Core|Foundation|AppKit|SwiftUI|Network|SystemConfiguration|Security|ServiceManagement|"
    r"ImageIO|ImageCapture|Quartz|CoreGraphics|CoreText|CoreImage|CoreMedia|CoreVideo|"
    r"CoreAudio|AudioToolbox|Metal|ModelIO|SceneKit|SpriteKit|MapKit|EventKit|Contacts|"
    r"Intents|Speech|Vision|NaturalLanguage|CreateML|BackgroundTasks|UserNotifications|"
    r"WidgetKit|Charts|Combine|Observation|SwiftData|StoreKit|PassKit|GameKit|"
    r"MultipeerConnectivity|BrowserEngineKit|ReplayKit|PhotoKit|Photos|AVKit|MediaPlayer|"
    r"WebKit|SafariServices|AuthenticationServices|CryptoKit|NetworkExtension|"
    r"EndpointSecurity|IOSurface|ColorSync|Accelerate|vImage|simd|Spatial|RealityKit|"
    r"ARKit|PermissionKit|MediaAccessibility|Accessibility|DiskArbitration|IOKit|HID|"
    r"PowerLog|Apple|MobileDevice|Lockdown|Shortcut|Automator|ScriptingBridge|AppleScript|"
    r"Carbon|TIS|LS|MD|SK|UT|AE|AB|AC|AD|AF|AG|AL|AM|AN|AO|AP|AQ|AR|AS|AT|AU|AW|SKPayment|"
    r"MXMetric|OS|lib)"
)

def load_csv(name):
    with open(os.path.join(OUT_DIR, name), encoding="utf-8") as f:
        return list(csv.DictReader(f))

def main():
    orig_classes = load_csv("原版-类清单.csv")
    orig_types = load_csv("原版-Swift类型清单.csv")
    orig_methods = load_csv("原版-ObjC方法明细.csv")
    next_types = {r["name"]: r["kind"] for r in load_csv("FrsetNext-类型清单.csv")}
    next_funcs = load_csv("FrsetNext-函数清单.csv")
    next_func_by_name = {}
    for r in next_funcs:
        next_func_by_name.setdefault(r["name"], []).append(r)

    # FrsetNext 源码全量标识符（用于"类型名是否在源码中出现"的弱匹配）
    import os as _os
    src_idents = set()
    src_root = "/Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/Sources"
    for dp, _, fns in _os.walk(src_root):
        for fn in fns:
            if fn.endswith((".swift", ".m", ".c", ".h")):
                try:
                    txt = open(_os.path.join(dp, fn), encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                src_idents.update(re.findall(r"\b[A-Za-z_]\w*\b", txt))

    # 人工映射状态归一化
    def norm_status(s):
        if s.startswith("迁移") or s == "同名":
            return "已覆盖-迁移/同名"
        if s.startswith("不适用"):
            return "不适用"
        if s.startswith("未实现"):
            return "未实现"
        return "待确认"

    # ---------- 类型级核对 ----------
    universe = {}
    for r in orig_types:
        universe[r["类型名"]] = (r["种类"], "Swift描述符")
    for r in orig_classes:
        short = r["短名"]
        mod = r["模块"]
        if short not in universe:
            universe[short] = ("class", f"ObjC类({mod})")
        elif "第三方" in mod:
            universe[short] = (universe[short][0], f"ObjC类({mod})")

    rows = []
    stat = {}
    for name in sorted(universe):
        kind, src = universe[name]
        is_apple = bool(APPLE_PREFIX.match(name))
        note = ""
        if name in next_types:
            status = "已覆盖-同名"
            target = f"FrsetNext:{next_types[name]}"
        elif name in MANUAL_MAP:
            target, raw = MANUAL_MAP[name]
            status = norm_status(raw)
            if status == "已覆盖-迁移/同名":
                status = "已覆盖-迁移"
        elif is_apple:
            status = "不适用-系统类型"
            target = "—"
            note = "Apple SDK 类型，由系统提供"
        elif name in src_idents:
            status = "已覆盖-源码引用"
            target = "FrsetNext 源码中出现同名标识符"
            note = "概念存在，实现方式可能不同（内联/改名）"
        else:
            key = name.lower()
            partial = [t for t in next_types if key[:12] in t.lower()]
            if partial:
                status = "待确认"
                target = "FrsetNext:" + "/".join(partial[:3])
                note = "名称部分匹配，需人工确认"
            else:
                status = "未匹配"
                target = "—"
                note = "FrsetNext 无对应类型或引用"
        stat[status] = stat.get(status, 0) + 1
        rows.append([name, kind, src, target, status, note])

    with open(os.path.join(OUT_DIR, "核对-原版vs-FrsetNext-类型级.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["原版类型", "原版种类", "原版来源", "FrsetNext对应", "核对状态", "备注"])
        w.writerows(rows)

    # ---------- 方法级核对 ----------
    mrows = []
    mstat = {"同名函数存在": 0, "无同名函数": 0, "不适用-第三方SDK": 0, "不适用-系统协议": 0}
    for m in orig_methods:
        owner, dem, mod = m["归属"], m["demangled归属"], m["模块"]
        sel = m["选择器"]
        base = sel.split(":")[0]
        if "第三方" in mod:
            mstat["不适用-第三方SDK"] += 1
            mrows.append([dem, mod, m["方法类型"], sel, "—", "不适用-第三方SDK", "Sentry/PostHog 等，FrsetNext 不含"])
            continue
        hits = next_func_by_name.get(base) or next_func_by_name.get(sel.rstrip(":"))
        if hits:
            scopes = "/".join(sorted({h["scope"] or h["file"] for h in hits})[:3])
            mstat["同名函数存在"] += 1
            mrows.append([dem, mod, m["方法类型"], sel, scopes, "同名函数存在", ""])
        else:
            if mod == "ObjC/其他":
                mstat["不适用-系统协议"] += 1
                mrows.append([dem, mod, m["方法类型"], sel, "—", "不适用-系统协议", "系统协议要求方法，FrsetNext 以 Swift 等价实现"])
            else:
                mstat["无同名函数"] += 1
                mrows.append([dem, mod, m["方法类型"], sel, "—", "无同名函数", ""])

    with open(os.path.join(OUT_DIR, "核对-原版vs-FrsetNext-方法级.csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["原版归属(demangled)", "模块", "方法类型", "选择器", "FrsetNext同名函数所在", "核对状态", "备注"])
        w.writerows(mrows)

    summary = {
        "原版函数入口总数": 41778,
        "原版ObjC类": len(orig_classes),
        "原版Frset模块类": sum(1 for r in orig_classes if r["模块"] == "Frset"),
        "原版第三方类": sum(1 for r in orig_classes if "第三方" in r["模块"]),
        "原版Swift类型描述符": 1462,
        "原版Swift协议": 82,
        "原版ObjC方法": len(orig_methods),
        "FrsetNext源码函数": len(next_funcs),
        "FrsetNext源码类型": len(next_types),
        "FrsetNext二进制函数入口": 19698,
        "类型级核对": stat,
        "方法级核对": mstat,
    }
    with open(os.path.join(OUT_DIR, "核对汇总.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
