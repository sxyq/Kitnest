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
            HStack(alignment: .top, spacing: 20) {
                usage.frame(width: 180)
                VStack(alignment: .leading, spacing: 20) {
                    eventSection("交互确认", description: "主动完成操作时反馈。", events: [
                        .gridMove, .gridResize, .layoutSaved, .copy
                    ])
                    eventSection("任务状态", description: "任务完成、录制及设备状态变化。", events: [
                        .screenshot, .ocr, .recordingStarted, .recordingSaved,
                        .transferCompleted, .downloadCompleted, .aiCompleted, .searchCompleted,
                        .deviceConnected, .deviceDisconnected
                    ])
                    eventSection("提醒与控制", description: "操作异常与主动媒体控制。", events: [
                        .operationFailed, .transferFailed, .mediaPlayPause, .volumeBoundary
                    ])
                }
                .frame(minWidth: 360, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var controls: some View {
        SettingsSection("全局强度与试听") {
            SettingsGroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Picker("全局强度", selection: $draft.configuration.intensity) {
                            ForEach(HapticIntensity.allCases, id: \.self) { intensity in
                                Text(intensity.title).tag(intensity)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                        Button("试听当前强度") {
                            HapticFeedback.preview(draft.configuration.intensity)
                        }
                        .disabled(draft.configuration.intensity == .off)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        Picker("试听场景", selection: $previewEvent) {
                            ForEach(HapticEvent.allCases, id: \.self) { event in
                                Text(event.setting.title).tag(event)
                            }
                        }
                        .frame(width: 260)
                        Button("试听所选场景") {
                            HapticFeedback.preview(draft.configuration.intensity)
                        }
                        .disabled(draft.configuration.intensity == .off || !draft.configuration.isEnabled(previewEvent))
                        Spacer(minLength: 0)
                    }
                    Text("系统模式：\(draft.configuration.intensity.systemMode)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var usage: some View {
        SettingsSection("使用说明") {
            VStack(alignment: .leading, spacing: 12) {
                Label("Force Touch 触控板", systemImage: "hand.tap")
                    .font(.system(size: 12, weight: .medium))
                Text("请将手指放在支持触觉反馈的触控板上试听；实际触感由系统和设备决定。")
                Text("轻、中、强分别对应对齐、通用、档位变化三种系统模式；系统不提供连续振幅调节。")
                Text("每项开关独立保存，强度统一跟随全局。关闭全局反馈后，场景选择仍会保留。")
                Text("保存后应用于实际操作；试听使用当前草稿。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func eventSection(_ title: String, description: String, events: [HapticEvent]) -> some View {
        SettingsSection(title) {
            VStack(alignment: .leading, spacing: 8) {
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                SettingsGroupBox {
                    ForEach(events, id: \.self) { event in
                        SettingsRow(title: event.setting.title, subtitle: event.setting.detail) {
                            Toggle(event.setting.title, isOn: Binding(
                                get: { draft.configuration.isEnabled(event) },
                                set: { enabled in
                                    if enabled { draft.configuration.disabledEvents.remove(event) }
                                    else { draft.configuration.disabledEvents.insert(event) }
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
        case .transferCompleted: return ("文件传输完成", "文件中转或设备传输任务完成")
        case .downloadCompleted: return ("下载完成", "下载文件成功保存")
        case .transferFailed: return ("下载或传输失败", "下载中断或文件传输失败")
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
