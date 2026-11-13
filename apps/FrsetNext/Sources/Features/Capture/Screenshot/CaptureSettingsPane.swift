import SwiftUI
import AppKit

// MARK: - 设置「截图」
//
// v262：原来这一页是独立的 `Form` 页签，和「钉图」「图帘」三页各占一个 tab；
// 三页合并成一个滚动页（`CaptureHubPane`）。这一页因此从 `Form` 改成
// `VStack + SettingsSection`——视觉上和钉图页、图帘页同一套。
//
// v271：用户要求「这些选项都进行拆分」并选择「拆回侧边栏独立项」，
// 五块改由 `CaptureBlockPage` 分别承载；本页只负责「截图」这一块，内部结构不变。

public struct CaptureSettingsPane: View {
    public init() {}

    public var body: some View {
        SettingsDraftEditor(id: "captureAppearance", makeDraft: { CaptureAppearanceDraft() }) { draft in
            CaptureSettingsContent(draft: draft)
        }
    }
}

private struct CaptureSettingsContent: View {
    @ObservedObject var draft: CaptureAppearanceDraft
    @ObservedObject private var manager = ScreenshotManager.shared
    @Stored private var savePath = Preferences.shared.value(Preferences.Keys.captureSavePath, default: "")

    private static let languageOptions: [(title: String, codes: [String])] = [
        ("简体中文 + 英文", ["zh-Hans", "en-US"]),
        ("仅简体中文", ["zh-Hans"]),
        ("仅英文", ["en-US"])
    ]

    private var languageIndex: Binding<Int> {
        Binding(get: { Self.languageOptions.firstIndex { $0.codes == draft.values.languages } ?? 0 },
                set: { draft.values.languages = Self.languageOptions[$0].codes })
    }

    var body: some View {
        VStack(spacing: 18) {
            saveSection
            behaviorSection
            // v264（B 档）：固定比例 / 文件命名 / 截完即用（静默识别、仅文本马赛克）
            CaptureRatioSettingsView(draft: draft)
            CaptureNamingSettingsView(draft: draft)
            CaptureExtraSettingsView(draft: draft)
            watermarkSection
            ocrSection
            permissionSection
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        // v274：「保存到」此前只写 @Stored（等价 @State，进程内临时值），
        // 而 ScreenshotManager 读的是 Preferences → 改完仍存到下载目录。
        // 输入 / 「选择…」/「恢复默认」三条路径统一在这里落盘。
        .onChange(of: savePath) { value in
            Preferences.shared.set(Preferences.Keys.captureSavePath, value)
        }
    }

    // MARK: 保存

    private var saveSection: some View {
        SettingsSection("保存") {
            SettingsGroupBox {
                HStack(spacing: 12) {
                    Text("保存到")
                        .font(.system(size: 12.5))
                        .frame(width: 92, alignment: .leading)
                    TextField(ScreenshotManager.shared.saveDirectory.path, text: $savePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: 340)
                    Button("选择…") { chooseDirectory() }
                        .controlSize(.small)
                    Button("恢复默认") {
                        savePath = ""
                        Preferences.shared.set(Preferences.Keys.captureSavePath, "")
                        ScreenshotManager.shared.reloadRecent()
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)

                SettingsDivider()

                HStack(spacing: 10) {
                    Text("留空则保存到 \(ScreenshotManager.shared.saveDirectory.path)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("在访达中打开") {
                        NSWorkspace.shared.open(ScreenshotManager.shared.saveDirectory)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: 行为

    private var behaviorSection: some View {
        SettingsSection("行为") {
            SettingsGroupBox {
                // v267（用户：「改为自适应，不用自己选择」）：
                // 这里原来是一个「自动识别窗口 / 手动框选」的下拉。既然覆盖层已经按
                // 动作判意图，让用户先选一次反而是负担，于是改成只读说明。
                row("截图方式") {
                    Text("自适应")
                        .font(.system(size: 12, weight: .medium))
                    Text("悬停窗口单击截整窗 · 拖拽截自定义范围 · 点空白处截全屏（⌘ 单击多选）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                SettingsDivider()

                row("提示音") {
                    Toggle("", isOn: $draft.values.soundEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Text("截图瞬间播放系统快门声")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("截图后") {
                    Picker("", selection: $draft.values.action) {
                        ForEach(CaptureDefaultAction.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                SettingsDivider()

                row("延时截图") {
                    Picker("", selection: $draft.values.delaySeconds) {
                        Text("3 秒").tag(3)
                        Text("5 秒").tag(5)
                        Text("10 秒").tag(10)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Text("倒计时 \(draft.values.delaySeconds) 秒，按 Esc 取消")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 水印

    private var watermarkSection: some View {
        SettingsSection("水印") {
            SettingsGroupBox {
                row("导出时加水印") {
                    Toggle("", isOn: $draft.values.watermark.enabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }

                if draft.values.watermark.enabled {
                    SettingsDivider()

                    row("水印文字") {
                        TextField("例如：内部资料", text: $draft.values.watermark.text)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Toggle("铺满画面", isOn: $draft.values.watermark.tile)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                    }

                    SettingsDivider()

                    row("不透明度") {
                        Slider(value: $draft.values.watermark.opacity, in: 0...0.5)
                            .frame(width: 180)
                        Text("\(Int(draft.values.watermark.opacity * 100))%")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }

                    SettingsDivider()

                    row("倾斜角") {
                        Slider(value: $draft.values.watermark.angle, in: -60...60)
                            .frame(width: 180)
                        Text("\(Int(draft.values.watermark.angle))°")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }

                    Text("只加在复制/保存的成品上，编辑时预览不叠加——不会被水印挡住看不清标注。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }

                CaptureWatermarkPreview(configuration: draft.values.watermark)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: 文字识别

    private var ocrSection: some View {
        SettingsSection("文字识别") {
            SettingsGroupBox {
                row("识别引擎") {
                    Text("Apple Vision（本机）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                SettingsDivider()

                row("识别语言") {
                    Picker("", selection: languageIndex) {
                        ForEach(0..<Self.languageOptions.count, id: \.self) { index in
                            Text(Self.languageOptions[index].title).tag(index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .disabled(draft.values.autoDetect)
                    Toggle("自动检测语言", isOn: $draft.values.autoDetect)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                }

                SettingsDivider()

                row("结果窗") {
                    Toggle("", isOn: $draft.values.showOCRWindow)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    Text("识别后弹出结果窗；关掉则只把文字放进剪贴板")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text("识别在本机完成（Apple Vision），不联网、不上传图片。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: 权限

    private var permissionSection: some View {
        SettingsSection("权限") {
            SettingsGroupBox {
                HStack(spacing: 10) {
                    Image(systemName: manager.hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(manager.hasPermission ? Color.green : Color.orange)
                        .font(.system(size: 12))
                    Text(manager.hasPermission ? "已获得屏幕录制权限" : "尚未获得屏幕录制权限")
                        .font(.system(size: 12.5))
                    Spacer(minLength: 8)
                    Button("检查 / 申请") {
                        Task { _ = await ScreenshotManager.shared.ensureScreenRecordingPermission() }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 9)
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
                // 92 是「导出时加水印」六个字在 12.5pt 下的实测宽度；
                // 74 会把它挤成两行，那一行就比别的行高出一截
                .frame(width: 92, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        savePath = url.path
        ScreenshotManager.shared.reloadRecent()
    }
}
