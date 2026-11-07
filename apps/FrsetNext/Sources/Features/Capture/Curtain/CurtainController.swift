import AppKit
import Foundation
import ImageIO

// MARK: - 图帘 · 控制器
//
// 生命周期（严格按「不是常驻」来做）：
//   开关关闭  → 不建窗口、不挂任何东西，内存里一个 item 都没有
//   开关打开  → 只是具备能力；截第一张图之前屏幕上仍然什么都不出现
//   截图完成  → 建窗口、挂上、开始倒计时
//   倒计时到  → 窗口 orderOut（**内容保留**，下次截图或手动唤出时全在）
//   手动移除  → 架空了就自动隐藏窗口
//
// 这里刻意不监听 NSApplication.didDeactivate 之类的事件去做显隐：
// 图帘是「贴边的一条」，它不该跟着 App 的激活状态闪。

@MainActor
public final class ImageCurtainController: NSObject {

    public static let shared = ImageCurtainController()

    /// 当前架上的截图（最新的在最左）
    public private(set) var items: [CurtainItem] = []
    /// 窗口是否正在显示（设置页用它决定「试一试」按钮要不要变成「收起」）
    public var isShowing: Bool { panel?.isVisible == true }

    private var panel: CurtainPanel?
    private var canvas: CurtainCanvasView?
    private var thumbnails: [UUID: CGImage] = [:]
    private var hideTask: Task<Void, Never>?
    private var wasEnabled = CurtainPref.enabled
    private var thumbsLoading: Set<UUID> = []
    /// 排障自检用：临时绕过「总开关」而不动用户偏好（见 runProbe）
    private var forceEnabled = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .curtainPreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(toggleRequested),
            name: .curtainToggleRequested, object: nil)
    }

    // MARK: - 对外：挂一张

    /// 截图落盘后调用。缩略图与尺寸在后台算，避免 6K 截图在主线程解码卡一下。
    ///
    /// - Parameter manual: true = 用户从截图动作条 / 菜单主动「挂到图帘」。
    ///   主动挂载不受「自动上架」开关限制，但仍然要求图帘总开关是开的。
    /// - Returns: 是否接受（关着的时候返回 false，调用方据此给提示）
    @discardableResult
    public func attach(url: URL, manual: Bool = false) -> Bool {
        guard forceEnabled || CurtainPref.enabled else { return false }
        guard manual || CurtainPref.attachOnCapture else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        // 缩略图按当前卡片宽度解码：420pt 宽的卡片配 640px 缩略图会糊，
        // 这里让解码尺寸跟着走；正常宽度仍是 320（×2 = 640px），不多占内存。
        let maxPixel = max(320, CurtainPref.cardWidth)
        Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) { () -> Prepared in
                let size = CurtainThumbnail.pixelSize(of: url)
                let image = CurtainThumbnail.make(for: url, maxPixel: maxPixel)
                return Prepared(size: size, image: image)
            }.value
            guard let self else { return }
            self.insert(url: url, size: prepared.size, image: prepared.image)
        }
        return true
    }

    private struct Prepared: @unchecked Sendable {
        let size: CGSize
        let image: CGImage?
    }

    private func insert(url: URL, size: CGSize, image: CGImage?) {
        let item = CurtainItem(fileURL: url, pixelSize: size)
        items.insert(item, at: 0)
        if let image { thumbnails[item.id] = image }

        // 超上限：从最旧的开始挤掉（只从帘上移除，不删文件）
        let limit = CurtainPref.maxCards
        if items.count > limit {
            for stale in items[limit...] { thumbnails.removeValue(forKey: stale.id) }
            items = Array(items.prefix(limit))
        }

        rebuild()
        showPanel()
    }

    // MARK: - 对外：显示 / 收起 / 清空

    public func show() {
        guard forceEnabled || CurtainPref.enabled else { return }
        guard !items.isEmpty else { return }
        rebuild(animate: false)
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
        liveCardWidth = nil
    }

    public func remove(_ item: CurtainItem) {
        items.removeAll { $0.id == item.id }
        thumbnails.removeValue(forKey: item.id)
        if items.isEmpty {
            hide()
            panel = nil
            canvas = nil
        } else {
            rebuild(animate: false)
            showPanel()
        }
    }

    public func toggle() {
        if isShowing { hide() } else { show() }
    }

    // MARK: - 窗口

    private func showPanel() {
        guard forceEnabled || CurtainPref.enabled, !items.isEmpty else { return }
        let panel = ensurePanel()
        rebuild(animate: false)
        panel.orderFrontRegardless()
        scheduleAutoHide()
    }

    private func ensurePanel() -> CurtainPanel {
        if let panel { return panel }
        let p = CurtainPanel()
        let host = CurtainHostView()
        host.wantsLayer = true
        let c = CurtainCanvasView()
        c.onRemove = { [weak self] item in self?.remove(item) }
        c.onSave = { item in Self.saveAs(item) }
        c.onPin = { item in Self.pin(item) }
        c.onResizeStep = { [weak self] delta in self?.resizeStep(delta) }
        c.onResizeEnd = { [weak self] in self?.resizeEnd() }
        host.addSubview(c)
        p.contentView = host
        panel = p
        canvas = c
        return p
    }

    // MARK: - 尺寸（v263：⌘ 拖动缩放）

    /// 拖动中的临时宽度；nil = 没有在拖，用用户偏好
    private var liveCardWidth: CGFloat?

    private func railScale(for width: CGFloat) -> CGFloat {
        guard CurtainPref.railScalesWithCards else { return 1 }
        return min(max(width / CurtainPref.baseCardWidth, 0.8), 3)
    }

    /// 当前屏幕能放下的实际卡片宽度。
    ///
    /// 用户可以把宽度调到 420，但挂 4 张时 4×420 已经超过 1440 屏宽。
    /// 这里按「不超屏」反算一个上限：优先保证整条帘子完整可见，
    /// 放不下时自动收窄（用户偏好本身不改，等张数变少会自己放大回去）。
    private func layoutMetrics(visible: NSRect) -> (cardWidth: CGFloat, railScale: CGFloat, maxHeight: CGFloat) {
        let desired = liveCardWidth ?? CurtainPref.cardWidth
        let n = CGFloat(max(items.count, 1))
        let available = visible.width - 24

        var width = desired
        for _ in 0..<2 {
            let scale = railScale(for: width)
            let gap = CurtainMetrics.gap(scale)
            let pad = CurtainMetrics.padding(scale) * 2
            let fit = (available - gap * (n - 1) - pad) / n
            width = min(desired, max(CurtainPref.minCardWidth, fit))
        }
        let scale = railScale(for: width)
        let maxHeight = max(visible.height * 0.56
                            - CurtainMetrics.ropeHeight(scale)
                            - CurtainMetrics.bottomInset(scale), 60)
        return (width, scale, maxHeight)
    }

    /// 内容需要的尺寸（未夹到屏幕）
    private func contentSize(cardWidth: CGFloat, railScale: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard !items.isEmpty else { return CGSize(width: 200, height: 120) }
        let sizes = items.map {
            $0.cardSize(cardWidth: cardWidth, railScale: railScale, maxHeight: maxHeight)
        }
        let gap = CurtainMetrics.gap(railScale)
        let w = sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(items.count - 1, 0)) * gap
            + CurtainMetrics.padding(railScale) * 2
        let maxH = sizes.map(\.height).max() ?? 100
        return CGSize(width: w,
                      height: CurtainMetrics.ropeHeight(railScale) + maxH
                            + CurtainMetrics.bottomInset(railScale))
    }

    private func rebuild(animate: Bool = true, live: Bool = false) {
        guard let canvas else { return }
        let visible = Self.activeScreen().visibleFrame
        let metrics = layoutMetrics(visible: visible)
        let content = contentSize(cardWidth: metrics.cardWidth,
                                  railScale: metrics.railScale,
                                  maxHeight: metrics.maxHeight)
        let frame = windowFrame(for: content, visible: visible)
        // 拖动中不强制同步重绘：`display: true` 会让每个鼠标事件都在主线程
        // 把 8 张卡 + 帘线画完才返回，正是掉帧的来源；交给下一轮 runloop 合并。
        panel?.setFrame(frame, display: !live)
        panel?.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        canvas.frame = NSRect(origin: .zero, size: frame.size)
        let entries = items.map { ($0, thumbnails[$0.id]) }
        if live {
            canvas.updateLayout(items: entries,
                                cardWidth: metrics.cardWidth,
                                railScale: metrics.railScale,
                                maxCardHeight: metrics.maxHeight,
                                size: frame.size)
        } else {
            canvas.reload(items: entries,
                          cardWidth: metrics.cardWidth,
                          railScale: metrics.railScale,
                          maxCardHeight: metrics.maxHeight,
                          style: CurtainPref.ropeStyle,
                          size: frame.size,
                          animate: animate)
        }
    }

    /// ⌘ 拖动 / ⌘ 滚轮：只改临时宽度并原地重排，不写偏好（避免每帧一次 UserDefaults + 通知）
    private func resizeStep(_ delta: CGFloat) {
        guard !items.isEmpty else { return }
        let current = liveCardWidth ?? CurtainPref.cardWidth
        let next = min(max(current + delta, CurtainPref.minCardWidth), CurtainPref.maxCardWidth)
        guard abs(next - current) > 0.5 else { return }
        liveCardWidth = next
        rebuild(live: true)
        scheduleAutoHide()   // 调尺寸时别被倒计时收走
    }

    private func resizeEnd() {
        guard let width = liveCardWidth else { return }
        liveCardWidth = nil
        CurtainPref.cardWidth = width
        rebuild(animate: false)
        Toast.show("图帘大小 \(Int(width.rounded())) pt", icon: "arrow.up.left.and.arrow.down.right")
        upgradeThumbnailsIfNeeded()
    }

    /// 放大后原来的 640px 缩略图会糊。这里只重解一次，且只在确实不够用时。
    private func upgradeThumbnailsIfNeeded() {
        let target = CurtainPref.cardWidth
        guard target > 220, !items.isEmpty else { return }
        let needed = Int(target * 1.6)
        let stale = items.filter { (thumbnails[$0.id]?.width ?? 0) < needed }
        guard !stale.isEmpty else { return }
        let urls = stale.map { ($0.id, $0.fileURL) }
        Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { () -> [UUID: CGImage] in
                var result: [UUID: CGImage] = [:]
                for (id, url) in urls {
                    if let image = CurtainThumbnail.make(for: url, maxPixel: target) {
                        result[id] = image
                    }
                }
                return result
            }.value
            guard let self, !decoded.isEmpty else { return }
            for (id, image) in decoded { self.thumbnails[id] = image }
            if self.isShowing { self.rebuild(animate: false) }
        }
    }

    /// 贴在**鼠标所在屏幕**的可见区顶部（菜单栏下方），水平居中。
    private func windowFrame(for content: CGSize, visible: NSRect) -> NSRect {
        let width = max(min(content.width, visible.width - 24), 160)
        let height = min(content.height, visible.height - 40)
        let x = visible.midX - width / 2
        // visibleFrame.maxY 是菜单栏下沿；再往上就会被菜单栏压住
        let y = visible.maxY - height
        // v263：大卡片 + 多张时窗口宽度可能到几千 pt，x 会变成负数——夹回屏幕内
        let clampedX = min(max(x, visible.minX + 12), visible.maxX - width - 12)
        return NSRect(x: clampedX.rounded(), y: y.rounded(), width: width, height: height)
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
        let seconds = CurtainPref.displayDuration
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
        let on = CurtainPref.enabled
        defer { wasEnabled = on }

        guard on else {
            // 关掉 = 立刻消失，不留窗口、不留内容
            if wasEnabled { dismissAll() }
            return
        }
        guard wasEnabled else { return }   // 刚打开：等截图，不空show

        // 样式 / 宽度 / 数量变了：按新样子重排（原本收起的仍然保持收起）。
        // 不重播落入动画——设置页拖滑块的每一格都重播一次会像在闪。
        if isShowing {
            rebuild(animate: false)
            scheduleAutoHide()
        }
    }

    // MARK: - 卡片动作

    private static func saveAs(_ item: CurtainItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.fileURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? FileManager.default.copyItem(at: item.fileURL, to: url)
            Toast.show("已保存", icon: "checkmark.circle")
        }
    }

    private static func pin(_ item: CurtainItem) {
        guard let src = CGImageSourceCreateWithURL(item.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        _ = PinnedScreenshotManager.shared.show(image: image)
    }

    // MARK: - 排障自检

    /// 深链 `kitnest://curtainprobe?count=3` 调用（旧 `shelfprobe` 仍兼容）。
    ///
    /// 生成几张合成「截图」→ 上架 → 打印真实窗口尺寸 → 自动清理。
    /// 全程不碰鼠标、不修改用户偏好（用 forceEnabled 临时绕过总开关）。
    /// 存在的意义：截图链路必须人手框选，验收时没法自动化，这个入口把
    /// 「窗口位置 / 卡片排布 / 缩略图解码 / 自动收起」四件事都跑一遍。
    public func runProbe(count: Int = 3, capturable: Bool = false,
                         cardWidth: CGFloat? = nil, sweep: Bool = false) {
        forceEnabled = true
        // 排障可指定宽度：验证「⌘ 放大」后的帘线/卡片比例，不必真的拖鼠标
        if let cardWidth {
            liveCardWidth = min(max(cardWidth, CurtainPref.minCardWidth), CurtainPref.maxCardWidth)
        }
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
        Log.info("Curtain", "自检：生成 \(urls.count) 张测试图，开始上架（可截取=\(capturable)）")
        for url in urls { attach(url: url, manual: true) }
        if sweep {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.runResizeSweep()
            }
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            let frame = self.panel?.frame ?? .zero
            Log.info("Curtain", "自检：items=\(self.items.count) 可见=\(self.isShowing) 宽度=\(Int(self.liveCardWidth ?? CurtainPref.cardWidth)) "
                     + "窗口=\(Int(frame.width))x\(Int(frame.height)) "
                     + "位置=(\(Int(frame.minX)),\(Int(frame.minY)))")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self.panel?.sharingType = .none
            self.dismissAll()
            self.liveCardWidth = nil
            self.forceEnabled = false
            Log.info("Curtain", "自检：已清理")
        }
    }

    /// 缩放压测：从 140 扫到 420 再回来，每帧都走真实的 `rebuild(live:)` + 同步重绘，
    /// 记录单帧最大耗时。用来回答「⌘ 拖动时会不会掉帧」——不靠肉眼，靠数字。
    private func runResizeSweep() {
        let panel = self.panel
        var maxMs: Double = 0
        var totalMs: Double = 0
        var frames = 0
        let widths: [CGFloat] = stride(from: 140.0, through: 420.0, by: 20.0).map { CGFloat($0) }
            + stride(from: 420.0, through: 140.0, by: -20.0).map { CGFloat($0) }
        for width in widths {
            let t0 = CFAbsoluteTimeGetCurrent()
            liveCardWidth = width
            rebuild(live: true)
            // `display: false` 把绘制留给 runloop；压测要算「最坏一帧」，
            // 所以这里主动同步画一次，把 CoreGraphics 的成本也算进去。
            panel?.displayIfNeeded()
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            maxMs = max(maxMs, ms)
            totalMs += ms
            frames += 1
        }
        let avg = frames > 0 ? totalMs / Double(frames) : 0
        Log.info("Curtain", String(format: "自检：缩放扫频 %d 帧，单帧最大 %.2f ms，平均 %.2f ms（16.7 ms 为 60fps 预算）",
                                   frames, maxMs, avg))
        liveCardWidth = nil
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
