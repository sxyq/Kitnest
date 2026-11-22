# C3 · TransferDock（文件中转 / 互传 / 投屏）逐行测绘

> 范围：`apps/FrsetNext/Sources/Features/TransferDock/`，17 个 `.swift`，**7 172 行**。全部整读。
> 符号对账：CSV 该目录 260 条声明，其中 **190 func + 17 init = 207 个函数级符号**；源码实际 `func` 声明 **225 处**——差值是 CSV 对**跨行签名**（带默认参数的多行 `func`）漏采，例如 `ADBFileBridge.push(...)`、`ScreenCastEngine.startMirror(...)`、`ADBWirelessEngine.pair/connect`。这些漏采的在本文表中已补齐。
> 只读测绘，未修改源码、未执行构建。

---

## 1. 文件清单

| # | 路径 | 行数 | 一句话职责 |
|---|---|---|---|
| 1 | `TransferDockView.swift` | 1577 | 中转页主体（发送/接收/云端三段 + 本地暂存网格）+ 拖放 + 定向二维码 + 行视图 |
| 2 | `LanTransferServer.swift` | 860 | 局域网 HTTP 直传服务（自写 HTTP 解析 + 内嵌手机页 + multipart 解析） |
| 3 | `CastView.swift` | 780 | 投屏页（设备/唯一主按钮/遥控行 + 两个折叠区：无线连接、更多工具） |
| 4 | `TransferCastEngines.swift` | 662 | 四个引擎：空投发送/接收监听、scrcpy 投屏、ADB 无线、ADB 文件桥 |
| 5 | `FileHoverPreview.swift` | 483 | 文件悬停预览（QuickLook 缩略图 + 文本前 8KB + 可调大小浮窗） |
| 6 | `ADBExtrasEngine.swift` | 415 | ADB 扩展（一键无线/通知同步/存储/APK/应用列表/导航键/单应用窗口） |
| 7 | `TransferDockService.swift` | 379 | OPPO 云端中转（调 Python 桥接脚本 + 登录态/空间/列表/上传下载） |
| 8 | `LocalTransferStore.swift` | 328 | 本地暂存（硬链接优先/符号链接/降级拷贝 + index.json 索引） |
| 9 | `TransferDockSettingsPane.swift` | 326 | 设置→文件中转（显示/投屏画质/扫码直传/云端/本地暂存） |
| 10 | `AndroidWebDAVServer.swift` | 306 | 把 /sdcard 暴露成 127.0.0.1 的 WebDAV（Finder 可挂载） |
| 11 | `MCPServer.swift` | 263 | 本机 MCP 服务器（JSON-RPC 2.0，8 个 adb 工具） |
| 12 | `AdbPairingService.swift` | 213 | 无线配对状态机（host 级 adb，绝不注入 `-s`） |
| 13 | `AdbPairingView.swift` | 200 | 配对卡 UI（发现列表/配对码弹框/已连列表/手动 IP） |
| 14 | `TransferDockLoginView.swift` | 137 | 内嵌 WKWebView 登录 OPPO 中转 + cookie 轮询落盘 |
| 15 | `TransferDockPreferences.swift` | 114 | 偏好键集中定义（云端/局域网/端口/token/投屏画质/自动暂存） |
| 16 | `TransferDockChrome.swift` | 68 | 两页共用小部件（区块头/轻按钮/设备行） |
| 17 | `QRCodeView.swift` | 61 | CIFilter 二维码（恒白底，3× 超采样） |

合计 7 172 行，与 `wc -l` 一致。

---

## 2. 类型清单

### 2.1 三条传输通道（关键架构）
| 通道 | 实现 | 对端要求 | 数据路径 |
|---|---|---|---|
| **隔空投送** | `AirDropSendEngine`（`NSSharingService(.sendViaAirDrop)`）+ `AirDropReceiveWatcher`（`DispatchSource` 监听 `~/Downloads`） | iPhone 零安装 | 系统级 P2P（AWDL） |
| **扫码直传** | `LanTransferServer`（NWListener + 自写 HTTP + 内嵌 HTML） | 手机浏览器（零安装） | 局域网 HTTP，带 4 位 token |
| **ADB 直传** | `ADBFileBridge`（`adb push/pull`）+ `AndroidWebDAVServer`（WebDAV over adb） | Android + 开发者选项 | USB / 无线 adb |
| （云端） | `TransferDockService`（`python3 frset_bridge.py` 子进程） | OPPO 中转站账号 | 公网 |

### 2.2 `LocalTransferStore`（`ObservableObject` 单例）
- **职责**：本地暂存池，是三条通道的共用「蓄水池」。
- **状态**：`items`（`@Published`）、`lastMessage`、`lastError`、`stagingRoot`、`indexURL`、串行队列 `frset.transfer.local`。
- **生命周期**：`init` → `load()`（读 index.json）→ `pruneMissing()`（剔除已删文件）；进程常驻。
- **依赖**：`LocalTransferPaths`、`StatisticsManager`、`TransferDockPref.autoStageExtensions`、`Notification.localTransferDidChange`。
- **被依赖**：`TransferDockView`、`LanTransferServer`（onMain 读 items）、`TransferDockSettingsPane`、`AirDropReceiveWatcher` 回调、剪贴板自动暂存（外部）。
- **三种模式**：`hardlink`（同卷，`link(2)` 不占空间）/ `symlink`（目录）/ `copy`（跨卷降级）/ `upload`（手机上传，真实独立文件）。

### 2.3 `LanTransferServer`（`ObservableObject` 单例）
- **状态**：`listener: NWListener?`、`running/port/shareURL/statusText/receivedCount/sentCount`（全部 `@Published private(set)`）、串行队列 `frset.transfer.lan`、静态 `_tokenCache`。
- **生命周期**：`start`/`startIfEnabled` → `startLocked` → `attemptBind`（端口顺延 9 次）；`stop`/`restart`/`rotateToken`。
- **每个连接一个 `ConnectionContext`**：`headerBuffer/headersParsed/method/path/headers/contentLength/bodyFile/bodyHandle/bodyReceived/done`。
- **依赖**：`NWListener/NWConnection`、`LocalTransferStore`、`MultipartParser`、`TransferDockPref`、`StatisticsManager`。
- **被依赖**：`TransferDockView`（出码/停服）、`TransferDockSettingsPane`（端口/二维码）。

### 2.4 `TransferDockService`（云端）
- **状态**：`loggedIn/leftSpace/totalSpace/files/…`（`@Published`）、`queue`（桥接串行）、`keepAliveTimer`（300s）、`liveSyncTimer`（30s）。
- **生命周期**：`startLiveSync`（中转页 onAppear）→ 30s `refresh()`；`startKeepAlive`（登录成功后）→ 300s `keepalive`。
- **依赖**：外部 Python 工程（`TransferDockPath.root`）、`/usr/bin/python3`、`NSWorkspace`。
- **被依赖**：`TransferDockView`、`TransferDockLoginView`、`TransferDockSettingsPane`。

### 2.5 四个 ADB 相关类型
- `ADBExtrasEngine`（enum）：`activeSerial`（5s 缓存）+ `run(args:timeout:completion:)` 统一封装 + 7 类能力。
- `ADBWirelessEngine`（enum）：`mdns services` 发现 / `pair` / `connect`（**注入 `-s`**）。
- `AdbPairingService`（`ObservableObject` 单例）：`Phase` 状态机 + `discovered` / `wirelessConnected`，**不注入 `-s`**（host 级命令）。
- `ADBFileBridge`（enum）：`push`（两版）/`pull`/`stagingDirectory`。
- `AndroidWebDAVServer` / `MCPServer`：两个本机 HTTP 服务（WebDAV over adb / MCP over adb）。

### 2.6 投屏相关
`ScreenCastEngine`（`findScrcpy`/`findADB`/`connectedDevices`/`startMirror`/`clipboardArguments`）、`CastView`（SwiftUI 页）、`AdbPairingView`（配对卡）。

### 2.7 预览 / UI 支撑
`FilePreviewPayload` / `FilePreviewBuilder` / `FileHoverPreviewController`（`NSResponder` 单例，为了拿 `mouseEntered/Exited` 才继承 NSResponder）/ `FileHoverPreviewView` / `VisualEffectBackground`；`TransferChrome`；`QRCodeImage` / `QRCodeView`；`TransferRowStyle`；`CloudRowView` / `LocalCardRowView`（Equatable 行视图）。

---

## 3. 函数级清单

### 3.1 ADBExtrasEngine.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `setActiveSerial(_:)` | 50 | 锁内写当前目标设备 + 时间戳 |
| `resolveSerialSync(_:)` | 58 | 后台解析目标设备：**无线优先**（serial 含 `:`），否则第一条 `device` |
| `needsSerialPin(_:)` | 83 | 全局命令白名单（devices/connect/pair/tcpip/mdns…）不需要 `-s` |
| `enableWireless(completion:)` | 132 | 取设备 IP → `adb tcpip 5555` → 等 2s → `adb connect ip:5555` |
| `deviceIP(completion:)` | 152 | 先 `ip addr show wlan0`，失败再全量 |
| `firstIPv4(in:)` | 161 | 正则取首个 `inet x.x.x.x/`，排除 127./0. |
| `openWirelessDebugging(completion:)` | 176 | 按三个候选 Activity 依次 `am start` |
| `attempt(_:)` | 183 | 上述递归尝试（内部 func） |
| `notifications(completion:)` | 202 | `dumpsys notification --noredact` → 解析 |
| `parseNotifications(_:)` | 208 | 按 `NotificationRecord(` 分块，取 title/text/bigText/when；过滤系统包、空标题，上限 30 |
| `flush()` | 216 | 块收尾（内部 func） |
| `extractValue(_:key:)` | 259 | `android.title=String (微信)` → `微信` |
| `shortAppName(_:)` | 269 | 跳过 com/org/android/client 等通用段，取最后有意义的段 |
| `shortTime(_:)` | 281 | 毫秒/秒时间戳 → `HH:mm` |
| `storage(completion:)` | 292 | `df -h /sdcard` + `du -sh /sdcard/*/`，按字节粗排 Top 8 |
| `byteValue(_:)` | 314 | `1.2G` → 数值（十进制进位） |
| `installAPK(url:completion:)` | 331 | `adb install -r -d`，180s 超时，成功判据含 `Success` |
| `thirdPartyApps(completion:)` | 341 | `pm list packages -3` → 按 label 排序 |
| `sendKey(_:completion:)` | 365 | `input keyevent <code>` |
| `expandNotifications(completion:)` | 372 | `cmd statusbar expand-notifications` |
| `startAppWindow(package:width:height:)` | 383 | scrcpy `--new-display=WxH/160 --start-app=` （Android 14+） |

**散文（`run` 是全部 adb 调用的唯一出口）**
- `run(_:timeout:completion:)`（92 行，CSV 漏采）在全局队列跑 `Process`，**自己轮询 `task.isRunning` 每 60ms 检查超时**后 `terminate()`。这个轮询是必要的：`adb` 在某些状态下会永久挂起（`waitUntilExit()` 无超时版本会卡死后台线程）。
- 超时后仍先 `terminate()` 再读管道——如果子进程有子进程（adb server fork），读管道可能继续阻塞到 EOF。
- `activeSerial` 只有 5 秒有效期，过期后 `resolveSerialSync` 重新跑一次 `adb devices`（每个命令都可能多一次进程启动）。

### 3.2 AdbPairingService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 59 | 单例 |
| `scan()` | 64 | `adb mdns services` → `DiscoveredDevice` 列表（区分 pair/connect 服务） |
| `pair(target:code:)` | 107 | 校验 `ip:port` + 非空码 → `adb pair`；成功判据含 `success` |
| `connect(target:)` | 133 | `adb connect`；成功判据 `connected to` / `already connected` |
| `disconnect(target:)` | 162 | `adb disconnect` + 刷新 |
| `refreshConnected()` | 173 | `adb devices` 里 serial 含 `:` 且状态 `device` 的 |
| `runADB(_:completion:)` | 188 | host 级执行：**绝不注入 `-s`**（与 `ADBWirelessEngine` 的关键差异） |

**散文（为什么两套 ADB 引擎并存）**
- `ADBWirelessEngine.runADB` 会给所有命令注入 `-s <activeSerial>`；而 `pair`/`connect`/`disconnect`/`mdns` 是 **host 级**命令，带上 `-s` 会失败（尤其设备已在线时）。
- 于是 v130 新增 `AdbPairingService` 专管这几个命令，并加了 `Phase` 状态机给 UI。两套引擎功能重叠但不完全等价——`ADBWirelessEngine` 仍被 `MCPServer`/`ADBFileBridge` 之外的地方留着，属**半重复实现**。

### 3.3 AdbPairingView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init(embedded:)` | 21 | 显式 init（`@Stored` 私有属性会让成员逐一初始化器变 private） |
| `discoveredRow(_:)` | 132 | 发现行：图标 + 名称 + `ip:port · 服务类型` + 配对/连接按钮 |

### 3.4 AndroidWebDAVServer.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 27 | 单例（默认端口 8768） |
| `start()` | 29 | 从 8768 起试 8 个端口 |
| `bind(port:)` | 38 | 建 `NWListener` + 信号量等 `.ready`（2s 超时） |
| `stop()` | 68 | cancel + 置状态 |
| `accept(_:)` | 75 | 起连接 → 读请求 |
| `readRequest(_:buffer:)` | 80 | 读到 `\r\n\r\n` 为止；body 不足则转 `readBody` |
| `readBody(_:header:body:need:)` | 102 | 递归补齐 `content-length` |
| `headerValue(_:_:)` | 117 | 大小写不敏感取头 |
| `dispatch(_:header:body:)` | 124 | OPTIONS/PROPFIND/GET/HEAD/PUT/MKCOL/DELETE 路由 |
| `remotePath(from:)` | 160 | URL 路径 → `/sdcard/...`；`..` 过滤（防穿越） |
| `propfind(_:path:depth:)` | 175 | 生成 multistatus XML（Depth 0/1） |
| `href(fromRemote:)` | 198 | 去掉 `/sdcard` 前缀并逐段百分号编码 |
| `entryXML(href:isDir:size:name:)` | 210 | 单条 `<D:response>` |
| `listRemote(_:completion:)` | 228 | `ls -l` 解析（权限/大小/名字，软链剥 `-> target`） |
| `download(_:path:headOnly:)` | 251 | `adb exec-out cat` 全量读入内存后一次性发 |
| `upload(_:path:data:)` | 283 | 落临时文件 → `adb push` → 删临时 |
| `send(_:status:headers:body:)` | 295 | 拼 HTTP 响应（`Connection: close`） |

**散文（WebDAV 的代价）**
- `download` 用 `adb exec-out cat` 把**整个文件读进内存**再发：几百 MB 的视频会直接把内存撑爆（无分块、无 Range 支持）。
- `listRemote` 用 `ls -l` 文本解析，`maxSplits: 7` 依赖列数固定；Android 各版本 `ls` 输出（尤其是 `total` 行、SELinux 上下文列）不完全一致，解析失败会静默少列文件。
- `remotePath` 用 `filter { $0 != ".." }` 挡穿越，但 `%2e%2e` 已被 `removingPercentEncoding` 解开成 `..` 再过滤，OK；然而符号链接未校验，手机上的软链仍可指向 `/sdcard` 之外。
- 服务绑定在 `127.0.0.1`（NWListener 默认监听所有接口！）——**注释声称只绑本机，但代码没有设置 `params.requiredLocalEndpoint`**。实际是否对外可达取决于系统默认；这是一个需要核实的风险点（见第 7 节）。

### 3.5 CastView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `deviceCard(serial:state:)` | 201 | 设备卡（状态点 + serial + 主按钮/右键菜单） |
| `navIconLabel(_:)` | 290 | 34×30 图标按钮外观 |
| `enableWireless()` | 348 | 一键无线（`ADBExtrasEngine.enableWireless`） |
| `hint(_:)` | 648 | 灰字提示行 |
| `tipLine(_:)` | 725 | 说明弹层的一行 |
| `refreshDevices(quiet:)` | 737 | `connectedDevices` → 更新 + 可选 Toast |
| `refreshNotifications()` | 750 | 拉通知（防重入） |
| `loadStorage()` | 759 | 拉存储摘要 |
| `loadApps()` | 766 | 拉第三方应用（防重入） |
| `notifTint(_:)` | 775 | 包名 hash → 7 色调色板 |

**散文（v154 的性能修复）**
- 通知 6s 轮询曾用 `Timer.publish(...).autoconnect()` 写在 `onReceive` 里：每次 body 重算都新建一个 publisher（autoconnect 随订阅启动新定时器），页面状态一抖就叠一个定时器。现改为 `static let notifTick` 共享单例。
- v154 把「进页面就拉通知/存储/应用」改成**挂在「更多工具」展开之后**：不进工具区就不起 adb 子进程。轮询条件也加了 `panelPage.page == .cast && toolsExpanded`。

### 3.6 FileHoverPreview.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `build(url:completion:)` | 42 | 判存在/目录/文本类；文本读前 8KB，其余走 QuickLook，失败回退系统图标 |
| `requestThumbnail(url:completion:)` | 115 | `QLThumbnailGenerator` 900×1200 @scale |
| `kindLabel(for:)` | 128 | 扩展名 → 中文类型名 |
| `scheduleShow(url:)` | 174 | 0.4s 防抖后 `show` |
| `scheduleHide()` | 186 | 0.35s 后关（指针在面板内则不关） |
| `hide()` | 198 | orderOut + 清 currentURL |
| `show(url:)` | 225 | 同文件只挪位置；换文件才换 rootView |
| `ensurePanel()` | 243 | 建 `.titled + .resizable + .fullSizeContentView + .utilityWindow + .nonactivatingPanel` 面板，隐藏三个红绿灯 |
| `position(_:near:)` | 304 | 指针右下方，贴边翻面并钳制 |
| `mouseEntered` | 325 | 指针进面板 → 取消防自动关闭 |
| `mouseExited` | 331 | 指针离开 → 重新计时关闭 |
| `reload()` | 361 | token 化重载（避免旧回调覆盖新内容） |
| `makeNSView` / `updateNSView` | 475/482 | `NSVisualEffectView` 包装 |

### 3.7 LanTransferServer.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 49 | 触发 token 首次生成 |
| `start()` | 56 | 队列内 `startLocked(preferred:)` |
| `startIfEnabled()` | 62 | 开关关着就什么都不做（按需启动语义） |
| `stop()` | 68 | cancel + 主线程清态 |
| `restart()` | 85 | **原本没在跑就不代启动**，只换端口 |
| `rotateToken()` | 103 | cancel → 重新生成 → 0.2s 后 `startLocked` |
| `startLocked(preferred:)` | 113 | 去重入后 `attemptBind`（顺延 9 次） |
| `attemptBind(startingAt:remaining:)` | 119 | 建 listener；`.ready` 拼 URL 并写回顺延后的端口；`.failed` 递归下一个 |
| `loadToken()` | 192 | 已有 ≥4 位就用，否则生成 |
| `regenerateToken()` | 200 | 4 位随机（排除易混字符 0/1/l/o） |
| `lanIPv4()` | 211 | `getifaddrs` 取 en0 优先的非回环 IPv4 |
| `init(_:)` | 254 | `ConnectionContext` 构造 |
| `handle(_:)` | 257 | 起连接 + 300s 兜底取消 + 计一次接收 |
| `receive(_:)` | 267 | 64KB 递归读，直到 done/complete |
| `consume(_:_:)` | 286 | 头解析 → 建 body 临时文件 → 写 body → 凑满即 `finish` |
| `parseHead(_:_:)` | 316 | 请求行 + 头字典 + `content-length` |
| `writeBody(_:_:)` | 335 | 只写剩余需要的字节 |
| `finish(_:)` | 343 | 关句柄 + 路由 |
| `route(_:)` | 353 | 校验 `/s/<token>` 前缀（否则 403）+ 查询串解析 + 路由表 |
| `onMain(_:)` | 402 | 后台读主线程 `@Published` 数组的桥（`DispatchQueue.main.sync`） |
| `listPayload()` | 407 | 列表 JSON |
| `handleUpload(_:)` | 421 | multipart 解析 → 逐个写临时文件 → 主线程 `addUploads` |
| `handleDownload(_:id:)` | 464 | 全量读文件 + `Content-Disposition`（RFC 5987） |
| `handleDelete(_:id:)` | 490 | 主线程 `remove` |
| `cleanupBody(_:)` | 504 | 删 body 临时文件 |
| `respond(_:status:json:)` | 511 | JSON 响应 |
| `respond(_:status:html:)` | 516 | HTML 响应 |
| `respond(_:status:text:)` | 520 | 文本响应 |
| `respond(_:status:data:contentType:)` | 524 | 统一响应（状态码 → reason） |
| `send(_:_:)` | 546 | 发送后 cancel（一请求一连接） |
| `errorPage(_:detail:)` | 554 | 内嵌错误页 |
| `boundary(from:)` | 751 | 从 Content-Type 取 boundary（去引号） |
| `files(in:boundary:)` | 763 | 从文件 URL（mapped）解析 |
| `files(in:boundary:)` | 768 | 从 Data 解析：按 `--boundary` 切段，记录正文偏移/长度（**不复制正文**） |
| `filename(fromHeaderData:)` | 803 | `filename*=UTF-8''` 优先，其次 `filename="…"` |
| `sanitize(_:)` | 828 | 取 lastPathComponent + 替换 `/`/`:` + 截 120 字 |
| `write(_:from:to:)` | 838 | 按偏移/长度用 `Darwin.write` 循环落盘（不整段进内存） |

**散文（自写 HTTP 的关键约束）**
- **必须"先读完管道再等退出"**：`handleUpload` 里 body 是先落到临时文件、`MultipartParser` 再 mapped 解析——如果先 `readDataToEndOfFile` 前 `waitUntilExit`，子进程可能因管道写满而卡死（同类问题在 `TransferDockService.runBridge` 里也踩过）。
- **一次请求一个连接**（`Connection: close`）：不支持 keep-alive，也不支持 Range/分块下载，所以 `handleDownload` 必须把整个文件读进内存。
- **主线程数组访问**：`LocalTransferStore.items` 是 `@Published`，后台直接读会拿到撕裂快照，所以 `onMain` 用 `main.sync` 包了一层。代价是网络回调线程会阻塞等主线程（主线程卡住时所有连接一起卡）。
- token 只有 **4 位**（约 32^4 ≈ 100 万组合），且路径前缀完全靠它做授权。同网段扫描 `http://ip:8787/s/xxxx/` 的成本很低——这是"防手滑"级别，不是"防攻击"级别。

### 3.8 LocalTransferStore.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 107 | 读索引 + 清幽灵条目 |
| `load()` | 116 | 解码并按 `addedAt` 倒序 |
| `persist()` | 125 | 原子写 index.json |
| `pruneMissing()` | 131 | 暂存文件被 Finder 删掉后同步剔除 |
| `add(urls:)` | 143 | 逐个建目录 → `stage` → 记元数据；失败收集原因；成功插队 + 通知 |
| `autoStage(urls:)` | 197 | 只对白名单扩展名，且同原始路径已存在则跳过 |
| `addUploads(_:source:)` | 218 | 手机上传：`moveItem` 失败则 `copyItem`+删源 |
| `stage(from:to:)` | 260 | 目录 → symlink；文件 → hardlink 失败降级 copy |
| `sizeOf(_:)` | 285 | 目录返回 0 |
| `remove(_:)` | 293 | 只删暂存目录，**不动原文件** |
| `clearAll()` | 303 | 逐个删暂存目录 + 清索引 |
| `reveal(_:)` | 313 | Finder 选中 |
| `open(_:)` | 317 | 系统打开 |
| `openStagingFolder()` | 321 | 打开暂存根目录 |

**散文（`LocalTransferPaths` 为什么是独立 enum）**
- 注释记录了真实崩溃：旧实现 `stagedURL` 走 `LocalTransferStore.shared.stagingRoot`，而单例 `init` 里 `pruneMissing()` 又读 `stagedURL` → `dispatch_once` 重入 → SIGTRAP（面板一开就崩）。现在路径抽成纯静态 `LocalTransferPaths.root`，任何地方都能安全读，不触发单例初始化。

### 3.9 MCPServer.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 35 | 单例（默认端口 8767） |
| `start()` | 39 | 8767 起试 8 个 |
| `bind(port:)` | 50 | 建 listener + 信号量等 ready |
| `stop()` | 80 | cancel |
| `handle(_:)` | 89 | 起连接 |
| `receive(_:buffer:)` | 94 | 读到 header 结束 + `content-length` 满 |
| `contentLength(in:)` | 117 | 取头 |
| `send(_:status:json:)` | 124 | JSON 响应（带 `Access-Control-Allow-Origin: *`） |
| `respond(_:request:body:)` | 131 | `GET` → health；否则按 JSON-RPC method 分发（initialize/initialized/ping/tools/list/tools/call） |
| `arg(_:)` | 215 | 取字符串参数（内部 func） |

> CSV 漏采 `toolDefinitions`（181，静态计算属性）、`tool(_:_:_:required:)`（204）、`call(name:args:completion:)`（213）。

**散文（MCP 的安全边界）**
- 只监听 `127.0.0.1`（注释如此，代码同样未显式设置 `requiredLocalEndpoint`——依赖 NWListener 默认绑定，见 7.3）。
- `adb_shell` 工具直接执行任意 `adb shell <cmd>`：任何本机进程（包括浏览器里的恶意页面，因为有 `Access-Control-Allow-Origin: *`）都能调用它。**CORS 全开 + 无 token** 是本模块最锋利的一处。
- 默认关闭（需在投屏页手动开），这是唯一缓解。

### 3.10 QRCodeView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `make(from:size:)` | 19 | `CIFilter.qrCodeGenerator`（纠错 M）→ 缩放到目标点数 |

### 3.11 TransferCastEngines.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `warmUp()` | 54 | 后台预热 `NSSharingService`（首次实例化初始化 AWDL 要 1–3s） |
| `send(urls:relativeTo:)` | 64 | 先 `NSApp.activate` 再 0.12s 后 `perform`（nonactivating 面板不激活时系统面板不出现） |
| `start()` | 103 | `AirDropReceiveWatcher` 启动（**全在后台队列**：枚举 Downloads + open 目录，v105 卡死 236s 的根因） |
| `stop()` | 128 | 取消 source |
| `scan()` | 135 | 扫新落盘的完整文件（跳过 `.download` / 隐藏文件），0.4s 稳定等待后回调主线程 |
| `findScrcpy()` | 161 | 4 个固定路径 + `which scrcpy` |
| `findADB()` | 187 | 4 个固定路径（含 `~/.local/bin/adb`） |
| `connectedDevices(completion:)` | 201 | `adb devices` 后台执行 + 解析 |
| `startMirror(serial:maxSize:bitRateMbps:)` | 228 | 组装 scrcpy 参数（画质 + 剪贴板）并 `run` |
| `clipboardArguments()` | 273 | 开 → 能显式传就传 `--clipboard-autosync`，否则不传；关 → `--no-clipboard-autosync` |
| `clipboardExplicitOnSupported()` | 285 | `scrcpy --help` 探测（缓存 10min） |
| `discoverServices(completion:)` | 322 | `adb mdns services` 解析 |
| `pair(host:port:code:completion:)` | 349 | `adb pair` |
| `connect(host:port:completion:)` | 357 | `adb connect` |
| `runADB(_:completion:)` | 365 | `ADBWirelessEngine` 的执行器（注入 `-s`） |
| `init()` | 426 | `PushProgress` 默认值 |
| `push(urls:remoteDir:completion:)` | 401 | 简单版推送（无进度） |
| `push(urls:remoteDir:progress:completion:)` | 456 | 带进度推送（算总字节 + 起 tracker） |
| `pushOne(...)` | 479 | 单文件推送：起 `adb push` 后**每 0.7s 轮询手机端文件大小**换算进度 |
| `remoteFileSize(adb:serial:path:)` | 555 | `adb shell stat -c %s` |
| `speedHint(_:)` | 573 | 从 `… 38.2 MB/s` 抽速率 |
| `parsePercent(_:)` | 579 | 从 `[ 42%]` 抽百分比（**当前未被使用**） |
| `runADBPush(...)` | 587 | 逐个推送 + 拼日志（简单版的递归） |
| `pull(remoteDir:into:completion:)` | 608 | 先清空 staging 再 `adb pull dir/.` |
| `runADB(_:completion:)` | 634 | `ADBFileBridge` 的执行器（注入 `-s`） |

**散文（进度条为什么改成"轮询手机端文件大小"）**
- 原实现解析 `adb push -p` 的 stderr `[ 42%]`。实测（v122）：**adb 在管道（非 tty）里不输出百分比**，只在结束时给一行 `1 file pushed … 38.2 MB/s`。
- 现在每 0.7s 跑一次 `adb shell stat -c %s <remote>`：代价是每个 tick 起一个 adb 进程（一次 push 会产生几十次进程启动），但能得到真实进度与速率/ETA。
- `parsePercent` 是这次改造留下的死函数。

### 3.12 TransferDockLoginView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `makeNSView(context:)` | 60 | 桌面 UA 加载 `cloud.heytap.com/.../transfer-dock`，起轮询 |
| `updateNSView` | 74 | 空实现 |
| `dismantleNSView(_:coordinator:)` | 76 | 停轮询（生命周期与登录页绑定） |
| `makeCoordinator()` | 80 | 建 coordinator |
| `startPolling(webView:)` | 97 | 1.2s 重复 Timer 查 cookie |
| `stopPolling()` | 110 | 失效 Timer |
| `checkCookies()` | 115 | 命中 `OCLOUD_ACCESS_TOKEN` + `HASLOGIN` → 交回 cookie 并停轮询 |
| `webView(_:didFinish:)` | 129 | 进度文案 |
| `webView(_:didFail:withError:)` | 133 | 失败文案 |

### 3.13 TransferDockPreferences.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `isOn(_:default:)` | 37 | 未设置时按默认（默认 true），避免升级后功能消失 |
| `arguments()` | 83 | 组装 scrcpy 画质参数（统一入口） |

### 3.14 TransferDockService.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `init` | 89 | 单例 |
| `startLiveSync()` | 92 | 30s Timer（`.common`），回调进 `autoreleasepool`；幂等 |
| `stopLiveSync()` | 104 | 失效 |
| `startKeepAlive()` | 111 | 300s Timer，只在已登录时打 `keepalive` |
| `refresh()` | 139 | 后台 `status` + `list 1 200`；两条桥接都在 `autoreleasepool` 里 |
| `upload(url:)` | 201 | 单文件上传 + 刷新 |
| `uploadBatch(_:)` | 224 | 逐个上传 + 统计成功/失败 + 一次刷新 |
| `download(_:)` | 257 | 下载并 reveal |
| `delete(_:)` | 279 | 删除 + 刷新 |
| `saveCookies(_:)` | 300 | 过滤 heytap/oppo 域 → 写 `cookies.json`（数组格式）→ 标记登录 + 起保活 |
| `runBridge(_:)` | 338 | 起 `python3 frset_bridge.py <args>`；先读空管道再等退出；10 分钟兜底 terminate；取**最后一行** JSON |

**散文（桥接子进程的两个坑）**
- 读管道顺序：`readDataToEndOfFile` 在 `waitUntilExit` **之前**。反了就会"子进程因管道写满而卡死，父进程等子进程退出"的经典死锁。
- 只取 stdout 的**最后一行** JSON：中间会有懒续期日志（走 stderr），但网关偶尔也会往 stdout 掺日志。若最后一行不是 JSON，循环会往前找——`for line in reversed()` 保证了鲁棒性。
- 每条命令一个 Python 进程（含解释器启动 ~80–150ms）。30s 轮询 + 300s 保活 = 常驻开销可忽略，但每次刷新是 `status` + `list` 两次进程启动。

### 3.15 TransferDockSettingsPane.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `applyPort()` | 287 | 校验 1024–65535 → 写偏好 → `lan.restart()` |
| `chooseBridgeFolder()` | 300 | 选目录 → 写 `TransferDockPath.root` → 重判可用性 |
| `copy(_:)` | 317 | 复制直传链接 |
| `notifyChange()` | 323 | 发 `transferDockSettingsDidChange` |

### 3.16 TransferDockView.swift

| 函数名 | 行 | 说明 |
|---|---|---|
| `segmentPill(_:icon:index:)` | 143 | 三段切换胶囊 |
| `sendChip(_:icon:help:action:)` | 239 | 发送出口 chip（等宽单行） |
| `sendableURL(_:)` | 269 | 优先暂存路径（原文件可能已删） |
| `stagedSelection()` | 276 | 勾选且真实存在的 URL 列表 |
| `addFilesToStaging()` | 283 | NSOpenPanel 多选（含目录）→ `local.add` |
| `sendViaAirDrop()` | 295 | 空投发送 |
| `sendViaADB()` | 304 | 带进度的 ADB 推送 |
| `sendViaBrowser()` | 333 | 生成定向二维码 |
| `openUploadQR()` | 413 | 不带 pick 的分享链接（可反向上传） |
| `openSettings()` | 510 | 打开设置「文件中转」页 |
| `runTransferProbe()` | 516 | 排障探针（`probe.transfer=preview|select`） |
| `copyLink(_:)` | 622 | 复制直传链接 |
| `smallAction(_:icon:action:)` | 628 | 描边小按钮 |
| `installAPK()` | 731 | 选 APK → `ADBExtrasEngine.installAPK` |
| `pushStagedToPhone()` | 747 | 推送全部暂存项 |
| `pullFromPhone()` | 765 | 拉取手机目录 → 再 `add()` 入索引 |
| `refreshCloudLogin()` | 787 | 跑 `extract_edge_cookies.py` 从 Edge 取 cookie |
| `toggleSelect(_:)` | 1062 | 勾选切换 |
| `showPickQR()` | 1072 | 勾选后**此时才**启动服务并生成 `?pick=ids` 二维码 |
| `stopServiceIfStartedForTransfer()` | 1095 | 只停"为传输而启动"的服务 |
| `pushSelectedToCloud()` | 1102 | 批量上传云端 |
| `removeSelected()` | 1115 | 批量移出 |
| `pickOverlay(_:)` | 1122 | 定向二维码弹层 |
| `localCard(_:)` | 1219 | 本地暂存卡（包成 Equatable 行） |
| `dropHint(_:)` | 1258 | 拖放提示遮罩 |
| `urls(from:completion:)` | 1275 | `NSItemProvider` → URL（DispatchGroup + 锁） |
| `handleLocalDrop(_:)` | 1297 | 拖入暂存 |
| `handleCloudDrop(_:)` | 1305 | 拖入云端 |
| `pickAndUpload()` | 1320 | 选文件上传云端 |
| `iconName(for:)` | 1537 | 扩展名 → SF Symbol |
| `fileTint(for:)` | 1550 | 扩展名 → 主题色 |
| `miniButton(_:help:action:)` | 1566 | 行内 14×14 图标按钮 |

**散文（本文件的结构债）**
- 1577 行里存在**三个已不被渲染的旧区块**：`lanCard`（545）、`airDropSection`（646）、`adbFileSection`（692）。v119 把页面改成「发送/接收/云端」三段后，这三块没有任何调用方（`airDropSection`/`adbFileSection` 只在旧版本 body 里用过），但仍编译进包。
- `@Stored` 用了 14 次（hover/勾选/进度/折叠/tab），全部是"用 UserDefaults 存瞬时 UI 状态"的兼容层（因为本工程 `@State` 宏不可用）。瞬时状态落 UserDefaults 会带来不必要的磁盘写。
- v128 把 hover 态下沉到 `CloudRowView` / `LocalCardRowView` 两个 Equatable 行视图——原实现 hover 一动就重算整个 body（200 行云列表 × 图标匹配 + 格式化 + 视图树重建）。

---

## 4. 关键数据流

### 4.1 拖文件进中转 → 空投出去

```
Finder 拖到「本地暂存」区
  → onDrop → urls(from:) → handleLocalDrop
  → LocalTransferStore.add(urls:)
      ├─ 逐项建 <uuid>/ 目录
      ├─ stage(from:to:)：link(2) 硬链 / 目录 symlink / 跨卷 copy
      ├─ items.insert + persist(index.json)
      └─ post .localTransfer.didChange
  → 用户勾选 → selectedIDs
  → 「隔空投送」→ stagedSelection() → AirDropSendEngine.send
      ├─ NSApp.activate(ignoringOtherApps:)
      └─ 0.12s 后 NSSharingService.perform(withItems:)   [系统空投面板]
```

### 4.2 手机扫码接收（定向）

```
勾选文件 → 「通用互传」→ showPickQR()
  ├─ lan.startIfEnabled()（未运行则拉起）→ LanTransferServer.attemptBind
  │     └─ .ready: shareURL = http://<en0 IP>:<port>/s/<token>/
  └─ shareURL + "?pick=id1,id2" → pickShareURL → 弹层二维码
手机扫码 → GET /s/<token>/（内嵌 HTML，JS 解析 ?pick= → 只列这几个文件）
  → GET  api/list  → onMain { LocalTransferStore.items } → JSON
  → GET  dl/<id>   → handleDownload（全量读入内存）→ 手机下载
（无 pick 时页面还有上传卡）
  → POST api/upload（multipart，body 落临时文件）
  → MultipartParser.files → 逐段 Darwin.write
  → 主线程 LocalTransferStore.addUploads(move/copy)
  → post .localTransfer.didChange → UI 刷新
```

### 4.3 云端（OPPO 中转）

```
进「云端」tab → service.refresh()
  → queue.async → runBridge(["status"]) → python3 frset_bridge.py
       → 解析 loggedIn/leftSpace/totalSpace
       → runBridge(["list","1","200"]) → files
  → startLiveSync（30s 轮询；条件：loggedIn && !isLoading && !isUploading）
未登录 → 「登录」→ TransferDockLoginView（WKWebView）
  → cookie 轮询命中 OCLOUD_ACCESS_TOKEN + HASLOGIN
  → saveCookies → 写 credentials/cookies.json → startKeepAlive(300s)
上传：pickAndUpload / 拖入 / 勾选「加入云端」
  → service.upload / uploadBatch → runBridge(["upload", path])
```

### 4.4 投屏

```
投屏页 onAppear → findScrcpy + connectedDevices("adb devices")
  → hasDevice → 「开始投屏」
  → ScreenCastEngine.startMirror(serial:)
      └─ scrcpy --stay-awake --no-power-on [剪贴板参数] --max-size N --video-bit-rate NM --max-fps F --serial S
无线连接（折叠区）
  ├─ 「一键无线」→ enableWireless → adb tcpip 5555 → 2s → adb connect ip:5555
  ├─ 「扫描附近」→ AdbPairingService.scan → adb mdns services
  └─ 配对码 → adb pair ip:port code → adb connect ip:port
更多工具（展开才起 adb）
  ├─ 通知（6s 轮询 dumpsys notification）
  ├─ 存储（df + du）
  ├─ 应用（pm list packages -3）
  └─ 服务：MCPServer(8767) / AndroidWebDAVServer(8768)
```

---

## 5. 资源清单

### 5.1 子进程（本模块是重灾区）
| 进程 | 位置 | 频率 | 超时 |
|---|---|---|---|
| `/usr/bin/python3 frset_bridge.py` | `TransferDockService.runBridge` | 30s 轮询 + 每次操作 | 10 分钟兜底 terminate |
| `/usr/bin/python3 extract_edge_cookies.py` | `TransferDockView.refreshCloudLogin` | 手动 | 无（`waitUntilExit`） |
| `adb devices / mdns / pair / connect / disconnect` | `ADBWirelessEngine` / `AdbPairingService` / `ScreenCastEngine` | 按需 / 5s 缓存 | 无（`waitUntilExit`） |
| `adb shell …`（dumpsys/df/du/pm/input/statusbar/mkdir/rm/stat/ls） | `ADBExtrasEngine.run` | 6s 轮询 + 按需 | 默认 25s，逐调用覆盖（15–180s） |
| `adb push / pull` | `ADBFileBridge` | 按需 | push 无超时；pull 无超时 |
| `adb exec-out cat` | `AndroidWebDAVServer.download` | 每次 GET | 无 |
| `scrcpy`（长驻） | `ScreenCastEngine.startMirror` / `ADBExtrasEngine.startAppWindow` | 每次投屏一个 | 进程生命周期 |
| `scrcpy --help` | `clipboardExplicitOnSupported` | 缓存 10min | 无 |
| `which scrcpy` | `findScrcpy` | 每次调用（无缓存） | 无 |

### 5.2 定时器 / 轮询
| 资源 | 周期 | 条件 |
|---|---|---|
| `liveSyncTimer` | 30s | 中转页可见 + 已登录 + 不忙 |
| `keepAliveTimer` | 300s | 已登录 |
| `notifTick`（static Timer.publish） | 6s | 投屏页 + 工具区展开 + 有设备 |
| `PushProgress` 轮询 | 0.7s | 推送期间 |
| cookie 轮询 | 1.2s | 登录页存在 |
| 悬停预览 show/hide | 0.4s / 0.35s | 悬停 |
| `AirDropReceiveWatcher` 稳定等待 | 0.4s 单次 | 新文件 |
| 连接兜底取消 | 300s 单次 | 每个 HTTP 连接 |

### 5.3 网络
| 服务 | 端口 | 绑定 | 默认状态 |
|---|---|---|---|
| `LanTransferServer` | 8787（顺延 9 个） | 未显式限制 | 关闭（按需启动） |
| `MCPServer` | 8767（顺延 8 个） | 注释称 127.0.0.1 | 关闭 |
| `AndroidWebDAVServer` | 8768（顺延 8 个） | 注释称 127.0.0.1 | 关闭 |
| 出站 | — | — | `cloud.heytap.com`（WKWebView）+ 中转站 API（Python 侧） |

### 5.4 文件路径
- `~/Library/Application Support/FrsetNext/transfer-local/<uuid>/<name>`（暂存）
- `~/Library/Application Support/FrsetNext/transfer-local/index.json`
- `~/Library/Application Support/FrsetNext/TransferStaging/`（ADB pull 落地）
- `<TransferDockPath.root>/网页/scripts/frset_bridge.py`、`extract_edge_cookies.py`
- `<TransferDockPath.root>/credentials/cookies.json`
- `~/Downloads`（空投接收监听）
- `FileManager.temporaryDirectory/frset-lan-<uuid>.body`（HTTP body）、`frset-lan-up-<uuid>/`（上传落地）、`frset-webdav-<uuid>`（WebDAV 上传中转）
- 默认 `TransferDockPath.root` = `/Users/sunyiyang/Desktop/Project/temp/OPPO 中转站`（**硬编码开发者本机路径**）

### 5.5 UserDefaults 键
| 键 | 默认 |
|---|---|
| `transferDock.rootPath` | 上述硬编码路径 |
| `transferDock.cloud.enabled` | 未设置=true |
| `transferDock.lan.enabled` | 未设置=true |
| `transferDock.lan.port` | 8787（1024–65535 之外回落默认） |
| `transferDock.lan.token` | 4 位随机 |
| `transferDock.autoStageClipboard` | 未设置=true |
| `cast.maxSize` / `cast.bitrate` / `cast.fps` | 1920 / 16 / 60 |
| `cast.clipboardAutoSync` | 未设置=true |
| `transferDock.previewSize.w` / `.h` | 320×240 |
| `probe.transfer` | 无（排障探针） |
| `Preferences.Keys.panelTransferDock` | 面板入口显隐 |

### 5.6 通知
- `.localTransferDidChange`（`frset.localTransfer.didChange`）
- `.transferDockSettingsDidChange`（`frset.transferDock.settingsChanged`）
- `.frsetAirDropFiles`（`frset.airDropFiles`，跨模块请求空投，userInfo `urls`）
- `NSWindow.didEndLiveResizeNotification`（预览面板记住尺寸）

### 5.7 单例
`TransferDockService.shared`、`LocalTransferStore.shared`、`LanTransferServer.shared`、`AdbPairingService.shared`、`MCPServer.shared`、`AndroidWebDAVServer.shared`、`AirDropReceiveWatcher.shared`、`FileHoverPreviewController.shared`。

---

## 6. 不变量与陷阱

1. **主线程不得枚举目录 / 起 adb / 起 python**。v105 实锤：`AirDropReceiveWatcher.start` 在主线程 `contentsOfDirectory` + `open(dir)`，`~/Downloads` 被同步盘挂起时**整个 App 冻结 236 秒**。现在所有目录枚举、`Process` 启动、`waitUntilExit` 都在后台队列。
2. **读管道必须在 `waitUntilExit` 之前**（`runBridge` / `runADB`）。反了会死锁。
3. **`LocalTransferPaths` 必须是纯静态**，不能走单例属性——否则 `dispatch_once` 重入 SIGTRAP（面板一开就崩）。
4. **暂存只删链接/副本，绝不删原文件**（`remove`/`clearAll` 只碰 `<uuid>/` 目录）。
5. **`activeSerial` 5s 过期**：过期后每个 adb 命令都会多跑一次 `adb devices`。
6. **pair/connect/disconnect/mdns 不能带 `-s`**（host 级命令）——`AdbPairingService` 与 `ADBWirelessEngine` 的差异点。
7. **隔空投送前必须 `NSApp.activate`**，且在 nonactivating 面板上要异步 `perform`，否则系统面板不出现。
8. **HTTP 服务一次请求一连接**：不支持 keep-alive/Range，下载必须全量入内存。
9. **`LocalTransferStore.items` 只能主线程读**（`@Published` 数组），后台必须 `onMain { }`。
10. **lan token 只有 4 位**，纯"防手滑"级别授权。
11. **`TransferDockPath.isAvailable` 只要 bridge 脚本**或**cookie 文件**之一存在即为 true**——桥接脚本缺失但 cookie 存在时，UI 会显示云端区块但所有操作都会失败。

---

## 7. 重复实现 / 死代码 / 风险

### 7.1 重复实现
| 项 | 说明 |
|---|---|
| **四份 adb 执行器** | `ADBExtrasEngine.run`（带 25s 轮询超时 + `-s` 智能注入）、`ADBWirelessEngine.runADB`（注入 `-s`，`waitUntilExit` 无超时）、`ADBFileBridge.runADB`（注入 `-s`，无超时）、`AdbPairingService.runADB`（**不注入** `-s`，无超时）、`AndroidWebDAVServer.download`（自己起 `exec-out cat`）。同一件事五种写法、超时策略不一致。 |
| **两套无线发现/配对** | `ADBWirelessEngine.discoverServices/pair/connect` 与 `AdbPairingService.scan/pair/connect` 逻辑几乎相同，后者多了状态机。`ADBWirelessEngine.pair/connect` 带 `-s` 实际上是错的（host 级命令），属已知瑕疵。 |
| **三套 scrcpy 参数组装** | `TransferDockPref.CastQuality.arguments()`（未被调用）、`ScreenCastEngine.startMirror`（内联组装）、`ADBExtrasEngine.startAppWindow`（内联组装）。 |
| **三处"文件类型 → 图标/颜色"映射** | `TransferRowStyle.iconName`、`TransferRowStyle.fileTint`、`FileHoverPreviewView.iconName`、`FilePreviewBuilder.kindLabel`——四份扩展名 switch。 |
| **两份 ByteCount/DateFormatter 缓存** | `TransferDockFile` 一套、`LocalTransferItem` 一套（同样的 v126 优化各做一遍）。 |
| **两台 HTTP 服务器** | `LanTransferServer` 与 `AndroidWebDAVServer` / `MCPServer` 各自手写 HTTP 解析（header 查找、content-length、响应拼装）。 |

### 7.2 死代码
- `TransferDockView.lanCard`（545）、`airDropSection`（646）、`adbFileSection`（692）：v119 改版后无调用方。
- `ADBFileBridge.parsePercent`（579）：改成轮询手机端大小后不再使用。
- `TransferDockPref.CastQuality.arguments()`（83）：无人调用（`startMirror` 自己拼）。
- `ADBWirelessEngine.pair/connect`：被 `AdbPairingService` 取代，但仍留在编译单元里。
- `TransferDockService.spaceRatio`：只在 `spaceBar` 用；`TransferDockService.lastSyncedAt` 只在状态行用（正常使用）。
- `LocalTransferStore.autoStage` 的调用方在剪贴板模块（跨模块），若那边没接线则本方法也是死的——需在 Clipboard 侧核对。

### 7.3 风险（按危险度）
1. **`MCPServer` 的 `adb_shell` + `Access-Control-Allow-Origin: *` + 无 token**（高）：默认关闭，但一旦用户打开，本机任意网页都能通过 `fetch('http://127.0.0.1:8767/mcp')` 执行 `adb shell`（等于任意 shell 命令）。
2. **三个 HTTP 服务均未显式绑定 127.0.0.1**（高，需实测确认）：`NWParameters.tcp` + `NWListener(using:on:)` 默认监听**所有接口**。注释写"只绑局域网/只绑本机"，代码里没有任何 `requiredLocalEndpoint`。若真的对外监听，`LanTransferServer`（4 位 token）与 `MCPServer`（无鉴权）都会暴露到局域网。
3. **`AndroidWebDAVServer.download` 全量读入内存**（高）：挂载 Finder 后打开一个 2GB 视频 → OOM。
4. **`TransferDockView` 里 `refreshCloudLogin` 用 `waitUntilExit()` 无超时**（中）：Edge cookie 提取脚本卡住会永久占用一个全局队列线程。
5. **`findScrcpy()` 每次都起 `which` 子进程**（中）：投屏页/每次启动镜像/每次剪贴板探测都会多一个进程；`clipboardExplicitOnSupported` 有 10min 缓存，`findScrcpy` 没有。
6. **`ADBFileBridge.pushOne` 每 0.7s 起一个 `adb shell stat`**（中）：一次大文件 push 会起几十上百个进程，且这些 stat 与 push 共用同一条 adb 通道，可能反过来拖慢传输。
7. **`LocalTransferItem.mode == .upload` 时 `originalPath` 指向已删除的临时文件**（低-中）：`originalPath` 语义在 upload 模式下是错的（指向 `tempURL`），只是当前 UI 没读它。
8. **lan token 4 位**（中）：同网段穷举成本极低。
9. **`TransferDockPath.root` 硬编码开发者本机绝对路径**（中，发布风险）：首次运行若用户没改路径，`isAvailable` 为 false → 云端区块消失（可接受），但错误提示会暴露该路径。
10. **`TransferDockView` 14 个 `@Stored` 承载瞬时 UI 状态**（低）：折叠/悬停/进度全落 UserDefaults，频繁写盘。
11. **`LocalTransferStore.add` 在主线程做 `linkItem`/`copyItem`**（中）：拖入大批文件（尤其是跨卷拷贝几个 GB）会卡住 UI——`add` 没有后台化。
12. **`LanTransferServer.onMain` 用 `main.sync`**（中）：主线程一旦卡住（比如上面第 11 条），所有 HTTP 连接一起阻塞直到 300s 兜底取消。
