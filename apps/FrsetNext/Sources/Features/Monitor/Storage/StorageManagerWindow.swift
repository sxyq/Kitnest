import AppKit
import SwiftUI

extension Notification.Name {
    /// v212 排障深链：按名字下钻到某一层（kitnest://storage?drill=Users）
    static let storageDrillTo = Notification.Name("frsetnext.storage.drillTo")
    /// v229：两指滑动返回上一级（由窗口 controller 的 scrollWheel 监听发出）
    static let storageSwipeBack = Notification.Name("frsetnext.storage.swipeBack")
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
        installSwipeMonitor(on: win)
    }

    /// v229（用户：「两个返回按钮全删，改用手势，两指左右滑」）
    ///
    /// 用 `scrollWheel` 的横向分量识别两指轻扫：触控板两指左右滑会产生
    /// `scrollingDeltaX`（纵向滚轮 deltaX 基本为 0），累计到阈值就发一次返回。
    /// 用 local monitor 而不是 NSView：气泡图整块是 SwiftUI，事件在 hosting 层就被消化了。
    private var swipeMonitor: Any?
    private var swipeAccum: CGFloat = 0

    private func installSwipeMonitor(on win: NSWindow) {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === win else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // 只认「横向明显大于纵向」的滑动；纵向滚轮/惯性不参与
            guard abs(dx) > abs(dy) * 1.2, abs(dx) >= 1 else { return event }
            self.swipeAccum += dx
            if abs(self.swipeAccum) >= 42 {
                self.swipeAccum = 0
                NotificationCenter.default.post(name: .storageSwipeBack, object: nil)
            }
            return nil   // 吃掉横向滚动，避免带着别的视图一起动
        }
    }

    deinit {
        if let m = swipeMonitor { NSEvent.removeMonitor(m) }
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

// MARK: - 根视图

struct StorageManagerRootView: View {

    @StateObject private var store = DiskIndexStore.shared
    /// 下钻路径栈；空 = 索引根
    @Stored private var stack: [DiskNode] = []
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
    private var volumeUsedText: String? {
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = (a[.systemSize] as? NSNumber)?.int64Value,
              let free = (a[.systemFreeSize] as? NSNumber)?.int64Value,
              total > free else { return nil }
        return "磁盘已用 \(StorageFormat.shortBytes(total - free))"
    }

    /// 清单副行显示相对 home 的短路径：同名 Caches/cache 靠路径才能区分开
    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                leftPane
                    .frame(minWidth: 320, idealWidth: 372, maxWidth: 420)
                rightPane
                    .frame(minWidth: 420)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            store.loadIfNeeded()
            // 第一次打开：告诉用户「返回」现在是两指滑动（原来的按钮已经删了）
            // 注意：onAppear 可能被调用多次，这里用 swipeHintShown 兜住，
            // 不能在里面先写 showSwipeHint = false——第二次 onAppear 会把提示立刻清掉。
            guard !swipeHintShown else { return }
            swipeHintShown = true
            showSwipeHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                showSwipeHint = false
            }
        }
        // v229：两指滑动返回上一级
        .onReceive(NotificationCenter.default.publisher(for: .storageSwipeBack)) { _ in
            if !stack.isEmpty { stack.removeLast() }
        }
        .overlay(alignment: .bottom) {
            if showSwipeHint {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 13, weight: .medium))
                    Text("两指左右滑动，返回上一级")
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
        .animation(Theme.Motion.fast, value: showSwipeHint)
        .onReceive(NotificationCenter.default.publisher(for: .storageDrillTo)) { note in
            guard let name = note.object as? String else { return }
            // v213 实测：深链在窗口刚建好时到达，onAppear 里的缓存读取是异步的，
            // 此时 snapshot 往往还是 nil，直接 return 会导致 drill 静默失效。
            // 有快照就立刻下钻，没有就挂起，等 snapshot 到位再执行。
            if let root = store.snapshot?.root,
               let target = root.children.first(where: { $0.name == name }) {
                stack = drillChain(to: target)
                pendingDrill = nil
            } else {
                pendingDrill = name
            }
        }
        .onChange(of: store.snapshot?.scannedAt) { _ in
            if let name = pendingDrill,
               let root = store.snapshot?.root,
               let target = root.children.first(where: { $0.name == name }) {
                stack = drillChain(to: target)
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
            stack = []
            store.reloadFromCache(autoScanIfMissing: false)
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
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(StorageFormat.shortBytes(cleanableBytes))
                        .font(.system(size: 40, weight: .light).monospacedDigit())
                    Text("可清理")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(headline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let snap = store.snapshot {
                    Text("\(store.scope.title) · 上次扫描 \(StorageFormat.date(snap.scannedAt)) · \(snap.nodeCount) 个节点"
                         + " · 跳过 \(snap.skippedCount) 处不可读路径 · 含隐藏目录"
                         + (volumeUsedText.map { " · \($0)" } ?? "")
                         + (snap.truncated == true ? " · 已达节点上限，结果不完整" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(2)
                        .help("索引只统计可读目录；系统只读卷、TCC 保护目录（照片/音乐/邮件/钥匙串…）"
                              + "与 APFS 本地快照不计入，因此索引量会小于磁盘已用。")
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if store.snapshot == nil, !store.isScanning {
                    Button {
                        store.rescan()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11))
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
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .glassCard(radius: Theme.Radius.control)
        }
        .buttonStyle(.plain)
        // 窗口一打开别把键盘焦点落在工具条上（会画出一圈系统 focus ring，很突兀）
        .focusable(false)
    }

    // MARK: 左栏（可清理清单）

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("可清理")
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

            Divider()

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
                            candidateRow(c)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("已选 \(selectedPaths.count) 项")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(StorageFormat.bytes(selectedBytes))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    // v212：不替用户做删除决策——生成提示词交给本地 Agent 判断
                    Button {
                        showAgentSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars")
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
                        Text("清理所选")
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
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func candidateRow(_ c: CleanupCandidate) -> some View {
        HStack(spacing: 8) {
            Button {
                if selectedPaths.contains(c.id) { selectedPaths.remove(c.id) }
                else { selectedPaths.insert(c.id) }
            } label: {
                Image(systemName: selectedPaths.contains(c.id) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(selectedPaths.contains(c.id) ? Theme.accent : Theme.tertiaryText)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(c.node.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                // 副行给「路径」而不是解释文案：Caches/cache 这类同名目录只有路径能区分
                HStack(spacing: 4) {
                    Circle()
                        .fill(c.safe ? Theme.accent.opacity(0.7) : Color.orange)
                        .frame(width: 4, height: 4)
                    Text(displayPath(c.node.path))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            Text(StorageFormat.shortBytes(c.node.size))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(selectedPaths.contains(c.id) ? Theme.accent.opacity(0.09) : Color.clear)
        )
        .help("\(c.reason) · \(c.node.path)")
    }

    // MARK: 右栏（面包屑 + 气泡地图 + 详情）

    private var rightPane: some View {
        VStack(spacing: 0) {
            // 导航条：面包屑（v229：两个「返回」按钮已删，返回交给两指滑动 / Esc / 点空白）
            HStack(spacing: 6) {
                Button {
                    stack.removeAll()
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
                        stack = Array(stack.prefix(idx + 1))
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
            .padding(.horizontal, 12)
            .frame(height: 36)
            .animation(Theme.Motion.fast, value: stack.count)

            if let node = currentNode {
                // v229（用户：「两个返回上一级按钮全删掉，改用手势」）：
                // 返回只保留「两指滑动」和 Esc、以及点气泡之间的空白；
                // 左上角与右下角那两个按钮都去掉了。
                StorageTreemap(node: node,
                               onDrill: { child in stack.append(contentsOf: drillChain(to: child)) },
                               onSelect: { detailNode = $0 },
                               onBack: { if !stack.isEmpty { stack.removeLast() } },
                               agentZone: CGSize(width: 196, height: 112),
                               onAgent: { showAgentSheet = true })
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .id(node.id)
                    .animation(Theme.Motion.fast, value: node.id)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let d = detailNode {
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(d.path).font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText).lineLimit(1)
                    }
                    Spacer()
                    Text(StorageFormat.bytes(d.size))
                        .font(.system(size: 11).monospacedDigit())
                    Button("移到废纸篓") {
                        pendingTrash = [d.path]
                        confirmTrash = true
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
            }
        }
        // Esc = 返回上一级（用户：「点击进入之后无法进行返回」）
        .onExitCommand {
            if !stack.isEmpty { stack.removeLast() }
        }
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
            stack = chain
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
        lines.append("1. **先看清每个目录里到底是什么**：对每一项跑 `ls -la <路径>` 和 "
                     + "`du -sh <路径>/*`，说明这些文件是什么、由哪个工具生成、删了会不会有副作用。")
        lines.append("2. 逐项给结论并写依据：可安全删除 / 需我确认 / 不要动"
                     + "（是不是缓存、能不能重建、是否含用户数据）。")
        lines.append("3. 可删的必须**具体到文件或子目录**，不要只给父目录：")
        lines.append("   列出完整路径、大小、一句话说明它是什么、为什么可以删。")
        lines.append("4. 对每一项给出建议命令：优先 `mv <路径> ~/.Trash/`，不要 `rm -rf`；")
        lines.append("   一条一行，命令后面用注释写明删的是什么。")
        lines.append("5. 输出一份 Markdown 报告，结构：目录 → 内容构成 → 判定 → 建议命令 → 预计释放空间；")
        lines.append("   最后给一个合计（能删多少、需确认多少）。")
        lines.append("6. 先只给方案，不要执行。等我逐条确认后再动手，每执行一条把结果告诉我。")
        lines.append("7. 遇到需要更多信息才能判断的，直接说「请跑 `du -sh <路径>/*` 把结果贴给我」，不要猜。")
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
            Text("扫描包含以「.」开头的隐藏目录与其他所有目录；符号链接不跟随。"
                 + "受系统 TCC 保护的目录（音乐/照片/邮件/钥匙串等）会自动跳过，避免弹授权框卡住扫描；"
                 + "需要它们请先在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里授权再重扫。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            selectedPaths.subtract(paths)
            if detailNode.map({ paths.contains($0.path) }) == true { detailNode = nil }
            stack.removeAll { node in paths.contains(where: { node.path.hasPrefix($0 + "/") }) }
            if ok > 0 {
                Toast.show("已将 \(ok) 项移到废纸篓 · \(StorageFormat.bytes(bytes))",
                           icon: "trash")
            } else {
                Toast.show("没有可移动的项（可能权限不足或已不存在）",
                           icon: "exclamationmark.triangle", isWarning: true)
            }
        }
    }
}
