import AppKit
import Vision

// MARK: - 马赛克「仅文本」（v264 · 1Capture 的 ANNOTATE_MOSAIC_TEXT_ONLY）
//
// 普通马赛克是「刷到哪糊到哪」：想把一段账号/手机号糊掉，得小心地沿着字刷，
// 手一抖就把旁边的正文也糊了。这个模式反过来——刷子只负责**指出范围**，
// 真正被糊的是「与笔触相交的文本行」的紧致矩形：
//   · 识别一次（Vision，本机，几十毫秒），按图像缓存；
//   · 只糊文本行，行间空白与图标不受影响；
//   · 没识别到文字时退回普通马赛克（不让用户以为工具坏了）。

public enum MosaicTextOnly {

    static let keyEnabled = "annotate.mosaic.textOnly"

    /// 默认关：它改变的是「刷一下会发生什么」，必须是用户主动选的
    public static var isEnabled: Bool {
        get { Preferences.shared.value(keyEnabled, default: false) }
        set { Preferences.shared.set(keyEnabled, newValue) }
    }

    /// 识别文本行矩形（**图像像素、左上原点**，与标注坐标系一致）
    public static func textLineRects(in image: CGImage) -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.warn("Capture", "仅文本马赛克：文本检测失败 \(error.localizedDescription)")
            return []
        }
        guard let observations = request.results else { return [] }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        return observations.compactMap { obs in
            let box = obs.boundingBox          // 归一化，左下原点
            guard box.width > 0, box.height > 0 else { return nil }
            return CGRect(x: box.minX * W,
                          y: (1 - box.maxY) * H,
                          width: box.width * W,
                          height: box.height * H)
        }
    }

    /// 笔触是否碰到某一文本行（按笔刷半径做膨胀判定）
    public static func stroke(_ points: [CGPoint], hits rect: CGRect, radius: CGFloat) -> Bool {
        guard !points.isEmpty else { return false }
        let expanded = rect.insetBy(dx: -max(2, radius), dy: -max(2, radius))
        // 线段上任一点落进膨胀矩形即算命中：按点采样（笔触本身已 1.2px 抽稀）
        for p in points where expanded.contains(p) { return true }
        // 长笔触跨过窄文本行时两点都在外侧 —— 补一次线段与矩形相交判定
        guard points.count >= 2 else { return false }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if expanded.contains(mid) { return true }
        }
        return false
    }
}
