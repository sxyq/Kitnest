import SwiftUI
import AppKit

/// 应用入口（菜单栏常驻应用：LSUIElement=1，不显示 Dock 图标）
@main
struct FrsetNextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // 主界面由各模块自管理窗口（面板/设置/截图选区等），这里只保留一个空场景。
        // v85（2026-10-20 设置页卡死根因）：此前 `Settings { Color.clear.frame(1,1)
        // .onAppear { 转发到自管窗 + 收掉 SwiftUI 空窗 } }`——**两个设置窗同时存在并
        // 同时布局**（SwiftUI Settings scene 的空窗 + 自管 NSHostingView 窗），
        // 实测 sample 栈：NSWindow layoutIfNeeded → 多层 _layoutSubtreeWithOldSize
        // → NSHostingView.layout → GeometryReader 读 size → 再触发 layout，主线程死循环。
        // 现改为：scene 只放 EmptyView（不转发、不创建内容），⌘, 用 commands
        // 直接指向自管设置窗——永远只有一个设置窗参与布局。
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    ServiceLocator.settings?.open(pane: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // v43：菜单栏监控「唯一一套」护栏——先于任何模块启动执行。
        // 菜单栏监控的唯一实现是 STATS 合并条；多开实例/官方原版同跑都会各画一套，
        // 表现为菜单栏出现重复的 CPU/RAM/SSD 组件（用户 2026-10-18 反馈）。
        guard enforceSingleMenubarOwner() else { return }

        // 不显示 Dock 图标（菜单栏应用）
        NSApp.setActivationPolicy(.accessory)
        // v259：上次异常退出可能留下被 SIGSTOP 的应用，先无条件唤醒再干别的
        ProcessFreezer.shared.thawOrphans()
        AppBootstrap.start()
        // v127（ArcZip P3）：注册 NSServices 服务提供者（访达右键「解压到此处/解压到…/压缩」）。
        // 服务项声明在 Info.plist 的 NSServices；selector 回调落到 ArchiveServicesProvider。
        NSApp.servicesProvider = ArchiveServicesProvider.shared
        NSUpdateDynamicServices()
        // v180：归档任务中心——任务开始时自动浮出右下角任务条（访达服务/创建面板/
        // 归档窗解压都走同一个队列，所以只在这里接一次）
        ArchiveTaskCenter.shared.start()
        Log.info("App", "启动完成")

        // 排障探针（2026-10-18）：FRSET_TOAST_PROBE=1 时启动 2s 后弹一条通知条，
        // 用于验证菜单栏通知条窗口在真机上确实可见（截图后"无提示"类问题的最小复现）。
        // 只在显式设置环境变量时执行，平时零开销、不打扰。
        if ProcessInfo.processInfo.environment["FRSET_TOAST_PROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Toast.show("提示条自检", icon: "checkmark.circle.fill")
            }
        }
    }

    /// 菜单栏监控「唯一一套」：STATS 合并条。
    ///
    /// 两道防线：
    /// 1. **同 bundle 多实例** → 新实例立即退出。每个进程都会 `StatsBarEngine.start()`
    ///    建一套合并条（同一个 NSStatusBar 上并列），菜单栏就出现重复组件。
    /// 2. **官方原版 Frset.app 在跑** → 原版的 STATS 注入引擎也会画一套合并条，且与本 app
    ///    共用 `~/Library/Application Support/FrsetStats/widgets.plist` 与 `engine.log`。
    ///    无法从进程内阻止它，因此只提示用户退出原版（避免误以为是我们重复创建）。
    private func enforceSingleMenubarOwner() -> Bool {
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != getpid() }
            if let existing = others.first {
                Log.info("App", "已有实例在运行（pid=\(existing.processIdentifier)）→ 本实例退出，保证菜单栏只有一套监控组件")
                existing.activate(options: [.activateIgnoringOtherApps])
                NSApp.terminate(nil)
                return false
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let originals = NSRunningApplication.runningApplications(withBundleIdentifier: "com.maoux.frset")
            guard !originals.isEmpty else { return }
            Log.info("App", "检测到官方原版 Frset 在运行：它的注入引擎会重复绘制一套菜单栏组件")
            Toast.show("官方原版 Frset 正在运行，会重复绘制一套菜单栏监控组件，建议退出原版",
                       icon: "exclamationmark.triangle.fill", isWarning: true)
        }
        return true
    }

    // v127（ArcZip P3）：退出前确认未完成归档任务（ArchiveTaskQueue 是 arch-engine 的
    // 公开类型，只读调用）——有未完成任务时弹确认框，「返回」则取消退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ArchiveTaskQueue.shared.confirmQuitIfNeeded() else { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // v259：退出前必须唤醒所有被暂停的应用，否则它们会一直挂着
        ProcessFreezer.shared.thawAll(reason: "退出")
        // v84：退出前把个性化防抖窗口内的改动立即落盘（否则 150ms 内退出会丢设置）
        Personalization.shared.flushPendingPersist()
        LogArchive.shared.stop()
        AppBootstrap.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ServiceLocator.panel?.show()
        return true
    }

    /// 程序化唤起入口：等价原版 `StatusBarController.showSettingsWindow:` 的 @objc
    /// 可调用能力。用法：open "kitnest://settings?pane=general"
    /// （pane: general/search/tools/shortcuts/about；缺省 general）
    /// 签名依据 macOS 13 SDK：ObjC 为 application:openURLs:（NSArray，10.13+），
    /// Swift renamed import 为 application(_:open:)，参数 [URL]。
    /// 满足 NSApplicationDelegate 该 optional 要求即自动生成 ObjC 入口（有 To 符号）。
    func application(_ application: NSApplication, open urls: [URL]) {
        // v167：访达双击 / 右键「用 Kitnest 打开」送来的是**文件 URL**（无 scheme 或 file），
        // 原实现第一行就 `guard url.scheme == "frsetnext"` 把它们全丢了 —— 所以此前
        // 双击压缩包只会唤起面板、不会进归档窗。这里先分流文件，再走深链。
        let files = urls.filter { $0.isFileURL }
        if !files.isEmpty {
            let archives = files.filter { ArchiveCore.isArchive($0) }
            for (idx, url) in archives.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(idx) * 0.05) {
                    ArchiveBrowserWindowController.show(url: url)
                }
            }
            if !archives.isEmpty { return }
            // v206（用户：「JSON 文件的那种预览是不是单独窗口……全部删掉」）：
            // JSON 检视器独立窗已删除，访达双击 JSON 不再开窗；剪贴板里的
            // JSON 仍旧在 hover 预览里内联展示（JSONInspectorView）。
        }
        guard let url = urls.first,
              url.scheme == "kitnest" || url.scheme == "frsetnext" else { return }
        Log.info("App", "URL 唤起: \(url.absoluteString)")
        // 窗口创建延后到下一 runloop：Apple Event 处理上下文内创建 NSWindow +
        // NSHostingView 会在 display cycle layout observer 中触发次级约束更新，
        // 导致 NSWindow._postWindowNeedsUpdateConstraints 异常（2026-10-16 实测：
        // 最小视图同样复现，与视图内容无关）。
        DispatchQueue.main.async {
            // v126（性能审计 F0023）：URLComponents 只解析一次——原实现每个分支各自
            // `URLComponents(url:resolvingAgainstBaseURL:)`，"panel" 分支一连解析 4 次
            // （每次都重做 scheme/host/query 切分），纯重复计算。
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            switch url.host {
            case "settings":
                let pane = comps?
                    .queryItems?.first(where: { $0.name == "pane" })?.value
                ServiceLocator.settings?.open(pane: pane)
            case "settingsprobe":
                // v264 排障：单独打开某个设置区块（?block=recording|workflow|capture）
                let block = comps?
                    .queryItems?.first(where: { $0.name == "block" })?.value ?? "recording"
                SettingsBlockProbeWindowController.shared.open(block: block)
            case "statistics":
                StatisticsWindowController.shared.openStatistics()
            case "monitor":
                // v74 深链：打开性能监测独立窗（部件点击/⌥P 的等价入口，便于排障）
                // v86：支持 kitnest://monitor?module=memory 直达指定模块（排障/截图验证用）
                let moduleRaw = comps?
                    .queryItems?.first(where: { $0.name == "module" })?.value
                let module = moduleRaw.flatMap(MonitorModuleID.init(rawValue:))
                MonitorPopoutWindowController.shared.open(module: module)
            case "longshot":
                // v74 排障/深链入口：直接进入长截图选区（等价 ⇧⌥L 与面板菜单「长截图」）
                LongScreenshotCoordinator.shared.beginSelection()
            case "capturebar":
                // v218 排障：直接弹出框选动作面板（拿一张主屏截图当预览），
                // 用来核对「预览在上 / 工具条在下 / 屏幕 1/4 高度居中」的版式。
                // v219：?expand=copyGroup 直接把某一组的子项浮层展开——
                // 悬停靠鼠标事件，无辅助功能授权时脚本点不出来。
                // 抓屏走后台（legacy API 在主线程会死锁，见 ScreenshotManager 头注）。
                let screenFrame = NSScreen.main?.frame ?? .zero
                let cgRect = NSScreen.main.map { ScreenSnapshot.cgRect(for: $0) } ?? .zero
                CaptureActionChain.debugExpandGroup =
                    comps?.queryItems?.first(where: { $0.name == "expand" })?.value
                Task.detached(priority: .utility) {
                    let image = ScreenSnapshot.cgCapture(rect: cgRect)
                    await MainActor.run {
                        guard let image else { return }
                        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "capturebar-demo.png")
                        if let data = ImageProcessor.pngData(image) {
                            try? data.write(to: url)
                        }
                        CaptureActionChain.present(image: image, url: url,
                                                   selectionAppKit: screenFrame)
                    }
                }
            case "longshotdemo":
                // v150 排障：固定选区直接起会话（无人值守验证 HUD / 预览）
                LongScreenshotCoordinator.shared.beginDemoSession()
            case "longshotfinish":
                LongScreenshotCoordinator.shared.finishCurrentSession()
            case "longshotcancel":
                LongScreenshotCoordinator.shared.cancelCurrentSession()
            case "longshotcard":
                // v181 排查：采集期实时预览卡（右侧/翻左/超宽三档），结果写 /tmp/livecard.txt
                let anchor = comps?.queryItems?.first(where: { $0.name == "anchor" })?.value ?? "center"
                LongScreenshotCoordinator.shared.runLiveCardCheck(anchor: anchor)
            case "tasks":
                // v181：压缩/解压任务队列（等于归档窗工具栏的「任务」按钮）
                ArchiveProgressWindowController.show()
            case "memcheck":
                // v259 排障入口：完整跑一次「深度释放」（暂停闲置 + 压力广播 + purge）。
                // ?freeze=0 只清缓存不冻结。结果写日志，不移动鼠标、不激活任何窗口。
                let freeze = comps?.queryItems?.first(where: { $0.name == "freeze" })?.value != "0"
                Task { await MemoryOptimizer.shared.optimize(freezeIdle: freeze) }
            case "memthaw":
                ProcessFreezer.shared.thawAll(reason: "排障入口")
            case "shelfprobe", "curtainprobe":
                // v261 排障：合成 N 张测试截图挂上图帘，打印窗口尺寸后自动清理。
                // 截图链路要人手框选，验收没法自动化，这个入口补上「排布/缩略图/自动收起」。
                // ?shot=1 时临时允许被抓屏（仅本次自检），用来肉眼验收渲染。
                let n = Int(comps?.queryItems?.first(where: { $0.name == "count" })?.value ?? "3") ?? 3
                let shot = comps?.queryItems?.first(where: { $0.name == "shot" })?.value == "1"
                let w = comps?.queryItems?.first(where: { $0.name == "w" })?.value.flatMap(Double.init)
                let sweep = comps?.queryItems?.first(where: { $0.name == "sweep" })?.value == "1"
                Task { @MainActor in
                    ImageCurtainController.shared.runProbe(count: n, capturable: shot,
                                                           cardWidth: w.map { CGFloat($0) },
                                                           sweep: sweep)
                }
            case "demo":
                // v264：手册配图专用直达入口。这些界面平时只能从按钮/菜单进，
                // 录屏脚本没法稳定点中（右键菜单不参与抓屏、欢迎窗只在首启弹），
                // 给一个确定性入口，录完即关。
                //   kitnest://demo?scene=welcome|beautify|recorder[&file=/tmp/x.png]
                let scene = comps?.queryItems?.first(where: { $0.name == "scene" })?.value ?? ""
                switch scene {
                case "welcome":
                    WelcomeWindowController.shared.show()
                case "beautify":
                    let path = comps?.queryItems?.first(where: { $0.name == "file" })?.value
                        ?? "/tmp/kitnest-demo.png"
                    if let img = ImageProcessor.cgImage(from: URL(fileURLWithPath: path)) {
                        BeautifyController.shared.show(image: img)
                    } else {
                        Log.warn("App", "demo beautify：图片不存在 \(path)")
                    }
                case "recorder":
                    StatsBarEngine.openRecorder()
                default:
                    Log.warn("App", "demo：未知场景 \(scene)")
                }
            case "manual":
                // v264：内置用户手册直达（设置 → 使用手册 的深链形式）
                ServiceLocator.settings?.open(pane: "manual")
            case "fileindex":
                // v264 排障：建立 / 查询全盘文件名索引，结果写日志。
                //   kitnest://fileindex?q=image%20html%20deck&build=1
                // build=1 强制重建（默认只加载缓存，没有才建）。
                let q = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? "image html deck"
                let force = comps?.queryItems?.first(where: { $0.name == "build" })?.value == "1"
                Task { @MainActor in
                    if force { FileNameIndex.shared.rebuild() } else { FileNameIndex.shared.ensureReady() }
                    var waited = 0
                    while waited < 300 {
                        switch FileNameIndex.shared.state {
                        case .ready(let count, _):
                            let t0 = CFAbsoluteTimeGetCurrent()
                            let hits = FileNameIndex.shared.search(q, limit: 8)
                            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                            Log.info("FileIndex", String(format: "探针就绪：%d 条 · 占用 %@ · q=「%@」命中 %d 条 · 耗时 %.1f ms",
                                                         count,
                                                         ByteCountFormatter.string(fromByteCount: FileNameIndex.shared.diskBytes, countStyle: .file),
                                                         q, hits.count, ms))
                            for h in hits { Log.info("FileIndex", "  → \(h)") }
                            return
                        case .failed(let m):
                            Log.info("FileIndex", "探针失败：\(m)")
                            return
                        default:
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            waited += 1
                        }
                    }
                    Log.info("FileIndex", "探针超时（5 分钟）")
                }
            case "clipdesk":
                // 悬浮剪贴板工作台（v191）：快捷键之外的确定性入口，排障/截图用
                // v202：支持 ?action=hide|toggle，便于验证「收起动画中重开」竞态
                switch comps?.queryItems?.first(where: { $0.name == "action" })?.value {
                case "hide": FloatingClipboardWindowController.shared.hide()
                case "toggle": FloatingClipboardWindowController.shared.toggle()
                default: FloatingClipboardWindowController.shared.show()
                }
            case "longshotpreview":
                // v150 排障：用合成 480×3600 长图打开预览（验等比缩放/初始位置）
                LongScreenshotDiagnostics.showPreviewDemo()
            case "longshotcheck":
                // v150 排障入口：用「合成长图 + 已知位移切片」回灌拼接器，
                // 校验画布尺寸/接缝/重复帧/向上滚动——不碰鼠标。
                LongScreenshotDiagnostics.runStitcherCheck()
            case "ocr":
                // v145 排障入口：跑一遍完整 OCR 链路（样张 → Vision → 本地 PP-OCR 复核），
                // 把两侧识别文本、耗时、内存都写进日志。不依赖鼠标，便于真机验收。
                OCRDiagnostics.runPipelineCheck()
            case "translate":
                // v146 排障入口：翻译链路自检（快速通道 / 当前引擎路由），同样不碰鼠标。
                TranslationDiagnostics.run()
            case "panel":
                // 先激活：主面板 windowDidResignKey → hide（transient 行为），
                // 不激活时窗口成为 key 后立即 resign 被自动关闭（2026-10-16 实证）
                NSApp.activate(ignoringOtherApps: true)
                // v73 排障入口：kitnest://panel?anchor=icon —— 用主图标实际 frame
                // 走锚点展开（验证「图标正下方 + 顶部三角」，等价左键点击路径）
                let anchorIcon = comps?
                    .queryItems?.first(where: { $0.name == "anchor" })?.value == "icon"
                // v74 深链：kitnest://panel?monitor=sensors——面板打开后直达性能页指定模块
                let monitorRaw = comps?
                    .queryItems?.first(where: { $0.name == "monitor" })?.value
                if let monitorRaw, let module = MonitorModuleID(rawValue: monitorRaw) {
                    MonitorCenterPresenter.shared.selectPerformance(module: module)
                }
                // 深链直达页面：kitnest://panel?page=transfer|cast|performance
                switch comps?.queryItems?.first(where: { $0.name == "page" })?.value {
                case "home":       MonitorCenterPresenter.shared.selectHome()
                case "transfer":   MonitorCenterPresenter.shared.selectTransferDock()
                case "cast":
                    MonitorCenterPresenter.shared.selectCast()
                    // v159 排障/自动化入口：kitnest://panel?page=cast&qr=1 —— 打开扫码弹层。
                    // 用途：① 无鼠标环境下验证弹层与重连链路；② 快捷指令一键唤起扫码。
                    if comps?.queryItems?.first(where: { $0.name == "qr" })?.value == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            NotificationCenter.default.post(name: .frsetOpenCastQR, object: nil)
                        }
                    }
                case "performance": MonitorCenterPresenter.shared.selectPerformance()
                default: break
                }
                if anchorIcon,
                   let anchor = StatusBarController.shared.mainStatusItem?.button?.window?.frame {
                    Log.info("App", "URL 锚点展开：icon frame=\(anchor)")
                    ServiceLocator.panel?.show(atAnchor: anchor)
                } else {
                    ServiceLocator.panel?.show()
                }
            case "annotate":
                // v100 视觉验收/排障深链：kitnest://annotate?file=/tmp/a.png&tool=m
                // 不经过截图流程直接打开标注编辑器，便于核对工具条与画笔马赛克。
                let path = comps?.queryItems?.first(where: { $0.name == "file" })?.value
                // ?tool=m / ?tool=highlighter / ?tool=mosaic —— 排障与自动化截图时直接落到指定工具
                let rawTool = comps?.queryItems?.first(where: { $0.name == "tool" })?.value?.lowercased()
                let tool = rawTool.flatMap { raw in
                    AnnotationTool.allCases.first {
                        $0.rawValue == raw || $0.shortcut.lowercased() == raw
                    }
                }
                let demo = comps?.queryItems?.first(where: { $0.name == "demo" })?.value == "1"
                if demo {
                    // v220：五个新标注工具的绘制验收（预置标注 + 写 /tmp/annot_newtools.png）
                    AnnotationEditorController.shared.debugNewToolsDemo()
                } else if let path, let img = ImageProcessor.cgImage(from: URL(fileURLWithPath: path)) {
                    AnnotationEditorController.shared.open(image: img, tool: tool)
                } else if !AnnotationEditorController.shared.openLatest() {
                    Log.warn("App", "标注深链：没有可打开的图片（可用 ?file= 指定）")
                }
            case "copyocr", "copytranslate":
                // v224 排障：这两个动作现在打开结果窗（不再自动复制），
                // 直接触发可以核对窗口内容与页签。
                let file = comps?.queryItems?.first(where: { $0.name == "file" })?.value
                if let file, let img = ImageProcessor.cgImage(from: URL(fileURLWithPath: file)) {
                    if url.host == "copytranslate" {
                        ScreenshotManager.shared.recognizeAndTranslate(img)
                    } else {
                        ScreenshotManager.shared.recognizeShowing(img)
                    }
                } else {
                    Log.warn("App", "\(url.host ?? "copyocr")：需要 ?file= 指定图片")
                }
            case "annotest":
                // v226：14 个标注工具逐项自检（合成器级，不依赖鼠标），
                // 结果写 /tmp/annot_selftest.txt + /tmp/annot_selftest.png
                let results = AnnotationSelfTest.run()
                let failed = results.filter { !$0.pass }
                Log.info("App", "标注自检：\(results.count - failed.count)/\(results.count) 通过"
                         + (failed.isEmpty ? "" : "，失败：\(failed.map(\.tool.rawValue).joined(separator: ","))"))
            case "ocrwin":
                // v223 排障：直接打开 OCR 结果窗，核对「标题 / 红绿灯 / 内容」的分层
                let file = comps?.queryItems?.first(where: { $0.name == "file" })?.value
                if let file, let img = ImageProcessor.cgImage(from: URL(fileURLWithPath: file)) {
                    Task { @MainActor in
                        let data = ImageProcessor.pngData(img) ?? Data()
                        let text = (try? await OCRService.shared.recognizeText(imageData: data,
                                                                               quality: .thorough))
                            ?? "（未识别到文字）"
                        ScreenshotOCRWindowController.shared.show(sourceImage: img,
                                                                  imageData: data,
                                                                  text: text)
                    }
                }
            case "pin":
                // v233 排障：kitnest://pin?file=… 直接把一张图钉到屏幕，
                // 用于核对控制条位置、关闭按钮、描边与悬停显隐。
                // ?probe=annotate|copy|more|zoom|close|grip|menu 直接展示对应气泡/列表
                // （本机 CGEvent 鼠标移动权限不稳定时靠它做确定性验收）
                let file = comps?.queryItems?.first(where: { $0.name == "file" })?.value
                let probe = comps?.queryItems?.first(where: { $0.name == "probe" })?.value
                if let file, let img = ImageProcessor.cgImage(from: URL(fileURLWithPath: file)) {
                    PinnedScreenshotManager.shared.show(image: img)
                    Log.info("App", "钉图排障：\(img.width)×\(img.height) probe=\(probe ?? "-")")
                    if let probe {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            PinnedScreenshotManager.shared.probeLast(probe)
                        }
                    }
                } else {
                    Log.warn("App", "pin：需要 ?file= 指定图片")
                }
            case "stagetest":
                // v235 排障：验证「截图先暂存、点保存才进下载目录」两条路径。
                // kitnest://stagetest?file=…            只暂存（等价于截图后点复制）
                // kitnest://stagetest?file=…&commit=1   再执行一次「保存」
                let file = comps?.queryItems?.first(where: { $0.name == "file" })?.value
                let commit = comps?.queryItems?.first(where: { $0.name == "commit" })?.value == "1"
                if let file, let img = ImageProcessor.cgImage(from: URL(fileURLWithPath: file)),
                   let data = ImageProcessor.pngData(img) {
                    if let staged = ScreenshotManager.shared.stagePNG(data, pixelSize: CGSize(width: img.width, height: img.height)) {
                        Log.info("App", "stagetest 暂存 → \(staged.path)")
                        if commit {
                            let dest = ScreenshotManager.shared.commitToSaveDirectory(staged: staged)
                            Log.info("App", "stagetest 保存 → \(dest?.path ?? "失败")")
                        }
                    }
                } else {
                    Log.warn("App", "stagetest：需要 ?file= 指定图片")
                }
            case "castapps":
                // v166.3 排障/直达：打开「全部应用」独立窗口
                CastAppLibraryWindowController.shared.show()
            case "storage":
                // v211 排障/直达：kitnest://storage —— 直接打开存储管理面板，
                // 便于无 UI 自动化环境下核对气泡地图、扫描进度与缓存加载。
                // ?scan=1 额外触发一次扫描（无人值守验证全盘索引用）；
                // ?drill=Users 下钻一层（验证返回按钮 / Esc 回上级）。
                let autoScan = comps?.queryItems?.first(where: { $0.name == "scan" })?.value == "1"
                let drill = comps?.queryItems?.first(where: { $0.name == "drill" })?.value
                let openAgent = comps?.queryItems?.first(where: { $0.name == "agent" })?.value == "1"
                StorageManagerWindowController.shared.show(autoScan: autoScan,
                                                           drill: drill,
                                                           openAgent: openAgent)
            case "castpair":
                // v166.5 排障/直达：打开面板并弹出「连接手机」弹层。
                // 等一个 runloop 再发通知——面板刚建好时 CastView 还没 onAppear，
                // 立刻发会丢订阅。
                NSApp.activate(ignoringOtherApps: true)
                PanelController.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: .frsetOpenCastQR, object: nil)
                }
            case "capture":
                // v130（SnowShot 对齐）：kitnest://capture?action=history|delayed[&seconds=N]
                // 历史窗 / 延时截图深链入口（CaptureDeepLink.handle 内部分流）
                CaptureDeepLink.handle(url: url)
            case "archive":
                // v118（ArcZip FR-603）：kitnest://archive?path=/a/b.zip[&action=extract|compress|open]
                let rawPath = comps?.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
                let action = comps?.queryItems?.first(where: { $0.name == "action" })?.value ?? "open"
                // v127（ArcZip P3）：action=filebox 开文件盒/暂存架浮窗——不需要压缩包路径，
                // 必须先于下面的路径存在性校验分流（空路径会被误判「文件不存在」）。
                if action == "filebox" {
                    ArchiveFileBoxWindow.show()
                    break
                }
                let fileURL = URL(fileURLWithPath: rawPath)
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    Log.warn("App", "归档深链：文件不存在 \(rawPath)")
                    break
                }
                switch action {
                case "extract":
                    let dir = fileURL.deletingLastPathComponent()
                    ArchiveCore.extract(url: fileURL, to: dir) { ok, msg in
                        Toast.show(ok ? "已解压到源目录" : "解压失败：\(msg)",
                                   icon: ok ? "archivebox" : "exclamationmark.triangle",
                                   isWarning: !ok)
                    }
                case "compress":
                    // v124：打开创建压缩包面板（含 5 种用途预设 / 分卷 / 密码）
                    ArchiveCreateWindowController.show(files: [fileURL])
                case "mini":
                    // v127（ArcZip P3）：Mini 独立小窗浏览（P3-1，不打断主窗口）
                    ArchiveMiniWindowController.show(url: fileURL)
                default:
                    // ?select=first → 排障：打开即选中第一条（本机合成点击点不中列表）
                    // ?entry=NAME → 排障：打开即选中指定条目（核对某类文件的预览）
                    let sel = comps?.queryItems?.first(where: { $0.name == "select" })?.value == "first"
                    let entry = comps?.queryItems?.first(where: { $0.name == "entry" })?.value
                    ArchiveBrowserWindowController.show(url: fileURL, selectFirst: sel, selectPath: entry)
                }
            case "cloudlink":
                // 排障深链：kitnest://cloudlink?url=<网盘链接>
                // 不复制也能直接打开解析中心，验证 8 家网盘的识别与配置页。
                let raw = comps?.queryItems?.first(where: { $0.name == "url" })?.value
                    ?? "https://pan.quark.cn/s/000000000000"
                // &action=download：跳过解析中心 UI，直驱「解析→下载」链路（网盘测试矩阵用）
                let wantsDownload = comps?.queryItems?
                    .first(where: { $0.name == "action" })?.value == "download"
                if let link = CloudDriveLinkDetector.detect(in: raw)
                    ?? URL(string: raw).flatMap({ u in
                        CloudDriveLinkDetector.provider(forHost: u.host ?? "").map {
                            CloudDriveLink(url: u, provider: $0,
                                           isSharePage: CloudDriveLinkDetector.isSharePage(u))
                        }
                    }) {
                    if wantsDownload {
                        Log.info("App", "cloudlink 深链：直驱下载 \(link.provider.rawValue) share=\(link.isSharePage)")
                        CloudLinkDownloader.shared.start(link: link, openBrowserOnFailure: false)
                    } else {
                        CloudLinkCenterController.shared.show(link: link)
                    }
                } else {
                    Log.warn("App", "cloudlink 深链：无法识别网盘链接 \(raw)")
                }
            case "toast":
                // v89 视觉验收/排障深链：kitnest://toast?text=已复制&icon=checkmark.circle.fill
                // 用途：不依赖具体业务路径即可复现全局提示，便于核对位置/样式/层级。
                let text = comps?.queryItems?.first(where: { $0.name == "text" })?.value ?? "已复制"
                let icon = comps?.queryItems?.first(where: { $0.name == "icon" })?.value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    Toast.show(text, icon: icon)
                }
            default:
                break
            }
        }
    }
}
