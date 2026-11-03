# C4 · Archive（归档 / 解压 / 压缩）逐行测绘

> 范围：`apps/FrsetNext/Sources/Features/Archive/`，14 个 `.swift`，**5 442 行**。全部整读。
> 符号对账：CSV 该目录 244 条声明，其中 **172 func + 19 init = 191 个函数级符号**；源码实际 `func` 声明 **196 处**——差值同样是 CSV 对**跨行签名**漏采（`ArchiveCore.run/runIn/execute/list/readEntry/extract/updateEntry/renameEntry/addFiles/removeEntries/create/saveEncryptedCopy`、`ArchiveServicesProvider` 三个 NSServices 入口、`ArchiveEntryThumbnail.load` 等）。本文表格已补齐。
> 只读测绘，未修改源码、未执行构建。

---

## 1. 文件清单

| # | 路径 | 行数 | 一句话职责 |
|---|---|---|---|
| 1 | `ArchiveBrowserWindow.swift` | 1092 | 归档浏览窗：左条目/右预览、目录树导航、多选、编辑回写、撤销、拖出、加密另存 |
| 2 | `ArchiveCore.swift` | 1029 | 归档引擎：7zz 执行器、列条目、解压、读写条目、压缩、路径安全、Windows 文件名 |
| 3 | `ArchiveFlowRecommender.swift` | 457 | Flow 智能推荐（规则引擎 + 横向推荐条） |
| 4 | `ArchiveFileBox.swift` | 454 | 文件盒浮窗（拖入收集 / 8 色 / 闲置收起 / 压缩全部） |
| 5 | `ArchiveCreateSheet.swift` | 401 | 创建压缩包面板（5 预设 / 6 强度 / 密码 / 分卷 / Windows 名修正） |
| 6 | `ArchiveMiniWindow.swift` | 288 | ArcZip Mini 小窗（网格浏览 / 置顶 / 拖出即解压） |
| 7 | `ArchiveTaskQueue.swift` | 282 | 归档任务队列（串行泵 / 取消传播 / 进度 / 退出保护） |
| 8 | `ArchiveEntryDrag.swift` | 252 | 拖出到 Finder（NSFilePromiseProvider）+ 共用右键菜单 + 图标磁贴交互 |
| 9 | `ArchiveEntryThumbnail.swift` | 230 | 条目缩略图分级解码（ImageIO/PDF/AV/文本/QL 兜底 + NSCache） |
| 10 | `ArchiveEntryTable.swift` | 224 | AppKit NSTableView 条目表（多选/双击/多承诺拖出/行视图） |
| 11 | `ArchivePeekView.swift` | 215 | 悬停气泡里的归档预览（图标网格）+ 条目磁贴 + 系统类型图标缓存 |
| 12 | `ArchiveProgressPanel.swift` | 211 | 任务进度面板（内嵌 compact / 独立浮窗） |
| 13 | `ArchiveUndoStack.swift` | 200 | 归档编辑撤销/重做栈（显式 ArchiveChange 双向模型） |
| 14 | `ArchiveServices.swift` | 107 | NSServices 访达集成（解压到此处 / 解压到… / 压缩） |

合计 5 442 行，与 `wc -l` 一致。

---

## 2. 类型清单

### 2.1 `ArchiveCore`（enum，纯静态）
- **职责**：归档能力的唯一实现层。所有真实压缩/解压/回写都落到随包 `7zz`（LGPL）子进程。
- **状态**：`ArchivePasswords.cache`（静态 `[String:String]` + `NSLock`）、`progressRegex`（静态编译）、`StreamBox.lastPercent`。
- **生命周期**：无实例；`sevenZipPath` 每次调用重新探测（`Bundle/Resources/bin/7zz` → 开发期硬编码路径 → Homebrew → `/usr/bin`）。
- **依赖**：`7zz`、`ArchiveTaskQueue`（取消/进度）、`FileManager`、`NSRegularExpression`。
- **被依赖**：`ArchiveBrowserModel`、`ArchiveMiniModel`、`ArchivePeekView`、`ArchiveEntryThumbnail`、`ArchiveCreateModel`、`ArchiveUndoStack`、`ArchiveServicesProvider`、`ArchiveFlowRecommender`、`ArchiveFilePromiseDelegate`、`TransferDock`（通过 `ArchiveCore.isArchive` 双击压缩包进浏览窗）。

### 2.2 `ArchiveTaskQueue`（`ObservableObject` 单例）
- **职责**：所有归档操作的串行调度 + 取消传播 + 进度聚合 + 退出保护。
- **状态**：`tasks: [ArchiveTask]`（`@Published`）、`pending`、`runningIDs`、`processes: [UUID: Process]`、`cancelFlags: Set<UUID>`（锁保护）、`maxConcurrent = 1`。
- **生命周期**：进程常驻；任务完成不自动清理（`clearFinished` 手动）。
- **依赖**：`Process`、`NSAlert`（退出确认）。
- **被依赖**：`ArchiveCore`（全部写操作）、`ArchiveProgressPanel`、`ArchiveCreateModel`、`ArchiveUndoStack`（间接）、`FrsetNextApp.applicationShouldTerminate`。

### 2.3 `ArchiveBrowserModel`（`ObservableObject`）
- **职责**：浏览窗的单一数据源：条目/选中/层级/搜索/预览/草稿/撤销栈。
- **状态**：`entries`、`loading`、`errorText`、`selection: Set<String>`、`previewKind`（none/text/image/pdf/office/unsupported）、`previewEntry`、`draftText`、`dirty`、`searchText`、`showAuxiliary`、`currentPath`、`officeThumb`、`selectionAnchor`、`undoStack`。
- **生命周期**：由 `ArchiveBrowserWindowController` 持有，随窗口创建/关闭。
- **依赖**：`ArchiveCore`、`ArchiveUndoStack`、`FilePreviewBuilder.textExtensions`、`QLThumbnailGenerator`、`PDFKit`。

### 2.4 拖出相关三件套
- `ArchiveFilePromiseDelegate`（`NSFilePromiseProviderDelegate`）：每个条目一个 delegate，`userInfo` 强持有（`provider.delegate` 是 weak），`OperationQueue` 串行。
- `ArchiveMenuActions`（`NSObject`）：右键菜单动作载体（`target` 必须是 `@objc` 方法）。
- `ArchiveTileInteractionView`（`NSView`）：图标磁贴的鼠标语义层（点选/多选/双击/拖出）。

### 2.5 窗口控制器族
`ArchiveBrowserWindowController`（`static open: [String: …]` 按路径去重）、`ArchiveCreateWindowController`（按文件列表签名去重）、`ArchiveMiniWindowController`（按路径去重）、`ArchiveProgressWindowController`（单例 toggle）、`ArchiveFileBoxWindow`（单例 `shared`）。

### 2.6 其它
`ArchiveEntry`（struct，含 `isUnsafe`/`isEncrypted`）、`ArchiveChange`（enum，4 种可逆变更）、`ArchiveUndoStack`、`ArchiveCreateModel`、`ArchiveMiniModel`、`ArchiveFileBoxModel`、`ArchiveFileBoxTint`（8 色）、`ArchiveFlowRecommendation`/`ArchiveFlowRecommender`/`ArchiveFlowBar`、`ArchiveEntryThumbnail`、`ArchiveFileIcon`、`ArchiveEntryRowView`、`ArchiveEntryTableHost`、`ArchiveProgressPanel`/`ArchiveTaskRow`、`ArchiveServicesProvider`、`ArchiveEntryTile`、`MiniEntryDragPayload`（`Transferable`）。

---

## 3. 函数级清单

### 3.1 ArchiveBrowserWindow.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(url:)` | 51 | 建模型 + 撤销栈；`onApplied` 里 reload + 重新载预览 |
| `children(in:of:)` | 78 | 某目录直接子项；**为缺显式目录条目的深层路径合成虚拟文件夹**；目录优先排序 |
| `navigateTo(_:)` | 113 | 跳层级（清搜索/选中/预览） |
| `enter(_:)` | 122 | 双击目录进入 |
| `goBack()` | 128 | 返回上一层 |
| `activate(_:)` | 134 | 双击：目录进入，文件选中 + 预览 |
| `clickSelect(_:)` | 153 | 图标视图点选（⌘ 切换 / ⇧ 连选 / 普通单选） |
| `contextualSelect(_:)` | 175 | 右键：不在选中集才单选 |
| `reload()` | 184 | 全量列条目（含辅助文件，由 `visibleEntries` 过滤）；密码错误自动弹框；修剪选中与预览 |
| `clearPreview()` | 213 | 清预览/草稿/脏标记 |
| `promptPassword()` | 222 | NSSecureTextField 弹框，写会话缓存后重载 |
| `loadPreview(for:)` | 241 | 目录→unsupported；文本→内存读可编辑；图片→内存解码；其余→解临时目录（PDF 用 PDFKit，Office 用 QL 缩略图） |
| `saveDraft(completion:)` | 319 | 草稿写临时文件 → `updateEntry` 回写 → 成功则入撤销栈并刷新基线 |
| `addFiles(_:)` | 357 | 先扫 Windows 文件名问题 → 三选一对话框（建议名/原名/取消） |
| `withSuggestedNames(_:)` | 389 | 改名副本到临时目录（原盘不动），全量去重防撞名 |
| `performAddFiles(_:)` | 418 | 目标目录 = 选中目录 或 当前层级；成功后 `captureAddeds` 建撤销点 |
| `pickAndAddFiles()` | 443 | NSOpenPanel 多选（含目录） |
| `deleteSelected()` | 451 | 先 `captureSnapshots` 备份 → `removeEntries` → 入撤销栈 |
| `renameSelected()` | 479 | 单个重命名（多选只取第一个）；成功后入撤销栈 |
| `extractAll()` | 510 | 选目录 → 整包解压 |
| `extractSelected()` | 519 | 逐个解压选中项（串行） |
| `extractSequential(_:_:to:failures:)` | 526 | 递归串行解压 + 汇总失败 |
| `pickExtractDirectory()` | 544 | 目录选择面板 |
| `openExternally(_:)` | 555 | 解到临时目录后用默认应用打开 |
| `saveEncryptedCopy()` | 566 | 弹框输名字/密码 → 整包重打成加密归档 |
| `captureSnapshots(of:completion:)` | 600 | 删除前逐条目解到临时目录备份（目录展开为文件，>48MB 跳过） |
| `next(_:)` | 615 | 上述递归（内部 func） |
| `captureAddeds(_:into:completion:)` | 632 | 添加后把新增文件复制成快照（撤销用） |
| `show(url:)` | 659 | 按标准化路径去重打开/前置 |
| `init(url:)` | 674 | 860×560 窗 + NSHostingController + 立即 reload |
| `init(coder:)` | 688 | `fatalError` |
| `windowShouldClose(_:)` | 694 | **先过未完成任务保护**，再问草稿是否保存（保存/不保存/取消） |
| `windowWillClose` | 718 | 从 `open` 表移除 |
| `undo(_:)` / `redo(_:)` | 723/724 | Edit 菜单转发到撤销栈 |
| `makeNSView` / `updateNSView` | 1065/1071 | `ArchiveEntryTableRepresentable`（AppKit 表格包装） |
| `makeNSView` / `updateNSView` | 1082/1089 | `PDFViewRepresentable` |

**散文（虚拟目录合成的必要性）**
- 7zz `l -slt -ba` 对 zip 只输出**文件**路径（`a/b/c.txt`），不保证有 `a/`、`a/b/` 的目录条目（实测）。若只按 `parent` 字段过滤，这些文件在层级视图里会"消失"。
- `children(in:of:)` 因此扫描所有以 `dir + "/"` 开头的文件路径，剥掉第一段补出虚拟目录；用 `known` 集合防重，合成的目录 `size=0`、`modified=""`。
- 代价：每次渲染 `visibleEntries` 都要 O(n) 扫全表；10 万条目的归档会明显卡（`visibleEntries` 是计算属性，`ForEach` 每帧都求值）。

### 3.2 ArchiveCore.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `isArchive(_:)` | 91 | 33 种扩展名 + 复合后缀（`.tar.gz/.tar.bz2/.tar.xz`） |
| `isEditable(_:)` | 99 | 只有 `zip` / `7z` 可写 |
| `isAuxiliary(_:)` | 107 | `.DS_Store`/`Thumbs.db`/`desktop.ini`/`._*`/`__MACOSX` |
| `auxExcludeArgs(_:)` | 118 | 生成 `-x!` 排除参数 |
| `windowsReservedBase(_:)` | 133 | 取第一个点前的基名判 Windows 保留名 |
| `windowsUnsafeName(_:)` | 142 | 非法字符/控制字符/结尾空格点/保留名 → 中文原因 |
| `sanitizeWindowsName(_:)` | 161 | 非法字符替换 `_`、去尾空格点、保留名前加 `_` |
| `windowsNameIssues(_:)` | 178 | 批量扫描 → (name, reason, suggested) |
| `uniqueWindowsNames(_:)` | 187 | 改名撞名去重（`a-2.ext` 递增） |
| `isHardUnsafeEntryPath(_:)` | 214 | **硬拦截**：空/`\0`/绝对路径/`~`/UNC/盘符/任一段 `..` |
| `isUnsafeEntryPath(_:)` | 235 | 硬拦截 + 设备名段（仅 UI 警告） |
| `get(_:)` / `set(_:for:)` | 250/255 | 密码会话缓存（按标准化路径） |
| `looksLikePasswordError(_:)` | 262 | 7zz 需要密码的 6 种文案识别 |
| `run(_:timeout:taskID:onProgress:completion:)` | 311 | 执行器入口（无 cwd） |
| `runIn(_:cwd:…)` | 320 | 带工作目录（`7zz a` 靠 cwd 保住包内路径） |
| `execute(…)` | 329 | 双管道各起读线程 → `Process.run` → 注册进任务队列 → watchdog 超时 terminate → 等 EOF + 退出 → 回主线程 |
| `append(_:)` | 397 | `StreamBox` 锁内追加 |
| `readStream(_:into:onProgress:)` | 406 | `availableData` 阻塞读到 EOF；顺带解析进度 |
| `parseProgress(_:box:onProgress:)` | 421 | 抓块内最后一个 ≤100 的 `NN%`，值没变不回调 |
| `progressCallback(_:phase:)` | 436 | 任务进度闭包（无 taskID 时 nil） |
| `passwordArg(_:)` | 443 | 无密码 → `-p`（空密码）；有 → `-p<密码>` |
| `list(url:password:includeAuxiliary:completion:)` | 452 | `l -slt -ba` → 解析 → 可选过滤辅助文件 |
| `parseListOutput(_:)` | 473 | 空行分块 + `Key = Value`；目录判 `Folder = +` 或尾 `/`；打 `isEncrypted`/`isUnsafe` |
| `flush()` | 477 | 块收尾（内部 func） |
| `readEntry(url:entry:password:limit:completion:)` | 520 | `e -so` 把单条目读到内存（默认 8MB 上限） |
| `extract(url:entry:to:…)` | 546 | 入队 → 取消检查 → 单条目直判 / 全量先列条目校验路径 → `performExtract` |
| `both(_:_:)` | 553 | 统一收尾（取消 → 「已取消」） |
| `performExtract(…)` | 607 | 建目标目录 → `x -y -o<dir>` + 密码 + 辅助文件排除 + 限制路径列表 |
| `extractEntryToTemp(url:entry:completion:)` | 636 | 解单条目到独立临时目录（不入队） |
| `updateEntry(url:entryPath:localFile:…)` | 669 | 临时目录按包内相对路径放好 → `7zz a` 回写（cwd 保证路径不变） |
| `both` | 674 | 同上（每个入队 API 各有一份） |
| `renameEntry(url:entryPath:newName:…)` | 719 | `7zz rn` 原地改名（新名只取最后一段 + 硬安全闸） |
| `both` | 724 | 同上 |
| `addFiles(url:files:intoDirectory:…)` | 755 | 复制到 staging（可按目标目录建子目录）→ `7zz a` |
| `both` | 761 | 同上 |
| `removeEntries(url:entryPaths:…)` | 814 | `7zz d` 批量删除 |
| `both` | 822 | 同上 |
| `create(files:to:level:password:volumeMB:useWindowsSafeNames:…)` | 848 | 可选 Windows 改名 staging → tar.gz 两趟 / 单趟 `a -t<ext>` + `-mx` + `-v` 分卷 |
| `both` | 859 | 同上 |
| `finalize(_:_:)` | 907 | 清 staging + 成功记密码 + 文案 |
| `saveEncryptedCopy(url:to:password:level:…)` | 976 | 全量解到临时目录 → `a -p…`（7z 加 `-mhe=on`）→ 记密码 |
| `both` | 982 | 同上 |

**散文（executor 的三处关键设计）**
- **双管道两个读线程**：旧实现"先读完 stdout 再读 stderr"。当 7zz 往 stderr 写满 64KB 缓冲区而父进程还没读时，子进程会阻塞在 write 上；父进程却还在等 stdout 的 EOF → 互锁。现在两个 `DispatchGroup` 成员并行读，`group.wait()` 收口。
- **`Process.run()` 失败时要先关写端**：父进程手里还握着 `fileHandleForWriting`，读线程永远等不到 EOF。代码里显式 `close()` 再 `group.wait()`。
- **取消传播**：`registerProcess(task, for: taskID)` 之后 `cancel(taskID)` 就能 `terminate()`；若取消发生在注册之前，`registerProcess` 里会查到 `isCancelled` 并立刻 terminate。被 terminate 的 7zz 往往返回非 0 且 stderr 为空，因此每个 API 的 `both()` 都把"失败 + cancelFlag"统一改写成「已取消」。
- **`-bsp1` 只在需要进度时加**：`l -slt` 的输出要被解析，`e -so` 输出是二进制正文，掺进百分比会污染。

### 3.3 ArchiveCreateSheet.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(files:)` | 40 | 输出目录 = 首个文件父目录；默认名 = 单文件 stem / 多文件父目录名；套用预设 0 |
| `applyPreset(_:)` | 52 | 写格式 + 强度并同步扩展名 |
| `syncOutputExtension()` | 62 | 换格式就换后缀（防「名字 .zip 内容是 7z」） |
| `cancelCreate()` | 94 | 取消进行中任务（走队列取消传播） |
| `create(completion:)` | 100 | 校验 → Windows 名一次性弹窗 → `ArchiveCore.create`（记 taskID） |
| `init(model:onDone:)` | 150 | 视图注入 |
| `show(files:)` | 338 | 按文件列表签名去重打开 |
| `init(files:key:)` | 355 | 460×520 窗 |
| `init(coder:)` | 380 | `fatalError` |
| `windowShouldClose(_:)` | 383 | 压缩中关窗 → 确认取消任务 |
| `windowWillClose` | 398 | 从 `open` 表移除 |

### 3.4 ArchiveEntryDrag.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(archiveURL:entry:)` | 28 | 每个条目一个 delegate（自带串行 OperationQueue） |
| `filePromiseProvider(_:fileNameForType:)` | 34 | 承诺文件名 = 条目名 |
| `operationQueue(for:)` | 39 | 返回串行队列 |
| `filePromiseProvider(_:writePromiseTo:completionHandler:)` | 44 | **落点才解压**：解到临时目录 → `moveItem` 就位 → 删临时目录 |
| `fileType(for:)` | 74 | 目录 → `public.folder`；有扩展名且 `conforms(to: .data)` → 该 UTI；否则 `public.data` |
| `makeProvider(archiveURL:entry:)` | 84 | 造 provider 并把 delegate 挂 `userInfo` 保活 |
| `init(model:)` | 99 | 菜单动作载体 |
| `menuPreview(_:)` | 103 | 预览 |
| `menuEnter(_:)` | 108 | 进入文件夹 |
| `menuRename(_:)` | 113 | 重命名 |
| `menuExtract(_:)` | 117 | 解压所选 |
| `menuOpenExternal(_:)` | 121 | 用默认应用打开 |
| `menuAddHere(_:)` | 126 | 添加到该文件夹 |
| `menuDelete(_:)` | 130 | 删除 |
| `buildMenu(hasDirectory:)` | 135 | 组装菜单（目录项条件出现） |
| `make(_:_:)` | 154 | 造 `NSMenuItem` 并绑 target |
| `init(frame:)` | 172 | 磁贴交互层 |
| `init(coder:)` | 176 | `fatalError` |
| `mouseDown` | 180 | 记录起点；双击进目录 |
| `mouseUp` | 189 | 单击（非拖拽）才选中 |
| `mouseDragged` | 194 | >4pt 才起拖；拖选中组 → 整组拖出，否则只拖自己 |
| `rightMouseDown` | 214 | 先选中再弹共用菜单 |
| `makeNSView` / `updateNSView` | 241/248 | `ArchiveTileInteraction` 包装 |
| `draggingSession(_:sourceOperationMaskFor:)` | 225 | 返回 `.copy` |
| `draggingSession(_:endedAt:operation:)` | 230 | 复位 dragging 标志 |

**散文（为什么必须用 NSFilePromiseProvider + AppKit 拖拽源）**
- `NSFilePromiseProvider` 是 `NSObject <NSPasteboardWriting>`，**不是** `NSItemProvider` 子类，SwiftUI 的 `.onDrag` 塞不进去（原注释记录"探针实测编译不过"）。
- 因此列表走 `NSTableView.pasteboardWriterForRow`（每行一个承诺，多选拖出天然变成 N 个承诺），图标磁贴走 `beginDraggingSession(with:event:source:)`。
- 「拖出即解压」的意义：拖动时只上屏"名字 + UTI"，真正落盘时才起 7zz——大文件零双份 IO（对比"先解到临时目录再拷到目标"）。
- 承诺 UTI 必须 conform `public.data`/`public.folder`，否则 `NSFilePromiseProvider` 抛异常——`fileType(for:)` 的 `conforms(to: .data)` 判断就是为此。

### 3.5 ArchiveEntryTable.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `rightMouseDown` | 17 | 命中行不在选中集则换选，再弹共用菜单 |
| `init()` | 41 | 单列无表头、行高 24、多选、双击、`setDraggingSourceOperationMask(.copy, forLocal: false)` |
| `init(coder:)` | 70 | `fatalError` |
| `layout` | 74 | 滚动视图铺满 |
| `doubleClicked(_:)` | 79 | 双击 → `model.activate` |
| `syncFromModel()` | 89 | 按「路径签名」决定是否 `reloadData`，再回填选中（`applyingSelection` 防环） |
| `numberOfRows(in:)` | 113 | 行数 |
| `tableView(_:viewFor:row:)` | 117 | 每行 `autoreleasepool` 内造 `ArchiveEntryRowView` |
| `tableViewSelectionDidChange` | 126 | 表选 → 模型选中（同值不写回） |
| `tableView(_:pasteboardWriterForRow:)` | 136 | 每行一个文件承诺 |
| `init(entry:)` | 164 | 行视图（图标/锁/警告/名字/辅助标/大小/压缩率） |
| `init(coder:)` | 221 | `fatalError` |

### 3.6 ArchiveEntryThumbnail.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `canRender(_:)` | 47 | 图片/视频/文本/Office/PDF 才值得解出来出图 |
| `load(archive:entry:size:completion:)` | 54 | 缓存命中直返；否则全局队列 + 信号量（≤3）→ 解临时文件 → `render` → 删临时 → 写缓存 |
| `render(url:size:completion:)` | 90 | 按扩展名分派（图片/PDF/视频/文本/QL），包 `autoreleasepool` |
| `imageThumbnail(url:pixels:)` | 120 | ImageIO 缩略（`kCGImageSourceThumbnailMaxPixelSize`） |
| `pdfFirstPage(url:maxPixels:)` | 131 | CGPDFDocument 首页渲染到 `NSBitmapImageRep` |
| `videoFirstFrame(url:maxPixels:completion:)` | 154 | `AVAssetImageGenerator` 取 0.5s 帧 |
| `textPreview(url:pixels:)` | 168 | 前 1200 字，白底黑字等宽，底部渐隐 |
| `qlThumbnail(url:pixels:completion:)` | 196 | `QLThumbnailGenerator` + **6s 超时**，`finished` 锁保证只回调一次 |
| `finish(_:)` | 206 | 内部：去重回调 + 唤醒超时 |
| `cacheKey(archive:entry:size:)` | 225 | `路径|归档 mtime|条目路径|尺寸`（归档一改缓存失效） |

### 3.7 ArchiveFileBox.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `add(urls:)` | 95 | 按标准化路径去重；记大小与可读性；上限 64 丢最旧 |
| `addFromPasteboard()` | 114 | 从剪贴板取文件 URL |
| `remove(id:)` | 126 | 移除单项 |
| `clear()` | 130 | 清空 |
| `compressAll()` | 135 | 交给创建面板 |
| `row(_:)` | 214 | 列表行（图标/名/大小/不可读锁标/移出） |
| `miniButton(_:help:action:)` | 305 | 14×14 图标按钮（点击先重置闲置计时） |
| `icon(for:)` | 317 | 按 UTI 取系统图标 |
| `show()` | 334 | 单例：已有则前置 + 重置计时 |
| `init()` | 352 | 无标题栏 `.nonactivatingPanel`、可拖背景、`registerForDraggedTypes([.fileURL])` |
| `buildContent()` | 373 | SwiftUI 内容 + 底部「压缩全部…」 |
| `restartIdleTimer()` | 400 | 30s 无操作自动 `orderOut`（拖放中暂停） |
| `draggingEntered` | 411 | 暂停计时并判可读 |
| `draggingUpdated` | 419 | 恒 `.copy` |
| `draggingExited` / `draggingEnded` | 421/426 | 恢复计时 |
| `prepareForDragOperation` | 431 | `true` |
| `performDragOperation` | 433 | 读 URL → `model.add` |
| `close()` | 444 | 拆计时器 + 清单例 |

### 3.8 ArchiveFlowRecommender.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `recommend(for:url:)` | 66 | 无选中的推荐 |
| `recommend(for:url:selected:)` | 71 | 规则引擎：解压所选 → .app 安装 → .dmg 挂载 → 字体安装 → 单文件打开 → 多图解压 → 解压到… → 浏览 |
| `extractAll(url:)` | 179 | 选目录整包解压 |
| `extractEntries(_:of:)` | 194 | 并发解出多个条目（DispatchGroup）+ 汇总 |
| `openFile(url:entry:)` | 219 | 解临时目录后用默认应用打开 |
| `installApp(archiveURL:appPath:)` | 231 | 整包解到临时 → 顶层 `.app` 拷入 `/Applications`（失败则临时目录打开），**不做签名校验** |
| `installFonts(archiveURL:entries:)` | 271 | 逐条解出 → 拷入 `~/Library/Fonts` |
| `mountDMG(archiveURL:entry:)` | 301 | 解出 `.dmg` → `hdiutil attach -nobrowse` |
| `init(entries:url:selected:)` | 349 | 现算推荐（取前 4 + 其余进菜单） |
| `init(recommendations:)` | 357 | 直接给定列表 |
| `chip(_:)` | 402 | 推荐 chip |
| `demo()` | 443 | 假数据预览（业务勿调） |

### 3.9 ArchiveMiniWindow.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `icon(for:)` | 52 | `MiniFileIcon`：目录/UTI 图标 |
| `init(url:)` | 107 | Mini 模型 |
| `reload()` | 113 | 列条目 |
| `openEntry(_:)` | 121 | 双击：解临时 → 默认应用打开 |
| `extractAll()` | 133 | 选目录整包解压 |
| `openFullBrowser()` | 148 | 切到完整浏览窗并关 Mini |
| `show(url:)` | 252 | 按路径去重 |
| `init(url:)` | 267 | 360×420 窗 |
| `init(coder:)` | 283 | `fatalError` |
| `windowWillClose` | 285 | 从 `open` 表移除 |

### 3.10 ArchivePeekView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `load()` | 94 | 列条目（onAppear 一次） |
| `byteText(_:)` | 102 | 字节格式化 |
| `loadThumbnail()` | 167 | 磁贴首次出现时异步取缩略图（`thumb == nil` 防重入） |
| `icon(for:)` | 197 | `ArchiveFileIcon`：扩展名 → 系统 UTI 图标（`NSCache` 256） |

### 3.11 ArchiveProgressPanel.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(compact:expanded:)` | 22 | 内嵌/独立两用 |
| `show()` | 173 | 单例浮窗前置 |
| `toggle()` | 185 | 可见则 orderOut，否则 show |
| `init()` | 193 | 380×280 窗 |
| `init(coder:)` | 206 | `fatalError` |
| `windowWillClose` | 208 | 清单例 |

### 3.12 ArchiveServices.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `extractHere(_:userData:error:)` | 26 | 批量解压到各自所在目录 |
| `extractTo(_:userData:error:)` | 47 | 选一个目录批量解压 |
| `compress(_:userData:error:)` | 75 | 交给创建面板 |
| `fileURLs(from:)` | 88 | 读 pboard 文件 URL |
| `archives(from:)` | 95 | 按 `isArchive` 过滤 |

> 接线核实：`Info.plist` 有 `NSServices`（三项 `extractHere/extractTo/compress`），`FrsetNextApp.swift:44` 设 `NSApp.servicesProvider = ArchiveServicesProvider.shared`，`applicationShouldTerminate` 调 `ArchiveTaskQueue.shared.confirmQuitIfNeeded()`。**NSServices 与退出保护均已接线**（不是死代码）。

### 3.13 ArchiveTaskQueue.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 100 | 单例 |
| `enqueue(kind:title:work:)` | 106 | 主线程建任务 + 入 pending + `pump()` |
| `finish(taskID:ok:message:)` | 118 | 幂等收尾（不在 running 集就忽略）；被取消 → 统一记 cancelled |
| `cancel(taskID:)` | 141 | 排队中直接出队；运行中置 flag + `terminate()` |
| `cancelAll()` | 162 | 全部取消 |
| `isCancelled(_:)` | 170 | 锁保护，后台可查 |
| `registerProcess(_:for:)` | 179 | 注册 + 若已取消立刻 terminate |
| `unregisterProcess(_:for:)` | 187 | 身份比对后移除 |
| `updateProgress(taskID:_:message:)` | 197 | `progress<0` 只更新 message |
| `clearFinished()` | 218 | 清已完成 |
| `confirmQuitIfNeeded()` | 227 | 有活跃任务 → NSAlert（仍要退出/返回） |
| `pump()` | 246 | 串行泵（`maxConcurrent = 1`），在全局队列跑 work |
| `mutate(_:_:)` | 264 | 按 id 原地改任务 |
| `onMain(_:)` | 269 | 主线程桥（同 `LanTransferServer.onMain` 的写法，但这里是 async，不死锁） |
| `setCancelFlag(_:)` / `takeCancelFlag(_:)` | 273/278 | 锁内增删取消标记 |

**散文（任务队列的三条纪律）**
- **串行是硬约束**：同一个归档的写操作绝不能并发（`7zz a` 会重写整个包）。`maxConcurrent = 1` 不是性能选择而是正确性要求。
- **`onMain` 必须 async**：如果用 `main.sync`，后台 work 体里调 `updateProgress` 时主线程正在等 `group.wait()` 就会死锁。这里用 `async`，代价是状态更新有延迟（进度条最多晚一帧）。
- **`finish` 幂等**：`guard runningIDs.contains(taskID)` 保证 work 误调两次 `done` 不会重复出队/重复 pump。

### 3.14 ArchiveUndoStack.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(path:tempURL:)` | 24 | 快照值对象 |
| `init(url:)` | 75 | 绑定归档 |
| `push(_:)` | 80 | 入栈 + 清重做 |
| `undo()` | 86 | busy 门禁 → 逆操作 → 成功则迁到重做栈 + Toast + `onApplied` |
| `redo()` | 104 | 对称 |
| `refresh()` | 122 | 同步 4 个 `@Published`（canUndo/canRedo/label） |
| `apply(_:undo:completion:)` | 131 | 4 种变更的正/逆分发 |
| `restore(_:_:_:)` | 159 | 逐快照 `updateEntry` 写回（串行递归） |
| `remove(_:_:)` | 175 | `removeEntries` |
| `writeText(path:text:completion:)` | 186 | 写临时文件 → `updateEntry` |

**散文（显式 Change 模型 vs NSUndoManager）**
- 每条 `ArchiveChange` 自带双向数据：`delete(items, roots)` 的 undo 是"按快照写回"、redo 是"按 **roots** 再删"（目录删的是子树，只删快照里的文件会留下空目录）。
- `rename(from,to)` 的 undo/redo 靠 `current = undo ? to : from` 推导当前包内路径——这依赖"上一次操作一定成功且路径未被外部改动"，外部用别的工具改过包就会失配。
- 备份放临时目录，**随 App 生命周期**；`>48MB` 的条目不备份（该项不可撤销，UI 不给提示）。
- `busy` 门禁防止双击 ⌘Z 时的弹栈错位；失败时不弹栈（用户可重试）。

---

## 4. 关键数据流

### 4.1 解压（含路径安全）

```
双击压缩包 / NSServices / Flow 推荐 / 浏览窗「解压全部」
  → ArchiveCore.extract(url:entry:to:password:includeAuxiliary:completion:)
  → ArchiveTaskQueue.enqueue(.extract)            [state=waiting]
  → pump() → 全局队列跑 work                       [state=running]
      ├─ list(includeAuxiliary: true)             ← 7zz l -slt -ba（校验用，看全量）
      ├─ isHardUnsafeEntryPath 逐条筛
      │     ├─ 全部不安全 → 拒绝
      │     └─ 部分不安全 → restrictTo = 安全条目（≤1500 条才用显式列表）
      └─ performExtract → run(["x","-y","-o<dir>", 密码, 辅助排除, 包, 条目…])
            └─ execute()：双读线程 + watchdog + registerProcess(taskID)
                  └─ onProgress（-bsp1 → NN%）→ queue.updateProgress
      → both(ok, msg) → done() → finish() → pump() 下一个
```

### 4.2 编辑回写

```
文本预览 → TextEditor 编辑 → ⌘S / 「保存到归档」
  → ArchiveBrowserModel.saveDraft
      草稿写临时文件 → ArchiveCore.updateEntry
        ├─ staging 目录按 entryPath 放好副本
        └─ runIn(["a","-y",密码, 包路径, entryPath], cwd: staging)
      → 成功后 push(.editText(path, oldText, newText)) 到撤销栈
      → reload() + 基线挪到新文本
```

### 4.3 拖出到 Finder

```
列表拖行 / 磁贴拖拽（>4pt）
  → NSTableView.pasteboardWriterForRow / beginDraggingSession
  → ArchiveFilePromiseDelegate.makeProvider（delegate 挂 userInfo 保活）
  → Finder 松手 → filePromiseProvider(_:writePromiseTo:)
      → ArchiveCore.extract(entry:…, to: tempDir)      ← 此时才起 7zz
      → moveItem(tempDir/<entry.path> → 目标 URL)
```

### 4.4 创建压缩包

```
NSServices「压缩」/ 面板按钮 / 文件盒「压缩全部…」
  → ArchiveCreateWindowController.show(files:)
  → 选预设（格式+强度）/ 密码 / 分卷 / Windows 名修正
  → ArchiveCreateModel.create → ArchiveCore.create
      ├─ 可选：Windows 安全名 staging（复制改名，原盘不动）
      ├─ tar.gz：runIn(["a","-ttar",…]) → runIn(["a","-tgzip",…])（两趟）
      └─ 其它：runIn(["a","-t<ext>","-mx=N","-v..m",…], cwd: base)
      → finalize：清 staging + 记密码 + 完成文案
```

---

## 5. 资源清单

### 5.1 子进程
| 进程 | 位置 | 超时 | 备注 |
|---|---|---|---|
| `7zz`（随包/Homebrew） | `ArchiveCore.execute` | 默认 300s（watchdog `terminate()`） | 所有压缩/解压/列条目/回写 |
| `/usr/bin/hdiutil attach` | `ArchiveFlowRecommender.mountDMG` | 无 | 挂载 .dmg |

### 5.2 线程 / 队列
- `DispatchQueue.global(.userInitiated)`：7zz 主执行体。
- `DispatchQueue.global(.utility)`：两个管道读线程。
- `DispatchQueue.global()`：watchdog（`asyncAfter`）、QL 超时。
- `OperationQueue("com.sxyq.frsetnext.archive-promise")`（串行，每个 promise delegate 一个）：落点解压。
- `ArchiveTaskQueue.pump` 把 work 丢到全局队列（并发上限靠 `maxConcurrent` 逻辑控制，不是队列宽度）。
- `NSLock`：`ArchivePasswords.lock`、`StreamBox.lock`、`ArchiveTaskQueue.cancelLock`、`qlThumbnail.finish` 锁。
- `DispatchSemaphore(value: 3)`：缩略图并发上限。

### 5.3 文件路径
- `<Bundle>/Contents/Resources/bin/7zz`（随包）
- `/Users/sunyiyang/Desktop/Project/frset-rebuild/apps/FrsetNext/Resources/bin/7zz`（**开发期硬编码**）
- `$TMPDIR/frset-archive-<uuid>/`（`extractEntryToTemp`，**从不清理**）
- `$TMPDIR/frset-archive-stage-<uuid>/`（`updateEntry` 用后删）
- `$TMPDIR/frset-archive-add-<uuid>/`（`addFiles` 用后删）
- `$TMPDIR/frset-archive-create-<uuid>/`（Windows 改名 staging，用后删）
- `$TMPDIR/frset-enc-<uuid>/`（加密另存，用后删）
- `$TMPDIR/frset-undo-<uuid>-<name>`、`$TMPDIR/frset-edit-<uuid>-<name>`（写入后删）
- `$TMPDIR/frset-promise-<uuid>/`（拖出，成功时删、失败不删）
- `$TMPDIR/frset-addsnap-<uuid>/`、`$TMPDIR/frset-addname-<uuid>/`（撤销快照 / 改名副本，**不清理**）
- `~/Library/Fonts`（装字体）、`/Applications`（装应用）、`/Volumes`（挂载后打开）

### 5.4 UserDefaults
| 键 | 默认 |
|---|---|
| `archive.fileBox.tint` | 0（蓝） |
| `archive.fileBox.opacity` | 0.88（0 视为未设置） |
| `archive.fileBox.idleClose` | true |
| `archiveBrowserViewMode` | false（列表） |

### 5.5 深链
`frsetnext://archive?action=compress&path=…`、`frsetnext://archive?action=filebox`、`frsetnext://archive?path=…&action=mini`（入口在 App 层分流）。

### 5.6 系统集成
- `Info.plist` → `NSServices`（`extractHere` / `extractTo` / `compress`）
- `NSApp.servicesProvider = ArchiveServicesProvider.shared`（`FrsetNextApp.swift:44`）
- `applicationShouldTerminate` → `ArchiveTaskQueue.shared.confirmQuitIfNeeded()`

---

## 6. 不变量与陷阱

1. **同一归档的写操作必须串行**（`maxConcurrent = 1`）。`7zz a/d/rn` 都是整包重写，并发会产生半截包。
2. **读管道顺序**：必须两个读线程并行或"先读后等"。旧写法会与子进程 stderr 缓冲互锁。
3. **`Process.run()` 抛错时要先关父侧写端**，否则读线程永不 EOF。
4. **`archiveTaskQueue` 的 `onMain` 必须 async**：`main.sync` 会在 work 体里死锁（主线程可能正在等 work）。
5. **`-bsp1` 只在要进度时加**：会污染 `l -slt` 解析与 `e -so` 二进制输出。
6. **`7zz a` 靠 cwd 保住包内路径**：`runIn(args, cwd: staging)` 里的路径必须是相对路径。
7. **拖出的 UTI 必须 conform `public.data`/`public.folder`**，否则 `NSFilePromiseProvider` 抛异常。
8. **`provider.delegate` 是 weak**：delegate 必须挂到 `userInfo` 上强持有，否则拖动到一半 delegate 被回收。
9. **路径安全分两级**：穿越/绝对路径/盘符/UNC → 拦截；设备名（CON/NUL）→ 只警告（macOS 合法）。
10. **`extract` 的 restrictTo ≤1500 条**：超过就退化为整包解压（见 7.3 风险）。
11. **虚拟目录**：zip 可能没有目录条目，层级视图必须自己合成，否则深层文件"消失"。
12. **撤销快照 >48MB 不备份**：该项静默不可撤销。

---

## 7. 重复实现 / 死代码 / 风险

### 7.1 重复实现
| 项 | 说明 |
|---|---|
| **`both(_:_:)` 收尾闭包 8 份** | `extract/updateEntry/renameEntry/addFiles/removeEntries/create/saveEncryptedCopy` 各定义一份**完全相同**的 `both`（`cancelled` 判定 + `done` + 主线程回调）。可抽成一个工厂函数。 |
| **`pickExtractDirectory` 逻辑 5 份** | `ArchiveBrowserModel.pickExtractDirectory`、`ArchiveFlowRecommender.extractAll/extractEntries`、`ArchiveMiniModel.extractAll`、`ArchiveServicesProvider.extractTo` 各写一遍 NSOpenPanel 目录选择。 |
| **"解临时目录 + 默认应用打开" 4 份** | `ArchiveBrowserModel.openExternally`、`ArchiveFlowRecommender.openFile`、`ArchiveMiniModel.openEntry`、`ArchiveEntryThumbnail`（QL 前物化）——都是 `extractEntryToTemp` + `NSWorkspace.open`。 |
| **"文件类型 → 图标" 3 份** | `ArchiveFileIcon.icon(for:)`、`MiniFileIcon.icon(for:)`、`ArchiveFileBoxView.icon(for:)`（第三份按 UTI 取，语义略不同）。 |
| **"扩展名集合" 4 份** | `ArchiveCore.archiveExtensions`、`ArchiveEntryThumbnail.{imageExts,videoExts,textExts,officeExts}`、`FilePreviewBuilder.textExtensions`（TransferDock 的）、`ArchiveFlowRecommender.{imageExtensions,fontExtensions}`。 |
| **"字节格式化" 10+ 处** | 每个视图各自调 `ByteCountFormatter.string(fromByteCount:countStyle:)`（类方法每次新建 formatter），只有 `TransferDockFile`/`LocalTransferItem` 做了 static 缓存。 |

### 7.2 死代码 / 半死代码
- `ArchivePeekView.byteText` 每次调用新建 formatter（未缓存，但只在 onAppear 后渲染几次）。
- `ArchiveFlowBar.demo()`：仅预览用，业务无调用。
- `ArchiveEntryThumbnail.canRender` 的 `officeExts` 分支最终都落到 `qlThumbnail`，多一次解压才出图。
- `ArchiveCore.parseProgress` 与 `TransferDock/ADBFileBridge.parsePercent` 是两个几乎相同的正则解析（跨模块重复）。
- `ArchiveMiniWindow` 的 `MiniEntryDragPayload`（`Transferable`）与浏览窗的 `NSFilePromiseProvider` 是**两套拖出实现**（一套 SwiftUI `.draggable`、一套 AppKit promise）。

### 7.3 风险（按危险度）
1. **`create` 的 tar.gz 分卷路径产出错误文件**（高，功能 bug）：`volumeMB > 0` 时先 `7zz a -ttar -v<MB>m` 生成 `x.tar.001/002…`，随后 `guard volumeMB == 0 else { finalize(0, ""); return }` —— **直接报成功，但没有 gzip**。用户得到的是 `.tar.001` 分卷，UI 却说"已创建 x.tar.gz（分卷 N MB）"。
2. **`extract` 的不安全条目回退**（高，安全）：当 `unsafe` 非空且安全条目数 > 1500 时 `restrict = nil` → `performExtract(entry: nil)` **整包解压**，穿越条目也会被解出（只靠 7zz 自身不做路径消毒；7zz 默认会拒绝 `../`，但依赖第三方行为而非显式校验）。安全闸被"性能兜底"绕过。
3. **`extractEntryToTemp` 的临时目录永不清理**（高，磁盘）：每次预览/拖出/缩略图都新建 `frset-archive-<uuid>/` 且不删。浏览一个含 200 张图的归档并逐个悬停，会留下 200 个临时目录（每份都是完整条目内容）。
4. **`textPreview` 在后台线程用 `NSImage.lockFocus()`**（高，稳定性）：`lockFocus` 依赖当前 `NSGraphicsContext` 栈，AppKit 未保证线程安全；批量缩略图（3 并发）时是明确的未定义行为面。`pdfFirstPage` 同类（`NSGraphicsContext(bitmapImageRep:)` + `saveGraphicsState`）。
5. **`ArchiveUndoStack` 的快照目录不清理**（中高）：`captureSnapshots`/`captureAddeds` 每个快照一个 `frset-addsnap-<uuid>/`，撤销/重做后也不删。删除 100 个文件 = 100 个临时目录常驻。
6. **`captureSnapshots` 串行起 N 个 7zz**（中）：删除 N 个条目要 N 次 `extractEntryToTemp`（每次一个进程 + 一次全包解压单条目）。删 50 个文件可能几十秒。
7. **`ArchiveBrowserModel.loadPreview` 的 office 分支不清理 tempURL**（中）：`previewKind = .office(tempURL)` 持有临时文件供"用默认应用打开"，切换预览时旧 tempURL 丢失且不删。
8. **`visibleEntries` 是 O(n) 计算属性**（中）：`children(in:of:)` 每次遍历全表 + 排序；10 万条目归档每帧都算（`ForEach` 多次求值），配合 `selection` 变化会明显卡。
9. **`ArchiveFilePromiseDelegate` 每个 delegate 一个 `OperationQueue`**（低）：多选拖 100 个文件 = 100 个队列实例。
10. **`installApp` 不做签名校验且直接写 `/Applications`**（中，安全/权限）：`/Applications` 不可写时回退到"从临时目录打开"，但没有隔离属性（`com.apple.quarantine`）处理——用户可能对"来路不明的 app"零提示地点开。
11. **`ArchiveEntryThumbnail.load` 的信号量可能泄漏**（低-中）：`ArchiveCore.extractEntryToTemp` 若因取消/超时失败仍会回调（`both` 一定调用），所以 `signal` 会执行；但如果 `extractEntryToTemp` 的 `performExtract` 提前 return（`restrictTo?.isEmpty`）走的是 `completion(true, …)`，也 OK。真正的风险是 300s 超时期间信号量被占满（3 个槽位卡 5 分钟，网格全是占位图标）。
12. **`ArchiveCreateModel` 的 `nameCheckConfirmed` 只弹一次**（低）：用户选了"保持原名"后，同一面板内后续压缩不再提醒（符合预期），但换一批文件也沿用旧决定——因为模型绑定的是固定 `files`，影响有限。
