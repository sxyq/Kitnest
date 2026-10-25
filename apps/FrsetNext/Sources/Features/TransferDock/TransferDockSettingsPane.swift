import AppKit
import Combine
import SwiftUI

// MARK: - 设置 → 文件中转
//
// 用户 2026-10-20：文件中转要有**单独的设置页**，而不是塞在「常规 → 功能」里一个勾选框。
// 这里集中三件事：
//   ① 面板入口显隐（沿用 panel.transferDock，与常规页同键）；
//   ② 手机扫码直传（内置 HTTP 服务的开关 / 端口 / 二维码 / 地址）；
//   ③ OPPO 云端通道（开关 + 桥接工程目录）——关掉后主面板**完全不渲染**云端分区。
//
// 就地生效：所有开关都不需要重启 App，改完立刻广播 transferDockSettingsDidChange，
// 面板中转页据此重新判可见性并重启/停止直传服务。

struct TransferDockSettingsPane: View {
    @AppStorage(TransferDockPref.panelVisible) private var panelVisible = true
    @AppStorage(TransferDockPref.lanEnabled) private var lanEnabled = true
    @AppStorage(TransferDockPref.cloudEnabled) private var cloudEnabled = true
    @AppStorage(TransferDockPref.autoStageClipboard) private var autoStageClipboard = true

    @ObservedObject private var lan = LanTransferServer.shared
    @ObservedObject private var local = LocalTransferStore.shared

    @Stored private var portText = String(TransferDockPref.lanPort)
    @Stored private var bridgePath = TransferDockPath.root.path
    @Stored private var bridgeAvailable = TransferDockPath.isAvailable
    @Stored private var revision = 0

    var body: some View {
        VStack(spacing: 20) {
            SettingsSection("显示") {
                SettingsGroupBox {
                    row("面板入口", subtitle: "主面板顶部出现「文件中转」分段") {
                        Toggle("", isOn: $panelVisible)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }

            SettingsSection("投屏画质") {
                SettingsGroupBox {
                    row("分辨率", subtitle: "短边上限；「原始」= 设备原生分辨率（更清晰、更吃带宽）") {
                        Picker("", selection: Binding(
                            get: { TransferDockPref.CastQuality.maxSize },
                            set: { TransferDockPref.CastQuality.maxSize = $0; notifyChange() })) {
                            ForEach(TransferDockPref.CastQuality.sizeOptions, id: \.1) { opt in
                                Text(opt.1 == 0 ? "原始" : "\(opt.0)p").tag(opt.1)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    SettingsDivider()
                    row("码率", subtitle: "越高越清晰；Wi-Fi 不稳时降到 8-16") {
                        Picker("", selection: Binding(
                            get: { TransferDockPref.CastQuality.bitrate },
                            set: { TransferDockPref.CastQuality.bitrate = $0; notifyChange() })) {
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
                            get: { TransferDockPref.CastQuality.fps },
                            set: { TransferDockPref.CastQuality.fps = $0; notifyChange() })) {
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
                            get: { TransferDockPref.CastQuality.clipboardAutoSync },
                            set: { TransferDockPref.CastQuality.clipboardAutoSync = $0; notifyChange() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingsDivider()
                    row("当前参数", subtitle: TransferDockPref.CastQuality.summary) {
                        Button("恢复推荐") {
                            TransferDockPref.CastQuality.maxSize = 1920
                            TransferDockPref.CastQuality.bitrate = 16
                            TransferDockPref.CastQuality.fps = 60
                            notifyChange()
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsSection("手机扫码直传") {
                SettingsGroupBox {
                    row("启用", subtitle: "手机与本机在同一 Wi-Fi，扫码即可在浏览器里上传/下载") {
                        Toggle("", isOn: $lanEnabled)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .onChange(of: lanEnabled) { on in
                                // 只在关闭时停服务；开启不自动启动（2026-10-20 用户需求）：
                                // 服务按需启动——中转页勾选文件点「扫码直传」，或点下方「启动」。
                                if !on { lan.stop() }
                                notifyChange()
                            }
                    }
                    SettingsDivider()
                    row("端口", subtitle: portSubtitle) {
                        HStack(spacing: 10) {
                            TextField("8787", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 76)
                                .disabled(!lanEnabled)
                                .onSubmit { applyPort() }
                            Button("应用") { applyPort() }
                                .controlSize(.small)
                                .disabled(!lanEnabled)
                        }
                    }
                    SettingsDivider()
                    row("访问地址", subtitle: lan.running
                        ? "手机浏览器打开即可上传/下载"
                        : "服务未启动 · 勾选文件后点「扫码直传」，或手动启动") {
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
                                Button("停止") { lan.stop(); revision += 1 }
                                    .controlSize(.small)
                            } else {
                                Button("启动") {
                                    lan.startIfEnabled()
                                    revision += 1
                                }
                                .controlSize(.small)
                                .disabled(!lanEnabled)
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
                                Button("重新生成") { lan.rotateToken(); revision += 1 }
                                    .controlSize(.small)
                                    .disabled(!lanEnabled)
                                Text("手机相机 / 微信扫一扫 → 打开直传页")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            SettingsSection("云端中转（OPPO）") {
                SettingsGroupBox {
                    row("启用云端通道", subtitle: "关闭后主面板不再显示云端分区，只剩本地暂存") {
                        Toggle("", isOn: $cloudEnabled)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .onChange(of: cloudEnabled) { _ in
                                bridgeAvailable = TransferDockPath.isAvailable
                                notifyChange()
                            }
                    }
                    SettingsDivider()
                    row("桥接工程", subtitle: bridgeAvailable
                        ? "已找到 frset_bridge.py／登录态文件"
                        : "未找到工程：云端分区会自动隐藏") {
                        HStack(spacing: 10) {
                            Text(bridgePath)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 300, alignment: .leading)
                            Button("选择…") { chooseBridgeFolder() }
                                .controlSize(.small)
                            Button("在 Finder 中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bridgePath)])
                            }
                            .controlSize(.small)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            SettingsSection("本地暂存") {
                SettingsGroupBox {
                    row("剪贴板文件自动暂存", subtitle: "复制 Word / PPT / Excel / PDF / 压缩包等文件时，自动进本地暂存") {
                        Toggle("", isOn: $autoStageClipboard)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
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
                    row("清空暂存", subtitle: "共 \(local.items.count) 项；只删中转里的链接/副本，不动原文件") {
                        Button("清空") {
                            local.clearAll()
                            Toast.show("已清空本地中转", icon: "trash")
                        }
                        .controlSize(.small)
                        .disabled(local.items.isEmpty)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12))
        .onAppear {
            portText = String(TransferDockPref.lanPort)
            bridgePath = TransferDockPath.root.path
            bridgeAvailable = TransferDockPath.isAvailable
            // 不自动拉起直传服务（2026-10-20 用户需求）：按需启动——
            // 中转页勾选文件点「扫码直传」，或本页「访问地址」行手动启动。
        }
        .onReceive(NotificationCenter.default.publisher(for: .localTransferDidChange)) { _ in
            revision += 1
        }
    }

    // MARK: - 行样式（与通用页一致：190pt 标题列 + 右侧控件）

    private func row<Content: View>(_ title: String, subtitle: String? = nil,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }
            .frame(width: 190, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
    }

    private var portSubtitle: String {
        if lan.running { return "正在监听 \(lan.port)" }
        return "默认 8787，被占用时自动顺延"
    }

    // MARK: - 动作

    private func applyPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let value = UInt16(trimmed), value >= 1024 else {
            Toast.show("端口需在 1024–65535 之间", icon: "exclamationmark.triangle", isWarning: true)
            portText = String(TransferDockPref.lanPort)
            return
        }
        TransferDockPref.lanPort = value
        lan.restart()
        Toast.show("直传端口已改为 \(value)", icon: "network")
        notifyChange()
    }

    private func chooseBridgeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择工程目录"
        panel.directoryURL = URL(fileURLWithPath: bridgePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        TransferDockPath.root = url
        bridgePath = url.path
        bridgeAvailable = TransferDockPath.isAvailable
        Toast.show(bridgeAvailable ? "已切换云端中转工程" : "该目录下没找到桥接脚本",
                   icon: bridgeAvailable ? "checkmark.circle" : "exclamationmark.triangle",
                   isWarning: !bridgeAvailable)
        notifyChange()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("已复制直传链接", icon: "doc.on.doc")
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .transferDockSettingsDidChange, object: nil)
    }
}
