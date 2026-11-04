import AppKit
import SwiftUI

/// 「全部应用」独立窗口。
///
/// 用户要求（2026-10-30）：筛选出来的全部应用要**单独一个界面**，不是挤在状态栏面板里；
/// 列表按使用频率排序（简单推荐），点图标即开独立应用窗口。
public final class CastAppLibraryWindowController {

    public static let shared = CastAppLibraryWindowController()

    private var window: NSWindow?

    private init() {}

    public func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "全部应用"
        w.titlebarAppearsTransparent = false   // v208：原生标题栏（唯一实现）
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 720, height: 560)
        w.contentMaxSize = NSSize(width: 720, height: 560)
        w.applyOfficialChrome()   // v179：统一灰底 + 圆钮（此前是裸窗口默认样式）
        w.center()

        let host = NSHostingView(rootView: CastAppLibraryView())
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        host.sizingOptions = []                  // 固定尺寸窗，禁止 SwiftUI 反压（工程铁律）
        w.contentView = host
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 视图

private struct CastAppLibraryView: View {

    @Stored private var apps: [DeviceAppCatalog.App] = []
    @Stored private var query = ""
    @Stored private var loading = true

    private var shown: [DeviceAppCatalog.App] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.label.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索应用", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                Spacer()
                Text("\(shown.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 10)

            Divider().opacity(0.4)

            if loading && apps.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                Text("正在读取手机应用与图标…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 8)
                Spacer()
            } else if shown.isEmpty {
                Spacer()
                Text(apps.isEmpty ? "没有第三方应用" : "没有匹配的应用")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: .infinity), spacing: 10)],
                              spacing: 12) {
                        ForEach(shown) { app in
                            Button { open(app) } label: { tile(app) }
                                .buttonStyle(.plain)
                                .help(app.id)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 720, height: 560)
        // v208：原生标题栏由窗口负责；内容顶部已经留出 34pt
        .onAppear { reload() }
    }

    private func tile(_ app: DeviceAppCatalog.App) -> some View {
        VStack(spacing: 6) {
            Group {
                if let img = app.icon {
                    Image(nsImage: img).resizable()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                        Text(String(app.label.prefix(1)))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous))

            Text(app.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
        .glassCard(radius: Theme.Radius.control)
    }

    private func open(_ app: DeviceAppCatalog.App) {
        CastAppUsage.record(app.id)
        ADBExtrasEngine.startAppWindow(package: app.id, title: app.label)
    }

    private func reload() {
        loading = true
        let serial = ADBExtrasEngine.activeSerial
        DeviceAppCatalog.shared.load(serial: serial) { list in
            apps = list
            loading = false
        }
    }
}
