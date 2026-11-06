import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件中转（面板第三页）
//
// 2026-10-20 第二版：**上下分区**（用户明确否掉左右双栏）。
//
//   ┌ 文件中转 ──────────────────  ↻  ⚙ ┐
//   │ 手机扫码直传  [二维码]  http://192.168.1.7:8787/s/ab3d │
//   ├──────────────────────────────────┤
//   │ 云端 · OPPO 中转     已登录 12    │  ← 设置里关掉后整块消失
//   │   …列表…                          │
//   ├──────────────────────────────────┤
//   │ 本地暂存             清空        │
//   │   …列表…                          │
//   └──────────────────────────────────┘
//
// 分区纪律：
//   · 云端（OPPO 专属中转）受「设置 → 文件中转 → 云端通道」与桥接工程是否存在双重门控，
//     任一不满足就**完全不渲染**（不是灰掉、不是占位）；
//   · 手机扫码直传受「设置 → 文件中转 → 局域网直传」门控，关掉同样整块消失；
//   · 本地暂存始终存在（它是这套功能的底座）。

struct TransferDockView: View {
    @ObservedObject private var service = TransferDockService.shared
    @ObservedObject private var local = LocalTransferStore.shared
    @ObservedObject private var lan = LanTransferServer.shared

    @AppStorage(TransferDockPref.cloudEnabled) private var cloudEnabled = true
    @AppStorage(TransferDockPref.lanEnabled) private var lanEnabled = true
    /// v181：「文件中转」功能总开关（设置 → 通用 → 功能 / 设置 → 文件中转）。
    /// 与「面板顶部是否出现中转分段」已经解耦：分段开着但这个开关关着时，
    /// 这里显示一句「已关闭」的说明，而不是整页空白或消失。
    @AppStorage(TransferDockPref.panelVisible) private var featureEnabled = true

    @Stored private var showsLogin = false
    @Stored private var bridgeAvailable = TransferDockPath.isAvailable
    @Stored private var cloudDropTargeted = false
    @Stored private var localDropTargeted = false
    // v128（流畅度）：hoveredCloudID/hoveredLocalID 已下沉到行视图（CloudRowView /
    // LocalCardRowView 各自持有），父视图不再跟踪 hover，避免 hover 触发整表重算。
    /// 本地暂存勾选集合（勾选后可「扫码直传 / 加入云端 / 移出」批量操作）
    @Stored private var selectedIDs = Set<String>()
    /// 「扫码直传」选中文件的二维码链接（带 ?pick=ids，手机只看到这几个）
    @Stored private var pickShareURL: String?
    /// 直传服务是否由「传输」动作拉起（是则勾选清空时随停；手动启动的不代停）
    @Stored private var lanStartedForTransfer = false
    /// v119：发送 / 接收 / 云端 三段（按动作分，不再按协议堆区块）
    @Stored private var transferTab = 0

    /// 云端分区是否出现：开关 + 桥接工程都在才算
    private var showsCloud: Bool { cloudEnabled && bridgeAvailable }

    var body: some View {
        if featureEnabled {
            dockContent
        } else {
            featureDisabledNotice
        }
    }

    /// v181：功能总开关关掉时中转页的说明（分段仍可保留在顶部，只是里面不能用了）
    private var featureDisabledNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text("文件中转已关闭")
                .font(.system(size: 13, weight: .semibold))
            Text("在「设置 → 文件中转」里重新启用；\n顶部是否出现这一页由「设置 → 个性化 → 主面板页面」决定。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开设置") { SettingsWindowController.shared.open(pane: "transfer") }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var dockContent: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            // v119（2026-10-25 用户：「一个文件传输一个隔空投送，太多了、意义不明」）：
            // 原来按**协议**分块（隔空投送 / ADB 文件互传 / 云端中转），三块都在干「把文件发出去」，
            // 用户不知道该点哪个。现在按**动作**分三段：发送（选出口）/ 接收 / 云端；
            // 「本地暂存」是三者共用的池子，常驻底部。
            transferSegments
            Divider().opacity(0.5)

            Group {
                switch transferTab {
                case 1:  receiveSection
                case 2:  cloudTab
                default: sendSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.5)

            localSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            bridgeAvailable = TransferDockPath.isAvailable
            // v103：空投接收监听（系统落盘 ~/Downloads → 自动进本地暂存）
            AirDropReceiveWatcher.shared.onFileReceived = { url in
                let n = LocalTransferStore.shared.add(urls: [url])
                if n > 0 { Toast.show("空投已接收：\(url.lastPathComponent)", icon: "dot.radiowaves.left.and.right") }
            }
            AirDropReceiveWatcher.shared.start()
            // v120：预热隔空投送服务（首次实例化会同步初始化 AWDL，1~3s）
            AirDropSendEngine.warmUp()
            runTransferProbe()
        }
        .onChange(of: cloudEnabled) { on in
            if on && bridgeAvailable {
                service.refresh()
                service.startLiveSync()
            } else {
                service.stopLiveSync()
            }
        }
        .onChange(of: lanEnabled) { on in
            // 只在关闭时停服务；开启**不**自动启动（2026-10-20 用户需求）：
            // 勾选文件后点「扫码直传」才拉起服务并生成二维码。
            if !on { lan.stop() }
        }
        .onChange(of: selectedIDs) { ids in
            // 没有选中文件 → 关二维码；若服务是「传输」拉起的则一并停掉
            if ids.isEmpty {
                pickShareURL = nil
                stopServiceIfStartedForTransfer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transferDockSettingsDidChange)) { _ in
            bridgeAvailable = TransferDockPath.isAvailable
            if showsCloud { service.refresh() }
        }
        .sheet(isPresented: $showsLogin) {
            TransferDockLoginView(
                onCancel: { showsLogin = false },
                onLoggedIn: {
                    showsLogin = false
                    service.refresh()
                })
        }
        // 「扫码直传」选中文件的二维码弹层
        .overlay {
            if let url = pickShareURL {
                pickOverlay(url)
            }
        }
    }

    // MARK: - v119 三段：发送 / 接收 / 云端

    private var transferSegments: some View {
        HStack(spacing: 4) {
            segmentPill("发送", icon: "paperplane.fill", index: 0)
            segmentPill("接收", icon: "tray.and.arrow.down.fill", index: 1)
            segmentPill("云端", icon: "icloud.fill", index: 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func segmentPill(_ title: String, icon: String, index: Int) -> some View {
        let on = transferTab == index
        return Button {
            transferTab = index
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background {
                if on { Capsule().fill(Theme.accent.gradient) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 发送（暂存勾选 → 三个出口）

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(selectedIDs.isEmpty
                     ? "先在下方暂存里勾选文件"
                     : "已选 \(selectedIDs.count) 项，选对方是什么设备")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selectedIDs.isEmpty ? Color.secondary : Theme.accent)
                Spacer(minLength: 2)
                smallAction("添加文件", icon: "plus") { addFilesToStaging() }
            }

            // v120（用户：「应该就分为两种设备」）：只留两类目标；
            // ADB 从主入口降级为下面一行次要链接（它要开发者选项，日常太麻烦）。
            // v153 设计审计（用户：「中转以及传输那些都不太好」）：
            // 旧版把「怎么发」拆成三种语汇——两张渐变大卡（苹果/安卓）+ 一行 8.5pt
            // 灰字里的「ADB 直传」文字链。同一决策三种控件、主按钮不唯一。
            // 现在收敛成一行等宽 chip：同一层级、同一尺寸、同一字号。
            HStack(spacing: 6) {
                sendChip("隔空投送", icon: "dot.radiowaves.left.and.right", help: "苹果设备 · 零安装") {
                    sendViaAirDrop()
                }
                sendChip("扫码直传", icon: "qrcode", help: "安卓/其他 · 浏览器扫码接收") {
                    sendViaBrowser()
                }
                sendChip("ADB 直传", icon: "cable.connector", help: "大文件/批量更快 · 需开发者选项") {
                    sendViaADB()
                }
            }

            // v122：传输进度条（百分比 + 已传/总量 + 速率 + 剩余时间）
            if pushActive {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(Theme.accent.gradient)
                                .frame(width: max(4, geo.size.width * pushFraction))
                                .animation(Theme.Motion.progress, value: pushFraction)
                        }
                    }
                    .frame(height: 5)
                    HStack(spacing: 4) {
                        Text("\(Int(pushFraction * 100))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                        Text(pushDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            } else if !adbFileStatus.isEmpty {
                Text(adbFileStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ADB 已是 chip：说明进 tooltip，不再占一行小灰字
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 发送方式 chip（v153）：同层级、等宽、单行，图标与文字同字号。
    /// 旧的 deviceCard 是「渐变底 + 38pt 圆形图标 + 两行文案」的 landing page 卡，
    /// 在 360pt 面板里既占地方又抢主按钮的位置。
    private func sendChip(_ title: String, icon: String, help: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .glassCard(radius: Theme.Radius.control)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(title)：\(help)")
    }

    /// v120 修复：暂存项的实际可发路径。
    /// 原来直接用 `originalPath`（加入暂存时的原文件路径）——原文件一旦删掉/移走，
    /// `fileExists` 就是 false，于是「明明勾选了却提示没勾选」。
    /// 暂存目录里是硬链接/副本，真实存在，优先用它。
    private func sendableURL(_ item: LocalTransferItem) -> URL {
        let staged = item.stagedURL
        if FileManager.default.fileExists(atPath: staged.path) { return staged }
        return URL(fileURLWithPath: item.originalPath)
    }

    /// 暂存里勾选的文件（两类设备共用）
    private func stagedSelection() -> [URL] {
        local.items
            .filter { selectedIDs.contains($0.id) }
            .map { sendableURL($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addFilesToStaging() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "添加到本地暂存"
        guard panel.runModal() == .OK else { return }
        let n = local.add(urls: panel.urls)
        Toast.show(n > 0 ? "已添加 \(n) 个文件到暂存" : "没有可添加的文件",
                   icon: n > 0 ? "tray.and.arrow.down" : "exclamationmark.triangle",
                   isWarning: n == 0)
    }

    private func sendViaAirDrop() {
        let urls = stagedSelection()
        guard !urls.isEmpty else {
            Toast.show("先在下方暂存里勾选要发送的文件", icon: "hand.point.up.left")
            return
        }
        AirDropSendEngine.send(urls: urls)
    }

    private func sendViaADB() {
        guard !adbPushing else { return }
        let urls = stagedSelection()
        guard !urls.isEmpty else {
            Toast.show("先在下方暂存里勾选要发送的文件", icon: "hand.point.up.left")
            return
        }
        adbPushing = true
        pushActive = true
        pushFraction = 0
        pushDetail = "准备推送…"
        adbFileStatus = ""
        ADBFileBridge.push(urls: urls, progress: { p in
            pushFraction = p.fraction
            pushDetail = "\(p.fileIndex + 1)/\(p.fileCount) · \(p.doneText)"
                + (p.speedText.isEmpty ? "" : " · \(p.speedText)")
                + (p.etaText.isEmpty ? "" : " · 剩 \(p.etaText)")
        }, completion: { sent, log in
            adbPushing = false
            pushActive = false
            pushFraction = sent > 0 ? 1 : 0
            adbFileStatus = log
            Toast.show(sent > 0 ? "已推送 \(sent)/\(urls.count) 个文件到手机"
                                : "推送失败：手机没连？（去「投屏」页连一次）",
                       icon: sent > 0 ? "square.and.arrow.up" : "exclamationmark.triangle",
                       isWarning: sent == 0)
        })
    }

    private func sendViaBrowser() {
        guard !selectedIDs.isEmpty else {
            Toast.show("先在下方暂存里勾选要发送的文件", icon: "hand.point.up.left")
            return
        }
        showPickQR()
    }

    // MARK: 接收

    private var receiveSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            receiveRow(icon: "dot.radiowaves.left.and.right", tint: Color(red: 0.15, green: 0.55, blue: 0.95),
                       title: "隔空投送",
                       detail: "iPhone / iPad 投过来，自动进暂存") {
                Text("已监听")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
            receiveRow(icon: "internaldrive", tint: Color(red: 0.2, green: 0.65, blue: 0.5),
                       title: "从手机拉取",
                       detail: "ADB · Download/Kitnest/ 全部文件") {
                smallAction(adbPushing ? "拉取中…" : "拉取", icon: "arrow.down.circle") {
                    pullFromPhone()
                }
            }
            receiveRow(icon: "qrcode", tint: Color(red: 0.60, green: 0.40, blue: 0.95),
                       title: "浏览器上传",
                       detail: "对方扫码后可在网页里反向传给你") {
                smallAction("出码", icon: "qrcode") { openUploadQR() }
            }
            if !adbFileStatus.isEmpty {
                Text(adbFileStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text("收到的文件都进下方「本地暂存」，不会散落在下载目录。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            // v120：安卓没有 AWDL（隔空投送是苹果私有协议），只能经本机中转
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent.opacity(0.8))
                Text("安卓传给 iPhone：先扫码传到本机暂存，勾选它再点「苹果设备」空投出去（安卓无法直接空投苹果）。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func receiveRow<Trailing: View>(icon: String, tint: Color,
                                            title: String, detail: String,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .fill(tint.opacity(0.16))
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
        }
    }

    /// 反向：不带 pick 的分享链接 → 对方打开网页可上传 + 下载全部暂存
    private func openUploadQR() {
        if !lan.running {
            lan.startIfEnabled()
            lanStartedForTransfer = true
        }
        let build: () -> Void = {
            guard let base = lan.shareURL else {
                Toast.show("直传服务未启动，无法生成二维码",
                           icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            pickShareURL = base
        }
        if lan.shareURL != nil {
            build()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: build)
        }
    }

    // MARK: 云端

    @ViewBuilder
    private var cloudTab: some View {
        if showsCloud {
            cloudSection
        } else {
            VStack(spacing: 6) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.tertiaryText)
                Text("云端中转未启用")
                    .font(.system(size: 11, weight: .medium))
                Text("设置 → 文件中转 → 云端中转（需要 OPPO 中转桥接工程）")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                Button("去设置") { openSettings() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("文件中转")   // v114：投屏拆出后本页只做文件传输
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 6)
            // v153 设计审计：原来是刷新 / 登录 / 齿轮三个无标签图标并排，
            // 其中齿轮与窗口右上角的全局齿轮职责重叠（一个开设置、一个也开设置）。
            // 收进一个「⋯」菜单，顶部只留一个可点目标。
            Menu {
                Button {
                    if showsCloud { service.refresh() }
                    local.objectWillChange.send()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(service.isLoading)

                if showsCloud {
                    Button {
                        showsLogin = true
                    } label: {
                        Label(service.loggedIn ? "重新登录云端" : "登录云端中转",
                              systemImage: service.loggedIn ? "person.crop.circle" : "person.crop.circle.badge.plus")
                    }
                }

                Divider()
                Button {
                    openSettings()
                } label: {
                    Label("文件中转设置…", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private func openSettings() {
        ServiceLocator.settings?.open(pane: "transfer")
    }

    /// 排障探针（2026-10-20）：defaults 键 probe.transfer=preview|select 时
    /// 自动演示「悬停预览 / 勾选 + 扫码直传」，用于无鼠标环境截屏核对；默认不生效。
    private func runTransferProbe() {
        guard let mode = UserDefaults.standard.string(forKey: "probe.transfer"), mode != "0" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let first = local.items.first else {
                Log.info("TransferDock", "探针：本地暂存为空")
                return
            }
            switch mode {
            case "preview":
                Log.info("TransferDock", "探针：悬停预览 \(first.name)")
                FileHoverPreviewController.shared.scheduleShow(url: first.stagedURL)
            case "select":
                let ids = local.items.prefix(2).map(\.id)
                selectedIDs = Set(ids)
                Log.info("TransferDock", "探针：勾选 \(ids.count) 项并弹定向二维码")
                showPickQR()
                // 3.5s 后自动清空勾选，验证「无勾选 → 停直传服务」（排障用）
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    selectedIDs.removeAll()
                    Log.info("TransferDock", "探针：清空勾选（应触发停服务）")
                }
            default:
                break
            }
        }
    }

    private func smallAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 文件互传 · Android（v112：ADB 文件桥，对标报告第一批 P1）

    @Stored private var adbFileStatus = ""
    @Stored private var adbPushing = false
    // v122：传输进度（用户：「数据也要显示」）
    @Stored private var pushActive = false
    @Stored private var pushFraction: Double = 0
    @Stored private var pushDetail = ""

    private func pullFromPhone() {
        guard !adbPushing else { return }
        adbPushing = true
        adbFileStatus = "拉取中…"
        let staging = ADBFileBridge.stagingDirectory
        ADBFileBridge.pull(into: staging) { count, log in
            adbPushing = false
            adbFileStatus = log
            // 拉取落盘的文件 → 走 add() 正式入暂存索引（硬链接语义，不重复占空间）
            let pulled = (try? FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent != ".DS_Store" } ?? []
            let n = pulled.isEmpty ? 0 : LocalTransferStore.shared.add(urls: pulled)
            Toast.show(n > 0 ? "已拉取 \(n) 个文件入暂存" : "手机目录为空或未连接",
                       icon: n > 0 ? "square.and.arrow.down" : "tray",
                       isWarning: n == 0)
        }
    }

    // MARK: 云端（OPPO 中转）

    /// v116：重跑 extract_edge_cookies.py（从 Edge 取 OPPO 中转站 cookie）
    private func refreshCloudLogin() {
        let web = TransferDockPath.webRoot
        let script = web.appendingPathComponent("scripts/extract_edge_cookies.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            Toast.show("未找到 extract_edge_cookies.py（检查设置里的桥接目录）",
                       icon: "exclamationmark.triangle", isWarning: true)
            return
        }
        Toast.show("正在从 Edge 读取登录态…", icon: "icloud")
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            task.arguments = [script.path]
            task.currentDirectoryURL = web
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do { try task.run() } catch {
                DispatchQueue.main.async {
                    Toast.show("无法运行脚本：\(error.localizedDescription)",
                               icon: "exclamationmark.triangle", isWarning: true)
                }
                return
            }
            task.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                let ok = task.terminationStatus == 0
                Toast.show(ok ? "登录态已刷新" : "刷新失败（确认 Edge 已登录中转站后重试）",
                           icon: ok ? "checkmark.seal.fill" : "exclamationmark.triangle",
                           isWarning: !ok)
                Log.info("Transfer", "OPPO cookie 刷新：\(out.suffix(200))")
                service.refresh()
            }
        }
    }

    private var cloudSection: some View {
        VStack(spacing: 0) {
            sectionHeader(title: "云端 · OPPO 中转", symbol: "icloud",
                          detail: service.loggedIn ? "已登录" : "未登录",
                          tint: service.loggedIn ? Theme.accent : .secondary) {
                if !service.loggedIn {
                    // v116：登录态失效时一键从 Edge 重新提取 cookie
                    smallAction("刷新登录", icon: "arrow.clockwise.icloud") { refreshCloudLogin() }
                }
                if service.loggedIn {
                    // 云端是「云盘式」实时同步：绿点 = 自动刷新在跑，旁边是当前文件数
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("实时")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                        if !service.files.isEmpty {
                            Text("\(service.files.count)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }
            }

            if service.loggedIn {
                if !service.spaceText.isEmpty { spaceBar }
                cloudList
            } else {
                cloudEmpty
            }

            Divider().opacity(0.4)
            HStack(spacing: 6) {
                if service.isUploading { ProgressView().controlSize(.mini) }
                Text(cloudStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Button("上传") { pickAndUpload() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.borderless)
                    .disabled(!service.loggedIn || service.isUploading)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $cloudDropTargeted) { providers in
            guard service.loggedIn else {
                Toast.show("请先登录云端中转", icon: "person.crop.circle.badge.exclamationmark", isWarning: true)
                return false
            }
            return handleCloudDrop(providers)
        }
        .overlay { if cloudDropTargeted { dropHint("松手上传到云端") } }
    }

    private var spaceBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Color.primary.opacity(0.42))
                    .frame(width: max(2, geo.size.width * service.spaceRatio))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .help(service.spaceText)
    }

    private var cloudList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                if service.files.isEmpty && !service.isLoading {
                    Text("空")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                }
                // v128（流畅度）：行抽成 Equatable 子视图——原 hoveredCloudID 是父视图
                // @Stored，鼠标扫过列表每换一行就重算整个 body（200 行 cloudRow 全重建，
                // 含 sizeText/dateText 格式化 + 图标匹配）。现 hover 态行内自持，
                // 父级状态未变时行 body 直接跳过。
                ForEach(service.files) { file in
                    CloudRowView(file: file).equatable()
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if service.isLoading && service.files.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var cloudEmpty: some View {
        VStack(spacing: 6) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text("未登录云端")
                .font(.system(size: 11, weight: .medium))
            Text("登录后可跨设备取回")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("登录") { showsLogin = true }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }

    // v126（性能审计 F2143）：DateFormatter 复用——cloudStatus 是 body 每次求值都会走的
    // 计算属性，原实现每次 new 一个 DateFormatter。提为 static 缓存。
    private static let syncTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var cloudStatus: String {
        // 未登录时不要把桥接层的原始报错（如「[1003] 用户信息获取失败」）怼到脸上，
        // 那是没 cookie 时的必然结果，对用户没有信息量。
        guard service.loggedIn else { return "未登录" }
        if let error = service.errorMessage { return error }
        if !service.statusMessage.isEmpty { return service.statusMessage }
        if let synced = service.lastSyncedAt {
            return "同步 \(Self.syncTimeFormatter.string(from: synced))"
        }
        return "就绪"
    }

    // MARK: 本地暂存（拖入 / 手机上传）

    private var localSection: some View {
        VStack(spacing: 0) {
            sectionHeader(title: "本地暂存", symbol: "internaldrive",
                          detail: local.items.isEmpty ? "空" : "\(local.items.count) 项",
                          tint: .secondary) {
                if !local.items.isEmpty {
                    Button {
                        // 全选 / 清选
                        if selectedIDs.count == local.items.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(local.items.map(\.id))
                        }
                    } label: {
                        Text(selectedIDs.count == local.items.count ? "清选" : "全选")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("勾选全部条目（勾选后可批量扫码直传 / 加入云端）")

                    Button {
                        local.clearAll()
                        selectedIDs.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("清空本地中转（不删原文件）")
                }
            }

            if local.items.isEmpty {
                localEmpty
            } else {
                localList
            }

            Divider().opacity(0.4)
            if selectedIDs.isEmpty {
                HStack(spacing: 6) {
                    if let error = local.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text(local.lastMessage.isEmpty ? "拖入即存 · 拖出即用" : local.lastMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button("打开目录") { local.openStagingFolder() }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
            } else {
                selectionBar
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $localDropTargeted) { providers in
            handleLocalDrop(providers)
        }
        .overlay { if localDropTargeted { dropHint("松手存到本地中转") } }
    }

    // MARK: 勾选后的批量操作条

    private var selectionBar: some View {
        HStack(spacing: 6) {
            Text("已选 \(selectedIDs.count) 项")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 2)
            smallAction("通用互传", icon: "qrcode") { showPickQR() }
            if showsCloud {
                smallAction("加入云端", icon: "icloud.and.arrow.up") { pushSelectedToCloud() }
            }
            smallAction("移出", icon: "xmark.circle") { removeSelected() }
            smallAction("取消", icon: "circle.slash") { selectedIDs.removeAll() }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.accent.opacity(0.06))
    }

    private func toggleSelect(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// 勾选后「扫码直传」：**此时才**启动服务并生成 ?pick=ids 的定向接收二维码
    /// （2026-10-20 用户需求：没选中文件不起服务，点传输才拉起并出码）。
    private func showPickQR() {
        let ids = local.items.filter { selectedIDs.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        if !lan.running {
            lan.startIfEnabled()
            lanStartedForTransfer = true
        }
        let build: () -> Void = {
            guard let base = lan.shareURL else {
                Toast.show("直传服务未启动，无法生成二维码", icon: "exclamationmark.triangle", isWarning: true)
                return
            }
            pickShareURL = base + "?pick=" + ids.joined(separator: ",")
        }
        if lan.shareURL != nil {
            build()
        } else {
            // 服务刚拉起，shareURL 要等端口绑定后才有
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: build)
        }
    }

    /// 停掉由「传输」拉起的直传服务（手动启动的不动）
    private func stopServiceIfStartedForTransfer() {
        guard lanStartedForTransfer else { return }
        lanStartedForTransfer = false
        lan.stop()
    }

    /// 勾选后「加入云端」：批量走 OPPO 中转桥接上传
    private func pushSelectedToCloud() {
        let urls = local.items
            .filter { selectedIDs.contains($0.id) }
            .map(\.stagedURL)
        guard !urls.isEmpty else { return }
        guard service.loggedIn else {
            Toast.show("请先登录云端中转", icon: "person.crop.circle.badge.exclamationmark", isWarning: true)
            return
        }
        service.uploadBatch(urls)
        Toast.show("正在上传 \(urls.count) 个文件到云端", icon: "icloud.and.arrow.up")
    }

    private func removeSelected() {
        let victims = local.items.filter { selectedIDs.contains($0.id) }
        for item in victims { local.remove(item) }
        selectedIDs.removeAll()
    }

    /// 「扫码直传」二维码弹层
    private func pickOverlay(_ url: String) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .onTapGesture { pickShareURL = nil }
            VStack(spacing: 10) {
                HStack {
                    Text(selectedIDs.isEmpty ? "扫码传给我" : "扫码接收选中文件")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Button {
                        pickShareURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                QRCodeView(text: url, size: 148)
                Text(selectedIDs.isEmpty
                     ? "手机扫码后，可在网页里把文件传给你，也能下载暂存里的全部文件"
                     : "手机扫码后可直接下载这 \(selectedIDs.count) 个文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("前提：手机与本机连同一个 Wi-Fi（扫码走局域网，不经服务器）")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    smallAction("复制链接", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        Toast.show("定向接收链接已复制", icon: "doc.on.doc")
                    }
                    smallAction("用浏览器打开", icon: "safari") {
                        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    }
                }
            }
            .padding(14)
            .frame(width: 230)
            // v181：统一玻璃面（结构浮层走 glassPlate，不再自己配 material + 描边）
            .glassPlate(radius: 12)
            .shadow(radius: 18)
        }
        .ignoresSafeArea()
    }

    private var localEmpty: some View {
        VStack(spacing: 5) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text("拖文件到这里")
                .font(.system(size: 11, weight: .medium))
            Text("不占双份空间；手机上传的也落在这里")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }

    private var localList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // v115：改双列彩色卡片（用户：「跟剪贴板一样，改为卡片，一行两个，
            // 图标 + 名字就够」）。列用 adaptive 而不是两个 .flexible()——
            // 面板预热会以 0 宽过一次布局，flexible 双列会算出负宽度触发
            // AppKit 布局异常（实测崩溃 2026-10-25）；adaptive 在窄宽自动退 1 列。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: .infinity), spacing: 6)],
                      spacing: 6) {
                ForEach(local.items) { item in
                    localCard(item)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    // v128（流畅度）：本地卡抽成 Equatable 行视图——原实现依赖父视图 @Stored
    // hoveredLocalID/selectedIDs，hover 一动就重算父 body，LazyVGrid 全部卡片跟着
    // 重建（含 fileTint/iconName 的字符串 switch、渐变/描边视图树）。现在 hover 态
    // 行内自持，勾选态作为参数参与 Equatable 比较，未变的行跳过 body。
    private func localCard(_ item: LocalTransferItem) -> some View {
        LocalCardRowView(
            item: item,
            selected: selectedIDs.contains(item.id),
            showsCloud: showsCloud,
            onToggleSelect: { toggleSelect($0) },
            onPickOnly: { id in
                selectedIDs = [id]
                showPickQR()
            },
            onRemove: { victim in
                local.remove(victim)
                selectedIDs.remove(victim.id)
            })
        .equatable()
    }

    // MARK: 共用件

    private func sectionHeader<Trailing: View>(title: String, symbol: String,
                                               detail: String, tint: Color,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
            Spacer(minLength: 2)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.primary.opacity(0.02))
    }

    private func dropHint(_ text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.accent.opacity(0.07))
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .allowsHitTesting(false)
    }

    // MARK: 拖放与选择

    private func urls(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var result: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                if let url {
                    lock.lock(); result.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { completion(result) }
    }

    private func handleLocalDrop(_ providers: [NSItemProvider]) -> Bool {
        urls(from: providers) { urls in
            guard !urls.isEmpty else { return }
            local.add(urls: urls)
        }
        return true
    }

    private func handleCloudDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                url = direct
            }
            guard let fileURL = url else { return }
            DispatchQueue.main.async { service.upload(url: fileURL) }
        }
        return true
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "上传"
        if panel.runModal() == .OK, let url = panel.url {
            service.upload(url: url)
        }
    }
}

extension Notification.Name {
    /// 设置页改了文件中转相关开关/路径/端口
    static let transferDockSettingsDidChange = Notification.Name("frset.transferDock.settingsChanged")
}

// MARK: - v128（流畅度）：列表行独立视图（hover/勾选态行内自持，避免整表重算）

/// 云端文件行（原 TransferDockView.cloudRow）
/// v128（流畅度）：hover 态从父视图 @Stored 下沉到行内——原实现鼠标扫过列表
/// 每换一行 hoveredCloudID 就变，父 body 重算导致全列表行重建（200 行 × 图标
/// 匹配/格式化/视图树）。现在只有被悬停的那一行重绘；Equatable 使父级重算时
/// 未变化的行直接跳过 body。闭包不参与比较（同 HeatmapGridView 的处理）。
private struct CloudRowView: View, Equatable {
    let file: TransferDockFile

    @Stored private var hovered = false

    static func == (lhs: CloudRowView, rhs: CloudRowView) -> Bool {
        lhs.file == rhs.file
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: TransferRowStyle.iconName(for: file.name))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.sizeText) · \(file.dateText)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered {
                HStack(spacing: 5) {
                    TransferRowStyle.miniButton("arrow.down.circle", help: "下载") {
                        TransferDockService.shared.download(file)
                    }
                    TransferRowStyle.miniButton("trash", help: "删除") {
                        TransferDockService.shared.delete(file)
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside }
        .onTapGesture(count: 2) { TransferDockService.shared.download(file) }
        .contextMenu {
            Button("下载") { TransferDockService.shared.download(file) }
            Button("删除", role: .destructive) { TransferDockService.shared.delete(file) }
        }
    }
}

/// 本地暂存卡行（原 TransferDockView.localCard 的主体；动作经闭包回传父视图）
private struct LocalCardRowView: View, Equatable {
    let item: LocalTransferItem
    let selected: Bool
    let showsCloud: Bool
    var onToggleSelect: (String) -> Void
    var onPickOnly: (String) -> Void
    var onRemove: (LocalTransferItem) -> Void

    @Stored private var hovered = false

    // v128（流畅度）：hover 是行内态不参与比较——父级重算时只要 item/selected
    // 没变就跳过 body，悬停高亮由本行 @Stored 自驱动。
    static func == (lhs: LocalCardRowView, rhs: LocalCardRowView) -> Bool {
        lhs.item == rhs.item
            && lhs.selected == rhs.selected
            && lhs.showsCloud == rhs.showsCloud
    }

    var body: some View {
        let tint = TransferRowStyle.fileTint(for: item.name)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                // 类型图标（按格式着色，渐变底）
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                    Image(systemName: TransferRowStyle.iconName(for: item.name))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                Button {
                    onToggleSelect(item.id)
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.45))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("勾选后可批量扫码直传 / 加入云端")
            }
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text(item.sizeText)
                    .font(.system(size: 11, design: .rounded))
                Spacer(minLength: 0)
                if hovered {
                    TransferRowStyle.miniButton("folder", help: "在 Finder 中显示") {
                        LocalTransferStore.shared.reveal(item)
                    }
                    TransferRowStyle.miniButton("xmark.circle", help: "移出中转") {
                        onRemove(item)
                    }
                } else {
                    Image(systemName: item.mode.symbol)
                        .font(.system(size: 7.5))
                }
            }
            .foregroundStyle(Theme.tertiaryText)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(selected
                      ? Theme.accent.opacity(0.10)
                      : Color.primary.opacity(hovered ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.55)
                                       : Color.primary.opacity(0.06),
                              lineWidth: 1)
        )
        .scaleEffect(hovered ? 1.02 : 1.0)
        .animation(Theme.Motion.springSnappy, value: hovered)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onHover { inside in
            hovered = inside
            if inside {
                FileHoverPreviewController.shared.scheduleShow(url: item.stagedURL)
            } else {
                FileHoverPreviewController.shared.scheduleHide()
            }
        }
        .onTapGesture(count: 2) {
            // v118：压缩包双击进归档浏览（ArcZip 能力），其他文件仍交给系统
            if ArchiveCore.isArchive(item.stagedURL) {
                ArchiveBrowserWindowController.show(url: item.stagedURL)
            } else {
                LocalTransferStore.shared.open(item)
            }
        }
        .onDrag {
            NSItemProvider(contentsOf: item.stagedURL) ?? NSItemProvider()
        }
        .contextMenu {
            if ArchiveCore.isArchive(item.stagedURL) {
                Button("浏览压缩包") { ArchiveBrowserWindowController.show(url: item.stagedURL) }
                Button("解压到…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.prompt = "解压到这里"
                    if panel.runModal() == .OK, let dir = panel.url {
                        ArchiveCore.extract(url: item.stagedURL, to: dir) { ok, msg in
                            Toast.show(ok ? "已解压" : "解压失败：\(msg)",
                                       icon: ok ? "archivebox" : "exclamationmark.triangle",
                                       isWarning: !ok)
                        }
                    }
                }
                Divider()
            }
            Button("打开") { LocalTransferStore.shared.open(item) }
            Button("在 Finder 中显示") { LocalTransferStore.shared.reveal(item) }
            Divider()
            Button(selected ? "取消勾选" : "勾选") { onToggleSelect(item.id) }
            Button("通用互传这个") { onPickOnly(item.id) }
            if showsCloud {
                Button("加入云端") { TransferDockService.shared.upload(url: item.stagedURL) }
            }
            Divider()
            Button("移出中转") { onRemove(item) }
        }
        .help("悬停预览 · 双击打开 · 拖到 Finder 或其他 App 即可使用")
    }
}

/// v128（流畅度）：行内共用的小件（从 TransferDockView 的私有方法提出，供行视图复用）
private enum TransferRowStyle {
    static func iconName(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp", "gif", "heic": return "photo"
        case "mp4", "mov", "mkv", "avi": return "film"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "md", "txt", "json", "xml", "csv": return "doc.text"
        case "swift", "py", "js", "ts", "c", "cpp", "m", "sh": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    /// 文件格式 → 卡片主题色（v115：让文件区不再是清一色灰）
    static func fileTint(for name: String) -> Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "tiff":   return .pink
        case "mp4", "mov", "mkv", "avi", "webm":                    return .purple
        case "pdf":                                                 return .red
        case "doc", "docx", "pages":                                return .blue
        case "xls", "xlsx", "numbers", "csv":                       return .green
        case "ppt", "pptx", "key":                                  return .orange
        case "zip", "rar", "7z", "tar", "gz", "tgz":                return .brown
        case "swift", "py", "js", "ts", "c", "cpp", "m", "sh",
             "json", "xml", "html", "css":                          return .teal
        case "md", "txt":                                           return .gray
        default:                                                    return .indigo
        }
    }

    static func miniButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
