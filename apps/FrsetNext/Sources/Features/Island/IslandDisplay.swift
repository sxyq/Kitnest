import AppKit
import CoreGraphics

/// 屏幕拓扑：给悬浮球、监测窗口挑屏用；镜像屏归到源屏的稳定身份。
struct IslandDisplay: Identifiable {
    let screen: NSScreen
    let id: String
    let displayID: CGDirectDisplayID
    var name: String { screen.localizedName }
    var frame: CGRect { screen.frame }
    var isMain: Bool { displayID == Self.sourceID(CGMainDisplayID()) }

    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let source = Self.sourceID(number.uint32Value)
        displayID = source
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(source)?.takeRetainedValue() else { return nil }
        id = CFUUIDCreateString(nil, uuid) as String
        self.screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == source
        } ?? screen
    }

    private static func sourceID(_ id: CGDirectDisplayID) -> CGDirectDisplayID {
        let source = CGDisplayMirrorsDisplay(id)
        return source == kCGNullDirectDisplay ? id : source
    }

    static var available: [Self] {
        var seen = Set<String>()
        return NSScreen.screens.compactMap { Self(screen: $0) }.filter { seen.insert($0.id).inserted }
    }
}
