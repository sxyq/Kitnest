import Foundation
import CoreGraphics
import ImageIO
import Vision

// MARK: - 直连模式的图片缓存

/// 直连通道的图片缓存（对应原作 `ScreenshotOCRDirectImageStore`）：
/// 按图片内容缓存已解码的 CGImage，避免「识别 → 重新识别」时重复解码同一份数据。
public final class ScreenshotOCRDirectImageStore {
    public static let shared = ScreenshotOCRDirectImageStore()

    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    /// NSData 按内容做相等/哈希，天然适合做内容键
    private let cache = NSCache<NSData, Box>()

    private init() { cache.countLimit = 12 }

    /// 取（必要时解码并缓存）图片
    public func image(for data: Data) -> CGImage? {
        let key = data as NSData
        if let box = cache.object(forKey: key) { return box.image }
        guard let image = ImageProcessor.cgImage(from: data) else { return nil }
        cache.setObject(Box(image), forKey: key)
        return image
    }
}

// MARK: - 识别质量档位（v141）

/// 识别遍数（v141）
/// - `fast`：单遍，适合剪贴板等高频后台路径
/// - `thorough`：多遍换配置识别 + 行级投票合并，适合「识字 / 翻译」这类用户显式动作
public enum OCRQuality {
    case fast
    case thorough
}

// MARK: - OCR 服务（本机 Vision）
//
// OCR 模型口径（2026-10-20 用户：只讨论 OCR 模型，不新增引擎）：
//   唯一识别通道是 **Apple Vision** 的 `VNRecognizeTextRequest`（accurate 档、revision 3），
//   离线、快、不上传图片。换模型要么捆绑第三方运行时（PaddleOCR/ONNX 之类），
//   要么走联网大模型——后者属「新增引擎」，本轮不做，只在文档里记结论。
///
/// 2026-10-20 用户反馈「OCR 效果不太行」，本机通道做了三项质量修复：
///   ① 阅读顺序：Vision 返回的 observations 是检测顺序，不是阅读顺序——必须按
///      boundingBox 自上而下、行内从左到右重排，否则整段文本读起来是乱的；
///   ② 段落：行间距明显大于行高的地方插空行，保留原文段落感；
///   ③ 中文空格：Vision 在中文里常插空格（「文 字」），逐行去掉 CJK 之间的空白。
public final class OCRService: OCRServiceProtocol {

    public static let shared = OCRService()

    private init() {}

    // MARK: 识别参数

    /// 自动语言检测（Vision revision 3）；关闭时用 Preferences.ocrLanguages 指定语言
    private static let autoDetectKey = "ocr.autoDetectLanguages"

    public static var autoDetectLanguages: Bool {
        get { Preferences.shared.value(autoDetectKey, default: true) }
        set { Preferences.shared.set(autoDetectKey, newValue) }
    }

    // MARK: OCRServiceProtocol

    // 协议要求（无 quality 参数）：默认单遍，剪贴板等高频路径直接走协议实现
    public func recognizeText(imageData: Data) async throws -> String {
        try await recognizeText(imageData: imageData, quality: .fast)
    }

    public func recognizeObservations(imageData: Data) async throws -> [OCRTextObservation] {
        try await recognizeObservations(imageData: imageData, quality: .fast)
    }

    /// 返回识别出的整段文本（按阅读顺序、段落分行）
    public func recognizeText(imageData: Data, quality: OCRQuality) async throws -> String {
        let observations = try await recognizeObservations(imageData: imageData, quality: quality)
        return Self.assemble(Self.readingOrder(observations))
    }

    /// 返回带归一化 boundingBox 的片段（左下原点，供取词 / 翻译定位用）。
    /// 定位用途必须用本机 Vision（AI 通道不给坐标），故此方法不随引擎切换。
    public func recognizeObservations(imageData: Data,
                                     quality: OCRQuality) async throws -> [OCRTextObservation] {
        // 经图片缓存解码，重复识别同一张图时省一次解码
        guard let image = ScreenshotOCRDirectImageStore.shared.image(for: imageData) else {
            throw CaptureError.invalidImage
        }
        return try await recognizeObservations(image: image, quality: quality)
    }

    // MARK: CGImage 入口（模块内使用）

    public func recognizeText(image: CGImage, quality: OCRQuality = .fast) async throws -> String {
        Self.assemble(Self.readingOrder(try await recognizeObservations(image: image, quality: quality)))
    }

    public func recognizeObservations(image: CGImage,
                                      quality: OCRQuality = .fast) async throws -> [OCRTextObservation] {
        switch quality {
        case .fast:
            return try Self.singlePass(image: image)
        case .thorough:
            // 整段多遍识别丢到后台线程（多遍合计几百毫秒，不能占主线程）
            return await Task.detached(priority: .userInitiated) {
                Self.multiPassSync(image: image)
            }.value
        }
    }

    // MARK: 单遍识别（含置信度过滤 + 空结果兜底）

    private static func singlePass(image: CGImage) throws -> [OCRTextObservation] {
        let auto = autoDetectEnabled
        var lines = try runPass(image: image, variant: .init(autoDetect: auto, languages: nil,
                                                            correction: true, scale: 1.0))
        if lines.isEmpty, auto {
            lines = (try? runPass(image: image, variant: .init(autoDetect: false,
                                                              languages: ["zh-Hans", "en-US"],
                                                              correction: true, scale: 1.6))) ?? []
        }
        // v151：仍然什么都认不出 → 试一次自适应放大。
        // 实测（用户给的 Pinterest 链接截图）：438×68 的链接条**贴进 1600×900 的大截图**后，
        // 原生尺寸下 Vision 返回 0 行（conf 0.00）；整图放大 2 倍立刻完整读出 URL。
        if lines.isEmpty, let scale = enhancementScale(image: image, lines: []) {
            Log.debug("Capture", "OCR 空结果：追加 \(String(format: "%.1f", scale))× 放大重试")
            lines = (try? runPass(image: image, variant: .init(autoDetect: auto, languages: nil,
                                                              correction: true, scale: scale))) ?? []
        }
        // 置信度过滤：碎噪点（图标边角/压缩噪点）常被识别成一两个字
        return lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if line.confidence < 0.3, text.count <= 2 { return nil }
            return OCRTextObservation(text: line.text, boundingBox: line.box)
        }
    }

    // MARK: 多遍识别 + 行级投票（v141）

    /// 一条识别结果（内部用，带置信度）
    private struct OCRLine {
        let text: String
        let confidence: Float
        let box: CGRect
    }

    /// 一遍识别的配置。Vision 对**相同输入 + 相同配置**是确定性的，重复跑没意义；
    /// 只有换配置（语言检测方式 / 语种顺序 / 纠错开关 / 放大倍率）才会得到互补的结果。
    private struct OCRVariant {
        let autoDetect: Bool
        let languages: [String]?
        let correction: Bool
        /// 相对**原图**的绝对放大倍率（不再是"再乘一次"的相对值——
        /// 实测不同倍率会给出互补结果：×1.0 认出「继续/的」，×3.0 却认成「时」）
        let scale: Double
    }

    private static func passVariants(for image: CGImage) -> [OCRVariant] {
        // 实测（12pt 中文：×1.0 认对「的路径」，×3.0 认成「时路径」；9pt 混排：
        // ×1.0 认对「继续」，×3.0 认成「续」）——**倍率是彼此互补的最大来源**。
        // 所以这里用「绝对倍率」铺 1.0 / 1.6 / 2.4 三档，而不是先统一放大再微调。
        let maxPixels = 3200.0
        let base = Double(image.width)
        var list: [OCRVariant] = [
            // ① 原尺寸 + 自动语言检测（清晰截图上这遍最准）
            .init(autoDetect: autoDetectEnabled, languages: nil, correction: true, scale: 1.0),
            // ② 1.6× + 显式中文优先（小字、中文被误判成日文/繁体）
            .init(autoDetect: false, languages: ["zh-Hans", "en-US"], correction: true, scale: 1.6),
            // ③ 2.4× + 英文优先 + 关纠错（术语/连笔被"纠错"纠坏）
            .init(autoDetect: false, languages: ["en-US", "zh-Hans"], correction: false, scale: 2.4)
        ]
        // 大图（Retina 截图 >=1600px 宽）本身已清晰，再放大只烧内存与时间
        list = list.filter { base * $0.scale <= maxPixels || $0.scale <= 1.0 }
        return list.isEmpty ? [.init(autoDetect: autoDetectEnabled, languages: nil, correction: true, scale: 1.0)] : list
    }

    /// 小字/空结果时的放大倍率（v151）
    ///
    /// 判据：**没有识别到任何行** → 2×；**文本行高中位数 < 14px** → 放大到行高约 18px（2~3×）。
    /// 行高 ≥14px 时不放大——v141 实测在 12pt 中文上盲目放大反而认错字（「的路径」→「时路径」）。
    /// 同时按内存/边长上限收口（放大后 ≤24MP、边长 ≤6000px）。
    private static func enhancementScale(image: CGImage, lines: [OCRLine]) -> Double? {
        let h = Double(image.height)
        var scale: Double
        if lines.isEmpty {
            scale = 2.0
        } else {
            let heights = lines.map { Double($0.box.height) * h }.sorted()
            guard !heights.isEmpty else { return nil }
            let median = heights[heights.count / 2]
            guard median > 0, median < 14 else { return nil }
            scale = min(3.0, max(2.0, 18.0 / median))
        }
        let pixels = Double(image.width) * h
        let cap = min((24_000_000.0 / max(pixels, 1)).squareRoot(),
                      6000.0 / Double(max(image.width, image.height)))
        guard cap >= 1.6 else { return nil }
        return min(scale, cap)
    }

    /// 锚（原生）与小字增强版的合并（v151）
    ///
    /// 逐行按 IoU 配对；增强版**多出字**（OCR 漏字是最常见失败）或置信度明显更高时采纳，
    /// 否则保留原生结果。增强版独有的行（原生整行没检测到）置信度 ≥0.5 才补进来。
    private static func mergeEnhanced(anchor: [OCRLine], enhanced: [OCRLine]) -> [OCRTextObservation] {
        var used = [Bool](repeating: false, count: enhanced.count)
        var out: [OCRTextObservation] = []
        out.reserveCapacity(max(anchor.count, enhanced.count))
        for a in anchor {
            var bestIdx: Int?
            var bestIoU: CGFloat = 0
            for (i, b) in enhanced.enumerated() where !used[i] {
                let v = iou(a.box, b.box)
                if v > bestIoU { bestIoU = v; bestIdx = i }
            }
            if let i = bestIdx, bestIoU >= 0.4 {
                used[i] = true
                let b = enhanced[i]
                let better = b.confidence > a.confidence + 0.08
                    || b.text.count > a.text.count + 1
                out.append(OCRTextObservation(text: better ? b.text : a.text, boundingBox: a.box))
            } else {
                out.append(OCRTextObservation(text: a.text, boundingBox: a.box))
            }
        }
        for (i, b) in enhanced.enumerated() where !used[i] {
            let text = b.text.trimmingCharacters(in: .whitespaces)
            guard b.confidence >= 0.5, text.count >= 2 else { continue }
            if !out.contains(where: { iou($0.boundingBox, b.box) >= 0.35 }) {
                out.append(OCRTextObservation(text: b.text, boundingBox: b.box))
            }
        }
        // ③ 被增强行「包住」的碎片丢掉：原生尺寸下长网址常被拆成两行
        //    （`in.pinteres..com/` + `10591200378628400704`），放大后是一整行。
        //    只按 IoU 配对（≥0.4）配不上，会留下碎片＋整行两份。这里若增强行
        //    覆盖了锚行的 60% 以上、且文字明显更长，就丢掉锚行。
        let enhancedBoxes = enhanced.map { ($0.box, $0.text) }
        out.removeAll { obs in
            guard let e = enhancedBoxes.first(where: { box, text in
                coverage(of: obs.boundingBox, in: box) >= 0.6 && text.count > obs.text.count + 2
            }) else { return false }
            return e.1.count > obs.text.count + 2
        }
        return out
    }

    /// a 被 b 覆盖的面积比例（a ∩ b / a）
    private static func coverage(of a: CGRect, in b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let area = a.width * a.height
        return area > 0 ? (inter.width * inter.height) / area : 0
    }

    private static func multiPassSync(image: CGImage) -> [OCRTextObservation] {
        let variants = passVariants(for: image)
        let anchorVariant = variants[0]

        // ① 先跑锚（原尺寸 + 自动语言）——实测这一遍最准
        let anchor = (try? runPass(image: image, variant: anchorVariant)) ?? []
        var observations: [OCRTextObservation] = anchor.map {
            OCRTextObservation(text: $0.text, boundingBox: $0.box)
        }

        // ② 自适应：锚「看起来可信」就不再多跑。判据：
        //    · 至少识别出 3 行
        //    · 低置信度行（<0.5）占比 < 30%
        //    基准测试（6 类样本，含杂乱背景/9pt 小字）里这一条让 95% 的情况只跑一遍，
        //    准确率与多遍完全一致——多遍在这些干净文字上没有任何增益。
        // v151：小字/空结果 → 直接跑一次放大版（这是「大截图里的小链接认不出」的根因：
        // 原生尺寸下 Vision 连行都检测不到，放大 2 倍后 100% 可读）。
        if let scale = enhancementScale(image: image, lines: anchor) {
            let enhanced = (try? runPass(image: image,
                                         variant: .init(autoDetect: autoDetectEnabled,
                                                        languages: nil,
                                                        correction: true,
                                                        scale: scale))) ?? []
            Log.debug("Capture", "OCR 小字增强：锚 \(anchor.count) 行 → "
                      + "\(String(format: "%.1f", scale))× 补跑 \(enhanced.count) 行")
            let merged = anchor.isEmpty
                ? enhanced.map { OCRTextObservation(text: $0.text, boundingBox: $0.box) }
                : mergeEnhanced(anchor: anchor, enhanced: enhanced)
            return OCRRefinerRegistry.shared.active.refine(merged, image: image)
        }

        let lowConf = anchor.filter { $0.confidence < 0.5 }.count
        let confident = anchor.count >= 3 && Double(lowConf) / Double(max(anchor.count, 1)) < 0.3
        if !confident {
            // ③ 可疑（几乎没识别出东西 / 大量低置信度）→ 换倍率补跑，只补漏行
            Log.debug("Capture", "OCR 首遍可疑（\(anchor.count) 行，低置信度 \(lowConf)），追加多倍率补识别")
            var passes = [anchor]
            var rest = variants
            rest.removeFirst()
            passes.append(contentsOf: rest.map { (try? runPass(image: image, variant: $0)) ?? [] })
            observations = merge(passes)
            Log.debug("Capture", "OCR 多遍补识别：逐遍行数 "
                      + passes.map { "\($0.count)" }.joined(separator: "/")
                      + " → 合并 \(observations.count) 行")
        }

        // ④ 复核：交给 OCR Refiner（v147 抽出接口）——
        //    `local` = 系统定位 + 本地 PP-OCR 认字（默认，中文更准）；
        //    `system` = 只用 Apple Vision。
        //    注意必须在所有合并之后做：合并分支会用锚的原始文本重建结果，先复核会被冲掉
        //    （实测「杂底小字」用例复核 3/3 行但最终文本仍是 Vision 的）。
        return OCRRefinerRegistry.shared.active.refine(observations, image: image)
    }

    /// 用本地 PP-OCR 逐行复核 Vision 的识别结果（v142 引入，v144 子进程，v145 采纳规则）
    ///
    /// 分工：**Apple Vision 定位文本行**（检测很准），**PP-OCR 认字**（中文更强）。
    ///
    /// v145 采纳规则（真机自检实测后收紧）：
    ///   1. 只要整屏**有任何一行**含中文才启用（纯英文/代码界面直接交回 Vision，
    ///      省一次子进程往返）；
    ///   2. 所有行都送过去，但**不是都采纳**：
    ///      · PP-OCR 认出更多中文字（补回 Vision 整词漏识）→ 采纳；
    ///      · 中文字数相同且都 > 0、内容（去标点后）不同 → 采纳（改形近字）；
    ///      · 纯英文/代码行（两边中文字数都是 0）→ 一律不采纳（实测 PP-OCR 会把
    ///        `\(result)` 吃成 `A(result)`、`https://` 的双斜杠吃成一个）；
    ///      · **只差标点** → 不采纳（真机实测：PP-OCR 会把「，」认成「。」，
    ///        而标点恰好是 Vision 的强项）。
    static func refineWithPPOCR(_ observations: [OCRTextObservation], image: CGImage) -> [OCRTextObservation] {
        guard !observations.isEmpty, PPOCROCREmote.isAvailable else { return observations }
        guard observations.contains(where: { Self.containsCJK($0.text) }) else { return observations }
        let w = CGFloat(image.width), h = CGFloat(image.height)

        var targets: [(index: Int, rect: CGRect)] = []
        targets.reserveCapacity(observations.count)
        for (index, obs) in observations.enumerated() {
            let bb = obs.boundingBox
            // Vision 的 boundingBox 是归一化 + 左下原点 → 图像像素矩形（外扩 2px 留边）
            let rect = CGRect(x: bb.minX * w - 2, y: (1 - bb.maxY) * h - 2,
                              width: bb.width * w + 4, height: bb.height * h + 4).integral
            guard rect.width >= 4, rect.height >= 4 else { continue }
            targets.append((index, rect))
        }
        guard !targets.isEmpty else { return observations }

        let results = PPOCROCREmote.recognize(image: image, boxes: targets.map { $0.rect })
        guard results.count == targets.count else {
            if !results.isEmpty {
                Log.warn("Capture", "本地 OCR：结果数量不匹配（\(results.count)/\(targets.count)），保留 Vision 文本")
            }
            return observations
        }

        var out = observations
        var replaced = 0, skippedPunctuation = 0
        for (k, target) in targets.enumerated() {
            guard let result = results[k],
                  result.confidence >= 0.45, !result.text.isEmpty else { continue }
            let visionText = observations[target.index].text
            let visionCJK = Self.cjkCount(visionText)
            let ppocrCJK = Self.cjkCount(result.text)
            let recovered = ppocrCJK > visionCJK
            let sameScript = ppocrCJK == visionCJK && ppocrCJK > 0
            guard recovered || sameScript else { continue }   // 英文/代码行：留在 Vision
            guard Self.contentKey(result.text) != Self.contentKey(visionText) else {
                skippedPunctuation += 1
                continue                                       // 只差标点：留在 Vision
            }
            out[target.index] = OCRTextObservation(text: result.text,
                                                   boundingBox: observations[target.index].boundingBox)
            replaced += 1
        }
        if replaced > 0 || skippedPunctuation > 0 {
            Log.debug("Capture", "OCR：本地 PP-OCR 复核 \(replaced)/\(observations.count) 行"
                      + (skippedPunctuation > 0 ? "（\(skippedPunctuation) 行仅标点差异，保留 Vision）" : "")
                      + "（子进程）")
        }
        return out
    }

    /// 中文字符数（判断「有没有补回字」）
    static func cjkCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
                || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                count += 1
            }
        }
        return count
    }

    /// 内容指纹：去空白、去标点、去符号、统一小写。
    /// 用来判断「两份文本是不是只差标点」——只差标点就保留 Vision 的（它的标点更准）。
    static func contentKey(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// 是否包含中日韩表意文字（决定这一行是否交给 PP-OCR）
    static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
                || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                return true
            }
        }
        return false
    }

    /// 锚定式合并（v141 实测修订）
    ///
    /// 一开始按「多数投票 / 最高置信度」合并，基准测试反而更差（1.8% → 2.6%）：
    /// 1.6×/2.4× 那两遍会把「继续」认成「总续」、把「的路径」认成「时路径」，
    /// 而它们的置信度并不低，投票/置信度都会把**正确结果挤掉**。
    /// 实测结论：**原尺寸 + 自动语言**这一遍最准，应作为锚；
    /// 其余遍只做两件事——补回锚里没有的行（召回），以及在锚里置信度很低时替换。
    private static func merge(_ passes: [[OCRLine]]) -> [OCRTextObservation] {
        guard let anchor = passes.first else { return [] }
        var merged: [(line: OCRLine, locked: Bool)] = anchor.map { ($0, true) }
        let others = passes.dropFirst().flatMap { $0 }

        // 只做「补行」：锚里**同一水平带**完全没有的行才收（别遍识别到了漏识内容）。
        // 不做"替换"——实测替换会把正确结果换成高置信度的错误结果。
        // 去重用 y 带重叠而不是 IoU：同一条文字在不同倍率下横向框会偏移，
        // 但纵向中心几乎不变；用 IoU 会误判成新行、把整行重复追加。
        for line in others where line.confidence >= 0.55 {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { continue }
            let newMidY = line.box.midY
            let newHeight = max(line.box.height, 0.004)
            let exists = merged.contains { item in
                abs(item.line.box.midY - newMidY) < newHeight * 0.5
            }
            if !exists { merged.append((line, false)) }
        }

        return merged.compactMap { item in
            let text = item.line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if item.line.confidence < 0.25, text.count <= 2 { return nil }
            return OCRTextObservation(text: item.line.text, boundingBox: item.line.box)
        }
    }

    /// 归一化矩形 IoU（Vision boundingBox 已是 0...1、左下原点）
    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let ia = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - ia
        return union > 0 ? ia / union : 0
    }

    // MARK: 识别执行（含小图放大预处理）

    private static func runPass(image: CGImage, variant: OCRVariant) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = variant.correction
        if #available(macOS 12.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        if #available(macOS 13.0, *), variant.autoDetect {
            request.automaticallyDetectsLanguage = true
        } else if let languages = variant.languages, !languages.isEmpty {
            request.recognitionLanguages = languages
        } else {
            request.recognitionLanguages = currentLanguages
        }
        guard let prepared = preparedForOCR(image, scale: variant.scale) else { return [] }
        let handler = VNImageRequestHandler(cgImage: prepared, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return OCRLine(text: text, confidence: candidate.confidence, box: observation.boundingBox)
        }
    }

    /// 小图放大预处理——Vision 对小字号敏感，界面截图（尤其 1x 屏或用户裁得很小）
    /// 直接喂进去经常整行漏识。宽度 < 1000px 时放大到 ~1600px（最多 3 倍，
    /// 高质量插值），识别完 boundingBox 仍是归一化坐标，不影响回绘。
    static func preparedForOCR(_ image: CGImage, scale: Double = 1.0) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(4.0, max(1.0, scale))
        guard scale >= 1.15 else { return image }
        let nw = Int((Double(w) * scale).rounded()), nh = Int((Double(h) * scale).rounded())
        guard nw < 12000, nh < 12000, let ctx = CGContext(data: nil, width: nw, height: nh,
                                  bitsPerComponent: 8, bytesPerRow: nw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    /// 自动语言检测是否开启（macOS 13+ 才有该能力）
    private static var autoDetectEnabled: Bool {
        if #available(macOS 13.0, *) { return autoDetectLanguages }
        return false
    }

    // MARK: 阅读顺序 / 段落 / 中文空格

    /// 按几何位置重排：自上而下（容差 ≈ 行高一半），同一行内从左到右。
    /// boundingBox 是归一化、左下原点，转成「行顶 y」比较。
    public static func readingOrder(_ list: [OCRTextObservation]) -> [OCRTextObservation] {
        list.sorted { a, b in
            let ay = 1 - a.boundingBox.maxY
            let by = 1 - b.boundingBox.maxY
            let tolerance = max(a.boundingBox.height, b.boundingBox.height) * 0.5
            if abs(ay - by) > tolerance { return ay < by }
            return a.boundingBox.minX < b.boundingBox.minX
        }
    }

    /// 拼段：同一段落内行与行之间只换行，行距明显更大时插空行分段
    public static func assemble(_ ordered: [OCRTextObservation]) -> String {
        var lines: [String] = []
        var previousBottom: CGFloat = 0
        for (index, obs) in ordered.enumerated() {
            let top = 1 - obs.boundingBox.maxY
            let height = max(obs.boundingBox.height, 0.012)
            if index > 0, top - previousBottom > height * 0.85 {
                lines.append("")
            }
            lines.append(cleanLine(obs.text))
            previousBottom = top + obs.boundingBox.height
        }
        return lines.joined(separator: "\n")
    }

    /// v126（性能审计 F2023）：正则编译缓存，避免 cleanLine 每次调用重新编译
    private static let cleanSpaceRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?<=[\\u4E00-\\u9FFF\\u3400-\\u4DBF\\u3000-\\u303F\\uFF01-\\uFF60])[ \\u00A0]+"
            + "(?=[\\u4E00-\\u9FFF\\u3400-\\u4DBF\\u3000-\\u303F\\uFF01-\\uFF60])")

    /// 去掉中文字符之间的空格（Vision 常见误差：「文 字 录 入」→「文字录入」）
    public static func cleanLine(_ raw: String) -> String {
        let cleaned: String
        if let regex = cleanSpaceRegex {
            let range = NSRange(raw.startIndex..., in: raw)
            cleaned = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        } else {
            cleaned = raw
        }
        return sanitizeURL(cleaned.trimmingCharacters(in: .whitespaces))
    }

    /// 网址整理（v151）：把「图标符号 + 网址」修成干净链接
    ///
    /// 实测问题：截图里的链接前面常带一个站点图标，Vision 会把它认成 `=` / `•` / `°` / `S`，
    /// 输出 `= in.pinterest.com/pin/1059120037362840070/`——看着像认错了，实际是**多了个垃圾前缀**，
    /// 复制出去也不是有效链接。这里只在「整行基本就是一个网址」时改写：
    ///   · 去掉开头非字母数字符号；
    ///   · 清掉网址内部的空格（`10591 2003...` → `105912003...`）；
    ///   · 去掉尾部句号/逗号（英文句子的句号不该粘进链接）。
    private static let urlLeadJunkRegex = try? NSRegularExpression(pattern: "^[^A-Za-z0-9]+")
    private static let urlLineRegex = try? NSRegularExpression(
        pattern: "^(?:https?://)?(?:[A-Za-z0-9-]+\\.)+[A-Za-z]{2,}(?:/[^\\s]*)?$")

    public static func sanitizeURL(_ line: String) -> String {
        guard line.contains("."), !line.isEmpty else { return line }
        var candidate = line

        // ① 去掉网址前的图标符号（仅当其后紧跟的是网址）
        if let regex = urlLeadJunkRegex {
            let full = NSRange(candidate.startIndex..., in: candidate)
            if let m = regex.firstMatch(in: candidate, range: full),
               let r = Range(m.range, in: candidate) {
                let rest = String(candidate[r.upperBound...])
                if isURLShaped(rest) || isURLShaped(rest.replacingOccurrences(of: " ", with: "")) {
                    candidate = rest
                }
            }
        }

        // ② 整行是网址：清理内部空格与尾部标点
        var url = candidate
        if !isURLShaped(url) {
            let compact = url.replacingOccurrences(of: " ", with: "")
            if url.contains("/"), isURLShaped(compact) { url = compact } else { return line }
        }
        while let last = url.last, ".,;:!?、。，；：".contains(last) { url.removeLast() }
        return url.isEmpty ? line : url
    }

    private static func isURLShaped(_ s: String) -> Bool {
        guard !s.isEmpty, let regex = urlLineRegex else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return regex.firstMatch(in: s, range: range) != nil
    }

    /// 识别语言：读 Preferences.ocrLanguages（默认 简体中文 + 英文）
    public static var currentLanguages: [String] {
        let langs = Preferences.shared.value(Preferences.Keys.ocrLanguages, default: ["zh-Hans", "en-US"])
        return langs.isEmpty ? ["zh-Hans", "en-US"] : langs
    }

    /// 写入识别语言
    public static func setLanguages(_ languages: [String]) {
        Preferences.shared.set(Preferences.Keys.ocrLanguages, languages)
    }
}
