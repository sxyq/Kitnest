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
    ///
    /// 2026-11-26 修复（二轮 low）：`VNRecognizeTextRequest(.accurate)` 是同步 perform，
    /// 而调用方在 mouseUp 的主线程里（AnnotationEditorWindow → textLines），4K 截图上首次
    /// 识别可阻塞数百毫秒、期间无超时无取消。现在：
    ///   · 结果按图像对象缓存（只留最后一张，见 `cachedImage`），同一张图只识别一次；
    ///   · 调用方可在图像载入时先调 `prewarm(in:)` 把识别丢到后台，之后这里直接命中缓存；
    ///   · 未预热时仍同步识别一次——保持原有「首次调用即得结果」的契约，
    ///     避免调用方把空的懒缓存记下来、导致「仅文本」整场失效。
    public static func textLineRects(in image: CGImage) -> [CGRect] {
        if let cached = cachedRects(for: image) { return cached }
        let rects = recognize(in: image)
        store(rects, for: image)
        return rects
    }

    /// 后台预热识别（**不阻塞调用线程**）。建议在图像载入后立刻调用。
    ///
    /// 同一张图只会真正跑一次：命中缓存或已有任务在跑时直接返回。
    /// 注意：预热尚未完成时若 `textLineRects` 被同步调用，会再识别一次（不在这里
    /// 阻塞等待——主线程上的等待比多跑一遍 Vision 更难接受）。
    public static func prewarm(in image: CGImage) {
        cacheLock.lock()
        let done = cachedImage === image
        let running = inFlightImage === image
        if !done && !running { inFlightImage = image }
        cacheLock.unlock()
        guard !done, !running else { return }
        DispatchQueue.global(qos: .utility).async {
            let rects = recognize(in: image)
            store(rects, for: image)
            cacheLock.lock()
            if inFlightImage === image { inFlightImage = nil }
            cacheLock.unlock()
        }
    }

    /// 实际识别（可能在任意线程调用）
    private static func recognize(in image: CGImage) -> [CGRect] {
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

    // MARK: 识别结果缓存（2026-11-26 修复）
    //
    // 只缓存**最后一张**图像：条目里存的是强引用，被缓存图像不会释放，
    // 因此 `===` 身份比较是可靠的（不会出现 ObjectIdentifier 复用导致串图），
    // 内存上也只多留一张图。

    private static let cacheLock = NSLock()
    private static var cachedImage: CGImage?
    private static var cachedLineRects: [CGRect] = []
    private static var inFlightImage: CGImage?

    private static func cachedRects(for image: CGImage) -> [CGRect]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard cachedImage === image else { return nil }
        return cachedLineRects
    }

    private static func store(_ rects: [CGRect], for image: CGImage) {
        cacheLock.lock()
        cachedImage = image
        cachedLineRects = rects
        cacheLock.unlock()
    }

    /// 笔触是否碰到某一文本行（按笔刷半径做膨胀判定）
    public static func stroke(_ points: [CGPoint], hits rect: CGRect, radius: CGFloat) -> Bool {
        guard !points.isEmpty else { return false }
        let expanded = rect.insetBy(dx: -max(2, radius), dy: -max(2, radius))
        // 线段上任一点落进膨胀矩形即算命中：按点采样（笔触本身已 1.2px 抽稀）
        for p in points where expanded.contains(p) { return true }
        guard points.count >= 2 else { return false }
        // 2026-11-26 修复（二轮 low）：原来只补「相邻两点中点」，两个点跨越整行时
        // （按下在行左、抬起在行右、中间无拖拽采样）端点与中点都可能落在行外 →
        // 判未命中并退回普通马赛克，「仅文本」开关等于失效。这里改成真正的
        // 线段-矩形相交判定（Liang–Barsky 裁剪，逐段精确，不再靠采样蒙）。
        for i in 1..<points.count where segmentIntersects(points[i - 1], points[i], rect: expanded) {
            return true
        }
        return false
    }

    /// 线段 ab 是否与 rect 相交（含端点落在内部、线段穿过、完全包含）
    private static func segmentIntersects(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        // Liang–Barsky：把线段参数 t∈[0,1] 逐边裁剪，全部不被裁掉即相交
        let dx = b.x - a.x
        let dy = b.y - a.y
        let p: [CGFloat] = [-dx, dx, -dy, dy]
        let q: [CGFloat] = [a.x - rect.minX, rect.maxX - a.x,
                            a.y - rect.minY, rect.maxY - a.y]
        var t0: CGFloat = 0, t1: CGFloat = 1
        for i in 0..<4 {
            if p[i] == 0 {
                // 与该边平行：落在外侧则不相交
                if q[i] < 0 { return false }
                continue
            }
            let t = q[i] / p[i]
            if p[i] < 0 {
                if t > t1 { return false }
                t0 = max(t0, t)
            } else {
                if t < t0 { return false }
                t1 = min(t1, t)
            }
        }
        return true
    }
}
