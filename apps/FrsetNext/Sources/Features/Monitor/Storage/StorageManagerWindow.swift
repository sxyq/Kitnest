import AppKit
import SwiftUI

extension Notification.Name {
    /// v212 排障深链：按名字下钻到某一层（kitnest://storage?drill=Users）
    static let storageDrillTo = Notification.Name("frsetnext.storage.drillTo")
    /// v212 排障深链：直接打开「让 Agent 清理」弹窗（kitnest://storage?agent=1）
    static let storageOpenAgent = Notification.Name("frsetnext.storage.openAgent")
}

// MARK: - 存储管理窗口（v211）
//
// 布局与交互按截图（Kanso）复刻：
//   顶部：大数字 + 一句说明 + 「重新扫描 / 工作记录 / 设置」；
//   左栏：可清理候选清单（勾选、全选、合计、清理所选）；
//   右栏：气泡地图 + 面包屑下钻 + 选中项详情 / 移到废纸篓。
// 配色全部换成我们自己的设计语言：统一玻璃窗、Theme.accent、Theme.Radius、
// 中性灰阶气泡、11pt 下限字号、Theme.Motion 动效——不引入截图里的米黄色板。
//
// 性能：窗口是单例且**只有点按钮才创建**，创建后才读缓存 / 才扫描；
// 不注册进 AppBootstrap、不参与启动、不常驻定时器。

public final class StorageManagerWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = StorageManagerWindowController()

    private init() {
        let hosting = NSHostingController(rootView: StorageManagerRootView())
        hosting.sizingOptions = []
        let win = NSWindow(contentViewController: hosting)
        win.title = "存储管理"
        win.setContentSize(NSSize(width: 1080, height: 720))
        win.minSize = NSSize(width: 860, height: 560)
        // v268：加 fullSizeContentView——右上工具条要顶到窗口最上沿，
        // 又不能盖住左上红绿灯（红绿灯是 AppKit 控件，仍在最上层）。
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.titleVisibility = .hidden   // v210 同款：避免标题画到最左压住红绿灯
        // v272：重启后第一条 kitnest://storage 深链把窗口开到了非活动 Space，
        // onScreenOnly 窗口列表里根本没有它（实测 02:18:40 深链静默无效）。
        // moveToActiveSpace 保证唤起时窗口落到当前 Space；fullScreenAuxiliary
        // 允许在全屏 Space 上以浮层形式出现。
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.applyOfficialChrome()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show(autoScan: Bool = false, drill: String? = nil, openAgent: Bool = false) {
        guard let window else {
            Log.warn("Storage", "show：window 尚未创建，深链无效")
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let f = window.frame
        Log.info("Storage", "show：\(Int(f.width))x\(Int(f.height)) @\(Int(f.minX)),\(Int(f.minY)) visible=\(window.isVisible)")
        // v211 排障：kitnest://storage?scan=1 —— 无人值守触发一次扫描（验证全盘索引/进度/截断提示）
        if autoScan { DiskIndexStore.shared.rescan() }
        // v212 排障：?drill=Users 下钻一层；?agent=1 直接开「让 Agent 清理」弹窗
        // （无 UI 自动化环境下点不了按钮，只能靠深链到达）
        if let drill {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NotificationCenter.default.post(name: .storageDrillTo, object: drill)
            }
        }
        if openAgent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                NotificationCenter.default.post(name: .storageOpenAgent, object: nil)
            }
        }
    }
}

/// 目录浏览区保留同一滚动监听器，切层动画不重建一次手势的状态。
/// v268：存储正文几何的唯一口径。
///
/// 背景：遮罩用「轮廓左移 12pt」，行宽却用未偏移轮廓再手减 12，
/// 卡片宽又单独按 0.50W 算——三处比例一旦有人改一处就会互相错位。
/// 现在全部由这里推导：改 tuck / seam / blobTopAnchor 一处，全局一致。
struct StorageBodyLayout {
    let region: CGSize
    var controlsHeight: CGFloat = 68
    /// 液面顶边在图框内的横向起点（与目录卡左缘对齐）。
    var blobTopAnchor: CGFloat = 0.50
    /// 图顶咬合深度：图上沿藏进目录卡背后多少 pt。
    var tuck: CGFloat = 6
    /// 清单与液面之间的呼吸缝（同时是清单 leading 内边距）。
    var seam: CGFloat = 12
    /// v274（用户：「整个方块按照我的曲线去占用」）：液面外轮廓整体向上抬，
    /// 顶边落在三个按钮下方、搜索/面包屑条上方；深色图块仍从搜索条下方开始。
    /// 96 = 顶边落在窗口 y≈112（按钮行底 ≈45，搜索卡顶 ≈128，中间留 16pt 横线）。
    var mapLift: CGFloat = 96
    /// 外轮廓顶边 → 深色图块画布顶边的浅色光条高度（搜索/面包屑卡所在）。
    /// 81 = 搜索卡下沿（窗口 y≈193）相对轮廓顶边 112 的距离。
    var tileInset: CGFloat = 81

    var mapTop: CGFloat { controlsHeight - tuck - mapLift }
    var mapSize: CGSize {
        CGSize(width: region.width, height: max(140, region.height - mapTop))
    }
    var listWidth: CGFloat { region.width * 0.48 }
    var listHeight: CGFloat {
        controlsHeight + max(0, region.height - controlsHeight) * 0.84
    }
    /// 目录卡宽 = 液面顶边左缘 → 卡与图天然连成一整块。
    var cardWidth: CGFloat { max(220, region.width * blobTopAnchor - 12) }

    var mapOutline: Path {
        StorageMapShape().path(in: CGRect(x: 0, y: mapTop,
                                          width: region.width,
                                          height: max(0, mapSize.height)))
    }
    /// 遮罩与行宽共用的轮廓：整体轮廓左移 seam。
    var seamOutline: Path { mapOutline.offsetBy(dx: -seam, dy: 0) }

    func listMask() -> Path {
        let bounds = CGPath(rect: CGRect(x: 0, y: 0,
                                         width: listWidth, height: listHeight),
                            transform: nil)
        return Path(bounds.subtracting(seamOutline.cgPath))
    }
}

private struct StorageSwipeRegion: NSViewRepresentable {
    let enabled: Bool
    let onNavigate: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        SwipeView(onNavigate: onNavigate)
    }

    func updateNSView(_ nsView: SwipeView, context: Context) {
        nsView.enabled = enabled
        nsView.onNavigate = onNavigate
    }

    final class SwipeView: NSView {
        private enum Axis { case pending, horizontal, vertical }

        var enabled = true
        var onNavigate: (Int) -> Void
        private var swipeMonitor: Any?
        private var delta = CGSize.zero
        private var swipeDidNavigate = false
        private var swipeAxis: Axis?
        private var lastEventAt: TimeInterval = 0
        private var hitPath = Path()
        private var hitBounds = CGRect.zero

        init(onNavigate: @escaping (Int) -> Void) {
            self.onNavigate = onNavigate
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let swipeMonitor {
                NSEvent.removeMonitor(swipeMonitor)
                self.swipeMonitor = nil
            }
            if window != nil { installSwipeMonitor() }
        }

        private func installSwipeMonitor() {
            swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, let window = self.window, window.isVisible,
                      event.window === window, event.momentumPhase.isEmpty else { return event }
                if self.bounds != self.hitBounds {
                    self.hitBounds = self.bounds
                    self.hitPath = StorageMapShape().path(in: self.bounds)
                }
                let now = ProcessInfo.processInfo.systemUptime
                // v266：兼容两类输入。触控板带 phase；鼠标横向滚轮 / 部分驱动没有 phase，
                // 用 260ms 静默当作新手势起点——旧实现只认 phase，这类设备完全划不动。
                let phaseStart = event.phase.contains(.began) || event.phase.contains(.mayBegin)
                let idleStart = event.phase.isEmpty && now - self.lastEventAt > 0.26
                if phaseStart || idleStart {
                    self.delta = .zero
                    self.swipeDidNavigate = false
                    let location = self.convert(event.locationInWindow, from: nil)
                    self.swipeAxis = self.hitPath.contains(location) ? .pending : nil
                }
                self.lastEventAt = now
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    let handled = self.swipeAxis == .horizontal
                    self.swipeAxis = nil
                    self.swipeDidNavigate = false
                    return handled ? nil : event
                }
                guard let axis = self.swipeAxis, axis != .vertical else { return event }
                if self.swipeDidNavigate { return nil }
                // 还原手指方向；系统「自然滚动」开关不改变「右滑返回 / 左滑前进」。
                self.delta.width += event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? -1 : 1)
                self.delta.height += event.scrollingDeltaY
                let dx = abs(self.delta.width)
                let dy = abs(self.delta.height)
                if axis == .pending {
                    guard max(dx, dy) >= 8 else { return event }
                    self.swipeAxis = dx > dy * 1.2 ? .horizontal : .vertical
                    guard self.swipeAxis == .horizontal else { return event }
                }
                // 一次手势只跳一层：命中后吞掉本手势余下事件（含回扫方向），
                // 松开后新起一次手势才继续 —— 「连续往返」仍逐层跟手，但不会一跳多级。
                // v267：阈值 32→28pt，轻扫更容易触发，轴判定仍要求横向占比 1.2 倍。
                if dx >= 28 {
                    self.swipeDidNavigate = true
                    let direction = self.delta.width > 0 ? -1 : 1
                    self.delta = .zero
                    self.onNavigate(direction)
                }
                return nil
            }
        }

        deinit {
            if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        }
    }
}

// MARK: - 根视图

struct StorageManagerRootView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store = DiskIndexStore.shared
    /// 每次实际进入的目录路径；游标两侧分别是返回、前进记录。
    @Stored private var directoryHistory: [[DiskNode]] = [[]]
    @Stored private var historyIndex = 0
    @Stored private var mapMotion: (anchor: UnitPoint, offset: CGFloat) = (.center, 0)
    /// v267：果冻系数。1 = 原状；切层瞬间压到 0.965（纵向 1.035）再弹回。
    /// 本工程 @State 宏不可用（SwiftUIMacros 缺失），按项目约定用 @Stored 兼容层。
    @Stored private var jelly: CGFloat = 1
    private var stack: [DiskNode] { directoryHistory[historyIndex] }
    @Stored private var selectedPaths: Set<String> = []
    @Stored private var detailNode: DiskNode?
    @Stored private var showDataCategories = false
    @Stored private var showRecords = false
    @Stored private var showSettings = false
    @Stored private var confirmTrash = false
    @Stored private var pendingTrash: [String] = []
    /// 让 Agent 清理：预览当前索引后复制提示词。
    @Stored private var showAgentSheet = false
    /// 深链下钻的待办：窗口刚显示时缓存可能还没读完（snapshot 为 nil），先记下来
    @Stored private var pendingDrill: String?

    private var currentNode: DiskNode? {
        if showDataCategories, let snap = store.snapshot {
            return DiskNode(path: "disk-categories", name: "系统数据分类", isDirectory: true,
                            size: snap.totalBytes, ownSize: 0, foldedCount: 0,
                            children: snap.dataCategories.map { $0.node }, isAggregate: true)
        }
        return stack.last ?? store.snapshot?.root
    }

    @Stored private var diskFreeBytes: Int64?
    @Stored private var volumeUsedBytes: Int64?
    @Stored private var hasFullDiskAccess = false

    private var candidates: [CleanupCandidate] { store.candidates() }

    private var selectedBytes: Int64 {
        DiskIndexStore.independentPaths(Array(selectedPaths)).reduce(Int64(0)) {
            $0 + (DiskIndexStore.findNode(store.snapshot?.root, path: $1)?.size ?? 0)
        }
    }

    /// 全部可清理项合计（大数字主指标——用户点开面板最想知道的就是「能腾出多少」）
    private var cleanableBytes: Int64 {
        candidates.reduce(Int64(0)) { $0 + $1.node.size }
    }

    /// 其中「确认后清理」的部分（常见缓存）
    private var safeBytes: Int64 {
        candidates.filter { $0.safe }.reduce(Int64(0)) { $0 + $1.node.size }
    }

    /// 磁盘整体已用（对比索引量用：两者差额来自系统卷 / TCC 保护目录 / APFS 快照）
    /// 磁盘「已用」字节数。
    ///
    /// 必须走数据卷 + `f_bfree`，两个坑（v264 实测）：
    /// 1. `attributesOfFileSystem(forPath: "/")` 的 systemSize−systemFreeSize
    ///    用的是 `f_bavail`，会把 33GB 系统保留空间算成已用，导致覆盖率凭空少 14%；
    /// 2. `/` 是只读系统卷（13GB），用户文件全在 `/System/Volumes/Data`。
    private func refreshDiskSpace() {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        diskFreeBytes = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
        hasFullDiskAccess = DiskScanScope.hasFullDiskAccess
        var s = statfs()
        guard statfs("/System/Volumes/Data", &s) == 0 else {
            // 老系统没有独立数据卷时退回 dome 口径
            if let a = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
               let total = (a[.systemSize] as? NSNumber)?.int64Value,
               let free = (a[.systemFreeSize] as? NSNumber)?.int64Value,
               total > free {
                volumeUsedBytes = total - free
            } else {
                volumeUsedBytes = nil
            }
            return
        }
        let total = Int64(s.f_blocks) * Int64(s.f_bsize)
        let free = Int64(s.f_bfree) * Int64(s.f_bsize)
        volumeUsedBytes = total > free ? total - free : nil
    }

    /// 覆盖度状态行（v264）。
    ///
    /// 用户原话：「它的那个清理的索引是不完整，就是没有索引到全盘，整个盘」。
    /// 光写「跳过 N 处不可读路径」看不出差多少，所以这里直接把
    /// **索引量 / 整盘已用** 并排摊开——差多少一眼就知道。
    private func statusLine(_ snap: DiskIndexSnapshot) -> String {
        var s = "\(DiskScanScope(rawValue: snap.scope)?.title ?? snap.scope) · \(StorageFormat.date(snap.scannedAt)) 扫描 · "
        s += snap.nodeCount >= 10_000
            ? "\(snap.nodeCount / 10_000) 万节点"
            : "\(snap.nodeCount) 个节点"
        if let used = volumeUsedBytes, used > 0 {
            s += " · 已索引 \(StorageFormat.shortBytes(snap.totalBytes))"
                + " / 整盘已用 \(StorageFormat.shortBytes(used))"
        }
        if snap.truncated == true {
            s += " · 已达 \(DiskIndexScanner.maxNodes) 节点上限"
        }
        return s
    }

    private var coverageHelp: String {
        guard let snap = store.snapshot else { return "尚未建立索引" }
        var lines = [
            "扫描根路径：\(snap.rootPath)（含隐藏目录）",
            "最多 \(DiskIndexScanner.maxDepth) 层、\(DiskIndexScanner.maxNodes) 个扫描条目；每目录保留最大 \(DiskIndexScanner.childrenPerDirectory) 项。",
            "沿用磁盘块占用口径；未读取或未索引的内容不补算字节。",
            "已跳过 \(snap.skippedCount) 处，含排除路径、符号链接和读取失败。",
            "APFS 快照与文件系统元数据不计入目录索引。",
        ]
        if !snap.excludedPaths.isEmpty {
            lines.append("本次排除目录及其后代：\n" + snap.excludedPaths.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        if let url { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .fixedSize(horizontal: false, vertical: true)
                // v274：液面外轮廓抬进 header 区域，按钮与左侧标题必须压在它上面。
                .zIndex(1)
            GeometryReader { region in
                // v268：正文几何的唯一口径。卡片宽、图框、清单宽、遮罩与行宽
                // 全部从同一个 layout 取值，遮罩和行右界用同一条 seam 轮廓，
                // 窗口缩放时不会再各算各的。
                let layout = StorageBodyLayout(region: region.size)
                let seamSampled = VoronoiTreemap.sampledPoints(layout.seamOutline, spacing: 12)
                ZStack(alignment: .topLeading) {
                    rightPane(contentTop: layout.tileInset)
                        .frame(width: layout.mapSize.width, height: layout.mapSize.height)
                        .overlay {
                            StorageSwipeRegion(enabled: !showDataCategories, onNavigate: navigateHistory(by:))
                                .allowsHitTesting(false)
                        }
                        // v274：外轮廓顶边抬到按钮下方。用 offset 而不是 padding——
                        // 负 padding 会改变兄弟视图的排版基准。
                        .offset(y: layout.mapTop)
                    VStack(alignment: .leading, spacing: 8) {
                        candidateControls
                            .frame(width: layout.listWidth - layout.seam)
                            .glassCard(radius: Theme.Radius.card)
                        leftPane(sampledOutline: seamSampled)
                            .glassCard(radius: Theme.Radius.card)
                    }
                    .frame(width: layout.listWidth, height: layout.listHeight)
                    .mask(layout.listMask())
                    .contentShape(layout.listMask())
                    .padding(.leading, layout.seam)
                    mapControls
                        .frame(width: layout.cardWidth, height: layout.controlsHeight)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                }
                .frame(width: region.size.width, height: region.size.height)
                .coordinateSpace(name: "storageCanvas")
                // v274：不再 clipped——液面要越过 GeometryReader 上沿伸进 header；
                // 窗口级裁剪仍由最外层 .clipped() 负责。
            }
            .zIndex(0)
        }
        // v268：fullSizeContentView 后内容从窗口最上沿开始；
        // 左列由 header 自身的 padding.top 24 让出红绿灯净空，这里只留一点边。
        .padding(.top, 8)
        .clipped()
        .onAppear {
            refreshDiskSpace()
            store.loadIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshDiskSpace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageDrillTo)) { note in
            guard let name = note.object as? String else { return }
            // v213 实测：深链在窗口刚建好时到达，onAppear 里的缓存读取是异步的，
            // 此时 snapshot 往往还是 nil，直接 return 会导致 drill 静默失效。
            // 有快照就立刻下钻，没有就挂起，等 snapshot 到位再执行。
            if let root = store.snapshot?.root,
               let target = root.children.first(where: { $0.name == name }) {
                navigate(to: [target])
                pendingDrill = nil
            } else {
                pendingDrill = name
            }
        }
        .onChange(of: store.indexRevision) { _ in
            refreshDiskSpace()
            directoryHistory = directoryHistory.map { path in
                path.compactMap { refreshedNavigationNode($0) }
            }
            selectedPaths = Set(selectedPaths.filter {
                DiskIndexStore.findNode(store.snapshot?.root, path: $0)?.isAggregate == false
            })
            if let d = detailNode {
                detailNode = store.snapshot?.dataCategories.first(where: { $0.id == d.id })?.node
                    ?? refreshedNavigationNode(d)
            }
            if let name = pendingDrill,
               let root = store.snapshot?.root,
               let target = root.children.first(where: { $0.name == name }) {
                navigate(to: [target])
                pendingDrill = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageOpenAgent)) { _ in
            showAgentSheet = true
        }
        .onChange(of: store.scope) { _ in
            directoryHistory = [[]]
            historyIndex = 0
        }
        .onChange(of: currentNode?.id) { _ in detailNode = nil }
        .onChange(of: showDataCategories) { _ in detailNode = nil }
        .onExitCommand {
            if store.isScanning { store.cancelScan() }
            else if showAgentSheet { showAgentSheet = false }
            else if showSettings { showSettings = false }
            else if showRecords { showRecords = false }
            else if detailNode != nil { detailNode = nil }
            else if showDataCategories { showDataCategories = false }
            else if historyIndex > 0 { navigateHistory(by: -1) }
            else { StorageManagerWindowController.shared.close() }
        }
        .alert("移到废纸篓？", isPresented: $confirmTrash) {
            Button("取消", role: .cancel) { pendingTrash = [] }
            Button("移到废纸篓", role: .destructive) { performTrash() }
        } message: {
            Text("将 \(pendingTrash.count) 项移到废纸篓（可从废纸篓恢复）。\n合计 \(StorageFormat.bytes(selectedBytesForPending()))")
        }
        .sheet(isPresented: $showRecords) { recordsSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showAgentSheet) { agentSheet }
        .overlay {
            if store.isScanning { scanningOverlay }
        }
    }

    // MARK: 顶部（大数字 + 说明 + 工具条）

    private var header: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                // 第一视觉层：能腾多少 + 三个占用口径并排。
                // padding.top 24 是给左上角红绿灯让位的净空（fullSizeContentView 后内容顶到 0）。
                HStack(alignment: .center, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(StorageFormat.shortBytes(cleanableBytes))
                            .font(.system(size: 38, weight: .light).monospacedDigit())
                        Text("清理候选")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    miniStat("已索引", store.snapshot?.totalBytes,
                             help: "本次索引覆盖的字节（区别于整盘实际已用）")
                    miniStat("整盘已用", volumeUsedBytes,
                             help: "数据卷实际占用，含索引未覆盖的系统卷 / TCC 保护目录")
                    miniStat("磁盘可用", diskFreeBytes,
                             help: "APFS 可用空间")
                    Spacer(minLength: 8)
                }
                .padding(.top, 24)
                if let snap = store.snapshot {
                    Text(statusLine(snap))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .help(coverageHelp)
                } else {
                    Text("尚未建立索引 · 点右上「建立索引」开始，结果保存在本地，平时不占资源")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
                if !hasFullDiskAccess {
                    HStack(spacing: 6) {
                        Text("未获完全磁盘访问权限：沙盒容器 / 邮件 / 照片 / 信息未计入")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(2)
                        Button("去授权") { openFullDiskAccessSettings() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .help("在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里勾上 Kitnest，"
                                  + "回来点「重新扫描」即可补全")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // v274（用户顶部箭头）：工具条再上移到与红绿灯同一行，
            // 给液面外轮廓让出按钮下方那条横线；-20pt 取自截图里按钮行与窗口顶的距离。
            HStack(spacing: 6) {
                toolbarButton("arrow.clockwise", store.snapshot == nil ? "建立索引" : "重新扫描") { store.rescan() }
                    .disabled(store.isScanning)
                toolbarButton("clock.arrow.circlepath", "工作记录") { showRecords = true }
                toolbarButton("gearshape", "设置") { showSettings = true }
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .offset(y: -20)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.bottom, 2)
    }

    /// 顶部第一层的并排小指标（标签在上、数值在下，等宽数字对齐）。
    private func miniStat(_ title: String, _ bytes: Int64?, help: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            Text(bytes.map { StorageFormat.shortBytes($0) } ?? "—")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
        .help(help)
    }

    private func toolbarButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14)
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .glassCard(radius: Theme.Radius.control)
        }
        .buttonStyle(.borderless)
        .help(title)
    }

    // MARK: 左栏（可清理清单）

    private var candidateControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("清理候选 · \(candidates.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                // 空清单不显示全选（否则一个 0 项也会显示「取消全选」，像是已选中了东西）
                if !candidates.isEmpty {
                    let all = Set(candidates.map { $0.id })
                    Button(all.isSubset(of: selectedPaths) ? "取消全选" : "全选") {
                        if all.isSubset(of: selectedPaths) { selectedPaths.subtract(all) }
                        else { selectedPaths.formUnion(all) }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("已选 \(DiskIndexStore.independentPaths(Array(selectedPaths)).count) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("父目录包含的子项只计一次")
                    Spacer()
                    Text(StorageFormat.bytes(selectedBytes))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }

                HStack(spacing: 8) {
                    // v212：不替用户做删除决策——生成提示词交给本地 Agent 判断
                    Button {
                        showAgentSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10.5))
                            Text("让 Agent 清理")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(Capsule(style: .continuous).fill(Theme.accent.opacity(0.10)))
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.22), lineWidth: 0.8))
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(store.snapshot == nil)
                    .help("把本次扫描明细整理成提示词，复制后粘给你本地的 Agent（Codex / Claude Code 等），由它判断怎么清")

                    Button {
                        pendingTrash = DiskIndexStore.independentPaths(Array(selectedPaths))
                        confirmTrash = true
                    } label: {
                        Text("移到废纸篓")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(Capsule(style: .continuous).fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(selectedPaths.isEmpty)
                    .opacity(selectedPaths.isEmpty ? 0.45 : 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03))

            Divider()
        }
    }

    /// v268：outline 直接传「seam 轮廓」的采样点，行右界与遮罩同源。
    private func leftPane(sampledOutline outline: [CGPoint]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if candidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.tertiaryText)
                    Text(store.snapshot == nil ? "尚未建立索引" : "没有发现明显的缓存目录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates) { c in
                            GeometryReader { row in
                                let frame = row.frame(in: .named("storageCanvas"))
                                let width = max(0, candidateWidth(at: frame.midY, outline: outline) - frame.minX)
                                StorageCandidateRow(candidate: c, compact: width < 180,
                                                    isSelected: selectedPaths.contains(c.id)) {
                                    if selectedPaths.contains(c.id) { selectedPaths.remove(c.id) }
                                    else { selectedPaths.insert(c.id) }
                                }
                                    .frame(width: width, alignment: .leading)
                                    .clipped()
                            }
                            .frame(height: 44)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func candidateWidth(at y: CGFloat, outline: [CGPoint]) -> CGFloat {
        var minX: CGFloat?
        for index in outline.indices {
            let a = outline[index]
            let b = outline[index + 1 == outline.count ? 0 : index + 1]
            if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                let x = a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
                minX = min(minX ?? x, x)
            }
        }
        return minX ?? 0
    }

    // MARK: 正文上方的目录操作区

    private var mapControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("查看", selection: $showDataCategories) {
                    Text("目录").tag(false)
                    Text("系统数据分类").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 120)
                if !showDataCategories {
                    Text("两指左滑返回 · 右滑前进")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("在液态图上横滑：一次手势只切一层，连续往返逐层跟手；竖向滚动不会触发")
                }
                Spacer(minLength: 4)
                if let node = currentNode {
                    Text(StorageFormat.bytes(node.size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(showDataCategories ? "面积按分类占用显示"
                              : "面积按实际占用显示，单文件从 100 MB 起索引")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 31)

            Divider().opacity(0.6)

            HStack(spacing: 6) {
                if showDataCategories {
                    Menu("分类") {
                        ForEach(store.snapshot?.dataCategories ?? []) { category in
                            Button("\(category.kind.title) · \(StorageFormat.bytes(category.bytes))") {
                                detailNode = category.node
                            }
                        }
                    }
                    .controlSize(.small)
                    Text("选择分类查看目录与范围")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach([-1, 1], id: \.self) { direction in
                        let enabled = directoryHistory.indices.contains(historyIndex + direction)
                        Button {
                            navigateHistory(by: direction)
                        } label: {
                            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(enabled ? Theme.accent : Theme.tertiaryText)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.primary.opacity(enabled ? 0.08 : 0.03)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .help(direction < 0 ? "返回上一目录（Esc / 两指左滑）" : "前进到下一目录（两指右滑）")
                        .keyboardShortcut(direction < 0 ? "[" : "]", modifiers: .command)
                    }

                    Button {
                        navigate(to: [])
                    } label: {
                        Text("根")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(stack.isEmpty ? .secondary : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(stack.isEmpty)

                    ForEach(Array(stack.enumerated()), id: \.offset) { entry in
                        let idx = entry.offset
                        let node = entry.element
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.tertiaryText)
                        Button {
                            navigate(to: Array(stack.prefix(idx + 1)))
                        } label: {
                            Text(node.name)
                                .font(.system(size: 11, weight: idx == stack.count - 1 ? .medium : .regular))
                                .foregroundStyle(idx == stack.count - 1 ? .secondary : Theme.accent)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 33)
        }
        .padding(.vertical, 1)
        .glassCard(radius: Theme.Radius.card)
    }

    // MARK: 正文画布（图形、清单遮罩和手势共用局部坐标）

    private func rightPane(contentTop: CGFloat) -> some View {
        GeometryReader { pane in
            ZStack(alignment: .topLeading) {
                if showDataCategories, let issue = store.snapshot?.categorySummaryIssue {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.tertiaryText)
                        Text("系统数据分类暂不可用")
                            .font(.system(size: 12, weight: .medium))
                        Text(issue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("现有目录索引仍可在“目录”视图查看。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("重新扫描") { store.rescan() }
                            .controlSize(.small)
                            .disabled(store.isScanning)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let node = currentNode {
                    StorageTreemap(node: node, selectedID: detailNode?.id,
                                   onDrill: { child, origin in
                                       if showDataCategories { detailNode = child }
                                       else { navigate(to: stack + [child], origin: origin) }
                                   },
                                   onSelect: { detailNode = detailNode?.id == $0.id ? nil : $0 },
                                   onBack: {
                                       if detailNode != nil { detailNode = nil }
                                       else if !showDataCategories { navigateHistory(by: -1) }
                                   },
                                   freeSpace: !showDataCategories && stack.isEmpty ? diskFreeBytes : nil,
                                   indexRevision: store.indexRevision,
                                   contentTop: contentTop)
                        .id(node.id)
                        // v266：Q 弹。旧版 0.82→1 的 springBouncy 太短，像淡入；
                        // 现在从被点块的中心涨开（0.55），回弹更慢更明显，
                        // 退场同时缩到 0.94 —— 连续往返时看得出「液态收拢再鼓起来」。
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.55, anchor: mapMotion.anchor)
                                .combined(with: .offset(x: mapMotion.offset))
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.94, anchor: mapMotion.anchor)
                                .combined(with: .opacity)))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.tertiaryText)
                        Text("索引不会在后台偷偷跑")
                            .font(.system(size: 12, weight: .medium))
                        Text("点下面的按钮才开始扫描；结果会写进本地缓存，下次打开直接读。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("建立索引") { store.rescan() }
                            .controlSize(.small)
                            .disabled(store.isScanning)
                    }
                    .padding(.leading, pane.size.width * 0.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StorageMapShape().fill(Color.primary.opacity(0.03)))
                }
            VStack(spacing: 0) {

            Spacer(minLength: 8)

            if let d = detailNode {
                if let category = store.snapshot?.dataCategories.first(where: { $0.id == d.id }) {
                    categoryDetail(category)
                        .padding(.leading, pane.size.width * 0.32 + 12)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                } else {
                VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(d.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        .help(d.name)
                    Spacer()
                    Text(StorageFormat.bytes(d.size))
                        .font(.system(size: 11).monospacedDigit())
                    if !d.isAggregate {
                    Button(selectedPaths.contains(d.path) ? "取消选择" : "加入所选") {
                        if selectedPaths.contains(d.path) { selectedPaths.remove(d.path) }
                        else { selectedPaths.insert(d.path) }
                    }
                    .controlSize(.small)
                    Button("在 Finder 显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.path)])
                    }
                    .controlSize(.small)
                    Button("移到废纸篓") {
                        pendingTrash = [d.path]
                        confirmTrash = true
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    }
                    Button { detailNode = nil } label: {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("关闭文件详情")
                }
                if d.isAggregate {
                    Text("聚合占用，仅供查看").font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    ScrollView {
                        Text(d.path).font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 32)
                }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .padding(.leading, pane.size.width * 0.32 + 12)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
                }
            }
            }
            .animation(reduceMotion ? nil : Theme.Motion.fast, value: detailNode?.id)
            }
            .clipShape(StorageMapShape())
            // v267：果冻回弹。切层时整张液面先被「压扁」再弹回，
            // X/Y 反向、低阻尼——和 0.55 涨开叠加后能看出两次回弹。
            .scaleEffect(x: jelly, y: 2 - jelly, anchor: mapMotion.anchor)
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.55), value: currentNode?.id)
        }
    }

    private func categoryDetail(_ category: DiskDataCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(category.kind.title).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text(StorageFormat.bytes(category.bytes)).font(.system(size: 11).monospacedDigit())
                Button { detailNode = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            Text("扫描根路径：\(store.snapshot?.rootPath ?? "")；分类合计 = 已索引 \(StorageFormat.bytes(store.snapshot?.totalBytes ?? 0))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    Text("各路径字节只计入本分类；嵌套分类已从上级路径中扣除。分类总量为各路径字节之和。")
                    if let paths = category.pathBytes {
                        if paths.isEmpty { Text("本次索引没有此类占用") }
                        ForEach(paths) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.path)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(StorageFormat.bytes(item.bytes))
                                    .font(.system(size: 11).monospacedDigit())
                            }
                        }
                    } else {
                        Text("此缓存缺少逐路径字节，请重新扫描。")
                    }
                    Text("其他类包含剩余已索引内容。分类用于查看，应用支持与系统资料不会自动加入清理推荐。")
                    Text(coverageHelp)
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 130)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    /// 展示层的「其他」分组不写入索引，沿现有成员更新导航记录。
    private func refreshedNavigationNode(_ node: DiskNode) -> DiskNode? {
        if let current = DiskIndexStore.findNode(store.snapshot?.root, path: node.path) { return current }
        guard node.isAggregate else { return nil }
        if node.path.hasPrefix("disk-files:") {
            let path = String(node.path.dropFirst("disk-files:".count))
            guard let parent = DiskIndexStore.findNode(store.snapshot?.root, path: path), parent.ownSize > 0 else { return nil }
            var current = node
            current.size = parent.ownSize
            current.ownSize = parent.ownSize
            return current
        }
        var current = node
        current.children = node.children.compactMap { refreshedNavigationNode($0) }
            .sorted { $0.size > $1.size }
        current.size = current.ownSize + current.children.reduce(Int64(0)) { $0 + $1.size }
        guard !current.children.isEmpty else { return nil }
        current.foldedCount = current.children.count
        current.name = "其他 \(current.children.count) 项"
        return current
    }

    private func navigate(to path: [DiskNode], origin: UnitPoint? = nil) {
        showDataCategories = false
        guard path.last?.id != stack.last?.id else { return }
        let forward = path.count >= historyIndex
        mapMotion = (origin ?? (forward ? .trailing : .leading), origin == nil ? (forward ? 28 : -28) : 0)
        if path.map(\.id) != stack.prefix(path.count).map(\.id) {
            directoryHistory = (0...path.count).map { Array(path.prefix($0)) }
        }
        historyIndex = path.count
        jellyPulse()
    }

    private func navigateHistory(by direction: Int) {
        let next = historyIndex + direction
        guard directoryHistory.indices.contains(next) else { return }
        mapMotion = (direction > 0 ? .trailing : .leading, direction > 0 ? 28 : -28)
        historyIndex = next
        jellyPulse()
    }

    /// v267：先无动画压扁，再低阻尼弹回——「Q 弹」的关键是两次回弹而不是一次淡入。
    private func jellyPulse() {
        guard !reduceMotion else { return }
        jelly = 0.965
        withAnimation(.spring(response: 0.5, dampingFraction: 0.4)) { jelly = 1 }
    }

    // MARK: 让 Agent 清理（v212）

    /// 跨层级取最大的目录：作为「详细占用日志」喂给 Agent（父子会同时出现，属正常）
    private func topDirectories(limit: Int = 12) -> [DiskNode] {
        guard let root = store.snapshot?.root else { return [] }
        var all: [DiskNode] = []
        func visit(_ n: DiskNode, depth: Int) {
            guard depth < 4 else { return }
            for c in n.children where c.isDirectory && c.size > 0 {
                all.append(c)
                visit(c, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return all.sorted { $0.size > $1.size }.prefix(limit).map { $0 }
    }

    /// 结构化提示词：扫描概况 + 可清理候选 + 最大目录 + 明确的执行纪律
    private func buildAgentPrompt() -> String {
        let snap = store.snapshot
        var lines: [String] = []

        lines.append("你是一个运行在我 Mac 上的命令行 AI Agent，协助我清理磁盘。")
        lines.append("")
        lines.append("下面是这台 Mac 的磁盘索引快照。请逐项判断：哪些可以安全删除、"
                     + "哪些需要我确认、哪些绝对不要动，并给出可执行命令。")
        lines.append("")
        lines.append("## 扫描概况")
        if let snap {
            lines.append("- \(statusLine(snap))")
        }
        lines.append(coverageHelp)
        lines.append("")
        lines.append("## 可清理候选（App 按常见缓存目录名筛出，共 \(candidates.count) 项，按大小降序）")
        if candidates.isEmpty {
            lines.append("（本次没有筛出候选，请看下面的目录占用自行判断）")
        }
        for (i, c) in candidates.enumerated() {
            lines.append("\(i + 1). \(c.node.name) — \(StorageFormat.bytes(c.node.size))"
                         + " — \(c.node.path) — \(c.safe ? "常见缓存" : "需确认")")
        }
        lines.append("")
        let tops = topDirectories()
        lines.append("## 占用最大的目录（跨层级 Top \(tops.count)）")
        for (i, n) in tops.enumerated() {
            lines.append("\(i + 1). \(n.path) — \(StorageFormat.bytes(n.size))")
        }
        lines.append("")
        lines.append("## 请你做的事")
        lines.append("1. **逐个目录看清里面到底是什么**：对每一项跑 `ls -la <路径>` 和 "
                     + "`du -sh <路径>/*`，把子项按大小列出来；说明每个文件/子目录是什么、"
                     + "由哪个工具或 App 生成、能否重建。")
        lines.append("2. **结论必须具体到文件**，不能只说「这个目录可以清」：")
        lines.append("   每条给：完整路径、大小、一句话说明它是什么、删了会怎样"
                     + "（能否重建 / 影响哪个 App / 是否含用户数据/登录态/项目源码）。")
        lines.append("3. **分三档判定**：✅ 可安全删除 / ⚠️ 需我确认 / ⛔ 不要动，每条都写依据。")
        lines.append("4. **给可执行命令**：优先 `mv <路径> ~/.Trash/`，不要 `rm -rf`；")
        lines.append("   一条一行，行尾注释写明删的是什么。")
        lines.append("5. **报告结构**：先给一张总表（目录 | 大小 | 判定 | 预计释放），再逐目录展开明细；")
        lines.append("   最后给合计：能删多少、需确认多少、建议保留多少。")
        lines.append("6. **先只给方案，不要执行**。等我逐条确认后再动手，每执行一条回报结果。")
        lines.append("7. **信息不足就问**：直接说「请跑 `du -sh <路径>/*` 把结果贴给我」，不要猜。")
        return lines.joined(separator: "\n")
    }

    private func copyAgentPrompt() {
        let text = buildAgentPrompt()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showAgentSheet = false
        Toast.show("提示词已复制，粘给 Agent 即可", icon: "doc.on.doc")
    }

    private var agentSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("让 Agent 清理")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("关闭") { showAgentSheet = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Text("App 不替你删。它会生成一段包含本次扫描明细的提示词，"
                 + "复制后粘给你本地的 Agent，由它判断哪些能清、怎么清。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // v228（用户：「不用分成多个客户端的 Codex，只需要留一个框」）：
            // 去掉客户端选择器，提示词对所有 Agent 通用，复制走人。
            ScrollView {
                Text(buildAgentPrompt())
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(height: 250)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )

            HStack {
                Text("复制后粘到你的 Agent 里，它会按提示词逐项判断。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button {
                    copyAgentPrompt()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10.5))
                        Text("复制提示词").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule(style: .continuous).fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding(16)
        .frame(width: 580, height: 470)
    }

    // MARK: 弹层

    private var scanningOverlay: some View {
        ZStack {
            Color.black.opacity(0.12)
            VStack(spacing: 10) {
                ProgressView()
                Text("正在建立磁盘索引…")
                    .font(.system(size: 12, weight: .medium))
                Text(store.progressText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 380)
                Button("取消") { store.cancelScan() }
                    .controlSize(.small)
            }
            .padding(20)
            .glassCard(radius: Theme.Radius.card)
        }
    }

    private var recordsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("工作记录").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("完成") { showRecords = false }.buttonStyle(.plain)
            }
            .padding(14)
            Divider()
            if store.records.isEmpty {
                Text("还没有清理记录")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.records) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(StorageFormat.date(r.at)) · \(r.paths.count) 项 · "
                                     + StorageFormat.bytes(r.bytes)
                                     + (r.succeeded ? "" : "（部分失败）"))
                                    .font(.system(size: 11, weight: .medium))
                                ForEach(r.paths.prefix(4), id: \.self) { p in
                                    Text(p).font(.system(size: 11))
                                        .foregroundStyle(Theme.tertiaryText).lineLimit(1)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 420, height: 340)
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设置").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("完成") { showSettings = false }.buttonStyle(.plain)
            }
            Divider()
            Text("扫描范围").font(.system(size: 11.5, weight: .medium))
            Picker("", selection: $store.scope) {
                ForEach(DiskScanScope.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.radioGroup)
            Text("扫描包含以「.」开头的隐藏目录与所有子目录，不限深度（v264 起不再在第 6 层截断）；"
                 + "符号链接不跟随，APFS 本地快照与交换文件不计入。"
                 + "受系统 TCC 保护的目录（音乐/照片/邮件/信息/钥匙串/沙盒容器）在没有「完全磁盘访问权限」时会被跳过——"
                 + "不是漏扫，是系统不让读；授权后重扫即完整。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !hasFullDiskAccess {
                Button {
                    openFullDiskAccessSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.open").font(.system(size: 10.5))
                        Text("打开「完全磁盘访问权限」设置").font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            Divider()
            HStack {
                Button("清除索引缓存") { store.clearCache() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                Spacer()
                Text("索引只在打开本窗口时加载，关闭后不参与任何后台刷新。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    // MARK: 动作

    private func selectedBytesForPending() -> Int64 {
        DiskIndexStore.independentPaths(pendingTrash).reduce(Int64(0)) { sum, p in
            sum + (DiskIndexStore.findNode(store.snapshot?.root, path: p)?.size ?? 0)
        }
    }

    private func performTrash() {
        let paths = pendingTrash
        pendingTrash = []
        guard !paths.isEmpty else { return }
        store.trash(paths: paths) { ok, bytes in
            if let error = store.lastError {
                Toast.show("已移动 \(ok) 项；\(error)",
                           icon: "exclamationmark.triangle", isWarning: true)
            } else {
                Toast.show("已将 \(ok) 项移到废纸篓 · \(StorageFormat.bytes(bytes))",
                           icon: "trash")
            }
        }
    }
}

private struct StorageCandidateRow: View {
    let candidate: CleanupCandidate
    let compact: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Stored private var isHovered = false

    /// 清单副行显示相对 home 的短路径：同名 Caches/cache 靠路径才能区分开
    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(candidate.node.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        if !compact {
                            Text(candidate.safe ? "缓存" : "需确认")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    if compact {
                        Text(StorageFormat.shortBytes(candidate.node.size))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(candidate.safe ? Theme.accent.opacity(0.7) : Color.orange)
                                .frame(width: 4, height: 4)
                            Text(displayPath(candidate.node.path))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                Spacer(minLength: 4)
                if !compact {
                    Text(StorageFormat.shortBytes(candidate.node.size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.09)
                          : isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .animation(reduceMotion ? nil : Theme.Motion.tap, value: isSelected)
        .help("\(candidate.reason) · \(StorageFormat.bytes(candidate.node.size)) · \(candidate.node.path)")
        .contextMenu {
            Button("在 Finder 显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.node.path)])
            }
        }
    }
}
