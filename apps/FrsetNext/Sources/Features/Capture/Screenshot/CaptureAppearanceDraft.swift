import SwiftUI

final class CaptureAppearanceDraft: SettingsEditableDraft {
    struct Values: Equatable {
        var soundEnabled = true
        var languages = ["zh-Hans", "en-US"]
        var action: CaptureDefaultAction = .save
        var showOCRWindow = true
        var autoDetect = true
        var delaySeconds = 5
        var selectedRatio = ""
        var customRatios: [CaptureAspectRatio] = []
        var fileNameTemplate = CaptureFileName.defaultTemplate
        var silent = false
        var notifySeconds = 4
        var textOnlyMosaic = false
        var watermark = Watermark.Configuration()

        static var current: Values {
            let manager = ScreenshotManager.shared
            return Values(soundEnabled: Preferences.shared.value(Preferences.Keys.captureSound, default: true),
                          languages: Preferences.shared.value(Preferences.Keys.ocrLanguages, default: ["zh-Hans", "en-US"]),
                          action: manager.defaultAction, showOCRWindow: manager.ocrShowResultWindow,
                          autoDetect: OCRService.autoDetectLanguages, delaySeconds: manager.delaySeconds,
                          selectedRatio: CaptureRatioStore.selectedID, customRatios: CaptureRatioStore.customItems,
                          fileNameTemplate: CaptureFileName.template, silent: CaptureOCRNotify.isSilent,
                          notifySeconds: CaptureOCRNotify.seconds, textOnlyMosaic: MosaicTextOnly.isEnabled,
                          watermark: .current)
        }
    }

    @Published var values: Values
    @Published var newRatioName = ""
    @Published var newRatioText = ""
    @Published private var saved: Values
    var isDirty: Bool { values != saved || !newRatioName.isEmpty || !newRatioText.isEmpty }

    init() {
        let current = Values.current
        values = current
        saved = current
    }

    func save() -> String? {
        if !newRatioText.isEmpty {
            guard addRatio() else { return "比例请输入两个正整数，例如 5:4。" }
        } else if !newRatioName.isEmpty {
            return "请为这组比例填写宽高，例如 5:4。"
        }
        let data: Data
        do { data = try JSONEncoder().encode(values.customRatios) }
        catch { return "保存固定比例失败：\(error.localizedDescription)" }
        Preferences.shared.set(Preferences.Keys.captureSound, values.soundEnabled)
        OCRService.setLanguages(values.languages)
        ScreenshotManager.shared.defaultAction = values.action
        ScreenshotManager.shared.ocrShowResultWindow = values.showOCRWindow
        OCRService.autoDetectLanguages = values.autoDetect
        ScreenshotManager.shared.delaySeconds = values.delaySeconds
        Preferences.shared.set(CaptureRatioStore.keyItems, data)
        CaptureRatioStore.selectedID = values.selectedRatio
        CaptureFileName.template = values.fileNameTemplate
        CaptureOCRNotify.isSilent = values.silent
        CaptureOCRNotify.seconds = values.notifySeconds
        MosaicTextOnly.isEnabled = values.textOnlyMosaic
        values.watermark.save()
        saved = values
        return nil
    }

    func discard() {
        values = saved
        newRatioName = ""
        newRatioText = ""
    }

    func restoreDefaults() {
        values = Values()
        newRatioName = ""
        newRatioText = ""
    }

    @discardableResult
    func addRatio() -> Bool {
        guard let (w, h) = CaptureAspectRatio.parse(newRatioText) else { return false }
        if let existing = (CaptureAspectRatio.builtins + values.customRatios).first(where: { $0.width == w && $0.height == h }) {
            values.selectedRatio = existing.id
        } else {
            let item = CaptureAspectRatio(name: newRatioName.isEmpty ? "\(w):\(h)" : newRatioName, width: w, height: h)
            values.customRatios.append(item)
            values.selectedRatio = item.id
        }
        newRatioName = ""
        newRatioText = ""
        return true
    }
}
