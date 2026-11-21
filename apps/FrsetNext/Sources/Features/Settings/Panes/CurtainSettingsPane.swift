import SwiftUI
import AppKit
import Combine

// MARK: - 图帘设置（对标 1Capture「拖放架 → 悬挂」）
//
// 「图帘」是 v263 起对用户露出的名字：截图后挂在屏幕顶边帘线上的一条临时暂存区。
// 之前叫「截图悬挂架」，代码里也顺手把 Shelf* 改成 Curtain*（偏好键仍是 shelf.*，
// 改了会丢老用户设置）。
//
// 这一页的第一行必须是**总开关**，而且默认是关的：
// 关着的时候不会创建任何窗口、不会在后台留任何东西——用户要的是
// 「可以开、可以关，不是常驻」。其余选项在关闭时置灰，但仍然可见，
// 让人先看清楚能调什么再决定开不开。

public struct CurtainSettingsPane: View {

    public init() {}

    public var body: some View {
        SettingsDraftEditor(id: "curtain", makeDraft: { CurtainSettingsDraft() }) { draft in
            CurtainSettingsContent(draft: draft)
        }
    }
}

final class CurtainSettingsDraft: SettingsEditableDraft {
    struct Values: Equatable {
        var enabled: Bool
        var style: CurtainRopeStyle
        var duration: Double
        var maxCards: Double
        var cardWidth: Double
        var railScales: Bool
        var attachOnCapture: Bool
        var revealOnHover: Bool

        static var current: Values {
            return Values(enabled: CurtainPref.enabled, style: CurtainPref.ropeStyle,
                duration: CurtainPref.displayDuration, maxCards: Double(CurtainPref.maxCards),
                cardWidth: Double(CurtainPref.cardWidth), railScales: CurtainPref.railScalesWithCards,
                attachOnCapture: CurtainPref.attachOnCapture, revealOnHover: CurtainPref.revealOnHover)
        }
    }

    @Published var values = Values.current
    private var saved = Values.current
    var isDirty: Bool { values != saved }

    func save() -> String? {
        let changed = isDirty
        let preferences = Preferences.shared
        if values.enabled != saved.enabled { preferences.set(Preferences.Keys.curtainEnabled, values.enabled) }
        if values.style != saved.style { preferences.set(Preferences.Keys.curtainRopeStyle, values.style.rawValue) }
        if values.duration != saved.duration { preferences.set(Preferences.Keys.curtainDisplayDuration, values.duration) }
        if values.maxCards != saved.maxCards { preferences.set(Preferences.Keys.curtainMaxCards, Int(values.maxCards)) }
        if values.cardWidth != saved.cardWidth { preferences.set(Preferences.Keys.curtainCardWidth, values.cardWidth) }
        if values.railScales != saved.railScales { preferences.set(Preferences.Keys.curtainRailScales, values.railScales) }
        if values.attachOnCapture != saved.attachOnCapture { preferences.set(Preferences.Keys.curtainAttachOnCapture, values.attachOnCapture) }
        if values.revealOnHover != saved.revealOnHover { preferences.set(Preferences.Keys.curtainRevealOnHover, values.revealOnHover) }
        guard UserDefaults.standard.synchronize() else { return "图帘设置写入磁盘失败，调整已保留" }
        // 所有字段写完才通知正式窗口与 Reveal，避免中途重排或唤出。
        if changed { NotificationCenter.default.post(name: .curtainPreferencesChanged, object: nil) }
        saved = values
        objectWillChange.send()
        return nil
    }

    func discard() { values = .current; saved = values }
    func restoreDefaults() {
        values = Values(enabled: false, style: .classic, duration: 12, maxCards: 8, cardWidth: 140,
                        railScales: true, attachOnCapture: true, revealOnHover: false)
    }
}

private struct CurtainSettingsContent: View {
    @Environment(\.settingsTargetField) private var targetField
    @ObservedObject var draft: CurtainSettingsDraft
    private var enabled: Bool { draft.values.enabled }
    private var style: CurtainRopeStyle {
        get { draft.values.style }
        nonmutating set { draft.values.style = newValue }
    }
    private var cardWidth: Double { draft.values.cardWidth }

    public var body: some View {
        VStack(spacing: 20) {
            masterSwitch

            previewSection
            VStack(spacing: 20) {
                ropeSection
                behaviorSection
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.62)

            footer
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 总开关

    private var masterSwitch: some View {
        // 外层 CaptureBlockPage 已有「图帘」页标题，这里不再重复一次
        SettingsSection("启用") {
            SettingsGroupBox {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("截图完成后，把图挂在屏幕顶边的帘线上暂存")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("开关与其他选项先在下方场景演示，保存后正式生效。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $draft.values.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)

                }
                .padding(.vertical, 8)


            }
        }
    }

    // MARK: 预览

    private var previewSection: some View {
        SettingsSection("预览", alwaysExpanded: true, summary: "模拟效果") {
            SettingsGroupBox {
                CurtainPreview(values: draft.values)
                    .frame(height: enabled ? 216 : 72)
                    .padding(.vertical, 4)
                Text("悬停展开正式卡片与按钮；场景内演示截图、唤出、收起和 ⌘ 缩放，按钮不写文件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: 样式

    private var ropeSection: some View {
        SettingsSection("帘线样式") {
            SettingsGroupBox {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(CurtainRopeStyle.allCases) { option in
                        VisualOptionCard(title: option.title,
                                         previewSize: CGSize(width: 96, height: 58),
                                         selected: style == option,
                                         action: {
                                             style = option
                                         }) {
                            CurtainRopeThumb(style: option)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)

                SettingsDivider()
                Text(style.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7)
            }
        }
    }

    // MARK: 行为

    private var behaviorSection: some View {
        SettingsSection("行为") {
            SettingsGroupBox {
                row("展示时长") {
                    Picker("", selection: $draft.values.duration) {
                        Text("5 秒").tag(5.0)
                        Text("8 秒").tag(8.0)
                        Text("12 秒").tag(12.0)
                        Text("30 秒").tag(30.0)
                        Text("永不收起").tag(0.0)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Text("到时只是收起，内容还在")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("最多挂") {
                    Picker("", selection: $draft.values.maxCards) {
                        ForEach((1...20).map { Double($0) }, id: \.self) { value in
                            Text("\(Int(value)) 张").tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Text("超出时从最旧的开始挤掉（不删文件）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("卡片宽度") {
                    Slider(value: $draft.values.cardWidth, in: 72...420, step: 4)
                        .frame(width: 200)
                    Text("\(Int(cardWidth)) pt")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Text("也可以在图帘上按住 ⌘ 左右拖（或 ⌘ + 滚轮）直接放大缩小；屏幕上放不下时会自动收窄。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)

                SettingsDivider()
                row("帘线缩放") {
                    Toggle("", isOn: $draft.values.railScales)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("开着时卡片变大、帘线/夹子/绳结一起变粗；关掉只放大图片")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("快捷键") {
                    Text(AppBootstrap.shortcutBinding(for: "curtainToggle").map {
                        ShortcutManager.display(keyCode: $0.keyCode, modifiers: $0.modifiers)
                    } ?? "未设置")
                    Button("前往快捷键设置") {
                        ServiceLocator.settings?.open(pane: "shortcuts#curtainToggle")
                    }
                    .buttonStyle(.link)
                    Text("随时展开 / 收起图帘")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("自动上架") {
                    Toggle("", isOn: $draft.values.attachOnCapture)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("关掉后只能用菜单「显示图帘」或快捷键手动唤出")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("悬停唤出") {
                    Toggle("", isOn: $draft.values.revealOnHover)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Text("鼠标移到屏幕顶边（菜单栏下沿 5pt）自动展开，移开 0.8 秒后收起")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()
                row("不进截图") {
                    Text("架子本身不会出现在任何截图或录屏里")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        Text("图帘是一次性暂存区：截图先挂这儿，需要时拖进聊天窗口或编辑器，不需要就等它自己收起。它不替代剪贴板历史和截图文件夹——原文件一直在原处。")
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ title: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12.5))
                .frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .background(targetField == title ? Theme.accent.opacity(0.08) : Color.clear)
        .id(title)
    }
}

// 直接嵌入正式画布，不创建图帘窗口或 Reveal。
private struct CurtainPreview: NSViewRepresentable {
    var values: CurtainSettingsDraft.Values
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> CurtainPreviewScene { CurtainPreviewScene() }
    func updateNSView(_ view: CurtainPreviewScene, context: Context) {
        view.update(values: values, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
    }
    static func dismantleNSView(_ view: CurtainPreviewScene, coordinator: ()) { view.stop() }
}

private struct CurtainRopeThumb: NSViewRepresentable {
    var style: CurtainRopeStyle
    func makeNSView(context: Context) -> CurtainRopeView { CurtainRopeView(frame: .zero) }
    func updateNSView(_ view: CurtainRopeView, context: Context) {
        view.style = style
        view.geometry = nil
    }
}
