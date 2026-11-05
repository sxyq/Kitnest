import SwiftUI
import AppKit

// MARK: - 设置「截图」页签

/// 截图设置：保存路径 / 提示音 / OCR 语言 / 截图后默认动作
public struct CaptureSettingsPane: View {
    @ObservedObject private var manager = ScreenshotManager.shared
    @Stored private var savePath: String
    @Stored private var soundEnabled: Bool
    @Stored private var languageIndex: Int
    @Stored private var action: CaptureDefaultAction
    @Stored private var showOCRWindow: Bool
    /// Vision 自动检测语言（开启后忽略下方语言列表）
    @Stored private var autoDetect: Bool
    /// v130（SnowShot 对齐）④：延时截图秒数（3 / 5 / 10）
    @Stored private var delaySeconds: Int
    /// v220：水印（对齐 1Capture 的文字水印）
    @Stored private var wmEnabled: Bool
    @Stored private var wmText: String
    @Stored private var wmTile: Bool
    @Stored private var wmOpacity: Double
    @Stored private var wmAngle: Double
    /// v233：钉图外观（对齐 1Capture 的 DecorateModel）
    @Stored private var pinBorderWidth: Double
    @Stored private var pinBorderColor: String
    @Stored private var pinCorner: Double
    @Stored private var pinShadow: Bool
    @Stored private var pinMagnet: Bool

    private static let languageOptions: [(title: String, codes: [String])] = [
        ("简体中文 + 英文", ["zh-Hans", "en-US"]),
        ("仅简体中文", ["zh-Hans"]),
        ("仅英文", ["en-US"])
    ]

    public init() {
        let prefs = Preferences.shared
        _savePath = Stored(wrappedValue: prefs.value(Preferences.Keys.captureSavePath, default: ""))
        _soundEnabled = Stored(wrappedValue: prefs.value(Preferences.Keys.captureSound, default: true))
        let langs: [String] = prefs.value(Preferences.Keys.ocrLanguages, default: ["zh-Hans", "en-US"])
        _languageIndex = Stored(wrappedValue: Self.languageOptions.firstIndex { $0.codes == langs } ?? 0)
        _action = Stored(wrappedValue: ScreenshotManager.shared.defaultAction)
        _showOCRWindow = Stored(wrappedValue: ScreenshotManager.shared.ocrShowResultWindow)
        _autoDetect = Stored(wrappedValue: OCRService.autoDetectLanguages)
        _delaySeconds = Stored(wrappedValue: ScreenshotManager.shared.delaySeconds)
        _wmEnabled = Stored(wrappedValue: Watermark.isEnabled)
        _wmText = Stored(wrappedValue: Watermark.text)
        _wmTile = Stored(wrappedValue: Watermark.tile)
        _wmOpacity = Stored(wrappedValue: Watermark.opacity)
        _wmAngle = Stored(wrappedValue: Watermark.angle)
        _pinBorderWidth = Stored(wrappedValue: PinStyle.borderWidth)
        _pinBorderColor = Stored(wrappedValue: PinStyle.borderColorToken)
        _pinCorner = Stored(wrappedValue: PinStyle.cornerRadius)
        _pinShadow = Stored(wrappedValue: PinStyle.shadow)
        _pinMagnet = Stored(wrappedValue: PinStyle.magnet)
    }

    public var body: some View {
        Form {
            Section("保存") {
                HStack {
                    TextField("默认：\(ScreenshotManager.shared.saveDirectory.path)", text: $savePath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseDirectory() }
                    Button("恢复默认") {
                        savePath = ""
                        Preferences.shared.set(Preferences.Keys.captureSavePath, "")
                        ScreenshotManager.shared.reloadRecent()
                    }
                }
                Text("留空则保存到 \(ScreenshotManager.shared.saveDirectory.path)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("在访达中打开截图目录") {
                    NSWorkspace.shared.open(ScreenshotManager.shared.saveDirectory)
                }
            }

            Section("行为") {
                Toggle("截图后播放提示音", isOn: $soundEnabled)
                    .onChange(of: soundEnabled) { newValue in
                        Preferences.shared.set(Preferences.Keys.captureSound, newValue)
                    }
                Picker("截图后默认执行", selection: $action) {
                    ForEach(CaptureDefaultAction.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .onChange(of: action) { newValue in
                    ScreenshotManager.shared.defaultAction = newValue
                }
                // v130（SnowShot 对齐）④：延时截图秒数（倒计时 5→4→3→2→1，Esc 可取消）
                Picker("延时截图秒数", selection: $delaySeconds) {
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                }
                .onChange(of: delaySeconds) { newValue in
                    ScreenshotManager.shared.delaySeconds = newValue
                }
            }

            Section("水印") {
                Toggle("导出时加水印", isOn: $wmEnabled)
                    .onChange(of: wmEnabled) { newValue in Watermark.isEnabled = newValue }
                if wmEnabled {
                    TextField("水印文字", text: $wmText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: wmText) { newValue in Watermark.text = newValue }
                    Toggle("铺满画面（关闭则只放右下角）", isOn: $wmTile)
                        .onChange(of: wmTile) { newValue in Watermark.tile = newValue }
                    HStack {
                        Text("不透明度")
                        Slider(value: $wmOpacity, in: 0.03...0.5)
                        Text("\(Int(wmOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .onChange(of: wmOpacity) { newValue in Watermark.opacity = newValue }
                    HStack {
                        Text("倾斜角")
                        Slider(value: $wmAngle, in: -60...60)
                        Text("\(Int(wmAngle))°")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .onChange(of: wmAngle) { newValue in Watermark.angle = newValue }
                    Text("只加在复制/保存的成品上，编辑时预览不叠加——不会被水印挡住看不清标注。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("钉图") {
                HStack {
                    Text("描边")
                    Slider(value: $pinBorderWidth, in: 0...6, step: 0.5)
                    Text(pinBorderWidth == 0 ? "无" : String(format: "%.1f pt", pinBorderWidth))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .onChange(of: pinBorderWidth) { newValue in PinStyle.borderWidth = newValue }
                Picker("描边颜色", selection: $pinBorderColor) {
                    Text("自动（按底色反色）").tag("auto")
                    Text("白色").tag("white")
                    Text("黑色").tag("black")
                    Text("强调色").tag("accent")
                }
                .onChange(of: pinBorderColor) { newValue in PinStyle.borderColorToken = newValue }
                HStack {
                    Text("圆角")
                    Slider(value: $pinCorner, in: 0...24, step: 1)
                    Text("\(Int(pinCorner))")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .onChange(of: pinCorner) { newValue in PinStyle.cornerRadius = newValue }
                Toggle("窗口阴影", isOn: $pinShadow)
                    .onChange(of: pinShadow) { newValue in PinStyle.shadow = newValue }
                Toggle("拖动时吸附到屏幕边缘与其它钉图", isOn: $pinMagnet)
                    .onChange(of: pinMagnet) { newValue in PinStyle.magnet = newValue }
                Text("钉住后悬停图片，底边会浮出控制条（标注 / 拷贝 / 更多 / 缩放），左上角是关闭。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("文字识别") {
                Text("识别引擎：Apple Vision（本机）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("识别语言", selection: $languageIndex) {
                    ForEach(0..<Self.languageOptions.count, id: \.self) { index in
                        Text(Self.languageOptions[index].title).tag(index)
                    }
                }
                .disabled(autoDetect)
                .onChange(of: languageIndex) { newValue in
                    OCRService.setLanguages(Self.languageOptions[newValue].codes)
                }
                Toggle("自动检测语言", isOn: $autoDetect)
                    .onChange(of: autoDetect) { newValue in
                        OCRService.autoDetectLanguages = newValue
                    }
                Toggle("识别后弹出结果窗", isOn: $showOCRWindow)
                    .onChange(of: showOCRWindow) { newValue in
                        ScreenshotManager.shared.ocrShowResultWindow = newValue
                    }
                Text("识别在本机完成（Apple Vision），不联网、不上传图片。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("权限") {
                HStack {
                    Text(manager.hasPermission ? "已获得屏幕录制权限" : "尚未获得屏幕录制权限")
                    Spacer()
                    Button("检查 / 申请") {
                        Task { _ = await ScreenshotManager.shared.ensureScreenRecordingPermission() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
        .onChange(of: savePath) { newValue in
            Preferences.shared.set(Preferences.Keys.captureSavePath, newValue)
            ScreenshotManager.shared.reloadRecent()
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        savePath = url.path
    }
}
