import AppKit
import CoreGraphics
import SwiftUI

// MARK: - 截图美化（eSearch 对齐，2026-10-19 用户需求）
//
// 背景（纯色/渐变 + 内边距）/ 圆角 / 投影，纯 CoreGraphics 零依赖。
// 产物可 复制 / 保存 / 贴图，并可作为「框选后默认动作」。

/// 美化参数
public struct BeautifyOptions: Equatable {
    /// 背景样式
    public enum Background: String, CaseIterable {
        case none        // 无背景（只做圆角/阴影）
        case solid       // 纯色
        case gradient    // 线性渐变
    }
    public var background: Background = .gradient
    /// 背景色（渐变时为起止色）
    public var colorA = NSColor(red: 0.98, green: 0.72, blue: 0.32, alpha: 1)
    public var colorB = NSColor(red: 0.99, green: 0.45, blue: 0.42, alpha: 1)
    /// 截图与背景边缘的距离（pt）
    public var padding: CGFloat = 32
    /// 截图圆角（pt）
    public var cornerRadius: CGFloat = 14
    /// 投影强度（0 = 无阴影；模糊半径与不透明度随该值缩放）
    public var shadow: CGFloat = 18

    public init() {}
}

public enum BeautifyRenderer {

    /// 渲染美化图。画布 = 截图 + 2×padding + 2×投影余量，背景填充 + 圆角裁剪 + 投影。
    public static func render(image: CGImage, options: BeautifyOptions) -> CGImage? {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return nil }
        // Retina 归一：宽 ≥1400px 的截图按 2x 素材处理（padding/圆角/阴影按 pt 视觉一致）
        let scale: CGFloat = iw >= 1400 ? 2 : 1
        let pt = { (v: CGFloat) in v * scale }   // pt → px

        let padding = pt(options.padding)
        let shadowMargin = options.shadow > 0 ? pt(options.shadow) * 2 : 8
        let margin = padding + shadowMargin
        let canvasW = Int(iw + margin * 2)
        let canvasH = Int(ih + margin * 2)
        guard canvasW > 0, canvasH > 0,
              let ctx = CGContext(data: nil, width: canvasW, height: canvasH,
                                  bitsPerComponent: 8, bytesPerRow: canvasW * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // 背景
        let bgRect = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        switch options.background {
        case .none:
            ctx.clear(bgRect)
        case .solid:
            ctx.setFillColor(options.colorA.cgColor)
            ctx.fill(bgRect)
        case .gradient:
            let colors = [options.colorA.cgColor, options.colorB.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: CGFloat(canvasW), y: CGFloat(canvasH)),
                                       options: [])
            }
        }

        // 截图绘制区（圆角矩形）
        let drawRect = CGRect(x: margin, y: margin, width: iw, height: ih)
        let radius = pt(options.cornerRadius)

        ctx.saveGState()
        // 投影（先画底形带阴影，再裁剪画图）
        if options.shadow > 0 {
            ctx.setShadow(offset: CGSize(width: 0, height: -pt(options.shadow) / 3),
                          blur: pt(options.shadow),
                          color: NSColor(white: 0, alpha: 0.38).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            let shadowPath = CGPath(roundedRect: drawRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(shadowPath)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        // 圆角裁剪 + 画图
        ctx.addPath(CGPath(roundedRect: drawRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()

        return ctx.makeImage()
    }
}

// MARK: - 美化窗口（预览 + 控件）

public final class BeautifyController: NSObject, NSWindowDelegate {
    public static let shared = BeautifyController()

    private var window: BeautifyWindow?
    private var sourceImage: CGImage?

    private override init() { super.init() }

    /// 非隔离入口（截图动作链/热键/命令面板任意上下文可调），内部跳主线程
    public func show(image: CGImage) {
        if Thread.isMainThread {
            showOnMain(image: image)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showOnMain(image: image)
            }
        }
    }

    private func showOnMain(image: CGImage) {
        sourceImage = image
        if let window {
            window.update(image: image)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = BeautifyWindow(image: image)
        win.delegate = self
        win.onCopy = { rendered in
            ScreenshotManager.shared.copyToPasteboard(rendered)
            Toast.show("美化图已复制", icon: "checkmark.circle.fill")
        }
        win.onSave = { rendered in
            guard let data = ImageProcessor.pngData(rendered),
                  let url = ScreenshotManager.shared.savePNG(data) else { return }
            ScreenshotManager.shared.registerCaptured(url: url, data: data)
            Toast.show("美化图已保存", icon: "checkmark.circle.fill")
        }
        win.onPin = { rendered in
            PinnedScreenshotManager.shared.show(image: rendered)
            Toast.show("美化图已钉在屏幕上", icon: "pin.fill")
        }
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) {
        if (notification.object as? BeautifyWindow) === window { window = nil }
    }
}

/// 美化窗口：左预览右控件（AppKit + SwiftUI 控件混排）
final class BeautifyWindow: NSWindow, NSWindowDelegate {

    private let imageView = NSImageView(frame: .zero)
    private var image: CGImage
    private var options = BeautifyOptions() {
        didSet { rerender() }
    }

    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onPin: ((CGImage) -> Void)?

    private var rendered: CGImage?
    /// 防抖渲染（slider 连续变化）
    private var renderWork: DispatchWorkItem?

    init(image: CGImage) {
        self.image = image
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "截图美化"
        applyOfficialChrome()
        isReleasedWhenClosed = false
        minSize = NSSize(width: 620, height: 440)
        buildUI()
        rerender()
    }

    func update(image newImage: CGImage) {
        image = newImage
        rerender()
    }

    private func buildUI() {
        let container = NSView(frame: NSRect(origin: .zero, size: contentRect(forFrameRect: frame).size))

        // 左：预览
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 12, y: 12, width: 470, height: 496)
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.cornerCurve = .continuous   // v156: G2（曲率连续）圆角
        imageView.layer?.masksToBounds = true
        container.addSubview(imageView)

        // 右：控件（SwiftUI 承载）
        let controls = BeautifyControlsView(options: Binding(
            get: { [weak self] in self?.options ?? BeautifyOptions() },
            set: { [weak self] in self?.options = $0 }))
        let host = NSHostingView(rootView: controls)
        host.frame = NSRect(x: 494, y: 52, width: 252, height: 456)
        host.autoresizingMask = [.minXMargin, .height]
        container.addSubview(host)

        // 底部按钮
        let copy = NSButton(title: "复制", target: self, action: #selector(copyTapped))
        let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
        let pin = NSButton(title: "钉住", target: self, action: #selector(pinTapped))
        for (index, button) in [copy, save, pin].enumerated() {
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 494 + CGFloat(index) * 88, y: 14, width: 80, height: 30)
            button.autoresizingMask = [.minXMargin]
            container.addSubview(button)
        }

        contentView = container
        // v208：标题栏使用原生红绿灯（不随 contentView 替换消失）
    }

    private func rerender() {
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let out = BeautifyRenderer.render(image: self.image, options: self.options) else { return }
            DispatchQueue.main.async {
                self.rendered = out
                self.imageView.image = ImageProcessor.nsImage(out)
            }
        }
        renderWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    @objc private func copyTapped() { if let r = rendered { onCopy?(r) } }
    @objc private func saveTapped() { if let r = rendered { onSave?(r) } }
    @objc private func pinTapped() { if let r = rendered { onPin?(r) } }
}

// MARK: - 控件（SwiftUI）

private struct BeautifyControlsView: View {
    @Binding var options: BeautifyOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("背景").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: $options.background) {
                    Text("无").tag(BeautifyOptions.Background.none)
                    Text("纯色").tag(BeautifyOptions.Background.solid)
                    Text("渐变").tag(BeautifyOptions.Background.gradient)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if options.background != .none {
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: options.colorA) },
                            set: { options.colorA = NSColor($0) }), supportsOpacity: false)
                            .labelsHidden()
                        if options.background == .gradient {
                            ColorPicker("", selection: Binding(
                                get: { Color(nsColor: options.colorB) },
                                set: { options.colorB = NSColor($0) }), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }

                sliderRow("边距", value: Binding(
                    get: { options.padding }, set: { options.padding = $0 }), range: 0...100)
                sliderRow("圆角", value: Binding(
                    get: { options.cornerRadius }, set: { options.cornerRadius = $0 }), range: 0...44)
                sliderRow("投影", value: Binding(
                    get: { options.shadow }, set: { options.shadow = $0 }), range: 0...40)
            }
            Spacer()
            Text("美化结果可复制 / 保存 / 贴图；也可在「截图后默认执行」里设为默认动作。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 4)
    }

    private func sliderRow(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}
