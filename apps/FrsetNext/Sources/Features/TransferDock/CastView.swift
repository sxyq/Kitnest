import AppKit
import Combine
import SwiftUI

// MARK: - 投屏页（v114 从「文件中转」拆出，主面板顶部第四段）
//
// 用户要求（2026-10-25）：「把投屏分拆开，文件传输这边只仅限 [文件传输]；
// 顶部加一个投屏按钮，做成左右切换的栏」。
//
// v154 精简（用户 2026-10-28：「投屏这边按钮太多了，太小了，内容太多了，需要进行一定的精简」）：
// 旧版把 6 个区块平铺在一屏里——设备(3 个行内按钮) + 配对卡 + 4 连导航 + 画质 + 剪贴板开关
// + 通知(刷新/清空) + 存储(刷新) + 应用(读取 + 24 个磁贴) + 扩展服务(2 复制 + 2 开关) + 5 条说明，
// 合计 45 个可点目标，全部 11pt 字号。在 360pt 面板里既看不清也点不准。
//
// v154.1（同日）：用户又说「按钮太多了，太小了」——上一版虽然收到 3 段，
// 但所有字号仍是全局规范化的 11pt，图标 24–30pt，在 360pt 面板里依然点不准。
// 这一版统一抬一档（正文 11.5–12.5、图标 13–14、主按钮 32 高、折叠行 38 高），
// 并把内容再砍一轮：通知 6→4 条、存储 6→4 条、应用磁贴 24→12 个。
//
// 现在的结构（3 段，进入页面只有 4 个大目标）：
//   ① 投屏主场：设备状态 + 唯一主按钮「开始投屏」+ 遥控行（图标 26pt，仅连接后出现）
//   ② 无线连接：（折叠，点开才出现配对列表 / 手动 IP / 一键无线）
//   ③ 更多工具：（折叠，内含 通知 / 存储 / 应用窗口 / 扩展服务）
// 说明改成右上角「?」弹层，不再常驻 5 行文字。
//
// 性能附赠：手机通知的 6s 轮询、存储与应用的 adb 调用原来在进入页面时就跑，
// 现在都挂在「更多工具」展开之后 —— 不进工具区就不起 adb 子进程。

struct CastView: View {

    // MARK: 状态

    @Stored private var devices: [(serial: String, state: String)] = []
    @Stored private var scrcpyReady = false
    @Stored private var scanned = false
    @Stored private var wirelessStatus = ""
    @Stored private var autoScanDone = false
    @Stored private var clipboardSyncOn = TransferDockPref.CastQuality.clipboardAutoSync
    @Stored private var notifications: [ADBExtrasEngine.PhoneNotification] = []
    @Stored private var notifBusy = false
    @Stored private var storageSummary = ""
    @Stored private var storageItems: [ADBExtrasEngine.StorageItem] = []
    @Stored private var apps: [ADBExtrasEngine.AppItem] = []
    @Stored private var appsBusy = false
    @Stored private var wirelessBusy = false
    @Stored private var mcpOn = false
    @Stored private var webdavOn = false
    // v154：两个折叠区 + 说明弹层
    @Stored private var toolsExpanded = false
    @Stored private var wirelessExpanded = false
    @Stored private var showTips = false
    // v157：扫码直连（Android 11+ 无线调试 QR 配对）
    @StateObject private var qrPair = AdbQrPairing()
    @Stored private var showQrPair = false
    @ObservedObject private var panelPage = MonitorCenterPresenter.shared

    // v128（流畅度）：轮询 timer 提为 static——原 `Timer.publish(...).autoconnect()` 写在
    // body 的 onReceive 里，每次 body 重算都新建一个 Timer publisher（autoconnect 随订阅
    // 启动新定时器），页面状态一抖就重建定时器。改为共享单例，只在条件满足时干活。
    private static let notifTick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    // MARK: 派生

    private var connectedDevices: [(serial: String, state: String)] {
        devices.filter { $0.state == "device" }
    }
    private var hasDevice: Bool { !connectedDevices.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                Divider().opacity(0.5)
                wirelessBlock
                Divider().opacity(0.5)
                toolsBlock
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // 首次进入只做「设备 + scrcpy」，不再顺手拉通知/存储（进工具区才拉）
            guard !autoScanDone else { return }
            autoScanDone = true
            scrcpyReady = ScreenCastEngine.findScrcpy() != nil
            refreshDevices(quiet: true)
            // 扫码配对成功 → 直接投屏（用户点「扫码直连」的预期就是「扫完就看」）
            qrPair.onConnected = { serial in
                showQrPair = false
                Toast.show("已连接 \(serial)，开始投屏", icon: "display")
                ScreenCastEngine.startMirror(serial: serial)
                refreshDevices(quiet: true)
            }
        }
        // v154：轮询条件再收紧一层——「更多工具」没展开就不拉通知（用户看不到也没必要跑 adb）
        .onReceive(Self.notifTick) { _ in
            guard panelPage.page == .cast, toolsExpanded else { return }
            guard hasDevice else { return }
            autoreleasepool { refreshNotifications() }
        }
        // 部署目标 macOS 13：用单参数 onChange（双参数是 14+ API）
        .onChange(of: toolsExpanded) { expanded in
            guard expanded else { return }
            if hasDevice {
                refreshNotifications()
                loadStorage()
            }
            if apps.isEmpty { loadApps() }
        }
    }

    // MARK: - ① 投屏主场

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroHeader

            if devices.isEmpty {
                emptyState
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(devices.enumerated()), id: \.offset) { _, dev in
                        deviceCard(serial: dev.serial, state: dev.state)
                    }
                }
            }

            if hasDevice {
                remoteRow
            }

            if !scrcpyReady {
                Text("未装 scrcpy：brew install scrcpy 后才能投屏")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var heroHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "display")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text("投屏")
                .font(.system(size: 13, weight: .semibold))
            Text(heroDetail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 2)
            iconAction("arrow.clockwise", "重新检测设备") {
                scrcpyReady = ScreenCastEngine.findScrcpy() != nil
                refreshDevices(quiet: false)
            }
            Button {
                showTips = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("投屏使用说明")
            .accessibilityLabel("投屏使用说明")
            .popover(isPresented: $showTips, arrowEdge: .bottom) { tipsPopover }
        }
    }

    private var heroDetail: String {
        if devices.isEmpty { return scanned ? "未发现设备" : "未检测" }
        let n = connectedDevices.count
        return n > 0 ? "\(n) 台已连接" : "\(devices.count) 台未就绪"
    }

    /// 空态：一句话说明 + 两个入口（不再列三行小字）
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 26))
                .foregroundStyle(Theme.tertiaryText)
            Text(scanned ? "未发现设备" : "尚未检测设备")
                .font(.system(size: 12.5, weight: .medium))
            Text("USB 连接手机并开启「开发者选项 → USB 调试」")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                // v154.1：两个按钮原来固定 132/110 宽再留白，现在平分整行——
                // 面板里等宽的双按钮比「一大一小 + 空白」干净，点击面积也更大。
                primaryButton("重新检测", icon: "antenna.radiowaves.left.and.right") {
                    scrcpyReady = ScreenCastEngine.findScrcpy() != nil
                    refreshDevices(quiet: false)
                }
                secondaryButton("无线连接", icon: "wifi") {
                    withAnimation(Theme.Motion.fast) { wirelessExpanded = true }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    /// 设备卡：状态行 + 唯一主按钮
    private func deviceCard(serial: String, state: String) -> some View {
        let connected = state == "device"
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(serial)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(connected ? "已连接" : state)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            }
            if connected {
                primaryButton("开始投屏", icon: "play.fill") {
                    ScreenCastEngine.startMirror(serial: serial)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous))
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

    /// 遥控行：图标按钮 26pt（比原来 11pt 文字的胶囊好点得多）+ 剪贴板同步开关
    private var remoteRow: some View {
        HStack(spacing: 8) {
            navIcon("arrow.uturn.backward", "返回", .back)
            navIcon("house.fill", "主页", .home)
            navIcon("square.on.square", "多任务", .recents)
            Button {
                ADBExtrasEngine.expandNotifications()
            } label: {
                navIconLabel("bell.fill")
            }
            .buttonStyle(.plain)
            .help("下拉手机通知栏")
            .accessibilityLabel("下拉手机通知栏")

            Spacer(minLength: 4)

            // 剪贴板同步：只留图标 + 开关，说明进 tooltip
            HStack(spacing: 3) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { clipboardSyncOn },
                    set: { v in
                        TransferDockPref.CastQuality.clipboardAutoSync = v
                        clipboardSyncOn = v
                    }))
                    .labelsHidden()
                    .controlSize(.mini)
                    .toggleStyle(.switch)
            }
            .help("双向剪贴板（\(clipboardSyncOn ? "已开启" : "已关闭")）：关掉则投屏窗口不做 Mac↔手机同步")
            .accessibilityLabel("双向剪贴板")
        }
    }

    private func navIcon(_ icon: String, _ title: String,
                         _ key: ADBExtrasEngine.NavKey) -> some View {
        Button {
            ADBExtrasEngine.sendKey(key)
        } label: {
            navIconLabel(icon)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func navIconLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundStyle(Theme.accent)
            .frame(width: 34, height: 30)
            .background(Theme.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
    }

    // MARK: - ② 无线连接（折叠）

    private var wirelessBlock: some View {
        VStack(spacing: 0) {
            disclosureRow(title: "无线连接",
                          icon: "wifi",
                          detail: wirelessDetail,
                          expanded: wirelessExpanded) {
                withAnimation(Theme.Motion.fast) { wirelessExpanded.toggle() }
            }

            if wirelessExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // v157（用户：「最重要的是扫码直连，不是基于某个局域网再用 adb 连」）：
                    // 主路径改成扫码——手机扫一下即配对+连接+投屏，不用插线、不用输 IP。
                    Button {
                        showQrPair = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 13, weight: .semibold))
                            Text("扫码直连")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Theme.accent.gradient,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control,
                                                         style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("手机扫一下二维码即配对、连接并开始投屏（Android 11+ 无线调试）")
                    .accessibilityLabel("扫码直连")
                    .popover(isPresented: $showQrPair, arrowEdge: .bottom) { qrPairPopover }

                    Text("手机：设置 → 开发者选项 → 无线调试 → 「使用二维码配对设备」")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    // 兜底两条：USB 打开 tcpip / 手动配对列表
                    HStack(spacing: 6) {
                        secondaryButton(wirelessBusy ? "启用中…" : "USB 开无线",
                                        icon: "wifi.router") { enableWireless() }
                        secondaryButton("手动配对", icon: "antenna.radiowaves.left.and.right") {
                            AdbPairingService.shared.scan()
                        }
                    }

                    // 配对卡片自带「发现列表 + 手动 IP + 状态」，这里内嵌，不再重复标题与按钮
                    AdbPairingView(embedded: true)

                    if !wirelessStatus.isEmpty {
                        Text(wirelessStatus)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private var wirelessDetail: String {
        if wirelessBusy { return "启用中…" }
        let n = AdbPairingService.shared.wirelessConnected.count
        return n > 0 ? "\(n) 台无线已连" : "扫码直连，零手输"
    }

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

    // MARK: - ③ 更多工具（折叠：通知 / 存储 / 应用 / 服务）

    private var toolsBlock: some View {
        VStack(spacing: 0) {
            disclosureRow(title: "更多工具",
                          icon: "square.grid.2x2",
                          detail: "通知 · 存储 · 应用 · 服务",
                          expanded: toolsExpanded) {
                withAnimation(Theme.Motion.fast) { toolsExpanded.toggle() }
            }

            if toolsExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    notificationsBlock
                    storageBlock
                    appsBlock
                    servicesBlock
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
        }
    }

    // 通知
    private var notificationsBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            subHeader("手机通知",
                      detail: notifBusy ? "同步中…" : (hasDevice ? "6 秒自动" : "未连接设备"),
                      refresh: hasDevice ? { refreshNotifications() } : nil)

            if notifications.isEmpty {
                hint("暂无通知（手机需有未清除的通知）")
            } else {
                VStack(spacing: 3) {
                    ForEach(notifications.prefix(4)) { n in
                        HStack(alignment: .top, spacing: 6) {
                            Text(n.app.prefix(2).uppercased())
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(notifTint(n.pkg).gradient,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip,
                                                                style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(n.title)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(n.time)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                                if !n.text.isEmpty {
                                    Text(n.text)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.03),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.chip,
                                                        style: .continuous))
                        .contextMenu {
                            Button("复制正文") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(n.title + "\n" + n.text, forType: .string)
                                Toast.show("已复制通知内容", icon: "doc.on.doc")
                            }
                        }
                    }
                }
                .contextMenu {
                    Button("清空列表") { notifications = [] }
                }
            }
        }
    }

    // 存储
    private var storageBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            subHeader("手机存储",
                      detail: storageSummary.isEmpty ? (hasDevice ? "读取中…" : "未连接设备") : storageSummary,
                      refresh: hasDevice ? { loadStorage() } : nil)

            if storageItems.isEmpty {
                hint(hasDevice ? "读取中…" : "连接设备后可查看")
            } else {
                VStack(spacing: 2) {
                    ForEach(storageItems.prefix(4)) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.2, green: 0.62, blue: 0.55).opacity(0.8))
                            Text(item.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(item.sizeText)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // 应用窗口
    private var appsBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            subHeader("应用窗口",
                      detail: appsBusy ? "读取中…" : "每个 App 一个独立窗口",
                      refresh: hasDevice ? { loadApps() } : nil)

            if apps.isEmpty {
                hint(hasDevice ? (appsBusy ? "读取中…" : "点右上角刷新读取已安装应用")
                               : "连接设备后可读取")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: .infinity), spacing: 6)],
                          spacing: 6) {
                    ForEach(apps.prefix(12)) { app in
                        Button {
                            ADBExtrasEngine.startAppWindow(package: app.id)
                        } label: {
                            VStack(spacing: 3) {
                                Text(app.label.prefix(3).uppercased())
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(width: 34, height: 34)
                                    .background(notifTint(app.id).gradient,
                                                in: RoundedRectangle(cornerRadius: Theme.Radius.control,
                                                                    style: .continuous))
                                Text(app.label)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.control,
                                                            style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(app.id)
                        .accessibilityLabel("在独立窗口打开 \(app.label)")
                    }
                }
            }
        }
    }

    // 扩展服务
    private var servicesBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            subHeader("扩展服务", detail: "仅本机 127.0.0.1", refresh: nil)

            serviceRow(icon: "brain.head.profile",
                       title: "MCP 服务器",
                       detail: MCPServer.shared.endpoint,
                       help: "给 AI 客户端用的本机 MCP 接口",
                       on: $mcpOn) { on in
                if on {
                    if !MCPServer.shared.start() { mcpOn = false }
                } else {
                    MCPServer.shared.stop()
                }
            }

            serviceRow(icon: "externaldrive.connected.to.line.below",
                       title: "手机文件 · WebDAV",
                       detail: AndroidWebDAVServer.shared.baseURL,
                       help: "Finder → 前往 → 连接服务器 → 粘贴地址，即可像网络盘一样浏览 /sdcard",
                       on: $webdavOn) { on in
                if on {
                    if !AndroidWebDAVServer.shared.start() { webdavOn = false }
                } else {
                    AndroidWebDAVServer.shared.stop()
                }
            }
        }
    }

    private func serviceRow(icon: String, title: String, detail: String, help: String,
                            on: Binding<Bool>, toggle: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(detail, forType: .string)
                Toast.show("已复制地址", icon: "doc.on.doc")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制地址")
            .accessibilityLabel("复制 \(title) 地址")
            Toggle("", isOn: Binding(get: { on.wrappedValue },
                                     set: { v in on.wrappedValue = v; toggle(v) }))
                .labelsHidden()
                .controlSize(.mini)
                .toggleStyle(.switch)
                .accessibilityLabel("\(title) 开关")
        }
        .padding(.vertical, 1)
        .help(help)
    }

    // MARK: - 通用小部件

    /// 折叠入口行（高度 32、整行可点、chevron 随状态旋转）
    private func disclosureRow(title: String, icon: String, detail: String,
                               expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(expanded ? "收起" : "展开")")
    }

    /// 工具区子标题：标题 + 说明 + 单个刷新图标（不再各配一排胶囊按钮）
    private func subHeader(_ title: String, detail: String,
                           refresh: (() -> Void)?) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 2)
            if let refresh {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("刷新\(title)")
                .accessibilityLabel("刷新\(title)")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func iconAction(_ icon: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// 主按钮：整宽、高 28、强调色实底（一屏只有一个）
    private func primaryButton(_ title: String, icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(Theme.accent.gradient,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 次按钮：描边、高 26、无底色填充
    private func secondaryButton(_ title: String, icon: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Theme.accent.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - 扫码直连弹层

    private var qrPairPopover: some View {
        VStack(spacing: 10) {
            Text("用手机扫这张码")
                .font(.system(size: 13, weight: .semibold))
            QRCodeView(text: qrPair.qrText, size: 208)
                .onAppear { qrPair.start() }
                .onDisappear { qrPair.cancel() }
            HStack(spacing: 5) {
                Circle()
                    .fill(qrPhaseColor)
                    .frame(width: 6, height: 6)
                Text(qrPair.phase.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(qrPair.phase.isTerminal ? Theme.tertiaryText : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if qrPair.phase.isTerminal {
                Button("重新生成") { qrPair.restart() }
                    .font(.system(size: 11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            Text("手机与 Mac 需在同一 Wi-Fi（未开热点隔离）")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
    }

    private var qrPhaseColor: Color {
        switch qrPair.phase {
        case .connected: return .green
        case .failed, .expired: return .orange
        case .idle: return .secondary
        default: return .accentColor
        }
    }

    // MARK: - 说明弹层（替代原来常驻的 5 行小字）

    private var tipsPopover: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("投屏说明")
                .font(.system(size: 12.5, weight: .semibold))
            tipLine("投屏窗口是独立 scrcpy 窗，关掉即断开（不影响手机）")
            tipLine("需要手机开启「开发者选项 → USB 调试」")
            tipLine("「一键无线」USB 连一次即可，之后免配对码直连")
            tipLine("「应用窗口」是虚拟屏（Android 14+），每个 App 独立窗口")
        }
        .padding(12)
        .frame(width: 268, alignment: .leading)
    }

    private func tipLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("·").foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 数据

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

    private func refreshNotifications() {
        guard !notifBusy else { return }
        notifBusy = true
        ADBExtrasEngine.notifications { list in
            notifBusy = false
            notifications = list
        }
    }

    private func loadStorage() {
        ADBExtrasEngine.storage { summary, items in
            storageSummary = summary
            storageItems = items
        }
    }

    private func loadApps() {
        guard !appsBusy else { return }
        appsBusy = true
        ADBExtrasEngine.thirdPartyApps { list in
            appsBusy = false
            apps = list
        }
    }

    private func notifTint(_ pkg: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .red]
        let h = abs(pkg.hashValue)
        return palette[h % palette.count]
    }
}
