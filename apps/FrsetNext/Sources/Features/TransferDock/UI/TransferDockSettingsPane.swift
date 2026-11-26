import AppKit
import Combine
import SwiftUI

final class LocalTransferSettingsDraft: SettingsEditableDraft {
    @Published var featureEnabled = TransferDockPref.isOn(TransferDockPref.featureEnabled)
    @Published var autoStage = TransferDockPref.isOn(TransferDockPref.autoStageClipboard)
    @Published var hoverPreview = TransferDockPref.hoverPreviewEnabled
    @Published var retentionDays = TransferDockPref.retentionDays
    private var saved = [String]()
    init() { saved = values }
    private var values: [String] { [String(featureEnabled), String(autoStage), String(hoverPreview), String(retentionDays)] }
    var isDirty: Bool { values != saved }
    func save() -> String? {
        if values[0] != saved[0] { Preferences.shared.set(TransferDockPref.featureEnabled, featureEnabled) }
        if values[1] != saved[1] { Preferences.shared.set(TransferDockPref.autoStageClipboard, autoStage) }
        if values[2] != saved[2] { Preferences.shared.set(TransferDockPref.hoverPreviewKey, hoverPreview) }
        if values[3] != saved[3] { Preferences.shared.set(TransferDockPref.retentionDaysKey, retentionDays) }
        guard UserDefaults.standard.synchronize() else { return "本地中转设置写入磁盘失败，调整已保留" }
        if values[3] != saved[3] { LocalTransferStore.shared.startRetentionCleanup() }
        NotificationCenter.default.post(name: .transferDockSettingsDidChange, object: nil)
        saved = values
        objectWillChange.send()
        return nil
    }
    func discard() {
        featureEnabled = TransferDockPref.isOn(TransferDockPref.featureEnabled)
        autoStage = TransferDockPref.isOn(TransferDockPref.autoStageClipboard)
        hoverPreview = TransferDockPref.hoverPreviewEnabled
        retentionDays = TransferDockPref.retentionDays
        saved = values
    }
    func restoreDefaults() { featureEnabled = true; autoStage = true; hoverPreview = true; retentionDays = 0 }
}

final class ScanTransferSettingsDraft: SettingsEditableDraft {
    @Published var enabled = TransferDockPref.isOn(TransferDockPref.lanEnabled)
    @Published var portText = String(TransferDockPref.lanPort)
    private var saved: [String] = []
    init() { saved = values }
    private var values: [String] { [String(enabled), portText] }
    var isDirty: Bool { values != saved }
    func save() -> String? {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
            return "端口需在 1024–65535 之间"
        }
        if values[0] != saved[0] { Preferences.shared.set(TransferDockPref.lanEnabled, enabled) }
        if portText != saved[1] { TransferDockPref.lanPort = port }
        guard UserDefaults.standard.synchronize() else { return "手机直传设置写入磁盘失败，调整已保留" }
        portText = String(port)
        saved = values
        objectWillChange.send()
        return nil
    }
    func discard() {
        enabled = TransferDockPref.isOn(TransferDockPref.lanEnabled)
        portText = String(TransferDockPref.lanPort)
        saved = values
    }
    func restoreDefaults() { enabled = true; portText = String(TransferDockPref.defaultLanPort) }
}

final class CloudTransferSettingsDraft: SettingsEditableDraft {
    @Published var enabled = TransferDockPref.isOn(TransferDockPref.cloudEnabled)
    @Published var bridgePath = TransferDockPath.root.path
    private var saved: [String] = []
    init() { saved = values }
    private var values: [String] { [String(enabled), bridgePath] }
    var isDirty: Bool { values != saved }
    var bridgeAvailable: Bool {
        let root = URL(fileURLWithPath: bridgePath)
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("网页/scripts/frset_bridge.py").path)
            || FileManager.default.fileExists(atPath: root.appendingPathComponent("credentials/cookies.json").path)
    }
    func save() -> String? {
        if values[0] != saved[0] { Preferences.shared.set(TransferDockPref.cloudEnabled, enabled) }
        if bridgePath != saved[1] { TransferDockPath.root = URL(fileURLWithPath: bridgePath) }
        guard UserDefaults.standard.synchronize() else { return "云端中转设置写入磁盘失败，调整已保留" }
        NotificationCenter.default.post(name: .transferDockSettingsDidChange, object: nil)
        saved = values
        objectWillChange.send()
        return nil
    }
    func discard() {
        enabled = TransferDockPref.isOn(TransferDockPref.cloudEnabled)
        bridgePath = TransferDockPath.root.path
        saved = values
    }
    func restoreDefaults() {
        enabled = true
        bridgePath = "/Users/sunyiyang/Desktop/Project/temp/OPPO 中转站"
    }
}

final class CastTransferSettingsDraft: SettingsEditableDraft {
    struct Values: Equatable {
        var maxSize = 1920
        var bitrate = 16
        var fps = 60
        var clipboardAutoSync = true
        static var current: Self {
            Self(maxSize: TransferDockPref.CastQuality.maxSize, bitrate: TransferDockPref.CastQuality.bitrate,
                 fps: TransferDockPref.CastQuality.fps, clipboardAutoSync: TransferDockPref.CastQuality.clipboardAutoSync)
        }
        var summary: String {
            let size = maxSize == 0 ? "原始分辨率" : "长边 ≤\(maxSize) px"
            let frames = fps == 0 ? "默认帧率" : "\(fps)fps"
            return "\(size) · \(bitrate)Mbps · \(frames)"
        }
    }
    @Published var values = Values.current
    private var saved = Values.current
    var isDirty: Bool { values != saved }
    func save() -> String? {
        if values.maxSize != saved.maxSize { TransferDockPref.CastQuality.maxSize = values.maxSize }
        if values.bitrate != saved.bitrate { TransferDockPref.CastQuality.bitrate = values.bitrate }
        if values.fps != saved.fps { TransferDockPref.CastQuality.fps = values.fps }
        if values.clipboardAutoSync != saved.clipboardAutoSync { TransferDockPref.CastQuality.clipboardAutoSync = values.clipboardAutoSync }
        guard UserDefaults.standard.synchronize() else { return "投屏设置写入磁盘失败，调整已保留" }
        saved = values
        objectWillChange.send()
        return nil
    }
    func discard() { values = .current; saved = values }
    func restoreDefaults() { values = Values() }
}

// 偏好只写草稿；服务启停与账号登录是即时操作。

struct TransferDockSettingsPane: View {
    enum Section: Hashable { case cast, scan, cloud, local }
    var section: Section = .local

    @ObservedObject private var lan = LanTransferServer.shared
    @ObservedObject private var local = LocalTransferStore.shared
    @ObservedObject private var cloud = TransferDockService.shared

    var body: some View {
        VStack(spacing: 20) {
            switch section {
            case .local:   localSection
            case .cast:    castSection
            case .scan:    scanSection
            case .cloud:   cloudSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12))
    }

    // MARK: - 二级页内容

    /// 二级页：投屏画质
    private var castSection: some View {
        SettingsDraftEditor(id: "transferCast", makeDraft: { CastTransferSettingsDraft() }) { draft in
        SettingsSection("投屏画质") {
            SettingsGroupBox {
                row("分辨率", subtitle: "长边像素上限；「原始」= 设备原生分辨率（更清晰、更吃带宽）") {
                    Picker("", selection: Binding(
                        get: { draft.values.maxSize },
                        set: { draft.values.maxSize = $0 })) {
                        ForEach(TransferDockPref.CastQuality.sizeOptions, id: \.1) { opt in
                            Text(opt.1 == 0 ? "原始" : "≤\(opt.0) px").tag(opt.1)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                SettingsDivider()
                row("码率", subtitle: "越高越清晰；Wi-Fi 不稳时降到 8-16") {
                    Picker("", selection: Binding(
                        get: { draft.values.bitrate },
                        set: { draft.values.bitrate = $0 })) {
                        ForEach(TransferDockPref.CastQuality.bitrateOptions, id: \.self) { b in
                            Text("\(b) Mbps").tag(b)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                SettingsDivider()
                row("帧率", subtitle: "30 省电；60 顺滑；90 高刷屏") {
                    Picker("", selection: Binding(
                        get: { draft.values.fps },
                        set: { draft.values.fps = $0 })) {
                        ForEach(TransferDockPref.CastQuality.fpsOptions, id: \.self) { f in
                            Text(f == 0 ? "默认" : "\(f) fps").tag(f)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                }
                SettingsDivider()
                // v130（AndroMeld/AgentHUD）：双向剪贴板显式开关（AndroMeld P0-2）
                row("双向剪贴板", subtitle: "Mac↔手机剪贴板自动同步；关闭后投屏/Meld 窗口不再同步剪贴板") {
                    Toggle("", isOn: Binding(
                        get: { draft.values.clipboardAutoSync },
                        set: { draft.values.clipboardAutoSync = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsDivider()
                row("草稿参数", subtitle: draft.values.summary + "（保存后，下次启动投屏时生效）") {
                    Button("恢复推荐") {
                        draft.values.maxSize = 1920
                        draft.values.bitrate = 16
                        draft.values.fps = 60
                    }
                    .controlSize(.small)
                }
            }
        }
        }
    }

    /// 二级页：手机扫码直传
    private var scanSection: some View {
        SettingsDraftEditor(id: "transferScan", makeDraft: { ScanTransferSettingsDraft() }) { draft in
        SettingsSection("手机扫码直传") {
            SettingsGroupBox {
                row("允许手机直传", subtitle: "保存配置后可手动启动；修改配置不启停正在运行的服务") {
                    Toggle("", isOn: Binding(get: { draft.enabled }, set: { draft.enabled = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsDivider()
                row("端口", subtitle: "保存后供下次启动使用；默认 8787，被占用时自动顺延") {
                    TextField("8787", text: Binding(get: { draft.portText }, set: { draft.portText = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                }
            }
        }
        SettingsSection("服务即时操作") {
            SettingsGroupBox {
                row("访问地址", subtitle: lan.running
                    ? "正在监听 \(lan.port)；停止后重新启动才使用已保存端口"
                    : "服务未启动 · 启动使用已保存配置，不应用当前草稿") {
                    HStack(spacing: 10) {
                        Text(lan.shareURL ?? "—")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(lan.shareURL == nil ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let url = lan.shareURL {
                            Button("复制") { copy(url) }.controlSize(.small)
                            Button("打开") {
                                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                            }
                            .controlSize(.small)
                        } else {
                            Text("配置端口 \(TransferDockPref.lanPort)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Button(lan.running ? "停止" : "启动") {
                            if lan.running { lan.stop() }
                            else { lan.startIfEnabled() }
                        }
                        .controlSize(.small)
                        .disabled(!lan.running && !TransferDockPref.isOn(TransferDockPref.lanEnabled))
                        // 2026-11-26 修复（二轮 low）：LanTransferServer.restart() 原本是死代码
                        // （改端口保存后只能手动「停止 → 启动」）。给它一个入口：运行中显示，
                        // 按**已保存**端口重新监听；草稿未保存时提示，避免误以为改了草稿就生效。
                        if lan.running {
                            Button("按已保存端口重启") {
                                lan.restart()
                                Toast.show("已按保存的端口重启直传服务", icon: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .help("用设置里已保存的端口重新监听；当前草稿未保存时不生效")
                        }
                        Spacer(minLength: 0)
                    }
                }
                SettingsDivider()
                row("二维码", subtitle: "重新生成后，之前扫过的链接立即失效") {
                    HStack(spacing: 14) {
                        if let url = lan.shareURL {
                            QRCodeView(text: url, size: 84)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Button("重新生成") { lan.rotateToken() }
                                .controlSize(.small)
                                .disabled(!lan.running)
                            Text("手机相机 / 微信扫一扫 → 打开直传页")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        }
    }

    /// 二级页：云端中转
    private var cloudSection: some View {
        SettingsDraftEditor(id: "transferCloud", makeDraft: { CloudTransferSettingsDraft() }) { draft in
        SettingsSection("云端中转（OPPO）") {
            SettingsGroupBox {
                row("启用云端通道", subtitle: "关闭后主面板不再显示云端分区，只剩本地暂存") {
                    Toggle("", isOn: Binding(get: { draft.enabled }, set: { draft.enabled = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsDivider()
                row("桥接工程", subtitle: draft.bridgeAvailable
                    ? "草稿目录已找到桥接脚本／登录态文件，保存后使用"
                    : "草稿目录未找到工程；保存后云端分区隐藏") {
                    HStack(spacing: 10) {
                        Text(draft.bridgePath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 300, alignment: .leading)
                        Button("选择…") { chooseBridgeFolder(draft) }
                            .controlSize(.small)
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: draft.bridgePath)])
                        }
                        .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        SettingsSection("云端即时操作") {
            SettingsGroupBox {
                row("云端同步", subtitle: "启停即时生效，使用已保存的桥接工程，不应用草稿") {
                    HStack(spacing: 10) {
                        Button("开始同步") { cloud.refresh(); cloud.startLiveSync() }
                        Button("停止同步") { cloud.stopLiveSync() }
                    }.controlSize(.small)
                }
                SettingsDivider()
                row("云端账号", subtitle: "登录与凭据写入即时生效，使用已保存的桥接工程，不应用草稿") {
                    HStack(spacing: 10) {
                        Text(cloud.loggedIn ? "已登录" : "未登录").foregroundStyle(.secondary)
                        Button(cloud.loggedIn ? "重新登录…" : "登录…") {
                            NotificationCenter.default.post(name: .frsetOpenTransferLogin, object: nil)
                        }.controlSize(.small)
                    }
                }
            }
        }
        }
    }

    /// 二级页：本地暂存
    private var localSection: some View {
        SettingsDraftEditor(id: "transferLocal", makeDraft: { LocalTransferSettingsDraft() }) { draft in
        SettingsSection("本地暂存") {
            SettingsGroupBox {
                row("启用文件中转", subtitle: "运行开关，保存后生效；主面板页面显隐在主面板设置调整") {
                    Toggle("", isOn: Binding(get: { draft.featureEnabled }, set: { draft.featureEnabled = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsDivider()
                row("剪贴板文件自动暂存", subtitle: "文件与文件夹复制后同时出现在剪贴板和中转；重复复制只置顶") {
                    Toggle("剪贴板文件自动暂存", isOn: Binding(get: { draft.autoStage }, set: { draft.autoStage = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsDivider()
                row("悬停预览", subtitle: "尺寸随内容自适应；动画跟随主面板。关闭后仍可点预览或按空格") {
                    Toggle("悬停预览", isOn: Binding(get: { draft.hoverPreview }, set: { draft.hoverPreview = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingsDivider()
                row("自动清理", subtitle: "每小时清理超出保留期的暂存；原文件保留，移出的内容可从废纸篓找回") {
                    Toggle("自动清理", isOn: Binding(get: { draft.retentionDays > 0 },
                        set: { draft.retentionDays = $0 ? 30 : 0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if draft.retentionDays > 0 {
                    row("保留天数", subtitle: "以最近一次加入或复制为起点；保存后生效") {
                        HStack {
                            Slider(value: Binding(get: { Double(draft.retentionDays) },
                                set: { draft.retentionDays = Int($0) }), in: 1...365, step: 1)
                                .frame(width: 170).accessibilityLabel("本地暂存保留天数")
                            Text("\(draft.retentionDays) 天").monospacedDigit().frame(width: 50)
                        }
                    }
                }
                SettingsDivider()
                row("暂存目录", subtitle: "手机上传的文件落在同一处") {
                    HStack(spacing: 10) {
                        Text(LocalTransferPaths.root.path)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 300, alignment: .leading)
                        Button("打开") { local.openStagingFolder() }
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }
                SettingsDivider()
                row("清理已过期", subtitle: "即时操作，按已保存的保留期清理；当前 \(local.items.count) 项") {
                    Button("立即清理") {
                        local.pruneExpired { result in
                            Toast.show(local.lastError ?? "已清理 \(result.removed) 项暂存到废纸篓", icon: local.lastError == nil ? "trash" : "exclamationmark.triangle", isWarning: local.lastError != nil)
                        }
                    }.controlSize(.small).disabled(TransferDockPref.retentionDays == 0)
                }
                SettingsDivider()
                row("清空暂存", subtitle: "即时操作；只移出中转里的链接/副本，不动原文件") {
                    Button("清空") {
                        local.remove(local.items) { result in
                            Toast.show(local.lastError ?? "已移出 \(result.removed) 项到废纸篓", icon: local.lastError == nil ? "trash" : "exclamationmark.triangle", isWarning: local.lastError != nil)
                        }
                    }
                    .controlSize(.small)
                    .disabled(local.items.isEmpty)
                }
            }
        }
        }
    }

    // MARK: - 行样式（与通用页一致：190pt 标题列 + 右侧控件）

    private func row<Content: View>(_ title: String, subtitle: String? = nil,
                                    @ViewBuilder content: () -> Content) -> some View {
        // v272：与 SettingsRow 同构（左标题 / 副标题，右控件），
        // 不再用 190pt 右对齐标题列——同一窗口两种版式是「不统一」的主要来源
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 16)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 44)
    }

    // MARK: - 动作

    private func chooseBridgeFolder(_ draft: CloudTransferSettingsDraft) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工程目录"
        panel.directoryURL = URL(fileURLWithPath: draft.bridgePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.bridgePath = url.path
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("已复制直传链接", icon: "doc.on.doc")
    }

}
