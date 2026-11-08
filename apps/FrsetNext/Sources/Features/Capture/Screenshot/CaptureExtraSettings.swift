import SwiftUI
import AppKit

// MARK: - 截图设置 · 补充段（v264）
//
// 原来没有、B 档补的：
//   ① 固定比例（可增删多组）—— 选一组之后框选就锁死这个比例；
//   ② 文件命名模板 —— 时间戳/序号/随机/尺寸，占位符替换，带实时预览；
//   ③ 静默识别 + 仅文本马赛克（v267 移除了同批加入的「拖拽角标」）。

struct CaptureRatioSettingsView: View {
    @Stored private var selectedID: String = CaptureRatioStore.selectedID
    @Stored private var custom: [CaptureAspectRatio] = CaptureRatioStore.customItems
    @Stored private var newName: String = ""
    @Stored private var newRatio: String = ""

    var body: some View {
        SettingsSection("固定比例") {
            SettingsGroupBox {
                SettingsRow(title: "框选锁定") {
                    Picker("", selection: $selectedID) {
                        Text("自由框选").tag("")
                        ForEach(CaptureAspectRatio.builtins) { item in
                            Text("\(item.name)（\(item.label)）").tag(item.id)
                        }
                        ForEach(custom) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .onChange(of: selectedID) { value in
                        CaptureRatioStore.selectedID = value
                    }
                    Text("选中后拖拽始终按该比例；⇧ 临时正方形")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if !custom.isEmpty {
                    SettingsDivider()
                    ForEach(custom) { item in
                        HStack(spacing: 10) {
                            Text(item.name).font(.system(size: 12))
                            Text(item.label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button {
                                CaptureRatioStore.remove(id: item.id)
                                custom = CaptureRatioStore.customItems
                                selectedID = CaptureRatioStore.selectedID
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("删除这组比例")
                        }
                        .padding(.vertical, 5)
                    }
                }

                SettingsDivider()

                HStack(spacing: 8) {
                    TextField("名称（可空）", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("例如 5:4", text: $newRatio)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Button("添加") { addRatio() }
                        .controlSize(.small)
                        .disabled(CaptureAspectRatio.parse(newRatio) == nil)
                    Text("比例会自动约分，并去重")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
            }
        }
    }

    private func addRatio() {
        guard let (w, h) = CaptureAspectRatio.parse(newRatio) else { return }
        if let item = CaptureRatioStore.add(name: newName, width: w, height: h) {
            newName = ""
            newRatio = ""
            custom = CaptureRatioStore.customItems
            selectedID = item.id
            CaptureRatioStore.selectedID = item.id
        }
    }
}

// MARK: - 文件命名

struct CaptureNamingSettingsView: View {
    @Stored private var template: String = CaptureFileName.template
    @Stored private var preview: String = CaptureFileName.preview(template: CaptureFileName.template)

    private let tokens = ["{yyyy}", "{MM}", "{dd}", "{HH}", "{mm}", "{ss}",
                          "{seq}", "{seq:4}", "{random:3}", "{w}", "{h}", "{mode}", "{app}"]

    var body: some View {
        SettingsSection("文件命名") {
            SettingsGroupBox {
                HStack(spacing: 12) {
                    Text("模板")
                        .font(.system(size: 12.5))
                        .frame(width: 92, alignment: .leading)
                    TextField(CaptureFileName.defaultTemplate, text: $template)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: 340)
                        .onChange(of: template) { value in
                            CaptureFileName.template = value
                            preview = CaptureFileName.preview(template: value)
                        }
                    Button("恢复默认") {
                        template = CaptureFileName.defaultTemplate
                        CaptureFileName.template = template
                        preview = CaptureFileName.preview(template: template)
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)

                SettingsDivider()

                HStack(spacing: 8) {
                    Text("预览")
                        .font(.system(size: 12.5))
                        .frame(width: 92, alignment: .leading)
                    Text(preview)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)

                SettingsDivider()

                // 占位符：点一下插到模板末尾（比让用户背下来现实）
                FlowTokens(tokens: tokens) { token in
                    template += token
                    CaptureFileName.template = template
                    preview = CaptureFileName.preview(template: template)
                }
                .padding(.vertical, 8)
            }
        }
    }
}

/// 简易流式布局（占位符 chip 换行）
private struct FlowTokens: View {
    let tokens: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("可用占位符（点一下追加）")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(tokens, id: \.self) { token in
                    Button(token) { onTap(token) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.system(size: 10.5, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - 静默识别 / 仅文本马赛克
//
// v267：原本这里还有「拖拽角标」（截图后右下角缩略图）开关，整套功能已按用户要求
// 删除，设置里不再留一个能把它开回来的入口。

struct CaptureExtraSettingsView: View {
    @Stored private var silent = CaptureOCRNotify.isSilent
    @Stored private var notifySeconds = CaptureOCRNotify.seconds
    @Stored private var textOnlyMosaic = MosaicTextOnly.isEnabled

    var body: some View {
        SettingsSection("截完即用") {
            SettingsGroupBox {
                ExtraSettingRow(title: "静默识别") {
                    Toggle("", isOn: $silent)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: silent) { value in
                            CaptureOCRNotify.isSilent = value
                        }
                    Stepper(value: $notifySeconds, in: 2...12) {
                        Text("\(notifySeconds) 秒")
                            .font(.system(size: 11.5).monospacedDigit())
                    }
                    .disabled(!silent)
                    .onChange(of: notifySeconds) { value in
                        CaptureOCRNotify.seconds = value
                    }
                    Text("只提示不弹窗，文字自动进剪贴板")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                ExtraSettingRow(title: "仅文本马赛克") {
                    Toggle("", isOn: $textOnlyMosaic)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: textOnlyMosaic) { value in
                            MosaicTextOnly.isEnabled = value
                        }
                    Text("刷子只圈范围，实际只糊文本行（Vision 本机识别）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 小工具

/// 统一的行：92pt 标题 + 内容 + 自动 Spacer（与 CaptureSettingsPane 的 row 视觉一致）
private struct ExtraSettingRow<Content: View>: View {
    let title: String
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
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
}
