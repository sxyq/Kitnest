import AppKit
import CoreGraphics
import CoreText

// MARK: - 录屏叠加层绘制（按键 / 点击）
//
// 每帧都要出图，所以这里只画**很小的画布**（按键条 ~720×110，点击环 160×160），
// 再由录制器按位置合成到整帧上。不要按视频分辨率建位图——
// 4K/60fps 下一帧全画布就是 33MB，光分配就能把帧率打下来。

public enum RecordingCompositor {

    /// 按键条：最多显示 4 个键帽，右对齐贴着画面底部居中
    /// - Parameter pixelScale: 视频像素 / 点（Retina 录制时 2）
    public static func keyOverlay(keys: [RecordedKey], now: CFTimeInterval,
                                  pixelScale: CGFloat) -> CGImage? {
        let visible = keys.suffix(4)
        guard !visible.isEmpty else { return nil }
        let pad: CGFloat = 10 * pixelScale
        let capH: CGFloat = 46 * pixelScale
        let gap: CGFloat = 8 * pixelScale
        let font = NSFont.systemFont(ofSize: 20 * pixelScale, weight: .semibold)

        var widths: [CGFloat] = []
        for key in visible {
            let w = (key.text as NSString).size(withAttributes: [.font: font]).width
            widths.append(max(w + 26 * pixelScale, capH))
        }
        let totalW = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)) + pad * 2
        let height = capH + pad * 2
        guard totalW > 1,
              let ctx = CGContext(data: nil, width: Int(totalW.rounded()), height: Int(height.rounded()),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: totalW, height: height))
        let bg = NSColor(calibratedWhite: 0.08, alpha: 0.82).cgColor
        let stroke = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor

        var x = pad
        for (index, key) in visible.enumerated() {
            let w = widths[index]
            let rect = CGRect(x: x, y: pad, width: w, height: capH)
            let path = CGPath(roundedRect: rect, cornerWidth: 9 * pixelScale,
                              cornerHeight: 9 * pixelScale, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(bg)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(1 * pixelScale)
            ctx.strokePath()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: key.text,
                                                                          attributes: attrs))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2,
                                       y: rect.midY - bounds.height / 2 - bounds.origin.y * 0)
            CTLineDraw(line, ctx)
            x += w + gap
        }
        return ctx.makeImage()
    }

    /// 点击环：160×160 画布，progress 0→1 时半径扩散、透明度衰减
    public static func clickOverlay(progress: CGFloat, isRight: Bool,
                                    pixelScale: CGFloat) -> CGImage? {
        let side = 160 * pixelScale
        guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let center = CGPoint(x: side / 2, y: side / 2)
        let clamped = max(0, min(1, progress))
        let color = isRight
            ? CGColor(red: 0.28, green: 0.62, blue: 1, alpha: 1)
            : CGColor(red: 1, green: 0.42, blue: 0.28, alpha: 1)

        // 中心点
        ctx.setFillColor(color.copy(alpha: 0.95) ?? color)
        ctx.fillEllipse(in: CGRect(x: center.x - 7 * pixelScale, y: center.y - 7 * pixelScale,
                                   width: 14 * pixelScale, height: 14 * pixelScale))
        // 扩散环（两圈：主环 + 稍慢的尾环）
        for (offset, alpha) in [(CGFloat(0), CGFloat(0.9)), (CGFloat(0.14), CGFloat(0.35))] {
            let t = max(0, clamped - offset) / (1 - offset)
            guard t > 0 else { continue }
            let radius = (10 + 58 * t) * pixelScale
            ctx.setStrokeColor(color.copy(alpha: alpha * (1 - t)) ?? color)
            ctx.setLineWidth((5 - 3 * t) * pixelScale)
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
        }
        return ctx.makeImage()
    }

    /// 摄像头画中画：按角与比例算矩形（**视频像素坐标，左上原点**）
    public static func cameraRect(videoSize: CGSize, corner: RecordingCorner,
                                  widthFraction: CGFloat) -> CGRect {
        let margin = videoSize.width * 0.02
        // 4:3 竖版画中画（人脸比 16:9 占的地方更合适）
        let w = videoSize.width * max(0.10, min(0.35, widthFraction))
        let h = w * 4 / 3
        switch corner {
        case .bottomRight: return CGRect(x: videoSize.width - w - margin, y: videoSize.height - h - margin, width: w, height: h)
        case .bottomLeft:  return CGRect(x: margin, y: videoSize.height - h - margin, width: w, height: h)
        case .topRight:    return CGRect(x: videoSize.width - w - margin, y: margin, width: w, height: h)
        case .topLeft:     return CGRect(x: margin, y: margin, width: w, height: h)
        }
    }
}
