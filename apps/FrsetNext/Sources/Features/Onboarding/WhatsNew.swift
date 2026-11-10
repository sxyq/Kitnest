import AppKit
import SwiftUI

// MARK: - WhatsNew 版本说明浮层（v114；对标原版逆向实锤的三件套）
//
// 原版证据链（逆向档案）：WhatsNewEntry → WhatsNewSection(+View) → WhatsNewOverlayView
// （按钮 "Got it 知道了"）→ WhatsNewPresenter → WhatsNewStore（键 whatsNewLastSeenVersion，
// 每个版本只弹一次）；调试入口 onTestWhatsNew。**不是**检查更新（那是 AppUpdateChecker）。
//
// 重建版语义（v201 / 2026-11-04 改为服务端下发）：
//   · 更新后第一次启动弹出「本次更新了什么」，看完关闭即记住；
//   · 条目来自更新清单 `whatsNew{added,improved,fixed}`（AppUpdateChecker 缓存，离线回退本地），
//     不再每批手动改代码；
//   · 已读按 **CFBundleVersion 内部 build 号** 记账（显示版本固定 1.0.0，不能当版本用）；
//   · 首启用欢迎窗（onboarding），WhatsNew 让路本次启动、下次启动再弹；
//   · 排障探针：FRSET_TEST_WHATSNEW=1 或 defaults probe.whatsnew → 无条件弹（对应原版
//     onTestWhatsNew 调试入口）。

// MARK: - 数据模型

public enum WhatsNewCategory: String, CaseIterable, Identifiable {
    case added, improved, fixed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .added:    return "新增"
        case .improved: return "改进"
        case .fixed:    return "修复"
        }
    }

    public var symbol: String {
        switch self {
        case .added:    return "plus.circle.fill"
        case .improved: return "arrow.up.circle.fill"
        case .fixed:    return "wrench.and.screwdriver.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .added:    return Color(nsColor: .systemGreen)
        case .improved: return Color(nsColor: .systemBlue)
        case .fixed:    return Color(nsColor: .systemOrange)
        }
    }
}

public struct WhatsNewEntry {
    let category: WhatsNewCategory
    let text: String
}

// MARK: - 内容目录（功能批次落地时维护；contentVersion 同步 +1）

public enum WhatsNewCatalog {

    /// 内容所属发布批次：优先用清单里的 build，取不到时用当前安装 build
    public static var contentBuild: Int {
        if let feed = AppUpdateChecker.shared.cachedFeed, let b = feed["build"] as? Int { return b }
        return AppUpdateChecker.shared.currentBuild
    }

    /// 兼容旧调用点（日志/诊断）
    public static var contentVersion: Int { contentBuild }

    /// 当前批次条目：服务端清单优先，离线或旧清单无 whatsNew 时回退本地
    public static var entries: [WhatsNewEntry] {
        let remote = remoteEntries
        return remote.isEmpty ? localEntries : remote
    }

    private static var remoteEntries: [WhatsNewEntry] {
        guard let feed = AppUpdateChecker.shared.cachedFeed,
              let groups = feed["whatsNew"] as? [String: Any] else { return [] }
        var result: [WhatsNewEntry] = []
        for category in WhatsNewCategory.allCases {
            guard let texts = groups[category.rawValue] as? [String] else { continue }
            result.append(contentsOf: texts.map { WhatsNewEntry(category: category, text: $0) })
        }
        return result
    }

    /// 离线兜底（首次安装或更新源不可达时仍能看到内容）
    public static let localEntries: [WhatsNewEntry] = [
        .init(category: .added, text: "在线更新：自动检查新版本，支持整包下载、校验与一键替换"),
        // v267：截图只有一套自适应行为，不再分「区域 / 窗口」两档
        .init(category: .added, text: "截图自适应：悬停窗口单击截整窗、直接拖拽截自定义范围、点空白处截全屏"),
        .init(category: .added, text: "命令面板 ⌥K：全部功能统一检索直达"),
        .init(category: .added, text: "传输与投屏：隔空投送收发、Android 无线配对、ADB 文件互传、扫码直传"),
        .init(category: .improved, text: "三级玻璃分层视觉，日历/剪贴板卡统一宽度"),
        .init(category: .improved, text: "启动性能收紧，预览窗高度自适应"),
        .init(category: .fixed, text: "剪贴板预览支持 Markdown 表格（Excel 风格完整网格）"),
        .init(category: .fixed, text: "长截图拼接与若干稳定性问题修复"),
    ]

    /// 按类别分组（保持 entries 顺序）
    public static func grouped() -> [(category: WhatsNewCategory, entries: [WhatsNewEntry])] {
        var order: [WhatsNewCategory] = []
        var map: [WhatsNewCategory: [WhatsNewEntry]] = [:]
        for entry in entries {
            if map[entry.category] == nil { order.append(entry.category) }
            map[entry.category, default: []].append(entry)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

// MARK: - 记忆存储

public final class WhatsNewStore {

    public static let shared = WhatsNewStore()

    /// v201：按内部 build 记账（旧键 whatsNewLastSeenVersion 是内容版本口径，不复用）
    private let key = "whatsNewLastSeenBuild"

    private init() {}

    /// 是否需要弹（当前安装的 build > 已看过的 build）
    public var shouldShow: Bool {
        UserDefaults.standard.integer(forKey: key) < AppUpdateChecker.shared.currentBuild
    }

    /// 标记已看（任意关闭路径都算「知道了」——每个 build 只弹一次）
    func markSeen() {
        let build = AppUpdateChecker.shared.currentBuild
        UserDefaults.standard.set(build, forKey: key)
        Log.info("WhatsNew", "已标记 seenBuild=\(build)")
    }
}

// MARK: - 浮层窗口

public final class WhatsNewWindowController: NSObject {

    public static let shared = WhatsNewWindowController()

    private var window: WhatsNewWindow?
    private var feedObserver: NSObjectProtocol?

    private override init() { super.init() }

    /// force = true 时无视 seen 状态（排障探针，对应原版 onTestWhatsNew）
    public func show(force: Bool = false) {
        guard force || WhatsNewStore.shared.shouldShow else { return }
        Log.info("WhatsNew", "浮层 show (force=\(force))")
        ensureWindow()
        installFeedObserver()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        RenderProbe.snapshot(window, name: "whatsNew", reason: "show")
    }

    /// 浮层已显示时清单才到达 → 用远端条目重建内容，避免「先弹窗后拉到内容」显示兜底文案
    private func installFeedObserver() {
        guard feedObserver == nil else { return }
        feedObserver = NotificationCenter.default.addObserver(
            forName: AppUpdateChecker.feedDidUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let win = self.window, win.isVisible else { return }
            let hosting = NSHostingView(rootView: WhatsNewView())
            hosting.sizingOptions = []
            if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
            win.setOfficialContent(hosting)
            Log.info("WhatsNew", "清单到达，已用远端条目刷新浮层")
        }
    }

    /// 「知道了」：标记已看 + 关闭
    public func finish() {
        WhatsNewStore.shared.markSeen()
        close()
    }

    public func close() {
        RenderProbe.snapshot(window, name: "whatsNew", reason: "close")
        window?.orderOut(nil)
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    // MARK: 窗口构建（形态对齐 WelcomeWindowController：固定尺寸 + 官方外观 + 延后装载）

    private func ensureWindow() {
        guard window == nil else { return }
        let win = WhatsNewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "本次更新"
        win.titleVisibility = .hidden
        win.applyOfficialChrome(lights: .fixed)
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 400, height: 500)
        win.contentMaxSize = NSSize(width: 400, height: 500)
        // v205：红黄绿三钮统一显示（固定尺寸窗口的黄/绿由系统置灰）
        win.center()
        win.contentView = NSView()
        window = win
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window else { return }
            let hostingView = NSHostingView(rootView: WhatsNewView())
            hostingView.sizingOptions = []
            if #available(macOS 13.3, *) { hostingView.safeAreaRegions = [] }
            win.setOfficialContent(hostingView)
        }
        Log.info("WhatsNew", "浮层窗口已创建")
    }
}

/// Esc / 叉号关闭都算「知道了」（每个版本只弹一次）
final class WhatsNewWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        WhatsNewStore.shared.markSeen()
        super.performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, event.type == .keyDown {   // Esc
            WhatsNewStore.shared.markSeen()
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 浮层内容

struct WhatsNewView: View {

    private let grouped = WhatsNewCatalog.grouped()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(grouped, id: \.category) { group in
                        section(group.category, entries: group.entries)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            footer
        }
        .frame(width: 400, height: 500)
        .background(Color(OfficialChrome.windowBackground))
        // v208：原生标题栏由窗口负责
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            Text("本次更新了什么")
                .font(.system(size: 18, weight: .semibold))
            Text("v\(AppUpdateChecker.shared.currentVersion) · build \(AppUpdateChecker.shared.currentBuild) 更新一览")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, OfficialChrome.titlebarInset)   // v272：统一标题栏净空
        .padding(.bottom, 10)
    }

    private func section(_ category: WhatsNewCategory, entries: [WhatsNewEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: category.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(category.tint)
                Text(category.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(category.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(category.tint.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        Text(entries[i].text)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                WhatsNewWindowController.shared.finish()
            } label: {
                Text("知道了")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            Text("此提示每个版本只显示一次")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}
