import AppKit
import CoreGraphics

// MARK: - 截图水印（v220，对齐 1Capture 的文字水印）
//
// 与「背景美化」不是一回事：
//   美化 = 让图好看（留白、圆角、阴影）；
//   水印 = 保护信息 / 标注来源（铺满画面的半透明文字）。
//
// 生效点在编辑器的 `composite()`——预览不叠加，复制/保存才盖上去，
// 这样编辑时不会被水印挡住看不清标注。

public enum Watermark {

    static let keyEnabled = "capture.watermark.enabled"
    static let keyText    = "capture.watermark.text"
    static let keyOpacity = "capture.watermark.opacity"
    static let keyAngle   = "capture.watermark.angle"
    static let keyTile    = "capture.watermark.tile"
    static let keyScale   = "capture.watermark.scale"

    public static var isEnabled: Bool {
        get { Preferences.shared.value(keyEnabled, default: false) }
        set { Preferences.shared.set(keyEnabled, newValue) }
    }

    public static var text: String {
        get { Preferences.shared.value(keyText, default: "Kitnest") }
        set { Preferences.shared.set(keyText, newValue) }
    }

    public static var opacity: Double {
        get { Preferences.shared.value(keyOpacity, default: 0.16) }
        set { Preferences.shared.set(keyOpacity, newValue) }
    }

    /// 倾斜角（度，负值 = 左下到右上）
    public static var angle: Double {
        get { Preferences.shared.value(keyAngle, default: -20) }
        set { Preferences.shared.set(keyAngle, newValue) }
    }

    /// true = 铺满画面；false = 单行落在右下角
    public static var tile: Bool {
        get { Preferences.shared.value(keyTile, default: true) }
        set { Preferences.shared.set(keyTile, newValue) }
    }

    /// 字号占图宽的比例（0.012–0.06）
    public static var scale: Double {
        get { Preferences.shared.value(keyScale, default: 0.028) }
        set { Preferences.shared.set(keyScale, newValue) }
    }

    /// 关闭、或文字为空时不叠加
    public static var active: Bool {
        isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 把水印烧进成图。无底图/未启用时原样返回。
    public static func applied(to image: CGImage) -> CGImage {
        guard active else { return image }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return image }
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 翻成左上原点，文字方向才正确
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let fontSize = max(10, CGFloat(w) * CGFloat(scale))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let a = CGFloat(min(0.6, max(0.02, opacity)))

        // 双色叠字：白字 + 深色描边偏移。浅色底靠深边、深色底靠白字，两种截图都读得出，
        // 又不像纯描边那样在缩略图上糊成一团。
        let dark: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.15, alpha: a * 0.9)
        ]
        let light: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(a)
        ]

        func stamp(at p: CGPoint) {
            (text as NSString).draw(at: CGPoint(x: p.x + 1, y: p.y + 1), withAttributes: dark)
            (text as NSString).draw(at: p, withAttributes: light)
        }

        if tile {
            let stepX = measured.width + fontSize * 6
            let stepY = measured.height + fontSize * 5
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            ctx.rotate(by: CGFloat(angle) * .pi / 180)
            let reach = hypot(CGFloat(w), CGFloat(h))
            var y = -reach
            while y < reach {
                var x = -reach
                while x < reach {
                    stamp(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
            }
            ctx.restoreGState()
        } else {
            let pad = fontSize * 1.2
            stamp(at: CGPoint(x: CGFloat(w) - measured.width - pad,
                              y: CGFloat(h) - measured.height - pad))
        }

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? image
    }
}
