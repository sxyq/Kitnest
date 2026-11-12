import AppKit
import SwiftUI

extension Notification.Name {
    /// v212 排障深链：按名字下钻到某一层（kitnest://storage?drill=Users）
    static let storageDrillTo = Notification.Name("frsetnext.storage.drillTo")
    /// v212 排障深链：直接打开「让 Agent 清理」弹窗（kitnest://storage?agent=1）
    static let storageOpenAgent = Notification.Name("frsetnext.storage.openAgent")
}

/// v212（用户：「让 Agent 清理这个选项需要询问用户调用 Codex 还是什么，
/// 复制成一个个提示词，让本地 Agent 根据提示词判断」）
///
/// App 自己不替用户做删除决策：只把扫描明细整理成一段结构化提示词，
/// 用户选目标 Agent → 复制 → 粘过去，由那个 Agent 判断哪些能清。
enum CleanupAgent: String, CaseIterable, Identifiable {
    case codex
    case claudeCode
    case cursor
    case generic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .generic: return "通用"
        }
    }

    var roleLine: String {
        switch self {
        case .codex:
            return "你是 Codex（OpenAI 命令行编码 Agent），正在我的 Mac 上协助清理磁盘。"
        case .claudeCode:
            return "你是 Claude Code（Anthropic 命令行 Agent），正在我的 Mac 上协助清理磁盘。"
        case .cursor:
            return "你是 Cursor 里的编码 Agent，正在我的 Mac 上协助清理磁盘。"
        case .generic:
            return "你是一个运行在我 Mac 上的命令行 AI Agent，协助我清理磁盘。"
        }
    }
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
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.titleVisibility = .hidden   // v210 同款：避免标题画到最左压住红绿灯
        win.applyOfficialChrome()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show(autoScan: Bool = false, drill: String? = nil, openAgent: Bool = false) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

/// SwiftUI 按钮会消化滚动事件，保留原 local monitor，只把范围收到图形轮廓。
private struct StorageSwipeRegion: NSViewRepresentable {
    let onNavigate: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        SwipeView(onNavigate: onNavigate)
    }

    func updateNSView(_ nsView: SwipeView, context: Context) {
        nsView.onNavigate = onNavigate
    }

    final class SwipeView: NSView {
        var onNavigate: (Int) -> Void
        private var swipeMonitor: Any?
        private var swipeAccum: CGFloat = 0
        private var swipeDidNavigate = false

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
                guard let self, let window = self.window, event.window === window else { return event }
                if event.phase.contains(.began) {
                    self.swipeAccum = 0
                    self.swipeDidNavigate = false
                }
                guard event.hasPreciseScrollingDeltas, !event.phase.isEmpty,
                      event.momentumPhase.isEmpty else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard StorageMapShape().path(in: self.bounds).contains(location) else {
                    self.swipeAccum = 0
                    return event
                }
                // 还原手指方向，系统自然滚动设置不改变「左退右进」。
                let dx = event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
                guard abs(dx) > abs(event.scrollingDeltaY) * 1.2 else { return event }
                self.swipeAccum += dx
                if abs(self.swipeAccum) >= 42, !self.swipeDidNavigate {
                    self.swipeDidNavigate = true
                    self.onNavigate(self.swipeAccum < 0 ? -1 : 1)
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
    @Stored private var hoveredCandidatePath: String?
    /// 每次实际进入的目录路径；游标两侧分别是返回、前进记录。
    @Stored private var directoryHistory: [[DiskNode]] = [[]]
    @Stored private var historyIndex = 0
    private var stack: [DiskNode] { directoryHistory[historyIndex] }
    @Stored private var selectedPaths: Set<String> = []
    @Stored private var detailNode: DiskNode?
    @Stored private var showRecords = false
    @Stored private var showSettings = false
    @Stored private var confirmTrash = false
    @Stored private var pendingTrash: [String] = []
    /// 让 Agent 清理：询问目标 Agent + 预览提示词
    @Stored private var showAgentSheet = false
    @Stored private var agentKind: CleanupAgent = .generic
    /// 深链下钻的待办：窗口刚显示时缓存可能还没读完（snapshot 为 nil），先记下来
    @Stored private var pendingDrill: String?
    /// 首次进面板是否已经自动落到有内容的一层
    @Stored private var didAutoLand = false
    /// v229：首次打开时的手势提示（只提示一次）
    /// 注意：本 target 的 Swift 工具链缺 SwiftUIMacros 插件，`@State` 编译不过，
    /// 临时状态一律用 @AppStorage / @Stored 承载。
    @AppStorage("storage.swipeHintShown") private var swipeHintShown = false
    @AppStorage("storage.swipeHintVisible") private var showSwipeHint = false

    private var currentNode: DiskNode? {
        stack.last ?? store.snapshot?.root
    }

    @Stored private var diskFreeBytes: Int64?

    private func refreshDiskSpace() {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        diskFreeBytes = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private var candidates: [CleanupCandidate] { store.candidates() }

    private var selectedBytes: Int64 {
        candidates.filter { selectedPaths.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.node.size }
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
    private var volumeUsedBytes: Int64? {
        var s = statfs()
        guard statfs("/System/Volumes/Data", &s) == 0 else {
            // 老系统没有独立数据卷时退回 dome 口径
            guard let a = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
                  let total = (a[.systemSize] as? NSNumber)?.int64Value,
                  let free = (a[.systemFreeSize] as? NSNumber)?.int64Value,
                  total > free else { return nil }
            return total - free
        }
        let total = Int64(s.f_blocks) * Int64(s.f_bsize)
        let free = Int64(s.f_bfree) * Int64(s.f_bsize)
        guard total > free else { return nil }
        return total - free
    }

    private var volumeUsedText: String? {
        volumeUsedBytes.map { "磁盘已用 \(StorageFormat.shortBytes($0))" }
    }

    /// 覆盖度状态行（v264）。
    ///
    /// 用户原话：「它的那个清理的索引是不完整，就是没有索引到全盘，整个盘」。
    /// 光写「跳过 N 处不可读路径」看不出差多少，所以这里直接把
    /// **索引量 / 整盘已用** 并排摊开——差多少一眼就知道。
    private func statusLine(_ snap: DiskIndexSnapshot) -> String {
        var s = "\(store.scope.title) · \(StorageFormat.date(snap.scannedAt)) 扫描 · "
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
        var lines = [
            "索引口径（v264 实测对照）：",
            "· 不限深度。/Applications 索引 22.4G，du -sh 实测 22G —— 对上了",
            "· 含隐藏目录（.workbuddy 17.2G、.cursor、.npm …）与全部 ~/Library",
            "· 含系统只读卷；不含 /System/Volumes（那是 /Users 的另一张脸，算了会翻倍）",
            "· 大小按磁盘实际块计（st_blocks），与 df/du 同一口径",
        ]
        if !DiskScanScope.hasFullDiskAccess {
            lines.append("· 缺口的最大一块是 ~/Library/Containers（沙盒容器，本机 du 实测 33G）、"
                         + "邮件/照片/信息——系统不让读，不是漏扫")
        }
        lines.append("· 整盘已用还含 APFS 本地快照、交换文件与文件系统元数据，"
                     + "它们不在任何目录里，索引天然覆盖不到")
        return lines.joined(separator: "\n")
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// 清单副行显示相对 home 的短路径：同名 Caches/cache 靠路径才能区分开
    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    var body: some View {
        GeometryReader { viewport in
            ZStack(alignment: .topLeading) {
                rightPane
                VStack(alignment: .leading, spacing: 8) {
                    header(width: viewport.size.width)
                    GeometryReader { region in
                        let top = region.frame(in: .named("storageCanvas")).minY
                        leftPane(canvas: viewport.size)
                            .frame(width: viewport.size.width * 0.48,
                                   height: viewport.size.height * 0.84 - top)
                            .glassCard(radius: Theme.Radius.card)
                            .mask {
                                GeometryReader { local in
                                    let origin = local.frame(in: .named("storageCanvas")).origin
                                    Path { path in
                                        path.addRect(CGRect(origin: .zero, size: local.size))
                                        path.addPath(StorageMapShape().path(in: CGRect(origin: .zero, size: viewport.size))
                                            .offsetBy(dx: -origin.x, dy: -origin.y))
                                    }
                                    .fill(style: FillStyle(eoFill: true))
                                }
                            }
                            .padding(.leading, 12)
                    }
                }
            }
        }
        .coordinateSpace(name: "storageCanvas")
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            refreshDiskSpace()
            store.loadIfNeeded()
            autoLandIfNeeded()
            // 第一次打开时提示图形内的目录手势。
            // 注意：onAppear 可能被调用多次，这里用 swipeHintShown 兜住，
            // 不能在里面先写 showSwipeHint = false——第二次 onAppear 会把提示立刻清掉。
            guard !swipeHintShown else { return }
            swipeHintShown = true
            showSwipeHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                showSwipeHint = false
            }
        }
        .overlay(alignment: .bottom) {
            if showSwipeHint {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 13, weight: .medium))
                    Text("图形内两指左滑返回，右滑前进")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.76)))
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.fast, value: showSwipeHint)
        .onReceive(NotificationCenter.default.publisher(for: .storageDrillTo)) { note in
            guard let name = note.object as? String else { return }
            // v213 实测：深链在窗口刚建好时到达，onAppear 里的缓存读取是异步的，
            // 此时 snapshot 往往还是 nil，直接 return 会导致 drill 静默失效。
            // 有快照就立刻下钻，没有就挂起，等 snapshot 到位再执行。
            if let root = store.snapshot?.root,
               let target = root.children.first(where: { $0.name == name }) {
                navigate(to: drillChain(to: target))
                pendingDrill = nil
            } else {
                pendingDrill = name
            }
        }
        .onChange(of: store.snapshot?.scannedAt) { _ in
            refreshDiskSpace()
            directoryHistory = directoryHistory.map { path in
                path.compactMap { DiskIndexStore.findNode(store.snapshot?.root, path: $0.path) }
            }
            selectedPaths.formIntersection(Set(candidates.map { $0.id }))
            detailNode = nil
            if let name = pendingDrill,
               let root = store.snapshot?.root,
               let target = root.children.first(where: { $0.name == name }) {
                navigate(to: drillChain(to: target))
                pendingDrill = nil
                didAutoLand = true
                return
            }
            autoLandIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageOpenAgent)) { _ in
            showAgentSheet = true
        }
        .onChange(of: store.scope) { _ in
            directoryHistory = [[]]
            historyIndex = 0
            store.reloadFromCache(autoScanIfMissing: false)
        }
        .onChange(of: currentNode?.id) { _ in detailNode = nil }
        .onExitCommand {
            if store.isScanning { store.cancelScan() }
            else if showAgentSheet { showAgentSheet = false }
            else if showSettings { showSettings = false }
            else if showRecords { showRecords = false }
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

    private func header(width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(StorageFormat.shortBytes(cleanableBytes))
                        .font(.system(size: 40, weight: .light).monospacedDigit())
                    Text("清理候选")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(headline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let snap = store.snapshot {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusLine(snap))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                            .help(coverageHelp)
                        if !DiskScanScope.hasFullDiskAccess {
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
                }
            }
            .frame(width: width * 0.44 - 20, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if store.snapshot == nil, !store.isScanning {
                    Button {
                        store.rescan()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "externaldrive").font(.system(size: 12))
                            Text("建立索引").font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule(style: .continuous).fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                toolbarButton("arrow.clockwise", "重新扫描") { store.rescan() }
                    .disabled(store.isScanning)
                toolbarButton("clock.arrow.circlepath", "工作记录") { showRecords = true }
                toolbarButton("gearshape", "设置") { showSettings = true }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var headline: String {
        guard let snap = store.snapshot else {
            return "尚未建立索引 · 点「建立索引」开始，结果保存在本地，平时不占资源"
        }
        return "已索引 \(StorageFormat.shortBytes(snap.totalBytes))"
            + " · 共 \(candidates.count) 处可清理位置，其中 \(StorageFormat.shortBytes(safeBytes)) 是常见缓存"
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

    private func leftPane(canvas: CGSize) -> some View {
        let outline = VoronoiTreemap.sampledPoints(
            StorageMapShape().path(in: CGRect(origin: .zero, size: canvas)), spacing: 12)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("清理候选 · \(candidates.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                // 空清单不显示全选（否则一个 0 项也会显示「取消全选」，像是已选中了东西）
                if !candidates.isEmpty {
                    Button(selectedPaths.count == candidates.count ? "取消全选" : "全选") {
                        if selectedPaths.count == candidates.count { selectedPaths.removeAll() }
                        else { selectedPaths = Set(candidates.map { $0.id }) }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: canvas.width * 0.40 - 24)

            Divider().frame(width: canvas.width * 0.40 - 24)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("已选 \(selectedPaths.count) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                        pendingTrash = Array(selectedPaths)
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
            .frame(width: canvas.width * 0.40 - 24)

            Divider().frame(width: canvas.width * 0.40 - 24)
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
                                let width = max(0, candidateWidth(at: frame.midY, outline: outline) - frame.minX - 12)
                                candidateRow(c, compact: width < 180)
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
        zip(outline, outline.dropFirst() + [outline[0]]).compactMap { a, b -> CGFloat? in
            if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                return a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)
            }
            return nil
        }.min() ?? 0
    }

    private func candidateRow(_ c: CleanupCandidate, compact: Bool) -> some View {
        Button {
            if selectedPaths.contains(c.id) { selectedPaths.remove(c.id) }
            else { selectedPaths.insert(c.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedPaths.contains(c.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(selectedPaths.contains(c.id) ? Theme.accent : Theme.tertiaryText)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(c.node.name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        if !compact {
                            Text(c.safe ? "缓存" : "需确认")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    if compact {
                        Text(StorageFormat.shortBytes(c.node.size))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                        Circle()
                            .fill(c.safe ? Theme.accent.opacity(0.7) : Color.orange)
                            .frame(width: 4, height: 4)
                        Text(displayPath(c.node.path))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.head)
                        }
                    }
                }
                Spacer(minLength: 4)
                if !compact {
                    Text(StorageFormat.shortBytes(c.node.size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(selectedPaths.contains(c.id) ? Theme.accent.opacity(0.09)
                          : hoveredCandidatePath == c.id ? Color.primary.opacity(0.04) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredCandidatePath = c.id }
            else if hoveredCandidatePath == c.id { hoveredCandidatePath = nil }
        }
        .accessibilityValue(selectedPaths.contains(c.id) ? "已选择" : "未选择")
        .animation(reduceMotion ? nil : Theme.Motion.tap, value: selectedPaths.contains(c.id))
        .help("\(c.reason) · \(StorageFormat.bytes(c.node.size)) · \(c.node.path)")
        .contextMenu {
            Button("在 Finder 显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.node.path)])
            }
        }
    }

    // MARK: 全窗口画布（面包屑与详情浮在图形上）

    private var rightPane: some View {
        GeometryReader { pane in
            ZStack(alignment: .topLeading) {
                if let node = currentNode {
                    StorageTreemap(node: node,
                                   onDrill: { child in navigate(to: stack + drillChain(to: child)) },
                                   onSelect: { detailNode = $0 },
                                   onBack: { navigateHistory(by: -1) },
                                   freeSpace: stack.isEmpty ? diskFreeBytes : nil)
                        .id(node.id)
                        .transition(.opacity)
                        .background(StorageSwipeRegion(onNavigate: { navigateHistory(by: $0) }))
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
            // 目录按钮、快捷键、图形手势共用同一访问历史。
            HStack(spacing: 6) {
                ForEach([-1, 1], id: \.self) { direction in
                    let enabled = directoryHistory.indices.contains(historyIndex + direction)
                    Button {
                        navigateHistory(by: direction)
                    } label: {
                        Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(enabled ? Theme.accent : Theme.tertiaryText)
                            .frame(width: 28, height: 28)
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
                Spacer(minLength: 4)
                if let node = currentNode {
                    Text(StorageFormat.bytes(node.size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                        .help("本层合计")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .padding(.leading, pane.size.width * 0.52)
            .padding(.trailing, 12)
            .padding(.top, 64)
            .animation(reduceMotion ? nil : Theme.Motion.fast, value: stack.count)

            HStack(spacing: 6) {
                Text(stack.isEmpty ? "面积 = 已索引占用与磁盘可用空间" : "面积 = 本层各项占用")
                Spacer()
                Text("左滑返回 · 右滑前进")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .padding(.leading, pane.size.width * 0.52)
            .padding(.trailing, 12)
            .padding(.top, 6)

            Spacer(minLength: 8)

            if let d = detailNode {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(d.path).font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText).lineLimit(1)
                    }
                    Spacer()
                    Text(StorageFormat.bytes(d.size))
                        .font(.system(size: 11).monospacedDigit())
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
                    Button { detailNode = nil } label: {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("关闭文件详情")
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .padding(.leading, pane.size.width * 0.32 + 12)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
            }
            .animation(reduceMotion ? nil : Theme.Motion.fast, value: currentNode?.id)
            .animation(reduceMotion ? nil : Theme.Motion.fast, value: detailNode?.id)
            }
        }
    }

    private func navigate(to path: [DiskNode]) {
        guard path.last?.id != stack.last?.id else { return }
        directoryHistory = Array(directoryHistory.prefix(historyIndex + 1)) + [path]
        historyIndex += 1
    }

    private func navigateHistory(by direction: Int) {
        let next = historyIndex + direction
        guard directoryHistory.indices.contains(next) else { return }
        historyIndex = next
    }

    /// 顺着一串「几乎只剩一个子目录」的层级走到底（v212）
    ///
    /// 实测：`/Users` 下除了 sunyiyang(30.9G) 还有 Shared 等几个极小目录，
    /// 所以「只有一个子项」的条件并不成立，但视觉上这一层就是一个整块。
    /// 改成按占比判定：最大子目录占本层 > 90% 就继续穿透（最多 4 层）。
    private func drillChain(to node: DiskNode) -> [DiskNode] {
        var chain = [node]
        var current = node
        while chain.count < 4, current.size > 0,
              let biggest = current.children.filter({ $0.isDirectory }).max(by: { $0.size < $1.size }),
              biggest.size > 0,
              Double(biggest.size) / Double(current.size) > 0.9 {
            chain.append(biggest)
            current = biggest
        }
        return chain
    }

    /// 首次打开自动落到最大的一层
    ///
    /// 根目录只有 5~6 个顶级目录（Users / private / Applications / usr / Library…），
    /// 堆块图会显得很空，和截图那种十几个块的密度差很远。
    /// 打开时直接进最大的目录链（通常是 /Users/<name>），首屏就有十几个块；
    /// 面包屑的「根」随时可以退回全盘。
    private func autoLandIfNeeded() {
        guard !didAutoLand, stack.isEmpty, let root = store.snapshot?.root else { return }
        didAutoLand = true
        guard let biggest = root.children
            .filter({ $0.isDirectory && $0.size > 0 })
            .max(by: { $0.size < $1.size }) else { return }
        let chain = drillChain(to: biggest)
        // 只有确实能展开出更多块时才落进去，避免落到一个空目录
        if chain.count > 1 || (chain.last?.children.count ?? 0) >= 4 {
            navigate(to: chain)
        }
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
    private func buildAgentPrompt(_ agent: CleanupAgent) -> String {
        let snap = store.snapshot
        var lines: [String] = []

        lines.append(agent.roleLine)
        lines.append("")
        lines.append("下面是我这台 Mac 刚跑完的一次磁盘占用扫描。请逐项判断：哪些可以安全删除、"
                     + "哪些需要我确认、哪些绝对不要动，并给出可执行命令。")
        lines.append("")
        lines.append("## 扫描概况")
        lines.append("- 扫描范围：\(store.scope.title)（根路径 \(snap?.rootPath ?? "/")）")
        lines.append("- 索引总量：\(StorageFormat.bytes(snap?.totalBytes ?? 0))")
        if let used = volumeUsedText {
            lines.append("- \(used)")
        }
        if let snap {
            lines.append("- 扫描时间：\(StorageFormat.date(snap.scannedAt))")
            lines.append("- 节点数：\(snap.nodeCount)（跳过 \(snap.skippedCount) 处不可读路径，含隐藏目录）")
        }
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
        let text = buildAgentPrompt(agentKind)
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
                Text(buildAgentPrompt(agentKind))
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
            if !DiskScanScope.hasFullDiskAccess {
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
        pendingTrash.reduce(Int64(0)) { sum, p in
            sum + (DiskIndexStore.findNode(store.snapshot?.root, path: p)?.size ?? 0)
        }
    }

    private func performTrash() {
        let paths = pendingTrash
        pendingTrash = []
        guard !paths.isEmpty else { return }
        store.trash(paths: paths) { ok, bytes in
            refreshDiskSpace()
            selectedPaths.formIntersection(Set(candidates.map { $0.id }))
            if let d = detailNode { detailNode = DiskIndexStore.findNode(store.snapshot?.root, path: d.path) }
            directoryHistory = directoryHistory.map { path in
                path.compactMap { DiskIndexStore.findNode(store.snapshot?.root, path: $0.path) }
            }
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
