import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - 设置 · 录屏（v264 · C 档五件套的开关面）

struct RecordingSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "recording", makeDraft: { RecordingSettingsDraft() }) { draft in
            RecordingSettingsContent(draft: draft)
        }
    }
}

final class RecordingSettingsDraft: SettingsEditableDraft {
    typealias Values = RecordingSettingsValues
    @Published var values = Values.current
    @Published var savePath = RecordingOptions.savePathRaw
    private var saved = Values.current
    private var savedPath = RecordingOptions.savePathRaw
    var isDirty: Bool { values != saved || savePath != savedPath }

    func save() -> String? {
        applyEffects()
        if values.fps != saved.fps { RecordingOptions.defaultFPS = values.fps }
        if values.audio != saved.audio { RecordingOptions.defaultAudio = values.audio }
        if values.cameraDevice != saved.cameraDevice { RecordingOptions.cameraDeviceID = values.cameraDevice }
        if values.excluded != saved.excluded { RecordingOptions.excludedBundleIDs = values.excluded }
        if savePath != savedPath { Preferences.shared.set(RecordingOptions.keySavePath, savePath) }
        guard UserDefaults.standard.synchronize() else { return "录屏设置写入磁盘失败，调整已保留" }
        objectWillChange.send()
        saved = values
        savedPath = savePath
        return nil
    }
    func discard() {
        values = .current
        savePath = RecordingOptions.savePathRaw
        saved = values
        savedPath = savePath
    }
    func restoreDefaults() { values = Values(); savePath = "" }

    func isDirty(in scope: String) -> Bool {
        guard scope == "effects" else { return isDirty }
        return values.showsCursor != saved.showsCursor || values.cameraOn != saved.cameraOn ||
            values.cameraCorner != saved.cameraCorner || values.cameraScale != saved.cameraScale ||
            values.showKeys != saved.showKeys || values.showClicks != saved.showClicks
    }
    func save(in scope: String) -> String? {
        guard scope == "effects" else { return save() }
        applyEffects()
        guard UserDefaults.standard.synchronize() else { return "录屏效果写入磁盘失败，调整已保留" }
        objectWillChange.send()
        copyEffects(from: values, to: &saved)
        return nil
    }
    func discard(in scope: String) {
        guard scope == "effects" else { discard(); return }
        let current = Values.current
        copyEffects(from: current, to: &values)
        copyEffects(from: current, to: &saved)
    }
    func restoreDefaults(in scope: String) {
        guard scope == "effects" else { restoreDefaults(); return }
        copyEffects(from: Values(), to: &values)
    }
    private func applyEffects() {
        if values.showsCursor != saved.showsCursor { RecordingOptions.defaultShowsCursor = values.showsCursor }
        if values.cameraOn != saved.cameraOn { RecordingOptions.cameraEnabled = values.cameraOn }
        if values.cameraCorner != saved.cameraCorner { RecordingOptions.cameraCorner = values.cameraCorner }
        if values.cameraScale != saved.cameraScale { RecordingOptions.cameraScale = values.cameraScale }
        if values.showKeys != saved.showKeys { RecordingOptions.showKeys = values.showKeys }
        if values.showClicks != saved.showClicks { RecordingOptions.showClicks = values.showClicks }
    }
    private func copyEffects(from source: Values, to target: inout Values) {
        target.showsCursor = source.showsCursor
        target.cameraOn = source.cameraOn
        target.cameraCorner = source.cameraCorner
        target.cameraScale = source.cameraScale
        target.showKeys = source.showKeys
        target.showClicks = source.showClicks
    }
}

private struct RecordingSettingsContent: View {
    @Environment(\.settingsTargetField) private var targetField
    @ObservedObject var draft: RecordingSettingsDraft
    @ObservedObject private var recorder = ScreenRecorder.shared

    @Stored private var cameras: [(id: String, name: String)] = []

    private func refreshCameras() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video, position: .unspecified)
        cameras = session.devices.map { ($0.uniqueID, $0.localizedName) }
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
        .onAppear { refreshCameras() }
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
                        // v274：去掉 .defaultAction —— 录制中在设置页误按回车
                        // 会「停止并编辑」，把素材截断（U03-003）。
                    } else {
                        Button("录整屏") { recorder.startDisplayRecording() }
                            .controlSize(.small)
                        Button("录区域…") { recorder.startRegionRecording() }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 9)

                Text("开始、暂停与停止立即执行，使用已保存参数。下方参数仅写草稿；预览不采集屏幕或摄像头。")
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
                    Picker("", selection: $draft.values.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                        Text("15 fps").tag(15)
                    }
                    .labelsHidden().frame(width: 110)
                    Text("60fps 更顺，但文件约大一倍")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("声音") {
                    Picker("", selection: $draft.values.audio) {
                        ForEach(RecordingAudioSource.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden().frame(width: 130)
                    Text("系统声音与麦克风只能二选一（双音轨在多数播放器里只播第一条）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("鼠标指针") {
                    Toggle("", isOn: $draft.values.showsCursor)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
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
                    Toggle("", isOn: $draft.values.cameraOn)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Picker("", selection: $draft.values.cameraDevice) {
                        Text("默认摄像头").tag("")
                        ForEach(cameras, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden().frame(width: 160)
                    .disabled(!draft.values.cameraOn)
                }

                if draft.values.cameraOn {
                    SettingsDivider()
                    row("位置与大小") {
                        Picker("", selection: $draft.values.cameraCorner) {
                            ForEach(RecordingCorner.allCases) { corner in
                                Text(corner.title).tag(corner)
                            }
                        }
                        .labelsHidden().frame(width: 90)
                        Slider(value: $draft.values.cameraScale, in: 0.10...0.35)
                            .frame(width: 150)
                        Text("\(Int(draft.values.cameraScale * 100))% 画面宽")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsDivider()

                row("显示按键") {
                    Toggle("", isOn: $draft.values.showKeys)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Text("画面底部显示最近按下的键（需要辅助功能/输入监控权限）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("点击动画") {
                    Toggle("", isOn: $draft.values.showClicks)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Text("点击处扩散圆环（左键橙 / 右键蓝）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                SettingsSection("录屏效果预览", alwaysExpanded: true, summary: "模拟效果") {
                    RecordingAppearancePreview(values: draft.values)
                }
                .padding(.vertical, 10)
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

                ForEach(draft.values.excluded, id: \.self) { bundleID in
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
                    TextField("下载目录", text: $draft.savePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: 340)
                    Button("选择…") { chooseDirectory() }
                        .controlSize(.small)
                    Button("恢复默认目录") { draft.savePath = "" }
                        .controlSize(.small)
                    Button("在访达中打开") {
                        NSWorkspace.shared.open(RecordingOptions.saveDirectory)
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .background(targetField == "保存到" ? Theme.accent.opacity(0.08) : Color.clear)
                .id("保存到")

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
        .background(targetField == title ? Theme.accent.opacity(0.08) : Color.clear)
        .id(title)
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
        var list = draft.values.excluded
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            if !list.contains(id) { list.append(id) }
        }
        draft.values.excluded = list
    }

    private func removeExcluded(_ id: String) {
        draft.values.excluded.removeAll { $0 == id }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.savePath = url.path
    }
}
