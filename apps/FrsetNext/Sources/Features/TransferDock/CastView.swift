import AppKit
import Combine
import SwiftUI

// MARK: - 投屏页（v114 从「文件中转」拆出，主面板顶部第四段）
//
// 用户要求（2026-10-25）：「把投屏分拆开，文件传输这边只仅限 [文件传输]；
// 顶部加一个投屏按钮，做成左右切换的栏」。
//
// 本页职责 = Android 设备中心 + 镜像投屏：
//   ① 设备检测（adb devices）与 scrcpy 就绪状态；
//   ② 无线连接（v112 ADBWirelessEngine：扫描 / 配对码 / 手动连接）；
//   ③ 开始投屏（scrcpy 独立窗，剪贴板双向同步）。
// 文件传输相关（隔空投送 / 扫码直传 / ADB 文件互传 / 本地暂存）留在「文件中转」页。

struct CastView: View {

    // MARK: 状态

    @Stored private var devices: [(serial: String, state: String)] = []
    @Stored private var scrcpyReady = false
    @Stored private var scanned = false
    // 无线配对（v130 移入 AdbPairingView/AdbPairingService，仅保留一键无线/提示用状态）
    @Stored private var wirelessStatus = ""
    @Stored private var autoScanDone = false
    // v130（AndroMeld/AgentHUD）：双向剪贴板显式开关（AndroMeld P0-2）
    @Stored private var clipboardSyncOn = TransferDockPref.CastQuality.clipboardAutoSync
    // v116：通知 / 存储 / 应用
    @Stored private var notifications: [ADBExtrasEngine.PhoneNotification] = []
    @Stored private var notifBusy = false
    @Stored private var storageSummary = ""
    @Stored private var storageItems: [ADBExtrasEngine.StorageItem] = []
    @Stored private var apps: [ADBExtrasEngine.AppItem] = []
    @Stored private var appsBusy = false
    @Stored private var wirelessBusy = false
    @Stored private var mcpOn = false
    @Stored private var webdavOn = false
    @ObservedObject private var panelPage = MonitorCenterPresenter.shared

    // v128（流畅度）：轮询 timer 提为 static——原 `Timer.publish(...).autoconnect()` 写在
    // body 的 onReceive 里，每次 body 重算都新建一个 Timer publisher（autoconnect 随订阅
    // 启动新定时器），页面状态一抖就重建定时器。改为共享单例，只在条件满足时干活。
    private static let notifTick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // v115：设备连上就能投——连接/镜像合并为一个「Android 设备」区
                deviceSection
                Divider().opacity(0.5)
                // v116：通知 / 存储 / 应用（Meld）
                notificationsSection
                Divider().opacity(0.5)
                storageSection
                Divider().opacity(0.5)
                appsSection
                Divider().opacity(0.5)
                servicesSection
                Divider().opacity(0.5)
                tipsSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // 首次进入自动扫一次（设备 + scrcpy 状态），不打扰、只一次
            guard !autoScanDone else { return }
            autoScanDone = true
            scrcpyReady = ScreenCastEngine.findScrcpy() != nil
            refreshDevices(quiet: true)
            refreshNotifications()
            loadStorage()
        }
        // v116：只在「投屏」页在前台时轮询手机通知（6s；离开即停，不空烧 adb）
        // v128（流畅度）：再收紧为「投屏页在前台 + 至少一台设备已连接」才拉通知——
        // 无设备时每 6s 白跑一次 adb 子进程（通知桥会起 shell），纯 CPU/IO 浪费。
        .onReceive(Self.notifTick) { _ in
            guard panelPage.page == .cast else { return }
            guard devices.contains(where: { $0.state == "device" }) else { return }
            // v128（流畅度）：回调体进 autoreleasepool（adb 桥接临时对象随回调排空）
            autoreleasepool { refreshNotifications() }
        }
    }

    // MARK: ① 设备（连接 + 镜像同一件事：连上就能投）

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TransferChrome.sectionHeader(
                title: "Android 设备",
                symbol: "display",
                detail: scrcpyReady
                        ? "双向剪贴板：\(TransferDockPref.CastQuality.clipboardAutoSync ? "已开启" : "已关闭") · \(TransferDockPref.CastQuality.summary)"
                        : "未装 scrcpy（brew install scrcpy）",
                tint: Color(red: 0.45, green: 0.36, blue: 0.95)) {
                TransferChrome.smallAction("检测", icon: "antenna.radiowaves.left.and.right") {
                    scrcpyReady = ScreenCastEngine.findScrcpy() != nil
                    refreshDevices(quiet: false)
                }
                TransferChrome.smallAction("无线扫描",
                                           icon: "wifi") {
                    AdbPairingService.shared.scan()
                }
                // v116：USB 一次 → adb tcpip 5555 → 之后免配对码直连
                TransferChrome.smallAction(wirelessBusy ? "启用中…" : "一键无线",
                                           icon: "wifi.router") {
                    enableWireless()
                }
            }
            .padding(.horizontal, 8)

            if devices.isEmpty {
                emptyDeviceCard
            } else {
                // adaptive 列（同 TransferDockView：预热 0 宽布局下不会算负宽度）
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: .infinity), spacing: 6)],
                          spacing: 6) {
                    ForEach(Array(devices.enumerated()), id: \.offset) { _, dev in
                        deviceCard(serial: dev.serial, state: dev.state)
                    }
                }
                .padding(.horizontal, 10)
            }

            // v130（AndroMeld/AgentHUD）：无线配对独立卡片（AndroMeld P0-1 配对流程 UI：
            // 扫描发现 / 配对码弹框 / 已连接列表 + 断开 / 状态提示），替代原内联配对行
            AdbPairingView()

            // v117：导航键（全面屏/手势机没有实体返回键，投屏时用这排按钮操作手机）
            HStack(spacing: 6) {
                navButton("返回", "arrow.uturn.backward", .back)
                navButton("主页", "house.fill", .home)
                navButton("多任务", "square.on.square", .recents)
                Button {
                    ADBExtrasEngine.expandNotifications()
                } label: {
                    navLabel(icon: "bell.fill", title: "通知栏")
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                TransferChrome.smallAction("画质设置", icon: "slider.horizontal.3") {
                    ServiceLocator.settings?.open(pane: "transfer")
                }
            }
            .padding(.horizontal, 12)

            // v130（AndroMeld/AgentHUD）：双向剪贴板显式开关（AndroMeld P0-2）
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("双向剪贴板：\(clipboardSyncOn ? "已开启" : "已关闭")")
                    .font(.system(size: 9.5, weight: .medium))
                Toggle("", isOn: Binding(
                    get: { clipboardSyncOn },
                    set: { v in
                        TransferDockPref.CastQuality.clipboardAutoSync = v
                        clipboardSyncOn = v
                    }))
                    .labelsHidden()
                    .controlSize(.mini)
                    .toggleStyle(.switch)
                Text("关掉则投屏/Meld 窗口不做 Mac↔手机剪贴板同步")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            // 一键无线 / 打开无线调试页 的状态提示（v130 保留：配对卡片自身状态走 AdbPairingService）
            if !wirelessStatus.isEmpty {
                Text(wirelessStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
    }

    /// 设备卡（双列，与文件中转的文件卡同族）
    private func deviceCard(serial: String, state: String) -> some View {
        let connected = state == "device"
        let tint = connected ? Color.green : Color.orange
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                    Image(systemName: "ipad.landscape")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(serial)
                .font(.system(size: 9.5, design: .monospaced))
                .lineLimit(1)
            if connected {
                Button {
                    ScreenCastEngine.startMirror(serial: serial)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("开始投屏").font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text(state)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contextMenu {
            if connected {
                Button("开始投屏") { ScreenCastEngine.startMirror(serial: serial) }
                Divider()
            }
            Button("用 USB 开启无线（tcpip 5555）") { enableWireless() }
            Button("打开手机无线调试页") {
                ADBExtrasEngine.openWirelessDebugging { msg in
                    wirelessStatus = msg
                    Toast.show(msg, icon: "iphone.gen3")
                }
            }
        }
    }

    /// v116 一键无线：USB 已连时 tcpip + connect
    private func enableWireless() {
        guard !wirelessBusy else { return }
        wirelessBusy = true
        wirelessStatus = "正在用 USB 开启无线…"
        ADBExtrasEngine.enableWireless { ok, msg in
            wirelessBusy = false
            wirelessStatus = msg
            Toast.show(msg, icon: ok ? "wifi.router" : "exclamationmark.triangle", isWarning: !ok)
            if ok { refreshDevices(quiet: true) }
        }
    }

    private var emptyDeviceCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(scanned ? "未发现设备" : "点右上「检测」开始")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("USB 连上并开启「开发者选项 → USB 调试」；或点「无线扫描」配对")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
    }

    private func navButton(_ title: String, _ icon: String, _ key: ADBExtrasEngine.NavKey) -> some View {
        Button {
            ADBExtrasEngine.sendKey(key)
        } label: {
            navLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }

    private func navLabel(icon: String, title: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(title).font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.accent.opacity(0.10), in: Capsule())
        .contentShape(Capsule())
    }

    /// 检测设备（v105 教训：adb 必须后台执行，禁止主线程 waitUntilExit）
    private func refreshDevices(quiet: Bool) {
        scanned = true
        ScreenCastEngine.connectedDevices { list in
            devices = list ?? []
            if !quiet {
                Toast.show(devices.isEmpty
                           ? "未发现 Android 设备（USB 连接并开启 USB 调试）"
                           : "发现 \(devices.count) 台设备",
                           icon: devices.isEmpty ? "antenna.radiowaves.left.and.right.slash" : "display")
            }
        }
    }

    // v130（AndroMeld/AgentHUD）：原 scanWireless/connect/pair 内联实现删除，
    // 配对流程统一走 AdbPairingService/AdbPairingView（host 级 adb，不带 -s）。

    // MARK: ② 手机通知（v116，dumpsys 轮询，零安装）

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TransferChrome.sectionHeader(
                title: "手机通知",
                symbol: "bell.badge",
                detail: notifBusy ? "同步中…" : "零安装 · 6 秒轮询",
                tint: Color(red: 0.95, green: 0.55, blue: 0.15)) {
                TransferChrome.smallAction("刷新", icon: "arrow.clockwise") { refreshNotifications() }
                TransferChrome.smallAction("清空", icon: "trash") { notifications = [] }
            }
            .padding(.horizontal, 8)

            if notifications.isEmpty {
                Text("暂无通知（手机需有未清除的通知；下拉手机通知栏可触发）")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(notifications.prefix(6)) { n in
                        HStack(alignment: .top, spacing: 6) {
                            Text(n.app.prefix(2).uppercased())
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(notifTint(n.pkg).gradient,
                                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(n.title)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(n.time)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                }
                                if !n.text.isEmpty {
                                    Text(n.text)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contextMenu {
                            Button("复制正文") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(n.title + "\n" + n.text, forType: .string)
                                Toast.show("已复制通知内容", icon: "doc.on.doc")
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 10)
    }

    private func notifTint(_ pkg: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .red]
        let h = abs(pkg.hashValue)
        return palette[h % palette.count]
    }

    private func refreshNotifications() {
        guard !notifBusy else { return }
        notifBusy = true
        ADBExtrasEngine.notifications { list in
            notifBusy = false
            notifications = list
        }
    }

    // MARK: ③ 存储（v116）

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TransferChrome.sectionHeader(
                title: "手机存储",
                symbol: "internaldrive",
                detail: storageSummary,
                tint: Color(red: 0.2, green: 0.62, blue: 0.55)) {
                TransferChrome.smallAction("刷新", icon: "arrow.clockwise") { loadStorage() }
            }
            .padding(.horizontal, 8)

            if storageItems.isEmpty {
                HStack(spacing: 6) {
                    smallProgress(0)
                    Text("读取中…").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(storageItems.prefix(6)) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.55).opacity(0.8))
                            Text(item.name)
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(item.sizeText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 10)
    }

    private func smallProgress(_ v: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Theme.accent.gradient)
                    .frame(width: max(2, geo.size.width * v))
            }
        }
        .frame(width: 60, height: 5)
    }

    private func loadStorage() {
        ADBExtrasEngine.storage { summary, items in
            storageSummary = summary
            storageItems = items
        }
    }

    // MARK: ④ 应用 · Meld 独立窗口（v116，scrcpy --new-display）

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TransferChrome.sectionHeader(
                title: "应用窗口",
                symbol: "macwindow.on.rectangle",
                detail: appsBusy ? "读取中…" : "每个 App 一个独立窗口",
                tint: Color(red: 0.62, green: 0.42, blue: 0.95)) {
                TransferChrome.smallAction(apps.isEmpty ? "读取应用" : "重读", icon: "square.grid.2x2") {
                    appsBusy = true
                    ADBExtrasEngine.thirdPartyApps { list in
                        appsBusy = false
                        apps = list
                    }
                }
            }
            .padding(.horizontal, 8)

            if apps.isEmpty {
                Text("读取手机已安装的第三方应用，点一下就在 Mac 上开一个独立窗口（Android 14+）")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: .infinity), spacing: 6)],
                          spacing: 6) {
                    ForEach(apps.prefix(24)) { app in
                        Button {
                            ADBExtrasEngine.startAppWindow(package: app.id)
                        } label: {
                            VStack(spacing: 3) {
                                Text(app.label.prefix(3).uppercased())
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(width: 30, height: 30)
                                    .background(notifTint(app.id).gradient,
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(app.label)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(app.id)
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: ④ 对外服务（MCP / WebDAV）

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TransferChrome.sectionHeader(
                title: "扩展服务",
                symbol: "app.connected.to.app.below.fill",
                detail: "仅本机 127.0.0.1",
                tint: Color(red: 0.35, green: 0.55, blue: 0.95)) { EmptyView() }
            .padding(.horizontal, 8)

            // MCP：给 AI 客户端用
            serviceRow(icon: "brain.head.profile",
                       title: "MCP 服务器",
                       detail: MCPServer.shared.endpoint,
                       on: $mcpOn) { on in
                if on {
                    if !MCPServer.shared.start() { mcpOn = false }
                } else {
                    MCPServer.shared.stop()
                }
            }

            // WebDAV：Finder 挂安卓存储
            serviceRow(icon: "externaldrive.connected.to.line.below",
                       title: "手机文件 · WebDAV",
                       detail: AndroidWebDAVServer.shared.baseURL,
                       on: $webdavOn) { on in
                if on {
                    if !AndroidWebDAVServer.shared.start() { webdavOn = false }
                } else {
                    AndroidWebDAVServer.shared.stop()
                }
            }
            Text("WebDAV：Finder → 前往 → 连接服务器 → 粘贴上面的地址，即可像网络盘一样浏览 /sdcard。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private func serviceRow(icon: String, title: String, detail: String,
                            on: Binding<Bool>, toggle: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 9.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(detail, forType: .string)
                Toast.show("已复制地址", icon: "doc.on.doc")
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(get: { on.wrappedValue },
                                     set: { v in on.wrappedValue = v; toggle(v) }))
                .labelsHidden()
                .controlSize(.mini)
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: ③ 说明

    private var tipsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            label("投屏窗口是独立 scrcpy 窗，关掉即断开（不影响手机）")
            label("多个设备同时连接时，先「检测设备」再对目标设备点「开始投屏」")
            label("投屏/无线连接需要「开发者选项」；公司网络若隔离组播，请用手动 IP:端口")
            label("「一键无线」用 USB 连一次即可（adb tcpip 5555），之后免配对码直连")
            label("「应用窗口」是 scrcpy 虚拟屏（Android 14+），每个 App 独立窗口")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("·").foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
