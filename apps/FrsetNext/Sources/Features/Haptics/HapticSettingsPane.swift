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

    /// 只有保存才写盘并替换业务侧快照；未保存时业务仍然使用已保存配置。
    func save() -> String? {
        if let error = HapticService.shared.apply(configuration) {
            return "触觉设置保存失败：\(error.localizedDescription)"
        }
        saved = configuration
        objectWillChange.send()
        return nil
    }

    func discard() { configuration = saved }
    func restoreDefaults() { configuration = HapticConfiguration() }
}

private struct HapticSettingsContent: View {
    @ObservedObject var draft: HapticSettingsDraft
    @ObservedObject var service = HapticService.shared
    @Stored private var previewEvent: HapticEvent = .copy

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            controls
            ForEach(HapticEvent.settingGroups, id: \.title) { group in
                eventSection(group.title, events: group.events)
            }
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
                            if enabled {
                                HapticService.shared.preview(event: .copy,
                                                             intensity: draft.configuration.intensity)
                            }
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
                        if draft.configuration.enabled {
                            HapticService.shared.preview(event: .copy, intensity: intensity)
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(title: "试听场景", subtitle: previewSubtitle) {
                    HStack(spacing: 8) {
                        Picker("模拟场景", selection: $previewEvent) {
                            ForEach(HapticEvent.allCases, id: \.self) { event in
                                Text(event.settingTitle).tag(event)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        Button("试听") { playPreview() }
                            .controlSize(.small)
                            .disabled(!draft.configuration.enabled
                                      || draft.configuration.intensity == .off
                                      || !draft.configuration.isEnabled(previewEvent)
                                      || service.availability == .unavailable)
                            .help("试听只演示这台设备能给出的节奏与强度；"
                                  + "场景是否生效取决于真实业务事件，两者不是一回事。")
                    }
                }
            }
        }
    }

    /// 设备不支持时如实说明；支持时不占版面（保持原布局）。
    private var previewSubtitle: String? {
        switch service.availability {
        case .ready, .unknown: return nil
        case .publicOnly(let reason):
            return "\(reason.text)：试听只能请求系统接口，手指贴着触控板时才有感"
        case .unavailable:
            return "没有可用的触觉设备"
        }
    }

    private func playPreview() {
        let intensity = draft.configuration.intensity
        HapticService.shared.preview(event: previewEvent, intensity: intensity)
        // 把「试听 ≠ 已接线」和当前设备边界说清楚，避免把演示当成场景已生效。
        Toast.show("已按「\(previewEvent.settingTitle)」的节奏试听一次 · \(service.deviceSummary)",
                   icon: "hand.tap")
    }

    private func eventSection(_ title: String, events: [HapticEvent]) -> some View {
        SettingsSection(title, collapsible: true, expanded: true, summary: "\(events.count) 个场景") {
            SettingsGroupBox {
                ForEach(Array(events.enumerated()), id: \.element) { index, event in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(title: event.settingTitle, subtitle: event.settingDetail) {
                        // 2026-11-26 修复（F-misc-1#7）：get 原来用复合 isEnabled
                        // （全局开关 && 强度≠off && 未禁用），全局一关所有场景开关都显示「关」、
                        // 点了立刻回弹，用户既看不到也无法编辑「单场景禁用集」。
                        // 现在 get 只表达该场景自身偏好，全局/强度门控改用 .disabled 表达。
                        Toggle(event.settingTitle, isOn: Binding(
                            get: { !draft.configuration.disabledEvents.contains(event) },
                            set: { enabled in
                                if enabled { draft.configuration.disabledEvents.remove(event) }
                                else { draft.configuration.disabledEvents.insert(event) }
                                if draft.configuration.enabled, draft.configuration.intensity != .off {
                                    HapticService.shared.preview(event: event,
                                                                 intensity: draft.configuration.intensity)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!draft.configuration.enabled || draft.configuration.intensity == .off)
                    }
                }
            }
        }
    }
}
