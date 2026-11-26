import AppKit
import SwiftUI

// 设置中的固定素材；水印和录屏叠加仍由各自的正式绘制入口完成。
enum CaptureAppearanceSample {
    static let image = NSImage(size: NSSize(width: 960, height: 540), flipped: true) { rect in
        NSColor(calibratedRed: 0.15, green: 0.23, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(rect: rect).fill()
        let card = NSRect(x: 92, y: 65, width: 776, height: 410)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(118 + i * 24), y: 88, width: 12, height: 12)).fill()
        }
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                                                   .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1)]
        ("项目笔记" as NSString).draw(at: NSPoint(x: 132, y: 145), withAttributes: title)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20),
                                                  .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)]
        for (i, line) in ["截图与录屏外观", "整理素材，清晰展示操作步骤。", "这是一幅固定示意画面。"].enumerated() {
            (line as NSString).draw(at: NSPoint(x: 132, y: CGFloat(209 + i * 42)), withAttributes: body)
        }
        NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.83, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 132, y: 362, width: 140, height: 44), xRadius: 9, yRadius: 9).fill()
        ("分享笔记" as NSString).draw(at: NSPoint(x: 157, y: 370), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.white
        ])
        return true
    }

    static let camera = NSImage(size: NSSize(width: 180, height: 240), flipped: true) { rect in
        NSColor(calibratedRed: 0.35, green: 0.47, blue: 0.59, alpha: 1).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor(calibratedRed: 0.91, green: 0.76, blue: 0.64, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 58, y: 43, width: 64, height: 83)).fill()
        NSColor(calibratedRed: 0.21, green: 0.30, blue: 0.40, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 25, y: 132, width: 130, height: 150), xRadius: 54, yRadius: 54).fill()
        return true
    }
}

struct CaptureWatermarkPreview: View {
    let configuration: Watermark.Configuration
    /// 2026-11-26 修复：旧实现每次 body 求值都对 960×540 样例做整幅 Watermark.applied 合成，
    /// 设置页拖动不透明度/角度/字号滑杆时逐帧在主线程重绘（无节流），拖一下就掉帧。
    /// 现在结果缓存在本地状态里，并用 task(id:) + 100ms 防抖只渲染最后一帧。
    @Stored private var rendered: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("效果预览 · 固定示意画面")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Group {
                if let image = rendered {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .accessibilityLabel("水印预览，使用正式水印绘制和固定示意画面")
                } else {
                    Color.clear.frame(height: 270)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: configuration) {
            // 防抖：id 变化会取消上一个 task，连续拖动只在停下后渲染一次
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            rendered = Self.render(configuration)
        }
    }

    /// 用半尺寸底图合成：预览最大只显示 480pt，没必要按 960×540 全幅算水印
    private static func render(_ configuration: Watermark.Configuration) -> NSImage? {
        guard let source = CaptureAppearanceSample.image
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let base = downscaled(source, maxWidth: 640) ?? source
        let out = Watermark.applied(to: base, configuration: configuration)
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    private static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return image }
        let h = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: maxWidth, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
        return ctx.makeImage()
    }
}
