import AppKit
import SwiftUI

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

    public func show(autoScan: Bool = false) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // v211 排障：kitnest://storage?scan=1 —— 无人值守触发一次扫描（验证全盘索引/进度/截断提示）
        if autoScan { DiskIndexStore.shared.rescan() }
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
                    .frame(minWidth: 330, idealWidth: 400, maxWidth: 480)
                rightPane
                    .frame(minWidth: 420)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { store.loadIfNeeded() }
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
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("已选 \(selectedPaths.count) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(StorageFormat.bytes(selectedBytes))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                Spacer()
                Button {
                    pendingTrash = Array(selectedPaths)
                    confirmTrash = true
                } label: {
                    Text("清理所选")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule(style: .continuous).fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(selectedPaths.isEmpty)
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
            HStack(spacing: 6) {
                Button {
                    stack.removeAll()
                } label: {
                    Text("根")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(stack.isEmpty ? .secondary : Theme.accent)
                }
                .buttonStyle(.plain)
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
                Spacer()
                if !stack.isEmpty {
                    Button("返回上级") { stack.removeLast() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)

            if let node = currentNode {
                StorageBubbleMap(node: node,
                                 onDrill: { child in stack.append(child) },
                                 onSelect: { detailNode = $0 })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .id(node.id)
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
