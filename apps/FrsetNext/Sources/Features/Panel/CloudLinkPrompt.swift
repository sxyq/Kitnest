import AppKit
import Combine
import SwiftUI

// MARK: - 复制网盘链接后的状态栏小提示
//
// 触发：剪贴板新增一条文本 → 命中网盘域名 → 在状态栏图标下方弹一个小胶囊。
// 交互：点胶囊 → 打开「网盘解析中心」（下载配置 + 诊断）；点 × 只收起本次提示。
// 约束：同一条链接只提示一次；启动时已有的历史条目不提示（避免一开机就弹旧链接）。

final class CloudLinkPromptController {

    static let shared = CloudLinkPromptController()

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var lastSeenItemID: String?
    private var lastPromptedURL: String?

    private var dismissWork: DispatchWorkItem?
    private var startedAt = Date()
    private var currentLink: CloudDriveLink?

    private init() {}

    func start() {
        guard cancellable == nil else { return }
        startedAt = Date()
        lastSeenItemID = ClipboardManager.shared.items.first?.id
        cancellable = ClipboardManager.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.handle(items) }
        // 双通道：条目通知（reload 后必发）兜底 publisher 的合并/节流
        NotificationCenter.default.addObserver(
            forName: ClipboardManager.itemsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.handle(ClipboardManager.shared.items)
            }
        Log.info("CloudLink", "状态栏网盘提示已启动（基线条目 \(lastSeenItemID ?? "无")）")
    }

    private func handle(_ items: [ClipboardItem]) {
        guard Date().timeIntervalSince(startedAt) > 1.5 else { return }
        guard let newest = items.first else { return }
        // 只处理「启动之后入库」的条目：历史条目不弹，首次加载也不会把新复制的那条吞掉
        guard newest.timestamp.timeIntervalSince(startedAt) > 0.3 else { return }
        guard newest.id != lastSeenItemID else { return }
        lastSeenItemID = newest.id
        Log.info("CloudLink", "剪贴板新条目 type=\(newest.type) chars=\(newest.content?.count ?? 0)")
        guard newest.type == .text || newest.type == .url || newest.type == .file else { return }
        guard let text = newest.content ?? newest.title,
              let link = CloudDriveLinkDetector.detect(in: text) else {
            Log.info("CloudLink", "新条目未命中网盘链接")
            return
        }
        guard link.url.absoluteString != lastPromptedURL else { return }
        lastPromptedURL = link.url.absoluteString
        Log.info("CloudLink", "剪贴板命中网盘链接：\(link.provider.rawValue) \(link.url.absoluteString)")
        show(link)
    }

    // MARK: 小窗

    private func show(_ link: CloudDriveLink) {
        currentLink = link
        dismiss()

        let host = NSHostingView(rootView: CloudLinkPromptView(
            link: link,
            onOpen: { [weak self] in
                self?.dismiss()
                CloudLinkCenterController.shared.show(link: link)
            },
            onTest: { [weak self] in
                self?.dismiss()
                CloudLinkCenterController.shared.show(link: link)
            },
            onClose: { [weak self] in self?.dismiss() }
        ))
        let width: CGFloat = 322
        let height: CGFloat = 64
        host.setFrameSize(NSSize(width: width, height: height))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.setFrame(positionFrame(size: NSSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        Log.info("CloudLink", "状态栏提示已弹出（\(Int(width))×\(Int(height))）")
    }

    /// 贴在状态栏图标正下方（右对齐，避免超出屏幕）
    private func positionFrame(size: NSSize) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var anchorX = screen.maxX - 24
        var anchorTopY = screen.maxY - 8
        if let buttonWindow = StatusBarController.shared.mainStatusItem?.button?.window?.frame {
            anchorX = buttonWindow.midX
            anchorTopY = buttonWindow.minY
        }
        var x = anchorX - size.width + 24
        x = min(max(screen.minX + 8, x), screen.maxX - size.width - 8)
        let y = anchorTopY - size.height - 6
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func dismiss() {
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
        panel = nil
        currentLink = nil
    }
}

// MARK: - 小窗内容

struct CloudLinkPromptView: View {
    let link: CloudDriveLink
    let onOpen: () -> Void
    let onTest: () -> Void
    let onClose: () -> Void

    private var tint: Color { Color(nsColor: link.provider.tint) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 32, height: 32)
                Image(systemName: link.provider.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("检测到\(link.provider.displayName)链接")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(link.isSharePage ? "分享页 · 点击测试解析" : "非分享页 · 可能需要登录")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            Button(action: onTest) {
                Text("测试")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(tint))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("打开解析中心，检查脚本与页面可达性")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 322)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: onOpen)
    }
}
