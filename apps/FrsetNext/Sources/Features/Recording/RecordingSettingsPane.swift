import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - 设置 · 录屏（v264 · C 档五件套的开关面）

struct RecordingSettingsPane: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    @Stored private var fps = RecordingOptions.defaultFPS
    @Stored private var audio: RecordingAudioSource = RecordingOptions.defaultAudio
    @Stored private var showsCursor = RecordingOptions.defaultShowsCursor
    @Stored private var cameraOn = RecordingOptions.cameraEnabled
    @Stored private var cameraDevice = RecordingOptions.cameraDeviceID
    @Stored private var cameraCorner: RecordingCorner = RecordingOptions.cameraCorner
    @Stored private var cameraScale = RecordingOptions.cameraScale
    @Stored private var showKeys = RecordingOptions.showKeys
    @Stored private var showClicks = RecordingOptions.showClicks
    @Stored private var excluded: [String] = RecordingOptions.excludedBundleIDs
    @Stored private var savePath = ""

    private var cameras: [(id: String, name: String)] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video, position: .unspecified)
        return session.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    var body: some View {
        VStack(spacing: 18) {
            startSection
            basicSection
            overlaySection
            excludeSection
            outputSection
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 开始

    private var startSection: some View {
        SettingsSection("录制") {
            SettingsGroupBox {
                HStack(spacing: 10) {
                    Circle()
                        .fill(recorder.state.isActive ? Color.red : Color.secondary.opacity(0.35))
                        .frame(width: 9, height: 9)
                    Text(statusText)
                        .font(.system(size: 12.5))
                    Spacer(minLength: 8)
                    if recorder.state.isActive {
                        Button("暂停 / 继续") { recorder.togglePause() }
                            .controlSize(.small)
                        Button("停止并编辑") {
                            Task { await recorder.stop() }
                        }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("录整屏") { recorder.startDisplayRecording() }
                            .controlSize(.small)
                        Button("录区域…") { recorder.startRegionRecording() }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 9)

                Text("录制时顶部会出现控制条（暂停 / 停止）；控制条本身不会录进画面。停止后自动打开裁剪导出窗口。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
    }

    private var statusText: String {
        switch recorder.state {
        case .idle:       return "就绪"
        case .preparing:  return "准备中…"
        case .recording:  return "录制中 \(recorder.elapsedText)"
        case .paused:     return "已暂停 \(recorder.elapsedText)"
        case .finishing:  return "正在写入文件…"
        }
    }

    // MARK: 基本

    private var basicSection: some View {
        SettingsSection("画面与声音") {
            SettingsGroupBox {
                row("帧率") {
                    Picker("", selection: $fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                        Text("15 fps").tag(15)
                    }
                    .labelsHidden().frame(width: 110)
                    .onChange(of: fps) { RecordingOptions.defaultFPS = $0 }
                    Text("60fps 更顺，但文件约大一倍")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("声音") {
                    Picker("", selection: $audio) {
                        ForEach(RecordingAudioSource.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden().frame(width: 130)
                    .onChange(of: audio) { RecordingOptions.defaultAudio = $0 }
                    Text("系统声音与麦克风只能二选一（双音轨在多数播放器里只播第一条）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("鼠标指针") {
                    Toggle("", isOn: $showsCursor)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: showsCursor) { RecordingOptions.defaultShowsCursor = $0 }
                    Text("关掉后画面更干净，但看不到操作位置")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 叠加

    private var overlaySection: some View {
        SettingsSection("叠加") {
            SettingsGroupBox {
                row("摄像头画中画") {
                    Toggle("", isOn: $cameraOn)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: cameraOn) { RecordingOptions.cameraEnabled = $0 }
                    Picker("", selection: $cameraDevice) {
                        Text("默认摄像头").tag("")
                        ForEach(cameras, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden().frame(width: 160)
                    .disabled(!cameraOn)
                    .onChange(of: cameraDevice) { RecordingOptions.cameraDeviceID = $0 }
                }

                if cameraOn {
                    SettingsDivider()
                    row("位置与大小") {
                        Picker("", selection: $cameraCorner) {
                            ForEach(RecordingCorner.allCases) { corner in
                                Text(corner.title).tag(corner)
                            }
                        }
                        .labelsHidden().frame(width: 90)
                        .onChange(of: cameraCorner) { RecordingOptions.cameraCorner = $0 }
                        Slider(value: $cameraScale, in: 0.10...0.35)
                            .frame(width: 150)
                            .onChange(of: cameraScale) { RecordingOptions.cameraScale = $0 }
                        Text("\(Int(cameraScale * 100))% 画面宽")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsDivider()

                row("显示按键") {
                    Toggle("", isOn: $showKeys)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: showKeys) { RecordingOptions.showKeys = $0 }
                    Text("画面底部显示最近按下的键（需要辅助功能/输入监控权限）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("点击动画") {
                    Toggle("", isOn: $showClicks)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: showClicks) { RecordingOptions.showClicks = $0 }
                    Text("点击处扩散圆环（左键橙 / 右键蓝）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 忽略 App

    private var excludeSection: some View {
        SettingsSection("忽略的 App") {
            SettingsGroupBox {
                Text("这些 App 的窗口不会出现在录制画面里（用 ScreenCaptureKit 的 App 级排除）。适合录教程时把聊天工具、密码管理器挡掉。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                ForEach(excluded, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        Image(systemName: "app.dashed")
                            .foregroundStyle(.secondary)
                        Text(appName(for: bundleID))
                            .font(.system(size: 12))
                        Text(bundleID)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button {
                            removeExcluded(bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }

                HStack(spacing: 8) {
                    Button("添加 App…") { addExcludedApp() }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                    Text("排除是「按 App」，不是按窗口——同一个 App 的所有窗口都不录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: 输出

    private var outputSection: some View {
        SettingsSection("保存") {
            SettingsGroupBox {
                HStack(spacing: 12) {
                    Text("保存到")
                        .font(.system(size: 12.5))
                        .frame(width: 92, alignment: .leading)
                    TextField(RecordingOptions.saveDirectory.path, text: $savePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: 340)
                        .onChange(of: savePath) { RecordingOptions.saveDirectory = URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    Button("选择…") { chooseDirectory() }
                        .controlSize(.small)
                    Button("在访达中打开") {
                        NSWorkspace.shared.open(RecordingOptions.saveDirectory)
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)

                SettingsDivider()

                Text("格式：H.264 MP4，码率按分辨率自动（1080p ≈ 8 Mbps、4K ≈ 12–24 Mbps）。录完可直接播放、上传，或进裁剪窗剪头剪尾。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: 工具

    private func row<Content: View>(_ title: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "排除"
        guard panel.runModal() == .OK else { return }
        var list = excluded
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            if !list.contains(id) { list.append(id) }
        }
        excluded = list
        RecordingOptions.excludedBundleIDs = list
    }

    private func removeExcluded(_ id: String) {
        var list = excluded
        list.removeAll { $0 == id }
        excluded = list
        RecordingOptions.excludedBundleIDs = list
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        savePath = url.path
        RecordingOptions.saveDirectory = url
    }
}
