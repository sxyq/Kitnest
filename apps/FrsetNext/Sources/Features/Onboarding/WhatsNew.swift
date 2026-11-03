import AppKit
import SwiftUI

// MARK: - WhatsNew 版本说明浮层（v114；对标原版逆向实锤的三件套）
//
// 原版证据链（逆向档案）：WhatsNewEntry → WhatsNewSection(+View) → WhatsNewOverlayView
// （按钮 "Got it 知道了"）→ WhatsNewPresenter → WhatsNewStore（键 whatsNewLastSeenVersion，
// 每个版本只弹一次）；调试入口 onTestWhatsNew。**不是**检查更新（那是 AppUpdateChecker）。
//
// 重建版语义：
//   · 升级/大版本内容更新后第一次启动弹出「本次更新了什么」，看完关闭即记住；
//   · 内容版本 WhatsNewCatalog.contentVersion 手动 +1（功能批次落地时），
//     不与 Info.plist 版本绑定（显示版本固定 1.0.0，见 AboutSettingsPane v90 注）；
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

    /// 当前内容版本：每次新增一批条目 +1，老用户升级后重见弹窗
    public static let contentVersion = 1

    /// 当前批次条目（按 Added / Improved / Fixed 分组渲染）
    public static let entries: [WhatsNewEntry] = [
        .init(category: .added, text: "窗口截图 ⇧⌥W：一键截取最前台应用窗口，自动排除遮挡"),
        .init(category: .added, text: "区域截图悬停吸附：窗口自动高亮，单击即整窗截取"),
        .init(category: .added, text: "命令面板 ⌥K：全部功能统一检索直达"),
        .init(category: .added, text: "欢迎窗与权限引导：四类系统权限状态一目了然"),
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

    /// 原版同款键名（逆向实锤：WhatsNewStore → whatsNewLastSeenVersion）
    private let key = "whatsNewLastSeenVersion"

    private init() {}

    /// 是否需要弹（当前内容版本 > 已看过版本）
    public var shouldShow: Bool {
        UserDefaults.standard.integer(forKey: key) < WhatsNewCatalog.contentVersion
    }

    /// 标记已看（任意关闭路径都算「知道了」——每个版本只弹一次）
    func markSeen() {
        UserDefaults.standard.set(WhatsNewCatalog.contentVersion, forKey: key)
        Log.info("WhatsNew", "已标记 seen=\(WhatsNewCatalog.contentVersion)")
    }
}

// MARK: - 浮层窗口

public final class WhatsNewWindowController: NSObject {

    public static let shared = WhatsNewWindowController()

    private var window: WhatsNewWindow?

    private override init() { super.init() }

    /// force = true 时无视 seen 状态（排障探针，对应原版 onTestWhatsNew）
    public func show(force: Bool = false) {
        guard force || WhatsNewStore.shared.shouldShow else { return }
        Log.info("WhatsNew", "浮层 show (force=\(force))")
        ensureWindow()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        RenderProbe.snapshot(window, name: "whatsNew", reason: "show")
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
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "本次更新"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.applyOfficialChrome()
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
            win.contentView = hostingView
            win.attachOfficialRoundCloseButton()
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
        // v206：标题栏独立分层（红绿灯不再是一条白条）
        .background(alignment: .top) { WindowTitleBand() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            Text("本次更新了什么")
                .font(.system(size: 18, weight: .semibold))
            Text("FrsetNext 近期批次更新一览")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 22)
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
