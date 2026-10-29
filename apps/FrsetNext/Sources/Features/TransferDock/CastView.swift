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
extension Notification.Name {
    /// v159：外部请求打开「扫码直连」弹层（深链 frsetnext://panel?page=cast&qr=1）
    static let frsetOpenCastQR = Notification.Name("frset.openCastQR")
}

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
//
// v158（用户 2026-10-29）：「客户端逻辑也要改，只有唯一的一套；区分 iOS 和安卓设备，
// 其他连接方式都不需要存在，只需要一种唯一的连接方式 + 交互方式——手机扫电脑上的码」。
//   · 连接方式只留「扫码直连」（Android 11+ 无线调试 QR 配对），删掉 USB/tcpip、
//     手动配对、附近扫描、配对卡列表 —— UI 里不再有任何第二条路。
//   · 顶部加设备类型切换：安卓（扫码直连）/ iPhone（系统限制，需 AirPlay 接收端）。

struct CastView: View {

    // MARK: 状态

    @Stored private var devices: [(serial: String, state: String)] = []
    @Stored private var scrcpyReady = false
    @Stored private var scanned = false
    @Stored private var autoScanDone = false
    @Stored private var clipboardSyncOn = TransferDockPref.CastQuality.clipboardAutoSync
    @Stored private var notifications: [ADBExtrasEngine.PhoneNotification] = []
    @Stored private var notifBusy = false
    @Stored private var storageSummary = ""
    @Stored private var storageItems: [ADBExtrasEngine.StorageItem] = []
    @Stored private var catalogApps: [DeviceAppCatalog.App] = []
    @Stored private var appsBusy = false
    @Stored private var mcpOn = false
    @Stored private var webdavOn = false
    // v154：两个折叠区
    @Stored private var toolsExpanded = false

    /// 设备类型：安卓（扫码直连）/ iPhone（系统层限制，暂不支持投屏）
    @Stored private var deviceKind: CastDeviceKind = .android
    // v157：扫码直连（Android 11+ 无线调试 QR 配对）
    @StateObject private var qrPair = AdbQrPairing()
    @Stored private var showQrPair = false
    @ObservedObject private var panelPage = MonitorCenterPresenter.shared

    // v128（流畅度）：轮询 timer 提为 static——原 `Timer.publish(...).autoconnect()` 写在
    // body 的 onReceive 里，每次 body 重算都新建一个 Timer publisher（autoconnect 随订阅
    // 启动新定时器），页面状态一抖就重建定时器。改为共享单例，只在条件满足时干活。
    private static let notifTick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    // MARK: 设备类型

    enum CastDeviceKind: String, CaseIterable {
        case android, ios
        var title: String { self == .android ? "安卓" : "iPhone" }
        var icon: String { self == .android ? "smartphone" : "iphone" }
    }

    // MARK: 派生

    private var connectedDevices: [(serial: String, state: String)] {
        devices.filter { $0.state == "device" }
    }
    private var hasDevice: Bool { !connectedDevices.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                kindSwitch
                Divider().opacity(0.5)
                if deviceKind == .android {
                    hero
                    Divider().opacity(0.5)
                    toolsBlock
                } else {
                    iosPane
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: .frsetOpenCastQR)) { _ in
            showQrPair = true
        }
        .onAppear {
            // v166.1：App 重启后 scrcpy 可能还在跑（我们只负责它的窗口），重新贴回控制条
            ScrcpyControlBarController.shared.attachIfScrcpyRunning()
            // v166.3：进页面就后台预热应用目录（真图标首次要跑一次设备端渲染，别等展开才转圈）
            if catalogApps.isEmpty { loadApps() }
            // v159：回调必须在 guard 之外——视图重建时 @StateObject 可能已是新实例，
            // 放在 guard 后面会导致「第二次进页面点扫码，连上了却不投屏」。
            qrPair.onConnected = { serial in
                showQrPair = false
                Toast.show("已连接 \(serial)，开始投屏", icon: "display")
                ScreenCastEngine.startMirror(serial: serial)
                refreshDevices(quiet: true)
            }
            // 首次进入只做「设备 + scrcpy」，不再顺手拉通知/存储（进工具区才拉）
            guard !autoScanDone else { return }
            autoScanDone = true
            scrcpyReady = ScreenCastEngine.findScrcpy() != nil
            refreshDevices(quiet: true)
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
            if catalogApps.isEmpty { loadApps() }
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
                qrButton("扫码添加设备", prominent: false)
                    .frame(maxWidth: 160)
            }

            if !scrcpyReady {
                Text("未安装投屏组件")
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
        }
    }

    private var heroDetail: String {
        if devices.isEmpty { return scanned ? "未发现设备" : "未检测" }
        let n = connectedDevices.count
        return n > 0 ? "\(n) 台已连接" : "\(devices.count) 台未就绪"
    }

    /// 空态：有历史设备时主按钮是「继续连接」（v159，对标 AndroMeld 的零交互重连）
    private var emptyState: some View {
        let last = AdbCastMemory.shared.lastDevice
        return VStack(spacing: 10) {
            Image(systemName: last == nil ? "qrcode.viewfinder" : "arrow.triangle.2.circlepath")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent.opacity(0.9))
            Text(last == nil ? "用手机扫一下就连上" : "连回上次的设备")
                .font(.system(size: 13, weight: .medium))
            if let last {
                // v159：主路径变成「继续连接」——端口没变时 0 交互直接连上。
                // 这就是 AndroMeld「配对一次之后不用再管」在我们这套 ADB 方案里的等价物。
                qrButton("继续连接 \(last.displayName)", prominent: true)
                    .frame(maxWidth: 240)
                qrButton("扫码连接新设备", prominent: false)
                    .frame(maxWidth: 200)
                Text("上次连接：\(last.serial)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            } else {
                qrButton("扫码直连", prominent: true)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// 设备类型切换（安卓 / iPhone）——顶部分段，两段等宽
    private var kindSwitch: some View {
        HStack(spacing: 4) {
            ForEach(CastDeviceKind.allCases, id: \.self) { k in
                Button {
                    withAnimation(Theme.Motion.fast) { deviceKind = k }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: k.icon)
                            .font(.system(size: 11.5, weight: .medium))
                        Text(k.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(deviceKind == k ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(deviceKind == k ? Color.primary.opacity(0.09) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(k.title)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// iPhone：只留最基本信息，不写说明性长文
    private var iosPane: some View {
        VStack(spacing: 10) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 30))
                .foregroundStyle(Theme.tertiaryText)
            Text("iPhone")
                .font(.system(size: 13, weight: .medium))
            Button {
                MonitorCenterPresenter.shared.selectTransferDock()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12))
                    Text("隔空投送").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Theme.accent.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
    }

    /// 唯一连接入口：弹出二维码
    private func qrButton(_ title: String, prominent: Bool) -> some View {
        Button {
            showQrPair = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: prominent ? 13 : 12, weight: .semibold))
                Text(title)
                    .font(.system(size: prominent ? 13 : 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : Theme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: prominent ? 36 : 30)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.accent.gradient)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.accent.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("手机扫二维码：配对 → 连接 → 投屏（Android 11+ 无线调试）")
        .accessibilityLabel("扫码直连")
        .popover(isPresented: $showQrPair, arrowEdge: .bottom) { qrPairPopover }
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
            Button("打开手机无线调试页") {
                ADBExtrasEngine.openWirelessDebugging { msg in
                    Toast.show(msg, icon: "iphone.gen3")
                }
            }
        }
    }

    /// 遥控行：导航键已经移到 **scrcpy 窗口上的控制条**（v166），面板里不再重复一份，
    /// 这里只留「剪贴板同步」开关。
    private var remoteRow: some View {
        HStack(spacing: 8) {
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

    // MARK: - ② 更多工具（折叠：通知 / 存储 / 应用 / 服务）

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

    // 应用窗口（真实图标 + 真实名称 + 按使用频率排序）
    private var appsBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            subHeader("应用窗口",
                      detail: appsBusy ? "读取中…" : (catalogApps.isEmpty ? "每个 App 一个独立窗口"
                                                                         : "\(catalogApps.count) 个"),
                      refresh: hasDevice ? { loadApps() } : nil)

            if catalogApps.isEmpty {
                hint(hasDevice ? (appsBusy ? "读取中…" : "点右上角刷新读取已安装应用")
                               : "连接设备后可读取")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66, maximum: .infinity), spacing: 6)],
                          spacing: 8) {
                    ForEach(topApps) { app in
                        Button { openApp(app) } label: { appTile(app) }
                            .buttonStyle(.plain)
                            .help(app.label)
                            .accessibilityLabel("在独立窗口打开 \(app.label)")
                    }
                }
                Button {
                    CastAppLibraryWindowController.shared.show()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 11))
                        Text("全部应用")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Theme.accent.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    /// 面板里只放「最可能用到」的 8 个：按使用次数 + 最近使用排序
    private var topApps: [DeviceAppCatalog.App] { Array(catalogApps.prefix(8)) }

    private func appTile(_ app: DeviceAppCatalog.App) -> some View {
        VStack(spacing: 4) {
            Group {
                if let img = app.icon {
                    Image(nsImage: img).resizable().interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(notifTint(app.id).gradient)
                        Text(String(app.label.prefix(1)))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(app.label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func openApp(_ app: DeviceAppCatalog.App) {
        CastAppUsage.record(app.id)
        ADBExtrasEngine.startAppWindow(package: app.id, title: app.label)
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
            // v159：先重连、后扫码。重连阶段不摆二维码，否则用户会以为必须扫。
            if qrPair.phase.showsQR {
                Text("扫码连接")
                    .font(.system(size: 13, weight: .semibold))
                QRCodeView(text: qrPair.qrText, size: 208)
            } else {
                Text("正在连接")
                    .font(.system(size: 13, weight: .semibold))
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                }
                .frame(width: 208, height: 208)
                Button("改为扫码") { qrPair.skipReconnect() }
                    .font(.system(size: 11.5))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
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
        }
        .padding(14)
        .frame(width: 250)
        // v159：生命周期提到整个弹层——重连阶段没有 QRCodeView，
        // 原来挂在它身上的 onAppear 就不会触发，弹层会一直停在 idle。
        .onAppear { qrPair.start() }
        .onDisappear { qrPair.cancel() }
    }

    private var qrPhaseColor: Color {
        switch qrPair.phase {
        case .connected: return .green
        case .failed, .expired: return .orange
        case .idle: return .secondary
        case .reconnecting: return .accentColor      // v159：重连中（蓝）
        case .launching: return .green               // v159：已连上，起画面
        default: return .accentColor
        }
    }

    // MARK: - 数据

    private func refreshDevices(quiet: Bool) {
        scanned = true
        ScreenCastEngine.connectedDevices { list in
            devices = list ?? []
            if !quiet {
                Toast.show(devices.isEmpty
                           ? "未发现设备"
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
        DeviceAppCatalog.shared.load(serial: ADBExtrasEngine.activeSerial) { list in
            appsBusy = false
            catalogApps = list
        }
    }

    private func notifTint(_ pkg: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .red]
        let h = abs(pkg.hashValue)
        return palette[h % palette.count]
    }
}
