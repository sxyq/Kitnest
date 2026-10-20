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

    @Stored private var showsLogin = false
    @Stored private var bridgeAvailable = TransferDockPath.isAvailable
    @Stored private var cloudDropTargeted = false
    @Stored private var localDropTargeted = false
    @Stored private var hoveredCloudID: String?
    @Stored private var hoveredLocalID: String?
    @Stored private var lanCollapsed = false
    /// 本地暂存勾选集合（勾选后可「扫码直传 / 加入云端 / 移出」批量操作）
    @Stored private var selectedIDs = Set<String>()
    /// 「扫码直传」选中文件的二维码链接（带 ?pick=ids，手机只看到这几个）
    @Stored private var pickShareURL: String?
    /// 直传服务是否由「传输」动作拉起（是则勾选清空时随停；手动启动的不代停）
    @Stored private var lanStartedForTransfer = false

    /// 云端分区是否出现：开关 + 桥接工程都在才算
    private var showsCloud: Bool { cloudEnabled && bridgeAvailable }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if lanEnabled {
                lanCard
                Divider().opacity(0.5)
            }

            if showsCloud {
                // 已登录：与本地各占一半；未登录：云端只留一个矮条（空状态说明 + 登录/上传），
                // 把高度让给真正有内容的本地暂存。
                if service.loggedIn {
                    cloudSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    cloudSection
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                }
                Divider().opacity(0.5)
            }

            localSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            bridgeAvailable = TransferDockPath.isAvailable
            if showsCloud {
                service.refresh()
                service.startLiveSync()   // 云端像云盘一样会变 → 30s 实时拉列表
            }
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

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("文件中转")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 6)
            Button {
                if showsCloud { service.refresh() }
                local.objectWillChange.send()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(service.isLoading)
            .help("刷新")

            if showsCloud {
                Button {
                    showsLogin = true
                } label: {
                    Image(systemName: service.loggedIn ? "person.crop.circle" : "person.crop.circle.badge.plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(service.loggedIn ? "重新登录云端" : "登录云端中转")
            }

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("文件中转设置")
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

    // MARK: 手机扫码直传

    private var lanCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 10))
                    .foregroundStyle(lan.running ? Theme.accent : Color.secondary)
                Text("手机扫码直传")
                    .font(.system(size: 11, weight: .semibold))
                Text(lan.running ? "同一 Wi-Fi" : "未启动")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 2)
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { lanCollapsed.toggle() }
                } label: {
                    Image(systemName: lanCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(lanCollapsed ? "展开二维码" : "收起二维码")
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.primary.opacity(0.02))

            if !lanCollapsed {
                HStack(alignment: .top, spacing: 10) {
                    QRCodeView(text: lan.shareURL ?? "frset://lan-pending", size: 74)
                        .opacity(lan.shareURL == nil ? 0.18 : 1)

                    VStack(alignment: .leading, spacing: 4) {
                        if let url = lan.shareURL {
                            Text(url)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                smallAction("复制链接", icon: "doc.on.doc") { copyLink(url) }
                                smallAction("用浏览器打开", icon: "safari") {
                                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                                }
                            }
                            Text(lan.running
                                 ? "微信/相机扫一扫 → 浏览器里选文件上传，也能下载 Mac 上的暂存文件"
                                 : "勾选文件后点「扫码直传」生成二维码；如需手机上传可手动启动")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(lan.statusText.isEmpty ? "服务未启动 · 勾选文件后点「扫码直传」" : lan.statusText)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            smallAction("启动直传", icon: "play.fill") {
                                lan.start()
                            }
                        }
                        if lan.receivedCount > 0 || lan.sentCount > 0 {
                            Text("本次已收 \(lan.receivedCount) · 已发 \(lan.sentCount)")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .padding(.top, 2)
            }
        }
    }

    private func copyLink(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        Toast.show("直传链接已复制", icon: "doc.on.doc")
    }

    private func smallAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8.5))
                Text(title).font(.system(size: 9.5, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 云端（OPPO 中转）

    private var cloudSection: some View {
        VStack(spacing: 0) {
            sectionHeader(title: "云端 · OPPO 中转", symbol: "icloud",
                          detail: service.loggedIn ? "已登录" : "未登录",
                          tint: service.loggedIn ? Theme.accent : .secondary) {
                if service.loggedIn {
                    // 云端是「云盘式」实时同步：绿点 = 自动刷新在跑，旁边是当前文件数
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("实时")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                        if !service.files.isEmpty {
                            Text("\(service.files.count)")
                                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.tertiary)
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
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Button("上传") { pickAndUpload() }
                    .font(.system(size: 10, weight: .medium))
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
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                }
                ForEach(service.files) { file in
                    cloudRow(file)
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

    private func cloudRow(_ file: TransferDockFile) -> some View {
        let hovered = hoveredCloudID == file.id
        return HStack(spacing: 5) {
            Image(systemName: iconName(for: file.name))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.sizeText) · \(file.dateText)")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered {
                HStack(spacing: 5) {
                    miniButton("arrow.down.circle", help: "下载") { service.download(file) }
                    miniButton("trash", help: "删除") { service.delete(file) }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in hoveredCloudID = inside ? file.id : nil }
        .onTapGesture(count: 2) { service.download(file) }
        .contextMenu {
            Button("下载") { service.download(file) }
            Button("删除", role: .destructive) { service.delete(file) }
        }
    }

    private var cloudEmpty: some View {
        VStack(spacing: 6) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.tertiary)
            Text("未登录云端")
                .font(.system(size: 11, weight: .medium))
            Text("登录后可跨设备取回")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Button("登录") { showsLogin = true }
                .font(.system(size: 10.5, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(6)
    }

    private var cloudStatus: String {
        // 未登录时不要把桥接层的原始报错（如「[1003] 用户信息获取失败」）怼到脸上，
        // 那是没 cookie 时的必然结果，对用户没有信息量。
        guard service.loggedIn else { return "未登录" }
        if let error = service.errorMessage { return error }
        if !service.statusMessage.isEmpty { return service.statusMessage }
        if let synced = service.lastSyncedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "同步 \(formatter.string(from: synced))"
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
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("勾选全部条目（勾选后可批量扫码直传 / 加入云端）")

                    Button {
                        local.clearAll()
                        selectedIDs.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9.5))
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
                            .font(.system(size: 9))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text(local.lastMessage.isEmpty ? "拖入即存 · 拖出即用" : local.lastMessage)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button("打开目录") { local.openStagingFolder() }
                        .font(.system(size: 9.5, weight: .medium))
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
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 2)
            smallAction("扫码直传", icon: "qrcode") { showPickQR() }
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
                    Text("扫码接收选中文件")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Button {
                        pickShareURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                QRCodeView(text: url, size: 148)
                Text("手机与本机同一 Wi-Fi，扫码后可直接下载这 \(selectedIDs.count) 个文件")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
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
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .shadow(radius: 18)
        }
        .ignoresSafeArea()
    }

    private var localEmpty: some View {
        VStack(spacing: 5) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text("拖文件到这里")
                .font(.system(size: 11, weight: .medium))
            Text("不占双份空间；手机上传的也落在这里")
                .font(.system(size: 9))
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
            LazyVStack(spacing: 1) {
                ForEach(local.items) { item in
                    localRow(item)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
        }
        .frame(maxHeight: .infinity)
    }

    private func localRow(_ item: LocalTransferItem) -> some View {
        let hovered = hoveredLocalID == item.id
        let selected = selectedIDs.contains(item.id)
        return HStack(spacing: 5) {
            // 勾选框：勾选后底部出现「扫码直传 / 加入云端」批量操作条
            Button {
                toggleSelect(item.id)
            } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.55))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("勾选后可批量扫码直传 / 加入云端")

            Image(systemName: iconName(for: item.name))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 3) {
                    Image(systemName: item.mode.symbol)
                        .font(.system(size: 7))
                    Text("\(item.mode.label) · \(item.sizeText)")
                        .font(.system(size: 8.5))
                }
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered {
                HStack(spacing: 5) {
                    miniButton("folder", help: "在 Finder 中显示") { local.reveal(item) }
                    miniButton("xmark.circle", help: "移出中转") {
                        local.remove(item)
                        selectedIDs.remove(item.id)
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected
                      ? Theme.accent.opacity(0.12)
                      : (hovered ? Color.primary.opacity(0.07) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredLocalID = inside ? item.id : nil
            // 悬停自动出预览（Word / PPT / Excel / PDF / 图片…），移开自动收
            if inside {
                FileHoverPreviewController.shared.scheduleShow(url: item.stagedURL)
            } else {
                FileHoverPreviewController.shared.scheduleHide()
            }
        }
        .onTapGesture(count: 2) { local.open(item) }
        // 拖出去：交给 Finder 的是暂存路径（同源数据，不是再一次拷贝）
        .onDrag {
            NSItemProvider(contentsOf: item.stagedURL) ?? NSItemProvider()
        }
        .contextMenu {
            Button("打开") { local.open(item) }
            Button("在 Finder 中显示") { local.reveal(item) }
            Divider()
            Button(selectedIDs.contains(item.id) ? "取消勾选" : "勾选") { toggleSelect(item.id) }
            Button("扫码直传这个") {
                selectedIDs = [item.id]
                showPickQR()
            }
            if showsCloud {
                Button("加入云端") { service.upload(url: item.stagedURL) }
            }
            Divider()
            Button("移出中转") {
                local.remove(item)
                selectedIDs.remove(item.id)
            }
        }
        .help("悬停预览 · 双击打开 · 拖到 Finder 或其他 App 即可使用")
    }

    // MARK: 共用件

    private func sectionHeader<Trailing: View>(title: String, symbol: String,
                                               detail: String, tint: Color,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 2)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.primary.opacity(0.02))
    }

    private func miniButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func dropHint(_ text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.accent.opacity(0.07))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45),
                              style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .allowsHitTesting(false)
    }

    private func iconName(for name: String) -> String {
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
