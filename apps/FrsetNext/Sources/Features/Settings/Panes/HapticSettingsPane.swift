import Combine
import SwiftUI

struct HapticSettingsPane: View {
    var body: some View {
        SettingsDraftEditor(id: "haptics", makeDraft: { HapticSettingsDraft() }) { draft in
            HapticSettingsContent(draft: draft)
        }
    }
}

final class HapticSettingsDraft: SettingsEditableDraft {
    @Published var configuration: HapticConfiguration
    private var saved: HapticConfiguration

    init() {
        let configuration = HapticConfiguration.load()
        self.configuration = configuration
        saved = configuration
    }

    var isDirty: Bool { configuration != saved }

    func save() -> String? {
        do { try configuration.persist() }
        catch { return "触觉设置保存失败：\(error.localizedDescription)" }
        saved = configuration
        objectWillChange.send()
        return nil
    }

    func discard() { configuration = saved }
    func restoreDefaults() { configuration = HapticConfiguration() }
}

private struct HapticSettingsContent: View {
    @ObservedObject var draft: HapticSettingsDraft
    @Stored private var previewEvent: HapticEvent = .copy

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            controls
            eventSection("布局与复制", events: [
                .gridMove, .gridResize, .layoutSaved, .copy
            ])
            eventSection("截图与录制", events: [
                .screenshot, .ocr, .recordingStarted, .recordingSaved,
                .downloadCompleted, .transferFailed
            ])
            eventSection("AI、搜索与设备", events: [
                .aiCompleted, .searchCompleted, .deviceConnected, .deviceDisconnected
            ])
            eventSection("提醒与媒体", events: [
                .operationFailed, .mediaPlayPause, .volumeBoundary
            ])
        }
    }

    private var controls: some View {
        SettingsSection("总开关与强度") {
            SettingsGroupBox {
                SettingsRow(title: "启用触觉反馈",
                            subtitle: "关闭后所有场景都不再触发") {
                    Toggle("启用触觉反馈", isOn: $draft.configuration.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: draft.configuration.enabled) { enabled in
                            if enabled { HapticFeedback.preview(draft.configuration.intensity) }
                        }
                }
                SettingsDivider()
                SettingsRow(title: "强度") {
                    Picker("全局强度", selection: $draft.configuration.intensity) {
                        ForEach(HapticIntensity.allCases, id: \.self) { intensity in
                            Text(intensity.title).tag(intensity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(!draft.configuration.enabled)
                    .onChange(of: draft.configuration.intensity) { intensity in
                        if draft.configuration.enabled { HapticFeedback.preview(intensity) }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "试听场景") {
                    HStack(spacing: 8) {
                        Picker("模拟场景", selection: $previewEvent) {
                            ForEach(HapticEvent.allCases, id: \.self) { event in
                                Text(event.setting.title).tag(event)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Button("试听") {
                            HapticFeedback.simulate(event: previewEvent,
                                                    intensity: draft.configuration.intensity)
                        }
                        .controlSize(.small)
                        .disabled(!draft.configuration.enabled
                                  || draft.configuration.intensity == .off
                                  || !draft.configuration.isEnabled(previewEvent))
                    }
                }
            }
        }
    }

    private func eventSection(_ title: String, events: [HapticEvent]) -> some View {
        SettingsSection(title, collapsible: true, expanded: true, summary: "\(events.count) 个场景") {
            SettingsGroupBox {
                ForEach(Array(events.enumerated()), id: \.element) { index, event in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: event.setting.title, subtitle: event.setting.detail) {
                        Toggle(event.setting.title, isOn: Binding(
                            get: { draft.configuration.isEnabled(event) },
                            set: { enabled in
                                if enabled { draft.configuration.disabledEvents.remove(event) }
                                else { draft.configuration.disabledEvents.insert(event) }
                                if draft.configuration.enabled, draft.configuration.intensity != .off {
                                    HapticFeedback.preview(draft.configuration.intensity)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

private extension HapticEvent {
    var setting: (title: String, detail: String) {
        switch self {
        case .gridMove: return ("网格吸附", "组件进入新的网格位置")
        case .gridResize: return ("组件尺寸切档", "组件切换到另一种网格尺寸")
        case .layoutSaved: return ("布局保存成功", "点击完成并成功保存布局")
        case .copy: return ("主动复制成功", "点击复制或使用复制快捷键")
        case .screenshot: return ("截图完成", "截图完成并可供使用")
        case .ocr: return ("文字识别完成", "OCR 识别结果准备完成")
        case .recordingStarted: return ("录屏开始", "录制正式开始")
        case .recordingSaved: return ("录屏保存完成", "录制文件成功保存")
        case .transferCompleted: return ("文件传输完成", "传输任务完成")
        case .downloadCompleted: return ("下载完成", "下载文件成功保存")
        case .transferFailed: return ("下载失败", "下载中断或失败")
        case .aiCompleted: return ("AI 回复完成", "模型生成结束并出现完整回复")
        case .searchCompleted: return ("搜索完成", "搜索结果准备完成")
        case .deviceConnected: return ("设备连接", "设备成功建立连接")
        case .deviceDisconnected: return ("设备断开", "已连接设备断开连接")
        case .operationFailed: return ("操作失败", "操作失败、权限不足或系统拒绝")
        case .mediaPlayPause: return ("播放与暂停", "主动切换媒体播放状态")
        case .volumeBoundary: return ("音量边界", "音量到达最小值或最大值")
        }
    }
}
