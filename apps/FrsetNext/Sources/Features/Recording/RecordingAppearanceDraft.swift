import SwiftUI

final class RecordingAppearanceDraft: SettingsEditableDraft {
    struct Values: Equatable {
        var fps = 30
        var audio: RecordingAudioSource = .none
        var showsCursor = true
        var cameraOn = false
        var cameraDevice = ""
        var cameraCorner: RecordingCorner = .bottomRight
        var cameraScale = 0.18
        var showKeys = false
        var showClicks = false
        var excluded: [String] = []

        static var current: Values {
            Values(fps: RecordingOptions.defaultFPS, audio: RecordingOptions.defaultAudio,
                   showsCursor: RecordingOptions.defaultShowsCursor,
                   cameraOn: RecordingOptions.cameraEnabled, cameraDevice: RecordingOptions.cameraDeviceID,
                   cameraCorner: RecordingOptions.cameraCorner, cameraScale: RecordingOptions.cameraScale,
                   showKeys: RecordingOptions.showKeys, showClicks: RecordingOptions.showClicks,
                   excluded: RecordingOptions.excludedBundleIDs)
        }
    }

    @Published var values: Values
    @Published private var saved: Values
    var isDirty: Bool { values != saved }

    init() {
        let current = Values.current
        values = current
        saved = current
    }

    func save() -> String? {
        RecordingOptions.defaultFPS = values.fps
        RecordingOptions.defaultAudio = values.audio
        RecordingOptions.defaultShowsCursor = values.showsCursor
        RecordingOptions.cameraEnabled = values.cameraOn
        RecordingOptions.cameraDeviceID = values.cameraDevice
        RecordingOptions.cameraCorner = values.cameraCorner
        RecordingOptions.cameraScale = values.cameraScale
        RecordingOptions.showKeys = values.showKeys
        RecordingOptions.showClicks = values.showClicks
        RecordingOptions.excludedBundleIDs = values.excluded
        saved = values
        return nil
    }

    func discard() { values = saved }
    func restoreDefaults() { values = Values() }
}
