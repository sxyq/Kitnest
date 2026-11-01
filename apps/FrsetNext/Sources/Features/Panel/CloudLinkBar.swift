import AppKit
import SwiftUI

// MARK: - 首页网盘链接条（LinkSwift 接入 · Layer 1 UI）
//
// 位置：主面板首页「搜索框」正下方（PanelRootView.homePage：searchSection 之后）。
// 行为（2026-10-19 用户澄清的交互形态）：
//   · 用户复制网盘链接 → 剪贴板入库（1s 轮询）→ 命中 → **自动弹出**该条，
//     下方日历/剪贴板列表平滑下移；平时完全不占位；
//   · 只认「最近 3 条」剪贴板：避免旧链接长期占位，突出「刚复制的那条」；
//   · 进入：顶部滑入 + 淡入 + 一次轻微放大脉冲（"弹出来"的感知）；
//   · 可手动关闭（×）——关闭后同一链接不再自动弹出，换新链接才重新出现。

public struct CloudLinkBar: View {
    @ObservedObject private var clipboard = ClipboardManager.shared

    /// 用户手动关掉的链接（absoluteString）——同链接不再弹，新链接照常
    /// （本机工具链缺 SwiftUIMacros 插件，@State 不可用；用工程的 @Stored 兼容层）
    @Stored private var dismissedURL: String?
    /// 首次出现时的放大脉冲
    @Stored private var pulse = false

    public init() {}

    /// 布局动画 key（父视图用：链接出现/消失时驱动日历与列表平滑下移）
    public static func detectionKey(items: [ClipboardItem]) -> String {
        CloudDriveLinkDetector.recentLink(in: items, scanLimit: 20)?.url.absoluteString ?? ""
    }

    /// 只扫最近 3 条（复制即识别，不做历史考古）
    private var link: CloudDriveLink? {
        guard let l = CloudDriveLinkDetector.recentLink(in: clipboard.items, scanLimit: 20) else { return nil }
        if let dismissedURL, dismissedURL == l.url.absoluteString { return nil }
        return l
    }

    public var body: some View {
        Group {
            if let link {
                bar(link)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .scaleEffect(pulse ? 1.015 : 1.0)
                    .onAppear {
                        // 一次轻脉冲：让「自动弹出」被看见
                        withAnimation(Theme.Motion.springBouncy) { pulse = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            withAnimation(Theme.Motion.springBouncy) { pulse = false }
                        }
                    }
            }
        }
        .animation(Theme.Motion.springSoft, value: link?.url.absoluteString)
    }

    private func bar(_ link: CloudDriveLink) -> some View {
        HStack(spacing: 10) {
            providerBadge(link.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(link.provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(shortURL(link))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.open(link.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("在浏览器打开")
            Button {
                CloudLinkActions.resolve(link)
            } label: {
                Text("解析下载")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(nsColor: link.provider.tint).opacity(0.16))
                    )
                    .foregroundStyle(Color(nsColor: link.provider.tint))
            }
            .buttonStyle(.plain)
            .help("取直链并下载（解析器 P1 接入中）")
            // 关闭：同链接不再自动弹
            Button {
                withAnimation(Theme.Motion.fast) { dismissedURL = link.url.absoluteString }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("暂时收起（同一链接不再弹出）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: link.provider.tint).opacity(0.22), lineWidth: 0.8)
        )
    }

    private func providerBadge(_ p: CloudDriveProvider) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Color(nsColor: p.tint).opacity(0.18))
                .frame(width: 28, height: 28)
            Image(systemName: p.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: p.tint))
        }
    }

    private func shortURL(_ link: CloudDriveLink) -> String {
        let p = link.url.path
        let tail = p.count > 26 ? "…" + p.suffix(24) : p
        return link.host + tail
    }
}

// MARK: - 预览底部操作条（文本预览命中网盘链接时显示）

public struct CloudLinkPreviewAction: View {
    let link: CloudDriveLink

    public init(link: CloudDriveLink) { self.link = link }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: link.provider.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: link.provider.tint))
            Text(link.provider.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button("复制链接") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(link.url.absoluteString, forType: .string)
                Toast.show("链接已复制", icon: "link")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Button("打开") { NSWorkspace.shared.open(link.url) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: link.provider.tint))

            Button("解析下载") { CloudLinkActions.resolve(link) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: link.provider.tint).opacity(0.16)))
                .foregroundStyle(Color(nsColor: link.provider.tint))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }
}

// MARK: - 动作（P0：打开网盘页面；P1 换成 CloudLinkResolver）

enum CloudLinkActions {
    static func resolve(_ link: CloudDriveLink) {
        Log.info("CloudLink", "解析请求: \(link.provider.rawValue) \(link.url.absoluteString) share=\(link.isSharePage)")
        StatisticsManager.shared.record(.browserOpen)
        // 真实下载链路（2026-10-20）：直链直接下；分享页 WKWebView 抓直链后下；
        // 解析不了就明确报错并打开页面，不再只弹「接入中」。
        CloudLinkDownloader.shared.start(link: link)
    }
}
