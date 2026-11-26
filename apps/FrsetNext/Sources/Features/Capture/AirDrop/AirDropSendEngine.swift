import AppKit

public extension Notification.Name {
    static let frsetAirDropFiles = Notification.Name("frset.airDropFiles")
}

public enum AirDropSendEngine {
    private static var _service: NSSharingService?
    private static var _stamp: TimeInterval = 0
    private static let lock = NSLock()
    private static let feedbackDelegate = FeedbackDelegate()

    private final class FeedbackDelegate: NSObject, NSSharingServiceDelegate {
        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            HapticService.shared.perform(.airDropCompleted)
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
            if (error as NSError).code != NSUserCancelledError {
                HapticService.shared.perform(.transferFailed)
            }
        }
    }

    private static var cachedService: NSSharingService? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if let service = _service, now - _stamp < 300 { return service }
        let service = NSSharingService(named: .sendViaAirDrop)
        _service = service
        _stamp = now
        return service
    }

    private static func freshService() -> NSSharingService? {
        lock.lock()
        defer { lock.unlock() }
        guard let service = _service, Date().timeIntervalSince1970 - _stamp < 300 else { return nil }
        return service
    }

    public static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            _ = cachedService
            Log.info("AirDrop", "隔空投送已预热")
        }
    }

    @discardableResult
    public static func send(urls: [URL], relativeTo view: NSView? = nil) -> Bool {
        guard !urls.isEmpty else {
            Toast.show("没有可发送的文件", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        if let service = freshService() {
            beginSend(service, urls: urls)
            return true
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let service = cachedService
            DispatchQueue.main.async {
                guard let service else {
                    HapticService.shared.perform(.transferFailed)
                    Toast.show("本机隔空投送不可用（检查系统设置）", icon: "exclamationmark.triangle", isWarning: true)
                    return
                }
                beginSend(service, urls: urls)
            }
        }
        return true
    }

    private static func beginSend(_ service: NSSharingService, urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            service.delegate = feedbackDelegate
            service.perform(withItems: urls)
            Log.info("AirDrop", "隔空投送发起：\(urls.count) 个文件")
        }
    }
}
