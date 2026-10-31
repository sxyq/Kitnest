# FrsetNext 模块依赖与规模

> 自动生成，重算：`python3 tools/swift_catalog.py`　共 19 个模块 / 241 文件 / 75,652 行 / 11,719 个成员

## 模块规模

| 模块 | 文件 | 行数 | 成员 |
|---|---:|---:|---:|
| Capture | 39 | 13,328 | 2397 |
| TransferDock | 26 | 9,876 | 1369 |
| Panel | 20 | 7,970 | 1185 |
| Monitor | 23 | 7,666 | 1277 |
| Toolbox | 23 | 6,010 | 860 |
| Clipboard | 16 | 5,989 | 972 |
| Archive | 14 | 5,663 | 744 |
| AI | 25 | 4,500 | 807 |
| Settings | 13 | 4,367 | 397 |
| Core | 18 | 2,950 | 565 |
| StatusBar | 7 | 2,432 | 436 |
| Onboarding | 6 | 1,236 | 114 |
| Manual | 2 | 990 | 142 |
| App | 2 | 886 | 78 |
| Storage | 1 | 622 | 93 |
| Models | 2 | 522 | 141 |
| Audio | 1 | 330 | 74 |
| MemoryHelper | 1 | 185 | 40 |
| OCRHelper | 2 | 130 | 28 |

## 模块依赖（顶层类型被跨模块引用，边权=引用到的类型数）

```mermaid
flowchart LR
  M0["AI"]
  M1["App"]
  M2["Archive"]
  M3["Audio"]
  M4["Capture"]
  M5["Clipboard"]
  M6["Core"]
  M7["Manual"]
  M8["MemoryHelper"]
  M9["Models"]
  M10["Monitor"]
  M11["OCRHelper"]
  M12["Onboarding"]
  M13["Panel"]
  M14["Settings"]
  M15["StatusBar"]
  M16["Storage"]
  M17["Toolbox"]
  M18["TransferDock"]
  M4 -->|112| M6
  M18 -->|84| M6
  M13 -->|81| M6
  M17 -->|78| M6
  M14 -->|69| M6
  M0 -->|69| M6
  M5 -->|68| M6
  M10 -->|65| M6
  M2 -->|44| M6
  M15 -->|33| M6
  M13 -->|25| M5
  M12 -->|23| M6
  M1 -->|16| M4
  M1 -->|15| M6
  M4 -->|15| M11
  M1 -->|13| M17
  M13 -->|12| M4
  M17 -->|12| M4
  M18 -->|12| M11
  M6 -->|10| M13
  M13 -->|10| M11
  M0 -->|10| M11
  M17 -->|10| M11
  M1 -->|9| M13
  M14 -->|9| M10
  M5 -->|9| M11
  M5 -->|9| M16
  M1 -->|8| M18
  M14 -->|8| M4
  M14 -->|8| M11
  M14 -->|8| M17
  M4 -->|8| M17
  M10 -->|8| M11
  M13 -->|8| M2
  M0 -->|8| M9
  M12 -->|8| M4
  M5 -->|8| M13
  M6 -->|7| M11
  M1 -->|7| M2
  M1 -->|7| M10
```

## 高复杂度成员 Top 30

| 复杂度 | 行数 | 成员 | 位置 |
|---:|---:|---|---|
| 59 | 61 | ShortcutManager.keyText | `Features/Toolbox/ShortcutManager.swift:223` |
| 55 | 12 | PreviewMarkdownRenderer.keywords | `Features/Panel/PreviewMarkdownRenderer.swift:542` |
| 24 | 28 | ColorKeyControl.swatch | `Features/Settings/MonitorWidgetsPane.swift:786` |
| 23 | 23 | CodeLanguage.keywords | `Features/Toolbox/ToolConverters.swift:410` |
| 22 | 49 | SearchSectionView.listContent | `Features/Toolbox/SearchSectionView.swift:646` |
| 19 | 20 | FilePreviewBuilder.kindLabel | `Features/TransferDock/FileHoverPreview.swift:128` |
| 18 | 225 | AISettingsPane.body | `Features/AI/AISettingsPane.swift:181` |
| 16 | 125 | MonitorWidgetsPane.optionGroups | `Features/Settings/MonitorWidgetsPane.swift:579` |
| 16 | 17 | SettingsUIState.applyPaneMapping | `Features/Settings/SettingsWindowController.swift:38` |
| 15 | 17 | AnnotationEditorWindow.root | `Features/Capture/AnnotationEditorWindow.swift:1198` |
| 14 | 32 | LongScreenshotCaptureStream.start | `Features/Capture/LongScreenshotCoordinator.swift:25` |
| 14 | 220 | TransferDockSettingsPane.body | `Features/TransferDock/TransferDockSettingsPane.swift:30` |
| 14 | 16 | PermissionCenter.quickStatus | `Features/Onboarding/PermissionCenter.swift:172` |
| 13 | 110 | NetworkStatsPanel.diagnosticsSection | `Features/Monitor/StatsModulePanels.swift:1054` |
| 13 | 76 | AdbPairingView.body | `Features/TransferDock/AdbPairingView.swift:33` |
| 13 | 14 | Phase.text | `Features/TransferDock/AdbQrPairing.swift:69` |
| 13 | 73 | TransferDockView.lanCard | `Features/TransferDock/TransferDockView.swift:545` |
| 13 | 16 | SearchEngine.logoAssetName | `Models/SearchEngine.swift:27` |
| 12 | 13 | CaptureModule.capture | `Features/Capture/CaptureModule.swift:126` |
| 12 | 11 | ManualBlock.id | `Features/Manual/ManualDocument.swift:64` |
| 12 | 52 | CastView.body | `Features/TransferDock/CastView.swift:88` |
| 12 | 58 | TransferDockView.cloudSection | `Features/TransferDock/TransferDockView.swift:825` |
| 12 | 11 | SearchServiceManager.builtInEngines | `Models/SearchEngine.swift:60` |
| 11 | 12 | AnnotationTool.title | `Features/Capture/AnnotationCompositor.swift:13` |
| 11 | 12 | AnnotationTool.shortcut | `Features/Capture/AnnotationCompositor.swift:28` |
| 11 | 13 | AnnotationTool.systemImage | `Features/Capture/AnnotationCompositor.swift:42` |
| 11 | 17 | AnnotationCanvasView.apply | `Features/Capture/AnnotationEditorWindow.swift:1029` |
| 11 | 12 | CaptureMode.title | `Features/Capture/CaptureEventBus.swift:40` |
| 11 | 13 | CaptureMode.systemImage | `Features/Capture/CaptureEventBus.swift:55` |
| 11 | 8 | MonitorPopoutWindowController.cancelDismiss | `Features/Monitor/MonitorPopoutWindow.swift:240` |
