import AppKit

// 从中转模块迁出既有系统分享入口；截图与剪贴板继续共用，不提供中转存储。
public extension Notification.Name {
    static let frsetAirDropFiles = Notification.Name("frset.airDropFiles")
}

public enum AirDropSendEngine {
    private static var _service: NSSharingService?
    private static var _stamp: TimeInterval = 0
    private static let lock = NSLock()

    private static var cachedService: NSSharingService? {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if let service = _service, now - _stamp < 300 { return service }
        let service = NSSharingService(named: .sendViaAirDrop)
        _service = service
        _stamp = now
        return service
    }

    @discardableResult
    public static func send(urls: [URL], relativeTo view: NSView? = nil) -> Bool {
        guard !urls.isEmpty else {
            Toast.show("没有可发送的文件", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        guard let service = cachedService else {
            Toast.show("本机隔空投送不可用（检查系统设置）", icon: "exclamationmark.triangle", isWarning: true)
            return false
        }
        // 原生分享要求激活应用；异步显示保留按钮的按下反馈。
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            service.perform(withItems: urls)
            Log.info("Share", "隔空投送发起：\(urls.count) 个文件")
        }
        return true
    }
}
