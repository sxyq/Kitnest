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

    /// 返回识别出的整段文本（按阅读顺序、段落分行）
    public func recognizeText(imageData: Data) async throws -> String {
        try await visionRecognizeText(imageData: imageData)
    }

    /// 返回带归一化 boundingBox 的片段（左下原点，供取词 / 翻译定位用）。
    /// 定位用途必须用本机 Vision（AI 通道不给坐标），故此方法不随引擎切换。
    public func recognizeObservations(imageData: Data) async throws -> [OCRTextObservation] {
        // 经图片缓存解码，重复识别同一张图时省一次解码
        guard let image = ScreenshotOCRDirectImageStore.shared.image(for: imageData) else {
            throw CaptureError.invalidImage
        }
        return try await recognizeObservations(image: image)
    }

    // MARK: CGImage 入口（模块内使用）

    public func recognizeText(image: CGImage) async throws -> String {
        Self.assemble(Self.readingOrder(try await recognizeObservations(image: image)))
    }

    public func recognizeObservations(image: CGImage) async throws -> [OCRTextObservation] {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let results = request.results, !results.isEmpty else { return [] }
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRTextObservation(text: candidate.string, boundingBox: observation.boundingBox)
        }
    }

    /// 本机 Vision 整段文本（排序 + 段落 + 中文空格清理）。
    /// 注意不能回调 `recognizeText(imageData:)`——那会按引擎再路由一次，AI 失败回落时会死循环。
    private func visionRecognizeText(imageData: Data) async throws -> String {
        let observations = try await recognizeObservations(imageData: imageData)
        return Self.assemble(Self.readingOrder(observations))
    }

    // MARK: 请求构造

    private func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 自动语言纠正（英文单词纠错）
        request.usesLanguageCorrection = true
        // revision3 在中英混排上准确率更高（macOS 12+）
        if #available(macOS 12.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }
        // 自动检测语言：Vision 按每个文本行选语言模型，中英混排截图比固定列表更准。
        // 开启后 recognitionLanguages 被忽略（Apple 文档）。
        if #available(macOS 13.0, *), Self.autoDetectLanguages {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = Self.currentLanguages
        }
        return request
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

    /// 去掉中文字符之间的空格（Vision 常见误差：「文 字 录 入」→「文字录入」）
    public static func cleanLine(_ raw: String) -> String {
        let pattern = "(?<=[\\u4E00-\\u9FFF\\u3400-\\u4DBF\\u3000-\\u303F\\uFF01-\\uFF60])[ \\u00A0]+"
            + "(?=[\\u4E00-\\u9FFF\\u3400-\\u4DBF\\u3000-\\u303F\\uFF01-\\uFF60])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return raw.trimmingCharacters(in: .whitespaces)
        }
        let range = NSRange(raw.startIndex..., in: raw)
        let cleaned = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        return cleaned.trimmingCharacters(in: .whitespaces)
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
