struct RecordingSettingsValues: Equatable {
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

    static var current: Self {
        Self(fps: RecordingOptions.defaultFPS, audio: RecordingOptions.defaultAudio,
             showsCursor: RecordingOptions.defaultShowsCursor,
             cameraOn: RecordingOptions.cameraEnabled, cameraDevice: RecordingOptions.cameraDeviceID,
             cameraCorner: RecordingOptions.cameraCorner, cameraScale: RecordingOptions.cameraScale,
             showKeys: RecordingOptions.showKeys, showClicks: RecordingOptions.showClicks,
             excluded: RecordingOptions.excludedBundleIDs)
    }
}
