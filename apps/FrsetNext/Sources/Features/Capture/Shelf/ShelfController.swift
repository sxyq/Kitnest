import AppKit
import Foundation
import ImageIO

// MARK: - 截图悬挂架 · 控制器
//
// 生命周期（严格按「不是常驻」来做）：
//   开关关闭  → 不建窗口、不挂任何东西，内存里一个 item 都没有
//   开关打开  → 只是具备能力；截第一张图之前屏幕上仍然什么都不出现
//   截图完成  → 建窗口、挂上、开始倒计时
//   倒计时到  → 窗口 orderOut（**内容保留**，下次截图或手动唤出时全在）
//   手动移除  → 架空了就自动隐藏窗口
//
// 这里刻意不监听 NSApplication.didDeactivate 之类的事件去做显隐：
// 悬挂架是「贴边的一条」，它不该跟着 App 的激活状态闪。

@MainActor
public final class ScreenshotShelfController: NSObject {

    public static let shared = ScreenshotShelfController()

    /// 当前架上的截图（最新的在最左）
    public private(set) var items: [ShelfItem] = []
    /// 窗口是否正在显示（设置页用它决定「试一试」按钮要不要变成「收起」）
    public var isShowing: Bool { panel?.isVisible == true }

    private var panel: ShelfPanel?
    private var canvas: ShelfCanvasView?
    private var thumbnails: [UUID: CGImage] = [:]
    private var hideTask: Task<Void, Never>?
    private var wasEnabled = ShelfPref.enabled
    private var thumbsLoading: Set<UUID> = []
    /// 排障自检用：临时绕过「总开关」而不动用户偏好（见 runProbe）
    private var forceEnabled = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .shelfPreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(toggleRequested),
            name: .shelfToggleRequested, object: nil)
    }

    // MARK: - 对外：挂一张

    /// 截图落盘后调用。缩略图与尺寸在后台算，避免 6K 截图在主线程解码卡一下。
    public func attach(url: URL) {
        guard forceEnabled || (ShelfPref.enabled && ShelfPref.attachOnCapture) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) { () -> Prepared in
                let size = ShelfThumbnail.pixelSize(of: url)
                let image = ShelfThumbnail.make(for: url)
                return Prepared(size: size, image: image)
            }.value
            guard let self else { return }
            self.insert(url: url, size: prepared.size, image: prepared.image)
        }
    }

    private struct Prepared: @unchecked Sendable {
        let size: CGSize
        let image: CGImage?
    }

    private func insert(url: URL, size: CGSize, image: CGImage?) {
        let item = ShelfItem(fileURL: url, pixelSize: size)
        items.insert(item, at: 0)
        if let image { thumbnails[item.id] = image }

        // 超上限：从最旧的开始挤掉（只从架上移除，不删文件）
        let limit = ShelfPref.maxCards
        if items.count > limit {
            for stale in items[limit...] { thumbnails.removeValue(forKey: stale.id) }
            items = Array(items.prefix(limit))
        }

        rebuild()
        showPanel()
    }

    // MARK: - 对外：显示 / 收起 / 清空

    public func show() {
        guard forceEnabled || ShelfPref.enabled else { return }
        guard !items.isEmpty else { return }
        rebuild()
        showPanel()
    }

    /// 收起到「只留内容不留窗口」。不动 items。
    public func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    /// 关闭功能时调用：窗口销毁 + 内容清空。
    public func dismissAll() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
        canvas = nil
        items.removeAll()
        thumbnails.removeAll()
    }

    public func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails.removeValue(forKey: item.id)
        if items.isEmpty {
            hide()
            panel = nil
            canvas = nil
        } else {
            rebuild()
            showPanel()
        }
    }

    public func toggle() {
        if isShowing { hide() } else { show() }
    }

    // MARK: - 窗口

    private func showPanel() {
        guard forceEnabled || ShelfPref.enabled, !items.isEmpty else { return }
        let panel = ensurePanel()
        rebuild()
        panel.orderFrontRegardless()
        scheduleAutoHide()
    }

    private func ensurePanel() -> ShelfPanel {
        if let panel { return panel }
        let p = ShelfPanel()
        let host = ShelfHostView()
        host.wantsLayer = true
        let c = ShelfCanvasView()
        c.onRemove = { [weak self] item in self?.remove(item) }
        c.onSave = { item in Self.saveAs(item) }
        c.onPin = { item in Self.pin(item) }
        host.addSubview(c)
        p.contentView = host
        panel = p
        canvas = c
        return p
    }

    /// 内容需要的尺寸（未夹到屏幕）
    private func contentSize() -> CGSize {
        guard !items.isEmpty else { return CGSize(width: 200, height: 120) }
        let cardWidth = ShelfPref.cardWidth
        let sizes = items.map { $0.cardSize(cardWidth: cardWidth) }
        let w = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(items.count - 1, 0)) * ShelfMetrics.gap
            + ShelfMetrics.padding * 2
        let maxH = sizes.map(\.height).max() ?? 100
        return CGSize(width: w, height: ShelfMetrics.ropeHeight + maxH + ShelfMetrics.bottomInset)
    }

    private func rebuild() {
        guard let canvas else { return }
        let content = contentSize()
        let frame = windowFrame(for: content)
        panel?.setFrame(frame, display: true)
        panel?.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        canvas.frame = NSRect(origin: .zero, size: frame.size)
        canvas.reload(items: items.map { ($0, thumbnails[$0.id]) },
                      cardWidth: ShelfPref.cardWidth,
                      style: ShelfPref.ropeStyle,
                      size: frame.size)
    }

    /// 贴在**鼠标所在屏幕**的可见区顶部（菜单栏下方），水平居中。
    private func windowFrame(for content: CGSize) -> NSRect {
        let visible = Self.activeScreen().visibleFrame
        let width = max(min(content.width, visible.width - 24), 160)
        let height = min(content.height, visible.height - 40)
        let x = visible.midX - width / 2
        // visibleFrame.maxY 是菜单栏下沿；再往上就会被菜单栏压住
        let y = visible.maxY - height
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
    }

    // MARK: - 自动收起

    private func scheduleAutoHide() {
        hideTask?.cancel()
        let seconds = ShelfPref.displayDuration
        guard seconds > 0 else { hideTask = nil; return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    // MARK: - 偏好变化

    @objc private func toggleRequested() { toggle() }

    @objc private func preferencesChanged() {
        let on = ShelfPref.enabled
        defer { wasEnabled = on }

        guard on else {
            // 关掉 = 立刻消失，不留窗口、不留内容
            if wasEnabled { dismissAll() }
            return
        }
        guard wasEnabled else { return }   // 刚打开：等截图，不空show

        // 样式 / 宽度 / 数量变了：按新样子重排（原本收起的仍然保持收起）
        if isShowing {
            showPanel()
        }
    }

    // MARK: - 卡片动作

    private static func saveAs(_ item: ShelfItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.fileURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? FileManager.default.copyItem(at: item.fileURL, to: url)
            Toast.show("已保存", icon: "checkmark.circle")
        }
    }

    private static func pin(_ item: ShelfItem) {
        guard let src = CGImageSourceCreateWithURL(item.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        _ = PinnedScreenshotManager.shared.show(image: image)
    }

    // MARK: - 排障自检

    /// 深链 `kitnest://shelfprobe?count=3` 调用。
    ///
    /// 生成几张合成「截图」→ 上架 → 打印真实窗口尺寸 → 自动清理。
    /// 全程不碰鼠标、不修改用户偏好（用 forceEnabled 临时绕过总开关）。
    /// 存在的意义：截图链路必须人手框选，验收时没法自动化，这个入口把
    /// 「窗口位置 / 卡片排布 / 缩略图解码 / 自动收起」四件事都跑一遍。
    public func runProbe(count: Int = 3, capturable: Bool = false) {
        forceEnabled = true
        // 先建窗口再决定能不能被截到：probe 要截图验证渲染，正常使用必须 .none
        let probePanel = ensurePanel()
        if capturable { probePanel.sharingType = .readOnly }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kitnest-shelf-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var urls: [URL] = []
        for i in 0..<max(1, min(count, 8)) {
            let size = CGSize(width: 960 + CGFloat(i) * 240, height: 600 + CGFloat(i) * 160)
            guard let image = Self.probeImage(index: i, size: size),
                  let url = Self.writePNG(image, dir: dir, index: i) else { continue }
            urls.append(url)
        }
        Log.info("Shelf", "自检：生成 \(urls.count) 张测试图，开始上架（可截取=\(capturable)）")
        for url in urls { attach(url: url) }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            let frame = self.panel?.frame ?? .zero
            Log.info("Shelf", "自检：items=\(self.items.count) 可见=\(self.isShowing) "
                     + "窗口=\(Int(frame.width))x\(Int(frame.height)) "
                     + "位置=(\(Int(frame.minX)),\(Int(frame.minY)))")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self.panel?.sharingType = .none
            self.dismissAll()
            self.forceEnabled = false
            Log.info("Shelf", "自检：已清理")
        }
    }

    /// 合成一张「像截图的东西」：渐变底 + 几条文字灰条 + 序号块
    private static func probeImage(index: Int, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let palettes: [(CGFloat, CGFloat, CGFloat)] = [
            (0.20, 0.42, 0.72), (0.72, 0.30, 0.32), (0.22, 0.55, 0.42),
            (0.55, 0.40, 0.20), (0.38, 0.30, 0.62),
        ]
        let c = palettes[index % palettes.count]
        let colors = [CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1),
                      CGColor(red: c.0 * 0.35, green: c.1 * 0.35, blue: c.2 * 0.35, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: size.width, y: size.height), options: [])
        }

        // 标题条 + 五行内容条
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
        ctx.fill(CGRect(x: 60, y: size.height - 130, width: 320, height: 18))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.55))
        for row in 0..<5 {
            let lineW = size.width * (0.66 - CGFloat(row) * 0.07)
            ctx.fill(CGRect(x: 60, y: size.height - 190 - CGFloat(row) * 48,
                            width: lineW, height: 13))
        }
        // 右下角一个方块放「第几张」，让不同卡片的缩略图能一眼区分
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
        let boxSide = min(size.height * 0.32, 190)
        ctx.fill(CGRect(x: size.width - boxSide - 60, y: 60, width: boxSide, height: boxSide))
        return ctx.makeImage()
    }

    private static func writePNG(_ image: CGImage, dir: URL, index: Int) -> URL? {
        let url = dir.appendingPathComponent("probe-\(index + 1).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                        "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}
