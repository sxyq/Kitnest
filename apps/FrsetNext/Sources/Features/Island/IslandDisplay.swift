import AppKit
import ColorSync
import CoreGraphics

/// 系统屏幕描述；镜像屏使用源屏幕的稳定身份与几何。
struct IslandDisplay: Identifiable {
    let screen: NSScreen
    let id: String
    let displayID: CGDirectDisplayID
    var name: String { screen.localizedName }
    var frame: CGRect { screen.frame }
    var isMain: Bool { displayID == Self.sourceID(CGMainDisplayID()) }
    var hasNotch: Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }
    var entrySize: CGSize { entrySize(hotspotWidth: 210) }
    func entrySize(hotspotWidth: Int) -> CGSize {
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: CGFloat(hotspotWidth), height: 28)
    }
    var entryFrame: CGRect { entryFrame(hotspot: .center, width: 210) }
    func entryFrame(hotspot: IslandHotspot, width: Int = 210) -> CGRect {
        let size = entrySize(hotspotWidth: width)
        let centerX: CGFloat
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            centerX = (left.maxX + right.minX) / 2
        } else {
            switch hotspot {
            case .left: centerX = frame.minX + size.width / 2 + 20
            case .center: centerX = frame.midX
            case .right: centerX = frame.maxX - size.width / 2 - 20
            }
        }
        return CGRect(x: centerX - size.width / 2, y: frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

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

    static func enabled(for configuration: IslandConfiguration) -> [Self] {
        guard configuration.enabled else { return [] }
        let displays = available
        switch configuration.displayScope {
        case .auto:
            return displays.sorted {
                if $0.hasNotch != $1.hasNotch { return $0.hasNotch }
                return $0.isMain && !$1.isMain
            }
        case .all: return displays
        case .main: return displays.filter(\.isMain)
        case .selected:
            let selected = displays.filter { configuration.selectedDisplayIDs.contains($0.id) }
            return selected.isEmpty && !configuration.selectedDisplayIDs.isEmpty ? displays.filter(\.isMain) : selected
        }
    }
}
