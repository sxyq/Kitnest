import AppKit
import CoreImage
import SwiftUI

struct RecordingAppearancePreview: View {
    let values: RecordingAppearanceDraft.Values
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private static let context = CIContext(options: [.cacheIntermediates: false])
    @Stored private var cachedFrame: NSImage?
    private var renderKey: String {
        "\(values.showsCursor)-\(values.cameraOn)-\(values.cameraCorner)-\(values.cameraScale)-\(values.showKeys)-\(values.showClicks)-\(reduceTransparency)"
    }

    private var frame: NSImage? {
        guard let base = CaptureAppearanceSample.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let camera = CaptureAppearanceSample.camera.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var options = RecordingOptions()
        options.showsCursor = values.showsCursor
        options.cameraEnabled = values.cameraOn
        options.cameraCorner = values.cameraCorner
        options.cameraScale = CGFloat(values.cameraScale)
        options.showKeys = values.showKeys
        options.showClicks = values.showClicks
        var image = CIImage(cgImage: base)
        if values.showsCursor,
           let cursor = NSCursor.arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            image = CIImage(cgImage: cursor)
                .transformed(by: CGAffineTransform(translationX: 202, y: 151))
                .composited(over: image)
        }
        let result = RecordingCompositor.composite(image: image, camera: CIImage(cgImage: camera),
            options: options, keys: [RecordedKey(text: "⌘", time: 0), RecordedKey(text: "C", time: 0)],
            clicks: [RecordedClick(point: CGPoint(x: 210, y: 383), time: -0.28, isRight: false),
                     RecordedClick(point: CGPoint(x: 700, y: 250), time: -0.28, isRight: true)],
            now: 0, pixelScale: 1, reduceTransparency: reduceTransparency)
        guard let cgImage = Self.context.createCGImage(result, from: CGRect(x: 0, y: 0, width: 960, height: 540)) else { return nil }
        return NSImage(cgImage: cgImage, size: CaptureAppearanceSample.image.size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("效果预览 · 固定示意画面")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let cachedFrame {
                Image(nsImage: cachedFrame)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 480)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .accessibilityLabel("录屏预览，使用正式叠加绘制和固定摄像头、按键、点击示意")
            }
            Text("摄像头、按键与点击均为固定示意；这里不启动录制或输入采集。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(minHeight: 300, alignment: .topLeading)
        .onAppear { cachedFrame = frame }
        .onChange(of: renderKey) { _ in cachedFrame = frame }
    }
}
