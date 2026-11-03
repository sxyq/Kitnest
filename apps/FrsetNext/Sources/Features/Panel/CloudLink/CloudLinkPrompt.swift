import AppKit
import Combine

// MARK: - 复制网盘链接后自动打开解析中心（v201）
//
// 触发：剪贴板新增一条文本 → 命中网盘域名 → **直接打开**「网盘解析中心」
// （CloudLinkCenter，单独窗口：解析/配置/下载状态）。
// 约束：同一条链接只打开一次；启动时已有的历史条目不打开（避免一开机就弹旧链接），
//       但启动后 2s 内会追赶最近 30 分钟内未提示过的分享链接一次。
//
// 历史（2026-10-20）：原本只弹状态栏小胶囊，点它才进解析中心；用户 2026-11-03
// 实测复制天翼云盘分享链接后「没有自动弹出那个界面」——改为命中即直开解析中心。

final class CloudLinkPromptController {

    static let shared = CloudLinkPromptController()

    private var cancellable: AnyCancellable?
    private var lastSeenItemID: String?
    private var lastPromptedURL: String?

    private var startedAt = Date()

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
        Log.info("CloudLink", "网盘链接自动打开已启动（基线条目 \(lastSeenItemID ?? "无")）")
        // 启动追赶（2026-10-20 用户：「之前复制的 123 下载链接没自动弹出」）：
        // 复制发生在重启前的分享链接，启动后 2s 内补开一次（30 分钟内、限一条），
        // 不让「恰好重启过」吞掉下载助手。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.catchUpRecentShareLink()
        }
    }

    /// 启动追赶：最近 30 分钟内入库、且尚未打开过的分享链接 → 补开一次
    private func catchUpRecentShareLink() {
        guard lastPromptedURL == nil else { return }
        let now = Date()
        for item in ClipboardManager.shared.items.prefix(20) {
            guard item.timestamp.timeIntervalSince(now) > -1800 else { break }
            guard item.type == .text || item.type == .url || item.type == .file || item.type == .richtext,
                  let text = item.content ?? item.title,
                  let link = CloudDriveLinkDetector.detect(in: text),
                  link.isSharePage else { continue }
            guard link.url.absoluteString != lastPromptedURL else { return }
            lastPromptedURL = link.url.absoluteString
            Log.info("CloudLink", "启动追赶：自动打开 \(link.provider.rawValue) \(link.url.absoluteString)")
            open(link)
            return
        }
    }

    private func handle(_ items: [ClipboardItem]) {
        guard Date().timeIntervalSince(startedAt) > 1.5 else { return }
        guard let newest = items.first else { return }
        // 只处理「启动之后入库」的条目：历史条目不弹，首次加载也不会把新复制的那条吞掉
        guard newest.timestamp.timeIntervalSince(startedAt) > 0.3 else { return }
        guard newest.id != lastSeenItemID else { return }
        lastSeenItemID = newest.id
        Log.info("CloudLink", "剪贴板新条目 type=\(newest.type) chars=\(newest.content?.count ?? 0)")
        guard newest.type == .text || newest.type == .url || newest.type == .file || newest.type == .richtext else { return }
        guard let text = newest.content ?? newest.title,
              let link = CloudDriveLinkDetector.detect(in: text) else {
            Log.info("CloudLink", "新条目未命中网盘链接")
            return
        }
        guard link.url.absoluteString != lastPromptedURL else { return }
        lastPromptedURL = link.url.absoluteString
        Log.info("CloudLink", "剪贴板命中网盘链接：\(link.provider.rawValue) \(link.url.absoluteString)")
        open(link)
    }

    /// 命中即直开解析中心（不再先弹小胶囊）
    private func open(_ link: CloudDriveLink) {
        CloudLinkCenterController.shared.show(link: link)
        Log.info("CloudLink", "已自动打开解析中心：\(link.provider.displayName) \(link.url.absoluteString)")
    }
}
