# LinkSwift 接入方案（FrsetNext）

> 调研对象：https://github.com/hmjz100/LinkSwift（v1.1.3，584 KB 单文件 UserScript，AGPL-3.0）
> 结论：**解析层必须在网盘页面的真实上下文中运行脚本；UI 与下载层用原生实现。**

## 一、LinkSwift 是什么（调研结论）

| 项 | 结论 |
|---|---|
| 形态 | 油猴 UserScript（`@run-at document-start`），IIFE 封闭，**无 window 暴露、无 postMessage/URL 触发** |
| 支持 | 百度 / 阿里（aliyundrive+alipan）/ 移动云盘(139) / 天翼(189) / 迅雷 / 夸克 / UC / 123 云盘（8 家，17 个域名） |
| 核心资产 | 每家的 `config.$xxx.api.getLink` 直链端点 + 分享页取链流程（getShareSign/getShareFiles/verify） |
| 取链依赖 | **页面运行时上下文**：夸克 `unsafeWindow.factStat.ut.baseParams.pwd_id`、百度 `bdstoken`+`localStorage[${surl}_pwd]`、迅雷页面 SDK `token.credentials`、阿里页面 token —— 纯 API 复刻不可行 |
| 触发方式 | 向网盘页面 DOM 注入按钮（`.mount` 选择器），点击 → 取链 → SweetAlert2 面板（API 下载 / 复制 / aria2 / IDM / ABDM / 比特彗星） |
| 下载 UA | 每家固定：百度 `pan.baidu.com`（>50MB 直链必须）、夸克 `quark-cloud-drive/3.20.0 ...` —— **原生下载必须按网盘设置 UA** |
| 依赖 | jQuery 3.6.0 / SweetAlert2 11.4.8 / js-md5 / js-sha256（均 unpkg CDN） |

## 二、接入架构（三层解耦）

```
┌─ Layer 1 识别与 UI（原生，零依赖）────────────────────────┐
│ CloudDriveLinkDetector：17 域名表 + URL 提取               │
│ 剪贴板入库 → 命中 → 标记 isCloudLink                       │
│ 首页搜索框下方 CloudLinkBar：网盘图标 + 分享页标题 + 解析   │
│ 预览弹层：URL 可点击（网盘链接 → 解析；普通链接 → 浏览器）  │
└──────────────────────┬───────────────────────────────────┘
                       │ 点击「解析下载」
┌─ Layer 2 解析（WKWebView + 注入脚本）──────────────────────┐
│ CloudLinkResolver：WKWebView(websiteDataStore=.default())  │
│  · 加载分享页（登录态持久，复用 TransferDock 模式）         │
│  · 注入 LinkSwift（app 内置资源）+ Bridge 小脚本           │
│  · Bridge：MutationObserver 监听脚本弹出的下载面板，       │
│    抓取直链/文件名 → WKScriptMessageHandler → 原生        │
│  · 超时/失败 → 回退：打开系统浏览器 + 提示                 │
└──────────────────────┬───────────────────────────────────┘
                       │ 直链 + UA + 文件名
┌─ Layer 3 下载（原生 URLSession）───────────────────────────┐
│ DownloadCenter：队列/进度/取消/断点，按网盘 UA 发请求      │
│ 保存 ~/Downloads/FrsetNext；完成后可选中/在 Finder 显示    │
└──────────────────────────────────────────────────────────┘
```

## 三、UI 落点（按你的要求）

1. **首页搜索框下方**：`PanelRootView.homePage` 中插入 `cloudLinkBar`
   `searchSection → CloudLinkBar（新）→ 12pt → calendarCard → clipboardSection`
   - **交互形态（2026-10-19 用户澄清，已实现）**：复制网盘链接 → 1s 轮询命中 → 链接条**自动弹出**（顶部滑入 + 淡入 + 一次轻脉冲），日历与下方列表**弹簧平滑下移**；平时完全不占位（无链接零高度）
   - 只认**最近 3 条**剪贴板（避免旧链接长期占位，突出刚复制的那条）
   - 右侧按钮：`[打开]`（浏览器）`[解析下载]`（P1 解析器）`[×]`（同链接不再弹，换新链接才重现）
   - 实测对比：`apps/FrsetNext/Resources/Manual/shots/cloudlink-before.png` / `cloudlink-after.png`
     （v268 去重后真机截图只保留 App 资源目录这一份）
2. **剪贴板自动识别**：`ClipboardManager` 入库时对 text 类型跑 `CloudDriveLinkDetector.detect`，结果缓存（不改 DB schema，运行时派生）
3. **预览中可点击**：`PreviewPopoverContentView` 文本预览改用 `AttributedString` 链接化；网盘链接点击 → `CloudLinkResolver.present(url)`；普通链接 → `NSWorkspace.open`
4. **下载进度**：CloudLinkBar 展开态显示进度条（复用 TransitDock 的下载卡片样式）

## 四、关键实现要点

### 4.1 域名表（从 @match 提取，17 主机）
```
pan.baidu.com / yun.baidu.com / www.aliyundrive.com / www.alipan.com
yun.139.com / caiyun.139.com / cloud.189.cn / pan.xunlei.com
pan.quark.cn / drive.uc.cn / *.123pan.com / *.123pan.cn
*.123684.com / *.123865.com / *.123952.com / *.123912.com
```
分享页判定：路径含 `/s/`（阿里/夸克/UC/123/百度 `/s/`）或 `/share/`（百度）。

### 4.2 注入与抓链（Layer 2 的脆弱点）
- LinkSwift 无程序化入口 → 注入 Bridge：
  1. `WKUserScript` 注入 LinkSwift（`forMainFrameOnly: false`，文档开始）
  2. 注入 Bridge：`MutationObserver` 监听 `.swal2-popup`（SweetAlert2 面板）出现；从面板内 `a[href]`、`input.value`、`textarea` 提取 `http(s)` 直链 + 文件名；`window.webkit.messageHandlers.fsCloudLink.postMessage({...})`
  3. 原生收到 → 结束 WebView → 下载
- 面板 DOM 改版会断 → 需「更新脚本」入口（从 GitHub raw 拉最新 `.user.js` 覆盖内置资源）
- 未登录时脚本可能只显示「保存到网盘」→ Bridge 检测「无直链」→ 回退提示「请先在解析窗登录网盘账号」

### 4.3 下载 UA 表（从 config.ua.downloadLink 提取）
| 网盘 | 下载 UA |
|---|---|
| 百度 | `pan.baidu.com` |
| 夸克 | `Mozilla/5.0 ... quark-cloud-drive/3.20.0 ...` |
| 其他 | 默认 UA（脚本 `enhance` 说明不强制） |

### 4.4 合规
- LinkSwift 为 AGPL-3.0：内置分发须保留版权声明与源码获取入口（app 内「关于 → 开源许可」注明）
- 仅调用网盘公开 API，不破解限速；UI 文案不出现「加速/破解」类表述

## 五、分期与工作量

| 期 | 内容 | 交付 |
|---|---|---|
| **P0（先做，纯原生）** | ✅ **已完成（2026-10-19）**：`CloudDriveLink.swift` 检测器（17 域名/8 网盘/分享页判定）+ `CloudLinkBar.swift` 首页条（搜索框正下方）+ 预览底部 `CloudLinkPreviewAction`（复制/打开/解析）+ `CloudLinkActions.resolve` 入口桩 | 实测截图 `apps/FrsetNext/Resources/Manual/shots/panel-cloudlink-p0.png` |
| **P1（核心）** | WKWebView 解析器 + Bridge 抓链 + 原生下载（UA/进度/保存） | 端到端：分享链接 → 直链 → 本地文件 |
| **P2** | 登录态管理（各网盘首次登录引导）、脚本在线更新、失败回退、多链接队列 | 稳定可用 |

## 六、风险清单

1. **登录态**：8 家网盘各自登录，首次使用成本高（P2 提供引导）。
2. **脚本时效**：网盘 API 常变（LinkSwift 更新频繁），内置版本会过期 → 必须提供更新入口。
3. **抓链脆弱**：依赖 SweetAlert2 面板 DOM；改版即断，需回退到「打开页面手动操作」。
4. **大文件**：百度 >50MB 直链必须 UA=`pan.baidu.com`，否则 403；必须在下载层强制。
5. **合规**：AGPL 声明 + 不宣传加速。
